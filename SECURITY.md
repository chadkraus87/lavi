# Security policy

Lavi runs on your Mac with your permissions, so security reports are welcome.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through GitHub's
[private vulnerability reporting](https://github.com/chadkraus87/lavi/security/advisories/new),
with the steps to reproduce and what an attacker could do. You'll get a reply as soon as possible.

## Scope

- The Claude Code mod (`mod/`): command parsing, `.lavi.json` handling, pings, the staged-changes check,
  and the prompt hand-off from the desktop app (`fill.json`).
- The desktop app (`desktop/`): anything that runs a shell or AppleScript, opens URLs, reads files from
  `~/.claude`, or handles the ElevenLabs key.
- `install.sh`: edits to `~/.claude/settings.json` and the LaunchAgent.

## Design notes

- Lavi treats a repo's `.lavi.json`, session files, transcript names and staged file names as untrusted input.
- The pre-commit check reports file names only, never the matched secret.
- Every git call runs with `core.fsmonitor=false` and the repo's own filter drivers emptied (diffs also without
  external diff tools or textconv), so a repo's local config can't make Lavi run a program.
- A prompt handed over by the desktop app only fills the session it names, only as an unsent draft, and only if
  it is under 3 seconds old.
- The ElevenLabs key lives only in the macOS login Keychain; it is never written to disk or logged.
- Nothing is sent anywhere except pings (Claude Code's push service), `gh` status calls, and
  read-aloud text when you press the button.
