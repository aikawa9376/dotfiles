local completion_utils = require("blink_extension.completion.utils")

local uv = vim.uv or vim.loop

local source = {}
source.__index = source
local completion_item_kind_text = 1
local completion_item_kind_loaded = false

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

local kana_map = {
  a = "あ",
  i = "い",
  u = "う",
  e = "え",
  o = "お",
  ka = "か",
  ki = "き",
  ku = "く",
  ke = "け",
  ko = "こ",
  kya = "きゃ",
  kyu = "きゅ",
  kyo = "きょ",
  ga = "が",
  gi = "ぎ",
  gu = "ぐ",
  ge = "げ",
  go = "ご",
  gya = "ぎゃ",
  gyu = "ぎゅ",
  gyo = "ぎょ",
  sa = "さ",
  si = "し",
  shi = "し",
  su = "す",
  se = "せ",
  so = "そ",
  sya = "しゃ",
  syu = "しゅ",
  syo = "しょ",
  sha = "しゃ",
  shu = "しゅ",
  sho = "しょ",
  za = "ざ",
  zi = "じ",
  ji = "じ",
  zu = "ず",
  ze = "ぜ",
  zo = "ぞ",
  zya = "じゃ",
  zyu = "じゅ",
  zyo = "じょ",
  ja = "じゃ",
  ju = "じゅ",
  jo = "じょ",
  ta = "た",
  ti = "ち",
  chi = "ち",
  tu = "つ",
  tsu = "つ",
  te = "て",
  to = "と",
  tya = "ちゃ",
  tyu = "ちゅ",
  tyo = "ちょ",
  cha = "ちゃ",
  chu = "ちゅ",
  cho = "ちょ",
  da = "だ",
  di = "ぢ",
  du = "づ",
  de = "で",
  ["do"] = "ど",
  dya = "ぢゃ",
  dyu = "ぢゅ",
  dyo = "ぢょ",
  na = "な",
  ni = "に",
  nu = "ぬ",
  ne = "ね",
  no = "の",
  nya = "にゃ",
  nyu = "にゅ",
  nyo = "にょ",
  ha = "は",
  hi = "ひ",
  hu = "ふ",
  fu = "ふ",
  he = "へ",
  ho = "ほ",
  hya = "ひゃ",
  hyu = "ひゅ",
  hyo = "ひょ",
  fa = "ふぁ",
  fi = "ふぃ",
  fe = "ふぇ",
  fo = "ふぉ",
  ba = "ば",
  bi = "び",
  bu = "ぶ",
  be = "べ",
  bo = "ぼ",
  bya = "びゃ",
  byu = "びゅ",
  byo = "びょ",
  pa = "ぱ",
  pi = "ぴ",
  pu = "ぷ",
  pe = "ぺ",
  po = "ぽ",
  pya = "ぴゃ",
  pyu = "ぴゅ",
  pyo = "ぴょ",
  ma = "ま",
  mi = "み",
  mu = "む",
  me = "め",
  mo = "も",
  mya = "みゃ",
  myu = "みゅ",
  myo = "みょ",
  ya = "や",
  yu = "ゆ",
  yo = "よ",
  ra = "ら",
  ri = "り",
  ru = "る",
  re = "れ",
  ro = "ろ",
  rya = "りゃ",
  ryu = "りゅ",
  ryo = "りょ",
  wa = "わ",
  wi = "うぃ",
  we = "うぇ",
  wo = "を",
  va = "ゔぁ",
  vi = "ゔぃ",
  vu = "ゔ",
  ve = "ゔぇ",
  vo = "ゔぉ",
  xa = "ぁ",
  xi = "ぃ",
  xu = "ぅ",
  xe = "ぇ",
  xo = "ぉ",
  la = "ぁ",
  li = "ぃ",
  lu = "ぅ",
  le = "ぇ",
  lo = "ぉ",
  xya = "ゃ",
  xyu = "ゅ",
  xyo = "ょ",
  lya = "ゃ",
  lyu = "ゅ",
  lyo = "ょ",
  xtu = "っ",
  xtsu = "っ",
  ltu = "っ",
  ltsu = "っ",
}

local builtin_dictionary = {
  ["にほんご"] = { "日本語" },
  ["にほん"] = { "日本" },
  ["きょう"] = { "今日" },
  ["あめ"] = { "雨" },
  ["あした"] = { "明日" },
  ["きのう"] = { "昨日" },
  ["いま"] = { "今" },
  ["じかん"] = { "時間" },
  ["せってい"] = { "設定" },
  ["じっそう"] = { "実装" },
  ["かくにん"] = { "確認" },
  ["しゅうせい"] = { "修正" },
  ["へんこう"] = { "変更" },
  ["ほかん"] = { "補完" },
  ["へんかん"] = { "変換" },
  ["じしょ"] = { "辞書" },
  ["もんだい"] = { "問題" },
  ["げんいん"] = { "原因" },
  ["すこし"] = { "少し" },
  ["ながい"] = { "長い" },
  ["みじかい"] = { "短い" },
  ["ふつう"] = { "普通" },
  ["ぶんしょう"] = { "文章" },
  ["にゅうりょく"] = { "入力" },
  ["ひらがな"] = { "平仮名" },
  ["かんじ"] = { "漢字" },
  ["せっきょくてき"] = { "積極的" },
  ["ちえん"] = { "遅延" },
  ["よみこみ"] = { "読み込み" },
  ["てっぱんやき"] = { "鉄板焼き" },
  ["たべたい"] = { "食べたい" },
  ["たべたいです"] = { "食べたいです" },
  ["がたべたい"] = { "が食べたい" },
  ["がたべたいです"] = { "が食べたいです" },
  ["ばいおてろ"] = { "バイオテロ" },
}

local preferred_readings = {}
local preferred_candidates = {}
local preferred_candidate_texts = {}
for reading in pairs(builtin_dictionary) do
  preferred_readings[reading] = true
end
for reading, candidates in pairs(builtin_dictionary) do
  preferred_candidates[reading] = {}
  for rank, candidate in ipairs(candidates) do
    preferred_candidates[reading][candidate] = rank
  end
  if candidates[1] then
    preferred_candidate_texts[#preferred_candidate_texts + 1] = candidates[1]
  end
end
table.sort(preferred_candidate_texts, function(a, b)
  return #a > #b
end)

local dictionary_cache = {}
local dictionary_read_chunk_size = 64 * 1024
local llm_unavailable_until = 0
local llm_server_job_id = nil

local skk_downloads = {
  M = {
    filename = "SKK-JISYO.M",
    url = "https://skk-dev.github.io/dict/SKK-JISYO.M.gz",
  },
  ML = {
    filename = "SKK-JISYO.ML",
    url = "https://skk-dev.github.io/dict/SKK-JISYO.ML.gz",
  },
  L = {
    filename = "SKK-JISYO.L",
    url = "https://skk-dev.github.io/dict/SKK-JISYO.L.gz",
  },
  ["L.unannotated"] = {
    filename = "SKK-JISYO.L.unannotated",
    url = "https://skk-dev.github.io/dict/SKK-JISYO.L.unannotated.gz",
  },
  propernoun = {
    filename = "SKK-JISYO.propernoun",
    url = "https://skk-dev.github.io/dict/SKK-JISYO.propernoun.gz",
  },
}

local default_init_dictionary_kinds = { "L.unannotated", "propernoun" }

local default_punctuation_candidates = {
  ["."] = { "。", "．" },
  [","] = { "、", "，" },
  ["!"] = { "！" },
  ["?"] = { "？" },
}

local function trim(text)
  return (text or ""):gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
end

local function dict_dir()
  return vim.fn.stdpath("config") .. "/dict"
end

local function default_registry_path()
  return dict_dir() .. "/romaji-japanese-dicts.txt"
end

local function default_opts(opts)
  return vim.tbl_deep_extend("force", {
    min_keyword_length = 4,
    min_partial_reading_length = 4,
    dictionary_beam_width = 24,
    dictionary_max_segment_candidates = 4,
    dictionary_viterbi_min_reading_length = 3,
    derive_katakana_readings_from_candidates = true,
    max_items = 20,
    use_builtin_dictionary = true,
    include_katakana = false,
    auto_katakana = true,
    katakana_min_keyword_length = 5,
    dictionary_paths = {
      vim.fn.stdpath("config") .. "/dict/romaji-japanese.tsv",
    },
    dictionary_registry_path = default_registry_path(),
    init_dictionary_kinds = default_init_dictionary_kinds,
    punctuation = {
      enabled = true,
      require_japanese_before = true,
      candidates = default_punctuation_candidates,
    },
    llm = {
      enabled = false,
      endpoint = "http://127.0.0.1:18080/v1/chat/completions",
      model = "romaji-ja",
      timeout_ms = 2500,
      backoff_ms = 5000,
      max_items = 5,
      max_hints = 8,
      max_tokens = 160,
      temperature = 0.1,
      top_p = 0.8,
      server = {
        command = "/tmp/llama.cpp/build/bin/llama-server",
        model_path = "/tmp/Qwen3-0.6B-Q4_0.gguf",
        host = "127.0.0.1",
        port = 18080,
        ctx_size = 2048,
        threads = 4,
        parallel = 1,
        reasoning = "off",
      },
    },
  }, opts or {})
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "RomajiJapaneseDict" })
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
  local prefix = line_to_cursor(ctx):match("([A-Za-z][A-Za-z'%-]*)$") or ""
  if prefix:find("%u") then
    return ""
  end

  return prefix
