local M = {}

local function mcp_server_name(params)
  local meta = type(params._meta) == "table" and params._meta or {}
  if meta.codex_approval_kind ~= "mcp_tool_call" then return nil end
  local explicit = meta.serverName or meta.server_name
  if type(explicit) == "string" and explicit ~= "" then return explicit end
  return tostring(params.message or ""):match('^Allow the ([%w_.-]+) MCP server to run tool ".+"%?$')
end

local function trusted_server(servers, name)
  if type(servers) ~= "table" or not name then return false end
  if servers[name] == true then return true end
  for _, candidate in ipairs(servers) do
    if candidate == name then return true end
  end
  return false
end

local function supports_persist_value(schema, target)
  local persist = type(schema) == "table"
      and type(schema.properties) == "table"
      and type(schema.properties.persist) == "table"
      and schema.properties.persist
    or nil
  if not persist then return false end
  for _, value in ipairs(type(persist.enum) == "table" and persist.enum or {}) do
    if value == target then return true end
  end
  for _, variant in ipairs(type(persist.oneOf) == "table" and persist.oneOf or {}) do
    if type(variant) == "table" and variant.const == target then return true end
  end
  return false
end

function M.auto_approve_mcp(params, trusted_servers)
  params = type(params) == "table" and params or {}
  if not trusted_server(trusted_servers, mcp_server_name(params)) then return nil end
  local content = vim.empty_dict()
  if supports_persist_value(params.requestedSchema, "once") then
    content = { persist = "once" }
  end
  return { action = "accept", content = content }
end

function M.auto_approve_team_mcp(params, session, trusted_servers)
  session = type(session) == "table" and session or {}
  local agent_cfg = type(session.agent_cfg) == "table" and session.agent_cfg or {}
  local thread_metadata = type(session.thread_record) == "table"
      and type(session.thread_record.metadata) == "table"
      and session.thread_record.metadata
    or {}
  local team = session.lazyagent_team
    or agent_cfg.lazyagent_team
    or thread_metadata.lazyagent_team
  if type(team) ~= "table" then return nil end
  return M.auto_approve_mcp(params, trusted_servers)
end

local function sorted_properties(schema)
  local properties = type(schema) == "table" and schema.properties or {}
  local required = {}
  for _, name in ipairs(type(schema) == "table" and schema.required or {}) do
    required[tostring(name)] = true
  end
  local names = vim.tbl_keys(type(properties) == "table" and properties or {})
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = {
      name = name,
      schema = type(properties[name]) == "table" and properties[name] or {},
      required = required[name] == true,
    }
  end
  return out
end

local function enum_choices(schema)
  local values = type(schema.enum) == "table" and schema.enum or nil
  if values then
    return vim.tbl_map(function(value)
      return { value = value, label = tostring(value) }
    end, values)
  end
  local variants = type(schema.oneOf) == "table" and schema.oneOf
    or type(schema.anyOf) == "table" and schema.anyOf
    or nil
  if not variants then return nil end
  local out = {}
  for _, variant in ipairs(variants) do
    if type(variant) == "table" and variant.const ~= nil then
      out[#out + 1] = {
        value = variant.const,
        label = tostring(variant.title or variant.const),
        description = variant.description,
      }
    end
  end
  return #out > 0 and out or nil
end

local function parse_scalar(value, schema)
  if value == nil or value == "" then
    if schema.default ~= nil then return schema.default end
    return value
  end
  if schema.type == "number" or schema.type == "integer" then
    local number = tonumber(value)
    if not number or (schema.type == "integer" and number % 1 ~= 0) then
      return nil, "expected " .. schema.type
    end
    if schema.minimum ~= nil and number < schema.minimum then
      return nil, "must be at least " .. tostring(schema.minimum)
    end
    if schema.maximum ~= nil and number > schema.maximum then
      return nil, "must be at most " .. tostring(schema.maximum)
    end
    return number
  end
  return value
end

