local Controller = require('controller')

local M = {}

local controller = Controller.new()

local function linediff(from, to, options)
  if not controller.differs[2]:is_blank() then
    controller:close_and_reset(true)
  end

  controller:add(from, to, options)

  if not controller.differs[2]:is_blank() then
    controller:perform_diff()
  end
end

local function linediff_add(from, to, options)
  controller:add(from, to, options)
end

local function linediff_last(from, to, options)
  linediff_add(from, to, options)
  controller:perform_diff()
end

local function linediff_show()
  controller:perform_diff()
end

local function linediff_reset(bang)
  local force = bang == '!'
  controller:close_and_reset(force)
end

local function find_merge_markers()
  local view = vim.fn.winsaveview()
  local result = {}
  pcall(function()
    if vim.fn.search('^<<<<<<<', 'cbW') <= 0 then
      return
    end
    local start_marker = vim.fn.line('.')
    local start_label = vim.fn.matchstr(vim.fn.getline(start_marker), '^<<<<<<<.*')
    vim.fn.winrestview(view)

    if vim.fn.search('^>>>>>>>', 'cW') <= 0 then
      return
    end
    local end_marker = vim.fn.line('.')
    local end_label = vim.fn.matchstr(vim.fn.getline(end_marker), '^>>>>>>>.*')

    if vim.fn.search('^=======', 'cbW') <= 0 then
      return
    end
    local other_marker = vim.fn.line('.')

    local base_marker = other_marker
    if vim.fn.search('^|||||||', 'cbW') > 0 then
      base_marker = vim.fn.line('.')
    end

    result = {
      {start_marker + 1, base_marker - 1, start_label},
      {base_marker + 1, other_marker - 1, "common ancestor"},
      {other_marker + 1, end_marker - 1, end_label},
    }
  end)
  vim.fn.winrestview(view)
  return result
end

local function linediff_local_pick()
  local merge_markers = find_merge_markers()
  if #merge_markers < 3 then
    return
  end

  local range_start = merge_markers[1][1] - 1
  local range_end = merge_markers[3][2] + 1
  if range_end - range_start <= 2 then
    return
  end

  local target_lines = {}

  for _, area in ipairs(merge_markers) do
    local start_line, end_line, _label = unpack(area)
    if start_line <= vim.fn.line('.') and vim.fn.line('.') <= end_line then
      target_lines = vim.fn.getline(start_line, end_line)
    end
  end

  if #target_lines > 0 then
    vim.cmd(string.format("silent %d,%ddelete _", range_start, range_end))
    vim.fn.append(range_start - 1, target_lines)
  end
end

local function linediff_merge()
  local areas = find_merge_markers()

  if #areas == 0 then
    vim.api.nvim_echo({{'Couldn\'t find merge markers around cursor', 'ErrorMsg'}}, false, {{}})
    return
  end

  local top_area = areas[1]
  local middle_area = areas[2]
  local bottom_area = areas[3]
  local mfrom = top_area[1] - 1
  local mto = bottom_area[2] + 1

  linediff_add(top_area[1], top_area[2], {
    is_merge = 1,
    merge_from = mfrom,
    merge_to = mto,
    label = top_area[3]
  })

  if middle_area[1] <= middle_area[2] then
    linediff_add(middle_area[1], middle_area[2], {
      is_merge = 1,
      merge_from = mfrom,
      merge_to = mto,
      label = middle_area[3]
    })
  end

  linediff_last(bottom_area[1], bottom_area[2], {
    is_merge = 1,
    merge_from = mfrom,
    merge_to = mto,
    label = bottom_area[3]
  })
end

local function linediff_pick()
  if vim.b.differ == nil then
    return linediff_local_pick()
  end

  if not vim.b.differ:is_merge_diff() then
    vim.api.nvim_echo({{'Linediff buffer not generated from :LinediffMerge, nothing to do', 'ErrorMsg'}}, false, {})
    return 0
  end

  vim.b.differ:replace_merge()
  linediff_reset(true)
end

