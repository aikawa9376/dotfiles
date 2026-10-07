-- Bounded speculative complete-file comparisons for collapsed Status/Commit files.
local M = {}
local structural = require('git.features.syntax_word_diff')
local sources = require('git.features.highlight_sources')
local jobs = require('git.features.highlight_jobs')

function M.new(bufnr, session, live)
  local entries, ordered, busy, serial, closed = {}, {}, nil, 0, false
  local self = {}
  local pump
  local function valid(entry)
    return not closed and live() and entries[entry.key] == entry
  end
  local function finish(entry)
    entry.done = true
    if busy == entry then busy = nil end
    jobs.schedule(pump)
  end
  pump = function()
    if closed or busy or not live() then return end
    for _, entry in ipairs(ordered) do
      if not entry.done then
        busy = entry
        session.request(entry.spec, function() return valid(entry) end, function(full)
          if not valid(entry) then finish(entry); return end
          if not full then finish(entry); return end
          entry.full = full
          full.parsed = full.parsed or {}
          local parsed = full.parsed[entry.lang] or {}
          full.parsed[entry.lang], entry.parsed = parsed, parsed
          local remaining = 2
          local function ready(side, source)
            if not valid(entry) then finish(entry); return end
            parsed[side] = source or false
            remaining = remaining - 1
            if remaining ~= 0 then return end
            if not parsed.old or not parsed.new then finish(entry); return end
            local _, pending = structural.compare_async(parsed.old, parsed.new, bufnr, nil, nil, true, true)
            entry.pending = pending
            if not pending then finish(entry) end
          end
          for _, side in ipairs({ 'old', 'new' }) do
            if parsed[side] ~= nil then ready(side, parsed[side])
            else structural.parse_async(full[side], entry.lang, function() return valid(entry) end,
              function(source) ready(side, source) end, function() finish(entry) end) end
          end
        end)
        return
      end
    end
  end
  function self.update(candidates)
    serial = serial + 1
    local revision = serial
    vim.defer_fn(function()
      if closed or revision ~= serial then return end
      local retained, order = {}, {}
      if live() then
        for _, item in ipairs(candidates or {}) do
          if #order >= 8 then break end
          local ft = vim.filetype.match({ filename = item.filename })
          local lang = ft and vim.treesitter.language.get_lang(ft)
          if lang and pcall(vim.treesitter.language.inspect, lang) then
            local key = lang .. '\0' .. sources.key(item.spec)
            if not retained[key] then
              local entry = entries[key] or { key = key, spec = item.spec, lang = lang }
              retained[key], order[#order + 1] = entry, entry
            end
          end
        end
      end
      entries, ordered = retained, order
      if busy and not valid(busy) then busy = nil end
      session.prune()
      pump()
    end, 200)
  end
  function self.ready()
    if busy and busy.pending then
      local pair = busy.parsed
      if pair.old.full_completed and pair.old.full_completed[pair.new] ~= nil then finish(busy) end
    end
  end
  function self.is_active(source, opposite)
    for _, entry in pairs(entries) do
      local pair = entry.parsed
      if valid(entry) and pair and pair.old == source and pair.new == opposite then return true end
    end
    return false
  end
  function self.retained(key)
    for _, entry in pairs(entries) do
      if valid(entry) and entry.key == entry.lang .. '\0' .. key then return entry.full end
    end
  end
  function self.close()
    closed, entries, ordered, busy = true, {}, {}, nil
    session.prune()
  end
  return self
end
return M
