local M = {}

local folded_by_buf = {}
local tick_by_buf = {}
local window_options = {}
local marker_ns = vim.api.nvim_create_namespace('git_status_fold_markers')

local heading_highlights = {
  { '^Head:', 'RainbowDelimiterBlue' },
  { '^Help:', 'Comment' },
  { '^Unmerged paths %(', 'RainbowDelimiterRed' },
  { '^Untracked files %(', 'RainbowDelimiterOrange' },
  { '^Unstaged changes %(', 'RainbowDelimiterYellow' },
  { '^Staged changes %(', 'RainbowDelimiterGreen' },
  { '^Unpulled ', 'RainbowDelimiterCyan' },
  { '^Unpushed %[only%] %(', 'RainbowDelimiterViolet' },
  { '^Commits %[latest 15%+%] %(', 'RainbowDelimiterViolet' },
  { '^Submodules %(', 'RainbowDelimiterBlue' },
  { '^Worktrees %(', 'RainbowDelimiterViolet' },
  { '^Stashes %(', 'RainbowDelimiterOrange' },
  { '^Pull requests %(', 'RainbowDelimiterGreen' },
  { '^Index flags %[local%]', 'RainbowDelimiterCyan' },
  { '^Loading repository details', 'Comment' },
  { '^Bisecting', 'RainbowDelimiterYellow' },
  { ' in progress', 'RainbowDelimiterYellow' },
}

function M.heading_group(line)
  for _, item in ipairs(heading_highlights) do
    if line:match(item[1]) then return item[2] end
  end
end

local headers = {
  { '^Unmerged paths %(', 'conflicted' },
  { '^Untracked files %(', 'untracked' },
  { '^Unstaged changes %(', 'unstaged' },
  { '^Staged changes %(', 'staged' },
  { '^Stashes %(', 'stashes' },
  { '^Unpushed %[only%] %(', 'commits' },
  { '^Commits %[latest 15%+%] %(', 'commits' },
  { '^Unpulled from .+ %(', 'unpulled' },
  { '^Pull requests %(', 'pull_requests' },
  { '^Submodules %(', 'submodules' },
  { '^Worktrees %(', 'worktrees' },
  { '^Index flags %[local%] %(', 'index_flags' },
}

local always_open = { untracked = true, unstaged = true, staged = true, commits = true }

local function header(line)
  for _, item in ipairs(headers) do
    if line:match(item[1]) then return item[2], tonumber(line:match('%((%d+)%)')) or 0 end
  end
end

function M.is_header(line)
  return header(line or '') ~= nil
end

local function sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found = {}
  for row, line in ipairs(lines) do
    local key, count = header(line)
    if key then
      local last = row
      while last < #lines and lines[last + 1] ~= '' do last = last + 1 end
      if last > row then table.insert(found, { key = key, count = count, first = row, last = last }) end
    end
  end
  return found
end

function M.setup_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  if not window_options[winid] then
    local saved = {}
    for _, name in ipairs({ 'foldmethod', 'foldenable', 'foldcolumn', 'signcolumn', 'foldtext', 'fillchars', 'winhighlight' }) do
      saved[name] = vim.api.nvim_get_option_value(name, { win = winid })
    end
    window_options[winid] = saved
  end
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = winid })
  vim.api.nvim_set_option_value('foldenable', true, { win = winid })
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = winid })
  vim.api.nvim_set_option_value('signcolumn', 'yes:1', { win = winid })
  vim.api.nvim_set_option_value('foldtext', 'v:lua.require("git.features.status_folds").foldtext()', { win = winid })
  local fillchars = vim.api.nvim_get_option_value('fillchars', { win = winid })
  local parts = vim.tbl_filter(function(part) return part ~= '' and not part:match('^fold:') end,
    vim.split(fillchars, ',', { plain = true }))
  table.insert(parts, 'fold: ')
  local blank_fold = table.concat(parts, ',')
  if fillchars ~= blank_fold then vim.api.nvim_set_option_value('fillchars', blank_fold, { win = winid }) end
  local highlights = vim.api.nvim_get_option_value('winhighlight', { win = winid })
  local value, replacements = highlights:gsub('Folded:[^,]+', 'Folded:GitStatusFolded')
  if replacements == 0 then value = highlights == '' and 'Folded:GitStatusFolded' or highlights .. ',Folded:GitStatusFolded' end
  if value ~= highlights then vim.api.nvim_set_option_value('winhighlight', value, { win = winid }) end
