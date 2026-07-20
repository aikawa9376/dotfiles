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

local function finish(agent_name)
  local item = pending[agent_name]
  if not item then return end
  pending[agent_name] = nil
  item.backend.set_read_only_guard(item.session.pane_id, item.guard_id, false)
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
  local saved, save_err = store:save(item.review)
  if not saved then
    vim.notify("LazyAgent Review: failed to save result: " .. tostring(save_err), vim.log.levels.ERROR)
    return
  end
  vim.schedule(function()
    drawer.open(as_thread(saved))
    vim.notify(string.format("LazyAgent Review: %d finding(s)", #annotations), vim.log.levels.INFO)
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

local function submit(review, item, scratch)
  review.reviewer = item.name
  local saved, err = store:save(review)
  if not saved then return nil, err end
  local guard_id = "git-review:" .. tostring(saved.review_id)
  local guarded, guard_err = item.backend.set_read_only_guard(
    item.session.pane_id,
    guard_id,
    true,
    "Git review " .. tostring(saved.review_id) .. " is read-only"
  )
  if not guarded then return nil, guard_err end
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

function M.start(range)
  M.setup()
  local scratch = capture_scratch()
  local review, create_err = GitReview.create(range, { cwd = vim.fn.getcwd(), blob_store = blobs })
  if not review then
    vim.notify("LazyAgent Review: " .. tostring(create_err), vim.log.levels.ERROR)
    return
  end
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

function M.open(id)
  M.setup()
  local function show(review)
    if not review then return end
    local _, err = drawer.open(as_thread(review))
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

M._as_thread = as_thread
M._finish = finish
M._capture_scratch = capture_scratch
M._consume_scratch = consume_scratch

return M
