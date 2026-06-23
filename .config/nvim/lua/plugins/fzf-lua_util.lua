local M = {}
local fzf_lua = require("fzf-lua")
local ui_select_registered = false

-- ------------------------------------------------------------------
-- default settings
-- ------------------------------------------------------------------

local defaultActions = {
  ["enter"] = fzf_lua.actions.file_edit,
  ["ctrl-s"] = fzf_lua.actions.file_split,
  ["ctrl-v"] = fzf_lua.actions.file_vsplit,
}

local middleFloatWinOpts = {
  split = false,
  border = "single",
  height = 0.6,
  width = 0.6,
  row = 0.5,
  preview = {
    border = "single"
  }
}

local fullFloatWinOpts = {
  split = false,
  border = "single",
  height = 0.9,
  width = 0.9,
  row = 0.5,
  preview = {
    border = "single"
  }
}

-- ------------------------------------------------------------------
-- Utils
-- ------------------------------------------------------------------

local getHomeName = function(path)
  local home_path = vim.fn.fnamemodify(path or vim.fn.getcwd(), ":~")

  if #home_path > 20 then
    home_path = vim.fn.pathshorten(home_path)
  end

  return home_path
end

local colorFilename = function(files)
  local cmd = 'echo "' .. table.concat(files, '\n') .. '" | xargs -d "\n" $XDG_CONFIG_HOME/nvim/bin/color-ls'
  local handle = io.popen(cmd)
  if handle then
    local result = handle:read("*all")
    handle:close()
    return vim.split(result, "\n", { trimempty = true })
  end
  return {}
end

