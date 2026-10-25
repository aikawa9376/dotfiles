local M = {}

function M.run()
  local name = "render-markdown.lib.node"
  local adapter_name = "lazyagent.render_markdown_node"
  local saved, saved_adapter = package.loaded[name], package.loaded[adapter_name]
  local Native = {}
  Native.__index = Native
  function Native.new(buf, node) return setmetatable({ buf = buf, node = node }, Native) end
  function Native:get() return self.node end
  function Native:level() return self.node.heading_level end
  function Native:sibling_count() error("native traversal must remain untouched") end
  package.loaded[name], package.loaded[adapter_name] = Native, nil
  local ok, err = xpcall(function()
    local Bounded = require(adapter_name)
    local calls = 0
    local function node(row, col, kind, level)
      local value = { heading_level = level }
      function value:type() return kind or "list_item" end
      function value:range() return row, col, row, col + 1 end
      function value:prev_sibling()
        calls = calls + 1
        assert(calls < 20, "a cyclic sibling walk must terminate")
        return self.previous
      end
      return value
    end
    local first, second, third = node(1, 0), node(1, 4), node(2, 0)
    second.previous, third.previous = first, second
    local wrapped = Bounded.wrap(Native.new(1, third))
    assert(wrapped:sibling_count("list_item") == 3, "valid siblings include earlier columns on the same row")
    assert(getmetatable(wrapped:create(first)) == Bounded, "derived nodes retain the scoped guard")

    calls = 0
    first.previous = first
    assert(Bounded.wrap(Native.new(1, first)):sibling_count("list_item") == 1,
      "self cycles terminate before another native sibling lookup")
    assert(calls == 1)
    calls = 0
    first.previous = second
    assert(wrapped:sibling_count("list_item") == 3, "multi-node cycles cannot revisit a later position")
    assert(calls == 3)

    local empty = node(0, 0)
    function empty:range() return 0, 0, 0, 0 end
    function empty:prev_sibling() error("collapsed nodes must never traverse native siblings") end
    assert(Bounded.wrap(Native.new(1, empty)):sibling_count("list_item") == 0)
    first.previous = empty
    assert(wrapped:sibling_count("list_item") == 3, "an empty preceding node also ends the walk")

    local h1, h2, h3 = node(1, 0, "section", 1), node(2, 0, "section", 2), node(3, 0, "section", 2)
    h3.previous, h2.previous = h2, h1
    assert(Bounded.wrap(Native.new(1, h3)):sibling_count("section", 2) == 2,
      "heading counts retain the native level filter")
    assert(getmetatable(Native.new(1, first)) == Native,
      "ordinary renderer nodes keep the native class")
    assert(not pcall(function() Native.new(1, first):sibling_count() end),
      "the native method was never replaced")
  end, debug.traceback)
  package.loaded[name], package.loaded[adapter_name] = saved, saved_adapter
  assert(ok, err)
end

return M
