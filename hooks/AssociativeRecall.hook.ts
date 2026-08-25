#!/usr/bin/env bun
/**
 * AssociativeRecall.hook.ts — Automatic memory recall on every user message
 *
 * THE MISSING PIECE: Searches memory.db for context relevant to what the
 * user is currently talking about and injects it as a system-reminder.
 *
 * Trigger: UserPromptSubmit
 * Input: { content: string } — the user's message
 * Output: stdout system-reminder with relevant past context (or empty)
 *
 * Performance budget: <300ms total.
 *   Tier 1: FTS5 keyword match (rare-term weighted).
 *   Tier 2 (added 2026-08-24): semantic — embed the query with local
 *   nomic-embed-text (Ollama, ~20-40ms warm) and cosine-scan the ~6k vectors
 *   in memory.db (~80ms). Fused with FTS via Reciprocal Rank Fusion so a
 *   prompt like "health check on your memory system" recalls memory-system
 *   work instead of whatever happens to contain the token "memory".
 *   Semantic tier is best-effort: Ollama down / slow (>1.5s) → FTS only.
 * Token budget: <2000 chars injected per message.
 */

import { Database } from "bun:sqlite";
import { existsSync, readFileSync } from "fs";
import { join } from "path";

const DB_PATH = join(process.env.HOME!, ".claude", "memory.db");
const MIN_QUERY_LENGTH = 12; // Skip very short messages like "yes", "ok", "do it"
const MAX_RESULTS = 5;
const MAX_OUTPUT_CHARS = 1800;
const PRIOR_MESSAGES_TO_INCLUDE = 2; // Read last N user messages for context blending
// Noise floor: suppress recall results scoring below this. Tuned from live
// diagnostic data — clearly-garbage matches cluster at 0.15–1.8; useful
// matches at 2.5+. Showing weak matches adds cognitive tax and can mislead,
// so silence is better than noise. Raise for stricter recall, lower for
// broader; 2.0 is the conservative default.
const MIN_SCORE = 2.0;
const OLLAMA_URL = "http://localhost:11434";
const EMBED_MODEL = "nomic-embed-text";
const SEMANTIC_TIMEOUT_MS = 2500; // nomic cold-load ≈1.5s when llama evicted it (MAX_LOADED_MODELS=1)
const SEMANTIC_MIN_SIM = 0.55; // nomic cosine: unrelated ~0.3-0.45, related ~0.6+
const SEMANTIC_TOP_K = 8;
const RRF_K = 60;

// Words that are too common to search for
const STOP_WORDS = new Set([
  "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
  "have", "has", "had", "do", "does", "did", "will", "would", "could",
  "should", "may", "might", "shall", "can", "need", "dare", "ought",
  "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
  "as", "into", "through", "during", "before", "after", "above", "below",
  "between", "out", "off", "over", "under", "again", "further", "then",
  "once", "here", "there", "when", "where", "why", "how", "all", "both",
  "each", "few", "more", "most", "other", "some", "such", "no", "nor",
  "not", "only", "own", "same", "so", "than", "too", "very", "just",
  "don", "now", "also", "that", "this", "what", "which", "who", "whom",
  "these", "those", "i", "me", "my", "we", "our", "you", "your", "he",
  "him", "his", "she", "her", "it", "its", "they", "them", "their",
  "and", "but", "or", "if", "because", "while", "although", "about",
  "make", "like", "get", "go", "know", "take", "see", "come", "think",
  "look", "want", "give", "use", "find", "tell", "ask", "work", "seem",
  "feel", "try", "leave", "call", "keep", "let", "begin", "show", "hear",
  "play", "run", "move", "live", "believe", "bring", "happen", "write",
  "provide", "sit", "stand", "lose", "pay", "meet", "include", "continue",
  "set", "learn", "change", "lead", "understand", "watch", "follow",
  "stop", "create", "speak", "read", "allow", "add", "spend", "grow",
  "open", "walk", "win", "offer", "remember", "love", "consider", "appear",
  "buy", "wait", "serve", "die", "send", "expect", "build", "stay",
  "fall", "cut", "reach", "kill", "remain", "please", "help", "thanks",
  "yeah", "yes", "yep", "nope", "sure", "okay", "right", "well",
  "gonna", "wanna", "gotta", "lets", "let's", "don't", "doesn't",
  "didn't", "won't", "can't", "couldn't", "shouldn't", "wouldn't",
  "check", "fix", "look", "update", "something", "anything", "everything",
  "nothing", "thing", "things", "stuff", "way", "time", "good", "bad",
  "new", "old", "first", "last", "long", "great", "little", "much",
  "still", "even", "back", "kind", "really", "actually", "basically",
]);

