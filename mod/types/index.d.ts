export type Mood = 'worried' | 'nudge' | 'calm' | 'happy' | 'busy'
export type Step = { id: string; text: string; why: string; mood: Mood }
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
      answer: string | null
      isAsking: boolean
      pings: Pings
    }
  }
}
