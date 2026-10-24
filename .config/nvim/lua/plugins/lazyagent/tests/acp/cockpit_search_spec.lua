local M = {}
function M.run()
  local Search = require("lazyagent.acp.cockpit_search")
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname() .. "-cockpit-search"
  vim.fn.mkdir(root, "p")
  local first, second = root .. "/first.md", root .. "/second.md"
  vim.fn.writefile({ "# User", "Needle prompt", "# Assistant", "回答 Needle", "# Tool", "result NEEDLE" }, first)
  vim.fn.writefile({ "# Assistant", "Only here: second answer" }, second)
  local threads = {
    { thread_id = "one", title = "First thread", provider_id = "Codex", cwd = root, transcript_path = first },
    { thread_id = "two", title = "Second thread", provider_id = "Claude", cwd = root, transcript_path = second },
    { thread_id = "missing", transcript_path = root .. "/missing.md" },
    { thread_id = "native-only", transcript_path = "" },
  }
  local report = assert(Search.scan(threads, "needle", { chunk_bytes = 8 }))
  assert(#report.hits == 3 and report.hits[1].line == 2 and report.hits[3].line == 6, "body search spans user, assistant and tool transcript lines")
  assert(report.stats.searched == 2 and report.stats.unavailable == 2, "missing native/local sources are visible")
  assert(report.hits[2].column == #"回答 " + 1, "UTF-8 positions use exact byte columns")
  assert(#Search.scan(threads, "NEEDLE prompt").hits == 1, "literal phrase and ASCII case insensitive search")
  assert(#Search.scan(threads, "[needle].*").hits == 0, "regular-expression characters are literal")
  assert(not Search.scan(threads, "") and not Search.scan(threads, "bad\nquery"), "empty/control text is rejected")
  local limited = Search.scan(threads, "needle", { per_thread = 1 })
  assert(#limited.hits == 1 and limited.stats.limited == 1, "per-thread match cap is explicit")
  assert(Search.scan(threads, "needle", { max_threads = 1 }).limits[1] == "thread limit", "thread budget is explicit")
  assert(Search.scan(threads, "needle", { max_results = 1 }).limits[1] == "result limit", "result budget is explicit")
  assert(Search.scan(threads, "needle", { max_bytes = 8 }).limits[1] == "byte limit", "byte budget is explicit")
  assert(Search.scan(threads, "needle", { max_file_bytes = 8 }).stats.oversized == 2, "oversized sources are counted")
  assert(Search.scan(threads, "needle", { timeout_ms = 0 }).limits[1] == "time limit", "time budget is explicit")
  local old_fstat, stat_calls = uv.fs_fstat, 0
  uv.fs_fstat = function(fd)
    stat_calls = stat_calls + 1
    local value = old_fstat(fd)
    if stat_calls == 2 then value.size = value.size + 1 end
    return value
  end
  local changed = Search.scan({ threads[1] }, "needle")
  uv.fs_fstat = old_fstat
  assert(changed.stats.changed == 1 and #changed.hits == 0, "a source changed during scanning does not publish unstable positions")
  local long = root .. "/long.md"
  vim.fn.writefile({ string.rep("あ", 10000) .. "CrossChunkNeedle" .. string.rep("あ", 5000) }, long)
  local long_report = assert(Search.scan({ { thread_id = "long", transcript_path = long } }, "crosschunkneedle", { chunk_bytes = 17 }))
  assert(#long_report.hits == 1 and long_report.hits[1].column == #string.rep("あ", 10000) + 1, "long lines and chunk-boundary matches retain correct positions")
  assert(pcall(vim.json.encode, long_report), "bounded snippets are valid printable UTF-8")
  local binary = root .. "/binary.md"
  local binary_fd = assert(uv.fs_open(binary, "w", 384))
  assert(uv.fs_write(binary_fd, "needle\0data", 0))
  uv.fs_close(binary_fd)
  assert(Search.scan({ { transcript_path = binary } }, "needle").stats.binary == 1, "binary sources are not searchable text")
  local hit = report.hits[1]
  local opened = assert(Search.read_hit(hit, "needle"))
  assert(opened.lines[2] == "Needle prompt" and opened.line == 2, "opening revalidates exact match location")
  vim.fn.writefile({ "appended response" }, first, "a")
  assert(Search.read_hit(hit, "needle"), "append-only growth preserves stable match navigation")
  vim.fn.writefile({ "inserted", "# User", "Needle prompt" }, first)
  local _, stale = Search.read_hit(hit, "needle")
  assert(stale:find("moved or changed", 1, true), "shifted result cannot jump to unrelated text")
  vim.fn.writefile({ "# User", "Needle prompt", "# Assistant", "回答 Needle", "# Tool", "result NEEDLE" }, first)
  local fresh = Search.scan(threads, "needle")
  local replacement = root .. "/replacement.md"
  vim.fn.writefile(vim.fn.readfile(first), replacement)
  assert(uv.fs_rename(replacement, first))
  assert(not Search.read_hit(fresh.hits[1], "needle"), "replaced transcript requires a fresh search")

  local async_report, async_error
  assert(Search.search(threads, "second answer", function(value, err) async_report, async_error = value, err end))
  assert(vim.wait(4000, function() return async_report or async_error end, 10), "search worker finishes")
  assert(not async_error and #async_report.hits == 1 and async_report.hits[1].thread_id == "two", "worker IPC preserves thread identity")

  local tab = vim.api.nvim_get_current_tabpage()
  local owner = vim.api.nvim_create_buf(false, true)
  local handle = Search.open(threads, "second answer", { owner_buf = owner, scope = "provider:Claude" })
  local buf = handle.bufnr
  assert(vim.wait(4000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:find("1 matches", 1, true)
  end, 10), "search results are rendered asynchronously")
  assert(not vim.bo[buf].modifiable, "search results are read-only")
  vim.fn.maparg("<C-y>", "n", false, true).callback()
  assert(vim.fn.getreg('"') == "agent:two", "search can copy the exact matched thread reference")
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(vim.wait(4000, function() return vim.api.nvim_get_current_tabpage() ~= tab end, 10), "opening a match is asynchronous")
  assert(vim.b.lazyagent_search_thread_id == "two" and vim.api.nvim_win_get_cursor(0)[1] == 2 and not vim.bo.modifiable,
    "match opens an immutable transcript snapshot at its source location")
  assert(vim.api.nvim_buf_get_name(0):find("lazyagent://search-hit/", 1, true), "search never edits the live transcript buffer")
  vim.cmd("normal q")
  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  vim.cmd("normal q")
  assert(not vim.api.nvim_buf_is_valid(buf), "closing results disposes the owner view")
  local old_system, cancelled, late_callback = vim.system, 0, nil
  vim.system = function(_, _, callback) late_callback = callback; return { kill = function() cancelled = cancelled + 1 end } end
  local pending = Search.open(threads, "needle", { owner_buf = owner })
  vim.system = old_system
  vim.api.nvim_buf_delete(owner, { force = true })
  assert(vim.wait(1000, function() return not vim.api.nvim_buf_is_valid(pending.bufnr) end, 10), "owner wipe closes pending results")
  assert(cancelled == 1, "owner wipe cancels the worker")
  late_callback({ code = 0, stdout = vim.json.encode({ hits = {}, stats = {}, limits = {} }) })
  vim.wait(20, function() return false end, 5)
  assert(not vim.api.nvim_buf_is_valid(pending.bufnr), "a late result cannot recreate disposed search UI")
  local failed_callback, failure
  vim.system = function(_, _, callback) failed_callback = callback; return { kill = function() end } end
  Search.search(threads, "needle", function(_, err) failure = err end)
  vim.system = old_system
  failed_callback({ code = 1, stdout = "" })
  assert(vim.wait(500, function() return failure ~= nil end, 5), "worker failure is reported instead of empty results")
  vim.fn.delete(root, "rf")
end
return M
