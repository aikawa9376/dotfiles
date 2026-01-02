local M = {}

local api = vim.api
local fn = vim.fn
local uv = vim.uv or vim.loop

local ns = api.nvim_create_namespace("lazyconflict")

local default_config = {
  detection = {
    auto = true,
    autocmds = { "BufEnter", "BufWritePost", "FocusGained", "TextChanged" },
    debounce_ms = 400,
    cwd = nil,
    mode = "git", -- "git" (default: git diff --diff-filter=U) or "marker" (scan all files for markers)
    command = nil, -- nil なら内蔵の git diff --name-only --diff-filter=U から rg する検出を使う
    pattern = "^<<<<<<<.*$|^>>>>>>>.*$|^\\|\\|\\|\\|\\|\\|\\|.*$|^=======.*$",
    silent_stderr = false,
  },
  statusline = {
    icon = "",
    formatter = function(count)
      if count and count > 0 then
        return string.format(" %d", count)
      end
      return ""
    end,
  },
  quickfix = {
    open = false,
  },
  disable_diagnostics = true,
  highlights = {
    current = "LazyConflictCurrent",
    current_label = "LazyConflictCurrentLabel",
    incoming = "LazyConflictIncoming",
    incoming_label = "LazyConflictIncomingLabel",
    ancestor = "LazyConflictAncestor",
    ancestor_label = "LazyConflictAncestorLabel",
    separator = "LazyConflictSeparator",
  },
  keymaps = {
    enabled = true,
    ours = "co",
    theirs = "ct",
    all_ours = "ca",
    all_theirs = "cA",
    both = "cb",
    cursor = "cc",
    none = "c0",
    next = "]]",
    prev = "[[",
  },
}

local state = {
  config = default_config,
  enabled = true,
  job = nil,
  conflicts = {},
  total = 0,
  cwd = nil,
  augroup = nil,
  buf_keymaps = {},
  commands_created = false,
  debounced_check = nil,
  git_job = nil,
}

local DEFAULT_COLORS = {
  current = "#06323d",
  current_label = "#094b5c", -- Brighter version of current
  incoming = "#073642",
  incoming_label = "#0b5063", -- Brighter version of incoming
  ancestor = "#2a0f2e", -- Dark purple to contrast with blue/green
  ancestor_label = "#4a1b52", -- Brighter version of ancestor
}

local function ensure_highlights()
  local hl = state.config.highlights
  local function link_or_set(target, source, default_val)
    if fn.hlexists(source) == 1 then
      api.nvim_set_hl(0, target, { link = source, default = true })
    elseif type(default_val) == "string" and default_val:sub(1, 1) ~= "#" then
       -- Link
      api.nvim_set_hl(0, target, { link = default_val, default = true })
    else
       -- Color code
      api.nvim_set_hl(0, target, { bg = default_val, bold = true, default = true })
    end
  end
  link_or_set(hl.current, "GitConflictCurrent", DEFAULT_COLORS.current)
  link_or_set(hl.current_label, "GitConflictCurrentLabel", DEFAULT_COLORS.current_label)
  link_or_set(hl.incoming, "GitConflictIncoming", DEFAULT_COLORS.incoming)
  link_or_set(hl.incoming_label, "GitConflictIncomingLabel", DEFAULT_COLORS.incoming_label)
  link_or_set(hl.ancestor, "GitConflictAncestor", DEFAULT_COLORS.ancestor)
  link_or_set(hl.ancestor_label, "GitConflictAncestorLabel", DEFAULT_COLORS.ancestor_label)
  if fn.hlexists("GitConflictSeparator") == 1 then
    api.nvim_set_hl(0, hl.separator, { link = "GitConflictSeparator", default = true })
  else
    api.nvim_set_hl(0, hl.separator, { link = "Comment", default = true })
  end
end

local function is_abs(path)
  return path:match("^%a:[/\\]") or path:sub(1, 1) == "/"
end

