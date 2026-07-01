return {
  "folke/snacks.nvim",
  event = "BufReadPre",
  cmd = "SnacksToggleMenu",
  config = function()
    local BIGFILE_SIZE = 1.5 * 1024 * 1024
    local BIGFILE_LINE_LENGTH = 1000
    local snacks

    local function set_buf_option(buf, name, value)
      pcall(vim.api.nvim_set_option_value, name, value, { buf = buf })
    end

    local function require_or_load(module, plugin)
      local ok, loaded = pcall(require, module)
      if ok then
        return loaded
      end

      local ok_lazy, lazy = pcall(require, "lazy")
      if ok_lazy then
        pcall(lazy.load, { plugins = { plugin } })
        ok, loaded = pcall(require, module)
        if ok then
          return loaded
        end
      end
    end

    local function load_plugins(plugins)
      local ok_lazy, lazy = pcall(require, "lazy")
      if ok_lazy then
        pcall(lazy.load, { plugins = plugins })
      end
    end

    local function toggle_snacks(id)
      local toggle = snacks.toggle.get(id)
      if toggle then
        toggle:toggle()
      end
    end

    local function toggle_trouble(mode)
      local trouble = require_or_load("trouble", "trouble.nvim")
      if not trouble then
        vim.notify("trouble.nvim is not available", vim.log.levels.ERROR)
        return
      end

      trouble.toggle({
        mode = mode,
        open_no_results = true,
      })
    end

    local function require_dapui()
      load_plugins({ "nvim-dap" })

      local ok, loaded = pcall(require, "dapui")
      if ok then
        return loaded
      end
    end

    local function dapui_is_open()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local buf = vim.api.nvim_win_get_buf(win)
          local filetype = vim.bo[buf].filetype
          if filetype:match("^dapui_") or filetype == "dap-repl" then
            return true
          end
        end
      end
      return false
    end

    local function set_dapui_open(state)
      local dapui = require_dapui()
      if not dapui then
        vim.notify("nvim-dap-ui is not available", vim.log.levels.ERROR)
        return
      end

      if state then
        dapui.open()
      else
        dapui.close()
      end
    end

    local function is_fugitive_status_window(win)
      if not vim.api.nvim_win_is_valid(win) then
        return false
      end

      local buf = vim.api.nvim_win_get_buf(win)
      if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "fugitive" then
        return false
      end

      local ok, status = pcall(vim.api.nvim_win_get_var, win, "fugitive_status")
      return vim.b[buf].fugitive_type == "index" or (ok and status ~= nil)
    end

    local function fugitive_status_is_open()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if is_fugitive_status_window(win) then
          return true
        end
      end
      return false
    end

    local function set_fugitive_status_open(state)
      if state then
        local ok, err = pcall(vim.cmd, "Git")
        if not ok then
          vim.notify("Fugitive status failed: " .. tostring(err), vim.log.levels.ERROR)
        end
        return
      end

      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if is_fugitive_status_window(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end

    local function require_colorizer()
      load_plugins({ "nvim-colorizer.lua" })

      local ok, loaded = pcall(require, "colorizer")
      if ok then
        return loaded
      end
    end

    local function colorizer_is_enabled()
      local colorizer = require_colorizer()
      if not colorizer or type(colorizer.is_buffer_attached) ~= "function" then
        return false
      end

      return colorizer.is_buffer_attached(vim.api.nvim_get_current_buf()) == true
    end

    local function set_colorizer_enabled(state)
      local colorizer = require_colorizer()
      if not colorizer then
        vim.notify("nvim-colorizer.lua is not available", vim.log.levels.ERROR)
        return
      end

      local buf = vim.api.nvim_get_current_buf()
      local current = colorizer.is_buffer_attached(buf) == true
      if current == state then
        return
      end

      local fn = state and colorizer.attach_to_buffer or colorizer.detach_from_buffer
      if type(fn) ~= "function" then
        vim.notify("nvim-colorizer.lua buffer API is not available", vim.log.levels.ERROR)
        return
      end
      fn(buf)
    end

    local function require_render_markdown()
      load_plugins({ "render-markdown.nvim" })

      local ok, loaded = pcall(require, "render-markdown")
      if ok then
        return loaded
      end
    end

    local function render_markdown_is_enabled()
      local render_markdown = require_render_markdown()
      if not render_markdown or type(render_markdown.get) ~= "function" then
        return false
      end

      return render_markdown.get() == true
    end

    local function set_render_markdown_enabled(state)
      local render_markdown = require_render_markdown()
      if not render_markdown then
        vim.notify("render-markdown.nvim is not available", vim.log.levels.ERROR)
        return
      end
      if type(render_markdown.set) ~= "function" then
        vim.notify("render-markdown.nvim toggle API is not available", vim.log.levels.ERROR)
        return
      end

      render_markdown.set(state)
    end

    local function require_gitsigns()
      load_plugins({ "gitsigns.nvim" })

      local ok, loaded = pcall(require, "gitsigns")
      if ok then
        return loaded
      end
    end

    local function get_gitsigns_config(name)
      load_plugins({ "gitsigns.nvim" })

      local ok, config = pcall(require, "gitsigns.config")
      if ok and config and config.config then
        return config.config[name] == true
      end
      return false
    end

    local function set_gitsigns_toggle(fn_name, state)
      local gitsigns = require_gitsigns()
      if not gitsigns or type(gitsigns[fn_name]) ~= "function" then
        vim.notify("gitsigns.nvim " .. fn_name .. " is not available", vim.log.levels.ERROR)
        return
      end

      gitsigns[fn_name](state)
    end

    local function run_command(command)
      vim.cmd(command)
    end

    local function open_toggle_menu()
      local items = {
        { label = "D  Diagnostics", run = function() toggle_snacks("diagnostics") end },
        { label = "i  Inlay hints", run = function() toggle_snacks("inlay_hints") end },
        { label = "n  Line numbers", run = function() toggle_snacks("line_number") end },
        { label = "s  Spell check", run = function() toggle_snacks("spell") end },
        { label = "o  Overseer tasks", run = function() toggle_snacks("overseer_tasks") end },
        { label = "u  DAP UI", run = function() toggle_snacks("dap_ui") end },
        { label = "g  Fugitive status", run = function() toggle_snacks("fugitive_status") end },
        { label = "z  Colorizer", run = function() toggle_snacks("colorizer") end },
        { label = "r  Render markdown", run = function() toggle_snacks("render_markdown") end },
        { label = "G  Gitsigns signs", run = function() toggle_snacks("gitsigns_signs") end },
        { label = "w  Gitsigns word diff", run = function() toggle_snacks("gitsigns_word_diff") end },
        { label = "d  Gitsigns deleted", run = function() toggle_snacks("gitsigns_deleted") end },
        { label = "m  Gitsigns numhl", run = function() toggle_snacks("gitsigns_numhl") end },
        { label = "h  Gitsigns linehl", run = function() toggle_snacks("gitsigns_linehl") end },
        { label = "c  Connector", run = function() run_command("Connector") end },
        { label = "l  LazyAgent toggle", run = function() run_command("LazyAgentToggle!") end },
        { label = "t  Trouble LSP", run = function() toggle_trouble("lsp") end },
        { label = "x  Trouble diagnostics", run = function() toggle_trouble("diagnostics") end },
      }

      vim.ui.select(items, {
        prompt = "Toggle / Task",
        kind = "toggle-menu",
        format_item = function(item)
          return item.label
        end,
      }, function(item)
        if not item then
          return
        end
        vim.schedule(item.run)
      end)
    end

    local function harden_bigfile_buffer(buf)
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
      end

      if vim.fn.exists(":NoMatchParen") ~= 0 then
        pcall(vim.cmd, "NoMatchParen")
      end

      vim.b[buf].completion = false
      vim.b[buf].illuminate_disable = true
      vim.b[buf].matchup_matchparen_enabled = 0
      vim.b[buf].minianimate_disable = true
      vim.b[buf].minihipatterns_disable = true
      vim.b[buf].gitgutter_enabled = 0

      set_buf_option(buf, "bufhidden", "wipe")
      set_buf_option(buf, "swapfile", false)
      set_buf_option(buf, "undofile", false)
      set_buf_option(buf, "undolevels", -1)
      set_buf_option(buf, "modeline", false)
      set_buf_option(buf, "syntax", "OFF")

      pcall(vim.treesitter.stop, buf)
      pcall(vim.diagnostic.disable, buf)
      pcall(vim.diagnostic.enable, false, { bufnr = buf })

      if vim.lsp and type(vim.lsp.get_clients) == "function" then
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
          pcall(vim.lsp.buf_detach_client, buf, client.id)
        end
      end

      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_set_option_value, "foldmethod", "manual", { win = win })
          pcall(vim.api.nvim_set_option_value, "statuscolumn", "", { win = win })
          pcall(vim.api.nvim_set_option_value, "conceallevel", 0, { win = win })
        end
      end
    end

    local function is_bigfile_buffer(buf, opts)
      opts = opts or {}
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
      end
      if vim.bo[buf].buftype ~= "" then
        return false
      end

      local path = vim.api.nvim_buf_get_name(buf)
      if path == "" then
        return false
      end

      local size = vim.fn.getfsize(path)
      if size <= 0 then
        return false
      end
      if size > BIGFILE_SIZE then
        return true
      end
      if opts.check_line_length == false then
        return false
      end
      if not vim.api.nvim_buf_is_loaded(buf) then
        return false
      end

      local lines = math.max(1, vim.api.nvim_buf_line_count(buf))
      return (size - lines) / lines > BIGFILE_LINE_LENGTH
    end

    local function maybe_harden_bigfile_buffer(buf, opts)
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.bo[buf].filetype ~= "bigfile" and not is_bigfile_buffer(buf, opts) then
        return
      end

      if vim.bo[buf].filetype ~= "bigfile" then
        set_buf_option(buf, "filetype", "bigfile")
      end
      harden_bigfile_buffer(buf)
    end

    local function overseer_list_is_open()
      if not package.loaded["overseer.window"] then
        return false
      end

      local ok, window = pcall(require, "overseer.window")
      return ok and window.is_open()
    end

    local function set_overseer_list_open(state)
      local overseer = require_or_load("overseer", "overseer.nvim")
      if not overseer then
        vim.notify("overseer.nvim is not available", vim.log.levels.ERROR)
        return
      end

      if state then
        overseer.open({ enter = true })
      else
        overseer.close()
      end
    end

    snacks = require("snacks")
    snacks.setup({
      bigfile = {
        enabled = true,
        line_length = BIGFILE_LINE_LENGTH,
        size = BIGFILE_SIZE,
        setup = function(ctx)
          harden_bigfile_buffer(ctx.buf)
        end,
      },
      image = {
        enabled = true,
        convert = {
          notify = false,
        },
      },
      bufdelete = {
        enabled = true,
      },
      toggle = {
        notify = true,
      },
    })

    snacks.toggle({
      id = "overseer_tasks",
      name = "Overseer Tasks",
      get = overseer_list_is_open,
      set = set_overseer_list_open,
      notify = function(state)
        vim.notify((state and "Opened" or "Closed") .. " Overseer tasks", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "dap_ui",
      name = "DAP UI",
      get = dapui_is_open,
      set = set_dapui_open,
      notify = function(state)
        vim.notify((state and "Opened" or "Closed") .. " DAP UI", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "fugitive_status",
      name = "Fugitive Status",
      get = fugitive_status_is_open,
      set = set_fugitive_status_open,
      notify = function(state)
        vim.notify((state and "Opened" or "Closed") .. " Fugitive status", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "colorizer",
      name = "Colorizer",
      get = colorizer_is_enabled,
      set = set_colorizer_enabled,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Colorizer", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "render_markdown",
      name = "Render Markdown",
      get = render_markdown_is_enabled,
      set = set_render_markdown_enabled,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Render Markdown", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "gitsigns_signs",
      name = "Gitsigns Signs",
      get = function() return get_gitsigns_config("signcolumn") end,
      set = function(state) set_gitsigns_toggle("toggle_signs", state) end,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Gitsigns signs", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "gitsigns_word_diff",
      name = "Gitsigns Word Diff",
      get = function() return get_gitsigns_config("word_diff") end,
      set = function(state) set_gitsigns_toggle("toggle_word_diff", state) end,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Gitsigns word diff", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "gitsigns_deleted",
      name = "Gitsigns Deleted Lines",
      get = function() return get_gitsigns_config("show_deleted") end,
      set = function(state) set_gitsigns_toggle("toggle_deleted", state) end,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Gitsigns deleted lines", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "gitsigns_numhl",
      name = "Gitsigns Number Highlight",
      get = function() return get_gitsigns_config("numhl") end,
      set = function(state) set_gitsigns_toggle("toggle_numhl", state) end,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Gitsigns number highlight", vim.log.levels.INFO)
      end,
    })
    snacks.toggle({
      id = "gitsigns_linehl",
      name = "Gitsigns Line Highlight",
      get = function() return get_gitsigns_config("linehl") end,
      set = function(state) set_gitsigns_toggle("toggle_linehl", state) end,
      notify = function(state)
        vim.notify((state and "Enabled" or "Disabled") .. " Gitsigns line highlight", vim.log.levels.INFO)
      end,
    })
    snacks.toggle.diagnostics()
    snacks.toggle.inlay_hints()
    snacks.toggle.line_number()
    snacks.toggle.option("spell", { name = "Spell Check" })
    vim.api.nvim_create_user_command("SnacksToggleMenu", open_toggle_menu, {
      desc = "Open toggle / task menu",
      force = true,
    })

    local group = vim.api.nvim_create_augroup("UserBigFileHardening", { clear = true })
    vim.api.nvim_create_autocmd("BufReadPre", {
      group = group,
      callback = function(args)
        maybe_harden_bigfile_buffer(args.buf, { check_line_length = false })
      end,
    })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
      group = group,
      callback = function(args)
        maybe_harden_bigfile_buffer(args.buf)
      end,
    })
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      callback = function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          maybe_harden_bigfile_buffer(buf)
        end
      end,
    })
    maybe_harden_bigfile_buffer(vim.api.nvim_get_current_buf(), { check_line_length = false })
  end,
  keys = {
    -- { "<leader>gg", function() Snacks.lazygit() end, desc = "Lazygit" },
    {
      "<Leader>t",
      "<cmd>SnacksToggleMenu<CR>",
      desc = "Toggle / task menu",
    },
  },
}
