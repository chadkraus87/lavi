import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderSurface } from 'claude-code'

import type { Advice, Answer, Pings, SessionFile, Signals } from '../types'
import { approvalPing, canPush, NO_PINGS, NUDGE_AFTER_MS, nudgePing, questionPing, turnPing } from './pings'
import { advise, isCodeFile, isTestCommand, parseAnswer, parseGitStatus } from './rules'

const PANE = 'codebuddy'
// The voice is casual; the thinking is not. Keep both halves of this prompt.
const ASK = [
  "You're Lavi, my coding buddy (a little lavender robot with headphones), looking over my shoulder at this session. Talk to me like a chill friend who happens to be a great senior engineer:",
  'plain words, short sentences, lowercase is fine, at most one emoji. If you need a technical term, explain it in a few words.',
  "Don't dumb down the thinking. Tell me the single best next step, why it's the best move right now, and any risk I should watch for.",
  'Be concrete: name the actual files, commands or numbers. At most 3 short bullets, no filler, no pep talk.',
  'Then add 2-3 ready-to-send prompts I could paste to you to act on it, one per line, exactly as `PROMPT: <2-4 word label> | <the full prompt, written as me talking to you>`.',
].join(' ')

const signals = atom({ plugin: 'codebuddy', key: 'signals' } as const, {
  isGit: false, branch: '', defaultBranch: '', dirtyFiles: 0, ahead: 0,
  lastCommitAt: null, lastTest: null, editsSinceTest: 0, contextPercent: 0,
} as Signals)
const advice = atom({ plugin: 'codebuddy', key: 'advice' } as const, null as Advice | null)
const answer = atom({ plugin: 'codebuddy', key: 'answer' } as const, null as Answer | null)
const bandHiddenFor = atom({ plugin: 'codebuddy', key: 'bandHiddenFor' } as const, null as string | null)
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
  const home = await $.env.get('HOME')
  if (!home) return
  const [id, cwd, a, s] = await Promise.all([$.session.id(), $.session.cwd(), read($, advice), read($, signals)])
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
  // A closed band comes back once the advice moves on.
  await update($, bandHiddenFor, h => (h === a.steps[0]!.id ? h : null))
  $.ui.status(`🤖 lavi: ${a.steps[0]!.text}`)
  await writeFile($, 'idle')
  return a
}

const ask = async ($: EngineInterface) => {
  await update($, isAsking, () => true)
  const r = await $.model.fork({ prompt: ASK })
  const a = r.isAnswered ? parseAnswer(r.text) : { text: `couldn't think that through right now (${r.reason}). try again in a sec?`, snippets: [] }
  await update($, answer, () => a)
  await update($, isAsking, () => false)
  return a
}

/**
 * Drops a snippet into the message box as a draft. Never sends it, and never wipes
 * what you already typed (it goes on a new line after it). Where no box can take it
 * (the phone, a dialog open), it lands on the clipboard instead.
 */
const useSnippet = async ($: EngineInterface, text: string, surface: RenderSurface) => {
  const box = await $.prompt.read()
  const filled = await $.prompt.fill({ text: box.text.trim() ? `\n${text}` : text, mode: 'append' })
  if (filled.isFilled) return $.ui.toast("it's in your message box. tweak it or hit enter.")
  const copied = await $.ui.copy({ text, surface })
  $.ui.toast(copied.isCopied ? 'copied. paste it into the message box.' : "couldn't drop that in. try lavi's pane on your computer.")
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
  const r = await $.tool.call({ tool: 'PushNotification', message: `lavi: ${message}`, status: 'proactive' })
  const said = r.deny ? `refused: ${r.deny}` : (r.text ?? 'sent')
  $.ui.log(`codebuddy ping: ${said}`, { to: 'debug' })
  if (!r.deny && !r.isError) await update($, pings, p => ({ ...p, lastPushAt: now }))
  return said
}

