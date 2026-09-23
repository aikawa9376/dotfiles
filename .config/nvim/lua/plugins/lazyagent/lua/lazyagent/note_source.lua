-- Capture review identity independently of the lifetime of plugin buffers.
local M = {}
local note_show = require("lazyagent.note_show")

local function git(root, args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local ok, result = pcall(function() return vim.system(command, { text = true }):wait(3000) end)
  if ok and result.code == 0 then return vim.trim(result.stdout) end
end

-- Unified diff rows are not file rows. Resolve only an unambiguous, single-side
-- selection inside one hunk; everything else keeps the captured excerpt.
local function capture_diff(bufnr, root, first, last)
  if not first or not vim.tbl_contains({ "git", "fugitive" }, vim.bo[bufnr].filetype) then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local header, hunk
  for i = first, 1, -1 do
    if not hunk and lines[i]:match("^@@ ") then hunk = i end
    if lines[i]:match("^diff %-%-git ") then header = i; break end
  end
  if not header or not hunk or hunk < header then return end
  local old, new = lines[hunk]:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
  if not old then return end
  local side
  for i = first, last do
    local prefix = lines[i]:sub(1, 1)
    if prefix ~= " " and prefix ~= "+" and prefix ~= "-" then return end
    local current = prefix == "+" and "b" or prefix == "-" and "a" or nil
    if current and side and current ~= side then return end
    side = current or side
  end
  side = side or "b"
  local path, oid
  for i = header + 1, hunk - 1 do
    local a, b = lines[i]:match("^index (%x+)%.%.(%x+)")
    if a then oid = side == "a" and a or b end
    local raw = lines[i]:match(side == "a" and "^%-%-%- (.+)$" or "^%+%+%+ (.+)$")
    if raw then
      raw = raw:match("^[^\t]+")
      if raw:sub(1, 1) == '"' then
        local ok, decoded = pcall(vim.fn["fugitive#Unquote"], raw)
        if not ok then return end
        raw = decoded
      end
      path = raw:match("^[abciow12]/(.+)$")
    end
  end
  if not path then return end
  local dir_ok, dir = pcall(vim.fn.FugitiveGitDir, bufnr)
  if dir_ok and dir ~= "" then
    local ok, worktree = pcall(vim.fn.FugitiveWorkTree, dir)
    if ok and worktree ~= "" then root = worktree end
  end
  local blob = oid and git(root, { "rev-parse", "--verify", oid .. "^{blob}" })
  local revision = "working-tree"
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ok, parsed = pcall(vim.fn["fugitive#Parse"], name)
  local commit = ok and parsed[1] and parsed[1]:match("^(%x+):?$")
  for i = header - 1, 1, -1 do
    local hash = lines[i]:match("^commit (%x+)")
    if hash then commit = hash; break end
  end
  if commit then
    local resolved = git(root, { "rev-parse", "--verify", commit .. (side == "a" and "^" or "") .. "^{commit}" })
    if resolved and blob and git(root, { "rev-parse", "--verify", resolved .. ":" .. path }) == blob then
      revision = resolved
    end
  end
  old, new = tonumber(old), tonumber(new)
  local start_line, end_line
  for i = hunk + 1, last do
    local prefix = lines[i]:sub(1, 1)
    if prefix ~= " " and prefix ~= "+" and prefix ~= "-" and prefix ~= "\\" then return end
    if i >= first then
      local row = side == "a" and old or new
      start_line, end_line = start_line or row, row
    end
    if prefix == " " or prefix == "-" then old = old + 1 end
    if prefix == " " or prefix == "+" then new = new + 1 end
  end
  if not start_line or start_line < 1 then return end
  return { kind = "fugitive", root = root, path = path, revision = revision,
    side = side, blob = blob, name = name, inline_diff = true,
    review_commit = commit and git(root, { "rev-parse", "--verify", commit .. "^{commit}" }) or nil,
    start_line = start_line, end_line = end_line }
end

function M.capture(bufnr, root, first, last)
  root = vim.b[bufnr].fugitive_work_tree or root
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.b[bufnr].custom_git_commit then
    return require(package.loaded['features.commit'] and 'features.commit_notes' or 'git.features.commit_notes').capture(bufnr, first, last or first)
  end
  local saved = vim.b[bufnr].lazyagent_note_source
  if saved then return vim.deepcopy(saved) end
  local status_source = require("lazyagent.note_status").capture(bufnr, root, first, last or first)
  if status_source then return status_source end
  local source = note_show.capture(bufnr, root, first, last or first) or capture_diff(bufnr, root, first, last or first)
  -- Inspect only an already loaded Diffview, without loading it for ordinary files.
  local lib = package.loaded["diffview.lib"]
  if lib and not source then
    pcall(function()
      for _, view in ipairs(lib.views or {}) do
        local layout = view.cur_layout
        for _, symbol in ipairs(layout and layout.symbols or {}) do
          local file = layout:get_file_for(symbol)
          if file and file.bufnr == bufnr and not file.nulled then
            source = {
              kind = "diffview", root = file.adapter.ctx.toplevel,
              path = file.path, revision = file.rev.commit or (file.rev.stage and (":" .. file.rev.stage) or "working-tree"),
              side = symbol, name = name,
              review_args = view.left and view.right and (function()
                local args = { "-C=" .. file.adapter.ctx.toplevel }
                local left, right = view.left, view.right
                if left.commit and right.commit then args[#args + 1] = left.commit .. ".." .. right.commit
                elseif left.commit then args[#args + 1] = left.commit
                elseif view.rev_arg then args[#args + 1] = view.rev_arg end
                if right.stage then args[#args + 1] = "--cached" end
                if #(view.path_args or {}) > 0 then
                  args[#args + 1] = "--"
                  vim.list_extend(args, view.path_args)
                end
                return args
              end)() or nil,
            }
            return
          end
        end
      end
    end)
  end
  if not source and name:match("^fugitive://") then
    pcall(function()
      local parsed = vim.fn["fugitive#Parse"](name)
      local spec, dir = parsed[1], parsed[2]
      local revision, path = spec:match("^(:?[^:]+):(.+)$")
      if not revision and spec:match("^%x+$") then
        local repo = vim.fn.FugitiveWorkTree(dir)
        local blob = git(repo, { "rev-parse", "--verify", spec .. "^{blob}" })
        if blob then
          source = { kind = "fugitive", root = repo, revision = "blob", blob = blob,
            side = "revision", name = name }
        end
      end
      if revision and path then
        source = { kind = "fugitive", root = vim.fn.FugitiveWorkTree(dir),
          path = path, revision = revision, side = "revision", name = name }
      end
    end)
  end
  -- Closed Diffview panes still carry a URI; commit and index formats come
  -- from vcs/file.lua. Panels and custom revisions intentionally fall back.
  if not source then
    local dir, revision, path = name:match("^diffview://(.-)/(:%d:)/(.+)$")
    if not dir then dir, revision, path = name:match("^diffview://(.-)/([a-fA-F0-9]+)/(.+)$") end
    if dir and path then
      local repo = dir:match("^(.*)/%.git$")
      if repo then
        source = { kind = "diffview", root = repo, path = path,
          revision = revision:gsub(":$", ""), side = "unknown", name = name }
      end
    end
  end
  if not source and (name == "" or vim.bo[bufnr].buftype ~= "" or name:match("^%a[%w+.-]*://")) then
    source = { kind = "buffer", root = root, name = name ~= "" and name or "[No Name]", side = "unknown" }
  end
  if source then
    source.root = vim.fs.normalize(type(source.root) == "string" and source.root ~= "" and source.root or root)
    if source.kind == "fugitive" and not source.inline_diff then
      local panes = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[win].diff then panes[#panes + 1] = win end
      end
      table.sort(panes, function(a, b)
        local pa, pb = vim.api.nvim_win_get_position(a), vim.api.nvim_win_get_position(b)
        return pa[2] == pb[2] and pa[1] < pb[1] or pa[2] < pb[2]
      end)
      for i, win in ipairs(panes) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
          source.side = #panes == 2 and (i == 1 and "left/top" or "right/bottom") or ("pane " .. i)
          break
        end
      end
    end
    source.git_dir = git(source.root, { "rev-parse", "--absolute-git-dir" })
    source.filetype = source.show and "git" or source.inline_diff and (vim.filetype.match({ filename = source.path }) or "") or vim.bo[bufnr].filetype
    if source.path and source.revision ~= "working-tree" and not source.inline_diff then
      local spec = source.revision .. ":" .. source.path
      source.blob = git(source.root, { "rev-parse", "--verify", spec })
      if not source.revision:match("^:") then
        source.revision = git(source.root, { "rev-parse", "--verify", source.revision .. "^{commit}" }) or source.revision
      end
    end
  end
  return source
end

-- Match identity independently of Neovim buffer numbers. Direct blob buffers
-- have no path; other sources must agree on the file as well as the object.
function M.same(a, b)
  if not a or not b or a.kind == "buffer" or b.kind == "buffer" or a.root ~= b.root then return false end
  if a.show or b.show then return a.show == b.show and a.review_commit == b.review_commit end
  if a.path and b.path and a.path ~= b.path then return false end
  if a.revision and b.revision and a.revision:match("^%x+$") and b.revision:match("^%x+$")
    and a.revision ~= b.revision then return false end
  if a.blob or b.blob then return a.blob ~= nil and a.blob == b.blob end
  return a.path == b.path and a.revision == b.revision
end

function M.diff_range(bufnr, source, excerpt)
  if source.show then return note_show.range(bufnr, source) end
  if not source.inline_diff or not excerpt or #excerpt == 0 then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if line == excerpt[1] and i + #excerpt - 1 <= #lines then
      local equal = true
      for j = 2, #excerpt do if lines[i + j - 1] ~= excerpt[j] then equal = false; break end end
      if equal then
        local candidate = M.capture(bufnr, source.root, i, i + #excerpt - 1)
        if M.same(source, candidate) and candidate.inline_diff
          and source.side == candidate.side and source.start_line == candidate.start_line
          and source.end_line == candidate.end_line then return i, i + #excerpt - 1 end
      end
    end
  end
end

function M.fugitive_buffer(source, commit_view)
  if not source.blob and not (commit_view and source.review_commit) then return end
  local object = commit_view and source.review_commit or
    (source.path and source.revision:match("^%x+$") and (source.revision .. ":" .. source.path) or source.blob)
  if not object then return end
  local native_ok, objects = pcall(require, 'git.objects')
  if native_ok and not commit_view then
    local uri = objects.uri(source.root, object)
    local buf = vim.fn.bufadd(uri)
    local loaded = pcall(vim.fn.bufload, buf)
    if loaded and vim.api.nvim_buf_is_loaded(buf) then return buf end
  end
  local ok, uri = pcall(vim.fn["fugitive#Find"], object, source.git_dir or (source.root .. "/.git"))
  if not ok or type(uri) ~= "string" or not uri:match("^fugitive://") then return end
  local buf = vim.fn.bufadd(uri)
  local loaded = pcall(vim.fn.bufload, buf)
  if not loaded or not vim.api.nvim_buf_is_loaded(buf) then return end
  return buf
end

function M.reopen_diffview(source, line, fallback)
  if source.kind ~= "diffview" or not source.review_args then return false end
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return false end
  local created, view = pcall(lib.diffview_open, source.review_args)
  if not created or not view then return false end
  local done = false
  local function finish()
    if done then return end
    done = true
    local jumped, result = pcall(M.jump_diffview, source, line)
    if not jumped or not result then fallback() end
  end
  view.emitter:once("files_updated", function() vim.schedule(finish) end)
  if not (view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage)) then view:open()
  else vim.schedule(finish) end
  vim.defer_fn(finish, 3000)
  return true
end

-- The explicit blob segment distinguishes an immutable index snapshot from a commit.
function M.reference(source)
  if not source then return end
  local dir = source.git_dir or (source.root .. "/.git")
  if source.status then return end
  if source.show then return dir .. "//show/" .. source.review_commit end
  if source.path and source.revision and source.revision:match("^%x+$") and source.blob then
    return dir .. "//" .. source.revision .. "/" .. source.path
  elseif source.blob then
    return dir .. "//blob/" .. source.blob .. (source.path and ("/" .. source.path) or "")
  end
end

-- Notes and visual-selection scratch prompts share the same reference contract.
function M.instructions(sources)
  local lines = {}
  local formats = {}
  for _, source in ipairs(sources) do
    if M.reference(source) then
      formats[source.show and "show" or (source.revision:match("^%x+$") and source.path and "file" or "blob")] = true
    end
  end
  if next(formats) then
    lines[#lines + 1] = "Git references (1-based lines):"
    if formats.show then
      lines[#lines + 1] = "//show/<commit>: git --git-dir=<git-dir> " .. table.concat(require("lazyagent.note_show").command("<commit>"), " ")
    end
    if formats.file then lines[#lines + 1] = "//<commit>/<path>: git --git-dir=<git-dir> show <commit>:<path>" end
    if formats.blob then lines[#lines + 1] = "//blob/<oid>[/<path>]: git --git-dir=<git-dir> cat-file blob <oid>" end
  end
  return lines
end

function M.selection_text(bufnr, first, last)
  if first > last then first, last = last, first end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = require("lazyagent.util").git_root_for_path(name) or vim.fn.getcwd()
  local source = M.capture(bufnr, root, first, last)
  local reference = M.reference(source)
  if source and source.status then
    local lines = { require("lazyagent.note_status").reference(source) }
    if source.selection and not source.start_line then
      for _, line in ipairs(source.selection) do lines[#lines + 1] = '> ' .. line end
    end
    return table.concat(lines, "\n")
  end
  if reference then
    first, last = source.start_line or first, source.end_line or last
    local suffix = first == last and tostring(first) or string.format("%d-%d", first, last)
    return table.concat(M.instructions({ source }), "\n") .. "\n\n@" .. reference .. ":" .. suffix
  elseif source then
    local lines = { M.describe(source), "", "Selected code:", "```" }
    vim.list_extend(lines, vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false))
    lines[#lines + 1] = "```"
    return table.concat(lines, "\n")
  elseif name ~= "" then
    local suffix = first == last and tostring(first) or string.format("%d-%d", first, last)
    return "@" .. vim.fn.fnamemodify(name, ":.") .. ":" .. suffix
  end
end

-- Reuse a live Diffview only when the saved side still represents the same code.
function M.jump_diffview(source, line)
  local lib = package.loaded["diffview.lib"]
  if source.kind ~= "diffview" or not lib then return false end
  for _, view in ipairs(lib.views or {}) do
    if view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) and view.files then
      for _, entry in view.files:iter() do
        local file = entry.layout and entry.layout:get_file_for(source.side)
        if file and not file.nulled and file.path == source.path
          and vim.fs.normalize(file.adapter.ctx.toplevel) == source.root then
          local rev = file.rev.commit or (file.rev.stage and (":" .. file.rev.stage)) or "working-tree"
          local blob = rev ~= "working-tree" and git(source.root, { "rev-parse", "--verify", rev .. ":" .. file.path }) or nil
          if (source.blob and blob == source.blob) or (not source.blob and rev == source.revision) then
            vim.api.nvim_set_current_tabpage(view.tabpage)
            local attempts = 0
            local function focus()
              local layout = view.cur_layout
              local win = layout and layout[source.side]
              local current = layout and layout:get_file_for(source.side)
              if current and current.path == source.path and win and win.id and vim.api.nvim_win_is_valid(win.id) then
                attempts = attempts + 1
                if vim.api.nvim_win_get_buf(win.id) ~= current.bufnr then
                  if attempts < 100 then vim.defer_fn(focus, 10) end
                  return
                end
                vim.api.nvim_set_current_win(win.id)
                local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win.id))
                vim.api.nvim_win_set_cursor(win.id, { math.max(1, math.min(line, count)), 0 })
              end
            end
            view.emitter:once("file_open_post", function() vim.schedule(focus) end)
            view:set_file(entry, false, true)
            return true
          end
        end
      end
    end
  end
  return false
end

function M.describe(source)
  if source.status then return "Git status: " .. source.section .. (source.path and (" / " .. source.path) or "") end
  if source.kind == "buffer" then return "buffer snapshot: " .. source.name end
  return string.format("%s; revision=%s; side=%s; repository=%s", source.kind, source.revision, source.side, source.root)
end

function M.restore(source)
  if source.show then return note_show.read(source.root, source.review_commit) end
  if source.blob and source.blob:match("^%x+$") then
    local result = vim.system({ "git", "-C", source.root, "cat-file", "blob", source.blob }, { text = true }):wait(3000)
    if result.code == 0 then
      local lines = vim.split(result.stdout, "\n", { plain = true })
      if lines[#lines] == "" then table.remove(lines) end
      if #lines == 0 then lines = { "" } end
      return lines
    end
  end
end

return M
