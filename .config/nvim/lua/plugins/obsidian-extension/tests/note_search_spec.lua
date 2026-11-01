local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
vim.opt.runtimepath:prepend(root)

local vault = vim.fn.tempname()
vim.fn.mkdir(vault .. "/notes/nested", "p")
local older = vault .. "/notes/nested/old_topic.md"
local newer = vault .. "/notes/new.md"
vim.fn.writefile({ "old body", "body:only 日本語\twith tab", "last line" }, older)
vim.fn.writefile({ "topic newest", "needle only in the body" }, newer)
assert(vim.uv.fs_utime(older, 100, 100))
assert(vim.uv.fs_utime(newer, 200, 200))

local metadata_reads = 0
package.loaded["obsidian.note"] = {
  from_file = function(path)
    metadata_reads = metadata_reads + 1
    return { aliases = path == older and { "別名", "old alias" } or { "new alias" } }
  end,
}
package.loaded["obsidian.util"] = { get_icon = function() return "", "Special" end }
package.loaded["fzf-lua.utils"] = {
  ansi_from_hl = function(hl, text)
    local colors = { Directory = 34, Comment = 90, String = 32, Special = 36, LineNr = 33 }
    return ("\27[%dm%s\27[0m"):format(colors[hl], text)
  end,
}
local captured, captured_opts, finished
package.loaded["fzf-lua"] = {
  fzf_exec = function(contents, opts)
    captured, captured_opts, finished = {}, opts, false
    assert(type(contents) == "function", "source opens before collection completes")
    contents(nil, function(batch, callback)
      if batch then vim.list_extend(captured, batch) else finished = true end
      if callback then callback() end
    end)
  end,
  get_last_query = function() return "new note query" end,
}
local edited, callback_path, linked, new_query
local edit = function(selected, opts) edited = { selected, opts } end
package.loaded["fzf-lua.actions"] = {
  file_edit_or_qf = edit, file_split = edit, file_vsplit = edit, file_sel_to_qf = edit,
}
package.loaded["fzf-lua.path"] = {
  entry_to_file = function(entry, opts)
    return { path = vim.fs.normalize(vim.fs.joinpath(opts.cwd, entry:match("^(.-):%d+:1:"))) }
  end,
}

