import { expect, test } from 'claude-code/testing'

import { approvalPing, canPush, LONG_TURN_MS, NO_PINGS, nudgePing, PING_GAP_MS, questionPing, turnPing } from './pings'

test('turn pings: error > failed tests > long task > nothing', () => {
  const base = { project: 'demo', durationMs: LONG_TURN_MS + 60_000, failed: true, errored: true, nextStep: 'Quick test run?' }
  expect(turnPing(base)).toContain('hit an error')
  expect(turnPing({ ...base, errored: false })).toContain('tests failed in demo')
  expect(turnPing({ ...base, errored: false, failed: false })).toBe('done with that big one in demo (4 min). next up: quick test run?')
  expect(turnPing({ ...base, errored: false, failed: false, durationMs: 30_000 })).toBeNull()
})

test('spam guard and off switch', () => {
  const p = { ...NO_PINGS, lastPushAt: 1_000_000 }
  expect(canPush(p, 1_000_000 + PING_GAP_MS - 1, true)).toBe(false)
  expect(canPush(p, 1_000_000 + PING_GAP_MS, true)).toBe(true)
  expect(canPush(p, 1_000_000 + PING_GAP_MS, false)).toBe(false)
})

test('approval pings say what claude wants to do, in plain words', () => {
  expect(approvalPing('demo', 'Bash', { command: 'rm -rf build' })).toBe('claude needs your ok in demo to run `rm -rf build`.')
  expect(approvalPing('demo', 'Edit', { file_path: '/a/b/app.ts' })).toBe('claude needs your ok in demo to change app.ts.')
  expect(approvalPing('demo', 'mcp__github__create_pr', {})).toBe('claude needs your ok in demo to use create_pr.')
})

test('messages stay one line and under the phone limit', () => {
  const long = questionPing('demo', 'which one?\n'.repeat(60))
  expect(long.length).toBeLessThanOrEqual(190)
  expect(long.includes('\n')).toBe(false)
  expect(nudgePing('demo', 1)).toBe("you've got 1 changed file in demo that aren't committed yet. want to lock them in?")
})
