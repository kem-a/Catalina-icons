#!/usr/bin/env python3
"""
resize-to-16.py — Resize SVG icons to 16×16 if they are not already that size

Sets width="16" and height="16" on the root <svg> element while preserving
the viewBox (or deriving one from the existing dimensions if none is set).
Skips symlinks and files that are already 16×16.

Usage:
    python3 tools/resize-to-16.py [directory] [options]

Arguments:
    directory       Root directory to search (default: current directory)

Options:
    --theme THEME   Filter by theme subdirectory (e.g. Catalina-dark, Catalina-light)
    --dry-run       Print what would be changed without writing files

Examples:
    python3 tools/resize-to-16.py
    python3 tools/resize-to-16.py Catalina-dark
    python3 tools/resize-to-16.py --dry-run
    python3 tools/resize-to-16.py Catalina-dark/16x16 --dry-run
"""

import sys
import argparse
import re
from pathlib import Path
from lxml import etree


SVG_NS = "http://www.w3.org/2000/svg"
TARGET = 16


def parse_length(value: str) -> float | None:
    """Parse an SVG length value, stripping units (px, pt, etc.)."""
    if value is None:
        return None
    m = re.match(r"^\s*([\d.]+)\s*(px|pt|mm|cm|in|em|rem|%)?\s*$", value)
    if m:
        return float(m.group(1))
    return None


def process_file(path: Path, dry_run: bool) -> str:
    """
    Resize the SVG at `path` to 16×16.
    Returns a status string: 'skipped', 'resized', or 'error: <msg>'.
    """
    try:
        parser = etree.XMLParser(recover=True, resolve_entities=False)
        tree = etree.parse(str(path), parser)
        root = tree.getroot()

        local = root.tag.split("}")[-1] if root.tag.startswith("{") else root.tag
        if local != "svg":
            return "error: root element is not <svg>"

        w = parse_length(root.get("width"))
        h = parse_length(root.get("height"))

        if w == TARGET and h == TARGET:
            return "skipped"

        # Ensure a viewBox is present so the artwork isn't clipped/stretched.
        vb = root.get("viewBox")
        if not vb:
            if w is not None and h is not None:
                root.set("viewBox", f"0 0 {int(w) if w == int(w) else w} {int(h) if h == int(h) else h}")
            else:
                # No size info at all — set a square viewBox matching the target.
                root.set("viewBox", f"0 0 {TARGET} {TARGET}")

        root.set("width", str(TARGET))
        root.set("height", str(TARGET))

        if not dry_run:
            tree.write(
                str(path),
                xml_declaration=True,
                encoding="UTF-8",
                pretty_print=False,
            )

        old = f"{int(w) if (w is not None and w == int(w)) else w}×{int(h) if (h is not None and h == int(h)) else h}"
        return f"resized ({old} → {TARGET}×{TARGET})"

    except Exception as e:
        return f"error: {e}"


def main():
    parser = argparse.ArgumentParser(description="Resize SVG icons to 16×16.")
    parser.add_argument("directory", nargs="?", default=".", help="Root directory to search")
    parser.add_argument("--theme", default=None, metavar="THEME",
                        help="Filter by theme subdirectory name")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would change without writing files")
    args = parser.parse_args()

    root = Path(args.directory).resolve()
    if not root.is_dir():
        print(f"Error: '{root}' is not a directory.", file=sys.stderr)
        sys.exit(1)

    if args.theme:
        root = root / args.theme
        if not root.is_dir():
            print(f"Error: theme directory '{root}' not found.", file=sys.stderr)
            sys.exit(1)

    svgs = [p for p in root.rglob("*.svg") if p.is_file() and not p.is_symlink()]

    if not svgs:
        print("No SVG files found.")
        return

    if args.dry_run:
        print("Dry run — no files will be written.\n")

    resized = skipped = errors = 0

    for path in sorted(svgs):
        rel = path.relative_to(root)
        status = process_file(path, dry_run=args.dry_run)

        if status == "skipped":
            skipped += 1
        elif status.startswith("error"):
            errors += 1
            print(f"  ERROR  {rel}  ({status})")
        else:
            resized += 1
            print(f"  {status:<30}  {rel}")

    print(f"\n{resized} resized, {skipped} already 16×16, {errors} errors")
    if args.dry_run and resized:
        print("(dry run — rerun without --dry-run to apply changes)")


if __name__ == "__main__":
    main()
