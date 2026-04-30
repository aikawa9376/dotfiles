local M = {}

local state = require("lazyagent.logic.state")
local edit_api = require("lazyagent.logic.edit_api")
local status = require("lazyagent.logic.status")
local transforms = require("lazyagent.transforms")
local util = require("lazyagent.util")

local ns = vim.api.nvim_create_namespace("lazyagent_edit_blocks")
local diff_fn = vim.text and vim.text.diff or vim.diff
local pending_by_buf = {}
local keymaps_by_buf = {}

local function edit_config()
  local defaults = {
    agent = "Copilot",
    transport = "command",
    command = nil,
    command_mode = "arg",
    timeout_ms = 90000,
    context_lines = 80,
    max_context_chars = 24000,
    preview = true,
    auto_apply = false,
    preserve_indent = true,
    max_inline_diff_lines = 120,
    api = {
      provider = nil,
      model = "gpt-4o-2024-11-20",
      endpoint = nil,
      proxy = nil,
      allow_insecure = false,
      use_response_api = nil,
      extra_headers = {},
      extra_body = {
        max_tokens = 20480,
      },
      copilot = {
        token_refresh_skew_seconds = 120,
      },
    },
    keymaps = {
      accept = "ct",
      accept_all = "ca",
      reject = "co",
      reject_alt = "cq",
      reject_none = "c0",
      next = "]]",
      prev = "[[",
    },
    candidates = {
      { name = "copilot", cmd = { "copilot", "-p" }, mode = "arg" },
      { name = "claude", cmd = { "claude", "-p" }, mode = "arg" },
      { name = "gemini", cmd = { "gemini", "-p" }, mode = "arg" },
    },
  }

  return vim.tbl_deep_extend("force", defaults, (state.opts and state.opts.edit_blocks) or {})
end

local function ensure_highlights()
  pcall(function()
    vim.api.nvim_set_hl(0, "LazyAgentEditCurrent", { link = "DiffDelete", default = true })
    vim.api.nvim_set_hl(0, "LazyAgentEditIncoming", { link = "DiffAdd", default = true })
    vim.api.nvim_set_hl(0, "LazyAgentEditHeader", { link = "DiffText", default = true })
    vim.api.nvim_set_hl(0, "LazyAgentEditHint", { link = "MoreMsg", default = true })
  end)
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_one_outer_newline(text)
  text = tostring(text or ""):gsub("\r\n", "\n")
  text = text:gsub("^\n", "")
  text = text:gsub("\n$", "")
  return text
end

local function split_replacement(text)
  text = tostring(text or ""):gsub("\r\n", "\n")
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function decode_json(text)
  local ok, decoded
  if vim.json and vim.json.decode then
    ok, decoded = pcall(vim.json.decode, text)
  else
    ok, decoded = pcall(vim.fn.json_decode, text)
  end
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

function M.extract_replacement(response)
  response = tostring(response or ""):gsub("\r\n", "\n")
  if response == "" then
    return nil, "empty response"
  end

  local tagged = response:match("<code>%s*\n?(.-)%s*</code>")
  if tagged ~= nil then
    return strip_one_outer_newline(tagged)
  end

  local json_block = response:match("```json%s*\n(.-)\n```")
  local parsed = json_block and decode_json(json_block) or decode_json(trim(response))
  if parsed then
    local value = parsed.replacement or parsed.code or parsed.content or parsed.text
    if type(value) == "string" then
      return strip_one_outer_newline(value)
    end
  end

  local fenced = response:match("```[%w_+%-%.]*%s*\n(.-)\n```")
  if fenced ~= nil then
    return strip_one_outer_newline(fenced)
  end

  local cleaned = trim(response)
  if cleaned == "" then
    return nil, "response did not contain replacement code"
  end
  return strip_one_outer_newline(cleaned)
end

local function first_executable(cmd)
  if type(cmd) == "table" then
    return cmd[1] and tostring(cmd[1]) or nil
  end
  if type(cmd) == "string" then
    return cmd:match("^%s*([^%s]+)")
  end
  return nil
end

