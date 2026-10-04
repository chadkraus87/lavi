import { expect, test } from 'claude-code/testing'

import type { Signals } from '../types'
import { advise, isCodeFile, isTestCommand, parseGitStatus } from './rules'

const NOW = 1_800_000_000_000
const base: Signals = {
  isGit: true, branch: 'feat', defaultBranch: 'main', dirtyFiles: 0, ahead: 0,
  lastCommitAt: NOW, lastTest: 'pass', editsSinceTest: 0, contextPercent: 10,
}
const ids = (s: Partial<Signals>) => advise({ ...base, ...s }, NOW).steps.map(x => x.id)

test('clean session is happy', () => {
  expect(advise(base, NOW).mood).toBe('happy')
  expect(ids({})).toEqual(['next'])
})

test('each rule triggers', () => {
  expect(ids({ lastTest: 'fail' })).toEqual(['fix-tests'])
  expect(ids({ editsSinceTest: 2 })).toEqual(['run-tests'])
  expect(ids({ dirtyFiles: 1, branch: 'main' })).toEqual(['branch'])
  expect(ids({ dirtyFiles: 9 })).toEqual(['commit'])
  expect(ids({ dirtyFiles: 1, lastCommitAt: NOW - 46 * 60000 })).toEqual(['commit'])
  expect(ids({ dirtyFiles: 1, lastCommitAt: NOW - 10 * 60000 })).toEqual(['next'])
  expect(ids({ contextPercent: 75 })).toEqual(['wrap'])
  expect(ids({ ahead: 2 })).toEqual(['push'])
})

test('priority order and mood come from the top step', () => {
  const a = advise({ ...base, lastTest: 'fail', editsSinceTest: 3, dirtyFiles: 20, branch: 'main', contextPercent: 90, ahead: 1 }, NOW)
  expect(a.steps.map(s => s.id)).toEqual(['fix-tests', 'branch', 'commit', 'wrap', 'push'])
  expect(a.mood).toBe('worried')
})

test('command and file classifiers', () => {
  expect(isTestCommand('pnpm test -- --run')).toBe(true)
  expect(isTestCommand('npx vitest run')).toBe(true)
  expect(isTestCommand('pytest -q')).toBe(true)
  expect(isTestCommand('ls test/')).toBe(false)
  expect(isCodeFile('/a/b.tsx')).toBe(true)
  expect(isCodeFile('/a/README.md')).toBe(false)
})

test('parses porcelain v2 status', () => {
  const out = '# branch.oid abc\n# branch.head feat/x\n# branch.upstream origin/feat/x\n# branch.ab +3 -0\n1 .M N... 100644 100644 100644 a b src/a.ts\n? new.ts\n'
  expect(parseGitStatus(out)).toEqual({ branch: 'feat/x', ahead: 3, dirty: 2 })
})
