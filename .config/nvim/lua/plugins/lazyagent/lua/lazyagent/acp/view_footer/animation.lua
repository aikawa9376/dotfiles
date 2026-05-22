local M = {}

local FOOTER_GRADIENT_STEPS = 8
local DEFAULT_FOOTER_ACTIVE_FG = 0x7dcfff
local DEFAULT_FOOTER_BG = 0x1a1b26
local FOOTER_INFO_HL = "LazyAgentACPFooterInfo"
local CHAR_SPLIT_CACHE_LIMIT = 64

function M.new(ctx)
  local state = ctx.state
  local footer_animation_frame = 0
  local footer_gradient_key = nil
  local footer_gradient_groups = {}
  local footer_info_key = nil
  local char_split_cache = {}
  local char_split_cache_count = 0

  local api = {}

  function api.enabled(session)
    if session and session.footer_animation ~= nil then
      return session.footer_animation == true
    end

    local acp = state and state.opts and state.opts.acp
    if type(acp) == "table" and acp.footer_animation ~= nil then
      return acp.footer_animation == true
    end

    return true
  end

  function api.strdisplaywidth(text)
    local ok, width = pcall(vim.fn.strdisplaywidth, text)
    return ok and width or #tostring(text or "")
  end

  local function highlight_spec(name)
    local ok, spec = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and type(spec) == "table" and spec or nil
  end

  local function highlight_color(name, attr)
    local spec = highlight_spec(name)
    return spec and spec[attr] or nil
  end

  function api.ensure_info_highlights()
    local meta_spec = highlight_spec("LazyAgentACPFooterMeta") or highlight_spec("SpecialComment") or {}
    local info_fg = meta_spec.fg
      or highlight_color("SpecialComment", "fg")
      or highlight_color("DiagnosticInfo", "fg")
      or highlight_color("Normal", "fg")
      or DEFAULT_FOOTER_ACTIVE_FG
    local key = table.concat({
      tostring(info_fg),
      meta_spec.bold and "bold" or "",
      meta_spec.italic and "italic" or "",
      meta_spec.underline and "underline" or "",
    }, ":")

    if footer_info_key ~= key then
      footer_info_key = key
      local text_spec = vim.deepcopy(meta_spec)
      text_spec.link = nil
      text_spec.default = nil
      text_spec.fg = info_fg
      text_spec.bg = nil
      text_spec.ctermfg = nil
      text_spec.ctermbg = nil
      pcall(vim.api.nvim_set_hl, 0, FOOTER_INFO_HL, text_spec)
    end

    return FOOTER_INFO_HL
  end

  local function blend_color(from, to, ratio)
    ratio = math.min(1, math.max(0, tonumber(ratio) or 0))
    local from_r = math.floor(from / 0x10000) % 0x100
    local from_g = math.floor(from / 0x100) % 0x100
    local from_b = from % 0x100
    local to_r = math.floor(to / 0x10000) % 0x100
    local to_g = math.floor(to / 0x100) % 0x100
    local to_b = to % 0x100
    local r = math.floor(from_r + (to_r - from_r) * ratio + 0.5)
    local g = math.floor(from_g + (to_g - from_g) * ratio + 0.5)
    local b = math.floor(from_b + (to_b - from_b) * ratio + 0.5)
    return r * 0x10000 + g * 0x100 + b
  end

  local function ensure_gradient_highlights()
    local active_spec = highlight_spec("LazyAgentACPFooterActive") or highlight_spec("DiagnosticInfo") or {}
    local active_fg = active_spec.fg
      or highlight_color("DiagnosticInfo", "fg")
      or highlight_color("Normal", "fg")
      or DEFAULT_FOOTER_ACTIVE_FG
    local normal_bg = highlight_color("Normal", "bg") or DEFAULT_FOOTER_BG
    local key = tostring(active_fg) .. ":" .. tostring(normal_bg)
    if footer_gradient_key == key and #footer_gradient_groups == FOOTER_GRADIENT_STEPS then
      return footer_gradient_groups
    end

    footer_gradient_key = key
    footer_gradient_groups = {}
    for step = 1, FOOTER_GRADIENT_STEPS do
      local group = "LazyAgentACPFooterActiveGradient" .. step
      local ratio = ((step - 1) / math.max(1, FOOTER_GRADIENT_STEPS - 1)) * 0.78
      local spec = vim.deepcopy(active_spec)
      spec.fg = blend_color(active_fg, normal_bg, ratio)
      spec.bg = nil
      spec.link = nil
      spec.default = nil
      spec.ctermfg = nil
      spec.ctermbg = nil
      pcall(vim.api.nvim_set_hl, 0, group, spec)
      footer_gradient_groups[step] = group
    end

    return footer_gradient_groups
  end

  function api.split_chars(text)
    text = tostring(text or "")
    local cached = char_split_cache[text]
    if cached then
      return cached
    end
    local chars = vim.fn.split(text, "\\zs")
    if char_split_cache_count >= CHAR_SPLIT_CACHE_LIMIT then
      char_split_cache = {}
      char_split_cache_count = 0
    end
    char_split_cache[text] = chars
    char_split_cache_count = char_split_cache_count + 1
    return chars
  end

  function api.animated_chunks(text)
    local groups = ensure_gradient_highlights()
    local chars = api.split_chars(text)
    if #chars == 0 then
      return nil
    end

    local wave_size = #groups
    local wave_head = (footer_animation_frame % (#chars + wave_size)) + 1
    local fallback_hl = groups[wave_size] or "LazyAgentACPFooterActive"
    local chunks = {}
    for idx = 1, #chars do
      local distance = wave_head - idx
      local hl = fallback_hl
      if distance >= 0 and distance < wave_size then
        hl = groups[distance + 1] or hl
      end
      chunks[idx] = { chars[idx], hl }
    end
    return chunks
  end

  function api.advance_frame()
    footer_animation_frame = footer_animation_frame + 1
  end

  function api.frame()
    return footer_animation_frame
  end

  return api
end

return M
