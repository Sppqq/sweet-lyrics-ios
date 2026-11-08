#!/usr/bin/env python3
"""Render the SVG variants (rsvg-convert + Pillow); keep the original icon intact."""
import json
from pathlib import Path
import subprocess
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'SpicyLyrics/Assets.xcassets'
RESOURCES = ROOT / 'SpicyLyrics/Resources'


def generate():
    for variant in ('Dark', 'Colorful'):
        folder = ASSETS / f'AppIcon{variant}.appiconset'
        folder.mkdir(exist_ok=True)
        image = folder / 'AppIcon.png'
        subprocess.run(['rsvg-convert', str(ROOT / f'scripts/app-icons/{variant.lower()}.svg'),
                        '-o', str(image)], check=True)
        with Image.open(image) as source:
            source.convert('RGB').save(image)
        (folder / 'Contents.json').write_text(json.dumps({
            'images': [{'filename': 'AppIcon.png', 'idiom': 'universal',
                        'platform': 'ios', 'size': '1024x1024'}],
            'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
        # Loose icons also support xtool, which does not compile asset catalogs.
        with Image.open(image) as source:
            for name, size in [('60x60@2x', 120), ('60x60@3x', 180),
                               ('76x76@2x', 152), ('83.5x83.5@2x', 167)]:
                source.resize((size, size), Image.Resampling.LANCZOS).save(
                    ROOT / 'Config/XtoolIcons' / f'AppIcon{variant}{name}.png')
    for name in ('AppIcon', 'AppIconDark', 'AppIconColorful'):
        with Image.open(ASSETS / f'{name}.appiconset/AppIcon.png') as source:
            source.resize((180, 180), Image.Resampling.LANCZOS).save(
                RESOURCES / f'{name}Preview.png')


if __name__ == '__main__':
    generate()
