local M = {}

local function center(text, width)
  local display_width = vim.fn.strdisplaywidth(text)
  local lpad = math.max(0, math.floor((width - display_width) / 2))
  local rpad = math.max(0, width - display_width - lpad)
  return string.rep(" ", lpad) .. text .. string.rep(" ", rpad)
end

function M.local_ip()
  local ip = vim.fn.system("ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}'"):gsub("%s+$", "")
  if ip == "" then
    ip = vim.fn.system("hostname -I 2>/dev/null | awk '{print $1}'"):gsub("%s+$", "")
  end
  if ip == "" then
    ip = "127.0.0.1"
  end
  return ip
end

function M.show(url, opts)
  opts = opts or {}
  if not url or url == "" then
    vim.notify(opts.error_prefix or "LazyAgentQR: URL is empty", vim.log.levels.WARN)
    return false
  end

  if vim.fn.executable("qrencode") == 0 then
    vim.notify("LazyAgentQR: qrencode not found (brew/apt install qrencode)", vim.log.levels.ERROR)
    return false
  end

  local qr_raw = vim.fn.system("qrencode -t UTF8 -m 1 -o - " .. vim.fn.shellescape(url))
  if vim.v.shell_error ~= 0 or qr_raw == "" then
    vim.notify("LazyAgentQR: qrencode failed", vim.log.levels.ERROR)
    return false
  end

  local qr_lines = vim.split(qr_raw, "\n", { plain = true })
  if qr_lines[#qr_lines] == "" then
    table.remove(qr_lines)
  end

  local width = 0
  for _, line in ipairs(qr_lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local hints = opts.hints or {}
  for _, text in ipairs(vim.list_extend({ url }, vim.deepcopy(hints))) do
    width = math.max(width, vim.fn.strdisplaywidth(text))
  end

  local lines = { center(url, width), "" }
  for _, line in ipairs(qr_lines) do
    local line_width = vim.fn.strdisplaywidth(line)
    table.insert(lines, string.rep(" ", math.max(0, math.floor((width - line_width) / 2))) .. line)
  end
  if #hints > 0 then
    table.insert(lines, "")
    for _, hint in ipairs(hints) do
      table.insert(lines, center(hint, width))
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.floor((ui.height - #lines) / 2),
    col = math.floor((ui.width - width) / 2),
    style = "minimal",
    border = "rounded",
    title = opts.title or " LazyAgent Web UI ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", "<cmd>close<cr>", { buffer = buf, silent = true })

  return true
end

return M
