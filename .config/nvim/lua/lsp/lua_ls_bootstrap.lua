-- Executed by the LuaLS binary (Lua 5.5), never required by Neovim.
-- LuaLS 3.19.1 loses its disk-reading workers after SIGSTOP/SIGCONT on Linux:
-- bee.epoll:wait() returns nil on EINTR, which breaks brave.start's iterator.
-- Retry only that interrupted, unbounded wait. Keep other errors visible.
-- https://github.com/LuaLS/lua-language-server/blob/3.19.1/script/brave/brave.lua

-- Resolve the installed runtime exactly as LuaLS's make/bootstrap.lua does.
-- Its native module path remains tied to the executable, even with this script.
local sep = package.config:sub(1, 1)
local separators = sep == '\\' and '/\\' or sep
local component = '[' .. separators .. ']+[^' .. separators .. ']+'
local root = assert(package.cpath:match('([^;]+)' .. component .. component .. '$'),
  'Cannot resolve LuaLS runtime from package.cpath')
package.path = root .. '/script/?.lua;' .. root .. '/script/?/init.lua'

-- Each worker has a separate Lua state; patch its native wait before it starts.
-- No installed server files, process lifetime, or workspace settings are changed.
local retry_interrupted_wait = [=[
do
  local ok, epoll = pcall(require, 'bee.epoll')
  if ok and type(epoll.create) == 'function' then
    local probe = epoll.create(1)
    if probe then
      local mt = debug.getmetatable(probe)
      local methods = mt and mt.__index
      probe:close()
      if type(methods) == 'table' and type(methods.wait) == 'function' then
        local wait = methods.wait
        methods.wait = function(self, timeout)
          if timeout ~= nil and timeout ~= -1 then return wait(self, timeout) end
          while true do
            local events, err = wait(self, timeout)
            if events or not tostring(err):find('(net:4)', 1, true) then
              return events, err
            end
          end
        end
      end
    end
  end
end
]=]

local thread = require 'bee.thread'
local create = thread.create
thread.create = function(source, ...)
  return create(retry_interrupted_wait .. source, ...)
end

arg[0] = root .. '/main.lua'
return dofile(arg[0])
