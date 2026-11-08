#!/usr/bin/env python3
"""Check packaged alternate icons on iPhone and iPad, including actual PNG files.

Run without arguments for the xtool inputs, or pass an Xcode-built .app directory.
"""
import json
from pathlib import Path
import plistlib
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = ('AppIconDark', 'AppIconColorful')


def png(path, size=None):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'Not a PNG: {path}'
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    assert width == height and (size is None or width == size), f'Wrong icon size: {path}'
    assert depth == 8 and color == 2, f'App icons must be opaque RGB: {path}'


def main():
    compiled = len(sys.argv) > 1
    app = Path(sys.argv[1]) if compiled else ROOT / 'Config/XtoolIcons'
    info = plistlib.loads((app / 'Info.plist' if compiled else ROOT / 'Config/Xtool-Info.plist').read_bytes())
    for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
        icons = info[key]['CFBundleAlternateIcons']
        for variant in VARIANTS:
            files = icons[variant]['CFBundleIconFiles']
            assert files, f'{key}/{variant} has no icon files'
            for name in files:
                matches = list(app.glob(f'{name}*.png'))
                assert matches, f'Missing packaged PNG for {key}/{variant}/{name}'
                for path in matches:
                    if compiled:
                        assert path.stat().st_size > 0, f'Empty packaged icon: {path}'
                    else:
                        png(path)
    resources = app if compiled else ROOT / 'SpicyLyrics/Resources'
    for name in ('AppIcon', *VARIANTS):
        preview = resources / f'{name}Preview.png'
        if compiled:
            assert preview.is_file() and preview.stat().st_size > 0, f'Missing preview: {preview}'
        else:
            png(preview, 180)
    if not compiled:
        for variant in VARIANTS:
            folder = ROOT / 'SpicyLyrics/Assets.xcassets' / f'{variant}.appiconset'
            catalog = json.loads((folder / 'Contents.json').read_text())
            png(folder / catalog['images'][0]['filename'], 1024)
    print('PASS: alternate icon metadata, opaque PNGs and previews for iPhone/iPad')


if __name__ == '__main__':
    main()
