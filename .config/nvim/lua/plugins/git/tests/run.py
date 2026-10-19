#!/usr/bin/env python3
"""Run standalone Git checks with isolated writable state and cache directories."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PLUGIN = Path(__file__).resolve().parents[1]


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('must be at least 1')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='*', help='Test stems; defaults to every Lua and TUI check')
    parser.add_argument('-j', '--jobs', type=positive, default=1)
    parser.add_argument('--timeout', type=positive, default=180, help='Seconds per check')
    args = parser.parse_args()
    available = {p.stem: p for p in (PLUGIN / 'tests').glob('*.lua')}
    available.update({p.stem: p for p in (PLUGIN / 'tests').glob('*_ui.py')})
    unknown = set(args.names) - available.keys()
    if unknown:
        parser.error('Unknown checks: ' + ', '.join(sorted(unknown)))
    tests = [available[name] for name in args.names] if args.names else sorted(available.values())

    def run(path):
        utilities = Path(os.environ.get('NVIM_UTILITIES_PATH',
                         str(Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
                             / 'nvim/lazy/utilities.lua')))
        command = ['nvim', '--headless', '--clean', '-u', 'NONE', '-i', 'NONE',
                   '--cmd', f'lua vim.opt.rtp:prepend({str(utilities)!r})']
        if path.suffix == '.py':
            command = [sys.executable, str(path)]
        elif path.stem == 'panel_layout':
            command += ["+lua local ok, err = pcall(dofile, 'tests/panel_layout.lua'); "
                        "if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 1') end", '+qa!']
        else:
            command += ['-l', str(path)]
        start = time.monotonic()
        with tempfile.TemporaryDirectory(prefix='git-check-' + path.stem + '-') as directory:
            env = os.environ | {'XDG_STATE_HOME': directory + '/state', 'XDG_CACHE_HOME': directory + '/cache'}
            # TUI checks start their own Neovim process without our --cmd options.
            env['LUA_PATH'] = (str(utilities / 'lua/?.lua') + ';' + str(utilities / 'lua/?/init.lua')
                               + ';' + os.environ.get('LUA_PATH', ';'))
            # Keep XDG_DATA_HOME: integration checks use installed plugins/parsers.
            try:
                result = subprocess.run(command, cwd=PLUGIN, env=env, capture_output=True,
                                        text=True, errors='replace', timeout=args.timeout)
                code, output = result.returncode, result.stdout + result.stderr
            except subprocess.TimeoutExpired:
                code, output = 124, f'Timed out after {args.timeout}s'
        return path.stem, code, output, time.monotonic() - start

    failures = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        for future in as_completed([executor.submit(run, path) for path in tests]):
            name, code, output, elapsed = future.result()
            print(f'{"PASS" if code == 0 else "FAIL"} {name} ({elapsed:.2f}s)', flush=True)
            if code != 0:
                failures += 1
                print(output, flush=True)
    print(f'{len(tests) - failures}/{len(tests)} checks passed', flush=True)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
