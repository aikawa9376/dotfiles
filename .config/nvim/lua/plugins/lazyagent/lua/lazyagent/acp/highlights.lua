local M = {}

function M.setup()
  local defs = {
    GitExtAdd = { default = true, bg = "#23384C" },
    GitExtDelete = { default = true, bg = "#321e1e" },
    GitExtAddText = { default = true, bg = "#005f5f" },
    GitExtDeleteText = { default = true, bg = "#8c3b40" },
    LazyAgentACPUserHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPAssistantHeader = { default = true, fg = "#9ece6a", bold = true },
    LazyAgentACPThinkingHeader = { default = true, fg = "#bb9af7", bold = true },
    LazyAgentACPSystemHeader = { default = true, fg = "#7dcfff", bold = true },
    LazyAgentACPErrorHeader = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPPlanHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPToolHeader = { default = true, fg = "#7aa2f7", bold = true },
    LazyAgentACPTerminalHeader = { default = true, fg = "#73daca", bold = true },
    LazyAgentACPPinIcon = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPBorder = { default = true, link = "FloatBorder" },
    LazyAgentACPFooterActive = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPFooterWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPFooterError = { default = true, link = "DiagnosticError" },
    LazyAgentACPFooterMuted = { default = true, link = "Comment" },
    LazyAgentACPFooterMeta = { default = true, link = "SpecialComment" },
    LazyAgentACPCardTitle = { default = true, link = "Title" },
    LazyAgentACPCardField = { default = true, link = "Identifier" },
    LazyAgentACPDiffDelete = { default = true, link = "GitExtDelete" },
    LazyAgentACPDiffAdd = { default = true, link = "GitExtAdd" },
    LazyAgentACPDiffDeleteWord = { default = true, link = "GitExtDeleteText" },
    LazyAgentACPDiffAddWord = { default = true, link = "GitExtAddText" },
  }

  for name, spec in pairs(defs) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

return M
