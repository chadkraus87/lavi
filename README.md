# CodeBuddy: meet Lavi

**Lavi** is a little lavender robot with headphones and a coding buddy that suggests the next step in every Claude Code session. You see it in three places:

- **In the session** (desktop app, CLI, and the phone via Remote Control): a `🤖 lavi: next step` entry on the status line, a band of ready-to-send prompts above the message box, and a `/lavi` pane (`/buddy` works too).
- **On your desktop**: a small lavender robot with headphones, shown whenever the Claude app or a `claude` process is running. Its face shows the session's state. Hover over it to see the advice. Click it for the full list of steps and every session.
- **On your phone**: Claude Code's built-in Remote Control. Open any session in the Claude mobile app to message it. The buddy's status entry and pane draw there too, and it **pings you** when something is worth coming back for (see below).

```
 Claude Code session ─ codebuddy mod ─► status line + /buddy pane (desktop & mobile)
                                    └─► ~/.claude/codebuddy/sessions/<id>.json
 CodeBuddy.app (LaunchAgent) ─ reads those files ─► floating character + session menu
```

## Install

```bash
./install.sh
```

The script:
- builds `~/Applications/CodeBuddy.app` with `swiftc`
- installs the LaunchAgent `com.chadkraus.codebuddy`, so the character starts at login
- adds `mod/` to `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json`, keeping any entries already there. It backs up the file first to `settings.json.codebuddy-backup`.

New sessions load the buddy. Restart the Claude app so its sessions pick it up. `./install.sh --uninstall` undoes all of this.

## How it decides

Deterministic rules run after every turn and cost no tokens (`mod/hooks/rules.ts`). They are listed by priority:

| # | When | Suggests |
|---|------|----------|
| 1 | The last test run failed | Fix the failing tests |
| 2 | Code was edited since the last test run | Run the tests |
| 3 | Uncommitted changes on the default branch | Create a branch |
| 4 | More than 8 files changed, or no commit in over 45 min with changes | Commit a checkpoint |
| 5 | Context window is 70% full or more | Write a handoff, then /compact |
| 6 | Branch is ahead of upstream | Push |
| 7 | None of the above | Pick the next task / save progress |

The signals come from `git status`, `git log`, the session's context usage, and the session's own tool calls (edits and test commands). The thresholds are constants at the top of `rules.ts`.

For a model's opinion, run `/buddy next` or press **Ask buddy** in the pane. It forks the session, so the question reuses the cached context instead of re-sending it. This is the only part that costs tokens.

## How it talks

It talks like a chill friend: plain words, the real file, command or number, and the reason in a sentence. For example: *"good time to save a checkpoint. commit what you've got. 12 files changed and no commit in 50 min. a commit is your undo button."*

**Ask Lavi** (`/lavi next`) uses the same voice. Its prompt in `register.tsx` still requires the single best next step, the reasoning, the risk, and specific files and commands.

## Lavi's voice

Lavi talks in a chill-friend voice designed in ElevenLabs. The voice is saved as **Lavi** in your ElevenLabs library, id `HCx2PwbeGgmrPl8yw3w0`. The 17 short lines were recorded once (`desktop/voice/voice-*.mp3`; their text is in `desktop/voice/lines.json`) and play offline, so there's no API key on the Mac and no cost per use. Spoken lines carry the gist; the speech bubble shows the exact numbers and names.

