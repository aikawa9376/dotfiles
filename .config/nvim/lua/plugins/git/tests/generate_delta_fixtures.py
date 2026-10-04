"""Record delta 0.19.2's real ANSI emphasis as source-byte regression fixtures.

Run from anywhere: python3 tests/generate_delta_fixtures.py
The production Lua comparator does not run delta. This script is its oracle.
"""
import json
import random
import re
import subprocess
from pathlib import Path

version = subprocess.check_output(['delta', '--version'], text=True).strip()
assert version == 'delta 0.19.2', f'Audit upstream before changing the oracle: {version}'
cases = []


def add(name, before, after):
    cases.append({'name': name, 'before': before, 'after': after})


add('numbers', ['return 1'], ['return 2'])
add('CRLF', ['return 1\r'], ['return 2\r'])
add('CRLF versus LF', ['return 1\r'], ['return 1'])
add('unrelated identifiers', ['old_call(old_argument)'], ['new_call(new_argument)'])
add('literal words', ['local s = "the old stale word"'], ['local s = "the new fresh word"'])
add('space between edits', ['read the commit number from here'], ['read build info from here'])
add('trailing space', ['a b c d '], ['x y c z '])
add('space before quote', ["'b '"], ["' b'"])
add('moved comma', ['[element,]'], ['[element],'])
add('inserted words', ['a a'], ['a b b a'])
add('repeat', ['a a a a a a b b b'], ['c a a a a a a c c'])
add('leading indent', ['  foo(a)'], ['    foo(b)'])
add('tabs versus spaces', ['\tfoo(a, b)'], ['        foo(a, c)'])
add('unequal indentation', ['\t\tfoo(a)'], ['\tfoo(b)'])
add('literal whitespace', ['local s = "a b"'], ['local s = "a  b"'])
add('unicode words', ['const 日本語 = 1;'], ['const 日本人 = 1;'])
add('combining words', ['value = e\u0301lan;'], ['value = elán;'])
add('emoji grapheme', ['value = 👩🏽;'], ['value = 👩🏾;'])
add('flags', ['value = 🇯🇵;'], ['value = 🇺🇸;'])
add('emoji joiner', ['value = 👩‍💻;'], ['value = 👨‍💻;'])
add('word joiners', ['value = a\u200db;'], ['value = a\u200dc;'])
add('unicode whitespace', ['a\u00a0old\u3000word'], ['a\u00a0new\u3000word'])
add('layout', ['foo(a, b)'], ['foo(', '  a,', '  b', ')'])
add('added statement', ['foo(a)'], ['foo(b)', 'new(statement)'])
add('added argument', ['foo(a, b)'], ['foo(', '  a,', '  b,', '  c', ')'])
add('callback', ['syntax_highlight.attach(b)', 'end'],
    ['syntax_highlight.attach(b, { diff_source = function(hunk)',
     '  return status_renderer.highlight_source(b, hunk.start_line)', 'end })', 'end'])
add('first qualifying versus best', ['return thing(old)'],
    ['return thing(first)', 'return thing(old)'])
add('forward order', ['foo(old)', 'bar(old)'], ['bar(new)', 'foo(new)'])
add('scan beyond four rows', ['unchanged(value)'],
    ['entirely unrelated text ' + str(i) for i in range(8)] + ['unchanged(updated)'])
add('pure addition', [], ['local x = 1'])
add('pure deletion', ['local x = 1'], [])
add('empty versus content', [''], ['something'])
add('blank indentation', [' '], ['   '])
for n in [31, 32, 33, 34, 64, 66]:
    add(f'buffer boundary {n}', [f'call(item_{i}, old)' for i in range(n)],
        [f'call(item_{i}, new)' for i in range(n)])
    add(f'plus buffer boundary {n}', ['call(old)'], [f'call(new_{i})' for i in range(n)])

root = Path(__file__).resolve().parents[1]
# Capture current real replacements as well as handcrafted edge cases.
for filename in ['lua/git/features/syntax_highlight.lua', 'README.md']:
    result = subprocess.run(['git', 'diff', '--no-ext-diff', '--', str(root / filename)],
                            capture_output=True, text=True, check=True)
    before, after = [], []
    for line in result.stdout.split('\n') + [' ']:
        if line.startswith(('---', '+++')):
            continue
        if line.startswith('-') and not after:
            before.append(line[1:])
        elif line.startswith('+'):
            after.append(line[1:])
        else:
            if before or after:
                add(f'working patch {filename} {len(cases)}', before, after)
            before, after = ([line[1:]], []) if line.startswith('-') else ([], [])

