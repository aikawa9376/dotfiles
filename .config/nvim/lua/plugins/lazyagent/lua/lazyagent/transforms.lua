-- Transformation utilities for lazyagent: token expansion, git context, and diagnostics.
-- Provides M.expand(text, opts) which replaces tokens in `text` with contextual values.
-- Known tokens:
--  - {buffer}      -> "@<path>" (path relative to git root or cwd)
--  - {buffer_abs}  -> absolute path of the source buffer
--  - {buffers}     -> newline-separated list of "bufferline"-equivalent buffers (listed buffers) with "@" prefix
--  - {buffers_abs} -> newline-separated list of bufferline-equivalent buffers, absolute paths with "@" prefix
--  - {git_root}    -> repository root path for the source buffer (git)
--  - {git_branch}  -> git branch name for the source buffer
--  - {diagnostics} -> fenced diagnostics code block formatted for prompts
local M = {}
local util = require("lazyagent.util")

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

local function gather_diagnostics(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.diagnostic or not vim.diagnostic.get then return {} end
  local diags = vim.diagnostic.get(bufnr) or {}
  local out = {}
  for _, d in ipairs(diags) do
    local fn = (d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr)) and vim.api.nvim_buf_get_name(d.bufnr) or vim.api.nvim_buf_get_name(bufnr)
    local ln = (d.lnum and (d.lnum + 1)) or 0
    local col = (d.col and (d.col + 1)) or 0
    local sev = "?"
    if d.severity and severity_names[d.severity] then sev = severity_names[d.severity] else sev = tostring(d.severity or "?") end
    table.insert(out, { bufnr = d.bufnr or bufnr, filename = fn or "", lnum = ln, col = col, severity = sev, message = d.message or "" })
  end
  return out
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

local function replace_token(token, opts, meta)
  opts = opts or {}
  meta = meta or {}
  local source_bufnr = get_target_bufnr(opts.source_bufnr or opts.origin_bufnr)

  if token == "buffer" then
    local rel = get_rel_to_root_path(source_bufnr) or (get_abs_path(source_bufnr) or "")
    if rel and rel ~= "" then return "@" .. rel end
    return get_abs_path(source_bufnr) or ""
  end

  if token == "buffer_abs" then
    return get_abs_path(source_bufnr) or ""
  end

  if token == "buffers" then
    return list_buffers_text(opts)
  end

  if token == "buffers_abs" then
    local _opts = opts or {}
    _opts = vim.tbl_extend("force", _opts, { absolute = true })
    return list_buffers_text(_opts)
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
    meta.diagnostics = diags
    if not diags or #diags == 0 then return "" end
    return "```diagnostics\n" .. diagnostics_to_text(diags) .. "\n```"
  end

  -- Unknown token: preserve original form to avoid surprising replacements.
  return "{" .. token .. "}"
end

function M.expand(text, opts)
  opts = opts or {}
  local meta = {}
  if not text then return "", meta end
  local ok, expanded = pcall(function()
    return tostring(text):gsub("{(.-)}", function(tok)
      return replace_token(tok, opts, meta)
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
  { name = "git_root", desc = "Repository root path for the source buffer (git)." },
  { name = "git_branch", desc = "Git branch name for the source buffer." },
  { name = "diagnostics", desc = "Fenced diagnostics code block formatted for prompts (````diagnostics````)." },
}

-- Return a copy of the available tokens so callers can't mutate the original list.
function M.available_tokens()
  return vim.deepcopy(token_definitions)
end

function M.token_description(name)
  for _, t in ipairs(token_definitions) do
    if t.name == name then return t.desc end
  end
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

return M
