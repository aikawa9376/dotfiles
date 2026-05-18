-- Transformation utilities for lazyagent: token expansion, git context, and diagnostics.
-- Provides M.expand(text, opts) which replaces tokens in `text` with contextual values.
-- Known tokens:
--  - #buffer      -> "@<path>" (path relative to git root or cwd)
--  - #buffer_abs  -> absolute path of the source buffer
--  - #buffers     -> newline-separated list of "bufferline"-equivalent buffers (listed buffers) with "@" prefix
--  - #buffers_abs -> newline-separated list of bufferline-equivalent buffers, absolute paths with "@" prefix
--  - #directory   -> Directory of the source buffer (relative to git root if available), prefixed with '@'.
--  - #git_root    -> repository root path for the source buffer (git)
--  - #git_branch  -> git branch name for the source buffer
--  - #diagnostics -> fenced diagnostics code block formatted for prompts
--  - #cursor-diagnostic-fix -> cursor location + diagnostics at cursor + targeted fix request
local M = {}
local util = require("lazyagent.util")
local summary = require("lazyagent.logic.summary")

local severity_names = {}
if vim and vim.diagnostic and vim.diagnostic.severity then
  severity_names[vim.diagnostic.severity.ERROR] = "ERROR"
  severity_names[vim.diagnostic.severity.WARN] = "WARN"
  severity_names[vim.diagnostic.severity.INFO] = "INFO"
  severity_names[vim.diagnostic.severity.HINT] = "HINT"
end

local function get_abs_path(bufnr)
  bufnr = bufnr or 0
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local name = vim.api.nvim_buf_get_name(bufnr) or ""
  if name == "" then return nil end
  return name
end

