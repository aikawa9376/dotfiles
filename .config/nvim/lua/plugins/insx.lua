return {
  "hrsh7th/nvim-insx",
  event = "InsertEnter",
  config = function ()
    require('insx.preset.standard').setup()

    -- nvim-insx keeps a private scratch buffer for keycode normalization.
    -- Recreate it if another plugin or buffer cleanup has wiped it.
    local keymap = require('insx.kit.Vim.Keymap')
    local normalize = keymap.normalize
    local function ensure_normalizer_buffer()
      for i = 1, 10 do
        local name, bufnr = debug.getupvalue(normalize, i)
        if not name then return end
        if name == 'buf' then
          if not vim.api.nvim_buf_is_valid(bufnr) then
            local replacement = vim.api.nvim_create_buf(false, true)
            vim.bo[replacement].bufhidden = 'hide'
            debug.setupvalue(normalize, i, replacement)
          end
          return
        end
      end
    end

    local insx = require('insx')
    if not insx._aikawa_normalizer_guard then
      local expand = insx.expand
      insx.expand = function(...)
        ensure_normalizer_buffer()
        return expand(...)
      end
      insx._aikawa_normalizer_guard = true
    end
  end
}
