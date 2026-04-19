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
      lazyagent = {},
    },
  },
  config = function(_, opts)
    local function ensure_lazyagent_loaded()
      local ok_lazy, lazy = pcall(require, "lazy")
      if ok_lazy and lazy and type(lazy.load) == "function" then
        pcall(lazy.load, { plugins = { "lazyagent" } })
      end
    end

    package.preload["resession.extensions.lazyagent"] = function()
      ensure_lazyagent_loaded()
      return require("lazyagent.resession_extension")
    end

    local resession = require("resession")
    resession.setup(opts)

    local function with_lazyagent(callback)
      ensure_lazyagent_loaded()

      local ok_agent, agent = pcall(require, "lazyagent")
      if ok_agent and agent then
        callback(agent)
      end
    end

    resession.add_hook("pre_save", function(name)
      with_lazyagent(function(agent)
        if type(agent.on_session_save_pre) == "function" then
          agent.on_session_save_pre({ source = "resession", session_name = name })
        end
      end)
    end)

    resession.add_hook("pre_load", function(name)
      with_lazyagent(function(agent)
        if type(agent.on_session_load_pre) == "function" then
          agent.on_session_load_pre({ source = "resession", session_name = name })
        end
      end)
    end)

    resession.add_hook("post_load", function(name)
      with_lazyagent(function(agent)
        if type(agent.on_session_load_post) == "function" then
          agent.on_session_load_post({ source = "resession", session_name = name })
        end
      end)
    end)
  end,
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