interface UserPromptInput {
  // Claude Code's UserPromptSubmit payload carries the text in `prompt`.
  // `content` is kept for manual testing / older harness versions.
  prompt?: string;
  content?: string;
  session_id?: string;
  transcript_path?: string;
  cwd?: string;
}

interface RecallResult {
  type: string;
  text: string;
  date: string;
  score: number;
}

// Read the last N user messages from this session's transcript JSONL.
// Catches "did that work?" / "do your X" / "run it" type queries that
// have no signal alone but rich signal when combined with prior turns.
function getRecentUserMessages(sessionId: string | undefined, count: number, knownTranscriptPath?: string): string[] {
  if (!sessionId && !knownTranscriptPath) return [];
  try {
    // Prefer the transcript_path the harness hands us — the fallback path
    // reconstruction is lossy (Claude Code encodes both "/" and "_" as "-").
    let transcriptPath = knownTranscriptPath || "";
    if (!transcriptPath || !existsSync(transcriptPath)) {
      const cwd = process.cwd();
      const encoded = "-" + cwd.replace(/^\/+/, "").replace(/[\/_]/g, "-");
      transcriptPath = join(process.env.HOME!, ".claude", "projects", encoded, `${sessionId}.jsonl`);
    }
    if (!existsSync(transcriptPath)) return [];

    const raw = readFileSync(transcriptPath, "utf-8");
    const lines = raw.split("\n");
    const tail = lines.slice(-200); // last 200 lines is plenty for ~5 user turns
    const userTexts: string[] = [];
    for (let i = tail.length - 1; i >= 0 && userTexts.length < count; i--) {
      const line = tail[i].trim();
      if (!line) continue;
      try {
        const obj = JSON.parse(line);
        const msg = obj?.message;
        if (msg?.role !== "user") continue;
        let text = "";
        if (typeof msg.content === "string") {
          text = msg.content;
        } else if (Array.isArray(msg.content)) {
          text = msg.content
            .filter((b: any) => b && b.type === "text")
            .map((b: any) => b.text || "")
            .join(" ");
        }
        // Strip system-reminder blocks and very short ack-style messages
        text = text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim();
        if (text.length < MIN_QUERY_LENGTH) continue;
        userTexts.unshift(text); // chronological order
      } catch { /* skip malformed line */ }
    }
    return userTexts;
  } catch {
    return []; // any failure → no prior context, hook still runs on current message alone
  }
}

function extractKeyTerms(text: string): string[] {
  // Remove markdown, URLs, code blocks, paths
  const cleaned = text
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`[^`]+`/g, "")
    .replace(/https?:\/\/\S+/g, "")
    .replace(/[^\w\s-]/g, " ")
    .toLowerCase();

  const words = cleaned.split(/\s+/).filter((w) => w.length > 2);
  const terms = words.filter((w) => !STOP_WORDS.has(w));
  const unique = [...new Set(terms)];

  // Rank by rarity in the memory corpus (IDF proxy). Rarer tokens carry
  // more topic signal than long-but-common ones. Length is a tiebreaker.
  // Terms present in zero rows fall back to length — they may be proper
  // nouns worth keeping even if they miss. DB probe cost: ~1ms per term,
  // well inside the 300ms hook budget.
  try {
    const db = new Database(DB_PATH, { readonly: true });
    const withScore = unique.map((term) => {
      let hits = 0;
      try {
        const q = `"${term.replace(/"/g, "")}"`;
        const r1 = db.prepare(`SELECT COUNT(*) AS c FROM loa_fts WHERE loa_fts MATCH ?`).get(q) as any;
        const r2 = db.prepare(`SELECT COUNT(*) AS c FROM decisions_fts WHERE decisions_fts MATCH ?`).get(q) as any;
        const r3 = db.prepare(`SELECT COUNT(*) AS c FROM learnings_fts WHERE learnings_fts MATCH ?`).get(q) as any;
        const r4 = db.prepare(`SELECT COUNT(*) AS c FROM errors_fts WHERE errors_fts MATCH ?`).get(q) as any;
        hits = (r1?.c ?? 0) + (r2?.c ?? 0) + (r3?.c ?? 0) + (r4?.c ?? 0);
      } catch { /* unsearchable term → fall back to length */ }
      return { term, hits, len: term.length };
    });
    db.close();
    // Ascending hits (rare first); zero-hit → infinity so they rank last.
    // Within equal rarity, longer wins.
    withScore.sort((a, b) => {
      const ah = a.hits === 0 ? 1e9 : a.hits;
      const bh = b.hits === 0 ? 1e9 : b.hits;
      if (ah !== bh) return ah - bh;
      return b.len - a.len;
    });
    return withScore.slice(0, 6).map((w) => w.term);
  } catch {
    // DB unreachable — fall back to length sort
    unique.sort((a, b) => b.length - a.length);
    return unique.slice(0, 6);
  }
}

