-- nvim --headless --clean -u NONE -l tests/core.lua
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local parser = require('overseer_http.parser')
local variables = require('overseer_http.variables')
local curl = require('overseer_http.curl')

local requests = assert(parser.parse({
  '### Get users',
  'get {{base_url}}/users',
  'Authorization: Bearer {{token}}',
  '',
  '### Create user',
  'POST {{base_url}}/users',
  'Content-Type: application/json',
  '',
  '{',
  '  "name": "foo"',
  '',
  '}',
}, '/tmp/api.http'))
assert(#requests == 2)
assert(requests[1].name == 'Get users' and requests[1].method == 'GET')
assert(requests[1].body == nil and requests[1].line_start == 1 and requests[1].line_end == 4)
assert(requests[2].body == '{\n  "name": "foo"\n\n}')
assert(parser.current(requests, 5) == requests[2])
assert(parser.current(requests, 12) == requests[2])
assert(parser.current(requests, 13) == nil)
local no_name = assert(parser.parse({ 'GET https://example.test' }, '/tmp/api.http'))
assert(#no_name == 1 and no_name[1].line_end == 1)
local invalid, err = parser.parse({ 'POST https://example.test', 'Bad header' }, '/tmp/api.http')
assert(invalid == nil and err:find('Invalid header', 1, true))
invalid, err = parser.parse({ 'BREW https://example.test' }, '/tmp/api.http')
assert(invalid == nil and err:find('Invalid request line', 1, true))
invalid, err = parser.parse({ 'GET https://example.test', 'Bad Key: value' }, '/tmp/api.http')
assert(invalid == nil and err:find('Invalid header', 1, true))

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')
vim.fn.writefile({ 'base_url=https://second.test', 'token=second' }, fixture .. '/.env.local')
vim.fn.writefile({ 'base_url=https://first.test', 'token=first' }, fixture .. '/.env')
local env = variables.environment(fixture .. '/api.http', {
  env_files = { '.env', '.env.local' },
  variables = { token = 'configured' },
})
assert(env.base_url == 'https://second.test' and env.token == 'configured')
local expanded = assert(variables.expand_request(requests[1], env))
assert(expanded.url == 'https://second.test/users')
assert(expanded.headers.Authorization == 'Bearer configured')
assert(requests[1].url == '{{base_url}}/users')
local missing, variable_err = variables.resolve('{{not_defined_anywhere}}', {})
assert(missing == nil and variable_err == 'Undefined variable: not_defined_anywhere')
assert(variables.resolve('{{PATH}}', {}) == os.getenv('PATH'))
local body_request = assert(parser.parse({
  'POST https://example.test', '', '{"token":"{{token}}"}',
}, '/tmp/api.http'))[1]
assert(variables.expand_request(body_request, env).body == '{"token":"configured"}')
local paths = { headers = '/tmp/headers', body = '/tmp/response', request_body = '/tmp/request' }
local args = curl.build(requests[2], paths, 'curl')
local joined = table.concat(args, '\0')
assert(joined:find('--data-binary\0@/tmp/request', 1, true))
assert(joined:find('--header\0Content-Type: application/json', 1, true))
assert(joined:find('--url\0{{base_url}}/users', 1, true))
assert(not joined:find('/bin/sh', 1, true))
assert(table.concat(curl.build({ method = 'HEAD', url = 'https://example.test', headers = {} }, paths), '\0'):find('--head', 1, true))
vim.fn.delete(fixture, 'rf')
print('PASS: parser, variables, curl argv')
vim.cmd('qa!')
