local M = {}

function M.setup()
  require("blink_extension.completion.romaji_japanese").setup_commands()
end

return M
