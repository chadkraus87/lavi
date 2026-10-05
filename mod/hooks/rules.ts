import type { Advice, Answer, LaviConfig, Signals, Snippet, Step } from '../types'

// Tuning knobs (a repo's .lavi.json can override the first three).
export const MAX_DIRTY_FILES = 8
export const MAX_MINUTES_SINCE_COMMIT = 45
export const CONTEXT_WRAP_PERCENT = 70
export const CI_CHECK_EVERY_MS = 5 * 60_000

const TEST_RE = /\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b|\bvitest\b|\bjest\b|\bpytest\b|\bgo test\b|\bcargo test\b|\bplaywright test\b|\bswift test\b|\bclaude plugin test\b/
const LINT_RE = /\btsc\b|\beslint\b|\bbiome\s+(check|lint)\b|\bruff\b|\bmypy\b|\bpyright\b|\bswiftlint\b|\bcargo clippy\b|\bgo vet\b|\b(npm|pnpm|yarn|bun)\s+(run\s+)?(lint|typecheck|type-check)\b/
const CODE_RE = /\.(tsx?|jsx?|mjs|cjs|py|go|rs|swift|rb|java|kt|cs|c|cc|cpp|h|php|vue|svelte|astro)$/

/**
 * The commands a shell line actually runs: each `&&`/`||`/`;`/`|` segment, minus leading
 * `VAR=x` assignments and runner wrappers (npx, uv run, python -m…). Matching only these keeps
 * `grep -r jest src` or `git commit -m "add vitest"` from counting as a test run.
 */
