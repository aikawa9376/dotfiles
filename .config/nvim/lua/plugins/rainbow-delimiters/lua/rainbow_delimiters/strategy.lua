-- Keep upstream's incremental rendering, but discard obsolete marks when the
-- buffer is replaced or injected trees move. Upstream clears only current tree
-- ranges, which cannot remove highlights left outside those ranges by reloads.
local global = require('rainbow-delimiters.strategy.global')
local lib = require('rainbow-delimiters.lib')
local M = {}
local states = {}

local function clear(buf)
  for lang in pairs(lib.nsids) do
    lib.clear_namespace(buf, lang)
  end
end

local function injections(parser)
  local ranges = {}
  parser:for_each_tree(function(tree, child)
    if child ~= parser then
      ranges[#ranges + 1] = child:lang() .. ':' .. table.concat({ tree:root():range() }, ',')
    end
  end)
  table.sort(ranges)
  return table.concat(ranges, ';')
end

function M.on_attach(buf, settings)
  local state = { line_count = vim.api.nvim_buf_line_count(buf) }
  states[buf] = state

  local function active()
    return states[buf] == state and lib.buffers[buf] == settings
      and vim.api.nvim_buf_is_loaded(buf)
  end

  local function refresh(force)
    if not active() then return end
    state.force = state.force or force
    if state.pending then return end
    state.pending = true
    vim.schedule(function()
      if not active() then return end
      if not state.force and injections(settings.parser) == state.ranges then
        state.pending = false
        return
      end
      -- Wait for all injections, including those outside the visible window.
      -- Do not detach: rainbow's detach destroys the shared TS parser.
      settings.parser:parse(true, function(err)
        if not active() then return end
        state.pending = false
        if err then return end
        local ranges = injections(settings.parser)
        if state.force or ranges ~= state.ranges then
          clear(buf)
          global.on_reset(buf, settings)
        end
        state.force = false
        state.ranges = ranges
      end)
    end)
  end
  state.refresh = refresh

  vim.api.nvim_buf_attach(buf, false, {
    on_reload = function()
      if not active() then return true end
      state.line_count = vim.api.nvim_buf_line_count(buf)
      clear(buf)
      refresh(true)
    end,
    on_lines = function(_, _, _, first, last, new_last)
      if not active() then return true end
      local replaced = first == 0 and last == state.line_count
      state.line_count = state.line_count + new_last - last
      if replaced then
        clear(buf)
        refresh(true)
      end
    end,
    on_detach = function()
      if states[buf] == state then states[buf] = nil end
    end,
  })
  settings.parser:register_cbs({
    on_changedtree = function() refresh(false) end,
    on_child_removed = function() refresh(true) end,
  }, true)
  global.on_attach(buf, settings)
  state.ranges = injections(settings.parser)
end

function M.on_reset(buf, settings)
  -- A reset must also clear marks outside the current trees' ranges.
  local state = states[buf]
  if state and lib.buffers[buf] == settings then state.refresh(true) end
end

function M.on_detach(buf)
  states[buf] = nil
  global.on_detach(buf)
end

return M
