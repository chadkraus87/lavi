import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderSurface } from 'claude-code'

import type { Advice, Answer, LaviConfig, Pings, SessionFile, Signals, Staged, Waiting } from '../types'
import { approvalPing, canPush, NO_PINGS, NUDGE_AFTER_MS, nudgePing, questionPing, redact, turnPing } from './pings'
import { advise, CI_CHECK_EVERY_MS, isCodeFile, isLintCommand, isPushCommand, isTestCommand, parseAnswer, parseFocus, filterOverrides, parseGitStatus, parsePr, QA_PROMPT, sanitizeConfig, scanStaged, speakable } from './rules'

const PANE = 'codebuddy'
// The voice is casual; the thinking is not. Keep both halves of this prompt.
const ASK = [
  "You're Lavi, my coding buddy (a little lavender robot with headphones), looking over my shoulder at this session. Talk to me like a chill friend who happens to be a great senior engineer:",
  'plain words, short sentences, lowercase is fine, at most one emoji. If you need a technical term, explain it in a few words.',
  "Don't dumb down the thinking. Tell me the single best next step, why it's the best move right now, and any risk I should watch for.",
  'Be concrete: name the actual files, commands or numbers. At most 3 short bullets, no filler, no pep talk.',
  'Then add 2-3 ready-to-send prompts I could paste to you to act on it, one per line, exactly as `PROMPT: <2-4 word label> | <the full prompt, written as me talking to you>`.',
].join(' ')

// Lavi drafts it; you review it in the message box and press Enter.
const HANDOFF = [
  'Draft a SecondBrain session handoff for what we did in this session.',
  "Reply with ONLY a ready-to-send prompt addressed to you, starting exactly with: \"Update SecondBrain with this session's progress (the project note and the Session Handoff), following my memory rules:\"",
  'then short sections: Done, Decisions (with the why), Next steps, Gotchas. Be specific: files, commands, numbers. No preamble, no closing line.',
].join(' ')

const signals = atom({ plugin: 'codebuddy', key: 'signals' } as const, {
  isGit: false, branch: '', defaultBranch: '', dirtyFiles: 0, ahead: 0,
  lastCommitAt: null, lastTest: null, editsSinceTest: 0, contextPercent: 0,
  lastLint: null, behind: 0, ci: null, prNumber: null, changesRequested: false, ciCheckedAt: 0, celebrate: null, staged: null,
} as Signals)
const advice = atom({ plugin: 'codebuddy', key: 'advice' } as const, null as Advice | null)
const answer = atom({ plugin: 'codebuddy', key: 'answer' } as const, null as Answer | null)
const bandHiddenFor = atom({ plugin: 'codebuddy', key: 'bandHiddenFor' } as const, null as string | null)
const isAsking = atom({ plugin: 'codebuddy', key: 'isAsking' } as const, false)
const pings = atom({ plugin: 'codebuddy', key: 'pings' } as const, NO_PINGS as Pings)
const waiting = atom({ plugin: 'codebuddy', key: 'waiting' } as const, null as Waiting)

let noFilters: string[] = [] // this repo's own filter drivers, emptied (see filterOverrides); refreshed each refresh

const git = async ($: EngineInterface, ...args: string[]) => {
  try {
    // core.fsmonitor off and filters emptied: a repo's local config can point either at any program, and
    // git status would run it.
    const r = await $.process.run(['git', '-c', 'core.fsmonitor=false', ...noFilters, ...args], { timeoutMs: 5000 })
    return r.exitCode === 0 ? r.stdout.trim() : null
  } catch {
    return null
  }
}

let cfg: LaviConfig = {} // ponytail: re-read every refresh; cheap, and edits to .lavi.json apply on the next turn

/** A repo's optional .lavi.json (quiet, testCommand, thresholds). */
const loadConfig = async ($: EngineInterface): Promise<LaviConfig> => {
  try {
    return sanitizeConfig(JSON.parse(await $.fs.read(`${await projectDir($)}/.lavi.json`)))
  } catch {
    return {}
  }
}

