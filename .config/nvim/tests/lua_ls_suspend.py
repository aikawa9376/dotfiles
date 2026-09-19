"""Linux integration regression: real LuaLS survives suspension and reads new files.

Run: python3 .config/nvim/tests/lua_ls_suspend.py /path/to/lua-language-server
Uses only temporary workspaces and processes; never signals an editor's server.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time


def eventually(predicate, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('Timed out waiting for LuaLS')


def check(binary, bootstrap):
    with tempfile.TemporaryDirectory(prefix='luals-suspend-') as directory:
        root = Path(directory)
        (root / 'main.lua').write_text('return {}\n')
        cmd = [binary] + ([str(bootstrap)] if bootstrap else [])
        proc = subprocess.Popen(cmd + ['--logpath=' + str(root / 'logs')],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        lock = threading.Lock()
        responses, progress = {}, {}

        def send(message):
            data = json.dumps(dict(jsonrpc='2.0', **message)).encode()
            with lock:
                proc.stdin.write(f'Content-Length: {len(data)}\r\n\r\n'.encode() + data)
                proc.stdin.flush()

        def receive():
            while True:
                header = proc.stdout.readline()
                if not header:
                    return
                size = int(header.split(b':', 1)[1])
                assert proc.stdout.readline() == b'\r\n'
                message = json.loads(proc.stdout.read(size))
                if 'method' in message and 'id' in message:
                    result = ([{} for _ in message['params']['items']]
                              if message['method'] == 'workspace/configuration' else None)
                    send(dict(id=message['id'], result=result))
                elif 'id' in message:
                    responses[message['id']] = message
                if message.get('method') == '$/progress':
                    params = message['params']
                    if params['value']['kind'] == 'end':
                        progress.pop(params['token'], None)
                    else:
                        progress[params['token']] = params['value']

        reader = threading.Thread(target=receive, daemon=True)
        reader.start()
        try:
            send(dict(id=1, method='initialize', params=dict(
                processId=os.getpid(), rootUri=root.as_uri(),
                capabilities={'window': {'workDoneProgress': True}},
                workspaceFolders=[dict(uri=root.as_uri(), name='regression')],
            )))
            eventually(lambda: 1 in responses)
            send(dict(method='initialized', params={}))
            time.sleep(1)
            threads = lambda: len(list(Path(f'/proc/{proc.pid}/task').iterdir()))
            initial_threads = threads()
            assert initial_threads >= 5, initial_threads
            for iteration in range(3 if bootstrap else 1):
                os.kill(proc.pid, signal.SIGSTOP)
                time.sleep(0.1)
                os.kill(proc.pid, signal.SIGCONT)
                time.sleep(0.2)
                name = f'suspend_probe_{iteration}'
                target = root / (name + '.lua')
                target.write_text(f'function {name}() return 42 end\n')
                send(dict(method='workspace/didChangeWatchedFiles', params={
                    'changes': [dict(uri=target.as_uri(), type=1)],
                }))
                if not bootstrap:
                    eventually(lambda: threads() < initial_threads and bool(progress))
                    print('Unmodified LuaLS: worker loss and stuck progress reproduced')
                    break
                eventually(lambda: any(
                    'Loaded finish:\t' + target.as_uri() in log.read_text(errors='replace')
                    for log in (root / 'logs').glob('*.log')
                ))
                eventually(lambda: not progress)
                assert threads() == initial_threads
                request_id = 10 + iteration
                send(dict(id=request_id, method='workspace/symbol', params={'query': name}))
                eventually(lambda: request_id in responses)
                assert any(item['name'] == name
                           for item in responses[request_id].get('result', [])), responses[request_id]
            if bootstrap:
                print('Workaround: 3 suspend/resume cycles; workers, file loading and symbols intact')
        finally:
            proc.kill()
            proc.wait()
            reader.join(timeout=2)
            proc.stdin.close()
            proc.stdout.close()


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('This regression requires Linux epoll and /proc')
    binary = sys.argv[1]
    bootstrap = Path(__file__).resolve().parents[1] / 'lua/lsp/lua_ls_bootstrap.lua'
    if '--baseline' in sys.argv:
        check(binary, None)  # Optional: expected to fail after the upstream bug is fixed.
    check(binary, bootstrap)
