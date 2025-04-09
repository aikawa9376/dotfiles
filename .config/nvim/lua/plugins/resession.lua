return {
  'stevearc/resession.nvim',
  lazy = true,
  opts = {
    -- Options for automatically saving sessions on a timer
    autosave = {
      enabled = false,
      -- How often to save (in seconds)
      interval = 60,
      -- Notify when autosaved
      notify = true,
    },
    -- Save and restore these options
    options = {
      "binary",
      "bufhidden",
      "buflisted",
      "cmdheight",
      "diff",
      "filetype",
      "modifiable",
      "previewwindow",
      "readonly",
      "scrollbind",
      "winfixheight",
      "winfixwidth",
    },
    -- Custom logic for determining if the buffer should be included
    -- buf_filter = require("resession").default_buf_filter,
    -- Custom logic for determining if a buffer should be included in a tab-scoped session
    tab_buf_filter = function(tabpage, bufnr)
      return true
    end,
    -- The name of the directory to store sessions in
    dir = "session",
    -- Show more detail about the sessions when selecting one to load.
    -- Disable if it causes lag.
    load_detail = true,
    -- List order ["modification_time", "creation_time", "filename"]
    load_order = "modification_time",
    -- Configuration for extensions
    extensions = {
      quickfix = {},
    },
  },
  init = function ()
    local function get_session_name()
      local name = vim.fn.getcwd()
      local branch = vim.trim(vim.fn.system("git branch --show-current"))
      if vim.v.shell_error == 0 then
        return name .. '-' .. branch
      else
        return name
      end
    end
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        require"resession".save(get_session_name(), { dir = "dirsession", notify = false })
      end,
    })
    vim.api.nvim_create_user_command("ResessionLoad", function()
      local name = get_session_name()
      require"resession".load(name, { dir = "dirsession", notify = false })
    end, { force = true })
  end
}
