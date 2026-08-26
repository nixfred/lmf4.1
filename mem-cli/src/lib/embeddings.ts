// Embedding generation for LMF4 semantic search.
// Uses Ollama for nomic-embed-text embeddings when available.
// Defaults to localhost:11434; override with OLLAMA_URL env var.
// If Ollama isn't running, semantic search gracefully degrades —
// keyword (FTS5) search still works and callers check checkEmbeddingService().

const OLLAMA_URL = process.env.OLLAMA_URL || 'http://localhost:11434';
const EMBEDDING_MODEL = process.env.EMBEDDING_MODEL || 'nomic-embed-text';
const EMBEDDING_DIMENSIONS = 768;

export interface EmbeddingResult {
  embedding: number[];
  model: string;
  dimensions: number;
}

/**
 * Generate embedding for text using Ollama (local, optional).
 */
// nomic-embed-text has an 8192-token context, but Ollama's llama.cpp server rejects any
// single input larger than its *physical batch* (n_batch, default 2048 tokens) with
// HTTP 500 "input (N tokens) is too large to process". 2026-08-25: loa_entries 6/19/1097
// (13k–75k chars) failed on every `mem embed` run because of this. ~3.7 chars/token for
// English prose, so 7000 chars ≈ 1900 tokens stays under the batch. Override with
// EMBED_MAX_CHARS if the server is started with a bigger OLLAMA_NUM_BATCH / num_batch.
const EMBED_MAX_CHARS = Number(process.env.EMBED_MAX_CHARS) || 7000;

export async function embed(text: string): Promise<EmbeddingResult> {
  let truncated = text.slice(0, EMBED_MAX_CHARS);
  let response: Response;

  // Retry with progressively shorter input if the server still says it's too large
  // (dense code/JSON tokenizes at ~2.5 chars/token, so the 7000-char cap can overshoot).
  for (let attempt = 0; ; attempt++) {
    response = await fetch(`${OLLAMA_URL}/api/embeddings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: EMBEDDING_MODEL,
        prompt: truncated
      })
    });
    if (response.ok) break;

    const body = await response.text().catch(() => '');
    const tooLarge = response.status === 500 && /too large|batch size|exceeds/i.test(body);
    if (tooLarge && attempt < 3 && truncated.length > 500) {
      truncated = truncated.slice(0, Math.floor(truncated.length / 2));
      continue;
    }
    throw new Error(`Ollama embedding failed: ${response.status} ${response.statusText}${body ? ` — ${body.slice(0, 120)}` : ''}`);
  }

  const data = await response.json() as { embedding: number[] };

  if (!data.embedding || !Array.isArray(data.embedding)) {
    throw new Error('Invalid embedding response from Ollama');
  }

  return {
    embedding: data.embedding,
    model: EMBEDDING_MODEL,
    dimensions: data.embedding.length
  };
}

/**
 * Generate embeddings for multiple texts in batch
 */
export async function embedBatch(texts: string[], onProgress?: (done: number, total: number) => void): Promise<EmbeddingResult[]> {
  const results: EmbeddingResult[] = [];

  for (let i = 0; i < texts.length; i++) {
    try {
      const result = await embed(texts[i]);
      results.push(result);
    } catch (err) {
      console.error(`Failed to embed text ${i}:`, err);
      // Push null embedding on failure
      results.push({
        embedding: [],
        model: EMBEDDING_MODEL,
        dimensions: 0
      });
    }

    if (onProgress) {
      onProgress(i + 1, texts.length);
    }
  }

  return results;
}

/**
 * Convert embedding array to SQLite BLOB format
 */
export function embeddingToBlob(embedding: number[]): Buffer {
  const buffer = Buffer.alloc(embedding.length * 4); // float32 = 4 bytes
  for (let i = 0; i < embedding.length; i++) {
    buffer.writeFloatLE(embedding[i], i * 4);
  }
  return buffer;
}

/**
 * Convert SQLite BLOB back to embedding array
 */
export function blobToEmbedding(blob: Buffer | Uint8Array): number[] {
  // bun:sqlite returns BLOBs as Uint8Array in Bun >= 1.2. DataView reads both
  // Buffer and Uint8Array in place — no Buffer.from() copy per row, which
  // matters when a hybrid search scans every embedding in the table.
  const view = new DataView(blob.buffer, blob.byteOffset, blob.byteLength);
  const embedding: number[] = new Array(blob.byteLength >> 2);
  for (let i = 0; i < embedding.length; i++) {
    embedding[i] = view.getFloat32(i * 4, true);
  }
  return embedding;
}

/**
 * Calculate cosine similarity between two embeddings
 */
export function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length !== b.length) {
    throw new Error('Embeddings must have same dimensions');
  }

  let dotProduct = 0;
  let normA = 0;
  let normB = 0;

  for (let i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
}

/**
 * Check if Ollama embedding service is available
 */
export async function checkEmbeddingService(): Promise<{ available: boolean; model: string; url: string }> {
  try {
    const response = await fetch(`${OLLAMA_URL}/api/tags`);
    if (!response.ok) {
      return { available: false, model: EMBEDDING_MODEL, url: OLLAMA_URL };
    }

    const data = await response.json() as { models?: Array<{ name: string }> };
    const hasModel = data.models?.some(m => m.name.startsWith(EMBEDDING_MODEL)) ?? false;

    return { available: hasModel, model: EMBEDDING_MODEL, url: OLLAMA_URL };
  } catch {
    return { available: false, model: EMBEDDING_MODEL, url: OLLAMA_URL };
  }
}

/**
 * Reciprocal Rank Fusion (RRF) for combining search results
 * Formula: score(d) = Σ 1/(k + rank_i(d))
 * k=60 is standard, provides good balance between top and lower ranks
 */
export function reciprocalRankFusion(
  rankedLists: Array<Array<{ id: string; score?: number }>>,
  k: number = 60
): Map<string, number> {
  const fusedScores = new Map<string, number>();

  for (const list of rankedLists) {
    for (let rank = 0; rank < list.length; rank++) {
      const item = list[rank];
      const rrfScore = 1 / (k + rank + 1); // rank is 0-indexed, so +1
      const current = fusedScores.get(item.id) || 0;
      fusedScores.set(item.id, current + rrfScore);
    }
  }

  return fusedScores;
}

export { EMBEDDING_DIMENSIONS, EMBEDDING_MODEL, OLLAMA_URL };
