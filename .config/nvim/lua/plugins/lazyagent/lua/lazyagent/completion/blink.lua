-- blink.cmp source for lazyagent token completions.
-- Exposes a blink.cmp source module that returns token suggestions like:
--   #buffer, #buffer_abs, #buffers, #buffers_abs, #git_root, #git_branch, #diagnostics
-- The source uses lazyagent.transforms for previews/documentation.
--
-- Usage (blink.cmp config):
-- sources.providers = {
--   lazyagent = {
--     name = "[S]",
--     module = "lazyagent.blink.transforms"
--   }
-- }
local ok_transforms, transforms = pcall(require, "lazyagent.transforms")
local ok_agent, agent_logic = pcall(require, "lazyagent.logic.agent")
local ok_state, state = pcall(require, "lazyagent.logic.state")
if not ok_transforms then
  -- If lazyagent transforms cannot be loaded, provide a noop source that returns no items.
  local noop = {}
  function noop.new(_) return setmetatable({}, { __index = noop }) end
  function noop:enabled() return false end
  function noop:get_trigger_characters() return { "#" } end
  function noop:get_completions(_, cb) cb({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false }) end
  return noop
end

-- blink.cmp types (optional dependency)
local ok_types, types = pcall(require, "blink.cmp.types")
if not ok_types then
  -- Fallback minimal types if blink.cmp isn't available.
  types = { CompletionItemKind = { Text = 1 } }
end

local source = {}
source.__index = source

-- New instance constructor
function source.new(opts)
  opts = opts or {}
  local self = setmetatable({}, source)
  self.opts = opts
  return self
end

-- Enable source only in contexts where lazyagent makes sense:
-- - scratch buffers with a persisted origin bufnr (vim.b[buf].lazyagent_source_bufnr)
-- - or common textlike filetypes like markdown/text
function source:enabled(ctx)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end

  if vim.b[bufnr] and (vim.b[bufnr].lazyagent_source_bufnr or vim.b[bufnr].lazyagent_agent) then return true end
  local ft = vim.bo[bufnr].filetype or ""
  if ft == "markdown" or ft == "text" or ft == "lazyagent" then return true end
  return false
end

-- Trigger characters: start token with '{'
function source:get_trigger_characters()
  return { "#", "/", "@", "{" }
end

function source:get_keyword_pattern()
  return "[#/@][A-Za-z0-9_%.%-/]*"
end

local function make_item(tok, _, bufnr)
  local label = "#" .. tok.name
  local insert_text = label .. " "

  -- Resolve preview/documentation using transforms.preview_token with best-effort source bufnr
  local opts = { source_bufnr = bufnr }
  local ok, preview = pcall(function() return transforms.preview_token(tok.name, opts) end)
  local doc_value = ""
  if ok and preview and preview ~= "" then
    -- transforms.preview_token may return a fenced block already, use as-is.
    if preview:match("^```") then
      doc_value = preview
    else
      doc_value = "```text\n" .. preview .. "\n```"
    end
  else
    doc_value = tok.desc or ""
  end

  local item = {
    label = label,
    -- Let blink.cmp fuzzy caret match on the value inside braces; including braces may be fine,
    -- but filterText without braces helps matching 'buffers' with keyword 'buf'.
    filterText = tok.name,
    insertText = insert_text,
    kind = types.CompletionItemKind.Text,
    documentation = { kind = "markdown", value = doc_value },
    detail = tok.desc or "",
  }

  return item
end

local function make_custom_item(prefix_char, text, desc)
  local label = text:match("^" .. vim.pesc(prefix_char)) and text or (prefix_char .. text)
  return {
    label = label,
    filterText = label:gsub("^" .. vim.pesc(prefix_char), ""),
    insertText = label .. " ",
    kind = types.CompletionItemKind.Text,
    documentation = { kind = "markdown", value = desc or "" },
  }
end

local function current_agent(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr] and vim.b[bufnr].lazyagent_agent then
    return vim.b[bufnr].lazyagent_agent
  end
  if ok_state and state and state.open_agent then return state.open_agent end
  return nil
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

-- Return completions: blink.cmp will do keyword filtering; we return all tokens.
function source:get_completions(ctx, callback)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()

  local function line_before_cursor()
    if ctx and ctx.line and ctx.col then
      return ctx.line:sub(1, math.max(0, ctx.col - 1))
    end
    local ok_cur, pos = pcall(vim.api.nvim_win_get_cursor, 0)
    local ok_line, line = pcall(vim.api.nvim_get_current_line)
    if ok_cur and ok_line and pos and line then
      local col = pos[2] or 0
      return line:sub(1, col)
    end
    return ""
  end

  local line_to_cursor = line_before_cursor()
  local token_prefix = line_to_cursor:match("{([%w_%-%./]*)$") or line_to_cursor:match("#([%w_%-%./]*)$") or nil
  local slash_prefix = line_to_cursor:match("/([%w_%-%./]*)$") or nil
  local at_prefix = line_to_cursor:match("@([%w_%-%./]*)$") or nil

  -- If the last character is a trigger but prefix detection failed, treat as empty prefix to force suggestions.
  local last_char = line_to_cursor:sub(-1)
  if not token_prefix and not slash_prefix and not at_prefix then
    if last_char == "#" or last_char == "{" then token_prefix = "" end
    if last_char == "/" then slash_prefix = "" end
    if last_char == "@" then at_prefix = "" end
  end

  if not token_prefix and not slash_prefix and not at_prefix then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  -- Prefer a persisted origin/source if this is a scratch buffer
  local source_buf = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr] and vim.b[bufnr].lazyagent_source_bufnr then
    local candidate = vim.b[bufnr].lazyagent_source_bufnr
    if vim.api.nvim_buf_is_valid(candidate) then source_buf = candidate end
  end
  source_buf = source_buf or bufnr

  local tokens = transforms.available_tokens() or {}
  local items = {}
  if token_prefix then
    for _, tok in ipairs(tokens) do
      if tok.name:sub(1, #token_prefix) == token_prefix then
        table.insert(items, make_item(tok, ctx, source_buf))
      end
    end
  end

  local agent = ok_agent and current_agent(bufnr) or nil
  if agent and ok_agent then
    local comps = agent_logic.get_scratch_completions(agent)
    if slash_prefix then
      for _, v in ipairs(comps.slash or {}) do
        local label, desc = parse_entry(v, "/")
        if label then
          local key = label:gsub("^/", "")
          if key:sub(1, #slash_prefix) == slash_prefix then
            table.insert(items, make_custom_item("/", label, desc or ("LazyAgent / command for " .. agent)))
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
            table.insert(items, make_custom_item("@", label, desc or ("LazyAgent @ item for " .. agent)))
          end
        end
      end
    end
  end

  -- Return items and indicate not-requesting incremental updates by default.
  callback({
    items = items,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })

  -- No long-running operation so simply return a no-op cancel function.
  return function() end
end

-- Optional: resolve can be used to lazily attach documentation before the doc popup
function source:resolve(item, callback)
  callback(item)
end

-- Optional: handle execution after accept; default behavior is fine.
function source:execute(_, _, callback, default_implementation)
  default_implementation()
  callback()
end

return source
