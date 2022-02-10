local vim, fn, api, g = vim, vim.fn, vim.api, vim.g

local M = {}

-- binary paths {{{
local bin = vim.env.XDG_CACHE_HOME .. '/dein/repos/github.com/junegunn/fzf.vim/bin/preview.sh'
-- }}}

-- utility functions {{{
local function partial(func, arg)
  return (function(...)
    return func(arg, ...)
  end)
end

local function perror(err)
  print("ERROR: " .. tostring(err))
end

local function mk_handler(fn)
  return function(...)
    local config_or_client_id = select(4, ...)
    local is_new = type(config_or_client_id) ~= 'number'
    if is_new then
      fn(...)
    else
      local err = select(1, ...)
      local method = select(2, ...)
      local result = select(3, ...)
      local client_id = select(4, ...)
      local bufnr = select(5, ...)
      local config = select(6, ...)
      fn(err, result, { method = method, client_id = client_id, bufnr = bufnr }, config)
    end
  end
end
-- }}}

local function unique (tbl)
    local check = {}
    local res = {}

    for i, v in ipairs(tbl) do
        if not(check[v]) then
            check[v] = true
            res[1+#res] = v
        end
    end

    for k, v in pairs (tbl) do
        if not (type(k)=="number" and k%1==0) then
            res[k] = v
        end
    end
    return res
end

-- LSP utility {{{
local function extract_result(results_lsp)
  if results_lsp then
    local results = {}
    for _, server_results in pairs(results_lsp) do
      if server_results.result then
        vim.list_extend(results, server_results.result)
      end
    end

    return results
  end
end

local function call_sync(method, params, opts, handler)
  params = params or {}
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local results_lsp, err = vim.lsp.buf_request_sync(
    bufnr, method, params, opts.timeout or g.fzf_lsp_timeout
  )

  local ctx = {
    method = method,
    bufnr = bufnr,
    client_id = results_lsp and next(results_lsp) or nil,
  }
  handler(err, extract_result(results_lsp), ctx, nil)
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

local function code_action_execute(action)
  if action.edit or type(action.command) == "table" then
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit)
    end
    if type(action.command) == "table" then
      vim.lsp.buf.execute_command(action.command)
    end
  else
    vim.lsp.buf.execute_command(action)
  end
end

local function lines_from_locations(locations, include_filename)
  local fnamemodify = (function (filename)
    if include_filename then
      return fn.fnamemodify(filename, ":~:.") .. ":"
    else
      return ""
    end
  end)
  local lines = {}
  for _, loc in ipairs(locations) do
    table.insert(lines, (
        "\x1b[38;2;102;204;0m" .. fnamemodify(loc['filename']) .. "\x1b[0m"
        .. loc["lnum"]
        .. ":"
        .. loc["col"]
        .. ": "
        .. "\x1b[38;2;181;137;0m" .. vim.trim(loc["text"]) .. "\x1b[0m"
    ))
  end

  return lines
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

local function location_handler(err, locations, ctx, _, error_message)
  if err ~= nil then
    perror(err)
    return
  end

  if not locations or vim.tbl_isempty(locations) then
    print(error_message)
    return
  end

  if vim.tbl_islist(locations) then
    if #locations == 1 then
      vim.lsp.util.jump_to_location(locations[1], 'utf-8')

      return
    end
  else
    vim.lsp.util.jump_to_location(locations, 'utf-8')
  end

  return lines_from_locations(
    vim.lsp.util.locations_to_items(locations, 'utf-8'), true
  )
end
-- }}}

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

local function fzf_locations(bang, prompt, header, source, infile)
  local preview_cmd = (infile and
    (bin .. " " .. fn.expand("%") .. ":{}") or
    (bin .. " {+1}:{+2}")
  )

  local options = {
    "--prompt", header .. " >",
    "--ansi", "--delimiter", ":",
    "--preview-window", "right:+{2}-4",
    "--multi",
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

  vim.list_extend(options, {"--preview", preview_cmd})
  fzf_run(fzf_wrap("fzf_lsp", {
    source = unique(source),
    sink = partial(common_sink, infile),
    options = options,
  }, bang))
end

local function fzf_code_actions(bang, prompt, header, actions)
  local lines = {}
  for i, a in ipairs(actions) do
    a["idx"] = i
    lines[i] = a["idx"] .. ". " .. a["title"]
  end

  local sink_fn = (function(source)
    local _, line = next(source)
    local idx = tonumber(line:match("(%d+)[.]"))
    code_action_execute(actions[idx])
  end)

  fzf_run(fzf_wrap("fzf_lsp", {
      source = lines,
      sink = sink_fn,
      options = {
        "--prompt", header .. " >",
        "--ansi",
      }
  }, bang))
end
-- }}}

