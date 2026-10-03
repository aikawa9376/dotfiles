local M = {}

function M.run()
  local names = { "render-markdown.request.view", "render-markdown.request.context" }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local context, delegated = {}, 0
  local View = { parse = function(_, _, callback) delegated = delegated + 1; callback() end }
  package.loaded[names[1]] = View
  package.loaded[names[2]] = { get = function(buf) return assert(context[buf]) end }
  local adapter = require("lazyagent.render_markdown")
  local enabled = adapter.async_view_parse_enabled
  adapter.async_view_parse_enabled = nil
  adapter.enable_async_view_parse()
  local wrapper = View.parse
  adapter.enable_async_view_parse()
  assert(View.parse == wrapper, "async adapter is installed once")

  local source = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lazyagent_acp"
  vim.api.nvim_win_set_buf(0, buf)
  local callbacks, displayed = {}, 0
  local parser = { parse = function(_, ranges, callback)
    assert(type(callback) == "function", "ACP parsing must use the async API")
    assert(ranges[1][1] == 0, "async parsing retains the requested ranges")
    callbacks[#callbacks + 1] = callback
  end }
  local function request()
    local view = { buf = buf, ranges = { { 0, 10 } } }
    context[buf] = { view = view, win = vim.api.nvim_get_current_win() }
    View.parse(view, parser, function() displayed = displayed + 1 end)
  end
  request()
  assert(displayed == 0, "Markdown waits for current injection trees")
  callbacks[1](nil, {})
  assert(displayed == 1, "a completed current parse can render")

  request()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new reply" })
  callbacks[2](nil, {})
  assert(displayed == 1, "text changes reject the old parse result")
  request()
  request()
  callbacks[3](nil, {})
  assert(displayed == 1, "a replaced scroll/resize request cannot render")
  callbacks[4](nil, {})
  assert(displayed == 2, "the latest request still renders")
  request()
  callbacks[5]("TIMEOUT", nil)
  assert(displayed == 2, "timed out parses do not render stale trees")
  local get_mode = vim.api.nvim_get_mode
  request()
  vim.api.nvim_get_mode = function() return { mode = "i" } end
  callbacks[6](nil, {})
  vim.api.nvim_get_mode = get_mode
  assert(displayed == 2, "mode changes reject late rendering")
  request()
  vim.api.nvim_win_set_buf(0, source)
  callbacks[7](nil, {})
  assert(displayed == 2, "hidden transcripts are not rendered by late callbacks")
  vim.api.nvim_win_set_buf(0, buf)
  request()
  vim.api.nvim_buf_delete(buf, { force = true })
  callbacks[8](nil, {})
  assert(displayed == 2, "wiped buffers safely discard late results")

  local ordinary = { buf = source }
  View.parse(ordinary, {}, function() displayed = displayed + 1 end)
  assert(delegated == 1 and displayed == 3, "ordinary Markdown keeps its original parser")

  local native = vim.treesitter.highlighter
  local get_parser, get_files = vim.treesitter.get_parser, vim.treesitter.query.get_files
  local query_path = vim.fn.tempname()
  vim.fn.writefile({
    '(fenced_code_block (fenced_code_block_delimiter) @markup.raw.block',
    ' (#set! conceal "") (#set! conceal_lines ""))',
    '((atx_heading) @markup.heading.1)',
  }, query_path)
  local created = 0
  local fake_parser = {}
  vim.treesitter.get_parser = function(_, lang) assert(lang == "markdown"); return fake_parser end
  vim.treesitter.query.get_files = function(lang, kind)
    assert(lang == "markdown" and kind == "highlights")
    return { query_path }
  end
  vim.treesitter.highlighter = {
    active = {},
    new = function(tree, opts)
      assert(tree == fake_parser)
      local query = opts.queries.markdown
      assert(not query:find("conceal_lines", 1, true), "native line conceal does not force sync parsing")
      assert(query:find('(#set! conceal "")', 1, true), "character conceal is preserved")
      assert(query:find("@markup.heading.1", 1, true), "syntax captures are preserved")
      created = created + 1
      vim.treesitter.highlighter.active[source] = {}
    end,
  }
  local highlighter = require("lazyagent.acp.highlighter")
  highlighter.start(source)
  highlighter.start(source)
  assert(created == 1, "repeated starts reuse the highlighter without duplicate callbacks")
  vim.treesitter.highlighter = native
  vim.treesitter.get_parser, vim.treesitter.query.get_files = get_parser, get_files
  vim.fn.delete(query_path)
  adapter.async_view_parse_enabled = enabled
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
end

return M
