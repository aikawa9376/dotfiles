return {
  "nvim-lualine/lualine.nvim",
  event = "BufReadPre",
  config = function()
    local lualine = require("lualine")

    --------------------------------------------------------------------
    -- 1. Git情報非同期キャッシュ (Git Info Cache)
    --------------------------------------------------------------------
    local git_cache = {}

    local function update_git_cache(bufnr)
      bufnr = bufnr or vim.api.nvim_get_current_buf()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname == "" or bufname:match("^%a+://") then
        git_cache[bufnr] = { is_git = false }
        return
      end

      local dir = vim.fn.fnamemodify(bufname, ":h")
      if vim.fn.isdirectory(dir) == 0 then dir = vim.fn.getcwd() end

      -- 非同期で git 情報を取得してブロッキング（ちらつき）を回避
      local cmd = string.format("git -C %s rev-parse --is-inside-work-tree --show-toplevel --git-common-dir --abbrev-ref HEAD 2>/dev/null", vim.fn.shellescape(dir))
      
      vim.fn.jobstart(cmd, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          if not data or #data < 4 or data[1] == "" then
            git_cache[bufnr] = { is_git = false }
          else
            local is_git = data[1] == "true"
            if not is_git then
              git_cache[bufnr] = { is_git = false }
            else
              local toplevel = data[2]
              local common_dir = data[3]
              local branch = data[4]

              -- common-dir ( .git の場所 ) を基準にプロジェクト名を特定
              local abs_common = common_dir
              if not (common_dir:sub(1,1) == "/" or common_dir:match("^%a:")) then
                abs_common = dir:gsub("/+$", "") .. "/" .. common_dir
              end

              -- 末尾のスラッシュを除去して親ディレクトリを取得
              local repo_root = vim.fn.fnamemodify(vim.fn.fnamemodify(abs_common, ":p"):gsub("/+$", ""), ":h")
              
              local is_worktree = toplevel:match("/%.worktree/") ~= nil
              local sync_status = ""
              
              -- ワークツリーの場合は同期状態を確認
              if is_worktree then
                local ok, wt = pcall(require, "features.worktree")
                if ok and wt and type(wt.lualine_sync_status) == "function" then
                  sync_status = wt.lualine_sync_status()
                end
              end

              git_cache[bufnr] = {
                is_git = true,
                branch = branch,
                is_worktree = is_worktree,
                project_name = vim.fn.fnamemodify(repo_root, ":t"),
                repo_root = repo_root,
                sync_status = sync_status,
              }
            end
          end
          vim.schedule(function() lualine.refresh() end)
        end,
      })
    end

    -- イベントに応じてキャッシュを更新
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "DirChanged" }, {
      callback = function(ev) update_git_cache(ev.buf) end,
    })

    -- バッファ削除時にキャッシュをクリア
    vim.api.nvim_create_autocmd("BufDelete", {
      callback = function(ev) git_cache[ev.buf] = nil end,
    })

    -- 追加のイベント: 保存や Fugitive の変更でキャッシュを更新
    vim.api.nvim_create_autocmd("BufWritePost", { callback = function() update_git_cache() end })
    vim.api.nvim_create_autocmd("User", { pattern = "FugitiveChanged", callback = function() update_git_cache() end })

    -- 起動時の初期更新
    update_git_cache()

    --------------------------------------------------------------------
    -- 2. 色定義
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

    local conditions = {
      buffer_not_empty = function() return vim.fn.empty(vim.fn.expand("%:t")) ~= 1 end,
      hide_in_width = function() return vim.fn.winwidth(0) > 80 end,
      obsession = function() return vim.fn.winwidth(0) >= 80 and vim.fn.exists("*ObsessionStatus") == 1 end,
      project = function()
        local bufnr = vim.api.nvim_get_current_buf()
        return vim.fn.winwidth(0) > 80 and git_cache[bufnr] and git_cache[bufnr].project_name ~= nil
      end,
      check_git_workspace = function()
        local bufnr = vim.api.nvim_get_current_buf()
        return vim.fn.winwidth(0) > 80 and git_cache[bufnr] and git_cache[bufnr].is_git
      end,
      recording = function() return vim.fn.reg_recording() ~= "" end,
    }

    --------------------------------------------------------------------
    -- 3. Lualine Setup
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
        lualine_a = {}, lualine_b = {}, lualine_y = {}, lualine_z = {},
        lualine_c = {
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
          {
            function()
              local bufnr = vim.api.nvim_get_current_buf()
              return (git_cache[bufnr] and git_cache[bufnr].branch) or ""
            end,
            icon = "",
            cond = conditions.check_git_workspace,
          },
          {
            function()
              local bufnr = vim.api.nvim_get_current_buf()
              local cache = git_cache[bufnr]
              if not cache or not cache.project_name then return "" end
              return (cache.is_worktree and "󰙅 " or " ") .. cache.project_name
            end,
            cond = conditions.project,
          },
          -- Worktree sync marker (separate component)
          {
            function()
              local bufnr = vim.api.nvim_get_current_buf()
              local status = git_cache[bufnr] and git_cache[bufnr].sync_status
              return (status and status ~= "") and (status .. " ") or ""
            end,
            cond = conditions.project,
            padding = { left = 0, right = 1 }
          },
          {
            function()
              local name = vim.fn.expand("%=")
              if name == "" then return "" end
              if string.find(name, "term") then name = "TERM"
              elseif string.find(name, "defx") then name = "DEFX"
              elseif string.find(name, "vista") then name = "Symbols"
              else name = vim.fn.fnamemodify(name, ":.") end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
              return (icon or "") .. " " .. name
            end,
            cond = conditions.buffer_not_empty,
          },
          {
            function()
              local gitsigns = vim.b.gitsigns_status_dict
              if not gitsigns then return "" end
              local parts = {}
              if gitsigns.added and gitsigns.added > 0 then parts[#parts+1] = "%#LualineGitAdded# " .. gitsigns.added .. "%*" end
              if gitsigns.changed and gitsigns.changed > 0 then parts[#parts+1] = "%#LualineGitChanged# " .. gitsigns.changed .. "%*" end
              if gitsigns.removed and gitsigns.removed > 0 then parts[#parts+1] = "%#LualineGitRemoved# " .. gitsigns.removed .. "%*" end
              return table.concat(parts, " ")
            end,
            cond = conditions.hide_in_width,
          },
          {
            "diagnostics",
            sources = { "nvim_diagnostic" },
            symbols = { error = " ", warn = " ", info = " " },
            color_error = colors.red,
            color_warn = colors.yellow,
            color_info = colors.cyan,
          },
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
              local name = vim.fn.expand("%=")
              if name == "" then return "" end
              local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
              return (icon or "") .. " " .. vim.fn.fnamemodify(name, ":.")
            end,
            cond = conditions.buffer_not_empty,
          },
        },
        lualine_b = {}, lualine_c = {}, lualine_x = {}, lualine_y = {}, lualine_z = {},
      },
    })
  end,
}
