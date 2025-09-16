
local Differ = require('differ')

local Controller = {}
Controller.__index = Controller

function Controller.new()
  local self = setmetatable({}, Controller)
  self.differs = {}
  for i = 1, 8 do
    table.insert(self.differs, Differ.new('linediff' .. i, i))
  end
  self.is_destroying = false
  return self
end

function Controller:add(from, to, options)
  for _, differ in ipairs(self.differs) do
    if differ:is_blank() then
      differ:init(from, to, options)
      return
    end
  end
  vim.api.nvim_echo({{'It\'s not possible to add more than 8 blocks to Linediff!', 'ErrorMsg'}}, false, {})
end

function Controller:close_and_reset(force)
  for _, differ in ipairs(self.differs) do
    differ:close_and_reset(force)
  end
end

function Controller:perform_diff()
  if vim.g.linediff_diffopt ~= 'builtin' then
    vim.g.linediff_original_diffopt = vim.o.diffopt
    vim.o.diffopt = vim.g.linediff_diffopt
  end

  self.differs[1]:create_diff_buffer(vim.g.linediff_first_buffer_command, 0)
  vim.b.controller = self

  vim.api.nvim_create_autocmd('BufUnload', {
    buffer = 0,
    callback = function()
      local differ = vim.b.differ
      if differ then
        differ:reset()
        local controller = vim.b.controller
        if controller then
          controller:start_destroying()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = 0,
    callback = function()
      local controller = vim.b.controller
      if controller and controller.is_destroying then
        controller:destroy(vim.b.differ.index)
      end
    end,
  })

  for i = 2, 8 do
    local differ = self.differs[i]
    if differ:is_blank() then
      break
    end

    differ:create_diff_buffer(vim.g.linediff_further_buffer_command, i - 1)
    vim.b.controller = self
  end

  local old_swb = vim.o.switchbuf
  vim.o.switchbuf = 'useopen,usetab'
  vim.cmd('sbuffer ' .. self.differs[1].diff_buffer)
  vim.o.switchbuf = old_swb

  for _, differ in ipairs(self.differs) do
    differ.other_differs = self.differs
  end
end

function Controller:start_destroying()
  for _, differ in ipairs(self.differs) do
    if not differ:is_blank() then
      self.is_destroying = true
      return
    end
  end
  self.is_destroying = false
end

function Controller:destroy(differ_index)
  if not self.is_destroying then
    return
  end

  local differ = self.differs[differ_index + 1]
  differ:close_and_reset(false)

  for _, d in ipairs(self.differs) do
    if not d:is_blank() then
      return
    end
  end

  self.is_destroying = false
end

return Controller
