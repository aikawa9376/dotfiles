local source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin = vim.fs.dirname(vim.fs.dirname(source))
vim.opt.runtimepath:prepend(plugin)
for _, name in ipairs({ "plenary.nvim", "obsidian.nvim" }) do
  vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/" .. name)
end
local graph = require("obsidian_extension.features.local_graph")
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/notes/sub", "p")
local notes = {
  ["notes/a.md"] = { "---", "id: root-id", "aliases: [Root alias]", "---", "# A", "[[b|B alias]] [[sub/c#Heading]] [[Missing]]", "[[dotted.name]] [[pic.png]]", "[D](sub/d.md#^block) [outside](../../outside.md)", "[web](https://example.com) `[[inline-code]]`", "```lua", "[[fenced]]", "```", "~~~", "[[tilde-fenced]]", "~~~", "<!-- [[comment]]", "[[multiline-comment]] -->" },
  ["notes/b.md"] = { "# B", "[[root-id]] [[sub/c]]" },
  ["notes/sub/c.md"] = { "# C", "[A](../a.md) [[deep]] [[b]]" },
  ["notes/sub/d.md"] = { "# D", "[[root-id]] [[b]]" },
  ["notes/deep.md"] = { "# Deep", "[[sub/d]]" },
  ["notes/ref.md"] = { "# Incoming", "[[Root alias#Heading]]" },
  ["notes/dotted.name.md"] = { "# Dotted" },
  ["notes/space name.md"] = { "# Space" },
}
local entries = {}
local function path(name) return fixture .. "/notes/" .. name .. ".md" end
for relative, lines in pairs(notes) do
  local full = fixture .. "/" .. relative
  vim.fn.writefile(lines, full)
  entries[full] = graph._parse_note(full, fixture, lines)
end
local parsed = entries[path("a")]
local targets = {}
for _, link in ipairs(parsed.links) do targets[link.target] = true end
assert(targets.b and targets["sub/c"] and targets["sub/d.md"], "aliases, heading and block fragments normalize to note targets")
assert(not targets["inline-code"] and not targets.fenced and not targets["tilde-fenced"], "code references are ignored")
assert(not targets.comment and not targets["multiline-comment"], "HTML comments are ignored")
local comments = graph._parse_note(path("comments"), fixture, {
  "<!--", "```", "[[hidden]]", "-->", "[[visible]]", "%% [[obsidian-comment]]", "[[hidden-too]] %% [[visible-too]]",
  "`<!--` `%%` [[outside-inline-code]]",
})
assert(#comments.links == 3 and comments.links[1].target == "visible"
  and comments.links[2].target == "visible-too" and comments.links[3].target == "outside-inline-code",
  "comments ignore code fences inside comments and comment delimiters inside inline code")
