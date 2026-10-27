frames = {}
for line in open('spectrum_bars.txt'):
    f, b, h = map(int, line.split())
    frames.setdefault(f, [0] * 128)[b] = h

W = 128 * 8 + 80
RH = 260
H = len(frames) * RH + 40
parts = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="monospace">',
    '<rect width="100%" height="100%" fill="#101018"/>',
]
for row, f in enumerate(sorted(frames)):
    y0 = 20 + row * RH
    parts.append(f'<text x="8" y="{y0 + 16}" fill="#e0e0e0" font-size="14">frame {f}</text>')
    for b, h in enumerate(frames[f]):
        x = 80 + b * 8
        y = y0 + 40 + (479 - h) * 0.35
        parts.append(f'<rect x="{x}" y="{y:.1f}" width="7" height="{h * 0.35:.1f}" fill="#40d0ff"/>')
    parts.append(f'<line x1="80" y1="{y0 + 40 + 479 * 0.35:.1f}" '
                 f'x2="{128 * 8 + 80}" y2="{y0 + 40 + 479 * 0.35:.1f}" stroke="#555"/>')
parts.append('</svg>')
open('spectrum_bars.svg', 'w').write('\n'.join(parts))
with open('spectrum_bars.csv', 'w') as out:
    out.write('frame,bar,height\n')
    out.write(open('spectrum_bars.txt').read())
print('wrote spectrum_bars.svg / spectrum_bars.csv')