local function normalize_path(path, cwd)
  if not path or path == "" then
    return ""
  end
  if not is_abs(path) then
    path = vim.fs.joinpath(cwd or fn.getcwd(), path)
  end
  return vim.fs.normalize(path)
end

local function get_buf_path(bufnr)
  return normalize_path(api.nvim_buf_get_name(bufnr))
end

local function slice(tbl, s, e)
  local out = {}
  for i = s, e do
    table.insert(out, tbl[i])
  end
  return out
end

local function debounce(fn, delay)
  if not delay or delay <= 0 then
    return fn
  end
  local timer
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer:close()
    end
    timer = uv.new_timer()
    timer:start(delay, 0, function()
      timer:stop()
      timer:close()
      timer = nil
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

local function parse_lines(lines, cwd)
  local entries = {}
  for _, line in ipairs(lines or {}) do
    if line ~= "" then
      local path, lnum, text = line:match("^(.-):(%d+):(.*)$")
      if path and lnum then
        table.insert(entries, {
          file = normalize_path(path, cwd),
          lnum = tonumber(lnum),
          text = text or "",
        })
      end
    end
  end
  return entries
end

local function set_conflicts(entries)
  local by_file = {}
  local total = 0
  for _, entry in ipairs(entries) do
    if entry.file and entry.file ~= "" then
      local info = by_file[entry.file]
      if not info then
        info = { file = entry.file, items = {} }
        by_file[entry.file] = info
      end
      table.insert(info.items, { lnum = entry.lnum, text = entry.text or "" })
    end
  end
  for _, info in pairs(by_file) do
    table.sort(info.items, function(a, b)
      return a.lnum < b.lnum
    end)
    -- マーカー行数ではなく、コンフリクトブロック数（<<<<<<< の数）をカウント
    local count = 0
    for _, item in ipairs(info.items) do
      if item.text:match("^<<<<<<<") then
        count = count + 1
      end
    end
    total = total + count
  end
  state.conflicts = by_file
  state.total = total
  M.apply_all_buffers()
end

local function ensure_commands()
  if state.commands_created then
    return
  end
  api.nvim_create_user_command("LazyConflictCheck", function()
    M.check()
  end, { desc = "lazyconflict: run conflict detection" })
  api.nvim_create_user_command("LazyConflictQuickfix", function()
    M.populate_quickfix({ open = true })
  end, { desc = "lazyconflict: populate quickfix with conflicts" })
  api.nvim_create_user_command("LazyConflictEnable", function()
    M.enable()
  end, { desc = "lazyconflict: enable automatic detection" })
  api.nvim_create_user_command("LazyConflictDisable", function()
    M.disable()
  end, { desc = "lazyconflict: disable automatic detection" })
  api.nvim_create_user_command("LazyConflictMode", function(opts)
    local mode = opts.args
    if mode == "git" or mode == "marker" then
      state.config.detection.mode = mode
      vim.notify("[lazyconflict] Switched to " .. mode .. " mode", vim.log.levels.INFO)
      M.check()
    else
      vim.notify("[lazyconflict] Invalid mode: " .. tostring(mode) .. ". Use 'git' or 'marker'", vim.log.levels.ERROR)
    end
  end, {
    desc = "lazyconflict: switch detection mode (git|marker)",
    nargs = 1,
    complete = function(ArgLead, CmdLine, CursorPos)
      return { "git", "marker" }
    end,
  })
  state.commands_created = true
end

local function ensure_augroup()
  if state.augroup then
    return state.augroup
  end
  state.augroup = api.nvim_create_augroup("LazyConflict", { clear = true })
  return state.augroup
end

local function clear_keymaps(bufnr)
  local keys = state.buf_keymaps[bufnr]
  if not keys then
    return
  end
  for _, key in ipairs(keys) do
    pcall(vim.keymap.del, "n", key, { buffer = bufnr })
  end
  state.buf_keymaps[bufnr] = nil
  if state.config.disable_diagnostics then
    vim.schedule(function()
      if api.nvim_buf_is_valid(bufnr) then
        if vim.diagnostic.enable then
          vim.diagnostic.enable(true, { bufnr = bufnr })
        end
        if vim.lsp.inlay_hint then
          vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
        end
        pcall(vim.cmd, "LspStart")
      end
    end)
  end
end

local function set_keymaps(bufnr)
  local cfg = state.config.keymaps
  if not cfg.enabled then
    return
  end
  if state.buf_keymaps[bufnr] then
    return
  end
  if state.config.disable_diagnostics then
    vim.schedule(function()
      if api.nvim_buf_is_valid(bufnr) then
        if vim.diagnostic.enable then
          vim.diagnostic.enable(false, { bufnr = bufnr })
        end
        if vim.lsp.inlay_hint then
          vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
        end
        pcall(vim.cmd, "LspStop")
      end
    end)
  end
  local keys = {}
  local function add(key, fnc, desc)
    if not key or key == "" then
      return
    end
    vim.keymap.set("n", key, fnc, { buffer = bufnr, silent = true, nowait = true, desc = desc })
    table.insert(keys, key)
  end
  add(cfg.next, M.jump_next, "Conflict next")
  add(cfg.prev, M.jump_prev, "Conflict prev")
  add(cfg.ours, function()
    M.accept("ours")
  end, "Conflict accept ours")
  add(cfg.theirs, function()
    M.accept("theirs")
  end, "Conflict accept theirs")
  add(cfg.all_ours, function()
    M.accept("all_ours")
  end, "Conflict accept all ours")
  add(cfg.all_theirs, function()
    M.accept("all_theirs")
  end, "Conflict accept all theirs")
  add(cfg.both, function()
    M.accept("both")
  end, "Conflict accept both")
  add(cfg.cursor, function()
    M.accept("cursor")
  end, "Conflict accept cursor")
  add(cfg.none, function()
    M.accept("none")
  end, "Conflict accept none")
  state.buf_keymaps[bufnr] = keys
end

local function apply_highlights(bufnr, info, regions)
  -- info は存在確認用。ハイライトは実際のバッファ内容から構築する。
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not info or not info.items then
    return
  end
  regions = regions or M.build_regions(bufnr)
  if not regions or #regions == 0 then
    clear_keymaps(bufnr)
    return
  end
  local hl = state.config.highlights
  local line_count = api.nvim_buf_line_count(bufnr)
  local function add_range(group, start_line, end_line)
    if not group or group == "" then
      return
    end
    start_line = math.max(1, math.min(start_line, line_count))
    end_line = math.max(1, math.min(end_line, line_count))
    if end_line < start_line then
      return
    end
    api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0, {
      hl_group = group,
      hl_eol = true,
      hl_mode = "combine",
      end_row = end_line,
      priority = vim.highlight.priorities.user,
    })
  end
  for _, r in ipairs(regions) do
    local ours_start = r.start
    local ours_end = (r.base or r.sep) - 1
    -- マーカー行自体には Label ハイライトを適用
    add_range(hl.current_label, ours_start, ours_start)
    add_range(hl.current, ours_start + 1, math.max(ours_end, ours_start))

    if r.base then
      add_range(hl.ancestor_label, r.base, r.base)
      add_range(hl.ancestor, r.base + 1, r.sep - 1)
    end

    add_range(hl.separator, r.sep, r.sep)

    add_range(hl.incoming, r.sep + 1, r.finish - 1)
    add_range(hl.incoming_label, r.finish, r.finish)
  end
