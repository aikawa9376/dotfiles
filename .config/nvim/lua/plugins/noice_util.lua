local M = {}

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
  local confirm_active = false
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
    end
    return handled
  end

  local on_show = cmdline.on_show
  cmdline.on_show = function(...)
    if confirm_active and confirm_content and not cmdline.confirm_message then
      -- Invalid keys hide and immediately redraw the cmdline without another
      -- msg_show.confirm event. Reattach the saved question to that prompt.
      cmdline.confirm_message = Message(confirm_content.event, confirm_content.kind, confirm_content.text)
    end

    local paired_confirm = cmdline.confirm_message ~= nil
    local result = on_show(...)

    if paired_confirm then
      -- Invalidate hide timers from earlier invalid-key redraws.
      confirm_generation = confirm_generation + 1
      state.clear("msg_show")
    end

    return result
  end

  cmdline.on_hide = function(event, level)
    local was_confirm = confirm_active
    on_hide(event, level)

    if was_confirm then
      local generation = confirm_generation
      -- Invalid input emits hide/show back-to-back. Keep the question around
      -- long enough to pair with that redraw, then discard it on final close.
      vim.defer_fn(function()
        if confirm_generation == generation then
          confirm_active = false
          confirm_content = nil
          state.clear("msg_show")
        end
      end, 50)
    end
  end
end

return M
