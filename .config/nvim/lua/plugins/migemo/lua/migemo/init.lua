local M = {}

local cache = {}
local unavailable_commands = {}
local preview = {}
local last_search

function M.command()
  local local_rmigemo = vim.fn.stdpath("config") .. "/bin/rmigemo"
  local uname = vim.uv.os_uname()
  local bundled_supported = uname.sysname == "Linux" and uname.machine == "x86_64"
  if
    bundled_supported
    and not unavailable_commands[local_rmigemo]
    and vim.fn.executable(local_rmigemo) == 1
  then
    return local_rmigemo
  end
  local system_rmigemo = vim.fn.exepath("rmigemo")
  if system_rmigemo ~= "" and not unavailable_commands[system_rmigemo] then
    return system_rmigemo
  end
end

--- Convert romaji input to migemo regex pattern.
--- @param input string
--- @param engine string? "vim" (default) | "egrep" | "grep" | "emacs"
--- @return string|nil pattern, or nil if conversion failed
function M.pattern(input, engine)
  if input == "" or not input:match("[%w_-]") then
    return nil
  end
  engine = engine or "vim"
  local key = input .. "\0" .. engine
  if cache[key] then return cache[key] end

  local cmd = M.command()
  if not cmd then return nil end

  local ok, result = pcall(vim.fn.system, { cmd, "-q", "-w", input, "-e", engine })
  if not ok or vim.v.shell_error ~= 0 then
    unavailable_commands[cmd] = true
    return M.pattern(input, engine)
  end

  local normalized = vim.trim(result)
  if normalized == "" then return nil end

  cache[key] = normalized
  return normalized
end

local function flash_exact(pattern)
  return "\\V" .. pattern:gsub("\\", "\\\\")
end

local function split_search_offset(input, delimiter)
  for index = 1, #input do
    if input:sub(index, index) == delimiter then
      local backslashes = 0
      local before = index - 1
      while before > 0 and input:sub(before, before) == "\\" do
        backslashes = backslashes + 1
        before = before - 1
      end
      if backslashes % 2 == 0 then
        return input:sub(1, index - 1), input:sub(index)
      end
    end
  end
  return input, ""
end

local function clear_preview_match()
  if preview.match and preview.win and vim.api.nvim_win_is_valid(preview.win) then
    pcall(vim.fn.matchdelete, preview.match, preview.win)
  end
  preview.match = nil
end

local function restore_preview_view()
  if preview.win and preview.view and vim.api.nvim_win_is_valid(preview.win) then
    pcall(vim.api.nvim_win_call, preview.win, function()
      vim.fn.winrestview(preview.view)
    end)
  end
end

local function start_cmdline_preview()
  local delimiter = vim.fn.getcmdtype()
  if delimiter ~= "/" and delimiter ~= "?" then return end

  local win = vim.api.nvim_get_current_win()
  preview = {
    delimiter = delimiter,
    incsearch = vim.o.incsearch,
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    win = win,
  }
  vim.o.incsearch = false
end

local function apply_cmdline_preview(pattern, generation)
  if preview.generation ~= generation or not preview.win or not vim.api.nvim_win_is_valid(preview.win) then return end

  local backward = preview.delimiter == "?"
  local flags = (backward and "b" or "") .. "c" .. (vim.o.wrapscan and "w" or "W")

  clear_preview_match()
  restore_preview_view()
  vim.api.nvim_win_call(preview.win, function()
    local ok, match = pcall(vim.fn.matchadd, "Search", pattern, 10, -1, { window = preview.win })
    if ok then preview.match = match end

    -- Match native incsearch semantics: every command-line change searches
    -- the complete buffer before accepting the next input event.
    pcall(vim.fn.searchpos, pattern, flags)
  end)
end

local function generate_preview_pattern(query, key, generation)
  local cmd = M.command()
  if not cmd then
    apply_cmdline_preview(query, generation)
    return
  end

  local ok = pcall(vim.system, { cmd, "-q", "-w", query, "-e", "vim" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        unavailable_commands[cmd] = true
        generate_preview_pattern(query, key, generation)
        return
      end

      local pattern = vim.trim(result.stdout or "")
      if pattern ~= "" then cache[key] = pattern end
      apply_cmdline_preview(pattern ~= "" and pattern or query, generation)
    end)
  end)
  if not ok then
    unavailable_commands[cmd] = true
    generate_preview_pattern(query, key, generation)
  end
end

local function update_cmdline_preview()
  if not preview.win or not vim.api.nvim_win_is_valid(preview.win) then return end

  preview.generation = (preview.generation or 0) + 1
  local generation = preview.generation
  local query = split_search_offset(vim.fn.getcmdline(), preview.delimiter)
  if query == "" then
    clear_preview_match()
    restore_preview_view()
    return
  end

  -- A one-letter Migemo pattern expands to thousands of bytes (for example,
  -- `k` is about 2.8 KiB) and can dominate the cost of every later keypress.
  if #query == 1 or not query:match("[%w_-]") then
    apply_cmdline_preview(query, generation)
    return
  end

  local key = query .. "\0vim"
  if cache[key] then
    apply_cmdline_preview(cache[key], generation)
    return
  end

  -- Do not reset a valid previous-prefix match while an uncached rmigemo
  -- process runs. Only the newest command-line generation may update the view.
  generate_preview_pattern(query, key, generation)
end

local function finish_cmdline_preview()
  clear_preview_match()
  restore_preview_view()
  local incsearch = preview.incsearch
  preview = {}
  return incsearch
