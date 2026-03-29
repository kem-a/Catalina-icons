#!/bin/bash
#
# cleanup-svgs.sh — Validate and optimize SVG files using xmllint and scour
#
# Usage:
#   ./cleanup-svgs.sh [OPTIONS] <directory|file.svg>
#
# Options:
#   --check    Validate XML only, do not modify files
#   --help     Show this help message
#
# Examples:
#   ./cleanup-svgs.sh Catalina-light/actions/22/
#   ./cleanup-svgs.sh --check Catalina-dark/
#   ./cleanup-svgs.sh Catalina-light/
#   ./cleanup-svgs.sh Catalina-light/apps/scalable/myapp.svg

set -euo pipefail

CHECK_ONLY=false
TARGET_DIR=""
JOBS=$(nproc 2>/dev/null || echo 4)

usage() {
    sed -n '3,14p' "$0" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=true; shift ;;
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

# Phase 2: Clean with scour
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
