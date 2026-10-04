import type { Advice, Signals, Step } from '../types'

// Tuning knobs.
export const MAX_DIRTY_FILES = 8
export const MAX_MINUTES_SINCE_COMMIT = 45
export const CONTEXT_WRAP_PERCENT = 70

const TEST_RE = /\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b|\bvitest\b|\bjest\b|\bpytest\b|\bgo test\b|\bcargo test\b|\bplaywright test\b|\bswift test\b|\bclaude plugin test\b/
const CODE_RE = /\.(tsx?|jsx?|mjs|cjs|py|go|rs|swift|rb|java|kt|cs|c|cc|cpp|h|php|vue|svelte|astro)$/

export const isTestCommand = (cmd: string) => TEST_RE.test(cmd)
export const isCodeFile = (path: string) => CODE_RE.test(path)

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

export function advise(s: Signals, now = Date.now()): Advice {
  const steps: Step[] = []
  const dirty = s.dirtyFiles > 0
  const minutesSinceCommit = s.lastCommitAt ? (now - s.lastCommitAt) / 60000 : Infinity

  if (s.lastTest === 'fail')
    steps.push({ id: 'fix-tests', text: 'Fix the failing tests before moving on.', why: 'The last test run failed.', mood: 'worried' })
  if (s.editsSinceTest > 0 && s.lastTest !== 'fail')
    steps.push({ id: 'run-tests', text: 'Run the tests.', why: `${s.editsSinceTest} code edit(s) since the last test run.`, mood: 'nudge' })
  if (dirty && s.isGit && s.branch && s.branch === s.defaultBranch)
    steps.push({ id: 'branch', text: 'Create a branch before going further.', why: `Uncommitted changes on ${s.branch}.`, mood: 'nudge' })
  if (dirty && (s.dirtyFiles > MAX_DIRTY_FILES || minutesSinceCommit > MAX_MINUTES_SINCE_COMMIT))
    steps.push({
      id: 'commit',
      text: 'Commit a checkpoint.',
      why: s.dirtyFiles > MAX_DIRTY_FILES
        ? `${s.dirtyFiles} files changed.`
        : `No commit in ${Number.isFinite(minutesSinceCommit) ? Math.round(minutesSinceCommit) + ' min' : 'this repo yet'}.`,
      mood: 'nudge',
    })
  if (s.contextPercent >= CONTEXT_WRAP_PERCENT)
    steps.push({ id: 'wrap', text: 'Wrap up: write a handoff, then /compact or start fresh.', why: `Context is ${s.contextPercent}% full.`, mood: 'nudge' })
  if (s.ahead > 0)
    steps.push({ id: 'push', text: 'Push your commits.', why: `${s.ahead} commit(s) ahead of upstream.`, mood: 'calm' })
  if (steps.length === 0)
    steps.push({ id: 'next', text: 'Good spot: pick the next task, or save progress to SecondBrain.', why: 'Tree clean and nothing failing.', mood: 'happy' })

  return { mood: steps[0]!.mood, steps }
}
