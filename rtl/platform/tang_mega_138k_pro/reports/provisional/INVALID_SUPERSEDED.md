# INVALID / DO NOT USE

The reports in this directory came from a build where `$readmemh` silently
failed to load the ROMs (WARN EX3988 in `synthesis.log` lines 49-50).  The engine
array constant-folded away (u_engine 124 FF / 222 LUT, only g_lane0 1 FF, no DSP
or BSRAM in P&R), so the reported 776-logic resource count and the "pass" timing
are **not valid evidence for this design**.  The bitstream from that run is
**invalid/disallowed**.

Superseded by `../attempt2_romfixed_syn_ok_pnr_blocked/`.  Kept only for the
record.  Not deleted (unknown user content preserved).
