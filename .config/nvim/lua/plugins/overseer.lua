return {
  'stevearc/overseer.nvim',
  cmd = { 'OverseerRun', 'OverseerToggle', 'OverseerWatch' },
  opts = {
    template_dirs = { 'tasks', 'overseer.template' },
    templates = {
      'builtin'
    },
    task_list = {
      bindings = { ['q'] = false, },
    },
  },
  config = function(_, opts)
    local overseer = require('overseer')
    local template_completion_cache = {}

    local function get_search_params()
      local dir = vim.fn.getcwd()
      if vim.bo.buftype == '' then
        local bufname = vim.api.nvim_buf_get_name(0)
        if bufname ~= '' then
          dir = vim.fn.fnamemodify(bufname, ':p:h')
        end
      end
      return {
        dir = dir,
        filetype = vim.bo.filetype,
      }
    end

    local function get_cache_key(search)
      return string.format('%s\0%s', search.dir, search.filetype or '')
    end

    local function normalize_completion_item(item)
      return vim.fn.escape(item, [[ \]])
    end

    local function build_completion_items(templates)
      local seen = {}
      local items = {}

      local function add(item)
        if not item or item == '' then
          return
        end

        item = normalize_completion_item(item)
        if seen[item] then
          return
        end

        seen[item] = true
        table.insert(items, item)
      end

      for _, template in ipairs(templates or {}) do
        if not template.hide then
          add(template.name)
        end
      end

      table.sort(items)
      return items
    end

    local function refresh_template_completion_cache(search, wait_ms)
      search = search or get_search_params()
      local cache_key = get_cache_key(search)
      local done = false

      require('overseer.template').list(search, function(templates)
        template_completion_cache[cache_key] = build_completion_items(templates)
        done = true
      end)

      if wait_ms and wait_ms > 0 then
        vim.wait(wait_ms, function()
          return done
        end)
      end

      return template_completion_cache[cache_key] or {}
    end

    local function complete_overseer_run(arg_lead)
      local search = get_search_params()
      local cache_key = get_cache_key(search)
      local items = template_completion_cache[cache_key]

      if not items then
        items = refresh_template_completion_cache(search, 200)
      end

      local prefix = arg_lead:lower()
      return vim.tbl_filter(function(item)
        return prefix == '' or item:lower():find('^' .. vim.pesc(prefix)) ~= nil
      end, items)
    end

    local function override_overseer_run_command()
      pcall(vim.api.nvim_del_user_command, 'OverseerRun')
      vim.api.nvim_create_user_command('OverseerRun', function(args)
        require('overseer.commands')._run_template(args)
      end, {
        desc = 'Run a task from a template',
        nargs = '*',
        complete = complete_overseer_run,
      })
    end

    local function create_overseer_watch_command()
      pcall(vim.api.nvim_del_user_command, 'OverseerWatch')
      vim.api.nvim_create_user_command('OverseerWatch', function()
        local path = vim.fn.expand('%:p')
        if vim.bo.buftype ~= '' or path == '' then
          vim.notify('OverseerWatch requires a file-backed buffer', vim.log.levels.ERROR)
          return
        end

        overseer.run_task({ autostart = false }, function(task, err)
          if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
          end

          if not task then
            vim.notify('Task selection was cancelled', vim.log.levels.WARN)
            return
          end

          task:add_component({ 'restart_on_save', paths = { path } })
          task:start()
          overseer.toggle()
        end)
      end, {
        desc = 'Select a task template, run it, and restart on save',
      })
    end

    overseer.setup(opts)
    override_overseer_run_command()
    create_overseer_watch_command()

    local group = vim.api.nvim_create_augroup('overseer_completion_cache', { clear = true })
    vim.api.nvim_create_autocmd({ 'VimEnter', 'BufEnter', 'DirChanged' }, {
      group = group,
      callback = function()
        refresh_template_completion_cache()
      end,
    })
    refresh_template_completion_cache()
  end,
}
