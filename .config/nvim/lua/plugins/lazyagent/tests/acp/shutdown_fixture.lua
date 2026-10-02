-- Executed in a separate Neovim so VimLeavePre and process teardown are real.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(root)
local directory = assert(vim.env.LAZYAGENT_SHUTDOWN_DIR)
local scenario = assert(vim.env.LAZYAGENT_SHUTDOWN_CASE)
local cache, workspace = directory .. '/cache', directory .. '/workspace'
vim.cmd.cd(workspace)
vim.fn.writefile({ tostring(vim.fn.getpid()) }, directory .. '/editor.pid')

if scenario == 'resession' then
  package.preload.resession = function()
    return { save = function(name)
      vim.fn.writefile({ name }, directory .. '/saved-session')
    end }
  end
  dofile(vim.fs.dirname(root) .. '/resession.lua').init()
end

-- Default backend stores are constructed while the facade is being required.
require('lazyagent.logic.state').opts = { cache = { dir = cache } }
local agent = require('lazyagent')
agent.setup({
  cache = { dir = cache }, backend = 'buffer_acp', resume = false,
  agentmux = scenario == 'agentmux', save_conversation_on_close = false,
  acp = { auto_permission = 'allow_once', footer_animation = false,
    brain_save = { enabled = false }, permissions = { dir = cache .. '/permissions' } },
})
local state = require('lazyagent.logic.state')
local backend = state.backends.buffer_acp
local busy = scenario == 'busy' or scenario:match('^git') ~= nil
if busy then state.opts.acp.auto_permission = nil; vim.ui.select = function() end end
local pane
backend.split(nil, 8, false, {
  on_split = function(id) pane = id end,
  acp = {
    agent_name = 'ShutdownFixture',
    command = { vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-l', root .. '/tests/acp/fake_agent.lua' },
    cwd = workspace, root_dir = workspace, additional_directories = { root .. '/tests' },
    env = { LAZYAGENT_FAKE_SIMPLE_PROMPT = busy and '0' or '1',
      LAZYAGENT_FAKE_CANCEL_FLOW = busy and '1' or '0',
      LAZYAGENT_FAKE_STUBBORN_EXIT = scenario == 'stubborn' and '1' or '0' },
    source_winid = vim.api.nvim_get_current_win(), source_bufnr = vim.api.nvim_get_current_buf(),
    release_buffer_on_hide = true, footer_animation = false,
  },
})
assert(vim.wait(5000, function()
  local runtime = pane and backend.get_runtime_snapshot(pane)
  return runtime and runtime.acp_ready
end, 5), 'shutdown fixture ready')
local runtime = backend.get_runtime_snapshot(pane)
vim.fn.writefile({ tostring(runtime.acp_process_id) }, directory .. '/child.pid')
vim.fn.writefile({ runtime.acp_thread_id }, directory .. '/thread.id')
state.sessions.ShutdownFixture = { backend = 'buffer_acp', pane_id = pane, cwd = workspace }
local persistence = require('lazyagent.logic.persistence')
persistence.update_session('ShutdownFixture', pane, workspace)
persistence.flush()
if scenario ~= 'empty' and scenario ~= 'stubborn' and scenario ~= 'resession' then
  assert(backend.paste_and_submit(pane, 'shutdown fixture prompt'))
  assert(vim.wait(5000, function()
    return busy and backend.get_pending_permission(pane) ~= nil or not busy and not backend.is_busy(pane)
  end, 5), 'shutdown fixture prompt settled or waiting for permission')
end
if scenario == 'hidden' then backend.break_pane(pane) end
if scenario == 'git-blob' then vim.fn.writefile({ 'changed fixture' }, workspace .. '/source.txt') end
if scenario == 'git-preview' then
  local buf = vim.fn.bufadd(workspace .. '/source.txt')
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed fixture' })
  vim.api.nvim_buf_call(buf, function() vim.cmd('silent write') end)
  local thread = backend.get_thread(runtime.acp_thread_id, { include_live = true })
  local turn = thread.change_journal.turns[#thread.change_journal.turns]
  assert(turn.file_revisions['source.txt'], 'file write queued a journal preview before exit')
end
local started
vim.api.nvim_create_autocmd('VimLeave', { callback = function()
  local snapshot = backend.get_debug_snapshot()
  snapshot.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  vim.fn.writefile({ vim.json.encode(snapshot) }, directory .. '/final.json')
end })
vim.fn.writefile({}, directory .. '/exit-started')
started = vim.uv.hrtime()
vim.cmd('qa!')
