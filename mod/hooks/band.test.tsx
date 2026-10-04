import { expect, mock, test } from 'claude-code/testing'

// After an advisory, the band above the message box offers snippet buttons, on desktop and phone.
test('band offers snippets for the top advice', async ($, on) => {
  mock.env(on, {}) // no HOME: the session file is skipped
  on('command.run', () => ({ text: '' })) // the engine beneath; the pane can't open in tests
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => { const { Box } = $.ui.resolve(e); return <Box key="engine" /> }) // stands in for the engine's own band
  await $.command.run({ command: 'buddy', args: '' } as never) // refreshes advice (no git in the test env: "good spot")
  for (const surface of ['terminal', 'desktop', 'mobile'] as const) {
    const ui = await $.ui.mount({
      plugin: 'codebuddy', surface, component: 'AbovePrompt', requestId: 'band',
      props: { bodyColumns: 80 } as never,
    })
    expect(await ui.find({ key: 'band-0' })).toBeDefined()
    expect(await ui.find({ key: 'band-hide' })).toBeDefined()
    await ui.unmount()
  }
})
