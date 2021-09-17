local vim, fn, api, g = vim, vim.fn, vim.api, vim.g

local M = {}

-- FZF functions {{{
local function fzf_wrap(name, opts, bang)
  name = name or ""
  opts = opts or {}
  bang = bang or 0

  if g.fzf_lsp_layout then
    opts = vim.tbl_extend('keep', opts, g.fzf_lsp_layout)
  end

  if g.fzf_lsp_colors then
    vim.list_extend(opts.options, {"--color", g.fzf_lsp_colors})
  end

  local sink_fn = opts["sink*"] or opts["sink"]
  if sink_fn ~= nil then
    opts["sink"] = nil; opts["sink*"] = 0
  else
    -- if no sink function is given i automatically put the actions
    if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
      vim.list_extend(
        opts.options, {"--expect", table.concat(vim.tbl_keys(g.fzf_lsp_action), ",")}
      )
    end
  end
  local wrapped = fn["fzf#wrap"](name, opts, bang)
  wrapped["sink*"] = sink_fn

  return wrapped
end

local function fzf_run(...)
  return fn["fzf#run"](...)
end

-- utility functions {{{
local function partial(func, arg)
  return (function(...)
    return func(arg, ...)
  end)
end

local function check_capabilities(feature, client_id)
  local clients = vim.lsp.buf_get_clients(client_id or 0)

  local supported_client = false
  for _, client in pairs(clients) do
    supported_client = client.resolved_capabilities[feature]
    if supported_client then goto continue end
  end

  ::continue::
  if supported_client then
    return true
  else
    if #clients == 0 then
      print("LSP: no client attached")
    else
      print("LSP: server does not support " .. feature)
    end
    return false
  end
end

local function locations_from_lines(lines, filename_included)
  local extract_location = (function (l)
    local path, lnum, col, text, bufnr

    if filename_included then
      path, lnum, col, text = l:match("([^:]*):([^:]*):([^:]*):(.*)")
    else
      bufnr = api.nvim_get_current_buf()
      path = fn.expand("%")
      lnum, col, text = l:match("([^:]*):([^:]*):(.*)")
    end

    return {
      bufnr = bufnr,
      filename = path,
      lnum = lnum,
      col = col,
      text = text or "",
    }
  end)

  local locations = {}
  for _, l in ipairs(lines) do
    table.insert(locations, extract_location(l))
  end

  return locations
end

local function common_sink(infile, lines)
  local action
  if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
    local key = table.remove(lines, 1)
    action = g.fzf_lsp_action[key]
  end

  local locations = locations_from_lines(lines, not infile)
  if action == nil and #lines > 1 then
    vim.lsp.util.set_qflist(locations)
    api.nvim_command("copen")
    api.nvim_command("wincmd p")

    return
  end

  action = action or "e"

  for _, loc in ipairs(locations) do
    local edit_infile = (
      (infile or fn.expand("%:~:.") == loc["filename"]) and
      (action == "e" or action == "edit")
    )
    -- if i'm editing the same file i'm in, i can just move the cursor
    if not edit_infile then
      -- otherwise i can start executing the actions
      local err = api.nvim_command(action .. " " .. loc["filename"])
      if err ~= nil then
        api.nvim_command("echoerr " .. err)
      end
    end

    fn.cursor(loc["lnum"], loc["col"])
    api.nvim_command("normal! zvzz")
  end
end

function M.workspace_symbol(bang, opts)
  if not check_capabilities("workspace_symbol") then
    return
  end

  local query = opts.query or ''
  local header = 'Workspace Symbols'

  -- command:python3 /home/aikawa/.cache/dein/repos/github.com/antoinemadec/coc-fzf/script/get_workspace_symbols.py %s %s %s %s %s %s %s %s
  -- ws_symbols_opts:
  -- query:
  -- ansi_typedef:'^[[38;2;181;137;0mSTRING^[[m'
  -- ansi_comment:'^[[38;2;88;110;117mSTRING^[[m'
  -- ansi_ignore:'^[[30mSTRING^[[m'
  -- symbol_excludes:"[]"
  local change_script = vim.env.XDG_CONFIG_HOME ..
    '/nvim/bin/get_workspace_symbols.py %s %s %s %s %s %s %s %s'
  local ansi_typedef = "'\x1b[38;2;181;137;0mSTRING\x1b[m'"
  local ansi_comment = "'\x1b[38;2;88;110;117mSTRING\x1b[m'"
  local ansi_ignore ="'\x1b[30mSTRING\x1b[m'"
  local symbol_excludes = "'[]'"

  -- let initial_command = printf(command_fmt,
  --       \ join(ws_symbols_opts), v:servername, bufnr(), "'" . initial_query . "'",
  --       \ ansi_typedef, ansi_comment, ansi_ignore, symbol_excludes)
  local initial_command = string.format(change_script,
    '', vim.v.servername, vim.api.nvim_get_current_buf(), "'" .. query .. "'",
    ansi_typedef, ansi_comment, ansi_ignore, symbol_excludes)
  local reload_command = string.format(change_script,
    '', vim.v.servername, vim.api.nvim_get_current_buf(), '{q}',
    ansi_typedef, ansi_comment, ansi_ignore, symbol_excludes)

  local options = {
    "--prompt", header .. ">",
    "--ansi",
    "--multi",
    "--bind", "ctrl-a:select-all,ctrl-d:deselect-all,change:reload:" .. reload_command,
  }

  if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
    vim.list_extend(
      options, {"--expect", table.concat(vim.tbl_keys(g.fzf_lsp_action), ",")}
    )
  end

  if g.fzf_lsp_preview_window then
    if #g.fzf_lsp_preview_window == 0 then
      g.fzf_lsp_preview_window = {"hidden"}
    end

    vim.list_extend(options, {"--preview-window", g.fzf_lsp_preview_window[1]})
    if #g.fzf_lsp_preview_window > 1 then
      local preview_bindings = {}
      for i=2, #g.fzf_lsp_preview_window, 1 do
        table.insert(preview_bindings, g.fzf_lsp_preview_window[i] .. ":toggle-preview")
      end
      vim.list_extend(options, {"--bind", table.concat(preview_bindings, ",")})
    end
  end

  print(initial_command)
  vim.list_extend(options, {"--preview", "bat"})
  fzf_run(fzf_wrap("fzf_lsp", {
    source = initial_command,
    sink = partial(common_sink, false),
    options = options,
  }, bang))

end

function M.get_workspace_synbols_sync(query, bufnr)
  local params = {query = query or ''}
  local results_lsp, err = vim.lsp.buf_request_sync(
    tonumber(bufnr), "workspace/symbol", params, 3000
  )
  if err then
    print("ERROR: " .. tostring(err))
    return
  end

  return results_lsp[1].result
  -- for k, v in pairs( results_lsp[1].result ) do
  --   -- block
  --   print(vim.inspect(k))
  --   print(vim.inspect(v))
  -- end
end

return M
