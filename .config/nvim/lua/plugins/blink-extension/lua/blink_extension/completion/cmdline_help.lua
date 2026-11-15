local task = require('blink.lib.task')
local fs = require('blink.lib.fs')

local help = {}
help.__index = help

function help.new()
  return setmetatable({ files = {}, snippets = {}, queue = {}, active = 0 }, help)
end

-- Cache in-flight reads too. Selection cancellation must never cancel shared I/O.
-- Limit both the number of open files and the amount read from each file.
function help:read(path)
  if self.files[path] then return self.files[path] end
  self.files[path] = task.new(function(resolve)
    self.queue[#self.queue + 1] = { path = path, resolve = resolve }
  end)
  self:pump()
  return self.files[path]
end

function help:pump()
  while self.active < 4 and #self.queue > 0 do
    local job = table.remove(self.queue, 1)
    self.active = self.active + 1
    fs.read(job.path, 2 * 1024 * 1024)
      :catch(function() return '' end)
      :schedule()
      :map(function(data)
        self.active = self.active - 1
        job.resolve(vim.split(data or '', '\n', { plain = true }))
        self:pump()
      end)
  end
end

local function locations(command, info)
  local roots, owners, seen = {}, {}, {}
  local function add(root)
    if not seen[root] then
      seen[root] = true
      roots[#roots + 1] = root
    end
  end
  for _, root in ipairs(vim.api.nvim_list_runtime_paths()) do add(root) end

  -- Lazy command placeholders have no desc; consult installed docs without loading
  -- the plugin. Resolved handlers remain available after the plugin is loaded.
  local config = package.loaded['lazy.core.config']
  local plugins = config and config.plugins or {}
  local origin
  if info and type(info.callback) == 'function' then
    origin = debug.getinfo(info.callback, 'S').source:gsub('^@', '')
  elseif info and info.script_id and info.script_id > 0 then
    local scripts = vim.fn.getscriptinfo({ sid = info.script_id })
    origin = scripts[1] and scripts[1].name
  end
  local names = vim.tbl_keys(plugins)
  table.sort(names)
  for _, name in ipairs(names) do
    local plugin = plugins[name]
    if plugin.dir then
      add(plugin.dir)
      local commands = plugin._ and plugin._.handlers and plugin._.handlers.cmd or {}
      if commands[command] or (origin and vim.startswith(origin, plugin.dir .. '/')) then
        owners[#owners + 1] = plugin.dir
      end
    end
  end
  return roots, owners
end

function help:index(roots)
  local key = table.concat(roots, '\n')
  if self.index_key == key then return self.index_task end
  self.index_key = key
  local reads = {}
  for _, root in ipairs(roots) do reads[#reads + 1] = self:read(root .. '/doc/tags') end
  self.index_task = task.all(reads):map(function(files)
    local index = {}
    for i, lines in ipairs(files) do
      for _, line in ipairs(lines) do
        local tag, filename = line:match('^([^\t]+)\t([^\t]+)\t')
        if tag and not index[tag] then
          index[tag] = { tag = tag, path = roots[i] .. '/doc/' .. filename }
        end
      end
    end
    return index
  end)
  return self.index_task
end

-- Stop at the next help entry/section, with a hard cap for long sections.
local function excerpt(lines, start, query)
  local result = {}
  for i = start, math.min(#lines, start + 44) do
    local line = lines[i]:gsub('\r$', '')
    if i > start and (line:match('^%s*[=%-][=%-][=%-]+%s*$') or line:match('%*[^%s*]+%*')) then break end
    -- List-style generated help (e.g. Obsidian) has no per-command tags.
    if i > start and line:match('^%s*[-*]%s+`?:%u') then break end
    if i > start and query then
      if lines[start]:match('^%s*|') and line:match('^%s*|') then break end
      if line:match('^%s*`?:' .. vim.pesc(query.command) .. '%f[%W]') then break end
      if lines[start]:match('^%s*[-*]%s+`') and line:match('^%s*[-*]%s+`') then break end
    end
    -- Native help indents prose by three tabs; avoid wasting the float's width.
    result[#result + 1] = line:gsub('^\t\t\t', ''):gsub('\t', '  ')
  end
  while result[#result] == '' do table.remove(result) end
  return table.concat(result, '\n')
end

function help:tagged(entry)
  return self:read(entry.path):map(function(lines)
    local anchor = '*' .. entry.tag .. '*'
    for i, line in ipairs(lines) do
      if line:find(anchor, 1, true) then
        return { text = excerpt(lines, i), tag = entry.tag }
      end
    end
  end)
end

local function argument_match(line, query)
  local full = ':' .. query.command .. ' ' .. table.concat(query.arguments, ' ')
  local _, finish = line:find(full, 1, true)
  if finish and not line:sub(finish + 1, finish + 1):match('[%w_]') then
    return line:match('^%s*[-*]?%s*`?:') and 3 or 1
  end
  -- Tables and definition lists inside the owning plugin's docs may omit the
  -- parent command, e.g. FzfLua's `files` row. Only its first cell/token counts.
  local cell = line:match('^%s*|%s*(.-)%s*|') or line:match('^%s*[-*]%s+`([^`]+)`')
  if cell then
    cell = vim.trim(cell:gsub('`', ''))
    if cell == table.concat(query.arguments, ' ') then return 4 end
  end
end

function help:plugin_command(command, owners, query, parent_entry)
  local scans = {}
  local function scan(path)
    return self:read(path):map(function(lines)
      local best
      for i, line in ipairs(lines) do
        local score
        if query then
          score = argument_match(line, query)
        else
          local _, finish = line:find(':' .. command, 1, true)
          if finish and not line:sub(finish + 1, finish + 1):match('[%w_]') then
            score = line:match('^%s*[-*]?%s*`?(:[%w]+)') == ':' .. command and 2 or 1
          end
        end
        if score and (not best or score > best.score) then
          best = { text = excerpt(lines, i, query), score = score }
        end
      end
      return best or false
    end)
  end
  if query and parent_entry then scans[#scans + 1] = task.all({ scan(parent_entry.path) }) end
  for _, root in ipairs(owners) do
    scans[#scans + 1] = fs.list_dir(root .. '/doc', 100)
      :catch(function() return {} end)
      :schedule()
      :map(function(entries)
        local reads = {}
        table.sort(entries, function(a, b) return a.name < b.name end)
        for _, entry in ipairs(entries) do
          if entry.name:match('%.txt$') then
            reads[#reads + 1] = scan(root .. '/doc/' .. entry.name)
          end
        end
        return task.all(reads)
      end)
  end
  return task.all(scans):map(function(results)
    local best
    for _, snippets in ipairs(results) do
      for _, snippet in ipairs(snippets) do
        if snippet and (not best or snippet.score > best.score) then best = snippet end
      end
    end
    return best
  end)
end

local function contextual_tags(query, owners, parent_entry)
  local names = { query.command, query.command:lower() }
  local aliases = { syntax = 'syn', highlight = 'hi' }
  if aliases[query.command] then names[#names + 1] = aliases[query.command] end
  for _, root in ipairs(owners) do names[#names + 1] = vim.fs.basename(root):gsub('%.n?vim$', '') end
  if parent_entry then names[#names + 1] = vim.fs.basename(parent_entry.path):gsub('%.txt$', ''):gsub('%.n?vim$', '') end
  local tags = {}
  for _, name in ipairs(names) do
    for _, separator in ipairs({ '-', '.', '_', ' ' }) do
      for first = 1, math.min(#query.arguments, 8) do
        local args = {}
        for i = first, #query.arguments do args[#args + 1] = query.arguments[i]:gsub('^%-+', ''):gsub('=$', '') end
        local tag = name .. separator .. table.concat(args, separator)
        tags[#tags + 1], tags[#tags + 2], tags[#tags + 3] = ':' .. tag, tag, tag .. '()'
      end
    end
  end
  return tags
end

function help:get(command, bufnr, query)
  query = query or { kind = 'command', command = command, title = ':' .. command }
  local commands = vim.api.nvim_get_commands({ builtin = false })
  local local_commands = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_commands(bufnr, {}) or {}
  local info = local_commands[command] or commands[command]
  local desc = query.kind == 'command' and info and info.desc or query.description
  local roots, owners = locations(command, info)

  local key = query.kind .. '\n' .. query.title .. '\n' .. table.concat(owners, '\n') .. '\n' .. table.concat(roots, '\n')
  if not self.snippets[key] then
    self.snippets[key] = self:index(roots):map(function(index)
      if query.kind == 'command' then
        local entry = index[':' .. command] or index[command]
        if entry then return self:tagged(entry) end
        return self:plugin_command(command, owners)
      end
      for _, tag in ipairs(query.tags) do
        if index[tag] then return self:tagged(index[tag]) end
      end
      if query.kind ~= 'argument' then return end
      local parent = index[':' .. command] or index[command]
      for _, tag in ipairs(contextual_tags(query, owners, parent)) do
        if index[tag] then return self:tagged(index[tag]) end
      end
      return self:plugin_command(command, owners, query, parent)
    end)
  end
  return self.snippets[key]:map(function(snippet)
    if not snippet and (not desc or desc == '') then return end
    local parts = { '# `' .. query.title .. '`' }
    if desc and desc ~= '' then parts[#parts + 1] = desc end
    if snippet then
      -- Preserve vimdoc layout and example blocks without interpreting help as Markdown.
      parts[#parts + 1] = '~~~~vimdoc\n' .. snippet.text .. '\n~~~~'
      if snippet.tag then parts[#parts + 1] = 'Help: `:help ' .. snippet.tag .. '`' end
    end
    return { kind = 'markdown', value = table.concat(parts, '\n\n') }
  end)
end

return help
