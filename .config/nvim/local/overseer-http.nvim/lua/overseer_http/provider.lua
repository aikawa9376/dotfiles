local M = {}
local registered = false

function M.register()
  if registered then return end
  require('overseer').register_template({
    name = 'overseer-http',
    condition = { filetype = { 'http', 'rest' } },
    generator = function(search)
      if search.filetype ~= 'http' and search.filetype ~= 'rest' then return {} end
      local source = vim.api.nvim_buf_get_name(0)
      if source == '' or vim.bo.buftype ~= '' or vim.bo.filetype ~= search.filetype then return {} end
      local requests = require('overseer_http').parse_buffer()
      if not requests then return {} end
      local templates = {}
      for _, request in ipairs(requests) do
        local captured = request
        local title = require('overseer_http.runner').title(captured)
        templates[#templates + 1] = {
          name = title .. (captured.name and ' (line ' .. captured.line_start .. ')' or ''),
          builder = function()
            local definition, err = require('overseer_http.runner').definition(captured)
            if not definition then error(err) end
            return definition
          end,
        }
      end
      return templates
    end,
  })
  registered = true
end

return M
