local fzf = require("fzf-lua")
local actions = require("fzf-lua.actions")

local M = {}
M._search_pat = ""
M._ns = vim.api.nvim_create_namespace("GitSearchPreviewNS")

vim.api.nvim_set_hl(0, "GitSearchMatch", { bg = "#2d5016", fg = "#a6e22e", bold = true })

local LOG_FORMAT = "--color --format='%C(yellow)%h%C(reset) %C(blue)%as%C(reset) %C(dim)_%C(reset) %s %C(green)%an%C(reset)'"

local function get_relative_path(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return nil end

  local handle = io.popen("git ls-files --full-name " .. vim.fn.shellescape(filepath) .. " 2>/dev/null")
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()

  result = result:gsub("\n", "")
  return result ~= "" and result or nil
end

local function parse_commit_line(line)
  local hash = line:match("^(%w+)")
  return hash
end

local function create_git_show_previewer(filepath)
  local Previewer = require("fzf-lua.previewer.builtin").buffer_or_file:extend()

  function Previewer:new(o, opts, fzf_win)
    Previewer.super.new(self, o, opts, fzf_win)
    setmetatable(self, Previewer)
    return self
  end

  function Previewer:populate_preview_buf(entry_str)
    if not self.win or not self.win:validate_preview() then return end

    local commit_hash = parse_commit_line(entry_str or "")
    if not commit_hash then return end

    local cmd = "git show --no-color " .. commit_hash
    if filepath and filepath ~= "" then
      cmd = cmd .. " -- " .. vim.fn.shellescape(filepath)
    end

    local handle = io.popen(cmd .. " 2>/dev/null")
    local output = handle and handle:read("*a") or ""
    if handle then handle:close() end

    local lines = {}
    for s in (output .. "\n"):gmatch("(.-)\n") do
      table.insert(lines, s)
    end

    local tmpbuf = self:get_tmp_buffer()
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, lines)
    vim.bo[tmpbuf].filetype = "git"
    self:set_preview_buf(tmpbuf)

    local first_match_line = 1
    local pat = M._search_pat or ""

    if pat ~= "" then
      local function is_diff_content(line)
        return line:match("^[+-][^+-]")
      end

      vim.api.nvim_buf_clear_namespace(tmpbuf, M._ns, 0, -1)

      for i, line in ipairs(lines) do
        if is_diff_content(line) then
          local start_pos = 1
          while true do
            local s, e = line:find(pat, start_pos, true)
            if not s then break end

            if first_match_line == 1 then
              first_match_line = i
            end

            vim.api.nvim_buf_set_extmark(tmpbuf, M._ns, i - 1, s - 1, {
              end_col = e,
              hl_group = "GitSearchMatch",
            })

            start_pos = e + 1
          end
        end
      end
    end

    self:preview_buf_post({ filetype = "git", do_not_cache = true, line = first_match_line, col = 1 })

    vim.schedule(function()
      if self.win and self.win.preview_winid and vim.api.nvim_win_is_valid(self.win.preview_winid) then
        vim.wo[self.win.preview_winid].cursorline = false
        vim.api.nvim_win_set_hl_ns(self.win.preview_winid, M._ns)
        vim.api.nvim_set_hl(M._ns, "Cursor", { blend = 100 })
      end
    end)
  end

  return Previewer
end

