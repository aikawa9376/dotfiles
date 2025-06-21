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
        mode = { "n", "v" },
      },
      {
        opts.mappings.refresh,
        function() require("avante.api").refresh() end,
        mode = "v",
      },
      {
        opts.mappings.edit,
        function() require("avante.api").edit() end,
        mode = { "n", "v" },
      },
      {
        opts.mappings.stop,
        function() require("avante.api").stop() end,
        mode = { "n", "v", "i" },
      },
      {
        "<Leader>cL",
        function ()
          require"plugins.avante_util".avante_code_readability_analysis()
        end,
        mode = { "n" },
      },
      {
        "<Leader>cl",
        function ()
          require"plugins.avante_util".avante_optimize_code()
        end,
        mode = { "v" },
      },
      {
        "<Leader>cf",
        function ()
          require"plugins.avante_util".avante_fix_bugs()
        end,
        mode = { "v" },
      },
      {
        "<Leader>cs",
        function ()
          require"plugins.avante_util".avante_add_docstring()
        end,
        mode = { "v" },
      },
      {
        "<Leader>cT",
        function ()
          require"plugins.avante_util".avante_add_tests()
        end,
        mode = { "v" },
      }
    }
    mappings = vim.tbl_filter(function(m) return m[1] and #m[1] > 0 end, mappings)
    return vim.list_extend(mappings, keys)
  end,
  opts = {
    ---@alias Provider "claude" | "openai" | "azure" | "gemini" | "cohere" | "copilot" | string
    provider = "copilot", -- Recommend using Claude
    mode = "legacy",
    providers = {
      copilot = {
        model = "claude-3.5-sonnet",
        endpoint = "https://api.githubcopilot.com",
        allow_insecure = false,
        timeout = 10 * 60 * 1000,
        max_completion_tokens = 1000000,
        reasoning_effort = "high",
        extra_request_body = {
          temperature = 0,
        },
        disable_tools = {
          "python",
          -- "replace_in_file",
        },
      },
    },
    auto_suggestions_provider = "copilot",
    behaviour = {
      auto_suggestions = false, -- Experimental stage
      auto_set_highlight_group = true,
      auto_set_keymaps = false,
      auto_apply_diff_after_generation = false,
      support_paste_from_clipboard = false,
    },
    web_search_engine = {
      provider = "tavily", -- tavily, serpapi, searchapi, google, kagi, brave, or searxng
      proxy = nil, -- proxy support, e.g., http://127.0.0.1:7890
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
      cancel = {
        normal = { "<C-c>" },
        insert = { "<C-c>" },
      },
      ask = "<leader>cc",
      edit = "<leader>ce",
      refresh = "<leader>cr",
      focus = "<leader>cf",
      stop = "<leader>cC",
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
      edit = {
        border = 'single'
      },
      ask = {
        border = 'single',
        start_insert = false,
      }
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
