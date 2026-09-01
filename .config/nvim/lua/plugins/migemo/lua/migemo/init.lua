local M = {}

local cache = {}
local persistent_unavailable = {}
local unavailable_commands = {}
local workers = {}
local preview = {}
local last_search

local function vim_case_prefix(input)
  local smartcase_match = vim.o.smartcase and input:find("%u") ~= nil
  return vim.o.ignorecase and not smartcase_match and "\\c" or "\\C"
end

local function pattern_key(input, engine)
  local case = engine == "vim" and vim_case_prefix(input) or ""
  return input .. "\0" .. engine .. "\0" .. case
end

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

local function worker_key(cmd, engine) return cmd .. "\0" .. engine end

local function fail_requests(worker)
  local pending = worker.pending
  worker.pending = {}
  for _, request in ipairs(pending) do
    request.done = true
    if request.callback then
      local callback = request.callback
      vim.schedule(function() callback(nil) end)
    end
  end
end

local function stop_worker(key, failed)
  local worker = workers[key]
  workers[key] = nil
  if not worker then return end

  worker.stopping = true
  if failed then fail_requests(worker) end
  if worker.job and worker.job > 0 then pcall(vim.fn.jobstop, worker.job) end
end

local function start_worker(cmd, engine)
  local key = worker_key(cmd, engine)
  local worker = {
    exited = false,
    pending = {},
    partial = "",
  }

  local job = vim.fn.jobstart({ cmd, "-q", "--stdio", "-e", engine }, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for index, chunk in ipairs(data) do
        if index == 1 then
          worker.partial = worker.partial .. chunk
        else
          local request = table.remove(worker.pending, 1)
          if request then
            request.done = true
            request.result = worker.partial
            if request.callback then request.callback(worker.partial) end
          end
          worker.partial = chunk
        end
      end
    end,
    on_exit = function(_, code)
      worker.exited = true
      worker.exit_code = code
      if not worker.stopping then
        persistent_unavailable[cmd] = true
        fail_requests(worker)
      end
    end,
  })
  if job <= 0 then return nil end

  worker.job = job
  workers[key] = worker
  return worker
end

local function send_request(worker, input, callback)
  local request = { callback = callback, done = false }
  table.insert(worker.pending, request)
  local ok, sent = pcall(vim.fn.chansend, worker.job, input .. "\n")
  if ok and sent ~= 0 then return request end

  if worker.pending[#worker.pending] == request then table.remove(worker.pending) end
  request.done = true
end

local function persistent_pattern(cmd, input, engine)
  if persistent_unavailable[cmd] then return nil end

  local key = worker_key(cmd, engine)
  local worker = workers[key]
  if not worker or worker.exited then
    stop_worker(key)
    worker = start_worker(cmd, engine)
  end
  if not worker then
    persistent_unavailable[cmd] = true
    return nil
  end

  local request = send_request(worker, input)
  if not request then
    stop_worker(key, true)
    return nil
  end

  local ready = vim.wait(1000, function() return request.done or worker.exited end, 1)
  if ready and request.result ~= nil then return request.result end

  stop_worker(key, true)
  persistent_unavailable[cmd] = true
  return nil
end

local function persistent_pattern_async(cmd, input, engine, callback)
  if persistent_unavailable[cmd] then return false end

  local key = worker_key(cmd, engine)
  local worker = workers[key]
  if not worker or worker.exited then
    stop_worker(key)
    worker = start_worker(cmd, engine)
  end
  if not worker then
    persistent_unavailable[cmd] = true
    return false
  end

  if send_request(worker, input, callback) then return true end

  stop_worker(key, true)
  return false
end

local function one_shot_pattern(cmd, input, engine)
  local ok, result = pcall(vim.fn.system, { cmd, "-q", "-w", input, "-e", engine })
  if ok and vim.v.shell_error == 0 then return result end

  unavailable_commands[cmd] = true
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
  local key = pattern_key(input, engine)
  if cache[key] then return cache[key] end

  local cmd = M.command()
  if not cmd then return nil end

  local result = persistent_pattern(cmd, input, engine) or one_shot_pattern(cmd, input, engine)
  if not result then return M.pattern(input, engine) end

  local normalized = vim.trim(result)
  if normalized == "" then return nil end
  if engine == "vim" then normalized = vim_case_prefix(input) .. normalized end

  cache[key] = normalized
  return normalized
end

--- Convert romaji input without blocking Neovim.
--- @param input string
--- @param engine string? "vim" (default) | "egrep" | "grep" | "emacs"
--- @param callback fun(pattern: string|nil)
function M.pattern_async(input, engine, callback)
  engine = engine or "vim"
  if input == "" or not input:match("[%w_-]") then
    vim.schedule(function() callback(nil) end)
    return
  end

  local key = pattern_key(input, engine)
  if cache[key] then
    local pattern = cache[key]
    vim.schedule(function() callback(pattern) end)
    return
  end

  local cmd = M.command()
  if not cmd then
    vim.schedule(function() callback(nil) end)
    return
  end

  local function apply_result(result)
    local normalized = vim.trim(result or "")
    if normalized ~= "" and engine == "vim" then
      normalized = vim_case_prefix(input) .. normalized
    end
    if normalized ~= "" then cache[key] = normalized end
    callback(normalized ~= "" and normalized or nil)
  end

  local function fallback()
    local ok = pcall(vim.system, { cmd, "-q", "-w", input, "-e", engine }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          unavailable_commands[cmd] = true
          M.pattern_async(input, engine, callback)
        else
          apply_result(result.stdout)
        end
      end)
    end)
    if not ok then
      unavailable_commands[cmd] = true
      M.pattern_async(input, engine, callback)
    end
  end

  local queued = persistent_pattern_async(cmd, input, engine, function(result)
    vim.schedule(function()
      if result == nil then
        fallback()
      else
        apply_result(result)
      end
    end)
  end)
  if not queued then fallback() end
