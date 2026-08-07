#!/usr/bin/env python3
"""Rewrite the icon SVGs into a form Xcode's `actool` renders faithfully.

`actool` mis-parses elliptical arc commands that use SVG's compact flag form,
where the large-arc and sweep booleans are written without separators
(`a6.105 6.105 0 013.046-.415` packs `0` and `1` into `01`). A parser that
scans numbers greedily reads `01` as a single value, shifting every following
parameter and producing an outline with spurious holes and notches.

So this converts every arc to cubic béziers, which `actool` renders correctly,
and emits an absolute path using only M/L/C/Z. It also pushes the root's
presentation attributes onto the paths and replaces the CSS-only
`currentColor` keyword, neither of which `actool` resolves.

Run from the repo root: python3 tools/flatten_svg_arcs.py
"""

import json
import math
import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "assets"
CATALOG = REPO / "BorderCollie/Assets.xcassets"

# imageset name -> (source svg, template-rendering-intent)
ICON_SETS = {
    "AgentIconClaude": ("claude-color.svg", "original"),
    "AgentIconCodex": ("codex.svg", "template"),
    "AgentIconCursor": ("cursor.svg", "template"),
    "MenuBarIcon": ("ollama.svg", "template"),
}

PARAM_COUNTS = {
    "M": 2, "L": 2, "T": 2,
    "H": 1, "V": 1,
    "C": 6, "S": 4, "Q": 4,
    "A": 7,
    "Z": 0,
}

NUMBER = re.compile(r"[+-]?(?:\d*\.\d+|\d+\.?)(?:[eE][+-]?\d+)?")


def tokenize(d):
    """Yield (command, params) with arc flags read as single digits."""
    i, n = 0, len(d)
    command = None
    while i < n:
        while i < n and d[i] in ", \t\r\n":
            i += 1
        if i >= n:
            break

        if d[i].isalpha():
            command = d[i]
            i += 1
        elif command is None:
            raise ValueError(f"path data starts with a number: {d[:20]!r}")
        elif command in "Mm":
            # Repeated moveto parameters are implicit linetos.
            command = "L" if command == "M" else "l"

        count = PARAM_COUNTS[command.upper()]
        params = []
        for index in range(count):
            while i < n and d[i] in ", \t\r\n":
                i += 1
            # The 4th and 5th arc parameters are flags: exactly one character
            # each, which is what the compact form relies on.
            if command in "Aa" and index in (3, 4):
                params.append(float(d[i]))
                i += 1
                continue
            match = NUMBER.match(d, i)
            if not match:
                raise ValueError(f"expected number at offset {i} in {d[:40]!r}")
            params.append(float(match.group()))
            i = match.end()

        yield command, params