local function getRootDir()
  local project = require("project")
  local rootDir = project.get_project_root()

  if rootDir ~= "" then
    local parts = vim.split(rootDir, "/", { plain = true })
    return parts[#parts]
  else
    return ""
  end
end

local function removeUnicodeUtf8(str)
  str = str:gsub("[\194-\244][\128-\191]*", "")
  return str
end

local function stripAnsi(str)
  return tostring(str or ""):gsub("\27%[[0-9;]*[A-Za-z]", "")
end

local function selectedPath(selected)
  return vim.trim(stripAnsi(selected and selected[1] or ""))
end

local function escapePattern(text)
  return text:gsub("([().%+%-*?[^$])", "%%%1")
end

local utilities = require"utilities"

---@return string|nil parent, table|nil meta for setup_parent_toggle
local function fzf_git_parent_bundle(dir)
  local ctx = utilities.git_parent_nav_context(dir)
  return ctx.parent, ctx.choose and { parent_choices = ctx.choose } or nil
end

local function setup_parent_toggle(opts, current_cwd, parent_git_root, reopen_fn, parent_meta)
  parent_meta = parent_meta or {}
  local parent_choices = parent_meta.parent_choices
  local from_dual = parent_choices and #parent_choices > 0
  local state_now = M._parent_toggle
  local can_toggle_or_go_parent = (state_now and state_now.parent == current_cwd) or parent_git_root or from_dual

  opts.actions = opts.actions or {}
  opts.actions["ctrl-t"] = can_toggle_or_go_parent and function(selected, fzf_opts)
    local state = M._parent_toggle
    if state and state.parent == current_cwd then
      M._parent_toggle = nil
      state.reopen(state.origin)
    elseif from_dual then
      vim.ui.select(parent_choices, utilities.git_parent_select_opts, function(choice)
        if choice then
          M._parent_toggle = {
            origin = current_cwd,
            parent = choice,
            reopen = reopen_fn,
          }
          reopen_fn(choice)
        end
      end)
    elseif parent_git_root then
      M._parent_toggle = {
        origin = current_cwd,
        parent = parent_git_root,
        reopen = reopen_fn,
      }
      reopen_fn(parent_git_root)
    end
  end or false

  if not can_toggle_or_go_parent then
    opts.fzf_opts = opts.fzf_opts or {}
    opts.fzf_opts["--bind"] = "ctrl-t:ignore"
  end
end

local function addPrefixAction(action, prefix)
  return function(selected, opts)
    for i, v in ipairs(selected) do
      selected[i] = prefix .. removeUnicodeUtf8(v)
    end
    action(selected, opts)
  end
end

local function copySelectedPathsToRegisterWithAt(selected)
  if not selected or #selected == 0 then
    vim.notify("No selection to copy", vim.log.levels.WARN)
    return
  end

  local entry_to_file = require("fzf-lua.path").entry_to_file
  local items = {}

  for _, s in ipairs(selected) do
    local ok, entry = pcall(entry_to_file, s)
    local path = nil
    if ok and entry and entry.path and entry.path ~= "" then
      path = entry.path
    else
      path = removeUnicodeUtf8(s)
    end

    if path and path ~= "" then
      table.insert(items, '@' .. path)
    end
  end

  if #items == 0 then
    vim.notify("No valid path to copy", vim.log.levels.WARN)
    return
  end

  local joined = table.concat(items, "\n")
  vim.fn.setreg('+', joined, 'l')
  vim.fn.setreg('\"', joined, 'l')

  if #items == 1 then
    vim.notify("Copied: " .. items[1], vim.log.levels.INFO)
  else
    vim.notify("Copied " .. tostring(#items) .. " paths to register +", vim.log.levels.INFO)
  end
end

local function extract_path_from_entry(entry_str)
  local function try_match(s)
    local patterns = {
      "([%w%._%+%-/\\~]+%.[%w%d]+:%d+:%d+)",
      "([%w%._%+%-/\\~]+%.[%w%d]+:%d+)",
      "([%w%._%+%-/\\~]+%.[%w%d]+)",
      "([%w%._%+%-/\\~]+)",
    }
    for _, pat in ipairs(patterns) do
      local m = s:match(pat)
      if m then return vim.trim(m) end
    end
    return nil
  end

  local raw = tostring(entry_str or "")
  local matched = try_match(raw)
  if matched then return matched end
  local stripped = raw:gsub("^%s*%d+%.%s*", "")
  matched = try_match(stripped)
  if matched then return matched end
  return vim.trim(stripped)
end

local function normalize_ui_select_prompt(prompt)
  prompt = vim.trim(tostring(prompt or "Select"))
  if prompt == "" then
    prompt = "Select"
  end
  if prompt:match("[:：>]$") then
    return prompt .. " "
  end
  return prompt .. ": "
end

-- ------------------------------------------------------------------
-- init vim.ui.select
-- ------------------------------------------------------------------
M.register_ui_select = function()
  if ui_select_registered then
    return
  end

  fzf_lua.register_ui_select(function (opts)
    opts = opts or {}
    local is_toggle_menu = opts.kind == "toggle-menu"

    -- If previewer is builtin, wrap it to strip fzf index prefixes ("1. foo") before parsing
    if opts.previewer == "builtin" then
      opts.previewer = {
        _ctor = function()
          local Parent = require("fzf-lua.previewer.builtin").buffer_or_file
          local Previewer = Parent:extend()
          function Previewer:parse_entry(entry_str)
            local path = extract_path_from_entry(entry_str)
            return Parent.parse_entry(self, path)
          end
          return Previewer
        end,
      }
    end

    opts.prompt = normalize_ui_select_prompt(opts.prompt)
    opts.winopts = {
      height = is_toggle_menu and 0.34 or 0.4,
      width = is_toggle_menu and 0.46 or 0.6,
      row = 0.5,
      split = false,
      border = "single",
      preview = {
        border = "single",
        hidden = true
      }
    }
    if is_toggle_menu then
      opts.fzf_opts = opts.fzf_opts or {}
      opts.fzf_opts["--tiebreak"] = "begin,index"
    end
    return opts
  end)

  ui_select_registered = true
end

M.register_ui_select()

-- ------------------------------------------------------------------
-- Files Enhanced
-- ------------------------------------------------------------------

local getFileOpt = function (cwd, parent_git_root, parent_meta)
  local opts = {}
  local current_cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("/$", "")

  opts.cwd = current_cwd
  opts.multiprocess = false
  opts.prompt = getHomeName(current_cwd) .. ' >'
  opts.previewer = "builtin"
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--scheme"] = "history",
    ["--tiebreak"] = "index",
    ["--no-unicode"] = "",
  }

  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
    ['ctrl-x'] = {
      function(selected)
        for _, f in ipairs(selected) do
          print("deleting:", f)
          vim.fn.delete(removeUnicodeUtf8(f))
        end
      end,
      fzf_lua.actions.resume
    },
    ["ctrl-s"] = function(selected)
      copySelectedPathsToRegisterWithAt(selected)
    end,
  })

  setup_parent_toggle(opts, current_cwd, parent_git_root, function(dir)
    M.fzf_files_for_dir(dir)
  end, parent_meta)

  opts.file_icons = true
  opts.git_icons = true
  opts.fn_transform = function(x)
    return fzf_lua.make_entry.file(x, {file_icons=true, color_icons=true})
  end

  return opts
end

M.fzf_files = function(opts)
  local cwd = vim.fn.getcwd()
  local parent, meta = fzf_git_parent_bundle(cwd)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix --follow --hidden --exclude .git --type f . " ..
    "-E .git -E '*.psd' -E '*.png' -E '*.jpg' -E '*.pdf' " ..
    "-E '*.ai' -E '*.jfif' -E '*.jpeg' -E '*.gif' " ..
    "-E '*.eps' -E '*.svg' -E '*.JPEM' -E '*.mp4' | " ..
    "eza -1 -sold --color=always --no-quotes",
    getFileOpt(cwd, parent, meta)
  )
