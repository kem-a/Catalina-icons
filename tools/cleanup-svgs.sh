#!/bin/bash
#
# cleanup-svgs.sh — Validate, fix, and optimize SVG files
#
# Usage:
#   ./cleanup-svgs.sh [OPTIONS] <directory|file.svg>
#
# Options:
#   --check      Validate XML only, do not modify files
#   --fix-size   Remove invisible rects and fix SVG dimensions to match target
#   --scale-up   Scale up undersized drawings to fill icon canvas (needs inkscape)
#   --help       Show this help message
#
# Examples:
#   ./cleanup-svgs.sh Catalina-light/actions/22/
#   ./cleanup-svgs.sh --check Catalina-dark/
#   ./cleanup-svgs.sh --fix-size --scale-up Catalina-dark/status/16/
#   ./cleanup-svgs.sh Catalina-light/apps/scalable/myapp.svg

set -euo pipefail

CHECK_ONLY=false
FIX_SIZE=false
SCALE_UP=false
TARGET_DIR=""
JOBS=$(nproc 2>/dev/null || echo 4)

usage() {
    sed -n '3,18p' "$0" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=true; shift ;;
        --fix-size) FIX_SIZE=true; shift ;;
        --scale-up) SCALE_UP=true; shift ;;
        --help|-h) usage ;;
        -*) echo "Error: Unknown option '$1'"; usage ;;
        *)
            if [[ -z "$TARGET_DIR" ]]; then
                TARGET_DIR="$1"
            else
                echo "Error: Multiple targets specified"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET_DIR" ]]; then
    echo "Error: No directory or file specified"
    usage
fi

if [[ ! -d "$TARGET_DIR" && ! -f "$TARGET_DIR" ]]; then
    echo "Error: '$TARGET_DIR' is not a file or directory"
    exit 1
fi

# Check dependencies
for cmd in xmllint scour; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is not installed"
        exit 1
    fi
done

if [[ "$SCALE_UP" == true ]] && ! command -v inkscape &>/dev/null; then
    echo "Error: 'inkscape' is required for --scale-up"
    exit 1
fi

# Collect SVG files
if [[ -f "$TARGET_DIR" ]]; then
    if [[ "$TARGET_DIR" != *.svg ]]; then
        echo "Error: '$TARGET_DIR' is not an SVG file"
        exit 1
    fi
    SVG_FILES=("$TARGET_DIR")
else
    mapfile -t SVG_FILES < <(find "$TARGET_DIR" -type f -name '*.svg' | sort)
