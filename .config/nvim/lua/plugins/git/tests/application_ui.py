"""Exercise the actual dedicated startup profile and process lifetime."""
import os
from pathlib import Path
import subprocess
import tempfile

plugin = Path(__file__).resolve().parents[1]
config = plugin.parents[2]
with tempfile.TemporaryDirectory(prefix='git-app-') as directory:
    root = Path(directory) / 'repo with spaces'
    root.mkdir()
    subprocess.run(['git', 'init', '-qb', 'main', str(root)], check=True, capture_output=True)
    for key, value in {'user.name': 'Test', 'user.email': 'test@example.invalid', 'commit.gpgsign': 'false'}.items():
        subprocess.run(['git', '-C', str(root), 'config', key, value], check=True, capture_output=True)
    (root / 'file.txt').write_text('original\n')
    (root / 'source.lua').write_text('local answer = 42\nreturn answer\n')
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'initial'], check=True, capture_output=True)
    env = os.environ | {'XDG_STATE_HOME': directory + '/state', 'XDG_CACHE_HOME': directory + '/cache'}

    def run(body, *, path=root, expected=0):
        script = Path(directory) / 'check.lua'
        script.write_text('''
vim.api.nvim_create_autocmd('User', { pattern = 'GitApplicationReady', once = true, callback = function()
  vim.schedule(function()
    local ok, err = pcall(function()
''' + body + '''
    end)
    if not ok then io.stderr:write(tostring(err) .. '\\n'); vim.cmd('cquit 2') end
  end)
end })
''')
        command = ['nvim', '--headless', '-i', 'NONE', '-u', str(config / 'init.lua'),
                   '--cmd', 'let g:git_app = 1', '--cmd', 'let g:git_status_auto_fetch = v:false',
                   '--cmd', f'lua dofile({str(script)!r})', str(path)]
        result = subprocess.run(command, cwd=directory, env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == expected, (command, result.returncode, result.stdout, result.stderr)
        return result

    run('''
local config = require('lazy.core.config')
for _, name in ipairs({ 'bufferline.nvim', 'incline.nvim', 'resession.nvim', 'nvim-lspconfig', 'lazyagent', 'project.nvim' }) do
  assert(not config.plugins[name], 'editor plugin leaked into Git profile: ' .. name)
end
local opts = require('lazy.core.plugin').values(config.plugins.git, 'opts', false)
assert(#opts.status_modules == 0, 'normal editor status shelves were inherited')
assert(vim.bo.filetype == 'gitstatus' and vim.o.showtabline == 0)
assert(#vim.api.nvim_list_tabpages() == 1 and #vim.api.nvim_tabpage_list_wins(0) == 1)
assert(vim.fn.getcwd() == ''' + repr(str(root)) + ''')
local map = vim.fn.maparg('q', 'n', false, true)
assert(map.callback, 'status q is missing')
map.callback()
error('status q did not terminate Neovim')
''')
    run('''
local home = vim.api.nvim_get_current_win()
assert(not vim.wo.number, 'Status should not show file line numbers')
vim.cmd('edit ' .. vim.fn.fnameescape(''' + repr(str(root / 'source.lua')) + '''))
assert(vim.wait(2000, function()
  return vim.api.nvim_get_current_win() ~= home and vim.wo.number
end, 10), 'file inspection did not enable line numbers')
local file = vim.api.nvim_get_current_buf()
assert(vim.bo[file].filetype == 'lua', 'filetype detection is disabled')
assert(vim.wait(2000, function() return vim.treesitter.highlighter.active[file] ~= nil end, 10),
  'file inspection has no Tree-sitter highlighting')
assert(vim.g.syntax_on ~= nil, 'syntax fallback is disabled')
assert(not vim.wo.relativenumber)
vim.fn.maparg('q', 'n', false, true).callback()
assert(vim.api.nvim_get_current_win() == home and not vim.wo.number, 'file number option leaked into Status')
vim.fn.maparg('q', 'n', false, true).callback()
''')
    # Closing the root while another tab is open must also end the process.
    run('''
local home = vim.api.nvim_get_current_win()
vim.cmd('tabnew ' .. vim.fn.fnameescape(''' + repr(str(root / 'file.txt')) + '''))
vim.api.nvim_win_close(home, false)
vim.defer_fn(function() vim.cmd('cquit 3') end, 1000)
''')
    run('''
vim.cmd('tabnew ' .. vim.fn.fnameescape(''' + repr(str(root / 'file.txt')) + '''))
local home
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[buf].filetype == 'gitstatus' then home = buf end
end
vim.api.nvim_buf_delete(assert(home), { force = false })
vim.defer_fn(function() vim.cmd('cquit 3') end, 1000)
''')
    (root / 'file.txt').write_text('staged change\n')
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True, capture_output=True)
    run('''
local home = vim.api.nvim_get_current_win()
vim.cmd('Git commit')
assert(vim.wait(10000, function() return vim.bo.filetype == 'gitcommit' end, 10), 'Git editor did not open')
assert(vim.fn.maparg('q', 'n', false, true).desc ~= 'Return to Git status', 'Git editor protocol was overridden')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'commit from Git application' })
vim.cmd('write')
vim.cmd('close')
assert(vim.wait(10000, function()
  local result = vim.system({ 'git', 'log', '-1', '--format=%s' }, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) == 'commit from Git application'
end, 10), 'Git did not resume after the editor closed')
assert(vim.api.nvim_get_current_win() == home and vim.bo.filetype == 'gitstatus')
vim.fn.maparg('q', 'n', false, true).callback()
''')
    result = run('', path=directory, expected=1)
    assert('Not in a Git working tree' in result.stderr)
print('PASS: actual Git startup profile, repository argv, root lifetime, commit RPC editor, and invalid repository exit')
