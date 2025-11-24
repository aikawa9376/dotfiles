-- nvim-cmp source for lazyagent token completions.
-- Provides completion items for tokens like {buffer}, {buffers}, {git_root}, etc.
-- The source triggers on '{' and uses lazyagent.transforms for previews.
local ok_cmp, cmp = pcall(require, "cmp")
if not ok_cmp or not cmp then
  -- If cmp is not available, returning an empty table (no-op) is harmless.
  return {}
end

local transforms = require("lazyagent.transforms")

local source = {}

-- 'new' creates a per-instance source (not strictly required here but keeps patterns consistent).
function source.new()
  return setmetatable({}, { __index = source })
end

-- Show token completions only when a token-like prefix is being typed:
-- Trigger when '{' is typed.
function source.get_trigger_characters()
  return { "{" }
end

-- Determine if the source should be available in the current buffer.
-- Prefer scratch detection (vim.b[bufnr].lazyagent_source_bufnr) or markdown/text filetypes.
-- If you prefer the source to always be available, change to `return true`.
function source.is_available(self)
  local bufnr = vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.b[bufnr] and vim.b[bufnr].lazyagent_source_bufnr then return true end
  local ft = vim.bo[bufnr].filetype or ""
  if ft == "markdown" or ft == "text" then return true end
  return false
end

-- Create a single completion item for token.
local function make_item(tok, params)
  local label = "{" .. tok.name .. "}"
  local insert_text = label

  local preview, meta = transforms.preview_token(tok.name, { source_bufnr = vim.api.nvim_get_current_buf() })
  local doc_value = ""
  if preview and preview ~= "" then
    -- If the preview already contains code-fenced diagnostics or blocks, use as-is.
    -- Otherwise present a simple markdown fenced block for readability.
    if preview:match("^```") then
      doc_value = preview
    else
      doc_value = "```text\n" .. preview .. "\n```"
    end
  else
    doc_value = tok.desc or ""
  end

  local kind = (cmp.lsp and cmp.lsp.CompletionItemKind and cmp.lsp.CompletionItemKind.Text) or 1

  local item = {
    label = label,
    insertText = insert_text,
    kind = kind,
    documentation = { kind = "markdown", value = doc_value },
    detail = tok.desc or "",
    data = { token = tok.name },
  }
  return item
end

-- Complete calls: called by cmp when completion is needed.
-- params contains cursor_before_line from which we can extract the token prefix.
function source.complete(self, params, callback)
  local cursor_before = (params.context and params.context.cursor_before_line) or ""
  local prefix = cursor_before:match("{([%w_]*)$") or ""
  if prefix == nil then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local tokens = transforms.available_tokens() or {}
  local items = {}
  for _, tok in ipairs(tokens) do
    -- match tokens starting with prefix (case-sensitive)
    if tok.name:sub(1, #prefix) == prefix then
      table.insert(items, make_item(tok, params))
    end
  end

  callback({ items = items, isIncomplete = false })
end

-- When loaded, register ourselves with cmp under the source name "lazyagent_transforms".
local function register()
  pcall(function()
    cmp.register_source("lazyagent_transforms", source)
  end)
end

-- Expose register function so other code (like transforms.try_register_cmp) can call it safely.
source.register = register

-- Auto-register on load if cmp is present (safe pcall).
register()

return source
