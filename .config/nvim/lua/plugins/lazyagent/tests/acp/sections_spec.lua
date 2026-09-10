local M = {}

function M.run()
  local sections = require("lazyagent.acp.view_buffer.sections")
  local heading = "─ Assistant ─"
  for _, fence in ipairs({ "```", "````", "~~~", "~~~~" }) do
    local lines = { "─ Tool ─", " python3 - <<'PY'", ' text = """', " " .. fence .. "python" }
    if #fence > 3 then
      lines[#lines + 1] = " " .. fence:sub(1, 3)
    end
    lines[#lines + 1] = ' """'
    lines[#lines + 1] = " PY"
    assert(sections.trailing_section_has_open_markdown_fence(lines), "literal fence remains open")
    assert(sections.append_crosses_unclosed_markdown_fence(lines, "\n" .. heading),
      "next reply requires repair")
    lines[#lines + 1] = heading
    lines[#lines + 1] = " reply"
    local balanced = sections.balance_unclosed_markdown_fences(lines)
    assert(balanced[#balanced - 2] == " " .. fence, "repair uses the opening delimiter")
    assert(not sections.trailing_section_has_open_markdown_fence(balanced), "reply is outside code")
  end
  assert(sections.markdown_fence_state({ " ```python", " ```lua" }) == "```",
    "a language-tagged line does not close an existing fence")
  assert(sections.markdown_fence_state({ " ```python", " ~~~" }) == "```",
    "mixed delimiters do not close a fence")
  assert(sections.markdown_fence_state({ " `````python", " `````` " }) == false,
    "a longer matching delimiter closes the fence")
  assert(sections.markdown_fence_state({ " ```python `literal`" }) == false,
    "backticks in an info string do not start a fence")
  assert(sections.markdown_fence_state({ "    ```python" }) == false,
    "indented code cannot start a fence")

  local _, before_tail = sections.markdown_fence_state({ "─ Tool ─", " ```" })
  local state = sections.markdown_fence_state({ " ```python", " code" }, before_tail)
  assert(state == "```", "extending a streamed fence does not count it twice")
end

return M
