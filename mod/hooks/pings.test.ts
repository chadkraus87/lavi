import { expect, test } from 'claude-code/testing'

import { approvalPing, canPush, LONG_TURN_MS, NO_PINGS, nudgePing, PING_GAP_MS, questionPing, redact, turnPing } from './pings'

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

test('pings never carry credentials to a lock screen', () => {
  expect(redact('run `curl -H "Authorization: Bearer abcdef1234567890xyz" api`')).not.toContain('abcdef1234567890xyz')
  expect(redact('export OPENAI=sk-proj-AbCdEf1234567890')).not.toContain('AbCdEf1234567890')
  expect(redact('git push https://ghp_abcdefghijklmnop123456@github.com/x')).not.toContain('ghp_abcdefghijklmnop123456')
  expect(redact('mysql --password=hunter22 db')).toBe('mysql --password=••• db')
  expect(redact('API_KEY="abc123def456"')).not.toContain('abc123def456')
  expect(redact('quick question: which database should we use?')).toBe('quick question: which database should we use?')
  expect(redact('run `npm test` in codebuddy')).toBe('run `npm test` in codebuddy')
})
