local M = {}

function M.run()
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
  local git = vim.fn.exepath('git')
  local timings = {}
  local scenarios = { 'empty', 'idle', 'hidden', 'busy', 'stubborn', 'agentmux', 'git', 'git-blob', 'git-preview' }
  if vim.fn.filereadable(vim.fs.dirname(root) .. '/resession.lua') == 1 then
    scenarios[#scenarios + 1] = 'resession'
  end
  for _, scenario in ipairs(scenarios) do
    local directory = vim.fn.tempname() .. '-shutdown-' .. scenario
    local workspace = directory .. '/workspace'
    vim.fn.mkdir(directory .. '/bin', 'p')
    vim.fn.mkdir(workspace, 'p')
    vim.fn.writefile({ 'fixture' }, workspace .. '/source.txt')
    assert(vim.system({ git, 'init', '-q', workspace }):wait(3000).code == 0)
    if scenario == 'git-blob' or scenario == 'git-preview' then
      assert(vim.system({ git, '-C', workspace, 'add', 'source.txt' }):wait(3000).code == 0)
      assert(vim.system({ git, '-C', workspace, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
        '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture' }):wait(3000).code == 0)
    end
    local stall_pattern = scenario == 'resession' and 'branch' or scenario == 'git-blob' and 'cat-file'
      or scenario == 'git-preview' and 'status|cat-file' or 'status'
    vim.fn.writefile({ '#!/bin/sh',
      'if [ -f "$LAZYAGENT_SHUTDOWN_DIR/exit-started" ]; then',
      '  for arg in "$@"; do case "$arg" in ' .. stall_pattern .. ') exec sleep 60;; esac; done', 'fi',
      'exec ' .. vim.fn.shellescape(git) .. ' "$@"',
    }, directory .. '/bin/git')
    vim.fn.writefile({ '#!/bin/sh', 'exec sleep 60' }, directory .. '/bin/agentmux')
    vim.uv.fs_chmod(directory .. '/bin/git', 493)
    vim.uv.fs_chmod(directory .. '/bin/agentmux', 493)
    local intercept = scenario:match('^git') or scenario == 'resession' or scenario == 'agentmux'
    local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-u', 'NONE',
      '-l', root .. '/tests/acp/shutdown_fixture.lua' }, {
      cwd = workspace, text = true, env = {
        LAZYAGENT_SHUTDOWN_DIR = directory, LAZYAGENT_SHUTDOWN_CASE = scenario,
        XDG_STATE_HOME = directory .. '/state', XDG_CACHE_HOME = directory .. '/xdg-cache',
        PATH = (intercept and directory .. '/bin:' or '') .. vim.env.PATH,
        TMUX_PANE = '%987654',
      },
    }):wait(8000)
    -- Recover the fixture child even on failure; never leave a stubborn provider.
    local pid_path = directory .. '/child.pid'
    local pid = vim.fn.filereadable(pid_path) == 1 and tonumber(vim.fn.readfile(pid_path)[1]) or nil
    local orphan = pid and vim.uv.kill(pid, 0) ~= nil
    if orphan then pcall(vim.uv.kill, pid, 9) end
    assert(result.code == 0, scenario .. ' failed to exit: ' .. tostring(result.stderr))
    assert(not orphan, scenario .. ' left its ACP process alive')
    local snapshot = vim.json.decode(table.concat(vim.fn.readfile(directory .. '/final.json'), '\n'))
    assert(snapshot.session_count == 0 and snapshot.child_process_count == 0
      and snapshot.callback_count == 0 and #snapshot.owners == 0, scenario .. ' retained ACP owners at VimLeave')
    local saved = vim.json.decode(table.concat(vim.fn.readfile(directory .. '/cache/sessions.json'), '\n'))
    assert(next(saved) == nil, scenario .. ' did not flush session removal on exit')
    if scenario == 'resession' then
      assert(vim.fn.readfile(directory .. '/saved-session')[1] == workspace,
        'resession must still save with the cwd when branch lookup times out')
    elseif scenario:match('^git') then
      local store = require('lazyagent.acp.thread_store').new({ dir = directory .. '/cache/acp/threads' })
      local record = assert(store:get(vim.fn.readfile(directory .. '/thread.id')[1]))
      local turns = record.change_journal.turns
      local turn = turns[#turns]
      assert(record.status == 'closed' and turn.capture_error:find('timed out', 1, true),
        'shutdown must preserve the interrupted journal with an explicit capture error')
      assert(turn.final_snapshot == nil and #turn.changes == 0, 'timed-out snapshot invented file changes')
    end
    timings[#timings + 1] = scenario .. '=' .. math.floor(snapshot.elapsed_ms) .. 'ms'
    vim.fn.delete(directory, 'rf')
  end
  print('shutdown: ' .. table.concat(timings, ', '))
end

return M
