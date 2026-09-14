-- Commit review coordinates belong to a reproducible patch, not either file side.
local M = {}
local flags = {
  "show", "--format=", "-p", "--no-color", "--no-ext-diff", "--no-textconv",
  "--no-renames", "--full-index", "--diff-algorithm=myers", "--no-indent-heuristic",
  "-U3", "--inter-hunk-context=0", "--src-prefix=a/", "--dst-prefix=b/",
  "--no-relative", "--no-notes", "--diff-merges=first-parent", "-O/dev/null",
}

function M.command(commit)
  local args = vim.list_extend({ "-c", "core.quotePath=true", "-c", "diff.suppressBlankEmpty=false" }, flags)
  vim.list_extend(args, { commit, "--" })
  return args
end

function M.read(root, commit)
  local args = { "git", "-C", root }
  vim.list_extend(args, M.command(commit))
  local result = vim.system(args, { text = true }):wait(3000)
  if result.code ~= 0 then return end
  local lines = vim.split(result.stdout, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

-- Align each file separately so identical +/- text in another file cannot win.
-- Index abbreviation differences are display metadata, not patch coordinates.
local function sections(lines)
  local result, active = {}, nil
  for i, line in ipairs(lines) do
    if line:match("^diff %-%-git ") then
      if result[line] then return {} end -- ambiguous repeated file / merge parent
      active = { first = i, lines = {} }
      result[line] = active
    end
    if active then active.lines[#active.lines + 1] = line:match("^index %x+%.%.%x+") and "index" or line end
  end
  return result
end

function M.mapping(display, canonical)
  local mapped = {}
  local targets = sections(canonical)
  for name, section in pairs(sections(display)) do
    local target = targets[name]
    if target then
      local changes = vim.diff(table.concat(section.lines, "\n") .. "\n", table.concat(target.lines, "\n") .. "\n",
        { result_type = "indices", algorithm = "minimal" })
      local a, b = 1, 1
      for _, change in ipairs(changes) do
        -- An insertion's start is the preceding row (zero at the beginning).
        local first = change[2] == 0 and change[1] + 1 or change[1]
        while a < first do mapped[section.first + a - 1] = target.first + b - 1; a, b = a + 1, b + 1 end
        a = first + change[2]
        b = (change[4] == 0 and change[3] + 1 or change[3]) + change[4]
      end
      while a <= #section.lines and b <= #target.lines do
        mapped[section.first + a - 1] = target.first + b - 1
        a, b = a + 1, b + 1
      end
    end
  end
  return mapped
end

function M.capture(bufnr, root, first, last)
  if not first or not vim.tbl_contains({ "git", "fugitive" }, vim.bo[bufnr].filetype) then return end
  local display = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ok, parsed = pcall(vim.fn["fugitive#Parse"], name)
  local commit = ok and parsed[1] and parsed[1]:match("^(%x+):?$")
  for i = first, 1, -1 do
    local hash = display[i]:match("^commit (%x+)")
    if hash then commit = hash; break end
  end
  if not commit then return end
  for i = first + 1, last do if display[i]:match("^commit %x+") then return end end
  local dir_ok, dir = pcall(vim.fn.FugitiveGitDir, bufnr)
  if dir_ok and dir ~= "" then
    local work_ok, worktree = pcall(vim.fn.FugitiveWorkTree, dir)
    if work_ok and worktree ~= "" then root = worktree end
  end
  local resolved = vim.system({ "git", "-C", root, "rev-parse", "--verify", commit .. "^{commit}" }, { text = true }):wait(3000)
  if resolved.code ~= 0 then return end
  commit = vim.trim(resolved.stdout)
  local canonical = M.read(root, commit)
  if not canonical then return end
  local mapping = M.mapping(display, canonical)
  local start_line, end_line = mapping[first], mapping[last]
  if not start_line or not end_line then return end
  -- Every selected row must map in order; don't silently drop custom output.
  local previous = start_line - 1
  for i = first, last do
    if not mapping[i] or mapping[i] <= previous then return end
    previous = mapping[i]
  end
  return { kind = "fugitive", root = root, revision = commit, review_commit = commit,
    show = true, inline_diff = true, side = "patch", name = name,
    start_line = start_line, end_line = end_line, filetype = "git" }
end

function M.range(bufnr, source)
  local saved = vim.b[bufnr].lazyagent_note_source
  if saved and saved.show and saved.review_commit == source.review_commit then
    return source.start_line, source.end_line
  end
  -- Commit identity is checked by capture at the matched endpoints below.
  local canonical = M.read(source.root, source.review_commit)
  if not canonical then return end
  local display = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local mapping = M.mapping(display, canonical)
  local first, last
  for row, mapped in pairs(mapping) do
    if mapped == source.start_line then first = row end
    if mapped == source.end_line then last = row end
  end
  if not first or not last or last < first then return end
  local candidate = M.capture(bufnr, source.root, first, last)
  if candidate and candidate.review_commit == source.review_commit then return first, last end
end

return M
