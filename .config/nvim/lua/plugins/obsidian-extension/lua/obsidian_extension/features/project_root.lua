local M = {}

local context = require("obsidian_extension.context")
local group = vim.api.nvim_create_augroup("ObsidianExtensionProjectRoot", { clear = true })

local function project_slug_from_path(path, vault_path)
  if type(path) ~= "string" or path == "" or type(vault_path) ~= "string" or vault_path == "" then
    return nil
  end

  local projects_root = vim.fs.normalize(vim.fs.joinpath(vault_path, "notes", "projects"))
  local absolute = vim.fs.normalize(path)
  if absolute:sub(1, #projects_root + 1) ~= projects_root .. "/" then
    return nil
  end

  local relative = absolute:sub(#projects_root + 2)
  local project_slug, note_path = relative:match("^([^/]+)/(.+%.md)$")
  if not project_slug or not note_path then
    return nil
  end
  return project_slug
end

local function resolve_project_root(project_slug, projects)
  if type(project_slug) ~= "string" or project_slug == "" then
    return nil
  end

  local matches = {}
  local seen = {}
  for _, project in ipairs(projects or {}) do
    local path = type(project) == "table" and project.path or project
    if type(path) == "string" and path ~= "" then
      path = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
      if vim.fs.basename(path) == project_slug and vim.fn.isdirectory(path) == 1 and not seen[path] then
        matches[#matches + 1] = path
        seen[path] = true
      end
    end
  end

  return #matches == 1 and matches[1] or nil
end

local function attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local vault_path = context.vault_path()
  local project_slug = project_slug_from_path(vim.api.nvim_buf_get_name(bufnr), vault_path)
  if not project_slug then
    return false
  end

  local history_ok, history = pcall(require, "project.util.history")
  local core_ok, core = pcall(require, "project.core")
  if not history_ok or not core_ok or type(core.set_pwd) ~= "function" then
    return false
  end

  local projects = history.get_recent_projects(false, false, true)
  local project_root = resolve_project_root(project_slug, projects)
  if not project_root then
    return false
  end

  if vim.fn.getcwd() == project_root and vim.b[bufnr].obsidian_extension_project_root == project_root then
    return true
  end

  local attached = core.set_pwd(project_root, "obsidian branch note", bufnr)
  if attached then
    vim.b[bufnr].obsidian_extension_project_root = project_root
  end
  return attached
end

function M.setup(opts)
  opts = opts or {}
  if opts.enabled ~= true then
    return
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.md",
    callback = function(event)
      attach(event.buf)
    end,
  })

  if vim.bo.filetype == "markdown" then
    local bufnr = vim.api.nvim_get_current_buf()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        attach(bufnr)
      end
    end)
  end
end

M._project_slug_from_path = project_slug_from_path
M._resolve_project_root = resolve_project_root
M._attach = attach

return M
