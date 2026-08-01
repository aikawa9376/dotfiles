local M = {}

local GitReview = require("lazyagent.acp.git_review")
local ReviewStore = require("lazyagent.acp.review_store")
local BlobStore = require("lazyagent.acp.blob_store")
local ReviewAnnotations = require("lazyagent.acp.review_annotations")
local ChangeReview = require("lazyagent.acp.change_review")
local cache_logic = require("lazyagent.logic.cache")
local state = require("lazyagent.logic.state")
local backend_logic = require("lazyagent.logic.backend")
local acp_logic = require("lazyagent.logic.acp")
local window = require("lazyagent.window")

local base = cache_logic.get_cache_dir() .. "/acp"
local store = ReviewStore.new({ dir = base .. "/reviews" })
local blobs = BlobStore.new({ dir = base .. "/blobs", max_blob_bytes = false })
local pending = {}
local initialized = false
local frontends = {}
local submit
local drawer = ChangeReview.new({
  read_blob = function(ref) return blobs:get(ref, { max_bytes = false }) end,
})

local function capture_scratch()
  if not window.is_open() then return nil end
  local winid, bufnr = window.get_winid(), window.get_bufnr()
  if not winid or not vim.api.nvim_win_is_valid(winid)
    or not bufnr or not vim.api.nvim_buf_is_valid(bufnr)
    or vim.b[bufnr].lazyagent_is_scratch ~= true
  then
    return nil
  end
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
  if text == "" then return nil end
  return {
    bufnr = bufnr,
    winid = winid,
    agent_name = vim.b[bufnr].lazyagent_agent,
    text = text,
  }
end

local function consume_scratch(scratch)
  if type(scratch) ~= "table" then return end
  if scratch.bufnr and vim.api.nvim_buf_is_valid(scratch.bufnr) then
    pcall(vim.api.nvim_buf_set_lines, scratch.bufnr, 0, -1, false, {})
  end
  if window.get_winid() == scratch.winid or window.get_bufnr() == scratch.bufnr then
    window.close({ force = true, keep_buffer = true })
  end
  local session = scratch.agent_name and state.sessions[scratch.agent_name] or nil
  if session and session.pane_id then
    local _, backend = backend_logic.resolve_backend_for_agent(
      scratch.agent_name,
      ((state.opts or {}).interactive_agents or {})[scratch.agent_name]
    )
    local snapshot = type(backend) == "table" and type(backend.get_runtime_snapshot) == "function"
        and backend.get_runtime_snapshot(session.pane_id)
      or nil
    if snapshot and snapshot.acp_thread_id and type(backend.set_thread_draft) == "function" then
      backend.set_thread_draft(snapshot.acp_thread_id, "")
    end
  end
end

local function as_thread(review)
  return {
    thread_id = "git-review-" .. review.review_id,
    title = review.range,
    cwd = review.root,
    review_mode = true,
    review = { base = review.base, head = review.head, status = review.status },
    change_journal = { turns = { {
      turn_id = review.review_id,
      state = "completed",
      baseline = { root = review.root },
      final_snapshot = { root = review.root },
      changes = vim.deepcopy(review.changes or {}),
      annotations = vim.deepcopy(review.annotations or {}),
    } } },
  }
end

local function frontend_for(review)
  local name = review and review.source and review.source.frontend
  if name and not frontends[name] then
    local ok, lazy = pcall(require, "lazy")
    if ok then pcall(lazy.load, { plugins = { name .. "-extension" } }) end
  end
  return name and frontends[name] or nil
end

local function show_review(review)
  local frontend = frontend_for(review)
  if frontend and type(frontend.open) == "function" then
    local ok, opened, err = pcall(frontend.open, review, {
      read_blob = function(ref) return blobs:get(ref, { max_bytes = false }) end,
    })
    if ok and opened ~= false then return true end
    if not ok then err = opened end
    if err then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.WARN) end
  end
  return drawer.open(as_thread(review))
end

local function canonical(path)
  if not path or path == "" then return nil end
  local absolute = vim.fn.fnamemodify(tostring(path), ":p"):gsub("/$", "")
  return (vim.uv or vim.loop).fs_realpath(absolute) or absolute
