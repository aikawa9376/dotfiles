local fzf_lua = require("fzf-lua")

-- ------------------------------------------------------------------
-- default settings
-- ------------------------------------------------------------------
--
local defaultActions = {
  ["enter"] = fzf_lua.actions.file_edit,
  ["ctrl-s"] = fzf_lua.actions.file_split,
  ["ctrl-v"] = fzf_lua.actions.file_vsplit,
}

local middleFloatWinOpts = {
  border = "rounded",
  height = 0.6,
  width = 0.6,
  row = 0.5,
  preview = {
    border = "rounded"
  }
}

local fullFloatWinOpts = {
  border = "rounded",
  height = 0.9,
  width = 0.9,
  row = 0.5,
  preview = {
    border = "rounded"
  }
}

fzf_lua.setup {
  winopts = {
    split = "botright new | resize " .. tostring(math.floor(vim.o.lines * 0.4)),
    height = 0.4,
    border = "none",
    preview = {
      -- default = "bat",
      title = false,
      wrap = false,
      border = "noborder",
      layout = "horizontal",
      horizontal = "right:50%",
      hidden = false,
      scrollbar = false,
      winopts = {
        -- signcolumn = "yes"
      }
    },
    treesitter = {
      enabled = true,
      fzf_colors = {
        ["hl"] = "red:reverse",
        ["hl+"] = "red:reverse",
      }
    },
  },
  hls = {
    preview_normal = "NormalFloat",
    backdrop = "FzfLuaPreviewNormal"
  },
  keymap = {
    builtin = {
      ["?"] = "toggle-preview",
      ["<M-K>"] = "preview-up",
      ["<M-j>"] = "preview-down",
    },
    fzf = {
      ["F4"] = "toggle-preview",
      ["alt-k"] = "preview-up",
      ["alt-j"] = "preview-down",
      ["ctrl-n"] = "down",
      ["ctrl-p"] = "up",
      ["home"] = "top",
      ["alt-n"] = "next-history",
      ["alt-p"] = "previous-history",
      ["ctrl-k"] = "kill-line",
    },
  },
  fzf_opts = {
    ["--reverse"] = "",
    ["--cycle"] = "",
    ["--info"] = "inline",
    ["--no-hscroll"] = "",
    ["--no-separator"] = "",
    ["--tabstop"] = "2",
    ["--tiebreak"] = "chunk,index",
    ["--color"] = "dark,hl:34,hl+:40,bg+:235,fg+:15,info:108,prompt:109,spinner:108,pointer:168,marker:168",
  },
  files = {
    fd_opts = "--type f --hidden --color=always --exclude .git",
  },
  dirs = {
    fd_opts = "--type d --hidden --color=always --exclude .git",
    preview_cmd = "tree -C {} | head -200",
  },
  buffers = {
    winopts = middleFloatWinOpts,
    fn_pre_win = function(opts)
      opts.winopts.split = nil
    end
  },
  lsp = {
    includeDeclaration = false,
    jump_to_single_result = true,
    ignore_current_line = true,
    finder = {
      includeDeclaration = false,
      ignore_current_line = true,
      jump_to_single_result = false,
    }
  }
}

vim.api.nvim_set_keymap('n', '<Leader>gf', 'm`:FzfLua git_files<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>gc', 'm`:FzfLua git_commits<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>gC', 'm`:FzfLua git_bcommits<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>b', 'm`:FzfLua buffers<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>l', 'm`:FzfLua blines<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>L', 'm`:FzfLua lines<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>q', 'm`:FzfLua helptags<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader><C-o>', 'm`:FzfLua jumps<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader><C-c>', 'm`:FzfLua changes<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'q:', 'm`:FzfLua command_history<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'q/', 'm`:FzfLua search_history<CR>', { noremap = true, silent = true })

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
  -- Vim Rooter の `FindRootDirectory` に依存
  if vim.fn.exists("*FindRootDirectory") == 1 and vim.fn.FindRootDirectory() ~= "" then
    local dir = vim.fn.FindRootDirectory()
    local parts = vim.split(dir, "/", { plain = true })
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
    ["--multi"] = "",
    ["--scheme"] = "history",
    ["--no-unicode"] = "",
  }

  return opts
end

_G.fzf_files = function(opts)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix --follow --hidden --exclude .git --type f --print0 . " ..
    "-E .git -E '*.psd' -E '*.png' -E '*.jpg' -E '*.pdf' " ..
    "-E '*.ai' -E '*.jfif' -E '*.jpeg' -E '*.gif' " ..
    "-E '*.eps' -E '*.svg' -E '*.JPEG' -E '*.mp4' | " ..
    "xargs -0 eza -1 -sold --color=always --no-quotes",
    getFileOpt()
  )
end

_G.fzf_all_files = function(opts)
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix -I --type file --follow --hidden --color=always --exclude .git",
    getFileOpt()
  )
end

