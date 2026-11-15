local builtin = require('blink.cmp.sources.cmdline')
local utils = require('blink.cmp.sources.cmdline.utils')
local list = require('blink.cmp.completion.list')
local context = require('blink_extension.completion.cmdline_context')

local source = {}
source.__index = source

function source.new(opts)
  local self = setmetatable({
    builtin = builtin.new(),
    help = require('blink_extension.completion.cmdline_help').new(),
    delay_ms = opts.documentation_delay_ms or 150,
    state = {}, -- Shared with Blink's source override proxy.
  }, source)
  list.select_emitter:on(function(event)
    if self.state.pending and event.item ~= self.state.pending.item then self:cancel() end
  end)
  list.hide_emitter:on(function() self:cancel() end)
  return self
end

function source:enabled() return self.builtin:enabled() end
function source:get_trigger_characters() return self.builtin:get_trigger_characters() end

function source:get_completions(ctx, callback)
  local target = context.capture(ctx, utils.get_completion_type(ctx), vim.api.nvim_get_current_buf())
  return self.builtin:get_completions(ctx, function(response)
    if target then
      for _, item in ipairs(response.items) do
        item.data = vim.tbl_extend('force', item.data or {}, {
          command_documentation = context.item(target, item),
        })
      end
    end
    callback(response)
  end)
end

local function stop(request)
  request.cancelled = true
  if request.timer and not request.timer:is_closing() then
    request.timer:stop()
    request.timer:close()
  end
end

function source:cancel()
  local request = self.state.pending
  if not request then return end
  self.state.pending = nil
  stop(request)

  -- Blink caches running resolves by item. Cancel the outer task as well, so an
  -- abandoned request is retried when revisiting that candidate. It also blocks
  -- Blink's already-scheduled resolve callback from displaying an old result.
  local providers = require('blink.cmp.sources.lib').providers
  local provider = providers[request.item.source_id]
  local cached = provider and provider.resolve_cache[request.item]
  if cached then cached:cancel() end
end

function source:resolve(item, callback)
  local data = item.data and item.data.command_documentation
  -- Acceptance hides the menu before resolving; documentation must not delay it.
  if not data or not list.context then return callback(item) end

  self:cancel()
  local request = { item = item }
  self.state.pending = request
  request.timer = vim.defer_fn(function()
    if request.cancelled then return end
    if list.get_selected_item() ~= item then return self:cancel() end
    local query = context.resolve(data)
    if not query then return callback(item) end
    self.help:get(query.command, data.bufnr, query):map(function(documentation)
      if request.cancelled then return end
      if list.get_selected_item() ~= item then return self:cancel() end
      local resolved = vim.deepcopy(item)
      resolved.documentation = documentation
      callback(resolved)
    end):catch(function()
      if not request.cancelled then callback(item) end
    end)
  end, self.delay_ms)
  return function() stop(request) end
end

function source:reload()
  self:cancel()
  self.help = require('blink_extension.completion.cmdline_help').new()
end

return source
