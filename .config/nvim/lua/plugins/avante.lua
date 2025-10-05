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
        opts.mappings.focus,
        function() require("avante.api").focus() end,
        mode = { "n" },
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
      },
      {
        "<Leader>cA",
        function ()
          require("avante.api").zen_mode()
        end,
        mode = { "n" }
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
      },
    },
    {
      acp_providers = {
        ["gemini-cli"] = {
          command = "gemini",
          args = { "--experimental-acp" },
          env = {
            NODE_NO_WARNINGS = "1",
            -- GEMINI_API_KEY = os.getenv("GEMINI_API_KEY"),
          },
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
    system_prompt = function()
      local hub = require("mcphub").get_hub_instance()
      return hub and hub:get_active_servers_prompt() or ""
    end,
    -- Using function prevents requiring mcphub before it's loaded
    custom_tools = function()
      return {
        require("mcphub.extensions.avante").mcp_tool(),
      }
    end,
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
        close = { "q" },
        close_from_input = { normal = "q", insert = "<C-d>" }
      },
      files = {
        add_current = "<leader>ca", -- Add current buffer to selected files
      },
      select_model = "<leader>c?", -- Select model command,
    },
    hints = { enabled = true },
    selector = {
      provider = "fzf_lua",
      provider_opts = {
        prompt = "select:",
        fzf_opts = {
          ["--multi"] = "",
        },
      },
    },
    windows = {
      ---@type "right" | "left" | "top" | "bottom"
      position = "right", -- the position of the sidebar
      wrap = true, -- similar to vim.o.wrap
      width = 30, -- default % based on available width
      sidebar_header = {
        align = "left", -- left, center, right for title
        rounded = false,
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