end

M.fzf_all_files = function(opts)
  local cwd = vim.fn.getcwd()
  local parent, meta = fzf_git_parent_bundle(cwd)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix -I --type file --follow --hidden --exclude .git | " ..
    "eza -1 -sold --color=always --no-quotes",
    getFileOpt(cwd, parent, meta)
  )
end

M.fzf_files_for_dir = function(dir)
  local search_dir
  if dir and vim.fn.isdirectory(dir) == 1 then
    search_dir = dir
  else
    local current_file_dir = vim.fn.expand('%:p:h')
    if current_file_dir ~= '' and vim.fn.isdirectory(current_file_dir) == 1 then
      search_dir = current_file_dir
    else
      search_dir = vim.loop.cwd()
    end
  end

  search_dir = vim.fn.fnamemodify(search_dir, ":p")

  local fd_cmd = "fd --strip-cwd-prefix --follow --hidden --exclude .git --type f"
  local exclusions = " -E .git -E '*.psd' -E '*.png' -E '*.jpg' -E '*.pdf' " ..
    "-E '*.ai' -E '*.jfif' -E '*.jpeg' -E '*.gif' " ..
    "-E '*.eps' -E '*.svg' -E '*.JPEM' -E '*.mp4'"
  local full_cmd = "cd " .. vim.fn.shellescape(search_dir) .. " && " ..
    fd_cmd .. exclusions .. " | " ..
    "eza -1 -sold --color=always --no-quotes"

  local parent, meta = fzf_git_parent_bundle(search_dir)
  fzf_lua.fzf_exec(full_cmd, getFileOpt(search_dir, parent, meta))
end

vim.cmd([[command! -nargs=* FilesLua lua require"plugins.fzf-lua_util".fzf_files()]])
vim.cmd([[command! -nargs=* AllFilesLua lua require"plugins.fzf-lua_util".fzf_all_files()]])
vim.cmd([[command! -nargs=* CurrentFilesLua lua require"plugins.fzf-lua_util".fzf_files_for_dir()]])

-- ------------------------------------------------------------------
-- Directories Enhanced
-- ------------------------------------------------------------------

local getDirOpt = function ()
  local opts = {}
  opts.prompt = 'Directories >'
  opts.preview = {
    type = "cmd",
    fn = function (items)
      -- print(vim.inspect(item[0]))
      return string.format("tree -C %s", items[1])
    end
  }
  opts.actions =  {
    ["enter"] = function(selected)
      require("oil").open(selectedPath(selected))
    end,
    ["ctrl-s"] = function(selected)
      vim.cmd("vsplit")
      require("oil").open(selectedPath(selected))
    end,
    ["ctrl-t"] = {
      function(selected)
        require('plugins.fzf-lua_util').fzf_files_for_dir(selected[1])
      end
    },
    ["ctrl-y"] = {
      function(selected)
        copySelectedPathsToRegisterWithAt(selected)
      end
    }
  }
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--scheme"] = "history",
    ["--tiebreak"] = "index",
    ["--no-unicode"] = "",
    ["--preview-window"] = "noborder"
  }
  opts.winopts = middleFloatWinOpts

  return opts
end

M.fzf_dirs = function(opts)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix --type directory --follow --hidden --color=always --exclude .git",
    getDirOpt()
  )
end

