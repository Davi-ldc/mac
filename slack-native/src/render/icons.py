#!/usr/bin/env python3
"""Writes Slack's icon set as outlines: python3 icons.py <folder of Slack's static JS> <out>.

Slack draws its icons as SVG components (a table of 20x20 drawings keyed by name in its vendors
bundle), not with its legacy icon font; the add-reaction pill's face is an inline SVG of its own
(class c-reaction_add__fg), written as "reaction-add".

The output has one icon per line, "<name>\t<element>...", each element a paint followed by an
absolute path in the 20-unit box: "E" fills even-odd, "F" fills non-zero, "S<width>" strokes
with round caps; the path uses only M, L, C and Z, so the app's reader stays trivial. Icons
painted in fixed colours (brand logos) are left out: the app tints every glyph with one colour.

The drawings are Slack's and are never published: the output goes to design/ (private), and
`make` copies it into the app bundle when it exists.
"""
import glob
import math
import re
import sys

source, out = sys.argv[1], sys.argv[2]


def find(needle):
    """The bundle containing needle, and where."""
    for path in sorted(glob.glob(source + "/*.js")):
        text = open(path, encoding="utf-8", errors="replace").read()
        at = text.find(needle)
        if at >= 0:
            return text, at
    sys.exit("no %s under %s" % (needle, source))


def closing(text, i):
    """Index of the bracket closing the one at text[i], skipping strings."""
    depth, quote = 0, None
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
        elif c in "{[(":
            depth += 1
        elif c in "}])":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced")


ELEMENT = re.compile(r'\(0,\w+\.jsxs?\)\("(\w+)",')


def elements(text):
    """[(tag, attributes, children)] of the JSX calls in text, outermost first."""
    found, i = [], 0
    while True:
        m = ELEMENT.search(text, i)
        if not m:
            return found
        end = closing(text, m.end())
        props = text[m.end() : end + 1]
        at = props.find("children:")
        own = props if at < 0 else props[:at]
        attributes = dict(re.findall(r'(\w+):"([^"]*)"', own))
        attributes.update(re.findall(r"(\w+):([\d.]+)[,}]", own))
        found.append((m.group(1), attributes, elements(props[at:]) if at >= 0 else []))
        i = end + 1


NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def tokens(d):
    """Commands and numbers; an arc's two flags are single digits that may touch what follows."""
    i, command, argument = 0, None, 0
    while i < len(d):
        if d[i] in " ,\t\n":
            i += 1
        elif d[i].isalpha():
            command, argument = d[i], 0
            yield command
            i += 1
        elif command in "Aa" and argument % 7 in (3, 4):
            yield float(d[i])
            i, argument = i + 1, argument + 1
        else:
            m = NUMBER.match(d, i)
            yield float(m.group(0))
            i, argument = m.end(), argument + 1


