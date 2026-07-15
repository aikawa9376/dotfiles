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
  if item.kind == "selection" and capabilities.embedded_context ~= true then
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