vim.cmd([[command! -nargs=* FilesLua lua _G.fzf_files()]])
vim.cmd([[command! -nargs=* AllFilesLua lua _G.fzf_all_files()]])
vim.api.nvim_set_keymap('n', '<Leader>f', 'm`:lua _G.fzf_files()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>F', 'm`:lua _G.fzf_all_files()<CR>', { noremap = true, silent = true })

-- ------------------------------------------------------------------
-- RG grep
-- ------------------------------------------------------------------

local getRipgrepOpts = function (isAll)
  isAll = isAll == nil and true or isAll

  local opts = {}
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
  -- opts.file_icons = true
  -- opts.fn_transform = function(x)
  --   return fzf_lua.make_entry.file(x, {file_icons=true, color_icons=true})
  -- end
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

_G.fzf_ripgrep = function(args)
  fzf_lua.fzf_exec(
    "rg --column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git " .. vim.fn.shellescape(args),
    getRipgrepOpts()
  )
end

_G.fzf_ripgrep_text = function(args)
  fzf_lua.fzf_exec(
    "rg --column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git " .. vim.fn.shellescape(args),
    getRipgrepOpts(false)
  )
end

_G.fzf_all_ripgrep = function(args)
  fzf_lua.fzf_exec(
    "rg --column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always --glob=!.git " .. vim.fn.shellescape(args),
    getRipgrepOpts()
  )
end

vim.cmd([[command! -nargs=* RgLua lua _G.fzf_ripgrep(<q-args>)]])
vim.cmd([[command! -nargs=* RgTextLua lua _G.fzf_ripgrep_text(<q-args>)]])
vim.cmd([[command! -nargs=* AllRgLua lua _G.fzf_all_ripgrep(<q-args>)]])
vim.api.nvim_set_keymap('n', '<Leader>a', 'm`:lua _G.fzf_ripgrep("")<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>;', "m`:lua _G.fzf_ripgrep(vim.fn.expand('<cword>'))<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>A', 'm`:lua _G.fzf_all_ripgrep("")<CR>', { noremap = true, silent = true })

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
    ["--multi"] = "",
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

_G.fzf_mru_files = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("file", true)),
    getMruOpts(_G.fzf_mrw_files, "MRU ALL")
  )
end

_G.fzf_mrw_files = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("write", true)),
    getMruOpts(_G.fzf_mru_files, "MRW ALL")
  )
end

_G.fzf_mru_files_cwd = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("file")),
    getMruOpts(_G.fzf_mrw_files_cwd, "MRU")
  )
end

_G.fzf_mrw_files_cwd = function(opts)
  fzf_lua.fzf_exec(
    colorFilename(mruFilesForCwd("write")),
    getMruOpts(_G.fzf_mru_files_cwd, "MRW")
  )
end

vim.cmd([[command! -nargs=* MruFilesCdwLua lua _G.fzf_mru_files_cwd()]])
vim.cmd([[command! -nargs=* MrwWritesCdwLua lua _G.fzf_mrw_files_cwd()]])
vim.cmd([[command! -nargs=* MruFilesLua lua _G.fzf_mru_files()]])
vim.cmd([[command! -nargs=* MrwWritesLua lua _G.fzf_mrw_files()]])
vim.api.nvim_set_keymap('n', '<Leader>e', 'm`:lua _G.fzf_mru_files_cwd()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>E', 'm`:lua _G.fzf_mru_files()<CR>', { noremap = true, silent = true })

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

_G.fzf_harpoon = function(winopts)
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
            _G.fzf_harpoon()
          end
        },
        ["ctrl-t"] = { function() _G.fzf_harpoon(fullFloatWinOpts) end },
        ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
      }),
      fzf_opts = {
        ["--multi"] = "",
        ["--scheme"] = "history",
        ["--no-unicode"] = "",
      },
      winopts =  winopts,
      fn_pre_win = function(opts)
        opts.winopts.split = nil

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

vim.cmd([[command! -nargs=* HarpoonLua lua _G.fzf_harpoon()]])
vim.keymap.set("n", "mx", "<cmd>HarpoonLua<CR>")

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

_G.fzf_junkfiles = function(opts)
  local junkDir = vim.fn.expand("$XDG_CACHE_HOME") .. "/junkfile/" .. getRootDir() .. "/"

  fzf_lua.fzf_exec(
    "rg --column -n --hidden --ignore-case --color=always '' " .. junkDir ..
    " | sed -e 's%" .. junkDir .. "%%g'",
    getJunkFileOpt()
  )
end

vim.cmd([[command! -nargs=* FilesLua lua _G.fzf_junkfiles()]])
vim.api.nvim_set_keymap('n', '<Leader>m', 'm`:lua _G.fzf_junkfiles()<CR>', { noremap = true, silent = true })

-- ------------------------------------------------------------------
-- lsp settings
-- ------------------------------------------------------------------

-- in /home/g;aikawa/dotfiles/.config/nvim/lua/lsp/configs/settings.lua
