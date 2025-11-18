return {
  "pwntester/octo.nvim",
  cmd = { "Octo", "OctoPrFromSha" },
  config = function ()
    require"octo".setup({
      picker = "fzf-lua"
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

      local out = vim.system({
        "gh", "api", "--hostname", hostname,
        ("repos/%s/commits/%s/pulls"):format(repo, sha),
        "-q", ".[].number"
      }, { text = true }):wait().stdout or ""

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
        local ok = pcall(vim.cmd, ("Octo pr edit %s %s"):format(pr_number, repo))
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
  end
}
