vim.opt.termguicolors = true
vim.opt.background = "dark"

local function set_highlight(group, opts)
  vim.api.nvim_set_hl(0, group, opts)
end

local function apply_colorscheme()
  set_highlight("Normal", { fg = "#839496", bg = "None" })
  set_highlight("NormalFloat", { bg = "#002b36" })
  set_highlight("NormalNC", { bg = "#073642" })
  set_highlight("ErrorMsg", { bold = true, fg = "#dc322f" })
  set_highlight("SignColumn", { bg = "None" })
  set_highlight("LineNr", { fg = "#586e75", bg = "None" })
  set_highlight("Comment", { italic = true, fg = "#586e75" })
  set_highlight("QuickFixLine", { bold = true, underline = true })
  set_highlight("StatusLine", { bg = "None" })
  set_highlight("StatusLineNC", { bg = "None" })
  set_highlight("Conceal", { fg = "Grey30" })
  set_highlight("NvimInternalError", { bold = true, fg = "#dc322f" })
  set_highlight("UnderLined", {})
  set_highlight("Todo", { bold = true, fg = "#81a1c1", bg = "None" })
  set_highlight("@text.todo", { bold = true, fg = "#81a1c1", bg = "NONE" })
  set_highlight("@text.note", { bold = true, fg = "#81a1c1", bg = "NONE" })
  set_highlight("@text.warning", { bold = true, fg = "#ebcb8b", bg = "NONE" })
  set_highlight("@text.danger", { bold = true, fg = "#bf616a", bg = "NONE" })
  set_highlight("NonText", { fg = "#2E3440", bg = "None" })
  set_highlight("SpecialKey", { fg = "#2E3440", bg = "NONE" })
  set_highlight("EndOfBuffer", { fg = "#002B36" })
  set_highlight("EWhitespace", { fg = "#586e75" })
  set_highlight("Pmenu", { fg = "#87afff", bg = "#073642" })
  set_highlight("PmenuSbar", { bg = "#073642" })
  set_highlight("PmenuThumb", { bg = "#005f5f" })
  set_highlight("PmenuSel", { fg = "#af0087", bg = "NONE" })
  set_highlight("Fmenu", { fg = "#87afff", bg = "#002b36" })
  set_highlight("Search", { bold = true, underline = true, fg = "#CFC8B8", bg = "None" })
  set_highlight("CurSearch", { bold = true, underline = true, fg = "#b58900", bg = "NONE" })
  set_highlight("IncSearch", { bold = true, underline = true, fg = "#b58900", bg = "NONE" })
  set_highlight("Visual", { bg = "#20436e" })
  set_highlight("CursorLine", { bg = "#073642", special = "#93a1a1" })
  set_highlight("CursorLineNr", { fg = "#93a1a1", bg = "None" })
  set_highlight("GitGutterAdd", { fg = "#98be65" })
  set_highlight("GitGutterChange", { fg = "#FF8800" })
  set_highlight("GitGutterDelete", { fg = "#ec5f67" })
  set_highlight("GitGutterChangeDelete", { fg = "#ec5f67", bg = "NONE" })
  set_highlight("LspDiagnosticsDefaultHint", { fg = "#98be65" })
  set_highlight("LspDiagnosticsDefaultError", { fg = "#ec5f67" })
  set_highlight("LspDiagnosticsDefaultWarning", { fg = "#FF8800", bg = "NONE" })
  set_highlight("LspDiagnosticsDefaultInformation", { fg = "#51afef", bg = "NONE" })
  set_highlight("LspSignatureActiveParameter", { bold = true, underline = true })
  set_highlight("MatchWord", { underline = true })
  set_highlight("MatchParen", { bold = true, underline = true })
  set_highlight("DiffDelete", { fg = "NONE", bg = "#341C28" })
  set_highlight("DiffAdd", { fg = "NONE", bg = "#23384C" })
  set_highlight("DiffChange", { fg = "NONE", bg = "#33406B" })
  set_highlight("DiffText", { fg = "NONE", bg = "#232C4C" })
  set_highlight("DiffviewDiffDelete", { fg = "#094b5c", bg = "NONE" })
  set_highlight("LspReferenceRead", { bold = true, bg = "#073642" })
  set_highlight("LspReferenceText", { bold = true, bg = "#073642" })
  set_highlight("LspReferenceWrite", { bold = true, italic = true, bg = "#073642" })
  set_highlight("LspCodeLens", { fg = "#586e75" })
  set_highlight("LspCodeLensSeparator", { fg = "#586e75" })
  set_highlight("WilderPoppupMenuAccent", { special = "#87afff" })
  set_highlight("WilderPopupMenuSelectedAccent", { special = "#87afff" })
  set_highlight("FidgetTask", { fg = "#586e75" })
  set_highlight("DiagnosticUnderlineError", { undercurl = true, special = "#ec5f67" })
  set_highlight("DiagnosticUnderlineWarn", { undercurl = true, special = "#ECBE7B" })
  set_highlight("DiagnosticUnderlineInfo", { undercurl = true, special = "#008080" })
  set_highlight("DiagnosticUnderlineHint", { undercurl = true, special = "#98be65" })
  set_highlight("DiagnosticError", { fg = "#ec5f67" })
  set_highlight("DiagnosticWarn", { fg = "#ECBE7B" })
  set_highlight("DiagnosticInfo", { fg = "#008080" })
  set_highlight("DiagnosticHint", { fg = "#98be65" })
  set_highlight("RainbowDelimiterRed", { fg = "#d84f76" })
  set_highlight("RainbowDelimiterYellow", { fg = "#e6a852" })
  set_highlight("RainbowDelimiterBlue", { fg = "#4a869c" })
  set_highlight("RainbowDelimiterOrange", { fg = "#d6746f" })
  set_highlight("RainbowDelimiterGreen", { fg = "#8aa872" })
  set_highlight("RainbowDelimiterViolet", { fg = "#d871a6" })
  set_highlight("RainbowDelimiterCyan", { fg = "#7bb8c1" })
  set_highlight("TSNodeKey", { bold = true, underline = true, fg = "#ff2f87" })
  set_highlight("NeoTreeCursorLine", { bold = true })
  set_highlight("NvimSurroundHighlight", { bold = true, fg = "#ff2f87" })
  set_highlight("LspInlayHint", { fg = "#586e75" })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "*",
  callback = apply_colorscheme
})

vim.api.nvim_create_autocmd("FocusGained", {
  pattern = "*",
  callback = function()
    set_highlight("Normal", { bg = "#002b36", fg = "#839496" })
  end
})

vim.api.nvim_create_autocmd("FocusLost", {
  pattern = "*",
  callback = function()
    set_highlight("Normal", { bg = "None", fg = "#839496" })
  end
})

vim.api.nvim_create_autocmd({ "VimEnter", "WinEnter" }, {
  callback = function()
    vim.cmd([[match EWhitespace / \+$/]])
  end
})

vim.opt.winhighlight = "Normal:Normal,NormalNC:NormalNC"
