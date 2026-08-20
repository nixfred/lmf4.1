#!/usr/bin/env bun
/**
 * StopFailure.hook.ts — Fires when a turn ends due to API error
 *
 * Logs the error to ERROR_PATTERNS.json and EXTRACT_LOG.txt.
 */

import { appendFileSync, readFileSync, writeFileSync } from "fs";

const MEMORY_DIR = `${process.env.HOME}/.claude/MEMORY`;
const ERROR_FILE = `${MEMORY_DIR}/ERROR_PATTERNS.json`;
const EXTRACT_LOG = `${MEMORY_DIR}/EXTRACT_LOG.txt`;

interface StopFailureInput {
  error?: string;
  error_code?: string;
  status_code?: number;
  session_id?: string;
  cwd?: string;
}

async function main() {
  let input: StopFailureInput = {};
  try {
    const raw = await Bun.stdin.text();
    input = JSON.parse(raw);
  } catch {
    // No input or invalid JSON — still log that it fired
  }

  const timestamp = new Date().toISOString();
  const errorCode = input.error_code || input.status_code?.toString() || "unknown";
  const errorMsg = input.error || "API error (no details provided)";

  // 1. Log to EXTRACT_LOG
  try {
    appendFileSync(EXTRACT_LOG, `[${timestamp}] STOP_FAILURE: code=${errorCode} error=${errorMsg}\n`);
  } catch {}

  // 2. Log to ERROR_PATTERNS.json
  // SessionExtract owns this file with the shape { patterns: [], meta: {} }.
  // Writing a bare array here (as pre-4.1.1 versions did) made the two hooks
  // clobber each other: once SessionExtract wrote the object form, this
  // hook's `errors.push` threw on the non-array and silently logged nothing.
  try {
    let data: { patterns: any[]; meta?: any } = { patterns: [] };
    try {
      const parsed = JSON.parse(readFileSync(ERROR_FILE, "utf-8"));
      if (Array.isArray(parsed)) {
        // Legacy bare-array file from an older StopFailure — migrate in place
        data = { patterns: parsed };
      } else if (parsed && Array.isArray(parsed.patterns)) {
        data = parsed;
      }
    } catch {}

    data.patterns.push({
      error: `API stop failure (code=${errorCode})`,
      cause: "stop_failure",
      fix: errorMsg,
      date: timestamp,
      session_id: input.session_id || null,
    });

    // Cap only this hook's records so extraction patterns are never evicted
    const stopFailures = data.patterns.filter((p) => p.cause === "stop_failure");
    if (stopFailures.length > 200) {
      const cutoff = stopFailures[stopFailures.length - 200].date;
      data.patterns = data.patterns.filter((p) => p.cause !== "stop_failure" || p.date >= cutoff);
    }

    data.meta = { ...(data.meta || {}), updated: timestamp };
    writeFileSync(ERROR_FILE, JSON.stringify(data, null, 2));
  } catch {}
}

main().catch(() => process.exit(1));
