return {
  "pwntester/octo.nvim",
  cmd = { "Octo", "OctoPrFromSha", "OctoPrFromBranch", "OctoCopyPrFromBranch" },
  config = function ()
    require"octo".setup({
      picker = "fzf-lua"
    })

    local function current_pr_info_from_buf()
      local name = vim.api.nvim_buf_get_name(0) or ""
      local host, repo, pr = name:match("octo://([^/]+)/(.+)/pull/(%d+)")
      if not host or not repo or not pr then return end
      return host, repo, pr
    end

    local function open_diffview_for_current_pr()
      local host, repo, pr = current_pr_info_from_buf()
      if not pr then
        vim.notify("Not in an Octo PR buffer", vim.log.levels.WARN)
        return
      end

      local base_ref = vim.system({
        "gh", "api", "--hostname", host,
        ("repos/%s/pulls/%s"):format(repo, pr),
        "-q", ".base.ref",
      }, { text = true }):wait().stdout or ""
      base_ref = base_ref:gsub("%s+$", "")
      if base_ref == "" then base_ref = "main" end

      local base_local = ("refs/octo/pr/%s/base"):format(pr)
      local head_local = ("refs/octo/pr/%s/head"):format(pr)

      local fetch_base = vim.system({ "git", "fetch", "origin", base_ref .. ":" .. base_local }, { text = true }):wait()
      if fetch_base.code ~= 0 then
        vim.notify("Failed to fetch base branch for PR #" .. pr, vim.log.levels.ERROR)
        return
      end

      local fetch_head = vim.system({ "git", "fetch", "origin", ("pull/%s/head:%s"):format(pr, head_local) }, { text = true }):wait()
      if fetch_head.code ~= 0 then
        vim.notify("Failed to fetch PR head for #" .. pr, vim.log.levels.ERROR)
        return
      end

      local range = ("%s...%s"):format(base_local, head_local)
      vim.cmd("DiffviewOpen " .. range)
    end

    vim.api.nvim_create_user_command("OctoDiffview", open_diffview_for_current_pr, { desc = "Open current Octo PR in Diffview" })

    vim.api.nvim_create_autocmd("FileType", {
      pattern = "octo",
      callback = function(ev)
        vim.keymap.set("n", "<leader>od", open_diffview_for_current_pr, { buffer = ev.buf, silent = true, desc = "Diffview current PR" })
      end,
    })

    local function parse_git_remote()
      local remote_url = vim.system({ "git", "config", "--get", "remote.origin.url" }, { text = true }):wait().stdout:gsub("%s+$", "")
      local hostname, repo = "github.com", ""

      local h, r = remote_url:match("https?://([^/]+)/(.+)")
      if h then
        hostname, repo = h, r
      else
        h, r = remote_url:match("@([^:]+):(.+)")
        if h then
          hostname, repo = h, r
        end
      end

      repo = repo:gsub("%.git$", "")
      return hostname, repo
    end

    local function gh_repo_arg(hostname, repo)
      if hostname and hostname ~= "" and hostname ~= "github.com" then
        return hostname .. "/" .. repo
      end
      return repo
    end

    local function current_branch_name()
      local res = vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait()
      if res.code ~= 0 then
        return ""
      end
      return vim.fn.trim(res.stdout or "")
    end

    local function branch_name_from_opts(opts)
      local branch_name = opts.args
      if branch_name == "" then
        branch_name = current_branch_name()
      end
      branch_name = vim.fn.trim(branch_name or "")

      if not branch_name or branch_name == "" then
        vim.notify("Could not determine branch name.", vim.log.levels.WARN)
        return nil
      end
      return branch_name
    end

    local function build_pr_url(hostname, repo, pr_number)
      return ("https://%s/%s/pull/%s"):format(hostname, repo, pr_number)
    end

    local function query_prs_for_branch(hostname, repo, branch_name)
      local res = vim.system({
        "gh", "pr", "list",
        "--repo", gh_repo_arg(hostname, repo),
        "--head", branch_name,
        "--state", "all",
        "--json", "number,url",
        "-q", ".[] | [.number, .url] | @tsv",
      }, { text = true }):wait()

      if res.code ~= 0 then
        local msg = res.stderr ~= "" and res.stderr or res.stdout
        vim.notify("Failed to query PRs for branch: " .. (msg or "unknown error"), vim.log.levels.ERROR)
        return nil
      end

      local pr_items = {}
      for line in (res.stdout or ""):gmatch("[^\r\n]+") do
        local number, url = line:match("^(%d+)%s+(.+)$")
        if number then
          table.insert(pr_items, {
            number = number,
            url = url ~= "" and url or build_pr_url(hostname, repo, number),
          })
        end
      end
      return pr_items
    end

    local function with_branch_pr(opts, action)
      local branch_name = branch_name_from_opts(opts)
      if not branch_name then
        return
      end

      local hostname, repo = parse_git_remote()
      local pr_items = query_prs_for_branch(hostname, repo, branch_name)
      if not pr_items then
        return
      end

      if #pr_items == 0 then
        vim.notify("No associated PRs for branch " .. branch_name, vim.log.levels.WARN)
        return
      end

      if #pr_items == 1 then
        action(pr_items[1], hostname, repo)
        return
      end

      vim.ui.select(pr_items, {
        prompt = "Select PR for branch " .. branch_name,
        format_item = function(item)
          return ("#%s %s"):format(item.number, item.url)
        end,
      }, function(choice)
        if choice then
          action(choice, hostname, repo)
        end
      end)
    end

    vim.api.nvim_create_user_command("OctoPrFromSha", function(opts)
      local sha = opts.args ~= "" and opts.args or vim.fn.expand("<cword>")
      sha = sha and sha:gsub("^%s+", ""):gsub("%s+$", "")

      if not sha or sha == "" then
        vim.notify("No SHA provided (pass an argument or place cursor on a commit SHA)", vim.log.levels.WARN)
        return
      end
      if not sha:match("^[0-9a-fA-F]+$") or #sha < 7 or #sha > 40 then
        vim.notify(("'%s' doesn't look like a commit SHA"):format(sha), vim.log.levels.WARN)
        return
      end

      local hostname, repo = parse_git_remote()
      sha = vim.system({ "git", "rev-parse", sha }, { text = true }):wait().stdout:gsub("%s+$", "")

      local res = vim.system({
        "gh", "api", "--hostname", hostname,
        ("repos/%s/commits/%s/pulls"):format(repo, sha),
        "-q", ".[].number"
      }, { text = true }):wait()

      if res.code ~= 0 then
        local msg = res.stderr ~= "" and res.stderr or res.stdout
        if msg and msg:match("No commit found") then
          vim.notify("Commit not found on remote (did you push it?): " .. sha, vim.log.levels.WARN)
        else
          vim.notify("Failed to query PRs for commit: " .. (msg or "unknown error"), vim.log.levels.ERROR)
        end
        return
      end

      local out = res.stdout or ""

      local pr_numbers = {}
      for n in out:gmatch("%d+") do
        table.insert(pr_numbers, n)
      end

      if #pr_numbers == 0 then
        vim.notify("No associated PRs", vim.log.levels.WARN)
        return
      end

      local function open_pr(pr_number)
        local pr_url = ("https://%s/%s/pull/%s"):format(hostname, repo, pr_number)

        -- if hostname ~= "github.com" then
        --   vim.fn.setreg("+", pr_url)
        --   vim.notify("PR URL copied to clipboard: " .. pr_url, vim.log.levels.INFO)
        --   return
        -- end

        vim.cmd("tabnew")
        local ok = pcall(function()
          vim.cmd(("Octo pr edit %s %s"):format(pr_number, repo))
        end)
        if not ok then
          vim.fn.setreg("+", pr_url)
          vim.notify("Octo failed. URL copied to clipboard: " .. pr_url, vim.log.levels.WARN)
        end
      end

      if #pr_numbers == 1 then
        open_pr(pr_numbers[1])
      else
        vim.ui.select(pr_numbers, { prompt = "Select PR" }, function(choice)
          if choice then open_pr(choice) end
        end)
      end
    end, { nargs = "?" })

    vim.api.nvim_create_user_command("OctoPrFromBranch", function(opts)
      with_branch_pr(opts, function(item, _, repo)
        vim.cmd("tabnew")
        local ok = pcall(function()
          vim.cmd(("Octo pr edit %s %s"):format(item.number, repo))
        end)
        if not ok then
          vim.fn.setreg("+", item.url)
          vim.notify("Octo failed. URL copied to clipboard: " .. item.url, vim.log.levels.WARN)
        end
      end)
    end, { nargs = "?", desc = "Open a PR associated with the current or given branch" })

    vim.api.nvim_create_user_command("OctoCopyPrFromBranch", function(opts)
      with_branch_pr(opts, function(item)
        local ok = pcall(vim.fn.setreg, "+", item.url)
        pcall(vim.fn.setreg, '"', item.url)
        if ok then
          vim.notify("PR URL copied to clipboard: " .. item.url, vim.log.levels.INFO)
        else
          vim.notify("Failed to copy PR URL: " .. item.url, vim.log.levels.ERROR)
        end
      end)
    end, { nargs = "?", desc = "Copy a PR URL associated with the current or given branch" })
  end
}
