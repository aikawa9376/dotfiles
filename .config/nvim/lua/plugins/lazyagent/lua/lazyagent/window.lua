local M = {}
local cache_logic = require("lazyagent.logic.cache")

local winid = nil
local scratch_bufnr = nil
local float_autocmd_group_id = nil
local float_original_opts = nil
local float_is_focused = false

local function ensure_scratch_buffer(bufnr, opts)
  -- Normalize accepting either (bufnr, opts) or (opts) as the first parameter.
  if type(bufnr) == "table" and opts == nil then
    opts = bufnr
    bufnr = nil
  end

  -- If the caller didn't pass a valid buffer, create a scratch buffer to avoid nvim_open_win assertion errors.
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(false, true)
    pcall(function()
      vim.bo[bufnr].bufhidden = "hide"
      vim.bo[bufnr].buftype = "nofile"
      vim.bo[bufnr].filetype = (opts and opts.filetype) or "lazyagent"
      vim.bo[bufnr].modifiable = true
    end)

    -- Remember this scratch buffer so we can restore it if another file is opened here.
    scratch_bufnr = bufnr
    pcall(function() vim.b[bufnr].lazyagent_is_scratch = true end)

    -- Provide buffer-local :edit / :e that open files in the last non-special window
    pcall(function()
      vim.api.nvim_buf_create_user_command(bufnr, "edit", function(cmd)
        local path = cmd.args or ""
        if path and path ~= "" then
          local util = require("lazyagent.util")
          util.open_in_normal_win(vim.fn.expand(path))
        end
      end, { nargs = "?", complete = "file" })

      vim.api.nvim_buf_create_user_command(bufnr, "e", function(cmd)
        local path = cmd.args or ""
        if path and path ~= "" then
          local util = require("lazyagent.util")
          util.open_in_normal_win(vim.fn.expand(path))
        end
      end, { nargs = "?", complete = "file" })
    end)
  end

  -- Keep a reference to the source buffer when provided so downstream logic
  -- (transforms/completion) can resolve context consistently.
  if opts and opts.source_bufnr then
    pcall(function() vim.b[bufnr].lazyagent_source_bufnr = opts.source_bufnr end)
  end

  return bufnr, opts
end

local function apply_window_defaults(id)
  vim.wo[id].rnu = false
  vim.wo[id].number = false
  vim.wo[id].cursorline = true
  vim.wo[id].wrap = true
  -- pcall(function() vim.wo[id].winfixbuf = true end)
end

local function is_normal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and config and config.relative == ""
end

local function resolve_parent_window(opts)
  local requested = opts and (opts.parent_winid or opts.source_winid or opts.origin_winid) or nil
  if is_normal_window(requested) then
    return requested
  end

  local current = vim.api.nvim_get_current_win()
  if is_normal_window(current) then
    return current
  end

  return nil
end

local function resolve_window_area(opts)
  local parent = resolve_parent_window(opts)
  if parent then
    local pos = vim.api.nvim_win_get_position(parent)
    return {
      row = pos[1],
      col = pos[2],
      width = vim.api.nvim_win_get_width(parent),
      height = vim.api.nvim_win_get_height(parent),
      parent_winid = parent,
    }
  end

  return {
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    parent_winid = nil,
  }
end

local function clamp_size_to_area(width, height, area)
  width = math.max(10, math.min(width, math.max(10, area.width - 2)))
  height = math.max(3, math.min(height, math.max(3, area.height - 2)))
  return width, height
end

M.ensure_scratch_buffer = ensure_scratch_buffer