end

local function with_conflict_info(bufnr)
  local path = get_buf_path(bufnr)
  if path == "" then
    return nil
  end
  return state.conflicts[path]
end

function M.apply_buffer(bufnr)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local info = with_conflict_info(bufnr)

  -- Gitでコンフリクトとして検知されていないファイルなら、
  -- 全行スキャン(build_regions)を避けて即座にクリーンアップ
  if not info then
    apply_highlights(bufnr, nil)
    clear_keymaps(bufnr)
    return
  end

  -- バッファの内容をチェックし、マーカーがなければクリーンアップして終了
  local regions = M.build_regions(bufnr)
  if not regions or #regions == 0 then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    clear_keymaps(bufnr)
    return
  end

  if not info or not info.items or #info.items == 0 then
    apply_highlights(bufnr, nil, regions)
    clear_keymaps(bufnr)
    return
  end
  apply_highlights(bufnr, info, regions)
  set_keymaps(bufnr)
end

function M.apply_all_buffers()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      M.apply_buffer(buf)
    else
      clear_keymaps(buf)
    end
  end
end

local function resolve_command(cmd)
  if type(cmd) == "function" then
    cmd = cmd()
  end
  return cmd
end

function M.check(opts)
  if not state.enabled then
    return
  end
  local cfg = state.config
  local detection = cfg.detection
  local cmd = resolve_command(opts and opts.command or detection.command)
  local cwd = opts and opts.cwd or detection.cwd or fn.getcwd()
  if type(cmd) == "string" then
    cmd = { cmd }
  end
  if state.job then
    pcall(fn.jobstop, state.job)
    state.job = nil
  end
  if state.git_job then
    pcall(fn.jobstop, state.git_job)
    state.git_job = nil
  end
  state.cwd = cwd

  local function run_rg(files)
    if not files or #files == 0 then
      set_conflicts({})
      return
    end
    local rg_cmd = {
      "rg",
      "--no-heading",
      "--line-number",
      "--color",
      "never",
      detection.pattern or default_config.detection.pattern,
    }
    vim.list_extend(rg_cmd, files)
    local stdout_data = {}
    local stderr_data = {}
    state.job = fn.jobstart(rg_cmd, {
      cwd = cwd,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stdout_data, line)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data and not detection.silent_stderr then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stderr_data, line)
            end
          end
        end
      end,
      on_exit = function(_, code)
        local notify_err = code > 1 and #stderr_data > 0
        local entries = {}
        if code == 0 or code == 1 then
          entries = parse_lines(stdout_data, cwd)
        end
        vim.schedule(function()
          set_conflicts(entries)
          if notify_err then
            vim.notify("[lazyconflict] " .. table.concat(stderr_data, "\n"), vim.log.levels.WARN)
          end
          if (opts and opts.open_quickfix) or (cfg.quickfix.open and state.total > 0) then
            M.populate_quickfix({ open = true })
          end
        end)
      end,
    })
  end

  if cmd and #cmd > 0 then
    -- ユーザカスタムコマンドをそのまま使う
    local stdout_data = {}
    local stderr_data = {}
    state.job = fn.jobstart(cmd, {
      cwd = cwd,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stdout_data, line)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data and not detection.silent_stderr then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stderr_data, line)
            end
          end
        end
      end,
      on_exit = function(_, code)
        local notify_err = code > 1 and #stderr_data > 0
        local entries = {}
        if code == 0 or code == 1 then
          entries = parse_lines(stdout_data, cwd)
        end
        vim.schedule(function()
          set_conflicts(entries)
          if notify_err then
            vim.notify("[lazyconflict] " .. table.concat(stderr_data, "\n"), vim.log.levels.WARN)
          end
          if (opts and opts.open_quickfix) or (cfg.quickfix.open and state.total > 0) then
            M.populate_quickfix({ open = true })
          end
        end)
      end,
    })
    return
  end

  -- デフォルト: git で競合ファイルだけ取得して rg
  if detection.mode == "marker" then
    -- "marker" モード: git の状態に関わらず、パターンにマッチするファイルを rg で検索
    local rg_files_cmd = {
      "rg",
      "--files-with-matches",
      "--no-messages",
      detection.pattern or default_config.detection.pattern,
      ".", -- カレントディレクトリ以下を検索
    }
    local files = {}
    local stderr_rg = {}
    state.git_job = fn.jobstart(rg_files_cmd, {
      cwd = cwd,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(files, normalize_path(line, cwd))
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data and not detection.silent_stderr then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stderr_rg, line)
            end
          end
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 and code ~= 1 then -- rg returns 1 if no matches found
          vim.schedule(function()
            if #stderr_rg > 0 then
              vim.notify("[lazyconflict] " .. table.concat(stderr_rg, "\n"), vim.log.levels.WARN)
            end
            set_conflicts({})
          end)
          return
        end
        vim.schedule(function()
          run_rg(files)
        end)
      end,
    })
    return
  end

  -- "git" モード (デフォルト): git diff --diff-filter=U で競合ファイルを取得
  local files = {}
  local stderr_git = {}
  state.git_job = fn.jobstart({ "git", "diff", "--name-only", "--diff-filter=U" }, {
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(files, normalize_path(line, cwd))
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data and not detection.silent_stderr then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_git, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          if #stderr_git > 0 then
            vim.notify("[lazyconflict] " .. table.concat(stderr_git, "\n"), vim.log.levels.WARN)
          end
          set_conflicts({})
        end)
        return
      end
      vim.schedule(function()
        run_rg(files)
      end)
    end,
  })
