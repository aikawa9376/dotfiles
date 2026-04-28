local M = {}

function M.new(ctx)
  local diff_utils = ctx.diff_utils
  local diff_ns = ctx.diff_ns or vim.api.nvim_create_namespace("lazyagent_acp_diff")
  local preview_ns = vim.api.nvim_create_namespace("lazyagent_acp_diff_preview")
  local util = require("lazyagent.util")

  local function session_for_agent(agent_name)
    return ctx.session_for_agent(agent_name)
  end

  local function transcript_line_count(bufnr)
    return ctx.transcript_line_count(bufnr)
  end

  local function transcript_lines(bufnr, start_idx, end_idx)
    if type(ctx.transcript_lines) == "function" then
      return ctx.transcript_lines(bufnr, start_idx, end_idx)
    end
    return vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
  end

  local function strdisplaywidth(text)
    local ok, width = pcall(vim.fn.strdisplaywidth, text)
    return ok and width or #tostring(text or "")
  end

  local function resolve_diff_path(session, path)
    path = tostring(path or "")
    if path == "" then
      return nil
    end
    if path:sub(1, 1) == "/" then
      return vim.fn.fnamemodify(path, ":p")
    end
    local base = session and (session.root_dir or session.cwd) or vim.fn.getcwd()
    return vim.fn.fnamemodify(base .. "/" .. path, ":p")
  end

  local function truncate_to_display_width(text, max_width)
    text = tostring(text or "")
    max_width = math.max(0, tonumber(max_width) or 0)
    if max_width <= 0 or strdisplaywidth(text) <= max_width then
      return text
    end

    local width = 0
    local out = {}
    local char_count = vim.fn.strchars(text)
    for idx = 0, math.max(0, char_count - 1) do
      local char = vim.fn.strcharpart(text, idx, 1)
      local char_width = math.max(0, strdisplaywidth(char))
      if width + char_width > max_width then
        break
      end
      out[#out + 1] = char
      width = width + char_width
    end
    return table.concat(out)
  end

  local function render_markdown_offset(value, used_width, win_width)
    value = tonumber(value) or 0
    used_width = math.max(0, tonumber(used_width) or 0)
    win_width = math.max(0, tonumber(win_width) or 0)
    if value <= 0 then
      return 0
    end
    if value >= 1 then
      return math.floor(value)
    end
    return math.max(0, math.floor(((win_width - used_width) * value) + 0.5))
  end

  local function render_markdown_code_prefix_width(bufnr, opening_line, body_lines, win_width)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return 0
    end

    local ok_state, state = pcall(require, "render-markdown.state")
    if not ok_state or type(state.get) ~= "function" then
      return 0
    end

    local ok_config, config = pcall(state.get, bufnr)
    local code = ok_config and type(config) == "table" and type(config.code) == "table" and config.code or nil
    if not code or config.enabled == false or code.enabled == false then
      return 0
    end

    local content_width = strdisplaywidth(opening_line or "")
    for _, line in ipairs(body_lines or {}) do
      content_width = math.max(content_width, strdisplaywidth(line))
    end

    local language_padding = render_markdown_offset(code.language_pad, content_width, win_width)
    local left_padding = render_markdown_offset(code.left_pad, content_width, win_width)
    local right_padding = render_markdown_offset(code.right_pad, content_width, win_width)
    local body_width = strdisplaywidth(code.language_left or "")
      + strdisplaywidth(code.language_right or "")
      + language_padding
      + strdisplaywidth(opening_line or "")
    body_width = math.max(
      body_width,
      left_padding + content_width + right_padding,
      tonumber(code.min_width) or 0
    )

    return left_padding + render_markdown_offset(code.left_margin, body_width, win_width)
  end

  local function path_for_fence(lines, fence_start)
    for scan = fence_start - 1, math.max(1, fence_start - 3), -1 do
      local path = (lines[scan] or ""):match("^%s*Path:%s+(.+)$")
      if path and path ~= "" then
        return path
      end
    end
    return nil
  end

  local function truncate_diff_marker_line(line, width)
    line = tostring(line or "")
    width = math.max(0, tonumber(width) or 0)
    if width <= 0 or strdisplaywidth(line) <= width then
      return line, false
    end

    local prefix = line:match("^(%s*[-+] )")
    if not prefix then
      return line, false
    end

    local ellipsis = "..."
    local body_width = width - strdisplaywidth(prefix) - strdisplaywidth(ellipsis)
    if body_width <= 0 then
      return prefix .. ellipsis, true
    end

    local body = line:sub(#prefix + 1)
    local truncated = truncate_to_display_width(body, body_width):gsub("%s+$", "")
    if truncated == "" then
      return prefix .. ellipsis, true
    end
    return prefix .. truncated .. ellipsis, true
  end

  local function truncate_code_block_line(line, width)
    line = tostring(line or "")
    width = math.max(0, tonumber(width) or 0)
    if width <= 0 or strdisplaywidth(line) <= width then
      return line, false
    end

    if line:match("^(%s*[-+] )") then
      return truncate_diff_marker_line(line, width)
    end

    local ellipsis = "..."
    local body_width = width - strdisplaywidth(ellipsis)
    if body_width <= 0 then
      return ellipsis, true
    end

    local truncated = truncate_to_display_width(line, body_width):gsub("%s+$", "")
    if truncated == "" then
      return ellipsis, true
    end
    return truncated .. ellipsis, true
  end

  local function normalize_diff_display_lines(bufnr, lines, width)
    lines = type(lines) == "table" and vim.deepcopy(lines) or {}
    width = math.max(0, tonumber(width) or 0)
    if #lines == 0 or width <= 0 then
      return lines, false
    end

    local changed = false
    local fence_start = nil
    for idx, line in ipairs(lines) do
      if tostring(line or ""):match("^%s*```") then
        if fence_start then
          local body_lines = vim.list_slice(lines, fence_start + 1, idx - 1)
          local available_width = math.max(
            0,
            width - render_markdown_code_prefix_width(bufnr, lines[fence_start], body_lines, width)
          )
          for body_idx = fence_start + 1, idx - 1 do
            local updated, line_changed = truncate_code_block_line(lines[body_idx], available_width)
            if line_changed then
              lines[body_idx] = updated
              changed = true
            end
          end
          fence_start = nil
        else
          fence_start = idx
        end
      end
    end

    return lines, changed
  end

  local function find_diff_block_at_row(bufnr, row)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end

    local transcript_stop = transcript_line_count(bufnr)
    if transcript_stop <= 0 then
      return nil
    end

    local lines = transcript_lines(bufnr, 0, transcript_stop)
    local idx = math.min(math.max(1, (tonumber(row) or 0) + 1), #lines)
    if lines[idx] and lines[idx]:match("^%s*Path:%s+") and lines[idx + 1] and lines[idx + 1]:match("^%s*```") then
      idx = idx + 1
    end

    local fence_start = nil
    for scan = idx, 1, -1 do
      if (lines[scan] or ""):match("^%s*```") then
        fence_start = scan
        break
      end
    end
    if not fence_start then
      return nil
    end

    local fence_end = nil
    for scan = fence_start + 1, #lines do
      if (lines[scan] or ""):match("^%s*```") then
        fence_end = scan
        break
      end
    end
    if not fence_end or idx < fence_start or idx > fence_end then
      return nil
    end

    local body_lines = vim.list_slice(lines, fence_start + 1, fence_end - 1)
    local parsed = diff_utils.parse_rendered_diff_block(body_lines)
    if #(parsed.old_lines or {}) == 0 and #(parsed.new_lines or {}) == 0 then
      return nil
    end

    return {
      path = path_for_fence(lines, fence_start),
      body_lines = body_lines,
    }
  end

  local function git_diff_lines(cwd, path)
    local diff = vim.fn.systemlist(
      "git -C " .. vim.fn.shellescape(cwd)
      .. " diff --unified=0 -- " .. vim.fn.shellescape(path)
      .. " 2>/dev/null"
    )
    if vim.v.shell_error ~= 0 or type(diff) ~= "table" then
      return {}
    end
    return diff
  end

  local function tab_has_diff(tabnr)
    tabnr = tabnr or vim.api.nvim_get_current_tabpage()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
      if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
        return true
      end
    end
    return false
  end

  local function git_repo_relative_path(cwd, abs_path)
    local rel = vim.fn.systemlist(
      "git -C " .. vim.fn.shellescape(cwd)
      .. " ls-files --full-name -- " .. vim.fn.shellescape(abs_path)
      .. " 2>/dev/null"
    )
    if vim.v.shell_error == 0 and type(rel) == "table" and rel[1] and rel[1] ~= "" then
      return rel[1]
    end

    local root = vim.fn.systemlist(
      "git -C " .. vim.fn.shellescape(cwd) .. " rev-parse --show-toplevel 2>/dev/null"
    )
    if vim.v.shell_error ~= 0 or type(root) ~= "table" or not root[1] or root[1] == "" then
      return nil
    end

    local root_path = vim.fn.fnamemodify(root[1], ":p")
    local normalized_path = vim.fn.fnamemodify(abs_path, ":p")
    if normalized_path:sub(1, #root_path) ~= root_path then
      return nil
    end

    local rel_path = normalized_path:sub(#root_path + 1)
    if rel_path:sub(1, 1) == "/" then
      rel_path = rel_path:sub(2)
    end
    return rel_path ~= "" and rel_path or nil
  end

  local function read_file_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
      return {}
    end
    return lines
  end

  local function set_diff_close_keymap(bufnr)
    vim.keymap.set("n", "q", function()
      pcall(vim.cmd, "tabclose")
    end, {
      buffer = bufnr,
      silent = true,
      noremap = true,
      desc = "Close ACP diff tab",
    })
  end

  local function configure_diff_buffer(bufnr, abs_path, lines, name, role)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].filetype = diff_utils.language_from_path(abs_path)
    vim.b[bufnr].lazyagent_diff_source_path = vim.fn.fnamemodify(abs_path, ":p")
    vim.b[bufnr].lazyagent_diff_role = role
    pcall(vim.api.nvim_buf_set_name, bufnr, name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    set_diff_close_keymap(bufnr)
  end

  local function open_builtin_head_diff(abs_path, cwd)
    local rel_path = git_repo_relative_path(cwd, abs_path)
    if not rel_path then
      return nil
    end

    local head_lines = vim.fn.systemlist(
      "git -C " .. vim.fn.shellescape(cwd)
      .. " show " .. vim.fn.shellescape("HEAD:" .. rel_path)
      .. " 2>/dev/null"
    )
    if vim.v.shell_error ~= 0 or type(head_lines) ~= "table" then
      head_lines = {}
    end

    local current_lines = read_file_lines(abs_path)
    local stamp = tostring(vim.loop.hrtime())

    local ok_tab = pcall(vim.cmd, "tabnew")
    if not ok_tab then
      return nil
    end

    local work_win = vim.api.nvim_get_current_win()
    local work_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(work_win, work_buf)
    configure_diff_buffer(
      work_buf,
      abs_path,
      current_lines,
      string.format("lazyagent://diff/worktree/%s/%s", stamp, rel_path:gsub("%s+", "_")),
      "worktree"
    )
    vim.wo[work_win].wrap = false

    vim.cmd("leftabove vnew")
    local head_win = vim.api.nvim_get_current_win()
    local head_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(head_win, head_buf)
    configure_diff_buffer(
      head_buf,
      abs_path,
      head_lines,
      string.format("lazyagent://diff/head/%s/%s", stamp, rel_path:gsub("%s+", "_")),
      "head"
    )
    vim.wo[head_win].wrap = false

    pcall(vim.cmd, "diffthis")
    pcall(vim.api.nvim_set_current_win, work_win)
    pcall(vim.cmd, "diffthis")
    pcall(vim.api.nvim_set_current_win, work_win)
    if not tab_has_diff() then
      return nil
    end
    return work_win
  end

  local function file_window_for_path(tabnr, abs_path)
    tabnr = tabnr or vim.api.nvim_get_current_tabpage()
    local normalized = vim.fn.fnamemodify(abs_path, ":p")
    local fallback = nil
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and vim.fn.fnamemodify(name, ":p") == normalized then
          return win
        end
        local ok_path, source_path = pcall(vim.api.nvim_buf_get_var, buf, "lazyagent_diff_source_path")
        if ok_path and source_path and vim.fn.fnamemodify(source_path, ":p") == normalized then
          local ok_role, role = pcall(vim.api.nvim_buf_get_var, buf, "lazyagent_diff_role")
          if ok_role and role == "worktree" then
            return win
          end
          fallback = fallback or win
        end
      end
    end
    return fallback
  end

  local function is_standard_window(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return false
    end

    local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
    if not ok_cfg or (cfg and cfg.relative ~= "") then
      return false
    end

    local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
    if not ok_buf or not buf or not vim.api.nvim_buf_is_valid(buf) then
      return false
    end

    local ok_pane, pane_id = pcall(vim.api.nvim_buf_get_var, buf, "lazyagent_acp_pane_id")
    if ok_pane and pane_id ~= nil then
      return false
    end

    local buftype = vim.bo[buf].buftype
    return buftype == "" or buftype == "acwrite"
  end

  local function preferred_source_window(session)
    local candidates = {
      session and session.view_state and session.view_state.source_winid or nil,
    }

    local ok_current, current = pcall(vim.api.nvim_get_current_win)
    if ok_current then
      candidates[#candidates + 1] = current
    end

    for _, win in ipairs(candidates) do
      if is_standard_window(win) then
        return win
      end
    end

    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if is_standard_window(win) then
        return win
      end
    end

    return nil
  end

  local function highlight_preview_line(bufnr, line)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local row = math.max(0, (tonumber(line) or 1) - 1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, preview_ns, 0, -1)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, preview_ns, row, 0, {
      line_hl_group = "Visual",
      hl_eol = true,
      priority = 250,
    })
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_clear_namespace, bufnr, preview_ns, 0, -1)
      end
    end, 1500)
  end

  local function resolve_diff_target(bufnr)
    local agent_name = ctx.agent_name_for_bufnr(bufnr)
    local session = session_for_agent(agent_name)
    local row = (vim.api.nvim_win_get_cursor(0) or { 1, 0 })[1] - 1
    local block = find_diff_block_at_row(bufnr, row)
    if not block or not block.path then
      return nil
    end

    local abs_path = resolve_diff_path(session, block.path)
    if not abs_path or vim.fn.filereadable(abs_path) ~= 1 then
      return {
        session = session,
        block = block,
        abs_path = abs_path,
        missing = true,
      }
    end

    local cwd = session and (session.root_dir or session.cwd) or vim.fn.getcwd()
    local line = diff_utils.line_for_rendered_block(block.body_lines, git_diff_lines(cwd, abs_path)) or 1
    return {
      session = session,
      block = block,
      abs_path = abs_path,
      cwd = cwd,
      line = line,
    }
  end

  local function open_git_diff_tab(abs_path, cwd, session)
    local source_win = preferred_source_window(session)
    if source_win and vim.api.nvim_win_is_valid(source_win) then
      pcall(vim.api.nvim_set_current_win, source_win)
    end
    return open_builtin_head_diff(abs_path, cwd)
  end

  local function apply_diff_range(bufnr, row, start_col, end_col, hl_group)
    if start_col >= end_col then
      return
    end
    vim.highlight.range(bufnr, diff_ns, hl_group, { row, start_col }, { row, end_col })
  end

  local function is_diff_marker_line(line)
    return type(line) == "string" and line:match("^%s*[-+] ") ~= nil
  end

  local function decorate_diff_block(bufnr, start_row, end_row)
    if end_row < start_row then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local has_diff = false
    for _, line in ipairs(lines) do
      if is_diff_marker_line(line) then
        has_diff = true
        break
      end
    end
    if not has_diff then
      return
    end

    local idx = 1
    while idx <= #lines do
      local line = lines[idx]
      local row = start_row + idx - 1
      local old_prefix = line and line:match("^(%s*%- )")
      local new_prefix = line and line:match("^(%s*%+ )")

      if old_prefix then
        apply_diff_range(bufnr, row, 0, #line, "LazyAgentACPDiffDelete")
        local next_line = lines[idx + 1]
        local next_row = row + 1
        local next_prefix = next_line and next_line:match("^(%s*%+ )")
        if next_prefix then
          apply_diff_range(bufnr, next_row, 0, #next_line, "LazyAgentACPDiffAdd")
          local old_text = line:sub(#old_prefix + 1)
          local new_text = next_line:sub(#next_prefix + 1)
          local change = diff_utils.find_inline_change(old_text, new_text)
          if change then
            apply_diff_range(
              bufnr,
              row,
              #old_prefix + change.old_start,
              #old_prefix + change.old_end,
              "LazyAgentACPDiffDeleteWord"
            )
            apply_diff_range(
              bufnr,
              next_row,
              #next_prefix + change.new_start,
              #next_prefix + change.new_end,
              "LazyAgentACPDiffAddWord"
            )
          end
          idx = idx + 2
        else
          idx = idx + 1
        end
      elseif new_prefix then
        apply_diff_range(bufnr, row, 0, #line, "LazyAgentACPDiffAdd")
        idx = idx + 1
      else
        idx = idx + 1
      end
    end
  end

  local api = {}

  function api.normalize_diff_display_lines(bufnr, lines, width)
    return normalize_diff_display_lines(bufnr, lines, width)
  end

  function api.open_diff_block_under_cursor(bufnr)
    local target = resolve_diff_target(bufnr)
    if not target or not target.block or not target.block.path then
      return false
    end

    if target.missing then
      vim.notify("LazyAgentACP: file not found for diff block", vim.log.levels.WARN)
      return true
    end

    local diff_win = open_git_diff_tab(target.abs_path, target.cwd, target.session)
    if not diff_win then
      vim.notify("LazyAgentACP: failed to open git diff for " .. target.block.path, vim.log.levels.WARN)
      return true
    end

    vim.schedule(function()
      local target_win = (diff_win and vim.api.nvim_win_is_valid(diff_win)) and diff_win
        or file_window_for_path(nil, target.abs_path)
      if target_win and vim.api.nvim_win_is_valid(target_win) then
        pcall(vim.api.nvim_set_current_win, target_win)
        pcall(vim.api.nvim_win_set_cursor, target_win, { math.max(1, tonumber(target.line) or 1), 0 })
        pcall(vim.cmd, "normal! zz")
      end
    end)

    return true
  end

  function api.has_diff_block_under_cursor(bufnr)
    local target = resolve_diff_target(bufnr)
    return target ~= nil and target.block ~= nil and target.block.path ~= nil
  end

  function api.preview_diff_block_under_cursor(bufnr)
    local target = resolve_diff_target(bufnr)
    if not target or not target.block or not target.block.path then
      return false
    end
    if target.missing then
      vim.notify("LazyAgentACP: file not found for diff block", vim.log.levels.WARN)
      return true
    end

    if not util.open_in_normal_win(target.abs_path, { line = target.line }) then
      vim.notify("LazyAgentACP: failed to preview source for " .. target.block.path, vim.log.levels.WARN)
      return true
    end

    local buf = vim.api.nvim_get_current_buf()
    highlight_preview_line(buf, target.line)
    return true
  end

  function api.decorate_diff_blocks(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local transcript_stop = transcript_line_count(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
    if transcript_stop <= 0 then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, transcript_stop, false)
    local fence_start = nil
    for idx, line in ipairs(lines) do
      if line:match("^%s*```") then
        if fence_start then
          decorate_diff_block(bufnr, fence_start, idx - 2)
          fence_start = nil
        else
          fence_start = idx
        end
      end
    end
  end

  return api
end

return M