local search = require("obsidian_extension.features.note_search")
local picker = {
  client = { dir = vault, opts = { search_max_lines = 1000 } },
  _note_selection_mappings = function()
    return { ["<C-l>"] = { callback = function(path) linked = path end } }
  end,
  _note_query_mappings = function()
    return { ["<C-x>"] = { callback = function(query) new_query = query end } }
  end,
}
search.open(picker, { query = "tpc", callback = function(path) callback_path = path end })
assert(vim.wait(5000, function() return finished end), "async source finishes")
assert(#captured == 5, "one result per text line")
assert(metadata_reads == 2, "aliases are parsed only once per file")
assert(captured[1]:match("^%./notes/new.md:1:1:"), "most recently modified note is first")
assert(captured[3]:match("^%./notes/nested/old_topic.md:1:1:"), "older note follows in line order")
assert(captured_opts.query == "tpc", "initial query belongs to fzf")
assert(captured_opts.previewer == "builtin", "native location preview enabled")
assert(captured_opts.fzf_opts["--sort"] and captured_opts.fzf_opts["--no-sort"] == false,
  "fzf ranks search matches and clears inherited no-sort")
assert(captured[4]:find("body:only 日本語 with tab", 1, true), "body colons and Unicode survive; tabs cannot add fields")
assert(captured[3]:find("\27[34mold_topic.md", 1, true), "filename is highlighted")
assert(captured[3]:find("\27[32m別名, old alias", 1, true), "aliases are highlighted")

local function filter(query)
  local cmd = { "fzf", "--filter=" .. query }
  for flag, value in pairs(captured_opts.fzf_opts) do
    if value ~= false then
      cmd[#cmd + 1] = value == true and flag or flag .. "=" .. value
    end
  end
  local result = vim.system(cmd, {
    stdin = table.concat(captured, "\n"), text = true,
    env = { FZF_DEFAULT_OPTS = "", FZF_DEFAULT_OPTS_FILE = "" },
  }):wait()
  assert(result.code <= 1, result.stderr)
  return vim.split(result.stdout or "", "\n", { trimempty = true })
end

local matches = filter("tpc")
assert(#matches == 4, "real fzf fuzzily matches basename and body")
local initial = filter("")
assert(initial[1]:match("^%./notes/new.md:1:1:"), "empty query starts with the newest note")
assert(initial[3]:match("^%./notes/nested/old_topic.md:1:1:"), "empty query preserves file and line order")
assert(#filter("needle") == 1, "body-only query matches")
assert(#filter("別名") == 3, "alias query matches every line of the note")
assert(#filter("nested") == 3, "directory query matches")
assert(#filter("oldtop 日本語") == 1, "separate terms can match filename and body")
assert(#filter("old_topic.md:1:1") == 0, "hidden native location cannot accidentally match")
assert(#filter("1") == 0, "line number cannot accidentally match")

local selected = { captured[4] }
captured_opts.actions.enter(selected, captured_opts)
assert(edited and callback_path == older, "enter edits the selected line and preserves path callback")
captured_opts.actions["ctrl-l"](selected, captured_opts)
assert(linked == older, "insert-link mapping receives a note path")
captured_opts.actions["ctrl-x"]()
assert(new_query == "new note query", "new-note mapping receives the fuzzy query")

captured = nil
search.open(picker, { no_default_mappings = true, callback = function(path) callback_path = path end })
assert(vim.wait(5000, function() return finished end))
edited, callback_path = nil, nil
captured_opts.actions.enter({ captured[1] }, captured_opts)
assert(edited == nil and callback_path == newer, "callback-only searches do not open the note")
assert(captured_opts.actions["ctrl-l"] == nil, "default note mappings can be disabled")

-- A long JSON record arrives over multiple stdout chunks without a newline.
-- This also verifies that source batching does not truncate body matches.
vim.fn.writefile({ string.rep("x", 200000) .. " tail sentinel" }, vault .. "/notes/long.md")
search.open(picker, { no_default_mappings = true })
assert(vim.wait(5000, function() return finished end), "large records split across chunks finish")
assert(#captured == 6 and #filter("sentinel") == 1, "the full body remains searchable across chunk boundaries")

local exact = vault .. "/notes/architecture.md"
local partial = vault .. "/notes/architecture-notes.md"
local fuzzy = vault .. "/notes/a-r-c-h-i-t-e-c-t-u-r-e.md"
vim.fn.writefile({ "identical score" }, exact)
vim.fn.writefile({ "identical score" }, partial)
vim.fn.writefile({ "identical score" }, fuzzy)
assert(vim.uv.fs_utime(exact, 10, 10))
assert(vim.uv.fs_utime(partial, 20, 20))
assert(vim.uv.fs_utime(fuzzy, 30, 30))
search.open(picker, { query = "architecture", no_default_mappings = true })
assert(vim.wait(5000, function() return finished end))
local ranked = filter("architecture")
assert(#ranked == 3, "architecture includes exact, partial and fuzzy filenames")
assert(ranked[1]:match("^%./notes/architecture.md:1:1:"), "exact filename ranks above newer partial and fuzzy matches")
assert(ranked[2]:match("^%./notes/architecture%-notes.md:1:1:"), "contiguous partial match ranks above scattered characters")
assert(filter("identical")[1]:match("^%./notes/a%-r%-c%-h%-i%-t%-e%-c%-t%-u%-r%-e.md:1:1:"),
  "equally strong body matches preserve newest-first order")

vim.fn.delete(vault, "rf")
print("ok - note_search_spec")
