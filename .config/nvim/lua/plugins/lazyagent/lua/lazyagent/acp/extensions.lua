local M = {}

local function cursor_property(question)
  local choices = {}
  for _, option in ipairs(type(question.options) == "table" and question.options or {}) do
    if type(option) == "table" and option.id ~= nil then
      choices[#choices + 1] = { const = tostring(option.id), title = tostring(option.label or option.id) }
    end
  end
  if question.allowMultiple == true then
    return {
      type = "array",
      title = tostring(question.prompt or question.id),
      items = { oneOf = choices },
      minItems = 1,
      uniqueItems = true,
    }
  end
  return { type = "string", title = tostring(question.prompt or question.id), oneOf = choices }
end

function M.cursor_question_as_elicitation(params)
  params = type(params) == "table" and params or {}
  local properties, required = {}, {}
  for _, question in ipairs(type(params.questions) == "table" and params.questions or {}) do
    if type(question) == "table" and question.id ~= nil then
      local id = tostring(question.id)
      properties[id] = cursor_property(question)
      required[#required + 1] = id
    end
  end
  return {
    mode = "form",
    message = tostring(params.title or "Cursor needs input"),
    requestedSchema = { type = "object", properties = properties, required = required },
    _meta = { lazyagent = { sourceMethod = "cursor/ask_question", toolCallId = params.toolCallId } },
  }
end

function M.cursor_question_response(params, response)
  response = type(response) == "table" and response or {}
  if response.action ~= "accept" then
    return { outcome = { outcome = response.action == "decline" and "skipped" or "cancelled" } }
  end
  local content = type(response.content) == "table" and response.content or {}
  local answers = {}
  for _, question in ipairs(type(params.questions) == "table" and params.questions or {}) do
    if type(question) == "table" and question.id ~= nil then
      local id = tostring(question.id)
      local value = content[id]
      local selected = type(value) == "table" and vim.deepcopy(value) or (value ~= nil and { value } or {})
      for index, item in ipairs(selected) do selected[index] = tostring(item) end
      answers[#answers + 1] = { questionId = id, selectedOptionIds = selected }
    end
  end
  return { outcome = { outcome = "answered", answers = answers } }
end

function M.cursor_notification(method, params)
  params = type(params) == "table" and params or {}
  if method == "cursor/update_todos" then
    return {
      sessionUpdate = "plan",
      entries = vim.deepcopy(params.todos or {}),
      _meta = { lazyagent = { sourceMethod = method, merge = params.merge == true, toolCallId = params.toolCallId } },
    }
  elseif method == "cursor/task" then
    return {
      sessionUpdate = "subagent_task",
      toolCallId = params.toolCallId,
      subagentSessionId = params.agentId,
      name = params.description or "Cursor task",
      task = params.prompt,
      subagentType = vim.deepcopy(params.subagentType),
      model = params.model,
      durationMs = params.durationMs,
      state = "completed",
      _meta = { lazyagent = { sourceMethod = method } },
    }
  elseif method == "cursor/generate_image" then
    return {
      sessionUpdate = "generated_image",
      toolCallId = params.toolCallId,
      description = params.description,
      filePath = params.filePath,
      referenceImagePaths = vim.deepcopy(params.referenceImagePaths or {}),
      _meta = { lazyagent = { sourceMethod = method } },
    }
  end
end

function M.plan_text(params)
  params = type(params) == "table" and params or {}
  local lines = {}
  if params.overview and params.overview ~= "" then lines[#lines + 1] = tostring(params.overview) end
  if params.plan and params.plan ~= "" then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = tostring(params.plan)
  end
  return table.concat(lines, "\n")
end

return M