local function prompt_field(field, done, deps)
  local schema = field.schema
  local title = tostring(schema.title or field.name)
  if schema.description and schema.description ~= "" then
    title = title .. " — " .. tostring(schema.description)
  end
  if schema.type == "array" then
    local choices = enum_choices(type(schema.items) == "table" and schema.items or {})
    if not choices then
      done(nil, "unsupported array schema")
      return
    end
    local selected = {}
    local function choose()
      local items = { { done = true, label = "Done" } }
      for _, choice in ipairs(choices) do
        items[#items + 1] = {
          value = choice.value,
          label = (selected[choice.value] and "✓ " or "  ") .. choice.label,
          description = choice.description,
        }
      end
      deps.select(items, {
        prompt = title .. (field.required and " (required)" or ""),
        format_item = function(choice)
          return choice.description and (choice.label .. " — " .. choice.description) or choice.label
        end,
      }, function(choice)
        if not choice then
          done(nil, "cancelled")
        elseif choice.done then
          local values = {}
          for _, candidate in ipairs(choices) do
            if selected[candidate.value] then values[#values + 1] = candidate.value end
          end
          local minimum = tonumber(schema.minItems) or (field.required and 1 or 0)
          if #values < minimum then
            deps.notify(string.format("%s requires at least %d choice(s)", field.name, minimum), vim.log.levels.WARN)
            choose()
          else
            done(values)
          end
        else
          selected[choice.value] = not selected[choice.value]
          choose()
        end
      end)
    end
    choose()
    return
  end
  local choices = enum_choices(schema)
  if choices then
    if field.other_name then
      choices[#choices + 1] = { other = true, label = "Other…" }
    end
    deps.select(choices, {
      prompt = title .. (field.required and " (required)" or ""),
      format_item = function(choice)
        return choice.description and (choice.label .. " — " .. choice.description) or choice.label
      end,
    }, function(choice)
      if not choice and field.required then
        done(nil, "cancelled")
      elseif choice and choice.other then
        deps.input({ prompt = "Other: " }, function(value)
          if value == nil then
            done(nil, "cancelled")
          elseif vim.trim(value) == "" then
            done(nil, "required")
          else
            done(value, nil, field.other_name)
          end
        end)
      else
        done(choice and choice.value or nil)
      end
    end)
    return
  end

  if schema.type == "boolean" then
    local boolean_choices = {
      { value = true, label = "Yes" },
      { value = false, label = "No" },
    }
    deps.select(boolean_choices, {
      prompt = title .. (field.required and " (required)" or ""),
      format_item = function(choice) return choice.label end,
    }, function(choice)
      if not choice and field.required then
        done(nil, "cancelled")
      else
        done(choice and choice.value or schema.default)
      end
    end)
    return
  end

  deps.input({
    prompt = title .. ": ",
    default = schema.default ~= nil and tostring(schema.default) or nil,
  }, function(value)
    if value == nil then
      done(nil, "cancelled")
      return
    end
    if value == "" and field.required and schema.default == nil then
      done(nil, "required")
      return
    end
    local parsed, err = parse_scalar(value, schema)
    done(parsed, err)
  end)
end

local function prompt_form(params, done, deps)
  local fields = sorted_properties(params.requestedSchema or {})
  local other_fields = {}
  for _, field in ipairs(fields) do
    local codex_meta = field.schema
      and field.schema._meta
      and field.schema._meta.codex
      or {}
    if codex_meta.isOtherAnswer == true and codex_meta.questionId then
      other_fields[tostring(codex_meta.questionId)] = field.name
      field.skip = true
    end
  end
  for _, field in ipairs(fields) do
    field.other_name = other_fields[field.name]
  end
  if #fields == 0 then
    done({ action = "accept", content = vim.empty_dict() })
    return
  end
  local content = {}
  local index = 0
  local function next_field()
    index = index + 1
    local field = fields[index]
    if not field then
      done({ action = "accept", content = content })
      return
    end
    if field.skip then
      next_field()
      return
    end
    prompt_field(field, function(value, err, target_name)
      if err == "cancelled" then
        done({ action = "cancel" })
        return
      end
      if err then
        deps.notify(string.format("ACP input for %s %s", field.name, err), vim.log.levels.WARN)
        index = index - 1
        next_field()
        return
      end
      if value ~= nil and value ~= "" then content[target_name or field.name] = value end
      next_field()
    end, deps)
  end
  next_field()
end

function M.handle(params, opts, done, deps)
  params = type(params) == "table" and params or {}
  opts = type(opts) == "table" and opts or {}
  deps = vim.tbl_extend("keep", deps or {}, {
    select = vim.ui.select,
    input = vim.ui.input,
    notify = vim.notify,
    open = vim.ui.open,
  })

  if opts.question_policy == "autonomous" then
    done({ action = "decline" })
    return
  end

  if params.mode == "url" then
    local choices = {
      { action = "accept", label = "Open URL" },
      { action = "decline", label = "Decline" },
    }
    deps.select(choices, {
      prompt = tostring(params.message or "ACP requests opening a URL") .. "\n" .. tostring(params.url or ""),
      format_item = function(choice) return choice.label end,
    }, function(choice)
      if not choice then
        done({ action = "cancel" })
      elseif choice.action == "accept" then
        if type(deps.open) == "function" then deps.open(params.url) end
        done({ action = "accept" })
      else
        done({ action = "decline" })
      end
    end)
    return
  end

  if params.mode ~= nil and params.mode ~= "form" then
    done(nil, { code = -32602, message = "Unsupported ACP elicitation mode: " .. tostring(params.mode) })
    return
  end
  prompt_form(params, done, deps)
end

return M