end

local function candidate(name, review)
  local session = state.sessions[name]
  if type(session) ~= "table" or not session.pane_id or not acp_logic.is_acp_backend(session.backend) then
    return nil
  end
  local _, backend = backend_logic.resolve_backend_for_agent(name, (state.opts.interactive_agents or {})[name])
  if type(backend.get_runtime_snapshot) ~= "function" or type(backend.set_read_only_guard) ~= "function" then return nil end
  local snapshot = backend.get_runtime_snapshot(session.pane_id)
  if not snapshot or snapshot.acp_ready ~= true or snapshot.acp_failed == true
    or snapshot.acp_busy == true or snapshot.acp_preparing_prompt == true
    or #(snapshot.acp_prompt_queue or {}) > 0 or (tonumber(snapshot.acp_terminal_count) or 0) > 0 or pending[name]
  then
    return nil
  end
  local review_root = canonical(review and review.root)
  if canonical(snapshot.root_dir) ~= review_root and canonical(snapshot.cwd) ~= review_root then return nil end
  return { name = name, session = session, backend = backend, snapshot = snapshot }
end

local function candidates(review)
  local result = {}
  for name in pairs(state.sessions or {}) do
    local item = candidate(name, review)
    if item then result[#result + 1] = item end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

local function latest_response(item)
  local thread_id = item.thread_id
  if not thread_id or type(item.backend.get_thread) ~= "function" then return nil end
  local thread = item.backend.get_thread(thread_id)
  local turns = thread and thread.change_journal and thread.change_journal.turns or {}
  local turn = turns[#turns]
  local explanations = ReviewAnnotations.for_turn(turn)
  for index = #explanations, 1, -1 do
    if explanations[index].kind == "explanation" then
      return explanations[index].rationale or explanations[index].summary
    end
  end
  return nil
end

local function feedback_prompt(review)
  local lines = {
    review.source and review.source.mutable == true
        and "Address the following review feedback in the working tree and run relevant tests."
      or "Respond to the following feedback about an immutable comparison. Do not modify files.",
    "Reply to every annotation using its exact ID.",
    "End your response with exactly one fenced block:",
    "```lazyagent-review-replies",
    '{"review_id":"' .. tostring(review.review_id) .. '","replies":[{"annotation_id":"id","body":"What was changed or why it was not changed"}]}',
    "```",
    "",
    "Review: " .. tostring(review.range or review.review_id),
  }
  for _, annotation in ipairs(review.annotations or {}) do
    if (annotation.pending == true or annotation.pending_state == true) and annotation.author and annotation.author.type == "user" then
      local target = annotation.path or "Overall"
      local line = annotation.target and annotation.target.start_line
      if line then target = target .. ":" .. tostring(line) end
      lines[#lines + 1] = string.format("- [%s] %s: %s", annotation.id, target, annotation.rationale or annotation.summary or "")
    elseif annotation.pending_state == true then
      lines[#lines + 1] = string.format("- [%s] state: %s", annotation.id, annotation.resolved and "resolved" or "unresolved")
    end
  end
  return table.concat(lines, "\n")
end

local function apply_feedback_response(review, response)
  local payload = tostring(response or ""):match("```lazyagent%-review%-replies%s*\n(.-)\n```")
  if not payload then return nil, "AI response has no lazyagent-review-replies block" end
  local replies = {}
  local ok, decoded = pcall(vim.json.decode, payload)
  if not ok or type(decoded) ~= "table" then return nil, "AI review replies are not valid JSON" end
  if tostring(decoded.review_id or "") ~= tostring(review.review_id) then return nil, "AI review reply ID does not match" end
  for _, reply in ipairs(type(decoded.replies) == "table" and decoded.replies or {}) do
    replies[tostring(reply.annotation_id or "")] = vim.trim(tostring(reply.body or ""))
  end
  for _, annotation in ipairs(review.annotations or {}) do
    if annotation.pending == true or annotation.pending_state == true then
      local body = replies[tostring(annotation.id)]
      if body and body ~= "" then
        annotation.replies = annotation.replies or {}
        annotation.replies[#annotation.replies + 1] = {
          body = body,
          author = { type = "agent", name = review.reviewer or "AI Reviewer" },
          created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
      end
      if body and body ~= "" then
        annotation.pending = false
        annotation.pending_state = false
        annotation.sent = true
      end
    end
  end
  review.feedback_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return review
end

local function finish_feedback(agent_name, item)
  pending[agent_name] = nil
  if item.guard_id then item.backend.set_read_only_guard(item.session.pane_id, item.guard_id, false) end
  local review, response_err = apply_feedback_response(item.review, latest_response(item))
  if not review then
    item.review.feedback_error = response_err
    store:save(item.review)
    vim.notify("LazyAgent Review: " .. tostring(response_err), vim.log.levels.ERROR)
    return
  end
  store:save(review)
  local frontend = frontend_for(review)
  if review.source and review.source.mutable == true and frontend and type(frontend.refresh_snapshot) == "function" then
    local ok, snapshot, err = pcall(frontend.refresh_snapshot, review, {
      put_blob = function(data) return blobs:put(data, { max_bytes = false }) end,
    })
    if ok and snapshot then
      snapshot.parent_review_id = review.review_id
      snapshot.lineage_id = review.lineage_id or review.changeset_id
      local followup, create_err = GitReview.from_snapshot(snapshot)
      if followup then
        local accepted, submit_err = submit(followup, {
          name = agent_name,
          session = item.session,
          backend = item.backend,
          snapshot = { acp_thread_id = item.thread_id },
        })
        if accepted then return end
        err = submit_err
      else
        err = create_err
      end
    elseif not ok then
      err = snapshot
    end
    if err then vim.notify("LazyAgent Review: follow-up review failed: " .. tostring(err), vim.log.levels.ERROR) end
  end
  vim.schedule(function() show_review(review) end)
end

local function finish(agent_name)
  local item = pending[agent_name]
  if not item then return end
  if item.phase == "feedback" then return finish_feedback(agent_name, item) end
  pending[agent_name] = nil
  if item.guard_id then item.backend.set_read_only_guard(item.session.pane_id, item.guard_id, false) end
  local response = latest_response(item)
  local annotations, parse_err = GitReview.parse(response, item.review)
  if not annotations then
    item.review.status = "failed"
    item.review.error = parse_err
    store:save(item.review)
    vim.notify("LazyAgent Review: " .. tostring(parse_err), vim.log.levels.ERROR)
    return
  end
  item.review.status = "completed"
  item.review.annotations = annotations
  item.review.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  item.review.reviewer = agent_name
  item.review.reviewer_thread_id = item.thread_id
  local saved, save_err = store:save(item.review)
  if not saved then
    vim.notify("LazyAgent Review: failed to save result: " .. tostring(save_err), vim.log.levels.ERROR)
    return
  end
  vim.schedule(function()
    show_review(saved)
    vim.notify(string.format("LazyAgent Review: %d finding(s)", #annotations), vim.log.levels.INFO)
    vim.api.nvim_exec_autocmds("User", { pattern = "LazyAgentReviewCompleted", data = { review = saved } })
  end)
end

function M.setup()
  if initialized then return end
  initialized = true
  local group = vim.api.nvim_create_augroup("LazyAgentGitReview", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazyAgentTurnDone",
    callback = function(args)
      local name = args.data and args.data.agent_name
      if name and pending[name] then finish(name) end
    end,
  })
end

submit = function(review, item, scratch)
  review.reviewer = item.name
  review.reviewer_thread_id = item.snapshot.acp_thread_id
  local saved, err = store:save(review)
  if not saved then return nil, err end
  local guard_id = "git-review:" .. tostring(saved.review_id)
  local guarded, guard_err = item.backend.set_read_only_guard(
    item.session.pane_id,
    guard_id,
    true,
    "Git review " .. tostring(saved.review_id) .. " is read-only"
  )
  if not guarded then
    saved.status, saved.error = "failed", guard_err
    store:save(saved)
    return nil, guard_err
  end
  pending[item.name] = {
    review = saved,
    backend = item.backend,
    thread_id = item.snapshot.acp_thread_id,
    session = item.session,
    guard_id = guard_id,
  }
  local accepted = item.backend.paste_and_submit(item.session.pane_id, GitReview.prompt(saved), { "C-m" }, {})
  if accepted ~= true then
    pending[item.name] = nil
    item.backend.set_read_only_guard(item.session.pane_id, guard_id, false)
    saved.status = "failed"
    saved.error = "the ACP session did not accept the review prompt"
    store:save(saved)
    return nil, "the ACP session did not accept the review prompt"
  end
  consume_scratch(scratch)
  vim.notify("LazyAgent Review: AI review started with " .. item.name, vim.log.levels.INFO)
  return true
end


function M.register_frontend(name, frontend)
  assert(type(name) == "string" and name ~= "", "review frontend name is required")
  assert(type(frontend) == "table", "review frontend must be a table")
  frontends[name] = frontend
end

function M.unregister_frontend(name)
  frontends[name] = nil
end

function M.create_from_snapshot(snapshot, opts)
  return GitReview.from_snapshot(snapshot, opts)
end

local function current_snapshot()
  local names = vim.tbl_keys(frontends)
  table.sort(names)
  for _, name in ipairs(names) do
    local frontend = frontends[name]
    if type(frontend.current_snapshot) == "function" then
      local ok, snapshot = pcall(frontend.current_snapshot, {
        put_blob = function(data) return blobs:put(data, { max_bytes = false }) end,
      })
      if ok and snapshot then return snapshot end
    end
  end
end

local function start_created(review, scratch)
  if #(review.changes or {}) == 0 then
    vim.notify("LazyAgent Review: the selected range has no changes", vim.log.levels.INFO)
    return
  end
  if scratch then review.instructions = scratch.text end
  local items = candidates(review)
  if #items == 0 then
    vim.notify("LazyAgent Review: start an idle ACP agent in the review repository first", vim.log.levels.WARN)
    return
  end
  local function selected(item)
    if not item then return end
    local ok, err = submit(review, item, scratch)
    if not ok then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.ERROR) end
  end
  if #items == 1 then selected(items[1]); return end
  vim.ui.select(items, {
    prompt = "Choose AI reviewer:",
    format_item = function(item) return item.name end,
  }, selected)
end

function M.start(range)
  M.setup()
  local scratch = capture_scratch()
  local requested = vim.trim(tostring(range or ""))
  local snapshot = requested == "" and current_snapshot() or nil
  local review, create_err
  if snapshot then
    review, create_err = GitReview.from_snapshot(snapshot)
  else
    review, create_err = GitReview.create(requested, { cwd = vim.fn.getcwd(), blob_store = blobs })
  end
  if not review then
    vim.notify("LazyAgent Review: " .. tostring(create_err), vim.log.levels.ERROR)
    return
  end
  start_created(review, scratch)
end

function M.rerun(review_id)
  M.setup()
  local previous, err = store:get(review_id)
  if not previous then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.ERROR); return end
  local review, create_err = GitReview.from_snapshot({
    root = previous.root, range = previous.range, mode = previous.mode,
    base = previous.base, head = previous.head, changes = previous.changes,
    source = previous.source, lineage_id = previous.lineage_id,
    parent_review_id = previous.review_id,
  })
  if not review then vim.notify("LazyAgent Review: " .. tostring(create_err), vim.log.levels.ERROR); return end
  start_created(review, capture_scratch())
end

function M.open(id)
  M.setup()
  local function show(review)
    if not review then return end
    local _, err = show_review(review)
    if err then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.ERROR) end
  end
  if id and id ~= "" then
    local review, err = store:get(id)
    if not review then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.ERROR); return end
    show(review)
    return
  end
  local reviews, err = store:list()
  if not reviews then vim.notify("LazyAgent Review: " .. tostring(err), vim.log.levels.ERROR); return end
  if #reviews == 0 then vim.notify("LazyAgent Review: no saved reviews", vim.log.levels.INFO); return end
  table.sort(reviews, function(a, b) return tostring(a.created_at) > tostring(b.created_at) end)
  vim.ui.select(reviews, {
    prompt = "Open Git review:",
    format_item = function(review)
      return string.format("%s  %s  %s", review.status or "unknown", review.range or "", review.review_id)
    end,
  }, show)
end


function M.get(id)
  return store:get(id)
end

function M.list(changeset_id, lineage_id)
  if lineage_id then return store:for_lineage(lineage_id) end
  if changeset_id then return store:for_changeset(changeset_id) end
  return store:list()
end

function M.save(review)
  return store:save(review)
end

local function user_annotation(input)
  local annotation = ReviewAnnotations.normalize(vim.tbl_deep_extend("force", input or {}, {
    kind = "comment",
    author = { type = "user", name = vim.env.USER or "User" },
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }))
  if annotation then annotation.pending = true end
  return annotation
end

function M.add_comment(review_id, input)
  local annotation = user_annotation(input)
  if not annotation then return nil, "review comment is empty" end
  return store:update(review_id, function(review)
    if annotation.path and annotation.target and (annotation.target.side == "before" or annotation.target.side == "after") then
      for _, change in ipairs(review.changes or {}) do
        if change.path == annotation.path then
          local ref = annotation.target.side == "before" and change.before_blob or change.after_blob
          annotation.target.blob_hash = type(ref) == "table" and ref.hash or nil
          break
        end
      end
    end
    review.annotations = review.annotations or {}
    review.annotations[#review.annotations + 1] = annotation
    return review
  end)
end

function M.update_annotation(review_id, annotation_id, mutate)
  return store:update(review_id, function(review)
    for index, annotation in ipairs(review.annotations or {}) do
      if annotation.id == annotation_id then
        local updated = type(mutate) == "function" and mutate(vim.deepcopy(annotation)) or nil
        if updated == false then table.remove(review.annotations, index) else review.annotations[index] = updated or annotation end
        return review
      end
    end
    return review
  end)
end

function M.toggle_resolved(review_id, annotation_id)
  return M.update_annotation(review_id, annotation_id, function(annotation)
    annotation.resolved = not annotation.resolved
    annotation.resolved_at = annotation.resolved and os.date("!%Y-%m-%dT%H:%M:%SZ") or nil
    annotation.pending_state = true
    return annotation
  end)
end

function M.read_blob(ref)
  return blobs:get(ref, { max_bytes = false })
end


function M.pending_feedback_count(review)
  local count = 0
  for _, annotation in ipairs(review and review.annotations or {}) do
    if annotation.pending == true or annotation.pending_state == true then count = count + 1 end
  end
  return count
end

function M.send_feedback(review_id)
  local review, err = store:get(review_id)
  if not review then return nil, err end
  if M.pending_feedback_count(review) == 0 then return nil, "no pending review feedback" end
  if not review.reviewer or not review.reviewer_thread_id then return nil, "the original ACP review thread is unavailable" end
  local item = candidate(review.reviewer, review)
  if not item or item.snapshot.acp_thread_id ~= review.reviewer_thread_id then
    return nil, "resume the original idle ACP review thread before sending feedback"
  end
  local guard_id
  if not (review.source and review.source.mutable == true) then
    guard_id = "git-review-feedback:" .. tostring(review.review_id)
    local guarded, guard_err = item.backend.set_read_only_guard(
      item.session.pane_id, guard_id, true, "Immutable Git review feedback " .. tostring(review.review_id)
    )
    if not guarded then return nil, guard_err end
  end
  pending[item.name] = {
    phase = "feedback",
    review = review,
    backend = item.backend,
    thread_id = item.snapshot.acp_thread_id,
    session = item.session,
    guard_id = guard_id,
  }
  local accepted = item.backend.paste_and_submit(item.session.pane_id, feedback_prompt(review), { "C-m" }, {})
  if accepted ~= true then
    pending[item.name] = nil
    if guard_id then item.backend.set_read_only_guard(item.session.pane_id, guard_id, false) end
    return nil, "the ACP session did not accept review feedback"
  end
  return true
end

M._as_thread = as_thread
M._finish = finish
M._capture_scratch = capture_scratch
M._consume_scratch = consume_scratch
M._feedback_prompt = feedback_prompt
M._apply_feedback_response = apply_feedback_response

return M
