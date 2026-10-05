import { expect, mock, test } from 'claude-code/testing'


// "Needs your OK" comes from the approval dialog really showing, not from a permission check that
// auto mode's classifier may settle without you. It clears once the call is done.
test('waiting on you: set by a real approval dialog, cleared when the tool finishes', async ($, on) => {
  mock.env(on, { HOME: '/home/t' })
  mock.store(on, { pingsOn: false })
  // The session file the desktop robot reads: catch each write, no disk.
  let session: { waiting?: { kind: string } | null } = {}
  on('fs.write', (_, e) => { if (e.path.includes('/sessions/')) session = JSON.parse(e.text); return { value: undefined } })
  on('session.id', () => ({ value: 'test-session' }))
  on('session.cwd', () => ({ value: '/home/t/proj' }))
  on('classic.PermissionRequest', () => ({})) // no settings hook decides: the dialog shows
  on('fs.read', () => ({ deny: 'no such file' }))
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: '' } }) as never) // no git here
  const waitingNow = () => session.waiting ?? null
  on('tool.check', () => ({ decision: 'ask' })) // an ask alone is not a dialog
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  await $.tool.check({ tool: 'Bash', input: { command: 'ls' } } as never)
  expect(waitingNow()).toBeNull()

  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -rf build' } } as never)
  expect(waitingNow()?.kind).toBe('approval')

  await $.tool.call({ tool: 'Bash', command: 'rm -rf build' } as never)
  expect(waitingNow()).toBeNull()
})

test("a subagent's approval counts too, and it clears when that tool finishes", async ($, on) => {
  mock.env(on, { HOME: '/home/t' })
  mock.store(on, { pingsOn: false })
  let session: { waiting?: { kind: string } | null } = {}
  on('fs.write', (_, e) => { if (e.path.includes('/sessions/')) session = JSON.parse(e.text); return { value: undefined } })
  on('session.id', () => ({ value: 'test-session' }))
  on('session.cwd', () => ({ value: '/home/t/proj' }))
  on('fs.read', () => ({ deny: 'no such file' }))
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: '' } }) as never)
  on('classic.PermissionRequest', () => ({}))
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  await $.classic.PermissionRequest({ tool_name: 'Write', tool_input: {}, agent_id: 'sub-1' } as never)
  expect(session.waiting?.kind).toBe('approval')
  await $.tool.call({ tool: 'Read', file_path: '/x' } as never) // some other tool finishing doesn't answer it
  expect(session.waiting?.kind).toBe('approval')
  await $.tool.call({ tool: 'Write', file_path: '/x', content: '' } as never)
  expect(session.waiting ?? null).toBeNull()
})
