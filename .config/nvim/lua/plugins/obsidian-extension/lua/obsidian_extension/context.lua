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

function M.vault_path()
  local ok, obsidian = pcall(require, "obsidian")
  local client = ok and obsidian.get_client and obsidian.get_client() or nil
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
  local start_dir = current_context_dir()
  local repo_result = vim.system({ "git", "rev-parse", "--show-toplevel" }, {
    cwd = start_dir,
    text = true,
  }):wait()
  if repo_result.code ~= 0 then return nil, repo_result end

  local repo_root = trim(repo_result.stdout or "")
  local repo_name = vim.fs.basename(repo_root)
  local repo_slug = normalize_note_segment(repo_name, "project")
  local branch_result = vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, {
    cwd = repo_root,
    text = true,
  }):wait()
  if branch_result.code ~= 0 then return nil, branch_result end

  local branch_name = trim(branch_result.stdout or "")
  if branch_name == "" then branch_name = "HEAD" end
  local branch_segments = vim.split(branch_name, "/", { trimempty = true })
  if vim.tbl_isempty(branch_segments) then branch_segments = { "HEAD" } end

  local note_segments = {}
  for index, segment in ipairs(branch_segments) do
    note_segments[index] = normalize_note_segment(segment, ("branch-%d"):format(index))
  end

  return {
    repo_root = repo_root,
    repo_name = repo_name,
    repo_slug = repo_slug,
    branch_name = branch_name,
    branch_note_segments = note_segments,
  }
end

return M
