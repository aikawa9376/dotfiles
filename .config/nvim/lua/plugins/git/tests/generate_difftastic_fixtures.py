#!/usr/bin/env python3
"""Refresh the checked-in syntax cases against installed Difftastic 0.71.0.

JSON supplies colored token positions (including weak literal coloring).
Inline ANSI additionally supplies bold/underlined changed-word emphasis.
The command is an oracle only; Neovim does not execute it at runtime.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

TARGET = Path(__file__).resolve().parent / 'fixtures/difftastic_word_diff.json'
VERSION = subprocess.check_output(['difft', '--version'], text=True).splitlines()[0]
assert VERSION == 'Difftastic 0.71.0', VERSION
fixture = json.loads(TARGET.read_text())
CSI = re.compile(r'\x1b\[([0-9;]*)m')

with tempfile.TemporaryDirectory(prefix='difftastic-oracle-') as directory:
    for case in fixture['cases']:
        paths = {}
        for side, field in [('old', 'before'), ('new', 'after')]:
            path = Path(directory) / (side + Path(case['name']).suffix)
            path.write_text('\n'.join(case[field]) + ('\n' if case[field] else ''))
            paths[side] = str(path)
        overrides = ['--override=*:text'] if case.get('force_text') else []
        result = subprocess.run(['difft', '--display=json', *overrides, paths['old'], paths['new']],
                                env=os.environ | {'DFT_UNSTABLE': 'yes'},
                                text=True, capture_output=True, check=True)
        native = json.loads(result.stdout)
        case['language'] = native['language']
        case['expected'] = {side: [[] for _ in case[field]]
                            for side, field in [('old', 'before'), ('new', 'after')]}
        case['emphasis'] = {side: [[] for _ in case[field]]
                            for side, field in [('old', 'before'), ('new', 'after')]}
        for chunk in native.get('chunks', []):
            for line in chunk:
                for key, side in [('lhs', 'old'), ('rhs', 'new')]:
                    if key not in line:
                        continue
                    row = line[key]['line_number']
                    if row >= len(case['expected'][side]):
                        continue
                    for change in line[key].get('changes', []):
                        if change['end'] > change['start']:
                            case['expected'][side][row].append([change['start'] + 1, change['end']])
        output = subprocess.check_output([
            'difft', '--display=inline', '--color=always', '--syntax-highlight=off',
            '--tab-width=1', '--context=0', *overrides, paths['old'], paths['new']], text=True)
        for raw in output.splitlines():
            plain = CSI.sub('', raw)
            # Inline old lines start with their left-aligned number. New
            # lines start with three spaces before their number.
            selected = None
            for side, field in [('old', 'before'), ('new', 'after')]:
                lines = case[field]
                width = len(str(max(len(lines), 1))) + 1
                start = 0 if side == 'old' else 3
                label = plain[start:start + width]
                offset = width + 3
                if not re.fullmatch(r' *\d+ ', label):
                    continue
                if side == 'old' and plain[width:offset] != '   ':
                    continue
                if side == 'new' and plain[:3] != '   ':
                    continue
                row = int(label) - 1
                if row < len(lines) and plain[offset:] == lines[row].replace('\t', ' '):
                    selected = side, row, lines, offset
                    break
            if selected is None:
                continue
            side, row, lines, offset = selected
            # Source verification catches spacing/line-number format changes.
            original = lines[row].replace('\t', ' ')
            assert plain[offset:] == original, (case['name'], side, plain, original)
            cursor, byte_offset, color, bold = 0, 0, None, False
            spans = case['emphasis'][side][row]
            for escape in list(CSI.finditer(raw)) + [None]:
                end = escape.start() if escape else len(raw)
                text = raw[cursor:end]
                first = byte_offset - offset + 1
                last = byte_offset + len(text.encode()) - offset
                if color in (91, 92) and bold and last >= first and first > 0:
                    spans.append([first, last])
                # JSON omits chunks for created/deleted files; ANSI still
                # exposes their exact syntactic token colors.
                if native['status'] in ('created', 'deleted') and color in (91, 92) and last >= first and first > 0:
                    case['expected'][side][row].append([first, last])
                byte_offset += len(text.encode())
                if escape:
                    codes = [int(c) for c in escape[1].split(';') if c] or [0]
                    for code in codes:
                        if code == 0:
                            color, bold = None, False
                        elif code == 1:
                            bold = True
                        elif code == 22:
                            bold = False
                        elif code == 39:
                            color = None
                        elif code in (91, 92):
                            color = code
                    cursor = escape.end()

fixture['oracle'] = VERSION + ' --display=json and --display=inline --syntax-highlight=off'
TARGET.write_text('{"oracle":' + json.dumps(fixture['oracle']) + ',"patches":'
    + json.dumps(fixture.get('patches', {}), ensure_ascii=False) + ',"cases":[\n' + ',\n'.join(
    json.dumps(case, ensure_ascii=False, separators=(',', ':')) for case in fixture['cases']) + '\n]}\n')
print(f'Recorded {len(fixture["cases"])} cases from {VERSION}')
