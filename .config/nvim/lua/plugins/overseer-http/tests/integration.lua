-- nvim --headless --clean -u NONE -l tests/integration.lua
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/overseer.nvim')
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')
local socket = assert(vim.uv.new_tcp())
assert(socket:bind('127.0.0.1', 0))
local port = socket:getsockname().port
socket:close()
local server = [[
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys
class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', '99')
        self.end_headers()
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/health')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{broken' if self.path == '/invalid' else b'{"ok":true}')
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(422)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
]]
local server_job = vim.fn.jobstart({ 'python3', '-u', '-c', server, tostring(port) })
assert(server_job > 0)
assert(vim.wait(3000, function()
  return vim.fn.system({ 'curl', '--silent', '--max-time', '1', 'http://127.0.0.1:' .. port .. '/health' }) == '{"ok":true}'
end, 50), 'HTTP fixture did not start')

local ok, err = xpcall(function()
  local overseer = require('overseer')
  local http = require('overseer_http')
  overseer.setup({ actions = require('overseer_http.actions').build() })
  http.setup()
  local file = fixture .. '/api.http'
  vim.fn.writefile({
    '### Health',
    'GET http://127.0.0.1:' .. port .. '/health',
    '',
    '### Invalid user',
    'POST http://127.0.0.1:' .. port .. '/users',
    'Content-Type: application/json',
    '',
    '{"name":"bad"}',
  }, file)
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.bo.filetype = 'http'
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  http.jump(1)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 4)
  http.jump(-1)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
  local listed
  require('overseer.template').list({ dir = fixture, filetype = 'http' }, function(templates)
    listed = templates
  end)
  assert(vim.wait(3000, function() return listed ~= nil end))
  local found = 0
  local health_template
  for _, item in ipairs(listed) do
    if item.name:find('HTTP:', 1, true) then
      found = found + 1
      if item.name:find('Health', 1, true) then health_template = item.name end
    end
  end
  assert(found == 2, vim.inspect(listed))
  local from_template, template_error
  overseer.run_task({ name = health_template }, function(task, run_err)
    from_template, template_error = task, run_err
  end)
  assert(vim.wait(5000, function() return from_template ~= nil or template_error ~= nil end))
  assert(from_template and not template_error, tostring(template_error))
  assert(vim.wait(5000, function() return from_template:is_complete() end))
  assert(from_template.result.http.status_code == 200)
  from_template:dispose(true)

  local inline_request = assert(require('overseer_http.parser').parse({
    '@base_url = http://127.0.0.1:' .. port,
    '',
    '### Inline health',
    '@curl_insecure',
    '@curl_location',
    '@curl_compressed',
    '@curl_max_time 5',
    '@curl_connect_timeout 2',
    'GET {{base_url}}/redirect',
  }, file))[1]
  http.config.variables.base_url = 'http://127.0.0.1:1'
  local inline_task = assert(require('overseer_http.runner').run(inline_request))
  http.config.variables.base_url = nil
  assert(vim.wait(5000, function() return inline_task:is_complete() end))
  assert(inline_task.status == overseer.STATUS.SUCCESS, vim.inspect(inline_task.result))
  assert(inline_task.metadata.overseer_http.request.url == 'http://127.0.0.1:' .. port .. '/redirect')
  assert(vim.tbl_contains(inline_task.metadata.overseer_http.args, '--insecure'))
  assert(vim.tbl_contains(inline_task.metadata.overseer_http.args, '--location'))
  assert(vim.tbl_contains(inline_task.metadata.overseer_http.args, '--compressed'))
  assert(vim.tbl_contains(inline_task.metadata.overseer_http.args, '--max-time'))
  assert(vim.tbl_contains(inline_task.metadata.overseer_http.args, '--connect-timeout'))
  assert(vim.fn.readfile(inline_task.result.http.body_path)[1] == '{"ok":true}')
  inline_task:dispose(true)

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local first = assert(http.run_current())
  assert(vim.wait(5000, function() return first:is_complete() end))
  assert(first.status == overseer.STATUS.SUCCESS, vim.inspect(first.result))
  assert(first.result.http.status_code == 200)
  assert(vim.fn.readfile(first.result.http.body_path)[1] == '{"ok":true}')
  assert(first.name:find('[200]', 1, true))
  local source_win = vim.api.nvim_get_current_win()
  local task_buf = assert(first:get_bufnr())
  assert(vim.b[task_buf].overseer_http_response_view == 'body')
  assert(vim.bo[task_buf].filetype == 'json')
  assert(vim.api.nvim_win_get_buf(source_win) ~= task_buf)
  local output_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == task_buf then output_win = win end
  end
  assert(output_win, 'Overseer result pane should display the response body')
  local window_count = #vim.api.nvim_tabpage_list_wins(0)
  local head = assert(require('overseer_http.parser').parse({
    'HEAD http://127.0.0.1:' .. port .. '/health',
  }, file))[1]
  local head_task = assert(require('overseer_http.runner').run(head))
  assert(vim.wait(5000, function() return head_task:is_complete() end))
  assert(head_task.status == overseer.STATUS.SUCCESS, vim.inspect(head_task.result))
  assert(head_task.result.http.status_code == 200)
  assert(vim.fn.getfsize(head_task.result.http.body_path) == 0)
  head_task:dispose(true)
  overseer.run_action(first, 'HTTP: Open Body')
  assert(vim.bo[task_buf].filetype == 'json')
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)
  if vim.fn.executable('jq') == 1 then
    assert(vim.wait(2000, function()
      local lines = vim.api.nvim_buf_get_lines(task_buf, 0, -1, false)
      return lines[1] == '{' and lines[2] == '  "ok": true'
    end), 'jq did not format the JSON response view')
    assert(vim.fn.readfile(first.result.http.body_path)[1] == '{"ok":true}')
  end
  local saved_response = fixture .. '/saved-response.json'
  local original_input, original_select = vim.ui.input, vim.ui.select
  vim.ui.input = function(opts, callback)
    assert(opts.prompt:find('response body', 1, true))
    callback(saved_response)
  end
  overseer.run_action(first, 'HTTP: Save Body to File')
  assert(vim.fn.readfile(saved_response)[1] == '{"ok":true}')
  vim.fn.writefile({ 'keep me' }, saved_response)
  vim.ui.select = function(_, _, callback) callback('Cancel') end
  overseer.run_action(first, 'HTTP: Save Body to File')
  assert(vim.fn.readfile(saved_response)[1] == 'keep me')
  vim.ui.select = function(_, _, callback) callback('Overwrite') end
  overseer.run_action(first, 'HTTP: Save Body to File')
  vim.ui.input = function(_, callback) callback('relative-response.json') end
  overseer.run_action(first, 'HTTP: Save Body to File')
  vim.ui.input, vim.ui.select = original_input, original_select
  assert(vim.fn.readfile(saved_response)[1] == '{"ok":true}')
  assert(vim.fn.readfile(fixture .. '/relative-response.json')[1] == '{"ok":true}')
  overseer.run_action(first, 'HTTP: Open Headers')
  assert(vim.bo[task_buf].filetype == 'http')
  assert(vim.b[task_buf].overseer_http_response_view == 'headers')
  assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)
  http.toggle_response()
  assert(vim.b[task_buf].overseer_http_response_view == 'body')
  assert(vim.api.nvim_win_get_buf(output_win) == task_buf)
  assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)
  local invalid_json = assert(require('overseer_http.parser').parse({
    'GET http://127.0.0.1:' .. port .. '/invalid',
  }, file))[1]
  local invalid_json_task = assert(require('overseer_http.runner').run(invalid_json))
  assert(vim.wait(5000, function() return invalid_json_task:is_complete() end))
  overseer.run_action(invalid_json_task, 'HTTP: Open Body')
  assert(vim.bo[invalid_json_task:get_bufnr()].filetype == 'json')
  assert(vim.api.nvim_buf_get_lines(invalid_json_task:get_bufnr(), 0, -1, false)[1] == '{broken')
  invalid_json_task:dispose(true)
  overseer.run_action(first, 'HTTP: Open Source Request')
  assert(vim.api.nvim_buf_get_name(0) == file)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.bo.filetype = 'http'
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local second = assert(http.run_current())
  assert(vim.wait(5000, function() return second:is_complete() end))
  assert(second.status == overseer.STATUS.FAILURE, vim.inspect(second.result))
  assert(second.result.http.status_code == 422 and second.result.http.curl_exit == 0)
  assert(vim.b[second:get_bufnr()].overseer_http_response_view == 'body')
  assert(vim.fn.readfile(second.result.http.body_path)[1] == '{"name":"bad"}')
  overseer.run_action(second, 'HTTP: Copy cURL')
  local copied = vim.fn.getreg('+')
  assert(copied:find('printf %s ', 1, true))
  assert(copied:find('--data-binary', 1, true))
  assert(not copied:find(second.metadata.overseer_http.paths.dir, 1, true))
  assert(http.latest_task() == second)
  http.repeat_last()
  assert(vim.wait(5000, function() return second:is_complete() end))
  assert(second.result.http.status_code == 422)
  assert(vim.b[second:get_bufnr()].overseer_http_response_view == 'body')
  local response_path = second.result.http.body_path
  assert(second:dispose(true))
  assert(vim.fn.filereadable(response_path) == 0)
  local closed = assert(vim.uv.new_tcp())
  assert(closed:bind('127.0.0.1', 0))
  local closed_port = closed:getsockname().port
  closed:close()
  local bad = assert(require('overseer_http.parser').parse({
    'GET http://127.0.0.1:' .. closed_port .. '/unreachable',
  }, file))[1]
  local transport = assert(require('overseer_http.runner').run(bad))
  assert(vim.wait(5000, function() return transport:is_complete() end))
  assert(transport.status == overseer.STATUS.FAILURE)
  assert(transport.result.http.curl_exit ~= 0)
  assert(vim.bo[transport:get_bufnr()].filetype == 'OverseerOutput')
  transport:dispose(true)
  first:dispose(true)
  assert(vim.fn.readfile(saved_response)[1] == '{"ok":true}')
  print('PASS: HTTP provider, curl task, status, response, restart, disposal')
end, debug.traceback)
vim.fn.jobstop(server_job)
vim.fn.delete(fixture, 'rf')
if not ok then error(err) end
vim.cmd('qa!')
