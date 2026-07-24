local M = {}

local function footer_text(session)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four", "five", "six" })

  local entry = {}
  local namespace = vim.api.nvim_create_namespace("lazyagent_acp_footer_spec_" .. tostring(bufnr))
  local footer = require("lazyagent.acp.view_footer").new({
    footer_ns = namespace,
    agent_logic = { get_visible_slash_commands = function() return {} end },
    state = { opts = {} },
    session_for_agent = function() return session end,
    agent_name_for_bufnr = function() return "Codex" end,
    transcript_line_count = function() return 6 end,
    overlay_target_width = function() return 120 end,
    is_acp_buffer = function() return true end,
    buffer_is_visible = function() return true end,
    layout_entry = function() return entry end,
    footer_padding_count = function() return 0 end,
    set_footer_padding = function() end,
  })

  footer.refresh_footer(bufnr, { force = true })
  local lines = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local chunks = mark[4].virt_text or {}
    local parts = {}
    for _, chunk in ipairs(chunks) do
      parts[#parts + 1] = chunk[1]
    end
    lines[#lines + 1] = table.concat(parts)
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return table.concat(lines, "\n")
end

function M.run()
  local session = {
    acp_ready = true,
    acp_supports_image = true,
    acp_agent_info = { title = "Codex", version = "1.1.4" },
    acp_session_info = {
      title = "the first user message as title",
      summary = "the first user message as summary",
    },
  }

  local hidden = footer_text(session)
  assert(hidden:find("Codex 1.1.4", 1, true), "provider metadata remains visible")
  assert(not hidden:find("the first user message as title", 1, true), "session title hidden by default")
  assert(not hidden:find("the first user message as summary", 1, true), "session summary hidden by default")
  assert(hidden:find("Image input", 1, true), "supported image input is visible")

  session.show_session_summary = true
  local visible = footer_text(session)
  assert(visible:find("the first user message as title", 1, true), "session title visible when enabled")
  assert(visible:find("the first user message as summary", 1, true), "session summary visible when enabled")

  session.acp_supports_image = false
  local text_only = footer_text(session)
  assert(text_only:find("No image input", 1, true), "unsupported image input is visible")
end

return M
