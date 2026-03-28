#!/usr/bin/env python3
"""
Flatten translate() transforms in symbolic SVG icons.

GTK4's simplified SVG renderer cannot handle translate() transforms with
large offset values — it parses the SVG without error but renders invisibly.
This script removes the <g transform="translate(dx dy)"> wrapper and applies
the offset directly to the first moveto coordinate of each <path>.

Usage:
    python3 flatten-svg-transforms.py <file_or_directory> [...]

Examples:
    python3 flatten-svg-transforms.py icon.svg
    python3 flatten-svg-transforms.py Catalina-light/devices/symbolic/
    python3 flatten-svg-transforms.py Catalina-light/*/symbolic/
"""

import re
import sys
import os
import glob


def parse_translate(transform_str):
    """Extract dx, dy from translate(dx dy) or translate(dx, dy)."""
    m = re.search(r'translate\(\s*([+-]?\d+\.?\d*)\s*[,\s]\s*([+-]?\d+\.?\d*)\s*\)', transform_str)
    if not m:
        return None
    return float(m.group(1)), float(m.group(2))


def apply_translate_to_path(d_attr, dx, dy):
    """Apply translate to SVG path data.

    Only the first moveto (m/M) of each <path> is absolute — all subsequent
    commands use relative coordinates, so only that first pair needs adjusting.
    """
    # Match the initial moveto: m or M followed by two numbers
    pattern = r'^([mM])\s*([+-]?\d+\.?\d*(?:e[+-]?\d+)?)\s*[,\s]\s*([+-]?\d+\.?\d*(?:e[+-]?\d+)?)'
    m = re.match(pattern, d_attr.strip())
    if not m:
        return d_attr  # Can't parse, return unchanged

    cmd = m.group(1)
    x = float(m.group(2)) + dx
    y = float(m.group(3)) + dy

    # Format numbers: drop trailing zeros, use compact representation
    def fmt(n):
        if n == int(n):
            return str(int(n))
        return f"{n:g}"

    rest = d_attr.strip()[m.end():]
    new_start = f"{cmd}{fmt(x)} {fmt(y)}"
    return new_start + rest


def flatten_svg(filepath):
    """Flatten translate transforms in an SVG file. Returns True if modified."""
    if not os.path.isfile(filepath) or os.path.islink(filepath) and not os.path.exists(filepath):
        return False
    with open(filepath, 'r') as f:
        content = f.read()

    # Find <g transform="translate(...)"> with optional other attributes
    g_pattern = r'<g\s+([^>]*?)transform="(translate\([^)]+\))"([^>]*)>'
    g_match = re.search(g_pattern, content)
    if not g_match:
        return False

    transform_str = g_match.group(2)
    offset = parse_translate(transform_str)
    if not offset:
        return False

    dx, dy = offset

    # Skip if offset is already small (coordinates already in viewport range)
    if abs(dx) < 20 and abs(dy) < 20:
        return False

    # Apply translate to each <path d="..."> within the file
    def replace_path_d(m):
        prefix = m.group(1)
        d_attr = m.group(2)
        new_d = apply_translate_to_path(d_attr, dx, dy)
        return f'{prefix}"{new_d}"'

    new_content = re.sub(r'(<path[^>]*\bd=)"([^"]*)"', replace_path_d, content)

    # Remove the transform attribute from the <g> element
    # Rebuild <g> without the transform, keeping other attributes
    before_transform = g_match.group(1).strip()
    after_transform = g_match.group(3).strip()
    remaining_attrs = f"{before_transform} {after_transform}".strip()
    if remaining_attrs:
        new_g = f'<g {remaining_attrs}>'
    else:
        new_g = '<g>'
    new_content = new_content[:g_match.start()] + new_g + new_content[g_match.end():]

    # Also fix non-integer height to round 16.009 -> 16 etc.
    new_content = re.sub(
        r'height="(\d+)\.\d+"',
        lambda m: f'height="{m.group(1)}"',
        new_content
    )

    with open(filepath, 'w') as f:
        f.write(new_content)

    return True


def process_path(path):
    """Process a file or directory."""
    if os.path.isfile(path) and path.endswith('.svg'):
        return [(path, flatten_svg(path))]

    results = []
    if os.path.isdir(path):
        for svg in sorted(glob.glob(os.path.join(path, '**', '*.svg'), recursive=True)):
            results.append((svg, flatten_svg(svg)))
    return results


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)

    total_modified = 0
    total_skipped = 0

    for arg in sys.argv[1:]:
        # Expand globs if shell didn't
        paths = glob.glob(arg) if '*' in arg else [arg]
        for path in paths:
            results = process_path(path)
            for filepath, modified in results:
                if modified:
                    print(f"  fixed: {filepath}")
                    total_modified += 1
                else:
                    total_skipped += 1

    print(f"\nDone: {total_modified} fixed, {total_skipped} skipped")


if __name__ == '__main__':
    main()
