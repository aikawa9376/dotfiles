local M = {}

function M.is_ascii(text)
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

function M.codepoint(char)
  return vim.fn.char2nr(char)
end

function M.split_chars(text)
  if type(text) ~= "string" or text == "" then
    return {}
  end

  return vim.fn.split(text, [[\zs]])
end

function M.is_hiragana_cp(cp)
  return (cp >= 0x3041 and cp <= 0x3096) or cp == 0x309D or cp == 0x309E
end

function M.is_katakana_cp(cp)
  return (cp >= 0x30A1 and cp <= 0x30FA)
    or cp == 0x30FC
    or cp == 0x30FD
    or cp == 0x30FE
    or cp == 0x30F5
    or cp == 0x30F6
end

function M.is_kanji_cp(cp)
  return cp == 0x3005
    or cp == 0x3006
    or (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0xF900 and cp <= 0xFAFF)
end

function M.is_japanese_cp(cp)
  return M.is_hiragana_cp(cp) or M.is_katakana_cp(cp) or M.is_kanji_cp(cp)
end

function M.has_japanese(text)
  for _, char in ipairs(M.split_chars(text)) do
    if M.is_japanese_cp(M.codepoint(char)) then
      return true
    end
  end

  return false
end

function M.extract_trailing_japanese(text)
  local chars = M.split_chars(text)
  local trailing = {}

  for i = #chars, 1, -1 do
    if not M.is_japanese_cp(M.codepoint(chars[i])) then
      break
    end

    table.insert(trailing, 1, chars[i])
  end

  return table.concat(trailing)
end

return M