| When | Lavi says |
|---|---|
| you click Lavi | the current advice ("tests are failing. let's fix those first.") or "all good" |
| the advice changes | that advice's line |
| a 3+ min task finishes while you're at the Mac | "done with that big one. come take a look." |
| a session opens | a greeting (at most every 10 min) |
| the Claude app opens again | "hey, welcome back!" greeting with a bubble (skips the 20 s spacing so it isn't swallowed by the goodbye) |
| the Claude app quits | a goodbye. Lavi stays on screen until it finishes, then hides |
| you copy a prompt from the menu | "copied. paste it in and hit enter." |

While Lavi talks, its screen-mouth moves with the loudness of the audio. Text appears in a cartoon speech bubble (bold headline, smaller detail line, tail pointing at Lavi) that flips to Lavi's other side when there's no room.

**Quiet rules:** at most one line every 20 s, except when you click. Silent in quiet hours (10pm–8am), unless you click. Menu → **Voice** has *Lavi talks* (on/off), Volume low/medium/high, and *Quiet 10pm–8am*.

**Not handled:** macOS doesn't let apps read whether a Focus mode is on, so use mute or quiet hours during meetings.

**Adding or changing a line:** edit `lines.json`, generate it with the Lavi voice (ElevenLabs `eleven_v3`), save it as `voice-<id>.mp3`, then rerun `./install.sh`.

## Ready-to-send prompts

Each piece of advice comes with 2–3 prompts you can send Claude straight away. Some examples:
- "run the tests and fix anything that fails"
- "commit what we have with a clear message that says what changed and why"
- "write a short handoff…"

**Ask buddy** also suggests prompts tailored to the session.

- **In the session:** a band above the message box shows the top advice and its prompts as buttons. Click one, or after ctrl+x tab press 1–3. The prompt **drops into your message box as a draft, and nothing is sent until you press Enter**, so you can edit it first. If you've already typed something, the prompt goes on a new line after it. × hides the band until the advice changes. The `/buddy` pane has buttons for every step and for Ask buddy's prompts.
- **Where a message box can't be filled** (the phone, or while a dialog is open), the prompt is copied to the clipboard instead.
- **Desktop robot:** each step in its menu has a submenu of prompts. Clicking one copies it, so you paste it into Claude with ⌘V.

The prompts live next to each rule in `mod/hooks/rules.ts`.

## Phone pings

The mod calls Claude Code's own `PushNotification` tool. That shows a desktop banner, and pushes to your phone when the session is connected to Remote Control (on by default now). The tool **skips the ping when you're at the computer**.

| Ping | When |
|---|---|
| long task finished | a turn ran 3+ min (says what's next) |
| something broke | tests failed during the turn, or it ended in an error |
| waiting on you | Claude asked you a question, or needs your OK to run something |
| gentle nudge | 30 min after a turn, there's still uncommitted work (once per session) |

Pings are spaced at least 2 minutes apart per session. The wording and thresholds live in `mod/hooks/pings.ts`. Commands: `/lavi pings off`, `/lavi pings on`, `/lavi pings test`.

## Moods

The robot art is in `desktop/art/` (made with Higgsfield; how is in that folder's README). If the art is missing, the app draws a simple blob instead.

| Mood | When |
|---|---|
| happy (thumbs up) | good spot |
| nudge (hand up) | a step is suggested |
| worried (red face) | tests failing |
| calm (blinks now and then) | nothing urgent |
| busy (`•••`, typing) | Claude is working |
| sleepy (zZ) | no session, or idle 30+ min |

It bobs gently, and faster while busy. When the system's Reduce Motion setting is on, it stays still. The size is in the menu: Small, Medium or Large.

## Desktop menu

Click the character to see:
- the focus session's steps
- **Sessions waiting on you** (`claude://code/needs-input`)
- **New Claude Code session**
- **Live** buddy sessions and the 15 most **Recent** transcripts. Each one can be:
  - **Opened in the Claude app** (`claude://resume?session=<id>`, which imports a CLI session into the app)
  - **Resumed in Terminal** (`claude --resume <id>`)
  - copied as a resume command
- **Hide for 1 hour**, **Quit**

Quit means quit: the LaunchAgent restarts the app only after a crash. Drag the character to move it, and it remembers the spot.

## Develop

```bash
cd mod && claude plugin validate . && claude plugin test . && tsc -p .
```

`tsc` needs the engine's types in `mod/.claude-plugin/types/` (gitignored). Regenerate them with `/plugin-types mod/.claude-plugin/types` inside Claude Code.