fi
TOTAL=${#SVG_FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
    echo "No SVG files found in '$TARGET_DIR'"
    exit 0
fi

echo "Found $TOTAL SVG file(s) in '$TARGET_DIR'"

# Extract target icon size from a file path (e.g. .../status/16/foo.svg -> 16)
get_target_size() {
    echo "$1" | grep -oP '/\K\d+(?=/)' | tail -1
}

# Phase 1: XML validation
echo ""
echo "=== Validating XML ==="
ERROR_COUNT=0
ERROR_LOG=$(mktemp)

for svg in "${SVG_FILES[@]}"; do
    errors=$(xmllint --noout "$svg" 2>&1)
    if [[ -n "$errors" ]]; then
        echo "$errors" >> "$ERROR_LOG"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

if [[ $ERROR_COUNT -gt 0 ]]; then
    echo "ERRORS: $ERROR_COUNT file(s) with XML errors:"
    echo ""
    cat "$ERROR_LOG"
    echo ""
    if [[ "$CHECK_ONLY" == false ]]; then
        echo "Fix XML errors before cleaning. Skipping files with errors during clean."
    fi
else
    echo "All $TOTAL files passed XML validation."
fi
rm -f "$ERROR_LOG"

if [[ "$CHECK_ONLY" == true ]]; then
    echo ""
    echo "=== Check complete ==="
    echo "Total: $TOTAL files, $ERROR_COUNT error(s)"
    exit $( (( ERROR_COUNT > 0 )) && echo 1 || echo 0 )
fi

# Phase 2: Fix SVG dimensions (--fix-size)
if [[ "$FIX_SIZE" == true ]]; then
    echo ""
    echo "=== Fixing SVG dimensions ==="

    FIX_RESULT=$(python3 - "${SVG_FILES[@]}" << 'PYEOF'
import re, sys, os

def get_target_size(path):
    """Extract target size from path like .../status/16/foo.svg"""
    m = re.findall(r'/(\d+)/', path)
    return int(m[-1]) if m else None

def fix_svg(svg_file, target):
    t = str(target)
    with open(svg_file, 'r') as f:
        content = f.read()
    original = content

    # Remove invisible rects and ellipses (self-closing, single-line)
    content = re.sub(
        r'[ \t]*<(rect|ellipse)\b[^>]*\b(?:fill-)?opacity="0"[^>]*/>\s*\n?',
        '', content)

    # Find the <svg ...> opening tag (may span multiple lines)
    svg_m = re.search(r'(<svg\b)([\s\S]*?)(>)', content)
    if not svg_m:
        if content != original:
            with open(svg_file, 'w') as f:
                f.write(content)
            return "cleaned"
        return None

    attrs = svg_m.group(2)
    w_m = re.search(r'\bwidth="([^"]*)"', attrs)
    h_m = re.search(r'\bheight="([^"]*)"', attrs)
    vb_m = re.search(r'\bviewBox="([^"]*)"', attrs)

    cur_w = w_m.group(1) if w_m else None
    cur_h = h_m.group(1) if h_m else None

    # Already correct?
    if cur_w == t and cur_h == t:
        if content != original:
            with open(svg_file, 'w') as f:
                f.write(content)
            return "cleaned"
        return None

    new_attrs = attrs

    # If no viewBox exists, add one using the original dimensions
    if not vb_m and cur_w and cur_h:
        try:
            vb_w = int(round(float(cur_w)))
            vb_h = int(round(float(cur_h)))
            new_attrs = new_attrs.replace(
                w_m.group(0),
                f'viewBox="0 0 {vb_w} {vb_h}" width="{t}"')
        except ValueError:
            new_attrs = new_attrs.replace(w_m.group(0), f'width="{t}"')
    elif w_m:
        new_attrs = new_attrs.replace(w_m.group(0), f'width="{t}"')

    # Fix height
    if h_m:
        new_attrs = new_attrs.replace(h_m.group(0), f'height="{t}"')
    else:
        new_attrs += f' height="{t}"'

    # Add width if it was missing
    if not w_m:
        new_attrs = f' width="{t}"' + new_attrs

    content = content[:svg_m.start(2)] + new_attrs + content[svg_m.end(2):]

    with open(svg_file, 'w') as f:
        f.write(content)

    old = f"{cur_w}x{cur_h}" if cur_w and cur_h else "missing"
    return f"size {old} -> {t}x{t}"

count = 0
for svg_file in sys.argv[1:]:
    target = get_target_size(svg_file)
    if not target:
        continue
    result = fix_svg(svg_file, target)
    if result:
        name = os.path.basename(svg_file)
        print(f"  FIXED ({result}): {name}", flush=True)
        count += 1

print(f"\n  Fixed {count} file(s)")
PYEOF
    )
    echo "$FIX_RESULT"
fi

# Phase 3: Scale up undersized drawings (--scale-up)
if [[ "$SCALE_UP" == true ]]; then
    echo ""
    echo "=== Scaling up undersized drawings ==="

    SCALE_RESULT=$(python3 - "${SVG_FILES[@]}" << 'PYEOF'
import re, sys, os, subprocess

def get_target_size(path):
    m = re.findall(r'/(\d+)/', path)
    return int(m[-1]) if m else None

def get_drawing_bbox(svg_file):
    """Query inkscape for the drawing bounding box (in user units)."""
    try:
        r = subprocess.run(
            ['inkscape', '--query-all', svg_file],
            capture_output=True, text=True, timeout=30)
        if r.returncode != 0 or not r.stdout.strip():
            return None
        first = r.stdout.strip().split('\n')[0]
        parts = first.split(',')
        if len(parts) < 5:
            return None
        return tuple(float(p) for p in parts[1:5])
    except Exception:
        return None

def scale_up(svg_file, target):
    bbox = get_drawing_bbox(svg_file)
    if not bbox:
        return None

    # Inkscape reports bbox in display pixels
    dx, dy, dw, dh = bbox
    max_dim = max(dw, dh)

    # Only scale if drawing is significantly smaller than target
    if max_dim >= target - 1:
        return None

    with open(svg_file, 'r') as f:
        content = f.read()

    svg_m = re.search(r'(<svg\b)([\s\S]*?)(>)', content)
    if not svg_m:
        return None

    attrs = svg_m.group(2)
    w_m = re.search(r'\bwidth="([^"]*)"', attrs)
    h_m = re.search(r'\bheight="([^"]*)"', attrs)
    vb_m = re.search(r'viewBox="([^"]*)"', attrs)

    svg_w = float(w_m.group(1)) if w_m else target
    svg_h = float(h_m.group(1)) if h_m else target

    # Convert display-pixel bbox to viewBox coordinates
    if vb_m:
        vb_parts = vb_m.group(1).split()
        vb_x, vb_y = float(vb_parts[0]), float(vb_parts[1])
        vb_w, vb_h = float(vb_parts[2]), float(vb_parts[3])
        scale_x = vb_w / svg_w
        scale_y = vb_h / svg_h
        real_x = vb_x + dx * scale_x
        real_y = vb_y + dy * scale_y
        real_w = dw * scale_x
        real_h = dh * scale_y
    else:
        # No viewBox: display pixels = coordinate system
        real_x, real_y, real_w, real_h = dx, dy, dw, dh

    # Round near-zero values and use reasonable precision
    def fmt(v):
        return "0" if abs(v) < 0.001 else f"{v:.4g}"
    new_vb = f"{fmt(real_x)} {fmt(real_y)} {fmt(real_w)} {fmt(real_h)}"

    if vb_m:
        new_attrs = attrs.replace(vb_m.group(0), f'viewBox="{new_vb}"')
    else:
        new_attrs = f' viewBox="{new_vb}"' + attrs

    content = content[:svg_m.start(2)] + new_attrs + content[svg_m.end(2):]

    with open(svg_file, 'w') as f:
        f.write(content)

    return real_w, real_h

count = 0
files = sys.argv[1:]
for i, svg_file in enumerate(files):
    target = get_target_size(svg_file)
    if not target:
        continue

    result = scale_up(svg_file, target)
    if result:
        dw, dh = result
        name = os.path.basename(svg_file)
        print(f"  SCALED ({dw:.1f}x{dh:.1f} -> fill {target}): {name}", flush=True)
        count += 1

    if (i + 1) % 100 == 0:
        print(f"  Processed {i + 1} / {len(files)} files...", flush=True)

print(f"\n  Scaled {count} file(s)")
PYEOF
    )
    echo "$SCALE_RESULT"
fi

# Phase 4: Clean with scour
echo ""
echo "=== Cleaning SVGs with scour ==="

CLEANED=0
SKIPPED=0
SIZE_BEFORE=0
SIZE_AFTER=0

fix_xml_errors() {
    local svg="$1"
    # Only strip namespace-prefixed attributes when the namespace is NOT declared in the file.
    # This avoids breaking xlink:href in files that properly declare xmlns:xlink, etc.
    local prefixes=(inkscape sodipodi sketch xlink osb)
    for prefix in "${prefixes[@]}"; do
        if ! grep -q "xmlns:${prefix}=" "$svg"; then
            sed -i -E \
                -e "s/ ${prefix}:[a-zA-Z_-]+=\"[^\"]*\"//g" \
                -e "s/ ${prefix}:[a-zA-Z_-]+='[^']*'//g" \
                "$svg"
        fi
    done
}

clean_svg() {
    local svg="$1"
    local tmp="${svg}.scour.tmp"

    # Always strip orphaned namespace-prefixed attributes before scour
    # (xmllint may not fail on these, but scour's expat parser will)
    fix_xml_errors "$svg"

    # Skip files with remaining XML errors
    local errors
    errors=$(xmllint --noout "$svg" 2>&1)
    if [[ -n "$errors" ]]; then
        echo "SKIP (xml error): $svg"
        return 1
    fi

    local before
    before=$(stat -c%s "$svg")

    if scour -i "$svg" -o "$tmp" \
        --remove-descriptive-elements \
        --enable-comment-stripping \
        --strip-xml-prolog \
        --enable-id-stripping \
        --protect-ids-prefix="current-" \
        --indent=none \
        --quiet 2>/dev/null; then

        local after
        after=$(stat -c%s "$tmp")
        mv "$tmp" "$svg"
        echo "$before $after"
    else
        rm -f "$tmp"
        echo "FAIL: $svg" >&2
        return 1
    fi
}

for svg in "${SVG_FILES[@]}"; do
    result=$(clean_svg "$svg" 2>&1) || { SKIPPED=$((SKIPPED + 1)); continue; }

    before=$(echo "$result" | awk '{print $1}')
    after=$(echo "$result" | awk '{print $2}')
    SIZE_BEFORE=$((SIZE_BEFORE + before))
    SIZE_AFTER=$((SIZE_AFTER + after))
    CLEANED=$((CLEANED + 1))

    # Progress indicator every 100 files
    if (( CLEANED % 100 == 0 )); then
        echo "  Processed $CLEANED / $TOTAL files..."
    fi
done

SAVED=$((SIZE_BEFORE - SIZE_AFTER))

human_size() {
    local bytes=$1
    if (( bytes >= 1048576 )); then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB"
    elif (( bytes >= 1024 )); then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}") KB"
    else
        echo "${bytes} B"
    fi
}

echo ""
echo "=== Done ==="
echo "Total files:  $TOTAL"
echo "Cleaned:      $CLEANED"
echo "Skipped:      $SKIPPED"
echo "Size before:  $(human_size $SIZE_BEFORE)"
echo "Size after:   $(human_size $SIZE_AFTER)"
echo "Saved:        $(human_size $SAVED)"
