"""Parent pin-only I2S envelope check from dedicated Gowin setup/hold reports.

NOT a full-build sign-off. Requires all three pins in both dedicated reports.
Correctness also requires independently established RTL falling-edge updates,
complete worst-case paths/transitions/PVT, and a valid board/jitter budget.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from review_gowin_reports import sta_table_violations

PINS = ('amp_bclk', 'amp_din', 'amp_lrc')
NUMBER = r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)'


def parse_report(raw, analysis=None):
    if analysis is not None:
        if analysis not in ('Setup', 'Hold'):
            raise ValueError('Expected Setup or Hold analysis')
        expected_corner = 'Slow' if analysis == 'Setup' else 'Fast'
        if not re.search(r'<' + analysis + r' Delay Model>:\s*' + expected_corner + r'\b', raw):
            raise ValueError(f'Missing original {analysis}/{expected_corner} corner evidence')
        # A full .tr may contain both analyses: never mix its Fast hold paths
        # into the Slow maximum dataset (or vice versa). Extract only the proper
        # analysis sections, including separately reported exception paths.
        headings = list(re.finditer(r'^\s*(?:\d+(?:\.\d+)*\s+)?'
                                    r'(Setup|Hold|Recovery|Removal) Analysis Report\s*$',
                                    raw, re.M))
        sections = []
        for i, heading in enumerate(headings):
            if heading.group(1) == analysis:
                end = headings[i+1].start() if i+1 < len(headings) else len(raw)
                sections.append(raw[heading.end():end])
        if not sections:
            raise ValueError('Missing original ' + analysis + ' Analysis Report section')
        raw = '\n'.join(sections)
    delays = {pin: [] for pin in PINS}
    for block in re.split(r'(?=Path Summary:)', raw):
        if not block.startswith('Path Summary:'):
            continue
        target = re.search(r'^To\s*:\s*(\S+)', block, re.M)
        if not target:
            continue
        pin = next((p for p in PINS if re.search(r'(?:^|/)' + p + r'_obuf(?:/O)?$',
                                               target.group(1))), None)
        if pin is None:
            continue
        launch = re.search(r'^Launch Clk\s*:\s*(\S+)', block, re.M)
        if not launch or launch.group(1) != 'clk_audio:[R]':
            raise ValueError(f'{pin}: expected rising clk_audio launch, found {launch}')
        arrival = re.search(r'^Data Arrival Time\s*:\s*(' + NUMBER + ')', block, re.M)
        table = re.search(r'Data Arrival Path:(.*?)(?:Data Required Path:|Path Statistics:)',
                          block, re.S)
        edge = re.search(r'^\s*(' + NUMBER + r')\s+' + NUMBER +
                         r'\s+active clock edge time\s*$', table.group(1), re.M) if table else None
        if not arrival or not edge:
            raise ValueError(f'{pin}: missing absolute arrival or launching edge evidence')
        # Remove the nominal launch-edge offset, but retain real clock insertion,
        # register C2Q, routes and pad delay. Both extrema use the same definition.
        delay = float(arrival.group(1)) - float(edge.group(1))
        if not math.isfinite(delay) or delay < 0:
            raise ValueError(f'{pin}: invalid clock-source-to-pin delay {delay}')
        delays[pin].append(delay)
    for pin, values in delays.items():
        if not values:
            raise ValueError(f'Missing dedicated clock-source-to-pin paths for {pin}')
    return delays


def check_bounds(maximum, minimum, margin_ns=10.0, envelope_ns=40.0):
    if not math.isfinite(margin_ns) or margin_ns < 0 or not math.isfinite(envelope_ns) or envelope_ns <= 0:
        raise ValueError('Invalid board/jitter margin or path envelope')
    limits = {}
    for pin in PINS:
        low, high = min(minimum[pin]), max(maximum[pin])
        if not (0 <= low <= high <= envelope_ns):
            raise ValueError(f'{pin}: measured interval [{low}, {high}] outside [0,{envelope_ns}]ns')
        limits[pin] = dict(min_ns=low, max_ns=high)
    bclk = limits['amp_bclk']
    result = dict(pin_delays=limits, assumed_board_jitter_budget_ns=margin_ns,
                  nominal_half_bclk_ns=160.0, receiver_minimum_ns=10.0, data={})
    for pin in ('amp_din', 'amp_lrc'):
        data = limits[pin]
        setup = 160.0 + bclk['min_ns'] - data['max_ns'] - margin_ns
        hold = 160.0 + data['min_ns'] - bclk['max_ns'] - margin_ns
        if min(setup, hold) < 10.0:
            raise ValueError(f'{pin}: MAX98357A setup/hold insufficient: {setup}/{hold}ns')
        result['data'][pin] = dict(setup_lower_bound_ns=setup, hold_lower_bound_ns=hold)
    return result


def certified_envelope(raw, margin_ns=10.0, envelope_ns=40.0,
                       reviewed_reset_sync_exceptions=False):
    """Conservative constraint bounds, not measured maximum/minimum paths.

    Only valid after complete STA is clean and active output constraints are
    independently verified. Do not manufacture Slow paths from Fast numbers.
    """
    for kind in ('Setup', 'Hold'):
        match = re.search(r'<Numbers of ' + kind + r' Violated Endpoints>:\s*(\d+)', raw)
        if not match or int(match.group(1)):
            raise ValueError(f'Cannot certify envelope: complete {kind} STA must have zero violations')
    failures = sta_table_violations(raw)
    if failures:
        raise ValueError('Cannot certify envelope: ' + failures[0])
    clock = re.search(r'^\s*\d+\s+clk_audio\s+Generated\s+(' + NUMBER + r')\s+', raw, re.M)
    if not clock or abs(float(clock.group(1)) - 80.0) > .001:
        raise ValueError('Certified proof requires actual clk_audio period 80ns')
    commands = re.findall(r'^\s*TC_\w+\s+Actived\s+(.+)$', raw, re.M)
    if not commands:
        raise ValueError('Missing tool active-constraint evidence')
    for command in commands:
        # A clock-latency override changes the epoch used to derive C2O <=40.
        if re.search(r'set_clock_latency|set_clock_uncertainty|set_multicycle_path|set_min_delay', command):
            raise ValueError('Additional timing override needs manual proof: ' + command)
        if 'set_false_path' in command:
            # Only scoped receiver synchronizer-pin exceptions may coexist with
            # this automated inference. Broad clock/port cuts cannot certify IO.
            if not re.search(r'-to\s+\[get_pins\s+', command) or any(p in command for p in PINS):
                raise ValueError('Broad/IO false path invalidates automated envelope inference')
            target = re.search(r'-to\s+\[get_pins\s+\{([^}]+)\}\]', command)
            # An explicitly reviewed reset-synchronizer exception is a different
            # case from the data D-pin stage1 hold exception. It may suppress
            # recovery/removal only on the dedicated async CLEAR pins, not the
            # synchronizer's D/CE or reset-driven ordinary logic.
            reset_allowed = (r'u_top/(?:u_clock_reset/crst_sync_[012]|'
                             r'u_audio/u_core/crst_sync_[01]|'
                             r'u_audio/u_core/u_transport/arst_sync_[01])_s\d+/CLEAR')
            if (reviewed_reset_sync_exceptions and target and target.group(1).split() and
                    all(re.fullmatch(reset_allowed, p) for p in target.group(1).split())):
                continue
            allowed = (r'.*/(?:wgray_s1|rgray_s1|dt_s1|tgl_s1|uf_s1|of_s1)'
                       r'[\w\[\]*\\]*/D')
            if not target or not re.search(r'(?:^|\s)-hold(?:\s|$)', command) or '-setup' in command:
                raise ValueError('Require explicit hold-only stage1 CDC exception for automated proof')
            if not target.group(1).split() or any(not re.fullmatch(allowed, pin) for pin in target.group(1).split()):
                raise ValueError('False-path target is not a recognised first-stage synchronizer')
        if 'set_max_delay' in command and any(p in command for p in PINS):
            raise ValueError('Overridden pin max delay needs independent manual proof')
    for pin in PINS:
        for flag, value in (('max', 80.0-envelope_ns), ('min', 0.0)):
            matches = []
            pattern = (r'^set_output_delay\s+-clock\s+clk_audio\s+(' + NUMBER +
                       r')\s+-' + flag + r'\s+\[get_ports\s+\{' + pin + r'\}\]\s*$')
            for command in commands:
                match = re.match(pattern, command)
                if match:
                    matches.append(float(match.group(1)))
            if len(matches) != 1 or abs(matches[0]-value) > .001:
                raise ValueError(f'{pin}: require exactly one active {flag} output delay {value}ns')
    result = check_bounds(dict.fromkeys(PINS, [envelope_ns]), dict.fromkeys(PINS, [0.0]),
                          margin_ns, envelope_ns)
    result['bound_vs_measured'] = ('Certified conservative 0..envelope bounds from active '
                                   'constraints and complete zero-violation STA; NOT measured paths')
    result['reset_sync_exception_review_acknowledged'] = reviewed_reset_sync_exceptions
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--setup-report')
    ap.add_argument('--hold-report')
    ap.add_argument('--certified-report', help='full STA with clean summaries and active bounds; NOT measured paths')
    ap.add_argument('--board-jitter-budget-ns', type=float, default=10.0)
    ap.add_argument('--envelope-ns', type=float, default=40.0)
    ap.add_argument('--reviewed-reset-sync-exceptions', action='store_true',
                    help='explicit acknowledgement of independently reviewed dedicated async CLEAR exceptions')
    a = ap.parse_args()
    if a.certified_report:
        if a.setup_report or a.hold_report:
            ap.error('Do not mix certified bounds and measured-path modes')
        files = [Path(a.certified_report)]
        result = certified_envelope(files[0].read_text(), a.board_jitter_budget_ns, a.envelope_ns,
                                    a.reviewed_reset_sync_exceptions)
    else:
        if not a.setup_report or not a.hold_report:
            ap.error('Require setup+hold reports or a certified full report')
        files = [Path(a.setup_report), Path(a.hold_report)]
        maximum, minimum = [parse_report(p.read_text(), kind) for p, kind in
                            zip(files, ('Setup', 'Hold'))]
        result = check_bounds(maximum, minimum, a.board_jitter_budget_ns, a.envelope_ns)
        result['bound_vs_measured'] = 'Measured report extrema: Slow/setup max and Fast/hold min'
    result['evidence_sha256'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    result['scope'] = ('PIN-ONLY conditional proof for audio80ns/BCLK320ns; NOT full-build '
                       'acceptance. Verify report completeness/PVT and RTL edge relation independently.')
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print('REJECT pin proof:', error, file=sys.stderr)
        raise SystemExit(1)
