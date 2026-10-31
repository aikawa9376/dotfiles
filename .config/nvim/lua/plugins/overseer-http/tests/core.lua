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
local inline = assert(parser.parse({
  '# file comment',
  '  // another file comment',
  '@base_url = https://api.example.test',
  '# comment after variable',
  '',
  '### First',
  '// first request',
  'GET {{base_url}}/users',
  '',
  '### Second',
  '@token = local-token',
  'POST {{base_url}}/users',
  '# header comment',
  'Authorization: Bearer {{token}}',
  '// another header comment',
  '',
  '# body text',
  '// body text',
  '@token = body text',
}, '/tmp/inline.http'))
assert(#inline == 2)
assert(inline[1].variables.base_url == 'https://api.example.test')
assert(inline[2].variables.token == 'local-token')
assert(inline[2].body == '# body text\n// body text\n@token = body text')
assert(#assert(parser.parse({ '# only a comment', '// another comment' }, '/tmp/comments.http')) == 0)
local curl_directives = assert(parser.parse({
  '### Verified',
  'GET https://example.test/verified',
  '',
  '### With options',
  '@curl_insecure',
  '@curl_location',
  '@curl_compressed',
  '@curl_max_time 10.5',
  'GET https://example.test/options',
  '@curl_connect_timeout = 3',
}, '/tmp/curl.http'))
assert(not curl_directives[1].curl_options.insecure)
assert(curl_directives[2].curl_options.insecure)
assert(curl_directives[2].curl_options.location)
assert(curl_directives[2].curl_options.compressed)
assert(curl_directives[2].curl_options.max_time == '10.5')
assert(curl_directives[2].curl_options.connect_timeout == '3')
local directive_body = assert(parser.parse({
  'POST https://example.test/body',
  '',
  '@curl_insecure',
}, '/tmp/body.http'))[1]
assert(not directive_body.curl_options.insecure and directive_body.body == '@curl_insecure')
invalid, err = parser.parse({ '@curl_max_time zero', 'GET https://example.test' }, '/tmp/api.http')
assert(invalid == nil and err:find('requires a positive number', 1, true))
invalid, err = parser.parse({ '@curl_typo', 'GET https://example.test' }, '/tmp/api.http')
assert(invalid == nil and err:find('Unsupported curl option', 1, true))
invalid, err = parser.parse({ '@base_url https://example.test' }, '/tmp/api.http')
assert(invalid == nil and err:find('Invalid variable definition', 1, true))

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')
vim.fn.writefile({ 'base_url=https://second.test', 'token=second' }, fixture .. '/.env.local')
vim.fn.writefile({ 'base_url=https://first.test', 'token=first' }, fixture .. '/.env')
local env = variables.environment(fixture .. '/api.http', {
  env_files = { '.env', '.env.local' },
  variables = { token = 'configured' },
})
assert(env.base_url == 'https://second.test' and env.token == 'configured')
local inline_env = vim.tbl_extend('force', env, inline[2].variables)
local inline_expanded = assert(variables.expand_request(inline[2], inline_env))
assert(inline_expanded.url == 'https://api.example.test/users')
assert(inline_expanded.headers.Authorization == 'Bearer local-token')
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
assert(not vim.tbl_contains(curl.build(curl_directives[1], paths), '--insecure'))
local option_args = table.concat(curl.build(curl_directives[2], paths), '\0')
assert(option_args:find('--insecure\0', 1, true))
assert(option_args:find('--location\0', 1, true))
assert(option_args:find('--compressed\0', 1, true))
assert(option_args:find('--max-time' .. '\0' .. '10.5', 1, true))
assert(option_args:find('--connect-timeout' .. '\0' .. '3', 1, true))
assert(table.concat(curl.build({ method = 'HEAD', url = 'https://example.test', headers = {} }, paths), '\0'):find('--head', 1, true))
vim.fn.delete(fixture, 'rf')
print('PASS: parser, variables, curl argv')
vim.cmd('qa!')
