local U = require("laravel_extension.utils")
local I = require("laravel_extension.index")
local M = {}

local function disk(path)
  local f = io.open(path, "rb")
  if not f then return end
  local text = f:read("*a"); f:close(); return text
end

local function write(path, text)
  local f, err = io.open(path, "wb")
  if not f then error(err) end
  local ok, why = f:write(text)
  local closed, close_err = f:close()
  assert(ok, why); assert(closed, close_err)
end

local function clean_buffer(path)
  local b = vim.fn.bufnr(path)
  return b < 0 or not vim.bo[b].modified
end

-- A plan has no side effects and is invalidated by any intervening disk/buffer
-- change. Names are Laravel view identifiers, not arbitrary filesystem paths.
function M.plan(target, new_name, files)
  if not target.path:match("%.blade%.php$") then return nil, "Rename from a Blade view file" end
  if not new_name:match("^[%w_.%-]+$") and not new_name:match("^[%w_%-]+::[%w_.%-]+$") then
    return nil, "Use a dotted view name, for example components.forms.alert"
  end
  local package, view = new_name:match("^([%w_%-]+)::(.+)$")
  view = view or new_name
  if view:find("..", 1, true) or view:sub(1, 1) == "." or view:sub(-1) == "." then return nil, "Invalid view name" end
  local base = target.root .. "/resources/views/"
  local new_path = base .. (package and ("vendor/" .. package .. "/") or "") .. view:gsub("%.", "/") .. ".blade.php"
  if new_path == target.path then return nil, "The view already has that name" end
  if vim.uv.fs_lstat(new_path) or vim.fn.bufnr(new_path) >= 0 then return nil, "Destination already exists: " .. new_path end
  local parent = vim.fs.dirname(new_path)
  while not vim.uv.fs_lstat(parent) do parent = vim.fs.dirname(parent) end
  local real = vim.uv.fs_realpath(parent)
  local views = vim.uv.fs_realpath((base:gsub("/$", "")))
  if not real or not views or (real ~= views and real:sub(1, #views + 1) ~= views .. "/") then
    return nil, "Destination must stay inside resources/views"
  end
  local new_target = I.file_target(new_path, target.root)
  local file_target = I.file_target(target.path, target.root)
  if not file_target or not new_target then return nil, "View must be inside resources/views" end
  local new_ids = {}
  for _, id in ipairs(new_target.identities) do new_ids[id.kind] = id.name end
  local old_ids = {}
  for _, id in ipairs(file_target.identities) do old_ids[id.kind] = id.name end
  -- Moving an anonymous component out of its component directory would remove
  -- its tag identity; reject rather than leave calls pointing to a missing tag.
  for kind in pairs(old_ids) do
    if not new_ids[kind] then return nil, "Keep this view in its " .. kind .. " directory" end
  end
  local plan = { old_path = target.path, new_path = new_path, changes = {}, items = {}, root = target.root }
  local includes_target = false
  for _, file in ipairs(files) do
    local edits = {}
    for _, ref in ipairs(file.refs) do
      if I.matches(ref, file_target) then
        local replacement = new_ids[ref.kind]
        if replacement and replacement ~= ref.name then
          edits[#edits + 1] = { start = ref.start, finish = ref.finish, text = replacement }
          plan.items[#plan.items + 1] = I.item(file, ref)
        end
      end
    end
    if #edits > 0 or file.path == target.path then
      local stat = vim.uv.fs_lstat(file.path)
      if not stat or stat.type ~= "file" then return nil, "Cannot rename through a symbolic link: " .. file.path end
      if not clean_buffer(file.path) then return nil, "Save modified buffer first: " .. file.path end
      local original = disk(file.path)
      if not original or original ~= file.text then return nil, "File changed during scan: " .. file.path end
      local updated = original
      table.sort(edits, function(a, b) return a.start > b.start end)
      for _, edit in ipairs(edits) do updated = updated:sub(1, edit.start - 1) .. edit.text .. updated:sub(edit.finish + 1) end
      plan.changes[#plan.changes + 1] = { path = file.path, before = original, after = updated }
      if file.path == target.path then includes_target = true end
    end
  end
  if not includes_target then
    return nil, "View file was not found in the project scan"
  end
  return plan
end

function M.apply(plan)
  if vim.uv.fs_lstat(plan.new_path) or vim.fn.bufnr(plan.new_path) >= 0 then return nil, "Destination already exists" end
  for _, change in ipairs(plan.changes) do
    if not clean_buffer(change.path) or disk(change.path) ~= change.before then
      return nil, "Plan is stale; scan again: " .. change.path
    end
  end
  local written, moved = {}, false
  local old_buf = vim.fn.bufnr(plan.old_path)
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(plan.new_path), "p")
    for _, change in ipairs(plan.changes) do
      if change.after ~= change.before then
        written[#written + 1] = change
        write(change.path, change.after)
      end
    end
    local renamed, why = vim.uv.fs_rename(plan.old_path, plan.new_path)
    assert(renamed, why)
    moved = true
    if old_buf >= 0 then vim.api.nvim_buf_set_name(old_buf, plan.new_path) end
  end)
  if not ok then
    local failures = {}
    if moved then
      local restored, why = vim.uv.fs_rename(plan.new_path, plan.old_path)
      if not restored then failures[#failures + 1] = why end
      if old_buf >= 0 then pcall(vim.api.nvim_buf_set_name, old_buf, plan.old_path) end
    end
    for _, change in ipairs(written) do
      local restored, why = pcall(write, change.path, change.before)
      if not restored then failures[#failures + 1] = why end
    end
    return nil, tostring(err) .. (#failures > 0 and ("; restore failed: " .. table.concat(failures, "; ")) or "")
  end
  for _, change in ipairs(plan.changes) do
    local path = change.path == plan.old_path and plan.new_path or change.path
    I.cache[change.path] = nil
    local b = vim.fn.bufnr(path)
    if b >= 0 and vim.api.nvim_buf_is_loaded(b) then
      vim.cmd("silent checktime " .. b)
    end
  end
  return true
end

function M.preview(plan)
  local entries = { { filename = plan.old_path, lnum = 1, col = 1,
    text = "MOVE -> " .. plan.new_path } }
  for _, item in ipairs(plan.items) do
    entries[#entries + 1] = { filename = item.path, lnum = item.row, col = item.col,
      text = "[" .. item.kind .. "] " .. item.text }
  end
  vim.fn.setqflist({}, " ", { title = "Laravel view rename preview", items = entries })
  vim.cmd("copen")
  vim.ui.select({ "Apply rename", "Cancel" }, {
    prompt = string.format("Move view and update %d references in %d files?", #plan.items, #plan.changes),
  }, function(choice)
    if choice ~= "Apply rename" then return end
    local ok, err = M.apply(plan)
    if ok then vim.cmd("cclose") end
    vim.notify(ok and ("Renamed view to " .. plan.new_path) or tostring(err), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

function M.rename(new_name)
  local b = vim.api.nvim_get_current_buf()
  local root = U.project_root(b)
  local target = root and I.file_target(vim.api.nvim_buf_get_name(b), root)
  if not target then vim.notify("Open the Blade view to rename", vim.log.levels.WARN); return end
  local function prepare(name)
    if not name or name == "" or name == target.name then return end
    I.scan(root, function(files, err)
      if not files then vim.notify(err, vim.log.levels.ERROR); return end
      local plan, why = M.plan(target, name, files)
      if not plan then vim.notify(tostring(why), vim.log.levels.WARN); return end
      M.preview(plan)
    end)
  end
  if new_name and new_name ~= "" then prepare(new_name)
  else vim.ui.input({ prompt = "New view name: ", default = target.name }, prepare) end
end

function M.setup(group)
  vim.api.nvim_create_user_command("LaravelRenameView", function(opts) M.rename(opts.args) end,
    { nargs = "?", desc = "Preview and rename a Blade view and its static references" })
  local function attach(buf)
    if vim.api.nvim_buf_get_name(buf):match("%.blade%.php$") and U.project_root(buf) then
      vim.keymap.set("n", "<Leader>rn", function() M.rename() end,
        { buffer = buf, silent = true, desc = "Rename Blade view and references" })
    end
  end
  vim.api.nvim_create_autocmd("FileType", { group = group, pattern = { "php", "blade" }, callback = function(ev) attach(ev.buf) end })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then attach(buf) end
  end
end
return M
