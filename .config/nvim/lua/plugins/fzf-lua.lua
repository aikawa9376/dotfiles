return {
  "ibhagwan/fzf-lua",
  cmd = { "FzfLua" },
  keys = {
    { "<Leader>gf", 'm`:FzfLua git_files<CR>', mode = { "n" }, silent = true },
    { "<Leader>gc", 'm`:FzfLua git_commits<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader>gC", 'm`:FzfLua git_bcommits<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader>b", 'm`:FzfLua buffers<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader>l", 'm`:FzfLua blines<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader>L", 'm`:FzfLua lines<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader>q", 'm`:FzfLua helptags<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader><C-o>", 'm`:FzfLua jumps<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader><C-c>", 'm`:FzfLua changes<CR>', mode = { "n" }, noremap = true, silent = true },
    { "q:", 'm`:FzfLua command_history<CR>', mode = { "n" }, noremap = true, silent = true },
    { "q/", 'm`:FzfLua search_history<CR>', mode = { "n" }, noremap = true, silent = true },
    { "<Leader>f", function () require"plugins.fzf-lua_util".fzf_files({}) end, silent = true },
    { "<Leader>F", function () require"plugins.fzf-lua_util".fzf_all_files() end, silent = true },
    { "<Leader>a", function () require"plugins.fzf-lua_util".fzf_ripgrep("") end, silent = true },
    { "<Leader>;", function () require"plugins.fzf-lua_util".fzf_ripgrep(vim.fn.expand('<cword>')) end, silent = true },
    { "<Leader>A", function () require"plugins.fzf-lua_util".fzf_all_ripgrep("") end, silent = true },
    { "<Leader>e", function () require"plugins.fzf-lua_util".fzf_mru_files_cwd() end, silent = true },
    { "<Leader>E", function () require"plugins.fzf-lua_util".fzf_mru_files() end, silent = true },
    { "<Leader>m", function () require"plugins.fzf-lua_util".fzf_junkfiles() end, silent = true },
    { "mx", function () require"plugins.fzf-lua_util".fzf_harpoon() end, silent = true }
  },
  opts = {
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
      winopts = {
      border = "rounded",
      height = 0.6,
      width = 0.6,
      row = 0.5,
      preview = {
        border = "rounded",
        layout = "horizontal",
        horizontal = "down:40%"
      }
    },
      fn_pre_win = function(opts)
        opts.winopts.split = nil
      end
    },
    lsp = {
      includeDeclaration = false,
      jump1 = true,
      ignore_current_line = true,
      finder = {
        includeDeclaration = false,
        ignore_current_line = true,
        jump1 = false,
      }
    }
  },
}