local function path_distance_score(base, target)
  local function split(path)
    return vim.tbl_filter(function(p) return p ~= "" end, vim.split(path, '/'))
  end

  local base_parts = split(vim.fn.fnamemodify(base, ':p'))
  local target_parts = split(vim.fn.fnamemodify(target, ':p'))

  local common = 0
  for i = 1, math.min(#base_parts, #target_parts) do
    if base_parts[i] == target_parts[i] then
      common = common + 1
    else
      break
    end
  end

  return (#base_parts - common) + (#target_parts - common)
end

M.fzf_dirs_smart = function(opts)
  local current_file = vim.api.nvim_buf_get_name(0)
  local base_dir = vim.fn.fnamemodify(current_file ~= "" and current_file or vim.fn.getcwd(), ":p:h")
  if type(base_dir) == "string" and base_dir:find("^oil://") then
    base_dir = base_dir:gsub("^oil://", "")
  end

  -- fdでディレクトリ取得
  require('plenary.job'):new({
    command = "fd",
    args = {
      "--strip-cwd-prefix",
      "--type", "directory",
      "--follow",
      "--hidden",
      "--exclude", ".git",
    },
    cwd = vim.fn.getcwd(),
    on_exit = function(j, return_val)
      if return_val ~= 0 then
        vim.schedule(function()
          vim.notify("fd failed", vim.log.levels.ERROR)
        end)
        return
      end

      local dirs = j:result()

      table.sort(dirs, function(a, b)
        return path_distance_score(base_dir, a) < path_distance_score(base_dir, b)
      end)

      dirs = #dirs > 1000 and dirs or colorFilename(dirs)

      vim.schedule(function()
        fzf_lua.fzf_exec(
          dirs,
          getDirOpt()
        )
      end)
    end
  }):start()
end

local function enhancd_log_candidates()
  local candidates = {}
  local seen = {}

  local function add(path)
    path = tostring(path or "")
    if path == "" or seen[path] then
      return
    end
    seen[path] = true
    candidates[#candidates + 1] = path
  end

  add(vim.env.ENHANCD_LOG)
  if vim.env.ENHANCD_DIR and vim.env.ENHANCD_DIR ~= "" then
    add(vim.env.ENHANCD_DIR .. "/enhancd.log")
  end
  if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
    add(vim.env.XDG_CONFIG_HOME .. "/enhancd/enhancd.log")
  end
  add(vim.fn.expand("~/.config/enhancd/enhancd.log"))

  return candidates
end

local function enhancd_history_dirs()
  local log_path = nil
  for _, path in ipairs(enhancd_log_candidates()) do
    if vim.fn.filereadable(path) == 1 then
      log_path = path
      break
    end
  end
  if not log_path then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, log_path)
  if not ok or type(lines) ~= "table" then
    return {}
  end

  local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
  local dirs = {}
  local seen = {}
  for idx = #lines, 1, -1 do
    local path = vim.trim(lines[idx] or "")
    if path ~= "" then
      path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
      if path ~= cwd and not seen[path] and vim.fn.isdirectory(path) == 1 then
        seen[path] = true
        dirs[#dirs + 1] = path
      end
    end
  end

  return dirs
end

local function color_enhancd_dir(path)
  path = tostring(path or "")
  return path:gsub("([^/]+)$", "\27[1;34m%1\27[0m")
end

local function enhancd_selected_paths(selected)
  local paths = {}
  for _, item in ipairs(selected or {}) do
    local path = vim.trim(stripAnsi(item):gsub("\r", ""))
    if path ~= "" then
      paths[#paths + 1] = path
    end
  end
  return paths
end

local function copy_enhancd_paths(selected)
  local paths = enhancd_selected_paths(selected)
  if #paths == 0 then
    vim.notify("No directory to copy", vim.log.levels.WARN)
    return
  end

  local joined = table.concat(paths, "\n")
  vim.fn.setreg("+", joined)
  vim.fn.setreg("\"", joined)
  vim.notify(#paths == 1 and ("Copied: " .. paths[1]) or ("Copied " .. #paths .. " directories"), vim.log.levels.INFO)
end

local function insert_enhancd_path(selected)
  local paths = enhancd_selected_paths(selected)
  local path = paths[#paths]
  if not path or path == "" then
    vim.notify("No directory to insert", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_put({ path }, "c", true, true)
end

local function getEnhancdDirOpt()
  local opts = {}
  opts.prompt = "enhancd >"
  opts.preview = {
    type = "cmd",
    fn = function(items)
      local path = enhancd_selected_paths(items)[1]
      if not path or path == "" then
        return ""
      end
      return string.format("tree -C %s | head -200", vim.fn.shellescape(path))
    end,
  }
  opts.actions = {
    ["enter"] = insert_enhancd_path,
    ["ctrl-y"] = copy_enhancd_paths,
  }
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--ansi"] = "",
    ["--scheme"] = "history",
    ["--tiebreak"] = "index",
    ["--no-unicode"] = "",
    ["--preview-window"] = "noborder",
  }
  opts.winopts = middleFloatWinOpts
  opts.fn_transform = color_enhancd_dir

  return opts
end

M.fzf_enhancd_dirs = function()
  local dirs = enhancd_history_dirs()
  if #dirs == 0 then
    vim.notify("enhancd history has no available directories", vim.log.levels.WARN)
    return
  end

  fzf_lua.fzf_exec(dirs, getEnhancdDirOpt())
end

vim.cmd([[command! EnhancdLua lua require"plugins.fzf-lua_util".fzf_enhancd_dirs()]])

-- ------------------------------------------------------------------
-- RG grep
-- ------------------------------------------------------------------

local getRipgrepOpts = function (isText, isAll, cwd, parent_git_root, parent_meta)
  isText = isText == nil and false or isText
  isAll = isAll == nil and false or isAll

  local current_cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("/$", "")

  local opts = {}
  opts.prompt = '>'
  opts.cwd = current_cwd
  opts.previewer = "builtin"
  opts.no_header_i = true
  opts.RIPGREP_CONFIG_PATH = vim.env.RIPGREP_CONFIG_PATH
  opts.winopts = {
    preview = {
      hidden = true
    },
    treesitter = {
      enabled = true,
    },
  }
  opts.fzf_opts = {
    ["--multi"] = "",
    ["--no-unicode"] = "",
  }

  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["enter"] = fzf_lua.actions.file_edit_or_qf,
    ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
    ["ctrl-O"] = {
      exec_silent = true,
      fn = function (selected)
        if not selected or #selected == 0 then return end
        local entry = require('fzf-lua.path').entry_to_file(selected[1])

        if not entry.path or entry.path == "" then
          vim.notify("fzf-lua: No valid path selected", vim.log.levels.WARN)
          return
        end

        vim.cmd("tabedit +" .. entry.line .. " " .. entry.path)
      end
    },
  })

  setup_parent_toggle(opts, current_cwd, parent_git_root, function(dir)
    M.fzf_ripgrep_for_dir(dir, isText, isAll)
  end, parent_meta)

  if isText then
    opts.fzf_opts["--delimiter"] = ":"
    opts.fzf_opts["--nth"] = "-1"
  else
    opts.fzf_opts["--delimiter"] = ":"
    opts.fzf_opts["--nth"] = "-1,1..-2"
  end

  if isAll then
    opts.rg_opts = "--column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always --glob=!.git "
  else
    opts.rg_opts = "--column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git "
  end

  return opts
end

M.fzf_ripgrep = function(args)
  local cwd = vim.fn.getcwd()
  local parent, meta = fzf_git_parent_bundle(cwd)
  fzf_lua.grep(vim.tbl_deep_extend("force", { search = args }, getRipgrepOpts(nil, nil, cwd, parent, meta)))
end

M.fzf_ripgrep_for_dir = function(dir, isText, isAll)
  local parent, meta = fzf_git_parent_bundle(dir)
  fzf_lua.grep(vim.tbl_deep_extend("force", { search = "" }, getRipgrepOpts(isText, isAll, dir, parent, meta)))
end

M.fzf_ripgrep_text = function(args)
  local cwd = vim.fn.getcwd()
  local parent, meta = fzf_git_parent_bundle(cwd)
  fzf_lua.grep(vim.tbl_deep_extend("force", { search = args }, getRipgrepOpts(true, nil, cwd, parent, meta)))
end

M.fzf_all_ripgrep = function(args)
  local cwd = vim.fn.getcwd()
  local parent, meta = fzf_git_parent_bundle(cwd)
  fzf_lua.grep(vim.tbl_deep_extend("force", { search = args }, getRipgrepOpts(false, true, cwd, parent, meta)))
end

vim.cmd([[command! -nargs=* RgLua lua require"plugins.fzf-lua_util".fzf_ripgrep(<q-args>)]])
vim.cmd([[command! -nargs=* RgTextLua lua require"plugins.fzf-lua_util".fzf_ripgrep_text(<q-args>)]])
vim.cmd([[command! -nargs=* AllRgLua lua require"plugins.fzf-lua_util".fzf_all_ripgrep(<q-args>)]])

-- Migemo grep: prompt for romaji, convert to migemo pattern, then grep
M.fzf_ripgrep_migemo = function()
  vim.ui.input({ prompt = "Migemo grep> " }, function(input)
    if not input or input == "" then return end
    local pattern = require("migemo").pattern(input, "egrep") or input
    local cwd = vim.fn.getcwd()
    local parent, meta = fzf_git_parent_bundle(cwd)
    fzf_lua.grep(
      vim.tbl_deep_extend("force", { search = pattern, no_esc = true }, getRipgrepOpts(nil, nil, cwd, parent, meta))
    )
  end)
end

vim.cmd([[command! MigemoRg lua require"plugins.fzf-lua_util".fzf_ripgrep_migemo()]])

-- ------------------------------------------------------------------
-- Ast grep
-- ------------------------------------------------------------------
--
local getAstGrepOpts = function ()
  local opts = {}
  opts.prompt = '>'
  opts.previewer = "builtin"
  opts.winopts = {
    preview = {
      hidden = false
    },
  }
  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["enter"] = fzf_lua.actions.file_edit_or_qf,
    ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
  })
  opts.fzf_opts = {
    ["--multi"] = "",
    ["--no-unicode"] = "",
  }

  opts.fzf_opts["--delimiter"] = ":"
  opts.fzf_opts["--with-nth"] = "{3..}"

  return opts
end

M.fzf_ast_grep = function(args)
  local lang = args[1] or vim.bo.filetype
  fzf_lua.fzf_live(
    "ast-grep --color always --no-ignore hidden --lang " .. lang ..
    " --heading always --pattern <query> 2>/dev/null | " ..
    "awk '!/│/ { filename=$0; print \"││\"filename } /│/ { print filename\"│\"$0 }' | sed 's/│/:/g'",
    getAstGrepOpts()
      )
end

M.fzf_ast_grep_txt = function(args)
  local lang = args[1] or vim.bo.filetype
  fzf_lua.fzf_live(
    "ast-grep --color always --no-ignore hidden --lang " .. lang ..
    " --pattern <query> 2>/dev/null",
    getAstGrepOpts()
      )
end

fzf_lua.ast_grep = M.fzf_ast_grep
vim.cmd([[command! -nargs=* AstGrepLua lua require"plugins.fzf-lua_util".fzf_ast_grep(<q-args>)]])
vim.cmd([[command! -nargs=* AstGrepTxtLua lua require"plugins.fzf-lua_util".fzf_ast_grep_txt(<q-args>)]])

-- ------------------------------------------------------------------
-- MRU Navigator
-- ------------------------------------------------------------------

local getMruOpts = function (func, name)
  local opts = {}
  opts.prompt = name .. " " .. getHomeName() .. ' >'
  opts.previewer = "builtin"
  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["ctrl-t"] = { function() func() end },
    ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
  })
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--tiebreak"] = "index",
    ["--scheme"] = "history",
    ["--no-unicode"] = "",
  }

  return opts
