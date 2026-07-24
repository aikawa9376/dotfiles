local M = {}

local api = vim.api
local preview_ns = api.nvim_create_namespace("LazyAgentImagePaste")

local function call_method(object, name)
  local method = object and object[name]
  if type(method) ~= "function" then
    return false
  end
  return pcall(method, object)
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr)
end

function M.new(ctx)
  local controller = {}
  local buffers = {}

  local function preview_opts()
    local opts = type(ctx.opts) == "function" and ctx.opts() or {}
    return type(opts) == "table" and opts or {}
  end

  local function is_acp_buffer(bufnr)
    return type(ctx.is_acp_buffer) == "function" and ctx.is_acp_buffer(bufnr) == true
  end

  local function visible_windows(bufnr)
    if not valid_buffer(bufnr) then
      return {}
    end

    local current = api.nvim_get_current_win()
    local windows = {}
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
        if win == current then
          table.insert(windows, 1, win)
        else
          windows[#windows + 1] = win
        end
      end
    end
    return windows
  end

  local function close_item(bufnr, buf_state, mark_id)
    local item = buf_state and buf_state.items and buf_state.items[mark_id] or nil
    if not item then
      return
    end
    call_method(item.placement, "close")
    if valid_buffer(bufnr) then
      pcall(api.nvim_buf_del_extmark, bufnr, preview_ns, mark_id)
    end
    buf_state.items[mark_id] = nil
  end

  local function close_items(bufnr, buf_state)
    if not buf_state or type(buf_state.items) ~= "table" then
      return
    end
    local mark_ids = vim.tbl_keys(buf_state.items)
    for _, mark_id in ipairs(mark_ids) do
      close_item(bufnr, buf_state, mark_id)
    end
  end

  local function clear_tracking(bufnr)
    local buf_state = buffers[bufnr]
    if not buf_state then
      return
    end
    close_items(bufnr, buf_state)
    if buf_state.augroup then
      pcall(api.nvim_del_augroup_by_id, buf_state.augroup)
    end
    buffers[bufnr] = nil
  end

  local function acp_scan_config()
    local opts = preview_opts()
    local max_previews = tonumber(opts.acp_max_previews)
    if max_previews == nil then
      max_previews = 6
    end
    local prefetch_lines = tonumber(opts.acp_prefetch_lines)
    if prefetch_lines == nil then
      prefetch_lines = 40
    end
    return {
      max_previews = math.max(0, math.floor(max_previews)),
      prefetch_lines = math.max(0, math.floor(prefetch_lines)),
    }
  end

  local function merge_ranges(ranges)
    table.sort(ranges, function(a, b)
      return a[1] < b[1]
    end)
    local merged = {}
    for _, range in ipairs(ranges) do
      local previous = merged[#merged]
      if previous and range[1] <= previous[2] + 1 then
        previous[2] = math.max(previous[2], range[2])
      else
        merged[#merged + 1] = { range[1], range[2] }
      end
    end
    return merged
  end

  local function scan_ranges(bufnr)
    local line_count = api.nvim_buf_line_count(bufnr)
    local windows = visible_windows(bufnr)
    if line_count <= 0 or #windows == 0 then
      return {}, nil, windows
    end
    if not is_acp_buffer(bufnr) then
      return { { 1, line_count } }, nil, windows
    end

    local cfg = acp_scan_config()
    if cfg.max_previews <= 0 then
      return {}, cfg, windows
    end

    local ranges = {}
    for _, win in ipairs(windows) do
      local ok, info = pcall(vim.fn.getwininfo, win)
      local bounds = ok and type(info) == "table" and info[1] or nil
      local top = type(bounds) == "table" and tonumber(bounds.topline) or 1
      local bottom = type(bounds) == "table" and tonumber(bounds.botline) or top
      ranges[#ranges + 1] = {
        math.max(1, (top or 1) - cfg.prefetch_lines),
        math.min(line_count, (bottom or 1) + cfg.prefetch_lines),
      }
    end
    return merge_ranges(ranges), cfg, windows
  end

  local function placement_opts(bufnr, reference, windows)
    local opts = preview_opts()
    local start_col = math.max(0, reference.start_col - 1)
    local placement = {
      inline = true,
      pos = { reference.row, start_col },
      range = { reference.row, start_col, reference.row, reference.end_col },
      max_width = opts.max_width,
      max_height = opts.max_height,
      auto_resize = opts.auto_resize ~= false,
    }

    if is_acp_buffer(bufnr) then
      local width
      local height
      for _, win in ipairs(windows) do
        local win_width = math.max(1, api.nvim_win_get_width(win) - 2)
        local win_height = math.max(1, api.nvim_win_get_height(win) - 2)
        width = width and math.min(width, win_width) or win_width
        height = height and math.min(height, win_height) or win_height
      end
      if type(opts.max_width) == "number" and opts.max_width > 0 then
        width = math.min(width or opts.max_width, opts.max_width)
      end
      if type(opts.max_height) == "number" and opts.max_height > 0 then
        height = math.min(height or opts.max_height, opts.max_height)
      end
      if width then
        placement.width = math.max(1, width)
        placement.max_width = placement.width
      end
      if height then
        placement.max_height = math.max(1, height)
      end
      placement.auto_resize = false
    end

    return placement
  end

  local function reference_key(row, source)
    return tostring(row) .. "\0" .. tostring(source)
  end

  local function desired_references(bufnr)
    local opts = preview_opts()
    local ranges, scan_cfg, windows = scan_ranges(bufnr)
    if opts.enabled == false or #ranges == 0 then
      return {}, windows
    end

    local desired = {}
    local limit = scan_cfg and scan_cfg.max_previews or math.huge
    for _, range in ipairs(ranges) do
      local lines = api.nvim_buf_get_lines(bufnr, range[1] - 1, range[2], false)
      for offset, line in ipairs(lines) do
        local candidate = ctx.extract_reference(line, { include_managed_refs = true })
        local source = candidate and (candidate.source_path or candidate.source_url) or nil
        if source then
          local start_col = math.max(1, math.min(#line + 1, tonumber(candidate.start_col) or 1))
          local end_col = math.max(start_col - 1, math.min(#line, tonumber(candidate.end_col) or #line))
          desired[#desired + 1] = {
            row = range[1] + offset - 1,
            start_col = start_col,
            end_col = end_col,
            source = source,
          }
          if #desired >= limit then
            return desired, windows
          end
        end
      end
    end
    return desired, windows
  end

  local function renderer()
    local snacks = type(ctx.load_snacks) == "function" and ctx.load_snacks() or nil
    local placement = snacks and snacks.image and snacks.image.placement or nil
    return placement and type(placement.new) == "function" and placement or nil
  end

  local function update_item(bufnr, mark_id, item, reference, windows)
    local next_opts = placement_opts(bufnr, reference, windows)
    local ok_mark = pcall(
      api.nvim_buf_set_extmark,
      bufnr,
      preview_ns,
      reference.row - 1,
      next_opts.pos[2],
      { id = mark_id, right_gravity = false }
    )
    if not ok_mark then
      return false
    end

    local owned = {
      "inline",
      "pos",
      "range",
      "width",
      "max_width",
      "max_height",
      "auto_resize",
    }
    item.placement.opts = item.placement.opts or {}
    for _, name in ipairs(owned) do
      item.placement.opts[name] = next_opts[name]
    end
    item.row = reference.row
    item.start_col = reference.start_col
    item.end_col = reference.end_col
    call_method(item.placement, "show")
    call_method(item.placement, "update")
    return true
  end

  local function create_item(bufnr, buf_state, reference, windows, placement_api)
    placement_api = placement_api or renderer()
    if not placement_api then
      return nil
    end

    local opts = placement_opts(bufnr, reference, windows)
    local ok, placement = pcall(placement_api.new, bufnr, reference.source, opts)
    if not ok or not placement then
      return nil
    end

    local ok_mark, mark_id = pcall(api.nvim_buf_set_extmark, bufnr, preview_ns, reference.row - 1, opts.pos[2], {
      right_gravity = false,
    })
    if not ok_mark then
      call_method(placement, "close")
      return nil
    end

    buf_state.items[mark_id] = {
      placement = placement,
      source = reference.source,
      row = reference.row,
      start_col = reference.start_col,
      end_col = reference.end_col,
    }
    return mark_id
  end

  local function reconcile(bufnr, buf_state)
    local desired, windows = desired_references(bufnr)
    local existing_by_key = {}
    local existing_by_source = {}
    local stale = {}

    for mark_id, item in pairs(buf_state.items) do
      local ok, pos = pcall(api.nvim_buf_get_extmark_by_id, bufnr, preview_ns, mark_id, {})
      if not ok or type(pos) ~= "table" or #pos < 2 or not item.placement or item.placement.closed then
        stale[#stale + 1] = mark_id
      else
        local key = reference_key(pos[1] + 1, item.source)
        local candidate = {
          mark_id = mark_id,
          item = item,
          row = pos[1] + 1,
          col = pos[2],
        }
        existing_by_key[key] = existing_by_key[key] or {}
        existing_by_key[key][#existing_by_key[key] + 1] = candidate
        existing_by_source[item.source] = existing_by_source[item.source] or {}
        existing_by_source[item.source][#existing_by_source[item.source] + 1] = candidate
      end
    end
    for _, mark_id in ipairs(stale) do
      close_item(bufnr, buf_state, mark_id)
    end

    local used = {}
    for _, candidates in pairs(existing_by_source) do
      table.sort(candidates, function(a, b)
        if a.row == b.row then
          if a.col == b.col then
            return a.mark_id < b.mark_id
          end
          return a.col < b.col
        end
        return a.row < b.row
      end)
    end

    local function take_candidate(candidates)
      while candidates and #candidates > 0 do
        local candidate = table.remove(candidates, 1)
        if buf_state.items[candidate.mark_id] and not used[candidate.mark_id] then
          return candidate
        end
      end
    end

    local placement_api
    for _, reference in ipairs(desired) do
      local key = reference_key(reference.row, reference.source)
      local matched = take_candidate(existing_by_key[key])
      if not matched then
        matched = take_candidate(existing_by_source[reference.source])
      end

      if matched then
        if update_item(bufnr, matched.mark_id, matched.item, reference, windows) then
          used[matched.mark_id] = true
        else
          close_item(bufnr, buf_state, matched.mark_id)
          matched = nil
        end
      end
      if not matched then
        placement_api = placement_api or renderer()
        local mark_id = create_item(bufnr, buf_state, reference, windows, placement_api)
        if mark_id then
          used[mark_id] = true
        end
      end
    end

    local unused = {}
    for mark_id in pairs(buf_state.items) do
      if not used[mark_id] then
        unused[#unused + 1] = mark_id
      end
    end
    for _, mark_id in ipairs(unused) do
      close_item(bufnr, buf_state, mark_id)
    end
  end

  local function refresh_delay(bufnr)
    local opts = preview_opts()
    if is_acp_buffer(bufnr) then
      local value = tonumber(opts.acp_refresh_debounce_ms)
      return math.max(0, math.floor(value == nil and 80 or value))
    end
    local value = tonumber(opts.refresh_debounce_ms)
    return math.max(0, math.floor(value or 0))
  end

  local schedule_refresh

  local function ensure_tracking(bufnr)
    local tracked = buffers[bufnr]
    if tracked then
      return tracked
    end

    local group = api.nvim_create_augroup("LazyAgentImagePreview" .. tostring(bufnr), { clear = true })
    tracked = {
      augroup = group,
      items = {},
      refresh_pending = false,
      refresh_token = 0,
      process_changes = false,
      process_changes_enabled = false,
    }
    buffers[bufnr] = tracked

    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter", "BufEnter", "WinEnter" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        schedule_refresh(bufnr, { process_changes = true })
      end,
    })

    api.nvim_create_autocmd({ "BufWinLeave", "BufHidden" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        schedule_refresh(bufnr, { immediate = true })
      end,
    })

    api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function(args)
        if not is_acp_buffer(bufnr) then
          return
        end
        local win = tonumber(args.match)
        if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
          schedule_refresh(bufnr)
        end
      end,
    })

    api.nvim_create_autocmd("WinResized", {
      group = group,
      callback = function()
        local opts = preview_opts()
        if is_acp_buffer(bufnr) or opts.auto_resize ~= false then
          schedule_refresh(bufnr)
        end
      end,
    })

    api.nvim_create_autocmd({ "WinClosed", "TabEnter" }, {
      group = group,
      callback = function()
        if next(tracked.items) or #visible_windows(bufnr) > 0 then
          schedule_refresh(bufnr, { immediate = true })
        end
      end,
    })

    api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = bufnr,
      callback = function()
        clear_tracking(bufnr)
      end,
    })

    return tracked
  end

  schedule_refresh = function(bufnr, opts)
    opts = opts or {}
    if not valid_buffer(bufnr) then
      clear_tracking(bufnr)
      return
    end
    local buf_state = ensure_tracking(bufnr)
    if opts.process_changes and buf_state.process_changes_enabled then
      buf_state.process_changes = true
    end
    if buf_state.refresh_pending and not opts.immediate then
      return
    end

    buf_state.refresh_pending = true
    buf_state.refresh_token = buf_state.refresh_token + 1
    local token = buf_state.refresh_token
    local function run()
      local current = buffers[bufnr]
      if not current or current.refresh_token ~= token then
        return
      end
      current.refresh_pending = false
      local process_changes = current.process_changes
      current.process_changes = false
      if not valid_buffer(bufnr) then
        clear_tracking(bufnr)
        return
      end
      if process_changes and not is_acp_buffer(bufnr) and type(ctx.on_buffer_changed) == "function" then
        pcall(ctx.on_buffer_changed, bufnr)
      end
      controller.refresh(bufnr)
    end

    local delay = opts.immediate and 0 or refresh_delay(bufnr)
    if delay == 0 then
      vim.schedule(run)
    else
      vim.defer_fn(run, delay)
    end
  end

  function controller.attach(bufnr)
    if not valid_buffer(bufnr) then
      return nil
    end
    local buf_state = ensure_tracking(bufnr)
    buf_state.process_changes_enabled = not is_acp_buffer(bufnr)
    schedule_refresh(bufnr, { process_changes = buf_state.process_changes_enabled, immediate = true })
    return bufnr
  end

  function controller.refresh(bufnr)
    if not valid_buffer(bufnr) then
      clear_tracking(bufnr)
      return nil
    end
    local buf_state = ensure_tracking(bufnr)
    reconcile(bufnr, buf_state)
    return bufnr
  end

  function controller.clear(bufnr)
    if type(bufnr) ~= "number" then
      return false
    end
    clear_tracking(bufnr)
    return true
  end

  return controller
end

return M
