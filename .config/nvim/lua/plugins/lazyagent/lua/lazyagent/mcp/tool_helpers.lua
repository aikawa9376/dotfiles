local M = {}

local state = require("lazyagent.logic.state")
local diff_utils = require("lazyagent.acp.diff")
local uv = vim.uv or vim.loop

function M.normalize_fs_path(path)
  path = tostring(path or "")
  if path == "" then
    return nil
  end
  local normalized = vim.fn.fnamemodify(path, ":p")
  if vim.fs and type(vim.fs.normalize) == "function" then
    normalized = vim.fs.normalize(normalized)
  end
  return normalized
end

local normalize_fs_path = M.normalize_fs_path

local function file_stat_stamp(path)
  path = normalize_fs_path(path)
  if not path then
    return { exists = false, size = -1, sec = -1, nsec = -1 }
  end

  if uv and type(uv.fs_stat) == "function" then
    local stat = uv.fs_stat(path)
    if stat then
      local mtime = stat.mtime or {}
      return {
        exists = true,
        size = tonumber(stat.size or -1) or -1,
        sec = tonumber(mtime.sec or mtime.tv_sec or -1) or -1,
        nsec = tonumber(mtime.nsec or mtime.tv_nsec or 0) or 0,
      }
    end
  end

  local sec = tonumber(vim.fn.getftime(path)) or -1
  if sec < 0 then
    return { exists = false, size = -1, sec = -1, nsec = -1 }
  end

  return {
    exists = true,
    size = tonumber(vim.fn.getfsize(path)) or -1,
    sec = sec,
    nsec = 0,
  }
end

local function same_file_stat(a, b)
  a = a or {}
  b = b or {}
  return a.exists == b.exists
    and tonumber(a.size or -1) == tonumber(b.size or -1)
    and tonumber(a.sec or -1) == tonumber(b.sec or -1)
    and tonumber(a.nsec or -1) == tonumber(b.nsec or -1)
end