end

-- MRU ファイルを取得する関数
local mruFilesForCwd = function(flag, notCwd)
  notCwd = notCwd or false

  local result = vim.fn.systemlist("sed -n '2,$p' $XDG_CACHE_HOME/neomru/" .. flag)
  local cwd = escapePattern(vim.fn.getcwd())

  return vim.fn.map(vim.fn.filter(
    result,
    function(_, val)
      return (val:match("^" .. cwd) or notCwd) and not val:match("__Tagbar__|\\[YankRing]|fugitive:|NERD_tree|^/tmp/|.git")
    end
  ),
    function(_, val) return vim.fn.fnamemodify(val, ":p:.") end
  )
end

M.fzf_mru_files = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("file", true)),
    getMruOpts(M.fzf_mrw_files, "MRU ALL")
  )
end

M.fzf_mrw_files = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("write", true)),
    getMruOpts(M.fzf_mru_files, "MRW ALL")
  )
end

M.fzf_mru_files_cwd = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("file")),
    getMruOpts(M.fzf_mrw_files_cwd, "MRU")
  )
end

M.fzf_mrw_files_cwd = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("write")),
    getMruOpts(M.fzf_mru_files_cwd, "MRW")
  )
end

vim.cmd([[command! -nargs=* MruFilesCdwLua lua require"plugins.fzf-lua_util".fzf_mru_files_cwd()]])
vim.cmd([[command! -nargs=* MrwWritesCdwLua lua require"plugins.fzf-lua_util".fzf_mrw_files_cwd()]])
vim.cmd([[command! -nargs=* MruFilesLua lua require"plugins.fzf-lua_util".fzf_mru_files()]])
vim.cmd([[command! -nargs=* MrwWritesLua lua require"plugins.fzf-lua_util".fzf_mrw_files()]])

