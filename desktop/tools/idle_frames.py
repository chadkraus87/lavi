#!/usr/bin/env python3
"""Turn a short chroma-key clip of Lavi into idle frames that line up with a mood still.

usage: idle_frames.py CLIP.mp4 KEY_HEX STILL.png OUT_PREFIX [every=3]
  CLIP      a Grok/Seedance clip of Lavi on a flat key color (#FF0000 or #00FF00)
  STILL     the matching mood still in desktop/art (frame 0 is scaled/placed to match it)
  OUT       e.g. desktop/art/idle-happy  ->  idle-happy_00.png, idle-happy_01.png, ...
Needs ffmpeg and ImageMagick (`magick`). Keeps every 3rd frame (24 fps clip -> 8 fps).
"""
import glob, os, re, subprocess, sys, tempfile

clip, key, still, out = sys.argv[1:5]
every = int(sys.argv[5]) if len(sys.argv) > 5 else 3
tmp = tempfile.mkdtemp()

def sh(*a): subprocess.run(a, check=True)
def bbox(f):
    o = subprocess.run(['magick', f, '-alpha', 'extract', '-threshold', '10%', '-format', '%@', 'info:'], capture_output=True, text=True).stdout
    w, h, x, y = map(int, re.match(r'(\d+)x(\d+)\+(\d+)\+(\d+)', o).groups()); return x, y, x + w, y + h

sh('ffmpeg', '-loglevel', 'error', '-i', clip, '-vf', f"select='not(mod(n\\,{every}))'", '-fps_mode', 'vfr', f'{tmp}/raw_%02d.png')
raws = sorted(glob.glob(f'{tmp}/raw_*.png'))
for f in raws:  # key out the flat color, then shave the 1px fringe
    sh('magick', f, '-fuzz', '28%', '-transparent', key, '-channel', 'A', '-morphology', 'Erode', 'Diamond:1', '+channel', f.replace('raw_', 'k_'))
keyed = sorted(glob.glob(f'{tmp}/k_*.png'))
side = int(subprocess.run(['magick', 'identify', '-format', '%w', keyed[0]], capture_output=True, text=True).stdout)
c, f0 = bbox(still), bbox(keyed[0])
canvas = int(subprocess.run(['magick', 'identify', '-format', '%w', still], capture_output=True, text=True).stdout)
scale = (c[3] - c[1]) / (f0[3] - f0[1])            # match the robot's height in the still
ox = round((c[0] + c[2]) / 2 - (f0[0] + f0[2]) / 2 * scale)  # and its bottom-center position
oy = round(c[3] - f0[3] * scale)
W = round(side * scale)
for f in glob.glob(f'{out}_*.png'): os.remove(f)
for i, f in enumerate(keyed):
    geo = f'+{ox}+{oy}'.replace('+-', '-')
    sh('magick', '-size', f'{canvas}x{canvas}', 'xc:none', '(', f, '-resize', f'{W}x{W}', ')', '-geometry', geo,
       '-composite', '-resize', '288x288', '-strip', '-define', 'png:compression-level=9', f'PNG32:{out}_{i:02d}.png')
print(f'{len(keyed)} frames -> {out}_*.png (scale {scale:.3f})')
