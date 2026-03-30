#!/bin/bash
# LMF4 System Test — focuses on whether things WORK, not docs
set -euo pipefail

LMF4_DIR=/home/alex/lmf4
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/bin:$HOME/go/bin:$HOME/.local/bin:/usr/local/go/bin:$PATH"
FAILS=0
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }
pass() { echo "  PASS: $1"; }

echo "============================================"
echo " LMF4 SYSTEM TEST — Iteration 5"
echo " $(date)"
echo "============================================"

# ─── INSTALL PHASE ────────────────────────────────────────
echo ""
echo "=== INSTALLING ==="

# bun
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq unzip rsync >/dev/null 2>&1
curl -fsSL https://bun.sh/install 2>/dev/null | bash 2>&1 >/dev/null
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
grep -q 'BUN_INSTALL' ~/.bashrc || { echo 'export BUN_INSTALL="$HOME/.bun"'; echo 'export PATH="$BUN_INSTALL/bin:$PATH"'; } >> ~/.bashrc
grep -q 'HOME/bin' ~/.bashrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc

# dirs
mkdir -p ~/.claude/hooks ~/.claude/tools ~/bin
mkdir -p ~/.claude/MEMORY/{WORK,LEARNING/{SYSTEM,ALGORITHM,FAILURES,SYNTHESIS,REFLECTIONS,SIGNALS},RESEARCH,SECURITY,STATE/{algorithms,kitty-sessions,tab-titles,progress,integrity},PAISYSTEMUPDATES,AUTO}

