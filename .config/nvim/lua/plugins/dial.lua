return {
  "monaqa/dial.nvim",
  ft = { "gitrebase", "gitrebaseplan" },
  keys = {
    {
      "<C-a>",
      function() require("dial.map").manipulate("increment", "normal") end,
      mode = { "n" },
      silent = true,
    },
    {
      "<C-x>",
      function() require("dial.map").manipulate("decrement", "normal") end,
      mode = { "n" },
      silent = true,
    },
    {
      "g<C-a>",
      function() require("dial.map").manipulate("increment", "gnormal") end,
      mode = { "n" },
      silent = true,
    },
    {
      "g<C-x>",
      function() require("dial.map").manipulate("decrement", "gnormal") end,
      mode = { "n" },
      silent = true,
    },
    {
      "<C-a>",
      function() require("dial.map").manipulate("increment", "visual") end,
      mode = { "v" },
      silent = true,
    },
    {
      "<C-x>",
      function() require("dial.map").manipulate("decrement", "visual") end,
      mode = { "v" },
      silent = true,
    },
    {
      "g<C-a>",
      function() require("dial.map").manipulate("increment", "gvisual") end,
      mode = { "v" },
      silent = true,
    },
    {
      "g<C-x>",
      function() require("dial.map").manipulate("decrement", "gvisual") end,
      mode = { "v" },
      silent = true,
    },
  },
  config = function ()
    local augend = require("dial.augend")
    require("dial.config").augends:register_group{
      -- default augends used when no group name is specified
      default = {
        augend.integer.alias.decimal, -- nonnegative decimal number (0, 1, 2, 3, ...)
        augend.integer.alias.hex, -- nonnegative hex number  (0x01, 0x1a1f, etc.)
        augend.constant.alias.bool, -- boolean value (true <-> false)
        augend.date.alias["%Y/%m/%d"], -- date (2022/02/18, etc.)
        augend.date.alias["%m/%d/%Y"], -- date (02/19/2022)
        -- augend.date.alias["%m-%d-%Y"], -- date (02-19-2022)
        -- augend.date.alias["%Y-%m-%d"], -- date (02-19-2022)
        augend.date.new({
          pattern = "%m.%d.%Y",
          default_kind = "day",
          only_valid = true,
          word = false,
        }),
        augend.misc.alias.markdown_header,
        augend.constant.alias.ja_weekday,
        augend.constant.alias.ja_weekday_full,
        -- augend.paren.alias.brackets,
        -- augend.paren.alias.quote,
      }
    }
    -- Rebase actions are the only incrementable field here: never alter a
    -- numeric-looking commit ID or a word inside a commit subject.
    local action_names = { "pick", "reword", "edit", "squash", "fixup", "drop" }
    local actions = augend.constant.new({
      elements = action_names,
      word = true,
      cyclic = true,
    })
    local aliases = { p = "pick", r = "reword", e = "edit", s = "squash", f = "fixup", d = "drop" }
    local rebase_action = augend.user.new({
      find = function(line, cursor)
        local first, last, name = line:find("^%s*(%a+)%s+%x+%s+")
        if not first or not (aliases[name] or vim.tbl_contains(action_names, name)) then return end
        first = line:find("%a")
        last = first + #name - 1
        if cursor and cursor > last then return end
        return { from = first, to = last }
      end,
      add = function(text, count, cursor)
        return actions:add(aliases[text] or text, count, cursor)
      end,
    })
    require("dial.config").augends:on_filetype({
      gitrebase = { rebase_action },
      gitrebaseplan = { rebase_action },
    })
    -- Neovim's gitrebase ftplugin installs buffer-local Cycle mappings, which
    -- take precedence over lazy's global keys. Apply after that ftplugin.
    local function rebase_keys(buf)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf)
          or not vim.tbl_contains({ "gitrebase", "gitrebaseplan" }, vim.bo[buf].filetype) then return end
        for key, direction in pairs({ ["<C-a>"] = "increment", ["<C-x>"] = "decrement" }) do
          vim.keymap.set("n", key, function() require("dial.map").manipulate(direction, "normal") end,
            { buffer = buf, silent = true, desc = "Cycle rebase action" })
        end
      end)
    end
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("DialRebaseActions", { clear = true }),
      pattern = { "gitrebase", "gitrebaseplan" },
      callback = function(ev) rebase_keys(ev.buf) end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then rebase_keys(buf) end
    end
  end
}
