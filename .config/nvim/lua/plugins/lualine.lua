return {
  "nvim-lualine/lualine.nvim",
  event = "BufReadPre",
  config = function()
    local lualine = require("lualine")

    --------------------------------------------------------------------
    -- 1. Git情報キャッシュ (Git Info Cache)
    --------------------------------------------------------------------
    local git_cache = {}

    local function update_git_cache()
      local bufnr = vim.api.nvim_get_current_buf()

      -- Check if inside work tree
      vim.fn.system('git rev-parse --is-inside-work-tree 2>/dev/null')
      local is_git = (vim.v.shell_error == 0)

      if not is_git then
        git_cache[bufnr] = { is_git = false }
        return
      end

      -- Get branch
      local branch = vim.trim(vim.fn.system('git branch --show-current 2>/dev/null'))

      -- Get toplevel and icon info
      local toplevel = vim.trim(vim.fn.system('git rev-parse --show-toplevel 2>/dev/null'))
      local is_worktree = toplevel:match("/%.worktree/") ~= nil

      -- Get project name from common dir
      local name = vim.fn.fnamemodify(toplevel, ":t")
      local common_dir = vim.trim(vim.fn.system('git rev-parse --git-common-dir 2>/dev/null'))
      if vim.v.shell_error == 0 and common_dir ~= "" then
        local abs_common = vim.fn.fnamemodify(common_dir, ':p'):gsub("/+$", "")
        local main_root = vim.fn.fnamemodify(abs_common, ':h')
        name = vim.fn.fnamemodify(main_root, ":t")
      end

      git_cache[bufnr] = {
        is_git = true,
        branch = branch,
        is_worktree = is_worktree,
        project_name = name,
      }
    end

    -- Update cache on important events
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "DirChanged", "BufWritePost" }, {
      callback = function()
        update_git_cache()
      end,
    })

    --------------------------------------------------------------------
    -- 2. 色定義 (Color Definitions)
    --------------------------------------------------------------------
    local colors = {
      bg = "none",
      fg = "#E5E9F0",
      yellow = "#ECBE7B",
      cyan = "#008080",
      darkblue = "#081633",
      green = "#98be65",
      orange = "#FF8800",
      violet = "#a9a1e1",
      magenta = "#c678dd",
      blue = "#51afef",
      red = "#ec5f67",
    }

    vim.api.nvim_set_hl(0, "LualineGitAdded",   { fg = colors.green,  bg = colors.bg, bold = true })
    vim.api.nvim_set_hl(0, "LualineGitChanged", { fg = colors.yellow, bg = colors.bg, bold = true })
    vim.api.nvim_set_hl(0, "LualineGitRemoved", { fg = colors.red,    bg = colors.bg, bold = true })

    --------------------------------------------------------------------
    -- 3. 表示条件 (Conditions)
    --------------------------------------------------------------------
    local conditions = {
      buffer_not_empty = function()
        return vim.fn.empty(vim.fn.expand("%:t")) ~= 1
      end,
      hide_in_width = function()
        return vim.fn.empty(vim.fn.expand("%:t")) ~= 1 and vim.fn.winwidth(0) > 80
      end,
      obsession = function()
        return vim.fn.winwidth(0) >= 80 and vim.fn.exists("*ObsessionStatus") == 1
      end,
      project = function()
        if vim.fn.winwidth(0) < 80 then return false end
        local bufnr = vim.api.nvim_get_current_buf()
        return git_cache[bufnr] ~= nil and git_cache[bufnr].project_name ~= nil
      end,
      check_git_workspace = function()
        if vim.fn.winwidth(0) < 80 then return false end
        local bufnr = vim.api.nvim_get_current_buf()
        return git_cache[bufnr] and git_cache[bufnr].is_git
      end,
      recording = function()
        return vim.fn.reg_recording() ~= ""
      end,
    }

    --------------------------------------------------------------------
    -- 4. ヘルパー関数 (Helper Functions)
    --------------------------------------------------------------------
    local function changeName(name)
      if name == "" or name == nil then return "" end
      if string.find(name, "term") then return "TERM"
      elseif string.find(name, "defx") then return "DEFX"
      elseif string.find(name, "vista") then return "Symbols" end
      return vim.fn.fnamemodify(name, ":.")
    end

    local function format_file_size(file)
      local size = vim.fn.getfsize(file)
      if size <= 0 then return "" end
      local sufixes = { "b", "k", "m", "g" }
      local i = 1
      while size > 1024 do size = size / 1024; i = i + 1 end
      return string.format("%.1f%s", size, sufixes[i])
    end

    --------------------------------------------------------------------
    -- 5. Lualine 本体設定 (Lualine Setup)
    --------------------------------------------------------------------
    lualine.setup({
      options = {
        component_separators = "",
        section_separators = "",
        theme = {
          normal = { c = { fg = colors.fg, bg = colors.bg } },
          inactive = { c = { fg = colors.fg, bg = colors.bg } },
        },
        globalstatus = true,
      },

      sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_y = {},
        lualine_z = {},

        lualine_c = {
          -- 1. モード
          {
            function()
              local mode_color = {
                n = colors.red, i = colors.green, v = colors.blue, ["␖"] = colors.blue,
                V = colors.blue, c = colors.magenta, no = colors.red, s = colors.orange,
                S = colors.orange, ["␓"] = colors.orange, ic = colors.yellow,
                R = colors.violet, Rv = colors.violet, cv = colors.red, ce = colors.red,
                r = colors.cyan, rm = colors.cyan, ["r?"] = colors.cyan, ["!"] = colors.red, t = colors.red,
              }
              vim.api.nvim_command("hi! LualineMode guifg=" .. mode_color[vim.fn.mode()] .. " guibg=" .. colors.bg .. " gui=bold")
              return require("lualine.utils.mode").get_mode()
            end,
            color = "LualineMode",
            left_padding = 0,
            cond = conditions.hide_in_width,
          },

          -- 2. Gitブランチ
          {
            function()
              local bufnr = vim.api.nvim_get_current_buf()
              return (git_cache[bufnr] and git_cache[bufnr].branch) or ""
            end,
            icon = "",
            cond = conditions.check_git_workspace,
          },

          -- 3. プロジェクト名
          {
            function()
              local bufnr = vim.api.nvim_get_current_buf()
              local cache = git_cache[bufnr]
              if not cache or not cache.project_name then return "" end
              local icon = cache.is_worktree and " " or " "
              return icon .. cache.project_name
            end,
            cond = conditions.project,
          },

          -- 4. ファイル名
          {
            function()
              local filename = changeName(vim.fn.expand("%="))
              if filename == "" then return "" end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
              return (icon or "") .. " " .. filename
            end,
            cond = conditions.buffer_not_empty,
          },

          -- 5. ファイルサイズ
          {
            function()
              local file = vim.fn.expand("%:p")
              return (string.len(file) > 0) and format_file_size(file) or ""
            end,
            cond = conditions.hide_in_width,
          },

          -- 6. Git Diff
          {
            function()
              local gitsigns = vim.b.gitsigns_status_dict
              local parts = {}
              if gitsigns then
                if gitsigns.added and gitsigns.added > 0 then parts[#parts+1] = "%#LualineGitAdded# " .. gitsigns.added .. "%*" end
                if gitsigns.changed and gitsigns.changed > 0 then parts[#parts+1] = "%#LualineGitChanged# " .. gitsigns.changed .. "%*" end
                if gitsigns.removed and gitsigns.removed > 0 then parts[#parts+1] = "%#LualineGitRemoved# " .. gitsigns.removed .. "%*" end
                if #parts > 0 then return table.concat(parts, " ") end
              end
              return ""
            end,
            cond = conditions.hide_in_width,
          },

          -- 7. LSP Diagnostics
          {
            "diagnostics",
            sources = { "nvim_diagnostic" },
            symbols = { error = " ", warn = " ", info = " " },
            color_error = colors.red,
            color_warn = colors.yellow,
            color_info = colors.cyan,
          },

          -- 8. conflict
          {
            function()
              local ok, conflict = pcall(require, "lazyconflict")
              return ok and conflict.statusline() or ""
            end,
            color = { fg = "#ff2f87" },
          }
        },

        lualine_x = {
          { function() return vim.fn.reg_recording() .. " recording" end, cond = conditions.recording, color = { fg = "#ff9e64" } },
          { "fileformat", symbols = { unix = "", dos = "", mac = "" } },
          {
            function()
              local ft = vim.o.filetype
              if ft == "" or ft == nil then return "" end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(ft)
              return (icon or "") .. " " .. ft
            end,
            cond = conditions.hide_in_width,
          },
          { function() return [[ %2p%% %2l:%v]] end, cond = conditions.hide_in_width },
          {
            function()
              local clients = vim.lsp.get_clients({ bufnr = 0 })
              return next(clients) ~= nil and " " or ""
            end,
            cond = conditions.hide_in_width,
          },
          { require("lazyagent").status },
          { function() return vim.fn.ObsessionStatus("", "") end, cond = conditions.obsession },
        },
      },

      inactive_sections = {
        lualine_a = {
          {
            function()
              local filename = changeName(vim.fn.expand("%="))
              if filename == "" then return "" end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
              return (icon or "") .. " " .. filename
            end,
            cond = conditions.buffer_not_empty,
          },
        },
        lualine_b = {}, lualine_c = {}, lualine_x = {}, lualine_y = {}, lualine_z = {},
      },
    })
  end,
}