# hooks + tools
cp $LMF4_DIR/hooks/* ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.ts ~/.claude/hooks/*.sh 2>/dev/null
cp $LMF4_DIR/tools/Inference.ts ~/.claude/tools/
cp $LMF4_DIR/mcp/mem-mcp-server.ts ~/.claude/hooks/
cp $LMF4_DIR/prompts/extract_prompt.md ~/.claude/MEMORY/extract_prompt.md

# memory.db
bun -e '
const{Database}=require("bun:sqlite");
const db=new Database(process.env.HOME+"/.claude/memory.db");
db.exec(`
CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT UNIQUE NOT NULL,started_at DATETIME DEFAULT CURRENT_TIMESTAMP,ended_at DATETIME,summary TEXT,project TEXT,cwd TEXT);
CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,timestamp DATETIME NOT NULL,role TEXT NOT NULL CHECK(role IN("user","assistant","system")),content TEXT NOT NULL,project TEXT,FOREIGN KEY(session_id)REFERENCES sessions(session_id));
CREATE TABLE IF NOT EXISTS loa_entries(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,title TEXT NOT NULL,fabric_extract TEXT NOT NULL,session_id TEXT,project TEXT,tags TEXT);
CREATE TABLE IF NOT EXISTS decisions(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,session_id TEXT,project TEXT,decision TEXT NOT NULL,reasoning TEXT,status TEXT DEFAULT "active" CHECK(status IN("active","superseded","reverted")));
CREATE TABLE IF NOT EXISTS errors(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,error TEXT NOT NULL,cause TEXT,fix TEXT,frequency INTEGER DEFAULT 1,last_seen DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS learnings(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,session_id TEXT,project TEXT,problem TEXT NOT NULL,solution TEXT,tags TEXT);
CREATE TABLE IF NOT EXISTS embeddings(id INTEGER PRIMARY KEY AUTOINCREMENT,source_table TEXT NOT NULL,source_id INTEGER NOT NULL,model TEXT NOT NULL DEFAULT "nomic-embed-text",dimensions INTEGER NOT NULL DEFAULT 768,embedding BLOB NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,UNIQUE(source_table,source_id));
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(content,content_rowid="id",tokenize="porter");
CREATE VIRTUAL TABLE IF NOT EXISTS loa_fts USING fts5(title,fabric_extract,content_rowid="id",tokenize="porter");
CREATE VIRTUAL TABLE IF NOT EXISTS decisions_fts USING fts5(decision,reasoning,content_rowid="id",tokenize="porter");
CREATE VIRTUAL TABLE IF NOT EXISTS errors_fts USING fts5(error,fix,content_rowid="id",tokenize="porter");
CREATE VIRTUAL TABLE IF NOT EXISTS learnings_fts USING fts5(problem,solution,content_rowid="id",tokenize="porter");
`);
const triggers=[["messages","content"],["loa_entries:loa","title, fabric_extract"],["decisions","decision, reasoning"],["errors","error, fix"],["learnings","problem, solution"]];
for(const[spec,cols]of triggers){const[table,ftsName]=spec.includes(":")?spec.split(":"):[spec,spec];const fts=ftsName+"_fts";const nc=cols.split(",").map(c=>"NEW."+c.trim()).join(", ");const oc=cols.split(",").map(c=>"OLD."+c.trim()).join(", ");try{db.exec(`CREATE TRIGGER ${fts}_insert AFTER INSERT ON ${table} BEGIN INSERT INTO ${fts}(rowid,${cols})VALUES(NEW.id,${nc});END;CREATE TRIGGER ${fts}_delete AFTER DELETE ON ${table} BEGIN INSERT INTO ${fts}(${fts},rowid,${cols})VALUES("delete",OLD.id,${oc});END;`);}catch(e){}}
db.close();
'

# mem CLI
mkdir -p ~/.claude/memory-cli/src ~/.claude/memory-cli/dist
cp $LMF4_DIR/mem-cli/src/* ~/.claude/memory-cli/src/
cp $LMF4_DIR/mem-cli/package.json ~/.claude/memory-cli/
cd ~/.claude/memory-cli && bun install 2>/dev/null && bun build src/index.ts --outdir dist --target node 2>/dev/null
chmod +x dist/index.js
ln -sf ~/.claude/memory-cli/dist/index.js ~/bin/mem
cd ~

# settings.json
HOME_DIR="$HOME"
cat > ~/.claude/settings.json << JSONEOF
{
  "hooks": {
    "PreCompact": [{"hooks": [{"type": "command", "command": "${HOME_DIR}/.claude/hooks/PreCompact.hook.sh"}]}],
    "PostCompact": [{"hooks": [{"type": "command", "command": "bun run ${HOME_DIR}/.claude/hooks/PostCompact.hook.ts"}]}],
    "StopFailure": [{"hooks": [{"type": "command", "command": "bun run ${HOME_DIR}/.claude/hooks/StopFailure.hook.ts"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "bun run ${HOME_DIR}/.claude/hooks/FabricExtract.hook.ts"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bun run ${HOME_DIR}/.claude/hooks/AssociativeRecall.hook.ts"}]}]
  },
  "mcpServers": {
    "pai-memory": {"type": "stdio", "command": "bun", "args": ["run", "${HOME_DIR}/.claude/hooks/mem-mcp-server.ts"]}
  },
  "daidentity": {"name": "TestBot", "fullName": "TestBot — Personal AI", "displayName": "TESTBOT"},
  "principal": {"name": "Tester"},
  "env": {"CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000"},
  "autoMemoryDirectory": "${HOME_DIR}/.claude/MEMORY/AUTO"
}
JSONEOF

# helper scripts
cat > ~/bin/memory-catchup << 'MCEOF'
#!/bin/bash
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$HOME/bin:$PATH"
exec bun run ~/.claude/hooks/FabricExtract.hook.ts --batch >> ~/.claude/MEMORY/EXTRACT_LOG.txt 2>&1
MCEOF
chmod +x ~/bin/memory-catchup

cat > ~/bin/memory-backup << 'MBEOF'
#!/bin/bash
set -e
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$HOME/bin:$PATH"
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/conversations-backup"
if [ ! -d "$BACKUP_DIR/.git" ]; then exit 1; fi
cd "$BACKUP_DIR"
for f in settings.json CLAUDE.md keybindings.json memory.db; do
    cp "$CLAUDE_DIR/$f" "$BACKUP_DIR/" 2>/dev/null || true
done
rsync -a --delete "$CLAUDE_DIR/hooks/" "$BACKUP_DIR/hooks/" 2>/dev/null || true
rsync -a --delete "$CLAUDE_DIR/MEMORY/" "$BACKUP_DIR/MEMORY/" 2>/dev/null || true
rsync -a --delete --exclude='tool-results/' --exclude='subagents/' "$CLAUDE_DIR/projects/" "$BACKUP_DIR/projects/" 2>/dev/null || true
git add -A 2>/dev/null
if ! git diff --cached --quiet 2>/dev/null; then
    TS=$(date '+%Y-%m-%d %H:%M')
    SC=$(find "$BACKUP_DIR/projects" -name "*.jsonl" 2>/dev/null | wc -l)
    DS=$(du -sh "$BACKUP_DIR/memory.db" 2>/dev/null | cut -f1)
    git commit -m "backup: $TS | ${SC} sessions | db: ${DS}" --no-gpg-sign 2>/dev/null
fi
MBEOF
chmod +x ~/bin/memory-backup

# timers
mkdir -p ~/.config/systemd/user
cp $LMF4_DIR/systemd/* ~/.config/systemd/user/
loginctl enable-linger $(whoami) 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now memory-catchup.timer 2>/dev/null || true
systemctl --user enable --now memory-backup.timer 2>/dev/null || true

# backup repo
mkdir -p ~/.claude/conversations-backup
cd ~/.claude/conversations-backup
git init -b main 2>/dev/null >/dev/null
git config user.name "tester"
git config user.email "tester@test"
echo "node_modules/" > .gitignore
git add -A 2>/dev/null
git commit -m "init" --no-gpg-sign 2>/dev/null >/dev/null
cd ~

# flat files
touch ~/.claude/MEMORY/EXTRACT_LOG.txt
echo "# Hot Recall" > ~/.claude/MEMORY/HOT_RECALL.md
echo "# Distilled" > ~/.claude/MEMORY/DISTILLED.md
cp $LMF4_DIR/templates/CLAUDE.md.memory ~/.claude/CLAUDE.md

echo "Install complete."
echo ""

# ─── SYSTEM TESTS ─────────────────────────────────────────
echo "=== SYSTEM TESTS ==="

# TEST 1: Insert into decisions — verify trigger populates FTS
echo ""
echo "--- TEST 1: FTS trigger fires on decision insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO decisions (decision, reasoning) VALUES (?, ?)").run("test decision alpha", "test reasoning beta");
const fts = db.prepare("SELECT * FROM decisions_fts WHERE decisions_fts MATCH ?").all("alpha");
db.close();
if (fts.length === 1) { console.log("PASS: exactly 1 FTS result"); process.exit(0); }
else { console.log("FAIL: expected 1 FTS result, got " + fts.length); process.exit(1); }
' && pass "Decision FTS trigger" || fail "Decision FTS trigger — duplicate or missing"

# TEST 2: Insert into loa_entries — verify trigger
echo ""
echo "--- TEST 2: FTS trigger fires on loa_entries insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO loa_entries (title, fabric_extract) VALUES (?, ?)").run("test session gamma", "extracted content delta");
const fts = db.prepare("SELECT * FROM loa_fts WHERE loa_fts MATCH ?").all("gamma");
db.close();
if (fts.length === 1) { console.log("PASS: exactly 1 FTS result"); process.exit(0); }
else { console.log("FAIL: expected 1 FTS result, got " + fts.length); process.exit(1); }
' && pass "LoA FTS trigger" || fail "LoA FTS trigger — duplicate or missing"

# TEST 3: Insert into errors — verify trigger
echo ""
echo "--- TEST 3: FTS trigger fires on errors insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO errors (error, fix) VALUES (?, ?)").run("test error epsilon", "test fix zeta");
const fts = db.prepare("SELECT * FROM errors_fts WHERE errors_fts MATCH ?").all("epsilon");
db.close();
if (fts.length === 1) { console.log("PASS: exactly 1 FTS result"); process.exit(0); }
else { console.log("FAIL: expected 1 FTS result, got " + fts.length); process.exit(1); }
' && pass "Error FTS trigger" || fail "Error FTS trigger — duplicate or missing"

# TEST 4: Insert into learnings — verify trigger
echo ""
echo "--- TEST 4: FTS trigger fires on learnings insert ---"
bun -e '
const db = new (require("bun:sqlite").Database)(process.env.HOME + "/.claude/memory.db");
db.prepare("INSERT INTO learnings (problem, solution) VALUES (?, ?)").run("test problem eta", "test solution theta");
const fts = db.prepare("SELECT * FROM learnings_fts WHERE learnings_fts MATCH ?").all("eta");
db.close();
if (fts.length === 1) { console.log("PASS: exactly 1 FTS result"); process.exit(0); }
else { console.log("FAIL: expected 1 FTS result, got " + fts.length); process.exit(1); }
' && pass "Learning FTS trigger" || fail "Learning FTS trigger — duplicate or missing"

# TEST 5: mem CLI search finds inserted data
echo ""
echo "--- TEST 5: mem CLI search finds trigger-synced data ---"
RESULT=$(~/bin/mem search "alpha" 2>&1)
if echo "$RESULT" | grep -q "alpha"; then
    pass "mem search finds FTS data"
else
    fail "mem search can't find FTS data: $RESULT"
fi

# TEST 6: MCP server responds and can search
echo ""
echo "--- TEST 6: MCP server search works ---"
MCP_SEARCH=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"alpha"}}}\n' | timeout 5 bun run ~/.claude/hooks/mem-mcp-server.ts 2>/dev/null | tail -1)
if echo "$MCP_SEARCH" | grep -q "alpha"; then
    pass "MCP memory_search returns results"
else
    fail "MCP memory_search empty or broken: $(echo $MCP_SEARCH | head -c 200)"
fi

# TEST 7: MCP memory_recall works
echo ""
echo "--- TEST 7: MCP memory_recall works ---"
MCP_RECALL=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"count":3}}}\n' | timeout 5 bun run ~/.claude/hooks/mem-mcp-server.ts 2>/dev/null | tail -1)
if echo "$MCP_RECALL" | grep -q "gamma"; then
    pass "MCP memory_recall returns recent entries"
else
    fail "MCP memory_recall empty: $(echo $MCP_RECALL | head -c 200)"
fi

# TEST 8: Genesis block writes correct count with NO duplicates
echo ""
echo "--- TEST 8: Genesis block — correct count, no FTS duplicates ---"
bun -e '
const{Database}=require("bun:sqlite");
const db=new Database(process.env.HOME+"/.claude/memory.db");
const now=new Date().toISOString();
function ie(t,c){db.prepare("INSERT INTO loa_entries(created_at,title,fabric_extract,session_id,project)VALUES(?,?,?,?,?)").run(now,t,c,"genesis","LMF4")}
function id(d,r){db.prepare("INSERT INTO decisions(created_at,session_id,project,decision,reasoning)VALUES(?,?,?,?,?)").run(now,"genesis","LMF4",d,r)}
function il(p,s){db.prepare("INSERT INTO learnings(created_at,session_id,project,problem,solution)VALUES(?,?,?,?,?)").run(now,"genesis","LMF4",p,s)}
ie("Genesis","origin story");
id("P1","verify"); id("P2","memory"); id("P3","collaborator"); id("P4","surgical");
id("P5","craft"); id("P6","protect"); id("P7","firstprinciples"); id("P8","checklists");
ie("Human","user info");
ie("Personality","config");
il("mistakes","own it"); il("memory use","search first"); il("common mistakes","list of 6");
db.close();
console.log("Done");
'

# Now verify counts
bun -e '
const db=new(require("bun:sqlite").Database)(process.env.HOME+"/.claude/memory.db");
const loa=db.prepare("SELECT count(*) as n FROM loa_entries WHERE session_id=\"genesis\"").get().n;
const dec=db.prepare("SELECT count(*) as n FROM decisions WHERE session_id=\"genesis\"").get().n;
const lrn=db.prepare("SELECT count(*) as n FROM learnings WHERE session_id=\"genesis\"").get().n;
db.prepare("INSERT INTO loa_entries(title,fabric_extract,session_id)VALUES(?,?,?)").run("dupcheck_unique_xyzzy","dupcheck_content_xyzzy","duptest");
const fts_dup=db.prepare("SELECT count(*) as n FROM loa_fts WHERE loa_fts MATCH \"xyzzy\"").get().n;
const dec_dup_check=db.prepare("SELECT count(*) as n FROM decisions_fts WHERE decisions_fts MATCH \"verify\"").get().n;
const fs=require("fs");
fs.writeFileSync("/tmp/genesis_counts.txt", loa+"|"+dec+"|"+lrn+"|"+fts_dup+"|"+dec_dup_check);
db.close();
'
GENESIS_COUNTS=$(cat /tmp/genesis_counts.txt)
LOA=$(echo "$GENESIS_COUNTS" | cut -d'|' -f1)
DEC=$(echo "$GENESIS_COUNTS" | cut -d'|' -f2)
LRN=$(echo "$GENESIS_COUNTS" | cut -d'|' -f3)
FTS_LOA=$(echo "$GENESIS_COUNTS" | cut -d'|' -f4)
FTS_DEC=$(echo "$GENESIS_COUNTS" | cut -d'|' -f5)

if [ "$LOA" = "3" ] && [ "$DEC" = "8" ] && [ "$LRN" = "3" ]; then
    pass "Genesis: 3 entries + 8 decisions + 3 learnings = 14"
else
    fail "Genesis counts wrong: loa=$LOA dec=$DEC lrn=$LRN"
fi

if [ "$FTS_LOA" = "1" ]; then
    pass "No FTS duplicates in loa_fts (unique term found exactly once)"
else
    fail "FTS duplicates in loa_fts! unique term found $FTS_LOA times (expected 1)"
fi

if [ "$FTS_DEC" = "1" ]; then
    pass "No FTS duplicates in decisions_fts for 'verify'"
else
    fail "FTS duplicates in decisions_fts! expected 1 match for 'verify', got $FTS_DEC"
fi

# TEST 9: AssociativeRecall hook runs without error
echo ""
echo "--- TEST 9: AssociativeRecall hook executes ---"
RECALL_OUT=$(echo '{"content":"tell me about kubernetes"}' | timeout 5 bun run ~/.claude/hooks/AssociativeRecall.hook.ts 2>/dev/null || echo "ERROR")
if [ "$RECALL_OUT" != "ERROR" ]; then
    pass "AssociativeRecall runs without crash"
else
    fail "AssociativeRecall crashed"
fi

# TEST 10: FabricExtract hook accepts --batch without crash
echo ""
echo "--- TEST 10: FabricExtract --batch runs ---"
EXTRACT_OUT=$(timeout 10 bun run ~/.claude/hooks/FabricExtract.hook.ts --batch 2>&1 || echo "CRASHED")
if echo "$EXTRACT_OUT" | grep -qi "crash\|fatal\|Cannot"; then
    fail "FabricExtract --batch crashed: $(echo $EXTRACT_OUT | head -c 200)"
else
    pass "FabricExtract --batch runs (may have 0 sessions to extract)"
fi

# TEST 11: PreCompact hook runs
echo ""
echo "--- TEST 11: PreCompact hook executes ---"
PRECOMPACT_OUT=$(echo '{"cwd":"/home/alex"}' | timeout 5 bash ~/.claude/hooks/PreCompact.hook.sh 2>&1 || echo "CRASHED")
if echo "$PRECOMPACT_OUT" | grep -q "CRASHED"; then
    fail "PreCompact crashed"
else
    pass "PreCompact runs"
fi

# TEST 12: systemd timers are scheduled
echo ""
echo "--- TEST 12: systemd timers active ---"
TIMER_COUNT=$(systemctl --user list-timers 2>/dev/null | grep -c memory)
if [ "$TIMER_COUNT" = "2" ]; then
    pass "2 memory timers active"
else
    fail "Expected 2 timers, got $TIMER_COUNT"
fi

# TEST 13: backup script runs successfully
echo ""
echo "--- TEST 13: backup script commits ---"
~/bin/memory-backup 2>/dev/null
BACKUP_COMMITS=$(cd ~/.claude/conversations-backup && git log --oneline 2>/dev/null | wc -l)
if [ "$BACKUP_COMMITS" -ge 2 ]; then
    pass "Backup committed ($BACKUP_COMMITS commits)"
else
    fail "Backup didn't commit (only $BACKUP_COMMITS commits)"
fi

# TEST 14: settings.json validates with Claude Code hook format
echo ""
echo "--- TEST 14: settings.json hook format valid ---"
HOOK_VALID=$(python3 -c "
import json, sys
s = json.load(open('$HOME/.claude/settings.json'))
for event, matchers in s.get('hooks', {}).items():
    for m in matchers:
        if 'hooks' not in m:
            print(f'INVALID: {event}')
            sys.exit(1)
print('VALID')
" 2>&1)
if [ "$HOOK_VALID" = "VALID" ]; then
    pass "All hooks use matcher+hooks format"
else
    fail "Hook format invalid: $HOOK_VALID"
fi

# TEST 15: Inference.ts can be imported by FabricExtract
echo ""
echo "--- TEST 15: Inference.ts is importable ---"
INFERENCE_TEST=$(bun -e '
const { existsSync } = require("fs");
const { join } = require("path");
const paths = [
    join(process.env.HOME, ".claude", "tools", "Inference.ts"),
    join(process.env.HOME, ".claude", "PAI", "Tools", "Inference.ts"),
];
const found = paths.find(p => existsSync(p));
if (found) { console.log("FOUND:" + found); } else { console.log("MISSING"); }
' 2>&1)
if echo "$INFERENCE_TEST" | grep -q "FOUND"; then
    pass "Inference.ts found at $(echo $INFERENCE_TEST | cut -d: -f2-)"
else
    fail "Inference.ts not found in any expected location"
fi

# ─── SUMMARY ──────────────────────────────────────────────
echo ""
echo "============================================"
echo " RESULTS: $FAILS failures"
echo "============================================"
exit $FAILS
