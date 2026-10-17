"""Read-only review of the production song's precise stage-one hold exceptions.

Not MTBF, bit-skew/PVT or whole-board sign-off. Verifies reviewed register chains,
exception scope, retained max_delay commands and their real STA path witnesses.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


PREFIX = 'u_top/u_audio/u_core/u_transport/'
TARGETS = {PREFIX + f'u_tx_fifo/{kind}_s1_{bit}_s0/D'
           for kind in ('wgray', 'rgray') for bit in range(5)} | {PREFIX + 'tgl_s1_s0/D'}
RESET_TARGETS = {'u_top/u_clock_reset/' + f'crst_sync_{bit}_s0/CLEAR' for bit in range(3)} | {
    'u_top/u_audio/u_core/' + f'crst_sync_{bit}_s0/CLEAR' for bit in range(2)} | {
    PREFIX + f'arst_sync_{bit}_s0/CLEAR' for bit in range(2)}
BOUNDS = {'set_max_delay -from [get_clocks {clk_core}] 10.000 -to [get_clocks {clk_audio}]',
          'set_max_delay -from [get_clocks {clk_audio}] 10.000 -to [get_clocks {clk_core}]'}


def module(text, name):
    m = re.search(r'\bmodule\s+' + re.escape(name) + r'\s*\(.*?\bendmodule\b', text, re.S)
    assert m, f'Missing reviewed module {name}'
    return m.group()


def registers(text):
    result = {}
    for m in re.finditer(r'\b(DFF\w*)\s+(\w+)\s*\((.*?)\);', text, re.S):
        ports = dict(re.findall(r'\.(\w+)\(\s*([^()]+?)\s*\)', m.group(3)))
        assert m.group(2) not in result, 'Repeated register instance'
        result[m.group(2)] = ports
    return result


def review(netlist, sdc, timing):
    fifo = registers(module(netlist, 'audio_async_fifo'))
    transport = registers(module(netlist, 'audio_transport'))
    facts = []
    for kind, src_clock, dst_clock in (('wgray', 'clk_core', 'clk_audio'),
                                       ('rgray', 'clk_audio', 'clk_core')):
        for bit in range(5):
            first, second = fifo[f'{kind}_s1_{bit}_s0'], fifo[f'{kind}_s2_{bit}_s0']
            src = kind if bit < 4 else kind.replace('gray', 'bin')
            q = f'{src}[{bit}]'
            sources = [r for r in fifo.values() if r.get('Q') == q]
            assert len(sources) == 1 and sources[0]['CLK'] == src_clock, (kind, bit, sources)
            assert first['D'] == q and first['CLK'] == dst_clock
            assert first['Q'] == f'{kind}_s1[{bit}]'
            assert second['D'] == first['Q'] and second['CLK'] == dst_clock
            facts.append(dict(pin=PREFIX + f'u_tx_fifo/{kind}_s1_{bit}_s0/D',
                              registered_source=q, source_clock=src_clock, capture_clock=dst_clock))
    first = transport['tgl_s1_s0']
    assert first['D'] == 'tick_tgl' and first['CLK'] == 'clk_core'
    tick_sources = [r for r in transport.values() if r.get('Q') == 'tick_tgl']
    assert len(tick_sources) == 1 and tick_sources[0]['CLK'] == 'clk_audio'
    assert transport['tgl_s2_s0']['D'] == first['Q']
    assert transport['tgl_s2_s0']['CLK'] == 'clk_core'
    facts.append(dict(pin=PREFIX + 'tgl_s1_s0/D', registered_source='tick_tgl',
                      source_clock='clk_audio', capture_clock='clk_core'))

    commands = [line.strip() for line in sdc.splitlines()
                if line.strip() and not line.lstrip().startswith('#')]
    assert not any('set_clock_groups' in c or 'set_clock_latency' in c for c in commands)
    assert BOUNDS <= set(commands), 'Gray max_delay bounds removed or changed'
    d_pins = set()
    for c in commands:
        if not c.startswith('set_false_path'):
            continue
        m = re.fullmatch(r'set_false_path -hold -to \[get_pins \{([^}]+)\}\]', c)
        assert m, f'Unreviewed exception syntax or setup cut: {c}'
        pin = m.group(1)
        assert pin in RESET_TARGETS | TARGETS, f'Unreviewed cut endpoint: {pin}'
        if pin.endswith('/D'):
            assert pin not in d_pins, f'Duplicate endpoint {pin}'
            d_pins.add(pin)
    assert d_pins == TARGETS, ('Incomplete first-stage set', TARGETS-d_pins)

    active = {m.strip() for m in re.findall(r'^\s*TC_\w+\s+Actived\s+(.+)$', timing, re.M)}
    assert not re.search(r'^\s*TC_\w+\s+(?:Inactive|Ignored)\b', timing, re.M)
    assert set(commands) <= active, ('Commands not active', set(commands)-active)
    for kind in ('Setup', 'Hold'):
        m = re.search(r'<Numbers of ' + kind + r' Violated Endpoints>:\s*(\d+)', timing)
        assert m and int(m.group(1)) == 0, f'{kind} remains failing'
    setup = re.search(r'^3\.7\.1 Setup Analysis Report(.*?)^3\.7\.2 ', timing, re.S | re.M)
    assert setup, 'Missing real exception setup path section'
    witnesses = []
    for bound in BOUNDS:
        # A path under each constraint, not just an Actived label.
        sections = re.findall(r'Timing Path Constraint\[\d+\]:\s*' + re.escape(bound) +
                              r'(.*?)(?=Timing Path Constraint\[|\Z)', setup.group(1), re.S)
        assert sections, f'No setup path witness for {bound}'
        m = re.search(r'From\s*:\s*(\S+).*?To\s*:\s*(\S+)', ''.join(sections), re.S)
        assert m, f'No real source/destination for {bound}'
        witnesses.append(dict(constraint=bound, source=m.group(1), destination=m.group(2)))
    return dict(stage_one_hold_pins=facts, max_delay_setup_witnesses=witnesses,
                setup_hold_counters=[0, 0], scope='CDC structure/model subset only; MPW/PVT not signed off')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--netlist', required=True, type=Path)
    p.add_argument('--sdc', required=True, type=Path)
    p.add_argument('--timing', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    result = review(a.netlist.read_text(), a.sdc.read_text(), a.timing.read_text())
    result['sha256'] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in (a.netlist, a.sdc, a.timing)}
    a.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print('Precise CDC model subset verified; MPW/PVT/board sign-off still separate')


if __name__ == '__main__':
    main()
