"""Paired A/B power measurement of a video wallpaper process.

Alternates a target process between playing (A) and paused (B) in an ABBA pattern, which
cancels slow drift, and compares each cycle's A block against its own B block. Power comes
from macmon (SMC and IOReport); CPU shares come from cumulative process CPU time, so
neither is a sampled estimate.

The difference is only meaningful while nothing else animates on screen: a second
animator already pays part of the cost of running the display pipeline, which makes the
target look cheaper. Check the paused WindowServer share printed in the header against a
run you know was quiet.

Requires macmon on PATH. Run on battery, hands off, with the usual window layout.
"""
import argparse
import json
import math
import os
import signal
import statistics
import subprocess
import sys
import threading
import time

INTERVAL_MS = 200
POWER_KEYS = ["sys_power", "cpu_power", "gpu_power", "display_power", "dcs_power", "ram_power"]

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--pid", type=int, nargs="+", required=True, help="process (or all processes of one app) to alternate between playing and paused")
parser.add_argument("--pause", default="USR1", help="signal that pauses the target (USR1, or STOP for a process without pause support)")
parser.add_argument("--resume", default="USR2", help="signal that resumes the target (USR2 or CONT)")
parser.add_argument("--hold-stopped", type=int, nargs="*", default=[], help="pids kept suspended for the whole run")
parser.add_argument("--cycles", type=int, default=12)
parser.add_argument("--window", type=float, default=10.0, help="seconds measured per block")
# System power read from the SMC lags a state change by several seconds.
parser.add_argument("--settle", type=float, default=6.0, help="seconds discarded after each switch")
parser.add_argument("--out", required=True, help="path of the JSON result")
args = parser.parse_args()

PAUSE = getattr(signal, "SIG" + args.pause)
RESUME = getattr(signal, "SIG" + args.resume)


def pgrep(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def cpu_seconds(pids):
    """Cumulative CPU seconds per pid, from ps (mm:ss.cc)."""
    out = subprocess.run(["ps", "-o", "pid=,time=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        pid, t = line.split()
        secs = 0.0
        for part in t.split(":"):
            secs = secs * 60 + float(part)
        result[int(pid)] = secs
    return result


def screen_locked():
    """True while the lock screen covers the desktop, which hides the wallpaper entirely."""
    out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-w0"], capture_output=True, text=True).stdout
    return '"CGSSessionScreenIsLocked"=Yes' in out


def send(pid, sig):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass


watch = {
    "ws_cpu_pct": pgrep("WindowServer"),
    "target_cpu_pct": args.pid,
    # Video decoding runs in these helper processes, not in the target itself.
    "decoder_cpu_pct": pgrep("VTDecoderXPCService"),
}
all_pids = sorted({p for pids in watch.values() for p in pids})

samples = []
macmon = subprocess.Popen(["macmon", "-i", str(INTERVAL_MS), "pipe"], stdout=subprocess.PIPE, text=True)


def reader():
    for line in macmon.stdout:
        try:
            samples.append((time.time(), json.loads(line)))
        except ValueError:
            continue


threading.Thread(target=reader, daemon=True).start()


def restore(*_):
    for pid in args.pid:
        send(pid, RESUME)
    for pid in args.hold_stopped:
        send(pid, signal.SIGCONT)


def bail(*_):
    restore()
    macmon.terminate()
    sys.exit(1)


for interrupt in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(interrupt, bail)

blocks = []
try:
    for pid in args.hold_stopped:
        send(pid, signal.SIGSTOP)
    for cycle in range(args.cycles):
        for state in ("AB" if cycle % 2 == 0 else "BA"):
            for pid in args.pid:
                send(pid, RESUME if state == "A" else PAUSE)
            time.sleep(args.settle)
            t0, c0 = time.time(), cpu_seconds(all_pids)
            time.sleep(args.window)
            t1, c1 = time.time(), cpu_seconds(all_pids)
            if any(pid not in c1 for pid in args.pid):
                # A result measured against a dead target would read as "costs nothing".
                print("the target process exited during the run; no result written", file=sys.stderr)
                bail()
            block = {"cycle": cycle, "state": state, "t0": t0, "t1": t1, "locked": screen_locked()}
            for key, pids in watch.items():
                used = sum(c1.get(p, 0) - c0.get(p, 0) for p in pids)
                block[key] = 100 * used / (t1 - t0)
            blocks.append(block)
finally:
    restore()
    time.sleep(0.5)
    macmon.terminate()

# Each macmon sample covers the interval before its timestamp, so skip the first one in a block.
for b in blocks:
    inside = [d for (t, d) in samples if b["t0"] + INTERVAL_MS / 1000 < t <= b["t1"]]
    b["n"] = len(inside)
    for k in POWER_KEYS:
        vals = [d[k] for d in inside if isinstance(d.get(k), (int, float))]
        b[k] = statistics.fmean(vals) if vals else None
plugged = sorted({d.get("battery_plugged") for (_, d) in samples if d.get("battery_plugged") is not None})


def t_crit(df):
    z = 1.959964
    return z + (z**3 + z) / (4 * df) + (5 * z**5 + 16 * z**3 + 3 * z) / (96 * df**2)


# A cycle measured behind the lock screen says nothing about the cost of a visible wallpaper.
locked_cycles = {b["cycle"] for b in blocks if b["locked"]}

summary = {}
for k in POWER_KEYS + list(watch):
    a = {b["cycle"]: b[k] for b in blocks if b["state"] == "A" and b[k] is not None}
    bb = {b["cycle"]: b[k] for b in blocks if b["state"] == "B" and b[k] is not None}
    cycles = sorted((set(a) & set(bb)) - locked_cycles)
    if len(cycles) < 2:
        continue
    diffs = [a[c] - bb[c] for c in cycles]
    sd = statistics.stdev(diffs)
    summary[k] = {
        "playing": statistics.fmean(a[c] for c in cycles),
        "paused": statistics.fmean(bb[c] for c in cycles),
        "diff_mean": statistics.fmean(diffs),
        "diff_ci95": t_crit(len(diffs) - 1) * sd / math.sqrt(len(diffs)),
        "diff_median": statistics.median(diffs),
        "diff_sd": sd,
        "positive_cycles": sum(d > 0 for d in diffs),
        "cycles": len(diffs),
    }

params = {k: v for k, v in vars(args).items() if k != "out"}
with open(args.out, "w") as f:
    json.dump({"params": params, "interval_ms": INTERVAL_MS, "battery_plugged": plugged,
               "summary": summary, "blocks": blocks}, f, indent=1)

paused_ws = summary["ws_cpu_pct"]["paused"] if "ws_cpu_pct" in summary else float("nan")
print(f"cycles={args.cycles} window={args.window}s settle={args.settle}s plugged={plugged} "
      f"excluded (screen locked)={len(locked_cycles)} paused WindowServer={paused_ws:.0f}%")
print(f"{'metric':<16}{'playing':>9}{'paused':>9}{'diff':>9}{'±95%':>8}{'median':>9}{'sd':>7}{'pos':>7}")
for k, s in summary.items():
    print(f"{k:<16}{s['playing']:>9.2f}{s['paused']:>9.2f}{s['diff_mean']:>9.2f}{s['diff_ci95']:>8.2f}"
          f"{s['diff_median']:>9.2f}{s['diff_sd']:>7.2f}{s['positive_cycles']:>4}/{s['cycles']}")
