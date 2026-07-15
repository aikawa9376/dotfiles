local M = {}

local uv = vim.uv or vim.loop
local ContentBlocks = require("lazyagent.acp.content_blocks")

local function preview(text, limit)
  text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  limit = math.max(16, tonumber(limit) or 240)
  if #text <= limit then
    return text
  end
  return text:sub(1, limit - 3) .. "..."
end

local function file_version(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return nil
  end
  local modified = stat.mtime
  return {
    size = tonumber(stat.size) or 0,
    mtime_sec = type(modified) == "table" and tonumber(modified.sec) or tonumber(modified),
    mtime_nsec = type(modified) == "table" and tonumber(modified.nsec) or 0,
  }
end

local function enrich(item, opts)
  opts = opts or {}
  local content = item.content
  if content ~= nil then
    item.size = #content
    item.token_estimate = math.ceil(item.size / 4)
    item.content_hash = vim.fn.sha256(content)
    item.preview = preview(content, opts.preview_limit)
  else
    local version = file_version(item.path)
    item.size = version and version.size or nil
    item.token_estimate = item.size and math.ceil(item.size / 4) or nil
    item.preview = item.display
  end
  item.source_version = opts.source_version or file_version(item.path)
  return item
end

local function file_uri(path)
  local normalized = vim.fn.fnamemodify(path, ":p")
  local ok, uri = pcall(vim.uri_from_fname, normalized)
  return ok and uri or ("file://" .. normalized)
end

local function range_note(display, range)
  if not range then
    return nil
  end
  if range.start_line == range.end_line and range.column then
    return string.format("Context from %s at line %d, column %d:", display, range.start_line, range.column)
  end
  if range.start_line == range.end_line then
    return string.format("Context from %s line %d:", display, range.start_line)
  end
  return string.format("Context from %s lines %d-%d:", display, range.start_line, range.end_line)
end

local function slice(lines, range)
  if not range then
    return vim.deepcopy(lines or {})
  end
  local result = {}
  for index = math.max(1, range.start_line), math.min(#lines, range.end_line) do
    result[#result + 1] = lines[index]
  end
  return result
end

function M.file(opts)
  opts = opts or {}
  local start_line = tonumber(opts.start_line)
  local end_line = tonumber(opts.end_line or start_line)
  if start_line and end_line and end_line < start_line then
    start_line, end_line = end_line, start_line
  end
  local range = start_line and {
    start_line = math.max(1, start_line),
    end_line = math.max(1, end_line),
    column = tonumber(opts.column),
  } or nil
  local path = vim.fn.fnamemodify(opts.path, ":p")
  local display = opts.display or path
  return enrich({
    kind = range and "range" or "file",
    source = opts.source or "reference",
    path = path,
    uri = file_uri(path),
    display = display,
    filetype = opts.filetype,
    range = range,
    content = table.concat(slice(opts.lines or {}, range), "\n"),
    note = range_note(display, range),
  }, opts)
end

function M.directory(opts)
  opts = opts or {}
  local path = vim.fn.fnamemodify(opts.path, ":p"):gsub("/$", "")
  return enrich({
    kind = "directory",
    source = opts.source or "reference",
    path = path,
    uri = file_uri(path),
    display = opts.display or path,
  }, opts)
end

function M.media(opts)
  opts = opts or {}
  local path = vim.fn.fnamemodify(opts.path, ":p")
  local kind = ContentBlocks.media_kind(path)
  if not kind then
    return nil, "unsupported media type"
  end
  return enrich({
    kind = kind,
    source = opts.source or "reference",
    path = path,
    uri = file_uri(path),
    display = opts.display or path,
  }, opts)
end

function M.selection(bufnr, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid selection buffer"
  end
  local start_line = tonumber(opts.start_line)
  local end_line = tonumber(opts.end_line)
  local start_column = tonumber(opts.start_column)
  local end_column = tonumber(opts.end_column)
  if not start_line or not end_line then
    local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
    local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
    start_line, end_line = start_mark[1], end_mark[1]
    start_column, end_column = start_mark[2], end_mark[2]
  end
  if not start_line or not end_line or start_line <= 0 or end_line <= 0 then
    return nil, "selection is unavailable"
  end
  if end_line < start_line then
    start_line, end_line = end_line, start_line
    start_column, end_column = end_column, start_column
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if start_column and end_column and #lines == 1 then
    lines[1] = lines[1]:sub(start_column + 1, end_column + 1)
  elseif start_column and end_column and #lines > 1 then
    lines[1] = lines[1]:sub(start_column + 1)
    lines[#lines] = lines[#lines]:sub(1, end_column + 1)
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local item = M.file({
    path = path ~= "" and path or ("selection-" .. tostring(bufnr)),
    display = path ~= "" and path or "selection",
    lines = lines,
    source = "selection",
    filetype = vim.bo[bufnr].filetype,
  })
  item.kind = "selection"
  item.range = { start_line = start_line, end_line = end_line }
  item.content = table.concat(lines, "\n")
  item.note = range_note(item.display, item.range)
  return enrich(item, {
    preview_limit = opts.preview_limit,
    source_version = { bufnr = bufnr, changedtick = vim.api.nvim_buf_get_changedtick(bufnr) },
  })
end

function M.diagnostics(bufnr, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid diagnostics buffer"
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local display = path ~= "" and vim.fn.fnamemodify(path, ":.") or ("buffer " .. tostring(bufnr))
  local severity_names = {
    [vim.diagnostic.severity.ERROR] = "ERROR",
    [vim.diagnostic.severity.WARN] = "WARN",
    [vim.diagnostic.severity.INFO] = "INFO",
    [vim.diagnostic.severity.HINT] = "HINT",
  }
  local lines = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, opts.diagnostic_opts or {})) do
    lines[#lines + 1] = string.format(
      "%s:%d:%d: %s: %s",
      display,
      (tonumber(diagnostic.lnum) or 0) + 1,
      (tonumber(diagnostic.col) or 0) + 1,
      severity_names[diagnostic.severity] or "DIAGNOSTIC",
      tostring(diagnostic.message or ""):gsub("%s+", " ")
    )
  end
  if #lines == 0 then
    lines[1] = "No diagnostics for " .. display .. "."
  end
  local item = enrich({
    kind = "diagnostics",
    source = "diagnostics",
    inline = true,
    path = path ~= "" and path or ("diagnostics-" .. tostring(bufnr)),
    uri = path ~= "" and file_uri(path) or ("lazyagent://buffer/" .. tostring(bufnr) .. "/diagnostics"),
    display = "diagnostics: " .. display,
    content = table.concat(lines, "\n"),
  }, {
    preview_limit = opts.preview_limit,
    source_version = { bufnr = bufnr, changedtick = vim.api.nvim_buf_get_changedtick(bufnr) },
  })
  return item
end

local function default_git_runner(root, args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local ok, result = pcall(function()
    return vim.system(command, { text = true }):wait(3000)
  end)
  if not ok then
    return nil, tostring(result)
  end
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or "")
    return nil, message ~= "" and message or "git command failed"
  end
  return result.stdout or ""
end

function M.branch_diff(root, opts)
  opts = opts or {}
  root = vim.fn.fnamemodify(root or vim.fn.getcwd(), ":p"):gsub("/$", "")
  local run = opts.run or default_git_runner
  local content, diff_err = run(root, { "diff", "--no-ext-diff", "HEAD", "--" })
  if content == nil then
    local staged = run(root, { "diff", "--no-ext-diff", "--cached", "--" })
    local unstaged = run(root, { "diff", "--no-ext-diff", "--" })
    if staged == nil and unstaged == nil then
      return nil, diff_err or "git diff failed"
    end
    content = tostring(staged or "") .. tostring(unstaged or "")
  end
  if content == "" then
    content = "No tracked branch changes in " .. root .. "."
  end
  local max_bytes = tonumber(opts.max_bytes) or (512 * 1024)
  if #content > max_bytes then
    content = content:sub(1, max_bytes) .. string.format("\n\n[branch diff truncated at %d bytes]", max_bytes)
  end
  return enrich({
    kind = "branch_diff",
    source = "git",
    inline = true,
    path = root,
    uri = "lazyagent://git/branch-diff?root=" .. vim.uri_encode(root),
    display = "branch diff: " .. root,
    filetype = "diff",
    content = content,
  }, {
    preview_limit = opts.preview_limit,
    source_version = { root = root, content_hash = vim.fn.sha256(content) },
  })
end

local SYMBOL_NODE_TYPES = {
  function_declaration = true,
  function_definition = true,
  method_definition = true,
  method_declaration = true,
  class_declaration = true,
  class_definition = true,
  arrow_function = true,
  function_expression = true,
  local_function = true,
  decorated_definition = true,
  impl_item = true,
  function_item = true,
}

function M.symbol(bufnr, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid symbol buffer"
  end
  local start_line = tonumber(opts.start_line)
  local end_line = tonumber(opts.end_line)
  if not start_line or not end_line then
    local cursor = opts.cursor
    if type(cursor) ~= "table" then
      local winid = vim.fn.bufwinid(bufnr)
      cursor = winid ~= -1 and vim.api.nvim_win_get_cursor(winid) or vim.api.nvim_buf_get_mark(bufnr, '"')
    end
    if not cursor or tonumber(cursor[1]) == nil or tonumber(cursor[1]) <= 0 then
      return nil, "source cursor is unavailable"
    end
    local ok, range_or_err = pcall(function()
      local node = vim.treesitter.get_node({
        bufnr = bufnr,
        pos = { tonumber(cursor[1]) - 1, tonumber(cursor[2]) or 0 },
      })
      while node and not SYMBOL_NODE_TYPES[node:type()] do
        node = node:parent()
      end
      if not node then
        return nil
      end
      local start_row, _, end_row = node:range()
      return { start_row + 1, end_row + 1 }
    end)
    if not ok then
      return nil, tostring(range_or_err)
    end
    if not range_or_err then
      return nil, "no enclosing function or class symbol at source cursor"
    end
    start_line, end_line = range_or_err[1], range_or_err[2]
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local item = M.file({
    path = path ~= "" and path or ("symbol-" .. tostring(bufnr)),
    display = path ~= "" and vim.fn.fnamemodify(path, ":.") or ("buffer " .. tostring(bufnr)),
    lines = lines,
    start_line = start_line,
    end_line = end_line,
    source = "symbol",
    filetype = vim.bo[bufnr].filetype,
    source_version = { bufnr = bufnr, changedtick = vim.api.nvim_buf_get_changedtick(bufnr) },
  })
  item.kind = "symbol"
  item.inline = true
  item.note = string.format("Context from enclosing symbol in %s lines %d-%d:", item.display, start_line, end_line)
  return item
end

function M.lower(item, capabilities)
  capabilities = capabilities or {}
  if item.kind == "image" or item.kind == "audio" then
    return ContentBlocks.from_file(item.path, {
      image = capabilities.image == true,
      audio = capabilities.audio == true,
    })
  end
  if item.kind == "directory" then
    return {
      type = "resource_link",
      uri = item.uri,
      name = vim.fn.fnamemodify(item.path, ":t"),
      title = item.display,
    }
  end
  if (item.kind == "selection" or item.inline == true) and capabilities.embedded_context ~= true then
    return { type = "text", text = item.content or "" }
  end
  if capabilities.embedded_context == true then
    return {
      type = "resource",
      resource = { uri = item.uri, mimeType = "text/plain", text = item.content or "" },
    }
  end
  return {
    type = "resource_link",
    uri = item.uri,
    name = vim.fn.fnamemodify(item.path, ":t"),
    title = item.display,
    mimeType = "text/plain",
  }
end

function M.to_markdown(item)
  return string.format("```%s\n%s\n```", tostring(item and item.filetype or ""), tostring(item and item.content or ""))
end

return M
