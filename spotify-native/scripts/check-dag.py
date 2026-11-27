#!/usr/bin/env python3
"""Verify strict acyclic module DAG under src/ for spotify-native (including ui/* submodules)."""

import os
import re
import sys

# Strict topological layers:
# theme, model -> store -> auth, net, connect -> audio -> render -> ui/kit -> ui/{feature panes} -> ui/shell -> app
LAYER_ORDER = [
    "theme",
    "model",
    "store",
    "auth",
    "net",
    "connect",
    "audio",
    "render",
    "ui/kit",
    "ui/sidebar",
    "ui/home",
    "ui/library",
    "ui/detail",
    "ui/search",
    "ui/player",
    "ui/auth",
    "ui/prefs",
    "ui/shell",
    "app",
]

UI_FEATURE_PANES = {
    "ui/sidebar",
    "ui/home",
    "ui/library",
    "ui/detail",
    "ui/search",
    "ui/player",
    "ui/auth",
    "ui/prefs",
}

ALLOWED_DEPS = {
    "theme": set(),
    "model": set(),
    "store": {"model"},
    "auth": {"model"},
    "net": {"model", "store", "auth"},
    "connect": {"model", "store", "auth", "net"},
    "audio": {"model", "store", "auth", "net", "connect"},
    "render": {"theme", "model", "store", "net"},
    "ui/kit": {"theme", "model", "store", "auth", "net", "connect", "audio", "render"},
    "ui/sidebar": {"theme", "model", "store", "render", "ui/kit"},
    "ui/home": {"theme", "model", "store", "render", "ui/kit"},
    "ui/library": {"theme", "model", "store", "render", "ui/kit"},
    "ui/detail": {"theme", "model", "store", "render", "ui/kit"},
    "ui/search": {"theme", "model", "store", "net", "render", "ui/kit"},
    "ui/player": {"theme", "model", "store", "connect", "audio", "render", "ui/kit"},
    "ui/auth": {"theme", "model", "auth", "render", "ui/kit"},
    "ui/prefs": {"theme", "model", "store", "auth", "audio", "render", "ui/kit"},
    "ui/shell": {
        "theme", "model", "store", "auth", "net", "connect", "audio", "render", "ui/kit",
    } | UI_FEATURE_PANES,
    "app": {
        "theme", "model", "store", "auth", "net", "connect", "audio", "render", "ui/kit", "ui/shell",
    } | UI_FEATURE_PANES,
}

GLOBAL_FORBIDDEN_SYSTEM_IMPORTS = {"SwiftUI"}

FORBIDDEN_SYSTEM_IMPORTS = {
    "theme": {"AppKit", "Cocoa", "SwiftUI", "AVFoundation", "MediaPlayer"},
    "model": {"AppKit", "Cocoa", "SwiftUI", "AVFoundation", "MediaPlayer"},
    "store": {"AppKit", "Cocoa", "SwiftUI", "AVFoundation", "MediaPlayer"},
}

IMPORT_RE = re.compile(r'^\s*#\s*(?:import|include)\s+"([^"]+)"', re.MULTILINE)
SYS_IMPORT_RE = re.compile(r'^\s*#\s*(?:import|include)\s+<([^/>]+)[/>]', re.MULTILINE)


def discover_modules(src_root: str):
    """Returns list of (module_name, directory_path) treating ui/* as distinct DAG nodes."""
    found = []
    for entry in sorted(os.listdir(src_root)):
        full = os.path.join(src_root, entry)
        if not os.path.isdir(full):
            continue
        if entry == "ui":
            # Any loose source files directly under src/ui/ are disallowed.
            for sub in sorted(os.listdir(full)):
                sub_full = os.path.join(full, sub)
                if os.path.isdir(sub_full):
                    found.append((f"ui/{sub}", sub_full))
                elif sub.endswith((".h", ".m", ".c")):
                    found.append(("ui", full))
        else:
            found.append((entry, full))
    return found


def resolve_import_target(inc: str, current_mod: str) -> str:
    parts = inc.split("/")
    if len(parts) == 1:
        return current_mod
    if parts[0] == "ui" and len(parts) >= 2:
        return f"ui/{parts[1]}"
    return parts[0]


def main() -> int:
    src_root = sys.argv[1] if len(sys.argv) > 1 else "src"
    if not os.path.isdir(src_root):
        print(f"FAIL: missing source directory {src_root}", file=sys.stderr)
        return 1

    layer_index = {m: i for i, m in enumerate(LAYER_ORDER)}
    discovered = discover_modules(src_root)
    graph = {m: set() for m, _ in discovered}
    violations = []

    for mod, mod_dir in discovered:
        if mod not in ALLOWED_DEPS:
            violations.append(f"Unknown module '{mod}' not declared in DAG")
            continue
        for root, _, files in os.walk(mod_dir):
            for name in sorted(files):
                if not name.endswith((".h", ".m", ".c")):
                    continue
                path = os.path.join(root, name)
                with open(path, "r", encoding="utf-8") as fh:
                    content = fh.read()

                forbidden_sys = GLOBAL_FORBIDDEN_SYSTEM_IMPORTS | FORBIDDEN_SYSTEM_IMPORTS.get(mod, set())
                for sys_inc in SYS_IMPORT_RE.findall(content):
                    if sys_inc in forbidden_sys:
                        violations.append(
                            f"{path}: module '{mod}' must not import system framework <{sys_inc}>"
                        )

                for inc in IMPORT_RE.findall(content):
                    target = resolve_import_target(inc, mod)
                    if target == mod:
                        continue
                    graph[mod].add(target)
                    if target not in ALLOWED_DEPS[mod]:
                        violations.append(
                            f"{path}: forbidden dependency '{mod}' -> '{target}' (#import \"{inc}\")"
                        )
                    elif target in layer_index and mod in layer_index and layer_index[target] >= layer_index[mod]:
                        violations.append(
                            f"{path}: topological layer violation '{mod}' -> '{target}' (#import \"{inc}\")"
                        )

    # Belt-and-suspenders DFS 3-color cycle detection.
    color = {m: 0 for m in graph}
    stack = []

    def dfs(u: str) -> None:
        color[u] = 1
        stack.append(u)
        for v in sorted(graph.get(u, ())):
            if v not in color:
                continue
            if color[v] == 1:
                idx = stack.index(v)
                cycle = " -> ".join(stack[idx:] + [v])
                violations.append(f"Cycle detected: {cycle}")
            elif color[v] == 0:
                dfs(v)
        stack.pop()
        color[u] = 2

    for m in sorted(graph):
        if color[m] == 0:
            dfs(m)

    if violations:
        for v in violations:
            print(f"DAG VIOLATION: {v}", file=sys.stderr)
        return 1

    ordered = [m for m in LAYER_ORDER if m in graph]
    summary = ", ".join(
        f"{m}->[{','.join(sorted(graph[m]))}]" for m in ordered
    )
    print(f"DAG OK ({len(ordered)} modules, 0 cycles): {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
