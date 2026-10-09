"""Parent STA screening for the isolated diagnostic tone, not the song core.

Checks the actual audio clock, explicit 400ps setup reserve, narrowly scoped
reset exceptions, and both-corner dedicated pin paths. Not full PVT sign-off.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

from review_gowin_reports import sta_table_violations
from review_i2s_pin_delays import check_bounds, parse_report


def review(base):
    base = Path(base)
    pnr = base / 'build/diagnostic_tone/impl/pnr'
    report = pnr / 'diagnostic_tone.tr'
    raw = report.read_text()
    console = (base / 'flow.log').read_text(errors='replace')
    assert re.search(r'^PNR_DONE\s*$', console, re.M), 'Missing completed P&R marker'
    bad = [line for line in console.splitlines() if re.search(
        r'\bERROR\b|invalid command name|syntax error|Cannot open file|EX3988|black.?box|empty collection|'
        r'(?:clock|pin).*not found|ignored.*constraint', line, re.I)]
    assert not bad, bad
    assert not sta_table_violations(raw), sta_table_violations(raw)
    for kind in ('Setup', 'Hold'):
        match = re.search(r'<Numbers of ' + kind + r' Violated Endpoints>:\s*(\d+)', raw)
        assert match and int(match[1]) == 0, kind + ' violated endpoint summary'
    for clock, period in (('clk_50m', 20), ('clk_audio', 80)):
        match = re.search(r'^\s*\d+\s+' + clock + r'\s+(?:Base|Generated)\s+(\d+\.\d+)', raw, re.M)
        assert match and float(match[1]) == period, clock
    assert not re.search(r'^\s*\d+\s+clk_core\s', raw, re.M), 'Unexpected core clock'
    inactive = re.findall(r'^\s*TC_\w+\s+(?:Ignored|Inactive)\s+(.+)$', raw, re.M)
    assert not inactive, inactive
    commands = [s.strip() for s in re.findall(r'^\s*TC_\w+\s+Actived\s+(.+)$', raw, re.M)]
    assert commands, 'No active constraint evidence'
    uncertainty = [s for s in commands if re.search(r'\bset_clock_uncertainty\b', s)]
    assert len(uncertainty) == 1 and re.fullmatch(
        r'set_clock_uncertainty\s+-setup\s+0\.400\s+-from\s+\[get_clocks\s+\{clk_audio\}\]'
        r'\s+-to\s+\[get_clocks\s+\{clk_audio\}\]',
        uncertainty[0]), uncertainty
    cuts = []
    for command in commands:
        assert not re.search(r'set_clock_latency|set_multicycle_path|set_min_delay', command), command
        if 'set_false_path' in command:
            match = re.fullmatch(r'set_false_path -hold -to \[get_pins \{(rst_sync_[012]_s\d+/CLEAR)\}\]', command)
            assert match, 'Unexpected timing cut: ' + command
            cuts.append(match[1])
    assert len(cuts) == 3 and len(set(cuts)) == 3, cuts
    for pin in ('amp_bclk', 'amp_lrc', 'amp_din'):
        for kind, number in (('max', '40.000'), ('min', '0.000')):
            expected = r'set_output_delay -clock clk_audio\s+' + re.escape(number) + \
                r' -' + kind + r' \[get_ports \{' + pin + r'\}\]'
            assert sum(bool(re.fullmatch(expected, s)) for s in commands) == 1, expected
    assert any(re.search(r'^set_max_delay .*100\.000 .*amp_sd', s) for s in commands)
    pin_html = (pnr / 'diagnostic_tone.pin.html').read_text()
    pin_rows = {}
    for row in re.findall(r'<tr>(.*?)</tr>', pin_html, re.S):
        cells = re.findall(r'<td[^>]*>(.*?)</td>', row, re.S)
        if cells and cells[0] in ('clk', 'amp_bclk', 'amp_lrc', 'amp_din', 'amp_sd'):
            pin_rows[cells[0]] = cells
    expected_pins = {'clk': 'P16/3', 'amp_bclk': 'C21/5', 'amp_lrc': 'B20/5',
                     'amp_din': 'B19/5', 'amp_sd': 'A17/5'}
    assert set(pin_rows) == set(expected_pins), pin_rows
    for port, pin in expected_pins.items():
        cells = pin_rows[port]
        assert cells[2] == pin and cells[7] == 'LVCMOS33' and cells[16] == '3.3', (port, cells)
        if port != 'clk':
            assert cells[4] == 'out' and cells[8] == '8', (port, cells)
    assert pin_rows['amp_sd'][9] == 'DOWN'

    # Use original complete reports with their actual Slow/Fast metadata. SDC
    # expands path reporting only; analysis summaries still cover the full build.
    path_sets = [parse_report(raw, kind) for kind in ('Setup', 'Hold')]
    pin_result = check_bounds(path_sets[0], path_sets[1], margin_ns=10)
    image = pnr / 'diagnostic_tone.fs'
    assert image.is_file() and image.stat().st_size > 1000
    result = dict(status='DIAGNOSTIC STA/PIN SCREEN PASS',
                  image=str(image), bytes=image.stat().st_size,
                  image_sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
                  report_sha256=hashlib.sha256(report.read_bytes()).hexdigest(),
                  setup_uncertainty_reserve_ns=0.4,
                  implemented_pin_mapping=expected_pins,
                  reset_sync_hold_exceptions=cuts,
                  pin_extrema=pin_result,
                  limits='Isolated tone only; conditional 10ns board/jitter budget, '
                         'not measured on user board or complete physical PLL/PVT sign-off; '
                         'does not validate or alter the frozen song/modal core.')
    (base / 'diagnostic_gate.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('evidence_dir')
    args = ap.parse_args()
    print(json.dumps(review(args.evidence_dir), indent=2))


if __name__ == '__main__':
    main()
