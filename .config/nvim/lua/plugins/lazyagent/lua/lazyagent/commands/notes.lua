local M = {}

local notes = require("lazyagent.notes")

local function add(cmdargs)
  local bufnr = vim.api.nvim_get_current_buf()
  local function save(text)
    if text == nil then return end
    local entry, err = notes.add({
      bufnr = bufnr,
      start_line = cmdargs.line1,
      end_line = cmdargs.line2,
      text = text,
    })
    if not entry then
      vim.notify("LazyAgentNote: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("LazyAgentNote: saved %s:%d", vim.fn.fnamemodify(entry.path, ":t"), entry.start_line))
  end

  local text = vim.trim(cmdargs.args or "")
  if text ~= "" then
    save(text)
  else
    vim.ui.input({ prompt = "LazyAgent Note: " }, save)
  end
end

function M.register(create)
  create("LazyAgentNote", add, {
    nargs = "*",
    range = true,
    desc = "Save an AI Note for the current line range",
  })
  create("LazyAgentNotes", function() notes.open() end, {
    desc = "Open saved AI Notes for the current workspace",
  })
  create("LazyAgentNotesClear", function()
    local count = notes.clear()
    vim.notify(string.format("LazyAgentNotes: cleared %d Note(s)", count))
  end, {
    desc = "Clear saved AI Notes for the current workspace",
  })
end

return M
