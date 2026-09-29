if vim.bo.buftype ~= '' then return end

local buffer = vim.api.nvim_get_current_buf()
local maps = {
  { '<CR>', 'OverseerHttpRun', 'Send HTTP request' },
  { '<leader>Rs', 'OverseerHttpRun', 'Send HTTP request' },
  { '<leader>Ra', 'OverseerHttpRunAll', 'Send all HTTP requests' },
  { '<leader>Rf', 'OverseerHttpSelect', 'Find HTTP request' },
  { '<leader>Rn', 'OverseerHttpNext', 'Next HTTP request' },
  { '<leader>Rp', 'OverseerHttpPrev', 'Previous HTTP request' },
  { ']]', 'OverseerHttpNext', 'Next HTTP request' },
  { '[[', 'OverseerHttpPrev', 'Previous HTTP request' },
  { '<leader>Rr', 'OverseerHttpRepeat', 'Repeat last HTTP request' },
  { '<leader>Rt', 'OverseerHttpToggleResponse', 'Toggle HTTP body/headers' },
  { '<leader>Rb', 'OverseerHttpBody', 'Open HTTP response body' },
  { '<leader>Rh', 'OverseerHttpHeaders', 'Open HTTP response headers' },
  { '<leader>Rc', 'OverseerHttpCopyCurl', 'Copy HTTP request as cURL' },
  { '<leader>Ro', 'OverseerToggle', 'Toggle Overseer tasks' },
}
for _, map in ipairs(maps) do
  vim.keymap.set('n', map[1], '<cmd>' .. map[2] .. '<CR>', {
    buffer = buffer,
    silent = true,
    desc = map[3],
  })
end
