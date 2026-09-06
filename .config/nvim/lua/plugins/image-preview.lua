return {
  "image-preview",
  virtual = true,
  cmd = "ImagePreview",
  dependencies = { "folke/snacks.nvim" },
  config = function()
    local M = {}
    local preview
    local request = 0
    local search_process

    local function notify(message)
      vim.notify(message, vim.log.levels.WARN, { title = "ImagePreview" })
    end

    function M.normalize(path)
      path = vim.trim(path or "")
      local wiki = path:match("^!%[%[(.-)%]%]$") or path:match("^%[%[(.-)%]%]$")
      path = wiki and wiki:gsub("|.*$", "") or path
      path = path:match("^<(.-)>$") or path:match('^"(.-)"$') or path:match("^'(.-)'$")
        or path:match("^`(.-)`$") or path
      path = path:gsub("[?#].*$", ""):gsub(":%d+:?%d*$", "")
      path = path:gsub("^file://", "")
      path = path:gsub("^https?://[^/]+", "")
      path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
      path = path:gsub("\\([ ()])", "%1"):gsub("\\", "/")
      return vim.fs.normalize(path)
    end

    -- Recognize links even on their labels, then quoted paths and plain <cfile>.
    function M.path_at_cursor()
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2] + 1
      local patterns = { "%[%[(.-)%]%]", "%b[](%b())", '"([^"\n]+)"', "'([^'\n]+)'", "`([^`\n]+)`" }
      for index, pattern in ipairs(patterns) do
        local from = 1
        while true do
          local first, last, value = line:find(pattern, from)
          if not first then break end
          local start = first
          if index <= 2 and line:sub(first - 1, first - 1) == "!" then start = first - 1 end
          if col >= start and col <= last then
            if index == 1 then
              value = value:gsub("|.*$", "")
            elseif index == 2 then
              value = value:sub(2, -2)
              value = value:match("^%s*<(.-)>") or value:gsub('%s+["\'].-["\']%s*$', "")
            end
            return M.normalize(value)
          end
          from = last + 1
        end
      end
      return M.normalize(vim.fn.expand("<cfile>"))
    end

    function M.project_root(buf)
      -- Use the same root policy as the other project-aware commands when loaded.
      local project = package.loaded.project
      if project then
        local ok, root = pcall(project.get_project_root, buf)
        if ok and root then return root end
      end
      return vim.fs.root(buf, { ".git", ".obsidian", "package.json", "composer.json", "Makefile" })
        or vim.fn.getcwd()
    end

    local function readable(path)
      return vim.fn.filereadable(path) == 1
    end

    local function supported(path)
      return require("snacks").image.supports_file(path:lower())
    end

    local function direct_path(query, root, source)
      local candidates = {}
      if query:sub(1, 1) == "/" or query:match("^%a:/") then
        candidates = { query }
      else
        candidates = {
          vim.fs.joinpath(vim.fs.dirname(source) or root, query),
          vim.fs.joinpath(root, query),
        }
      end
      for _, path in ipairs(candidates) do
        if readable(path) and supported(path) then return vim.fs.normalize(path) end
      end
    end

    -- Exact filenames dominate stem/substring matches; trailing directories
    -- distinguish e.g. icons/logo.png from screenshots/logo.png.
    function M.rank(query, files)
      local name = vim.fs.basename(query):lower()
      local stem = name:gsub("%.[^.]+$", "")
      if name == "" or stem == "" then return {} end
      local wanted = vim.split(query:lower(), "/", { plain = true, trimempty = true })
      local results = {}
      for _, file in ipairs(files) do
        if supported(file) then
          local base = vim.fs.basename(file):lower()
          local base_stem = base:gsub("%.[^.]+$", "")
          local score = base == name and 300 or base_stem == stem and 200
            or base_stem:find(stem, 1, true) and 100 or 0
          if score > 0 then
            local parts = vim.split(file:lower(), "/", { plain = true, trimempty = true })
            local suffix = 0
            for offset = 0, math.min(#parts, #wanted) - 1 do
              if parts[#parts - offset] ~= wanted[#wanted - offset] then break end
              suffix = suffix + 1
            end
            results[#results + 1] = { path = file, score = score, suffix = suffix }
          end
        end
      end
      table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.suffix ~= b.suffix then return a.suffix > b.suffix end
        return a.path < b.path
      end)
      return results
    end

    function M.show(path)
      if not readable(path) then return notify("Image not found: " .. path) end
      if preview then preview:close() end
      local snacks = require("snacks")
      -- A scratch buffer avoids changing keymaps/options on an existing image buffer.
      -- Use the same style and renderer as image.hover(), with an explicit source.
      local win = snacks.win({
        style = "snacks_image",
        relative = "cursor",
        row = 1,
        col = 1,
        width = 0.6,
        height = 0.6,
        max_width = 100,
        max_height = 40,
        border = true,
        backdrop = false,
        enter = true,
        focusable = true,
        title = " " .. vim.fs.basename(path) .. " ",
        keys = { q = "close", ["<Esc>"] = "close" },
      })
      preview = win
      snacks.image.buf.attach(win.buf, { src = path })
      return win
    end

    --- Preview an explicit image path, or the link/path under the cursor.
    --- opts.root can override project detection for callers.
    function M.open(path, opts)
      opts = opts or {}
      request = request + 1
      local id = request
      if search_process then search_process:kill(15); search_process = nil end
      local query = path and M.normalize(path) or M.path_at_cursor()
      if query == "" or query == "." then return notify("No image path under cursor") end
      local source_win = vim.api.nvim_get_current_win()
      local source_buf = vim.api.nvim_get_current_buf()
      local source = vim.api.nvim_buf_get_name(source_buf)
      local root = vim.fs.normalize(opts.root or M.project_root(source_buf))
      local exact = direct_path(query, root, source)
      if exact then return M.show(exact) end
      if vim.fn.executable("rg") ~= 1 then return notify("Project image search requires rg") end

      local function current()
        return id == request and vim.api.nvim_win_is_valid(source_win)
          and vim.api.nvim_win_get_buf(source_win) == source_buf
          and vim.api.nvim_get_current_win() == source_win
      end
      -- NUL output and argv arguments preserve spaces and shell metacharacters.
      local formats = require("snacks").image.config.formats
      local argv = { "rg", "--files", "--hidden", "--null", "-g", "!.git",
        "--iglob", "*.{" .. table.concat(formats, ",") .. "}", "." }
      search_process = vim.system(argv,
        { cwd = root }, function(result)
          vim.schedule(function()
            if id == request then search_process = nil end
            if not current() then return end
            if result.code ~= 0 and result.code ~= 1 then
              return notify("Image search failed: " .. vim.trim(result.stderr or ""))
            end
            local files = vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
            local matches = M.rank(query, files)
            if #matches == 0 then return notify("No matching image in " .. root .. ": " .. query) end
            local function choose(item)
              if item and current() then M.show(vim.fs.joinpath(root, item.path)) end
            end
            if #matches == 1 then return choose(matches[1]) end
            vim.ui.select(matches, {
              prompt = "Image: " .. query,
              format_item = function(item) return item.path:gsub("^%./", "") end,
            }, function(item)
              -- Select UIs may restore the source window after invoking the callback.
              vim.schedule(function() choose(item) end)
            end)
          end)
        end)
    end

    vim.api.nvim_create_user_command("ImagePreview", function(args)
      M.open(args.args ~= "" and args.args or nil)
    end, {
      nargs = "?",
      complete = "file",
      desc = "Preview an image under cursor or find it in the project",
      force = true,
    })

    return M
  end,
}