rng = random.Random(20261004)
words = ['aaa', 'bbb', 'value', 'foo', 'bar', 'count', '日本語', '日本人', 'élan', 'e\u0301',
         'α', '👩🏽', '👩🏾', '🇯🇵', '🇺🇸', '👩‍💻', '👨‍💻']
separators = [' ', '  ', '\t', '.', '(', ')', ',', ';', '_', '\u00a0']


def line():
    return rng.choice(['', '  ', '\t']) + ''.join(
        rng.choice(words) + rng.choice(separators) for _ in range(rng.randrange(1, 7)))


for i in range(500):
    before = [line() for _ in range(rng.randrange(1, 6))]
    after = before.copy()
    for _ in range(rng.randrange(1, 4)):
        action = rng.randrange(3)
        if action == 0 and after:
            after[rng.randrange(len(after))] = line()
        elif action == 1:
            after.insert(rng.randrange(len(after) + 1), line())
        elif after:
            del after[rng.randrange(len(after))]
    add(f'generated {i}', before, after)

patch = []
for i, case in enumerate(cases):
    name = f'case_{i:04d}.txt'
    patch.extend([f'diff --git a/{name} b/{name}', 'index 1111111..2222222 100644',
                  f'--- a/{name}', f'+++ b/{name}',
                  f'@@ -1,{len(case["before"])} +1,{len(case["after"])} @@'])
    patch.extend('-' + line for line in case['before'])
    patch.extend('+' + line for line in case['after'])
args = ['delta', '--no-gitconfig', '--dark', '--paging=never', '--true-color=always',
        '--syntax-theme=none', '--keep-plus-minus-markers', '--file-style=raw',
        '--hunk-header-style=raw', '--file-decoration-style=none',
        '--hunk-header-decoration-style=none', '--minus-style=normal #010101',
        '--plus-style=normal #020202', '--minus-emph-style=normal #030303',
        '--plus-emph-style=normal #040404', '--width=80']
result = subprocess.run(args, input='\n'.join(patch) + '\n', text=True,
                        capture_output=True, check=True)
Path('/tmp/git-delta-word-diff/oracle.ansi').write_text(result.stdout)
csi = re.compile(r'\x1b\[([0-9;]*)([A-Za-z])')
current, row = None, {'old': 0, 'new': 0}
for raw in result.stdout.split('\n'):
    plain = csi.sub('', raw)
    match = re.fullmatch(r'diff --git a/case_(\d+)\.txt b/case_\d+\.txt', plain)
    if match:
        current = cases[int(match[1])]
        current['expected'] = {'old': [], 'new': []}
        row = {'old': 0, 'new': 0}
    elif current is not None and plain.startswith(('-', '+')) and not plain.startswith(('---', '+++')):
        side = 'old' if plain[0] == '-' else 'new'
        original = current['before' if side == 'old' else 'after'][row[side]]
        expanded = original.removesuffix('\r').replace('\t', ' ' * 8)
        assert plain[1:] == expanded or not original and plain[1:] == ' ', (current['name'], plain)
        mapping = [0]  # displayed +/- prefix
        offset = 1
        for ch in original.removesuffix('\r'):
            length = len(ch.encode())
            mapping.extend([offset] * 8 if ch == '\t' else range(offset, offset + length))
            offset += length
        spans, cursor, byte_offset, bg = [], 0, 0, None
        for escape in list(csi.finditer(raw)) + [None]:
            end = escape.start() if escape else len(raw)
            chunk = raw[cursor:end].encode()
            if bg == (3, 3, 3) or bg == (4, 4, 4):
                first, last = max(1, byte_offset), min(len(mapping) - 1, byte_offset + len(chunk) - 1)
                if first <= last:
                    a, b = mapping[first], mapping[last]
                    if spans and a <= spans[-1][1] + 1:
                        spans[-1][1] = max(spans[-1][1], b)
                    else:
                        spans.append([a, b])
            byte_offset += len(chunk)
            if escape:
                if escape[2] == 'm':
                    codes = [int(v) for v in escape[1].split(';') if v] or [0]
                    if 0 in codes or 49 in codes:
                        bg = None
                    if codes[:2] == [48, 2]:
                        bg = tuple(codes[2:5])
                cursor = escape.end()
        current['expected'][side].append(spans)
        row[side] += 1
for case in cases:
    assert len(case['expected']['old']) == len(case['before']), case['name']
    assert len(case['expected']['new']) == len(case['after']), case['name']
target = root / 'tests/fixtures/delta_word_diff.json'
target.parent.mkdir(exist_ok=True)
target.write_text('{"oracle":' + json.dumps(version) + ',"cases":[\n' + ',\n'.join(
    json.dumps(case, ensure_ascii=False, separators=(',', ':')) for case in cases) + '\n]}\n')
print(f'Recorded {len(cases)} cases from {version}')
