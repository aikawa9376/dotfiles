local M = {}

M.settings = function ()
  vim.diagnostic.config({
    virtual_text = false,
    float = {
      border = "single",
      focusable = false
    },
    signs = {
      priority = 100,
      text = {
        [vim.diagnostic.severity.ERROR] = "",
        [vim.diagnostic.severity.WARN] = "",
        [vim.diagnostic.severity.INFO] = "",
        [vim.diagnostic.severity.HINT] = ""
      },
      numhl = {
        [vim.diagnostic.severity.ERROR] = "DiagnosticSignError",
        [vim.diagnostic.severity.WARN] = "DiagnosticSignWarn",
        [vim.diagnostic.severity.INFO] = "DiagnosticSignInfo",
        [vim.diagnostic.severity.HINT] = "DiagnosticSignHint"
      }
    },
  })

  vim.diagnostic.handlers.signs = {
    show = function(namespace, bufnr, diagnostics, opts)
      vim.validate('namespace', namespace, 'number')
      vim.validate('bufnr', bufnr, 'number')
      vim.validate('diagnostics', diagnostics, vim.islist, 'a list of diagnostics')
      vim.validate('opts', opts, 'table', true)

      bufnr = vim._resolve_bufnr(bufnr)
      opts = opts or {}

      local ns = vim.diagnostic.get_namespace(namespace)
      if not ns.user_data.sign_ns then
        ns.user_data.sign_ns =
        vim.api.nvim_create_namespace(string.format('nvim.%s.diagnostic.signs', ns.name))
      end

      -- 10 is the default sign priority when none is explicitly specified
      local priority = opts.signs and opts.signs.priority or 10

      local numhl = opts.signs.numhl or {}
      local linehl = opts.signs.linehl or {}

      local line_count = vim.api.nvim_buf_line_count(bufnr)

      for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.lnum <= line_count then
          vim.api.nvim_buf_set_extmark(bufnr, ns.user_data.sign_ns, diagnostic.lnum, 0, {
            number_hl_group = numhl[diagnostic.severity],
            line_hl_group = linehl[diagnostic.severity],
            priority = priority,
          })
        end
      end
    end,
    hide = function(namespace, bufnr)
      local ns = vim.diagnostic.get_namespace(namespace)
      if ns.user_data.sign_ns and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns.user_data.sign_ns, 0, -1)
      end
    end,
  }
end

return M