local function diff_register(register, from, to)
  local reg_buf = vim.api.nvim_create_buf(false, true)
  local reg_content = vim.fn.getreg(register, 1, true)
  vim.api.nvim_buf_set_lines(reg_buf, 0, -1, false, reg_content)

  controller:add(1, #reg_content, { bufnr = reg_buf })
  controller:add(from, to, {})
  controller:perform_diff()
end

function M.setup()
  -- settings
  vim.g.linediff_indent = vim.g.linediff_indent or 0
  vim.g.linediff_buffer_type = vim.g.linediff_buffer_type or 'tempfile'
  vim.g.linediff_first_buffer_command = vim.g.linediff_first_buffer_command or 'tabnew'
  vim.g.linediff_further_buffer_command = vim.g.linediff_further_buffer_command or 'rightbelow vertical new'
  vim.g.linediff_diffopt = vim.g.linediff_diffopt or 'builtin'
  vim.g.linediff_modify_statusline = vim.g.linediff_modify_statusline or 1

  -- highlights
  vim.cmd('highlight default link LinediffSign1 DiffAdd')
  vim.cmd('highlight default link LinediffSign2 DiffChange')
  vim.cmd('highlight default link LinediffSign3 DiffText')
  vim.cmd('highlight default link LinediffSign4 DiffAdd')
  vim.cmd('highlight default link LinediffSign5 DiffChange')
  vim.cmd('highlight default link LinediffSign6 DiffText')
  vim.cmd('highlight default link LinediffSign7 DiffAdd')
  vim.cmd('highlight default link LinediffSign8 DiffChange')

  -- commands
  vim.api.nvim_create_user_command('Linediff', function(opts)
    linediff(opts.line1, opts.line2, {})
  end, { range = true })

  vim.api.nvim_create_user_command('LinediffAdd', function(opts)
    linediff_add(opts.line1, opts.line2, {})
  end, { range = true })

  vim.api.nvim_create_user_command('LinediffLast', function(opts)
    linediff_last(opts.line1, opts.line2, {})
  end, { range = true })

  vim.api.nvim_create_user_command('LinediffShow', linediff_show, {})

  vim.api.nvim_create_user_command('LinediffReset', function(opts)
    linediff_reset(opts.bang)
  end, { bang = true })

  vim.api.nvim_create_user_command('LinediffMerge', linediff_merge, {})

  vim.api.nvim_create_user_command('LinediffPick', linediff_pick, {})

  vim.api.nvim_create_user_command('LinediffRegister', function(opts)
    diff_register(opts.args, opts.line1, opts.line2)
  end, { range = true, nargs = 1 })

  -- mappings
  function M.linediff_op(wise)
    vim.cmd("silent '[, '] Linediff")
  end

  function M.linediff_add_op(wise)
    vim.cmd("silent '[, '] LinediffAdd")
  end

  function M.linediff_last_op(wise)
    vim.cmd("silent '[, '] LinediffLast")
  end

  function M.linediff_register_op(wise)
    local reg = vim.v.register
    if reg == '' then
      reg = '"'
    end
    vim.cmd(string.format("silent '[, '] LinediffRegister %s", reg))
  end

  vim.keymap.set('n', '<Plug>(linediff-operator)', function()
    vim.o.operatorfunc = 'v:lua.require("linediff").linediff_op'
    return 'g@'
  end, { expr = true, silent = true })

  vim.keymap.set('n', '<Plug>(linediff-add-operator)', function()
    vim.o.operatorfunc = 'v:lua.require("linediff").linediff_add_op'
    return 'g@'
  end, { expr = true, silent = true })

  vim.keymap.set('n', '<Plug>(linediff-last-operator)', function()
    vim.o.operatorfunc = 'v:lua.require("linediff").linediff_last_op'
    return 'g@'
  end, { expr = true, silent = true })

  vim.keymap.set('n', '<Plug>(linediff-register-operator)', function()
    vim.o.operatorfunc = 'v:lua.require("linediff").linediff_register_op'
    return 'g@'
  end, { expr = true, silent = true })
end

return M