function buildFtsQuery(terms: string[]): string {
  // OR-join terms for broader matching, quote multi-word terms
  return terms.map((t) => `"${t}"`).join(" OR ");
}

function searchMemory(terms: string[]): RecallResult[] {
  if (terms.length === 0) return [];

  const db = new Database(DB_PATH, { readonly: true });
  const results: RecallResult[] = [];
  const ftsQuery = buildFtsQuery(terms);
  const now = Date.now();

  // Search decisions (highest value — direct actionable context)
  try {
    const rows = db
      .prepare(
        `SELECT d.decision, d.reasoning, d.created_at, rank
         FROM decisions_fts
         JOIN decisions d ON decisions_fts.rowid = d.id
         WHERE decisions_fts MATCH ? AND d.status = 'active'
         ORDER BY rank
         LIMIT 8`
      )
      .all(ftsQuery) as any[];

    for (const r of rows) {
      const age = (now - new Date(r.created_at).getTime()) / 86400000;
      const decay = Math.pow(0.97, age); // ~50% at 23 days
      results.push({
        type: "decision",
        text: r.reasoning ? `${r.decision} — ${r.reasoning}` : r.decision,
        date: r.created_at?.slice(0, 10) || "",
        score: Math.abs(r.rank) * decay * 1.0,
      });
    }
  } catch {}

  // Search errors (high value — prevents repeating mistakes)
  try {
    const rows = db
      .prepare(
        `SELECT e.error, e.fix, e.created_at, rank
         FROM errors_fts
         JOIN errors e ON errors_fts.rowid = e.id
         WHERE errors_fts MATCH ?
         ORDER BY rank
         LIMIT 5`
      )
      .all(ftsQuery) as any[];

    for (const r of rows) {
      if (!r.fix) continue;
      const age = (now - new Date(r.created_at).getTime()) / 86400000;
      const decay = Math.pow(0.97, age);
      results.push({
        type: "error/fix",
        text: `${r.error} → ${r.fix}`,
        date: r.created_at?.slice(0, 10) || "",
        score: Math.abs(r.rank) * decay * 0.9,
      });
    }
  } catch {}

  // Search session summaries (context — what did we work on?)
  try {
    const rows = db
      .prepare(
        `SELECT l.title, snippet(loa_fts, 1, '', '', '...', 30) as excerpt, l.created_at, rank
         FROM loa_fts
         JOIN loa_entries l ON loa_fts.rowid = l.id
         WHERE loa_fts MATCH ?
         ORDER BY rank
         LIMIT 5`
      )
      .all(ftsQuery) as any[];

    for (const r of rows) {
      const age = (now - new Date(r.created_at).getTime()) / 86400000;
      const decay = Math.pow(0.97, age);
      results.push({
        type: "past session",
        text: r.title,
        date: r.created_at?.slice(0, 10) || "",
        score: Math.abs(r.rank) * decay * 0.7,
      });
    }
  } catch {}

  // Search learnings
  try {
    const rows = db
      .prepare(
        `SELECT l.problem, l.solution, l.created_at, rank
         FROM learnings_fts
         JOIN learnings l ON learnings_fts.rowid = l.id
         WHERE learnings_fts MATCH ?
         ORDER BY rank
         LIMIT 5`
      )
      .all(ftsQuery) as any[];

    for (const r of rows) {
      if (!r.solution) continue;
      const age = (now - new Date(r.created_at).getTime()) / 86400000;
      const decay = Math.pow(0.97, age);
      results.push({
        type: "learning",
        text: `${r.problem} → ${r.solution}`,
        date: r.created_at?.slice(0, 10) || "",
        score: Math.abs(r.rank) * decay * 0.8,
      });
    }
  } catch {}

  db.close();

  // Sort by score descending, apply noise floor, take top N
  results.sort((a, b) => b.score - a.score);
  return results.filter((r) => r.score >= MIN_SCORE).slice(0, MAX_RESULTS);
}

