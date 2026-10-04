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

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`

// Voice: a chill friend. Plain words, the real number/file/command, and the "why" in one breath.
export function advise(s: Signals, now = Date.now()): Advice {
  const steps: Step[] = []
  const dirty = s.dirtyFiles > 0
  const minutesSinceCommit = s.lastCommitAt ? (now - s.lastCommitAt) / 60000 : Infinity
  const sinceCommit = Number.isFinite(minutesSinceCommit) ? `${Math.round(minutesSinceCommit)} min` : 'ever (no commits yet)'

  if (s.lastTest === 'fail')
    steps.push({
      id: 'fix-tests', mood: 'worried',
      text: "tests are failing. let's fix those before anything else.",
      why: 'piling new changes on top of a broken test makes it way harder to tell what went wrong.',
    })
  if (s.editsSinceTest > 0 && s.lastTest !== 'fail')
    steps.push({
      id: 'run-tests', mood: 'nudge',
      text: 'quick test run?',
      why: `${plural(s.editsSinceTest, 'code edit')} since the last time tests ran. catching a break now is cheap; later it isn't.`,
    })
  if (dirty && s.isGit && s.branch && s.branch === s.defaultBranch)
    steps.push({
      id: 'branch', mood: 'nudge',
      text: `you're working straight on ${s.branch}. spin up a branch first.`,
      why: `a branch is a safe sandbox: if this goes sideways, ${s.branch} stays clean.`,
    })
  if (dirty && (s.dirtyFiles > MAX_DIRTY_FILES || minutesSinceCommit > MAX_MINUTES_SINCE_COMMIT))
    steps.push({
      id: 'commit', mood: 'nudge',
      text: "good time to save a checkpoint. commit what you've got.",
      why: `${plural(s.dirtyFiles, 'file')} changed and no commit in ${sinceCommit}. a commit is your undo button.`,
    })
  if (s.contextPercent >= CONTEXT_WRAP_PERCENT)
    steps.push({
      id: 'wrap', mood: 'nudge',
      text: `my memory's getting full (${s.contextPercent}%). let's write a quick handoff and start fresh.`,
      why: 'past this point I start forgetting earlier details. a handoff note keeps the important stuff, then /compact or a new session clears space.',
    })
  if (s.ahead > 0)
    steps.push({
      id: 'push', mood: 'calm',
      text: 'push your commits up.',
      why: `${plural(s.ahead, 'commit')} only live on this Mac right now. pushing backs them up.`,
    })
  if (steps.length === 0)
    steps.push({
      id: 'next', mood: 'happy',
      text: "nice, you're in a good spot. pick the next thing, or save progress to SecondBrain.",
      why: 'everything is committed and nothing is failing.',
    })

  return { mood: steps[0]!.mood, steps }
}
