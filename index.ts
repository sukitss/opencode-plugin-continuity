/**
 * opencode-plugin-continuity
 *
 * Keeps coding agents running on router providers, without patching OpenCode source.
 *
 *  1. overflow-rescue — on retry-hook failures that look like "prompt too long"
 *     (incl. the unclassified `Prompt exceeds max length` / code 1261), veto the
 *     retry — repeating an oversized prompt fails deterministically — and request
 *     compaction so the next prompt can continue.
 *  2. retry-tuning — provider 5xx: give the origin 30s+ before retrying instead
 *     of ten fast attempts in ~84s.
 *
 * Model context limits are synced into opencode.json directly (limit.context,
 * see sync-models.sh) because v2.0.30 model-transform edits do not reach the
 * model read path. On startup this plugin runs `sync-models.sh --check` once
 * and logs a warning when the config has drifted from the router/profiles
 * (detection only — applying stays a deliberate, human-run step).
 */

import { execFile } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

/** Run `sync-models.sh --check` once; log a warning when limits drifted. */
function checkLimitDriftOnce(): void {
  if (process.env.OPENCODE_SYNC_CHECK === "0") return
  try {
    const dir = dirname(fileURLToPath(import.meta.url))
    execFile(
      "python3",
      [join(dir, "sync-models.sh"), "--check"],
      { timeout: 120_000 },
      (err, stdout) => {
        if (err) {
          console.log("[continuity] limit drift-check failed:", String((err as Error).message ?? err))
          return
        }
        const match = String(stdout).match(/--check:\s*(\d+)\s+change/)
        const pending = match ? Number(match[1]) : 0
        if (pending > 0) {
          console.log(
            `[continuity] model limits drifted from router/profiles — ${pending} update(s) available. ` +
              `run: ${join(dir, "sync-models.sh")}`,
          )
        } else {
          console.log("[continuity] model limits in sync with router/profiles")
        }
      },
    )
  } catch (err) {
    console.log("[continuity] limit drift-check skipped:", String(err))
  }
}

export interface ContinuityOptions {
  /** Minimum delay for 5xx retries (capped at 60s). Default 30000. */
  serverErrorDelayMs?: number
  /** Set false to disable the prompt-too-long veto + compaction request. Default true. */
  rescueOverflow?: boolean
}

const DEFAULT_SERVER_ERROR_DELAY_MS = 30_000
const MAX_5XX_DELAY_MS = 60_000

/** Messages that mean the prompt itself is too large; retrying the same request cannot succeed. */
const PROMPT_TOO_LONG = [
  /prompt exceeds max length/i,
  /prompt is too long/i,
  /prompt (?:too long|超长)/i,
  /context[_ ]length[_ ]exceeded/i,
  /model_context_window_exceeded/i,
  /maximum (?:prompt|context) length is \d+/i,
  /exceeds (?:the )?(?:model'?s )?maximum context length/i,
  /"code"\s*:\s*"?1261"?\b/,
] as const

export function looksLikePromptTooLong(message: string | undefined | null): boolean {
  if (!message) return false
  return PROMPT_TOO_LONG.some((pattern) => pattern.test(message))
}

export function paceServerError(
  decision: { retry: boolean; delay?: number },
  serverErrorDelayMs: number,
): { retry: boolean; delay?: number } {
  if (!decision.retry) return decision
  const delay = Math.max(decision.delay ?? 0, serverErrorDelayMs)
  return { retry: true, delay: Math.min(delay, MAX_5XX_DELAY_MS) }
}

interface RetryDecision {
  retry: boolean
  delay?: number
}

interface RetryEvent {
  readonly sessionID: string
  readonly error?: { type?: string; message?: string; status?: number }
  readonly attempt: number
  decision: RetryDecision
}

interface ContinuityContext {
  options?: ContinuityOptions
  session: {
    hook(name: "retry", callback: (event: RetryEvent) => void): Promise<unknown>
    compact(input: { sessionID: string }): Promise<unknown>
  }
}

export default {
  id: "continuity",
  async setup(ctx: ContinuityContext) {
    const serverErrorDelayMs = ctx.options?.serverErrorDelayMs ?? DEFAULT_SERVER_ERROR_DELAY_MS
    const rescueOverflow = ctx.options?.rescueOverflow !== false

    checkLimitDriftOnce()

    await ctx.session.hook("retry", (event) => {
      if (rescueOverflow && looksLikePromptTooLong(event.error?.message)) {
        event.decision = { retry: false }
        void ctx.session.compact({ sessionID: event.sessionID }).catch(() => {})
        return
      }
      const status = event.error?.status
      if (status !== undefined && status >= 500) {
        event.decision = paceServerError(event.decision, serverErrorDelayMs)
      }
    })
  },
}
