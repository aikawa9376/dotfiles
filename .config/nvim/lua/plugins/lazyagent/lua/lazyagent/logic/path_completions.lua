local M = {}

local uv = vim.uv or vim.loop

local function truncate_text(text, max_len)
  if #text > max_len then return text:sub(1, max_len) .. "\n... (truncated)" end
  return text
end

local function path_doc(path)
  local full = vim.fn.fnamemodify(path, ":p")
  local stat = uv and uv.fs_stat(full) or nil
  if not stat then return "(missing)", full end

  if stat.type == "directory" then
    local entries = {}
    local scanner = uv and uv.fs_scandir(full) or nil
    while scanner and #entries < 20 do
      local name = uv.fs_scandir_next(scanner)
      if not name then break end
      if name ~= "." and name ~= ".." then table.insert(entries, name) end
    end
    local body = #entries > 0 and table.concat(entries, "\n") or "(empty)"
    return body, full
  end

  if stat.type == "file" and vim.fn.filereadable(full) == 1 then
    local ok, lines = pcall(vim.fn.readfile, full, "", 200)
    if ok and lines and type(lines) == "table" then
      local text = truncate_text(table.concat(lines, "\n"), 3000)
      local doc = (text ~= "" and text) or "(empty)"
      return doc, full
    end
    return "(unable to read)", full
  end

  return "(path)", full
end

function M.list_fd_paths()
  if vim.fn.executable("fd") ~= 1 then return {} end
  local cmd = {
    "fd",
    "--type",
    "f",
    "--type",
    "d",
    "--hidden",
    "--follow",
    "--exclude",
    ".git",
    "--strip-cwd-prefix",
    ".",
  }
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if not ok or not out then return {} end
  local items = {}
  for _, line in ipairs(out) do
    if line and line ~= "" then
      local doc, summary = path_doc(line)
      table.insert(items, { label = "@" .. line, desc = summary or ("Path: " .. line), doc = doc })
    end
  end
  return items
end

return M