-- ------------------------------------------------------------------
-- harpoon
-- ------------------------------------------------------------------

local convertHarpoonItem = function (itemString)
  local table = vim.split(itemString, ":")
  return {
    value = table[1],
    context = {
      row = tonumber(table[2]),
      col = tonumber(table[3])
    }
  }
end

local setAnsi = function(texts)
  return vim.tbl_map(function (text)
    local s = vim.split(text, ":")
    s[1] = "\27[38;2;115;218;202m" .. s[1] .. "\27[0m"
    return table.concat(s, ":")
  end, texts)
end

M.fzf_harpoon = function(winopts)
  local harpoon = require("harpoon")
  winopts = winopts or fullFloatWinOpts

  fzf_lua.fzf_exec(
    setAnsi(harpoon:list("multiple"):display()),
    {
      prompt = "Harpoon >",
      previewer = "builtin",
      actions =   vim.tbl_deep_extend("force", defaultActions, {
        ["ctrl-d"] = {
          function(selected)
            for _, t in ipairs(selected) do
              harpoon:list("multiple"):remove(convertHarpoonItem(t))
            end
            M.fzf_harpoon()
          end
        },
        ["ctrl-t"] = { function() M.fzf_harpoon(fullFloatWinOpts) end },
        ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
      }),
      fzf_opts = {
        ["--multi"] = "",
        ["--scheme"] = "history",
        ["--no-unicode"] = "",
      },
      winopts =  winopts,
      winopts_fn= function(opts)
        -- bufferだけに影響が収まるのか未調査
        harpoon:extend({
          REMOVE = function(obj)
            local reindexed_items = {}
            local keys = {}

            for k in pairs(obj.list.items) do
              if type(k) == "number" then
                table.insert(keys, k)
              end
            end
            table.sort(keys)

            for _, k in ipairs(keys) do
              table.insert(reindexed_items, obj.list.items[k])
            end

            obj.list.items = reindexed_items
            obj.list._length = #reindexed_items
          end
        })
      end
    }
  )
