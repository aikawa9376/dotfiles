local task = require("blink.lib.task")
local parser = require("blink.cmp.sources.buffer.parser")
local buf_utils = require("blink.cmp.sources.buffer.utils")
local cmdline_utils = require("blink.cmp.sources.cmdline.utils")
local lib = require("blink.lib")

local function is_ascii(text)
  if type(text) ~= "string" then
    return false
  end

  for i = 1, #text do
    if text:byte(i) > 127 then
      return false
    end
  end

  return true
end

local function filter_ascii_words(words)
  return vim.tbl_filter(function(word)
    return is_ascii(word)
  end, words)
end

local function buffer_var(bufnr, name)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  if ok then
    return value
  end
  return nil
end

local function is_lazyagent_acp_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].filetype == "lazyagent_acp" then
    return true
  end

  if buffer_var(bufnr, "lazyagent_acp_transcript") == true then
    return true
  end

  local name = vim.api.nvim_buf_get_name(bufnr) or ""
  return name:match("^lazyagent://acp/") ~= nil
end

local function visible_acp_bufnrs()
  return vim
    .iter(vim.api.nvim_list_wins())
    :map(function(win)
      return vim.api.nvim_win_get_buf(win)
    end)
    :filter(function(bufnr)
      return is_lazyagent_acp_buffer(bufnr)
    end)
    :totable()
end

local function is_lazyagent_completion_context(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.b[bufnr] and (vim.b[bufnr].lazyagent_is_scratch or vim.b[bufnr].lazyagent_agent) then
    return true
  end

  return vim.bo[bufnr].filetype == "lazyagent"
end

local function words_to_items(words)
  local kind_text = require("blink.cmp.types").CompletionItemKind.Text
  local plain_text = vim.lsp.protocol.InsertTextFormat.PlainText
  local items = {}

  for i = 1, #words do
    items[i] = {
      label = words[i],
      kind = kind_text,
      insertTextFormat = plain_text,
      insertText = words[i],
    }
  end

  return items
end

local source = {}

function source.new(opts)
  local self = setmetatable({}, { __index = source })

  opts = vim.tbl_deep_extend("keep", opts or {}, {
    get_bufnrs = visible_acp_bufnrs,
    max_sync_buffer_size = 20000,
    max_async_buffer_size = 200000,
    max_total_buffer_size = 500000,
    retention_order = { "visible", "recency", "largest" },
    use_cache = true,
  })

  if vim.tbl_contains(opts.retention_order, "recency") then
    require("blink.cmp.sources.buffer.recency").start_tracking()
  end

  if opts.use_cache then
    self.cache = require("blink.cmp.sources.buffer.cache").new()
  end

  self.opts = opts
  return self
end

function source:enabled()
  if cmdline_utils.is_command_line() then
    return false
  end

  if not is_lazyagent_completion_context(vim.api.nvim_get_current_buf()) then
    return false
  end

  return #self.opts.get_bufnrs() > 0
end

function source:get_buf_items(bufnr)
  local changedtick

  if self.opts.use_cache then
    changedtick = vim.b[bufnr].changedtick
    local cache = self.cache:get(bufnr)

    if cache and cache.changedtick == changedtick then
      return task.resolve(cache.words)
    end
  end

  local function store_in_cache(words)
    local filtered_words = filter_ascii_words(words)

    if self.opts.use_cache then
      self.cache:set(bufnr, {
        changedtick = changedtick,
        words = filtered_words,
      })
    end

    return filtered_words
  end

  return parser.get_buf_words(bufnr, false, self.opts):map(store_in_cache)
end

function source:get_completions(_, callback)
  local bufnrs = lib.list.dedup(self.opts.get_bufnrs())

  if #bufnrs == 0 then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  local selected_bufnrs = buf_utils.retain_buffers(
    bufnrs,
    self.opts.max_total_buffer_size,
    self.opts.max_async_buffer_size,
    self.opts.retention_order
  )

  local tasks = vim.tbl_map(function(bufnr)
    return self:get_buf_items(bufnr)
  end, selected_bufnrs)

  task.all(tasks):map(function(words_per_buf)
    local unique = {}
    local words = {}

    for _, buf_words in ipairs(words_per_buf) do
      for _, word in ipairs(buf_words) do
        if not unique[word] then
          unique[word] = true
          table.insert(words, word)
        end
      end
    end

    if self.opts.use_cache then
      self.cache:cleanup(selected_bufnrs)
    end

    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = words_to_items(words),
    })
  end)
end

return source
