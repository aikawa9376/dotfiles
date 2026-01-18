local M = {}

local float_win = nil
local float_buf = nil

local reflog_redo_stack = {}

local function get_work_tree_from_fugitive()
  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == '' then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil
  end

  local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
  local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

  if vim.v.shell_error ~= 0 or work_tree == '' then
    vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
    return nil
  end

  return work_tree
end

-- Worktree cleanliness helper
local function apply_auto_stash(work_tree)
  -- Check if worktree is dirty
  local status = vim.fn.systemlist("git -C " .. vim.fn.shellescape(work_tree) .. " status --porcelain")
  if vim.v.shell_error ~= 0 then
    vim.notify("git status failed; skipping auto-stash", vim.log.levels.WARN)
    return false
  end
  if #status == 0 then
    return false
  end

  local msg = "fugitive-ext auto-stash"
  vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " stash push -u -m " .. vim.fn.shellescape(msg))
  if vim.v.shell_error ~= 0 then
    vim.notify("auto-stash failed; aborting command", vim.log.levels.ERROR)
    return nil
  end
  return true
end

local function pop_auto_stash(work_tree)
  vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " stash pop --index --quiet")
  if vim.v.shell_error ~= 0 then
    vim.notify("Auto-stash pop failed; please pop manually", vim.log.levels.ERROR)
  end
end

local function hard_reset_to_commit(work_tree, commit)
  if not commit or commit == '' then
    vim.notify("No commit to reset to", vim.log.levels.WARN)
    return false
  end

  local stashed = apply_auto_stash(work_tree)
  if stashed == nil then return false end

  local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " reset --hard " .. vim.fn.shellescape(commit)
  local output = vim.fn.system(cmd)

  if stashed then pop_auto_stash(work_tree) end

  if vim.v.shell_error ~= 0 then
    vim.notify("Reset failed: " .. output, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.close_commit_info_float()
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_win_close(float_win, true)
    float_win = nil
    float_buf = nil
  end
end

function M.show_commit_info_float(commit, toggle, create_if_missing)
  local create = create_if_missing == nil and true or create_if_missing
  -- If no commit provided, do nothing
  if not commit or commit == '' then
    return
  end
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    if toggle then
      M.close_commit_info_float()
      return
    end
  else
    if not create then
      return
    end
    float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].modifiable = false
    vim.bo[float_buf].filetype = 'git'

    local width = math.min(80, vim.o.columns - 4)
    local height = math.min(30, vim.o.lines - 4)
    local col = vim.o.columns - width - 4
    local row = 2

    float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      col = col,
      row = row,
      style = 'minimal',
      border = 'single',
      title = ' Commit Info ',
      title_pos = 'center',
    })

    vim.api.nvim_set_option_value('wrap', false, { win = float_win })
    vim.api.nvim_set_option_value('cursorline', false, { win = float_win })
  end

  -- Use git show with custom format to get pre-formatted date
  local command = "git show -s --date=format:'%Y-%m-%d %H:%M' --format='tree %T%nparent %P%nauthor %an <%ae> %ad%ncommitter %cn <%ce> %ad%n%n%B' " .. vim.fn.shellescape(commit)
  local commit_info = vim.fn.systemlist(command)

  if vim.v.shell_error == 0 then
    -- Trim trailing empty lines from the output
    while #commit_info > 0 and commit_info[#commit_info] == '' do
      table.remove(commit_info)
    end

    vim.bo[float_buf].modifiable = true
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, commit_info)
    vim.bo[float_buf].modifiable = false

    local line_count = #commit_info
    local win_height = math.min(line_count, vim.o.lines - 4)
    vim.api.nvim_win_set_height(float_win, win_height)
  end

  vim.api.nvim_set_option_value('wrap', false, { win = float_win })
  vim.api.nvim_set_option_value('cursorline', false, { win = float_win })
end