-- LSP reponse handlers {{{
local function code_action_handler(bang, err, result, _, _)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("Code Action not available")
    return
  end

  for i, a in ipairs(result) do
    a.idx = i
  end

  fzf_code_actions(bang, "", "Code Actions", result)
end

local function definition_handler(bang, err, result, ctx, config)
  local results = location_handler(
    err, result, ctx, config, "Definition not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Definitions", results, false)
  end
end

local function declaration_handler(bang, err, result, ctx, config)
  local results = location_handler(
    err, result, ctx, config, "Declaration not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Declarations", results, false)
  end
end

local function type_definition_handler(bang, err, result, ctx, config)
  local results = location_handler(
    err, result, ctx, config, "Type Definition not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Type Definitions", results, false)
  end
end

local function implementation_handler(bang, err, result, ctx, config)
  local results = location_handler(
    err, result, ctx, config, "Implementation not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Implementations", results, false)
  end
end

local function references_handler(bang, err, result, ctx, _)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("References not found")
    return
  end

  local lines = lines_from_locations(
    vim.lsp.util.locations_to_items(result, 'utf-8'), true
  )
  fzf_locations(bang, "", "References", lines, false)
end

local function document_symbol_handler(bang, err, result, ctx, _)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("Document Symbol not found")
    return
  end

  local lines = lines_from_locations(
    vim.lsp.util.symbols_to_items(result, ctx.bufnr), false
  )
  fzf_locations(bang, "", "Document Symbols", lines, true)
end
-- }}}

-- COMMANDS {{{
function M.definition(bang, opts)
  if not check_capabilities("goto_definition") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/definition", params, opts, partial(definition_handler, bang)
  )
end

function M.declaration(bang, opts)
  if not check_capabilities("declaration") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/declaration", params, opts, partial(declaration_handler, bang)
  )
end

function M.type_definition(bang, opts)
  if not check_capabilities("type_definition") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/typeDefinition", params, opts, partial(type_definition_handler, bang)
  )
end

function M.implementation(bang, opts)
  if not check_capabilities("implementation") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/implementation", params, opts, partial(implementation_handler, bang)
  )
end

function M.references(bang, opts)
  if not check_capabilities("find_references") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = true }
  call_sync(
    "textDocument/references", params, opts, partial(references_handler, bang)
  )
end

function M.document_symbol(bang, opts)
  if not check_capabilities("document_symbol") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/documentSymbol", params, opts, partial(document_symbol_handler, bang)
  )
end

function M.code_action(bang, opts)
  if not check_capabilities("code_action") then
    return
  end

  local params = vim.lsp.util.make_range_params()
  params.context = {
    diagnostics = vim.lsp.diagnostic.get_line_diagnostics()
  }
  call_sync(
    "textDocument/codeAction", params, opts, partial(code_action_handler, bang)
  )
end

function M.range_code_action(bang, opts)
  if not check_capabilities("code_action") then
    return
  end

  local params = vim.lsp.util.make_given_range_params()
  params.context = {
    diagnostics = vim.lsp.diagnostic.get_line_diagnostics()
  }
  call_sync(
    "textDocument/codeAction", params, opts, partial(code_action_handler, bang)
  )
end

