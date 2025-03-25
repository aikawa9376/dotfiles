return {
  "yetone/avante.nvim",
  version = false,
  build = "make",
  keys = function(_, keys)
    ---@type avante.Config
    local opts =
    require("lazy.core.plugin").values(require("lazy.core.config").spec.plugins["avante.nvim"], "opts", false)

    local mappings = {
      {
        opts.mappings.ask,
        function() require("avante.api").ask() end,
        desc = "avante: ask",
        mode = { "n", "v" },
      },
      {
        opts.mappings.refresh,
        function() require("avante.api").refresh() end,
        desc = "avante: refresh",
        mode = "v",
      },
      {
        opts.mappings.edit,
        function() require("avante.api").edit() end,
        desc = "avante: edit",
        mode = { "n", "v" },
      },
    }
    mappings = vim.tbl_filter(function(m) return m[1] and #m[1] > 0 end, mappings)
    return vim.list_extend(mappings, keys)
  end,
  opts = {
    ---@alias Provider "claude" | "openai" | "azure" | "gemini" | "cohere" | "copilot" | string
    provider = "copilot", -- Recommend using Claude
    auto_suggestions_provider = "copilot",
    behaviour = {
      auto_suggestions = false, -- Experimental stage
      auto_set_highlight_group = true,
      auto_set_keymaps = false,
      auto_apply_diff_after_generation = false,
      support_paste_from_clipboard = false,
    },
    mappings = {
      --- @class AvanteConflictMappings
      diff = {
        ours = "co",
        theirs = "ct",
        all_theirs = "ca",
        both = "cb",
        cursor = "cc",
        next = "]x",
        prev = "[x",
      },
      suggestion = {
        accept = "<M-l>",
        next = "<M-]>",
        prev = "<M-[>",
        dismiss = "<C-]>",
      },
      jump = {
        next = "]]",
        prev = "[[",
      },
      submit = {
        normal = "<CR>",
        insert = "<C-s>",
      },
      ask = "<leader>cc",
      edit = "<leader>ce",
      refresh = "<leader>cr",
      focus = "<leader>cf",
      toggle = {
        default = "<leader>ct",
        debug = "<leader>cd",
        hint = "<leader>ch",
        suggestion = "<leader>cs",
        repomap = "<leader>cR",
      },
      sidebar = {
        switch_windows = "<Tab>",
        reverse_switch_windows = "<S-Tab>",
        close = { "<ESC>", "q" },
        close_from_input = { normal = "<ESC><ESC>", insert = "<C-d>" }
      },
      files = {
        add_current = "<leader>ca", -- Add current buffer to selected files
      },
      select_model = "<leader>c?", -- Select model command,
    },
    hints = { enabled = true },
    file_selector = {
      provider = "fzf",
      -- Options override for custom providers
      provider_opts = {},
    },
    windows = {
      ---@type "right" | "left" | "top" | "bottom"
      position = "right", -- the position of the sidebar
      wrap = true, -- similar to vim.o.wrap
      width = 30, -- default % based on available width
      sidebar_header = {
        align = "center", -- left, center, right for title
        rounded = true,
      },
    },
    highlights = {
      ---@type AvanteConflictHighlights
      diff = {
        current = "DiffText",
        incoming = "DiffAdd",
      },
    },
    --- @class AvanteConflictUserConfig
    diff = {
      autojump = true,
      ---@type string | fun(): any
      list_opener = "copen",
    },
  }
}
