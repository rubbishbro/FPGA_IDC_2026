"""Read-only parent screening of Gowin reports before accepting a build.

This is a necessary structural/STA gate, NOT an external-I2S/CDC sign-off or an
assurance that the physical part is correct. It rejects empty-ROM and failing
setup/hold builds even when Gowin produces a bitstream.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def sta_table_violations(raw):
    """Check reset recovery/removal and pulse widths as well as summary counters.

    Some Gowin reports include removal violations in the hold counter but keep
    the actual Hold Paths Table positive. Never mislabel those as FIFO data hold.
    """
    errors = []
    headings = list(re.finditer(r'^\s*\d+(?:\.\d+)+\s+(.+)\s*$', raw, re.M))
    for i, heading in enumerate(headings):
        if heading.group(1).strip() == 'Minimum Pulse Width Table':
            end = headings[i+1].start() if i+1 < len(headings) else len(raw)
            rows = re.findall(r'^\s*(\d+)\s+(-?\d+(?:\.\d+)?)\s+'
                              r'(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(.+)$',
                              raw[heading.end():end], re.M)
            for number, slack, actual, required, target in rows:
                if float(slack) < 0:
                    errors.append(f'STA minimum pulse width path {number}: slack {slack}ns '
                                  f'(actual {actual}ns < required {required}ns; {target.strip()})')
            continue
        kind = re.fullmatch(r'(Setup|Hold|Recovery|Removal) Paths Table', heading.group(1).strip())
        if not kind:
            continue
        end = headings[i+1].start() if i+1 < len(headings) else len(raw)
        table = raw[heading.end():end]
        rows = re.findall(r'^\s*(\d+)\s+(-?\d+(?:\.\d+)?)\s+(\S+)\s+(\S+)', table, re.M)
        for number, slack, source, target in rows:
            if float(slack) < 0:
                errors.append(f'STA {kind.group(1).lower()} table path {number}: '
                              f'slack {slack}ns ({source} -> {target})')
    return errors


def review(directory, require_body=False):
    directory = Path(directory)
    errors = []
    required = ('synthesis.log', 'synthesis_resources.xml', 'pnr_report.txt',
                'timing_report.tr')
    for name in required:
        path = directory / name
        if not path.is_file() or not path.stat().st_size:
            errors.append('Missing/empty evidence: ' + name)
    def text(name):
        path = directory / name
        return path.read_text(errors='replace') if path.is_file() else ''
    syn, pnrlog = text('synthesis.log'), text('pnr.log')
    if not pnrlog and not text('flow.log'):
        errors.append('Missing P&R diagnostics: require nonempty pnr.log or flow.log')
    # The Tcl console may contain P&R errors without creating a pnr.log at all.
    diagnostics = set()
    for line in (syn + '\n' + pnrlog + '\n' + text('flow.log')).splitlines():
        if re.search(r'\bERROR\b|Cannot open file|EX3988|black.?box|empty collection|'
                     r'(?:clock|pin).*not found', line, re.I):
            diagnostic = line.strip()
            if diagnostic not in diagnostics:
                diagnostics.add(diagnostic)
                errors.append('Tool diagnostic: ' + diagnostic)
    xml = directory / 'synthesis_resources.xml'
    try:
        root = ET.parse(xml).getroot() if xml.is_file() else None
        lanes = [e for e in root.iter()
                 if re.search(r'g_lane\[[0-3]\]\.u_lane', e.attrib.get('name', ''))] if root is not None else []
        for lane in range(4):
            matches = [e for e in lanes if f'g_lane[{lane}].u_lane' in e.attrib['name']]
            if not matches:
                errors.append(f'Missing implemented modal lane {lane} in resource hierarchy')
            else:
                element = matches[0]
                bsram = int(element.attrib.get('T_Bsram', '0').split('(')[0])
                mult = int(element.attrib.get('T_MULT27X36', '0').split('(')[0])
                if bsram < 1 or mult < 1:
                    errors.append(f'Modal lane {lane} lacks real RAM/multiplier mapping '
                                   f'(BSRAM={bsram}, MULT27X36={mult})')
        if require_body:
            bodies = [e for e in root.iter() if e.attrib.get('name') == 'g_body.u_body'] if root is not None else []
            if not bodies:
                errors.append('Missing implemented shared body; prebody netlist is not a body delivery')
            else:
                body = bodies[0]
                registers = int(body.attrib.get('T_Register', '0').split('(')[0])
                multipliers = int(body.attrib.get('T_MULT27X36', '0').split('(')[0])
                # Necessary resource sanity, not a proof of the coefficient image
                # or every output bit. Mapping may still need manual netlist review.
                if registers < 1000 or multipliers < 1:
                    errors.append('Implausible shared-body mapping: '
                                  f'{registers} FF/{multipliers} MULT27X36')
    except ET.ParseError as exc:
        errors.append('Invalid resource XML: ' + str(exc))
    except ValueError as exc:
        errors.append('Invalid resource count: ' + str(exc))
    report = text('pnr_report.txt')
    for resource, minimum in (('DSP', 4), ('BSRAM', 1)) if report else ():
        # Zero-used resources are omitted in the observed Gowin PnR report.
        match = re.search(r'^\s*' + resource + r'[^|\n]*\|\s*(\d+)', report, re.M | re.I)
        count = int(match.group(1)) if match else 0
        if count < minimum:
            errors.append(f'Implausible {resource} count {count}; expected >= {minimum} '
                          'for real coefficient/state/modal arithmetic mapping')
    timing = text('timing_report.tr')
    if timing:
        errors.extend(sta_table_violations(timing))
        # A nominal source-latency override can replace real device/PVT clock
        # extremes while leaving every path and endpoint in the report. Clean
        # counters alone then do not certify the original physical timing model.
        # This automated gate has no reviewed replacement clock model to apply.
        for command in re.findall(r'^\s*TC_\w+\s+Actived\s+(.+)$', timing, re.M):
            if re.search(r'\bset_clock_latency\b', command):
                errors.append('Clock-latency override requires independent physical-model proof: '
                              + command.strip())
        for command in re.findall(r'^\s*TC_\w+\s+(?:Ignored|Inactive)\s+(.+)$', timing, re.M):
            errors.append('Ignored/inactive timing constraint: ' + command.strip())
        for kind in ('Setup', 'Hold'):
            match = re.search(r'<Numbers of ' + kind + r' Violated Endpoints>:\s*(\d+)', timing)
            if not match:
                errors.append('Missing STA violated-endpoint summary for ' + kind)
            elif int(match.group(1)):
                errors.append(f'STA {kind.lower()} failed: {match.group(1)} violated endpoints')
        for name, period in (('clk_50m', 20.0), ('clk_core', 10.0), ('clk_audio', 80.0)):
            match = re.search(r'^\s*\d+\s+' + name + r'\s+(?:Base|Generated)\s+(\d+(?:\.\d+)?)\s',
                              timing, re.M)
            if not match:
                errors.append('Missing implemented STA clock: ' + name)
            elif abs(float(match.group(1)) - period) > 0.001:
                errors.append(f'Wrong STA clock period: {name}={match.group(1)}ns; '
                              f'expected diagnostic-build {period}ns')
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('report_dir')
    ap.add_argument('--require-body', action='store_true',
                    help='reject a prebody netlist when reviewing the body-enabled delivery')
    args = ap.parse_args()
    errors = review(args.report_dir, require_body=args.require_body)
    if errors:
        for error in errors:
            print('REJECT:', error, file=sys.stderr)
        print('Build NOT accepted. Do not program this artifact.', file=sys.stderr)
        return 1
    print('Structural/STA report gate passed. Still requires independent external '
          'I2S setup/hold, CDC exceptions/Gray bounds, unconstrained paths, ROM content/'
          'netlist function and physical-part review before programming.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