export function commandHeads(cmd: string): string[] {
  const wrapper = /^(?:\w+=\S*\s+|(?:npx|bunx|pnpm\s+(?:exec|dlx)|yarn\s+dlx|uv\s+run|poetry\s+run|pipenv\s+run|python3?\s+-m|time|timeout\s+\S+|env)\s+)/
  return cmd.split(/&&|\|\||;|\||\n/).map(seg => {
    let h = seg.trim().replace(/^\(+/, '')
    for (let prev = ''; prev !== h; ) { prev = h; h = h.replace(wrapper, '') }
    return h
  }).filter(Boolean)
}
const runs = (re: RegExp) => (cmd: string) => commandHeads(cmd).some(h => re.test(h))
export const isTestCommand = runs(new RegExp(`^(?:${TEST_RE.source})`))
export const isLintCommand = runs(new RegExp(`^(?:${LINT_RE.source})`))
export const isPushCommand = runs(/^git\s+push\b/)

/**
 * A repo's .lavi.json is untrusted (it comes with whatever you clone): keep only well-formed
 * values, so a hostile repo can't smuggle text into the prompts Lavi offers you to send.
 */
export function sanitizeConfig(raw: unknown): LaviConfig {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const r = raw as Record<string, unknown>
  const cfg: LaviConfig = {}
  if (typeof r.quiet === 'boolean') cfg.quiet = r.quiet
  // A plain command line: letters, digits, spaces and . / : @ = + - _ only. No quotes, backticks, $, ; or newlines.
  if (typeof r.testCommand === 'string' && /^[\w ./:@=+-]{1,80}$/.test(r.testCommand.trim())) cfg.testCommand = r.testCommand.trim()
  const num = (v: unknown, min: number, max: number) => (typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : undefined)
  const d = num(r.maxDirtyFiles, 1, 10_000), m = num(r.maxMinutesSinceCommit, 1, 7 * 24 * 60), w = num(r.contextWrapPercent, 10, 100)
  if (d !== undefined) cfg.maxDirtyFiles = d
  if (m !== undefined) cfg.maxMinutesSinceCommit = m
  if (w !== undefined) cfg.contextWrapPercent = w
  return cfg
}
export const isCodeFile = (path: string) => CODE_RE.test(path)

/** The one-click deep check: a full QA pass and security audit, fixing as it goes, ending in a report. */
export const QA_PROMPT = [
  'do a full QA pass and security audit of this project, and fix bugs along the way.',
  '1) QA: run the test suite, typecheck and lint; read the core flows and recent changes looking for real bugs (edge cases, error handling, race conditions, broken assumptions). add or fix tests where it makes sense.',
  '2) security: review for leaked secrets, injection (shell, SQL, path), unsafe file/process handling, auth and permission gaps, unsafe deserialization, and dependency advisories (use the security-audit skill or /security-review if available).',
  "3) fix what you find with the smallest correct change, re-run the checks after each fix, and don't commit or push without asking me.",
  "4) finish with a full report: what you checked, every finding with severity (critical/high/medium/low), what you fixed (files and why), what's left and why, and anything I should decide.",
].join('\n')

/** Parses `git status --porcelain=v2 --branch`. */
export function parseGitStatus(out: string) {
  let branch = '', ahead = 0, dirty = 0
  for (const line of out.split('\n')) {
    if (line.startsWith('# branch.head ')) branch = line.slice(14)
    else if (line.startsWith('# branch.ab ')) ahead = Number(line.split(' ')[2]?.slice(1) ?? 0)
    else if (line && !line.startsWith('#')) dirty++
  }
  return { branch, ahead, dirty }
}

/** Reads `gh pr view --json number,reviewDecision,statusCheckRollup`. */
export function parsePr(json: string): Pick<Signals, 'ci' | 'prNumber' | 'changesRequested'> {
  try {
    const pr = JSON.parse(json) as { number?: number; reviewDecision?: string; statusCheckRollup?: Record<string, string>[] }
    const checks = pr.statusCheckRollup ?? []
    const results = checks.map(c => (c.conclusion || c.state || c.status || '').toUpperCase())
    const ci = !checks.length ? null
      : results.some(r => ['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'].includes(r)) ? 'fail'
      : results.some(r => ['PENDING', 'IN_PROGRESS', 'QUEUED', 'WAITING', 'EXPECTED', ''].includes(r)) ? 'pending'
      : 'pass'
    return { ci, prNumber: pr.number ?? null, changesRequested: pr.reviewDecision === 'CHANGES_REQUESTED' }
  } catch {
    return { ci: null, prNumber: null, changesRequested: false }
  }
}

const snip = (label: string, text: string, action?: Snippet['action']): Snippet => (action ? { label, text, action } : { label, text })

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`

// Voice: a chill friend. Plain words, the real number/file/command, and the "why" in one breath.
export function advise(s: Signals, now = Date.now(), cfg: LaviConfig = {}): Advice {
  const maxDirty = cfg.maxDirtyFiles ?? MAX_DIRTY_FILES
  const maxMinutes = cfg.maxMinutesSinceCommit ?? MAX_MINUTES_SINCE_COMMIT
  const wrapAt = cfg.contextWrapPercent ?? CONTEXT_WRAP_PERCENT
  const testCmd = cfg.testCommand ? `\`${cfg.testCommand}\`` : 'the tests'
  const steps: Step[] = []
  const dirty = s.dirtyFiles > 0
  const minutesSinceCommit = s.lastCommitAt ? (now - s.lastCommitAt) / 60000 : Infinity
  const sinceCommit = Number.isFinite(minutesSinceCommit) ? `${Math.round(minutesSinceCommit)} min` : 'ever (no commits yet)'
  const pr = s.prNumber ? `PR #${s.prNumber}` : 'this branch'

  if (s.lastTest === 'fail')
    steps.push({
      id: 'fix-tests', mood: 'worried',
      snippets: [
        snip('fix the root cause', `the tests are failing. run ${testCmd}, show me what broke, and fix the actual cause. don't just patch the test to pass.`),
        snip('explain first', `run ${testCmd} and explain in plain words why they fail before changing anything.`),
      ],
      text: "tests are failing. let's fix those first.",
      why: 'piling new changes on top of a broken test makes it way harder to tell what went wrong.',
    })
  if (s.ci === 'fail')
    steps.push({
      id: 'fix-ci', mood: 'worried',
      snippets: [
        snip('fix CI', `CI is failing on ${pr}. look at the failing checks with \`gh pr checks\` and their logs, find the cause, and fix it.`),
        snip('why is CI red?', `CI is red on ${pr}. explain in plain words which checks fail and why, before changing anything.`),
      ],
      text: `CI is red on ${pr}.`,
      why: "it passed for you but not on the server, so something's different there: env, versions or a test you didn't run.",
    })
  if (s.lastLint === 'fail')
    steps.push({
      id: 'fix-lint', mood: 'nudge',
      snippets: [
        snip('fix types/lint', 'the typecheck or linter is failing. run it, fix every error properly (no blanket ignores), then run it again.'),
      ],
      text: 'types or lint are broken.',
      why: 'these catch real bugs early. fixing them now is quicker than untangling them after more changes.',
    })
  if (s.changesRequested)
    steps.push({
      id: 'review', mood: 'nudge',
      snippets: [
        snip('address review', `read the review comments on ${pr} with gh, then address each one. tell me which ones you disagree with and why.`),
      ],
      text: `${pr} has changes requested.`,
      why: 'a reviewer asked for changes. clearing them gets this merged.',
    })
  if (s.editsSinceTest > 0 && s.lastTest !== 'fail')
    steps.push({
      id: 'run-tests', mood: 'nudge',
      snippets: [
        snip('run all tests', `run ${testCmd} and fix anything that fails.`),
        snip('just what changed', 'run only the tests that cover the files we changed this session, and tell me if anything is uncovered.'),
        snip('write tests', 'write tests for what we just built, then run them.'),
      ],
      text: 'quick test run?',
      why: `${plural(s.editsSinceTest, 'code edit')} since the last time tests ran. catching a break now is cheap; later it isn't.`,
    })
  if (dirty && s.isGit && s.branch && s.branch === s.defaultBranch)
    steps.push({
      id: 'branch', mood: 'nudge',
      snippets: [
        snip('make a branch', `create a new branch for this work with a short descriptive name, move my uncommitted changes onto it, and keep ${s.branch} clean.`),
      ],
      text: `you're working straight on ${s.branch}. spin up a branch first.`,
      why: `a branch is a safe sandbox: if this goes sideways, ${s.branch} stays clean.`,
    })
  if (dirty && (s.dirtyFiles > maxDirty || minutesSinceCommit > maxMinutes))
    steps.push({
      id: 'commit', mood: 'nudge',
      snippets: [
        snip('commit it', 'commit what we have with a clear message that says what changed and why.'),
        snip('split commits', 'split these changes into a few small logical commits with clear messages.'),
        snip('review first', 'give me a quick plain-language summary of everything that changed before we commit.'),
      ],
      text: "good time to save a checkpoint. commit what you've got.",
      why: `${plural(s.dirtyFiles, 'file')} changed and no commit in ${sinceCommit}. a commit is your undo button.`,
    })
  if (s.behind > 0 && s.branch && s.branch !== s.defaultBranch)
    steps.push({
      id: 'rebase', mood: 'nudge',
      snippets: [
        snip('rebase on main', `rebase this branch onto origin/${s.defaultBranch}, resolve any conflicts carefully, then run ${testCmd}.`),
      ],
      text: `${s.defaultBranch} moved on. rebase before you push.`,
      why: `${plural(s.behind, 'new commit')} on ${s.defaultBranch} you don't have yet. rebasing now keeps conflicts small.`,
    })
  if (s.contextPercent >= wrapAt)
    steps.push({
      id: 'wrap', mood: 'nudge',
      snippets: [
        snip('draft handoff', 'draft a SecondBrain handoff', 'handoff'),
        snip('write a handoff', "write a short handoff: what we did, what's left, and any gotchas, so a fresh session can pick it up."),
      ],
      text: `my memory's getting full (${s.contextPercent}%). let's write a quick handoff and start fresh.`,
      why: 'past this point I start forgetting earlier details. a handoff note keeps the important stuff, then /compact or a new session clears space.',
    })
  if (s.ahead > 0)
    steps.push({
      id: 'push', mood: 'calm',
      snippets: [
        snip('push it', 'push this branch.'),
        snip('push + PR', 'push this branch and open a pull request with a short summary of the changes.'),
      ],
      text: 'push your commits up.',
      why: `${plural(s.ahead, 'commit')} only live on this Mac right now. pushing backs them up.`,
    })
  if (steps.length === 0)
    steps.push({
      id: 'next', mood: 'happy',
      snippets: [
        snip("what's next?", "what's the most valuable next thing to work on here? give me 2-3 options with a one-line why for each."),
        snip('quick review', 'review the code we changed this session for bugs, edge cases or rough spots.'),
        snip('draft handoff', 'draft a SecondBrain handoff', 'handoff'),
      ],
      text: "nice, you're in a good spot. pick the next thing, or save progress to SecondBrain.",
      why: 'everything is committed and nothing is failing.',
    })

  return { mood: steps[0]!.mood, steps }
}