local function executable_available(cmd)
  local exe = first_executable(cmd)
  return exe and exe ~= "" and vim.fn.executable(exe) == 1
end

local function normalize_runner(spec, opts)
  if type(spec) == "function" then
    return { name = "function", run = spec }
  end

  if type(spec) == "string" then
    return {
      name = first_executable(spec) or "custom",
      cmd = spec,
      mode = (opts and opts.command_mode) or "arg",
    }
  end

  if type(spec) ~= "table" then
    return nil
  end

  local cmd = spec.cmd or spec.command
  if not cmd and spec[1] then
    cmd = vim.deepcopy(spec)
  end
  if not cmd then
    return nil
  end

  return {
    name = spec.name or first_executable(cmd) or "custom",
    cmd = cmd,
    mode = spec.mode or spec.command_mode or (opts and opts.command_mode) or "arg",
    env = spec.env,
    cwd = spec.cwd,
  }
end

local function resolve_runners(opts)
  opts = opts or {}
  local cfg = edit_config()
  local explicit = opts.command or cfg.command
  if explicit then
    local runner = normalize_runner(explicit, { command_mode = opts.command_mode or cfg.command_mode })
    return runner and { runner } or {}, true
  end

  local runners = {}
  local agent_name = opts.agent or cfg.agent
  local agent_cfg = agent_name and state.opts and state.opts.interactive_agents and state.opts.interactive_agents[agent_name]
  local agent_cmd = agent_cfg and (agent_cfg.edit_cmd or agent_cfg.edit_command)
  if agent_cmd then
    local runner = normalize_runner(agent_cmd, {
      command_mode = agent_cfg.edit_command_mode or cfg.command_mode,
    })
    if runner and executable_available(runner.cmd) then
      runners[#runners + 1] = runner
    end
  end

  for _, candidate in ipairs(cfg.candidates or {}) do
    local runner = normalize_runner(candidate, { command_mode = cfg.command_mode })
    if runner and executable_available(runner.cmd) then
      runners[#runners + 1] = runner
    end
  end

  return runners, false
end

local function visual_or_mark_range(bufnr)
  local mode = vim.fn.mode()
  if mode:match("[vV\x16]") then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")

    if start_pos and end_pos and start_pos[2] > 0 and end_pos[2] > 0 then
      local start_line = start_pos[2]
      local finish_line = end_pos[2]
      if start_line > finish_line then
        start_line, finish_line = finish_line, start_line
      end

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      start_line = math.max(1, math.min(start_line, line_count))
      finish_line = math.max(1, math.min(finish_line, line_count))
      return start_line, finish_line
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1], cursor[1]
end

local function leave_visual_mode()
  if vim.fn.mode():match("[vV\x16]") then
    pcall(vim.cmd, "normal! \027")
  end
end

local function truncate_context(lines, max_chars)
  max_chars = tonumber(max_chars) or 0
  if max_chars <= 0 then
    return lines
  end

  local total = 0
  local out = {}
  for _, line in ipairs(lines) do
    total = total + #line + 1
    if total > max_chars then
      out[#out + 1] = "... (context truncated)"
      break
    end
    out[#out + 1] = line
  end
  return out
end

local function numbered_lines(lines, start_line)
  local out = {}
  for i, line in ipairs(lines or {}) do
    out[#out + 1] = string.format("%5d | %s", start_line + i - 1, line)
  end
  return table.concat(out, "\n")
end

local function selection_diagnostics(bufnr, start_line, finish_line)
  local out = {}
  for _, diag in ipairs(transforms.gather_diagnostics(bufnr) or {}) do
    local lnum = tonumber(diag.lnum) or 0
    if lnum >= start_line and lnum <= finish_line then
      out[#out + 1] = string.format(
        "- %s line %d:%d %s",
        tostring(diag.severity or "?"),
        lnum,
        tonumber(diag.col) or 0,
        tostring(diag.message or "")
      )
    end
  end
  return out
end

local function capture_selection(opts)
  opts = opts or {}
  local cfg = edit_config()
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid buffer"
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = opts.line1
  local finish_line = opts.line2
  if not start_line or not finish_line then
    start_line, finish_line = visual_or_mark_range(bufnr)
  end
  start_line = math.max(1, math.min(tonumber(start_line) or 1, line_count))
  finish_line = math.max(1, math.min(tonumber(finish_line) or start_line, line_count))
  if start_line > finish_line then
    start_line, finish_line = finish_line, start_line
  end

  local original_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, finish_line, false)
  if #original_lines == 0 then
    return nil, "selection is empty"
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = util.git_root_for_path(path) or vim.fn.getcwd()
  local relpath = path
  if path ~= "" and root ~= "" and path:sub(1, #root) == root then
    relpath = path:sub(#root + 2)
  end
  local filetype = vim.bo[bufnr].filetype or ""
  local context_lines = tonumber(opts.context_lines or cfg.context_lines) or 80
  local before_start = math.max(1, start_line - context_lines)
  local after_finish = math.min(line_count, finish_line + context_lines)
  local before_lines = vim.api.nvim_buf_get_lines(bufnr, before_start - 1, start_line - 1, false)
  local after_lines = vim.api.nvim_buf_get_lines(bufnr, finish_line, after_finish, false)
  local max_context_chars = tonumber(opts.max_context_chars or cfg.max_context_chars) or 24000

  return {
    bufnr = bufnr,
    winid = vim.api.nvim_get_current_win(),
    path = path,
    relpath = relpath,
    root = root,
    filetype = filetype,
    line_count = line_count,
    start_line = start_line,
    finish_line = finish_line,
    before_start = before_start,
    before_lines = truncate_context(before_lines, math.floor(max_context_chars / 2)),
    after_start = finish_line + 1,
    after_lines = truncate_context(after_lines, math.floor(max_context_chars / 2)),
    original_lines = original_lines,
    diagnostics = selection_diagnostics(bufnr, start_line, finish_line),
  }
end

local function build_prompt(ctx, request)
  local lang = ctx.filetype ~= "" and ctx.filetype or "text"
  local diagnostics = (#ctx.diagnostics > 0) and table.concat(ctx.diagnostics, "\n") or "(none)"

  return table.concat({
    "You are editing a selected range in a source file.",
    "Return ONLY the complete replacement for the selected range.",
    "Wrap the replacement in <code>...</code> and do not include markdown fences, explanations, or line numbers.",
    "Do not edit code outside the selected range. Preserve surrounding behavior and indentation.",
    "",
    "File: " .. (ctx.relpath ~= "" and ctx.relpath or ctx.path),
    "Language: " .. lang,
    string.format("Selected lines: %d-%d", ctx.start_line, ctx.finish_line),
    "",
    "User request:",
    request,
    "",
    "Diagnostics in selected range:",
    diagnostics,
    "",
    "Context before selection:",
    "```" .. lang,
    numbered_lines(ctx.before_lines, ctx.before_start),
    "```",
    "",
    "Selected code to replace:",
    "<selection>",
    table.concat(ctx.original_lines, "\n"),
    "</selection>",
    "",
    "Context after selection:",
    "```" .. lang,
    numbered_lines(ctx.after_lines, ctx.after_start),
    "```",
    "",
    "Respond exactly as:",
    "<code>",
    "replacement code here",
    "</code>",
  }, "\n")
end

local function run_job(runner, prompt, ctx, opts, callback)
  opts = opts or {}
  local mode = runner.mode or "arg"
  local cmd
  if type(runner.cmd) == "table" then
    cmd = vim.deepcopy(runner.cmd)
    if mode == "arg" then
      cmd[#cmd + 1] = prompt
    end
  elseif type(runner.cmd) == "string" then
    cmd = runner.cmd
    if mode == "arg" then
      cmd = cmd .. " " .. vim.fn.shellescape(prompt)
    end
  else
    callback(false, "", "invalid command")
    return
  end

  local stdout = {}
  local stderr = {}
  local timer
  local finished = false
  local timeout_ms = tonumber(opts.timeout_ms) or edit_config().timeout_ms

  local function finish(ok, out, err)
    if finished then
      return
    end
    finished = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
    end
    callback(ok, out, err)
  end

  local job = vim.fn.jobstart(cmd, {
    cwd = runner.cwd or ctx.root,
    env = runner.env,
    stdin = mode == "stdin" and "pipe" or nil,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if type(data) == "table" then
        for _, line in ipairs(data) do
          stdout[#stdout + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      if type(data) == "table" then
        for _, line in ipairs(data) do
          stderr[#stderr + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      local out = table.concat(stdout, "\n")
      local err = table.concat(stderr, "\n")
      if code == 0 then
        finish(true, out, err)
      else
        finish(false, out, err ~= "" and err or ("exit code " .. tostring(code)))
      end
    end,
  })

  if job <= 0 then
    finish(false, "", "failed to start " .. tostring(runner.name))
    return
  end

  if mode == "stdin" then
    vim.fn.chansend(job, prompt)
    vim.fn.chanclose(job, "stdin")
  end

  if timeout_ms > 0 then
    timer = vim.loop.new_timer()
    timer:start(timeout_ms, 0, vim.schedule_wrap(function()
      pcall(vim.fn.jobstop, job)
      finish(false, table.concat(stdout, "\n"), "timed out after " .. tostring(timeout_ms) .. "ms")
    end))
  end
end

local function run_function(runner, prompt, ctx, _opts, callback)
  local ok, result = pcall(runner.run, prompt, ctx, callback)
  if not ok then
    callback(false, "", result)
    return
  end
  if type(result) == "string" then
    callback(true, result, "")
  elseif type(result) == "table" then
    callback(result.ok ~= false, result.stdout or result.output or "", result.stderr or result.error or "")
  end
end

local function run_runner(runner, prompt, ctx, opts, callback)
  if runner.run then
    run_function(runner, prompt, ctx, opts, callback)
    return
  end
  run_job(runner, prompt, ctx, opts, callback)
end

local function same_lines(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function current_range(ctx)
  local start_line = ctx.start_line
  local finish_line = ctx.finish_line
  if ctx.start_mark_id then
    local start_pos = vim.api.nvim_buf_get_extmark_by_id(ctx.bufnr, ns, ctx.start_mark_id, {})
    if start_pos and start_pos[1] then
      start_line = start_pos[1] + 1
    end
  end
  if ctx.end_mark_id then
    local end_pos = vim.api.nvim_buf_get_extmark_by_id(ctx.bufnr, ns, ctx.end_mark_id, {})
    if end_pos and end_pos[1] then
      finish_line = end_pos[1] + 1
    end
  end
  if finish_line < start_line then
    finish_line = start_line
  end
  return start_line, finish_line
end

local function current_selection_matches(ctx)
  if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return false, "buffer is no longer valid"
  end
  local start_line, finish_line = current_range(ctx)
  local current = vim.api.nvim_buf_get_lines(ctx.bufnr, start_line - 1, finish_line, false)
  if same_lines(current, ctx.original_lines) then
    ctx.start_line = start_line
    ctx.finish_line = finish_line
    return true
  end
  return false, "selected range changed while waiting for the edit"
end

local function base_indent(lines)
  for _, line in ipairs(lines or {}) do
    local indent = line:match("^(%s*)%S")
    if indent then
      return indent
    end
  end
  return ""
end

local function maybe_preserve_indent(ctx, replacement_lines, opts)
  opts = opts or {}
  if opts.preserve_indent == false then
    return replacement_lines
  end

  local indent = base_indent(ctx.original_lines)
  if indent == "" or #replacement_lines == 0 then
    return replacement_lines
  end

  local replacement_indent = base_indent(replacement_lines)
  if replacement_indent ~= "" then
    return replacement_lines
  end

  local out = {}
  for _, line in ipairs(replacement_lines) do
    out[#out + 1] = line == "" and line or (indent .. line)
  end
  return out
end

local function clear_keymaps(bufnr)
  local keys = keymaps_by_buf[bufnr]
  if not keys then return end
  for _, key in ipairs(keys) do
    pcall(vim.keymap.del, "n", key, { buffer = bufnr })
  end
  keymaps_by_buf[bufnr] = nil
end

local function clear_inline(ctx)
  if ctx and ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr) then
    vim.api.nvim_buf_clear_namespace(ctx.bufnr, ns, 0, -1)
    pending_by_buf[ctx.bufnr] = nil
    clear_keymaps(ctx.bufnr)
  end
end

function M.apply(ctx)
  local ok, err = current_selection_matches(ctx)
  if not ok then
    vim.notify("LazyAgentEdit: " .. err, vim.log.levels.ERROR)
    return false
  end

  vim.api.nvim_buf_set_lines(ctx.bufnr, ctx.start_line - 1, ctx.finish_line, false, ctx.replacement_lines or {})
  clear_inline(ctx)
  if ctx.winid and vim.api.nvim_win_is_valid(ctx.winid) then
    pcall(vim.api.nvim_set_current_win, ctx.winid)
    pcall(vim.api.nvim_win_set_cursor, ctx.winid, { ctx.start_line, 0 })
  end
  util.fire_event("EditBlocksApplied", {
    bufnr = ctx.bufnr,
    path = ctx.path,
    start_line = ctx.start_line,
    finish_line = ctx.finish_line,
  })
  vim.notify("LazyAgentEdit: applied selected block edit", vim.log.levels.INFO)
  return true
end

local function reject(ctx)
  clear_inline(ctx)
end

local function unified_diff(ctx)
  local old_text = table.concat(ctx.original_lines or {}, "\n")
  local new_text = table.concat(ctx.replacement_lines or {}, "\n")
  local ok, diff = pcall(diff_fn, old_text, new_text, {
    result_type = "unified",
    ctxlen = 3,
    algorithm = "histogram",
  })
  if ok and type(diff) == "string" and diff ~= "" then
    return vim.tbl_filter(function(line)
      return line ~= "\\ No newline at end of file"
    end, vim.split(diff, "\n", { plain = true }))
  end
  return {
    "--- original",
    "+++ replacement",
    "@@ selected range @@",
    "- " .. old_text:gsub("\n", "\n- "),
    "+ " .. new_text:gsub("\n", "\n+ "),
  }
end

local function mark_selection(ctx)
  local last_line = ctx.original_lines[#ctx.original_lines] or ""
  pcall(function()
    vim.api.nvim_buf_clear_namespace(ctx.bufnr, ns, 0, -1)
    ctx.start_mark_id = vim.api.nvim_buf_set_extmark(ctx.bufnr, ns, ctx.start_line - 1, 0, {})
    ctx.end_mark_id = vim.api.nvim_buf_set_extmark(ctx.bufnr, ns, ctx.finish_line - 1, #last_line, {})
    ctx.selection_mark_id = vim.api.nvim_buf_set_extmark(ctx.bufnr, ns, ctx.start_line - 1, 0, {
      hl_group = "LazyAgentEditCurrent",
      hl_eol = true,
      hl_mode = "combine",
      end_row = ctx.finish_line - 1,
      end_col = #last_line,
    })
  end)
end

local function diff_hl(line)
  if line:match("^%+[^+]") then return "LazyAgentEditIncoming" end
  if line:match("^%-[^-]") then return "LazyAgentEditCurrent" end
  if line:match("^@@") then return "LazyAgentEditHeader" end
  return "Comment"
end

local function inline_diff_lines(ctx)
  local cfg = edit_config()
  local lines = {
    string.format(
      "LazyAgentEdit %s:%d-%d  %s accept  %s accept-all  %s/%s reject",
      ctx.relpath ~= "" and ctx.relpath or ctx.path,
      ctx.start_line,
      ctx.finish_line,
      cfg.keymaps.accept or "ct",
      cfg.keymaps.accept_all or "ca",
      cfg.keymaps.reject or "co",
      cfg.keymaps.reject_alt or "cq"
    ),
  }
  local diff_lines = unified_diff(ctx)
  local max_lines = tonumber(cfg.max_inline_diff_lines) or 120
  for i, line in ipairs(diff_lines) do
    if i > max_lines then
      lines[#lines + 1] = "... diff truncated ..."
      break
    end
    lines[#lines + 1] = line
  end

  local virt = {}
  for i, line in ipairs(lines) do
    virt[#virt + 1] = { { "  " .. line, i == 1 and "LazyAgentEditHint" or diff_hl(line) } }
  end
  return virt
end

local function pending_for_current_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  return pending_by_buf[bufnr]
end

function M.apply_current()
  local ctx = pending_for_current_buffer()
  if not ctx then
    vim.notify("LazyAgentEdit: no pending edit in this buffer", vim.log.levels.INFO)
    return
  end
  M.apply(ctx)
end

function M.reject_current()
  local ctx = pending_for_current_buffer()
  if not ctx then
    vim.notify("LazyAgentEdit: no pending edit in this buffer", vim.log.levels.INFO)
    return
  end
  reject(ctx)
  vim.notify("LazyAgentEdit: rejected edit", vim.log.levels.INFO)
end

function M.apply_all_pending()
  local pending = {}
  for _, ctx in pairs(pending_by_buf) do
    pending[#pending + 1] = ctx
  end
  if #pending == 0 then
    vim.notify("LazyAgentEdit: no pending edits", vim.log.levels.INFO)
    return
  end
  for _, ctx in ipairs(pending) do
    M.apply(ctx)
  end
end

local function jump_pending(direction)
  local current_buf = vim.api.nvim_get_current_buf()
  if pending_by_buf[current_buf] then
    local start_line = current_range(pending_by_buf[current_buf])
    vim.api.nvim_win_set_cursor(0, { start_line, 0 })
    return
  end

  local bufs = {}
  for bufnr, _ in pairs(pending_by_buf) do
    bufs[#bufs + 1] = bufnr
  end
  table.sort(bufs)
  if #bufs == 0 then
    vim.notify("LazyAgentEdit: no pending edits", vim.log.levels.INFO)
    return
  end
  local target = direction == "prev" and bufs[#bufs] or bufs[1]
  vim.api.nvim_set_current_buf(target)
  local start_line = current_range(pending_by_buf[target])
  vim.api.nvim_win_set_cursor(0, { start_line, 0 })
end

local function set_keymaps(bufnr)
  if keymaps_by_buf[bufnr] then return end
  local keys = {}
  local cfg = edit_config().keymaps or {}
  local function add(lhs, rhs, desc)
    if not lhs or lhs == "" then return end
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
    keys[#keys + 1] = lhs
  end
  add(cfg.accept or "ct", M.apply_current, "LazyAgent edit accept")
  add(cfg.accept_all or "ca", M.apply_all_pending, "LazyAgent edit accept all")
  add(cfg.reject or "co", M.reject_current, "LazyAgent edit reject")
  add(cfg.reject_alt or "cq", M.reject_current, "LazyAgent edit reject")
  add(cfg.reject_none or "c0", M.reject_current, "LazyAgent edit reject")
  add(cfg.next or "]]", function() jump_pending("next") end, "LazyAgent edit next")
  add(cfg.prev or "[[", function() jump_pending("prev") end, "LazyAgent edit previous")
  keymaps_by_buf[bufnr] = keys
end

local function show_inline_diff(ctx)
  local previous = pending_by_buf[ctx.bufnr]
  if previous and previous ~= ctx then
    reject(previous)
  end
  pending_by_buf[ctx.bufnr] = ctx
  ensure_highlights()
  mark_selection(ctx)
  set_keymaps(ctx.bufnr)

  local _, finish_line = current_range(ctx)
  local row = math.max(0, math.min(finish_line - 1, vim.api.nvim_buf_line_count(ctx.bufnr) - 1))
  ctx.preview_mark_id = vim.api.nvim_buf_set_extmark(ctx.bufnr, ns, row, 0, {
    virt_lines = inline_diff_lines(ctx),
    virt_lines_above = false,
  })

  if ctx.winid and vim.api.nvim_win_is_valid(ctx.winid) then
    pcall(vim.api.nvim_set_current_win, ctx.winid)
    pcall(vim.api.nvim_win_set_cursor, ctx.winid, { ctx.start_line, 0 })
  end
  vim.notify("LazyAgentEdit: ct accept, ca accept all, co/cq reject", vim.log.levels.INFO)
end

local function handle_response(ctx, response, opts)
  local replacement, parse_err = M.extract_replacement(response)
  if not replacement then
    reject(ctx)
    vim.notify("LazyAgentEdit: " .. tostring(parse_err), vim.log.levels.ERROR)
    return false
  end

  ctx.replacement_lines = maybe_preserve_indent(ctx, split_replacement(replacement), opts)
  if same_lines(ctx.original_lines, ctx.replacement_lines) then
    reject(ctx)
    vim.notify("LazyAgentEdit: agent returned unchanged code", vim.log.levels.INFO)
    return true
  end

  if opts.auto_apply or opts.preview == false then
    M.apply(ctx)
  else
    show_inline_diff(ctx)
  end
  return true
end

local function submit(ctx, request, opts)
  opts = opts or {}

  local prompt = build_prompt(ctx, request)
  local transport = trim(opts.transport):lower()
  if transport == "" then
    transport = "command"
  end
  local errors = {}
  ctx.status_task_id = status.start_task("Edit", { icon = "" })

  local function stop_loading()
    if ctx.status_task_id then
      status.stop_task(ctx.status_task_id)
      ctx.status_task_id = nil
    end
  end

  if transport == "api" then
    vim.notify("LazyAgentEdit: requesting " .. edit_api.label(opts), vim.log.levels.INFO)
    edit_api.request(prompt, ctx, opts, function(ok, stdout, stderr)
      vim.schedule(function()
        if not ok then
          stop_loading()
          reject(ctx)
          vim.notify("LazyAgentEdit failed: " .. trim(stderr), vim.log.levels.ERROR)
          return
        end

        handle_response(ctx, stdout, opts)
        stop_loading()
      end)
    end)
    return
  end

  if transport ~= "command" then
    stop_loading()
    reject(ctx)
    vim.notify("LazyAgentEdit: unsupported transport '" .. tostring(transport) .. "'", vim.log.levels.ERROR)
    return
  end

  local runners, explicit = resolve_runners(opts)
  if #runners == 0 then
    stop_loading()
    vim.notify("LazyAgentEdit: no one-shot edit command found. Configure edit_blocks.command.", vim.log.levels.ERROR)
    reject(ctx)
    return
  end

  local function attempt(index)
    local runner = runners[index]
    if not runner then
      stop_loading()
      reject(ctx)
      vim.notify("LazyAgentEdit failed:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
      return
    end

    vim.notify("LazyAgentEdit: running " .. tostring(runner.name), vim.log.levels.INFO)
    run_runner(runner, prompt, ctx, opts, function(ok, stdout, stderr)
      vim.schedule(function()
        if not ok then
          errors[#errors + 1] = tostring(runner.name) .. ": " .. trim(stderr)
          if explicit then
            stop_loading()
            reject(ctx)
            vim.notify("LazyAgentEdit failed: " .. trim(stderr), vim.log.levels.ERROR)
          else
            attempt(index + 1)
          end
          return
        end

        local parsed_ok = handle_response(ctx, stdout, opts)
        if parsed_ok or explicit then
          stop_loading()
        end
        if not parsed_ok and not explicit then
          errors[#errors + 1] = tostring(runner.name) .. ": invalid replacement"
          attempt(index + 1)
        end
      end)
    end)
  end

  attempt(1)
end

function M.edit_selection(opts)
  opts = vim.tbl_deep_extend("force", edit_config(), opts or {})
  local ctx, err = capture_selection(opts)
  if not ctx then
    vim.notify("LazyAgentEdit: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  leave_visual_mode()
  ensure_highlights()
  mark_selection(ctx)

  local request = opts.request or opts.args
  if request and trim(request) ~= "" then
    submit(ctx, trim(request), opts)
    return
  end

  vim.ui.input({ prompt = "LazyAgent edit> " }, function(input)
    input = trim(input)
    if input == "" then
      reject(ctx)
      return
    end
    submit(ctx, input, opts)
  end)
end

return M
