#!/bin/bash
# LMF4.1 System Test — verifies install, mem CLI, hooks, library, systemd.
# Set LMF4_DIR env var to the checkout location, or we infer from this script.
set -euo pipefail

# Resolve LMF4_DIR from the script location if not given
LMF4_DIR="${LMF4_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/bin:$HOME/.local/bin:$PATH"

FAILS=0
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }
pass() { echo "  PASS: $1"; }

echo "============================================"
echo " LMF4.1 SYSTEM TEST"
echo " LMF4_DIR=$LMF4_DIR"
echo " $(date -Iseconds)"
echo "============================================"

# ─── Ensure LMF4 is installed ─────────────────────────────
echo ""
echo "=== INSTALL ==="
if [ ! -x "$HOME/bin/mem" ] || [ ! -f "$HOME/.claude/hooks/SessionExtract.hook.ts" ]; then
    echo "LMF4 not fully installed — running $LMF4_DIR/install..."
    bash "$LMF4_DIR/install"
else
    echo "LMF4 appears installed (mem present + SessionExtract hook present)."
fi

# ─── DB schema / FTS triggers ────────────────────────────
echo ""
echo "=== DB TESTS ==="

echo ""
echo "--- TEST 1: FTS trigger fires on decision insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO decisions (decision, reasoning) VALUES (?, ?)").run("test decision alpha", "test reasoning beta");
const fts = db.prepare("SELECT * FROM decisions_fts WHERE decisions_fts MATCH ?").all("alpha");
db.close();
if (fts.length === 1) { console.log("OK"); process.exit(0); }
else { console.log("FAIL: expected 1, got " + fts.length); process.exit(1); }
' >/dev/null && pass "decisions FTS trigger" || fail "decisions FTS trigger"

echo ""
echo "--- TEST 2: FTS trigger fires on loa_entries insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO loa_entries (title, fabric_extract) VALUES (?, ?)").run("test session gamma", "extracted content delta");
const fts = db.prepare("SELECT * FROM loa_fts WHERE loa_fts MATCH ?").all("gamma");
db.close();
if (fts.length === 1) { console.log("OK"); process.exit(0); }
else { console.log("FAIL: got " + fts.length); process.exit(1); }
' >/dev/null && pass "loa_entries FTS trigger" || fail "loa_entries FTS trigger"

echo ""
echo "--- TEST 3: FTS trigger fires on errors insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO errors (error, fix) VALUES (?, ?)").run("test error epsilon", "test fix zeta");
const fts = db.prepare("SELECT * FROM errors_fts WHERE errors_fts MATCH ?").all("epsilon");
db.close();
if (fts.length === 1) { console.log("OK"); process.exit(0); }
else { console.log("FAIL: got " + fts.length); process.exit(1); }
' >/dev/null && pass "errors FTS trigger" || fail "errors FTS trigger"

echo ""
echo "--- TEST 4: FTS trigger fires on learnings insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO learnings (problem, solution) VALUES (?, ?)").run("test problem eta", "test solution theta");
const fts = db.prepare("SELECT * FROM learnings_fts WHERE learnings_fts MATCH ?").all("eta");
db.close();
if (fts.length === 1) { console.log("OK"); process.exit(0); }
else { console.log("FAIL: got " + fts.length); process.exit(1); }
' >/dev/null && pass "learnings FTS trigger" || fail "learnings FTS trigger"

# ─── mem CLI subcommands ──────────────────────────────────
echo ""
echo "=== MEM CLI TESTS ==="

for sub in search recent stats dump loa; do
    echo ""
    echo "--- TEST mem $sub --help runs ---"
    if "$HOME/bin/mem" "$sub" --help >/dev/null 2>&1; then
        pass "mem $sub --help"
    else
        # Some subcommands (loa, embed) are groups; try bare list instead
        if "$HOME/bin/mem" "$sub" >/dev/null 2>&1; then
            pass "mem $sub (group)"
        else
            fail "mem $sub doesn't respond"
        fi
    fi
done

echo ""
echo "--- TEST mem search finds FTS data ---"
RESULT=$("$HOME/bin/mem" search "alpha" 2>&1 || true)
if echo "$RESULT" | grep -qi "alpha"; then
    pass "mem search returns FTS results"
else
    fail "mem search can't find inserted data"
fi

echo ""
echo "--- TEST mem stats runs and shows counts ---"
if "$HOME/bin/mem" stats 2>&1 | grep -qE "sessions|messages|decisions"; then
    pass "mem stats"
else
    fail "mem stats missing expected output"
fi

echo ""
echo "--- TEST mem catchup command exists ---"
if "$HOME/bin/mem" catchup --help >/dev/null 2>&1; then
    pass "mem catchup wired"
else
    fail "mem catchup missing"
fi

# ─── MCP server ───────────────────────────────────────────
echo ""
echo "=== MCP TESTS ==="

echo ""
echo "--- TEST MCP memory_search returns results ---"
MCP_SEARCH=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"alpha"}}}\n' | timeout 5 bun run "$HOME/.claude/hooks/mem-mcp-server.ts" 2>/dev/null | tail -1)
if echo "$MCP_SEARCH" | grep -q "alpha"; then
    pass "MCP memory_search"
else
    fail "MCP memory_search empty"
fi

echo ""
echo "--- TEST MCP memory_recall returns recent ---"
MCP_RECALL=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"count":3}}}\n' | timeout 5 bun run "$HOME/.claude/hooks/mem-mcp-server.ts" 2>/dev/null | tail -1)
if echo "$MCP_RECALL" | grep -q "gamma"; then
    pass "MCP memory_recall"
else
    fail "MCP memory_recall empty"
fi

# ─── Hooks ────────────────────────────────────────────────
echo ""
echo "=== HOOK TESTS ==="