// ─── Tier 2: semantic recall ─────────────────────────────────────

async function embedQuery(text: string): Promise<Float32Array | null> {
  try {
    const res = await fetch(`${OLLAMA_URL}/api/embeddings`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: EMBED_MODEL, prompt: text.slice(0, 4000), keep_alive: "2h" }),
      signal: AbortSignal.timeout(SEMANTIC_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { embedding?: number[] };
    if (!data.embedding || data.embedding.length === 0) return null;
    const q = Float32Array.from(data.embedding);
    let n = 0;
    for (let i = 0; i < q.length; i++) n += q[i] * q[i];
    n = Math.sqrt(n) || 1;
    for (let i = 0; i < q.length; i++) q[i] /= n;
    return q;
  } catch {
    return null; // Ollama down/slow → FTS-only, never block the prompt
  }
}

async function semanticSearch(queryText: string): Promise<RecallResult[]> {
  const q = await embedQuery(queryText);
  if (!q) return [];

  const db = new Database(DB_PATH, { readonly: true });
  const out: RecallResult[] = [];
  try {
    const rows = db
      .prepare(
        `SELECT source_table, source_id, embedding FROM embeddings
         WHERE source_table IN ('loa_entries','decisions','learnings','errors')`
      )
      .all() as any[];

    const scored: { table: string; id: number; sim: number }[] = [];
    for (const r of rows) {
      const b = r.embedding as Uint8Array;
      if (!b || b.byteLength !== q.length * 4) continue;
      const v = new Float32Array(b.buffer, b.byteOffset, q.length);
      let dot = 0, norm = 0;
      for (let i = 0; i < q.length; i++) { dot += v[i] * q[i]; norm += v[i] * v[i]; }
      const sim = norm > 0 ? dot / Math.sqrt(norm) : 0;
      if (sim >= SEMANTIC_MIN_SIM) scored.push({ table: r.source_table, id: r.source_id, sim });
    }
    scored.sort((a, b) => b.sim - a.sim);

    // Fetch a few extra so recency re-ranking has room, then re-sort below.
    for (const h of scored.slice(0, SEMANTIC_TOP_K * 2)) {
      try {
        let row: any; let type = ""; let text = "";
        switch (h.table) {
          case "decisions":
            row = db.prepare(`SELECT decision, reasoning, created_at FROM decisions WHERE id = ? AND status = 'active'`).get(h.id);
            if (!row) continue;
            type = "decision"; text = row.reasoning ? `${row.decision} — ${row.reasoning}` : row.decision; break;
          case "errors":
            row = db.prepare(`SELECT error, fix, created_at FROM errors WHERE id = ?`).get(h.id);
            if (!row?.fix) continue;
            type = "error/fix"; text = `${row.error} → ${row.fix}`; break;
          case "learnings":
            row = db.prepare(`SELECT problem, solution, created_at FROM learnings WHERE id = ?`).get(h.id);
            if (!row?.solution) continue;
            type = "learning"; text = `${row.problem} → ${row.solution}`; break;
          default:
            row = db.prepare(`SELECT title, created_at FROM loa_entries WHERE id = ?`).get(h.id);
            if (!row) continue;
            type = "past session"; text = row.title;
        }
        // Gentle recency weighting: a 6-month-old hit needs ~0.05 more
        // similarity to beat a fresh one. Keeps old-but-exact matches alive.
        const ageDays = (Date.now() - new Date(row.created_at).getTime()) / 86400000;
        const recency = 0.85 + 0.15 * Math.pow(0.99, Math.max(0, ageDays));
        out.push({ type, text, date: row.created_at?.slice(0, 10) || "", score: h.sim * recency });
      } catch { /* skip row */ }
    }
  } catch { /* semantic tier is best-effort */ }
  db.close();
  out.sort((a, b) => b.score - a.score);
  return out.slice(0, SEMANTIC_TOP_K);
}

