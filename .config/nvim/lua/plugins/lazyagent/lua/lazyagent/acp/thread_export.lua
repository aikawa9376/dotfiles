local M = {}

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

return M