end

vim.cmd([[command! -nargs=* HarpoonLua lua require"plugins.fzf-lua_util".fzf_harpoon()]])

-- ------------------------------------------------------------------
-- JunkFile
-- ------------------------------------------------------------------

local getJunkFileOpt = function ()
  local workDir = vim.fn.expand("$XDG_CACHE_HOME") .. "/junkfile/" .. getRootDir() .. "/"
  local previewer = require("fzf-lua.previewer.builtin").buffer_or_file:extend()
  function previewer:new(o, opts, fzf_win)
    previewer.super.new(self, o, opts, fzf_win)
    setmetatable(self, previewer)
    return self
  end
  function previewer:parse_entry(entry_str)
    local path = require "fzf-lua.path"
    return path.entry_to_file(workDir .. removeUnicodeUtf8(entry_str))
  end

  local opts = {}
  opts.multiprocess = false
  opts.prompt = 'Memo >'
  opts.previewer = previewer
  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["enter"] = addPrefixAction(fzf_lua.actions.file_edit, workDir),
    ['ctrl-x'] = {
      function(selected)
        print("deleting:", selected)
        vim.fn.delete(removeUnicodeUtf8(workDir .. selected))
      end,
      fzf_lua.actions.resume
    }
  })
  opts.file_icons = true
  opts.git_icons = true
  opts.fn_transform = function(x)
    return fzf_lua.make_entry.file(x, {file_icons=true, color_icons=true})
  end
  opts.fzf_opts = {
    ["--multi"] = "",
    ["--ansi"] = "",
    ["--no-unicode"] = "",
  }

  return opts
end

M.fzf_junkfiles = function(opts)
  local junkDir = vim.fn.expand("$XDG_CACHE_HOME") .. "/junkfile/" .. getRootDir() .. "/"

  fzf_lua.fzf_exec(
    "rg --column -n --hidden --ignore-case --color=always '' " .. junkDir ..
    " | sed -e 's%" .. junkDir .. "%%g'",
    getJunkFileOpt()
  )
end

vim.cmd([[command! -nargs=* JunkFilesLua lua require"plugins.fzf-lua_util".fzf_junkfiles()]])

-- ------------------------------------------------------------------
-- font/emoji settings
-- ------------------------------------------------------------------

local getIconOpts = function (name)
  local opts = {}
  opts.prompt = name .. ' >'
  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["enter"] = function (selected, _)
      if #selected == 1 then
        local griff = vim.fn.split(selected[1], ":")[1]
        vim.api.nvim_put({griff}, 'c', true, true)
      else
        vim.notify('Please select only one item.', vim.log.levels.WARN)
      end
    end,
  })
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--preview-window"] = "hidden",
    ["--tiebreak"] = "chunk",
    ["--ansi"] = true,
  }

  return opts
end

M.fzf_nerd_fonts = function(opts)
  fzf_lua.fzf_exec(
    require"sources.nerdfont".get(),
    getIconOpts('NerdFonts')
  )
end

M.fzf_emoji = function(opts)
  fzf_lua.fzf_exec(
    require"sources.emoji".get(),
    getIconOpts('Emoji')
  )
end

fzf_lua.nerd_fonts = M.fzf_nerd_fonts
fzf_lua.emoji = M.fzf_emoji
vim.cmd([[command! -nargs=* NerdFontLua lua require"plugins.fzf-lua_util".fzf_nerd_fonts()]])
vim.cmd([[command! -nargs=* EmojiLua lua require"plugins.fzf-lua_util".fzf_emoji()]])

-- ------------------------------------------------------------------
-- lazyagent
-- ------------------------------------------------------------------

local getAgentOpts = function (cacheDir)
  local opts = {}
  opts.prompt = 'lazyagent >'
  opts.previewer = "builtin"
  opts.cwd = cacheDir
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--ansi"] = true,
  }

  return opts
end

M.fzf_lazyagent = function()
  local cache = require"lazyagent.logic.cache"
  local cacheDir = cache.get_conversation_dir()
  local conversations = vim.tbl_map(function(entry)
    return entry.name
  end, cache.list_conversation_files() or {})

  fzf_lua.fzf_exec(
    conversations,
    getAgentOpts(cacheDir)
  )
end

