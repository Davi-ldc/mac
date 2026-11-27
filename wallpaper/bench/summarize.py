"""Writes summary.tsv for a results directory: one row per scenario, in the order they ran.

    summarize.py <results-dir>
"""
import glob
import json
import os
import sys

directory = sys.argv[1]
columns = ["scenario", "kind", "playing_w", "paused_w", "diff_w", "diff_ci95_w", "diff_median_w",
           "cpu_w", "gpu_w", "display_w", "dcs_w", "ram_w", "ws_playing_pct", "ws_paused_pct",
           "positive_cycles", "cycles", "average_w", "average_sd_w"]
rows = []
for path in sorted(glob.glob(os.path.join(directory, "*.json")), key=os.path.getmtime):
    data = json.load(open(path))
    row = dict.fromkeys(columns, "")
    row["scenario"] = os.path.basename(path)[:-5]
    if "summary" in data:
        # Paired run: component columns are differences, playing minus paused.
        s = data["summary"]
        power = s["sys_power"]
        row.update(kind="paired", playing_w=power["playing"], paused_w=power["paused"],
                   diff_w=power["diff_mean"], diff_ci95_w=power["diff_ci95"],
                   diff_median_w=power["diff_median"], cpu_w=s["cpu_power"]["diff_mean"],
                   gpu_w=s["gpu_power"]["diff_mean"], display_w=s["display_power"]["diff_mean"],
                   dcs_w=s["dcs_power"]["diff_mean"], ram_w=s["ram_power"]["diff_mean"],
                   ws_playing_pct=s["ws_cpu_pct"]["playing"], ws_paused_pct=s["ws_cpu_pct"]["paused"],
                   positive_cycles=power["positive_cycles"], cycles=power["cycles"])
    else:
        # Plain average: component columns are absolute.
        row.update(kind="average", average_w=data["sys_power"], average_sd_w=data["sys_power_sd"],
                   cpu_w=data["cpu_power"], gpu_w=data["gpu_power"], display_w=data["display_power"],
                   dcs_w=data["dcs_power"], ram_w=data["ram_power"], ws_paused_pct=data["ws_cpu_pct"])
    rows.append(row)


def cell(value):
    return f"{value:.2f}" if isinstance(value, float) else str(value)


with open(os.path.join(directory, "summary.tsv"), "w") as f:
    f.write("\t".join(columns) + "\n")
    for row in rows:
        f.write("\t".join(cell(row[c]) for c in columns) + "\n")
print(f"{len(rows)} scenarios")