end

function M.stop()
  local keys = vim.tbl_keys(workers)
  for _, key in ipairs(keys) do
    stop_worker(key)
  end
end

local function flash_exact(pattern)
  return vim_case_prefix(pattern) .. "\\V" .. pattern:gsub("\\", "\\\\")
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

local function generate_preview_pattern(query, generation)
  M.pattern_async(query, "vim", function(pattern)
    apply_cmdline_preview(pattern or query, generation)
  end)
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

  local key = pattern_key(query, "vim")
  if cache[key] then
    apply_cmdline_preview(cache[key], generation)
    return
  end

  -- Do not reset a valid previous-prefix match while an uncached rmigemo
  -- request runs. Only the newest command-line generation may update the view.
  generate_preview_pattern(query, generation)
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

--- Match only the lines Flash is going to label.
local function flash_visible_matcher(win, state, opts)
  local matches = {}
  if state.pattern.search == "" then return matches end
  local Pos = require("flash.search.pos")
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local from = opts.from and Pos(opts.from) or Pos({ 1, 0 })
  local to = opts.to and Pos(opts.to) or Pos({ line_count + 1, 0 })
  local first_line = math.max(from[1], 1)
  local last_line = math.min(to[1], line_count)
  if last_line < first_line then return matches end

  local ok, regex = pcall(vim.regex, state.pattern.search)
  if not ok then return matches end
  local lines = vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false)

  for index, line in ipairs(lines) do
    local line_number = first_line + index - 1
    local offset = line_number == from[1] and from[2] or 0
    while true do
      local start_offset, end_offset = regex:match_line(buf, line_number - 1, offset)
      if start_offset == nil then break end

      local start_col = offset + start_offset
      local end_exclusive = offset + end_offset
      local pos = Pos({ line_number, start_col })
      if pos > to then break end

      local end_col = start_col
      if end_exclusive > start_col then
        end_col = vim.fn.byteidx(line, vim.fn.charidx(line, end_exclusive - 1))
      end
      table.insert(matches, {
        win = win,
        pos = pos,
        end_pos = Pos({ line_number, math.max(end_col, start_col) }),
      })

      offset = end_exclusive > offset and end_exclusive or offset + 1
    end
  end

  return matches
end

--- Skip labels that would be ambiguous with the character following a
--- visible match, without searching the complete buffer again.
local function flash_visible_labeler(_, state)
  if not state._migemo_labeler then
    local labeler = require("flash.labeler").new(state)
    labeler.skip = function(_, win, labels)
      local available = {}
      for _, label in ipairs(labels) do
        available[vim.o.ignorecase and label:lower() or label] = true
      end

      local skipped = {}
      local lines = {}
      for _, match in ipairs(state.results) do
        if match.win == win then
          local buf = vim.api.nvim_win_get_buf(win)
          local row = match.end_pos[1]
          local line_key = buf .. ":" .. row
          local line = lines[line_key]
          if not line then
            line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            lines[line_key] = line
          end

          local last = vim.fn.strpart(line, match.end_pos[2], 1, true)
          local following = vim.fn.strpart(line, match.end_pos[2] + #last, 1, true)
          local key = vim.o.ignorecase and following:lower() or following
          if available[key] then skipped[key] = true end
        end
      end

      return vim.tbl_filter(function(label)
        local key = vim.o.ignorecase and label:lower() or label
        return not skipped[key]
      end, labels)
    end
    state._migemo_labeler = labeler
  end
  state._migemo_labeler:update()
end

--- Setup flash.nvim integration and keymaps.
function M.setup()
  local config = require("flash.config")
  config.modes.migemo = {
    labeler = flash_visible_labeler,
    matcher = flash_visible_matcher,
    search = {
      mode = function(pattern)
        if vim.fn.strchars(pattern) == 1 then return flash_exact(pattern) end
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
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = M.stop,
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