local common_actions = {
  ["ctrl-d"] = {
    exec_silent = true,
    fn = function(selected, opts)
      if not selected or #selected == 0 then return end
      local commit_hash = parse_commit_line(selected[1])
      if not commit_hash then return end
      local filepath = opts and opts.filepath
      if filepath and filepath ~= "" then
        vim.cmd("tabedit | DiffviewOpen " .. commit_hash .. "~.." .. commit_hash .. " -- " .. filepath)
        vim.cmd("tabNext | bwipeout")
      else
        vim.cmd("tabedit | DiffviewOpen " .. commit_hash .. "~.." .. commit_hash)
        vim.cmd("tabNext | bwipeout")
      end
    end
  },
  ["ctrl-o"] = {
    exec_silent = true,
    fn = function(selected)
      local commit_hash = parse_commit_line(selected[1])
      if not commit_hash then return end
      vim.cmd("OctoPrFromSha " .. commit_hash)
    end
  },
  ["ctrl-y"] = {
    exec_silent = true,
    fn = function(selected)
      if not selected or #selected == 0 then return end
      local commit_hash = parse_commit_line(selected[1])
      if not commit_hash then return end
      vim.fn.setreg("+", commit_hash)
      vim.fn.setreg("*", commit_hash)
      vim.notify("Copied commit hash: " .. commit_hash, vim.log.levels.INFO)
    end
  },
  ["default"] = {
    exec_silent = true,
    fn = function(selected)
      if not selected or #selected == 0 then return end
      local commit_hash = parse_commit_line(selected[1])
      if not commit_hash then return end
      vim.cmd("tabedit | silent! Gedit " .. commit_hash)
    end
  },
  ["ctrl-q"] = function(selected)
    if not selected or #selected == 0 then return end
    local qf_list = {}
    for _, line in ipairs(selected) do
      local commit_hash = parse_commit_line(line)
      if commit_hash then
        local handle = io.popen("git show --no-patch --format='%s' " .. commit_hash .. " 2>/dev/null")
        local message = handle and handle:read("*l") or ""
        if handle then handle:close() end

        vim.cmd("silent Gedit " .. commit_hash)
        local bufnr = vim.api.nvim_get_current_buf()

        table.insert(qf_list, {
          bufnr = bufnr,
          module = commit_hash,
          text = message,
        })
      end
    end
    vim.fn.setqflist(qf_list, 'r')
    vim.cmd('copen')
    vim.notify(string.format("Added %d commit(s) to quickfix", #qf_list), vim.log.levels.INFO)
  end,
}

local function split_query_author(query)
  if type(query) ~= "string" then
    return "", nil
  end
  if not query or query == "" then
    return "", nil
  end
  local at_pos = string.find(query, "@")
  if at_pos then
    local prompt = query:sub(1, at_pos - 1):match("^%s*(.-)%s*$")
    local author = query:sub(at_pos + 1):match("^%s*(.-)%s*$")
    return prompt, author
  end
  return query, nil
end

local function normalize_query(query_tbl)
  return (type(query_tbl) == "table" and query_tbl[1]) or query_tbl or ""
end

local function build_log_command(query_tbl, follow)
  local query = normalize_query(query_tbl)
  local prompt, author = split_query_author(query)
  M._search_pat = prompt or ""

  local cmd = "GIT_PAGER=cat git log " .. LOG_FORMAT
  if prompt and prompt ~= "" then
    if prompt:sub(1, 1) == "#" then
      local grep_prompt = prompt:sub(2)
      cmd = cmd .. " --grep=" .. vim.fn.shellescape(grep_prompt)
    else
      cmd = cmd .. " -G " .. vim.fn.shellescape(prompt) .. " --pickaxe-all"
    end
  end
  if author and author ~= "" then
    cmd = cmd .. " " .. vim.fn.shellescape("--author=" .. author)
  end
  cmd = cmd .. follow
  return cmd
end

local function build_grep_log_command(query, extra_args, follow)
  local prompt, author = split_query_author(query)
  M._search_pat = prompt or ""

  local cmd = "git log " .. (extra_args or "") .. " " .. LOG_FORMAT

  if prompt and prompt ~= "" then
    cmd = cmd .. " -s -i --grep=" .. vim.fn.shellescape(prompt)
  end

  if author and author ~= "" then
    cmd = cmd .. " --author=" .. vim.fn.shellescape(author)
  end

  if follow and follow ~= "" then
    cmd = cmd .. " " .. follow
  end

  return cmd
end

function M.search_log_content(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = opts.file_scoped and get_relative_path(bufnr) or nil
  local follow = filepath and (" --follow -- " .. vim.fn.shellescape(filepath)) or ""

  fzf.fzf_live(function(query_tbl)
    return build_log_command(query_tbl, follow)
  end, {
      prompt = "Log Content (use @ for author)> ",
      exec_empty_query = true,
      fzf_opts = { ["--multi"] = true },
      previewer = create_git_show_previewer(filepath),
      actions = common_actions,
    })
end

function M.search_log_content_file()
  M.search_log_content({ file_scoped = true })
end

function M.diff_commit_file(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = get_relative_path(bufnr)

  if not filepath or filepath == "" then
    vim.notify("Not in a git-tracked file", vim.log.levels.WARN)
    return
  end

  fzf.fzf_live(function(query)
    query = normalize_query(query)
    local follow = " --follow -- " .. vim.fn.shellescape(filepath)
    return build_grep_log_command(query, nil, follow)
  end, {
      prompt = "Commit Message (use @ for author)> ",
      exec_empty_query = true,
      fzf_opts = { ["--multi"] = true },
      previewer = create_git_show_previewer(filepath),
      actions = common_actions,
    })
end

function M.diff_commit_line(opts)
  opts = opts or {}
  local start_line = opts.line1 or vim.fn.line("'<")
  local end_line = opts.line2 or vim.fn.line("'>")
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = get_relative_path(bufnr)

  if not filepath or filepath == "" then
    vim.notify("Not in a git-tracked file", vim.log.levels.WARN)
    return
  end

  if start_line == 0 or end_line == 0 then
    vim.notify("No visual selection", vim.log.levels.WARN)
    return
  end

  local location = string.format("-L%d,%d:%s", start_line, end_line, filepath)

  fzf.fzf_live(function(query)
    query = normalize_query(query)
    local extra_args = location .. " --no-patch"
    return build_grep_log_command(query, extra_args, nil)
  end, {
      prompt = "Line History (use @ for author)> ",
      exec_empty_query = true,
      multiprocess = false,
      func_async_callback = false,
      fzf_opts = { ["--multi"] = true },
      previewer = create_git_show_previewer(filepath),
      actions = common_actions,
    })
end

function M.diff_branch_file(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = get_relative_path(bufnr)

  if not filepath or filepath == "" then
    vim.notify("Not in a git-tracked file", vim.log.levels.WARN)
    return
  end

  local cmd = "git branch --format='%(refname:short)'"

  fzf.fzf_exec(cmd, {
    prompt = "Diff Branch> ",
    func_async_callback = false,
    preview = "git diff --color {1} -- " .. vim.fn.shellescape(filepath),
    actions = common_actions,
  })
end

function M.changed_on_branch(opts)
  opts = opts or {}

  local get_base_cmd = [[
    git show-branch | \
    sed "s/].*//" | \
    grep "*" | \
    grep -v "$(git rev-parse --abbrev-ref HEAD)" | \
    head -n1 | \
    sed "s/^.*[ /"
  ]]

  local handle = io.popen(get_base_cmd)
  if not handle then
    vim.notify("Failed to detect base branch", vim.log.levels.ERROR)
    return
  end
  local base_branch = handle:read("*a"):gsub("\n", "")
  handle:close()

  if base_branch == "" then
    vim.notify("Could not detect base branch. Make sure you have commits on current branch.", vim.log.levels.WARN)
    return
  end

  local cmd = "git diff --name-only --cached --diff-filter=ACMR --merge-base " .. base_branch

  fzf.fzf_exec(cmd, {
    prompt = "Changed Files> ",
    func_async_callback = false,
    preview = "git diff --color --merge-base " .. base_branch .. " -- {1}",
    actions = {
      ["default"] = actions.file_edit,
    },
  })
end

function M.setup()
    vim.api.nvim_create_user_command("GitSearch", function(args)
        local cmd = args.fargs[1]
        if cmd == "log" then
          M.search_log_content()
        elseif cmd == "log_file" then
          M.search_log_content_file()
        elseif cmd == "diff_file" then
          M.diff_commit_file()
        elseif cmd == "diff_line" then
          M.diff_commit_line(args)
        elseif cmd == "branch" then
          M.diff_branch_file()
        elseif cmd == "changed" then
          M.changed_on_branch()
        else
          fzf.fzf_exec({
            "log - Search in repo log content (code changes)",
            "log_file - Search in file log content (code changes)",
            "diff_file - Diff file with commit (by commit message)",
            "diff_line - Diff selected lines history (by commit message)",
            "branch - Diff current file with branch",
            "changed - Show files changed on current branch",
          }, {
              prompt = "Git Search> ",
              actions = {
                ["default"] = function(selected)
                  if not selected or #selected == 0 then return end
                  local command = selected[1]:match("^([%w_]+)")
                  if command == "log" then
                    M.search_log_content()
                  elseif command == "log_file" then
                    M.search_log_content_file()
                  elseif command == "diff_file" then
                    M.diff_commit_file()
                  elseif command == "diff_line" then
                    M.diff_commit_line({})
                  elseif command == "branch" then
                    M.diff_branch_file()
                  elseif command == "changed" then
                    M.changed_on_branch()
                  end
                end,
              },
            })
        end
      end, {
          nargs = "?",
          range = true,
          complete = function(ArgLead, CmdLine, CursorPos)
            local commands = { "log", "log_file", "diff_file", "diff_line", "branch", "changed" }
            if ArgLead == "" then
              return commands
            end
            local matches = {}
            for _, cmd in ipairs(commands) do
              if cmd:find("^" .. ArgLead) then
                table.insert(matches, cmd)
              end
            end
            return matches
          end,
          desc = "Git search commands with fzf-lua",
        })
  end

return M
