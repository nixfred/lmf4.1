#!/bin/bash
set -euo pipefail

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/.claude/hooks" "$TEST_ROOT/.claude/projects/-tmp" "$TEST_ROOT/.claude/MEMORY"
cp "$(dirname "$0")/../hooks/SessionExtract.hook.ts" "$TEST_ROOT/.claude/hooks/"

TRANSCRIPT="$TEST_ROOT/.claude/projects/-tmp/short-session.jsonl"
printf '%s\n' '{"message":{"role":"user","content":"short message"}}' > "$TRANSCRIPT"
SECOND_TRANSCRIPT="$TEST_ROOT/.claude/projects/-tmp/another-short-session.jsonl"
printf '%s\n' '{"message":{"role":"user","content":"another short message"}}' > "$SECOND_TRANSCRIPT"

# Two local skips must complete immediately rather than incurring the
# five-second API rate limit between them.
HOME="$TEST_ROOT" timeout 2 bun run "$TEST_ROOT/.claude/hooks/SessionExtract.hook.ts" --batch >/dev/null 2>&1

TRACKER="$TEST_ROOT/.claude/MEMORY/.extraction_tracker.json"
test -f "$TRACKER"
jq -e --arg path "$TRANSCRIPT" '.[$path].extractedAt and (.[$path].size > 0)' "$TRACKER" >/dev/null
jq -e --arg path "$SECOND_TRANSCRIPT" '.[$path].extractedAt and (.[$path].size > 0)' "$TRACKER" >/dev/null

echo "PASS: short transcripts are tracked as handled"
