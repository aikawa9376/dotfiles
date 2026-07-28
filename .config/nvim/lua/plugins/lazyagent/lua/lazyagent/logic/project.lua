local M = {}
local uv = vim.uv or vim.loop

M.directory = ".lazyagent"
M.max_prompt_bytes = 64 * 1024
M.max_instructions_bytes = 128 * 1024

local function normalize_dir(path)
  path = vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p")
  if vim.fn.isdirectory(path) ~= 1 then path = vim.fn.fnamemodify(path, ":h") end
  return path:gsub("/$", "")
end

function M.find(start_path)
  local dir = normalize_dir(start_path)
  while dir ~= "" do
    local candidate = dir .. "/" .. M.directory
    if vim.fn.isdirectory(candidate) == 1 then
      return candidate, dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h"):gsub("/$", "")
    if parent == dir or parent == "" then break end
    dir = parent
  end
  return nil
end

function M.skills_dir(start_path)
  local project_dir = M.find(start_path)
  local path = project_dir and (project_dir .. "/skills") or nil
  return path and vim.fn.isdirectory(path) == 1 and path or nil
end

function M.prompts_dir(start_path)
  local project_dir = M.find(start_path)
  local path = project_dir and (project_dir .. "/prompts") or nil
  return path and vim.fn.isdirectory(path) == 1 and path or nil
end

function M.instructions(start_path)
  local project_dir = M.find(start_path)
  if not project_dir then return nil end
  local path = project_dir .. "/AGENTS.md"
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local size = vim.fn.getfsize(path)
  if size < 0 or size > M.max_instructions_bytes then
    return nil, "project AGENTS.md exceeds 128 KiB"
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil, "failed to read project AGENTS.md: " .. tostring(lines) end
  local content = vim.trim(table.concat(lines, "\n"))
  if content == "" then return nil end
  return {
    content = content,
    path = uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p"),
    hash = vim.fn.sha256(content),
  }
end

local function provider_key(provider_id)
  return tostring(provider_id or ""):lower()
end

function M.uses_native_instructions(provider_id)
  local key = provider_key(provider_id)
  return key == "codex" or key == "copilot" or key == "claude" or key == "gemini"
end

