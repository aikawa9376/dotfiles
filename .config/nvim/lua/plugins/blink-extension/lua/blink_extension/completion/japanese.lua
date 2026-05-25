local completion_utils = require("blink_extension.completion.utils")

local ok_types, types = pcall(require, "blink.cmp.types")
if not ok_types then
  types = { CompletionItemKind = { Text = 1 } }
end

local trim_suffixes = {
  "について",
  "に対して",
  "において",
  "によって",
  "による",
  "している",
  "していた",
  "されている",
  "されていた",
  "して",
  "した",
  "する",
  "される",
  "された",
  "できる",
  "できた",
  "でき",
  "として",
  "にして",
  "ための",
  "など",
  "だけ",
  "くらい",
  "ぐらい",
  "から",
  "まで",
  "より",
  "では",
  "には",
  "にも",
  "へは",
  "へも",
  "とは",
  "とも",
  "でも",
  "とか",
  "って",
  "です",
  "でした",
  "ます",
  "ました",
  "の",
  "は",
  "が",
  "を",
  "に",
  "へ",
  "と",
  "で",
  "も",
  "や",
  "か",
  "な",
  "ね",
  "よ",
}

local ignored_hiragana_tokens = {
  ["です"] = true,
  ["ます"] = true,
  ["でした"] = true,
  ["ました"] = true,
  ["こと"] = true,
  ["もの"] = true,
  ["ため"] = true,
  ["よう"] = true,
  ["それ"] = true,
  ["これ"] = true,
  ["あれ"] = true,
}

local hard_boundary_suffixes = {
  "について",
  "に対して",
  "において",
  "によって",
  "による",
  "として",
  "にして",
  "ための",
  "では",
  "には",
  "にも",
  "へは",
  "へも",
  "とは",
  "とも",
  "でも",
  "とか",
  "って",
  "の",
  "は",
  "が",
  "を",
  "に",
  "へ",
  "と",
  "で",
  "も",
  "や",
  "か",
  "な",
  "ね",
  "よ",
}

