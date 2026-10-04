import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Advice, SessionFile, Signals } from '../types'
import { advise, isCodeFile, isTestCommand, parseGitStatus } from './rules'

const PANE = 'codebuddy'
const ASK =
  'You are my coding buddy. Looking at this session so far, what is the single best next step for me, and why? ' +
  'Answer in at most 3 short bullets. Be concrete (name files/commands).'

const signals = atom({ plugin: 'codebuddy', key: 'signals' } as const, {
  isGit: false, branch: '', defaultBranch: '', dirtyFiles: 0, ahead: 0,
  lastCommitAt: null, lastTest: null, editsSinceTest: 0, contextPercent: 0,
} as Signals)
const advice = atom({ plugin: 'codebuddy', key: 'advice' } as const, null as Advice | null)
const answer = atom({ plugin: 'codebuddy', key: 'answer' } as const, null as string | null)
const isAsking = atom({ plugin: 'codebuddy', key: 'isAsking' } as const, false)

const git = async ($: EngineInterface, ...args: string[]) => {
  try {
    const r = await $.process.run(['git', ...args], { timeoutMs: 5000 })
    return r.exitCode === 0 ? r.stdout.trim() : null
  } catch {
    return null
  }
}

// Mirrors this session into ~/.claude/codebuddy/sessions/<id>.json for the desktop character.
const writeFile = async ($: EngineInterface, status: SessionFile['status']) => {
  const [home, id, cwd, a, s] = await Promise.all([$.env.get("HOME"), $.session.id(), $.session.cwd(), read($, advice), read($, signals)])
  if (!home) return
  const file: SessionFile = {
    id, cwd, project: cwd.split('/').pop() ?? cwd, branch: s.branch, status,
    mood: status === 'busy' ? 'busy' : (a?.mood ?? 'calm'),
    steps: a?.steps ?? [], updatedAt: Date.now(),
  }
  await $.fs.write(`${home}/.claude/codebuddy/sessions/${id}.json`, JSON.stringify(file, null, 2))
}

const refresh = async ($: EngineInterface) => {
  const status = await git($, 'status', '--porcelain=v2', '--branch')
  const prev = await read($, signals)
  let next: Signals = { ...prev, isGit: status !== null }
  if (status !== null) {
    const { branch, ahead, dirty } = parseGitStatus(status)
    const head = await git($, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    const last = await git($, 'log', '-1', '--format=%ct')
    next = {
      ...next, branch, ahead, dirtyFiles: dirty,
      defaultBranch: head?.replace(/^origin\//, '') || (branch === 'master' ? 'master' : 'main'),
      lastCommitAt: last ? Number(last) * 1000 : null,
    }
  }
  try {
    next.contextPercent = (await $.session.usage()).context.percent ?? 0
  } catch {}
  const a = advise(next)
  await update($, signals, () => next)
  await update($, advice, () => a)
  $.ui.status(`🐾 ${a.steps[0]!.text}`)
  await writeFile($, 'idle')
}

const ask = async ($: EngineInterface) => {
  await update($, isAsking, () => true)
  const r = await $.model.fork({ prompt: ASK })
  const text = r.isAnswered ? r.text : `Couldn't ask right now (${r.reason}).`
  await update($, answer, () => text)
  await update($, isAsking, () => false)
  return text
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'buddy', description: 'Coding buddy: next steps pane. `/buddy next` asks the model.' })
    const started = await next(e)
    await refresh($)
    return started
  })

  on('command.run', { command: 'buddy' }, async ($, e) => {
    if (e.args.trim() === 'next') return { text: await ask($) }
    await refresh($)
    await $.ui.open({ id: PANE, title: 'Buddy' })
    return { text: 'Buddy pane opened.' }
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny) return ran
    if ((e.tool === 'Edit' || e.tool === 'Write') && isCodeFile(e.file_path)) {
      await update($, signals, s => ({ ...s, editsSinceTest: s.editsSinceTest + 1 }))
    } else if (e.tool === 'NotebookEdit') {
      await update($, signals, s => ({ ...s, editsSinceTest: s.editsSinceTest + 1 }))
    } else if (e.tool === 'Bash' && isTestCommand(e.command)) {
      const lastTest = ran.isError ? 'fail' : 'pass'
      await update($, signals, (s): Signals => ({ ...s, editsSinceTest: 0, lastTest }))
    }
    return ran
  })

  on('turn.start', async ($, e, next) => {
    await writeFile($, 'busy')
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const ran = await next(e)
    await refresh($)
    return ran
  })

  on('session.end', async ($, e, next) => {
    await writeFile($, 'ended')
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Markdown } = $.ui.resolve(e)
    const [a, s, said, busy] = await Promise.all([read($, advice), read($, signals), read($, answer), read($, isAsking)])

    return (
      <Box flexDirection="column" gap={1}>
        <Text bold>Next steps</Text>
        {(a?.steps ?? []).map((step, i) => (
          <Box flexDirection="column">
            <Text bold={i === 0}>{i + 1}. {step.text}</Text>
            <Text dimColor>   {step.why}</Text>
          </Box>
        ))}
        <Text dimColor>
          {s.isGit ? `${s.branch} · ${s.dirtyFiles} changed · ` : 'not a git repo · '}
          tests {s.lastTest ?? 'not run'} · context {s.contextPercent}%
        </Text>
        <Box gap={1}>
          <Button key="ask" variant="primary" label={busy ? 'Thinking…' : 'Ask buddy'} onPress={() => void ask($)} />
          <Button key="refresh" label="Refresh" onPress={() => void refresh($)} />
        </Box>
        {said && <Markdown key="answer" text={said} />}
      </Box>
    )
  })
}
