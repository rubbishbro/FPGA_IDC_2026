"""Read-only Matplotlib placement view of an existing Gowin timing report.

Plots only coordinates printed in the STA report. Connections are straight-line
schematics, NOT routed-wire geometry. Encrypted .p/.pr files are not decoded.
Missing fanout coordinates remain missing; no die extent or congestion is guessed.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager


LOCATION = re.compile(r"\b(R(\d+)C(\d+)(?:\[\d+\])?(?:\[[AB]\])?)\s+(\S+)\s*$")
PRIMITIVE = re.compile(r"^\s*(\w+)\s+(\w+)\s*\((.*?)\);", re.M | re.S)
PREFIX = "u_top/u_audio/u_core/u_engine/u_bank/g_lane[3].u_lane/"
EXPECTED = ["pend_local_5_s0", "pd_cl_2_s2", "pd_cl_2_s1", "sv_pend_2_s",
            "n1634_s6", "state_valid_279_s4", "state_valid_279_s1"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def positions(text):
    found = {}
    for number, line in enumerate(text.splitlines(), 1):
        m = LOCATION.search(line)
        if not m:
            continue
        node = m[4]
        if "/" not in node:
            continue
        instance = node.rsplit("/", 1)[0]
        item = dict(location=m[1], row=int(m[2]), column=int(m[3]))
        found.setdefault(instance, {})[m[1]] = item
    # A primitive can have multiple reported internal locations (e.g. DSP).
    # Do not average them or silently select one for the context plot.
    resolved = {name: next(iter(entries.values())) for name, entries in found.items()
                if len(entries) == 1}
    ambiguous = {name: list(entries.values()) for name, entries in found.items()
                 if len(entries) != 1}
    return resolved, ambiguous


def backannotated_positions(text, report_positions, anchors):
    """Read fixed CFU sites from an independently exported placement CST.

    Region constraints are NOT placement coordinates. All seven critical anchors
    must match the existing STA report before any exported positions are used.
    """
    fixed = {}
    pattern = re.compile(
        r'^\s*INS_LOC\s+"([^"\n]+)"\s+(R(\d+)C(\d+)\[\d+\]\[[AB]\])'
        r'\s*(?:exclusive\s*)?;\s*(?://.*)?$')
    for number, line in enumerate(text.splitlines(), 1):
        m = pattern.match(line)
        if not m:
            continue
        name = m[1]
        item = dict(location=m[2], row=int(m[3]), column=int(m[4]))
        if name in fixed and fixed[name] != item:
            raise ValueError(f"conflicting exported placement for {name}, CST line {number}")
        fixed[name] = item
    for name in anchors:
        if name not in fixed:
            raise ValueError(f"export missing exact critical primitive name: {name}")
        if fixed[name] != report_positions[name]:
            raise ValueError(f"export does not match v5 STA anchor: {name}")
    for name in set(fixed) & set(report_positions):
        if fixed[name] != report_positions[name]:
            raise ValueError(f"export/report coordinate mismatch: {name}")
    return fixed


def critical_path(text):
    section = text.split("3.3.1 Setup Analysis Report\n", 1)[1]
    first = section.split("Data Required Path:", 1)[0]
    assert re.search(r"Slack\s*:\s*0\.001\b", first)
    nodes, edges, previous = {}, [], None
    for line in first.splitlines():
        loc = LOCATION.search(line)
        if not loc:
            continue
        fields = line.split()
        delay, kind = float(fields[1]), fields[2]
        node = loc[4]
        if not node.startswith(PREFIX):
            continue
        primitive, pin = node.rsplit("/", 1)
        short = primitive.removeprefix(PREFIX)
        if short not in EXPECTED:
            raise ValueError(f"unexpected first critical path primitive: {short}")
        item = dict(instance=primitive, name=short, location=loc[1], row=int(loc[2]),
                    column=int(loc[3]))
        assert primitive not in nodes or nodes[primitive] == item
        nodes[primitive] = item
        if kind == "tNET" and previous:
            edges.append(dict(source=previous["instance"], target=primitive,
                              source_pin=previous["pin"], target_pin=pin,
                              source_fanout=previous["fanout"], delay_ns=delay,
                              evidence_line=line.strip()))
        if kind in ("tC2Q", "tINS"):
            previous = dict(instance=primitive, pin=pin, fanout=int(fields[4]))
    assert set(nodes) == {PREFIX + name for name in EXPECTED}
    assert len(edges) == 6
    long_edge = next(e for e in edges if e["source"] == PREFIX + "n1634_s6")
    assert long_edge["delay_ns"] == 3.979 and long_edge["source_fanout"] == 96
    assert nodes[long_edge["source"]]["location"] == "R63C142[1][B]"
    assert nodes[long_edge["target"]]["location"] == "R70C151[1][B]"
    return list(nodes.values()), edges


def fanout(netlist, known):
    # Verify the production instance binds to the selected synthesized module.
    assert re.search(r"poly_modal_lane_2\s+\\g_lane\[3\]\.u_lane\s*\(", netlist)
    start = netlist.index("module poly_modal_lane_2 (")
    body = netlist[start:netlist.index("endmodule", start)]
    matches = list(PRIMITIVE.finditer(body))
    driver = next(m for m in matches if m[2] == "n1634_s6")
    driver_pins = dict(re.findall(r"\.(\w+)\(([^)]*)\)", driver[3]))
    wire = driver_pins["F"]
    loads = []
    for match in matches:
        pins = dict(re.findall(r"\.(\w+)\(([^)]*)\)", match[3]))
        for pin, signal in pins.items():
            if signal != wire or pin in ("F", "Q", "SUM", "COUT"):
                continue
            instance = PREFIX + match[2]
            loads.append(dict(instance=instance, primitive_type=match[1], pin=pin,
                              position=known.get(instance)))
    assert len(loads) == 96, f"fanout changed: {len(loads)}"
    assert any(l["instance"] == PREFIX + "state_valid_279_s4" and l["pin"] == "I1"
               for l in loads)
    return wire, loads


def make_plot(nodes, edges, known, loads, output):
    fonts = {f.name for f in font_manager.fontManager.ttflist}
    if "Noto Sans CJK SC" in fonts:
        plt.rcParams["font.family"] = "Noto Sans CJK SC"
    plt.rcParams.update({"axes.unicode_minus": False, "font.size": 10})
    fig = plt.figure(figsize=(17, 10), layout="constrained")
    grid = fig.add_gridspec(2, 2, width_ratios=[1.65, 1], height_ratios=[1, 1])
    ax = fig.add_subplot(grid[:, 0])
    context = fig.add_subplot(grid[0, 1])
    bars = fig.add_subplot(grid[1, 1])
    by_name = {n["instance"]: n for n in nodes}
    labels = {PREFIX + n: chr(65 + i) for i, n in enumerate(EXPECTED)}
    driver = by_name[PREFIX + "n1634_s6"]
    known_loads = [l for l in loads if l["position"] is not None]
    lane_points = [p for name, p in known.items() if name.startswith(PREFIX)]
    ax.scatter([p["column"] for p in lane_points], [p["row"] for p in lane_points],
               c="#c8ced6", s=38, label="lane3：其余已知位置", zorder=1)
    for load in known_loads:
        p = load["position"]
        ax.plot([driver["column"], p["column"]], [driver["row"], p["row"]],
                color="#d59a63", linestyle=":", lw=1.4, zorder=2)
        ax.scatter(p["column"], p["row"], marker="s", facecolor="none",
                   edgecolor="#ad661e", s=220, zorder=4)
    for edge in edges:
        a, b = by_name[edge["source"]], by_name[edge["target"]]
        heavy = edge["delay_ns"] == 3.979
        ax.annotate("", xy=(b["column"], b["row"]), xytext=(a["column"], a["row"]),
                    arrowprops=dict(arrowstyle="->", color="#dc3545" if heavy else "#3478ad",
                                    lw=3 if heavy else 1.6), zorder=3)
        if heavy:
            ax.annotate("E → F：3.979 ns\n驱动网共96负载", xy=(146.5, 66.5),
                        xytext=(25, 28), textcoords="offset points", color="#b52332",
                        fontsize=12, weight="bold", bbox=dict(fc="white", ec="#dc3545", alpha=.95))
    grouped = {}
    for n in nodes:
        grouped.setdefault((n["column"], n["row"]), []).append(n)
    offsets = {"A/B": (-90, 12), "C": (-85, -28), "D": (20, -8),
               "E": (-25, 38), "F": (15, -8), "G": (-55, -38)}
    for (column, row), same_cell in grouped.items():
        tag = "/".join(labels[n["instance"]] for n in same_cell)
        color = "#dc3545" if tag in ("E", "F") else "#165780"
        ax.scatter(column, row, color=color, s=95, zorder=5)
        ax.annotate(f"{tag}  R{row}C{column}", xy=(column, row),
                    xytext=offsets[tag], textcoords="offset points", fontsize=11,
                    arrowprops=dict(arrowstyle="-", color="#667"),
                    bbox=dict(fc="white", ec="#ddd", alpha=.95), zorder=6)
    extra = next((l for l in known_loads if l["instance"] != PREFIX + "state_valid_279_s4"), None)
    if extra:
        p = extra["position"]
        ax.annotate("另一个已知负载\n" + extra["instance"].removeprefix(PREFIX),
                    xy=(p["column"], p["row"]), xytext=(-100, 25), textcoords="offset points",
                    arrowprops=dict(arrowstyle="-", color="#ad661e"), fontsize=9,
                    bbox=dict(fc="white", ec="#d59a63"))
    ax.set(xlim=(128, 159), ylim=(80, 54), xlabel="器件网格列 C", ylabel="器件网格行 R（向下增加）",
           title="关键路径局部位置：实点为STA放置坐标，箭头不是实际走线")
    ax.set_aspect("equal", adjustable="box")
    ax.grid(alpha=.22)
    explanation = "\n".join(f"{labels[n['instance']]}：{n['name']}  {n['location']}" for n in nodes)
    ax.text(.02, .02, explanation + "\n\nA/B同一R/C、不同CLS子位置；图中重合，不挪动坐标。",
            transform=ax.transAxes, va="bottom", fontsize=9,
            bbox=dict(fc="white", ec="#ccc", alpha=.97))
    context.scatter([p["column"] for p in known.values()], [p["row"] for p in known.values()],
                    s=12, c="#c8ced6", label="可取得固定坐标的实例")
    context.scatter([p["column"] for p in lane_points], [p["row"] for p in lane_points],
                    s=30, c="#3478ad", label="lane3已知实例")
    context.scatter(driver["column"], driver["row"], s=85, marker="*", c="#dc3545", label="关键译码驱动")
    context.invert_yaxis()
    context.set(xlabel="列 C", ylabel="行 R", title="可取得坐标的背景对照（非资源/拥塞图）")
    context.grid(alpha=.2)
    context.legend(fontsize=8, loc="best")
    names = [labels[e["source"]] + " → " + labels[e["target"]] for e in edges]
    values = [e["delay_ns"] for e in edges]
    bars.barh(names, values, color=["#dc3545" if v == 3.979 else "#3478ad" for v in values])
    bars.invert_yaxis()
    for i, value in enumerate(values):
        bars.text(value + .035, i, f"{value:.3f}", va="center", fontsize=10)
    bars.set(xlim=(0, 4.7), xlabel="报告的数据走线延迟 tNET / ns",
             title="6段数据连接；总走线6.740 ns\nLUT/ALU合计2.555 ns，Clock→Q为0.344 ns")
    bars.grid(axis="x", alpha=.2)
    fig.suptitle("v5实际P&R：100 MHz最坏Setup路径物理位置对照", fontsize=18, weight="bold")
    coverage = ("已取得全部96个负载的坐标。" if len(known_loads) == 96 else
                f"仅定位96个负载中的{len(known_loads)}个；其余缺坐标。")
    fig.supxlabel(coverage + "网格距离不等于线路长度，不能据图证明绕路或拥塞。", fontsize=11)
    for extension in ("png", "svg", "pdf"):
        fig.savefig(output / f"critical_placement.{extension}", dpi=180)
    plt.close(fig)


def make_fanout_plot(driver, loads, output):
    """Only generate a distribution plot when ALL 96 actual loads are located."""
    assert len(loads) == 96 and all(load["position"] is not None for load in loads)
    xs = [l["position"]["column"] for l in loads]
    ys = [l["position"]["row"] for l in loads]
    distances = [l["euclidean_grid_distance"] for l in loads]
    target = next(l for l in loads if l["instance"] == PREFIX + "state_valid_279_s4")
    key = target["position"]
    mean_x, mean_y = statistics.mean(xs), statistics.mean(ys)
    fig, (ax, histogram) = plt.subplots(1, 2, figsize=(16, 8),
                                       gridspec_kw={"width_ratios": [1.5, 1]}, layout="constrained")
    for x, y in zip(xs, ys):
        ax.plot([driver["column"], x], [driver["row"], y], color="#3478ad", alpha=.13, lw=.8)
    ax.scatter(xs, ys, c="#3478ad", s=38, alpha=.75, label="96个真实输入负载（同R/C可能重合）")
    ax.scatter(driver["column"], driver["row"], marker="*", s=230, c="#222", zorder=5,
               label="n1634_s6：驱动点")
    ax.scatter(key["column"], key["row"], marker="s", s=130, facecolors="none",
               edgecolors="#dc3545", lw=2.3, zorder=6, label="3.979ns关键分支接收点")
    ax.plot([driver["column"], key["column"]], [driver["row"], key["row"]],
            c="#dc3545", lw=2.2, zorder=4)
    ax.scatter(mean_x, mean_y, marker="x", c="#b47900", s=130, lw=2,
               label="负载几何重心（不是最佳电气位置）")
    ax.set_aspect("equal", adjustable="datalim")
    ax.invert_yaxis()
    ax.set(xlabel="器件网格列 C", ylabel="器件网格行 R", title="完整96负载物理分布；连接线非真实路由")
    ax.grid(alpha=.2)
    ax.legend(fontsize=9, loc="best")
    histogram.hist(distances, bins=12, color="#3478ad", edgecolor="white")
    histogram.axvline(target["euclidean_grid_distance"], c="#dc3545", lw=2,
                      label="关键接收点距离")
    histogram.set(xlabel="欧几里得网格距离 √(ΔR²+ΔC²)", ylabel="输入负载数量",
                  title="96个负载的距离分布（不是延迟分布）")
    histogram.legend()
    histogram.grid(axis="y", alpha=.2)
    p95 = statistics.quantiles(distances, n=100, method="inclusive")[94]
    rank = 1 + sum(d < target["euclidean_grid_distance"] - 1e-12 for d in distances)
    summary = (f"负载=96/96；距离 min={min(distances):.2f}，median={statistics.median(distances):.2f}，"
               f"P95={p95:.2f}，max={max(distances):.2f}；关键接收点={target['euclidean_grid_distance']:.2f}，"
               f"距离升序排名={rank}/96。")
    fig.suptitle("v5原始布局：共享译码网的完整扇出位置与欧几里得距离", fontsize=17, weight="bold")
    fig.supxlabel(summary + "\n网格距离不等于物理微米、真实线路长度或电气延迟；未重新布局。", fontsize=10)
    for extension in ("png", "svg", "pdf"):
        fig.savefig(output / f"fanout_placement.{extension}", dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--netlist", type=Path, required=True)
    parser.add_argument("--placement-cst", type=Path,
                        help="actual v5 FloorPlanner back-annotation export; anchors and all 96 loads required")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    text = args.report.read_text()
    known, ambiguous = positions(text)
    nodes, edges = critical_path(text)
    by_name = {n["instance"]: n for n in nodes}
    for edge in edges:
        a, b = by_name[edge["source"]], by_name[edge["target"]]
        edge["row_difference"] = abs(a["row"] - b["row"])
        edge["column_difference"] = abs(a["column"] - b["column"])
        edge["manhattan_grid_distance"] = edge["row_difference"] + edge["column_difference"]
    coordinate_source = dict(type="partial_original_STA_report")
    exported = {}
    if args.placement_cst:
        exported = backannotated_positions(args.placement_cst.read_text(), known,
                                          [n["instance"] for n in nodes])
        coordinate_source = dict(type="user_supplied_back_annotation_export",
                                 path=str(args.placement_cst.resolve()), sha256=sha(args.placement_cst),
                                 fixed_CFU_instances=len(exported))
        known.update(exported)
    wire, loads = fanout(args.netlist.read_text(), known)
    source, target = nodes[4], nodes[5]
    for load in loads:
        p = load["position"]
        load["euclidean_grid_distance"] = (math.hypot(p["row"] - source["row"],
                                                      p["column"] - source["column"])
                                               if p is not None else None)
    if args.placement_cst and not all(l["position"] is not None for l in loads):
        missing = [l["instance"] for l in loads if l["position"] is None]
        raise ValueError(f"export does not locate all 96 loads; missing {len(missing)}: {missing}")
    metrics = dict(row_difference=abs(source["row"] - target["row"]),
                   column_difference=abs(source["column"] - target["column"]),
                   manhattan_grid_distance=abs(source["row"] - target["row"]) +
                   abs(source["column"] - target["column"]))
    evidence = dict(report=str(args.report.resolve()), report_sha256=sha(args.report),
                    netlist=str(args.netlist.resolve()), netlist_sha256=sha(args.netlist),
                    script_sha256=sha(Path(__file__)), critical_nodes=nodes,
                    critical_edges=edges, fanout_wire=wire, fanout_loads=loads,
                    coordinate_source=coordinate_source,
                    fanout_count=len(loads), located_fanout_count=sum(l["position"] is not None for l in loads),
                    unique_report_positions=known, ambiguous_report_positions=ambiguous,
                    geometric_comparison=metrics,
                    limitations=["Straight arrows are connectivity only, not routing geometry.",
                                 "Only STA-reported positions are plotted; missing positions are not guessed.",
                                 "Grid coordinates are not physical micrometres or congestion measurements.",
                                 "No encrypted placement files decoded; no RTL/CST/SDC or P&R changed."])
    (output / "placement_evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    with (output / "critical_path.csv").open("w") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(nodes[0]))
        writer.writeheader()
        writer.writerows(nodes)
    with (output / "fanout_loads.csv").open("w") as handle:
        writer = csv.writer(handle)
        writer.writerow(["instance", "type", "pin", "location", "row", "column", "euclidean_grid_distance"])
        for load in loads:
            p = load["position"] or {}
            writer.writerow([load["instance"], load["primitive_type"], load["pin"],
                             p.get("location", "UNKNOWN"), p.get("row", ""), p.get("column", ""),
                             load["euclidean_grid_distance"]])
    make_plot(nodes, edges, known, loads, output)
    if args.placement_cst:
        make_fanout_plot(source, loads, output)
    print(json.dumps(dict(output=str(output), coordinates=metrics, fanout=len(loads),
                         located_loads=evidence["located_fanout_count"],
                         unique_report_positions=len(known), ambiguous_instances=len(ambiguous)), indent=2))


if __name__ == "__main__":
    main()
