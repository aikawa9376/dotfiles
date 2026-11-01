local M = {}

local function field(text)
  -- Keep source text from introducing fields or terminal control sequences.
  return tostring(text or ""):gsub("[%z\1-\31\127]", " ")
end

local function keymap(key)
  return key:lower():gsub("<c%-", "ctrl-"):gsub("<m%-", "alt-"):gsub(">", "")
end

local function header(client, relative_path)
  relative_path = relative_path:gsub("^%./", "")
  local utils = require("fzf-lua.utils")
  local util = require("obsidian.util")
  local path = vim.fs.normalize(vim.fs.joinpath(tostring(client.dir), relative_path))
  local ok, note = pcall(require("obsidian.note").from_file, path, { max_lines = client.opts.search_max_lines })
  local icon, icon_hl = util.get_icon(path)
  local name = vim.fs.basename(relative_path)
  local directory = relative_path:sub(1, #relative_path - #name)
  local aliases = ok and note.aliases or {}
  local alias_text = {}
  for _, alias in ipairs(aliases or {}) do
    alias_text[#alias_text + 1] = field(alias)
  end
  return table.concat({
    (icon and utils.ansi_from_hl(icon_hl or "Directory", icon) .. " " or "")
      .. utils.ansi_from_hl("Comment", field(directory)),
    utils.ansi_from_hl("Directory", field(name)),
    #alias_text > 0 and (utils.ansi_from_hl("Comment", " [")
      .. utils.ansi_from_hl("String", table.concat(alias_text, ", "))
      .. utils.ansi_from_hl("Comment", "]")) or "",
  }, "\t")
end

local function rows(client, stdout, headers)
  local result = {}
  headers = headers or {}
  local utils = require("fzf-lua.utils")
  for line in stdout:gmatch("[^\n]+") do
    local event = vim.json.decode(line)
    if event.type == "match" and event.data.path.text and event.data.lines.text then
      local data = event.data
      local path = data.path.text
      headers[path] = headers[path] or header(client, path)
      local body = data.lines.text:gsub("\r?\n$", "")
      -- The hidden native location remains available to preview/edit/qf actions.
      -- Only the five visible fields participate in fuzzy matching.
      result[#result + 1] = ("%s:%d:1:\t%s\t%s\t%s"):format(
        path, data.line_number, headers[path],
        utils.ansi_from_hl("LineNr", tostring(data.line_number)), field(body)
      )
    end
  end
  return result
end

local function source(client)
  return function(_, write)
    local pending, headers, stopped = "", {}, false
    local process
    local function write_done(err)
      if err then
        stopped = true
        if process then process:kill(15) end
      end
    end
    -- Read every line once. '^' avoids rg emitting one JSON submatch per
    -- character on long lines, which happens with an empty pattern.
    -- The user's query belongs to fzf, never rg.
    -- Decode complete JSON records in small batches so the editor stays responsive.
    local cmd = { "rg", "--no-config", "--type=md", "--json", "--sortr=modified", "--", "^", "." }
    process = vim.system(cmd, {
      cwd = tostring(client.dir),
      text = true,
      stdout = vim.schedule_wrap(function(err, data)
        if stopped then return end
        if err then
          write_done(err)
          write()
          vim.notify("Obsidian search: " .. err, vim.log.levels.ERROR)
          return
        end
        if not data then return end
        pending = pending .. data
        local last_newline = pending:match("^.*()\n")
        if last_newline then
          local batch = rows(client, pending:sub(1, last_newline), headers)
          pending = pending:sub(last_newline + 1)
          if #batch > 0 then write(batch, write_done) end
        end
      end),
    }, vim.schedule_wrap(function(result)
      if stopped then return end
      if pending ~= "" then write(rows(client, pending, headers), write_done) end
      write()
      if result.code > 1 then
        vim.notify("Obsidian search: " .. vim.trim(result.stderr or "ripgrep failed"), vim.log.levels.ERROR)
      end
    end))
  end
end

function M.open(picker, opts)
  opts = opts or {}
  picker.calling_bufnr = vim.api.nvim_get_current_buf()
  local fzf = require("fzf-lua")
  local actions = require("fzf-lua.actions")
  local entry_to_file = require("fzf-lua.path").entry_to_file
  local picker_actions = {
    ["enter"] = function(selected, fzf_opts)
      if not selected or not selected[1] then return end
      if not opts.no_default_mappings then
        actions.file_edit_or_qf(selected, fzf_opts)
      end
      if opts.callback then
        opts.callback(entry_to_file(selected[1], fzf_opts).path)
      end
    end,
    ["ctrl-s"] = actions.file_split,
    ["ctrl-v"] = actions.file_vsplit,
    ["ctrl-q"] = actions.file_sel_to_qf,
  }
  if not opts.no_default_mappings then
    for key, mapping in pairs(picker:_note_selection_mappings() or {}) do
      picker_actions[keymap(key)] = function(selected, fzf_opts)
        if selected and selected[1] then
          mapping.callback(entry_to_file(selected[1], fzf_opts).path)
        end
      end
    end
    for key, mapping in pairs(picker:_note_query_mappings() or {}) do
      picker_actions[keymap(key)] = function()
        mapping.callback(fzf.get_last_query() or "")
      end
    end
  end

  return fzf.fzf_exec(source(picker.client), {
    cwd = tostring(picker.client.dir),
    prompt = (opts.prompt_title or "Search notes") .. " ❯ ",
    query = opts.query,
    previewer = "builtin",
    actions = picker_actions,
    winopts = { preview = { hidden = false, layout = "horizontal", horizontal = "right:55%" } },
    fzf_opts = {
      ["--ansi"] = true,
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      -- Indices refer to the visible fields: directory, basename, aliases,
      -- line number, body. Try each term in this order.
      ["--nth"] = "2,3,1,5",
      -- An empty query preserves rg's newest-first input order. Once typed,
      -- rank by fuzzy score and matched chunk length, then by that same order.
      ["--no-sort"] = false,
      ["--sort"] = true,
      ["--tiebreak"] = "chunk,index",
    },
  })
end

return M
