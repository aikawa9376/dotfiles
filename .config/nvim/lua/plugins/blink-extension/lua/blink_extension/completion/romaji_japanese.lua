local completion_utils = require("blink_extension.completion.utils")

local source = {}
source.__index = source

local uv = vim.uv or vim.loop
local completion_item_kind_text = 1
local completion_item_kind_loaded = false

local function join_path(base, ...)
  local path = tostring(base or ""):gsub("/+$", "")
  for _, part in ipairs({ ... }) do
    part = tostring(part or ""):gsub("^/+", ""):gsub("/+$", "")
    if part ~= "" then
      path = path .. "/" .. part
    end
  end
  return path
end

local function module_root()
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if src and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  return (src and src:match("(.*/blink%-extension/)lua/blink_extension/completion/romaji_japanese%.lua$")) or ""
end

local function current_platform_tags()
  local uname = uv.os_uname and uv.os_uname() or {}
  local sysname = tostring(uname and uname.sysname or ""):lower()
  local machine = tostring(uname and uname.machine or ""):lower()
  local os_name = "unknown"
  local arch_name = machine ~= "" and machine or "unknown"

  if sysname:find("linux", 1, true) then
    os_name = "linux"
  elseif sysname:find("darwin", 1, true) or sysname:find("mac", 1, true) then
    os_name = "darwin"
  elseif sysname:find("windows", 1, true) then
    os_name = "windows"
  elseif sysname ~= "" then
    os_name = sysname
  end

  if arch_name == "x86_64" or arch_name == "amd64" then
    arch_name = "x64"
  elseif arch_name == "aarch64" then
    arch_name = "arm64"
  end

  local tags = { os_name .. "-" .. arch_name }
  if arch_name == "x64" then
    tags[#tags + 1] = os_name .. "-x86_64"
    tags[#tags + 1] = os_name .. "-amd64"
  elseif arch_name == "arm64" then
    tags[#tags + 1] = os_name .. "-aarch64"
  end

  return tags
end

local function bundled_viterust_paths()
  local root = module_root()
  if root == "" then
    root = join_path(vim.fn.stdpath("config"), "lua/plugins/blink-extension")
  end

  local bin_root = join_path(root, "bin")
  local bin_dir = bin_root
  for _, tag in ipairs(current_platform_tags()) do
    local candidate = join_path(bin_root, tag)
    if vim.fn.isdirectory(candidate) == 1 then
      bin_dir = candidate
      break
    end
  end

  return {
    command = join_path(bin_dir, "viterust"),
    dict = join_path(root, "data/viterust/jawiki-corpus.vtrdict"),
    ngram = join_path(root, "data/viterust/jawiki-3gram.vtrngram"),
  }
end

local function text_completion_kind()
  if completion_item_kind_loaded then
    return completion_item_kind_text
  end

  local ok_types, types = pcall(require, "blink.cmp.types")
  if ok_types and types and types.CompletionItemKind and types.CompletionItemKind.Text then
    completion_item_kind_text = types.CompletionItemKind.Text
  end
  completion_item_kind_loaded = true
  return completion_item_kind_text
end

local function default_opts(opts)
  local bundled = bundled_viterust_paths()
  return vim.tbl_deep_extend("force", {
    min_keyword_length = 2,
    max_items = 20,
    trigger_characters = { ".", ",", "!", "?", "`" },
    viterust = {
      enabled = true,
      command = bundled.command,
      dict = bundled.dict,
      ngram = bundled.ngram,
      top = 20,
      beam = 24,
      fuzzy = 0,
      extra_args = {},
    },
  }, opts or {})
end

local function trim(text)
  return (text or ""):gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
end

local function expand_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

local function readable_path(path)
  local expanded = expand_path(path)
  return expanded ~= "" and vim.fn.filereadable(expanded) == 1, expanded
end

local function executable_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end

  local expanded = vim.fn.expand(path)
  return vim.fn.executable(expanded) == 1 and expanded or ""
end

local function line_to_cursor(ctx)
  local line = type(ctx) == "table" and ctx.line or ""
  local cursor = type(ctx) == "table" and ctx.cursor or nil
  local col = type(cursor) == "table" and cursor[2] or 0

  if type(line) ~= "string" then
    return ""
  end
  if type(col) ~= "number" or col < 0 then
    col = 0
  end

  return line:sub(1, col)
end

local function extract_prefix(ctx)
  local prefix = line_to_cursor(ctx):match("([A-Za-z0-9`][A-Za-z0-9`'%-.,!?]*)$") or ""
  if prefix == "" then
    prefix = line_to_cursor(ctx):match("([.,!?])$") or ""
  end
  if prefix:match("^[.,!?]$") then
    return prefix
  end
  if prefix:find("[A-Z]") or not prefix:find("[a-z]") then
    return ""
  end
  return prefix
end

local function text_before_prefix(ctx, prefix)
  local text = line_to_cursor(ctx)
  if prefix == "" or #text < #prefix or text:sub(#text - #prefix + 1) ~= prefix then
    return text
  end
  return text:sub(1, #text - #prefix)
end

local function is_after_japanese_text(ctx)
  return completion_utils.extract_trailing_japanese(line_to_cursor(ctx)) ~= ""
end

local function is_prefix_after_japanese(ctx, prefix)
  return prefix ~= "" and completion_utils.extract_trailing_japanese(text_before_prefix(ctx, prefix)) ~= ""
end

local function keyword_length(prefix)
  return #(prefix:gsub("[`.,!?]", ""))
end

local function has_symbol_suffix(prefix)
  return prefix:find("[`.,!?]$") ~= nil
end

local function is_single_punctuation(prefix)
  return prefix:match("^[.,!?]$") ~= nil
end

local function has_enough_keyword_length(prefix, min_keyword_length)
  if is_single_punctuation(prefix) then
    return true
  end

  local length = keyword_length(prefix)
  if length >= min_keyword_length then
    return true
  end
  return has_symbol_suffix(prefix) and length >= 1
end

local function response(items, opts)
  opts = opts or {}
  return {
    items = items,
    is_incomplete_forward = opts.is_incomplete_forward ~= false,
    is_incomplete_backward = opts.is_incomplete_backward ~= false,
  }
end

local function item_range(ctx, prefix)
  local cursor = type(ctx) == "table" and ctx.cursor or vim.api.nvim_win_get_cursor(0)
  local row = type(cursor) == "table" and cursor[1] or 1
  local col = type(cursor) == "table" and cursor[2] or 0

  return {
    start = { line = math.max(0, row - 1), character = math.max(0, col - #prefix) },
    ["end"] = { line = math.max(0, row - 1), character = col },
  }
end

local function blink_context_keyword(ctx)
  if type(ctx) ~= "table" or type(ctx.bounds) ~= "table" or type(ctx.line) ~= "string" then
    return ""
  end

  local start_col = tonumber(ctx.bounds.start_col)
  local length = tonumber(ctx.bounds.length)
  if not start_col or not length or start_col < 1 or length <= 0 then
    return ""
  end

  return ctx.line:sub(start_col, start_col + length - 1)
end

local function is_filter_context_char(char)
  if char:match("^[A-Za-z0-9_%-]$") then
    return true
  end
  return completion_utils.is_japanese_cp(completion_utils.codepoint(char))
end

local function trailing_filter_context(text)
  local chars = completion_utils.split_chars(text)
  local trailing = {}

  for i = #chars, 1, -1 do
    if not is_filter_context_char(chars[i]) then
      break
    end
    table.insert(trailing, 1, chars[i])
  end

  return table.concat(trailing)
end

local function item_filter_text(ctx, prefix)
  local keyword_prefix = trailing_filter_context(text_before_prefix(ctx, prefix))
  if keyword_prefix ~= "" then
    local filter_text = keyword_prefix .. prefix
    local keyword = blink_context_keyword(ctx)
    if keyword ~= "" and #keyword >= #filter_text then
      return keyword
    end
    return filter_text
  end

  local japanese_prefix = completion_utils.extract_trailing_japanese(text_before_prefix(ctx, prefix))
  if japanese_prefix == "" then
    return prefix
  end
  return japanese_prefix .. prefix
end

local function item_score_offset(prefix)
  return has_symbol_suffix(prefix) and 20 or 0
end

local function add_item(items, seen, ctx, prefix, label, rank)
  label = trim(label)
  if label == "" or label == prefix or seen[label] then
    return rank
  end

  seen[label] = true
  items[#items + 1] = {
    label = label,
    filterText = item_filter_text(ctx, prefix),
    sortText = ("%04d:%s"):format(rank, label),
    score_offset = item_score_offset(prefix),
    kind = text_completion_kind(),
    kind_name = "text",
    detail = "[viterust]",
    documentation = {
      kind = "markdown",
      value = ("`%s` -> `%s`"):format(prefix, label),
    },
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    textEdit = {
      newText = label,
      range = item_range(ctx, prefix),
    },
  }

  return rank + 1
end

local function viterust_options(opts)
  return type(opts) == "table" and type(opts.viterust) == "table" and opts.viterust or {}
end

local function viterust_available(opts)
  local viterust = viterust_options(opts)
  return viterust.enabled ~= false and executable_path(viterust.command) ~= ""
end

local function append_extra_args(args, extra_args)
  if type(extra_args) ~= "table" then
    return
  end

  for _, arg in ipairs(extra_args) do
    if type(arg) == "string" and arg ~= "" then
      args[#args + 1] = arg
    end
  end
end

local function viterust_args(input, opts, max_items)
  local viterust = viterust_options(opts)
  local command = executable_path(viterust.command)
  max_items = tonumber(max_items) or 20
  local top = tonumber(viterust.top) or max_items
  local beam = tonumber(viterust.beam) or 24
  local args = {
    command,
    "convert",
    input,
    "-n",
    tostring(math.max(1, math.min(max_items, top))),
    "--beam",
    tostring(beam),
  }

  local dict_ok, dict = readable_path(viterust.dict)
  if dict_ok then
    vim.list_extend(args, { "--dict", dict })
  end

  local ngram_ok, ngram = readable_path(viterust.ngram)
  if dict_ok and ngram_ok then
    vim.list_extend(args, { "--ngram", ngram })
  end

  local fuzzy = tonumber(viterust.fuzzy or 0) or 0
  if fuzzy > 0 then
    vim.list_extend(args, { "--fuzzy", tostring(fuzzy) })
  end

  append_extra_args(args, viterust.extra_args)
  return args
end

local function parse_viterust_candidates(stdout, max_items)
  local candidates = {}
  local seen = {}

  for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
    local fields = vim.split(line, "\t", { plain = true })
    local candidate = fields[2] or line:match("^%d+%s+(.+)%s+cost=")
    candidate = trim(candidate)
    if candidate ~= "" and not seen[candidate] then
      candidates[#candidates + 1] = candidate
      seen[candidate] = true
      if #candidates >= max_items then
        break
      end
    end
  end

  return candidates
end

local function request_viterust_candidates(input, opts, max_items, on_done)
  if not viterust_available(opts) or max_items <= 0 then
    return function() end
  end

  local cancelled = false
  local job = vim.system(viterust_args(input, opts, max_items), { text = true }, function(result)
    vim.schedule(function()
      if cancelled then
        return
      end

      if result.code ~= 0 then
        on_done({})
        return
      end

      on_done(parse_viterust_candidates(result.stdout, max_items))
    end)
  end)

  return function()
    cancelled = true
    if job then
      pcall(function()
        job:kill(15)
      end)
    end
  end
end

function source.new(opts)
  return setmetatable({ opts = default_opts(opts) }, source)
end

function source:enabled()
  local ok_mode, mode = pcall(vim.api.nvim_get_mode)
  local current_mode = ok_mode and mode and mode.mode or ""
  return type(current_mode) ~= "string" or current_mode:sub(1, 1) ~= "c"
end

local function completion_context_kind(ctx, opts)
  opts = default_opts(opts)
  local prefix = extract_prefix(ctx)
  if prefix == "" then
    return is_after_japanese_text(ctx) and "romaji_after_japanese" or nil
  end
  if not has_enough_keyword_length(prefix, opts.min_keyword_length) then
    return is_prefix_after_japanese(ctx, prefix) and "romaji_after_japanese" or nil
  end
  if is_prefix_after_japanese(ctx, prefix) then
    return "romaji_after_japanese"
  end
  return "romaji"
end

function source:get_trigger_characters()
  return vim.deepcopy(self.opts.trigger_characters or {})
end

function source:get_completions(ctx, callback)
  local prefix = extract_prefix(ctx)
  if prefix == "" or not has_enough_keyword_length(prefix, self.opts.min_keyword_length) then
    callback(response({}, {
      is_incomplete_forward = true,
      is_incomplete_backward = prefix ~= "",
    }))
    return function() end
  end

  local items = {}
  local seen = {}
  local cancelled = false
  local cancel_viterust = request_viterust_candidates(prefix, self.opts, self.opts.max_items, function(candidates)
    if cancelled then
      return
    end

    local rank = 1
    for _, candidate in ipairs(candidates) do
      rank = add_item(items, seen, ctx, prefix, candidate, rank)
      if #items >= self.opts.max_items then
        break
      end
    end

    callback(response(items))
  end)

  callback(response(items))
  return function()
    cancelled = true
    cancel_viterust()
  end
end

function source:reload() end

function source.is_completion_context(ctx, opts)
  return completion_context_kind(ctx, opts) ~= nil
end

function source.setup_commands() end

function source.clear_cache() end

function source.status(opts)
  opts = default_opts(opts)
  return {
    available = viterust_available(opts),
    command = executable_path(viterust_options(opts).command),
  }
end

source._test = {
  extract_prefix = extract_prefix,
  parse_viterust_candidates = parse_viterust_candidates,
  viterust_args = viterust_args,
}

return source
