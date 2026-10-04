# CodeBuddy v3: Lavi gets a name and a voice

> **Status 2026-10-04: built.**
> - Voice: preview 1, saved as "Lavi" (`HCx2PwbeGgmrPl8yw3w0`). 17 lines recorded with `eleven_v3`, about 750 ElevenLabs credits, roughly $0.14.
> - Talking face: 2 Higgsfield frames, 1 credit.
> - Focus-mode detection is not done: there's no public API for it, so mute and quiet hours cover it.
> - Verified on screen: the greeting played with the mouth moving, then went back to the idle loop.

Decided 2026-10-04:
- **Name:** Lavi
- **Voice:** ElevenLabs, pre-recorded lines, in a chill-friend style
- **Lavi speaks:** on click, when advice changes, when a long task finishes while you're here, as a greeting, and as a goodbye when the Claude app closes

## 1. The name

- Shown as **Lavi** everywhere you see it:
  - the pane title
  - the band: `🤖 lavi: …`
  - the robot's menu header, "Quit Lavi", and its VoiceOver label
  - phone pings start with "lavi:"
  - the Ask-buddy prompt ("you're Lavi, my coding buddy…")
- The repo, mod id and app bundle stay `codebuddy`, so nothing breaks and no reinstall shuffle.

## 2. The voice (ElevenLabs, pre-recorded)

- **Design:**
  - Make 3 previews with ElevenLabs voice design from this description: "warm, relaxed young-adult voice, friendly and casual, a little playful, clear diction, like a chill friend who's a great engineer".
  - You pick one, and it's saved to your ElevenLabs voice library.
- **Line library** (`desktop/voice/<line-id>.mp3`), about 25 short lines:

  | Group | Lines | Example |
  |---|---|---|
  | greeting | 3 variants | "hey, lavi here. what are we building today?" |
  | goodbye | 3 variants | "nice session. go rest, I'll be here." |
  | advice, one per rule (7) | spoken version of each headline, with no dynamic numbers | "tests are failing. let's fix those first." / "you're working right on your main branch. let's spin up a branch." |
  | task done | 2 variants | "done with that big one. come take a look." |
  | nothing to say (click while calm or sleepy) | 2 variants | "all good. you're in a nice spot." |
  | snippet copied | 1 | "copied. paste it in and hit enter." |

  - The lines are listed in `desktop/voice/lines.json` (id → text), so regenerating or adding lines is one script run.
  - Dynamic details (counts, branch names, %) stay in the bubble text. The spoken line is the gist.
- **Cost:** a one-time ElevenLabs spend, about 2–3k characters plus the voice-design previews. There's no API key on the Mac and no cost per use.

## 3. When Lavi talks (the desktop app plays the clips)

| Trigger | How it's detected | Line |
|---|---|---|
| click | a click on the robot (the menu still opens) | the current top advice, or "all good" |
| advice changes | the top step's id changes in the session file while the session is idle | that rule's line |
| task done while you're here | the session goes busy → idle after 3+ min, and you used the Mac in the last 2 min | task-done line |
| greeting | a session file appears for the first time | greeting, at most once per 10 min |
| goodbye | macOS reports that Claude.app is quitting | goodbye. Lavi stays visible until the clip ends, then hides |

Lavi stays quiet when:
- **Muted** from the menu (Voice: On/Off, Volume: Low/Med/High)
- **In quiet hours:** default 10pm–8am, changeable
- **A Focus mode is on:** to be checked during the build, since macOS has no public API for reading the Focus state. If it can't be detected reliably, quiet hours and mute cover it.
- **Too soon:** at most one line every 20 s, and advice lines only when the advice actually changed

Goodbye note: macOS has no way to delay another app's quit. Lavi says goodbye as Claude closes (the robot lingers for the clip), not before it.

## 4. Optional: a talking face (about 1 credit)

Two more Higgsfield frames of the calm pose, one with the mouth half open and one fully open. While a clip plays, the app switches frames based on how loud the audio is, so Lavi's screen-mouth moves with the words.

## Order

1. Rename to Lavi: the mod's strings, pings, the app's labels. Tests updated.
2. ElevenLabs: 3 voice previews, you pick, generate the line library, `lines.json`.
3. Desktop app: `AVAudioPlayer` playback, triggers, the quiet rules, voice and volume menu items.
4. (Optional) talking-face frames plus mouth movement driven by loudness.
5. Reinstall, check on screen and by ear, then update the README and SecondBrain.
