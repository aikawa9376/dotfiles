-- Optional Rust shortest-path worker. Tree conversion and painting stay in Lua.
local M = { config = { backend = 'auto', min_nodes = 64, workers = 2 },
  stats = { started = 0, completed = 0, failed = 0, cancelled = 0 } }
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(
  vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))))
local binary = require('git.features.syntax_native_build').new(plugin .. '/native/src/main.rs',
  plugin .. '/../../../bin')
local queue, running, active = {}, {}, 0
local pump

function M.command()
  if M.config.backend == 'lua' then return nil end
  if M.config.command then
    return vim.fn.executable(M.config.command) == 1 and M.config.command or nil
  end
  return binary.command()
end

local function request(command, input, valid, done, background)
  local task = { command = command, input = input, valid = valid, done = done, background = background }
  queue[#queue + 1] = task
  pump()
end
pump = function()
  while active < M.config.workers and #queue > 0 do
    local selected = 1
    for index, task in ipairs(queue) do
      if not task.background or not task.background() then selected = index; break end
    end
    local task = table.remove(queue, selected)
    if not task.valid() then task.done(nil)
    else
      active, running[task] = active + 1, true
      local timer = vim.uv.new_timer()
      local finished = false
      local function finish(output)
        if finished then return end
        finished = true
        timer:stop(); timer:close()
        active, running[task] = active - 1, nil
        task.input, task.process = nil, nil
        if output then M.stats.completed = M.stats.completed + 1
        elseif not task.cancelled then M.stats.failed = M.stats.failed + 1 end
        task.done(output)
        pump()
      end
      local ok, process = pcall(vim.system, { task.command }, { stdin = task.input, text = false, timeout = 120000 },
        function(result) vim.schedule(function() finish(result.code == 0 and result.stdout or nil) end) end)
      if not ok then finish(nil)
      elseif not finished then
        task.process = process
        M.stats.started = M.stats.started + 1
        timer:start(25, 25, vim.schedule_wrap(function()
          if finished or task.valid() then return end
          task.cancelled = true
          M.stats.cancelled = M.stats.cancelled + 1
          pcall(process.kill, process, 15)
          finish(nil)
        end))
      end
    end
  end
end

local function size(first)
  local count = 0
  while first do count = count + 1 + (first.descendants or 0); first = first.next end
  return count
end
local function nodes(first, checkpoint)
  local result, index = {}, {}
  local function append(node)
    result[#result + 1], index[node] = node, #result + 1
    if checkpoint and #result % 128 == 0 then checkpoint() end
    for _, child in ipairs(node.children or {}) do append(child) end
  end
  while first do append(first); first = first.next end
  return result, index
end
local actions = { 'equal', 'delimiters', 'left', 'right', 'replace' }
local function decode(output, left, right, checkpoint)
  local at = 5
  local function number()
    local a, b, c, d = output:byte(at, at + 3)
    assert(d, 'truncated search result')
    at = at + 4
    return a + b * 256 + c * 65536 + d * 16777216
  end
  assert(output:sub(1, 4) == 'GSR1', 'unsupported search result')
  local status, count = number(), number()
  assert(status <= 1 and count <= 3000000 and #output == 12 + count * 16, 'invalid search result')
  if status == 1 then assert(count == 0); return nil end
  assert(count > 0, 'empty successful search path')
  local vertex = {}
  for index = 1, count do
    local action, old, new, pct = number(), number(), number(), number()
    assert(actions[action] and old <= #left and new <= #right and pct <= 100, 'invalid search step')
    assert((action == 4 or old > 0) and (action == 3 or new > 0), 'missing search node')
    vertex.a, vertex.b = left[old], right[new]
    vertex = { prev = vertex, action = actions[action], pct = pct }
    if checkpoint and index % 128 == 0 then checkpoint() end
  end
  return vertex
end

function M.route(lhs, rhs, checkpoint, valid, background)
  local command = M.command()
  if not command or size(lhs) + size(rhs) < M.config.min_nodes then return nil, false end
  local left, li = nodes(lhs, checkpoint)
  local right, ri = nodes(rhs, checkpoint)
  local pieces, numbers = { 'GSD1' }, {}
  local function number(value)
    local packed = numbers[value]
    if not packed then
      packed = string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
      numbers[value] = packed
    end
    pieces[#pieces + 1] = packed
  end
  local function text(value) value = value or ''; number(#value); pieces[#pieces + 1] = value end
  number(3000000); number(#left); number(#right)
  local kinds = { normal = 0, string = 1, comment = 2, text = 3 }
  for _, side in ipairs({ { left, li }, { right, ri } }) do
    for index, node in ipairs(side[1]) do
      number(node.content_id); number(node.depth); number(side[2][node.children and node.children[1]] or 0)
      number(side[2][node.next] or 0); number(kinds[node.kind] or 0); number(node.children and 1 or 0)
      number((node.text == ',' or node.text == ';' or node.text == '.') and 1 or 0)
      text(node.text); text(node.open and node.open.text); text(node.close and node.close.text)
      if checkpoint and index % 128 == 0 then checkpoint() end
    end
  end
  local input = table.concat(pieces)
  if #input > 64 * 1024 * 1024 then return nil, false end
  local output
  coroutine.yield({ wait = function(resume)
    request(command, input, valid, function(result) output = result; resume() end, background)
  end })
  if not output then return nil, false end
  -- Unsupported protocol or malformed replies use the resident Lua search.
  local ok, result = pcall(decode, output, left, right, checkpoint)
  if not ok then M.stats.failed = M.stats.failed + 1; return nil, false end
  return result, true
end

return M
