"""Average system power over a fixed window, for states that cannot be toggled (idle floor,
display mode, brightness level). Prints one line and writes the same numbers as JSON.

Unlike power_ab.py this is not a paired measurement, so two averages are only comparable
when taken close together on a machine where nothing else animates on screen.
"""
import argparse
import json
import statistics
import subprocess
import time

INTERVAL_MS = 200
POWER_KEYS = ["sys_power", "cpu_power", "gpu_power", "display_power", "dcs_power", "ram_power"]

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--label", required=True)
parser.add_argument("--seconds", type=float, default=60.0)
parser.add_argument("--settle", type=float, default=5.0, help="seconds discarded at the start")
parser.add_argument("--out", required=True)
args = parser.parse_args()


def window_server_cpu_seconds():
    pids = subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True).stdout.split()
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(pids)], capture_output=True, text=True).stdout
    total = 0.0
    for line in out.split():
        secs = 0.0
        for part in line.split(":"):
            secs = secs * 60 + float(part)
        total += secs
    return total


macmon = subprocess.Popen(["macmon", "-i", str(INTERVAL_MS), "pipe"], stdout=subprocess.PIPE, text=True)
samples = []
launched = time.time()
began = None
try:
    for line in macmon.stdout:
        now = time.time()
        if now - launched < args.settle:
            continue
        if began is None:
            began, cpu_began = now, window_server_cpu_seconds()
        try:
            samples.append(json.loads(line))
        except ValueError:
            continue
        if now - began >= args.seconds:
            break
finally:
    macmon.terminate()
ws_pct = 100 * (window_server_cpu_seconds() - cpu_began) / (time.time() - began)

result = {"label": args.label, "seconds": args.seconds, "n": len(samples), "ws_cpu_pct": ws_pct}
for key in POWER_KEYS:
    values = [s[key] for s in samples if isinstance(s.get(key), (int, float))]
    result[key] = statistics.fmean(values) if values else None
    result[key + "_sd"] = statistics.pstdev(values) if values else None
result["sys_power_median"] = statistics.median(s["sys_power"] for s in samples)
with open(args.out, "w") as f:
    json.dump(result, f, indent=1)

print(f"{args.label:<26} sys={result['sys_power']:.2f}W (med {result['sys_power_median']:.2f}, sd {result['sys_power_sd']:.2f}) "
      f"cpu={result['cpu_power']:.2f} gpu={result['gpu_power']:.2f} display={result['display_power']:.2f} "
      f"dcs={result['dcs_power']:.2f} ram={result['ram_power']:.2f} ws={ws_pct:.1f}%")
