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
