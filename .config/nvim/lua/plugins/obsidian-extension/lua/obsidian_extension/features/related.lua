local M = {}
local context = require("obsidian_extension.context")
local uv = vim.uv or vim.loop

local cache = {
  root = nil,
  entries = {},
  signatures = {},
  building = false,
  callbacks = {},
}

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function unquote(text)
  text = trim(text)
  local quote = text:sub(1, 1)
  if (quote == '"' or quote == "'") and text:sub(-1) == quote then
    return text:sub(2, -2)
  end
  return text
end

local function append_inline_list(target, value)
  value = trim(value)
  if value:match("^%[.*%]$") then value = value:sub(2, -2) end
  for item in value:gmatch("[^,]+") do
    local cleaned = unquote(item)
    if cleaned ~= "" then target[#target + 1] = cleaned end
  end
end

local function parse_note(path, relative_path, lines)
  local entry = {
    path = path,
    relative_path = relative_path,
    aliases = {},
    tags = {},
    links = {},
  }
  local list_key
  local frontmatter = lines[1] == "---"
  local frontmatter_done = not frontmatter

  for index, line in ipairs(lines) do
    if frontmatter and index > 1 and (line == "---" or line == "...") then
      frontmatter_done = true
      list_key = nil
    elseif not frontmatter_done then
      local key, value = line:match("^([%w_-]+):%s*(.*)$")
      if key then
        list_key = nil
        if key == "aliases" or key == "tags" then
          list_key = key
          if value ~= "" and value ~= "[]" then append_inline_list(entry[key], value) end
        elseif key == "id" or key == "project" or key == "branch" or key == "status" or key == "type" then
          entry[key] = unquote(value)
        end
      elseif list_key then
        local item = line:match("^%s*%-%s*(.+)$")
        if item then entry[list_key][#entry[list_key] + 1] = unquote(item) end
      end
    end

    if not entry.title then entry.title = line:match("^#%s+(.+)$") end
    for target in line:gmatch("%[%[([^%]]+)%]%]") do
      local normalized = trim((target:match("^([^|#]+)") or target)):gsub("\\", "/"):gsub("%.md$", "")
      if normalized ~= "" then entry.links[normalized:lower()] = true end
    end
  end

  entry.title = entry.title or entry.aliases[1] or entry.id or vim.fn.fnamemodify(relative_path, ":t:r")
  entry.search_title = (entry.title .. " " .. table.concat(entry.aliases, " ")):lower()
  entry.search_metadata = table.concat(entry.tags, " ")
    .. " " .. (entry.project or "") .. " " .. (entry.branch or "") .. " " .. relative_path
  entry.search_metadata = entry.search_metadata:lower()
  entry.search_body = table.concat(lines, "\n"):lower()
  entry.link_keys = {
    relative_path:gsub("%.md$", ""):lower(),
    relative_path:gsub("%.md$", ""):gsub("^notes/", ""):lower(),
    vim.fn.fnamemodify(relative_path, ":t:r"):lower(),
  }
  if entry.id and entry.id ~= "" then entry.link_keys[#entry.link_keys + 1] = entry.id:lower() end
  return entry
end

local function file_signature(stat)
  local mtime = stat and stat.mtime or {}
  return table.concat({ tostring(mtime.sec or 0), tostring(mtime.nsec or 0), tostring(stat and stat.size or 0) }, ":")
end

local function finish_build()
  cache.building = false
  local callbacks = cache.callbacks
  cache.callbacks = {}
  for _, callback in ipairs(callbacks) do callback(cache.entries) end
end

local function process_paths(root, paths)
  local seen = {}
  local index = 1
  local batch_size = 40

  local function process_batch()
    local finish = math.min(index + batch_size - 1, #paths)
    for position = index, finish do
      local relative_path = paths[position]
      local path = vim.fs.joinpath(root, relative_path)
      local stat = uv.fs_stat(path)
      if stat and stat.type == "file" then
        seen[path] = true
        local signature = file_signature(stat)
        if cache.signatures[path] ~= signature then
          local ok, lines = pcall(vim.fn.readfile, path)
          if ok then
            cache.entries[path] = parse_note(path, relative_path, lines)
            cache.signatures[path] = signature
          end
        end
      end
    end
    index = finish + 1
    if index <= #paths then
      vim.schedule(process_batch)
      return
    end

    for path in pairs(cache.entries) do
      if not seen[path] then
        cache.entries[path] = nil
        cache.signatures[path] = nil
      end
    end
    finish_build()
  end

  process_batch()
end

local function refresh_index(root, callback)
  if cache.root ~= root then
    cache.root = root
    cache.entries = {}
    cache.signatures = {}
  end
  cache.callbacks[#cache.callbacks + 1] = callback
  if cache.building then return end
  cache.building = true

  vim.system({ "rg", "--files", "-0", "-g", "*.md" }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= 1 then
        cache.building = false
        cache.callbacks = {}
        vim.notify("Failed to index Obsidian notes: " .. trim(result.stderr), vim.log.levels.ERROR)
        return
      end
      process_paths(root, vim.split(result.stdout or "", "\0", { plain = true, trimempty = true }))
    end)
  end)
end

local function branch_note_relative(git_context)
  if not git_context or not git_context.branch_note_segments or #git_context.branch_note_segments == 0 then return nil end
  return ("notes/projects/%s/%s.md"):format(
    git_context.repo_slug,
    table.concat(git_context.branch_note_segments, "/")
  )
end

local function query_terms(query)
  query = trim(query):lower()
  if query == "" then return {} end
  local terms, seen = { query }, { [query] = true }
  for term in query:gmatch("%S+") do
    if not seen[term] then
      seen[term] = true
      terms[#terms + 1] = term
    end
  end
  return terms
end

local function has_link(entry, target)
  local target_has_path = target:find("/", 1, true) ~= nil
  for _, key in ipairs(entry.link_keys or {}) do
    if target == key and (not target_has_path or key:find("/", 1, true)) then return true end
  end
  return false
end

local function rank_entries(entries_by_path, git_context, query)
  local entries = vim.tbl_values(entries_by_path)
  local branch_relative = branch_note_relative(git_context)
  local branch_entry = branch_relative and entries_by_path[vim.fs.joinpath(cache.root or "", branch_relative)] or nil
  local terms = query_terms(query)
  local ranked = {}

  for _, entry in ipairs(entries) do
    local score, reasons = 0, {}
    local same_project = git_context and entry.project == git_context.repo_slug
    local same_branch = same_project and git_context.branch_name and entry.branch == git_context.branch_name
    if same_project then score = score + 100; reasons[#reasons + 1] = "project" end
    if same_branch then score = score + 100; reasons[#reasons + 1] = "branch" end
    if branch_entry and entry.path ~= branch_entry.path then
      for target in pairs(branch_entry.links) do
        if has_link(entry, target) then
          score = score + 80
          reasons[#reasons + 1] = "linked"
          break
        end
      end
      for _, key in ipairs(branch_entry.link_keys) do
        if entry.links[key] then
          score = score + 45
          reasons[#reasons + 1] = "backlink"
          break
        end
      end
    end

    for _, term in ipairs(terms) do
      if entry.search_title:find(term, 1, true) then
        score = score + 80
        reasons[#reasons + 1] = "title"
      elseif entry.search_metadata:find(term, 1, true) then
        score = score + 35
        reasons[#reasons + 1] = "metadata"
      elseif entry.search_body:find(term, 1, true) then
        score = score + 10
        reasons[#reasons + 1] = "content"
      end
    end
    if entry.status == "archived" then score = score - 30 end
    -- Keep every note in the picker so an empty command argument still opens
    -- a useful, searchable index. Context and query matches only affect order.
    ranked[#ranked + 1] = { entry = entry, score = score, reasons = reasons }
  end

  table.sort(ranked, function(a, b)
    if a.score == b.score then return a.entry.title < b.entry.title end
    return a.score > b.score
  end)
  return ranked
end

local function open_picker(root, ranked, git_context)
  if #ranked == 0 then
    vim.notify("No related Obsidian notes found", vim.log.levels.INFO)
    return
  end
  local lines = {}
  for _, candidate in ipairs(ranked) do
    local reasons = #candidate.reasons > 0 and (" [" .. table.concat(candidate.reasons, ",") .. "]") or ""
    -- fzf-lua's builtin previewer understands this native location format.
    -- Keeping the path relative to cwd also makes the candidate display compact.
    lines[#lines + 1] = ("%s:1:1:%4d  %s%s"):format(
      candidate.entry.relative_path,
      candidate.score,
      candidate.entry.title,
      reasons
    )
  end
  local fzf = require("fzf-lua")
  local context_label = git_context and git_context.repo_slug or "all notes"
  if git_context and git_context.branch_name then
    context_label = context_label .. "/" .. git_context.branch_name
  end
  fzf.fzf_exec(lines, {
    prompt = ("Related [%s] > "):format(context_label),
    cwd = root,
    previewer = "builtin",
    actions = {
      ["enter"] = fzf.actions.file_edit_or_qf,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
      ["ctrl-q"] = fzf.actions.file_sel_to_qf,
    },
    fzf_opts = {
      ["--delimiter"] = ":",
      ["--nth"] = "4..,1",
      ["--no-sort"] = true,
    },
  })
end

local function suggest(query)
  local root = context.vault_path()
  if not root then
    vim.notify("Could not determine the current Obsidian vault", vim.log.levels.ERROR)
    return
  end
  local git_context = context.git()
  refresh_index(root, function(entries)
    open_picker(root, rank_entries(entries, git_context, query), git_context)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("ObsidianRelated", function(opts)
    suggest(opts.args)
  end, { nargs = "*", desc = "Suggest notes related to the current Git context and text" })

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufDelete" }, {
    pattern = "*.md",
    callback = function(event)
      local path = vim.api.nvim_buf_get_name(event.buf)
      if context.is_vault_path(path, cache.root) then cache.signatures[path] = nil end
    end,
  })
end

M._parse_note = parse_note
M._rank_entries = rank_entries
M._branch_note_relative = branch_note_relative
M._open_picker = open_picker
M._refresh_index = refresh_index
M._cache = cache

return M
