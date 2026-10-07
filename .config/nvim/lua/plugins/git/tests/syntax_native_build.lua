-- nvim --headless --clean -u NONE -l tests/syntax_native_build.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
local build = require('git.features.syntax_native_build')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local source = root .. '/main.rs'
vim.fn.writefile({ 'fn main() { println!("ready"); }' }, source)

local uname = vim.uv.os_uname
for _, case in ipairs({ { 'Linux', 'x86_64', 'linux-x64' },
  { 'Darwin', 'arm64', 'darwin-arm64' }, { 'Darwin', 'x86_64', 'darwin-x64' },
  { 'Linux', 'aarch64', 'linux-arm64' } }) do
  vim.uv.os_uname = function() return { sysname = case[1], machine = case[2] } end
  assert(build.new(source, root .. '/bin').path == root .. '/bin/' .. case[3] .. '/git-syntax-search',
    'worker path did not distinguish OS/CPU')
end
vim.uv.os_uname = uname

local executable, system = vim.fn.executable, vim.system
local compiler, calls, pending = false, 0, nil
vim.fn.executable = function(path)
  if path == 'rustc' then return compiler and 1 or 0 end
  return executable(path)
end
vim.system = function(command, opts, callback)
  calls = calls + 1
  assert(command[1] == 'rustc' and opts.text, 'build required something other than rustc')
  pending = { output = command[#command], callback = callback }
  return {}
end
local binary = build.new(source, root .. '/bin')
assert(not binary.command() and calls == 0, 'missing compiler did not leave Lua available')
compiler = true
assert(not binary.command() and binary.building and calls == 1, 'missing binary was not built asynchronously')
assert(not binary.command() and calls == 1, 'repeated availability checks duplicated the build')
local function output(text)
  vim.fn.writefile({ text or 'built worker' }, pending.output)
  assert(vim.uv.fs_chmod(pending.output, 493)) -- 0755
end
local function complete(code)
  pending.callback({ code = code, stderr = code ~= 0 and 'compiler failed' or '' })
  assert(vim.wait(1000, function() return not binary.building end, 1), 'build completion was not scheduled')
end
output()
assert(not binary.command(), 'incomplete build output was published')
complete(0)
assert(binary.command() == binary.path and calls == 1, 'completed binary was not reused')
assert(not vim.uv.fs_stat(pending.output), 'successful build left a temporary binary')

assert(vim.uv.fs_utime(binary.path, 1, 1))
assert(not binary.command() and calls == 2, 'outdated binary did not trigger rebuilding')
output('partial worker')
complete(1)
assert(binary.error == 'compiler failed' and not binary.command() and calls == 2,
  'failed compilation retried on every availability check')
assert(vim.fn.readfile(binary.path)[1] == 'built worker' and not vim.uv.fs_stat(pending.output),
  'failed compilation replaced the previous binary or left partial output')

vim.fn.writefile({ '// new source', 'fn main() { println!("ready"); }' }, source)
assert(not binary.command() and calls == 3, 'changed source could not retry a failed build')
output('outdated worker')
vim.fn.writefile({ '// changed during compilation', 'fn main() { println!("ready"); }' }, source)
complete(0)
assert(vim.fn.readfile(binary.path)[1] == 'built worker' and not vim.uv.fs_stat(pending.output),
  'source changes during compilation published an outdated worker')
assert(not binary.command() and calls == 4, 'new source revision did not retry')
output('current worker')
complete(0)
assert(binary.command() == binary.path and vim.fn.readfile(binary.path)[1] == 'current worker',
  'successful rebuild did not atomically replace the old binary')

local failed = build.new(source, root .. '/failed-bin')
vim.system = function() calls = calls + 1; error('spawn failed') end
assert(not failed.command() and not failed.building and failed.error:find('spawn failed', 1, true),
  'process-start failure did not recover')
local prior_calls = calls
assert(not failed.command() and calls == prior_calls, 'process-start failure repeatedly rebuilt')

local native = require('git.features.syntax_native')
native.config.backend = 'lua'
assert(not native.command() and calls == prior_calls, 'Lua-only backend triggered compilation')
native.config.backend, native.config.command = 'auto', root .. '/missing-command'
assert(not native.command() and calls == prior_calls, 'explicit missing worker triggered compilation')
native.config.command = binary.path
assert(native.command() == binary.path and calls == prior_calls, 'explicit worker was not respected')
native.config.command = nil
vim.fn.executable, vim.system = executable, system

-- A real rustc-only compile checks flags, permissions and post-build discovery.
assert(executable('rustc') == 1, 'install rustc to run the build integration test')
local real = build.new(source, root .. '/real-bin')
assert(not real.command() and real.building, 'real build blocked or failed to start')
assert(vim.wait(30000, function() return not real.building end, 10), 'real rustc build timed out')
assert(real.command() == real.path, real.error or 'real build did not produce an executable')
local result = system({ real.path }, { text = true }):wait()
assert(result.code == 0 and vim.trim(result.stdout) == 'ready', 'compiled executable did not run')
vim.fn.delete(root, 'rf')
print('PASS: Linux/Mac paths, async rustc build, atomic publication, stale-source rebuild, failure fallback and overrides')