let root = '' // the repo's top folder, so a `cd` into a subfolder doesn't rename the session
const projectDir = async ($: EngineInterface) => root || (await $.session.cwd())
const project = async ($: EngineInterface) => {
  const dir = await projectDir($)
  return dir.split('/').pop() || dir
}

// Mirrors this session into ~/.claude/codebuddy/sessions/<id>.json for the desktop character.
const writeFile = async ($: EngineInterface, status: SessionFile['status']) => {
  const home = await $.env.get('HOME')
  if (!home) return
  const [id, cwd, a, s, w] = await Promise.all([$.session.id(), projectDir($), read($, advice), read($, signals), read($, waiting)])
  // In the desktop app, its own session id lets the robot open this session instead of importing a copy.
  const host = await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')
  const appId = host && /^local_[A-Za-z0-9-]{1,64}$/.test(host) ? host : undefined
  const file: SessionFile = {
    id, cwd, project: cwd.split('/').pop() ?? cwd, branch: s.branch, status,
    mood: status === 'busy' ? 'busy' : (a?.mood ?? 'calm'),
    steps: a?.steps ?? [], updatedAt: Date.now(), quiet: cfg.quiet === true, celebrate: s.celebrate, appId, waiting: w,
  }
  await $.fs.write(`${home}/.claude/codebuddy/sessions/${id}.json`, JSON.stringify(file, null, 2))
}

/**
 * The pre-commit check: what's staged, scanned for secrets, .env files, big untested changes and new TODOs.
 * No external diff tools or textconv filters: a repo's own config could point those at any program.
 */
const checkStaged = async ($: EngineInterface): Promise<Staged | null> => {
  // -z and --no-renames: real paths, never "dir/{a => b}" or a quoted escape, so a staged .env can't hide.
  const numstat = await git($, 'diff', '--cached', '--numstat', '-z', '--no-renames', '--no-ext-diff', '--no-textconv')
  if (!numstat) return null
  const diff = await git($, 'diff', '--cached', '-U0', '--no-renames', '--no-color', '--no-ext-diff', '--no-textconv')
  return scanStaged(numstat, (diff ?? '').slice(0, 400_000))
}

/** Claude is (or stops being) blocked on you; the desktop robot shows it. */
const setWaiting = async ($: EngineInterface, w: Waiting) => {
  const before = await read($, waiting)
  if (!before && !w) return
  await update($, waiting, () => w)
  await writeFile($, 'busy')
}

let approvalFor = '' // the tool whose approval dialog is up

let lastFillAt = 0 // ponytail: module memory; after a hot reload the 3 s staleness check stops replays

/**
 * The desktop robot's prompt buttons: it writes {to, text | action, at, id} to fill.json and this
 * session, if it's the one named, drops the text into its own message box (never sends it), then
 * answers in fill-ack.json so the robot knows whether to fall back to the clipboard.
 */
const fillFromDesktop = async ($: EngineInterface) => {
  const home = await $.env.get('HOME')
  if (!home) return
  let req: { to?: unknown; text?: unknown; action?: unknown; at?: unknown; id?: unknown }
  try { req = JSON.parse(await $.fs.read(`${home}/.claude/codebuddy/fill.json`)) } catch { return }
  if (typeof req.at !== 'number' || req.at <= lastFillAt) return
  lastFillAt = req.at
  // 3 s: the robot falls back to the clipboard after 3.5 s, so a late fill never lands twice.
  if (req.to !== (await $.session.id()) || Date.now() - req.at > 3_000) return
  const ack = (ok: boolean, why?: string) =>
    $.fs.write(`${home}/.claude/codebuddy/fill-ack.json`, JSON.stringify({ id: req.id, ok, why, at: Date.now() })).catch(() => {})
  if (req.action === 'handoff') {
    await ack(true, 'handoff')
    return draftHandoff($, 'desktop')
  }
  if (typeof req.text !== 'string' || !req.text.trim() || req.text.length > 10_000) return ack(false, 'bad request')
  const box = await $.prompt.read()
  const filled = await $.prompt.fill({ text: box.text.trim() ? `\n${req.text}` : req.text, mode: 'append' })
  await $.store.set('lastFill', filled.isFilled ? 'box (from desktop Lavi)' : `desktop Lavi fell back to the clipboard (${filled.refusal ?? 'refused'})`)
  if (filled.isFilled) $.ui.toast("lavi put it in your message box. tweak it or hit enter.")
  await ack(filled.isFilled, filled.refusal)
}

