local M = {}

local ns = vim.api.nvim_create_namespace("diffview_extension_review")
local panel_ns = vim.api.nvim_create_namespace("diffview_extension_review_panel")
local states = {}

local function controller()
  return require("lazyagent.acp.git_review_controller")
end

local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() or nil
end

local function state(view)
  if not view or not view.tabpage then return nil end
  states[view.tabpage] = states[view.tabpage] or { visibility = 1 }
  return states[view.tabpage]
end

local function reviews_for(view)
  local s = state(view)
  if not s or not s.changeset_id then return {} end
  local reviews = controller().list(nil, s.lineage_id) or {}
  table.sort(reviews, function(a, b) return tostring(a.created_at) < tostring(b.created_at) end)
  return reviews
end

local function current_file(view, bufnr)
  local layout = view and view.cur_layout
  local entry = view and (view.cur_entry or (view.panel and view.panel.cur_item and view.panel.cur_item[2]))
  for _, win in ipairs(layout and layout.windows or {}) do
    if win.file and win.file.bufnr == bufnr then
      return (entry and entry.path) or win.file.path, win.file.symbol == "a" and "before" or "after"
    end
  end
  return entry and entry.path or nil, "after"
end

local function annotations_for(view, path, side, include_hidden)
  local s = state(view)
  if not s or (s.visibility == 3 and not include_hidden) then return {} end
  local result = {}
  local reviews = reviews_for(view)
  local latest = reviews[#reviews]
  local latest_change
  for _, change in ipairs(latest and latest.changes or {}) do if change.path == path then latest_change = change; break end end
  for _, review in ipairs(reviews) do
    for _, annotation in ipairs(review.annotations or {}) do
      local target = annotation.target or {}
      local same_path = annotation.path == path
      -- File-level findings belong to the file panel.  Treating them as
      -- findings for either diff side makes them match every cursor line.
      local same_side = target.side == side
      if same_path and same_side and (s.visibility == 2 or not annotation.resolved) then
        local copy = vim.deepcopy(annotation)
        copy.review_id = review.review_id
        copy.reviewer = review.reviewer
        copy.review_created_at = review.created_at
        local expected = latest_change and (side == "before" and latest_change.before_blob or latest_change.after_blob)
        copy.outdated = target.blob_hash and expected and target.blob_hash ~= expected.hash or false
        result[#result + 1] = copy
      end
    end
  end
  return result
end

local function annotation_text(annotation)
  local prefix = annotation.resolved and "✓ 💬" or annotation.outdated and "↻ 💬" or "💬"
  local label = annotation.label and ("[" .. annotation.label .. "] ") or ""
  return string.format(" %s %s%s", prefix, label, annotation.summary or annotation.rationale or "Review note")
end

local function render_buffer(view, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local path, side = current_file(view, bufnr)
  if not path then return end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local grouped = {}
  for _, annotation in ipairs(annotations_for(view, path, side)) do
    local line = tonumber(annotation.target and annotation.target.start_line)
    if line then
      line = math.max(1, math.min(line, line_count))
      grouped[line] = grouped[line] or {}
      grouped[line][#grouped[line] + 1] = annotation
    end
  end
  for line, annotations in pairs(grouped) do
    local chunks = {}
    for index, annotation in ipairs(annotations) do
      if index > 1 then chunks[#chunks + 1] = { " · ", "Comment" } end
      chunks[#chunks + 1] = { annotation_text(annotation), annotation.resolved and "Comment" or "DiagnosticInfo" }
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
      virt_text = chunks, virt_text_pos = "eol", priority = 120,
    })
  end
end

local function render_panel(view)
  local panel = view and view.panel
  local bufnr = panel and panel.bufid
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, panel_ns, 0, -1)
  local counts, overall = {}, 0
  for _, review in ipairs(reviews_for(view)) do
    for _, annotation in ipairs(review.annotations or {}) do
      if annotation.path and not annotation.resolved then
        counts[annotation.path] = (counts[annotation.path] or 0) + 1
      elseif not annotation.path and not annotation.resolved then
        overall = overall + 1
      end
    end
  end
  if overall > 0 and vim.api.nvim_buf_line_count(bufnr) > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, panel_ns, 0, 0, {
      virt_text = { { "  💬 overall:" .. overall, "DiagnosticInfo" } }, virt_text_pos = "eol",
    })
  end
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    for path, count in pairs(counts) do
      if line:find(vim.pesc(vim.fn.fnamemodify(path, ":t"))) then
        vim.api.nvim_buf_set_extmark(bufnr, panel_ns, row - 1, 0, {
          virt_text = { { "  💬" .. count, "DiagnosticInfo" } }, virt_text_pos = "eol",
        })
        break
      end
    end
  end
  if M._setup_panel_keymaps then M._setup_panel_keymaps(view, bufnr) end
end

local keymaps

local function hook_panel(view)
  local panel = view and view.panel
  if not panel or panel._lazyagent_review_hooked then return end
  panel._lazyagent_review_hooked = true

  local function wrap(method)
    local original = panel[method]
    if type(original) ~= "function" then return end
    panel[method] = function(self, ...)
      local result = original(self, ...)
      vim.schedule(function()
        if self == panel and self.bufid and vim.api.nvim_buf_is_valid(self.bufid) then
          render_panel(view)
        end
      end)
      return result
    end
  end

  -- redraw() normally writes the panel buffer. Some auto-resize paths call
  -- render() and then write it directly, so hook both entry points.
  wrap("render")
  wrap("redraw")
end

local function refresh(view)
  if not view then return end
  hook_panel(view)
  for _, win in ipairs(view.cur_layout and view.cur_layout.windows or {}) do
    if win.file and win.file.bufnr then
      keymaps(view, win.file.bufnr)
      render_buffer(view, win.file.bufnr)
    end
  end
  render_panel(view)
end

local function at_cursor(view, all)
  local bufnr = vim.api.nvim_get_current_buf()
  local path, side = current_file(view, bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local result = {}
  local in_panel = view.panel and view.panel.bufid == bufnr
  if in_panel then
    local file = type(view.panel.cur_file) == "function" and view.panel:cur_file() or view.cur_entry
    path = file and file.path or path
    for _, review in ipairs(reviews_for(view)) do
      for _, annotation in ipairs(review.annotations or {}) do
        local target = annotation.target or {}
        if (not annotation.path or (annotation.path == path and target.side == "file"))
          and (all or not annotation.resolved)
        then
          local copy = vim.deepcopy(annotation)
          copy.review_id, copy.reviewer, copy.review_created_at = review.review_id, review.reviewer, review.created_at
          result[#result + 1] = copy
        end
      end
    end
    return result, path, "file", row
  end
  for _, annotation in ipairs(annotations_for(view, path, side, all)) do
    local first = tonumber(annotation.target and annotation.target.start_line)
    local last = tonumber(annotation.target and annotation.target.end_line) or first
    if not first or (row >= first and row <= last) then result[#result + 1] = annotation end
  end
  return result, path, side, row
end

local function popup(view)
  local annotations = at_cursor(view, true)
  if #annotations == 0 then vim.notify("LazyAgent Review: no finding at cursor", vim.log.levels.INFO); return end
  local lines = {}
  for index, annotation in ipairs(annotations) do
    if index > 1 then vim.list_extend(lines, { "", "---", "" }) end
    lines[#lines + 1] = string.format("## %s%s", annotation.label and ("[" .. annotation.label .. "] ") or "", annotation.summary or "Review note")
    vim.list_extend(lines, { "", annotation.rationale or annotation.summary or "" })
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("_%s · %s%s_", annotation.reviewer or "User", annotation.review_created_at or "", annotation.outdated and " · outdated" or "")
    for _, reply in ipairs(annotation.replies or {}) do
      vim.list_extend(lines, { "", "> " .. tostring(reply.body or "") })
    end
  end
  local width = math.min(100, math.max(40, vim.o.columns - 8))
  local height = math.min(#lines + 2, math.max(8, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { relative = "editor", style = "minimal", border = "rounded", width = width, height = height, row = 2, col = math.floor((vim.o.columns - width) / 2) })
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
end

local function active_review(view)
  local reviews = reviews_for(view)
  return reviews[#reviews]
end

local function comment(view, range)
  local review = active_review(view)
  if not review then vim.notify("LazyAgent Review: run :LazyAgentReview first", vim.log.levels.WARN); return end
  local _, path, side, row = at_cursor(view, true)
  if not path then return end
  local first, last = row, row
  if range then first, last = range[1], range[2] end
  require("lazyagent.acp.review_feedback").open_editor({
    source_bufnr = vim.api.nvim_get_current_buf(),
    source_winid = vim.api.nvim_get_current_win(),
    title = string.format(" LazyAgent Review Note · %s:%d%s ", path, first, last ~= first and ("-" .. last) or ""),
    submit_desc = "Save Diffview review comment",
    on_submit = function(text)
      local saved, err = controller().add_comment(review.review_id, {
        rationale = text, path = path,
        target = { side = side, start_line = first, end_line = last },
      })
      if not saved then return nil, err end
      refresh(view)
      return true
    end,
  })
end

local function file_comment(view)
  local review = active_review(view)
  local file = view.panel and type(view.panel.cur_file) == "function" and view.panel:cur_file() or view.cur_entry
  local path = file and file.path
  if not review or not path then return end
  require("lazyagent.acp.review_feedback").open_editor({
    title = " LazyAgent File Review Note · " .. path .. " ", submit_desc = "Save file review comment",
    on_submit = function(text)
      local saved, err = controller().add_comment(review.review_id, {
        rationale = text, path = path, target = { side = "file" },
      })
      if not saved then return nil, err end
      refresh(view); return true
    end,
  })
end

local function send(view)
  local annotations = at_cursor(view, true)
  local review = annotations[1] and controller().get(annotations[1].review_id) or nil
  if not review or controller().pending_feedback_count(review) == 0 then
    local reviews = reviews_for(view)
    for index = #reviews, 1, -1 do
      if controller().pending_feedback_count(reviews[index]) > 0 then review = reviews[index]; break end
    end
  end
  if not review then return end
  local count = controller().pending_feedback_count(review)
  if count == 0 then vim.notify("LazyAgent Review: no pending feedback", vim.log.levels.INFO); return end
  vim.ui.select({ "Send", "Cancel" }, { prompt = string.format("Send %d review item(s) to %s?", count, review.reviewer or "reviewer") }, function(choice)
    if choice ~= "Send" then return end
    local ok, err = controller().send_feedback(review.review_id)
    if not ok then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.ERROR) end
  end)
end

local function action_menu(view)
  local annotations = at_cursor(view, true)
  local items = { "Add file comment", "Add overall comment", "Rerun review" }
  if annotations[1] then
    table.insert(items, 1, annotations[1].resolved and "Mark unresolved" or "Resolve finding")
    if annotations[1].author and annotations[1].author.type == "user" then
      table.insert(items, 2, "Edit comment")
      table.insert(items, 3, "Delete comment")
    end
  end
  vim.ui.select(items, { prompt = "LazyAgent review action:" }, function(choice)
    local annotation = annotations[1]
    if choice == "Resolve finding" or choice == "Mark unresolved" then
      controller().toggle_resolved(annotation.review_id, annotation.id); refresh(view)
    elseif choice == "Delete comment" then
      controller().update_annotation(annotation.review_id, annotation.id, function() return false end); refresh(view)
    elseif choice == "Edit comment" then
      require("lazyagent.acp.review_feedback").open_editor({
        title = " Edit LazyAgent Review Note ", text = annotation.rationale or annotation.summary,
        submit_desc = "Update review comment",
        on_submit = function(text)
          local saved, err = controller().update_annotation(annotation.review_id, annotation.id, function(value)
            value.rationale, value.summary, value.pending = text, nil, true
            return value
          end)
          if not saved then return nil, err end
          refresh(view); return true
        end,
      })
    elseif choice == "Rerun review" then
      local review = active_review(view)
      if review then controller().rerun(review.review_id) else controller().start("") end
    elseif choice == "Add file comment" or choice == "Add overall comment" then
      local review = active_review(view)
      local _, path = at_cursor(view, true)
      require("lazyagent.acp.review_feedback").open_editor({
        title = " LazyAgent Review Note ", submit_desc = "Save review comment",
        on_submit = function(text)
          local saved, err = controller().add_comment(review.review_id, choice == "Add overall comment"
            and { rationale = text, target = { side = "overall" } }
            or { rationale = text, path = path, target = { side = "file" } })
          if not saved then return nil, err end
          refresh(view); return true
        end,
      })
    end
  end)
end

local function navigate(view, delta)
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if delta > 0 then
    for _, mark in ipairs(marks) do if mark[2] > row then vim.api.nvim_win_set_cursor(0, { mark[2] + 1, 0 }); return end end
  else
    for index = #marks, 1, -1 do if marks[index][2] < row then vim.api.nvim_win_set_cursor(0, { marks[index][2] + 1, 0 }); return end end
  end

  local entries, current_index = {}, nil
  if view.files and type(view.files.iter) == "function" then
    for _, entry in view.files:iter() do
      entries[#entries + 1] = entry
      if view.cur_entry == entry then current_index = #entries end
    end
  elseif view.panel and view.panel.cur_item and view.panel.cur_item[1] then
    for _, entry in ipairs(view.panel.cur_item[1].files or {}) do
      entries[#entries + 1] = entry
      if view.panel.cur_item[2] == entry then current_index = #entries end
    end
  end
  if #entries > 1 and current_index then
    for offset = 1, #entries - 1 do
      local index = ((current_index - 1 + delta * offset) % #entries) + 1
      local entry = entries[index]
      local side = #annotations_for(view, entry.path, "after") > 0 and "after"
        or (#annotations_for(view, entry.path, "before") > 0 and "before" or nil)
      if side then
        view:set_file(entry, false, true)
        vim.schedule(function()
          for _, win in ipairs(view.cur_layout and view.cur_layout.windows or {}) do
            local win_side = win.file and win.file.symbol == "a" and "before" or "after"
            if win_side == side and win.id and vim.api.nvim_win_is_valid(win.id) then
              vim.api.nvim_set_current_win(win.id)
              render_buffer(view, win.file.bufnr)
              local next_marks = vim.api.nvim_buf_get_extmarks(win.file.bufnr, ns, 0, -1, {})
              local target = delta > 0 and next_marks[1] or next_marks[#next_marks]
              if target then vim.api.nvim_win_set_cursor(win.id, { target[2] + 1, 0 }) end
              return
            end
          end
        end)
        return
      end
    end
  end
  local target = delta > 0 and marks[1] or marks[#marks]
  if target then vim.api.nvim_win_set_cursor(0, { target[2] + 1, 0 }) end
end

keymaps = function(view, bufnr)
  if vim.b[bufnr].diffview_extension_review_keymaps then return end
  vim.b[bufnr].diffview_extension_review_keymaps = true
  local map = function(mode, lhs, rhs, desc) vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc }) end
  map("n", "K", function() popup(view) end, "Show review finding")
  map("n", "]r", function() navigate(view, 1) end, "Next review finding")
  map("n", "[r", function() navigate(view, -1) end, "Previous review finding")
  map("n", "c", function() comment(view) end, "Add review comment")
  map("x", "c", function()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    comment(view, { math.min(first, last), math.max(first, last) })
  end, "Add review range comment")
  map("n", "S", function() send(view) end, "Send review feedback")
  map("n", "v", function() local s = state(view); s.visibility = s.visibility % 3 + 1; refresh(view) end, "Cycle review annotations")
  map("n", "?", function() action_menu(view) end, "Review actions")
end

function M._setup_panel_keymaps(view, bufnr)
  if vim.b[bufnr].diffview_extension_review_keymaps then return end
  vim.b[bufnr].diffview_extension_review_keymaps = true
  local map = function(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, desc = desc }) end
  map("c", function() file_comment(view) end, "Add file review comment")
  map("K", function() popup(view) end, "Show file and overall review findings")
  map("S", function() send(view) end, "Send review feedback")
  map("v", function() local s = state(view); s.visibility = s.visibility % 3 + 1; refresh(view) end, "Cycle review annotations")
  map("?", function() action_menu(view) end, "Review actions")
end

function M.attach_current()
  local view = current_view()
  local s = state(view)
  if not s or not s.changeset_id then return end
  -- Diffview restores focus to the file panel after loading an entry, so the
  -- current buffer is not reliably one of the diff buffers by the time the
  -- scheduled event handler runs. Refresh the complete layout every time.
  refresh(view)
end

local function blob_lines(ref)
  local data = ref and controller().read_blob(ref) or ""
  if not data or data == "" then return {} end
  local lines = vim.split(data, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

function M.open(review)
  local view = current_view()
  if view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel == review.root
    and review.source and (review.source.kind == "diffview" or review.source.kind == "file_history")
    and review.source.tabpage == view.tabpage
    and review.source.instance == vim.g.diffview_extension_instance
  then
    local s = state(view); s.review_id, s.changeset_id, s.lineage_id = review.review_id, review.changeset_id, review.lineage_id
    hook_panel(view)
    refresh(view)
    return true
  end
  local api = require("diffview.api.views.diff.diff_view")
  local before, after, files = {}, {}, { working = {}, staged = {}, conflicting = {} }
  local status = { added = "A", deleted = "D", moved = "R", modified = "M" }
  for _, change in ipairs(review.changes or {}) do
    before[change.previous_path or change.path] = blob_lines(change.before_blob)
    after[change.path] = blob_lines(change.after_blob)
    files.working[#files.working + 1] = {
      path = change.path, oldpath = change.previous_path, status = status[change.operation] or "M",
      left_null = change.operation == "added", right_null = change.operation == "deleted",
      selected = #files.working == 0,
    }
  end
  -- CUSTOM revisions use the same diffview:// buffer name on both sides.
  -- Give captured commits their real revision identity, and reserve CUSTOM
  -- for the worktree side, so the two snapshots cannot collapse into one
  -- shared buffer.
  local left = review.base and api.Rev(api.RevType.COMMIT, review.base) or api.Rev(api.RevType.CUSTOM)
  local right = review.head and api.Rev(api.RevType.COMMIT, review.head) or api.Rev(api.RevType.CUSTOM)
  local custom = api.CDiffView({
    git_root = review.root,
    left = left, right = right,
    files = files, update_files = function() return files end,
    get_file_data = function(_, path, side) return side == "left" and (before[path] or {}) or (after[path] or {}) end,
  })
  hook_panel(custom)
  custom:open()
  local s = state(custom); s.review_id, s.changeset_id, s.lineage_id = review.review_id, review.changeset_id, review.lineage_id
  vim.schedule(function() refresh(custom) end)
  return true
end

function M.bind_review(view, review)
  local s = state(view); s.review_id, s.changeset_id, s.lineage_id = review.review_id, review.changeset_id, review.lineage_id
  hook_panel(view)
  refresh(view)
end

function M.cleanup()
  for tabpage in pairs(states) do if not vim.api.nvim_tabpage_is_valid(tabpage) then states[tabpage] = nil end end
end

M._states = states
M._annotations_for = annotations_for
M._render_buffer = render_buffer

return M
