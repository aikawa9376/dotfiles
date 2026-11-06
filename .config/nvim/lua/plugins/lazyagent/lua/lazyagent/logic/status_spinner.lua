local M = {}
local uv = vim.uv or vim.loop
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame = 1
local timer

M.expression = "%{v:lua.require'lazyagent.logic.status_spinner'.get_frame()}"

function M.get_frame()
  return frames[timer and frame or (math.floor(uv.now() / 100) % #frames + 1)]
end

function M.stop()
  if timer then
    local previous = timer
    timer = nil
    previous:stop()
    previous:close()
  end
end

function M.start()
  if timer or vim.o.laststatus == 0 or type(vim.api.nvim__redraw) ~= "function" then return end
  local current = uv.new_timer()
  timer = current
  local pending = false
  current:start(100, 100, function()
    -- Do not accumulate callbacks while Neovim is busy, or run an old tick
    -- after the spinner has been stopped/restarted.
    if pending then return end
    pending = true
    vim.schedule(function()
      pending = false
      if timer ~= current then return end
      local wins = vim.api.nvim_tabpage_list_wins(0)
      if vim.o.laststatus == 0 or (vim.o.laststatus == 1 and #wins == 1) then
        M.stop()
        return
      end
      local visible = false
      for _, win in ipairs(wins) do
        local statusline = vim.api.nvim_get_option_value("statusline", { win = win })
        if statusline:find(M.expression, 1, true) then
          visible = true
          break
        end
      end
      if not visible then
        M.stop()
        return
      end
      if vim.api.nvim_get_mode().blocking then return end
      frame = frame % #frames + 1
      -- Redraw native statusline expressions only. lualine's other components
      -- keep their normal refresh rate. Avoid a full screen/cursor update.
      -- With native 'termsync', the terminal presents each frame atomically.
      if not pcall(vim.api.nvim__redraw, { statusline = true }) then
        M.stop()
      end
    end)
  end)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("LazyAgentStatusSpinner", { clear = true }),
  callback = M.stop,
})

return M