const refresh = async ($: EngineInterface) => {
  // Reading config runs nothing.
  noFilters = filterOverrides((await git($, 'config', '--local', '--name-only', '--get-regexp', '^filter\\.')) ?? '')
  const status = await git($, 'status', '--porcelain=v2', '--branch')
  root = status === null ? '' : ((await git($, 'rev-parse', '--show-toplevel')) ?? '')
  const prev = await read($, signals)
  let next: Signals = { ...prev, isGit: status !== null }
  if (status !== null) {
    const { branch, ahead, dirty } = parseGitStatus(status)
    const head = await git($, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    const last = await git($, 'log', '-1', '--format=%ct')
    const defaultBranch = head?.replace(/^origin\//, '') || (branch === 'master' ? 'master' : 'main')
    // Behind the default branch, as of the last fetch (no network here).
    const behind = await git($, 'rev-list', '--count', `HEAD..origin/${defaultBranch}`)
    next = {
      ...next, branch, ahead, dirtyFiles: dirty, defaultBranch,
      lastCommitAt: last ? Number(last) * 1000 : null, behind: Number(behind ?? 0) || 0,
      staged: await checkStaged($),
    }
    // CI and review state for this branch's PR, via gh, at most every 5 min (it's a network call).
    if (Date.now() - next.ciCheckedAt > CI_CHECK_EVERY_MS) {
      next.ciCheckedAt = Date.now()
      try {
        const r = await $.process.run(['gh', 'pr', 'view', '--json', 'number,reviewDecision,statusCheckRollup'], { timeoutMs: 8000 })
        Object.assign(next, r.exitCode === 0 ? parsePr(r.stdout) : { ci: null, prNumber: null, changesRequested: false })
      } catch {} // no gh, not logged in, or offline: CI rules just stay quiet
    }
  }
  cfg = await loadConfig($)
  try {
    next.contextPercent = (await $.session.usage()).context.percent ?? 0
  } catch {}
  const a = advise(next, Date.now(), cfg)
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
  try {
    const r = await $.model.fork({ prompt: ASK })
    const a: Answer = r.isAnswered ? parseAnswer(r.text) : { text: `couldn't think that through right now (${r.reason}). try again in a sec?`, snippets: [] }
    await update($, answer, () => a)
    return a
  } catch {
    const a: Answer = { text: "couldn't ask the model right now. try again in a sec?", snippets: [] }
    await update($, answer, () => a)
    return a
  } finally {
    await update($, isAsking, () => false) // never leave the pane stuck on "thinking…"
  }
}

/**
 * Drops a snippet into the message box as a draft. Never sends it, and never wipes
 * what you already typed (it goes on a new line after it). Where no box can take it
 * (the phone, a dialog open), it lands on the clipboard instead.
 */
const useSnippet = async ($: EngineInterface, text: string, surface: RenderSurface) => {
  const box = await $.prompt.read()
  const filled = await $.prompt.fill({ text: box.text.trim() ? `\n${text}` : text, mode: 'append' })
  if (filled.isFilled) {
    await $.store.set('lastFill', `box (${surface})`)
    return $.ui.toast("it's in your message box. tweak it or hit enter.")
  }
  const copied = await $.ui.copy({ text, surface })
  await $.store.set('lastFill', copied.isCopied ? `clipboard (${surface}, box said ${filled.refusal ?? 'no'})` : `failed (${surface})`)
  $.ui.toast(copied.isCopied ? 'copied. paste it into the message box.' : "couldn't drop that in. try lavi's pane on your computer.")
}

/** Lavi drafts a SecondBrain handoff from this session and drops it in the message box to review. */
const draftHandoff = async ($: EngineInterface, surface: RenderSurface) => {
  $.ui.toast('drafting a handoff… give me a sec.')
  const r = await $.model.fork({ prompt: HANDOFF })
  if (!r.isAnswered) return $.ui.toast(`couldn't draft it right now (${r.reason}).`)
  await useSnippet($, r.text.trim(), surface)
}

/** Asks the desktop robot to read text aloud in Lavi's voice (live ElevenLabs, if you've added a key). */
const readAloud = async ($: EngineInterface, text: string) => {
  const home = await $.env.get('HOME')
  if (!home) return
  await $.fs.write(`${home}/.claude/codebuddy/say.json`, JSON.stringify({ text: speakable(text), at: Date.now() }))
  $.ui.toast("lavi's reading it out (needs your ElevenLabs key in Lavi's settings).")
}

const pick = ($: EngineInterface, sn: { text: string; action?: 'handoff' }, surface: RenderSurface) =>
  sn.action === 'handoff' ? draftHandoff($, surface) : useSnippet($, sn.text, surface)

const pingsOn = async ($: EngineInterface) => (await $.store.get('pingsOn')) !== false

/**
 * Sends a ping through Claude Code's own PushNotification tool: a desktop banner,
 * and a phone push when Remote Control is connected. The tool itself skips it when
 * you're at the computer. Returns what the tool said, for /buddy ping-test.
 */
const push = async ($: EngineInterface, message: string, force = false) => {
  const now = Date.now()
  if (!force && (cfg.quiet || !canPush(await read($, pings), now, await pingsOn($)))) return 'held back (spam guard, pings off, or a quiet repo)'
  const r = await $.tool.call({ tool: 'PushNotification', message: `lavi: ${redact(message)}`, status: 'proactive' })
  const said = r.deny ? `refused: ${r.deny}` : (r.text ?? 'sent')
  $.ui.log(`codebuddy ping: ${said}`, { to: 'debug' })
  if (!r.deny && !r.isError) await update($, pings, p => ({ ...p, lastPushAt: now }))
  await $.store.set('lastPing', `${new Date(now).toLocaleString()}: ${said}`)
  return said
}

/**
 * macOS keeps the active Focus in a file only apps with Full Disk Access can read. Claude Code can; the desktop
 * robot can't. So the mod relays it: every 30 s it writes {on, mode, at} for the robot, which treats anything
 * older than 2 min as stale. A failed read writes nothing, so it never claims "off" it can't see.
 */
const syncFocus = async ($: EngineInterface) => {
  const home = await $.env.get('HOME')
  if (!home) return
  let raw: string
  try { raw = await $.fs.read(`${home}/Library/DoNotDisturb/DB/Assertions.json`) } catch { return }
  const mode = parseFocus(raw)
  await $.fs.write(`${home}/.claude/codebuddy/focus-state.json`, JSON.stringify({ on: mode !== null, mode, at: Date.now() })).catch(() => {})
}

/** `/lavi doctor`: checks every moving part and says what's working. */
async function doctor($: EngineInterface) {
  const ok = (b: boolean) => (b ? '✓' : '✗')
  const run = async (argv: string[]) => {
    try { return (await $.process.run(argv, { timeoutMs: 8000 })).exitCode === 0 } catch { return false }
  }
  const home = (await $.env.get('HOME')) ?? ''
  const exists = async (p: string) => { try { await $.fs.stat(p); return true } catch { return false } }
  const [gitOk, ghOk, appUp, voiceOk, sessionOk, surfaces, s, cfgNow] = await Promise.all([
    run(['git', '--version']), run(['gh', 'auth', 'status']), run(['pgrep', '-x', 'CodeBuddy']),
    exists(`${home}/Applications/CodeBuddy.app/Contents/Resources/voice-greeting-1.mp3`),
    exists(`${home}/.claude/codebuddy/sessions/${await $.session.id()}.json`),
    $.session.surfaces(), read($, signals), loadConfig($),
  ])
  const watch = (await $.env.get('CLAUDE_CODE_PLUGIN_DIR_WATCH')) === '1'
  return [
    "lavi's checkup:",
    `${ok(gitOk)} git`,
    `${ok(ghOk)} gh logged in (CI and PR advice)${ghOk ? '' : ': run `gh auth login` to turn it on'}`,
    `${ok(sessionOk)} this session's file for the desktop robot`,
    `${ok(appUp)} desktop Lavi running${appUp ? '' : ': run ./install.sh in the codebuddy repo'}`,
    `${ok(voiceOk)} voice lines installed`,
    `${ok(watch)} mods hot-reload in desktop sessions`,
    `${ok(await pingsOn($))} pings ${cfgNow.quiet ? '(this repo is quiet via .lavi.json)' : ''}`,
    `   last ping: ${(await $.store.get('lastPing')) ?? 'none yet (try /lavi pings test)'}`,
    `   last prompt button: ${(await $.store.get('lastFill')) ?? 'none yet (click one in the band to test)'}`,
    `   last read-aloud: ${await $.fs.read(`${home}/.claude/codebuddy/read-aloud-status.txt`).catch(() => 'none yet (🔊 read it to me under an Ask Lavi answer)')}`,
    `   drawing on: ${surfaces.join(', ') || 'nothing yet'}${surfaces.includes('mobile') ? ' (your phone is attached)' : ''}`,
    `   tracking: ${s.editsSinceTest} edits since tests · tests ${s.lastTest ?? 'not run'} · lint ${s.lastLint ?? 'not run'} · CI ${s.ci ?? 'n/a'}${s.prNumber ? ` (PR #${s.prNumber})` : ''} · ${s.behind} behind ${s.defaultBranch || 'main'}`,
    `   .lavi.json: ${Object.keys(cfgNow).length ? JSON.stringify(cfgNow) : 'none'}`,
  ].join('\n')
}

/** /lavi (and the old /buddy): the pane, `next`, `doctor`, `qa`, `handoff`, `pings on|off|test`. */
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
  if (cmd === 'doctor') return { text: await doctor($) }
  if (cmd === 'settings') {
    const home = await $.env.get('HOME')
    if (home) await $.fs.write(`${home}/.claude/codebuddy/open-settings`, '')
    return { text: "opening lavi's settings on your desktop." }
  }
  if (cmd === 'qa') { await useSnippet($, QA_PROMPT, 'terminal'); return { text: 'the QA + security prompt is in your message box. hit enter when ready.' } }
  if (cmd === 'handoff') { await draftHandoff($, 'terminal'); return { text: 'handoff draft is in your message box. review it, then hit enter.' } }
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
        description: 'Lavi, your coding buddy. Opens the pane; `next` advice · `qa` full QA+security pass · `handoff` · `doctor` · `settings` · `pings on|off|test`.',
      })
    const started = await next(e)
    // The desktop robot's "Full QA + security pass" menu reads the same prompt the band uses.
    const home = await $.env.get('HOME')
    if (home) await $.fs.write(`${home}/.claude/codebuddy/qa-prompt.txt`, QA_PROMPT).catch(() => {})
    await syncFocus($)
    $.clock.every(30_000, () => void syncFocus($).catch(() => {}))
    // Requests already in fill.json are old: never replay them.
    if (home) lastFillAt = Math.max(lastFillAt, Number(JSON.parse(await $.fs.read(`${home}/.claude/codebuddy/fill.json`).catch(() => '{}')).at) || 0)
    $.clock.every(1000, () => void fillFromDesktop($).catch(() => {}))
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
      await setWaiting($, { kind: 'question', since: Date.now() })
      const q = (e as { questions?: { question?: string }[] }).questions?.[0]?.question
      if (q && !(await read($, pings)).waitingPushed) {
        await update($, pings, p => ({ ...p, waitingPushed: true }))
        void push($, questionPing(await project($), q)).catch(() => {})
      }
    }
    const ran = await next(e)
    // Answered: the question, or the approval this call waited on (ponytail: matched by tool name; an approved
    // long command keeps the badge until it ends, as no event fires the moment the dialog closes).
    if (e.tool === 'AskUserQuestion' && !e.agentId) await setWaiting($, null)
    else if (e.tool === approvalFor) { approvalFor = ''; await setWaiting($, null) }
    if (ran.deny) return ran
    // A command sent to the background hasn't finished yet: its result says nothing about pass/fail.
    const background = (e as { run_in_background?: boolean }).run_in_background === true
    if ((e.tool === 'Edit' || e.tool === 'Write') && isCodeFile(String(e.file_path))) {
      await update($, signals, s => ({ ...s, editsSinceTest: s.editsSinceTest + 1 }))
    } else if (e.tool === 'NotebookEdit') {
      await update($, signals, s => ({ ...s, editsSinceTest: s.editsSinceTest + 1 }))
    } else if (e.tool === 'Bash' && !background && isTestCommand(String(e.command))) {
      const lastTest = ran.isError ? 'fail' : 'pass'
      await update($, signals, (s): Signals => ({
        ...s, editsSinceTest: 0, lastTest,
        // red → green: worth a little celebration
        celebrate: s.lastTest === 'fail' && lastTest === 'pass' ? { kind: 'tests', at: Date.now() } : s.celebrate,
      }))
      if (lastTest === 'fail') await update($, pings, p => ({ ...p, turnFailed: true }))
    } else if (e.tool === 'Bash' && !background && isLintCommand(String(e.command))) {
      const lastLint = ran.isError ? 'fail' : 'pass'
      await update($, signals, (s): Signals => ({ ...s, lastLint }))
    } else if (e.tool === 'Bash' && !background && isPushCommand(String(e.command)) && !ran.isError) {
      await update($, signals, (s): Signals => ({ ...s, celebrate: { kind: 'push', at: Date.now() }, ciCheckedAt: 0 }))
    }
    return ran
  })

  // Claude needs your approval to run a tool. This fires only when the approval dialog is really shown:
  // a tool.check verdict of 'ask' can be settled by auto mode's classifier without you.
  // A subagent's approval needs you just the same.
  on('classic.PermissionRequest', async ($, e, next) => {
    approvalFor = e.tool_name
    await setWaiting($, { kind: 'approval', since: Date.now() })
    if (!(await read($, pings)).waitingPushed) {
      await update($, pings, p => ({ ...p, waitingPushed: true }))
      void push($, approvalPing(await project($), e.tool_name, e.tool_input)).catch(() => {})
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    await update($, pings, p => ({ ...p, turnFailed: false, waitingPushed: false }))
    await update($, waiting, () => null)
    await writeFile($, 'busy')
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId) return ran // a subagent's turn, not yours
    await update($, waiting, () => null)
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
    if (e.props.hasSurvey || !top || top.id === hidden) return below

    const { Box, Text, Button } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        <Box gap={1} flexWrap="wrap">
          <Text>🤖 lavi: {top.text}</Text>
          {top.snippets.map((sn, i) => (
            <Button key={`band-${i}`} hotkey={String(i + 1)} label={sn.label} onPress={() => void pick($, sn, e.surface)} />
          ))}
          <Button key="band-qa" hotkey="q" label="🛡 QA + security" onPress={() => void useSnippet($, QA_PROMPT, e.surface)} />
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
                <Button key={`s-${step.id}-${j}`} label={sn.label} onPress={() => void pick($, sn, e.surface)} />
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
          <Button key="qa" label="🛡 QA + security" onPress={() => void useSnippet($, QA_PROMPT, e.surface)} />
          <Button key="handoff" label="SecondBrain handoff" onPress={() => void draftHandoff($, e.surface)} />
          <Button key="refresh" label="Refresh" onPress={() => void refresh($)} />
        </Box>
        {said && <Markdown key="answer" text={said.text} />}
        {said && <Button key="read" label="🔊 read it to me" onPress={() => void readAloud($, said.text)} />}
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
