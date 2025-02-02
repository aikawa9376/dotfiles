local fzf_lua = require("fzf-lua")

fzf_lua.setup {
  winopts = {
    split = "belowright new",
    height = 0.3,
    border = "none",
    preview = {
      -- default = "bat",
      title = false,
      border = "noborder",
      layout = "horizontal",
      wrap = "nowrap",
      horizontal = "right:50%",
      hidden = "nohidden",
      scrollbar = false,
    },
  },
  keymap = {
    builtin = {
      true,
      ["<M-j>"] = "preview-down",
      ["<M-K>"] = "preview-up",
      ["ctrl-n"] = "down",
      ["ctrl-p"] = "up",
      ["alt-a"] = "toggle-all",
      ["home"] = "top",
      ["alt-p"] = "previous-history",
      ["alt-n"] = "next-history",
      ["ctrl-k"] = "kill-line",
      ["alt-i"] = "execute(feh {})",
      ["?"] = "toggle-preview",
    },
    fzf = {
      true,
      ["ctrl-k"] = "preview-up",
      ["ctrl-j"] = "preview-down",
      ["ctrl-n"] = "down",
      ["ctrl-p"] = "up",
    },
  },
  fzf_opts = {
    ["--reverse"] = "",
    ["--cycle"] = "",
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
}

_G.fzf_files = function(opts)
  opts = opts or {}
  opts.prompt = "Directories> "
  opts.fn_transform = function(x)
    return fzf_lua.utils.ansi_codes.magenta(x)
  end
  opts.actions = {
    ['default'] = function(selected)
      vim.cmd("cd " .. selected[1])
    end
  }
  fzf_lua.fzf_exec(
    "fd --strip-cwd-prefix --follow --hidden --exclude .git --type f --print0 . " ..
    "-E .git -E '*.psd' -E '*.png' -E '*.jpg' -E '*.pdf' " ..
    "-E '*.ai' -E '*.jfif' -E '*.jpeg' -E '*.gif' " ..
    "-E '*.eps' -E '*.svg' -E '*.JPEG' -E '*.mp4' | " ..
    "xargs -0 eza -1 -sold --color=always --no-quotes",
    opts
  )
end

-- map our provider to a user command ':Directories'
vim.cmd([[command! -nargs=* FilesLua lua _G.fzf_files()]])