local function append_command_args(command, args)
  if type(command) == "table" then
    local updated = vim.deepcopy(command)
    vim.list_extend(updated, args)
    return updated
  end
  if type(command) == "string" and command ~= "" then
    local updated = { command }
    for _, arg in ipairs(args) do
      updated[#updated + 1] = vim.fn.shellescape(tostring(arg))
    end
    return table.concat(updated, " ")
  end
  return command
end

local function append_unique_csv(value, addition)
  local entries = {}
  local seen = {}
  for entry in tostring(value or ""):gmatch("[^,]+") do
    entry = vim.trim(entry)
    if entry ~= "" and not seen[entry] then
      seen[entry] = true
      entries[#entries + 1] = entry
    end
  end
  if not seen[addition] then entries[#entries + 1] = addition end
  return table.concat(entries, ",")
end

local function combined_instructions(existing, instructions)
  local blocks = {}
  existing = vim.trim(tostring(existing or ""))
  if existing ~= "" then blocks[#blocks + 1] = existing end
  blocks[#blocks + 1] = "# LazyAgent project instructions\n\n"
    .. "Source: " .. instructions.path .. "\n\n"
    .. instructions.content
  return table.concat(blocks, "\n\n")
end

function M.prepare_native(provider_id, start_path, launch)
  launch = launch or {}
  local instructions, err = M.instructions(start_path)
  local result = {
    command = launch.command,
    env = vim.tbl_extend("force", {}, launch.env or {}),
    native = false,
    instructions = instructions,
  }
  if err or not instructions then return result, err end

  local key = provider_key(provider_id)
  if key == "codex" and launch.acp then
    local config = {}
    local encoded = result.env.CODEX_CONFIG
    if encoded and encoded ~= "" then
      local ok, decoded = pcall(vim.json.decode, encoded)
      if not ok or type(decoded) ~= "table" then
        return result, "CODEX_CONFIG is not valid JSON; using prompt fallback"
      end
      config = decoded
    end
    config.developer_instructions = combined_instructions(config.developer_instructions, instructions)
    result.env.CODEX_CONFIG = vim.json.encode(config)
    result.native = true
  elseif key == "codex" then
    result.command = append_command_args(result.command, {
      "-c",
      "developer_instructions=" .. vim.json.encode(combined_instructions(nil, instructions)),
    })
    result.native = true
  elseif key == "copilot" then
    local project_dir = vim.fn.fnamemodify(instructions.path, ":h")
    result.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS =
      append_unique_csv(result.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS, project_dir)
    result.native = true
  elseif key == "claude" then
    result.command = append_command_args(result.command, {
      "--append-system-prompt-file",
      instructions.path,
    })
    result.native = true
  elseif key == "gemini" and result.env.GEMINI_CLI_HOME and result.env.GEMINI_CLI_HOME ~= "" then
    local gemini_dir = result.env.GEMINI_CLI_HOME .. "/.gemini"
    local target = gemini_dir .. "/GEMINI.md"
    vim.fn.mkdir(gemini_dir, "p")
    local user_path = vim.fn.expand("~/.gemini/GEMINI.md")
    local user_content = ""
    if vim.fn.filereadable(user_path) == 1 then
      local ok, lines = pcall(vim.fn.readfile, user_path)
      if ok then user_content = table.concat(lines, "\n") end
    end
    if uv.fs_lstat(target) then vim.fn.delete(target) end
    local ok, write_err = pcall(vim.fn.writefile,
      vim.split(combined_instructions(user_content, instructions), "\n", { plain = true }),
      target)
    if not ok then return result, "failed to prepare Gemini project memory: " .. tostring(write_err) end
    result.native = true
  end
  return result
end

function M.apply_instructions(text, tracker, start_path, session_instructions, opts)
  opts = opts or {}
  text = tostring(text or "")
  local include_project = opts.include_project ~= false
  local project_applied = not include_project
    or (type(tracker) == "table" and tracker.project_instructions_applied == true)
  local session_applied = type(tracker) == "table" and tracker.session_instructions_applied == true
  session_instructions = vim.trim(tostring(session_instructions or ""))
  if project_applied and (session_instructions == "" or session_applied) then
    return text
  end
  local source = type(tracker) == "table" and tracker.project_instructions_root or nil
  local instructions, err
  if not project_applied then instructions, err = M.instructions(source or start_path) end
  if err then return nil, err end
  local include_session = session_instructions ~= "" and not session_applied
  if not instructions and not include_session then return text end
  local lines = {}
  if include_session then
    lines[#lines + 1] = session_instructions
    if type(tracker) == "table" then tracker.session_instructions_applied = true end
  end
  if instructions then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "# LazyAgent project instructions"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "The following instructions come from " .. instructions.path
      .. " and apply to this project session."
    lines[#lines + 1] = ""
    lines[#lines + 1] = instructions.content
  end
  if type(tracker) == "table" then
    if instructions then
      tracker.project_instructions_applied = true
      tracker.project_instructions_path = instructions.path
      tracker.project_instructions_hash = instructions.hash
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "# User request"
  lines[#lines + 1] = ""
  lines[#lines + 1] = text
  return table.concat(lines, "\n")
end

function M.list_prompts(start_path)
  local dir = M.prompts_dir(start_path)
  if not dir then return {} end
  local real_dir = uv.fs_realpath(dir) or dir
  local prompts = {}
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok then return prompts end
  for _, filename in ipairs(entries) do
    local name = filename:match("^([%w][%w_.-]*)%.md$")
    local path = name and (dir .. "/" .. filename) or nil
    local resolved = path and uv.fs_realpath(path) or nil
    if resolved and resolved:sub(1, #real_dir + 1) == real_dir .. "/" and vim.fn.filereadable(resolved) == 1 then
      prompts[#prompts + 1] = { name = name, path = resolved }
    end
  end
  table.sort(prompts, function(left, right) return left.name < right.name end)
  return prompts
end

function M.expand_prompt(text, start_path)
  text = tostring(text or "")
  local name, input = text:match("^/prompt%s+([%w][%w_.-]*)%s*(.*)$")
  if not name then return text, nil, false end
  local selected = nil
  for _, prompt in ipairs(M.list_prompts(start_path)) do
    if prompt.name == name then selected = prompt break end
  end
  if not selected then return nil, "project prompt not found: " .. name, true end
  local size = vim.fn.getfsize(selected.path)
  if size < 0 or size > M.max_prompt_bytes then
    return nil, "project prompt exceeds 64 KiB: " .. name, true
  end
  local ok, lines = pcall(vim.fn.readfile, selected.path)
  if not ok then return nil, "failed to read project prompt: " .. tostring(lines), true end
  local body = table.concat(lines, "\n")
  local replaced = false
  body = body:gsub("{{input}}", function()
    replaced = true
    return input
  end)
  if not replaced and input ~= "" then body = body .. "\n\n# Request\n" .. input end
  return vim.trim(body), nil, true
end

return M
