-- nvim --headless --clean -u NONE -l .config/nvim/tests/noice_acp_layout.lua
-- Uses an isolated attached UI and installed Inkstone/Noice/Nui/Markdown parsers.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '--headless', '--clean', '-u', 'NONE', '-i', 'NONE', '-n' }, { rpc = true })
local function lua(code, ...) return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... }) end
vim.rpcrequest(child, 'nvim_ui_attach', 100, 35, { rgb = true })
local ok, result = xpcall(function()
  return lua([=[
    local root = ...
    vim.opt.rtp:prepend(root)
    vim.opt.rtp:append(root .. '/lua/plugins/lazyagent')
    for _, name in ipairs({ 'inkstone.nvim', 'noice.nvim', 'nui.nvim' }) do
      vim.opt.rtp:append(vim.fn.stdpath('data') .. '/lazy/' .. name)
    end
    vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
    vim.o.laststatus, vim.o.showcmd, vim.o.ruler = 0, false, false
    local spec = dofile(root .. '/lua/plugins/inkstone.lua')
    spec.init()
    require('inkstone').setup(spec.opts)
    require('inkstone.core.manager').init()
    require('noice').setup({ cmdline = { enabled = false }, messages = { enabled = false },
      popupmenu = { enabled = false }, notify = { enabled = false },
      lsp = { progress = { enabled = false }, hover = { enabled = false },
        signature = { enabled = false }, message = { enabled = false } } })
    require('plugins.noice_util').patch_mini_timers()
    local path = vim.fn.tempname() .. '-noice-acp.log'
    vim.fn.writefile({ '─ Assistant ─', '', string.rep('日本語の整形された段落です。', 18), '',
      '| Name | Description |', '| --- | --- |', '| First | ' .. string.rep('テストです。', 15) .. ' |',
      '', '```lua', 'local result = 42', '```', '', 'End of response.' }, path)
    local state = require('lazyagent.logic.state')
    state.opts = { acp = { footer_animation = false } }
    local view = require('lazyagent.acp.view_buffer')
    local pane, info
    view.create_pane({ transcript_path = path, size = '60%', is_vertical = true,
      acp = { agent_name = 'noice-layout-test', source_winid = vim.api.nvim_get_current_win() },
    }, function(id, value) pane, info = id, value end)
    assert(vim.wait(3000, function() return info ~= nil end, 5), 'pane creation timed out')
    local session = { pane_id = pane, agent_name = 'noice-layout-test', backend = 'buffer_acp',
      acp_ready = true, transcript_path = path, view_state = {} }
    state.sessions[session.agent_name] = session
    view.on_session_created(session)
    view.resume_follow(pane)
    local buf, win = info.bufnr, info.winid
    local ui = require('inkstone.core.ui')
    assert(vim.wait(3000, function() return ui.cache[buf] and ui.cache[buf].n > 0 end, 5), 'no initial render')
    vim.wait(500, function() return false end, 5)
    local function snapshot()
      vim.cmd('redraw!')
      return { renders = ui.cache[buf].n, marks = vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, { details = true }),
        height = vim.api.nvim_win_text_height(win, {}).all, linebreak = vim.wo[win].linebreak,
        tick = vim.api.nvim_buf_get_changedtick(buf), cursor = vim.api.nvim_win_get_cursor(win),
        view = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
    end
    local before = snapshot()
    local mini = require('noice.view').get_view('mini')
    local message = require('noice.message')('lsp', 'progress', 'Loading...')
    local samples = 0
    for index = 1, 12 do
      message:set('Loading ' .. index .. string.rep('.', index % 4))
      mini:set({ message })
      mini:display()
      vim.wait(110, function() return false end, 5)
      assert(mini.view._nui.winid and vim.api.nvim_win_is_valid(mini.view._nui.winid), 'Noice notification must remain visible')
      assert(vim.deep_equal(snapshot(), before), 'Noice progress changed ACP rendering or viewport at update ' .. index)
      samples = samples + 1
    end
    mini:dismiss()
    vim.wait(500, function() return false end, 5)
    assert(vim.deep_equal(snapshot(), before), 'notification closure reflowed ACP')
    require('noice').disable()
    view.kill_pane(pane, session)
    state.sessions[session.agent_name] = nil
    vim.fn.delete(path)
    return { samples = samples, renders = before.renders, extra_renders = 0 }
  ]=], root)
end, debug.traceback)
pcall(vim.rpcnotify, child, 'nvim_command', 'qa!')
if vim.fn.jobwait({ child }, 2000)[1] == -1 then vim.fn.jobstop(child) end
assert(ok, result)
print('PASS: real Noice progress preserves ACP decorations, source, cursor and viewport: ' .. vim.json.encode(result))
