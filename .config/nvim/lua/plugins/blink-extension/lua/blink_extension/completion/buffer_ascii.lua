local task = require("blink.lib.task")
local parser = require("blink.cmp.sources.buffer.parser")
local buf_utils = require("blink.cmp.sources.buffer.utils")
local cmdline_utils = require("blink.cmp.sources.cmdline.utils")
local lib = require("blink.lib")
local completion_utils = require("blink_extension.completion.utils")

local function filter_ascii_words(words)
  return vim.tbl_filter(function(word)
    return completion_utils.is_ascii(word)
  end, words)
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

local buffer = {}

function buffer.new(opts)
  local self = setmetatable({}, { __index = buffer })

  opts = vim.tbl_deep_extend("keep", opts or {}, {
    get_bufnrs = function()
      return vim
        .iter(vim.api.nvim_list_wins())
        :map(function(win)
          return vim.api.nvim_win_get_buf(win)
        end)
        :filter(function(bufnr)
          return vim.bo[bufnr].buftype ~= "nofile"
        end)
        :totable()
    end,
    get_search_bufnrs = function()
      return { vim.api.nvim_get_current_buf() }
    end,
    max_sync_buffer_size = 20000,
    max_async_buffer_size = 200000,
    max_total_buffer_size = 500000,
    retention_order = { "focused", "visible", "recency", "largest" },
    use_cache = true,
    enable_in_ex_commands = false,
  })

  if vim.tbl_contains(opts.retention_order, "recency") then
    require("blink.cmp.sources.buffer.recency").start_tracking()
  end

  if opts.enable_in_ex_commands then
    vim.on_key(function()
      if cmdline_utils.is_command_line({ ":" }) and vim.o.inccommand ~= "" then
        vim.o.inccommand = ""
      end
    end)
  end

  if opts.use_cache then
    self.cache = require("blink.cmp.sources.buffer.cache").new()
  end

  self.opts = opts
  return self
end

function buffer:is_search_context()
  if cmdline_utils.is_command_line({ "/", "?" }) then
    return true
  end

  if self.opts.enable_in_ex_commands and cmdline_utils.in_ex_search_commands() then
    return true
  end

  return false
end

function buffer:get_buf_items(bufnr, exclude_word_under_cursor)
  local changedtick

  if self.opts.use_cache then
    changedtick = vim.b[bufnr].changedtick
    local cache = self.cache:get(bufnr)

    if cache
      and cache.changedtick == changedtick
      and cache.exclude_word_under_cursor == exclude_word_under_cursor
    then
      return task.resolve(cache.words)
    end
  end

  local function store_in_cache(words)
    local filtered_words = filter_ascii_words(words)

    if self.opts.use_cache then
      self.cache:set(bufnr, {
        changedtick = changedtick,
        exclude_word_under_cursor = exclude_word_under_cursor,
        words = filtered_words,
      })
    end

    return filtered_words
  end

  return parser.get_buf_words(bufnr, exclude_word_under_cursor, self.opts):map(store_in_cache)
end

function buffer:enabled()
  return not cmdline_utils.is_command_line() or self:is_search_context()
end

function buffer:get_completions(_, callback)
  local is_search = self:is_search_context()
  local get_bufnrs = is_search and self.opts.get_search_bufnrs or self.opts.get_bufnrs
  local bufnrs = lib.list.dedup(get_bufnrs())

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
    return self:get_buf_items(bufnr, not is_search)
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

return buffer
