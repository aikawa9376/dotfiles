return {
  "pwntester/octo.nvim",
  cmd = { "Octo", "OctoPrFromSha" },
  config = function ()
    require"octo".setup({
      picker = "fzf-lua"
    })

    local function pr_from_sha(sha)
      local repo = vim.system({ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" }, { text = true }):wait().stdout:gsub("%s+$","")
      local repo_url = vim.system({ "gh", "repo", "view", "--json", "url", "-q", ".url" }, { text = true }):wait().stdout:gsub("%s+$","")
      repo_url = repo_url:gsub("/$","")
      sha = vim.system({ "git", "rev-parse", sha }, { text = true }):wait().stdout:gsub("%s+$","")
      local out = vim.system({ "gh", "api", ("repos/%s/commits/%s/pulls"):format(repo, sha), "-q", ".[].number" }, { text = true }):wait().stdout or ""
      local numbers = {}
      for n in string.gmatch(out, "%d+") do table.insert(numbers, n) end
      if #numbers == 0 then
        vim.notify("No associated PRs", vim.log.levels.WARN)
        return
      end
      if #numbers == 1 then
        vim.cmd("Octo " .. (repo_url .. "/pull/" .. numbers[1]))  -- Open PR in view-only mode (works with Enterprise hosts)
      else
        vim.ui.select(numbers, { prompt = "Select PR" }, function(choice)
          if choice then vim.cmd("Octo " .. (repo_url .. "/pull/" .. choice)) end
        end)
      end
    end

    vim.api.nvim_create_user_command("OctoPrFromSha", function(opts)
      local sha = opts.args ~= "" and opts.args or vim.fn.expand("<cword>")
      -- If no sha provided (and no word under cursor), bail out early to avoid running git/gh with invalid input
      if sha == nil or sha == "" then
        vim.notify("No SHA provided (pass an argument or place cursor on a commit SHA)", vim.log.levels.WARN)
        return
      end
      -- Trim surrounding whitespace
      sha = sha:gsub("^%s+", ""):gsub("%s+$", "")
      -- Reject inputs that don't look like a commit SHA (short SHA >=7 and up to 40 hex chars)
      if not sha:match("^[0-9a-fA-F]+$") or #sha < 7 or #sha > 40 then
        vim.notify(("'%s' doesn't look like a commit SHA"):format(sha), vim.log.levels.WARN)
        return
      end
      pr_from_sha(sha)
    end, { nargs = "?" })
  end
}