function M.open_float(bufnr, opts)
  -- Ensure we always get a valid buffer and canonical opts table.
  bufnr, opts = ensure_scratch_buffer(bufnr, opts or {})
  -- Record the previously focused normal window so we can restore files opened here.
  pcall(function()
    local prev_win = resolve_parent_window(opts) or vim.api.nvim_get_current_win()
    pcall(function() vim.b[bufnr].lazyagent_prev_win = prev_win end)
  end)

  local area = resolve_window_area(opts)

  -- Center the floating window relative to the source/parent window when available.
  local width = math.floor(area.width * (opts.is_vertical and 0.6 or 0.5))
  local height = math.floor(area.height * (opts.is_vertical and 0.3 or 0.5))

  -- Apply specific window overrides if provided
  if opts.window_opts then
    if opts.window_opts.width_ratio then
      width = math.floor(area.width * opts.window_opts.width_ratio)
    elseif opts.window_opts.width then
      width = opts.window_opts.width
    end

    if opts.window_opts.height_ratio then
      height = math.floor(area.height * opts.window_opts.height_ratio)
    elseif opts.window_opts.height then
      height = opts.window_opts.height
    end
  end

  width, height = clamp_size_to_area(width, height, area)

  local row = area.row + math.floor((area.height - height) / 2)
  local col = area.col + math.floor((area.width - width) / 2)

  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "single",
    style = "minimal",
    title = opts.title or " lazyagent ",
    title_pos = "center",
  }

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    winid = vim.api.nvim_open_win(bufnr, true, win_opts)
  else
    -- If window exists, just set buffer and focus
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)
  end

  -- Setup focus-change behavior for floating window:
  -- shrink to bottom-right when focus leaves, and restore original size when focus returns.
  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
  end

  float_original_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = win_opts.border,
    style = win_opts.style,
    title = win_opts.title,
    title_pos = win_opts.title_pos,
  }
  float_is_focused = true

  local function shrink_float()
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    local shrink_area = resolve_window_area(opts)
    -- Small size and place in bottom-right corner
    local w = math.max(10, math.floor(shrink_area.width * 0.2))
    local h = math.max(3, math.floor(shrink_area.height * (opts.is_vertical and 0.1 or 0.2)))
    w, h = clamp_size_to_area(w, h, shrink_area)
    local r = shrink_area.row + math.max(0, shrink_area.height - h)
    local c = shrink_area.col + math.max(0, shrink_area.width - w)
    local cfg = {
      relative = "editor",
      row = r,
      col = c,
      width = w,
      height = h,
      border = float_original_opts.border,
      style = float_original_opts.style,
      title = float_original_opts.title,
      title_pos = float_original_opts.title_pos,
    }
    pcall(function() vim.api.nvim_win_set_config(winid, cfg) end)
  end

  local function restore_float()
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    pcall(function() vim.api.nvim_win_set_config(winid, float_original_opts) end)
  end

  local gid = vim.api.nvim_create_augroup("LazyAgentFloat" .. tostring(winid), { clear = true })
  float_autocmd_group_id = gid
  vim.api.nvim_create_autocmd("WinEnter", {
    group = gid,
    callback = function()
      local curr = vim.api.nvim_get_current_win()
      if curr == winid then
        -- When floating window regains focus, restore original position/size and enter insert.
        if not float_is_focused then
          restore_float()
          float_is_focused = true
          if opts and opts.start_in_insert_on_focus then
            pcall(function() vim.cmd("startinsert") end)
          end
        end
      else
        -- When focus moves away, shrink and move it to the bottom-right.
        if float_is_focused then
          shrink_float()
          float_is_focused = false
        end

        -- Update the source buffer to the current buffer if we are in a normal buffer
        local current_buf = vim.api.nvim_get_current_buf()
        -- Ensure we are not tracking the lazyagent buffer itself, nor special buffers
        if current_buf ~= bufnr and vim.api.nvim_buf_is_valid(current_buf) and vim.bo[current_buf].buftype == "" then
           pcall(function() vim.b[bufnr].lazyagent_source_bufnr = current_buf end)
        end
      end
    end,
  })

  apply_window_defaults(winid)

  if opts and opts.start_in_insert_on_focus then
    vim.cmd("startinsert") -- Start in insert mode
  end
end

function M.open_vsplit(bufnr, opts)
  -- Ensure we always get a valid buffer and canonical opts table.
  bufnr, opts = ensure_scratch_buffer(bufnr, opts or {})
  pcall(function()
    local prev_win = resolve_parent_window(opts) or vim.api.nvim_get_current_win()
    pcall(function() vim.b[bufnr].lazyagent_prev_win = prev_win end)
  end)
  -- If a float autocmd group is active, clear it as we are switching to vsplit mode.
  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
    float_original_opts = nil
    float_is_focused = false
  end
  local area = resolve_window_area(opts)
  local width = math.max(10, math.floor(area.width * 0.5))

  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)
  else
    local parent = resolve_parent_window(opts)
    if parent then
      pcall(vim.api.nvim_set_current_win, parent)
    end
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(vim.api.nvim_get_current_win(), width)
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end

  apply_window_defaults(winid)
  if opts and opts.start_in_insert_on_focus then
    vim.cmd("startinsert")
  end
  return winid
