return {
  "nvim-neo-tree/neo-tree.nvim",
  keys = {
    { "<Leader>n", "<Cmd>Neotree reveal toggle<CR>", silent = true }
  },
  opts = {
    popup_border_style = "",
    close_if_last_window = false, -- Close Neo-tree if it is the last window left in the tab
    enable_git_status = true,
    enable_diagnostics = true,
    sort_case_insensitive = false, -- used when sorting files and directories in the tree
    use_default_mappings = false,
    sort_function = nil, -- use a custom function for sorting files and directories in the tree
    -- sort_function = function (a,b)
    --       if a.type == b.type then
    --           return a.path > b.path
    --       else
    --           return a.type > b.type
    --       end
    --   end , -- this sorts files and directories descendantly
    -- sources = {
    --   "filesystem",
    --   "buffers",
    --   "document_symbols",
    -- },
    default_component_configs = {
      container = {
        enable_character_fade = true,
      },
      indent = {
        indent_size = 2,
        padding = 1, -- extra padding on left hand side
        -- indent guides
        with_markers = true,
        indent_marker = "│",
        last_indent_marker = "└",
        highlight = "NeoTreeIndentMarker",
        -- expander config, needed for nesting files
        with_expanders = nil, -- if nil and file nesting is enabled, will enable expanders
        expander_collapsed = "",
        expander_expanded = "",
        expander_highlight = "NeoTreeExpander",
      },
      icon = {
        folder_closed = "",
        folder_open = "",
        folder_empty = "ﰊ",
        -- The next two settings are only a fallback, if you use nvim-web-devicons and configure default icons there
        -- then these will never be used.
        default = "*",
        highlight = "NeoTreeFileIcon",
      },
      modified = {
        symbol = "[+]",
        highlight = "NeoTreeModified",
      },
      name = {
        trailing_slash = false,
        use_git_status_colors = true,
        highlight = "NeoTreeFileName",
      },
      git_status = {
        symbols = {
          -- Change type
          added = "", -- or "✚", but this is redundant info if you use git_status_colors on the name
          modified = "", -- or "", but this is redundant info if you use git_status_colors on the name
          deleted = "✖", -- this can only be used in the git_status source
          renamed = "", -- this can only be used in the git_status source
          -- Status type
          untracked = "",
          ignored = "",
          unstaged = "",
          staged = "",
          conflict = "",
        },
      },
    },
    window = {
      position = "left",
      width = 30,
      mapping_options = {
        noremap = true,
        nowait = true,
      },
      mappings = {
        ["o"] = {
          "toggle_node",
          nowait = true, -- disable `nowait` if you have existing combos starting with this char that you want to use
        },
        ["<2-LeftMouse>"] = "open",
        ["<cr>"] = "open",
        ["<esc>"] = "revert_preview",
        ["P"] = {
          "toggle_preview",
          config = {
            use_float = true,
            use_image_nvim = true,
          },
        },
        ["S"] = "open_split",
        ["s"] = "open_vsplit",
        -- ["S"] = "split_with_window_picker",
        -- ["s"] = "vsplit_with_window_picker",
        ["t"] = "open_tabnew",
        -- ["<cr>"] = "open_drop",
        -- ["t"] = "open_tab_drop",
        ["w"] = "open_with_window_picker",
        --["P"] = "toggle_preview", -- enter preview mode, which shows the current node without focusing
        ["z"] = "close_all_nodes",
        --["Z"] = "expand_all_nodes",
        ["a"] = {
          "add",
          -- some commands may take optional config options, see `:h neo-tree-mappings` for details
          config = {
            show_path = "none", -- "none", "relative", "absolute"
          },
        },
        ["K"] = "add_directory", -- also accepts the optional config.show_path option like "add".
        ["d"] = "delete",
        ["r"] = "rename",
        ["p"] = "paste_from_clipboard",
        ["y"] = "copy_to_clipboard",
        ["m"] = "cut_to_clipboard", -- takes text input for destination, also accepts the optional config.show_path option like "add".
        ["q"] = "close_window",
        ["R"] = "refresh",
        ["?"] = "show_help",
        ["<"] = "prev_source",
        [">"] = "next_source",
        ["c"] = function(state)
          local node = state.tree:get_node()
          vim.fn.setreg("+", node.name, "c")
        end,
        ["C"] = function(state)
          local node = state.tree:get_node()
          vim.fn.setreg("+", node.path, "c")
        end,
      },
    },
    nesting_rules = {},
    filesystem = {
      filtered_items = {
        visible = false, -- when true, they will just be displayed differently than normal items
        hide_dotfiles = false,
        hide_gitignored = false,
        hide_hidden = false, -- only works on Windows for hidden files/directories
        hide_by_name = {
          --"node_modules"
        },
        hide_by_pattern = { -- uses glob style patterns
          --"*.meta",
          --"*/src/*/tsconfig.json",
        },
        always_show = { -- remains visible even if other settings would normally hide it
          --".gitignored",
        },
        never_show = { -- remains hidden even if visible is toggled to true, this overrides always_show
          --".DS_Store",
          --"thumbs.db"
        },
        never_show_by_pattern = { -- uses glob style patterns
          --".null-ls_*",
        },
      },
      follow_current_file = {
        enabled = false, -- This will find and focus the file in the active buffer every time
        leave_dirs_open = false, -- `false` closes auto expanded dirs, such as with `:Neotree reveal`
      },
      -- time the current file is changed while the tree is open.
      group_empty_dirs = false, -- when true, empty folders will be grouped together
      find_command = "fd",
      find_args = { -- you can specify extra args to pass to the find command.
        fd = {
          "--exclude",
          ".git",
          "--exclude",
          "node_modules",
          "--exclude",
          ".next",
          "--exclude",
          "dist",
          "--exclude",
          "vendor",
        },
      },
      hijack_netrw_behavior = "open_default", -- netrw disabled, opening a directory opens neo-tree
      -- in whatever position is specified in window.position
      -- "open_current",  -- netrw disabled, opening a directory opens within the
      -- window like netrw would, regardless of window.position
      -- "disabled",    -- netrw left alone, neo-tree does not handle opening dirs
      use_libuv_file_watcher = true, -- This will use the OS level file watchers to detect changes
      -- instead of relying on nvim autocmd events.
      commands = {
        copy_file_name = function(state)
          local node = state.tree:get_node()
          vim.fn.setreg("*", node.name, "c")
        end,
      },
      window = {
        mappings = {
          ["<bs>"] = "navigate_up",
          ["."] = "set_root",
          ["H"] = "toggle_hidden",
          ["/"] = "none",
          ["f"] = "fuzzy_finder",
          ["D"] = "fuzzy_finder_directory",
          ["F"] = "filter_on_submit",
          ["<c-x>"] = "clear_filter",
          ["[g"] = "prev_git_modified",
          ["]g"] = "next_git_modified",
        },
        fuzzy_finder_mappings = {
          ["<down>"] = "move_cursor_down",
          ["<C-n>"] = "move_cursor_down",
          ["<up>"] = "move_cursor_up",
          ["<C-p>"] = "move_cursor_up",
          ["<esc>"] = "close",
          ["<S-CR>"] = "close_keep_filter",
          ["<C-CR>"] = "close_clear_filter",
          ["<C-w>"] = { "<C-S-w>", raw = true },
          {
            n = {
              ["j"] = "move_cursor_down",
              ["k"] = "move_cursor_up",
              ["<S-CR>"] = "close_keep_filter",
              ["<C-CR>"] = "close_clear_filter",
              ["<esc>"] = "close",
            }
          },
        },
      },
    },
    buffers = {
      follow_current_file = {
        enabled = true, -- This will find and focus the file in the active buffer every time
        leave_dirs_open = false, -- `false` closes auto expanded dirs, such as with `:Neotree reveal`
      },
      -- time the current file is changed while the tree is open.
      group_empty_dirs = true, -- when true, empty folders will be grouped together
      show_unloaded = true,
      window = {
        mappings = {
          ["bd"] = "buffer_delete",
          ["<bs>"] = "navigate_up",
          ["."] = "set_root",
        },
      },
    },
    git_status = {
      window = {
        position = "float",
        mappings = {
          ["A"] = "git_add_all",
          ["gu"] = "git_unstage_file",
          ["ga"] = "git_add_file",
          ["gr"] = "git_revert_file",
          ["gc"] = "git_commit",
          ["gp"] = "git_push",
          ["gg"] = "git_commit_and_push",
        },
      },
    },
    event_handlers = {
      {
        event = "neo_tree_window_after_open",
        handler = function()
          vim.api.nvim_set_var("auto_cursorline_disable", 1)
        end,
      },
      {
        event = "neo_tree_window_after_close",
        handler = function()
          vim.api.nvim_set_var("auto_cursorline_disable", 0)
        end,
      },
    },
    sources = {
      "filesystem",
      "buffers",
      "git_status",
      "document_symbols",
    },
    source_selector = {
      winbar = true, -- toggle to show selector on winbar
      statusline = false, -- toggle to show selector on statusline
      show_scrolled_off_parent_node = false, -- boolean
      sources = { -- table
        {
          source = "filesystem",
          display_name = "  Files "
        }, -- string | nil
        {
          source = "buffers",
          display_name = "  Bufs "
        }, -- string | nil
        {
          source = "git_status",
          display_name = "  Git "
        }, -- string | nil
        {
          source = "diagnostics",
          display_name = " 裂Diagnos "
        } -- string | nil
      },
      content_layout = "start", -- string
      tabs_layout = "equal", -- string
      truncation_character = "…", -- string
      tabs_min_width = nil, -- int | nil
      tabs_max_width = nil, -- int | nil
      padding = 0, -- int | { left: int, right: int }
      separator = { left = "", right = "" }, -- string | { left: string, right: string, override: string | nil }
      separator_active = nil, -- string | { left: string, right: string, override: string | nil } | nil
      show_separator_on_edge = false, -- boolean
      highlight_tab = "NormalNC", -- string
      highlight_tab_active = "NeoTreeTabActive", -- string
      highlight_background = "NormalNC", -- string
      highlight_separator = "NormalNC", -- string
      highlight_separator_active = "NeoTreeTabActive", -- string

    }
  }
}
