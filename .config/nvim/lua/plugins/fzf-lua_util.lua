local M = {}
local fzf_lua = require("fzf-lua")

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

local getHomeName = function()
  local path = vim.fn.getcwd()
  local home_path = vim.fn.fnamemodify(path, ":~")

  if #home_path > 20 then
    home_path = vim.fn.pathshorten(home_path)
  end

  return home_path
end

local colorFilename = function(files)
  local cmd = 'echo -e "' .. table.concat(files, '\n') .. '" | xargs -d "\n" $XDG_CONFIG_HOME/nvim/bin/color-ls'
  local handle = io.popen(cmd)
  if handle then
    local result = handle:read("*all")
    handle:close()
    return vim.split(result, "\n", { trimempty = true })
  end
  return {}
end

local function getRootDir()
  local project = require("project.api")
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

local function escapePattern(text)
  return text:gsub("([().%+%-*?[^$])", "%%%1")
end

local function addPrefixAction(action, prefix)
  return function(selected, opts)
    for i, v in ipairs(selected) do
      selected[i] = prefix .. removeUnicodeUtf8(v)
    end
    action(selected, opts)
  end
end

-- ------------------------------------------------------------------
-- Files Enhanced
-- ------------------------------------------------------------------

local getFileOpt = function ()
  local opts = {}
  opts.multiprocess = false
  opts.prompt = getHomeName() .. ' >'
  opts.previewer = "builtin"
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
    }
  })
  opts.file_icons = true
  opts.git_icons = true
  opts.fn_transform = function(x)
    return fzf_lua.make_entry.file(x, {file_icons=true, color_icons=true})
  end
  opts.fzf_opts = {
    ["-x"] = "",
    ["--multi"] = "",
    ["--scheme"] = "history",
    ["--tiebreak"] = "index",
    ["--no-unicode"] = "",
  }

  return opts
end

M.fzf_files = function(opts)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix --follow --hidden --exclude .git --type f . " ..
    "-E .git -E '*.psd' -E '*.png' -E '*.jpg' -E '*.pdf' " ..
    "-E '*.ai' -E '*.jfif' -E '*.jpeg' -E '*.gif' " ..
    "-E '*.eps' -E '*.svg' -E '*.JPEM' -E '*.mp4' | " ..
    "eza -1 -sold --color=always --no-quotes",
    getFileOpt()
  )
end

M.fzf_all_files = function(opts)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix -I --type file --follow --hidden --exclude .git | " ..
    "eza -1 -sold --color=always --no-quotes",
    getFileOpt()
  )
end

vim.cmd([[command! -nargs=* FilesLua lua require"plugins.fzf-lua_util".fzf_files()]])
vim.cmd([[command! -nargs=* AllFilesLua lua require"plugins.fzf-lua_util".fzf_all_files()]])

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
    ["enter"] = {
      function (selected)
        vim.cmd('TermForceCloseAll')
        vim.cmd('Oil ' .. selected[1])
      end
    },
    ["ctrl-s"] = {
      function (selected)
        vim.cmd('TermForceCloseAll')
        vim.cmd('vsplit')
        vim.cmd('Oil ' .. selected[1])
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

-- ------------------------------------------------------------------
-- RG grep
-- ------------------------------------------------------------------

local getRipgrepOpts = function (isAll)
  isAll = isAll == nil and true or isAll

  local opts = {}
  opts.multiprocess = false
  opts.prompt = '>'
  opts.previewer = "builtin"
  opts.winopts = {
    preview = {
      hidden = true
    },
    -- treesitter = {
    --   enabled = true,
    --   fzf_colors = {
    --     ["hl"] = "red:reverse",
    --     ["hl+"] = "red:reverse",
    --   }
    -- },
  }
  opts.actions = vim.tbl_deep_extend("force", defaultActions, {
    ["enter"] = fzf_lua.actions.file_edit_or_qf,
    ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
  })
  opts.file_icons = true
  opts.fn_transform = function(x)
    return fzf_lua.make_entry.file(x, {file_icons=true, color_icons=true})
  end
  -- opts.fn_pre_win = function(_)
  --   vim.keymap.set("t", "?", "<F4>", { noremap = true, silent = true })
  -- end
  opts.fzf_opts = {
    ["--multi"] = "",
    ["--no-unicode"] = "",
  }

  if isAll then
    opts.fzf_opts["--delimiter"] = ":"
    opts.fzf_opts["--nth"] = "4..,1"
  else
    opts.fzf_opts["--delimiter"] = ":"
    opts.fzf_opts["--nth"] = "4.."
  end

  return opts
end

M.fzf_ripgrep = function(args)
  fzf_lua.fzf_exec(
    "rg --column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git " .. vim.fn.shellescape(args),
    getRipgrepOpts()
  )
end

M.fzf_ripgrep_text = function(args)
  fzf_lua.fzf_exec(
    "rg --column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git " .. vim.fn.shellescape(args),
    getRipgrepOpts(false)
  )
end

M.fzf_all_ripgrep = function(args)
  fzf_lua.fzf_exec(
    "rg --column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always --glob=!.git " .. vim.fn.shellescape(args),
    getRipgrepOpts()
  )
end

vim.cmd([[command! -nargs=* RgLua lua require"plugins.fzf-lua_util".fzf_ripgrep(<q-args>)]])
vim.cmd([[command! -nargs=* RgTextLua lua require"plugins.fzf-lua_util".fzf_ripgrep_text(<q-args>)]])
vim.cmd([[command! -nargs=* AllRgLua lua require"plugins.fzf-lua_util".fzf_all_ripgrep(<q-args>)]])

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
--
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
-- loravel.nvim override
-- ------------------------------------------------------------------

M.fzf_laravel = function(winopts)
  if vim.g.filetype ~= "php" and vim.g.filetype ~= "blade" then
    if _G.laravel_nvim and _G.laravel_nvim.is_laravel_project then
      local navigate = require('laravel.navigate')
      if navigate.is_laravel_navigation_context() then
        -- This is a Laravel-specific context, try Laravel navigation
        local success = pcall(navigate.goto_laravel_string)
        if success then
          return -- Laravel navigation succeeded
        end
      end
    end

    -- Default to LSP definition for everything else
    if vim.lsp.buf.definition then
      require("fzf-lua.cmd").run_command('lsp_definitions')
    else
      vim.notify('No LSP definition available', vim.log.levels.WARN)
    end
  else
    require("fzf-lua.cmd").run_command('lsp_definitions')
  end
end

vim.cmd([[command! -nargs=* LaravelLua lua require"plugins.fzf-lua_util".fzf_laravel()]])

-- ------------------------------------------------------------------
-- lsp settings
-- ------------------------------------------------------------------

-- in /home/g;aikawa/dotfiles/.config/nvim/lua/lsp/configs/settings.lua

return M