end

function M.open(bufnr, opts)
  -- Accept either (bufnr, opts) or (opts) calling style and ensure a valid buffer/opts.
  if type(bufnr) == "table" and opts == nil then
    opts = bufnr
    bufnr = nil
  end
  bufnr, opts = ensure_scratch_buffer(bufnr, opts or {})
  local window_type = opts.window_type or "float"

  if window_type == "vsplit" then
    return M.open_vsplit(bufnr, opts)
  else
    return M.open_float(bufnr, opts)
  end
end

local function buffer_has_content(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or not lines then
    return false
  end
  for _, l in ipairs(lines) do
    if l and l:match("%S") then
      return true
    end
  end
  return false
end

function M.close(opts)
  opts = opts or {}
  local bufnr = winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) or nil

  if not (opts.force) and buffer_has_content(bufnr) then
    local raw_choice = vim.fn.confirm(
      "Scratch buffer has content. Close?",
      "&Yes\n&No\n&Save to history",
      3
    )
    local choice = tonumber(raw_choice) or 0
    if choice == 2 or choice == 0 then
      return false
    end
    if choice == 3 then
      pcall(cache_logic.write_scratch_to_cache, bufnr)
    end
  end

  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
    winid = nil
  end

  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
  end
  float_original_opts = nil
  float_is_focused = false
  return true
end

function M.is_open()
  return winid and vim.api.nvim_win_is_valid(winid)
end

function M.get_bufnr()
  if winid and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_buf(winid)
  end
  return nil
end

function M.get_winid()
  return winid
end

function M.get_scratch_bufnr()
  return scratch_bufnr
end

function M.set_title(title)
  if winid and vim.api.nvim_win_is_valid(winid) then
    local config = vim.api.nvim_win_get_config(winid)
    if config.relative ~= "" then
       config.title = title
       pcall(vim.api.nvim_win_set_config, winid, config)
    end
  end
end

-- Redirect files accidentally opened in the scratch window to the last normal window.
pcall(function()
  local group = vim.api.nvim_create_augroup("LazyAgentRedirectOpen", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      pcall(function()
        local win = vim.api.nvim_get_current_win()
        if type(args) == "table" then
          local aw = args["win"]
          if aw and aw ~= 0 then
            win = aw
          end
        end
        if not win or win == 0 then return end
        if winid == nil or not vim.api.nvim_win_is_valid(winid) then return end
        if win ~= winid then return end
        local buf = args.buf or vim.api.nvim_get_current_buf()
        if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
        -- Skip if it's the scratch buffer
        if vim.bo[buf].filetype == "lazyagent" then return end
        -- Only handle buffers with a real filename
        local name = vim.api.nvim_buf_get_name(buf) or ""
        if name == "" then return end
        -- Find a normal window to move the buffer into
        local target = nil
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if w ~= win then
            local b = vim.api.nvim_win_get_buf(w)
            if b and vim.api.nvim_buf_is_valid(b) then
              local bt = vim.bo[b].buftype
              if bt == "" then
                target = w
                break
              end
            end
          end
        end
        if not target then
          -- create a split and use it
          pcall(function()
            vim.api.nvim_set_current_win(win)
            vim.cmd("belowright split")
            target = vim.api.nvim_get_current_win()
          end)
        end
        if not target then return end
        -- move the new file buffer to the target window
        pcall(function() vim.api.nvim_win_set_buf(target, buf) end)
        -- restore the scratch buffer in the lazyagent window
        if scratch_bufnr and vim.api.nvim_buf_is_valid(scratch_bufnr) then
          pcall(function() vim.api.nvim_win_set_buf(win, scratch_bufnr) end)
        else
          -- recreate scratch if missing
          local nb = ensure_scratch_buffer(nil, { filetype = "lazyagent" })
          pcall(function() vim.api.nvim_win_set_buf(win, nb) end)
        end
        -- focus the file in the target window
        pcall(function() vim.api.nvim_set_current_win(target) end)
      end)
    end,
  })
end)

return M
