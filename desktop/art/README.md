# Buddy art

The moods of the lavender headphones robot. All seven are cropped to one shared 384px frame, so swapping moods never makes the robot jump. Each was generated with Higgsfield `gpt_image_2_5` using a transparent background, from the hero image (job `20e0075a-f52f-4862-810a-ec92741fc1ee`) as the reference. The hero itself came from concept job `07b3430e-…`.

| file | Higgsfield job |
|---|---|
| happy | 522e53e3-7d87-4b18-b3df-4354f6bbc839 |
| nudge | 4639986c-4192-4814-aaca-e51c98a538e0 |
| worried | e1f1566f-5037-40d9-80a8-76decb0973a5 |
| calm | 8956ddb2-e3d8-499d-8dda-dd244d61c5a9 |
| busy | 2459a127-fb71-4760-a903-9867e06c2b3c |
| blink | 8ebd2abe-8ae3-4ee8-b2f9-d258e21ba1a2 (pairs with calm) |
| sleepy | 4ab8ae05-0cad-4a60-8ac0-81ead2dfdb45 |

The 1024px originals are in `desktop/art-src/`, which git ignores. To add a mood, generate it from the hero with the same prompt preamble, crop it to the same frame, then add its name to the `art` list in `Buddy.swift`.

## Idle animation (`idle_00` … `idle_24`)

The calm mood plays a looping idle animation (head sway, a nod, a blink). It plays at 8 fps, forward and then backward, so the loop never jumps. When the system's Reduce Motion setting is on, the still `calm.png` shows instead.

How it was made (AutoSprite can't be reached through the Higgsfield connector, and Seedance needs the Plus plan):
1. The calm robot re-rendered on flat pure red (`gpt_image_2_5`, job `18f66063-1ee4-47ed-a8f3-4fef53b283ad`). The robot's colors contain no red, so red is a clean key color.
2. A 3 s Grok Video 1.5 clip from that frame (job `bf576bb1-a3e1-42e8-861e-02023b9e5a8e`, 7.5 credits).
3. With ffmpeg and ImageMagick: keep every 3rd frame (8 fps), key out the red (`-fuzz 28% -transparent red`, alpha eroded 1px), then rescale so frame 0 matches `calm.png` in size and bottom-center position.
