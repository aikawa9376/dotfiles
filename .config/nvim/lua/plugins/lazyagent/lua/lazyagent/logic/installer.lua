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

function M.install(opts)
  opts = opts or {}
  local scope = opts.scope or "project"
  local components = opts.components or "all"
  if scope ~= "project" and scope ~= "global" then return nil, "scope must be project or global" end
  if components ~= "all" and components ~= "instructions" and components ~= "skills" then
    return nil, "components must be all, instructions, or skills"
  end

  local target_dir = M.target_dir(scope, opts)
  local result = { scope = scope, components = components, target_dir = target_dir, created = {}, skipped = {} }
  if components == "all" or components == "instructions" then
    local ok, err = install_instructions(target_dir, result)
    if not ok then return nil, err end
  end
  if components == "all" or components == "skills" then
    local source = module_root() .. "skills"
    local ok, err = copy_missing(source, target_dir .. "/skills", result)
    if not ok then return nil, err end
  end
  return result
end

return M
