#!/usr/bin/env bash
# promote.sh — promote a memory file to canonical status in the LMF4 Library.
#
# Usage: promote.sh PATH_TO_MEMO.md
#
# Copies the memo into $HOME/.claude/LIBRARY/_canonical/ and appends an
# entry to $HOME/.claude/LIBRARY/MEMORY.md (the canonical index). Idempotent
# — running twice on the same file is harmless.

set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ]; then
    echo "Usage: $0 PATH_TO_MEMO.md" >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "Not found: $SRC" >&2
    exit 1
fi

DEST_DIR="$HOME/.claude/LIBRARY/_canonical"
INDEX="$HOME/.claude/LIBRARY/MEMORY.md"

mkdir -p "$DEST_DIR"

BASENAME=$(basename "$SRC")
cp "$SRC" "$DEST_DIR/$BASENAME"
echo "Promoted: $BASENAME -> $DEST_DIR/"

# Ensure index exists
if [ ! -f "$INDEX" ]; then
    cat > "$INDEX" <<'EOF'
# Canonical Memory Index

These are memories the human has promoted from the session-extraction
pipeline into canonical status. Load this file at session start — every
entry here is something the AI must not forget.

EOF
fi

# Append index entry if not already present
STEM="${BASENAME%.md}"
if ! grep -q "(_canonical/$BASENAME)" "$INDEX" 2>/dev/null; then
    # Try to pull a headline from the file (first non-empty, non-# line)
    HEADLINE=$(grep -vE '^\s*#|^\s*$' "$SRC" 2>/dev/null | head -1 | sed -e 's/^\s*[*-]\s*//' -e 's/[`_*]//g' | cut -c1-80)
    HEADLINE="${HEADLINE:-no summary}"
    DATE=$(date +%Y-%m-%d)
    echo "- [$STEM](_canonical/$BASENAME) — $HEADLINE _(promoted $DATE)_" >> "$INDEX"
    echo "Indexed in $INDEX"
else
    echo "(already indexed)"
fi
