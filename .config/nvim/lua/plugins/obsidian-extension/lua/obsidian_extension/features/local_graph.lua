local M = {}
local context = require("obsidian_extension.context")
local uv = vim.uv or vim.loop
local defaults = {
  depth = 1,
  incoming = true,
  outgoing = true,
  neighbor_links = true,
  existing_only = false,
  follow = true,
  width = 64,
  max_nodes = 500,
}
local config = vim.deepcopy(defaults)
local state = { generation = 0, entries = {}, cache = {}, query = "" }
local ns = vim.api.nvim_create_namespace("ObsidianLocalGraph")
local directions = { "Incoming", "Outgoing", "Mutual" }

local function setup_highlights()
  local links = {
    Title = "Title", Center = "Special", Heading = "Title", Path = "Comment", Tree = "Comment",
    Missing = "DiagnosticWarn", Enabled = "DiagnosticOk", Disabled = "Comment", Key = "Special",
    Value = "Number", Match = "Search",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, "ObsidianLocalGraph" .. name, { default = true, link = target })
  end
  for depth = 1, 10 do
    for direction, target in pairs({ Incoming = "Special", Outgoing = "String", Mutual = "Type" }) do
      vim.api.nvim_set_hl(0, ("ObsidianLocalGraph%sDepth%d"):format(direction, depth), { default = true, link = target })
    end
  end
end

