// Phone pings: what to say, and whether to say it. Pure, so it's testable.
// Same voice as rules.ts: a chill friend, plain words, the real detail.
import type { Pings } from '../types'

// Tuning knobs.
export const LONG_TURN_MS = 3 * 60_000
export const PING_GAP_MS = 2 * 60_000
export const NUDGE_AFTER_MS = 30 * 60_000
const MAX_LEN = 190 // mobile OSes cut around 200

export const NO_PINGS: Pings = { lastPushAt: 0, nudged: false, turnFailed: false, waitingPushed: false }

const clip = (s: string, n = MAX_LEN) => {
  const one = s.replace(/\s+/g, ' ').trim()
  return one.length > n ? one.slice(0, n - 1) + '…' : one
}
const lower = (s: string) => s.charAt(0).toLowerCase() + s.slice(1)

/**
 * Pings can land on a lock screen, so scrub anything that looks like a credential first:
 * known token shapes, `Bearer …`, `password=…`-style pairs, and long opaque strings.
 */
export function redact(text: string) {
  return text
    .replace(/\b(sk|pk|rk|xi|ghp|gho|ghs|ghu|github_pat|xox[abprs]|glpat|AKIA|ASIA)[-_A-Za-z0-9]{8,}/g, '•••')
    .replace(/\b(Bearer|Basic|token)\s+[A-Za-z0-9._~+/=-]{8,}/gi, '$1 •••')
    .replace(/\b(api[_-]?key|token|secret|password|passwd|pwd|auth)(["']?\s*[:=]\s*["']?)[^\s"'&]+/gi, '$1$2•••')
    .replace(/[A-Za-z0-9+/_=-]{40,}/g, '•••')
}

export const canPush = (p: Pings, now: number, isOn: boolean) => isOn && now - p.lastPushAt >= PING_GAP_MS

/** After a main-thread turn ends: something broke beats a long task finishing. */
export function turnPing(t: { project: string; durationMs: number; failed: boolean; errored: boolean; nextStep?: string }) {
  if (t.errored) return clip(`heads up: that turn in ${t.project} hit an error and stopped. come take a look when you can.`)
  if (t.failed) return clip(`heads up: tests failed in ${t.project}. want me to dig in?`)
  if (t.durationMs >= LONG_TURN_MS) {
    const min = Math.round(t.durationMs / 60_000)
    return clip(`done with that big one in ${t.project} (${min} min).${t.nextStep ? ` next up: ${lower(t.nextStep)}` : ''}`)
  }
  return null
}

export const questionPing = (project: string, question: string) =>
  clip(`quick question for you in ${project}: ${question}`)

/** Plain-language version of "Claude wants permission to run a tool". */
export function approvalPing(project: string, tool: string, input: unknown) {
  const i = (input ?? {}) as Record<string, unknown>
  const what =
    tool === 'Bash' && typeof i.command === 'string' ? `run \`${clip(i.command, 70)}\``
    : (tool === 'Edit' || tool === 'Write') && typeof i.file_path === 'string' ? `change ${i.file_path.split('/').pop()}`
    : tool === 'WebFetch' && typeof i.url === 'string' ? `open ${clip(i.url, 70)}`
    : `use ${tool.replace(/^mcp__[^_]+__/, '')}`
  return clip(`claude needs your ok in ${project} to ${what}.`)
}

export const nudgePing = (project: string, dirtyFiles: number) =>
  clip(`you've got ${dirtyFiles} changed file${dirtyFiles === 1 ? '' : 's'} in ${project} that aren't committed yet. want to lock them in?`)
