import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Advice, Pings, SessionFile, Signals } from '../types'
import { approvalPing, canPush, NO_PINGS, NUDGE_AFTER_MS, nudgePing, questionPing, turnPing } from './pings'
import { advise, isCodeFile, isTestCommand, parseGitStatus } from './rules'

const PANE = 'codebuddy'
// The voice is casual; the thinking is not. Keep both halves of this prompt.
const ASK = [
  "You're my coding buddy, looking over my shoulder at this session. Talk to me like a chill friend who happens to be a great senior engineer:",
  'plain words, short sentences, lowercase is fine, at most one emoji. If you need a technical term, explain it in a few words.',
  "Don't dumb down the thinking. Tell me the single best next step, why it's the best move right now, and any risk I should watch for.",
  'Be concrete: name the actual files, commands or numbers. At most 3 short bullets, no filler, no pep talk.',
].join(' ')

const signals = atom({ plugin: 'codebuddy', key: 'signals' } as const, {
  isGit: false, branch: '', defaultBranch: '', dirtyFiles: 0, ahead: 0,
  lastCommitAt: null, lastTest: null, editsSinceTest: 0, contextPercent: 0,
} as Signals)
const advice = atom({ plugin: 'codebuddy', key: 'advice' } as const, null as Advice | null)
const answer = atom({ plugin: 'codebuddy', key: 'answer' } as const, null as string | null)
const isAsking = atom({ plugin: 'codebuddy', key: 'isAsking' } as const, false)
const pings = atom({ plugin: 'codebuddy', key: 'pings' } as const, NO_PINGS as Pings)

const git = async ($: EngineInterface, ...args: string[]) => {
  try {
    const r = await $.process.run(['git', ...args], { timeoutMs: 5000 })
    return r.exitCode === 0 ? r.stdout.trim() : null
  } catch {
    return null
  }
}

const project = async ($: EngineInterface) => {
  const cwd = await $.session.cwd()
  return cwd.split('/').pop() || cwd
}

// Mirrors this session into ~/.claude/codebuddy/sessions/<id>.json for the desktop character.
const writeFile = async ($: EngineInterface, status: SessionFile['status']) => {
  const [home, id, cwd, a, s] = await Promise.all([$.env.get('HOME'), $.session.id(), $.session.cwd(), read($, advice), read($, signals)])
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
  $.ui.status(`🤖 ${a.steps[0]!.text}`)
  await writeFile($, 'idle')
  return a
}

const ask = async ($: EngineInterface) => {
  await update($, isAsking, () => true)
  const r = await $.model.fork({ prompt: ASK })
  const text = r.isAnswered ? r.text : `couldn't think that through right now (${r.reason}). try again in a sec?`
  await update($, answer, () => text)
  await update($, isAsking, () => false)
  return text
}

const pingsOn = async ($: EngineInterface) => (await $.store.get('pingsOn')) !== false

/**
 * Sends a ping through Claude Code's own PushNotification tool: a desktop banner,
 * and a phone push when Remote Control is connected. The tool itself skips it when
 * you're at the computer. Returns what the tool said, for /buddy ping-test.
 */
const push = async ($: EngineInterface, message: string, force = false) => {
  const now = Date.now()
  if (!force && !canPush(await read($, pings), now, await pingsOn($))) return 'held back (spam guard or pings off)'
  const r = await $.tool.call({ tool: 'PushNotification', message, status: 'proactive' })
  const said = r.deny ? `refused: ${r.deny}` : (r.text ?? 'sent')
  $.ui.log(`codebuddy ping: ${said}`, { to: 'debug' })
  if (!r.deny && !r.isError) await update($, pings, p => ({ ...p, lastPushAt: now }))
  return said
}

