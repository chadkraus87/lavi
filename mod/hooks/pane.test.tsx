import { expect, test } from 'claude-code/testing'

// The /buddy pane must draw on the desktop app and on the phone (Remote Control).
test('buddy pane renders on desktop and mobile', async $ => {
  for (const surface of ['terminal', 'desktop', 'mobile'] as const) {
    const ui = await $.ui.mount({
      plugin: 'codebuddy', surface, component: 'Pane', requestId: 'codebuddy',
      props: { title: 'Buddy', bodyColumns: 60 } as never, // engine fills the rest
    })
    expect(await ui.find({ key: 'ask' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Next steps/ })).toBeDefined()
    await ui.unmount()
  }
})
