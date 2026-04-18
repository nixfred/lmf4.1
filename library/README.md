# The Library — Canonical Memory

**Extracted memory is volume. Canonical memory is law.**

When your AI sees a recurring correction for the tenth time, that insight
deserves to be more than one of five thousand auto-extracted notes — it
deserves to be in the Library, read at the top of every session, never
forgotten.

## The Problem

The memory pipeline (SessionExtract + AssociativeRecall) is excellent at
volume: it captures every decision, every fixed error, every learning from
every session into `memory.db`. FTS5 and semantic search find relevant bits
when you ask. But volume has a weakness — important things drown in noise.

If your AI keeps misusing a term, keeps reaching for the wrong tool, keeps
making an architectural mistake you corrected three months ago, associative
recall might not surface the correction at the right moment. The insight
exists in the DB; it just didn't win the relevance ranking for today's query.

## The Solution — A Curated Tier

The Library is a small, human-curated collection of high-value memories
promoted out of the noise. They live as plain markdown files under
`$HOME/.claude/LIBRARY/_canonical/` and are indexed in `MEMORY.md`.

Two rules:
1. **Every canonical file is markdown.** No schemas, no special tools to read.
2. **Promotion is a human act, not an AI act.** The AI can suggest what to
   promote; you decide.

## When to Promote

- The AI violated the same rule three times across three sessions.
- A hard-won architectural decision that must not be re-litigated.
- An identity fact about you or your projects the AI must always know.
- A term or convention the AI keeps getting wrong.
- Anything you'd want on day 1 of a brand new AI instance inheriting this system.

## How to Promote

```bash
bash library/bin/promote.sh PATH_TO_MEMO.md
```

This copies the memo to `$HOME/.claude/LIBRARY/_canonical/` and appends a
line to `$HOME/.claude/LIBRARY/MEMORY.md`. Done.

Your CLAUDE.md (or the equivalent in your AI framework) should reference
`$HOME/.claude/LIBRARY/MEMORY.md` so canonical memories load at session
start — eliminating the recall-lottery problem entirely for anything that
matters.

## Structure

```
$HOME/.claude/LIBRARY/
├── MEMORY.md              # Index + short summaries, auto-updated by promote.sh
└── _canonical/
    ├── feedback_no_dashes.md          # example: AI kept using em-dashes
    ├── decision_python_banned.md      # example: we hate Python in this codebase
    └── user_git_identity.md           # example: GitHub username, commit email
```

File names are yours — the convention above (category_name.md) is just a
habit that makes `ls` scannable. The file contents are yours — short
markdown with a clear headline is easiest for the AI to consume.

## The Philosophy

Persistent memory has three tiers in LMF4.1:

| Tier       | Storage                      | Who writes        | When read                 |
|------------|------------------------------|-------------------|---------------------------|
| Volume     | `memory.db` (FTS5 + vectors) | SessionExtract hook | On-demand via recall     |
| Auto       | `MEMORY/AUTO/*.md`           | AI, per-session   | Session start (injected)  |
| Canonical  | `LIBRARY/_canonical/*.md`    | Human via promote | Session start (always)    |

Volume is cheap and comprehensive but low-signal. Auto is medium-signal
and per-project. Canonical is the short list you've personally decided
the AI must never forget.