def arc(x1, y1, rx, ry, angle, large, sweep, x2, y2):
    """Cubic segments [(c1, c2, end)] for an SVG elliptical arc (SVG 1.1 appendix F.6)."""
    if rx == 0 or ry == 0:
        return [((x1, y1), (x2, y2), (x2, y2))]
    phi = math.radians(angle)
    cos, sin = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cos * dx + sin * dy, -sin * dx + cos * dy
    rx, ry = abs(rx), abs(ry)
    scale = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if scale > 1:
        rx, ry = rx * math.sqrt(scale), ry * math.sqrt(scale)
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    k = math.sqrt(max(0, num / den)) * (-1 if large == sweep else 1)
    cxp, cyp = k * rx * y1p / ry, -k * ry * x1p / rx
    cx, cy = cos * cxp - sin * cyp + (x1 + x2) / 2, sin * cxp + cos * cyp + (y1 + y2) / 2

    def angle_of(ux, uy, vx, vy):
        return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)

    theta = angle_of(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    delta = angle_of((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi
    count = max(1, math.ceil(abs(delta) / (math.pi / 2) - 1e-9))
    step = delta / count
    t = 4 / 3 * math.tan(step / 4)

    def point(a):
        x, y = rx * math.cos(a), ry * math.sin(a)
        return cos * x - sin * y + cx, sin * x + cos * y + cy

    def tangent(a):
        x, y = -rx * math.sin(a), ry * math.cos(a)
        return cos * x - sin * y, sin * x + cos * y

    segments = []
    for i in range(count):
        a, b = theta + i * step, theta + (i + 1) * step
        (ax, ay), (bx, by) = point(a), point(b)
        (tax, tay), (tbx, tby) = tangent(a), tangent(b)
        segments.append(((ax + t * tax, ay + t * tay), (bx - t * tbx, by - t * tby), (bx, by)))
    segments[-1] = (segments[-1][0], segments[-1][1], (x2, y2))
    return segments


def normalize(d):
    """The path as absolute M, L, C and Z commands."""
    out, items = [], list(tokens(d))
    x = y = sx = sy = 0.0
    last_control, last_command, command, i = None, None, None, 0
    while i < len(items):
        if isinstance(items[i], str):
            command = items[i]
            i += 1
            if command in "Zz":
                out.append("Z")
                x, y, last_control, last_command = sx, sy, None, "Z"
                continue
        relative, op = command.islower(), command.upper()
        count = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7}[op]
        args = items[i : i + count]
        i += count
        if op != "A":
            for n in range(len(args)):
                if relative and op not in "HV":
                    args[n] += x if n % 2 == 0 else y
                elif relative:
                    args[n] += x if op == "H" else y
        control = None
        if op == "M":
            x, y = args
            sx, sy = x, y
            out.append("M%s %s" % (num(x), num(y)))
            command = "l" if relative else "L"  # further pairs are line-tos
        elif op in "LHV":
            x, y = (args[0], y) if op == "H" else (x, args[0]) if op == "V" else args
            out.append("L%s %s" % (num(x), num(y)))
        elif op in "CS":
            if op == "S":
                c1 = (2 * x - last_control[0], 2 * y - last_control[1]) if last_command in ("C", "S") else (x, y)
                args = list(c1) + args
            out.append("C" + " ".join(num(v) for v in args))
            control, (x, y) = (args[2], args[3]), (args[4], args[5])
        elif op in "QT":
            if op == "T":
                q = (2 * x - last_control[0], 2 * y - last_control[1]) if last_command in ("Q", "T") else (x, y)
                args = list(q) + args
            qx, qy, ex, ey = args
            out.append("C" + " ".join(num(v) for v in (x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey), ex, ey)))
            control, (x, y) = (qx, qy), (ex, ey)
        else:
            rx, ry, angle, large, sweep, ex, ey = args
            if relative:
                ex, ey = ex + x, ey + y
            for c1, c2, end in arc(x, y, rx, ry, angle, bool(large), bool(sweep), ex, ey):
                out.append("C" + " ".join(num(v) for v in (*c1, *c2, *end)))
            x, y = ex, ey
        last_control, last_command = control, op
    return "".join(out)


def num(v):
    text = ("%.3f" % v).rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def paint(tag, attributes, inherited, found):
    style = dict(inherited, **attributes)
    if tag == "path":
        fill, stroke = style.get("fill", "currentColor"), style.get("stroke", "none")
        for colour in (fill, stroke):
            if colour not in ("currentColor", "none"):
                raise ValueError("fixed colour")
        if stroke != "none":
            found.append("S%s %s" % (num(float(style.get("strokeWidth", 1))), normalize(style["d"])))
        if fill != "none":
            found.append(("E" if style.get("fillRule") == "evenodd" else "F") + normalize(style["d"]))
    elif tag in ("svg", "g"):
        attributes = {k: v for k, v in attributes.items() if k in ("fill", "stroke", "fillRule", "strokeWidth")}
    else:
        raise ValueError("unsupported " + tag)
    return dict(inherited, **{k: v for k, v in attributes.items() if k != "d"})


def drawing(nodes, inherited, found):
    for tag, attributes, children in nodes:
        drawing(children, paint(tag, attributes, inherited, found), found)
    return found


text, at = find('displayName="SvgIconPrimitive"')
table = text[: text.rfind("},J=", 0, at)]
lines = []
for m in re.finditer(r'[{,]"?([a-z0-9-]+)"?:\w+\.forwardRef(\()\(\w+,\w+\)=>', table):
    nodes = elements(table[m.end() : closing(table, m.start(2))])
    if nodes[0][1].get("viewBox") != "0 0 20 20":
        continue
    try:
        lines.append("\t".join([m.group(1)] + drawing(nodes, {}, [])))
    except ValueError:
        continue

text, at = find('className:"c-reaction_add__bg"')
start = text.rfind("(0,", 0, text.rfind('("svg",', 0, at))
svg = elements(text[start : closing(text, text.find("(", start + 3)) + 1])[0]
face = [node for node in svg[2] if node[1].get("className") == "c-reaction_add__fg"]
lines.append("\t".join(["reaction-add"] + drawing(face, {}, [])))
open(out, "w").write("\n".join(lines) + "\n")
print("%d icons -> %s" % (len(lines), out))