/** /lavi (and the old /buddy): the pane, `next` for advice, `pings on|off|test`. */
async function onCommand($: EngineInterface, e: { args: string }) {
  const [cmd, arg] = e.args.trim().split(/\s+/)
  if (cmd === 'next') {
    const a = await ask($)
    if (a.snippets.length) await $.ui.open({ id: PANE, title: 'Lavi' })
    const list = a.snippets.map((sn, i) => `${i + 1}. ${sn.label}: ${sn.text}`).join('\n')
    return { text: list ? `${a.text}\n\nready-to-send prompts (pick one in lavi's pane):\n${list}` : a.text }
  }
  if (cmd === 'pings' && (arg === 'on' || arg === 'off')) {
    await $.store.set('pingsOn', arg === 'on')
    return { text: arg === 'on' ? "pings are on. I'll buzz you when something's worth coming back for." : "pings off. I'll keep quiet." }
  }
  if (cmd === 'pings' && arg === 'test') {
    return { text: `test ping: ${await push($, `hey, it's me from ${await project($)}. pings work 👋`, true)}` }
  }
  if (cmd === 'pings') return { text: `pings are ${(await pingsOn($)) ? 'on' : 'off'}. use /lavi pings on, off or test.` }
  await refresh($)
  await $.ui.open({ id: PANE, title: 'Lavi' })
  return { text: "lavi's pane is open." }
}

export const register: Register = on => {
  let nudge: { cancel: () => void } | undefined // ponytail: lost on hot reload; the next turn re-arms it

  on('session.start', async ($, e, next) => {
    for (const name of ['lavi', 'buddy'])
      await $.command.register({
        name,
        description: 'Lavi, your coding buddy. Opens the pane; `next` asks for advice; `pings on|off|test`.',
      })
    const started = await next(e)
    await refresh($)
    return started
  })

  on('command.run', { command: 'lavi' }, onCommand)
  on('command.run', { command: 'buddy' }, onCommand)

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

  // The band above the message box: top advice + its snippets. Wraps whatever is
  // drawn beneath (other plugins' bands) instead of replacing it.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    const [a, hidden] = await Promise.all([read($, advice), read($, bandHiddenFor)])
    const top = a?.steps[0]
    if (e.props.hasSurvey || !top || top.id === hidden || !top.snippets.length) return below

    const { Box, Text, Button } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        <Box gap={1} flexWrap="wrap">
          <Text>🤖 lavi: {top.text}</Text>
          {top.snippets.map((sn, i) => (
            <Button key={`band-${i}`} hotkey={String(i + 1)} label={sn.label} onPress={() => void useSnippet($, sn.text, e.surface)} />
          ))}
          <Button key="band-hide" role="dismiss" label="×" onPress={() => void update($, bandHiddenFor, () => top.id)} />
        </Box>
        {below}
      </Box>
    )
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
            <Box gap={1} flexWrap="wrap">
              {step.snippets.map((sn, j) => (
                <Button key={`s-${step.id}-${j}`} label={sn.label} onPress={() => void useSnippet($, sn.text, e.surface)} />
              ))}
            </Box>
          </Box>
        ))}
        <Text dimColor>
          {s.isGit ? `${s.branch} · ${s.dirtyFiles} changed · ` : 'not a git repo · '}
          tests {s.lastTest ?? 'not run yet'} · memory {s.contextPercent}% full
        </Text>
        <Box gap={1}>
          <Button key="ask" variant="primary" label={busy ? 'thinking…' : 'Ask Lavi'} onPress={() => void ask($)} />
          <Button key="refresh" label="Refresh" onPress={() => void refresh($)} />
        </Box>
        {said && <Markdown key="answer" text={said.text} />}
        {said && said.snippets.length > 0 && (
          <Box gap={1} flexWrap="wrap">
            {said.snippets.map((sn, j) => (
              <Button key={`a-${j}`} label={sn.label} onPress={() => void useSnippet($, sn.text, e.surface)} />
            ))}
          </Box>
        )}
      </Box>
    )
  })
}
