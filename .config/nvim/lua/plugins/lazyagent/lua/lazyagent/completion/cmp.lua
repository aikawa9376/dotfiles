-- nvim-cmp source for lazyagent token completions.
-- Provides completion items for tokens like {buffer}, {buffers}, {git_root}, etc.
-- The source triggers on '{' and uses lazyagent.transforms for previews.
local ok_cmp, cmp = pcall(require, "cmp")
if not ok_cmp or not cmp then
  -- If cmp is not available, returning an empty table (no-op) is harmless.
  return {}
end

local transforms = require("lazyagent.transforms")
local state = require("lazyagent.logic.state")
local agent_logic = require("lazyagent.logic.agent")

local source = {}

-- 'new' creates a per-instance source (not strictly required here but keeps patterns consistent).
function source.new()
  return setmetatable({}, { __index = source })
end

-- Show token completions only when a token-like prefix is being typed:
-- Trigger when '{' is typed.
function source.get_trigger_characters()
  return { "#", "/", "@", "{" }
end

function source.get_keyword_pattern()
  return "[#/@][A-Za-z0-9_%.%-/]*"
end

-- Determine if the source should be available in the current buffer.
-- Prefer scratch detection (vim.b[bufnr].lazyagent_source_bufnr) or markdown/text filetypes.
-- If you prefer the source to always be available, change to `return true`.
function source.is_available(self)
  local bufnr = vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.b[bufnr] and (vim.b[bufnr].lazyagent_source_bufnr or vim.b[bufnr].lazyagent_agent) then return true end
  local ft = vim.bo[bufnr].filetype or ""
  if ft == "markdown" or ft == "text" or ft == "lazyagent" then return true end
  return false
end

-- Create a single completion item for token.
local function make_item(tok, params)
  local label = "#" .. tok.name
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

local function make_custom_item(prefix_char, text, desc, kind)
  local label = text:match("^" .. vim.pesc(prefix_char)) and text or (prefix_char .. text)
  return {
    label = label,
    insertText = label,
    filterText = label:gsub("^" .. vim.pesc(prefix_char), ""),
    kind = kind,
    documentation = { kind = "markdown", value = desc or "" },
  }
end

local function current_agent()
  local bufnr = vim.api.nvim_get_current_buf()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr] and vim.b[bufnr].lazyagent_agent then
    return vim.b[bufnr].lazyagent_agent
  end
  return state.open_agent
end

local function parse_entry(entry, prefix_char)
  if type(entry) == "string" then
    return entry, nil
  end
  if type(entry) == "table" then
    local label = entry.label or entry.text or entry[1]
    local desc = entry.desc or entry.description or entry[2]
    if label then
      if not label:match("^" .. vim.pesc(prefix_char)) then
        label = prefix_char .. label
      end
      return label, desc
    end
  end
  return nil, nil
end

-- Complete calls: called by cmp when completion is needed.
-- params contains cursor_before_line from which we can extract the token prefix.
function source.complete(self, params, callback)
  local cursor_before = (params.context and params.context.cursor_before_line) or ""
  local token_prefix = cursor_before:match("{([%w_%-%.]*)$") or cursor_before:match("#([%w_%-%.]*)$") or nil
  local slash_prefix = cursor_before:match("/([%w_%-%./]*)$") or nil
  local at_prefix = cursor_before:match("@([%w_%-%./]*)$") or nil

  if not token_prefix and not slash_prefix and not at_prefix then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local tokens = transforms.available_tokens() or {}
  local items = {}
  if token_prefix then
    for _, tok in ipairs(tokens) do
      if tok.name:sub(1, #token_prefix) == token_prefix then
        table.insert(items, make_item(tok, params))
      end
    end
  end

  local agent = current_agent()
  if agent then
    local comps = agent_logic.get_scratch_completions(agent)
    local kind = (cmp.lsp and cmp.lsp.CompletionItemKind and cmp.lsp.CompletionItemKind.Text) or 1

    if slash_prefix then
      for _, v in ipairs(comps.slash or {}) do
        local label, desc = parse_entry(v, "/")
        if label then
          local key = label:gsub("^/", "")
          if key:sub(1, #slash_prefix) == slash_prefix then
            table.insert(items, make_custom_item("/", label, desc or ("LazyAgent / command for " .. agent), kind))
          end
        end
      end
    end

    if at_prefix then
      for _, v in ipairs(comps.at or {}) do
        local label, desc = parse_entry(v, "@")
        if label then
          local key = label:gsub("^@", "")
          if key:sub(1, #at_prefix) == at_prefix then
            table.insert(items, make_custom_item("@", label, desc or ("LazyAgent @ item for " .. agent), kind))
          end
        end
      end
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