local source = {}
source.__index = source

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function endswith(text, suffix)
  return suffix ~= "" and text:sub(-#suffix) == suffix
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
  if type(ctx) == "table"
    and type(ctx.line) == "string"
    and type(ctx.bounds) == "table"
    and type(ctx.bounds.start_col) == "number"
    and type(ctx.cursor) == "table"
    and type(ctx.cursor[2]) == "number"
  then
    local start_col = math.max(1, ctx.bounds.start_col)
    local end_col = math.max(start_col, ctx.cursor[2])
    local keyword = ctx.line:sub(start_col, end_col)
    local prefix = completion_utils.extract_trailing_japanese(keyword)
    if prefix ~= "" then
      return prefix
    end
  end

  return completion_utils.extract_trailing_japanese(line_to_cursor(ctx))
end

local function char_class(char)
  local cp = completion_utils.codepoint(char)
  if completion_utils.is_kanji_cp(cp) then
    return "kanji"
  end
  if completion_utils.is_katakana_cp(cp) then
    return "katakana"
  end
  if completion_utils.is_hiragana_cp(cp) then
    return "hiragana"
  end

  return "other"
end

local function token_has_class(token, class_name)
  for _, char in ipairs(completion_utils.split_chars(token)) do
    if char_class(char) == class_name then
      return true
    end
  end

  return false
end

local function endswith_any(text, suffixes)
  for _, suffix in ipairs(suffixes) do
    if #text > #suffix and endswith(text, suffix) then
      return true
    end
  end

  return false
end

local function trim_suffix(token, prefix)
  local trimmed = trim(token)
  local prefix_chars = vim.fn.strchars(prefix)

  while true do
    local changed = false
    for _, suffix in ipairs(trim_suffixes) do
      if #trimmed > #suffix and endswith(trimmed, suffix) then
        local candidate = trimmed:sub(1, #trimmed - #suffix)
        if candidate:sub(1, #prefix) == prefix and vim.fn.strchars(candidate) >= prefix_chars then
          trimmed = candidate
          changed = true
          break
        end
      end
    end

    if not changed then
      break
    end
  end

  return trimmed
end

local function expand_candidate(chars, start_idx, prefix)
  local prefix_chars = vim.fn.strchars(prefix)
  local end_idx = math.min(#chars, start_idx + prefix_chars - 1)
  local token = table.concat(chars, "", start_idx, end_idx)
  local has_kanji = token_has_class(token, "kanji")
  local has_katakana = token_has_class(token, "katakana")
  local has_hiragana = token_has_class(token, "hiragana")
  local previous_class = char_class(chars[end_idx])

  if endswith_any(token, hard_boundary_suffixes) then
    return token
  end

  local i = end_idx + 1
  while i <= #chars do
    local class_name = char_class(chars[i])
    if class_name == "other" then
      break
    end

    if has_katakana and not has_kanji then
      if class_name ~= "katakana" then
        break
      end
    elseif has_hiragana and not has_kanji and not has_katakana then
      if class_name ~= "hiragana" then
        break
      end
    elseif has_kanji and (class_name == "katakana" or (previous_class == "hiragana" and class_name == "kanji")) then
      break
    end

    end_idx = i
    if class_name == "kanji" then
      has_kanji = true
    elseif class_name == "katakana" then
      has_katakana = true
    elseif class_name == "hiragana" then
      has_hiragana = true
    end
    previous_class = class_name
    i = i + 1
  end

  return trim_suffix(table.concat(chars, "", start_idx, end_idx), prefix)
end

local function candidates_from_text(prefix, text)
  local candidates = {}
  local chars = completion_utils.split_chars(text)
  local search_from = 1

  while true do
    local start_byte, end_byte = text:find(prefix, search_from, true)
    if not start_byte then
      break
    end

    local start_idx = vim.fn.strchars(text:sub(1, start_byte - 1)) + 1
    local token = expand_candidate(chars, start_idx, prefix)
    if token ~= "" then
      candidates[#candidates + 1] = token
    end

    search_from = end_byte + 1
  end

  return candidates
end

local function item_detail(kind, path, line_number)
  if path and path ~= "" and line_number then
    return string.format("[%s] %s:%d", kind, path, line_number)
  end

  if path and path ~= "" then
    return string.format("[%s] %s", kind, path)
  end

  return string.format("[%s]", kind)
end

local function add_text_tokens(items, seen, prefix, text, detail, doc)
  for _, token in ipairs(candidates_from_text(prefix, text)) do
    if token ~= ""
      and token ~= prefix
      and not seen[token]
      and token:sub(1, #prefix) == prefix
      and completion_utils.has_japanese(token)
      and not completion_utils.is_ascii(token)
      and not (not token_has_class(token, "kanji") and not token_has_class(token, "katakana") and ignored_hiragana_tokens[token])
    then
      seen[token] = true
      items[#items + 1] = {
        label = token,
        insertText = token,
        filterText = token,
        kind = types.CompletionItemKind.Text,
        kind_name = "text",
        detail = detail,
        documentation = {
          kind = "markdown",
          value = doc,
        },
      }
    end
  end
end

local function sort_items(items, prefix)
  table.sort(items, function(a, b)
    local a_exact = a.label == prefix
    local b_exact = b.label == prefix

    if a_exact ~= b_exact then
      return a_exact
    end

    if #a.label ~= #b.label then
      return #a.label < #b.label
    end

    return a.label < b.label
  end)
end

local function current_buffer_items(bufnr, prefix, max_items)
  local items = {}
  local seen = {}

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return items, seen
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local path = bufname ~= "" and vim.fn.fnamemodify(bufname, ":~:.") or "current-buffer"

  for line_number, text in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if text:find(prefix, 1, true) then
      add_text_tokens(
        items,
        seen,
        prefix,
        text,
        item_detail("JB", path, line_number),
        ("```text\n%s\n```"):format(trim(text))
      )
    end

    if #items >= max_items then
      break
    end
  end

  return items, seen
end

local function project_root(bufnr, opts)
  local root = vim.fs.root(bufnr or 0, opts.project_root_marker)
  if root or not opts.project_root_fallback then
    return root
  end

  return vim.fn.getcwd()
end

local function append_rg_items(items, seen, prefix, stdout, max_items)
  for _, line in ipairs(vim.split(stdout or "", "\n", { trimempty = true })) do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" and decoded.type == "match" and type(decoded.data) == "table" then
      local path = decoded.data.path and decoded.data.path.text or ""
      local line_number = tonumber(decoded.data.line_number)
      local text = decoded.data.lines and decoded.data.lines.text or ""
      add_text_tokens(
        items,
        seen,
        prefix,
        text,
        item_detail("JR", path, line_number),
        ("```text\n%s\n```"):format(trim(text))
      )
    end

    if #items >= max_items then
      break
    end
  end
end

local function response(items)
  return {
    items = items,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  }
end

function source.new(opts)
  opts = vim.tbl_deep_extend("keep", opts or {}, {
    min_keyword_length = 2,
    max_items = 50,
    max_filesize = "1M",
    max_line_matches = 20,
    project_root_marker = ".git",
    project_root_fallback = true,
    search_casing = "--ignore-case",
    additional_rg_options = {},
  })

  return setmetatable({ opts = opts }, source)
end

function source:enabled()
  local ok_mode, mode = pcall(vim.api.nvim_get_mode)
  local current_mode = ok_mode and mode and mode.mode or ""
  return type(current_mode) ~= "string" or current_mode:sub(1, 1) ~= "c"
end

function source:get_completions(ctx, callback)
  local prefix = extract_prefix(ctx)
  if prefix == "" or vim.fn.strchars(prefix) < self.opts.min_keyword_length then
    callback(response({}))
    return function() end
  end

  local bufnr = type(ctx) == "table" and ctx.bufnr or vim.api.nvim_get_current_buf()
  local items, seen = current_buffer_items(bufnr, prefix, self.opts.max_items)
  local root = project_root(bufnr, self.opts)

  if #items >= self.opts.max_items or root == nil or vim.fn.executable("rg") ~= 1 then
    sort_items(items, prefix)
    callback(response(items))
    return function() end
  end

  local cmd = {
    "rg",
    "--no-config",
    "--json",
    "--fixed-strings",
    "--max-filesize=" .. self.opts.max_filesize,
    self.opts.search_casing,
    "-m",
    tostring(self.opts.max_line_matches),
  }

  for _, option in ipairs(self.opts.additional_rg_options) do
    cmd[#cmd + 1] = option
  end

  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = prefix
  cmd[#cmd + 1] = root

  local cancelled = false
  local handle = vim.system(cmd, { text = true }, function(result)
    if cancelled then
      return
    end

    vim.schedule(function()
      if cancelled then
        return
      end

      if result.code == 0 then
        append_rg_items(items, seen, prefix, result.stdout, self.opts.max_items)
      end

      sort_items(items, prefix)
      callback(response(items))
    end)
  end)

  return function()
    cancelled = true
    if handle and handle.kill then
      pcall(handle.kill, handle, 15)
    end
  end
end

return source