local function get_rel_to_root_path(bufnr)
  local abs = get_abs_path(bufnr)
  if not abs then return nil end
  local root = util.git_root_for_path(abs)
  if root and #root > 0 and abs:sub(1, #root) == root then
    local rel = abs:sub(#root + 2) -- remove trailing slash
    if rel and rel ~= "" then return rel end
  end
  return vim.fn.fnamemodify(abs, ":.")
end

-- If the buffer is a scratchpad, use the alternate buffer instead.
local function get_target_bufnr(bufnr)
  local target_bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(target_bufnr) then
    -- If this buffer is a lazyagent scratch, prefer an explicit source buffer mapping
    -- set on the scratch buffer as vim.b[bufnr].lazyagent_source_bufnr.
    local src = vim.b[target_bufnr] and vim.b[target_bufnr].lazyagent_source_bufnr
    if src and src > 0 and vim.api.nvim_buf_is_valid(src) then
      return src
    end

    local buftype = vim.api.nvim_get_option_value("buftype", { buf = target_bufnr })
    if buftype == "nofile" then
      local alt_buf = vim.fn.bufnr("#")
      if alt_buf > 0 and alt_buf ~= target_bufnr and vim.api.nvim_buf_is_valid(alt_buf) then
        target_bufnr = alt_buf
      end
    end
  end
  return target_bufnr
end

local function raw_diagnostics(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.diagnostic or not vim.diagnostic.get then return {} end
  return vim.diagnostic.get(bufnr) or {}
end

local function normalize_diagnostic(d, fallback_bufnr)
  local resolved_bufnr = d.bufnr or fallback_bufnr
  local fn = (resolved_bufnr and vim.api.nvim_buf_is_valid(resolved_bufnr)) and vim.api.nvim_buf_get_name(resolved_bufnr)
    or vim.api.nvim_buf_get_name(fallback_bufnr)
  local ln = (d.lnum and (d.lnum + 1)) or 0
  local col = (d.col and (d.col + 1)) or 0
  local sev = "?"
  if d.severity and severity_names[d.severity] then sev = severity_names[d.severity] else sev = tostring(d.severity or "?") end
  return {
    bufnr = resolved_bufnr or fallback_bufnr,
    filename = fn or "",
    lnum = ln,
    col = col,
    severity = sev,
    message = d.message or "",
    end_lnum = d.end_lnum and (d.end_lnum + 1) or nil,
    end_col = d.end_col and (d.end_col + 1) or nil,
  }
end

local function gather_diagnostics(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local diags = raw_diagnostics(bufnr)
  local out = {}
  for _, d in ipairs(diags) do
    table.insert(out, normalize_diagnostic(d, bufnr))
  end
  return out
end

local function cursor_position(bufnr)
  local target_bufnr = get_target_bufnr(bufnr)
  local path = get_rel_to_root_path(target_bufnr) or get_abs_path(target_bufnr) or ""
  local winid = vim.fn.bufwinid(target_bufnr)
  if winid ~= -1 then
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return {
      bufnr = target_bufnr,
      path = path,
      line = cursor[1],
      col = cursor[2] + 1,
      col0 = cursor[2],
    }
  end
  local mark = vim.api.nvim_buf_get_mark(target_bufnr, '"')
  if mark and mark[1] > 0 then
    return {
      bufnr = target_bufnr,
      path = path,
      line = mark[1],
      col = mark[2] + 1,
      col0 = mark[2],
    }
  end
  return {
    bufnr = target_bufnr,
    path = path,
  }
end

local function cursor_text(bufnr)
  local pos = cursor_position(bufnr)
  local path = pos.path or ""
  if pos.line and pos.col then
    return string.format("@%s:%d:%d", path, pos.line, pos.col)
  end
  return "@" .. path
end

local function diagnostic_contains_cursor(diagnostic, pos)
  if type(diagnostic) ~= "table" or type(pos) ~= "table" or not pos.line or pos.col0 == nil then
    return false
  end

  local line0 = pos.line - 1
  local col0 = pos.col0
  local start_line = diagnostic.lnum or 0
  local end_line = diagnostic.end_lnum or start_line
  if line0 < start_line or line0 > end_line then
    return false
  end

  local start_col = diagnostic.col or 0
  local end_col = diagnostic.end_col
  if line0 == start_line and line0 == end_line then
    if end_col == nil then
      return col0 >= start_col
    end
    return col0 >= start_col and col0 <= math.max(start_col, end_col)
  end
  if line0 == start_line then
    return col0 >= start_col
  end
  if line0 == end_line and end_col ~= nil then
    return col0 <= math.max(0, end_col)
  end
  return true
end

local function gather_cursor_diagnostics(bufnr)
  local pos = cursor_position(bufnr)
  if not pos.bufnr or not pos.line or pos.col0 == nil then
    return {}
  end

  local out = {}
  for _, diagnostic in ipairs(raw_diagnostics(pos.bufnr)) do
    if diagnostic_contains_cursor(diagnostic, pos) then
      table.insert(out, normalize_diagnostic(diagnostic, pos.bufnr))
    end
  end
  return out
end

local function cursor_diagnostic_fix_text(bufnr)
  local pos = cursor_position(bufnr)
  local lines = { cursor_text(pos.bufnr) }
  local diags = gather_cursor_diagnostics(pos.bufnr)
  if #diags > 0 then
    lines[#lines + 1] = "```diagnostics"
    lines[#lines + 1] = diagnostics_to_text(diags)
    lines[#lines + 1] = "```"
    lines[#lines + 1] = "- Fix the diagnostics at the cursor position with a minimal, targeted change. Avoid unrelated refactors."
  else
    lines[#lines + 1] = "- No diagnostics were found at the cursor position."
    lines[#lines + 1] = "- If you change anything, keep it minimal and scoped to the cursor context."
  end
  return table.concat(lines, "\n")
end

local function diagnostics_to_text(diags)
  if not diags or #diags == 0 then return "" end
  local lines = {}
  for _, d in ipairs(diags) do
    local filename = d.filename or ""
    local ln = d.lnum or 0
    local col = d.col or 0
    local sev = d.severity or "?"
    local msg = d.message or ""
    table.insert(lines, string.format("- %s %s:%d:%d %s", sev, filename, ln, col, msg))
  end
  return table.concat(lines, "\n")
end

local function list_buffers_text(opts)
  opts = opts or {}
  local parts = {}
  local include_unlisted = opts.include_unlisted or false
  local absolute = opts.absolute or false

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      -- Mimic bufferline defaults: include "listed" buffers only unless explicitly asked.
      if include_unlisted or vim.api.nvim_get_option_value("buflisted", { buf = b }) then
        local name = vim.api.nvim_buf_get_name(b) or ""
        if name ~= "" then
          local path = absolute and (get_abs_path(b) or name) or (get_rel_to_root_path(b) or name)
          table.insert(parts, "@" .. path)
        end
      end
    end
  end
  return table.concat(parts, "\n")
end

-- External transforms: allow third-party files (transforms-*.lua) or runtime
-- registration to provide additional token transforms.
local external_transforms = {}

local function register_external_transform(t)
  if not t or type(t) ~= "table" then
    if vim and vim.notify then pcall(vim.notify, "lazyagent.transforms: invalid transform (not a table)", vim.log.levels.WARN) end
    return nil
  end
  if not t.name or type(t.name) ~= "string" then
    if vim and vim.notify then pcall(vim.notify, "lazyagent.transforms: transform must have a string 'name' field", vim.log.levels.WARN) end
    return nil
  end
  if not t.trans or (type(t.trans) ~= "string" and type(t.trans) ~= "function") then
    if vim and vim.notify then pcall(vim.notify, "lazyagent.transforms: transform 'trans' must be a string or function for " .. t.name, vim.log.levels.WARN) end
    return nil
  end
  external_transforms[t.name] = { desc = t.desc or "", trans = t.trans }
  return external_transforms[t.name]
end

local function replace_token(token, opts, meta)
  opts = opts or {}
  meta = meta or {}
  meta.used_tokens = meta.used_tokens or {}
  meta.used_tokens[token] = (meta.used_tokens[token] or 0) + 1
  local source_bufnr = get_target_bufnr(opts.source_bufnr or opts.origin_bufnr)

  if token == "buffer" then
    local rel = get_rel_to_root_path(source_bufnr) or (get_abs_path(source_bufnr) or "")
    if rel and rel ~= "" then return "@" .. rel end
    return get_abs_path(source_bufnr) or ""
  end

  if token == "buffer_abs" then
    return get_abs_path(source_bufnr) or ""
  end

  if token == "cursor" then
    return cursor_text(source_bufnr)
  end

  if token == "buffers" then
    return list_buffers_text(opts)
  end

  if token == "buffers_abs" then
    local _opts = opts or {}
    _opts = vim.tbl_extend("force", _opts, { absolute = true })
    return list_buffers_text(_opts)
  end

  if token == "directory" then
    local abs = get_abs_path(source_bufnr) or vim.fn.getcwd()
    if not abs or abs == "" then return "" end
    local dir = vim.fn.fnamemodify(abs, ":h")
    if not dir or dir == "" then return "" end
    local root = util.git_root_for_path(abs)
    if root and #root > 0 and dir:sub(1, #root) == root then
      local rel = dir:sub(#root + 2) -- remove trailing slash
      if rel and rel ~= "" then return "@" .. rel end
    end
    return dir
  end

  if token == "git_root" then
    local a = get_abs_path(source_bufnr) or vim.fn.getcwd()
    return util.git_root_for_path(a) or ""
  end

  if token == "git_branch" then
    local a = get_abs_path(source_bufnr) or vim.fn.getcwd()
    return util.git_branch_for_path(a) or ""
  end

  if token == "diagnostics" then
    local diags = gather_diagnostics(source_bufnr)

    if not diags or #diags == 0 then return "" end
    return "```diagnostics\n" .. diagnostics_to_text(diags) .. "\n```"
  end

  if token == "cursor-diagnostic-fix" then
    return cursor_diagnostic_fix_text(source_bufnr)
  end

  if token == "selection" then
    local ok1, mark_s = pcall(vim.api.nvim_buf_get_mark, source_bufnr, "<")
    local ok2, mark_e = pcall(vim.api.nvim_buf_get_mark, source_bufnr, ">")
    if not ok1 or not ok2 or not mark_s or not mark_e then return "" end
    local sl, el = mark_s[1], mark_e[1]
    if sl == 0 and el == 0 then return "" end
    local lines = vim.api.nvim_buf_get_lines(source_bufnr, sl - 1, el, false)
    if not lines or #lines == 0 then return "" end
    if #lines == 1 then
      lines[1] = lines[1]:sub(mark_s[2] + 1, mark_e[2] + 1)
    else
      lines[1] = lines[1]:sub(mark_s[2] + 1)
      lines[#lines] = lines[#lines]:sub(1, mark_e[2] + 1)
    end
    local ft = vim.bo[source_bufnr] and vim.bo[source_bufnr].filetype or ""
    return "```" .. ft .. "\n" .. table.concat(lines, "\n") .. "\n```"
  end

  if token == "git_diff" or token == "git_staged" then
    local a = get_abs_path(source_bufnr) or vim.fn.getcwd()
    local root = util.git_root_for_path(a) or vim.fn.getcwd()
    local cmd = "git -C " .. vim.fn.shellescape(root)
      .. (token == "git_staged" and " diff --staged" or " diff HEAD")
    local result = vim.fn.systemlist(cmd)
    if not result or #result == 0 then return "" end
    return "```diff\n" .. table.concat(result, "\n") .. "\n```"
  end

  if token == "quickfix" then
    local qflist = vim.fn.getqflist()
    if not qflist or #qflist == 0 then return "" end
    local lines = {}
    for _, item in ipairs(qflist) do
      local fname = (item.bufnr and item.bufnr > 0) and vim.api.nvim_buf_get_name(item.bufnr) or (item.filename or "")
      table.insert(lines, string.format("%s:%d:%d: %s", fname, item.lnum or 0, item.col or 0, item.text or ""))
    end
    return "```quickfix\n" .. table.concat(lines, "\n") .. "\n```"
  end

  if token == "lsp_hover" then
    local winid = vim.fn.bufwinid(source_bufnr)
    if winid == -1 then return "" end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(source_bufnr) },
      position = { line = cursor[1] - 1, character = cursor[2] },
    }
    local ok, results = pcall(vim.lsp.buf_request_sync, source_bufnr, "textDocument/hover", params, 2000)
    if not ok or not results then return "" end
    for _, res in pairs(results) do
      if res.result and res.result.contents then
        local c = res.result.contents
        local val = (type(c) == "table" and c.value) or (type(c) == "string" and c) or nil
        if val and val ~= "" then return "```\n" .. val .. "\n```" end
      end
    end
    return ""
  end

  if token == "symbol" then
    local winid = vim.fn.bufwinid(source_bufnr)
    if winid == -1 then return "" end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    -- Try treesitter: walk up to the nearest function/class node
    local ok, result = pcall(function()
      local node = vim.treesitter.get_node({ bufnr = source_bufnr, pos = { cursor[1] - 1, cursor[2] } })
      if not node then return nil end
      local function_types = {
        "function_declaration", "function_definition", "method_definition",
        "method_declaration", "class_declaration", "class_definition",
        "arrow_function", "function_expression", "local_function",
        "decorated_definition", "impl_item", "function_item",
      }
      local cur = node
      while cur do
        local ntype = cur:type()
        for _, ft in ipairs(function_types) do
          if ntype == ft then
            local sr, _, er, _ = cur:range()
            local lines = vim.api.nvim_buf_get_lines(source_bufnr, sr, er + 1, false)
            local filetype = vim.bo[source_bufnr] and vim.bo[source_bufnr].filetype or ""
            return "```" .. filetype .. "\n" .. table.concat(lines, "\n") .. "\n```"
          end
        end
        cur = cur:parent()
      end
      return nil
    end)
    if ok and result then return result end
    return ""
  end

  -- #history: @-reference to the latest conversation log for the current project+branch.
  if token == "history" then
    local ok_cache, cache_logic = pcall(require, "lazyagent.logic.cache")
    if not ok_cache then return "" end
    if type(cache_logic.list_conversation_files) ~= "function" then return "" end
    local entries = cache_logic.list_conversation_files()
    if not entries or #entries == 0 then return "" end
    local prefix = cache_logic.build_cache_prefix(source_bufnr)
    -- Find the most recent file matching this project+branch prefix
    for _, entry in ipairs(entries) do
      local name = entry.name or ""
      if name:lower():sub(1, #prefix) == prefix:lower() then
        return "@" .. (entry.path or name)
      end
    end
    return ""
  end

  if token == "lazyagent-rule" then
    local src = debug.getinfo(1, "S").source:sub(2)
    local dir = src:match("^(.+/lazyagent)/")
    if dir then
      local path = dir .. "/default_instructions.md"
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        return vim.trim(content)
      end
    end
    return ""
  end

  if token == "report" then
    local dir = summary.summary_dir()
    local prefix = summary.summary_prefix(source_bufnr)
    local example = summary.example_summary_path(source_bufnr)
    meta.summary_dir = dir
    meta.summary_prefix = prefix
    local instructions = "- Summarize in Markdown file.\n"
      .. "- Choose a concise, hyphenated slug for this task (e.g., feature-x or bug-123).\n"
      .. "- Write (create if missing) the summary to: "
      .. prefix .. "<slug>.md\n"
      .. "- Example path: " .. example .. "\n"
      .. "- Preserve existing content and append a new section with a timestamp and latest notes.\n"
      .. "- Include paths or commands worth revisiting."
    return instructions
  end

  -- Allow externally registered transforms to handle custom tokens (either string or function).
  local ext = external_transforms[token]
  if ext then
    if type(ext.trans) == "function" then
      local ok, val = pcall(ext.trans, opts, meta, token)
      if not ok then return "" end
      if type(val) == "string" then
        local ok2, expanded = pcall(function() return M.expand(val, opts) end)
        if ok2 and expanded then return expanded end
        return val
      end
      return tostring(val or "")
    elseif type(ext.trans) == "string" then
      local ok, expanded = pcall(function() return M.expand(ext.trans, opts) end)
      if ok then return expanded end
      return ext.trans
    end
  end

  -- Unknown token: preserve original form to avoid surprising replacements.
  return "#" .. token
end

function M.expand(text, opts)
  opts = opts or {}
  local meta = {}
  if not text then return "", meta end

  -- First, expand tokens matching pattern #token
  local ok, expanded = pcall(function()
    return tostring(text):gsub("#([%w_%-]+)", function(tok)
      local ok_token, value = pcall(replace_token, tok, opts, meta)
      if not ok_token then
        meta.errors = meta.errors or {}
        table.insert(meta.errors, { token = tok, error = tostring(value) })
        return "#" .. tok
      end
      return value or ""
    end)
  end)
  if not ok then expanded = tostring(text) end

  return expanded, meta
end

-- Token definitions used by completion/preview providers
local token_definitions = {
  { name = "buffer", desc = "Path to the source buffer (relative to git root if available), prefixed with '@'." },
  { name = "buffer_abs", desc = "Absolute path of the source buffer." },
  { name = "buffers", desc = "Newline-separated list of listed buffers with @ prefix (relative paths by default)." },
  { name = "buffers_abs", desc = "Newline-separated list of listed buffers with @ prefix (absolute paths)." },
  { name = "cursor", desc = "Path to the source buffer, prefixed with '@' and including line and column (e.g., @path:line:col)." },
  {
    name = "cursor-diagnostic-fix",
    desc = "Cursor location plus diagnostics at the cursor position, followed by a minimal targeted-fix request.",
    available = function(opts)
      return #gather_cursor_diagnostics(get_target_bufnr(opts and opts.source_bufnr or opts and opts.origin_bufnr)) > 0
    end,
  },
  { name = "directory", desc = "Directory of the source buffer (relative to git root if available), prefixed with '@'." },
  { name = "git_root", desc = "Repository root path for the source buffer (git)." },
  { name = "git_branch", desc = "Git branch name for the source buffer." },
  { name = "diagnostics", desc = "Fenced diagnostics code block formatted for prompts (````diagnostics````)." },
  { name = "selection", desc = "Last visual selection from the source buffer as a fenced code block." },
  { name = "git_diff", desc = "Output of `git diff HEAD` for the source buffer's repository as a fenced diff block." },
  { name = "git_staged", desc = "Output of `git diff --staged` for the source buffer's repository as a fenced diff block." },
  { name = "quickfix", desc = "Current quickfix list entries as a fenced quickfix block." },
  { name = "lsp_hover", desc = "LSP hover information at the cursor position in the source buffer." },
  { name = "symbol", desc = "Nearest enclosing function/class node (via treesitter) at the cursor position." },
  { name = "report", desc = "Instructions for creating or updating a Markdown summary/report file using the project's summary directory and filename prefix." },
  { name = "history", desc = "@ reference to the latest conversation log file for the current project+branch." },
  { name = "lazyagent-rule", desc = "Inject the lazyagent default instructions (default_instructions.md)." },
}

-- Public helpers to register external transforms at runtime.
function M.register_transform(t)
  return register_external_transform(t)
end

function M.register_transforms(list)
  if not list or type(list) ~= "table" then return nil end
  for _, tr in ipairs(list) do
    register_external_transform(tr)
  end
end

-- Public helper to gather diagnostics for a buffer.
-- Use this instead of depending on transforms' return `meta` object.
function M.gather_diagnostics(bufnr)
  return gather_diagnostics(bufnr)
end

function M.gather_cursor_diagnostics(bufnr)
  return gather_cursor_diagnostics(bufnr)
end

local function token_is_available(definition, opts)
  if type(definition) ~= "table" or type(definition.available) ~= "function" then
    return true
  end
  local ok, available = pcall(definition.available, opts or {})
  return ok and available ~= false
end

-- Find potential transform files on runtime path (eg. transforms-source.lua), and project-root lazygit.lua
-- This will look for transforms-*.lua on runtimepath and also include lazily-defined
-- `lazygit.lua` files located at repository roots discovered by `util.git_root_for_path`.
local function find_external_transform_files()
  local files = vim.api.nvim_get_runtime_file("lua/**/lazyagent/transforms/*.lua", true) or {}

  -- Deduplicate results
  local seen = {}
  for _, p in ipairs(files) do seen[p] = true end

  -- Collect git roots (current buf, cwd, and all buffer filepaths)
  local roots = {}
  local function try_add_root_from_path(path)
    if not path or path == "" then return end
    local root = util.git_root_for_path(path)
    if root and root ~= "" then roots[root] = true end
  end

  -- Current buffer and cwd
  try_add_root_from_path(vim.api.nvim_buf_get_name(0))
  try_add_root_from_path(vim.fn.getcwd())

  -- All valid buffers
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local name = vim.api.nvim_buf_get_name(b) or ""
      if name ~= "" then try_add_root_from_path(name) end
    end
  end

  -- Check for lazygit.lua under each root
  for root, _ in pairs(roots) do
    if root and root ~= "" then
      local candidate = root .. "/lazygit.lua"
      -- vim.fn.filereadable returns 1 if file is readable
      if vim.fn.filereadable(candidate) == 1 and not seen[candidate] then
        table.insert(files, candidate)
        seen[candidate] = true
      end
    end
  end

  return files
end

-- Safely load and register any transforms exposed by files found on runtime path.
local function try_load_external_transforms()
  local files = find_external_transform_files()
  if not files or #files == 0 then return end
  for _, f in ipairs(files) do
    local ok, res = pcall(function() return dofile(f) end)
    if not ok then
      if vim and vim.notify then pcall(vim.notify, "lazyagent.transforms: failed to load " .. f .. ": " .. tostring(res), vim.log.levels.WARN) end
    else
      -- The file may return a single transform {name, desc, trans} or an array of them.
      if type(res) == "table" then
        if res.name and res.trans then
          register_external_transform(res)
        else
          for _, it in ipairs(res) do
            if type(it) == "table" and it.name and it.trans then register_external_transform(it) end
          end
        end
      end
      -- If the file registers transforms itself via M.register_transform, it will be handled
      -- already because the file executed; nothing else to do.
    end
  end
end

function M.available_tokens(opts)
  local tokens = {}
  for _, token in ipairs(token_definitions) do
    if token_is_available(token, opts) then
      table.insert(tokens, { name = token.name, desc = token.desc })
    end
  end
  local external_names = {}
  for name in pairs(external_transforms) do
    table.insert(external_names, name)
  end
  table.sort(external_names)
  for _, name in ipairs(external_names) do
    local t = external_transforms[name]
    if token_is_available(t, opts) then
      table.insert(tokens, { name = name, desc = t.desc or "" })
    end
  end
  return tokens
end

function M.token_description(name)
  for _, t in ipairs(token_definitions) do
    if t.name == name then return t.desc end
  end
  if external_transforms[name] then return external_transforms[name].desc end
  return nil
end

-- Preview a single token (returns expanded string and meta like M.expand does).
-- token: token without braces (e.g. "buffer")
-- opts: same opts passed to M.expand (e.g. { source_bufnr = bufnr })
function M.preview_token(token, opts)
  opts = opts or {}
  local meta = {}
  local ok, val = pcall(function() return replace_token(token, opts, meta) end)
  if not ok then val = "" end
  return val, meta
end

-- Auto-register nvim-cmp source if cmp is present in the environment.
-- The implementation of the cmp source is located in:
-- lua/lazyagent/cmp/transforms/cmp.lua (it registers itself on load).
local function try_register_cmp()
  local ok, _ = pcall(require, "cmp")
  if not ok then return end
  local ok2, src = pcall(require, "lazyagent.cmp.transforms.cmp")
  if ok2 and src and type(src.register) == "function" then
    -- The source module exposes .register as a convenience; call it safely.
    pcall(src.register)
  end
end

pcall(try_register_cmp)

-- Discover any runtime-provided transforms (files named transforms-*.lua)
pcall(try_load_external_transforms)

return M
