local version = vim.version()

---@type vim.lsp.Config
return {
  init_options = {
    editorInfo = {
      name = "neovim",
      version = string.format("%d.%d.%d", version.major, version.minor, version.patch),
    },
    editorPluginInfo = {
      name = "Github Copilot LSP for Neovim",
      version = "0.0.1",
    },
  },
  settings = {
    nextEditSuggestions = {
      enabled = true,
    },
  },
  handlers = require("copilot-lsp.handlers"),
  root_dir = vim.uv.cwd(),
  on_init = function(client)
    local au = vim.api.nvim_create_augroup("copilot-language-server", { clear = true })

    --NOTE: didFocus
    vim.api.nvim_create_autocmd("BufEnter", {
      callback = function()
        local td_params = vim.lsp.util.make_text_document_params()
        ---@diagnostic disable-next-line: param-type-mismatch
        client:notify("textDocument/didFocus", {
          textDocument = {
            uri = td_params.uri,
          },
        })
      end,
      group = au,
    })

    vim.keymap.set("n", "<Tab>", function()
      local bufnr = vim.api.nvim_get_current_buf()
      local state = vim.b[bufnr].nes_state
      local nes = require("copilot-lsp.nes")

      if state then
        if nes.walk_cursor_start_edit() then
          return
        end
        if nes.apply_pending_nes() then
          nes.walk_cursor_end_edit()
          vim.schedule(function()
            nes.request_nes(client)
          end)
        end
      else
        nes.request_nes(client)
      end
    end)
  end,
}