end

local function is_after_japanese_text(ctx)
  return completion_utils.extract_trailing_japanese(line_to_cursor(ctx)) ~= ""
end

local function punctuation_options(opts)
  local punctuation = type(opts) == "table" and type(opts.punctuation) == "table" and opts.punctuation or {}
  if punctuation.enabled == false then
    return nil
  end

  return punctuation
end

local function punctuation_candidates(opts)
  local punctuation = punctuation_options(opts)
  if not punctuation then
    return {}
  end

  return type(punctuation.candidates) == "table" and punctuation.candidates or default_punctuation_candidates
end

local function extract_romaji_punctuation(ctx, opts)
  local text = line_to_cursor(ctx)
  if text == "" then
    return nil, nil, nil
  end

  local char = text:sub(-1)
  local candidates = punctuation_candidates(opts)[char]
  if type(candidates) ~= "table" or #candidates == 0 then
    return nil, nil, nil
  end

  local prefix = text:sub(1, #text - 1):match("([A-Za-z][A-Za-z'%-]*)$") or ""
  if prefix == "" or prefix:find("%u") then
    return nil, nil, nil
  end

  return prefix, char, candidates
end

local function extract_punctuation(ctx, opts)
  local text = line_to_cursor(ctx)
  if text == "" then
    return nil, nil
  end

  local candidates_by_char = punctuation_candidates(opts)
  local char = text:sub(-1)
  local candidates = candidates_by_char[char]
  if type(candidates) ~= "table" or #candidates == 0 then
    return nil, nil
  end

  local punctuation = punctuation_options(opts) or {}
  if punctuation.require_japanese_before ~= false then
    local before = text:sub(1, #text - 1)
    if completion_utils.extract_trailing_japanese(before) == "" then
      return nil, nil
    end
  end

  return char, candidates
end

local function is_vowel_or_y(char)
  return char ~= "" and char:match("[aiueoy]") ~= nil
end

local function is_consonant(char)
  return char ~= "" and char:match("[bcdfghjklmnpqrstvwxyz]") ~= nil
end

local function romaji_to_hiragana(input)
  input = tostring(input or ""):lower()
  if input == "" or input:find("[^a-z'%-]") then
    return nil
  end

  local out = {}
  local i = 1
  while i <= #input do
    local char = input:sub(i, i)
    local next_char = input:sub(i + 1, i + 1)
    local next_next_char = input:sub(i + 2, i + 2)

    if char == "-" then
      out[#out + 1] = "ー"
      i = i + 1
    elseif char == "'" then
      i = i + 1
    elseif char == "n" then
      if next_char == "'" then
        out[#out + 1] = "ん"
        i = i + 2
      elseif next_char == "n" and next_next_char == "y" then
        out[#out + 1] = "ん"
        i = i + 2
      elseif next_char == "n" and not is_vowel_or_y(next_next_char) then
        out[#out + 1] = "ん"
        i = i + 2
      elseif next_char == "" or (not is_vowel_or_y(next_char) and not kana_map[input:sub(i, i + 1)]) then
        out[#out + 1] = "ん"
        i = i + 1
      else
        local matched = false
        for len = 3, 1, -1 do
          local kana = kana_map[input:sub(i, i + len - 1)]
          if kana then
            out[#out + 1] = kana
            i = i + len
            matched = true
            break
          end
        end
        if not matched then
          return nil
        end
      end
    elseif char ~= "n" and is_consonant(char) and next_char == char then
      out[#out + 1] = "っ"
      i = i + 1
    else
      local matched = false
      for len = 4, 1, -1 do
        local kana = kana_map[input:sub(i, i + len - 1)]
        if kana then
          out[#out + 1] = kana
          i = i + len
          matched = true
          break
        end
      end
      if not matched then
        return nil
      end
    end
  end

  return table.concat(out)
end

local function convert_kana_block(text, from_start, from_end, offset)
  local out = {}
  for _, char in ipairs(completion_utils.split_chars(text)) do
    local cp = completion_utils.codepoint(char)
    if cp >= from_start and cp <= from_end then
      out[#out + 1] = vim.fn.nr2char(cp + offset, true)
    else
      out[#out + 1] = char
    end
  end
  return table.concat(out)
end

local function katakana_to_hiragana(text)
  return convert_kana_block(text, 0x30A1, 0x30F6, -0x60)
end

local function hiragana_to_katakana(text)
  return convert_kana_block(text, 0x3041, 0x3096, 0x60)
end

local katakana_reading_markers = {
  "ばいお",
  "てろ",
  "こんぴゅ",
  "ぷろぐ",
  "さーば",
  "くらいあんと",
  "あぷり",
  "でーた",
  "めーる",
  "ふぁ",
  "ふぃ",
  "ふぇ",
  "ふぉ",
  "てぃ",
  "でぃ",
  "うぃ",
  "うぇ",
  "うぉ",
  "ゔ",
  "ー",
}

local function should_offer_katakana(prefix, kana, opts)
  if opts.include_katakana then
    return true
  end
  if opts.auto_katakana ~= true then
    return false
  end
  if #prefix < (opts.katakana_min_keyword_length or 5) then
    return false
  end

  if prefix:find("[vfqx%-]") then
    return true
  end

  for _, marker in ipairs(katakana_reading_markers) do
    if kana:find(marker, 1, true) then
      return true
    end
  end

  return false
end

local function normalize_reading(reading)
  reading = trim(reading)
  if reading == "" then
    return ""
  end

  if completion_utils.is_ascii(reading) then
    return romaji_to_hiragana(reading) or ""
  end

  return katakana_to_hiragana(reading)
end

local function clean_dictionary_candidate(candidate)
  return trim((candidate or ""):gsub(";.*$", ""))
end

local function is_katakana_reading_candidate(candidate)
  local saw_katakana = false
  for _, char in ipairs(completion_utils.split_chars(candidate)) do
    local cp = completion_utils.codepoint(char)
    if completion_utils.is_katakana_cp(cp) then
      saw_katakana = true
    elseif char ~= "ー" and char ~= "・" and char ~= "･" and char ~= " " and char ~= "　" then
      return false
    end
  end
  return saw_katakana
end

local function derived_katakana_reading(candidate)
  candidate = clean_dictionary_candidate(candidate)
  if not is_katakana_reading_candidate(candidate) then
    return ""
  end

  local reading = {}
  for _, char in ipairs(completion_utils.split_chars(katakana_to_hiragana(candidate))) do
    if char ~= "・" and char ~= "･" and char ~= " " and char ~= "　" then
      reading[#reading + 1] = char
    end
  end
  return table.concat(reading)
end

local function add_normalized_dictionary_entry(map, reading, candidates)
  if reading == "" or not completion_utils.has_japanese(reading) then
    return
  end

  map[reading] = map[reading] or {}
  local seen = {}
  for _, candidate in ipairs(map[reading]) do
    seen[candidate] = true
  end

  for _, candidate in ipairs(candidates) do
    candidate = clean_dictionary_candidate(candidate)
    if candidate ~= "" and candidate ~= reading and completion_utils.has_japanese(candidate) and not seen[candidate] then
      map[reading][#map[reading] + 1] = candidate
      seen[candidate] = true
    end
  end
end

local function add_dictionary_entry(map, reading, candidates, opts)
  local normalized_reading = normalize_reading(reading)
  add_normalized_dictionary_entry(map, normalized_reading, candidates)

  if opts and opts.derive_katakana_readings_from_candidates == false then
    return
  end

  for _, candidate in ipairs(candidates) do
    local derived_reading = derived_katakana_reading(candidate)
    if derived_reading ~= "" and derived_reading ~= normalized_reading then
      add_normalized_dictionary_entry(map, derived_reading, { candidate })
    end
  end
end

local function split_candidates(text, delimiters)
  local delimiter_set = {}
  for _, delimiter in ipairs(delimiters or { ",", "，", "/" }) do
    delimiter_set[delimiter] = true
  end

  local candidates = {}
  local current = {}
  for _, char in ipairs(completion_utils.split_chars(tostring(text or ""))) do
    if delimiter_set[char] then
      local candidate = trim(table.concat(current))
      if candidate ~= "" then
        candidates[#candidates + 1] = candidate
      end
      current = {}
    else
      current[#current + 1] = char
    end
  end

  local candidate = trim(table.concat(current))
  if candidate ~= "" then
    candidates[#candidates + 1] = candidate
  end

  return candidates
end

local function parse_dictionary_line(line)
  line = trim(line)
  if line == "" or line:sub(1, 1) == "#" or line:sub(1, 2) == ";;" then
    return nil, nil
  end

  local skk_reading, skk_body = line:match("^([^ \t]+)[ \t]+/(.*)/[ \t]*$")
  if skk_reading and skk_body then
    return skk_reading, split_candidates(skk_body, { "/" })
  end

  if line:find("\t", 1, true) then
    local fields = vim.split(line, "\t", { plain = true })
    return fields[1], split_candidates(fields[2] or "")
  end

  local reading, body = line:match("^([^ \t]+)[ \t]+(.+)$")
  if reading and body then
    return reading, split_candidates(body)
  end

  return nil, nil
end

local function build_dictionary_index(map)
  local by_first = {}
  for reading, candidates in pairs(map) do
    if #candidates > 0 then
      local chars = completion_utils.split_chars(reading)
      local first = chars[1]
      if first then
        by_first[first] = by_first[first] or {}
        by_first[first][#by_first[first] + 1] = {
          reading = reading,
          chars = chars,
          candidates = candidates,
        }
      end
    end
  end

  for _, entries in pairs(by_first) do
    table.sort(entries, function(a, b)
      if #a.chars ~= #b.chars then
        return #a.chars > #b.chars
      end
      return a.reading < b.reading
    end)
  end

  return {
    map = map,
    by_first = by_first,
  }
end

local function expand_dictionary_path(path)
  return vim.fn.fnamemodify(vim.fn.expand(tostring(path or "")), ":p")
end

local function add_unique_path(paths, seen, path)
  if type(path) ~= "string" or trim(path) == "" then
    return
  end

  local expanded = expand_dictionary_path(path)
  if expanded == "" or seen[expanded] then
    return
  end

  paths[#paths + 1] = expanded
  seen[expanded] = true
end

local function read_registry_paths(registry_path)
  registry_path = expand_dictionary_path(registry_path or default_registry_path())
  if registry_path == "" or vim.fn.filereadable(registry_path) ~= 1 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, registry_path)
  if not ok then
    return {}
  end

  local paths = {}
  for _, line in ipairs(lines) do
    line = trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      paths[#paths + 1] = line
    end
  end
  return paths
end

local function effective_dictionary_paths(opts)
  local paths = {}
  local seen = {}
  for _, path in ipairs(opts.dictionary_paths or {}) do
    add_unique_path(paths, seen, path)
  end
  for _, path in ipairs(read_registry_paths(opts.dictionary_registry_path)) do
    add_unique_path(paths, seen, path)
  end
  return paths
end

local function file_signature(path)
  local expanded = expand_dictionary_path(path)
  local stat = uv and uv.fs_stat(expanded) or nil
  return ("%s:%s:%s"):format(
    expanded,
    stat and stat.size or "-",
    stat and stat.mtime and stat.mtime.sec or "-"
  )
end

local function dictionary_signature(opts, paths)
  local parts = {
    "builtin:" .. tostring(opts.use_builtin_dictionary),
    "derive_katakana:" .. tostring(opts.derive_katakana_readings_from_candidates),
    "registry:" .. file_signature(opts.dictionary_registry_path or default_registry_path()),
  }
  for _, path in ipairs(paths or {}) do
    parts[#parts + 1] = file_signature(path)
  end
  return table.concat(parts, "\n")
end

local function count_dictionary_entries(map)
  local count = 0
  for _, candidates in pairs(map) do
    count = count + #candidates
  end
  return count
end

local function seed_builtin_dictionary(map, opts)
  if opts.use_builtin_dictionary then
    for reading, candidates in pairs(builtin_dictionary) do
      add_dictionary_entry(map, reading, candidates, opts)
    end
  end
end

local function add_dictionary_line(map, state, line, opts)
  state.line_count = state.line_count + 1
  local reading, candidates = parse_dictionary_line(line)
  if reading and candidates then
    add_dictionary_entry(map, reading, candidates, opts)
  end
end

local function close_file(fd)
  if fd and uv then
    pcall(uv.fs_close, fd)
  end
end

local function read_dictionary_file_async(path, map, state, opts, done)
  if not uv then
    done("vim.uv is unavailable")
    return
  end

  uv.fs_open(path, "r", 438, function(open_err, fd)
    vim.schedule(function()
      if open_err or not fd then
        done(open_err or "failed to open dictionary")
        return
      end

      local offset = 0
      local rest = ""

      local function parse_chunk(chunk)
        local text = rest .. chunk
        local complete, next_rest = text:match("^(.*\n)([^\n]*)$")
        if not complete then
          rest = text
          return
        end

        rest = next_rest or ""
        for line in complete:gmatch("([^\n]*)\n") do
          add_dictionary_line(map, state, line, opts)
        end
      end

      local function read_next()
        uv.fs_read(fd, dictionary_read_chunk_size, offset, function(read_err, data)
          vim.schedule(function()
            if read_err then
              close_file(fd)
              done(read_err)
              return
            end

            if not data or data == "" then
              if rest ~= "" then
                add_dictionary_line(map, state, rest, opts)
              end
              close_file(fd)
              done()
              return
            end

            offset = offset + #data
            parse_chunk(data)
            read_next()
          end)
        end)
      end

      read_next()
    end)
  end)
end

local function finish_dictionary_load(state, map)
  state.dictionary = build_dictionary_index(map)
  state.status = "ready"
  state.completed_at = uv and uv.hrtime() or nil
  state.entry_count = count_dictionary_entries(map)
  state.current_path = nil

  local waiters = state.waiters
  state.waiters = {}
  for _, waiter in ipairs(waiters) do
    if not waiter.cancelled then
      waiter.callback(state.dictionary, state)
    end
  end
end

local function start_dictionary_load(state, opts, paths)
  local map = {}
  seed_builtin_dictionary(map, opts)

  local function read_next_path(index)
    if index > #paths then
      finish_dictionary_load(state, map)
      return
    end

    local path = paths[index]
    if vim.fn.filereadable(path) ~= 1 then
      state.errors[#state.errors + 1] = ("%s: not readable"):format(path)
      read_next_path(index + 1)
      return
    end

    state.current_path = path
    read_dictionary_file_async(path, map, state, opts, function(err)
      if err then
        state.errors[#state.errors + 1] = ("%s: %s"):format(path, tostring(err))
      end
      read_next_path(index + 1)
    end)
  end

  read_next_path(1)
end

local function request_dictionary(opts, callback)
  local paths = effective_dictionary_paths(opts)
  local signature = dictionary_signature(opts, paths)
  local state = dictionary_cache[signature]

  if state and state.status == "ready" then
    return state.dictionary, function() end
  end

  if not state then
    state = {
      status = "loading",
      signature = signature,
      paths = paths,
      waiters = {},
      errors = {},
      line_count = 0,
      entry_count = 0,
      started_at = uv and uv.hrtime() or nil,
      current_path = nil,
    }
    dictionary_cache[signature] = state
    start_dictionary_load(state, opts, paths)
  end

  if state.status == "ready" then
    return state.dictionary, function() end
  end

  local waiter = { cancelled = false, callback = callback }
  state.waiters[#state.waiters + 1] = waiter
  return nil, function()
    waiter.cancelled = true
  end
end

local function clear_dictionary_cache()
  dictionary_cache = {}
end

local function current_dictionary_state(opts)
  opts = default_opts(opts)
  local paths = effective_dictionary_paths(opts)
  return dictionary_cache[dictionary_signature(opts, paths)]
end

local function load_dictionary_sync_for_test(opts)
  opts = default_opts(opts)
  local paths = effective_dictionary_paths(opts)
  local map = {}
  seed_builtin_dictionary(map, opts)

  for _, path in ipairs(paths) do
    if vim.fn.filereadable(path) == 1 then
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok then
        local state = { line_count = 0 }
        for _, line in ipairs(lines) do
          add_dictionary_line(map, state, line, opts)
        end
      end
    end
  end

  return build_dictionary_index(map)
end

local function entry_matches(chars, start_idx, entry)
  if start_idx + #entry.chars - 1 > #chars then
    return false
  end

  for offset, char in ipairs(entry.chars) do
    if chars[start_idx + offset - 1] ~= char then
      return false
    end
  end

  return true
end

local function matches_at(dictionary, chars, start_idx)
  local entries = dictionary.by_first[chars[start_idx]]
  if not entries then
    return {}
  end

  local matches = {}
  for _, entry in ipairs(entries) do
    if entry_matches(chars, start_idx, entry) then
      matches[#matches + 1] = entry
    end
  end
  return matches
end

local function best_match_at(dictionary, chars, start_idx, min_chars)
  for _, match in ipairs(matches_at(dictionary, chars, start_idx)) do
    if #match.chars >= min_chars then
      return match
    end
  end
  return nil
end

local function join_chars(chars, start_idx, end_idx)
  if start_idx > end_idx then
    return ""
  end
  return table.concat(chars, "", start_idx, end_idx)
end

local function char_count(text)
  return #completion_utils.split_chars(text)
end

local function has_kanji(text)
  for _, char in ipairs(completion_utils.split_chars(text)) do
    if completion_utils.is_kanji_cp(completion_utils.codepoint(char)) then
      return true
    end
  end
  return false
end

local function has_kana(text)
  for _, char in ipairs(completion_utils.split_chars(text)) do
    local cp = completion_utils.codepoint(char)
    if completion_utils.is_hiragana_cp(cp) or completion_utils.is_katakana_cp(cp) then
      return true
    end
  end
  return false
end

local function all_kanji(text)
  local saw = false
  for _, char in ipairs(completion_utils.split_chars(text)) do
    saw = true
    if not completion_utils.is_kanji_cp(completion_utils.codepoint(char)) then
      return false
    end
  end
  return saw
end

local kana_keep_segments = {
  "になってしまう",
  "なってしまう",
  "してしまう",
  "てしまう",
  "しまう",
  "している",
  "してる",
  "できません",
  "できます",
  "できる",
  "でしょう",
  "でした",
  "ですか",
  "ですね",
  "です",
  "ません",
  "ました",
  "ますか",
  "ます",
  "ない",
  "たい",
  "だと",
  "では",
  "には",
  "とは",
  "から",
  "まで",
  "より",
  "ので",
  "けど",
  "なら",
}

table.sort(kana_keep_segments, function(a, b)
  return char_count(a) > char_count(b)
end)

local particle_chars = {
  ["は"] = true,
  ["が"] = true,
  ["を"] = true,
  ["に"] = true,
  ["で"] = true,
  ["と"] = true,
  ["も"] = true,
  ["の"] = true,
  ["へ"] = true,
  ["や"] = true,
  ["か"] = true,
}

local common_short_readings = {
  ["あめ"] = true,
  ["いま"] = true,
  ["きょう"] = true,
}

local function greedy_dictionary_candidate(kana, dictionary, min_partial_reading_length)
  local chars = completion_utils.split_chars(kana)
  local out = {}
  local changed = false
  local i = 1

  while i <= #chars do
    local match = best_match_at(dictionary, chars, i, min_partial_reading_length)
    if match and match.candidates[1] then
      out[#out + 1] = match.candidates[1]
      i = i + #match.chars
      changed = true
    else
      out[#out + 1] = chars[i]
      i = i + 1
    end
  end

  if not changed then
    return nil
  end
  return table.concat(out)
end

local function copy_append(list, value)
  local out = {}
  for i, item in ipairs(list) do
    out[i] = item
  end
  out[#out + 1] = value
  return out
end

local function prune_beam(bucket, beam_width)
  table.sort(bucket, function(a, b)
    if a.cost ~= b.cost then
      return a.cost < b.cost
    end
    return table.concat(a.out) < table.concat(b.out)
  end)

  local pruned = {}
  local seen = {}
  for _, state in ipairs(bucket) do
    local text = table.concat(state.out)
    if not seen[text] then
      pruned[#pruned + 1] = state
      seen[text] = true
      if #pruned >= beam_width then
        break
      end
    end
  end

  return pruned
end

local function push_beam(beams, index, state, beam_width)
  beams[index] = beams[index] or {}
  beams[index][#beams[index] + 1] = state
  if #beams[index] > beam_width * 4 then
    beams[index] = prune_beam(beams[index], beam_width)
  end
end

local function segment_matches(chars, start_idx, segment)
  local segment_chars = completion_utils.split_chars(segment)
  if start_idx + #segment_chars - 1 > #chars then
    return false, 0
  end

  for offset, char in ipairs(segment_chars) do
    if chars[start_idx + offset - 1] ~= char then
      return false, 0
    end
  end

  return true, #segment_chars
end

local function fallback_char_cost(char)
  if particle_chars[char] then
    return 0.2
  end
  return 1.3
end

local function keep_segment_cost(length)
  return math.max(0.2, length * 0.15)
end

local okurigana_like_starters = {
  ["べ"] = true,
  ["め"] = true,
  ["げ"] = true,
  ["ぜ"] = true,
  ["れ"] = true,
  ["け"] = true,
}

local function reading_has_internal_particle(entry)
  for i = 2, #entry.chars - 1 do
    if particle_chars[entry.chars[i]] then
      return true
    end
  end
  return false
end

local function dictionary_segment_cost(entry, candidate, candidate_index, chars, index)
  local reading_len = #entry.chars
  local cost = 8 - math.min(reading_len, 8) * 1.2

  if has_kanji(candidate) then
    cost = cost - 2
  else
    cost = cost + 1.5
  end

  if has_kana(candidate) then
    cost = cost - 0.5
  end

  if common_short_readings[entry.reading] then
    cost = cost - 2.2
  end

  if preferred_readings[entry.reading] then
    cost = cost - 2.5
  end

  local preferred_rank = preferred_candidates[entry.reading]
    and preferred_candidates[entry.reading][candidate]
  if preferred_rank then
    cost = cost - (5 / preferred_rank)
  end

  if all_kanji(candidate) and reading_len <= 3 and not common_short_readings[entry.reading] then
    cost = cost + 6
  end

  if char_count(candidate) == 1 and reading_len <= 3 and not common_short_readings[entry.reading] then
    cost = cost + 4
  end

  if all_kanji(candidate) and not preferred_readings[entry.reading] then
    if reading_has_internal_particle(entry) then
      cost = cost + 7
    end
    local next_char = chars[index + reading_len]
    if next_char and okurigana_like_starters[next_char] then
      cost = cost + 6
    end
    if particle_chars[entry.chars[1]] and index > 1 then
      cost = cost + 8
    end
    if particle_chars[entry.chars[#entry.chars]] and index + reading_len <= #chars then
      cost = cost + 8
    end
  end

  cost = cost + (candidate_index - 1) * 2.5
  return math.max(0.05, cost)
end

local function preferred_text_bonus(text)
  local bonus = 0
  for _, candidate in ipairs(preferred_candidate_texts) do
    if text:find(candidate, 1, true) then
      bonus = bonus + 4
    end
  end
  return bonus
end

local function push_dictionary_transitions(beams, state, dictionary, chars, index, opts)
  local min_reading_length = opts.dictionary_viterbi_min_reading_length
    or opts.min_partial_reading_length
    or 3
  local max_segment_candidates = opts.dictionary_max_segment_candidates or 4

  for _, entry in ipairs(matches_at(dictionary, chars, index)) do
    local reading_len = #entry.chars
    if reading_len >= min_reading_length or common_short_readings[entry.reading] then
      for candidate_index, candidate in ipairs(entry.candidates) do
        if candidate_index > max_segment_candidates then
          break
        end

        push_beam(beams, index + reading_len, {
          cost = state.cost + dictionary_segment_cost(entry, candidate, candidate_index, chars, index),
          out = copy_append(state.out, candidate),
          changed = true,
        }, opts.dictionary_beam_width or 24)
      end
    end
  end
end

local function push_keep_segment_transitions(beams, state, chars, index, beam_width)
  for _, segment in ipairs(kana_keep_segments) do
    local matched, length = segment_matches(chars, index, segment)
    if matched then
      push_beam(beams, index + length, {
        cost = state.cost + keep_segment_cost(length),
        out = copy_append(state.out, segment),
        changed = state.changed,
      }, beam_width)
      return
    end
  end
end

local function viterbi_dictionary_candidates(kana, dictionary, max_items, opts)
  if max_items <= 0 then
    return {}
  end

  opts = opts or {}
  local chars = completion_utils.split_chars(kana)
  local beam_width = opts.dictionary_beam_width or 24
  local beams = {
    [1] = {
      { cost = 0, out = {}, changed = false },
    },
  }

  for index = 1, #chars do
    local beam = beams[index]
    if beam then
      beams[index] = prune_beam(beam, beam_width)
      for _, state in ipairs(beams[index]) do
        push_keep_segment_transitions(beams, state, chars, index, beam_width)
        push_dictionary_transitions(beams, state, dictionary, chars, index, opts)
        push_beam(beams, index + 1, {
          cost = state.cost + fallback_char_cost(chars[index]),
          out = copy_append(state.out, chars[index]),
          changed = state.changed,
        }, beam_width)
      end
    end
  end

  local final_beam = prune_beam(beams[#chars + 1] or {}, beam_width)
  table.sort(final_beam, function(a, b)
    local a_text = table.concat(a.out)
    local b_text = table.concat(b.out)
    local a_cost = a.cost - preferred_text_bonus(a_text)
    local b_cost = b.cost - preferred_text_bonus(b_text)
    if a_cost ~= b_cost then
      return a_cost < b_cost
    end
    return a_text < b_text
  end)

  local candidates = {}
  local seen = {}
  for _, state in ipairs(final_beam) do
    local candidate = table.concat(state.out)
    if state.changed and candidate ~= kana and not seen[candidate] then
      candidates[#candidates + 1] = candidate
      seen[candidate] = true
      if #candidates >= max_items then
        break
      end
    end
  end

  return candidates
end

local suspicious_candidate_fragments = {
  "に本",
  "日本ご",
  "二本ご",
  "木型べ",
  "や木型",
}

local function suspicious_candidate_penalty(candidate)
  local penalty = 0
  for _, fragment in ipairs(suspicious_candidate_fragments) do
    if candidate:find(fragment, 1, true) then
      penalty = penalty + 20
    end
  end
  return penalty
end

local function rank_dictionary_candidates(candidates, max_items)
  local ranked = {}
  local has_unsuspicious_candidate = false
  for index, candidate in ipairs(candidates) do
    local suspicious_penalty = suspicious_candidate_penalty(candidate)
    if suspicious_penalty == 0 then
      has_unsuspicious_candidate = true
    end
    ranked[#ranked + 1] = {
      index = index,
      candidate = candidate,
      suspicious = suspicious_penalty > 0,
      score = suspicious_penalty - preferred_text_bonus(candidate),
    }
  end

  table.sort(ranked, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    return a.index < b.index
  end)

  local out = {}
  for _, item in ipairs(ranked) do
    if not (has_unsuspicious_candidate and item.suspicious) then
      out[#out + 1] = item.candidate
    end
    if max_items and #out >= max_items then
      break
    end
  end
  return out
end

local function dictionary_candidates(kana, dictionary, max_items, opts)
  opts = opts or {}
  local min_partial_reading_length = opts.min_partial_reading_length or 3
  local chars = completion_utils.split_chars(kana)
  local candidates = {}
  local seen = {}

  for _, candidate in ipairs(dictionary.map[kana] or {}) do
    if candidate ~= kana and not seen[candidate] then
      candidates[#candidates + 1] = candidate
      seen[candidate] = true
      if #candidates >= max_items then
        return rank_dictionary_candidates(candidates, max_items)
      end
    end
  end

  for _, candidate in ipairs(viterbi_dictionary_candidates(kana, dictionary, max_items - #candidates, opts)) do
    if not seen[candidate] then
      candidates[#candidates + 1] = candidate
      seen[candidate] = true
      if #candidates >= max_items then
        return rank_dictionary_candidates(candidates, max_items)
      end
    end
  end

  local greedy = greedy_dictionary_candidate(kana, dictionary, min_partial_reading_length)
  if greedy and greedy ~= kana and not seen[greedy] then
    candidates[#candidates + 1] = greedy
    seen[greedy] = true
  end

  for i = 1, #chars do
    local match = best_match_at(dictionary, chars, i, min_partial_reading_length)
    if match then
      local before = join_chars(chars, 1, i - 1)
      local after = join_chars(chars, i + #match.chars, #chars)
      for _, candidate in ipairs(match.candidates) do
        local converted = before .. candidate .. after
        if converted ~= kana and not seen[converted] then
          candidates[#candidates + 1] = converted
          seen[converted] = true
          if #candidates >= max_items then
            return rank_dictionary_candidates(candidates, max_items)
          end
        end
      end
    end
  end

  return rank_dictionary_candidates(candidates, max_items)
end

local function response(items, opts)
  opts = opts or {}
  return {
    items = items,
    is_incomplete_forward = opts.is_incomplete_forward == true,
    is_incomplete_backward = opts.is_incomplete_backward == true,
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

local function item_filter_text(ctx, prefix)
  local text = line_to_cursor(ctx)
  if prefix == "" or #text < #prefix or text:sub(#text - #prefix + 1) ~= prefix then
    return prefix
  end

  local before = text:sub(1, #text - #prefix)
  local japanese_prefix = completion_utils.extract_trailing_japanese(before)
  if japanese_prefix == "" then
    return prefix
  end

  return japanese_prefix .. prefix
end

local function add_item(items, seen, ctx, prefix, label, detail, rank)
  if label == "" or seen[label] then
    return
  end

  seen[label] = true
  items[#items + 1] = {
    label = label,
    filterText = item_filter_text(ctx, prefix),
    sortText = ("%04d:%s"):format(rank, label),
    kind = text_completion_kind(),
    kind_name = "text",
    detail = detail,
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
end

local function add_item_variants(items, seen, ctx, prefix, label, detail, rank, suffixes)
  if type(suffixes) ~= "table" or #suffixes == 0 then
    add_item(items, seen, ctx, prefix, label, detail, rank)
    return rank + 1
  end

  for _, suffix in ipairs(suffixes) do
    add_item(items, seen, ctx, prefix, label .. suffix, detail, rank)
    rank = rank + 1
  end
  return rank
end

local function add_dictionary_items(items, seen, ctx, prefix, kana, dictionary, opts, rank, suffixes)
  local remaining = math.max(0, opts.max_items - #items)
  if remaining <= 0 then
    return rank
  end

  for _, candidate in ipairs(dictionary_candidates(kana, dictionary, remaining, opts)) do
    rank = add_item_variants(items, seen, ctx, prefix, candidate, "[dict]", rank, suffixes)
    if #items >= opts.max_items then
      break
    end
  end

  return rank
end

local function now_ms()
  if uv and uv.now then
    return uv.now()
  end
  return math.floor(os.time() * 1000)
end

local function llm_options(opts)
  return type(opts) == "table" and type(opts.llm) == "table" and opts.llm or {}
end

local function llm_available(opts)
  local llm = llm_options(opts)
  return llm.enabled == true
    and type(llm.endpoint) == "string"
    and llm.endpoint ~= ""
    and now_ms() >= llm_unavailable_until
    and vim.fn.executable("curl") == 1
end

local function build_llm_payload(prefix, kana, opts, hints)
  local llm = llm_options(opts)
  local current_request = {
    "romaji: " .. prefix,
    "reading: " .. kana,
  }

  if type(hints) == "table" and #hints > 0 then
    current_request[#current_request + 1] = "dictionary hints:"
    for _, hint in ipairs(hints) do
      current_request[#current_request + 1] = "- " .. hint
    end
    current_request[#current_request + 1] =
      "Use the hints only if they fit the reading. Prefer the most natural full-sentence candidate."
  end

  current_request[#current_request + 1] = "answer:"

  return {
    model = llm.model or "romaji-ja",
    messages = {
      {
        role = "system",
        content = table.concat({
          "You are a Japanese kana-kanji IME conversion engine.",
          "The hiragana reading is already provided, so do not merely transliterate it.",
          "Return natural Japanese conversion candidates for an IME menu.",
          "Every candidate must match the given reading exactly.",
          "Never output text for a different reading.",
          "Prefer common kanji for nouns, verbs, adjectives, and technical terms.",
          "Keep particles and auxiliary endings in kana.",
          "The first candidate should contain kanji unless no natural kanji exists.",
          "Kana-only candidates are allowed only after kanji-mixed candidates.",
          "If dictionary hints are provided, use them as candidate material and improve kana-only words to common kanji.",
          "Return exactly one compact JSON array of 1 to 5 strings.",
          "Do not return markdown or explanation.",
        }, " "),
      },
      {
        role = "user",
        content = table.concat(current_request, "\n"),
      },
    },
    temperature = llm.temperature or 0.1,
    top_p = llm.top_p or 0.8,
    max_tokens = llm.max_tokens or 96,
    stream = false,
  }
end

local function collect_strings(value, out)
  if type(value) == "string" then
    out[#out + 1] = value
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      collect_strings(item, out)
    end
  end
end

local function parse_llm_candidates(text)
  local candidates = {}
  if type(text) ~= "string" or text == "" then
    return candidates
  end

  local ok, decoded = pcall(vim.fn.json_decode, text)
  if ok then
    collect_strings(decoded, candidates)
  else
    for quoted in text:gmatch([["([^"]+)"]]) do
      candidates[#candidates + 1] = quoted
    end
  end

  return candidates
end

local function candidate_too_short_for_reading(candidate, kana)
  local kana_len = char_count(kana)
  if kana_len < 12 then
    return false
  end

  local candidate_len = char_count(candidate)
  return candidate_len <= 4 or (kana_len >= 20 and candidate_len < math.floor(kana_len * 0.35))
end

local function prioritize_llm_candidates(candidates, kana, max_items)
  local kanji_candidates = {}
  local other_candidates = {}

  for _, candidate in ipairs(candidates) do
    if not candidate_too_short_for_reading(candidate, kana) then
      if has_kanji(candidate) then
        kanji_candidates[#kanji_candidates + 1] = candidate
      else
        other_candidates[#other_candidates + 1] = candidate
      end
    end
  end

  local prioritized = {}
  vim.list_extend(prioritized, kanji_candidates)
  vim.list_extend(prioritized, other_candidates)

  while #prioritized > max_items do
    table.remove(prioritized)
  end

  return prioritized
end

local function llm_candidates_from_response(stdout, kana, max_items)
  local ok, decoded = pcall(vim.fn.json_decode, stdout or "")
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  local choice = type(decoded.choices) == "table" and decoded.choices[1] or nil
  local message = type(choice) == "table" and choice.message or nil
  local content = type(message) == "table" and message.content or nil

  local candidates = {}
  local seen = {}
  for _, candidate in ipairs(parse_llm_candidates(content)) do
    candidate = trim(candidate)
    if candidate ~= "" and completion_utils.has_japanese(candidate) and not seen[candidate] then
      candidates[#candidates + 1] = candidate
      seen[candidate] = true
    end
  end

  return prioritize_llm_candidates(candidates, kana, max_items)
end

local function merge_llm_candidates(kana, max_items, ...)
  local candidates = {}
  local seen = {}

  for _, list in ipairs({ ... }) do
    for _, candidate in ipairs(list or {}) do
      candidate = trim(candidate)
      if candidate ~= "" and completion_utils.has_japanese(candidate) and not seen[candidate] then
        candidates[#candidates + 1] = candidate
        seen[candidate] = true
      end
    end
  end

  return prioritize_llm_candidates(candidates, kana, max_items)
end

local function request_llm_candidates(prefix, kana, opts, hints, on_done)
  if not llm_available(opts) then
    return function() end
  end

  local llm = llm_options(opts)
  local timeout_seconds = tostring(math.max(1, (llm.timeout_ms or 2500) / 1000))
  local cancelled = false
  local job = vim.system({
    "curl",
    "-fsS",
    "--max-time",
    timeout_seconds,
    "-H",
    "Content-Type: application/json",
    "--data-binary",
    vim.fn.json_encode(build_llm_payload(prefix, kana, opts, hints)),
    llm.endpoint,
  }, { text = true }, function(result)
    vim.schedule(function()
      if cancelled then
        return
      end

      if result.code ~= 0 then
        llm_unavailable_until = now_ms() + (llm.backoff_ms or 5000)
        return
      end

      local max_items = llm.max_items or 5
      local response_candidates = llm_candidates_from_response(result.stdout, kana, max_items * 2)
      on_done(merge_llm_candidates(kana, max_items, hints, response_candidates))
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

local function add_hint(hints, seen, hint, max_hints)
  if hint == nil or hint == "" or seen[hint] then
    return
  end

  hints[#hints + 1] = hint
  seen[hint] = true

  while #hints > max_hints do
    table.remove(hints)
  end
end

local function builtin_greedy_hint(kana)
  local map = {}
  seed_builtin_dictionary(map, { use_builtin_dictionary = true })
  return greedy_dictionary_candidate(kana, build_dictionary_index(map), 3)
end

local function llm_dictionary_hints(kana, dictionary, opts)
  local llm = llm_options(opts)
  local max_hints = llm.max_hints or 8
  if max_hints <= 0 then
    return {}
  end

  local hints = {}
  local seen = {}
  add_hint(hints, seen, builtin_greedy_hint(kana), max_hints)

  if not dictionary or #hints >= max_hints then
    return hints
  end

  local hint_opts = vim.tbl_extend("force", opts, {
    min_partial_reading_length = llm.min_partial_reading_length or opts.min_partial_reading_length or 4,
  })
  for _, hint in ipairs(dictionary_candidates(kana, dictionary, max_hints, hint_opts)) do
    add_hint(hints, seen, hint, max_hints)
  end

  return hints
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

  if extract_punctuation(ctx, opts) then
    return "punctuation"
  end

  local prefix, suffix_char = extract_romaji_punctuation(ctx, opts)
  prefix = prefix or extract_prefix(ctx)
  if prefix == "" or #prefix < opts.min_keyword_length or romaji_to_hiragana(prefix) == nil then
    return nil
  end

  if suffix_char ~= nil then
    return "romaji_punctuation"
  end

  local text = line_to_cursor(ctx)
  local before = text:sub(1, #text - #prefix)
  if completion_utils.extract_trailing_japanese(before) ~= "" then
    return "romaji_after_japanese"
  end

  return "romaji"
end

function source:get_trigger_characters()
  local chars = vim.tbl_keys(punctuation_candidates(self.opts))
  table.sort(chars)
  return chars
end

function source:get_completions(ctx, callback)
  local punctuation, punctuation_items = extract_punctuation(ctx, self.opts)
  if punctuation then
    local items = {}
    local seen = {}
    for rank, label in ipairs(punctuation_items) do
      add_item(items, seen, ctx, punctuation, label, "[punct]", rank)
    end
    callback(response(items, { is_incomplete_forward = true, is_incomplete_backward = true }))
    return function() end
  end

  local prefix, suffix_char, suffixes = extract_romaji_punctuation(ctx, self.opts)
  local item_prefix = prefix and (prefix .. suffix_char) or nil
  prefix = prefix or extract_prefix(ctx)
  item_prefix = item_prefix or prefix
  if prefix == "" or #prefix < self.opts.min_keyword_length then
    local should_refetch_forward = prefix ~= "" or is_after_japanese_text(ctx)
    callback(response({}, { is_incomplete_forward = should_refetch_forward, is_incomplete_backward = prefix ~= "" }))
    return function() end
  end

  local kana = romaji_to_hiragana(prefix)
  if not kana or kana == "" or not completion_utils.has_japanese(kana) then
    callback(response({}, { is_incomplete_forward = true, is_incomplete_backward = true }))
    return function() end
  end

  local items = {}
  local seen = {}
  local rank = 1

  add_item_variants(items, seen, ctx, item_prefix, kana, "[kana]", 9000, suffixes)

  local cancelled = false
  local cancel_llm = function() end
  local llm_started = false

  local function start_llm(loaded_dictionary, base_seen, base_rank)
    if cancelled or llm_started then
      return
    end
    llm_started = true

    local hints = llm_dictionary_hints(kana, loaded_dictionary, self.opts)

    cancel_llm = request_llm_candidates(prefix, kana, self.opts, hints, function(candidates)
      if cancelled then
        return
      end

      local llm_items = {}
      local llm_seen = vim.deepcopy(base_seen or seen)
      local llm_rank = (base_rank or rank) + 100
      for _, candidate in ipairs(candidates) do
        llm_rank = add_item_variants(llm_items, llm_seen, ctx, item_prefix, candidate, "[llm]", llm_rank, suffixes)
        if #llm_items >= self.opts.max_items then
          break
        end
      end

      if #llm_items > 0 then
        callback(response(llm_items, { is_incomplete_forward = true, is_incomplete_backward = true }))
      end
    end)
  end

  local dictionary, cancel_load = request_dictionary(self.opts, function(loaded_dictionary)
    if cancelled then
      return
    end

    local dict_items = {}
    local dict_seen = vim.deepcopy(seen)
    local dict_rank =
      add_dictionary_items(dict_items, dict_seen, ctx, item_prefix, kana, loaded_dictionary, self.opts, rank, suffixes)
    callback(response(dict_items, { is_incomplete_forward = true, is_incomplete_backward = true }))
    start_llm(loaded_dictionary, dict_seen, dict_rank)
  end)

  if dictionary then
    rank = add_dictionary_items(items, seen, ctx, item_prefix, kana, dictionary, self.opts, rank, suffixes)
  end

  if should_offer_katakana(prefix, kana, self.opts) and #items < self.opts.max_items then
    add_item_variants(items, seen, ctx, item_prefix, hiragana_to_katakana(kana), "[katakana]", rank, suffixes)
  end

  if dictionary then
    start_llm(dictionary, seen, rank)
  end

  callback(response(items, { is_incomplete_forward = true, is_incomplete_backward = true }))
  return function()
    cancelled = true
    if cancel_load then
      cancel_load()
    end
    if cancel_llm then
      cancel_llm()
    end
  end
end

function source:reload()
  clear_dictionary_cache()
end

function source.is_completion_context(ctx, opts)
  return completion_context_kind(ctx, opts) ~= nil
end

local function registry_lines(registry_path)
  registry_path = expand_dictionary_path(registry_path or default_registry_path())
  if registry_path == "" or vim.fn.filereadable(registry_path) ~= 1 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, registry_path)
  if not ok then
    return {}
  end
  return lines
end

local function write_registry_lines(registry_path, lines)
  registry_path = expand_dictionary_path(registry_path or default_registry_path())
  vim.fn.mkdir(vim.fn.fnamemodify(registry_path, ":h"), "p")
  return pcall(vim.fn.writefile, lines, registry_path)
end

local function registered_path_set(opts)
  local set = {}
  for _, path in ipairs(read_registry_paths(opts.dictionary_registry_path)) do
    set[expand_dictionary_path(path)] = true
  end
  return set
end

local function active_path_set(opts)
  local set = {}
  for _, path in ipairs(effective_dictionary_paths(opts)) do
    set[expand_dictionary_path(path)] = true
  end
  return set
end

local function add_registered_dictionary_path(path, opts)
  opts = default_opts(opts)
  local expanded = expand_dictionary_path(path)
  if expanded == "" then
    return false, "path is empty"
  end
  if vim.fn.filereadable(expanded) ~= 1 then
    return false, ("not readable: %s"):format(expanded)
  end

  if active_path_set(opts)[expanded] then
    return true, ("already active: %s"):format(expanded)
  end

  local lines = registry_lines(opts.dictionary_registry_path)
  if registered_path_set(opts)[expanded] then
    return true, ("already registered: %s"):format(expanded)
  end

  lines[#lines + 1] = expanded
  local ok, err = write_registry_lines(opts.dictionary_registry_path, lines)
  if not ok then
    return false, tostring(err)
  end

  clear_dictionary_cache()
  return true, ("added: %s"):format(expanded)
end

local function command_list(opts)
  local lines = {}
  for _, path in ipairs(effective_dictionary_paths(opts)) do
    local marker = vim.fn.filereadable(path) == 1 and "ok" or "missing"
    lines[#lines + 1] = ("[%s] %s"):format(marker, path)
  end

  if #lines == 0 then
    notify("no dictionary paths")
  else
    notify(table.concat(lines, "\n"))
  end
end

local function elapsed_ms(started_at)
  if not started_at or not uv then
    return nil
  end
  return math.floor((uv.hrtime() - started_at) / 1000000)
end

local function command_status(opts)
  local state = current_dictionary_state(opts)
  if not state then
    notify("dictionary: idle")
    return
  end

  local lines = {
    "status: " .. state.status,
    "paths: " .. tostring(#(state.paths or {})),
    "lines: " .. tostring(state.line_count or 0),
    "entries: " .. tostring(state.entry_count or 0),
  }

  local ms = elapsed_ms(state.started_at)
  if ms then
    lines[#lines + 1] = "elapsed_ms: " .. tostring(ms)
  end
  if state.current_path then
    lines[#lines + 1] = "current: " .. state.current_path
  end
  if state.errors and #state.errors > 0 then
    lines[#lines + 1] = "errors:"
    vim.list_extend(lines, state.errors)
  end

  notify(table.concat(lines, "\n"))
end

local function run_system(args, on_done)
  if vim.fn.executable(args[1]) ~= 1 then
    on_done(false, ("%s is not executable"):format(args[1]))
    return
  end

  vim.system(args, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        on_done(true)
      else
        local stderr = result.stderr or ""
        local stdout = result.stdout or ""
        on_done(false, trim(stderr ~= "" and stderr or stdout))
      end
    end)
  end)
end

local function llm_health_url(opts)
  local endpoint = llm_options(opts).endpoint
  if type(endpoint) == "string" and endpoint ~= "" then
    local health = endpoint:gsub("/v1/chat/completions$", "/health")
    if health ~= endpoint then
      return health
    end
  end

  local server = llm_options(opts).server or {}
  return ("http://%s:%s/health"):format(server.host or "127.0.0.1", tostring(server.port or 18080))
end

local function llm_server_args(opts)
  local server = llm_options(opts).server or {}
  local args = {
    server.command or "/tmp/llama.cpp/build/bin/llama-server",
    "-m",
    server.model_path or "/tmp/Qwen3-0.6B-Q4_0.gguf",
    "--host",
    server.host or "127.0.0.1",
    "--port",
    tostring(server.port or 18080),
    "--ctx-size",
    tostring(server.ctx_size or 2048),
    "--threads",
    tostring(server.threads or 4),
    "--parallel",
    tostring(server.parallel or 1),
    "--reasoning",
    server.reasoning or "off",
    "--no-webui",
    "--alias",
    llm_options(opts).model or "romaji-ja",
  }

  return args
end

local function check_llm_health(opts, on_done)
  if vim.fn.executable("curl") ~= 1 then
    on_done(false, "curl is not executable")
    return
  end

  vim.system({ "curl", "-fsS", "--max-time", "1", llm_health_url(opts) }, { text = true }, function(result)
    vim.schedule(function()
      local stderr = result.stderr or ""
      local stdout = result.stdout or ""
      on_done(result.code == 0, trim(stderr ~= "" and stderr or stdout))
    end)
  end)
end

local function command_llm_status(opts)
  opts = default_opts(opts)
  check_llm_health(opts, function(ok, message)
    if ok then
      notify("llm: running")
    else
      notify("llm: stopped" .. (message ~= "" and ("\n" .. message) or ""))
    end
  end)
end

local function command_llm_start(opts)
  opts = default_opts(opts)
  local args = llm_server_args(opts)

  if vim.fn.executable(args[1]) ~= 1 then
    notify(("not executable: %s"):format(args[1]), vim.log.levels.ERROR)
    return
  end
  if vim.fn.filereadable(args[3]) ~= 1 then
    notify(("model not readable: %s"):format(args[3]), vim.log.levels.ERROR)
    return
  end

  check_llm_health(opts, function(ok)
    if ok then
      notify("llm: already running")
      return
    end

    llm_unavailable_until = 0
    llm_server_job_id = vim.fn.jobstart(args, {
      detach = false,
      stdout_buffered = false,
      stderr_buffered = false,
      on_exit = function(_, code)
        if llm_server_job_id ~= nil then
          llm_server_job_id = nil
          vim.schedule(function()
            if code ~= 0 then
              notify(("llm: exited (%s)"):format(tostring(code)), vim.log.levels.WARN)
            end
          end)
        end
      end,
    })

    if type(llm_server_job_id) ~= "number" or llm_server_job_id <= 0 then
      notify("llm: failed to start", vim.log.levels.ERROR)
      llm_server_job_id = nil
      return
    end

    notify("llm: starting")
  end)
end

local function command_llm_stop()
  llm_unavailable_until = 0
  if llm_server_job_id == nil then
    notify("llm: no tracked server job")
    return
  end

  vim.fn.jobstop(llm_server_job_id)
  llm_server_job_id = nil
  notify("llm: stopping")
end

local function command_llm_restart(opts)
  local had_job = llm_server_job_id ~= nil
  if had_job then
    vim.fn.jobstop(llm_server_job_id)
    llm_server_job_id = nil
  end

  vim.defer_fn(function()
    command_llm_start(opts)
  end, had_job and 500 or 0)
end

local function dictionary_destination(kind)
  local spec = skk_downloads[kind]
  if not spec then
    return nil, nil, ("unknown dictionary: %s"):format(tostring(kind))
  end

  local dir = dict_dir()
  return dir .. "/" .. spec.filename, spec, nil
end

local function download_dictionary(kind, opts, on_done)
  opts = default_opts(opts)
  local destination, spec, err = dictionary_destination(kind)
  if err then
    on_done(false, err)
    return
  end

  vim.fn.mkdir(vim.fn.fnamemodify(destination, ":h"), "p")
  local gz_path = destination .. ".gz"
  local utf8_path = destination .. ".utf8"
  notify(("downloading %s..."):format(spec.filename))

  run_system({ "curl", "-fL", spec.url, "-o", gz_path }, function(ok, err)
    if not ok then
      on_done(false, err)
      return
    end

    run_system({ "gunzip", "-f", gz_path }, function(gunzip_ok, gunzip_err)
      if not gunzip_ok then
        on_done(false, gunzip_err)
        return
      end

      run_system({ "iconv", "-f", "EUC-JP", "-t", "UTF-8", destination, "-o", utf8_path }, function(iconv_ok, iconv_err)
        if not iconv_ok then
          on_done(false, iconv_err)
          return
        end

        local rename_ok, rename_err = os.rename(utf8_path, destination)
        if not rename_ok then
          on_done(false, tostring(rename_err))
          return
        end

        local add_ok, add_message = add_registered_dictionary_path(destination, opts)
        clear_dictionary_cache()
        on_done(add_ok, add_message, destination)
      end)
    end)
  end)
end

local function ensure_dictionary(kind, opts, on_done)
  opts = default_opts(opts)
  local destination, _, err = dictionary_destination(kind)
  if err then
    on_done(false, err)
    return
  end

  if vim.fn.filereadable(destination) == 1 then
    local ok, message = add_registered_dictionary_path(destination, opts)
    clear_dictionary_cache()
    on_done(ok, message, destination)
    return
  end

  download_dictionary(kind, opts, on_done)
end

local function preload_dictionary(opts, on_done)
  local dictionary, cancel = request_dictionary(opts, function(_, state)
    on_done(state)
  end)

  if dictionary then
    if cancel then
      cancel()
    end
    on_done(current_dictionary_state(opts))
  end
end

local function command_download(kind, opts)
  opts = default_opts(opts)
  if type(kind) ~= "string" or kind == "" then
    kind = "ML"
  end

  download_dictionary(kind, opts, function(ok, message)
    notify(message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

local function command_init(kinds, opts)
  opts = default_opts(opts)
  if type(kinds) ~= "table" or #kinds == 0 then
    kinds = opts.init_dictionary_kinds or default_init_dictionary_kinds
  end

  local errors = {}
  local configured = {}
  local normalized_kinds = {}
  for _, kind in ipairs(kinds) do
    if skk_downloads[kind] then
      normalized_kinds[#normalized_kinds + 1] = kind
    else
      errors[#errors + 1] = ("unknown dictionary: %s"):format(tostring(kind))
    end
  end

  if #normalized_kinds == 0 then
    notify(table.concat(errors, "\n"), vim.log.levels.ERROR)
    return
  end

  notify(("initializing dictionaries: %s"):format(table.concat(normalized_kinds, ", ")))

  local function finish()
    clear_dictionary_cache()
    preload_dictionary(opts, function(state)
      local lines = {
        #errors == 0 and "init complete" or "init finished with errors",
        "recommended: " .. table.concat(normalized_kinds, ", "),
        "configured: " .. tostring(#configured),
      }

      if state then
        lines[#lines + 1] = "entries: " .. tostring(state.entry_count or 0)
      end
      if #errors > 0 then
        lines[#lines + 1] = "errors:"
        vim.list_extend(lines, errors)
      end

      notify(table.concat(lines, "\n"), #errors == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  end

  local function init_next(index)
    if index > #normalized_kinds then
      finish()
      return
    end

    local kind = normalized_kinds[index]
    ensure_dictionary(kind, opts, function(ok, message, path)
      if ok then
        configured[#configured + 1] = path or kind
        notify(("%s: %s"):format(kind, message))
      else
        errors[#errors + 1] = ("%s: %s"):format(kind, message)
        notify(("%s: %s"):format(kind, message), vim.log.levels.ERROR)
      end
      init_next(index + 1)
    end)
  end

  init_next(1)
end

local function dict_command_complete(arg_lead, cmdline)
  local args = vim.split(cmdline, "%s+", { trimempty = true })
  local subcommands = { "add", "download", "init", "list", "reload", "status" }
  if #args <= 1 or (#args == 2 and cmdline:sub(-1) ~= " ") or (cmdline:sub(-1) == " " and #args == 1) then
    return vim.tbl_filter(function(command)
      return vim.startswith(command, arg_lead)
    end, subcommands)
  end

  if args[2] == "download" or args[2] == "init" then
    local kinds = vim.tbl_keys(skk_downloads)
    table.sort(kinds)
    return vim.tbl_filter(function(kind)
      return vim.startswith(kind, arg_lead)
    end, kinds)
  end

  if args[2] == "add" then
    return vim.fn.getcompletion(arg_lead, "file")
  end

  return {}
end

local function llm_command_complete(arg_lead)
  local subcommands = { "restart", "start", "status", "stop" }
  return vim.tbl_filter(function(command)
    return vim.startswith(command, arg_lead)
  end, subcommands)
end

local function handle_dict_command(cmd_opts, opts)
  opts = default_opts(opts)
  local subcommand = cmd_opts.fargs[1] or "status"

  if subcommand == "add" then
    local path_parts = {}
    for i = 2, #cmd_opts.fargs do
      path_parts[#path_parts + 1] = cmd_opts.fargs[i]
    end
    local path = table.concat(path_parts, " ")
    if path == "" then
      notify("usage: RomajiJapaneseDict add {path}", vim.log.levels.ERROR)
      return
    end
    local ok, message = add_registered_dictionary_path(path, opts)
    notify(message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  elseif subcommand == "download" then
    command_download(cmd_opts.fargs[2] or "ML", opts)
  elseif subcommand == "init" then
    local kinds = {}
    for i = 2, #cmd_opts.fargs do
      kinds[#kinds + 1] = cmd_opts.fargs[i]
    end
    command_init(kinds, opts)
  elseif subcommand == "list" then
    command_list(opts)
  elseif subcommand == "reload" then
    clear_dictionary_cache()
    notify("dictionary cache cleared")
  elseif subcommand == "status" then
    command_status(opts)
  else
    notify("unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
  end
end

local function handle_llm_command(cmd_opts, opts)
  opts = default_opts(opts)
  local subcommand = cmd_opts.fargs[1] or "status"

  if subcommand == "restart" then
    command_llm_restart(opts)
  elseif subcommand == "start" then
    command_llm_start(opts)
  elseif subcommand == "status" then
    command_llm_status(opts)
  elseif subcommand == "stop" then
    command_llm_stop()
  else
    notify("unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
  end
end

function source.setup_commands(opts)
  opts = default_opts(opts)
  pcall(vim.api.nvim_del_user_command, "RomajiJapaneseDict")
  vim.api.nvim_create_user_command("RomajiJapaneseDict", function(cmd_opts)
    handle_dict_command(cmd_opts, opts)
  end, {
    nargs = "*",
    complete = dict_command_complete,
    desc = "Manage romaji Japanese completion dictionaries",
  })

  pcall(vim.api.nvim_del_user_command, "RomajiJapaneseLLM")
  vim.api.nvim_create_user_command("RomajiJapaneseLLM", function(cmd_opts)
    handle_llm_command(cmd_opts, opts)
  end, {
    nargs = "*",
    complete = llm_command_complete,
    desc = "Manage romaji Japanese completion LLM server",
  })
end

function source.clear_cache()
  clear_dictionary_cache()
end

function source.status(opts)
  return current_dictionary_state(opts)
end

source._test = {
  romaji_to_hiragana = romaji_to_hiragana,
  hiragana_to_katakana = hiragana_to_katakana,
  normalize_reading = normalize_reading,
  load_dictionary_sync = load_dictionary_sync_for_test,
  parse_llm_candidates = parse_llm_candidates,
  llm_candidates_from_response = llm_candidates_from_response,
}

return source
