return {
  "nvim-lualine/lualine.nvim",
  event = "BufReadPre",
  config = function()
    local lualine = require("lualine")

    --------------------------------------------------------------------
    -- 1. 色定義 (Color Definitions)
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
    -- 2. 表示条件 (Conditions)
    --------------------------------------------------------------------
    local conditions = {
      buffer_not_empty = function()
        return vim.fn.empty(vim.fn.expand("%:t")) ~= 1
      end,
      hide_in_width = function()
        return vim.fn.empty(vim.fn.expand("%:t")) ~= 1 and vim.fn.winwidth(0) > 80
      end,
      obsession = function()
        if vim.fn.winwidth(0) < 80 then
          return false
        end
        return vim.fn.exists("*ObsessionStatus") == 1
      end,
      project = function()
        if vim.fn.winwidth(0) < 80 then
          return false
        end
        local ok = pcall(require, "project.project")
        if not ok then
          return false
        end
        return require("project.project").get_project_root() ~= nil
      end,
      check_git_workspace = function()
        if vim.fn.winwidth(0) < 80 then
          return false
        end
        local filepath = vim.fn.expand("%:p:h")
        local gitdir = vim.fn.finddir(".git", filepath .. ";")
        return gitdir and #gitdir > 0 and #gitdir < #filepath
      end,
      recording = function()
        return vim.fn.reg_recording() ~= ""
      end,
    }

    --------------------------------------------------------------------
    -- 3. ヘルパー関数 (Helper Functions)
    --------------------------------------------------------------------

    --- ファイル名を整形する (特殊バッファ名の変換、相対パス化)
    local function changeName(name)
      if name == "" or name == nil then
        return ""
      end

      -- 特殊バッファ名の処理
      if string.find(name, "term") then
        return "TERM"
      elseif string.find(name, "defx") then
        return "DEFX"
      elseif string.find(name, "vista") then
        return "Symbols"
      end

      -- ファイル名をカレントディレクトリからの相対パスに変換
      name = vim.fn.fnamemodify(name, ":.")
      return name
    end

    --- ファイルサイズをフォーマットする
    local function format_file_size(file)
      local size = vim.fn.getfsize(file)
      if size <= 0 then
        return ""
      end
      local sufixes = { "b", "k", "m", "g" }
      local i = 1
      while size > 1024 do
        size = size / 1024
        i = i + 1
      end
      return string.format("%.1f%s", size, sufixes[i])
    end

    --------------------------------------------------------------------
    -- 4. Lualine 本体設定 (Lualine Setup)
    --------------------------------------------------------------------
    lualine.setup({
      options = {
        component_separators = "",
        section_separators = "",
        theme = {
          -- cセクション（中央）をメインに使うため、デフォルトの背景を透明に
          normal = { c = { fg = colors.fg, bg = colors.bg } },
          inactive = { c = { fg = colors.fg, bg = colors.bg } },
        },
        globalstatus = true,
      },

      ----------------------------------------
      -- アクティブウィンドウのセクション (Active Sections)
      ----------------------------------------
      sections = {
        -- デフォルトセクションを無効化
        lualine_a = {},
        lualine_b = {},
        lualine_y = {},
        lualine_z = {},

        -- 左側 (lualine_c)
        lualine_c = {
          -- 1. モード
          {
            function()
              -- auto change color according to neovims mode
              local mode_color = {
                n = colors.red,
                i = colors.green,
                v = colors.blue,
                ["␖"] = colors.blue,
                V = colors.blue,
                c = colors.magenta,
                no = colors.red,
                s = colors.orange,
                S = colors.orange,
                ["␓"] = colors.orange,
                ic = colors.yellow,
                R = colors.violet,
                Rv = colors.violet,
                cv = colors.red,
                ce = colors.red,
                r = colors.cyan,
                rm = colors.cyan,
                ["r?"] = colors.cyan,
                ["!"] = colors.red,
                t = colors.red,
              }
              vim.api.nvim_command(
                "hi! LualineMode guifg=" .. mode_color[vim.fn.mode()] .. " guibg=" .. colors.bg .. " gui=bold"
              )
              return require("lualine.utils.mode").get_mode()
            end,
            color = "LualineMode",
            left_padding = 0,
            cond = conditions.hide_in_width,
          },

          -- 2. Gitブランチ
          {
            "branch",
            icon = "",
            cond = conditions.check_git_workspace,
          },

          -- 3. プロジェクト名
          {
            function()
              local root = require("project.api").get_project_root()
              if root then
                -- パスの末尾（プロジェクト名）のみ表示
                return " " .. vim.fn.fnamemodify(root, ":t")
              end
              return ""
            end,
            cond = conditions.project,
          },

          -- 4. ファイル名
          {
            function()
              local filename = changeName(vim.fn.expand("%="))
              if filename == "" then
                return ""
              end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
              if (icon == nil) then
                return filename
              else
                return icon .. " " .. filename
              end
            end,
            cond = conditions.buffer_not_empty,
          },

          -- 5. ファイルサイズ
          {
            function()
              local file = vim.fn.expand("%:p")
              if string.len(file) == 0 then
                return ""
              end
              return format_file_size(file)
            end,
            cond = conditions.hide_in_width,
          },

          -- 6. Git Diff (single component with colored parts)
          {
            function()
              local gitsigns = vim.b.gitsigns_status_dict
              local parts = {}

              if gitsigns then
                if gitsigns.added and gitsigns.added > 0 then
                  parts[#parts+1] = "%#LualineGitAdded# " .. gitsigns.added .. "%*"
                end
                if gitsigns.changed and gitsigns.changed > 0 then
                  parts[#parts+1] = "%#LualineGitChanged# " .. gitsigns.changed .. "%*"
                end
                if gitsigns.removed and gitsigns.removed > 0 then
                  parts[#parts+1] = "%#LualineGitRemoved# " .. gitsigns.removed .. "%*"
                end
                if #parts > 0 then
                  return table.concat(parts, " ")
                end
              end

              -- fugitive fallback: --numstat の added/removed を取得
              local bufname = vim.fn.bufname()
              if bufname:match("^fugitive://") then
                local sha, filepath = bufname:match("fugitive://.*%.git//(%x+)/(.*)")
                if sha and filepath then
                  local cmd = string.format("git -C %s diff --numstat %s^ %s -- %s",
                    vim.fn.shellescape(vim.fn.FugitiveWorkTree()),
                    sha, sha, filepath)
                  local output = vim.fn.system(cmd)
                  if vim.v.shell_error == 0 and output ~= "" then
                    local added, removed = output:match("^(%d+)%s+(%d+)")
                    if (added and tonumber(added) > 0) or (removed and tonumber(removed) > 0) then
                      local fparts = {}
                      if added and tonumber(added) > 0 then
                        fparts[#fparts+1] = "%#LualineGitAdded# " .. added .. "%*"
                      end
                      if removed and tonumber(removed) > 0 then
                        fparts[#fparts+1] = "%#LualineGitRemoved# " .. removed .. "%*"
                      end
                      return table.concat(fparts, " ")
                    end
                  end
                end
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
        },

        -- 右側 (lualine_x)
        lualine_x = {
          -- 1. マクロ記録中
          {
            function()
              return vim.fn.reg_recording() .. " recording"
            end,
            cond = conditions.recording,
            color = { fg = "#ff9e64" },
          },

          -- 2. ファイルフォーマット (LF/CRLF)
          {
            "fileformat",
            symbols = {
              unix = "", -- e712
              dos = "", -- e70f
              mac = "", -- e711
            },
          },

          -- 3. ファイルタイプ
          {
            function()
              local ft = vim.o.filetype
              if ft == "" or ft == nil then
                return ""
              end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(ft)
              if (icon == nil) then
                return ft
              else
                return icon .. " " .. ft
              end
            end,
            cond = conditions.hide_in_width,
          },

          -- 4. カーソル位置
          {
            function()
              return [[ %2p%% %2l:%v]]
            end,
            cond = conditions.hide_in_width,
          },

          -- 5. LSPステータス
          {
            function()
              local clients = vim.lsp.get_clients({ bufnr = 0 })
              if next(clients) ~= nil then
                return " "
              end

              return ""
            end,
            cond = conditions.hide_in_width,
          },

          -- 6. Obsession ステータス
          {
            function()
              return vim.fn.ObsessionStatus("", "")
            end,
            cond = conditions.obsession,
          },
        },
      },

      ----------------------------------------
      -- 非アクティブウィンドウのセクション (Inactive Sections)
      ----------------------------------------
      inactive_sections = {
        lualine_a = {
          -- 非アクティブ時はファイル名のみ表示 (元の設定を維持)
          {
            function()
              local filename = changeName(vim.fn.expand("%="))
              if filename == "" then
                return ""
              end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
              if (icon == nil) then
                return filename
              else
                return icon .. " " .. filename
              end
            end,
            cond = conditions.buffer_not_empty,
          },
        },
        lualine_b = {},
        lualine_c = {},
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      },
    })
  end,
}
