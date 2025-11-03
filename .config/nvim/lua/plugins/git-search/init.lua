return {
  "git-search",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/git-search",
  dependencies = { "ibhagwan/fzf-lua", "sindrets/diffview.nvim" },
  cmd = { "GitSearch" },
  config = function()
    local fzf = require("fzf-lua")
    local actions = require("fzf-lua.actions")

    local M = {}

    -- Constants
    local LOG_FORMAT = "--color --format='%C(yellow)%h%C(reset) %C(blue)%as%C(reset) %C(green)%an%C(reset) %C(dim)_%C(reset) %s'"

    -- Helper functions
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

    -- Common actions
    local common_actions = {
      ["ctrl-d"] = function(selected, opts)
        if not selected or #selected == 0 then return end
        local commit_hash = parse_commit_line(selected[1])
        if not commit_hash then return end
        local filepath = opts and opts.filepath or get_relative_path()
        if filepath and filepath ~= "" then
          vim.cmd("DiffviewOpen " .. commit_hash .. "~.." .. commit_hash .. " -- " .. filepath)
        else
          vim.cmd("DiffviewOpen " .. commit_hash .. "~.." .. commit_hash)
        end
        fzf.resume()
      end,
      ["ctrl-o"] = function(selected)
        local commit_hash = parse_commit_line(selected[1])
        if not commit_hash then return end
        vim.cmd("OctoPrFromSha " .. commit_hash)
        fzf.resume()
      end,
      ["ctrl-y"] = function(selected)
        if not selected or #selected == 0 then return end
        local commit_hash = parse_commit_line(selected[1])
        if not commit_hash then return end
        vim.fn.setreg("+", commit_hash)
        vim.fn.setreg("*", commit_hash)
        vim.notify("Copied commit hash: " .. commit_hash, vim.log.levels.INFO)
        fzf.resume()
      end,
      ["ctrl-q"] = function(selected)
        if not selected or #selected == 0 then return end
        local qf_list = {}
        for _, line in ipairs(selected) do
          local commit_hash = parse_commit_line(line)
          if commit_hash then
            -- Get commit info
            local handle = io.popen("git show --no-patch --format='%s' " .. commit_hash .. " 2>/dev/null")
            local message = handle and handle:read("*l") or ""
            if handle then handle:close() end

            -- Open the commit buffer with Gedit to get the buffer number
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

    local function build_preview_command(filepath)
      local file_filter = filepath and (" -- " .. vim.fn.shellescape(filepath)) or ""

      return table.concat({
        "sh -c 'q={q}; pat=\"${q%%@*}\"; ",
        "if [ -z \"$pat\" ]; then ",
        "  git show --color=always {1}" .. file_filter .. "; ",
        "else ",
        "  diff=$(git show --color=always {1}" .. file_filter .. "); ",
        "  matched=$(echo \"$diff\" | rg --pcre2 -n --color=never \"^(?:\\x1B\\[[0-9;]*m)*[\\+\\-](?!(?:\\x1B\\[[0-9;]*m)*[\\+\\-]).*?$pat\" | head -1 | cut -d: -f1); ",
        "  if [ -n \"$matched\" ]; then ",
        "    context=$((matched > 10 ? matched - 10 : 1)); ",
        "    echo \"$diff\" | tail -n +$context | rg --pcre2 --passthru ",
        "      --colors 'match:fg:yellow' --colors 'match:style:bold' --color=always ",
        "      \"^(?:\\x1B\\[[0-9;]*m)*[\\+\\-](?![\\+\\-]).*?\\K$pat\"; ",
        "  else ",
        "    echo \"$diff\" | rg --pcre2 --passthru ",
        "      --colors 'match:fg:yellow' --colors 'match:style:bold' --color=always ",
        "      \"^(?:\\x1B\\[[0-9;]*m)*[\\+\\-](?![\\+\\-]).*?\\K$pat\"; ",
        "  fi; ",
        "fi'",
      }, "")
    end

    -- Public functions
    function M.search_log_content(opts)
      opts = opts or {}
      local bufnr = vim.api.nvim_get_current_buf()
      local filepath = opts.file_scoped and get_relative_path(bufnr) or nil
      local follow = filepath and (" --follow -- " .. vim.fn.shellescape(filepath)) or ""

      fzf.fzf_live(function(query_tbl)
        local query = normalize_query(query_tbl)
        local prompt, author = split_query_author(query)

        local cmd = "GIT_PAGER=cat git log " .. LOG_FORMAT
        if prompt and prompt ~= "" then
          cmd = cmd .. " -G " .. vim.fn.shellescape(prompt) .. " --pickaxe-all"
        end
        if author and author ~= "" then
          cmd = cmd .. " " .. vim.fn.shellescape("--author=" .. author)
        end
        cmd = cmd .. follow
        return cmd
      end, {
          prompt = "Log Content (use @ for author)> ",
          exec_empty_query = true,
          fzf_opts = { ["--multi"] = true },
          preview = build_preview_command(filepath),
          actions = vim.tbl_extend("force", common_actions, {
            ["default"] = function(selected)
              if not selected or #selected == 0 then return end
              local commit_hash = parse_commit_line(selected[1])
              if commit_hash then
                vim.cmd("Gedit " .. commit_hash)
              end
            end,
          }),
        })
    end

    function M.search_log_content_file()
      M.search_log_content({ file_scoped = true })
    end

    -- Diff commit file (searches commit message with --grep)
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
        local prompt, author = split_query_author(query)

        local cmd = "git log " .. LOG_FORMAT

        if prompt and prompt ~= "" then
          cmd = cmd .. " -s -i --grep=" .. vim.fn.shellescape(prompt)
        end

        if author and author ~= "" then
          cmd = cmd .. " --author=" .. vim.fn.shellescape(author)
        end

        cmd = cmd .. " --follow -- " .. vim.fn.shellescape(filepath)

        return cmd
      end, {
          prompt = "Commit Message (use @ for author)> ",
          exec_empty_query = true,
          fzf_opts = { ["--multi"] = true },
          preview = "git show --color {1} -- " .. vim.fn.shellescape(filepath),
          actions = vim.tbl_extend("force", common_actions, {
            ["default"] = function(selected)
              if not selected or #selected == 0 then return end
              local commit_hash = parse_commit_line(selected[1])
              if commit_hash then
                vim.cmd("Gedit " .. commit_hash)
              end
            end,
          }),
        })
    end

    -- Diff commit line (searches commit message with --grep for specific lines)
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
        local prompt, author = split_query_author(query)

        local cmd = "git log " .. location .. " --no-patch " .. LOG_FORMAT

        if prompt and prompt ~= "" then
          cmd = cmd .. " -s -i --grep=" .. vim.fn.shellescape(prompt)
        end

        if author and author ~= "" then
          cmd = cmd .. " --author=" .. vim.fn.shellescape(author)
        end

        return cmd
      end, {
          prompt = "Line History (use @ for author)> ",
          exec_empty_query = true,
          multiprocess = false,
          func_async_callback = false,
          fzf_opts = { ["--multi"] = true },
          preview = "git show --color {1} -- " .. vim.fn.shellescape(filepath),
          actions = vim.tbl_extend("force", common_actions, {
            ["default"] = function(selected)
              if not selected or #selected == 0 then return end
              local commit_hash = parse_commit_line(selected[1])
              if commit_hash then
                vim.cmd("Gedit " .. commit_hash)
              end
            end,
          }),
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
        actions = {
          ["default"] = function(selected)
            if not selected or #selected == 0 then return end
            local branch = selected[1]:match("^%s*(.-)%s*$")
            vim.cmd("DiffviewOpen " .. branch .. " -- " .. filepath)
          end,
        },
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
  end,
}
