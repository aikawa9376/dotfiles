local M = {}

-- Use real buffers/extmarks with a manually driven timer: every captured frame
-- can be compared without wall-clock races or touching a live agent session.
function M.exercise(module, force_full, frames)
  local uv = vim.uv or vim.loop
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'transcript', 'last line' })
  local ns = vim.api.nvim_create_namespace('footer_animation_fixture')
  local entry, padding, width = {}, 0, 70
  local session = { acp_ready = true, agent_status = 'thinking', agent_status_message = '考えています Thinking...',
    acp_agent_info = { title = 'Fixture', version = '1.0' }, acp_supports_image = true,
    show_session_summary = true, acp_session_info = { title = '日本語のタイトル', summary = string.rep('summary ', 12) } }
  local metrics = { writes = 0, buffer_scans = 0, window_scans = 0, highlights = 0, checks = 0, padding_writes = 0 }
  local originals = { timer = uv.new_timer, schedule = vim.schedule_wrap }
  local tracked = { nvim_buf_set_extmark = 'writes', nvim_list_bufs = 'buffer_scans',
    nvim_list_wins = 'window_scans', nvim_get_hl = 'highlights' }
  for name, metric in pairs(tracked) do
    originals[name] = vim.api[name]
    vim.api[name] = function(...)
      metrics[metric] = metrics[metric] + 1
      return originals[name](...)
    end
  end
  local tick, stopped = nil, false
  uv.new_timer = function()
    return { start = function(_, delay, interval, callback)
      assert(delay == 100 and interval == 100, 'animation cadence stays at 100ms')
      tick, stopped = callback, false
    end, stop = function() stopped = true end, close = function() end }
  end
  vim.schedule_wrap = function(callback) return callback end
  local snapshots = {}
  local ok, err = xpcall(function()
    local footer = module.new({ footer_ns = ns, state = { opts = {} },
      agent_logic = { get_visible_slash_commands = function() return {} end },
      session_for_agent = function() return session end,
      agent_name_for_bufnr = function() return 'Fixture' end,
      transcript_line_count = function() return vim.api.nvim_buf_line_count(buf) - padding end,
      overlay_target_width = function() return width end,
      is_acp_buffer = function(b) metrics.checks = metrics.checks + 1; return b == buf end,
      buffer_is_visible = function(b) return #vim.fn.win_findbuf(b) > 0 end,
      layout_entry = function() return entry end,
      footer_padding_count = function() return padding end,
      set_footer_padding = function(_, count)
        metrics.padding_writes = metrics.padding_writes + 1
        local tail = vim.api.nvim_buf_line_count(buf) - padding
        local blanks = {}; for _ = 1, count do blanks[#blanks + 1] = '' end
        vim.api.nvim_buf_set_lines(buf, tail, -1, false, blanks)
        padding = count
      end,
    })
    if force_full then
      local refresh = footer.refresh_footer
      footer.refresh_footer = function(b, opts)
        if opts and opts.animation_tick then opts.animation_tick = nil end
        return refresh(b, opts)
      end
    end
    local function snapshot()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      local result = {}
      for _, mark in ipairs(marks) do
        result[#result + 1] = { mark[2], mark[3], mark[4].virt_text, mark[4].virt_text_pos, mark[4].hl_mode }
      end
      snapshots[#snapshots + 1] = { marks = result, lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false) }
    end
    footer.refresh_footer(buf, { force = true })
    assert(tick, 'thinking starts timer')
    local ids = vim.deepcopy(entry.footer_extmark_ids)
    for key in pairs(metrics) do metrics[key] = 0 end
    collectgarbage('collect')
    local heap = collectgarbage('count')
    local started = uv.hrtime()
    for _ = 1, frames or 12 do tick() end
    metrics.ms = (uv.hrtime() - started) / 1e6
    collectgarbage('collect')
    metrics.retained_kib = collectgarbage('count') - heap
    assert(vim.deep_equal(ids, entry.footer_extmark_ids), 'steady frames preserve extmark IDs')
    assert(metrics.padding_writes == 0, 'steady frames never rewrite padding')
    local steady = vim.deepcopy(metrics)
    snapshot()
    tick(); snapshot()
    width = 34; tick(); snapshot()
    session.acp_session_info.summary = 'changed summary'; tick(); snapshot()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'new transcript line' }); tick(); snapshot()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1); tick(); snapshot()
    vim.api.nvim_set_hl(0, 'LazyAgentACPFooterMeta', { fg = 0xabcdef, italic = true }); tick(); snapshot()
    session.agent_status = 'waiting'; footer.refresh_footer(buf, { force = true }); snapshot()
    assert(stopped, 'waiting stops timer')
    session.agent_status = 'thinking'; footer.refresh_footer(buf, { force = true }); tick(); snapshot()
    vim.api.nvim_win_set_buf(win, previous)
    tick()
    assert(stopped, 'hidden footer stops timer')
    metrics = steady
  end, debug.traceback)
  uv.new_timer, vim.schedule_wrap = originals.timer, originals.schedule
  for name in pairs(tracked) do vim.api[name] = originals[name] end
  vim.api.nvim_win_set_buf(win, previous)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  return snapshots, metrics
end

function M.run()
  local module = require('lazyagent.acp.view_footer')
  local old_hl = vim.api.nvim_get_hl(0, { name = 'LazyAgentACPFooterMeta' })
  vim.api.nvim_set_hl(0, 'LazyAgentACPFooterMeta', { fg = 0x778899 })
  local optimized, metrics = M.exercise(module, false)
  vim.api.nvim_set_hl(0, 'LazyAgentACPFooterMeta', { fg = 0x778899 })
  local full, full_metrics = M.exercise(module, true)
  vim.api.nvim_set_hl(0, 'LazyAgentACPFooterMeta', old_hl)
  assert(vim.deep_equal(optimized, full), 'optimized frames must match full rendering through layout/state changes')
  assert(not vim.deep_equal(optimized[1], optimized[2]), 'animation still changes each frame')
  assert(metrics.writes < full_metrics.writes, 'steady animation avoids static extmark writes')
  assert(metrics.buffer_scans == 0 and metrics.window_scans == 12, 'one window scan per tick, no buffer scans')
end

return M
