-- Transformation utilities for send-agent: token expansion, git context, and diagnostics.
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
local util = require("send-agent.util")

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
      if include_unlisted or vim.api.nvim_buf_get_option(b, "buflisted") then
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
  local source_bufnr = opts.source_bufnr or opts.origin_bufnr or vim.api.nvim_get_current_buf()

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

return M
