local U = require("laravel_extension.utils")
local I = require("laravel_extension.index")
local S = require("laravel_extension.syntax")
local P = require("laravel_extension.php")
local M = {}
local verbs = { get = "GET|HEAD", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE",
  options = "OPTIONS", any = "ANY", match = "MATCH", resource = "RESOURCE", apiResource = "RESOURCE" }

function M.in_source(path, text)
  local doc = P.document(path, text)
  if not doc then return {} end
  local tokens, groups, routes = S.tokens(text), {}, {}
  local function value(arg) local t = S.literal(tokens, arg); return t and t.value end
  local function class(arg)
    if not arg then return end
    local name = tokens[arg[1]]
    if not name then return end
    if name.kind == "string" then return name.value:gsub("^\\", "") end
    if tokens[arg[1] + 1] and tokens[arg[1] + 1].value == "::"
        and tokens[arg[1] + 2] and tokens[arg[1] + 2].value == "class" then
      return P.resolve_name(doc, name.value)
    end
  end
  local function chain_start(index)
    local j = index - 1
    while j > 0 do
      if tokens[j].value == ")" and tokens[j].pair then j = tokens[j].pair
      elseif tokens[j].value == ";" or tokens[j].value == "{" or tokens[j].value == "}" then break end
      j = j - 1
    end
    return j + 1
  end
  local function is_route(index)
    for j = chain_start(index), index - 2 do
      if tokens[j + 1] and tokens[j + 1].value == "::" then
        local owner = tokens[j].value
        if owner == "Route" or P.resolve_name(doc, owner) == "Illuminate\\Support\\Facades\\Route" then return true end
      end
    end
    return false
  end
  for i, t in ipairs(tokens) do
    if t.value == "group" and tokens[i + 1] and tokens[i + 1].value == "(" and is_route(i) then
      local opening = tokens[i + 1]
      local group = { start = opening.start, finish = tokens[opening.pair or (i + 1)].finish,
        prefix = "", name = "" }
      for j = chain_start(i), i - 1 do
        if tokens[j + 1] and tokens[j + 1].value == "(" then
          local args = S.args(tokens, j + 1)
          if tokens[j].value == "prefix" then group.prefix = value(args[1]) or ""
          elseif tokens[j].value == "name" then group.name = value(args[1]) or ""
          elseif tokens[j].value == "controller" then group.controller = class(args[1]) end
        end
      end
      local arg = S.args(tokens, i + 1)[1]
      if arg and tokens[arg[1]].value == "[" then
        for _, entry in ipairs(S.args(tokens, arg[1])) do
          local key = tokens[entry[1]]
          local target = { entry[1] + 2, entry[2] }
          if key.value == "prefix" then group.prefix = value(target) or ""
          elseif key.value == "as" then group.name = value(target) or ""
          elseif key.value == "controller" then group.controller = class(target) end
        end
      end
      groups[#groups + 1] = group
    end
  end
  for i, t in ipairs(tokens) do
    if verbs[t.value] and tokens[i + 1] and tokens[i + 1].value == "(" and is_route(i) then
      local args = S.args(tokens, i + 1)
      local uri_index = t.value == "match" and 2 or 1
      local url, action = value(args[uri_index]), args[uri_index + 1]
      if url and action then
        local controller, method
        if tokens[action[1]].value == "[" then
          local pair = S.args(tokens, action[1])
          controller, method = class(pair[1]), value(pair[2])
        else
          local literal = value(action)
          if literal then
            controller, method = literal:match("^(.+)@([^@]+)$")
            if not controller then method = literal end
          else controller, method = class(action), "__invoke" end
        end
        local prefix, name = {}, ""
        for _, group in ipairs(groups) do
          if t.start > group.start and t.finish < group.finish then
            if group.prefix ~= "" then prefix[#prefix + 1] = group.prefix end
            name = name .. group.name
            controller = controller or group.controller
          end
        end
        if controller and not controller:find("\\", 1, true) then
          controller = doc.aliases[controller] or ("App\\Http\\Controllers\\" .. controller)
        end
        local opening = tokens[i + 1]
        local j, suffix, only, except = (opening.pair or i + 1) + 1, "", nil, {}
        while tokens[j] and tokens[j].value == "->" and tokens[j + 2] and tokens[j + 2].value == "(" do
          local chained, chained_args = tokens[j + 1].value, S.args(tokens, j + 2)
          if chained == "name" then suffix = value(chained_args[1]) or ""
          elseif chained == "only" or chained == "except" then
            local set = {}
            for k = j + 3, (tokens[j + 2].pair or j + 3) - 1 do
              if tokens[k].kind == "string" then set[tokens[k].value] = true end
            end
            if chained == "only" then only = set else except = set end
          end
          j = (tokens[j + 2].pair or j + 2) + 1
        end
        prefix[#prefix + 1] = url
        url = "/" .. table.concat(prefix, "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
        local row, col = S.position(text, t.start)
        local function add(action_name, http, route_url, route_name)
          if not controller then return end
          routes[#routes + 1] = { path = path, row = row, col = col, kind = "route", controller = controller,
            action = action_name, method = http, url = route_url, name = route_name,
            text = http .. " " .. route_url .. (route_name ~= "" and (" [" .. route_name .. "]") or "") }
        end
        if t.value == "resource" or t.value == "apiResource" then
          controller = class(action) or controller
          local resource_name = url:match("([^/]+)$") or "resource"
          local resources = { {"index", "GET|HEAD", ""}, {"create", "GET|HEAD", "/create"},
            {"store", "POST", ""}, {"show", "GET|HEAD", "/{id}"}, {"edit", "GET|HEAD", "/{id}/edit"},
            {"update", "PUT|PATCH", "/{id}"}, {"destroy", "DELETE", "/{id}"} }
          for _, entry in ipairs(resources) do
            if (not only or only[entry[1]]) and not except[entry[1]]
                and not (t.value == "apiResource" and (entry[1] == "create" or entry[1] == "edit")) then
              add(entry[1], entry[2], url .. entry[3], name .. resource_name .. "." .. entry[1])
            end
          end
        else
          local http = verbs[t.value]
          if t.value == "match" and args[1] then
            local methods = {}
            for k = args[1][1], args[1][2] do
              if tokens[k].kind == "string" then methods[#methods + 1] = tokens[k].value:upper() end
            end
            http = table.concat(methods, "|")
          end
          if method then add(method, http, url, name .. suffix) end
        end
      end
    end
  end
  return routes
end

function M.find(root, target, callback)
  return I.scan(root, function(files, err)
    if not files then callback(nil, err); return end
    local result = {}
    for _, file in ipairs(files) do
      if not file.path:match("%.blade%.php$") and file.text:find("Route", 1, true) then
        file.routes = file.routes or M.in_source(file.path, file.text)
        for _, route in ipairs(file.routes) do
          if route.controller == target.class and route.action == target.method then result[#result + 1] = route end
        end
      end
    end
    callback(result)
  end)
end

function M.goto_at_cursor(opts)
  opts = opts or {}
  local root = opts.root or U.project_root(0)
  local target = root and P.method_at_cursor(root, opts.allow_body)
  if not target then return false end
  M.find(root, target, function(items, err)
    if err then vim.notify(err, vim.log.levels.ERROR)
    elseif #items > 0 then
      (opts.picker or require("laravel_extension.fzf_picker").select)(items, { cwd = root, prompt = "Controller routes > " })
    elseif opts.fallback then opts.fallback()
    else vim.notify("No static routes found for " .. target.class .. "@" .. target.method, vim.log.levels.INFO) end
  end)
  return true
end

function M.setup()
  vim.api.nvim_create_user_command("LaravelControllerRoutes", function()
    if not M.goto_at_cursor({ allow_body = true }) then vim.notify("Place the cursor in a controller method", vim.log.levels.INFO) end
  end, {})
end
return M
