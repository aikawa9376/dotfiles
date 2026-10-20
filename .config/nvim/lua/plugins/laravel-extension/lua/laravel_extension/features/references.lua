local U = require("laravel_extension.utils")
local I = require("laravel_extension.index")
local P = require("laravel_extension.php")
local M = {}

local function fallback() require("fzf-lua.cmd").run_command("lsp_references") end

function M.target(opts)
  opts = opts or {}
  local target = I.at_cursor(opts)
  if target then return target end
  local root = opts.root or U.project_root(0)
  if not root then return end
  local path = vim.api.nvim_buf_get_name(0)
  for _, base in ipairs({ "app/Livewire/", "app/Http/Livewire/" }) do
    local prefix = root .. "/" .. base
    if path:sub(1, #prefix) == prefix then
      local doc = P.document(path)
      local pos = vim.api.nvim_win_get_cursor(0)
      local node = doc and doc.root:named_descendant_for_range(pos[1] - 1, pos[2], pos[1] - 1, pos[2])
      if doc and doc.class and node == doc.class:field("name")[1] then
        local parts = vim.split(path:sub(#prefix + 1):gsub("%.php$", ""), "/", { plain = true })
        for j, part in ipairs(parts) do parts[j] = U.kebab(part) end
        local name = table.concat(parts, ".")
        return { path = path, root = root, kind = "livewire", name = name,
          identities = { { kind = "livewire", name = name } } }
      end
    end
  end
end

function M.goto_at_cursor(opts)
  opts = opts or {}
  local root = opts.root or U.project_root(0)
  if not root then return false end
  if require("laravel_extension.features.component").goto_references_at_cursor(opts) then return true end
  if require("laravel_extension.features.routes").goto_at_cursor({ root = root, picker = opts.picker,
      fallback = opts.fallback or fallback }) then return true end
  local target = M.target(opts)
  if not target then return false end
  I.references(target, function(items, err)
    if err then vim.notify(err, vim.log.levels.ERROR)
    elseif #items == 0 then vim.notify("No static references found for " .. target.name, vim.log.levels.INFO)
    else (opts.picker or require("laravel_extension.fzf_picker").select)(items,
      { cwd = root, prompt = "References for " .. target.name .. " > " }) end
  end)
  return true
end

function M.setup(group)
  local function attach(buf)
    if not U.project_root(buf) then return end
    vim.keymap.set("n", "gd", "m`:lua require'plugins.fzf-lua_util'.fzf_laravel()<CR>",
      { buffer = buf, silent = true, desc = "Laravel/LSP definition" })
    vim.keymap.set("n", "gr", function()
      vim.cmd("normal! m`")
      if not M.goto_at_cursor() then fallback() end
    end, { buffer = buf, silent = true, desc = "Laravel/LSP references" })
  end
  vim.api.nvim_create_autocmd("FileType", { group = group, pattern = { "php", "blade" }, callback = function(ev) attach(ev.buf) end })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and (vim.bo[buf].filetype == "php" or vim.bo[buf].filetype == "blade") then attach(buf) end
  end
  vim.api.nvim_create_user_command("LaravelReferences", function()
    if not M.goto_at_cursor() then fallback() end
  end, {})
end
return M
