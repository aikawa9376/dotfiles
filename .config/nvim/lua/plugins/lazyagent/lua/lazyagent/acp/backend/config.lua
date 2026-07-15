local M = {}

function M.setup(deps)
  local state = deps.state
  local acp_logic = deps.acp_logic
  local agent_logic = deps.agent_logic
  local skills_logic = deps.skills_logic
  local local_commands = deps.local_commands
  local transforms = deps.transforms
  local normalize_text = deps.normalize_text
  local append_block = deps.append_block
  local sync_runtime_session = deps.sync_runtime_session
  local sync_thread = deps.sync_thread or function() end
  local first_nonempty = deps.first_nonempty
  local item_body_text = deps.item_body_text
  local matches_exact = deps.matches_exact
  local matches_pattern = deps.matches_pattern
  local find_config_option
  local config_option_choice_items

  local module = {}

  local brain_save = require("lazyagent.acp.backend.config.brain_save").setup({
    state = state,
    skills_logic = skills_logic,
    normalize_text = normalize_text,
    item_body_text = item_body_text,
  })
  local maybe_save_turn_to_brain = brain_save.maybe_save_turn_to_brain

  local function normalize_config_key(value)
    return tostring(value or ""):lower():gsub("[^%w]+", "")
  end

  local function compact_config_value(value)
    local text = tostring(value or "")
    if text == "" then
      return ""
    end
    return text:gsub("^https://agentclientprotocol%.com/protocol/session%-modes#", "")
  end

  local function current_config_label(session, keys)
    local option = find_config_option(session, keys)
    if not option then
      return nil
    end

    local current = option.currentValue
    if current == nil or current == "" then
      return nil
    end

    for _, choice in ipairs(config_option_choice_items(option)) do
      if type(choice) == "table" and choice.value == current then
        return compact_config_value(choice.name or current)
      end
    end

    return compact_config_value(current)
  end

  local function provider_heading_label(session)
    local info = session and session.agent_info or {}
    local name = info.title or info.name or session.agent_name or "ACP"
    local parts = { tostring(name) }

    local model = current_config_label(session, { "model" })
    if model and model ~= "" then
      parts[#parts + 1] = model
    end

    local reasoning = current_config_label(session, { "thought_level", "reasoning_effort" })
    if reasoning and reasoning ~= "" and reasoning:lower() ~= "none" then
      parts[#parts + 1] = reasoning
    end

    return table.concat(parts, " ")
  end

  local function assistant_heading_label(session)
    local label = provider_heading_label(session)
    if label == "" then
      return "Assistant"
    end
    return label
  end

  local function normalize_available_commands(commands)
    local out = {}
    for _, command in ipairs(commands or {}) do
      if type(command) == "table" and command.name and command.name ~= "" then
        local desc = tostring(command.description or command.doc or "")
        local hint = command.input and command.input.hint or nil
        table.insert(out, {
          name = tostring(command.name),
          label = "/" .. tostring(command.name),
          desc = desc,
          category = first_nonempty(command.category, command.group),
          input_hint = hint and tostring(hint) or nil,
          input_required = command.input and command.input.required == true or false,
          input_placeholder = command.input and command.input.placeholder or nil,
        })
      end
    end
    return out
  end

  local function extract_slash_command_name(text)
    local trimmed = normalize_text(text):gsub("^%s+", ""):gsub("%s+$", "")
    return trimmed:match("^/([%w_-]+)")
  end

  local function session_has_available_command(session, name)
    if not session or type(session.available_commands) ~= "table" then
      return false
    end
    local expected = "/" .. tostring(name)
    for _, command in ipairs(session.available_commands) do
      if type(command) == "table" and command.label == expected then
        return true
      end
    end
    return false
  end

  local function note_unadvertised_slash_command(session, prompt)
    local name = extract_slash_command_name(prompt)
    if not name or session_has_available_command(session, name) then
      return
    end

    session.warned_unadvertised_commands = session.warned_unadvertised_commands or {}
    if session.warned_unadvertised_commands[name] then
      return
    end
    session.warned_unadvertised_commands[name] = true

    append_block(
      session,
      "System",
      string.format(
        "ACP did not advertise /%s for this session. Picker-style CLI slash commands are not available over ACP, so this input will be handled as plain prompt text.",
        name
      )
    )
  end
  local function config_option_key(option)
    if type(option) ~= "table" then
      return nil
    end
    return option.category or option.id or option.name
  end

  local function config_option_title(option)
    if type(option) ~= "table" then
      return "ACP setting"
    end
    return option.name or option.label or option.id or option.category or "ACP setting"
  end

  local function config_option_description(option)
    if type(option) ~= "table" then
      return nil
    end
    return first_nonempty(option.description, option.doc, option.helpText, option.help)
  end

  local function config_option_category(option)
    if type(option) ~= "table" then
      return nil
    end
    local category = first_nonempty(option.category, option.group)
    if not category then
      return nil
    end
    category = tostring(category)
    local title = tostring(config_option_title(option))
    if category == "" or category == title then
      return nil
    end
    return category
  end

  local function config_option_kind(option)
    local option_type = normalize_config_key(type(option) == "table" and option.type or "")
    if option_type == "select" or option_type == "multiselect" then
      if type(option.options) == "table" and #option.options > 0 then
        return "select"
      end
    end
    if option_type == "boolean" or option_type == "bool" or option_type == "toggle" then
      return "toggle"
    end
    return option_type ~= "" and option_type or nil
  end

  local function parse_boolean(value)
    if type(value) == "boolean" then
      return value
    end
    if value == nil then
      return nil
    end
    local normalized = tostring(value):lower()
    if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" or normalized == "enabled" then
      return true
    end
    if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" or normalized == "disabled" then
      return false
    end
    return nil
  end

  local function config_option_current_name(option)
    if type(option) ~= "table" then
      return nil
    end
    local current = option.currentValue
    if current == nil or current == "" then
      return nil
    end
    for _, choice in ipairs(option.options or {}) do
      if type(choice) == "table" and choice.value == current then
        return choice.name or tostring(current)
      end
    end
    if config_option_kind(option) == "toggle" then
      local boolean = parse_boolean(current)
      if boolean ~= nil then
        return boolean and "Enabled" or "Disabled"
      end
    end
    return tostring(current)
  end


  local function followup_picker_for_option(session, option)
    if normalize_config_key(config_option_key(option)) ~= "model" and normalize_config_key(option.id) ~= "model" then
      return nil
    end

    for _, key in ipairs({
      "thought_level",
      "thought-level",
      "thoughtLevel",
      "reasoning_effort",
      "reasoning-effort",
      "reasoningEffort",
    }) do
      local option_match = find_config_option(session, key)
      if option_match then
        return option_match
      end
    end

    return nil
  end

  local function selectable_config_options(session, category)
    local out = {}
    for _, option in ipairs(session.config_options or {}) do
      local kind = config_option_kind(option)
      if type(option) == "table" and (kind == "select" or kind == "toggle") then
        local key = config_option_key(option)
        if not category or key == category or option.id == category then
          table.insert(out, option)
        end
      end
    end
    table.sort(out, function(a, b)
      return config_option_title(a):lower() < config_option_title(b):lower()
    end)
    return out
  end

  local function move_current_choice_to_head(option)
    local ordered = {}
    local current = option and option.currentValue or nil
    for _, choice in ipairs(option.options or {}) do
      if type(choice) == "table" and choice.value == current then
        table.insert(ordered, choice)
      end
    end
    for _, choice in ipairs(option.options or {}) do
      if type(choice) == "table" and choice.value ~= current then
        table.insert(ordered, choice)
      end
    end
    return ordered
  end

  config_option_choice_items = function(option)
    if config_option_kind(option) == "toggle" then
      local base_description = config_option_description(option)
      return {
        {
          name = first_nonempty(option.enabledLabel, option.trueLabel, "Enabled"),
          value = true,
          description = first_nonempty(option.enabledDescription, option.trueDescription, base_description),
        },
        {
          name = first_nonempty(option.disabledLabel, option.falseLabel, "Disabled"),
          value = false,
          description = first_nonempty(option.disabledDescription, option.falseDescription, base_description),
        },
      }
    end
    return move_current_choice_to_head(option)
  end

  local function config_option_picker_label(option)
    local label = config_option_title(option)
    local current = config_option_current_name(option)
    local meta = {}
    local category = config_option_category(option)
    local kind = config_option_kind(option)

    if current and current ~= "" then
      label = string.format("%s (%s)", label, current)
    end
    if category and category ~= "" then
      meta[#meta + 1] = tostring(category)
    end
    if kind and kind ~= "" and kind ~= "select" then
      meta[#meta + 1] = tostring(kind)
    end
    if #meta > 0 then
      label = string.format("%s [%s]", label, table.concat(meta, ", "))
    end

    local description = config_option_description(option)
    if description and description ~= "" then
      label = label .. " - " .. description
    end
    return label
  end

  local function queue_after_ready(session, callback)
    session.on_ready_actions = session.on_ready_actions or {}
    table.insert(session.on_ready_actions, callback)
  end

  local function apply_config_option_choice(session, option, choice, on_done, opts)
    opts = opts or {}
    if type(on_done) ~= "function" then
      on_done = function(...) end
    end
    if not session.ready or session.failed or not session.client then
      append_block(session, "Error", "ACP session is not ready for configuration changes.")
      on_done(false)
      return false
    end

    local label = config_option_title(option)
    local key = config_option_key(option)
    local source = opts.source or "manual"
    local method = "set_config_option"
    if session.client._legacy_api then
      if key == "mode" and type(session.client.set_mode) == "function" then
        method = "set_mode"
      elseif key == "model" and type(session.client.set_model) == "function" then
        method = "set_model"
      end
    end

    local callback = function(config_options, err)
      if err then
        append_block(session, "Error", string.format("Failed to update %s: %s", label, err.message or tostring(err)))
        on_done(false, err)
        return
      end
      session.config_options = vim.deepcopy(config_options or session.client.config_options or session.config_options or {})
      session.manual_config_overrides = session.manual_config_overrides or {}
      session.auto_switch_state = session.auto_switch_state or {}
      if source == "manual" and key then
        session.manual_config_overrides[key] = true
      elseif source == "auto" and key then
        session.auto_switch_state[key] = choice.value
      end
      sync_runtime_session(session)
      sync_thread(session, { config = vim.deepcopy(session.config_options or {}) })
      local success_message = opts.success_message
      if success_message == nil then
        success_message = string.format("%s set to %s", label, choice.name or tostring(choice.value))
      end
      if success_message ~= false and success_message ~= "" then
        append_block(session, "System", success_message)
      end
      on_done(true)
    end

    if method == "set_config_option" then
      session.client:set_config_option(option.id, choice.value, callback)
    elseif method == "set_mode" then
      session.client:set_mode(choice.value, callback)
    else
      session.client:set_model(choice.value, callback)
    end

    return true
  end

  find_config_option = function(session, keys)
    if not session or type(session.config_options) ~= "table" then
      return nil
    end

    keys = type(keys) == "table" and keys or { keys }
    for _, option in ipairs(session.config_options or {}) do
      if type(option) == "table" then
        local option_key = normalize_config_key(config_option_key(option))
        local option_id = normalize_config_key(option.id)
        local option_category = normalize_config_key(option.category)
        local option_name = normalize_config_key(option.name)
        for _, key in ipairs(keys) do
          local expected = normalize_config_key(key)
          if expected ~= "" and (
            option_key == expected
            or option_id == expected
            or option_category == expected
            or option_name == expected
          ) then
            return option
          end
        end
      end
    end
    return nil
  end

  local function find_config_choice(option, value)
    if type(option) ~= "table" or value == nil or value == "" then
      return nil
    end
    local expected = tostring(value)
    for _, choice in ipairs(config_option_choice_items(option)) do
      if type(choice) == "table" and tostring(choice.value) == expected then
        return choice
      end
    end
    return nil
  end

  local function choice_display_name(choice)
    if type(choice) ~= "table" then
      return tostring(choice or "")
    end
    return choice.name or tostring(choice.value or "")
  end

  local function session_source_bufnr(session)
    local bufnr = session and session.agent_cfg and (session.agent_cfg.source_bufnr or session.agent_cfg.origin_bufnr) or nil
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
    return nil
  end

  local function build_auto_switch_context(session, prompt)
    local bufnr = session_source_bufnr(session)
    local path = bufnr and vim.api.nvim_buf_get_name(bufnr) or ""
    local filetype = (bufnr and vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
    local diagnostics = bufnr and transforms.gather_diagnostics(bufnr) or {}
    local counts = {
      diagnostics = #diagnostics,
      errors = 0,
      warnings = 0,
      infos = 0,
      hints = 0,
    }

    for _, item in ipairs(diagnostics or {}) do
      local severity = tostring(item.severity or ""):upper()
      if severity == "ERROR" then
        counts.errors = counts.errors + 1
      elseif severity == "WARN" or severity == "WARNING" then
        counts.warnings = counts.warnings + 1
      elseif severity == "INFO" then
        counts.infos = counts.infos + 1
      elseif severity == "HINT" then
        counts.hints = counts.hints + 1
      end
    end

    return {
      agent = tostring(session and session.agent_name or ""),
      cwd = tostring(session and (session.root_dir or session.cwd) or vim.fn.getcwd()),
      path = path,
      filetype = filetype,
      text = tostring(prompt or ""),
      prompt_length = vim.fn.strchars(tostring(prompt or "")),
      prompt_lines = select(2, tostring(prompt or ""):gsub("\n", "\n")) + 1,
      diagnostics = counts.diagnostics,
      errors = counts.errors,
      warnings = counts.warnings,
      infos = counts.infos,
      hints = counts.hints,
    }
  end

  local function auto_switch_rule_label(rule, idx)
    if type(rule) ~= "table" then
      return string.format("rule #%d", idx)
    end
    return tostring(rule.name or rule.label or rule.id or ("rule #" .. tostring(idx)))
  end

  local function auto_switch_rule_matches(context, rule)
    if type(rule) ~= "table" then
      return false
    end
    if not matches_exact({ context.agent }, rule.agent) then
      return false
    end
    if not matches_pattern({ context.agent }, rule.agent_pattern) then
      return false
    end
    if not matches_exact({ context.cwd }, rule.cwd) then
      return false
    end
    if not matches_pattern({ context.cwd }, rule.cwd_pattern) then
      return false
    end
    if not matches_exact({ context.filetype }, rule.filetype) then
      return false
    end
    if not matches_pattern({ context.filetype }, rule.filetype_pattern) then
      return false
    end
    if not matches_exact({ context.path }, rule.path) then
      return false
    end
    if not matches_pattern({ context.path }, rule.path_pattern) then
      return false
    end
    if not matches_pattern({ context.text }, rule.text_pattern) then
      return false
    end
    if rule.prompt_length_min and context.prompt_length < tonumber(rule.prompt_length_min) then
      return false
    end
    if rule.prompt_length_max and context.prompt_length > tonumber(rule.prompt_length_max) then
      return false
    end
    if rule.prompt_lines_min and context.prompt_lines < tonumber(rule.prompt_lines_min) then
      return false
    end
    if rule.prompt_lines_max and context.prompt_lines > tonumber(rule.prompt_lines_max) then
      return false
    end
    if rule.diagnostics_min and context.diagnostics < tonumber(rule.diagnostics_min) then
      return false
    end
    if rule.diagnostics_max and context.diagnostics > tonumber(rule.diagnostics_max) then
      return false
    end
    if rule.errors_min and context.errors < tonumber(rule.errors_min) then
      return false
    end
    if rule.errors_max and context.errors > tonumber(rule.errors_max) then
      return false
    end
    if rule.warnings_min and context.warnings < tonumber(rule.warnings_min) then
      return false
    end
    if rule.warnings_max and context.warnings > tonumber(rule.warnings_max) then
      return false
    end
    return true
  end

  local function resolve_auto_switch_operations(session, prompt)
    local latest_cfg = acp_logic.resolve_config(session.agent_cfg or {})
    session.auto_switch = vim.deepcopy(latest_cfg.auto_switch or {})
    sync_runtime_session(session)

    local auto_cfg = session.auto_switch or {}
    if auto_cfg.enabled ~= true then
      return {}
    end

    local context = build_auto_switch_context(session, prompt)
    local operations = {}
    local preserve_manual = auto_cfg.preserve_manual ~= false

    for _, spec in ipairs({
      { key = "mode", rules = auto_cfg.mode_rules, value_key = "mode" },
      { key = "model", rules = auto_cfg.model_rules, value_key = "model" },
    }) do
      if not (preserve_manual and session.manual_config_overrides and session.manual_config_overrides[spec.key]) then
        local option = find_config_option(session, spec.key)
        if option then
          for idx, rule in ipairs(spec.rules or {}) do
            if auto_switch_rule_matches(context, rule) then
              local desired = rule.value or rule[spec.value_key]
              local choice = find_config_choice(option, desired)
              local current = tostring(option.currentValue or "")
              if choice and tostring(choice.value or "") ~= current then
                operations[#operations + 1] = {
                  key = spec.key,
                  option = option,
                  choice = choice,
                  rule_label = auto_switch_rule_label(rule, idx),
                }
              end
              break
            end
          end
        end
      end
    end

    return operations
  end

  local function maybe_apply_auto_switch(session, prompt, done)
    done = done or function() end
    if not session or session.failed or not session.ready or not session.client then
      done()
      return
    end

    local operations = resolve_auto_switch_operations(session, prompt)
    if #operations == 0 then
      done()
      return
    end

    local function step(index)
      local item = operations[index]
      if not item then
        done()
        return
      end

      apply_config_option_choice(session, item.option, item.choice, function()
        step(index + 1)
      end, {
          source = "auto",
          success_message = string.format(
            "Auto %s -> %s (%s)",
            item.key,
            choice_display_name(item.choice),
            item.rule_label
          ),
        })
    end

    step(1)
  end

  local function apply_initial_session_config(session, done)
    done = done or function() end
    if session.initial_config_applied then
      done()
      return
    end
    session.initial_config_applied = true

    local pending = {}
    for _, saved in ipairs(type(session.initial_config_snapshot) == "table" and session.initial_config_snapshot or {}) do
      if type(saved) == "table" and saved.id and saved.currentValue ~= nil then
        table.insert(pending, {
          key = saved.id,
          value = saved.currentValue,
          title = config_option_title(saved),
        })
      end
    end
    if session.default_mode and session.default_mode ~= "" then
      table.insert(pending, { key = "mode", value = session.default_mode, title = "mode" })
    end
    if session.initial_model and session.initial_model ~= "" then
      table.insert(pending, { key = "model", value = session.initial_model, title = "model" })
    end

    local function step(index)
      local item = pending[index]
      if not item then
        done()
        return
      end

      local option = find_config_option(session, item.key)
      if not option then
        step(index + 1)
        return
      end

      local choice = find_config_choice(option, item.value)
      if not choice then
        append_block(session, "System", string.format("ACP %s `%s` is not available for this session.", item.title, item.value))
        step(index + 1)
        return
      end

      if tostring(option.currentValue or "") == tostring(choice.value) then
        step(index + 1)
        return
      end

      apply_config_option_choice(session, option, choice, function()
        step(index + 1)
      end, { source = "initial" })
    end

    step(1)
  end

  local function show_config_value_picker(session, option)
    local items = config_option_choice_items(option)
    if #items == 0 then
      append_block(session, "System", string.format("%s does not expose any selectable values.", config_option_title(option)))
      return false
    end

    local function open_followup_picker()
      local followup = followup_picker_for_option(session, option)
      if followup then
        vim.schedule(function()
          show_config_value_picker(session, followup)
        end)
        return true
      end
      return false
    end

    local current = option.currentValue
    vim.ui.select(items, {
      prompt = "Select " .. config_option_title(option) .. ":",
      format_item = function(item)
        local prefix = (tostring(item.value) == tostring(current)) and "● " or "  "
        local suffix = item.description and item.description ~= "" and (": " .. item.description) or ""
        return prefix .. (item.name or tostring(item.value)) .. suffix
      end,
    }, function(choice)
        if not choice then
          return
        end
        if choice.value == current then
          open_followup_picker()
          return
        end
        apply_config_option_choice(session, option, choice, function(updated)
          if not updated then
            return
          end

          open_followup_picker()
        end)
      end)

    return true
  end

  local function show_config_picker_for_session(session, category)
    if not session then
      return false
    end

    local label = category and ("`" .. category .. "`") or "ACP config"
    if session.failed then
      append_block(session, "Error", "ACP session is disconnected. Restart the agent session to continue.")
      return false
    end

    if not session.ready or not session.client then
      queue_after_ready(session, function()
        show_config_picker_for_session(session, category)
      end)
      append_block(session, "System", string.format("ACP session is still connecting. %s picker will open when ready.", label))
      return true
    end

    local options = selectable_config_options(session, category)
    if #options == 0 then
      append_block(session, "System", string.format("This ACP session does not expose any %s options.", label))
      return false
    end

    if #options == 1 then
      return show_config_value_picker(session, options[1])
    end

    vim.ui.select(options, {
      prompt = "Choose ACP setting:",
      format_item = function(item)
        return config_option_picker_label(item)
      end,
    }, function(choice)
        if not choice then
          return
        end
        show_config_value_picker(session, choice)
      end)

    return true
  end

  local function command_palette_items(session)
    local out = {}
    local advertised = {}

    for _, command in ipairs(session and session.available_commands or {}) do
      if type(command) == "table" and command.label and command.label ~= "" then
        advertised[command.label] = true
      end
    end

    for _, command in ipairs(local_commands.merged_entries(session, session and session.available_commands or {})) do
      if type(command) == "table" and command.label then
        local source = advertised[command.label] and "agent" or "local"
        out[#out + 1] = vim.tbl_extend("force", { source = source }, vim.deepcopy(command))
      end
    end

    for _, command in ipairs(agent_logic.get_visible_slash_commands(session and session.agent_name, session)) do
      if type(command) == "table" and command.label then
        local exists = false
        for _, item in ipairs(out) do
          if item.label == command.label then
            exists = true
            break
          end
        end
        if not exists then
          local source = advertised[command.label] and "agent" or "local"
          out[#out + 1] = vim.tbl_extend("force", { source = source }, vim.deepcopy(command))
        end
      end
    end

    return out
  end

  local function show_command_palette_for_session(session, submit)
    if not session then
      return false
    end

    if session.failed then
      append_block(session, "Error", "ACP session is disconnected. Restart the agent session to continue.")
      return false
    end

    if not session.ready or not session.client then
      queue_after_ready(session, function()
        show_command_palette_for_session(session, submit)
      end)
      append_block(session, "System", "ACP session is still connecting. Command palette will open when ready.")
      return true
    end

    local items = command_palette_items(session)
    if #items == 0 then
      append_block(session, "System", "This ACP session does not expose any slash commands yet.")
      return false
    end

    vim.ui.select(items, {
      prompt = "Choose ACP command:",
      format_item = function(item)
        local source = item.source or "agent"
        local meta = { source }
        if item.category and item.category ~= "" then
          meta[#meta + 1] = tostring(item.category)
        end
        if item.input_required then
          meta[#meta + 1] = "args"
        elseif item.input_hint and item.input_hint ~= "" then
          meta[#meta + 1] = "input"
        end
        local details = {}
        if item.desc and item.desc ~= "" then
          details[#details + 1] = tostring(item.desc)
        end
        if item.input_hint and item.input_hint ~= "" then
          details[#details + 1] = "Input: " .. tostring(item.input_hint)
        elseif item.input_placeholder and item.input_placeholder ~= "" then
          details[#details + 1] = "Input: " .. tostring(item.input_placeholder)
        end
        local desc = #details > 0 and (" - " .. table.concat(details, " · ")) or ""
        return string.format("%s [%s]%s", item.label, table.concat(meta, ", "), desc)
      end,
    }, function(choice)
        if not choice or not choice.label or choice.label == "" then
          return
        end
        submit(choice.label)
      end)

    return true
  end

  module.normalize_config_key = normalize_config_key
  module.find_config_option = find_config_option
  module.assistant_heading_label = assistant_heading_label
  module.current_config_label = current_config_label
  module.config_option_key = config_option_key
  module.config_option_title = config_option_title
  module.config_option_description = config_option_description
  module.config_option_category = config_option_category
  module.config_option_kind = config_option_kind
  module.config_option_current_name = config_option_current_name
  module.session_has_available_command = session_has_available_command
  module.normalize_available_commands = normalize_available_commands
  module.note_unadvertised_slash_command = note_unadvertised_slash_command
  module.maybe_save_turn_to_brain = maybe_save_turn_to_brain
  module.maybe_apply_auto_switch = maybe_apply_auto_switch
  module.apply_initial_session_config = apply_initial_session_config
  module.show_config_picker_for_session = show_config_picker_for_session
  module.command_palette_items = command_palette_items
  module.show_command_palette_for_session = show_command_palette_for_session

  return module
end

return M
