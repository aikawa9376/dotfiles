return {
  "diff-dim",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/diff-dim",
  cmd = "DiffDim",
  config = function()
    local ns_id = vim.api.nvim_create_namespace("DimNonDiffLines")
    local blame_state = {}
    local blame_commands = {
      clear = true,
      latest = true,
      older = true,
      newer = true,
    }

    local function git_systemlist(cmd)
      local result = vim.fn.systemlist(cmd)
      if vim.v.shell_error ~= 0 then
        return nil
      end
      return result
    end

    local function get_git_context(bufnr)
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      if filepath == "" then
        vim.notify("DiffDim requires a file-backed buffer.", vim.log.levels.WARN)
        return nil
      end

      local filedir = vim.fn.fnamemodify(filepath, ":h")
      local root_result = git_systemlist(
        "git -C " .. vim.fn.shellescape(filedir) .. " rev-parse --show-toplevel"
      )
      if not root_result or not root_result[1] or root_result[1] == "" then
        vim.notify("DiffDim requires a file inside a git repository.", vim.log.levels.WARN)
        return nil
      end

      local git_root = root_result[1]
      local prefix = git_root .. "/"
      local relative_path = filepath:sub(1, #prefix) == prefix and filepath:sub(#prefix + 1)
        or vim.fn.fnamemodify(filepath, ":.")

      return {
        filepath = filepath,
        git_root = git_root,
        relative_path = relative_path,
      }
    end

    local function clear_marks(bufnr)
      local target_bufnr = bufnr == 0 and vim.api.nvim_get_current_buf()
        or bufnr
        or vim.api.nvim_get_current_buf()
      require("gitsigns").reset_base()
      vim.api.nvim_buf_clear_namespace(target_bufnr, ns_id, 0, -1)
      blame_state[target_bufnr] = nil
    end

    local function set_diff_marks(hunks, bufnr, rev)
      if hunks == nil then
        local revision = rev or "HEAD"
        vim.notify("No hunks found for revision: " .. revision, vim.log.levels.WARN)
        return
      end

      local diff_lines = {}
      for _, hunk in ipairs(hunks) do
        local count = hunk.added.count - 1
        for i = hunk.added.start, hunk.added.start + count do
          diff_lines[i] = true
        end
      end

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
      for i = 1, line_count do
        if not diff_lines[i] then
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
            line_hl_group = vim.api.nvim_get_hl_id_by_name("LineNr"),
          })
        end
      end
    end

    local function dim_lines(args)
      local rev = args.fargs[1] or nil
      local bufnr = vim.api.nvim_get_current_buf()

      blame_state[bufnr] = nil
      if rev then
        require("gitsigns").change_base(rev, false, function()
          local hunks = require("gitsigns").get_hunks(bufnr)
          set_diff_marks(hunks, bufnr, rev)
        end)
      else
        local hunks = require("gitsigns").get_hunks(bufnr)
        set_diff_marks(hunks, bufnr, nil)
      end
    end

    local function build_blame_state(bufnr)
      if vim.bo[bufnr].modified then
        vim.notify("Save the buffer before using DiffDim latest/older/newer.", vim.log.levels.WARN)
        return nil
      end

      local git_context = get_git_context(bufnr)
      if not git_context then
        return nil
      end

      local blame_output = git_systemlist(
        "git -C "
          .. vim.fn.shellescape(git_context.git_root)
          .. " blame --line-porcelain -- "
          .. vim.fn.shellescape(git_context.relative_path)
      )
      if not blame_output or #blame_output == 0 then
        vim.notify("Could not read git blame information for this file.", vim.log.levels.WARN)
        return nil
      end

      local line_commits = {}
      local commits = {}
      local current_commit = nil
      local remaining_lines = 0
      local order = 0

      for _, line in ipairs(blame_output) do
        local commit, _, _, group_count = line:match("^(%x+) (%d+) (%d+) (%d+)$")
        if commit then
          current_commit = commit
          remaining_lines = tonumber(group_count)
          if not commits[commit] then
            order = order + 1
            commits[commit] = {
              sha = commit,
              author_time = 0,
              summary = commit,
              order = order,
              line_count = 0,
            }
          end
        elseif current_commit and line:match("^author%-time ") then
          commits[current_commit].author_time = tonumber(line:match("^author%-time (%d+)$")) or 0
        elseif current_commit and line:match("^summary ") then
          commits[current_commit].summary = line:match("^summary (.*)$")
        elseif current_commit and line:sub(1, 1) == "\t" and remaining_lines > 0 then
          line_commits[#line_commits + 1] = current_commit
          commits[current_commit].line_count = commits[current_commit].line_count + 1
          remaining_lines = remaining_lines - 1
        end
      end

      local ordered_commits = {}
      for commit, info in pairs(commits) do
        if not commit:match("^0+$") then
          ordered_commits[#ordered_commits + 1] = info
        end
      end

      table.sort(ordered_commits, function(a, b)
        if a.author_time == b.author_time then
          return a.order < b.order
        end
        return a.author_time > b.author_time
      end)

      if #ordered_commits == 0 then
        vim.notify("No committed lines found in this file.", vim.log.levels.WARN)
        return nil
      end

      local state = {
        filepath = git_context.filepath,
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
        line_commits = line_commits,
        ordered_commits = ordered_commits,
        selected_index = nil,
      }
      blame_state[bufnr] = state
      return state
    end

    local function get_blame_state(bufnr)
      local state = blame_state[bufnr]
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
      if not state or state.filepath ~= filepath or state.changedtick ~= changedtick then
        return build_blame_state(bufnr)
      end
      return state
    end

    local function apply_blame_dim(bufnr, state, commit_info)
      require("gitsigns").reset_base()
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      for i = 1, line_count do
        if state.line_commits[i] ~= commit_info.sha then
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
            line_hl_group = vim.api.nvim_get_hl_id_by_name("LineNr"),
          })
        end
      end

      vim.notify(
        string.format(
          "DiffDim %s: %s (%d lines)",
          commit_info.sha:sub(1, 8),
          commit_info.summary,
          commit_info.line_count
        ),
        vim.log.levels.INFO
      )
    end

    local function dim_blame_commit(direction)
      local bufnr = vim.api.nvim_get_current_buf()
      local state = get_blame_state(bufnr)
      if not state then
        return
      end

      local index = state.selected_index
      if direction == "latest" then
        index = 1
      elseif direction == "older" then
        index = math.min((index or 1) + 1, #state.ordered_commits)
      elseif direction == "newer" then
        index = math.max((index or 2) - 1, 1)
      end

      if not index or not state.ordered_commits[index] then
        vim.notify("No matching commit found for DiffDim " .. direction .. ".", vim.log.levels.WARN)
        return
      end

      if state.selected_index == index and direction ~= "latest" then
        vim.notify("No " .. direction .. " commit found for this file.", vim.log.levels.INFO)
        return
      end

      state.selected_index = index
      apply_blame_dim(bufnr, state, state.ordered_commits[index])
    end

    local function complete_diffdim(arg_lead, cmd_line, cursor_pos)
      local _ = cmd_line
      local __ = cursor_pos
      local matches = {}
      local seen = {}

      for _, item in ipairs({ "clear", "latest", "older", "newer" }) do
        if item:find("^" .. vim.pesc(arg_lead)) then
          matches[#matches + 1] = item
          seen[item] = true
        end
      end

      for _, item in ipairs(require("utilities").get_git_completions(arg_lead, cmd_line, cursor_pos) or {}) do
        if not seen[item] then
          matches[#matches + 1] = item
          seen[item] = true
        end
      end

      return matches
    end

    vim.api.nvim_create_user_command("DiffDim", function(args)
      local command = args.fargs[1]
      if command == "clear" then
        clear_marks(0)
        print("Dimmed lines cleared.")
        return
      end

      if command and blame_commands[command] then
        dim_blame_commit(command)
        return
      end

      local marks = vim.api.nvim_buf_get_extmarks(0, ns_id, 0, -1, { limit = 1 })
      if #marks > 0 and command == nil then
        clear_marks(0)
        print("Dimmed lines cleared.")
      else
        dim_lines(args)
        print("Diff lines dimmed.")
      end
    end, {
      nargs = "?",
      complete = complete_diffdim,
    })
  end,
}
