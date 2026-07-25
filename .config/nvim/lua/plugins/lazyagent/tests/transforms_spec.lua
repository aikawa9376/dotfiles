local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function contains(haystack, needle, message)
  if not tostring(haystack):find(needle, 1, true) then
    error(string.format("%s: %q does not contain %q", message, haystack, needle))
  end
end

local function excludes(haystack, needle, message)
  if tostring(haystack):find(needle, 1, true) then
    error(string.format("%s: %q unexpectedly contains %q", message, haystack, needle))
  end
end

function M.run()
  local transforms = require("lazyagent.transforms")
  local obsidian
  local obsidian_html
  for _, token in ipairs(transforms.available_tokens()) do
    if token.name == "obsidian" then
      obsidian = token
    elseif token.name == "obsidian-html" then
      obsidian_html = token
    end
  end

  assert(obsidian, "#obsidian transform is available")
  assert(obsidian_html, "#obsidian-html transform is available")
  assert_equal(
    obsidian.desc,
    "Turn the durable result into a linked Markdown note in the Obsidian vault",
    "#obsidian description"
  )
  assert_equal(
    obsidian_html.desc,
    "Create an Obsidian Markdown summary with a polished companion HTML artifact",
    "#obsidian-html description"
  )
  assert_equal(obsidian_html.aliases[1], "obsiditan-html", "#obsidian-html typo alias")

  local preview = transforms.preview_token("obsidian")
  contains(preview, "use the `obsidian` skill", "#obsidian invokes the vault skill")
  contains(preview, "Search the vault before writing", "#obsidian prevents duplicate notes")
  contains(preview, "today's daily note", "#obsidian creates a chronological retrieval path")
  contains(preview, "`project`, and `branch` properties", "#obsidian records repository facets")
  contains(preview, "Do not encode repository or branch names as tags", "#obsidian avoids branch tags")
  contains(preview, "open or create the matching", "#obsidian creates a missing branch note")
  contains(preview, "under `## AI notes`", "#obsidian indexes captures from the branch note")
  contains(preview, "web-capture workflow", "#obsidian routes URLs through web capture")
  contains(preview, "Base", "#obsidian can route property-driven overviews")
  contains(preview, "Canvas", "#obsidian can route spatial maps")
  contains(preview, "Markdown only", "#obsidian remains lightweight")
  excludes(preview, "follow its HTML-artifact workflow", "#obsidian does not create HTML")

  local expanded = transforms.expand("Keep this result: #obsidian")
  contains(expanded, "Keep this result:", "#obsidian preserves the surrounding request")
  contains(expanded, "reusable Markdown knowledge", "#obsidian expands Markdown capture instructions")

  local html_preview = transforms.preview_token("obsidian-html")
  contains(html_preview, "follow its HTML-artifact workflow", "#obsidian-html creates paired HTML material")
  contains(html_preview, "concise canonical Markdown summary", "#obsidian-html keeps a searchable summary")
  contains(html_preview, "self-contained HTML companion", "#obsidian-html creates the artifact")
  contains(html_preview, "`project`, and `branch` properties", "#obsidian-html records repository facets")
  contains(html_preview, "open or create the matching", "#obsidian-html creates a missing branch note")

  local html_expanded = transforms.expand("Keep a visual report: #obsiditan-html")
  contains(html_expanded, "Keep a visual report:", "#obsidian-html alias preserves the request")
  contains(html_expanded, "assets/html/", "#obsidian-html alias expands the artifact instructions")
end

return M
