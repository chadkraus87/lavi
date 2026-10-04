# CodeBuddy v2: look, voice, phone pings

> **Status 2026-10-04:** built. 7.5 credits spent: 4 concepts, the hero, 7 moods. The transparent-background output made the paid background removal unnecessary. AutoSprite is **not run**, because Higgsfield's cost check errors for that model; it can be revisited with a known price. A push from the mod is confirmed to reach the tool, which held it back because the terminal was active. Delivery to the phone still needs a real away-from-desk check.

Decided 2026-10-04:
- **Look:** a little desk robot, in a 3D vinyl-toy style
  - Picked **concept 3, the lavender headphones cube** (`docs/concepts/concept-3.png`, Higgsfield job `07b3430e-ca0b-4d24-b03e-28296352d401`). The hero swaps its piano keyboard for a computer keyboard.
- **Voice:** a chill friend
- **Pings:** all four kinds

## 1. The look: Higgsfield artwork

**Budget:** about 30 of the 85.8 credits.

| Step | Model | Count | Credits |
|---|---|---|---|
| Concepts: 4 different robots, **done, picked #3** | gpt_image_2_5 | 4 | 1 (spent) |
| Hero shot of the chosen robot (optional polish) | nano_banana_pro | 1–2 | 2–4 |
| Moods, each made from the hero as a reference so it stays the same robot | gpt_image_2_5 | 7 | ~2 |
| Background removal on each mood | remove_background | 7 | price checked before running |
| Idle animation: a gentle sway plus a blink, as a sprite sheet | autosprite (turbo) | 1–2 | price checked before running |

**Moods.** The screen face carries most of the emotion; the body pose adds the rest.

| Mood | When | Face / pose |
|---|---|---|
| happy | good spot, tests green | big smile eyes `^ ^`, thumbs up |
| nudge | there's a suggested step | raised hand or pointing, eyebrows up |
| worried | tests failing | wobbly frown, sweat drop, hands on head |
| calm | nothing urgent | soft neutral eyes, relaxed |
| busy | Claude is working | typing on a tiny keyboard, `…` on the screen |
| blink | the blink frame for any mood | eyes closed |
| sleepy | idle for more than 30 min | half-closed eyes, a small zZ |

**Code changes** (`desktop/Buddy.swift`):
- Replace the hand-drawn blob with PNGs bundled under `desktop/art/<mood>.png`. `install.sh` copies them into `Contents/Resources`.
- If a sprite sheet exists for a mood, play its frames; otherwise use the still image.
- Keep the code-driven bob, turned off when Reduce Motion is on.
- Raise the size to about 110pt and make it adjustable in the menu (S/M/L).
- Keep the vector blob as a fallback for when the art is missing, so the app never shows nothing.

## 2. The voice: chill friend, still smart

The style rules: plain words and short sentences. Name the actual file, command or number. When a technical term is unavoidable, explain it in a few words. Lowercase is fine. At most one emoji.

- **Rule texts** (`mod/hooks/rules.ts`): rewrite every `text` and `why`. Examples:
  - fix-tests: "tests are failing. let's fix those before anything else."
    why: "the last test run broke, so stacking more changes on top makes it harder to find what went wrong."
  - commit: "good time to save a checkpoint — commit what you've got."
    why: "12 files changed and no commit in 50 min. a commit is your undo button."
  - wrap: "my memory's getting full (72%). let's write a quick handoff and start fresh."
  - The ids stay the same, so the tests and the app don't change.
- **"Ask buddy" / `/buddy next`:** the prompt asks the model to talk like a chill friend. It still has to:
  - give the single best next step and the reasoning behind it
  - name concrete files and commands
  - point out risks
  - fit in 3 short bullets, with no filler and no padding
- **Desktop speech bubble, pane and pushes** all use the same voice.

## 3. Phone pings

**Mechanism:** the mod calls Claude Code's own `PushNotification` tool through `$.tool.call`. That tool:
- shows a desktop banner, and pushes to the phone when Remote Control is connected
- skips itself when you're at the computer

**Setup:** turn on the Code tab setting `connect_new_sessions_to_remote_control` (you approve it on a card).

**Triggers** (pushes are built from templates, so they cost no tokens):

| Trigger | How it's detected | Example push |
|---|---|---|
| Long task finished | the turn took 3+ min (`turn.start` → `turn.complete`) | "done with that big one in codebuddy (6 min). next up: run the tests." |
| Something broke | a test run failed during the turn, or the turn ended in an error | "heads up — tests failed in codebuddy. want me to dig in?" |
| Waiting on you | `tool.call` for AskUserQuestion, or `tool.check` coming back `ask` (needs your approval) | "quick question for you in codebuddy: which database should we use?" |
| Gentle nudge | a timer 30 min after a turn ends, when there's uncommitted work; cancelled by your next prompt; once per session | "you've got 9 changed files in codebuddy that aren't committed yet. want to lock them in?" |

**Spam guards:**
- one push per session per 2 minutes
- the "waiting" push is limited to once per pause
- a `/buddy pings off` switch, stored in `$.store`

**Tests:** a pure `pings.ts` (decide whether to push, and with what text) plus `pings.test.ts`, in the same style as `rules.ts`.

## Order

1. Pick a concept, then generate the hero and moods, then remove backgrounds. Review them together.
2. Voice rewrite of the rule texts and the ask prompt, with tests.
3. A spike to confirm `$.tool.call('PushNotification')` from a mod reaches the phone. If it doesn't, fall back to a desktop-only banner and rethink the phone part.
4. Pings, then the Remote Control default.
5. Swift art swap, the AutoSprite idle animation, the size option, and a reinstall.
6. Update the README and the SecondBrain note.