export const register: Register = on => {
  let nudge: { cancel: () => void } | undefined // ponytail: lost on hot reload; the next turn re-arms it

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'buddy',
      description: 'Coding buddy. `/buddy` opens the pane, `/buddy next` asks for advice, `/buddy pings on|off|test`.',
    })
    const started = await next(e)
    await refresh($)
    return started
  })

  on('command.run', { command: 'buddy' }, async ($, e) => {
    const [cmd, arg] = e.args.trim().split(/\s+/)
    if (cmd === 'next') return { text: await ask($) }
    if (cmd === 'pings' && (arg === 'on' || arg === 'off')) {
      await $.store.set('pingsOn', arg === 'on')
      return { text: arg === 'on' ? "pings are on. I'll buzz you when something's worth coming back for." : "pings off. I'll keep quiet." }
    }
    if (cmd === 'pings' && arg === 'test') {
      return { text: `test ping: ${await push($, `hey, it's your buddy from ${await project($)}. pings work 👋`, true)}` }
    }
    if (cmd === 'pings') return { text: `pings are ${(await pingsOn($)) ? 'on' : 'off'}. use /buddy pings on, off or test.` }
    await refresh($)
    await $.ui.open({ id: PANE, title: 'Buddy' })
    return { text: 'buddy pane is open.' }
  })

  on('prompt.submit', async ($, e, next) => {
    nudge?.cancel()
    nudge = undefined
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    // Claude is about to ask you something: ping before the dialog blocks the turn.
    if (e.tool === 'AskUserQuestion' && !e.agentId) {
      const q = (e as { questions?: { question?: string }[] }).questions?.[0]?.question
      if (q && !(await read($, pings)).waitingPushed) {
        await update($, pings, p => ({ ...p, waitingPushed: true }))
        void push($, questionPing(await project($), q))
      }
    }
    const ran = await next(e)
    if (ran.deny) return ran
    if ((e.tool === 'Edit' || e.tool === 'Write') && isCodeFile(String(e.file_path))) {
      await update($, signals, s => ({ ...s, editsSinceTest: s.editsSinceTest + 1 }))
    } else if (e.tool === 'NotebookEdit') {
      await update($, signals, s => ({ ...s, editsSinceTest: s.editsSinceTest + 1 }))
    } else if (e.tool === 'Bash' && isTestCommand(String(e.command))) {
      const lastTest = ran.isError ? 'fail' : 'pass'
      await update($, signals, (s): Signals => ({ ...s, editsSinceTest: 0, lastTest }))
      if (lastTest === 'fail') await update($, pings, p => ({ ...p, turnFailed: true }))
    }
    return ran
  })

  // Claude needs your approval to run a tool.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict.decision === 'ask' && e.tool !== 'AskUserQuestion' && !(await read($, pings)).waitingPushed) {
      await update($, pings, p => ({ ...p, waitingPushed: true }))
      void push($, approvalPing(await project($), e.tool, e.input))
    }
    return verdict
  })

  on('turn.start', async ($, e, next) => {
    await update($, pings, p => ({ ...p, turnFailed: false, waitingPushed: false }))
    await writeFile($, 'busy')
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId) return ran // a subagent's turn, not yours
    const a = await refresh($)
    const p = await read($, pings)
    const name = await project($)
    const msg = e.isAborted ? null : turnPing({
      project: name, durationMs: e.durationMs, failed: p.turnFailed,
      errored: e.reason === 'error', nextStep: a.steps[0]?.text,
    })
    if (msg) await push($, msg)

    // Gentle nudge: still uncommitted work 30 min after this turn, once per session.
    nudge?.cancel()
    nudge = undefined
    const s = await read($, signals)
    if (s.dirtyFiles > 0 && !p.nudged) {
      nudge = $.clock.after(NUDGE_AFTER_MS, async () => {
        const now = await read($, signals)
        if (now.dirtyFiles === 0 || (await read($, pings)).nudged) return
        await update($, pings, q => ({ ...q, nudged: true }))
        await push($, nudgePing(name, now.dirtyFiles))
      })
    }
    return ran
  })

  on('session.end', async ($, e, next) => {
    nudge?.cancel()
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
          tests {s.lastTest ?? 'not run yet'} · memory {s.contextPercent}% full
        </Text>
        <Box gap={1}>
          <Button key="ask" variant="primary" label={busy ? 'thinking…' : 'Ask buddy'} onPress={() => void ask($)} />
          <Button key="refresh" label="Refresh" onPress={() => void refresh($)} />
        </Box>
        {said && <Markdown key="answer" text={said} />}
      </Box>
    )
  })
}
