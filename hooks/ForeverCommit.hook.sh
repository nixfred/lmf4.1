#!/usr/bin/env bash
# ForeverCommit.hook.sh — Auto-commit $HOME/.claude (or $HOME) to a private
# git repo on SessionEnd. OPT-IN. Dangerous if misconfigured.
#
# ═══════════════════════════════════════════════════════════════════════
# SECRETS WARNING — READ BEFORE ENABLING
# ═══════════════════════════════════════════════════════════════════════
# Committing $HOME to git will very likely capture secrets — .env files,
# .ssh/, API tokens, AWS credentials, GPG keys — UNLESS a strict
# .gitignore keeps them out. This hook refuses to run without the
# LMF4 .gitignore template present in the target repo.
#
# Recommended scope: $HOME/.claude only, NOT $HOME.
# See docs/for-the-human/08-forever-commit.md.
# ═══════════════════════════════════════════════════════════════════════
#
# Four safeguards (all must be true for the hook to do work):
#   1. Env var LMF4_ENABLE_FOREVER_COMMIT=1  (explicitly opted in at install time)
#   2. Sentinel file exists: $HOME/.claude/.lmf4-forever-opt-in
#   3. Target repo contains templates/forever-commit.gitignore content
#      (either as .gitignore or as an included file)
#   4. Hook refuses to run if target dir is $HOME and no sentinel is found
#
# Wired to SessionEnd in settings.json only when the installer confirms opt-in.

set -euo pipefail

# ─── Safeguard 1: env gate ─────────────────────────────────────────────
if [ "${LMF4_ENABLE_FOREVER_COMMIT:-0}" != "1" ]; then
    # Silently exit — not enabled at this process level
    exit 0
fi

# ─── Safeguard 2: sentinel file ────────────────────────────────────────
SENTINEL="$HOME/.claude/.lmf4-forever-opt-in"
if [ ! -f "$SENTINEL" ]; then
    # Silently exit — user has not explicitly opted in
    exit 0
fi

# ─── Config (read from sentinel; sensible defaults) ────────────────────
# Sentinel format (one key=value per line):
#   target_dir=/home/USER/.claude          # dir to auto-commit
#   remote=git@github.com:USER/repo.git    # optional; if unset, commits locally only
#   branch=main                            # optional; default main
TARGET_DIR=$(grep -E '^target_dir=' "$SENTINEL" 2>/dev/null | head -1 | cut -d= -f2- || true)
REMOTE=$(grep -E '^remote='     "$SENTINEL" 2>/dev/null | head -1 | cut -d= -f2- || true)
BRANCH=$(grep -E '^branch='     "$SENTINEL" 2>/dev/null | head -1 | cut -d= -f2- || true)
TARGET_DIR="${TARGET_DIR:-$HOME/.claude}"
BRANCH="${BRANCH:-main}"

# ─── Safeguard 4: refuse $HOME without explicit override ───────────────
# If target is $HOME itself, require a second sentinel confirming the user
# has read the secrets warning and added a strict .gitignore.
if [ "$TARGET_DIR" = "$HOME" ]; then
    if [ ! -f "$HOME/.lmf4-forever-commit-home-confirmed" ]; then
        echo "[ForeverCommit] Refusing to commit \$HOME without $HOME/.lmf4-forever-commit-home-confirmed." >&2
        echo "[ForeverCommit] Read docs/for-the-human/08-forever-commit.md first." >&2
        exit 0
    fi
fi

# ─── Safeguard 3: gitignore sanity check ───────────────────────────────
if [ ! -d "$TARGET_DIR/.git" ]; then
    echo "[ForeverCommit] Target $TARGET_DIR is not a git repo; skipping." >&2
    exit 0
fi
if [ ! -f "$TARGET_DIR/.gitignore" ]; then
    echo "[ForeverCommit] No .gitignore in $TARGET_DIR. Refusing to run." >&2
    echo "[ForeverCommit] Copy templates/forever-commit.gitignore into $TARGET_DIR/.gitignore first." >&2
    exit 0
fi

# Heuristic: .gitignore must include at least the obvious secrets patterns.
REQUIRED_PATTERNS=("\\.env" "\\.ssh/" "\\.aws/" "\\.gnupg/" "\\*\\.key" "\\*\\.pem" "credential")
MISSING=0
for pat in "${REQUIRED_PATTERNS[@]}"; do
    if ! grep -qE "$pat" "$TARGET_DIR/.gitignore"; then
        MISSING=1
        echo "[ForeverCommit] .gitignore is missing required pattern: $pat" >&2
    fi
done
if [ "$MISSING" = 1 ]; then
    echo "[ForeverCommit] Refusing to run. Use templates/forever-commit.gitignore as a base." >&2
    exit 0
fi

# ─── Commit ────────────────────────────────────────────────────────────
cd "$TARGET_DIR"
git add -A 2>/dev/null || true
if git diff --cached --quiet 2>/dev/null; then
    # Nothing to commit
    exit 0
fi

MSG="auto: session end $(date -Iseconds)"
git commit -m "$MSG" --no-gpg-sign >/dev/null 2>&1 || { echo "[ForeverCommit] commit failed" >&2; exit 0; }

# ─── Optional push ─────────────────────────────────────────────────────
if [ -n "${REMOTE:-}" ]; then
    # Ensure remote is configured
    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "$REMOTE" >/dev/null 2>&1 || true
    fi
    git push origin "$BRANCH" >/dev/null 2>&1 || echo "[ForeverCommit] push failed; commit is local" >&2
fi

exit 0
