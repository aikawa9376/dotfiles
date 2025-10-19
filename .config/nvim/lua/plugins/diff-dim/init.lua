return {
  "diff-dim",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/diff-dim",
  cmd = "DiffDim",
  config = function()
    local ns_id = vim.api.nvim_create_namespace("DimNonDiffLines")

    local function dim_lines(args)
      local function set_marks(hunks, bufnr, rev)
        if hunks == nil then
          local revision = rev or 'HEAD'
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
        for i = 1, line_count do
          if not diff_lines[i] then
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
              line_hl_group = vim.api.nvim_get_hl_id_by_name("LineNr"),
            })
          else
            vim.api.nvim_buf_clear_namespace(bufnr, ns_id, i - 1, i)
          end
        end
      end

      local hunks
      local rev = args.fargs[1] or nil
      local bufnr = vim.api.nvim_get_current_buf()

      if rev then
        require('gitsigns').change_base(rev, false, function ()
          hunks = require('gitsigns').get_hunks(bufnr)
          set_marks(hunks, bufnr, rev)
        end)
      else
        hunks = require('gitsigns').get_hunks(bufnr)
        set_marks(hunks, bufnr, nil)
      end
    end

    local function clear_marks()
      require('gitsigns').reset_base()
      vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
    end

    vim.api.nvim_create_user_command("DiffDim", function(args)
      if args.fargs[1] == "clear" then
        clear_marks()
        print("Dimmed lines cleared.")
        return
      end

      local marks = vim.api.nvim_buf_get_extmarks(0, ns_id, 0, -1, { limit = 1 })
      if #marks > 0 and args.fargs[1] == nil then
        clear_marks()
        print("Dimmed lines cleared.")
      else
        dim_lines(args)
        print("Diff lines dimmed.")
      end
    end, {
        nargs = '?',
        complete = require"utilities".get_git_completions,
      })
  end
}
