local M = {}

local function metadata(task)
  return task.metadata and task.metadata.overseer_http
end

local function response_filetype(path)
  if vim.fn.filereadable(path) == 0 then return 'text' end
  local content_type = ''
  for _, line in ipairs(vim.fn.readfile(path)) do
    local value = line:lower():match('^content%-type:%s*([^;]+)')
    if value then content_type = value:gsub('%s+$', '') end
  end
  local filetypes = { ['text/html'] = 'html', ['application/xml'] = 'xml', ['text/xml'] = 'xml' }
  if content_type:find('json', 1, true) then return 'json' end
  return filetypes[content_type] or 'text'
end

local function pretty_print_json(task, buf, path)
  local config = require('overseer_http').config.response
  if not config.pretty_json or vim.fn.executable('jq') ~= 1 then return end
  vim.system({ 'jq', '.', path }, { text = true }, function(result)
    if result.code ~= 0 or not result.stdout or result.stdout == '' then return end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) or task:get_bufnr() ~= buf
        or vim.b[buf].overseer_http_response_view ~= 'body' then return end
      local lines = vim.split(result.stdout, '\n', { plain = true })
      if lines[#lines] == '' then table.remove(lines) end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].modified = false
    end)
  end)
end

local function show_file(task, kind, notify_missing)
  local info = metadata(task)
  if not info then return false end
  local path = info.paths[kind]
  if vim.fn.filereadable(path) == 0 then
    if notify_missing then vim.notify('HTTP ' .. kind .. ' is not available yet', vim.log.levels.WARN) end
    return false
  end
  local buf = task:get_bufnr()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  vim.b[buf].overseer_http_response_view = kind
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path, 'b'))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if kind == 'headers' then
    vim.bo[buf].filetype = 'http'
  else
    vim.bo[buf].filetype = response_filetype(info.paths.headers)
    if vim.bo[buf].filetype == 'json' then pretty_print_json(task, buf, path) end
  end
  return true
end

function M.open_body(task) return show_file(task, 'body', true) end
function M.open_headers(task) return show_file(task, 'headers', true) end
function M.show_default(task) return show_file(task, 'body', false) end

function M.save_body(task)
  local info = metadata(task)
  if not info then return end
  if not task:is_complete() then
    vim.notify('HTTP response is not complete yet', vim.log.levels.WARN)
    return
  end
  local source = info.paths.body
  if vim.fn.filereadable(source) == 0 then
    vim.notify('HTTP body is not available', vim.log.levels.WARN)
    return
  end
  local source_dir = vim.fn.fnamemodify(info.request.source_file, ':p:h')
  vim.ui.input({
    prompt = 'Save HTTP response body to: ',
    default = source_dir .. '/response-' .. task.id .. '.body',
  }, function(input)
    if not input or input == '' then return end
    local destination = input
    if destination:sub(1, 1) == '~' then destination = vim.fn.expand(destination) end
    if not destination:match('^/') then destination = source_dir .. '/' .. destination end
    destination = vim.fs.normalize(destination)
    if destination == source then
      vim.notify('Choose a different path for the HTTP response body', vim.log.levels.ERROR)
      return
    end

    local function copy(overwrite)
      if vim.fn.filereadable(source) == 0 then
        vim.notify('HTTP body is no longer available', vim.log.levels.ERROR)
        return
      end
      -- 1 is UV_FS_COPYFILE_EXCL: leave existing files untouched until confirmed.
      local ok, err = vim.uv.fs_copyfile(source, destination, overwrite and 0 or 1)
      if ok then
        vim.notify('Saved HTTP response body to ' .. destination)
      elseif not overwrite and err and err:match('^EEXIST:') then
        vim.ui.select({ 'Overwrite', 'Cancel' }, {
          prompt = 'File exists: ' .. destination,
        }, function(choice)
          if choice == 'Overwrite' then copy(true) end
        end)
      else
        vim.notify('Could not save HTTP response body: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end
    copy(false)
  end)
end

function M.copy_curl(task)
  local info = metadata(task)
  if not info then return end
  local args = {}
  local prefix = ''
  local index = 1
  while index <= #info.args do
    local arg = info.args[index]
    if arg == '--dump-header' or arg == '--output' or arg == '--write-out' then
      index = index + 2
    else
      if arg == '@' .. info.paths.request_body then
        -- Pipe the body so the copied command survives task disposal.
        arg = '@-'
        prefix = 'printf %s ' .. vim.fn.shellescape(info.request.body) .. ' | '
      end
      args[#args + 1] = arg
      index = index + 1
    end
  end
  local quoted = {}
  for _, arg in ipairs(args) do
    quoted[#quoted + 1] = vim.fn.shellescape(arg)
  end
  vim.fn.setreg('+', prefix .. table.concat(quoted, ' '))
  vim.notify('Copied cURL command (may contain secrets)')
end

function M.open_source(task)
  local info = metadata(task)
  if not info then return end
  vim.cmd.edit(vim.fn.fnameescape(info.request.source_file))
  vim.api.nvim_win_set_cursor(0, { info.request.line_start, 0 })
end

return M
