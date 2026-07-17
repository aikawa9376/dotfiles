local M = {}
local TextRef = require("lazyagent.acp.text_ref")
local uv = vim.uv or vim.loop

local function read_ref(ref)
  if type(ref) ~= "table" or not ref.path or vim.fn.filereadable(ref.path) ~= 1 then return "" end
  local ok, lines
  if ref.end_line then
    ok, lines = pcall(vim.fn.readfile, ref.path, "", tonumber(ref.end_line))
  else
    ok, lines = pcall(vim.fn.readfile, ref.path)
  end
  if not ok then return "" end
  if ref.start_line then
    local sliced = {}
    for index = math.max(1, tonumber(ref.start_line) or 1), #lines do sliced[#sliced + 1] = lines[index] end
    lines = sliced
  end
  return table.concat(lines, "\n")
end

local function expanded_text(value, chunks, ref, load_ref)
  if type(value) == "string" and value ~= "" then return value end
  if type(chunks) == "table" and #chunks > 0 then return table.concat(chunks, "") end
  return load_ref(ref)
end

local function append_indented(lines, heading, text)
  if not text or text == "" then return end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "### " .. heading
  lines[#lines + 1] = ""
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = "    " .. line
  end
end

function M.render(opts)
  opts = opts or {}
  local load_ref = opts.read_ref or read_ref
  local lines = { "# " .. tostring(opts.title or "LazyAgent ACP thread") }
  if opts.provider_id or opts.cwd or opts.thread_id then
    lines[#lines + 1] = ""
    if opts.provider_id then lines[#lines + 1] = "- Provider: `" .. tostring(opts.provider_id) .. "`" end
    if opts.cwd then lines[#lines + 1] = "- Workspace: `" .. tostring(opts.cwd) .. "`" end
    if opts.thread_id then lines[#lines + 1] = "- Thread: `" .. tostring(opts.thread_id) .. "`" end
  end

  local tools = {}
  for _, entry in ipairs(opts.tools or {}) do tools[entry.toolCallId] = entry end
  for _, item in ipairs(opts.conversation or {}) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. tostring(item.heading or item.title or item.kind or "Message")
    lines[#lines + 1] = ""
    local body = expanded_text(item.body, item.body_chunks, item.body_ref, load_ref)
    lines[#lines + 1] = body ~= "" and body or "_No retained content._"
    local tool = item.toolCallId and tools[item.toolCallId] or nil
    if tool then
      append_indented(lines, "Expanded tool content", expanded_text(
        tool.rendered_content,
        nil,
        tool.rendered_content_ref,
        load_ref
      ))
      append_indented(lines, "Raw tool output", expanded_text(
        tool.rendered_raw_output,
        nil,
        tool.rendered_raw_output_ref,
        load_ref
      ))
    end
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function write_all(fd, data)
  local offset = 0
  while offset < #data do
    local written, err = uv.fs_write(fd, data:sub(offset + 1), -1)
    if not written or written <= 0 then
      return nil, err or "short thread export write"
    end
    offset = offset + written
  end
  return true
end

function M.write(opts, path)
  opts = opts or {}
  local fd, open_err = uv.fs_open(path, "w", 420)
  if not fd then
    return nil, open_err
  end
  local failed = nil
  local function emit(text)
    if failed or text == nil or text == "" then return failed == nil end
    local ok, err = write_all(fd, tostring(text))
    if not ok then failed = err end
    return ok
  end
  local function emit_ref(ref, indent)
    if type(ref) ~= "table" then return true end
    local at_line_start = indent == true
    local ok, err = TextRef.each_chunk(ref, function(chunk)
      if indent then
        if at_line_start then chunk = "    " .. chunk end
        chunk = chunk:gsub("\n", "\n    ")
        if chunk:sub(-4) == "    " and chunk:sub(-5, -5) == "\n" then
          chunk = chunk:sub(1, -5)
          at_line_start = true
        else
          at_line_start = false
        end
      end
      return emit(chunk)
    end)
    if not ok then failed = err end
    return ok
  end
  local function emit_expanded(value, chunks, ref, indent)
    local text = type(value) == "string" and value ~= "" and value or nil
    if not text and type(chunks) == "table" and #chunks > 0 then
      text = table.concat(chunks, "")
    end
    if text then
      if indent then
        text = "    " .. text:gsub("\n", "\n    ")
      end
      return emit(text)
    end
    return emit_ref(ref, indent)
  end

  emit("# " .. tostring(opts.title or "LazyAgent ACP thread"))
  if opts.provider_id or opts.cwd or opts.thread_id then
    emit("\n")
    if opts.provider_id then emit("\n- Provider: `" .. tostring(opts.provider_id) .. "`") end
    if opts.cwd then emit("\n- Workspace: `" .. tostring(opts.cwd) .. "`") end
    if opts.thread_id then emit("\n- Thread: `" .. tostring(opts.thread_id) .. "`") end
  end

  local tools = {}
  for _, entry in ipairs(opts.tools or {}) do tools[entry.toolCallId] = entry end
  for _, item in ipairs(opts.conversation or {}) do
    emit("\n\n## " .. tostring(item.heading or item.title or item.kind or "Message") .. "\n\n")
    local has_body = (type(item.body) == "string" and item.body ~= "")
      or (type(item.body_chunks) == "table" and #item.body_chunks > 0)
      or type(item.body_ref) == "table"
    if has_body then
      emit_expanded(item.body, item.body_chunks, item.body_ref, false)
    else
      emit("_No retained content._")
    end
    local tool = item.toolCallId and tools[item.toolCallId] or nil
    if tool then
      local sections = {
        { "Expanded tool content", tool.rendered_content, tool.rendered_content_ref },
        { "Raw tool output", tool.rendered_raw_output, tool.rendered_raw_output_ref },
      }
      for _, section in ipairs(sections) do
        if (type(section[2]) == "string" and section[2] ~= "") or type(section[3]) == "table" then
          emit("\n\n### " .. section[1] .. "\n\n")
          emit_expanded(section[2], nil, section[3], true)
        end
      end
    end
  end
  emit("\n")
  uv.fs_close(fd)
  if failed then return nil, failed end
  return path
end

return M
