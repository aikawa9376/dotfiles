return {
  "folke/snacks.nvim",
  event = "BufReadPre",
  config = function()
    local BIGFILE_SIZE = 1.5 * 1024 * 1024
    local BIGFILE_LINE_LENGTH = 1000

    local function set_buf_option(buf, name, value)
      pcall(vim.api.nvim_set_option_value, name, value, { buf = buf })
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

    require("snacks").setup({
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
        }
      },
      bufdelete = {
        enabled = true
      }
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
  },
}
