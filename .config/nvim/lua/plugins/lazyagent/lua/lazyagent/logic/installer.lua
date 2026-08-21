local M = {}
local uv = vim.uv or vim.loop

local project = require("lazyagent.logic.project")
local util = require("lazyagent.util")

local function module_root()
  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  return source:match("(.*/lazyagent/)lua/lazyagent/logic/installer%.lua$") or ""
end

local function resolve_project_root(opts)
  local explicit = opts and opts.root_dir
  if explicit and explicit ~= "" then return vim.fn.fnamemodify(explicit, ":p"):gsub("/$", "") end
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  return util.git_root_for_path(path) or vim.fn.getcwd()
end

function M.target_dir(scope, opts)
  if scope == "global" then
    return (opts and opts.global_dir) or project.global_dir()
  end
  return resolve_project_root(opts) .. "/.lazyagent"
end

local function copy_missing(source, target, result)
  local stat = uv.fs_stat(source)
  if not stat then return nil, "missing bundled skill source: " .. source end
  if stat.type == "directory" then
    vim.fn.mkdir(target, "p")
    local scan = uv.fs_scandir(source)
    if not scan then return nil, "failed to scan bundled skills: " .. source end
    while true do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      local ok, err = copy_missing(source .. "/" .. name, target .. "/" .. name, result)
      if not ok then return nil, err end
    end
    return true
  end
  if uv.fs_lstat(target) then
    result.skipped[#result.skipped + 1] = target
    return true
  end
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
  local ok, err = uv.fs_copyfile(source, target)
  if not ok then return nil, "failed to install " .. target .. ": " .. tostring(err) end
  result.created[#result.created + 1] = target
  return true
end

local function install_instructions(target_dir, result)
  local target = target_dir .. "/AGENTS.md"
  if uv.fs_lstat(target) then
    result.skipped[#result.skipped + 1] = target
    return true
  end
  vim.fn.mkdir(target_dir, "p")
  local ok, err = pcall(vim.fn.writefile, {
    "# LazyAgent instructions",
    "",
    "<!-- Add durable instructions for agents working in this scope. -->",
  }, target)
  if not ok then return nil, "failed to install " .. target .. ": " .. tostring(err) end
  result.created[#result.created + 1] = target
  return true
end

local instruction_profiles = {
  obsidian = {
    heading = "Obsidian",
    source = "skills/obsidian-memory/assets/global-instructions.md",
  },
}

local function profile_lines(name)
  local profile = instruction_profiles[name]
  if not profile then return nil, "unknown instructions profile: " .. tostring(name) end
  local path = module_root() .. profile.source
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil, "failed to read instructions profile " .. path .. ": " .. tostring(lines) end
  return lines, profile
end

local function marker_range(lines, name)
  local first, last
  local start_marker = "<!-- lazyagent:instructions:" .. name .. ":start -->"
  local end_marker = "<!-- lazyagent:instructions:" .. name .. ":end -->"
  for index, line in ipairs(lines) do
    if line == start_marker then first = index end
    if first and line == end_marker then last = index; break end
  end
  if not first or not last then return nil, nil end
  return first, last
end

local function heading_range(lines, heading)
  local first, last
  for index, line in ipairs(lines) do
    if line:match("^##%s+") then
      if first then
        last = index - 1
        break
      end
      if vim.trim(line:sub(3)) == heading then first = index end
    end
  end
  return first, last or (first and #lines or nil)
end

local function merge_profile(lines, name, profile, replacement)
  local first, last = marker_range(lines, name)
  if not first then first, last = heading_range(lines, profile.heading) end

  local merged = {}
  if first then
    vim.list_extend(merged, vim.list_slice(lines, 1, first - 1))
    vim.list_extend(merged, replacement)
    vim.list_extend(merged, vim.list_slice(lines, last + 1))
  else
    vim.list_extend(merged, lines)
    if #merged > 0 and merged[#merged] ~= "" then merged[#merged + 1] = "" end
    vim.list_extend(merged, replacement)
  end
  return merged
end

local function install_instruction_profile(target_dir, name, result)
  local replacement, profile = profile_lines(name)
  if not replacement then return nil, profile end

  local target = target_dir .. "/AGENTS.md"
  local lines = { "# LazyAgent instructions", "" }
  if uv.fs_lstat(target) then
    local ok, current = pcall(vim.fn.readfile, target)
    if not ok then return nil, "failed to read " .. target .. ": " .. tostring(current) end
    lines = current
  end
  local merged = merge_profile(lines, name, profile, replacement)
  if vim.deep_equal(lines, merged) then
    result.skipped[#result.skipped + 1] = target
    return true
  end

  vim.fn.mkdir(target_dir, "p")
  local existed = uv.fs_lstat(target) ~= nil
  local ok, err = pcall(vim.fn.writefile, merged, target)
  if not ok then return nil, "failed to install " .. target .. ": " .. tostring(err) end
  local changed = existed and result.updated or result.created
  changed[#changed + 1] = target
  return true
end

local function install_teams(target_dir, result)
  local target = target_dir .. "/teams.json"
  if uv.fs_lstat(target) then
    result.skipped[#result.skipped + 1] = target
    return true
  end
  vim.fn.mkdir(target_dir, "p")
  local lines = {
    "{",
    '  "version": 1,',
    '  "default_team": "sol-luna",',
    '  "teams": {',
    '    "sol-luna": {',
    '      "name": "Sol and Luna",',
    '      "lead": "sol_lead",',
    '      "members": {',
    '        "sol_lead": {',
    '          "agent": "Codex",',
    '          "model": "gpt-5.6-sol",',
    '          "effort": "max",',
    '          "role": "Lead architect",',
    '          "instructions": "Plan the work, delegate focused tasks, review reports, and integrate the final answer.",',
    '          "reports": ["luna_implementer", "luna_reviewer"]',
    "        },",
    '        "luna_implementer": {',
    '          "agent": "Codex",',
    '          "model": "gpt-5.6-luna",',
    '          "effort": "medium",',
    '          "role": "Implementation engineer",',
    '          "instructions": "Implement the delegated scope and report concrete changes and verification.",',
    '          "reports": []',
    "        },",
    '        "luna_reviewer": {',
    '          "agent": "Codex",',
    '          "model": "gpt-5.6-luna",',
    '          "effort": "medium",',
    '          "role": "Review engineer",',
    '          "instructions": "Review the delegated scope independently and report risks, defects, and recommendations.",',
    '          "reports": []',
    "        }",
    "      }",
    "    }",
    "  }",
    "}",
  }
  local ok, err = pcall(vim.fn.writefile, lines, target)
  if not ok then return nil, "failed to install " .. target .. ": " .. tostring(err) end
  result.created[#result.created + 1] = target
  return true
end

function M.install(opts)
  opts = opts or {}
  local scope = opts.scope or "project"
  local components = opts.components or "all"
  local profile = opts.profile
  if scope ~= "project" and scope ~= "global" then return nil, "scope must be project or global" end
  if components ~= "all" and components ~= "instructions" and components ~= "skills" and components ~= "teams" then
    return nil, "components must be all, instructions, skills, or teams"
  end
  if profile and components ~= "instructions" then return nil, "instructions profiles require the instructions component" end

  local target_dir = M.target_dir(scope, opts)
  local result = {
    scope = scope,
    components = components,
    profile = profile,
    target_dir = target_dir,
    created = {},
    updated = {},
    skipped = {},
  }
  if components == "all" or components == "instructions" then
    local ok, err
    if profile then
      ok, err = install_instruction_profile(target_dir, profile, result)
    else
      ok, err = install_instructions(target_dir, result)
    end
    if not ok then return nil, err end
  end
  if components == "all" or components == "skills" then
    local source = module_root() .. "skills"
    local ok, err = copy_missing(source, target_dir .. "/skills", result)
    if not ok then return nil, err end
  end
  if components == "all" or components == "teams" then
    local ok, err = install_teams(target_dir, result)
    if not ok then return nil, err end
  end
  return result
end

function M.instruction_profiles()
  local names = vim.tbl_keys(instruction_profiles)
  table.sort(names)
  return names
end

return M
