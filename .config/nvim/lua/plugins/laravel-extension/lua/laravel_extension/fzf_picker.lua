local M = {}

local function item_path(item)
  if item.path then return item.path end
  local location = item.location or {}
  local uri = location.uri or location.targetUri
  return uri and vim.uri_to_fname(uri) or ""
end

local function item_position(item)
  if item.row then return item.row, item.col or 1 end
  local location = item.location or {}
  local range = location.range or location.targetSelectionRange or location.targetRange or {}
  local start = range.start or {}
  return (tonumber(start.line) or 0) + 1, (tonumber(start.character) or 0) + 1
end

local function item_text(item, path, row)
  if item.text and item.text ~= "" then return item.text end
  local bufnr = vim.fn.bufnr(path)
  if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.trim(vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""):gsub("%s+", " ")
  end
  return ""
end

local function relative_path(path, cwd)
  if not cwd or cwd == "" then return path end
  cwd = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", "")
  local prefix = cwd .. "/"
  return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
end

function M.entries(items, opts)
  opts = opts or {}
  return vim.tbl_map(function(item)
    local path = item_path(item)
    local row, col = item_position(item)
    local text = item_text(item, path, row)
    local label = string.format("[%s]%s", item.kind or "reference", text ~= "" and " " .. text or "")
    return string.format("%s:%d:%d:%s", relative_path(path, opts.cwd), row, col, label)
  end, items or {})
end

function M.select(items, opts)
  opts = opts or {}
  local fzf_lua = require("fzf-lua")
  fzf_lua.fzf_exec(M.entries(items, opts), {
    cwd = opts.cwd,
    prompt = opts.prompt or "References > ",
    previewer = "builtin",
    actions = {
      ["enter"] = fzf_lua.actions.file_edit_or_qf,
      ["ctrl-s"] = fzf_lua.actions.file_split,
      ["ctrl-v"] = fzf_lua.actions.file_vsplit,
      ["ctrl-q"] = fzf_lua.actions.file_sel_to_qf,
    },
    fzf_opts = {
      ["--delimiter"] = ":",
      ["--nth"] = "4..,1",
    },
  })
end

return M
