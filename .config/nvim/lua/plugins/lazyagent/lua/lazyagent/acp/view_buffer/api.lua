local M = {}

function M.attach(api, ctx)
  local M = api
  local image_paste = require("lazyagent.logic.image_paste")
  local smooth_scroll = require("lazyagent.acp.view_buffer.smooth_scroll")
  local footer_view = ctx.footer_view
  local ensure_layout_autocmds = ctx.ensure_layout_autocmds
  local to_bufnr = ctx.to_bufnr
  local save_window_views = ctx.save_window_views
  local pane_config = ctx.pane_config
  local first_visible_window = ctx.first_visible_window
  local restore_window_views = ctx.restore_window_views
  local resolve_anchor_window = ctx.resolve_anchor_window
  local capture_window_options = ctx.capture_window_options
  local set_window_size = ctx.set_window_size
  local create_transcript_buffer = ctx.create_transcript_buffer
  local adopt_transcript_buffer = ctx.adopt_transcript_buffer
  local apply_transcript_window_opts = ctx.apply_transcript_window_opts
  local refresh_buffer_from_path = ctx.refresh_buffer_from_path
  local refresh_buffer_from_file = ctx.refresh_buffer_from_file
  local resume_deferred_updates_for_buffer = ctx.resume_deferred_updates_for_buffer
  local refresh_buffer_layout = ctx.refresh_buffer_layout
  local cleanup_markdown_rendering = ctx.cleanup_markdown_rendering
  local close_buffer_windows = ctx.close_buffer_windows
  local should_release_buffer_on_hide = ctx.should_release_buffer_on_hide
  local release_transcript_buffer = ctx.release_transcript_buffer
  local resolve_release_buffer_on_hide = ctx.resolve_release_buffer_on_hide
  local buffer_var = ctx.buffer_var
  local set_follow_output = ctx.set_follow_output
  local pause_follow_output = ctx.pause_follow_output
  local pane_buffers = ctx.pane_buffers
  local layout_state = ctx.layout_state
  local dedicated_transcript_windows = ctx.dedicated_transcript_windows
  local redirecting_transcript_windows = ctx.redirecting_transcript_windows
  local allocate_pane_id = ctx.allocate_pane_id
  local close_timer = ctx.close_timer
  local queue_append = ctx.queue_append

  local function smooth_scroll_config(bufnr, mode)
    local pane_id = buffer_var(bufnr, "lazyagent_acp_pane_id")
    local opts = pane_config[tostring(pane_id or "")] or {}
    return smooth_scroll.config(opts.smooth_scroll, mode)
  end

  function M.refresh_all_footers()
    return footer_view.refresh_all_footers()
  end

  function M.refresh_agent_footers(agent_name, opts)
    return footer_view.refresh_agent_footers(agent_name, opts)
  end

  function M.capture_switch_view(pane_id)
    ensure_layout_autocmds()
    local bufnr = to_bufnr(pane_id)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end

    local windows = {}
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        windows[#windows + 1] = win
      end
    end
    if #windows == 0 then
      return nil
    end

    return {
      pane_id = tostring(pane_id),
      bufnr = bufnr,
      windows = windows,
      views = save_window_views(bufnr),
      pane_config = vim.deepcopy(pane_config[tostring(pane_id)] or {}),
    }
  end

  function M.create_pane(args, on_split)
    ensure_layout_autocmds()
    local anchor_win = resolve_anchor_window(args.acp and args.acp.source_winid)
    local pane_id = allocate_pane_id("buffer-acp")
    local agent_name = (args.acp or {}).agent_name or "agent"
    local switch_view = args.acp and args.acp.reuse_view or nil
    local bufnr = adopt_transcript_buffer(
      pane_id,
      agent_name,
      args.transcript_path,
      switch_view,
      args.acp and args.acp.source_bufnr or nil
    )
    local reused_view = bufnr ~= nil

    local base_pane_config = reused_view and type(switch_view) == "table" and switch_view.pane_config or nil
    local inherited_follow_output = true
    if reused_view and type(base_pane_config) == "table" and base_pane_config.follow_output == false then
      inherited_follow_output = false
    end
    pane_config[pane_id] = vim.tbl_extend("force", base_pane_config or pane_config[pane_id] or {}, {
      source_winid = anchor_win,
      source_window_options = capture_window_options(anchor_win),
      pane_size = args.size,
      is_vertical = args.is_vertical == true,
      follow_output = inherited_follow_output,
      buffer_background = args.acp and args.acp.buffer_background or nil,
      buffer_inactive_background = args.acp and args.acp.buffer_inactive_background or nil,
      table_layout = args.acp and args.acp.table_layout or "table",
      fancy_mode = args.acp and args.acp.fancy_mode == true,
      smooth_scroll = vim.deepcopy(args.acp and args.acp.smooth_scroll or {}),
      release_buffer_on_hide = args.acp and args.acp.release_buffer_on_hide == true,
      transcript_max_lines = args.acp and args.acp.transcript_max_lines or nil,
      render_markdown_max_lines = args.acp and args.acp.render_markdown_max_lines or nil,
      transcript_compaction = vim.deepcopy(args.acp and args.acp.transcript_compaction or {}),
    })

    local win = bufnr and first_visible_window(bufnr) or nil
    if reused_view and win then
      for _, visible_win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(visible_win) then
          apply_transcript_window_opts(visible_win, args.is_vertical, pane_config[pane_id])
        end
      end
      refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
      restore_window_views(bufnr, switch_view and switch_view.views or nil)
    else
      if anchor_win then
        pcall(vim.api.nvim_set_current_win, anchor_win)
      end

      if args.is_vertical then
        vim.cmd("vsplit")
      else
        vim.cmd("split")
      end

      win = vim.api.nvim_get_current_win()
      set_window_size(win, args.size, args.is_vertical)
      bufnr = create_transcript_buffer(
        pane_id,
        agent_name,
        args.transcript_path,
        args.acp and args.acp.source_bufnr or nil
      )
      vim.api.nvim_win_set_buf(win, bufnr)
      apply_transcript_window_opts(win, args.is_vertical, pane_config[pane_id])
      refresh_buffer_from_path(bufnr, args.transcript_path, { force = true })
    end

    if anchor_win and anchor_win ~= win then
      pcall(vim.api.nvim_set_current_win, anchor_win)
    end

    if on_split then
      vim.schedule(function()
        on_split(pane_id, {
          bufnr = bufnr,
          winid = win,
          source_winid = anchor_win,
          preserve_existing_transcript = reused_view == true,
        })
      end)
    end
  end

  function M.on_session_created(session)
    local bufnr = to_bufnr(session and session.pane_id)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(function()
        vim.b[bufnr].lazyagent_acp_pane_id = tostring(session.pane_id)
        vim.b[bufnr].lazyagent_acp_agent = session.agent_name
        vim.b[bufnr].lazyagent_acp_transcript_path = session.transcript_path
        local source_bufnr = session.agent_cfg and (session.agent_cfg.source_bufnr or session.agent_cfg.origin_bufnr)
          or nil
        if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
          vim.b[bufnr].lazyagent_source_bufnr = source_bufnr
        end
      end)
      refresh_buffer_layout(bufnr, { force_footer = true })
    end
    if session and session.view_state and session.view_state.preserve_existing_transcript == true then
      return
    end
    refresh_buffer_from_file(session)
  end

  function M.on_transcript_updated(session, text, mode)
    session.view_state = session.view_state or {}
    if mode == "w" then
      session.view_state.force_full_refresh = true
      session.view_state.preserve_existing_transcript = nil
      session.view_state.pending_append = ""
      session.view_state.pending_append_chunks = nil
      session.view_state.pending_append_size = 0
      close_timer(session.view_state.append_timer)
      session.view_state.append_timer = nil
      refresh_buffer_from_file(session)
      return
    end
    if session.view_state.force_full_refresh then
      refresh_buffer_from_file(session)
      return
    end
    queue_append(session, text)
  end

  function M.configure_pane(pane_id, opts)
    local key = tostring(pane_id)
    local merged = vim.tbl_extend("force", pane_config[key] or {}, opts or {})
    local source_win = resolve_anchor_window(merged.source_winid)
    if source_win then
      merged.source_window_options = capture_window_options(source_win) or merged.source_window_options
    end
    pane_config[key] = merged
    if pane_config[key].follow_output == nil then
      pane_config[key].follow_output = true
    end
    return true
  end

  function M.clear_pane_config(pane_id)
    pane_config[tostring(pane_id)] = nil
    return true
  end

  function M.debug_snapshot()
    local snapshot = {
      pane_count = 0,
      config_count = 0,
      buffer_count = 0,
      valid_buffer_count = 0,
      window_count = 0,
      layout_count = 0,
      active_timer_count = 0,
      dedicated_window_count = 0,
      redirecting_window_count = 0,
      panes = {},
    }

    for _ in pairs(pane_config) do
      snapshot.config_count = snapshot.config_count + 1
    end
    for pane_id, bufnr in pairs(pane_buffers) do
      snapshot.pane_count = snapshot.pane_count + 1
      snapshot.buffer_count = snapshot.buffer_count + 1
      local valid = vim.api.nvim_buf_is_valid(bufnr)
      local windows = valid and vim.fn.win_findbuf(bufnr) or {}
      if valid then
        snapshot.valid_buffer_count = snapshot.valid_buffer_count + 1
      end
      snapshot.window_count = snapshot.window_count + #windows
      snapshot.panes[tostring(pane_id)] = {
        bufnr = bufnr,
        buffer_valid = valid,
        window_count = #windows,
        configured = pane_config[tostring(pane_id)] ~= nil,
      }
    end
    for _, entry in pairs(layout_state) do
      snapshot.layout_count = snapshot.layout_count + 1
      if type(entry) == "table" and entry.markdown_render_timer ~= nil then
        snapshot.active_timer_count = snapshot.active_timer_count + 1
      end
    end
    for _ in pairs(dedicated_transcript_windows) do
      snapshot.dedicated_window_count = snapshot.dedicated_window_count + 1
    end
    for _ in pairs(redirecting_transcript_windows) do
      snapshot.redirecting_window_count = snapshot.redirecting_window_count + 1
    end

    return snapshot
  end

  function M.capture_thread_view(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local win = first_visible_window(bufnr)
    local saved = nil
    if win then
      local ok, result = pcall(vim.api.nvim_win_call, win, function()
        return vim.fn.winsaveview()
      end)
      saved = ok and result or nil
    end
    return {
      follow_output = (pane_config[tostring(pane_id)] or {}).follow_output ~= false,
      view = type(saved) == "table" and {
        lnum = saved.lnum,
        col = saved.col,
        topline = saved.topline,
        leftcol = saved.leftcol,
      } or {},
    }
  end

  function M.restore_thread_view(pane_id, saved)
    if type(saved) ~= "table" then
      return false
    end
    local bufnr = to_bufnr(pane_id)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    local key = tostring(pane_id)
    pane_config[key] = pane_config[key] or {}
    pane_config[key].follow_output = saved.follow_output ~= false
    local win = first_visible_window(bufnr)
    if not win or type(saved.view) ~= "table" then
      return true
    end
    local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    local restored = vim.deepcopy(saved.view)
    restored.lnum = math.min(math.max(1, tonumber(restored.lnum) or 1), line_count)
    restored.topline = math.min(math.max(1, tonumber(restored.topline) or 1), line_count)
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(restored)
    end)
    return true
  end

  function M.release_session_resources(session)
    if type(session) ~= "table" then
      return false
    end

    local bufnr = to_bufnr(session.pane_id)
    if bufnr then
      cleanup_markdown_rendering(bufnr)
      if type(image_paste.clear_buffer_previews) == "function" then
        image_paste.clear_buffer_previews(bufnr)
      end
    end

    local view_state = type(session.view_state) == "table" and session.view_state or nil
    local source_winid = view_state and view_state.source_winid or nil
    if view_state then
      close_timer(view_state.append_timer)
    end

    session.view_state = source_winid ~= nil and { source_winid = source_winid } or {}
    return true
  end

  function M.pane_exists(pane_id)
    return to_bufnr(pane_id) ~= nil or pane_config[tostring(pane_id)] ~= nil
  end

  function M.kill_pane(pane_id, session)
    local bufnr = to_bufnr(pane_id)
    if session then
      M.release_session_resources(session)
    end
    if bufnr then
      cleanup_markdown_rendering(bufnr)
      if type(image_paste.clear_buffer_previews) == "function" then
        image_paste.clear_buffer_previews(bufnr)
      end
    end
    pane_buffers[tostring(pane_id)] = nil
    pane_config[tostring(pane_id)] = nil
    if not bufnr then
      return true
    end
    close_buffer_windows(bufnr)
    layout_state[tostring(bufnr)] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return true
  end

  function M.get_pane_info(pane_id, on_info)
    local bufnr = to_bufnr(pane_id)
    local info = nil
    if bufnr then
      local win = first_visible_window(bufnr)
      if win then
        info = {
          width = vim.api.nvim_win_get_width(win),
          height = vim.api.nvim_win_get_height(win),
        }
      end
    end
    if on_info then
      vim.schedule(function()
        on_info(info)
      end)
    end
    return info ~= nil
  end

  function M.break_pane(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr then
      return pane_config[tostring(pane_id)] ~= nil
    end
    close_buffer_windows(bufnr)
    if should_release_buffer_on_hide(pane_id) then
      release_transcript_buffer(pane_id, bufnr)
    end
    return true
  end

  function M.break_pane_sync(pane_id)
    return M.break_pane(pane_id)
  end

  function M.join_pane(pane_id, size, is_vertical, on_done, session)
    ensure_layout_autocmds()
    local bufnr = to_bufnr(pane_id)
    local pane_opts = pane_config[tostring(pane_id)] or {}
    local anchor_win = resolve_anchor_window(pane_opts.source_winid)
    local existing = bufnr and first_visible_window(bufnr) or nil
    if existing then
      pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_opts, {
        source_winid = anchor_win,
        source_window_options = capture_window_options(anchor_win) or pane_opts.source_window_options,
        pane_size = size or pane_opts.pane_size,
        is_vertical = is_vertical == true,
        buffer_background = pane_opts.buffer_background or (session and session.buffer_background) or nil,
        buffer_inactive_background = pane_opts.buffer_inactive_background
          or (session and session.buffer_inactive_background)
          or nil,
        table_layout = pane_opts.table_layout or (session and session.table_layout) or "table",
        fancy_mode = pane_opts.fancy_mode == true or (session and session.fancy_mode == true),
        smooth_scroll = vim.deepcopy(pane_opts.smooth_scroll or (session and session.smooth_scroll) or {}),
        release_buffer_on_hide = resolve_release_buffer_on_hide(pane_opts, session),
        transcript_max_lines = pane_opts.transcript_max_lines or (session and session.transcript_max_lines) or nil,
        render_markdown_max_lines = pane_opts.render_markdown_max_lines
          or (session and session.render_markdown_max_lines)
          or nil,
        transcript_compaction = vim.deepcopy(
          pane_opts.transcript_compaction or (session and session.transcript_compaction) or {}
        ),
      })
      refresh_buffer_layout(bufnr, { force_footer = true })
      if on_done then
        vim.schedule(function()
          on_done(true)
        end)
      end
      return true
    end

    if not bufnr then
      if not session then
        if on_done then
          vim.schedule(function()
            on_done(false)
          end)
        end
        return false
      end
      local source_bufnr = session.agent_cfg and (session.agent_cfg.source_bufnr or session.agent_cfg.origin_bufnr)
        or nil
      bufnr = create_transcript_buffer(pane_id, session.agent_name, session.transcript_path, source_bufnr)
    end

    if anchor_win then
      pcall(vim.api.nvim_set_current_win, anchor_win)
    end

    if is_vertical then
      vim.cmd("vsplit")
    else
      vim.cmd("split")
    end
    local win = vim.api.nvim_get_current_win()
    set_window_size(win, size, is_vertical)
    vim.api.nvim_win_set_buf(win, bufnr)
    pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_config[tostring(pane_id)] or {}, {
      source_winid = anchor_win,
      source_window_options = capture_window_options(anchor_win) or pane_opts.source_window_options,
      pane_size = size or pane_opts.pane_size,
      is_vertical = is_vertical == true,
      follow_output = pane_opts.follow_output ~= false,
      buffer_background = pane_opts.buffer_background or (session and session.buffer_background) or nil,
      buffer_inactive_background = pane_opts.buffer_inactive_background
        or (session and session.buffer_inactive_background)
        or nil,
      table_layout = pane_opts.table_layout or (session and session.table_layout) or "table",
      fancy_mode = pane_opts.fancy_mode == true or (session and session.fancy_mode == true),
      smooth_scroll = vim.deepcopy(pane_opts.smooth_scroll or (session and session.smooth_scroll) or {}),
      release_buffer_on_hide = resolve_release_buffer_on_hide(pane_opts, session),
      transcript_max_lines = pane_opts.transcript_max_lines or (session and session.transcript_max_lines) or nil,
      render_markdown_max_lines = pane_opts.render_markdown_max_lines
        or (session and session.render_markdown_max_lines)
        or nil,
      transcript_compaction = vim.deepcopy(
        pane_opts.transcript_compaction or (session and session.transcript_compaction) or {}
      ),
    })
    apply_transcript_window_opts(win, is_vertical, pane_config[tostring(pane_id)])
    refresh_buffer_from_path(bufnr, session and session.transcript_path or buffer_var(bufnr, "lazyagent_acp_transcript_path"))

    if anchor_win and anchor_win ~= win then
      pcall(vim.api.nvim_set_current_win, anchor_win)
    end

    if on_done then
      vim.schedule(function()
        on_done(true)
      end)
    end
    return true
  end

  function M.open_fullscreen_transcript(pane_id, session)
    session = type(session) == "table" and session or nil
    if not session or not session.transcript_path or session.transcript_path == "" then
      return false
    end

    local source_opts = pane_config[tostring(pane_id)] or {}
    local tab_opts = vim.tbl_extend("force", {}, source_opts, {
      source_winid = nil,
      source_window_options = nil,
      pane_size = nil,
      is_vertical = false,
      follow_output = false,
      fancy_mode = false,
      table_layout = "table",
      release_buffer_on_hide = false,
      transcript_max_lines = nil,
      render_markdown_max_lines = nil,
    })
    tab_opts.transcript_compaction = vim.tbl_deep_extend(
      "force",
      vim.deepcopy(source_opts.transcript_compaction or session.transcript_compaction or {}),
      { enabled = false }
    )

    local inspector_pane_id = allocate_pane_id("buffer-acp-inspector")

    vim.cmd("tabnew")
    local win = vim.api.nvim_get_current_win()
    local source_bufnr = session.agent_cfg and (session.agent_cfg.source_bufnr or session.agent_cfg.origin_bufnr)
      or nil
    local bufnr = create_transcript_buffer(
      inspector_pane_id,
      session.agent_name or "agent",
      session.transcript_path,
      source_bufnr
    )
    pane_config[tostring(inspector_pane_id)] = tab_opts

    vim.api.nvim_win_set_buf(win, bufnr)
    apply_transcript_window_opts(win, false, tab_opts)
    refresh_buffer_from_path(bufnr, session.transcript_path, { force = true })
    set_follow_output(bufnr, false)

    vim.bo[bufnr].bufhidden = "wipe"
    vim.b[bufnr].lazyagent_acp_fullscreen_transcript = true

    vim.keymap.set("n", "q", function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
        vim.cmd("tabclose")
      end
    end, {
      buffer = bufnr,
      noremap = true,
      nowait = true,
      silent = true,
      desc = "LazyAgentACP: close fullscreen transcript",
    })

    return true
  end

  function M.copy_mode()
    return false
  end

  local function scroll_delta_for_key(win, key)
    local height = math.max(1, vim.api.nvim_win_get_height(win))
    local half = tonumber(vim.wo[win].scroll) or math.floor(height / 2)
    if half <= 0 then
      half = math.floor(height / 2)
    end
    half = math.max(1, half)

    if key == "<C-u>" then
      return -half
    elseif key == "<C-d>" then
      return half
    elseif key == "<C-b>" then
      return -math.max(1, height - 2)
    elseif key == "<C-f>" then
      return math.max(1, height - 2)
    end
    return nil
  end

  local function scroll_window_by_key(win, key, cfg, opts)
    opts = opts or {}
    if not win or not vim.api.nvim_win_is_valid(win) then
      return false
    end

    local delta = cfg and scroll_delta_for_key(win, key) or nil
    if delta then
      return smooth_scroll.scroll_by_lines(win, delta, cfg, opts)
    end

    local moved = false
    pcall(vim.api.nvim_win_call, win, function()
      local before = vim.fn.winsaveview()
      local termcode = vim.api.nvim_replace_termcodes(key, true, false, true)
      vim.cmd.normal({ bang = true, args = { termcode } })
      local after = vim.fn.winsaveview()
      moved = before.topline ~= after.topline or before.lnum ~= after.lnum or before.topfill ~= after.topfill
    end)
    return moved
  end

  function M._scroll_buffer_with_key(bufnr, key, opts)
    opts = opts or {}
    if opts.pause ~= false then
      pause_follow_output(bufnr, { reason = "manual", win = vim.api.nvim_get_current_win() })
    end

    local cfg = smooth_scroll_config(bufnr, "manual")
    local scrolled = false
    local function resume_if_needed()
      if opts.resume_at_end == true and M._any_window_at_transcript_end(bufnr) then
        M._resume_follow_output(bufnr)
      end
    end

    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if scroll_window_by_key(win, key, cfg, {
        bufnr = bufnr,
        mode = "manual",
        on_finish = resume_if_needed,
      }) then
        scrolled = true
      end
    end

    if not cfg then
      resume_if_needed()
    end

    return scrolled
  end

  function M.scroll_up(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr then
      return false
    end

    return M._scroll_buffer_with_key(bufnr, "<C-u>")
  end

  function M.scroll_down(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr then
      return false
    end

    return M._scroll_buffer_with_key(bufnr, "<C-d>", { resume_at_end = true })
  end

  function M.scroll_page_up(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr then
      return false
    end

    return M._scroll_buffer_with_key(bufnr, "<C-b>")
  end

  function M.scroll_page_down(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr then
      return false
    end

    return M._scroll_buffer_with_key(bufnr, "<C-f>", { resume_at_end = true })
  end

  function M.resume_follow(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr then
      return false
    end
    return M._resume_follow_output(bufnr)
  end

  function M.sync_mobile_transcript(pane_id)
    local bufnr = to_bufnr(pane_id)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    if type(resume_deferred_updates_for_buffer) ~= "function" then
      return false
    end

    return resume_deferred_updates_for_buffer(bufnr, {
      allow_hidden_incremental = true,
      refresh_layout = true,
    })
  end

  function M.cleanup_if_idle()
    local cleaned = false

    for pane_id, bufnr in pairs(pane_buffers) do
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        pane_buffers[pane_id] = nil
        pane_config[pane_id] = nil
        cleaned = true
      end
    end

    for key, _ in pairs(layout_state) do
      local bufnr = tonumber(key)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        layout_state[key] = nil
        cleaned = true
      end
    end

    for key, entry in pairs(dedicated_transcript_windows) do
      local bufnr = entry and entry.bufnr or nil
      local winid = entry and entry.winid or nil
      if (bufnr and not vim.api.nvim_buf_is_valid(bufnr)) or (winid and not vim.api.nvim_win_is_valid(winid)) then
        dedicated_transcript_windows[key] = nil
        redirecting_transcript_windows[key] = nil
        cleaned = true
      end
    end

    return cleaned
  end
end

return M
