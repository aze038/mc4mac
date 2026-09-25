"""FalconMail mark from Shahin's sketch: an open envelope whose two flaps are wings.
Writes mark.svg (colour mark), overlay.svg (check against the sketch), icon.svg (macOS tile),
logo-*.svg (lockups). Run: python mark.py && node render.js <file>."""
import os
D = os.path.dirname(os.path.abspath(__file__))

RED, RED_DK = '#E0533F', '#D8323C'
TEAL, BLUE = '#5AA7B6', '#3A82B0'
WHITE = '#FFFFFF'

# Local coordinates: x -158..158, y 0..212 (the sketch's pixels, centred on its x=342, top y=244).
def poly(pts):
    return 'M' + ' L'.join(f'{x:.1f},{y:.1f}' for x, y in pts) + ' Z'

def mirror(pts):
    return [(-x, y) for x, y in pts]

LEFT_FLAP = [(-150, 8), (-150, 196), (-10, 97)]
LEFT_FOLD = [(-10, 97), (-40, 76), (-146, 200)]
ENVELOPE  = [(0, 56), (140, 166), (140, 206), (-140, 206), (-140, 166)]

def shapes(glow=True, body=WHITE):
    j = 'stroke-linejoin="round"'
    out = []
    if glow:
        out.append(f'<path d="{poly(ENVELOPE)}" fill="{WHITE}" stroke="{WHITE}" stroke-width="18" {j} filter="url(#glow)" opacity="0.55"/>')
    out.append(f'<path d="{poly(ENVELOPE)}" fill="{body}" stroke="{body}" stroke-width="16" {j}/>')
    for flap, fold, c, cd in [(LEFT_FLAP, LEFT_FOLD, RED, RED_DK), (mirror(LEFT_FLAP), mirror(LEFT_FOLD), TEAL, BLUE)]:
        out.append(f'<path d="{poly(flap)}" fill="{c}" stroke="{c}" stroke-width="16" {j}/>')
        out.append(f'<path d="{poly(fold)}" fill="{cd}" stroke="{cd}" stroke-width="8" {j}/>')
    return '\n    '.join(out)

GLOW = '''<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="14"/></filter>'''

def group(tx, ty, s, glow=True, body=WHITE):
    return f'<g transform="translate({tx},{ty}) scale({s})">\n    {shapes(glow, body)}\n  </g>'

def write(name, body):
    open(os.path.join(D, name), 'w').write(body)

# 1. Overlay on the sketch (702 x 704): sketch below, new shapes in half-transparent colour.
write('overlay.svg', f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="702" height="704" viewBox="0 0 702 704">
  <image href="/home/umbrel/.hermes/images/upload_20260925_225250_8.png" width="702" height="704"/>
  <g opacity="0.55">{group(342, 244, 1, glow=False)}</g>
</svg>''')

# 2. The mark alone, tight, transparent.
write('mark.svg', f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-170 -12 340 236" width="680" height="472">
  <defs>{GLOW}</defs>
  {shapes(glow=False)}
</svg>''')

# 3. macOS icon: 1024 canvas, 824 tile at 100 (Apple's grid), corner 185.
S = 1.52  # mark 300 wide -> ~456 px, about 55% of the tile
write('icon.svg', f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    {GLOW}
    <radialGradient id="face" cx="0.5" cy="0.44" r="0.75">
      <stop offset="0" stop-color="#0B0F18"/>
      <stop offset="0.55" stop-color="#101B28"/>
      <stop offset="1" stop-color="#1B3A4A"/>
    </radialGradient>
    <radialGradient id="warm" cx="0.92" cy="0.95" r="0.55">
      <stop offset="0" stop-color="#5A1E1C" stop-opacity="0.9"/>
      <stop offset="1" stop-color="#5A1E1C" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#6CCFE0"/>
      <stop offset="0.5" stop-color="#3B6A80"/>
      <stop offset="1" stop-color="#F0553F"/>
    </linearGradient>
    <filter id="rimglow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="22"/></filter>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="12"/></filter>
  </defs>
  <rect x="100" y="112" width="824" height="824" rx="185" fill="#000" opacity="0.35" filter="url(#shadow)"/>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="none" stroke="url(#rim)" stroke-width="10" filter="url(#rimglow)" opacity="0.55"/>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#face)"/>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#warm)"/>
  <rect x="104" y="104" width="816" height="816" rx="181" fill="none" stroke="url(#rim)" stroke-width="5" opacity="0.8"/>
  {group(512, 512 - 106 * S - 8, S)}
</svg>''')

# 4. Logo lockups: mark + wordmark (Liberation Sans Bold stands in for the final typeface).
def lockup(name, text_fill, bg=None, body=WHITE):
    rect = f'<rect width="1400" height="360" fill="{bg}"/>' if bg else ''
    write(name, f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1400 360" width="1400" height="360">
  <defs>{GLOW}</defs>
  {rect}
  {group(210, 74, 1.0, glow=False, body=body)}
  <text x="420" y="222" font-family="Liberation Sans" font-weight="700" font-size="150" letter-spacing="-3" fill="{text_fill}">Falcon<tspan font-weight="400">Mail</tspan></text>
</svg>''')

lockup('logo-light.svg', '#0E1A28', body='#0E1A28')
lockup('logo-dark.svg', '#FFFFFF', bg='#0E1421')
print('ok')

# 5. The mark on its own for light backgrounds.
write('mark-light.svg', f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-170 -12 340 236" width="680" height="472">
  {shapes(glow=False, body='#0E1A28')}
</svg>''')