end

function M.restore_window(winid)
  local saved = window_options[winid]
  window_options[winid] = nil
  if not saved or not vim.api.nvim_win_is_valid(winid) then return end
  for name, value in pairs(saved) do
    vim.api.nvim_set_option_value(name, value, { win = winid })
  end
end

function M.forget_window(winid)
  window_options[winid] = nil
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local group = M.heading_group(line) or 'Normal'
  return { { line, group } }
end

local function render_markers(bufnr, found, states)
  vim.api.nvim_buf_clear_namespace(bufnr, marker_ns, 0, -1)
  for _, section in ipairs(found) do
    local line = vim.api.nvim_buf_get_lines(bufnr, section.first - 1, section.first, false)[1]
    vim.api.nvim_buf_set_extmark(bufnr, marker_ns, section.first - 1, 0, {
      sign_text = states[section.key] and '▸' or '▾',
      sign_hl_group = M.heading_group(line) or 'Normal',
    })
  end
end

function M.capture(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  if tick_by_buf[bufnr] ~= vim.api.nvim_buf_get_changedtick(bufnr) then return end
  local winid = vim.fn.win_findbuf(bufnr)[1]
  if not (winid and vim.api.nvim_win_is_valid(winid)) then return end
  local states = folded_by_buf[bufnr] or {}
  vim.api.nvim_win_call(winid, function()
    for _, section in ipairs(sections(bufnr)) do
      if vim.fn.foldlevel(section.first) > 0 then
        states[section.key] = vim.fn.foldclosed(section.first) == section.first
      end
    end
  end)
  folded_by_buf[bufnr] = states
end

function M.rebuild(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local found = sections(bufnr)
  local states = folded_by_buf[bufnr] or {}
  folded_by_buf[bufnr] = states
  for _, section in ipairs(found) do
    if states[section.key] == nil then
      states[section.key] = section.key == 'index_flags'
        or (not always_open[section.key] and section.count >= 3)
    end
  end
  local windows = vim.fn.win_findbuf(bufnr)
  if not (opts and opts.skip_capture) and tick_by_buf[bufnr] == tick then M.capture(bufnr) end
  for _, winid in ipairs(windows) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_call(winid, function()
        M.setup_window(winid)
        vim.cmd('silent! normal! zE')
        for _, section in ipairs(found) do
          vim.cmd(('silent! %d,%dfold'):format(section.first, section.last))
          if not states[section.key] then vim.cmd(('silent! %dfoldopen'):format(section.first)) end
        end
      end)
    end
  end
  render_markers(bufnr, found, states)
  tick_by_buf[bufnr] = tick
end

function M.toggle(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  local key = header(line or '')
  if not key then return false end
  local states = folded_by_buf[bufnr] or {}
  states[key] = not states[key]
  folded_by_buf[bufnr] = states
  M.rebuild(bufnr, { skip_capture = true })
  return true
end

function M.set(bufnr, key, folded, opts)
  local states = folded_by_buf[bufnr] or {}
  states[key] = folded
  folded_by_buf[bufnr] = states
  if not (opts and opts.rebuild == false) then
    M.rebuild(bufnr, { skip_capture = true })
  end
end

function M.cleanup(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_clear_namespace(bufnr, marker_ns, 0, -1) end
  folded_by_buf[bufnr] = nil
  tick_by_buf[bufnr] = nil
end

return M