end

function M.statusline()
  local formatter = state.config.statusline.formatter
  return formatter(state.total)
end

function M.populate_quickfix(opts)
  local function regions_from_info(info)
    local regions = {}
    local start_lnum
    local ancestor_lnum
    local sep_lnum
    for _, item in ipairs(info.items or {}) do
      local text = item.text or ""
      if text:match("^<<<<<<<") then
        start_lnum = item.lnum
        ancestor_lnum = nil
        sep_lnum = nil
      elseif text:match("^|||||||") then
        ancestor_lnum = item.lnum
      elseif text:match("^=======") then
        sep_lnum = item.lnum
      elseif text:match("^>>>>>>>") and start_lnum and sep_lnum then
        table.insert(regions, {
          start = start_lnum,
          ancestor = ancestor_lnum,
          sep = sep_lnum,
          finish = item.lnum,
        })
        start_lnum, ancestor_lnum, sep_lnum = nil, nil, nil
      end
    end
    return regions
  end

  local items = {}
  for path, info in pairs(state.conflicts) do
    local regions = regions_from_info(info)
    if #regions > 0 then
      for _, r in ipairs(regions) do
        local current_lines = (r.ancestor or r.sep) - r.start - 1
        table.insert(items, {
          filename = path,
          lnum = r.start,
          col = 0,
          text = string.format("current change (%d lines)", current_lines),
          type = "",
          pattern = "^<<<<<<<",
        })
        local incoming_lines = r.finish - r.sep - 1
        table.insert(items, {
          filename = path,
          lnum = r.sep + 1,
          col = 0,
          text = string.format("incoming change (%d lines)", incoming_lines),
          type = "",
          pattern = "^=======",
        })
        if r.ancestor then
          local base_lines = r.sep - r.ancestor - 1
          table.insert(items, {
            filename = path,
            lnum = r.ancestor + 1,
            col = 0,
            text = string.format("base change (%d lines)", base_lines),
            type = "",
            pattern = "^|||||||",
          })
        end
      end
    else
      for _, item in ipairs(info.items or {}) do
        table.insert(items, {
          filename = path,
          lnum = item.lnum,
          col = 0,
          text = item.text or "conflict",
          type = "",
        })
      end
    end
  end
  table.sort(items, function(a, b)
    if a.filename == b.filename then
      return a.lnum < b.lnum
    end
    return a.filename < b.filename
  end)
  if #items == 0 then
    fn.setqflist({}, " ", { title = "lazyconflict", items = {} })
    if opts and opts.open then
      vim.notify("[lazyconflict] No conflicts found", vim.log.levels.INFO)
    end
    return
  end
  fn.setqflist({}, " ", { title = "lazyconflict", items = items })
  if opts and opts.open then
    vim.cmd("copen")
  end
