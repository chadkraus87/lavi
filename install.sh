#!/bin/bash
# Builds and installs CodeBuddy: the desktop character (LaunchAgent) and the Claude Code mod.
# ./install.sh            install or update
# ./install.sh --uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/CodeBuddy.app"
AGENT="$HOME/Library/LaunchAgents/com.chadkraus.codebuddy.plist"
SETTINGS="$HOME/.claude/settings.json"
MOD="$ROOT/mod"

# Adds (or with "remove", drops) the mod folder in env.CLAUDE_CODE_PLUGIN_DIRS, keeping other entries.
plugin_dirs() {
  mkdir -p "$(dirname "$SETTINGS")"
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
  # Keep the first backup (your settings before CodeBuddy ever touched them); later runs don't overwrite it.
  [[ -f "$SETTINGS.codebuddy-backup" ]] || cp "$SETTINGS" "$SETTINGS.codebuddy-backup"
  python3 - "$SETTINGS" "$MOD" "$1" <<'PY'
import json, os, sys, tempfile
path, mod, mode = sys.argv[1:]
s = json.load(open(path))
env = s.setdefault("env", {})
dirs = [d for d in env.get("CLAUDE_CODE_PLUGIN_DIRS", "").split(":") if d and d != mod]
if mode == "add": dirs.append(mod)
before = s["env"].get("CLAUDE_CODE_PLUGIN_DIRS")
if dirs: env["CLAUDE_CODE_PLUGIN_DIRS"] = ":".join(dirs)
else: env.pop("CLAUDE_CODE_PLUGIN_DIRS", None)
print(f"CLAUDE_CODE_PLUGIN_DIRS: {before!r} -> {env.get('CLAUDE_CODE_PLUGIN_DIRS')!r}")
# Write a temp file and swap it in, so a crash mid-write can't leave settings.json truncated.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2); f.write("\n")
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
PY
}

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID/com.chadkraus.codebuddy" 2>/dev/null || true
  rm -rf "$APP" "$AGENT" "$AGENT.disabled"
  plugin_dirs remove
  # The ElevenLabs key you saved in Settings lives in your login Keychain: don't leave it behind.
  security delete-generic-password -s com.chadkraus.codebuddy.elevenlabs >/dev/null 2>&1 && echo "Removed the ElevenLabs key from your Keychain." || true
  echo "Uninstalled. Session files remain in ~/.claude/codebuddy (delete if you like)."
  exit 0
fi

echo "Building CodeBuddy.app…"
BUILD="$ROOT/desktop/build/CodeBuddy.app"
rm -rf "$BUILD"; mkdir -p "$BUILD/Contents/MacOS"
cp "$ROOT/desktop/Info.plist" "$BUILD/Contents/"
mkdir -p "$BUILD/Contents/Resources" && cp "$ROOT"/desktop/art/*.png "$BUILD/Contents/Resources/"
cp "$ROOT"/desktop/voice/*.mp3 "$BUILD/Contents/Resources/"
swiftc -O -swift-version 5 "$ROOT"/desktop/*.swift -o "$BUILD/Contents/MacOS/CodeBuddy"
mkdir -p "$HOME/Applications"; rm -rf "$APP"; cp -R "$BUILD" "$APP"

echo "Installing LaunchAgent…"
launchctl bootout "gui/$UID/com.chadkraus.codebuddy" 2>/dev/null || true
# bootout is asynchronous: wait until the old job is really gone, or bootstrap fails with an I/O error
for _ in $(seq 1 20); do launchctl print "gui/$UID/com.chadkraus.codebuddy" >/dev/null 2>&1 || break; sleep 0.25; done
sed "s|__BIN__|$APP/Contents/MacOS/CodeBuddy|" "$ROOT/desktop/com.chadkraus.codebuddy.plist" > "$AGENT"
launchctl bootstrap "gui/$UID" "$AGENT"

echo "Registering the mod with Claude Code…"
plugin_dirs add
echo "Done. New Claude Code sessions load the buddy; restart the Claude app for desktop sessions to pick it up."