function M.setup()
  vim.api.nvim_create_user_command('GeditHeadAtFile', function()
    local filepath = vim.fn.expand('%:.')
    if filepath == '' then
      print('No file in current buffer')
      return
    end

    local handle = io.popen('git ls-files --full-name ' .. vim.fn.shellescape(filepath) .. ' 2>/dev/null')
    if not handle then
      return
    end
    local git_filepath = handle:read('*a'):gsub('\n', '')
    handle:close()

    if git_filepath == '' then
      print('File not tracked by git: ' .. filepath)
      return
    end

    local commit_handle = io.popen('git log --format=%H -n 1 -- ' .. vim.fn.shellescape(git_filepath) .. ' 2>/dev/null')
    if not commit_handle then
      return
    end
    local latest_commit = commit_handle:read('*a'):gsub('\n', '')
    commit_handle:close()

    if latest_commit == '' then
      print('No commits found for: ' .. git_filepath)
      return
    end

    vim.schedule(function()
      local fugitive_path = vim.fn.FugitiveFind(latest_commit)
      local existing_buf = vim.fn.bufnr(fugitive_path)
      local is_listed = existing_buf ~= -1 and vim.fn.getbufvar(existing_buf, '&buflisted') == 1 or false

      if existing_buf ~= -1 and is_listed then
        vim.cmd('tabedit #' .. existing_buf)
      else
        vim.cmd('tabedit')
        local noname_buf = vim.api.nvim_get_current_buf()
        vim.cmd('Gedit ' .. latest_commit)
        if vim.api.nvim_buf_is_valid(noname_buf) and vim.api.nvim_get_current_buf() ~= noname_buf then
          vim.api.nvim_buf_delete(noname_buf, { force = true })
        end
      end

      vim.schedule(function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line:match('^diff %-%-git [ab]/' .. vim.pesc(git_filepath) .. ' ') then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            vim.cmd('normal! zO')
            break
          end
        end
      end)
    end)
  end, {})

  local function git_push(opts)
    opts = opts or {}
    local on_complete = opts.on_complete

    -- fugitiveバッファのgitディレクトリを取得
    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify("Not in a git repository", vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    local output_lines = {}
    vim.fn.jobstart("git -C " .. vim.fn.shellescape(work_tree) .. " push --force-with-lease", {
      on_exit = function(_, exit_code)
        vim.schedule(function()
          local message = table.concat(output_lines, "\n")
          if exit_code == 0 then
            vim.notify("Push successful", vim.log.levels.INFO)
            vim.cmd('doautocmd User FugitiveChanged')
          else
            vim.notify("Push failed\n" .. message, vim.log.levels.ERROR)
          end
          if on_complete then
            on_complete(exit_code)
          end
        end)
        vim.fn['fugitive#ReloadStatus']()
      end,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              table.insert(output_lines, line)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              table.insert(output_lines, line)
            end
          end
        end
      end,
    })
  end

  vim.api.nvim_create_user_command("GitPush", function()
    git_push({})
  end, {})

  local function git_cherry_pick(opts)
    local reg_char = opts.reg or ''
    local on_complete = opts.on_complete
    local reg_name = reg_char == '' and '""' or '"' .. reg_char .. '"'

    local hashes_str = vim.fn.getreg(reg_char)

    if hashes_str == nil or hashes_str == '' then
      vim.notify('Register ' .. reg_name .. ' is empty.', vim.log.levels.WARN)
      return
    end

    -- Sanitize hashes string: replace newlines with spaces and trim whitespace.
    local hashes_list = vim.split(vim.fn.trim(hashes_str), '[\r\n]+')
    -- Reverse the order for correct cherry-pick sequence
    local reversed_hashes = {}
    for i = #hashes_list, 1, -1 do
      table.insert(reversed_hashes, hashes_list[i])
    end
    hashes_str = vim.fn.trim(table.concat(reversed_hashes, ' '))

    if hashes_str == '' then
      vim.notify('Register ' .. reg_name .. ' contains only whitespace.', vim.log.levels.WARN)
      return
    end

    -- fugitiveバッファのgitディレクトリを取得
    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify("Not in a git repository", vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    local output_lines = {}
    local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " cherry-pick " .. hashes_str
    vim.fn.jobstart(cmd, {
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if stashed then pop_auto_stash(work_tree) end
          local message = table.concat(output_lines, "\n")
          if exit_code == 0 then
            vim.notify("Cherry-pick successful", vim.log.levels.INFO)
            vim.cmd('doautocmd User FugitiveChanged')
          else
            vim.notify("Cherry-pick failed\n" .. message, vim.log.levels.ERROR)
          end
          if on_complete then
            on_complete(exit_code)
          end
        end)
        vim.fn['fugitive#ReloadStatus']()
      end,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              table.insert(output_lines, line)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              table.insert(output_lines, line)
            end
          end
        end
      end,
    })
  end

  vim.api.nvim_create_user_command("GCherryPick", function(cmd_opts)
    git_cherry_pick({ reg = cmd_opts.reg })
  end, { register = true })

  local function reflog_undo()
    local work_tree = get_work_tree_from_fugitive()
    if not work_tree then return end

    local prev_commit = vim.fn.trim(vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse --verify --quiet HEAD@{1}'))
    if prev_commit == '' or vim.v.shell_error ~= 0 then
      vim.notify('No older reflog entries', vim.log.levels.WARN)
      return
    end

    local current_commit = vim.fn.trim(vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse HEAD'))
    if current_commit == '' or vim.v.shell_error ~= 0 then
      vim.notify('Failed to resolve current HEAD', vim.log.levels.ERROR)
      return
    end
    local ok = hard_reset_to_commit(work_tree, prev_commit)
    if not ok then return end

    table.insert(reflog_redo_stack, current_commit)
    M.reload_log()
  end

  local function reflog_redo()
    if #reflog_redo_stack == 0 then
      vim.notify('Nothing to redo', vim.log.levels.WARN)
      return
    end

    local work_tree = get_work_tree_from_fugitive()
    if not work_tree then return end

    local target_commit = table.remove(reflog_redo_stack)
    local current_commit = vim.fn.trim(vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse HEAD'))
    if current_commit == '' or vim.v.shell_error ~= 0 then
      vim.notify('Failed to resolve current HEAD', vim.log.levels.ERROR)
      table.insert(reflog_redo_stack, target_commit)
      return
    end
    local ok = hard_reset_to_commit(work_tree, target_commit)
    if not ok then
      table.insert(reflog_redo_stack, target_commit)
      return
    end

    vim.notify(string.format('Redo to %s', target_commit:sub(1, 7)), vim.log.levels.INFO)
    M.reload_log()
  end

  vim.api.nvim_create_user_command("UndoFugitive", function()
    reflog_undo()
  end, {})

  vim.api.nvim_create_user_command("RedoFugitive", function()
    reflog_redo()
  end, {})

  function M.reword_commit(commit_hash, new_message, on_complete)
    if not commit_hash or commit_hash == '' then
      vim.notify('No commit hash provided', vim.log.levels.ERROR)
      return
    end
    if not new_message or new_message == '' then
      vim.notify('New commit message is empty', vim.log.levels.WARN)
      return
    end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    local short_commit_hash = commit_hash:sub(1, 7)

    -- Sequence editor: mark target commit for reword
    local seq_file = vim.fn.tempname()
    local seq_script = string.format('#!/bin/sh\nsed -i "s/^pick %s/reword %s/" "$1"\n', short_commit_hash, short_commit_hash)
    local f_seq = io.open(seq_file, 'w')
    if not f_seq then
      if stashed then pop_auto_stash(work_tree) end
      vim.notify('Failed to create sequence editor script', vim.log.levels.ERROR)
      return
    end
    f_seq:write(seq_script)
    f_seq:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(seq_file))

    -- Editor script: replace message with provided text
    local msg_file = vim.fn.tempname()
    local f_msg = io.open(msg_file, 'w')
    if not f_msg then
      if stashed then pop_auto_stash(work_tree) end
      vim.fn.delete(seq_file)
      vim.notify('Failed to create message file', vim.log.levels.ERROR)
      return
    end
    f_msg:write(new_message .. '\n')
    f_msg:close()

    local editor_file = vim.fn.tempname()
    local editor_script = string.format('#!/bin/sh\ncat %s > "$1"\n', vim.fn.shellescape(msg_file))
    local f_editor = io.open(editor_file, 'w')
    if not f_editor then
      if stashed then pop_auto_stash(work_tree) end
      vim.fn.delete(seq_file)
      vim.fn.delete(msg_file)
      vim.notify('Failed to create editor script', vim.log.levels.ERROR)
      return
    end
    f_editor:write(editor_script)
    f_editor:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(editor_file))

    local rebase_cmd = string.format(
      'GIT_SEQUENCE_EDITOR=%s GIT_EDITOR=%s git -C %s rebase -i %s',
      vim.fn.shellescape(seq_file),
      vim.fn.shellescape(editor_file),
      vim.fn.shellescape(work_tree),
      vim.fn.shellescape(commit_hash .. '^')
    )

    local result = vim.fn.system(rebase_cmd)

    vim.fn.delete(seq_file)
    vim.fn.delete(editor_file)
    vim.fn.delete(msg_file)
    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Reword failed: ' .. result, vim.log.levels.ERROR)
    else
      vim.fn['fugitive#ReloadStatus']()
      if on_complete then
        vim.schedule(on_complete)
      end
    end
  end

  function M.fixup_commit(commit_hash, on_complete)
    if not commit_hash or commit_hash == '' then
      vim.notify('No commit hash provided', vim.log.levels.ERROR)
      return
    end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    -- Get the parent commit hash
    local parent_commit_hash_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse ' .. commit_hash .. '^'
    local parent_commit_hash = vim.fn.trim(vim.fn.system(parent_commit_hash_cmd))
    if vim.v.shell_error ~= 0 then
      if stashed then pop_auto_stash(work_tree) end
      vim.notify('Failed to get parent commit for ' .. commit_hash, vim.log.levels.ERROR)
      return
    end

    -- Create a temporary script file
    local tmpfile = vim.fn.tempname()
    local short_commit_hash = commit_hash:sub(1, 7)
    local script_content = string.format('#!/bin/sh\nsed -i \'s/^pick %s/fixup %s/\' "$1"\n', short_commit_hash, short_commit_hash)

    local f = io.open(tmpfile, 'w')
    if not f then
      vim.notify('Failed to create temp script', vim.log.levels.ERROR)
      return
    end

    f:write(script_content)
    f:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(tmpfile))

    -- Run rebase with GIT_SEQUENCE_EDITOR
    local rebase_cmd = 'GIT_SEQUENCE_EDITOR=' .. vim.fn.shellescape(tmpfile) .. ' git -C ' .. vim.fn.shellescape(work_tree) .. ' rebase -i ' .. vim.fn.shellescape(parent_commit_hash .. '^')
    local result = vim.fn.system(rebase_cmd)
    vim.fn.delete(tmpfile)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Rebase failed: ' .. result, vim.log.levels.ERROR)
    else
      -- Reload status if the fugitive buffer is open
      vim.fn['fugitive#ReloadStatus']()
      if on_complete then
        vim.schedule(on_complete)
      end
    end
  end

  function M.mix_index(commit_hash, on_complete, new_message)
    if not commit_hash or commit_hash == '' then
      vim.notify('No commit hash provided', vim.log.levels.ERROR)
      return
    end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))
    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree", vim.log.levels.ERROR)
      return
    end

    -- Check if there are staged changes
    local has_staged = vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' diff --cached --quiet')
    -- exit_code is 1 if there are differences (dirty), 0 if clean
    local is_clean = (vim.v.shell_error == 0)

    local allow_empty = ''
    if is_clean then
       if not new_message or new_message == '' then
          vim.notify("No staged changes to fixup", vim.log.levels.WARN)
          return
       end
       allow_empty = ' --allow-empty'
    end

    -- 1. Create the fixup/amend commit using the index
    -- Note: 'git commit --fixup=amend:<commit> -m <msg>' is not supported.
    -- We must manually construct the commit message for autosquash if we have a new message.

    local commit_cmd = ''
    local msg_file = nil

    if new_message and new_message ~= '' then
       -- Get the subject of the target commit for "amend!" prefix
       local subject_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' log -1 --format=%s ' .. commit_hash
       local subject = vim.fn.trim(vim.fn.system(subject_cmd))

       if vim.v.shell_error ~= 0 then
          vim.notify("Failed to get commit subject", vim.log.levels.ERROR)
          return
       end

       -- Construct message: "amend! <subject>\n\n<new_message>"
       msg_file = vim.fn.tempname()
       local f = io.open(msg_file, 'w')
       if not f then return end
       -- 'amend!' prefix triggers fixup -C (reword) in autosquash
       f:write('amend! ' .. subject .. '\n\n' .. new_message)
       f:close()

       commit_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' commit ' .. allow_empty .. ' -F ' .. vim.fn.shellescape(msg_file)
    else
       -- Standard fixup (no message change)
       commit_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' commit ' .. allow_empty .. ' --fixup=' .. commit_hash
    end

    local commit_res = vim.fn.system(commit_cmd)

    if msg_file then vim.fn.delete(msg_file) end

    if vim.v.shell_error ~= 0 then
      vim.notify("Commit failed: " .. commit_res, vim.log.levels.ERROR)
      return
    end

    -- 2. Auto stash unstaged changes
    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end -- Error in stashing

    -- 3. Rebase --autosquash
    local parent_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse ' .. commit_hash .. '^'
    local parent_hash = vim.fn.trim(vim.fn.system(parent_cmd))

    local rebase_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rebase -i --autosquash ' .. vim.fn.shellescape(parent_hash)

    rebase_cmd = 'GIT_SEQUENCE_EDITOR=: ' .. rebase_cmd

    local rebase_res = vim.fn.system(rebase_cmd)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
       vim.notify("Rebase failed: " .. rebase_res, vim.log.levels.ERROR)
    else
       vim.fn['fugitive#ReloadStatus']()
       if on_complete then vim.schedule(on_complete) end
    end
  end

  function M.mix_index_with_input(commit_hash)
    if not commit_hash then
       vim.notify('No commit provided', vim.log.levels.WARN)
       return
    end
    vim.ui.input({ prompt = 'Commit message (empty to keep, cancel to abort): ' }, function(input)
       if input == nil then return end -- Cancelled
       M.mix_index(commit_hash, nil, input)
    end)
  end

  function M.reload_log()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    if vim.fn.exists('*fugitive#Reload') == 1 then
      vim.fn['fugitive#Reload']()
    else
      vim.cmd('edit')
    end
    pcall(vim.api.nvim_win_set_cursor, 0, cursor_pos)
  end

  function M.move_commit(current_commit, target_commit, direction, on_complete)
    if not current_commit or current_commit == '' or not target_commit or target_commit == '' then
      vim.notify('Invalid commits', vim.log.levels.WARN)
      return
    end

    local current_branch = vim.fn.system('git rev-parse --abbrev-ref HEAD'):gsub('\n', '')
    if current_branch == 'HEAD' then
      vim.notify('Cannot move commits in detached HEAD state', vim.log.levels.ERROR)
      return
    end

    -- Determine the base commit for rebase (parent of the older commit)
    local base_commit
    if direction == 'down' then
      base_commit = target_commit .. '^'
    else
      base_commit = current_commit .. '^'
    end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    -- Create awk script - simplest approach
    local tmpfile = vim.fn.tempname()
    local script = string.format([[
#!/bin/bash
awk '
/^pick %s/ { line1=NR; save1=$0; next }
/^pick %s/ { line2=NR; save2=$0; next }
{ lines[NR]=$0 }
END {
  for (i=1; i<=NR+2; i++) {
    if (i==line1) print save2
    else if (i==line2) print save1
    else if (lines[i]) print lines[i]
  }
}
' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
]], current_commit:sub(1,7), target_commit:sub(1,7))

    local debug_script = string.format([[
#!/bin/bash
echo "[DEBUG] Original todo:" > /tmp/rebase-debug.log
cat "$1" >> /tmp/rebase-debug.log
%s
echo "[DEBUG] Modified todo:" >> /tmp/rebase-debug.log
cat "$1" >> /tmp/rebase-debug.log
]], script)

    local f = io.open(tmpfile, 'w')
    f:write(debug_script)
    f:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(tmpfile))

    local cmd = string.format('GIT_SEQUENCE_EDITOR=%s git rebase -i %s', vim.fn.shellescape(tmpfile), base_commit)
    local output = vim.fn.system(cmd)
    vim.fn.delete(tmpfile)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Failed to swap commits:\n' .. output, vim.log.levels.ERROR)
    else
      if on_complete then
        vim.schedule(on_complete)
      else
        M.reload_log()
      end
    end
  end

  function M.drop_commits(commits)
    if not commits or #commits == 0 then return end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    -- Sort commits to find the oldest one (last in chronological order)
    local commits_args = table.concat(commits, " ")
    local sort_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-list --no-walk --date-order ' .. commits_args
    local sorted_commits = vim.fn.systemlist(sort_cmd)

    if vim.v.shell_error ~= 0 or #sorted_commits == 0 then
        if stashed then pop_auto_stash(work_tree) end
        vim.notify('Failed to process commits', vim.log.levels.ERROR)
        return
    end

    -- The last one in rev-list output (date-order) is the oldest
    local oldest_commit = sorted_commits[#sorted_commits]

    -- Construct sed command to delete lines
    local sed_expr = ""
    for _, commit in ipairs(commits) do
        local short = commit:sub(1, 7)
        sed_expr = sed_expr .. " -e '/^pick " .. short .. "/d'"
    end

    local tmpfile = vim.fn.tempname()
    local f = io.open(tmpfile, 'w')
    f:write('#!/bin/sh\n')
    f:write('sed -i' .. sed_expr .. ' "$1"\n')
    f:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(tmpfile))

    local rebase_cmd = 'GIT_SEQUENCE_EDITOR=' .. vim.fn.shellescape(tmpfile) .. ' git -C ' .. vim.fn.shellescape(work_tree) .. ' rebase -i ' .. vim.fn.shellescape(oldest_commit .. '^')
    local result = vim.fn.system(rebase_cmd)
    vim.fn.delete(tmpfile)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Drop failed: ' .. result, vim.log.levels.ERROR)
    else
      M.reload_log()
    end
  end

  -- Preview helpers ------------------------------------------------------
  local preview_win = nil
  local preview_buf = nil
  local preview_commit = nil
  local preview_update_timer = nil
  local preview_update_pending_commit = nil

  local function open_with_fugitive(win, commit)
    local ok, _ = pcall(function()
      vim.api.nvim_set_current_win(win)
      vim.cmd('keepalt keepjumps silent Gedit ' .. commit)
    end)
    if not ok then
      return nil
    end
    return vim.api.nvim_win_get_buf(win)
  end

  function M.is_preview_open()
    return preview_win and vim.api.nvim_win_is_valid(preview_win)
  end

  function M.close_preview()
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_close, preview_win, true)
    end
    preview_win = nil
    preview_commit = nil
    preview_buf = nil
    if preview_update_timer then
      pcall(vim.fn.timer_stop, preview_update_timer)
      preview_update_timer = nil
      preview_update_pending_commit = nil
    end
  end

  -- Load a commit into a plain scratch buffer using git show. Returns true on success.
  local function load_commit_into_buf(commit, buf)
    if not (commit and commit ~= '') then return false end
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end

    -- Determine work tree if possible
    local git_dir = vim.fn.FugitiveGitDir()
    local work_tree = nil
    if git_dir and git_dir ~= '' then
      local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
      work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))
      if vim.v.shell_error ~= 0 then
        work_tree = nil
      end
    end

    local cmd
    if work_tree then
      cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' show --no-color ' .. vim.fn.shellescape(commit)
    else
      cmd = 'git show --no-color ' .. vim.fn.shellescape(commit)
    end

    local lines = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 or not lines or #lines == 0 then
      return false
    end

    local ok, err = pcall(function()
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
    end)
    if not ok then
      return false
    end

    return true
  end

  function M.open_preview_window(commit)
    if not commit or commit == '' then
      return
    end

    local current_win = vim.api.nvim_get_current_win()

    local function finalize_preview(buf)
      vim.api.nvim_set_option_value('buflisted', false, { buf = buf })
      vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
      vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
      vim.api.nvim_set_option_value('winfixwidth', true, { win = preview_win })
      local current_ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
      if current_ft ~= 'git' then
        vim.api.nvim_set_option_value('filetype', 'git', { buf = buf })
        vim.api.nvim_exec_autocmds('FileType', { buffer = buf })
      end
      pcall(vim.api.nvim_win_set_cursor, preview_win, {1, 0})
      if vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
      preview_commit = commit
    end

    -- Reuse existing preview window if present
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      local prev_buf = preview_buf or vim.api.nvim_win_get_buf(preview_win)
      if not vim.api.nvim_buf_is_valid(prev_buf) then
        prev_buf = nil
        preview_buf = nil
      end

      local buf_from_fugitive = open_with_fugitive(preview_win, commit)
      if buf_from_fugitive and vim.api.nvim_buf_is_valid(buf_from_fugitive) then
        finalize_preview(buf_from_fugitive)
        preview_buf = buf_from_fugitive
        return
      end

      -- If there's an existing buffer, try to overwrite it with git show
      if prev_buf then
        local ok = load_commit_into_buf(commit, prev_buf)
        if ok then
          finalize_preview(prev_buf)
          preview_buf = prev_buf
          return
        end
      end

      -- Create a new buffer and set it into the preview window
      local new_buf = vim.api.nvim_create_buf(false, true)
      local ok_set = pcall(vim.api.nvim_win_set_buf, preview_win, new_buf)
      if not ok_set then
        M.close_preview()
        return
      end

      local ok = load_commit_into_buf(commit, new_buf)
      if not ok then
        -- Restore previous buffer if possible
        if prev_buf and vim.api.nvim_buf_is_valid(prev_buf) then
          pcall(vim.api.nvim_win_set_buf, preview_win, prev_buf)
          finalize_preview(prev_buf)
          preview_buf = prev_buf
        else
          M.close_preview()
        end
        return
      end

      finalize_preview(new_buf)
      preview_buf = new_buf
      return
    end

    -- Open split and populate buffer (reuse the buffer created by :new to avoid stray [No Name] buffers)
    vim.cmd('vertical rightbelow new')
    preview_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()

    local buf_from_fugitive = open_with_fugitive(preview_win, commit)
    local ok = buf_from_fugitive and vim.api.nvim_buf_is_valid(buf_from_fugitive)
    if ok then
      buf = buf_from_fugitive
    else
      ok = load_commit_into_buf(commit, buf)
    end

    if not ok then
      local buf_to_delete = buf
      M.close_preview()
      if buf_to_delete and vim.api.nvim_buf_is_valid(buf_to_delete) then
        pcall(vim.api.nvim_buf_delete, buf_to_delete, { force = true })
      end
      if vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
      return
    end

    finalize_preview(buf)
    preview_buf = buf
  end

  function M.update_preview(commit)
    if not M.is_preview_open() then return end
    if not commit or commit == '' then
      return
    end
    if preview_commit == commit then
      return
    end

    -- Use git show to load the commit; open_preview_window will reuse the window/buffer.
    M.open_preview_window(commit)
  end

  function M.toggle_preview(commit)
    if M.is_preview_open() then
      M.close_preview()
      return false
    end
    if not commit or commit == '' then
      return false
    end
    M.open_preview_window(commit)
    return true
  end

  function M.schedule_update_preview(commit)
    preview_update_pending_commit = commit
    if preview_update_timer then
      pcall(vim.fn.timer_stop, preview_update_timer)
      preview_update_timer = nil
    end
    preview_update_timer = vim.fn.timer_start(120, function()
      preview_update_timer = nil
      local to_commit = preview_update_pending_commit
      preview_update_pending_commit = nil
      vim.schedule(function()
        M.update_preview(to_commit)
      end)
    end)
  end

  -- Export functions for use in other modules
  M.git_push = git_push
  M.git_cherry_pick = git_cherry_pick
  M.reflog_undo = reflog_undo
  M.reflog_redo = reflog_redo
  M.apply_auto_stash = apply_auto_stash
  M.pop_auto_stash = pop_auto_stash
end

return M
