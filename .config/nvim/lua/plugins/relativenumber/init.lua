return {
  "relativenumber",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/relativenumber",
  event = "BufRead",
  config = function()
    local delay_ms = 1000
    local timer = nil
    local excluded_filetypes = {
      -- "oil",
      "fugitive",
    }

    local augroup = vim.api.nvim_create_augroup("ToggleRelativeNumber", { clear = true })

    local function is_excluded_filetype()
      local current_ft = vim.bo.filetype
      for _, ft in ipairs(excluded_filetypes) do
        if current_ft == ft then
          return true
        end
      end
      return false
    end

    local function enable_relative_number()
      if vim.wo.relativenumber == false and vim.wo.number and not is_excluded_filetype() then
        vim.opt.relativenumber = true
      end
    end

    local function disable_relative_number()
      if vim.wo.relativenumber then
        vim.opt.relativenumber = false
      end
    end

    local function reset_timer()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end

      local loop = vim.loop or vim.uv
      timer = loop.new_timer()
      if timer then
        timer:start(delay_ms, 0, vim.schedule_wrap(function()
          enable_relative_number()
        end))
      end
    end

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = augroup,
      pattern = "*",
      callback = function()
        disable_relative_number()
        reset_timer()
      end,
    })

    vim.api.nvim_create_autocmd("InsertEnter", {
      group = augroup,
      pattern = "*",
      callback = function()
        disable_relative_number()
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
      end,
    })

    vim.api.nvim_create_autocmd("InsertLeave", {
      group = augroup,
      pattern = "*",
      callback = function()
        reset_timer()
      end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
      group = augroup,
      pattern = "*",
      callback = function()
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
        disable_relative_number()
      end,
    })
  end
}
