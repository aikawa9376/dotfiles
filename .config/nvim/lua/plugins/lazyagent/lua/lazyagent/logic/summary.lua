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
  local root_component = sanitize_filename_component(rootname)
  local branch_component = sanitize_filename_component(branch)
  local dir = summary_dir() .. "/" .. root_component .. "/" .. branch_component
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return root_component .. "/" .. branch_component .. "/summary.md"
end

local function build_summary_filename_with_slug(bufnr, slug)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  local root_component = sanitize_filename_component(rootname)
  local branch_component = sanitize_filename_component(branch)
  local suffix = slug and sanitize_filename_component(slug) or "summary"
  local dir = summary_dir() .. "/" .. root_component .. "/" .. branch_component
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return root_component .. "/" .. branch_component .. "/" .. suffix .. ".md"
end

local function build_summary_prefix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  local root_component = sanitize_filename_component(rootname)
  local branch_component = sanitize_filename_component(branch)
  local dir = summary_dir() .. "/" .. root_component .. "/" .. branch_component
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir .. "/"
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

local function resolve_filter_dir()
  local bufn = vim.api.nvim_buf_get_name(0) or ""
  local root = util.git_root_for_path(bufn)
  local branch = util.git_branch_for_path(bufn)
  if not root or root == "" or not branch or branch == "" then return nil end
  local root_component = sanitize_filename_component(vim.fn.fnamemodify(root, ":t"))
  local branch_component = sanitize_filename_component(branch)
  if root_component == "" or branch_component == "" then return nil end
  local candidate = summary_dir() .. "/" .. root_component .. "/" .. branch_component
  if vim.fn.isdirectory(candidate) == 1 then
    return candidate
  end
  return nil
end

function M.list()
  local dir = summary_dir()
  if vim.fn.isdirectory(dir) == 0 then return {} end
  local filter_dir = resolve_filter_dir()

  local entries = {}
  local search_dir = filter_dir or dir
  local files = vim.fn.globpath(search_dir, "**/*.md", false, true) or {}
  for _, path in ipairs(files) do
    local rel_base = filter_dir or dir
    local rel = path:sub(#rel_base + 2)
    local name = filter_dir and (vim.fn.fnamemodify(path, ":t")) or (rel and #rel > 0 and rel or path)
    table.insert(entries, { name = name, path = path, mtime = vim.fn.getftime(path) or 0 })
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
    pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { scope = "win", win = win })
    vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
  end)
end

function M.pick(action)
  local entries = M.list()
  if not entries or #entries == 0 then
    vim.notify("LazyAgentSummary: no summary files found in " .. summary_dir(), vim.log.levels.INFO)
    return
  end

  local display_cwd = resolve_filter_dir() or summary_dir()
  local choices = {}
  local lookup = {}
  for _, e in ipairs(entries) do
    local rel = e.path
    if display_cwd and e.path:sub(1, #display_cwd) == display_cwd then
      rel = e.path:sub(#display_cwd + 2)
    elseif e.path:sub(1, #summary_dir()) == summary_dir() then
      rel = e.path:sub(#summary_dir() + 2)
    end
    table.insert(choices, rel)
    lookup[rel] = e
  end

  local function format_item(item)
    local e = lookup[item]
    if not e then return item end
    local ts = e.mtime and os.date("%Y-%m-%d %H:%M:%S", e.mtime) or ""
    local name = e.name or item
    if ts ~= "" then
      return name .. " (" .. ts .. ")"
    end
    return name
  end

  vim.ui.select(choices, {
    prompt = "Open lazyagent summary:",
    previewer = "builtin",
    cwd = display_cwd,
    format_item = format_item,
  }, function(choice)
    if not choice then return end
    local entry = lookup[choice]
    if not entry then return end
    select_action(entry, action or "open")
  end)
end

return M
