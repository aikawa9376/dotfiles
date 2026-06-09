return {
  "gbprod/yanky.nvim",
  keys = {
    {
      "y",
      function()
        if _G["yanky_remember_registers_before_yank"] then
          _G["yanky_remember_registers_before_yank"]()
        end

        return "m`mvmr<Plug>(YankyYank)"
      end,
      expr = true,
      mode = { "n", "x" },
      remap = true,
    },
    {
      "=p",
      function()
        return "<Plug>(YankyPutAfterFilterJoined)"
      end,
      expr = true,
      remap = true,
    },
    {
      "=P",
      function()
        return "<Plug>(YankyPutBeforeFilterJoined)"
      end,
      expr = true,
      remap = true,
    },
  },
  opts = {
    ring = {
      history_length = 100,
      storage = "shada",
      storage_path = vim.fn.stdpath("data") .. "/databases/yanky.db", -- Only for sqlite storage
      sync_with_numbered_registers = true,
      cancel_event = "update",
      ignore_registers = { "_" },
      update_register_on_cycle = false,
      permanent_wrapper = nil,
    },
    picker = {
      select = {
        action = nil, -- nil to use default put action
      },
    },
    system_clipboard = {
      sync_with_ring = true,
      clipboard_register = nil,
    },
    highlight = {
      on_put = false,
      on_yank = false,
      timer = 500,
    },
    preserve_cursor_position = {
      enabled = true,
    },
    textobj = {
      enabled = true,
    },
  },
  config = function(_, opts)
    local yanky = require("yanky")
    yanky.setup(opts)

    local last_registers = {}

    local function normalize_register(register)
      if register == nil or register == "" then
        return '"'
      end

      if register:match("^%u$") then
        return register:lower()
      end

      return register
    end

    local function is_writable_register(register)
      register = normalize_register(register)

      return register == '"'
        or register == "-"
        or register == "+"
        or register == "*"
        or register:match("^%d$")
        or register:match("^%l$")
    end

    local function add_register(registers, seen, register)
      register = normalize_register(register)

      if not is_writable_register(register) or seen[register] then
        return
      end

      registers[#registers + 1] = register
      seen[register] = true
    end

    local function default_register()
      local ok, utils = pcall(require, "yanky.utils")
      if not ok then
        return '"'
      end

      return normalize_register(utils.get_default_register())
    end

    local function get_register_info(register)
      register = normalize_register(register)

      if not is_writable_register(register) then
        return nil
      end

      local ok_contents, regcontents = pcall(vim.fn.getreg, register)
      local ok_type, regtype = pcall(vim.fn.getregtype, register)

      if not ok_contents or not ok_type then
        return nil
      end

      return {
        regcontents = regcontents,
        regtype = regtype,
      }
    end

    local function set_register_info(register, info)
      if not info then
        return
      end

      pcall(vim.fn.setreg, normalize_register(register), info.regcontents, info.regtype)
    end

    local function remember_registers(registers)
      for _, register in ipairs(registers) do
        local info = get_register_info(register)

        if info then
          last_registers[normalize_register(register)] = info
        end
      end
    end

    local function restore_registers(registers)
      for _, register in ipairs(registers) do
        set_register_info(register, last_registers[normalize_register(register)])
      end
    end

    local function initial_registers()
      local registers = {}
      local seen = {}

      for _, register in ipairs({ '"', "-" }) do
        add_register(registers, seen, register)
      end

      for i = 0, 9 do
        add_register(registers, seen, tostring(i))
      end

      for byte = string.byte("a"), string.byte("z") do
        add_register(registers, seen, string.char(byte))
      end

      return registers
    end

    local function event_registers(event)
      local registers = {}
      local seen = {}
      local operator = event.operator

      add_register(registers, seen, '"')
      add_register(registers, seen, event.regname)
      add_register(registers, seen, default_register())

      if operator == "y" then
        add_register(registers, seen, "0")
      elseif operator == "d" or operator == "c" then
        add_register(registers, seen, "-")

        for i = 1, 9 do
          add_register(registers, seen, tostring(i))
        end
      end

      return registers
    end

    local function yanked_text(event)
      if type(event.regcontents) == "table" then
        return table.concat(event.regcontents, "\n")
      end

      if type(event.regcontents) == "string" then
        return event.regcontents
      end

      local info = get_register_info(event.regname)
      return info and info.regcontents or nil
    end

    local function is_blank_text(text)
      return type(text) == "string" and text:match("^%s*$") ~= nil
    end

    local function is_blank_yank(event)
      return is_blank_text(yanked_text(event))
    end

    local history = require("yanky.history")
    local original_on_yank = yanky.on_yank
    local ignored_registers = {}

    for _, register in ipairs(opts.ring.ignore_registers or {}) do
      ignored_registers[normalize_register(register)] = true
    end

    remember_registers(initial_registers())

    for index = #history.all(), 1, -1 do
      local item = history.all()[index]

      if item and is_blank_text(item.regcontents) then
        history.delete(index)
      end
    end

    history.sync_with_numbered_registers()

    _G["yanky_remember_registers_before_yank"] = function()
      remember_registers(event_registers({
        operator = "y",
        regname = vim.v.register,
      }))
    end

    rawset(yanky, "on_yank", function()
      local event = vim.v.event or {}

      if ignored_registers[normalize_register(event.regname)] then
        original_on_yank()
        return
      end

      local registers = event_registers(event)

      if is_blank_yank(event) then
        restore_registers(registers)
        pcall(require("yanky.preserve_cursor").on_yank)
        return
      end

      original_on_yank()
      remember_registers(registers)
    end)
  end
}