def arc_to_cubics(x1, y1, rx, ry, rotation, large_arc, sweep, x2, y2):
    """SVG endpoint arc -> list of cubic segments (per SVG 1.1 F.6.5)."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", [x2, y2])]

    rx, ry = abs(rx), abs(ry)
    phi = math.radians(rotation % 360)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)

    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cos_phi * dx + sin_phi * dy
    y1p = -sin_phi * dx + cos_phi * dy

    # Scale up radii that are too small to span the endpoints.
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx, ry = rx * scale, ry * scale

    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    factor = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large_arc == sweep:
        factor = -factor

    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2
    cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        norm = math.hypot(ux, uy) * math.hypot(vx, vy)
        value = 0.0 if norm == 0 else max(-1.0, min(1.0, dot / norm))
        result = math.acos(value)
        return -result if ux * vy - uy * vx < 0 else result

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    theta = angle(1, 0, ux, uy)
    delta = angle(ux, uy, vx, vy)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    def point(t):
        return (
            cx + rx * cos_phi * math.cos(t) - ry * sin_phi * math.sin(t),
            cy + rx * sin_phi * math.cos(t) + ry * cos_phi * math.sin(t),
        )

    def derivative(t):
        return (
            -rx * cos_phi * math.sin(t) - ry * sin_phi * math.cos(t),
            -rx * sin_phi * math.sin(t) + ry * cos_phi * math.cos(t),
        )

    # A cubic approximates at most a quarter turn within tolerable error.
    steps = max(1, math.ceil(abs(delta) / (math.pi / 2)))
    step = delta / steps
    alpha = 4 / 3 * math.tan(step / 4)

    segments = []
    for index in range(steps):
        t0 = theta + index * step
        t1 = t0 + step
        p0x, p0y = point(t0)
        p1x, p1y = point(t1)
        d0x, d0y = derivative(t0)
        d1x, d1y = derivative(t1)
        segments.append(("C", [
            p0x + alpha * d0x, p0y + alpha * d0y,
            p1x - alpha * d1x, p1y - alpha * d1y,
            p1x, p1y,
        ]))
    return segments


def flatten(d):
    """Absolute path using only M/L/C/Z."""
    out = []
    x = y = 0.0
    start_x = start_y = 0.0
    prev_control = None
    prev_command = None

    for command, params in tokenize(d):
        absolute = command.upper()
        relative = command.islower()

        if absolute == "Z":
            out.append(("Z", []))
            x, y = start_x, start_y
            prev_control = None
        elif absolute in ("M", "L", "T"):
            px, py = params
            if relative:
                px, py = x + px, y + py
            if absolute == "T":
                cx1, cy1 = (2 * x - prev_control[0], 2 * y - prev_control[1]) \
                    if prev_command in "QqTt" and prev_control else (x, y)
                out.extend(quad_to_cubic(x, y, cx1, cy1, px, py))
                prev_control = (cx1, cy1)
            else:
                out.append((absolute, [px, py]))
                if absolute == "M":
                    start_x, start_y = px, py
                prev_control = None
            x, y = px, py
        elif absolute == "H":
            px = x + params[0] if relative else params[0]
            out.append(("L", [px, y]))
            x = px
            prev_control = None
        elif absolute == "V":
            py = y + params[0] if relative else params[0]
            out.append(("L", [x, py]))
            y = py
            prev_control = None
        elif absolute == "C":
            c1x, c1y, c2x, c2y, px, py = params
            if relative:
                c1x, c1y = x + c1x, y + c1y
                c2x, c2y = x + c2x, y + c2y
                px, py = x + px, y + py
            out.append(("C", [c1x, c1y, c2x, c2y, px, py]))
            prev_control = (c2x, c2y)
            x, y = px, py
        elif absolute == "S":
            c2x, c2y, px, py = params
            if relative:
                c2x, c2y = x + c2x, y + c2y
                px, py = x + px, y + py
            c1x, c1y = (2 * x - prev_control[0], 2 * y - prev_control[1]) \
                if prev_command in "CcSs" and prev_control else (x, y)
            out.append(("C", [c1x, c1y, c2x, c2y, px, py]))
            prev_control = (c2x, c2y)
            x, y = px, py
        elif absolute == "Q":
            cx1, cy1, px, py = params
            if relative:
                cx1, cy1 = x + cx1, y + cy1
                px, py = x + px, y + py
            out.extend(quad_to_cubic(x, y, cx1, cy1, px, py))
            prev_control = (cx1, cy1)
            x, y = px, py
        elif absolute == "A":
            rx, ry, rotation, large_arc, sweep, px, py = params
            if relative:
                px, py = x + px, y + py
            out.extend(arc_to_cubics(x, y, rx, ry, rotation, large_arc, sweep, px, py))
            prev_control = None
            x, y = px, py
        else:
            raise ValueError(f"unsupported command {command!r}")

        prev_command = command

    return render(out)


def quad_to_cubic(x, y, cx, cy, px, py):
    return [("C", [
        x + 2 / 3 * (cx - x), y + 2 / 3 * (cy - y),
        px + 2 / 3 * (cx - px), py + 2 / 3 * (cy - py),
        px, py,
    ])]


def render(segments):
    def num(value):
        text = f"{value:.4f}".rstrip("0").rstrip(".")
        return "0" if text in ("", "-0") else text

    return " ".join(
        command + (" " + " ".join(num(v) for v in params) if params else "")
        for command, params in segments
    )


def sanitize(svg):
    header = re.search(r"<svg([^>]*)>", svg).group(1)
    attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', header))

    # actool resolves neither inherited presentation attributes nor the
    # CSS-only `currentColor` keyword. These icons are monochrome and ship as
    # template images, so black is the correct paint.
    inherited = ""
    if "fill-rule" in attrs:
        inherited += f' fill-rule="{attrs["fill-rule"]}"'
    fill = attrs.get("fill")
    if fill:
        inherited += f' fill="{"#000000" if fill == "currentColor" else fill}"'

    def rewrite_path(match):
        body = match.group(1)
        d = re.search(r'\sd="([^"]*)"', body).group(1)
        body = re.sub(r'\sd="[^"]*"', "", body)
        return f'<path{inherited}{body} d="{flatten(d)}"/>'

    svg = re.sub(r"<path([^>]*?)/?>", rewrite_path, svg)
    # Paths are emitted self-closing, so drop any now-orphaned end tag.
    svg = svg.replace("</path>", "")

    # `1em` is CSS-relative; pin the dimensions to the viewBox instead.
    clean = re.sub(r'\s(?:fill|fill-rule|width|height|style)="[^"]*"', "", header)
    return re.sub(r"<svg[^>]*>", f'<svg width="24" height="24"{clean}>', svg, count=1)


def main():
    for name, (filename, intent) in ICON_SETS.items():
        directory = CATALOG / f"{name}.imageset"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / filename).write_text(sanitize((SRC / filename).read_text()))
        (directory / "Contents.json").write_text(json.dumps({
            "images": [{"filename": filename, "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {
                "preserves-vector-representation": True,
                "template-rendering-intent": intent,
            },
        }, indent=2) + "\n")
        print(f"wrote {directory.relative_to(REPO)}")


if __name__ == "__main__":
    main()
