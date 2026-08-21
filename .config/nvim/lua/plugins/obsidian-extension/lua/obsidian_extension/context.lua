local M = {}

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_note_segment(text, fallback)
  local normalized = trim(text)
    :gsub("[/\\]", "-")
    :gsub("[^%w%._-]", "-")
    :gsub("%-+", "-")
    :gsub("^[-_.]+", "")
    :gsub("[-_.]+$", "")
  return normalized ~= "" and normalized or fallback
end

local function branch_note_segments(branch_name)
  local branch_segments = vim.split(branch_name, "/", { trimempty = true })
  if vim.tbl_isempty(branch_segments) then branch_segments = { "HEAD" } end

  local note_segments = {}
  for index, segment in ipairs(branch_segments) do
    note_segments[index] = normalize_note_segment(segment, ("branch-%d"):format(index))
  end
  return note_segments
end

local function unquote(text)
  text = trim(text)
  local quote = text:sub(1, 1)
  if (quote == '"' or quote == "'") and text:sub(-1) == quote then
    return text:sub(2, -2)
  end
  return text
end

local function git_context_from_frontmatter(lines)
  if type(lines) ~= "table" or lines[1] ~= "---" then return nil end
  local project, branch
  for index = 2, #lines do
    local line = lines[index]
    if line == "---" or line == "..." then break end
    local key, value = line:match("^([%w_-]+):%s*(.*)$")
    if key == "project" then project = unquote(value) end
    if key == "branch" then branch = unquote(value) end
  end
  if not project or project == "" then return nil end

  local note_segments = branch and branch_note_segments(branch) or {}
  return {
    repo_name = project,
    repo_slug = normalize_note_segment(project, "project"),
    branch_name = branch ~= "" and branch or nil,
    branch_note_segments = note_segments,
    source = "note",
  }
end

local function current_note_git_context()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" or not M.is_vault_path(bufname) then return nil end
  local line_count = vim.api.nvim_buf_line_count(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, math.min(line_count, 100), false)
  return git_context_from_frontmatter(lines)
end

local function current_context_dir()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname ~= "" then
    local vault = M.vault_path()
    local absolute = vim.fn.fnamemodify(bufname, ":p")
    if vault and (absolute == vault or absolute:sub(1, #vault + 1) == vault .. "/") then
      return vim.fn.getcwd()
    end
    local stat = vim.uv.fs_stat(bufname)
    if stat then
      return stat.type == "directory" and bufname or vim.fs.dirname(bufname)
    end
    local bufdir = vim.fs.dirname(bufname)
    if bufdir and vim.uv.fs_stat(bufdir) then return bufdir end
  end
  return vim.fn.getcwd()
end

local function project_root_for_buffer(bufnr)
  local ok, project = pcall(require, "project")
  if not ok or type(project.get_project_root) ~= "function" then return nil end

  local root_ok, root = pcall(project.get_project_root, bufnr or 0)
  if not root_ok or type(root) ~= "string" or root == "" then return nil end
  return vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
end

function M.vault_path()
  local ok, obsidian = pcall(require, "obsidian")
  local client
  if ok and obsidian.get_client then
    local client_ok, resolved = pcall(obsidian.get_client)
    if client_ok then
      client = resolved
    end
  end
  local path = client and client.dir and tostring(client.dir) or ""
  if path == "" then return nil end
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/+$", "")
end

function M.is_vault_path(path, vault_path)
  vault_path = vault_path or M.vault_path()
  if not vault_path or not path or path == "" then return false end
  local absolute = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  return absolute == vault_path or absolute:sub(1, #vault_path + 1) == vault_path .. "/"
end

function M.git()
  local note_context = current_note_git_context()
  if note_context then return note_context end

  local project_root = project_root_for_buffer(0)
  local start_dir = project_root or current_context_dir()
  local repo_result = vim.system({ "git", "rev-parse", "--show-toplevel" }, {
    cwd = start_dir,
    text = true,
  }):wait()
  if repo_result.code ~= 0 then return nil, repo_result end

  local repo_root = project_root or trim(repo_result.stdout or "")
  local repo_name = vim.fs.basename(repo_root)
  local repo_slug = normalize_note_segment(repo_name, "project")
  local branch_result = vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, {
    cwd = repo_root,
    text = true,
  }):wait()
  if branch_result.code ~= 0 then return nil, branch_result end

  local branch_name = trim(branch_result.stdout or "")
  if branch_name == "" then branch_name = "HEAD" end
  return {
    repo_root = repo_root,
    repo_name = repo_name,
    repo_slug = repo_slug,
    branch_name = branch_name,
    branch_note_segments = branch_note_segments(branch_name),
    source = "git",
  }
end

function M.local_branches(git_context)
  if not git_context or not git_context.repo_root then return {} end
  local result = vim.system({
    "git", "for-each-ref", "--format=%(refname:short)", "refs/heads",
  }, {
    cwd = git_context.repo_root,
    text = true,
  }):wait()
  if result.code ~= 0 then return {} end

  local branches = {}
  for branch in (result.stdout or ""):gmatch("[^\r\n]+") do
    branch = trim(branch)
    if branch ~= "" then branches[#branches + 1] = branch end
  end
  return branches
end

function M.with_branch(git_context, branch_name)
  local selected = vim.deepcopy(git_context)
  selected.branch_name = branch_name
  selected.branch_note_segments = branch_note_segments(branch_name)
  return selected
end

M._git_context_from_frontmatter = git_context_from_frontmatter
M._project_root_for_buffer = project_root_for_buffer

return M
