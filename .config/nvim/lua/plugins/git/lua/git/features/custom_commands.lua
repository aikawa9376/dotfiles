-- User-owned declarative Git argv, never shell templates or repository code.
local M = {}
local configured = {}
local workflow = require('git.features.workflow')
function M.setup(entries)
  local seen, result = {}, {}
  for _, entry in ipairs(entries or {}) do
    assert(type(entry.key) == 'string' and entry.key ~= '' and not seen[entry.key], 'Custom Git commands need unique keys')
    assert(not vim.tbl_contains({ 'q', '<Esc>', '<CR>', '<C-s>', '<C-r>', '<C-w>', '<C-h>', '<C-d>' }, entry.key), 'Reserved custom Git key: ' .. entry.key)
    assert(type(entry.label) == 'string' and type(entry.args) == 'table' and #entry.args > 0, 'Custom Git command needs label and argv')
    for _, arg in ipairs(entry.args) do assert(type(arg) == 'string', 'Custom Git argv must contain strings') end
    local names = { commit = true, branch = true, path = true, paths = true, commits = true, ref = true, worktree = true }
    for _, input in ipairs(entry.inputs or {}) do
      assert(type(input.name) == 'string' and input.name:match('^[%a_][%w_]*$') and not names[input.name], 'Custom input needs a unique alphanumeric name')
      names[input.name] = true
    end
    seen[entry.key] = true; result[#result + 1] = vim.deepcopy(entry)
  end
  configured = result
end
local function substitute(text, vars)
  return (text:gsub('{([%w_]+)}', function(name)
    local value = vars[name]
    if type(value) ~= 'string' or value == '' then error('No value for {' .. name .. '}', 0) end
    return value
  end))
end
function M.execute(entry, ctx)
  local vars = { commit = ctx.commit, branch = ctx.branch, path = ctx.path,
    ref = ctx.branch or ctx.commit, worktree = ctx.work_tree }
  local function fail(err) vim.notify(tostring(err), vim.log.levels.WARN) end
  local function execute()
    local ok, args = pcall(function()
      local argv = {}
      for _, arg in ipairs(entry.args) do
        if arg == '{paths}' or arg == '{commits}' then
          local values = arg == '{paths}' and (ctx.paths or (ctx.path and { ctx.path }))
            or (arg == '{commits}' and (ctx.commits or (ctx.commit and { ctx.commit })))
          if not values or #values == 0 then error('No selection for ' .. arg, 0) end
          vim.list_extend(argv, values)
        else argv[#argv + 1] = substitute(arg, vars) end
      end
      return argv
    end)
    if not ok then fail(args); return end
    local uses_editor = entry.editor == true or (entry.editor ~= false and vim.tbl_contains({
      'commit', 'merge', 'rebase', 'cherry-pick', 'revert', 'am', 'subtree', 'notes', 'tag', '-c',
    }, args[1]))
    local function run() workflow.run(ctx.work_tree, args, { mutation = entry.mutation ~= false,
      editor = uses_editor, output = entry.output ~= false, title = entry.label }) end
    if entry.confirm then
      vim.ui.select({ 'Proceed', 'Cancel' }, { prompt = entry.label .. ': git ' .. table.concat(vim.tbl_map(vim.fn.shellescape, args), ' ') },
        function(choice) if choice == 'Proceed' then run() end end)
    else run() end
  end
  local function input(at)
    local spec = (entry.inputs or {})[at]
    if not spec then execute(); return end
    local function answer(text) if text ~= nil and text ~= '' then vars[spec.name] = text; input(at + 1) end end
    if spec.choices then vim.ui.select(spec.choices, { prompt = spec.prompt or spec.name }, answer)
    else
      local ok, default = pcall(substitute, spec.default or '', vars)
      if not ok then fail(default); return end
      vim.ui.input({ prompt = (spec.prompt or spec.name) .. ': ', default = default }, answer)
    end
  end
  -- Resolve fallback branch only if a template uses it. Detached HEAD has no branch.
  local needs_branch = false
  for _, arg in ipairs(entry.args) do if arg:find('{branch}', 1, true) then needs_branch = true end end
  for _, spec in ipairs(entry.inputs or {}) do if (spec.default or ''):find('{branch}', 1, true) then needs_branch = true end end
  if needs_branch and not vars.branch then
    workflow.run(ctx.work_tree, { 'symbolic-ref', '--quiet', '--short', 'HEAD' }, { mutation = false,
      callback = function(ok, result) if ok then vars.branch = vim.trim(result); input(1) else fail('No branch is selected and HEAD is detached') end end })
  else input(1) end
end
function M.open(ctx, ui, show)
  local actions = {}
  for _, entry in ipairs(configured) do
    if not entry.panels or vim.tbl_contains(entry.panels, ctx.panel) then
      actions[#actions + 1] = { key = entry.key, label = entry.label, run = function() M.execute(entry, ctx) end }
    end
  end
  if #actions == 0 then
    vim.notify('Register custom_commands with require("git").setup({...})', vim.log.levels.INFO); return
  end
  return show({ kind = 'custom-commands', title = 'Custom Git commands', groups = { { title = 'Commands', actions = actions } } }, ui)
end
return M
