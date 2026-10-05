export type Mood = 'worried' | 'nudge' | 'calm' | 'happy' | 'busy'
/** A ready-to-send prompt the buddy offers; picking one drops it in the message box (you still press Enter). */
export type Snippet = { label: string; text: string; action?: 'handoff' }
export type Step = { id: string; text: string; why: string; mood: Mood; snippets: Snippet[] }
/** The model's take from Ask buddy: the answer, plus the prompts it suggests. */
export type Answer = { text: string; snippets: Snippet[] }
export type Advice = { mood: Mood; steps: Step[] }

export type Signals = {
  isGit: boolean
  branch: string
  defaultBranch: string
  dirtyFiles: number
  ahead: number
  lastCommitAt: number | null
  lastTest: 'pass' | 'fail' | null
  editsSinceTest: number
  contextPercent: number
  lastLint: 'pass' | 'fail' | null
  /** commits on the default branch this branch doesn't have (from the last fetch) */
  behind: number
  ci: 'pass' | 'fail' | 'pending' | null
  prNumber: number | null
  changesRequested: boolean
  ciCheckedAt: number
  /** something worth a little celebration, for the desktop robot */
  celebrate: { kind: 'tests' | 'push'; at: number } | null
}

/** A repo's optional `.lavi.json`. */
export type LaviConfig = {
  /** no voice, no pings for this repo */
  quiet?: boolean
  testCommand?: string
  maxDirtyFiles?: number
  maxMinutesSinceCommit?: number
  contextWrapPercent?: number
}

/** Phone-ping bookkeeping for one session. */
export type Pings = {
  lastPushAt: number
  nudged: boolean
  turnFailed: boolean
  waitingPushed: boolean
}

/** What the desktop character reads from ~/.claude/codebuddy/sessions/<id>.json */
export type SessionFile = {
  id: string
  cwd: string
  project: string
  branch: string
  status: 'busy' | 'idle' | 'ended'
  mood: Mood
  steps: Step[]
  updatedAt: number
  quiet?: boolean
  celebrate?: { kind: 'tests' | 'push'; at: number } | null
  /** the Claude desktop app's own id for this session (local_…), when it runs there */
  appId?: string
}

declare module 'claude-code' {
  interface PluginState {
    codebuddy: {
      signals: Signals
      advice: Advice | null
      answer: Answer | null
      isAsking: boolean
      pings: Pings
      /** id of the advice whose band you closed; it comes back when the advice changes */
      bandHiddenFor: string | null
    }
  }
}
