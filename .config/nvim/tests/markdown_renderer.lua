-- nvim --headless --clean -u NONE -l .config/nvim/tests/markdown_renderer.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(root .. '/lua/plugins/lazyagent')
vim.opt.rtp:append(root .. '/lua/plugins/git')
local selector = require('lazyagent.markdown_renderer')
local integration = require('config.markdown_renderer')
local pr = require('git.features.pr_markdown')
vim.treesitter.language.add = function() return true end
vim.treesitter.get_parser = function() return { set_included_regions = function() end } end
vim.treesitter.start = function() end

local function check(names, preferred, expected)
  local rendered
  for _, name in ipairs({ 'inkstone', 'render-markdown' }) do
    package.loaded[name] = names[name] and {
      initialized = true,
      render = function() rendered = name end,
    } or nil
  end
  vim.g.markdown_renderer = preferred
  local buf = vim.api.nvim_create_buf(false, true)
  local renderer = integration.get()
  if expected then
    assert(selector.name() == expected, 'LazyAgent selected the wrong renderer')
    assert(renderer == package.loaded[expected], 'Blink/Snacks selected the wrong renderer')
    assert(pr.prepare(buf), 'Git did not attach its optional renderer')
    pr.update(buf, { { 0, 1 } })
    assert(rendered == expected, 'Git selected the wrong renderer')
  else
    assert(renderer == nil and not pr.prepare(buf), 'Missing plugins must leave plain Markdown')
    assert(not pcall(selector.require, 'state'), 'Optional LazyAgent renderer must be absent')
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

check({ inkstone = true }, nil, 'inkstone')
check({ ['render-markdown'] = true }, nil, 'render-markdown')
check({ inkstone = true, ['render-markdown'] = true }, 'inkstone', 'inkstone')
check({ inkstone = true, ['render-markdown'] = true }, 'render-markdown', 'render-markdown')
check({ ['render-markdown'] = true }, 'inkstone', 'render-markdown')
check({ inkstone = true }, 'render-markdown', 'inkstone')
check({}, nil, nil)
print('PASS: optional renderer detection, explicit preferences and missing-plugin fallback in LazyAgent/Git/Blink/Snacks')
