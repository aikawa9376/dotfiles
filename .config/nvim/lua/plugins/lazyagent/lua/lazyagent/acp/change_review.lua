local M = {}

local operation_marker = {
  added = "A",
  modified = "M",
  deleted = "D",
  moved = "R",
}

local function latest_changed_turn(thread)
  local turns = thread and thread.change_journal and thread.change_journal.turns or {}
  for index = #turns, 1, -1 do
    if type(turns[index].changes) == "table" and #turns[index].changes > 0 then
      return turns[index]
    end
  end
  return nil
end

local function display_path(change)
  if change.operation == "moved" and change.previous_path then
    return string.format("%s -> %s", change.previous_path, change.path)
  end
  return tostring(change.path or "unknown")
end

local function split_lines(text)
  local lines = vim.split(tostring(text or ""), "\n", { plain = true })
  return #lines > 0 and lines or { "" }
end

local function set_scratch(bufnr, name, lines, filetype)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype or ""
  vim.bo[bufnr].modifiable = false
end

local function filetype_for(path)
  local extension = tostring(path or ""):match("%.([^./]+)$")
  return extension and vim.filetype.match({ filename = "file." .. extension }) or nil
end

function M.latest_turn(thread)
  return latest_changed_turn(thread)
end

function M.drawer_lines(thread, turn)
  local lines = {
    string.format("LazyAgent ACP Changes — %s", thread.title or thread.thread_id),
    string.format("Turn %s · %d file(s)", turn.turn_id or "unknown", #(turn.changes or {})),
    "",
  }
  for _, change in ipairs(turn.changes or {}) do
    local binary = change.binary == true and " [binary]" or ""
    local decision = change.decision and (" [" .. change.decision .. "]") or ""
    local decided_hunks = 0
    for _, hunk in ipairs(change.hunks or {}) do
      if hunk.decision then
        decided_hunks = decided_hunks + 1
      end
    end
    local hunk_state = decided_hunks > 0 and string.format(" [hunks %d/%d]", decided_hunks, #change.hunks) or ""
    lines[#lines + 1] = string.format(
      "%s  %s%s%s%s",
      operation_marker[change.operation] or "?",
      display_path(change),
      binary,
      decision,
      hunk_state
    )
  end
  return lines
end

function M.new(opts)
  opts = opts or {}
  local review = {}

  local function read_blob(ref)
    if not ref then
      return ""
    end
    return opts.read_blob(ref)
  end

  function review.open_change(thread, turn, change, index)
    if change.binary == true then
      local bufnr = vim.api.nvim_create_buf(false, true)
      set_scratch(bufnr, string.format("lazyagent://binary-change/%s/%d", turn.turn_id, index), {
        "LazyAgent ACP Binary Change",
        "",
        "operation: " .. tostring(change.operation),
        "path: " .. tostring(change.path),
        "previous path: " .. tostring(change.previous_path or ""),
        "before: " .. vim.inspect(change.before_blob),
        "after: " .. vim.inspect(change.after_blob),
      }, "markdown")
      vim.cmd("tabnew")
      vim.api.nvim_win_set_buf(0, bufnr)
      return true
    end

    local before, before_err = read_blob(change.before_blob)
    local after, after_err = read_blob(change.review_blob or change.after_blob)
    if before == nil or after == nil then
      vim.notify("LazyAgent ACP: failed to read change blobs: " .. tostring(before_err or after_err), vim.log.levels.ERROR)
      return false
    end
    local suffix = tostring((vim.uv or vim.loop).hrtime())
    local before_buf = vim.api.nvim_create_buf(false, true)
    local after_buf = vim.api.nvim_create_buf(false, true)
    local ft = filetype_for(change.path)
    set_scratch(before_buf, "lazyagent://before/" .. suffix .. "/" .. display_path(change), split_lines(before), ft)
    set_scratch(after_buf, "lazyagent://after/" .. suffix .. "/" .. display_path(change), split_lines(after), ft)

    vim.cmd("tabnew")
    local before_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(before_win, before_buf)
    vim.cmd("vsplit")
    local after_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(after_win, after_buf)
    vim.api.nvim_set_current_win(before_win)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(after_win)
    vim.cmd("diffthis")
    return true
  end

  function review.open(thread)
    local turn = latest_changed_turn(thread)
    if not turn then
      return nil, "thread has no completed file changes"
    end
    local name = string.format("lazyagent://changes/%s/%s", thread.thread_id, turn.turn_id)
    local existing = vim.fn.bufnr(name)
    local bufnr = existing >= 0 and existing or vim.api.nvim_create_buf(false, true)
    if existing < 0 then
      vim.api.nvim_buf_set_name(bufnr, name)
    end
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.drawer_lines(thread, turn))
    vim.bo[bufnr].filetype = "lazyagent_changes"
    vim.bo[bufnr].modifiable = false
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, bufnr)

    vim.keymap.set("n", "<CR>", function()
      local index = vim.api.nvim_win_get_cursor(0)[1] - 3
      local change = turn.changes[index]
      if change then
        review.open_change(thread, turn, change, index)
      end
    end, { buffer = bufnr, silent = true, desc = "Review LazyAgent ACP change" })
    vim.keymap.set("n", "a", function()
      for index, change in ipairs(turn.changes) do
        review.open_change(thread, turn, change, index)
      end
    end, { buffer = bufnr, silent = true, desc = "Review all LazyAgent ACP changes" })
    local function refresh(decided_turn)
      turn = decided_turn or turn
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.drawer_lines(thread, turn))
      vim.bo[bufnr].modifiable = false
    end
    local function decide(indices, decision)
      if type(opts.decide) ~= "function" then
        return
      end
      local decided, err = opts.decide(thread, turn, indices, decision)
      if not decided then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      refresh(decided)
    end
    local function undecided_indices()
      local indices = {}
      for index, change in ipairs(turn.changes) do
        if not change.decision then
          indices[#indices + 1] = index
        end
      end
      return indices
    end
    vim.keymap.set("n", "k", function()
      local index = vim.api.nvim_win_get_cursor(0)[1] - 3
      if turn.changes[index] and not turn.changes[index].decision then
        decide({ index }, "kept")
      end
    end, { buffer = bufnr, silent = true, desc = "Keep LazyAgent ACP file change" })
    vim.keymap.set("n", "K", function()
      local indices = undecided_indices()
      if #indices > 0 then
        decide(indices, "kept")
      end
    end, { buffer = bufnr, silent = true, desc = "Keep all LazyAgent ACP changes" })
    local function confirm_reject(indices, label)
      vim.ui.select({ "Cancel", "Reject" }, { prompt = label }, function(choice)
        if choice == "Reject" then
          decide(indices, "rejected")
        end
      end)
    end
    vim.keymap.set("n", "r", function()
      local index = vim.api.nvim_win_get_cursor(0)[1] - 3
      if turn.changes[index] and not turn.changes[index].decision then
        confirm_reject({ index }, "Reject this file change?")
      end
    end, { buffer = bufnr, silent = true, desc = "Reject LazyAgent ACP file change" })
    vim.keymap.set("n", "R", function()
      local indices = undecided_indices()
      if #indices > 0 then
        confirm_reject(indices, "Reject all file changes?")
      end
    end, { buffer = bufnr, silent = true, desc = "Reject all LazyAgent ACP changes" })
    vim.keymap.set("n", "h", function()
      local change_index = vim.api.nvim_win_get_cursor(0)[1] - 3
      local change = turn.changes[change_index]
      if not change or change.decision or type(opts.hunks) ~= "function" then
        return
      end
      local hunks, err = opts.hunks(thread, turn, change_index)
      if not hunks then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.INFO)
        return
      end
      vim.ui.select(hunks, {
        prompt = "Select change hunk:",
        format_item = function(hunk)
          local state = hunk.decision and (" [" .. hunk.decision .. "]") or ""
          return string.format(
            "@@ -%d,%d +%d,%d @@%s",
            hunk.before_start,
            hunk.before_count,
            hunk.after_start,
            hunk.after_count,
            state
          )
        end,
      }, function(hunk)
        if not hunk or hunk.decision or type(opts.decide_hunk) ~= "function" then
          return
        end
        vim.ui.select({ "Keep", "Reject", "Cancel" }, { prompt = "Hunk decision:" }, function(choice)
          if choice ~= "Keep" and choice ~= "Reject" then
            return
          end
          local decided, decide_err = opts.decide_hunk(
            thread,
            turn,
            change_index,
            hunk.index,
            choice == "Keep" and "kept" or "rejected"
          )
          if not decided then
            vim.notify("LazyAgent ACP: " .. tostring(decide_err), vim.log.levels.ERROR)
            return
          end
          refresh(decided)
        end)
      end)
    end, { buffer = bufnr, silent = true, desc = "Decide LazyAgent ACP change hunk" })
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = bufnr, silent = true, desc = "Close changes drawer" })
    return bufnr
  end

  return review
end

return M