/** Splits Ask Lavi's reply into the advice and its `PROMPT: label | text` lines. */
export function parseAnswer(reply: string): Answer {
  const snippets: Snippet[] = []
  const keep: string[] = []
  for (const line of reply.split('\n')) {
    const m = line.match(/^\s*(?:[-*]\s*)?`?PROMPT:\s*`?(.+?)`?\s*$/i)
    if (!m) { keep.push(line); continue }
    const [label, ...rest] = m[1]!.split('|')
    const text = rest.join('|').trim() || label!.trim()
    const name = rest.length ? label!.trim() : text.split(/\s+/).slice(0, 3).join(' ')
    snippets.push({ label: name.length > 28 ? name.slice(0, 27) + '…' : name, text: text.slice(0, 2000) })
  }
  return { text: keep.join('\n').trim(), snippets: snippets.slice(0, 4) }
}

/** Markdown → plain text for reading aloud, capped so a long answer can't run up the bill. */
export function speakable(md: string, max = 600) {
  const t = md.replace(/```[\s\S]*?```/g, ' ').replace(/`([^`]*)`/g, '$1').replace(/[*_#>]+/g, '')
    .replace(/^\s*[-•]\s*/gm, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/\s+/g, ' ').trim()
  return t.length > max ? t.slice(0, t.lastIndexOf(' ', max)) + '…' : t
}

/**
 * The Focus mode that's on right now, from macOS's ~/Library/DoNotDisturb/DB/Assertions.json
 * ("com.apple.focus.work", …), or null when none is. Malformed input counts as none.
 */
export function parseFocus(json: string): string | null {
  try {
    const records = JSON.parse(json)?.data?.[0]?.storeAssertionRecords
    if (!Array.isArray(records) || records.length === 0) return null
    const mode = records[0]?.assertionDetails?.assertionDetailsModeIdentifier
    return typeof mode === 'string' && mode ? mode : 'focus'
  } catch {
    return null
  }
}