local function git_status_paths(cwd)
  local lines = vim.fn.systemlist({ "git", "-C", cwd, "status", "--short" })
  if vim.v.shell_error ~= 0 or type(lines) ~= "table" or #lines == 0 then
    return {}
  end

  local paths = {}
  for _, line in ipairs(lines) do
    local rel = tostring(line or ""):sub(4):gsub("^%s+", "")
    local renamed = rel:match("^.+ %-> (.+)$")
    if renamed and renamed ~= "" then
      rel = renamed
    end
    if rel ~= "" then
      paths[#paths + 1] = rel
    end
  end
  return paths
end

local function changed_file_snapshot(cwd)
  local snapshot = {}
  for _, rel in ipairs(git_status_paths(cwd)) do
    local abs = normalize_fs_path(cwd .. "/" .. rel)
    if abs then
      snapshot[abs] = {
        rel = rel,
        stat = file_stat_stamp(abs),
      }
    end
  end
  return snapshot
end

-- Return git-changed files touched during the current turn.
-- Falls back to mtime filtering if no per-turn snapshot exists.
function M.changed_files_since(cwd, since)
  local all = git_status_paths(cwd)
  if not all or #all == 0 then
    return {}
  end

  local normalized_cwd = normalize_fs_path(cwd)
  local snapshot = normalized_cwd and state._hook_turn_cwd == normalized_cwd and state._hook_turn_snapshot or nil
  if type(snapshot) == "table" then
    local result = {}
    for _, rel in ipairs(all) do
      local abs = normalize_fs_path(cwd .. "/" .. rel)
      local before = abs and snapshot[abs] or nil
      local after = abs and file_stat_stamp(abs) or nil
      if not before or not same_file_stat(before.stat, after) then
        table.insert(result, rel)
      end
    end
    return result
  end

  if not since then
    return all
  end

  local result = {}
  for _, rel in ipairs(all) do
    local abs = cwd .. "/" .. rel
    if vim.fn.getftime(abs) >= since then
      table.insert(result, rel)
    end
  end
  return result
end

function M.begin_edit_tracking(cwd)
  cwd = normalize_fs_path(cwd or vim.fn.getcwd())
  state._hook_turn_start = os.time()
  state._hook_turn_cwd = cwd
  state._hook_turn_snapshot = cwd and changed_file_snapshot(cwd) or {}
  local hopts = (state.opts and state.opts.hooks) or {}
  if hopts.quickfix_on_edit ~= false then
    state._qf_items = {}
    vim.fn.setqflist({}, "r", { title = "Agent turn", items = {} })
  end
  -- Stop any active diagnostic-review loop and clear fix-request flag when a new agent turn begins
  state._diagnostic_loop_active = false
  state._fix_requested = false
end

function M.resolve_tool_cwd(params)
  params = type(params) == "table" and params or {}
  if params.cwd and params.cwd ~= "" then
    return normalize_fs_path(params.cwd)
  end
  local session = params.agent_name and state.sessions and state.sessions[params.agent_name] or nil
  local cwd = session and (session.root_dir or session.cwd) or vim.fn.getcwd()
  return normalize_fs_path(cwd)
end

function M.resolve_target_path(path, cwd)
  path = tostring(path or "")
  if path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return normalize_fs_path(path)
  end
  return normalize_fs_path((cwd or vim.fn.getcwd()) .. "/" .. path)
end

function M.reload_loaded_buffers_for_paths(cwd, files)
  if type(files) ~= "table" or #files == 0 then
    return { reloaded = 0, skipped_modified = 0 }
  end

  local targets = {}
  for _, rel in ipairs(files) do
    local abs = M.resolve_target_path(rel, cwd)
    if abs and vim.fn.filereadable(abs) == 1 then
      targets[abs] = true
    end
  end
  if not next(targets) then
    return { reloaded = 0, skipped_modified = 0 }
  end

  local result = { reloaded = 0, skipped_modified = 0 }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = normalize_fs_path(vim.api.nvim_buf_get_name(bufnr))
      if name and targets[name] and vim.bo[bufnr].buftype == "" then
        if vim.bo[bufnr].modified then
          result.skipped_modified = result.skipped_modified + 1
        else
          pcall(vim.cmd, "silent checktime " .. tostring(bufnr))
          result.reloaded = result.reloaded + 1
        end
      end
    end
  end

  return result
end

function M.hook_reload_enabled()
  return ((((state.opts or {}).hooks or {}).reload_mode) or "hook") ~= "watch"
end

local function git_diff_for_path(cwd, abs_path)
  local diff = vim.fn.systemlist({ "git", "-C", cwd, "diff", "--unified=0", "--", abs_path })
  if vim.v.shell_error ~= 0 or type(diff) ~= "table" then
    return {}
  end
  return diff
end

function M.changed_line_from_diff(cwd, abs_path, params)
  local diff = git_diff_for_path(cwd, abs_path)
  if not diff or #diff == 0 then
    return 1
  end

  local line = diff_utils.line_for_change(
    params.oldText or params.old_text,
    params.newText or params.new_text,
    diff
  )
  if line then
    return tonumber(line) or 1
  end

  local first = diff_utils.parse_unified_diff_hunks(diff)[1]
  if first then
    if (first.new_count or 0) > 0 then
      return tonumber(first.new_start) or 1
    end
    return tonumber(first.old_start) or 1
  end

  return 1
end

-- Get the "current" code buffer and its window, skipping lazyagent scratch buffers.
function M.current_buf()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, src = pcall(vim.api.nvim_buf_get_var, buf, "lazyagent_source_bufnr")
    if ok and src and vim.api.nvim_buf_is_valid(src) and vim.bo[src].buftype == "" then
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == src then
          return src, w
        end
      end
      return src, vim.api.nvim_get_current_win()
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bt = vim.bo[buf].buftype
    if bt == "" or bt == "acwrite" then
      return buf, win
    end
  end
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

return M