end

function M.build_regions(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local regions = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match("^<<<<<<<") then
      local start_idx = i
      local base_idx
      local sep_idx
      local end_idx
      i = i + 1
      while i <= #lines do
        if not base_idx and lines[i]:match("^|||||||") then
          base_idx = i
        end
        if lines[i]:match("^=======") then
          sep_idx = i
        end
        if lines[i]:match("^>>>>>>>") then
          end_idx = i
          break
        end
        i = i + 1
      end
      if sep_idx and end_idx then
        table.insert(regions, {
          start = start_idx,
          base = base_idx,
          sep = sep_idx,
          finish = end_idx,
        })
      end
    else
      i = i + 1
    end
  end
  return regions
end

local function find_conflict_region(bufnr)
  local regions = M.build_regions(bufnr)
  if not regions or #regions == 0 then
    return nil
  end
  local cur = api.nvim_win_get_cursor(0)[1]
  for _, r in ipairs(regions) do
    if cur >= r.start and cur <= r.finish then
      return {
        start_idx = r.start,
        base_idx = r.base,
        sep_idx = r.sep,
        end_idx = r.finish,
        lines = api.nvim_buf_get_lines(bufnr, 0, -1, false),
      }
    end
  end
  return nil
end

function M.accept(which)
  local bufnr = api.nvim_get_current_buf()
  local region = find_conflict_region(bufnr)
  if not region then
    vim.notify("[lazyconflict] No conflict region found under cursor", vim.log.levels.INFO)
    return
  end
  local start_line = region.start_idx + 1
  local ours_end = (region.base_idx or region.sep_idx) - 1
  local theirs_start = region.sep_idx + 1
  local theirs_end = region.end_idx - 1
  local ours_lines = slice(region.lines, start_line, math.max(ours_end, start_line - 1))
  local theirs_lines = slice(region.lines, theirs_start, math.max(theirs_end, theirs_start - 1))
  local replacement = {}
  if which == "ours" then
    replacement = ours_lines
  elseif which == "theirs" then
    replacement = theirs_lines
  elseif which == "both" then
    vim.list_extend(replacement, ours_lines)
    vim.list_extend(replacement, theirs_lines)
  elseif which == "none" then
    replacement = {}
  elseif which == "all_ours" then
    local all_regions = M.build_regions(bufnr)
    -- 後ろから処理しないと行番号がずれる
    for i = #all_regions, 1, -1 do
      local r = all_regions[i]
      local r_start_line = r.start + 1
      local r_ours_end = (r.base or r.sep) - 1
      local r_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local r_replacement = slice(r_lines, r_start_line, math.max(r_ours_end, r_start_line - 1))
      api.nvim_buf_set_lines(bufnr, r.start - 1, r.finish, false, r_replacement)
    end
    if state.debounced_check then state.debounced_check() else M.check() end
    return
  elseif which == "all_theirs" then
    local all_regions = M.build_regions(bufnr)
    for i = #all_regions, 1, -1 do
      local r = all_regions[i]
      local r_theirs_start = r.sep + 1
      local r_theirs_end = r.finish - 1
      local r_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local r_replacement = slice(r_lines, r_theirs_start, math.max(r_theirs_end, r_theirs_start - 1))
      api.nvim_buf_set_lines(bufnr, r.start - 1, r.finish, false, r_replacement)
    end
    if state.debounced_check then state.debounced_check() else M.check() end
    return
  elseif which == "cursor" then
    -- カーソル位置が ours/base/theirs のどこにあるか判定して採用
    local cursor_lnum = api.nvim_win_get_cursor(0)[1]
    if cursor_lnum >= region.start and cursor_lnum < (region.base or region.sep) then
      replacement = ours_lines
    elseif cursor_lnum > region.sep and cursor_lnum < region.finish then
      replacement = theirs_lines
    elseif region.base and cursor_lnum > region.base and cursor_lnum < region.sep then
      -- base を採用する場合 (base change の内容を取得する必要がある)
      local base_start = region.base + 1
      local base_end = region.sep - 1
      replacement = slice(region.lines, base_start, math.max(base_end, base_start - 1))
    else
      -- マーカー行上や範囲外なら ours をデフォルトとするか、何もしないか
      -- ここでは ours を採用する挙動にしておく
      replacement = ours_lines
    end
  else
    vim.notify("[lazyconflict] Unknown choice: " .. tostring(which), vim.log.levels.ERROR)
    return
  end
  api.nvim_buf_set_lines(bufnr, region.start_idx - 1, region.end_idx, false, replacement)
  if state.debounced_check then
    state.debounced_check()
  else
    M.check()
  end
end

local function jump(direction)
  local bufnr = api.nvim_get_current_buf()
  local regions = M.build_regions(bufnr)

  -- 現在のバッファにコンフリクトがある場合、まずはバッファ内移動を試みる
  if regions and #regions > 0 then
    local cursor = api.nvim_win_get_cursor(0)[1]
    local target
    if direction == "next" then
      for _, r in ipairs(regions) do
        if r.start > cursor then
          target = r.start
          break
        end
      end
    else
      for i = #regions, 1, -1 do
        local r = regions[i]
        if r.finish < cursor then
          target = r.start
          break
        end
      end
    end

    -- バッファ内で移動先が見つかればそこにジャンプ
    if target then
      api.nvim_win_set_cursor(0, { target, 0 })
      return
    end
  end

  -- バッファ内で見つからない（端まで来た）場合、次の/前のコンフリクトファイルへ移動
  local current_file = normalize_path(api.nvim_buf_get_name(bufnr), state.cwd)
  local conflict_files = {}
  for file, info in pairs(state.conflicts) do
    if info.items and #info.items > 0 then
      table.insert(conflict_files, file)
    end
  end
  table.sort(conflict_files)

  if #conflict_files == 0 then
    vim.notify("[lazyconflict] No conflicts found globally", vim.log.levels.INFO)
    return
  end

  local current_idx = 0
  for i, file in ipairs(conflict_files) do
    if file == current_file then
      current_idx = i
      break
    end
  end

  local next_file
  if direction == "next" then
    local next_idx = current_idx + 1
    if next_idx > #conflict_files then
      next_idx = 1 -- 最後のファイルの次は最初のファイルへ（循環）
    end
    next_file = conflict_files[next_idx]
  else
    local next_idx = current_idx - 1
    if next_idx < 1 then
      next_idx = #conflict_files -- 最初のファイルの次は最後のファイルへ（循環）
    end
    next_file = conflict_files[next_idx]
  end

  if next_file then
    vim.cmd("edit " .. fn.fnameescape(next_file))
    -- ファイルを開いた後、そのファイルの最初/最後のコンフリクトへジャンプ
    local new_bufnr = api.nvim_get_current_buf()
    -- 少し待たないとバッファ読み込みが間に合わない場合があるかもだが、editは同期的なはず
    local new_regions = M.build_regions(new_bufnr)
    if new_regions and #new_regions > 0 then
      local target_line
      if direction == "next" then
        target_line = new_regions[1].start
      else
        target_line = new_regions[#new_regions].start
      end
      api.nvim_win_set_cursor(0, { target_line, 0 })
    end
  end
end

function M.jump_next()
  jump("next")
end

function M.jump_prev()
  jump("prev")
end

function M.enable()
  state.enabled = true
  M.check()
end

function M.disable()
  state.enabled = false
  if state.job then
    pcall(fn.jobstop, state.job)
    state.job = nil
  end
  set_conflicts({})
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", default_config, opts or {})
  state.enabled = true
  state.debounced_check = debounce(M.check, state.config.detection.debounce_ms)
  ensure_highlights()
  ensure_commands()
  if state.config.detection.auto then
    local group = ensure_augroup()
    api.nvim_clear_autocmds({ group = group })
    api.nvim_create_autocmd(state.config.detection.autocmds, {
      group = group,
      callback = function()
        state.debounced_check()
      end,
    })
    api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
      group = group,
      callback = function(args)
        M.apply_buffer(args.buf)
      end,
    })
  end
  M.check()
end

return M