local function inside(path, root)
  return path:sub(1, #root + 1) == root .. "/"
end

local function absolute(root, path)
  return vim.fs.normalize(vim.fs.joinpath(root, path))
end

local function parse_note(path, root, lines)
  local Note = require("obsidian.note")
  local search = require("obsidian.search")
  local util = require("obsidian.util")
  local index = 0
  local note = Note.from_lines(function()
    index = index + 1
    return lines[index]
  end, path, { max_lines = #lines + 1 })
  local entry = {
    id = path,
    path = path,
    relative_path = path:sub(#root + 2),
    title = note:display_name(),
    aliases = note.aliases,
    note_id = tostring(note.id),
    links = {},
  }
  local fence_char, fence_length, comment
  local function comment_start(line, marker)
    local position = 1
    while true do
      local start = line:find(marker, position, true)
      if not start then return end
      local in_code = false
      for code_start, code_end in util.gfind(line, "`[^`]*`") do
        if code_start < start and start < code_end then
          position, in_code = code_end + 1, true
          break
        end
      end
      if not in_code then return start end
    end
  end
  for _, original in ipairs(lines) do
    local line = original
    -- Obsidian ignores fenced/inline code and HTML comments when indexing links.
    local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if fence_char then
      if fence and fence:sub(1, 1) == fence_char and #fence >= fence_length
        and line:match("^%s*[`~]+%s*$") then
        fence_char = nil
      end
    elseif fence and not comment then
      fence_char, fence_length = fence:sub(1, 1), #fence
    else
      local visible = {}
      while line ~= "" do
        if comment then
          local finish = line:find(comment, 1, true)
          if not finish then break end
          line, comment = line:sub(finish + #comment), false
        else
          local start = comment_start(line, "<!--")
          local obsidian_comment = comment_start(line, "%%")
          local closing = "-->"
          if obsidian_comment and (not start or obsidian_comment < start) then
            start, closing = obsidian_comment, "%%"
          end
          if not start then visible[#visible + 1] = line; break end
          visible[#visible + 1] = line:sub(1, start - 1)
          line, comment = line:sub(start + (closing == "%%" and 2 or 4)), closing
        end
      end
      line = table.concat(visible)
      for _, match in ipairs(search.find_refs(line)) do
        local raw = line:sub(match[1], match[2])
        local target, _, kind = util.parse_link(raw, { link_type = match[3] })
        if target and not target:match("^[%a][%w+.-]*:") and target:sub(1, 2) ~= "//" then
          target = util.urldecode(target):gsub("#.*$", "")
          target = vim.trim(target):gsub("\\", "/")
          if target ~= "" then
            entry.links[#entry.links + 1] = { target = target, markdown = kind == search.RefTypes.Markdown }
          end
        end
      end
    end
  end
  return entry
end

local function build_graph(entries, root, notes_subdir)
  local graph = { nodes = {}, outgoing = {}, incoming = {} }
  local keys = {}
  local function key(text)
    return text:gsub("%.md$", ""):lower()
  end
  local paths = vim.tbl_keys(entries)
  table.sort(paths)
  for _, path in ipairs(paths) do
    local entry = entries[path]
    graph.nodes[path] = entry
    local names = { entry.relative_path, vim.fs.basename(path), entry.note_id, entry.title }
    vim.list_extend(names, entry.aliases or {})
    for _, name in ipairs(names) do
      local normalized = key(name)
      keys[normalized] = keys[normalized] or {}
      if not vim.tbl_contains(keys[normalized], path) then
        keys[normalized][#keys[normalized] + 1] = path
      end
    end
  end
  for _, path in ipairs(paths) do
    local entry = entries[path]
    for _, link in ipairs(entry.links) do
      local target = link.target
      local filename = target:match("%.md$") and target or target .. ".md"
      local relative = absolute(vim.fs.dirname(path), filename)
      local vault_path = absolute(root, filename:gsub("^/", ""))
      local notes_path = absolute(root, (notes_subdir or "") .. "/" .. filename)
      local candidates = link.markdown and { relative, vault_path, notes_path } or { vault_path, relative, notes_path }
      local resolved
      for _, candidate in ipairs(candidates) do
        if entries[candidate] then resolved = candidate; break end
      end
      if not resolved and not target:match("^%.%./") and not target:match("^%./") then
        resolved = (keys[key(target)] or {})[1]
      end
      -- A dotted note name may resolve to foo.bar.md; other extensions are attachments.
      if not resolved and (not target:match("%.[^/]+$") or target:match("%.md$")) then
        local missing_path
        if link.markdown or target:match("^%.%./") or target:match("^%./") then
          missing_path = relative
        elseif target:find("/", 1, true) then
          missing_path = vault_path
        else
          missing_path = notes_path
        end
        if inside(missing_path, root) then
          resolved = "missing:" .. missing_path
          graph.nodes[resolved] = graph.nodes[resolved] or {
            id = resolved,
            title = target:gsub("%.md$", ""),
            relative_path = missing_path:sub(#root + 2),
            missing = true,
          }
        end
      end
      if resolved and resolved ~= path then
        graph.outgoing[path] = graph.outgoing[path] or {}
        graph.incoming[resolved] = graph.incoming[resolved] or {}
        graph.outgoing[path][resolved] = true
        graph.incoming[resolved][path] = true
      end
    end
  end
  return graph
end

local function link_direction(graph, parent, child)
  local outgoing = graph.outgoing[parent] and graph.outgoing[parent][child]
  local incoming = graph.outgoing[child] and graph.outgoing[child][parent]
  if outgoing and incoming then return 3, "↔ " end
  if outgoing then return 2, "→ " end
  return 1, "← "
end

local function select_graph(graph, center, opts, query)
  local result = { order = {}, parent = {}, distance = {}, children = {}, extra = {}, truncated = false }
  if not graph.nodes[center] then return result end
  local queue = { center }
  result.distance[center] = 0
  local position = 1
  while position <= #queue do
    local id = queue[position]
    position = position + 1
    if result.distance[id] < opts.depth then
      local neighbors = {}
      if opts.outgoing then
        for other in pairs(graph.outgoing[id] or {}) do neighbors[other] = true end
      end
      if opts.incoming then
        for other in pairs(graph.incoming[id] or {}) do neighbors[other] = true end
      end
      local sorted = vim.tbl_keys(neighbors)
      table.sort(sorted, function(a, b) return graph.nodes[a].relative_path < graph.nodes[b].relative_path end)
      for _, other in ipairs(sorted) do
        if result.distance[other] == nil and (not opts.existing_only or not graph.nodes[other].missing) then
          if #queue < opts.max_nodes then
            queue[#queue + 1] = other
            result.distance[other] = result.distance[id] + 1
            result.parent[other] = id
          else
            result.truncated = true
          end
        end
      end
    end
  end
  local keep = { [center] = true }
  query = (query or ""):lower()
  for _, id in ipairs(queue) do
    local node = graph.nodes[id]
    local text = table.concat({ node.title, node.relative_path, table.concat(node.aliases or {}, " ") }, " "):lower()
    if query == "" or text:find(query, 1, true) then
      local ancestor = id
      while ancestor and not keep[ancestor] do
        keep[ancestor] = true
        ancestor = result.parent[ancestor]
      end
    end
  end
  for _, id in ipairs(queue) do
    if keep[id] then
      result.order[#result.order + 1] = id
      local parent = result.parent[id]
      if parent then
        result.children[parent] = result.children[parent] or {}
        table.insert(result.children[parent], id)
      end
    end
  end
  -- Group the displayed siblings without changing shortest paths or limit selection.
  for parent, children in pairs(result.children) do
    table.sort(children, function(a, b)
      local a_direction = link_direction(graph, parent, a)
      local b_direction = link_direction(graph, parent, b)
      if a_direction ~= b_direction then return a_direction < b_direction end
      return graph.nodes[a].relative_path < graph.nodes[b].relative_path
    end)
  end
  -- Non-tree edges retain cycles and connections between branches without recursion.
  if opts.neighbor_links then
    for _, from in ipairs(result.order) do
      for to in pairs(graph.outgoing[from] or {}) do
        local reciprocal = graph.outgoing[to] and graph.outgoing[to][from]
        if keep[to] and result.parent[to] ~= from and result.parent[from] ~= to
          and (not reciprocal or from < to) then
          result.extra[#result.extra + 1] = { from = from, to = to }
        end
      end
    end
    table.sort(result.extra, function(a, b)
      local a_from = graph.nodes[a.from].relative_path
      local b_from = graph.nodes[b.from].relative_path
      if a_from ~= b_from then return a_from < b_from end
      local a_direction = link_direction(graph, a.from, a.to)
      local b_direction = link_direction(graph, b.from, b.to)
      if a_direction ~= b_direction then return a_direction < b_direction end
      return graph.nodes[a.to].relative_path < graph.nodes[b.to].relative_path
    end)
  end
  return result
end

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function render()
  if not is_open() then return end
  local lines, entries, highlights = {}, {}, {}
  local old = state.entries[vim.api.nvim_win_get_cursor(state.win)[1]]
  local function add(text, id, highlight)
    lines[#lines + 1] = text
    entries[#lines] = id
    if highlight then highlights[#highlights + 1] = { #lines - 1, 0, -1, highlight } end
  end
  local function add_parts(parts, id)
    local texts = {}
    for _, part in ipairs(parts) do texts[#texts + 1] = part[1] end
    add(table.concat(texts), id)
    local column = 0
    for _, part in ipairs(parts) do
      local text, highlight = part[1], part[2]
      if highlight then highlights[#highlights + 1] = { #lines - 1, column, column + #text, highlight } end
      if part[3] and state.query ~= "" then
        local start = 1
        while start <= #text do
          local first, last = text:lower():find(state.query:lower(), start, true)
          if not first then break end
          highlights[#highlights + 1] = { #lines - 1, column + first - 1, column + last, "ObsidianLocalGraphMatch" }
          start = last + 1
        end
      end
      column = column + #text
    end
  end
  local function flag(value) return value and "on" or "off" end
  local function flag_part(value)
    return { flag(value), value and "ObsidianLocalGraphEnabled" or "ObsidianLocalGraphDisabled" }
  end
  add("LOCAL GRAPH · ローカルグラフ", nil, "ObsidianLocalGraphTitle")
  add_parts({
    { "Depth ", "Comment" }, { tostring(config.depth), "ObsidianLocalGraphValue" },
    { "   Incoming ", "Comment" }, flag_part(config.incoming),
    { "   Outgoing ", "Comment" }, flag_part(config.outgoing),
  })
  add_parts({
    { "Neighbor links ", "Comment" }, flag_part(config.neighbor_links),
    { "   Existing only ", "Comment" }, flag_part(config.existing_only),
    { "   Follow ", "Comment" }, flag_part(config.follow),
  })
  if state.query ~= "" then
    add_parts({ { "Filter: ", "Comment" }, { state.query, "ObsidianLocalGraphMatch" } })
  end
  add("")
  if state.graph and state.graph.nodes[state.center] then
    local selected = select_graph(state.graph, state.center, config, state.query)
    local function label_parts(id, highlight)
      local node = state.graph.nodes[id]
      local parts = {
        { node.title:gsub("[\r\n\t]", " "), node.missing and "ObsidianLocalGraphMissing" or highlight, true },
        { "  [" .. node.relative_path .. "]", "ObsidianLocalGraphPath", true },
      }
      if node.missing then parts[#parts + 1] = { " (missing)", "ObsidianLocalGraphMissing" } end
      return parts
    end
    local function arrow(parent, child, highlight)
      local _, text = link_direction(state.graph, parent, child)
      return { text, highlight }
    end
    local function direction_highlight(direction, depth)
      return ("ObsidianLocalGraph%sDepth%d"):format(directions[direction], math.max(1, depth))
    end
    add_parts(vim.list_extend({ { "● ", "ObsidianLocalGraphCenter" } }, label_parts(state.center, "ObsidianLocalGraphCenter")), state.center)
    local function branch(parent, prefix, children)
      children = children or selected.children[parent] or {}
      for index, id in ipairs(children) do
        local last = index == #children
        local depth = selected.distance[id]
        local direction = link_direction(state.graph, parent, id)
        local highlight = direction_highlight(direction, depth)
        local parts = {
          { prefix, "ObsidianLocalGraphTree" }, { last and "└─ " or "├─ ", highlight }, arrow(parent, id, highlight),
        }
        add_parts(vim.list_extend(parts, label_parts(id, highlight)), id)
        branch(id, prefix .. (last and "   " or "│  "))
      end
    end
    local groups = { {}, {}, {} }
    for _, id in ipairs(selected.children[state.center] or {}) do
      local direction = link_direction(state.graph, state.center, id)
      groups[direction][#groups[direction] + 1] = id
    end
    local titles = { "INCOMING ← · リンク元", "OUTGOING → · リンク先", "MUTUAL ↔ · 相互リンク" }
    for direction, children in ipairs(groups) do
      if #children > 0 then
        add("")
        add_parts({
          { "  " .. titles[direction], direction_highlight(direction, 1) },
          { "  (" .. #children .. ")", "ObsidianLocalGraphValue" },
        })
        branch(state.center, "  ", children)
      end
    end
    if #selected.order == 1 then add("  (No connected notes matching these filters)", nil, "Comment") end
    if #selected.extra > 0 then
      add("")
      add("NEIGHBOR LINKS · 枝同士のリンク / 循環", nil, "ObsidianLocalGraphHeading")
      for _, edge in ipairs(selected.extra) do
        local direction = link_direction(state.graph, edge.from, edge.to)
        local function node_highlight(id)
          return id == state.center and "ObsidianLocalGraphCenter"
            or direction_highlight(direction, selected.distance[id])
        end
        local parts = vim.list_extend({ { "  " } }, label_parts(edge.from, node_highlight(edge.from)))
        local link = arrow(edge.from, edge.to, node_highlight(edge.to))
        link[1] = " " .. link[1]
        parts[#parts + 1] = link
        add_parts(vim.list_extend(parts, label_parts(edge.to, node_highlight(edge.to))), edge.to)
      end
    end
    add("")
    add(("%d nodes%s"):format(#selected.order, selected.truncated and " · limit reached; reduce depth or raise max_nodes" or ""), nil, "Comment")
  else
    local message = state.error or (state.loading and "Loading…" or "The center note is no longer available. Open another note or refresh.")
    add(message, nil, state.error and "DiagnosticError" or "Comment")
  end
  if state.loading and state.graph then add("Refreshing…", nil, "Comment") end
  add("")
  local function help(items)
    local parts = {}
    for index, item in ipairs(items) do
      if index > 1 then parts[#parts + 1] = { "   " } end
      parts[#parts + 1] = { item[1], "ObsidianLocalGraphKey" }
      parts[#parts + 1] = { " " .. item[2], "Comment" }
    end
    add_parts(parts)
  end
  help({ { "<CR>", "open" }, { "c", "center" }, { "+/-", "depth" }, { "/", "filter" } })
  help({ { "i", "incoming" }, { "o", "outgoing" }, { "n", "neighbor links" } })
  help({ { "e", "existing only" }, { "f", "follow" }, { "R", "refresh" }, { "q", "close" } })
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, highlight[4], highlight[1], highlight[2], highlight[3])
  end
  vim.bo[state.buf].modifiable = false
  state.entries = entries
  if old then
    for line = 1, #lines do
      if entries[line] == old then vim.api.nvim_win_set_cursor(state.win, { line, 0 }); break end
    end
  end
end

local function current_source(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return end
  local root = context.vault_path()
  local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  if root and inside(path, root) and path:match("%.md$") then return path, root end
end

function M.refresh(rescan)
  if not is_open() then return end
  state.generation = state.generation + 1
  local generation, root = state.generation, state.root
  state.loading, state.error = true, nil
  local cache = state.cache[root] or {}
  state.cache[root] = cache
  local function valid() return generation == state.generation and is_open() end
  local function load(paths)
    local entries, loaded, position, failures = {}, {}, 1, 0
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
        local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
        if inside(path, root) and path:match("%.md$") then loaded[path] = buf end
      end
    end
    local seen = {}
    for _, path in ipairs(paths) do seen[path] = true end
    for path in pairs(loaded) do
      if not seen[path] and (vim.bo[loaded[path]].modified or path == state.center) then
        paths[#paths + 1] = path
      end
    end
    local function batch()
      if not valid() then return end
      local finish = math.min(position + 39, #paths)
      for index = position, finish do
        local path = paths[index]
        local stat, buf = uv.fs_stat(path), loaded[path]
        if buf and (not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf)) then
          buf = nil
        end
        local signature
        if buf then
          signature = "buf:" .. buf .. ":" .. vim.api.nvim_buf_get_changedtick(buf)
        elseif stat then
          signature = table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":")
        end
        if signature then
          local cached = cache[path]
          if not cached or cached.signature ~= signature then
            local ok, entry = pcall(function()
              local lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or vim.fn.readfile(path)
              return parse_note(path, root, lines)
            end)
            cached = ok and { signature = signature, entry = entry } or nil
            cache[path] = cached
            if not ok then failures = failures + 1 end
          end
          if cached then entries[path] = cached.entry end
        end
      end
      position = finish + 1
      if position <= #paths then vim.schedule(batch); return end
      for path in pairs(cache) do if not entries[path] then cache[path] = nil end end
      state.paths = paths
      local client = require("obsidian").get_client()
      state.graph = build_graph(entries, root, client.opts.notes_subdir)
      state.loading = false
      if failures > 0 then
        vim.notify(("Local graph: skipped %d unreadable notes"):format(failures), vim.log.levels.WARN)
      end
      render()
    end
    batch()
  end
  render()
  if not rescan and state.paths then load(vim.deepcopy(state.paths)); return end
  vim.system({ "rg", "--no-config", "--files", "-0", "-g", "*.md" }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      if not valid() then return end
      if result.code ~= 0 and result.code ~= 1 then
        state.loading, state.error = false, "Failed to scan vault: " .. vim.trim(result.stderr or "")
        state.graph = nil
        render()
        return
      end
      local paths = {}
      for _, path in ipairs(vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })) do
        paths[#paths + 1] = absolute(root, path)
      end
      load(paths)
    end)
  end)
end

local function configure_editor(win)
  for _, option in ipairs({
    "wrap", "number", "relativenumber", "spell", "signcolumn", "foldcolumn",
    "foldmethod", "foldexpr", "foldenable", "foldlevel", "winbar", "cursorline",
  }) do
    vim.wo[win][option] = vim.o[option]
  end
  vim.wo[win].winfixwidth = false
end

function M.close()
  state.generation = state.generation + 1
  local win, buf = state.win, state.buf
  state.win, state.buf, state.entries = nil, nil, {}
  if win and vim.api.nvim_win_is_valid(win) then
    if #vim.api.nvim_list_wins() == 1 then
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      configure_editor(win)
    else
      vim.api.nvim_win_close(win, true)
    end
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end

local function open_entry(recenter)
  local id = state.entries[vim.api.nvim_win_get_cursor(state.win)[1]]
  local node = state.graph and state.graph.nodes[id]
  if not node then return end
  if recenter then state.center = id; render(); return end
  if not node.path then
    vim.notify("Local graph: this note does not exist", vim.log.levels.INFO)
    return
  end
  local win = state.source_win
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    vim.cmd("leftabove vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
    state.source_win = win
    configure_editor(win)
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(node.path))
end

function M.open(depth)
  local path, root = current_source()
  if not path and not is_open() then
    vim.notify("Current buffer is not an Obsidian note", vim.log.levels.WARN)
    return
  end
  if depth then config.depth = depth end
  if path then
    if root ~= state.root then state.graph, state.paths = nil, nil end
    state.root, state.center, state.source_win = root, path, vim.api.nvim_get_current_win()
  end
  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    M.refresh(true)
    return
  end
  vim.cmd("botright " .. config.width .. "vsplit")
  state.win = vim.api.nvim_get_current_win()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.api.nvim_buf_set_name(state.buf, "obsidian-local-graph://" .. state.root)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "obsidian-local-graph"
  vim.bo[state.buf].modifiable = false
  for _, option in ipairs({ "number", "relativenumber", "wrap", "spell" }) do vim.wo[state.win][option] = false end
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldcolumn = "0"
  vim.wo[state.win].foldmethod = "manual"
  vim.wo[state.win].foldenable = false
  vim.wo[state.win].winfixwidth = true
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].winbar = "%#ObsidianLocalGraphTitle# Local graph %*· ローカルグラフ"
  local function map(key, action, desc)
    vim.keymap.set("n", key, action, { buffer = state.buf, silent = true, nowait = true, desc = desc })
  end
  map("q", M.close, "Close local graph")
  map("<CR>", function() open_entry(false) end, "Open selected note")
  map("<2-LeftMouse>", function() open_entry(false) end, "Open selected note")
  map("c", function() open_entry(true) end, "Center on selected note")
  map("+", function() config.depth = math.min(10, config.depth + 1); render() end, "Increase graph depth")
  map("=", function() config.depth = math.min(10, config.depth + 1); render() end, "Increase graph depth")
  map("-", function() config.depth = math.max(1, config.depth - 1); render() end, "Decrease graph depth")
  for key, option in pairs({ i = "incoming", o = "outgoing", n = "neighbor_links", e = "existing_only", f = "follow" }) do
    map(key, function() config[option] = not config[option]; render() end, "Toggle " .. option)
  end
  map("R", function() M.refresh(true) end, "Refresh local graph")
  map("/", function()
    local buf = state.buf
    vim.ui.input({ prompt = "Local graph filter (title/path/alias): ", default = state.query }, function(query)
      if query ~= nil and state.buf == buf and is_open() then state.query = query; render() end
    end)
  end, "Filter local graph")
  map("<Esc>", function() state.query = ""; render() end, "Clear graph filter")
  M.refresh(true)
end

function M.setup(opts)
  config = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
  config.depth = math.max(1, math.min(10, math.floor(tonumber(config.depth) or 1)))
  config.max_nodes = math.max(1, math.floor(tonumber(config.max_nodes) or defaults.max_nodes))
  config.width = math.max(24, math.floor(tonumber(config.width) or defaults.width))
  vim.api.nvim_create_user_command("ObsidianLocalGraph", function(args)
    local depth = args.args ~= "" and tonumber(args.args) or nil
    if args.args ~= "" and (not depth or depth % 1 ~= 0 or depth < 1 or depth > 10) then
      vim.notify("Local graph depth must be an integer from 1 to 10", vim.log.levels.WARN)
      return
    end
    M.open(depth)
  end, { nargs = "?", desc = "Open a local graph around the current note", complete = function() return { "1", "2", "3", "4", "5" } end })
  local group = vim.api.nvim_create_augroup("ObsidianExtensionLocalGraph", { clear = true })
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = setup_highlights })
  local change = 0
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if not is_open() or not config.follow then return end
      local path, root = current_source(args.buf)
      if not path then return end
      if root ~= state.root then state.graph, state.paths = nil, nil end
      state.root, state.center, state.source_win = root, path, vim.api.nvim_get_current_win()
      M.refresh(false)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*.md",
    callback = function(args)
      local path, root = current_source(args.buf)
      if not is_open() or not path or root ~= state.root then return end
      change = change + 1
      local token, buf = change, state.buf
      vim.defer_fn(function()
        if token == change and state.buf == buf and is_open() then M.refresh(true) end
      end, 150)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      if tonumber(args.match) == state.win then
        state.generation = state.generation + 1
        state.win, state.buf, state.entries = nil, nil, {}
      end
    end,
  })
end

M._parse_note = parse_note
M._build_graph = build_graph
M._select_graph = select_graph
M._state = state

return M