vim.cmd([[command! -nargs=* LazyAgentLua lua require"plugins.fzf-lua_util".fzf_lazyagent()]])

-- ------------------------------------------------------------------
-- akin (path similarity)
-- ------------------------------------------------------------------

---@param line string
---@return string
local function akin_line_to_relpath(line)
  local path = line:match("^%d+%.%d+%s+(.+)$")
  return vim.trim(path or line)
end

---@param base string
---@param target_basename string
local function getAkinOpts(base, target_basename)
  local opts = {}
  opts.cwd = base
  opts.multiprocess = false
  opts.prompt = "akin " .. target_basename .. " >"
  opts.previewer = "builtin"
  opts.file_icons = true
  opts.git_icons = true
  opts.fn_transform = function(line)
    local relpath = akin_line_to_relpath(line)
    return fzf_lua.make_entry.file(relpath, { file_icons = true, color_icons = true })
  end
  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
  })
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--scheme"] = "history",
    ["--tiebreak"] = "index",
    ["--no-unicode"] = "",
  }
  return opts
end

---@param user_opts? { target?: string, top?: number, threshold?: number }
M.fzf_akin = function(user_opts)
  user_opts = user_opts or {}
  if vim.fn.executable("akin") ~= 1 then
    vim.notify("akin が PATH にありません", vim.log.levels.ERROR)
    return
  end

  local target = user_opts.target
  if not target or target == "" then
    target = vim.api.nvim_buf_get_name(0)
  else
    target = vim.fn.fnamemodify(vim.fn.expand(target), ":p")
  end

  if target == "" or vim.fn.filereadable(target) ~= 1 then
    vim.notify("akin: 有効なファイルを開くか、引数でパスを指定してください", vim.log.levels.WARN)
    return
  end

  target = vim.fn.fnamemodify(target, ":p")

  local project = require("project")
  local base = project.get_project_root()
  if base == "" then
    base = vim.fn.getcwd()
  end
  base = vim.fn.fnamemodify(base, ":p"):gsub("/$", "")

  local top = user_opts.top or 50
  local shell = string.format(
    "cd %s && akin -n %d%s %s",
    vim.fn.shellescape(base),
    top,
    user_opts.threshold and (" -t " .. tostring(user_opts.threshold)) or "",
    vim.fn.shellescape(target)
  )

  fzf_lua.fzf_exec(shell, getAkinOpts(base, vim.fn.fnamemodify(target, ":t")))
end

vim.cmd(
  [[command! -nargs=* AkinLua lua require"plugins.fzf-lua_util".fzf_akin({ target = vim.fn.expand(<q-args>) })]]
)

-- ------------------------------------------------------------------
-- laravel.nvim override
-- ------------------------------------------------------------------

local function goto_laravel_extension_context()
  local ft = vim.bo.filetype
  if ft ~= "php" and ft ~= "blade" then
    return false
  end

  local ok_livewire, livewire = pcall(require, "laravel_extension.features.livewire")
  if ok_livewire and livewire.goto_livewire_at_cursor({ notify = false }) then
    return true
  end

  local ok_component, component = pcall(require, "laravel_extension.features.component")
  if ok_component and component.goto_component_at_cursor({ notify = false }) then
    return true
  end

  local ok_view, view = pcall(require, "laravel_extension.features.view")
  if ok_view and view.goto_view_at_cursor({ notify = false, fallback_to_laravel = false }) then
    return true
  end

  return false
end

local function goto_laravel_nvim_context()
  if not (_G.laravel_nvim and _G.laravel_nvim.is_laravel_project) then
    return false
  end

  local ok_nav, navigate = pcall(require, "laravel.navigate")
  if not ok_nav or type(navigate.is_laravel_navigation_context) ~= "function" then
    return false
  end

  local ok_context, is_context = pcall(navigate.is_laravel_navigation_context)
  if not ok_context or not is_context or type(navigate.goto_laravel_string) ~= "function" then
    return false
  end

  local ok_goto, result = pcall(navigate.goto_laravel_string)
  return ok_goto and result ~= false
end

local function goto_lsp_definitions()
  if vim.lsp.buf.definition then
    require("fzf-lua.cmd").run_command("lsp_definitions")
  else
    vim.notify("No LSP definition available", vim.log.levels.WARN)
  end
end

M.fzf_laravel = function()
  if goto_laravel_extension_context() or goto_laravel_nvim_context() then
    return
  end

  goto_lsp_definitions()
end

vim.cmd([[command! -nargs=* LaravelLua lua require"plugins.fzf-lua_util".fzf_laravel()]])

-- ------------------------------------------------------------------
-- lsp settings
-- ------------------------------------------------------------------

-- in /home/aikawa/dotfiles/.config/nvim/lua/lsp/default.lua

return M
