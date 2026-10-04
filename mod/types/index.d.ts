export type Mood = 'worried' | 'nudge' | 'calm' | 'happy' | 'busy'
/** A ready-to-send prompt the buddy offers; picking one drops it in the message box (you still press Enter). */
export type Snippet = { label: string; text: string }
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
