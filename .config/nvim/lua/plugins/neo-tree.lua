return {
  "nvim-neo-tree/neo-tree.nvim",
  keys = {
    { "<Leader>n", "<Cmd>Neotree reveal toggle<CR>", silent = true }
  },
  opts = {
    popup_border_style = "",
    use_default_mappings = false,
    default_component_configs = {
      modified = {
        symbol = "[+]",
        highlight = "NeoTreeModified",
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
      width = 30,
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
            use_snacks_image = true,
          },
        },
        ["S"] = "open_split",
        ["s"] = "open_vsplit",
        ["t"] = "open_tabnew",
        ["w"] = "open_with_window_picker",
        ["z"] = "close_all_nodes",
        ["a"] = {
          "add",
          config = {
            show_path = "none",
          },
        },
        ["K"] = "add_directory",
        ["d"] = "delete",
        ["r"] = "rename",
        ["p"] = "paste_from_clipboard",
        ["y"] = "copy_to_clipboard",
        ["m"] = "cut_to_clipboard",
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
    filesystem = {
      filtered_items = {
        visible = false,
        hide_dotfiles = false,
        hide_gitignored = false,
        hide_hidden = false,
      },
      -- time the current file is changed while the tree is open.
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
      use_libuv_file_watcher = true,
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
    sources = {
      "filesystem",
      "buffers",
      "git_status",
      "document_symbols",
    },
    sources = {
      "filesystem",
      "buffers",
      "git_status",
      "document_symbols",
    },
    source_selector = {
      winbar = true,
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
      separator = { left = "", right = "" }, -- string | { left: string, right: string, override: string | nil }
    }
  }
}
