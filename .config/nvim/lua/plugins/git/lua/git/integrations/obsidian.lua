local M = {}
function M.module(opts)
  opts = opts or {}
  return {
    id = 'obsidian', title = 'Related notes',
    before = opts.before,
    after = not opts.before and (opts.after or 'commits') or nil,
    folded = opts.folded,
    events = { { event = 'User', pattern = 'ObsidianRelatedChanged' } },
    load = function(ctx, done)
      local ok = pcall(require, 'obsidian') -- Load its existing workspace/dependency configuration lazily.
      if not ok then done(nil, 'Obsidian is unavailable'); return end
      local context = require('obsidian_extension.context')
      return require('obsidian_extension.features.related').query({
        git_context = context.for_repository(ctx.root, ctx.branch),
        min_score = 1, limit = opts.limit or 8,
      }, function(ranked, err)
        if not ranked then done(nil, err); return end
        local items = {}
        for _, candidate in ipairs(ranked) do
          local entry = candidate.entry
          items[#items + 1] = { id = entry.path, text = entry.title, path = entry.path,
            detail = entry.mtime and os.date('%Y-%m-%d', entry.mtime) or nil,
            reasons = candidate.reasons, score = candidate.score }
        end
        done(items)
      end)
    end,
    open = function(_, item)
      if vim.fn.filereadable(item.path) ~= 1 then error('Note no longer exists: ' .. item.path, 0) end
      vim.cmd('tabedit ' .. vim.fn.fnameescape(item.path))
    end,
  }
end
return M
