local M = {}

function M.patch_mini_timers()
  local Mini = require("noice.view.backend.mini")
  if Mini._bounded_mini_timers then return end
  Mini._bounded_mini_timers = true
  local function close(timer)
    if not timer:is_closing() then timer:stop(); timer:close() end
  end
  -- The installed mini backend drops expired handles from self.timers without
  -- closing them, retaining a callback and its view for every message.
  Mini.autohide = function(self, id)
    local timer = self.timers[id] or vim.uv.new_timer()
    if not timer then return end
    self.timers[id] = timer
    timer:start(self._opts.timeout, 0, function()
      local message = self.active[id]
      if message and not self:can_hide(message) then return self:autohide(id) end
      self.timers[id] = nil
      close(timer)
      if not message then return end
      self.active[id] = nil
      vim.schedule(function() self:update() end)
    end)
  end
  local dismiss = Mini.dismiss
  Mini.dismiss = function(self)
    for _, timer in pairs(self.timers) do close(timer) end
    self.timers = {}
    return dismiss(self)
  end
end

function M.patch_confirm_lifecycle()
  local cmdline = require("noice.ui.cmdline")
  if cmdline._confirm_lifecycle_patch then
    return
  end
  cmdline._confirm_lifecycle_patch = true

  local state = require("noice.ui.state")
  local Message = require("noice.message")
  local on_confirm = cmdline.on_confirm
  local on_hide = cmdline.on_hide
  local confirm_content
  local confirm_prompt
  local confirm_active = false
  local confirm_prompt_visible = false
  local confirm_redraw_pending = false
  local confirm_generation = 0

  cmdline.on_confirm = function(message)
    local handled = on_confirm(message)
    if handled then
      confirm_active = true
      confirm_generation = confirm_generation + 1
      confirm_content = {
        event = message.event,
        kind = message.kind,
        text = message:content(),
      }
      confirm_prompt = nil
      confirm_prompt_visible = false
      confirm_redraw_pending = false
    end
    return handled
  end

  local on_show = cmdline.on_show
  cmdline.on_show = function(event, content, pos, firstc, prompt, indent, level)
    local looks_like_confirm = firstc == "" and prompt ~= ""
    local matches_confirm = looks_like_confirm and (not confirm_prompt or prompt == confirm_prompt)
    local paired_confirm = cmdline.confirm_message ~= nil

    if not paired_confirm and confirm_active and confirm_content and matches_confirm then
      if confirm_prompt_visible then
        -- A repeated show without a hide is a redraw, not a second prompt.
        return
      end

      if confirm_redraw_pending or not confirm_prompt then
        -- Invalid keys hide and immediately redraw the cmdline without another
        -- msg_show.confirm event. Reattach the saved question to that prompt.
        cmdline.confirm_message = Message(confirm_content.event, confirm_content.kind, confirm_content.text)
        paired_confirm = true
      end
    end

    local result = on_show(event, content, pos, firstc, prompt, indent, level)

    if paired_confirm then
      confirm_prompt = prompt
      confirm_prompt_visible = true
      confirm_redraw_pending = false
      -- Invalidate hide timers from earlier invalid-key redraws.
      confirm_generation = confirm_generation + 1
      state.clear("msg_show")
    end

    return result
  end

  cmdline.on_hide = function(event, level)
    local was_confirm = confirm_active
    if was_confirm and confirm_prompt_visible then
      confirm_prompt_visible = false
      confirm_redraw_pending = true
    end
    on_hide(event, level)

    if was_confirm then
      local generation = confirm_generation
      -- Invalid input emits hide/show back-to-back. Keep the question around
      -- long enough to pair with that redraw, then discard it on final close.
      vim.defer_fn(function()
        if confirm_generation == generation then
          confirm_active = false
          confirm_content = nil
          confirm_prompt = nil
          confirm_prompt_visible = false
          confirm_redraw_pending = false
          state.clear("msg_show")
        end
      end, 50)
    end
  end
end

return M