// Reciprocal Rank Fusion: each list contributes 1/(k+rank). Items found by
// BOTH tiers float to the top; singletons keep their tier's ordering.
function fuseResults(fts: RecallResult[], sem: RecallResult[]): RecallResult[] {
  const key = (r: RecallResult) => `${r.type}|${r.text.slice(0, 120)}`;
  const merged = new Map<string, RecallResult>();
  const add = (list: RecallResult[], weight: number) => {
    list.forEach((r, i) => {
      const k = key(r);
      const contrib = weight / (RRF_K + i + 1);
      const prev = merged.get(k);
      if (prev) prev.score += contrib;
      else merged.set(k, { ...r, score: contrib });
    });
  };
  add(fts, 1.0);
  add(sem, 1.0);
  return [...merged.values()].sort((a, b) => b.score - a.score).slice(0, MAX_RESULTS);
}

function formatResults(results: RecallResult[]): string {
  if (results.length === 0) return "";

  const lines: string[] = ["[MEMORY CONTEXT — auto-recalled from past sessions]"];

  let chars = lines[0].length;
  for (const r of results) {
    const line = `• [${r.type}] (${r.date}) ${r.text}`;
    const truncated = line.length > 300 ? line.slice(0, 297) + "..." : line;
    if (chars + truncated.length + 1 > MAX_OUTPUT_CHARS) break;
    lines.push(truncated);
    chars += truncated.length + 1;
  }

  return lines.join("\n");
}

async function main() {
  let input: UserPromptInput = {};
  try {
    const raw = await Bun.stdin.text();
    input = JSON.parse(raw);
  } catch {
    return; // No input — skip
  }

  const content = input.prompt || input.content || "";
  const trimmed = content.trim();

  // Skip pure numeric ratings — they have zero recall signal on their own
  // AND zero recall signal when blended with prior context.
  if (/^\d{1,2}$/.test(trimmed)) return;

  // Classify the current prompt. Short / ack / low-signal prompts get
  // blended with prior user turns so recall anchors on the conversation
  // topic, not on the single tiny current message.
  const isShort = content.length < MIN_QUERY_LENGTH;
  const isAck = /^(yes|yep|yeah|no|nope|ok|okay|sure|thanks|thx|do it|do your|go|run it|try (it|that)|fix it|make it|apply|continue|proceed|right|correct|agreed?|ship it|lgtm|good|great|perfect)\b/i.test(trimmed);
  const wordCount = trimmed.split(/\s+/).filter(Boolean).length;
  const looksLikeAck = wordCount <= 4 || extractKeyTerms(content).length < 3;

  let queryText = content;
  if (isShort || isAck || looksLikeAck) {
    // Low-signal current turn — blend in prior context. Only skip outright
    // when the turn is a true ack/short with nothing prior; a short but
    // specific question ("who is Chappy and what is the DDN thing" → 2 key
    // terms) must still reach the semantic tier, which needs no key terms.
    const prior = getRecentUserMessages(input.session_id, PRIOR_MESSAGES_TO_INCLUDE, input.transcript_path);
    if (prior.length === 0 && (isShort || isAck || wordCount <= 4)) return;
    queryText = prior.length > 0 ? prior.join(" ") + " " + content : content;
  } else {
    // Substantive turn — still blend the immediately-prior user turn so
    // recall reflects the conversational arc, not just this one sentence.
    const prior = getRecentUserMessages(input.session_id, 1, input.transcript_path);
    if (prior.length > 0 && prior[0] !== content) {
      queryText = prior[0] + " " + content;
    }
  }

  const terms = extractKeyTerms(queryText);

  // Run both tiers concurrently; semantic is best-effort and time-boxed.
  const [fts, sem] = await Promise.all([
    Promise.resolve(terms.length > 0 ? searchMemory(terms) : []),
    semanticSearch(queryText),
  ]);
  const results = fuseResults(fts, sem);
  if (results.length === 0) return;

  const formatted = formatResults(results);
  if (!formatted) return;

  // Output as system-reminder for context injection
  console.log(`<system-reminder>\n${formatted}\n</system-reminder>`);
}

main().catch(() => process.exit(0)); // Fail silently — never block the user
