local M = {}

local State = require("flash.state")
local orig_get_char = State.get_char

-- Default configuration
local config = {
  -- Highlighting priority (must be > flash backdrop priority which is 5000)
  priority = 6000,
  -- Highlight groups
  highlights = {
    primary = "FlashQuickScopePrimary",
    secondary = "FlashQuickScopeSecondary",
  },
}

-- Setup function to initialize the plugin
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  -- Define default highlight groups if not defined
  local function set_hl(name, val)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, val)
    end
  end

  set_hl("FlashQuickScopePrimary", { fg = "#ff007c", bold = true, ctermfg = 198, underline = true })
  set_hl("FlashQuickScopeSecondary", { fg = "#00f5d4", ctermfg = 45 })

  -- Hook into flash.state.get_char
  State.get_char = function(state)
    local is_char_mode = state.opts.mode == "char"

    -- Apply highlights only in char mode and when pattern is empty (waiting for target char)
    if is_char_mode and state.pattern and state.pattern:empty() then
      M.apply_highlights(state)
      vim.cmd("redraw")
    end

    -- Call original function to wait for input
    local ret = orig_get_char(state)

    -- Clear highlights after input
    if is_char_mode then
      M.clear_highlights(state)
      vim.cmd("redraw")
    end

    return ret
  end
end

-- Namespace for extmarks
local ns = vim.api.nvim_create_namespace("flash_quickscope")

function M.clear_highlights(state)
  local win = state.win
  if win and vim.api.nvim_win_is_valid(win) then
    local buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

function M.apply_highlights(state)
  local win = state.win
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2] -- 0-based byte index

  -- Get the current line
  local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
  if #lines == 0 then return end
  local line = lines[1]

  local forward = state.opts.search.forward

  local char_count = vim.fn.strchars(line)
  local cursor_char_idx = vim.fn.charidx(line, col)

  -- Determine scan range (char indices, 0-based for internal logic)
  local scan_start, scan_end
  if forward then
    scan_start = cursor_char_idx + 1
    scan_end = char_count - 1
  else
    scan_start = 0
    scan_end = cursor_char_idx - 1
  end

  if scan_start > scan_end then return end

  -- Function to check if a char is part of a "word" (highlightable char)
  -- Following quick-scope defaults: a-z, A-Z, 0-9
  local function is_allowed_char(char)
    return char:match("[a-zA-Z0-9]") ~= nil
  end

  -- Helper to handle case sensitivity based on vim options
  local ignore_case = vim.o.ignorecase
  local function char_key(c)
    return ignore_case and c:lower() or c
  end

  -- Global counts of characters seen so far (from cursor outwards)
  local seen_chars = {}

  -- Iterator for words in the direction of search
  -- Returns: start_idx, end_idx (inclusive, 0-based relative to line scan range)
  local function word_iterator()
    local idx = forward and scan_start or scan_end

    return function()
      if forward then
        if idx > scan_end then return nil end

        -- Skip non-allowed chars (delimiters)
        while idx <= scan_end do
          local char = vim.fn.strcharpart(line, idx, 1)
          if is_allowed_char(char) then break end
          local k = char_key(char)
          seen_chars[k] = (seen_chars[k] or 0) + 1
          idx = idx + 1
        end

        if idx > scan_end then return nil end

        local start_word = idx
        -- Consume allowed chars
        while idx <= scan_end do
          local char = vim.fn.strcharpart(line, idx, 1)
          if not is_allowed_char(char) then break end
          idx = idx + 1
        end
        return start_word, idx - 1
      else
        -- Backward search
        if idx < scan_start then return nil end

        -- Skip non-allowed chars (moving backwards)
        while idx >= scan_start do
          local char = vim.fn.strcharpart(line, idx, 1)
          if is_allowed_char(char) then break end
          local k = char_key(char)
          seen_chars[k] = (seen_chars[k] or 0) + 1
          idx = idx - 1
        end

        if idx < scan_start then return nil end

        local end_word = idx
        -- Consume allowed chars (moving backwards)
        while idx >= scan_start do
          local char = vim.fn.strcharpart(line, idx, 1)
          if not is_allowed_char(char) then break end
          idx = idx - 1
        end
        -- Return correct start/end for the word found (start < end)
        return idx + 1, end_word
      end
    end
  end

  for w_start, w_end in word_iterator() do
    local candidates = {}

    -- Process characters in the word
    -- We need to iterate carefully to maintain "word start" priority
    -- regardless of search direction, usually people want the start of the word highlighted.

    -- Extract word chars and their absolute indices
    local word_chars = {}
    for i = w_start, w_end do
      local char = vim.fn.strcharpart(line, i, 1)
      table.insert(word_chars, { char = char, idx = i })
    end

    -- Analyze candidates
    -- When backward, we process chars from right to left (end to start) to determine uniqueness properly against seen_chars
    if not forward then
        local reversed_chars = {}
        for i = #word_chars, 1, -1 do
            table.insert(reversed_chars, word_chars[i])
        end
        word_chars = reversed_chars
    end

    for _, item in ipairs(word_chars) do
      local char = item.char
      local k = char_key(char)
      local count = seen_chars[k] or 0

      local score = 0
      if count == 0 then
        score = 2 -- Primary (First time seen)
      elseif count == 1 then
        score = 1 -- Secondary (Second time seen)
      end

      if score > 0 then
        table.insert(candidates, { idx = item.idx, score = score, char = char })
      end
    end

    -- Update global seen counts for ALL chars in this word
    -- (Doing this AFTER candidate analysis ensures we judge uniqueness based on PREVIOUS words)
    for _, item in ipairs(word_chars) do
      local k = char_key(item.char)
      seen_chars[k] = (seen_chars[k] or 0) + 1
    end

    -- Select best candidate
    if #candidates > 0 then
      local best = nil

      -- Priority: Score > Position
      -- For Forward: closer to word start (smaller idx)
      -- For Backward: closer to word END (larger idx) because that's closer to cursor

      for _, cand in ipairs(candidates) do
        if not best then
          best = cand
        else
          if cand.score > best.score then
            best = cand
          elseif cand.score == best.score then
            if forward then
                -- Tie-breaker: closer to word start (smaller index)
                if cand.idx < best.idx then
                    best = cand
                end
            else
                -- Tie-breaker: closer to word end (larger index) - closest to cursor
                if cand.idx > best.idx then
                    best = cand
                end
            end
          end
        end
      end

      if best then
        local hl_group = best.score == 2 and config.highlights.primary or config.highlights.secondary
        local byte_idx = vim.fn.byteidx(line, best.idx)
        vim.api.nvim_buf_set_extmark(buf, ns, row, byte_idx, {
          hl_group = hl_group,
          priority = config.priority,
          strict = false,
          end_col = byte_idx + vim.fn.strlen(best.char)
        })
      end
    end
  end
end

return M
