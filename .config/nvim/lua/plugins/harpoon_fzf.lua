-- Fuzzy Harpoon selection shares the same structured targets as the quick menu.
local M = {}
function M.open(winopts, fullopts)
  local fzf = require('fzf-lua')
  local list = require('harpoon'):list('multiple')
  local items = require('plugins.harpoon_items')
  local contents, by_label = {}, {}
  for index = 1, list:length() do
    local item = list:get(index)
    if item then
      local label = items.display(item)
      contents[#contents + 1] = '\27[38;2;115;218;202m' .. label .. '\27[0m'
      by_label[label] = item
    end
  end
  local function resolve(text) return by_label[(text:gsub('\27%[[0-9;]*[A-Za-z]', ''))] end
  local function select(options)
    return function(selected)
      for _, text in ipairs(selected) do items.select(resolve(text), nil, options) end
    end
  end
  return fzf.fzf_exec(contents, {
    prompt = 'Harpoon >', winopts = winopts,
    previewer = { _ctor = function()
      local Previewer = require('fzf-lua.previewer.builtin').buffer_or_file:extend()
      function Previewer:parse_entry(text)
        local item = resolve(text)
        if not item then return {} end
        local ok, lines, row, col, ft = pcall(items.preview, item)
        if not ok then lines, row, col, ft = { tostring(lines) }, 1, 0, 'text' end
        if #lines == 0 then lines = { '' } end
        row = math.max(1, math.min(row or 1, #lines))
        col = math.min(col or 0, #lines[row])
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = 'wipe'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        -- Use syntax without running the target panel's FileType handlers.
        self.syntax = false
        vim.bo[buf].syntax = ft or 'text'
        return { _scratch_buf = buf, path = items.display(item), lnum = row, col = col + 1, do_not_cache = true }
      end
      return Previewer
    end },
    actions = {
      enter = select(), ['ctrl-s'] = select({ split = true }), ['ctrl-v'] = select({ vsplit = true }),
      ['ctrl-d'] = function(selected)
        for _, text in ipairs(selected) do local item = resolve(text); if item then list:remove(item) end end
        M.open(winopts, fullopts)
      end,
      ['ctrl-t'] = function() M.open(fullopts or winopts, fullopts) end,
      ['ctrl-q'] = function(selected)
        local entries = {}
        for _, text in ipairs(selected) do
          local item = resolve(text)
          if item and not item.context.git then
            entries[#entries + 1] = { filename = items.path(item), lnum = item.context.row, col = (item.context.col or 0) + 1 }
          end
        end
        if #entries > 0 then vim.fn.setqflist(entries, 'r'); vim.cmd('copen') end
      end,
    },
    fzf_opts = { ['--multi'] = '', ['--scheme'] = 'history', ['--no-unicode'] = '' },
  })
end
return M
