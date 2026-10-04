# CodeBuddy

A coding buddy that suggests the next step in every Claude Code session. You see it in three places:

- **In the session** (desktop app, CLI, and the phone via Remote Control): a `🐾 next step` entry on the status line, plus a `/buddy` pane.
- **On your desktop**: a small floating character, shown whenever the Claude app or a `claude` process is running. Its face shows the session's state. Hover over it to see the advice. Click it for the full list of steps and every session.
- **On your phone**: Claude Code's built-in Remote Control. Open any session in the Claude mobile app to message it. The buddy's status entry and pane draw there too.

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

## Faces

| Face | Mood |
|------|------|
| red frown | worried (failing tests) |
| orange "o" | nudge (an action is suggested) |
| teal flat | calm |
| green smile | happy (good spot) |
| purple, eyes up, bobbing | busy (a turn is running) |

When the system's Reduce Motion setting is on, the character doesn't move.

## Desktop menu

Click the character to see:
- the focus session's steps
- **Sessions waiting for you** (`claude://code/needs-input`)
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