end

local function rewrite_noice_content(content)
  if not last_search then return content end

  local search_register = vim.fn.getreg("/")
  if search_register ~= last_search.pattern and search_register ~= last_search.executed_pattern then
    return content
  end

  local display = last_search.delimiter .. last_search.input
  local parts = {}
  for _, chunk in ipairs(content) do
    if type(chunk) == "table" and type(chunk[2]) == "string" then
      table.insert(parts, chunk[2])
    end
  end
  local current, total = table.concat(parts):match("%[(>?%d+)/(>?%d+)%]%s*$")
  if current and total then
    return { { 0, ("%s [%s/%s]"):format(display, current, total) } }
  end

  local buf = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(buf)
  local ok_size, byte_count = pcall(vim.api.nvim_buf_get_offset, buf, line_count)
  if line_count > 20000 or not ok_size or byte_count > 1024 * 1024 then
    return { { 0, display } }
  end

  local ok, count = pcall(vim.fn.searchcount, {
    maxcount = 10000,
    recompute = true,
    timeout = 20,
  })
  if not ok or vim.tbl_isempty(count) or count.incomplete == 1 then
    return { { 0, display } }
  end

  current = count.current > count.maxcount and ">" .. count.maxcount or tostring(count.current)
  total = (count.incomplete == 2 or count.total > count.maxcount)
      and ">" .. count.maxcount
    or tostring(count.total)
  return { { 0, ("%s [%s/%s]"):format(display, current, total) } }
end

local function setup_noice_search_count()
  local ok, Msg = pcall(require, "noice.ui.msg")
  if not ok or Msg._migemo_search_count then return end

  Msg._migemo_search_count = true
  local on_show = Msg.on_show
  Msg.on_show = function(event, kind, content, ...)
    if kind == Msg.kinds.search_count then
      content = rewrite_noice_content(content)
    end
    return on_show(event, kind, content, ...)
  end
end

--- Replace the executed search with Migemo while retaining the typed history.
local function convert_cmdline_search()
  if vim.v.event.abort then return end

  local delimiter = vim.fn.getcmdtype()
  if delimiter ~= "/" and delimiter ~= "?" then return end

  local input = vim.fn.getcmdline()
  if input == "" or input:sub(1, 1) == delimiter then return end

  local query, offset = split_search_offset(input, delimiter)
  local pattern = M.pattern(query, "vim")
  if not pattern then
    last_search = nil
    return
  end

  -- An unescaped delimiter would terminate the search pattern.
  local executed_pattern = pattern:gsub(vim.pesc(delimiter), "\\" .. delimiter)
  local executed = executed_pattern .. offset
  last_search = {
    delimiter = delimiter,
    executed_pattern = executed_pattern,
    input = input,
    pattern = pattern,
  }
  vim.fn.setcmdline(executed)

  vim.schedule(function()
    -- Neovim records the executed regex. Replace only that newest entry so
    -- another history mutation from an autocmd is not accidentally deleted.
    if vim.fn.histget("search", -1) == executed then
      vim.fn.histdel("search", -1)
    end
    vim.fn.histadd("search", input)
  end)
end

--- Match only inside the range Flash is going to label.
---
--- Flash's default matcher is given a visible range, but `searchpos()` can
--- still scan to the end of the buffer before deciding there is no match in
--- that range. Stop at the range's last line to keep the cost bounded.
local function flash_visible_matcher(win, state, opts)
  local matches = {}
  local matcher = require("flash.search").new(win, state)
  local Pos = require("flash.search.pos")
  local Hacks = require("flash.hacks")
  local stopline = opts.to and opts.to[1] or vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))

  matcher:_call(opts.from or { 1, 0 }, function()
    local flags = "cW"
    while true do
      local ok, result = pcall(vim.fn.searchpos, state.pattern.search, flags, stopline)
      if not ok or result[1] == 0 then break end

      local pos = Pos({ result[1], result[2] - 1 })
      if opts.to and pos > opts.to then break end
      table.insert(matches, { win = win, pos = pos, end_pos = Hacks.get_end_pos(pos) })
      flags = "W"
    end
  end)

  return matches
end

--- Setup flash.nvim integration and keymaps.
function M.setup()
  local config = require("flash.config")
  config.modes.migemo = {
    matcher = flash_visible_matcher,
    search = {
      mode = function(pattern)
        return M.pattern(pattern, "vim") or flash_exact(pattern)
      end,
    },
  }

  local group = vim.api.nvim_create_augroup("migemo_search", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    pattern = { "/", "?" },
    callback = start_cmdline_preview,
  })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    pattern = { "/", "?" },
    callback = update_cmdline_preview,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    pattern = { "/", "?" },
    callback = function()
      local incsearch = finish_cmdline_preview()
      convert_cmdline_search()
      if incsearch ~= nil then vim.o.incsearch = incsearch end
    end,
  })
  setup_noice_search_count()
end

--- Convert current / or ? command-line input to a Migemo search and skip history.
function M.search_no_history()
  local cmd_type = vim.fn.getcmdtype()
  if cmd_type ~= "/" and cmd_type ~= "?" then return end
  local input = vim.fn.getcmdline()
  if input == "" then return end
  local result = M.pattern(input, "vim")
  if not result then return end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
  vim.schedule(function()
    vim.cmd((cmd_type == "/" and "/" or "?") .. result)
    vim.fn.histdel("search", -1)
  end)
end

return M
