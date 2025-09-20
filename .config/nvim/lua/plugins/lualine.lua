return {
  "nvim-lualine/lualine.nvim",
  event = "BufReadPre",
  config = function ()
    -- Eviline config for lualine
    -- Author: shadmansaleh
    -- Credit: glepnir
    local lualine = require("lualine")

    -- Color table for highlights
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
        local ok = vim.fn.exists("*ObsessionStatus")
        if ok ~= 0 then
          return true
        else
          return false
        end
      end,
      project = function()
        if vim.fn.winwidth(0) < 80 then
          return false
        end
        local ok = require("project.project").get_project_root()
        if ok ~= nil then
          return true
        else
          return false
        end
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

    -- Config
    local config = {
      options = {
        -- Disable sections and component separators
        component_separators = "",
        section_separators = "",
        theme = {
          -- We are going to use lualine_c an lualine_x as left and
          -- right section. Both are highlighted by c theme .  So we
          -- are just setting default looks o statusline
          normal = { c = { fg = colors.fg, bg = colors.bg } },
          inactive = { c = { fg = colors.fg, bg = colors.bg } },
        },
        globalstatus = true,
      },
      sections = {
        -- these are to remove the defaults
        lualine_a = {},
        lualine_b = {},
        lualine_y = {},
        lualine_z = {},
        -- These will be filled later
        lualine_c = {},
        lualine_x = {},
      },
      inactive_sections = {
        -- these are to remove the defaults
        lualine_a = {},
        lualine_v = {},
        lualine_y = {},
        lualine_z = {},
        lualine_c = {},
        lualine_x = {},
      },
    }

    local function split(inputstr, sep)
      if sep == nil then
        sep = "%s"
      end
      local t = {}
      for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
      end
      return t
    end

    -- Inserts a component in lualine_c at left section
    local function ins_left(component)
      table.insert(config.sections.lualine_c, component)
    end

    -- Inserts a component in lualine_x at right section
    local function ins_right(component)
      table.insert(config.sections.lualine_x, component)
    end

    -- Inserts a component in lualine_c at left section
    local function ins_inactive_left(component)
      table.insert(config.inactive_sections.lualine_a, component)
    end

    -- Inserts a component in lualine_x at right section
    local function ins_inactive_right(component)
      table.insert(config.inactive_sections.lualine_x, component)
    end

    local changeName = function (name)
      if string.find(name, "term") then
        return "TERM"
      elseif string.find(name, "defx") then
        return "DEFX"
      elseif string.find(name, "vista") then
        return "Symbols"
      end
      -- なぜかgdなどでファイル名が絶対パスで表示されるので
      local cwd = vim.fn.getcwd()
      if cwd and name then
        local cwd_pattern = cwd
        if not cwd:match("/$") then
          cwd_pattern = cwd .. "/"
        end
        cwd_pattern = cwd_pattern:gsub("([%.%-%+%[%]%(%)%$%^%%%?%*])", "%%%1")

        name = name:gsub(cwd_pattern, "")
        name = name:gsub("^/", "")
      end
      return name
    end

    ins_left({
      -- mode component
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
        vim.api.nvim_command("hi! LualineMode guifg=" .. mode_color[vim.fn.mode()] .. " guibg=" .. colors.bg .. " gui=bold")
        return require("lualine.utils.mode").get_mode()
      end,
      color = "LualineMode",
      left_padding = 0,
      condition = conditions.hide_in_width,
    })

    ins_left({
      "branch",
      icon = "",
      condition = conditions.check_git_workspace,
    })

    ins_left({
      function()
        local prod = split(require("project.api").get_project_root(), "/")
        if next(prod) then
          return " " .. prod[#prod]
        end
      end,
      condition = conditions.project,
    })

    ins_left({
      function()
        local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
        if (icon == nil) then
          return  changeName(vim.fn.expand("%="))
        else
          return icon .. " " .. changeName(vim.fn.expand("%="))
        end
      end,
      condition = conditions.buffer_not_empty,
    })

    ins_left({
      -- filesize component
      function()
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
        local file = vim.fn.expand("%:p")
        if string.len(file) == 0 then
          return ""
        end
        return format_file_size(file)
      end,
      condition = conditions.hide_in_width,
    })

    ins_left({
      "diff",
      -- Is it me or the symbol for modified us really weird
      symbols = { added = " ", modified = "柳", removed = " " },
      color_added = colors.green,
      color_modified = colors.orange,
      color_removed = colors.red,
      condition = conditions.hide_in_width,
    })

    ins_left({
      "diagnostics",
      sources = { "nvim_diagnostic" },
      symbols = { error = " ", warn = " ", info = " " },
      color_error = colors.red,
      color_warn = colors.yellow,
      color_info = colors.cyan,
    })

    -- TODO いきなりスローに
    -- Add components to right sections
    -- ins_right {
    --   'filetype',
    --   condition = conditions.hide_in_width,
    -- }
    ins_right({
      function ()
        return vim.fn.reg_recording() .. ' recording'
      end,
      cond = conditions.recording,
      color = { fg = "#ff9e64" },
    })

    ins_right({
      'fileformat',
      symbols = {
        unix = '', -- e712
        dos = '',  -- e70f
        mac = '',  -- e711
      }
    })

    ins_right({
      function()
        local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
        if (icon == nil) then
          return  vim.o.filetype
        else
          return  icon .. " " .. vim.o.filetype
        end
      end,
      condition = conditions.hide_in_width,
    })

    ins_right({
      function()
        return [[ %2p%% %2l:%v]]
      end,
      condition = conditions.hide_in_width,
    })

    ins_right({
      -- Lsp server name .
      function()
        local msg = ""
        local buf_ft = vim.nvim_get_option_value("filetype", { buf =  0})
        local clients = vim.lsp.active_clients()
        if next(clients) == nil then
          return msg
        end
        for _, client in ipairs(clients) do
          local filetypes = client.config.filetypes
          if filetypes and vim.fn.index(filetypes, buf_ft) ~= -1 then
            return " "
          end
        end
        return msg
      end,
      condition = conditions.hide_in_width,
    })

    ins_right({
      function()
        return vim.fn.ObsessionStatus("", "")
      end,
      condition = conditions.obsession,
    })

    table.insert(config.inactive_sections.lualine_a, {
      function()
        local icon = require("nvim-web-devicons").get_icon_by_filetype(vim.o.filetype)
        if (icon == nil) then
          return  changeName(vim.fn.expand("%="))
        else
          return  icon .. " " .. changeName(vim.fn.expand("%="))
        end
      end,
      condition = conditions.buffer_not_empty,
    })

    -- Now don't forget to initialize lualine
    lualine.setup(config)
  end
}
