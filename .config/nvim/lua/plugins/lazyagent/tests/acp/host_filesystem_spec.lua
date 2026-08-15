local M = {}

local function equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local base = vim.fn.tempname() .. "-host-fs"
  vim.fn.mkdir(base, "p")
  local path = base .. "/fixture.txt"
  vim.fn.writefile({ "disk one", "disk two", "disk three" }, path)
  local outside = vim.fn.tempname() .. "-outside.txt"
  vim.fn.writefile({ "outside disk" }, outside)

  local state_helpers = require("lazyagent.acp.backend.state").setup({
    cache_logic = { get_cache_dir = function() return base end, build_cache_prefix = function() return "fixture-" end },
    util = require("lazyagent.util"), state = { opts = {} }, normalize_text = function(value) return value end,
    append_block = function() end,
  })
  local host = require("lazyagent.acp.backend.host").setup({
    ACPClient = {}, state = { opts = {} }, acp_logic = {}, util = require("lazyagent.util"),
    build_transcript_path = state_helpers.build_transcript_path,
    clamp_utf8_from_end = state_helpers.clamp_utf8_from_end,
    ensure_parent_dir = state_helpers.ensure_parent_dir,
    read_path_lines = state_helpers.read_path_lines,
    reload_loaded_buffers_for_path = function() end,
    write_session_transcript = function() end,
    sync_runtime_session = function() end,
    update_session_info = function() end,
    update_usage_stats = function() end,
    normalize_session_info = function() end,
    assistant_heading_label = function() return "Assistant" end,
    apply_initial_session_config = function(_, done) done() end,
    normalize_available_commands = function() return {} end,
    append_block = function() end, append_stream_chunk = function() end, close_stream = function() end,
    render_content = function() return "" end, render_tool_content = function() return "" end,
    render_tool_raw_output = function() return "" end, summarize_tool_block = function() return "" end,
    extract_tool_paths = function() return {} end, merge_tool_update = function() return {} end,
    tool_update_is_terminal = function() return false end, tool_heading = function() return "Tool" end,
    resolve_permission_rule = function() end, render_permission_preview = function() return "" end,
    maybe_call_mcp_tool = function() end, maybe_sync_acp_edit_targets = function() end,
  })
  local session = { cwd = base, additional_directories = {}, terminals = {}, read_only_guards = {} }

  local bufnr = vim.fn.bufadd(path)
  vim.bo[bufnr].buflisted = true
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "buffer one", "buffer two", "buffer three" })
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local response = assert(host.read_text_file(session, { path = path, line = 2, limit = 1 }))
  equal(response, { content = "buffer two" }, "READ-01/03 loaded buffer slice wins")
  equal(session.last_read.source, "buffer", "READ-05 buffer provenance")
  equal(session.last_read.bufnr, bufnr, "READ-05 buffer identity")
  equal(session.last_read.changedtick, changedtick, "READ-05 changedtick")
  assert(not vim.inspect(session.last_read):find("buffer two", 1, true), "READ-05 provenance contains no content")
  vim.api.nvim_buf_delete(bufnr, { force = true })

  response = assert(host.read_text_file(session, { path = path, line = 2, limit = 2 }))
  equal(response, { content = "disk two\ndisk three" }, "READ-02/03 disk slice semantics")
  equal(session.last_read, { source = "disk", path = vim.fn.fnamemodify(path, ":p") }, "READ-06 disk provenance")

  local previous = vim.deepcopy(session.last_read)
  local rejected, rejected_err = host.read_text_file(session, { path = outside })
  equal(rejected, nil, "READ-04 outside root rejected")
  assert(rejected_err and rejected_err.code == -32602, "READ-04 path guard error")
  equal(session.last_read, previous, "READ-04 guard runs before source/provenance lookup")

  local special = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(special, path)
  vim.api.nvim_buf_set_lines(special, 0, -1, false, { "special content" })
  local special_lines, special_bufnr, special_provenance = state_helpers.read_path_lines(path)
  equal(special_lines, { "disk one", "disk two", "disk three" }, "special/unlisted buffer is conservatively excluded")
  equal(special_bufnr, nil, "special buffer is not selected")
  equal(special_provenance.source, "disk", "special buffer falls back to disk provenance")
  vim.api.nvim_buf_delete(special, { force = true })

  vim.fn.delete(base, "rf")
  vim.fn.delete(outside)
end

return M