echo ""
echo "--- TEST AssociativeRecall runs without crash ---"
RECALL_OUT=$(echo '{"content":"tell me about kubernetes"}' | timeout 5 bun run "$HOME/.claude/hooks/AssociativeRecall.hook.ts" 2>/dev/null || echo "ERROR")
if [ "$RECALL_OUT" != "ERROR" ]; then
    pass "AssociativeRecall runs"
else
    fail "AssociativeRecall crashed"
fi

echo ""
echo "--- TEST SessionExtract --batch runs without crash ---"
EXTRACT_OUT=$(timeout 10 bun run "$HOME/.claude/hooks/SessionExtract.hook.ts" --batch 2>&1 || echo "CRASHED")
if echo "$EXTRACT_OUT" | grep -qiE "cannot find|syntax error|unhandled"; then
    fail "SessionExtract --batch crashed: $(echo "$EXTRACT_OUT" | head -c 200)"
else
    pass "SessionExtract --batch runs"
fi

echo ""
echo "--- TEST PreCompact runs without crash ---"
PRECOMPACT_OUT=$(echo '{"cwd":"'"$HOME"'"}' | timeout 5 bash "$HOME/.claude/hooks/PreCompact.hook.sh" 2>&1 || echo "CRASHED")
if [ "$PRECOMPACT_OUT" = "CRASHED" ]; then
    fail "PreCompact crashed"
else
    pass "PreCompact runs"
fi

# ─── Library ──────────────────────────────────────────────
echo ""
echo "=== LIBRARY TESTS ==="

echo ""
echo "--- TEST library/ tree present ---"
if [ -d "$LMF4_DIR/library/_canonical" ] && [ -x "$LMF4_DIR/library/bin/promote.sh" ]; then
    pass "library tree + promote.sh present and executable"
else
    fail "library tree incomplete"
fi

echo ""
echo "--- TEST promote.sh copies + indexes ---"
TESTMEMO=$(mktemp --suffix=.md)
cat > "$TESTMEMO" <<'TEOF'
# Test promotion memo
A short test entry used by system-test.sh.
TEOF
bash "$LMF4_DIR/library/bin/promote.sh" "$TESTMEMO" >/dev/null 2>&1
PROMOTED_BASENAME=$(basename "$TESTMEMO")
if [ -f "$HOME/.claude/LIBRARY/_canonical/$PROMOTED_BASENAME" ] && \
   grep -q "(_canonical/$PROMOTED_BASENAME)" "$HOME/.claude/LIBRARY/MEMORY.md"; then
    pass "promote.sh copies + indexes"
    # Cleanup
    rm -f "$HOME/.claude/LIBRARY/_canonical/$PROMOTED_BASENAME"
    grep -v "(_canonical/$PROMOTED_BASENAME)" "$HOME/.claude/LIBRARY/MEMORY.md" > "$HOME/.claude/LIBRARY/MEMORY.md.tmp" && mv "$HOME/.claude/LIBRARY/MEMORY.md.tmp" "$HOME/.claude/LIBRARY/MEMORY.md"
else
    fail "promote.sh didn't copy or index"
fi
rm -f "$TESTMEMO"

# ─── systemd ──────────────────────────────────────────────
echo ""
echo "=== SYSTEMD TESTS ==="

echo ""
echo "--- TEST systemd timer units exist ---"
if [ -f "$HOME/.config/systemd/user/memory-catchup.timer" ] && \
   [ -f "$HOME/.config/systemd/user/memory-backup.timer" ]; then
    pass "memory-catchup.timer + memory-backup.timer present"
else
    fail "timer units missing"
fi

echo ""
echo "--- TEST systemd timers scheduled (may be skipped outside user session) ---"
TIMER_COUNT=$(systemctl --user list-timers 2>/dev/null | grep -c memory || true)
if [ "$TIMER_COUNT" -ge 1 ]; then
    pass "$TIMER_COUNT memory timer(s) scheduled"
else
    echo "  SKIP: timers not scheduled (may need 'systemctl --user daemon-reload')"
fi

# ─── settings.json ────────────────────────────────────────
echo ""
echo "=== SETTINGS.JSON TESTS ==="

echo ""
echo "--- TEST hooks use matcher+hooks format ---"
HOOK_VALID=$(python3 -c "
import json, sys
s = json.load(open('$HOME/.claude/settings.json'))
for event, matchers in s.get('hooks', {}).items():
    for m in matchers:
        if 'hooks' not in m:
            print('INVALID: ' + event); sys.exit(1)
print('VALID')
" 2>&1)
if [ "$HOOK_VALID" = "VALID" ]; then
    pass "hook format valid"
else
    fail "hook format: $HOOK_VALID"
fi

echo ""
echo "--- TEST SessionExtract (not FabricExtract) wired on Stop ---"
if grep -q 'SessionExtract' "$HOME/.claude/settings.json" 2>/dev/null; then
    pass "SessionExtract hook wired"
else
    fail "SessionExtract not found in settings.json"
fi

# ─── Sanitization sanity ──────────────────────────────────
echo ""
echo "=== SANITIZATION SCAN ==="
echo ""
echo "--- TEST no personal data in repo ---"
LEAK=$(cd "$LMF4_DIR" && git grep -iE '\b(larry|blueally|monolith|100\.95\.128)\b' -- ':!tests/system-test.sh' || true)
if [ -z "$LEAK" ]; then
    pass "no personal-data leak in tracked files"
else
    fail "personal-data leak: $LEAK"
fi

# ─── SUMMARY ──────────────────────────────────────────────
echo ""
echo "============================================"
echo " RESULTS: $FAILS failure(s)"
echo "============================================"
exit $FAILS
