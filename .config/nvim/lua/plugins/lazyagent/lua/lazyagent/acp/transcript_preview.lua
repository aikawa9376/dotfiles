local markdown_renderer = require("lazyagent.markdown_renderer")
local M = {}
local sections = require("lazyagent.acp.view_buffer.sections")
local viewport = require("lazyagent.acp.view_buffer.viewport")
local ns = vim.api.nvim_create_namespace("lazyagent_acp_preview")

-- A display-only adapter: it owns no ACP pane, runtime, footer or follow state.
function M.attach(bufnr)
  local source, transcript, provider, width
  local markdown_timer
  local generation = 0
  local entry = { transcript_display_meta = { pinned_rows = {} } }
  local function visible_window()
    return vim.fn.win_findbuf(bufnr)[1]
  end
  local function replace(_, start, stop, lines)
    local modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, start, stop, false, lines)
    vim.bo[bufnr].modifiable = modifiable
    vim.bo[bufnr].modified = false
  end
  local renderer = require("lazyagent.acp.view_buffer.render").new({
    section_heading_for_line = sections.section_heading_for_line,
    replace_heading_token = sections.replace_heading_token,
    section_style_for_line = sections.section_style_for_line,
    line_has_tail = sections.line_has_tail,
    first_visible_window = visible_window,
    fancy_mode_enabled = function() return false end,
    provider_for_bufnr = function() return provider end,
    strdisplaywidth = vim.fn.strdisplaywidth,
    layout_entry = function() return entry end,
    transcript_line_count = function() return vim.api.nvim_buf_line_count(bufnr) end,
    replace_buffer_lines = replace,
    transcript_ns = ns,
    ensure_highlights = require("lazyagent.acp.highlights").setup,
    truncate_headers = true,
    preserve_assistant_icon = true,
  })

  local function markdown()
    pcall(require("lazyagent.acp.highlighter").start, bufnr)
    local ok, manager = pcall(markdown_renderer.require, "core.manager")
    if ok and type(manager.attach) == "function" then pcall(manager.attach, bufnr) end
    local ok_ui, ui = pcall(markdown_renderer.require, "core.ui")
    local win = visible_window()
    if ok_ui and type(ui.update) == "function" and win then
      pcall(ui.update, bufnr, win, "LazyAgentACPPreview", false)
      -- The external renderer throttles leading updates. Retry the final frame
      -- after its debounce so a quick mode/thread change cannot remain stale.
      local state = markdown_renderer.loaded("state")
      local config = state and state.cache and state.cache[bufnr]
      local delay = config and tonumber(config.debounce) or 0
      if delay > 0 then
        markdown_timer = markdown_timer or (vim.uv or vim.loop).new_timer()
        local token = generation
        markdown_timer:start(delay + 10, 0, vim.schedule_wrap(function()
          if token ~= generation or not source or not vim.api.nvim_buf_is_valid(bufnr) then return end
          local current_win = visible_window()
          if current_win then pcall(ui.update, bufnr, current_win, "LazyAgentACPPreview", false) end
        end))
      end
    end
  end

  local function decorate()
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    if not transcript then return end
    for _, range in ipairs(viewport.ranges(bufnr, 80)) do
      renderer.decorate_transcript_range(bufnr, range[1], range[2])
    end
  end

  local function render()
    generation = generation + 1
    if markdown_timer then markdown_timer:stop() end
    local win = visible_window()
    width = win and vim.api.nvim_win_get_width(win) or nil
    local lines = transcript and renderer.normalize_header_lines(bufnr, source) or source
    replace(bufnr, 0, -1, lines)
    decorate()
    markdown()
  end

  -- The buffer owns these callbacks. Wiping it releases the source snapshot.
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter" }, {
    buffer = bufnr,
    callback = function() if source then decorate() end end,
  })
  local group = vim.api.nvim_create_augroup("LazyAgentACPPreviewRender" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if not source then return end
      local win = visible_window()
      if not win then return end
      if width ~= vim.api.nvim_win_get_width(win) then render() else decorate() end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      source = nil
      generation = generation + 1
      if markdown_timer then
        markdown_timer:stop()
        markdown_timer:close()
        markdown_timer = nil
      end
      vim.api.nvim_del_augroup_by_id(group)
      -- History-only Cockpits need not have initialized the live view's cleanup.
      local ui = markdown_renderer.loaded("core.ui")
      local decorator = ui and ui.cache and ui.cache[bufnr]
      if decorator and decorator.timer then
        decorator.timer:stop()
        if not decorator.timer:is_closing() then decorator.timer:close() end
        decorator.timer = nil
      end
      if ui and ui.cache then ui.cache[bufnr] = nil end
      local state = markdown_renderer.loaded("state")
      if state and state.cache then state.cache[bufnr] = nil end
      local manager = markdown_renderer.loaded("core.manager")
      if manager and manager.buffers then
        for index = #manager.buffers, 1, -1 do
          if manager.buffers[index] == bufnr then table.remove(manager.buffers, index) end
        end
      end
    end,
  })

  return {
    set = function(lines, opts)
      source, transcript, provider = lines, opts.transcript == true, opts.provider
      -- All modes share the ACP Markdown adapter; only mirrors paint role headers.
      -- Keeping the filetype stable also retains one renderer configuration/cache.
      if vim.bo[bufnr].filetype ~= "lazyagent_acp" then vim.bo[bufnr].filetype = "lazyagent_acp" end
      render()
    end,
  }
end

return M