assert(parsed.note_id == "root-id" and parsed.aliases[1] == "Root alias", "metadata uses upstream note parsing")
local long = { "# Long" }
for _ = 1, 600 do long[#long + 1] = "text" end
long[#long + 1] = "[Space](space%20name.md) [[#local-anchor]]"
local long_note = graph._parse_note(path("long"), fixture, long)
assert(#long_note.links == 1 and long_note.links[1].target == "space name.md", "links beyond 500 lines are indexed and URLs decoded")
entries[long_note.id] = long_note
local index = graph._build_graph(entries, fixture, "notes")
local a, b, c, d, deep, ref = path("a"), path("b"), path("sub/c"), path("sub/d"), path("deep"), path("ref")
local missing = "missing:" .. path("Missing")
assert(index.outgoing[a][b] and index.outgoing[b][a], "frontmatter IDs resolve reciprocal links")
assert(index.outgoing[c][a] and index.outgoing[a][d], "Markdown paths are relative to the source note")
assert(index.outgoing[ref][a], "frontmatter aliases resolve incoming links")
assert(index.outgoing[a][path("dotted.name")], "dotted note names still resolve")
assert(index.outgoing[long_note.id][path("space name")], "URL-encoded Markdown links resolve")
assert(index.nodes[missing].missing, "unresolved note links have shared missing nodes")
for _, node in pairs(index.nodes) do
  assert(not node.relative_path:find("outside", 1, true), "relative paths cannot escape the vault")
  assert(not node.relative_path:find("pic.png", 1, true), "attachments are not missing note nodes")
end
local opts = { depth = 1, incoming = true, outgoing = true, neighbor_links = true, existing_only = false, max_nodes = 500 }
local selected = graph._select_graph(index, a, opts)
assert(selected.distance[b] == 1 and selected.distance[ref] == 1, "both link directions are explored")
assert(selected.distance[deep] == nil, "depth one does not visit second-degree notes")
assert(#selected.extra > 0, "connections between branches retain non-tree edges")
assert(vim.deep_equal(selected.children[a], { ref, missing, path("dotted.name"), b, c, d }),
  "siblings group incoming, outgoing, and mutual links, with paths sorted within each group")
local reciprocal_count = 0
for _, edge in ipairs(selected.extra) do
  if (edge.from == b and edge.to == c) or (edge.from == c and edge.to == b) then
    reciprocal_count = reciprocal_count + 1
  end
end
assert(reciprocal_count == 1, "reciprocal cross-branch links have a single edge")
opts.depth = 2
selected = graph._select_graph(index, a, opts)
assert(selected.distance[deep] == 2 and #selected.order == 8, "depth two adds connected notes exactly once despite cycles")
opts.incoming = false
selected = graph._select_graph(index, a, opts)
assert(selected.distance[ref] == nil and selected.distance[deep] == 2, "outgoing-only traversal respects direction at every depth")
opts.outgoing, opts.incoming, opts.depth = false, true, 1
selected = graph._select_graph(index, a, opts)
assert(selected.distance[ref] == 1 and selected.distance[d] == 1 and selected.distance[missing] == nil, "incoming-only traversal excludes outgoing-only nodes")
opts.outgoing, opts.depth, opts.existing_only = true, 2, true
selected = graph._select_graph(index, a, opts)
assert(selected.distance[missing] == nil and #selected.order == 7, "existing-only hides missing nodes before traversal")
opts.neighbor_links = false
selected = graph._select_graph(index, a, opts)
assert(#selected.extra == 0 and selected.distance[deep] == 2, "neighbor toggle hides extra edges without dropping branches")
selected = graph._select_graph(index, a, opts, "DEEP")
assert(#selected.order == 3 and selected.parent[deep] == c, "filter preserves the center and path to a matching descendant")
opts.max_nodes = 2
selected = graph._select_graph(index, a, opts)
assert(#selected.order == 2 and selected.truncated, "node limits are explicit and bound graph expansion")
opts.max_nodes, opts.incoming, opts.outgoing = 500, false, false
assert(#graph._select_graph(index, a, opts).order == 1, "both directions disabled leave the center only")

-- Use a real note parser and temporary vault, with only the client boundary replaced.
package.loaded.obsidian = {
  get_client = function() return { dir = fixture, opts = { notes_subdir = "notes" } } end,
}
graph.setup()
vim.cmd.edit(vim.fn.fnameescape(a))
local source_win = vim.api.nvim_get_current_win()
local source_buf = vim.api.nvim_get_current_buf()
vim.cmd("ObsidianLocalGraph 2")
local state = graph._state
local function ready()
  return state.graph ~= nil and not state.loading
end
assert(vim.wait(4000, ready, 10), "async graph indexing completes")
assert(state.center == a and state.win ~= source_win, "command opens a graph beside the source note")
assert(vim.api.nvim_win_get_buf(source_win) == source_buf, "opening the graph preserves the editor")
local function text() return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n") end
assert(text():find("↔", 1, true) and text():find("NEIGHBOR LINKS", 1, true), "rendered graph includes reciprocal and cross edges")
assert(text():find("Depth 2", 1, true), "command argument controls graph depth")
local incoming_heading = text():find("INCOMING ←", 1, true)
local outgoing_heading = text():find("OUTGOING →", 1, true)
local mutual_heading = text():find("MUTUAL ↔", 1, true)
assert(incoming_heading and outgoing_heading and mutual_heading
  and incoming_heading < outgoing_heading and outgoing_heading < mutual_heading,
  "direction headings make the groups visible")
assert(text():find("[notes/b.md] ↔ C", 1, true), "reciprocal neighbor edges render with a bidirectional arrow")
local marks = vim.api.nvim_buf_get_extmarks(state.buf, vim.api.nvim_create_namespace("ObsidianLocalGraph"), 0, -1, { details = true })
local function has_highlight(id, token, group)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  for line, value in ipairs(lines) do
    if state.entries[line] == id then
      local column = value:find(token, 1, true)
      if column then
        for _, mark in ipairs(marks) do
          if mark[2] == line - 1 and mark[3] <= column - 1 and mark[4].end_col >= column - 1 + #token
            and mark[4].hl_group == group then return true end
        end
      end
      return false
    end
  end
  return false
end
for _, item in ipairs({
  { ref, "Incoming", "←", "ObsidianLocalGraphIncomingDepth1" },
  { path("dotted.name"), "Dotted", "→", "ObsidianLocalGraphOutgoingDepth1" },
  { b, "B", "↔", "ObsidianLocalGraphMutualDepth1" },
}) do
  assert(has_highlight(item[1], item[2], item[4]) and has_highlight(item[1], item[3], item[4]),
    "node titles and arrows share their relationship's highlight: " .. item[4])
end
local function key(name)
  local callback = vim.fn.maparg(name, "n", false, true).callback
  assert(type(callback) == "function", "buffer mapping exists: " .. name)
  callback()
end
local function select(id)
  for line = 1, vim.api.nvim_buf_line_count(state.buf) do
    if state.entries[line] == id then vim.api.nvim_win_set_cursor(state.win, { line, 0 }); return end
  end
  error("node not rendered: " .. id)
end
key("-")
assert(text():find("Depth 1", 1, true) and not text():find("[notes/deep.md]", 1, true), "depth mapping rerenders branches")
key("+")
key("n")
assert(not text():find("NEIGHBOR LINKS", 1, true), "neighbor links can be hidden interactively")
key("e")
assert(not text():find("(missing)", 1, true), "existing-only mapping hides unresolved links")
key("e")
local original_input = vim.ui.input
vim.ui.input = function(_, callback) callback("Deep") end
key("/")
assert(text():find("[notes/deep.md]", 1, true) and not text():find("[notes/ref.md]", 1, true), "interactive filter retains matching paths")
key("<Esc>")
vim.ui.input = original_input
select(missing)
key("<CR>")
assert(vim.api.nvim_get_current_win() == state.win and vim.fn.filereadable(path("Missing")) == 0, "opening a missing node never creates a file")
select(c)
key("c")
assert(state.center == c, "selection can become the graph center")
key("f")
vim.api.nvim_set_current_win(source_win)
vim.cmd.edit(vim.fn.fnameescape(b))
assert(state.center == c, "follow can be disabled")
vim.api.nvim_set_current_win(state.win)
key("f")
vim.api.nvim_set_current_win(source_win)
assert(vim.wait(1000, function() return state.center == b and not state.loading end, 10), "entering a note recenters with follow enabled")
vim.api.nvim_set_current_win(state.win)
select(a)
key("<CR>")
assert(vim.api.nvim_get_current_win() == source_win and vim.api.nvim_buf_get_name(0) == a, "Enter opens notes in the original editor")
assert(vim.wait(1000, function() return state.center == a and not state.loading end, 10), "opening a note also updates the center")
vim.api.nvim_buf_set_lines(source_buf, -1, -1, false, { "[[space name]]" })
graph.refresh(false)
assert(vim.wait(1000, ready, 10) and state.graph.outgoing[a][path("space name")], "unsaved buffer edits override cached disk entries")
vim.api.nvim_buf_set_lines(source_buf, -1, -1, false, { "[[unsaved-new]]" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = source_buf })
assert(vim.wait(2000, function()
  return not state.loading and state.graph.nodes["missing:" .. path("unsaved-new")] ~= nil
end, 10), "text changes refresh through the debounced autocmd")
vim.api.nvim_set_current_win(state.win)
local old_buf = state.buf
key("q")
assert(not vim.api.nvim_buf_is_valid(old_buf), "closing the graph releases its scratch buffer")
vim.api.nvim_set_current_win(source_win)
vim.cmd("ObsidianLocalGraph")
local second_buf = state.buf
assert(second_buf ~= old_buf, "closed graph can be reopened")
assert(vim.wait(2000, ready, 10), "reopening refreshes the graph")
graph.refresh(true)
graph.close()
vim.wait(200, function() return false end, 10)
assert(state.buf == nil and state.win == nil, "pending callbacks cannot resurrect a closed graph")

-- An editor may be closed while the graph remains; opening a node must create a normal editor.
graph.open(2)
assert(vim.wait(2000, ready, 10))
vim.api.nvim_win_close(source_win, true)
vim.api.nvim_set_current_win(state.win)
select(b)
key("<CR>")
assert(vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) == b, "opening from an orphaned graph creates an editing split")
assert(not vim.wo.winfixwidth, "new editor does not inherit fixed graph width")
assert(vim.wo.winbar == vim.o.winbar and vim.wo.foldenable == vim.o.foldenable, "new editor restores ordinary window options")
local recreated = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(state.win)
vim.api.nvim_win_close(recreated, true)
graph.close()
assert(state.buf == nil and state.win == nil and vim.bo.buftype == "", "last graph window can close safely")
assert(vim.wo.winbar == vim.o.winbar, "closing the last graph restores its window options")

vim.cmd.edit(vim.fn.fnameescape(path("new-empty")))
graph.open()
assert(vim.wait(2000, ready, 10) and state.graph.nodes[path("new-empty")], "a new empty unsaved note is still a graph center")
graph.close()
vim.fn.delete(fixture, "rf")
print("ok - local_graph_spec")
