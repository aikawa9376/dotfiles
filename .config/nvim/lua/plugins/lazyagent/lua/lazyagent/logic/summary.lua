local M = {}

local cache = require("lazyagent.logic.cache")
local util = require("lazyagent.util")

local function sanitize_filename_component(s)
  if not s then return "" end
  s = tostring(s)
  s = s:gsub("[^%w-_]+", "-")
  return s
end

local function summary_dir()
  local base = cache.get_cache_dir()
  local dir = base .. "/summary"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end
M.summary_dir = summary_dir

local function build_summary_filename(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  return sanitize_filename_component(rootname) .. "-" .. sanitize_filename_component(branch) .. "-summary.md"
end

local function build_summary_filename_with_slug(bufnr, slug)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  local suffix = slug and sanitize_filename_component(slug) or "summary"
  return sanitize_filename_component(rootname) .. "-" .. sanitize_filename_component(branch) .. "-" .. suffix .. ".md"
end

local function build_summary_prefix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  return summary_dir() .. "/" .. sanitize_filename_component(rootname) .. "-" .. sanitize_filename_component(branch) .. "-"
end
M.summary_prefix = build_summary_prefix

function M.summary_path(bufnr)
  return summary_dir() .. "/" .. build_summary_filename(bufnr)
end

function M.example_summary_path(bufnr)
  return summary_dir() .. "/" .. build_summary_filename_with_slug(bufnr, "task-slug")
end

function M.ensure_summary_file(bufnr)
  return M.summary_path(bufnr)
end

function M.copy_path(path)
  if not path or path == "" then return false end
  local ok = pcall(vim.fn.setreg, "+", path)
  if ok then pcall(vim.fn.setreg, '"', path) end
  return ok
end

function M.list()
  local dir = summary_dir()
  if vim.fn.isdirectory(dir) == 0 then return {} end
  local raw = vim.fn.readdir(dir) or {}
  local entries = {}
  for _, f in ipairs(raw) do
    if f:match("%.md$") then
      local path = dir .. "/" .. f
      table.insert(entries, { name = f, path = path, mtime = vim.fn.getftime(path) or 0 })
    end
  end
  table.sort(entries, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
  return entries
end

local function select_action(entry, action)
  if not entry or not entry.path then return end
  if action == "copy" then
    if M.copy_path(entry.path) then
      pcall(vim.notify, "LazyAgentSummary: copied path: " .. entry.path, vim.log.levels.INFO)
    end
    return
  end

  vim.schedule(function()
    local target = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local wf = vim.api.nvim_get_option_value("winfixbuf", { win = w })
      local b = vim.api.nvim_win_get_buf(w)
      local bt = vim.api.nvim_get_option_value("buftype", { buf = b })
      if not wf and bt == "" then
        target = w
        break
      end
    end

    if target and target ~= vim.api.nvim_get_current_win() then
      pcall(vim.api.nvim_set_current_win, target)
    elseif vim.api.nvim_get_option_value("winfixbuf", { win = vim.api.nvim_get_current_win() }) then
      vim.cmd("belowright split")
    end

    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_option, win, "winfixbuf", false)
    vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
  end)
end

function M.pick(action)
  local entries = M.list()
  if not entries or #entries == 0 then
    vim.notify("LazyAgentSummary: no summary files found in " .. summary_dir(), vim.log.levels.INFO)
    return
  end

  local choices = {}
  for _, e in ipairs(entries) do
    table.insert(choices, e.name .. " (" .. os.date("%Y-%m-%d %H:%M:%S", e.mtime or 0) .. ")")
  end

  vim.ui.select(choices, { prompt = "Open lazyagent summary:" }, function(choice, idx)
    if not choice or not idx then return end
    local entry = entries[idx]
    if not entry then return end
    select_action(entry, action or "open")
  end)
end

return M