function M.diagnostic(bang, all, severity, severity_limit)

  local bufnr = api.nvim_get_current_buf()

  local buffer_diags
  if all then
    buffer_diags = vim.lsp.diagnostic.get_all()
  else
    buffer_diags = vim.lsp.diagnostic.get(bufnr)
  end

  local severity = severity
  local severity_limit = severity_limit

  local items = {}
  local get_diag_item = function(bufnr, diag)
    if severity then
      if not diag.severity then
        return
      end

      if severity ~= diag.severity then
        return
      end
    elseif severity_limit then
      if not diag.severity then
        return
      end

      if severity_limit < diag.severity then
        return
      end
    end

    local pos = diag.range.start
    local row = pos.line
    local col = vim.lsp.util.character_offset(bufnr, row, pos.character)
    local filename = all and vim.api.nvim_buf_get_name(bufnr) or nil

    return {
      filename = filename,
      lnum = row + 1,
      col = col + 1,
      text = diag.message,
      type = vim.lsp.protocol.DiagnosticSeverity[diag.severity or
        vim.lsp.protocol.DiagnosticSeverity.Error]
    }

  end

  local entries = {}
  if all then
    for bufnr, diag_list in pairs(buffer_diags) do
      local tmp = {}
      for _, diag in ipairs(diag_list) do
        table.insert(tmp, get_diag_item(bufnr, diag))
      end
      table.sort(tmp, function(a, b) return a.lnum < b.lnum end)
      vim.list_extend(items, tmp)
    end

  else
    for _, diag in ipairs(buffer_diags) do
      table.insert(items, get_diag_item(bufnr, diag))
    end
    table.sort(items, function(a, b) return a.lnum < b.lnum end)

  end

  local fnamemodify = (function (filename)
    if filename ~= nil and all then
      return fn.fnamemodify(filename, ":~:.")
    else
      return ""
    end
  end)

  for i, e in ipairs(items) do
    entries[i] = (
      fnamemodify(e["filename"])
      .. ':'
      .. e["lnum"]
      .. ':'
      .. e["col"]
      .. ':'
      .. "\x1b[38;2;102;204;0m" .. e["type"] .. "\x1b[0m"
      .. ': '
      .. "\x1b[38;2;181;137;0m" .. e["text"]:gsub("%s", " ") .. "\x1b[0m"
    )
  end

  if vim.tbl_isempty(entries) then
    print("Empty diagnostic")
    return
  end

  fzf_locations(bang, "", "Diagnostics", entries, not all)
end
-- }}}

-- LSP FUNCTIONS {{{
M.code_action_call = partial(M.code_action, 0)
M.range_code_action_call = partial(M.range_code_action, 0)
M.definition_call = partial(M.definition, 0)
M.declaration_call = partial(M.declaration, 0)
M.type_definition_call = partial(M.type_definition, 0)
M.implementation_call = partial(M.implementation, 0)
M.references_call = partial(M.references, 0)
M.document_symbol_call = partial(M.document_symbol, 0)
M.diagnostic_call = partial(M.diagnostic, 0)
-- }}}

-- LSP HANDLERS {{{
M.code_action_handler = partial(code_action_handler, 0)
M.definition_handler = partial(definition_handler, 0)
M.declaration_handler = partial(declaration_handler, 0)
M.type_definition_handler = partial(type_definition_handler, 0)
M.implementation_handler = partial(implementation_handler, 0)
M.references_handler = partial(references_handler, 0)
M.document_symbol_handler = partial(document_symbol_handler, 0)
-- }}}

-- Lua SETUP {{{
M.setup = function(opts)
  opts = opts or {}
  vim.cmd [[command! -bang Definition lua require("lsp.configs.fzf").definition(<bang>0)]]
  vim.cmd [[command! -bang Declaration lua require("lsp.configs.fzf").declaration(<bang>0)]]
  vim.cmd [[command! -bang TypeDefinition lua require("lsp.configs.fzf").type_definition(<bang>0)]]
  vim.cmd [[command! -bang Implementation lua require("lsp.configs.fzf").implementation(<bang>0)]]
  vim.cmd [[command! -bang References lua require("lsp.configs.fzf").references(<bang>0)]]
  vim.cmd [[command! -bang DocumentSymbol lua require("lsp.configs.fzf").document_symbol(<bang>0)]]
  vim.cmd [[command! -bang CodeAction lua require("lsp.configs.fzf").code_action(<bang>0)]]
  vim.cmd [[command! -bang RangeCodeAction lua require("lsp.configs.fzf").range_code_action(<bang>0)]]
  vim.cmd [[command! -bang Diagnostics lua require("lsp.configs.fzf").diagnostic(<bang>0)]]
  vim.cmd [[command! -bang DiagnosticsAll lua require("lsp.configs.fzf").diagnostic(<bang>0, true)]]
end
-- }}}

return M
