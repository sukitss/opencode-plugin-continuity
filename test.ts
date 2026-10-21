/**
 * Regression tests for opencode-plugin-continuity.
 * Run: bun test.ts  (from this folder)
 *
 * Error strings are real samples from ~/.local/share/opencode/log/opencode.log (T-004).
 */
import { looksLikePromptTooLong, paceServerError } from "./index.ts"

let failures = 0
function check(name: string, actual: unknown, expected: unknown) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failures++
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : ` — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`}`)
}

// --- looksLikePromptTooLong ---

// Real 1261 payload from log line 74488 (2026-10-14, session ses_ee0093e...)
check(
  "real 1261 payload matches",
  looksLikePromptTooLong('[400]: {"error":{"code":"1261","message":"Prompt exceeds max length"}}'),
  true,
)
check("bare phrase matches", looksLikePromptTooLong("Prompt exceeds max length"), true)
check("anthropic phrasing matches", looksLikePromptTooLong("prompt is too long: 210000 tokens > 200000"), true)
check("context_length_exceeded matches", looksLikePromptTooLong("context_length_exceeded"), true)

check("rate limit does not match", looksLikePromptTooLong("429 rate limit exceeded, retry later"), false)
check("http 524 does not match", looksLikePromptTooLong("Provider request failed with HTTP 524"), false)
check("auth error does not match", looksLikePromptTooLong("401 invalid api key"), false)
check("empty does not match", looksLikePromptTooLong(undefined), false)
check("empty string does not match", looksLikePromptTooLong(""), false)

// --- paceServerError ---

// v2 default first retry is ~2s; a 524 means the origin already burned ~100s upstream.
check(
  "5xx retry delay raised to 30s",
  paceServerError({ retry: true, delay: 2_000 }, 30_000),
  { retry: true, delay: 30_000 },
)
check(
  "existing longer delay is kept",
  paceServerError({ retry: true, delay: 45_000 }, 30_000),
  { retry: true, delay: 45_000 },
)
check(
  "delay capped at 60s",
  paceServerError({ retry: true, delay: 900_000 }, 30_000),
  { retry: true, delay: 60_000 },
)
check("vetoed retry stays vetoed", paceServerError({ retry: false }, 30_000), { retry: false })

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`)
if (failures > 0) process.exit(1)
