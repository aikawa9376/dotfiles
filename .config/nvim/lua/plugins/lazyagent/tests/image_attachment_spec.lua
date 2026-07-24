local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  local previous_sessions = state.sessions
  local previous_notify = vim.notify
  local previous_bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local base = vim.fn.tempname() .. "-image-attachment"
  local source_path = base .. "/source.png"
  local storage = base .. "/storage"
  local scratch_bufnr
  local other_bufnr

  local function cleanup()
    local image_paste = package.loaded["lazyagent.logic.image_paste"]
    if image_paste and scratch_bufnr then
      pcall(image_paste.clear_buffer_previews, scratch_bufnr)
    end
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(previous_bufnr) then
      pcall(vim.api.nvim_win_set_buf, winid, previous_bufnr)
    end
    for _, bufnr in ipairs({ scratch_bufnr, other_bufnr }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    state.opts = previous_opts
    state.sessions = previous_sessions
    vim.notify = previous_notify
    vim.fn.delete(base, "rf")
  end

  local ok, err = xpcall(function()
    vim.fn.mkdir(base, "p")
    vim.fn.writefile({ "image-attachment-fixture" }, source_path, "b")
    vim.notify = function() end
    state.opts = {
      image_paste = {
        enabled = true,
        dir = storage,
        dir_layout = "flat",
        max_dimension = 0,
        notify = false,
        import = { copy = true },
        drop = { enabled = false },
        picker = { recent_limit = 5 },
        preview = { enabled = false },
      },
    }
    state.sessions = {
      Codex = {
        backend = "buffer_acp",
        acp_ready = true,
        acp_supports_image = true,
      },
    }

    scratch_bufnr = vim.api.nvim_create_buf(false, true)
    vim.b[scratch_bufnr].lazyagent_is_scratch = true
    vim.b[scratch_bufnr].lazyagent_agent = "Codex"
    vim.api.nvim_win_set_buf(winid, scratch_bufnr)

    local image_paste = require("lazyagent.logic.image_paste")
    local stored_path = assert(image_paste.attach_file_into_buffer(scratch_bufnr, source_path))
    assert(stored_path ~= source_path, "selected image is copied into LazyAgent storage")
    assert_equal(vim.fn.filereadable(stored_path), 1, "stored attachment exists")
    assert_equal(
      vim.api.nvim_buf_get_lines(scratch_bufnr, 0, 2, false),
      { "@" .. stored_path, "" },
      "stored attachment reference"
    )

    other_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(winid, other_bufnr)
    local hidden_stored_path = assert(image_paste.attach_file_into_buffer(scratch_bufnr, source_path))
    assert_equal(vim.api.nvim_get_current_buf(), other_bufnr, "hidden scratch attachment preserves current buffer")
    assert_equal(
      vim.api.nvim_buf_get_lines(scratch_bufnr, 0, -1, false),
      { "@" .. stored_path, "@" .. hidden_stored_path, "" },
      "hidden scratch attachment appends without using another buffer's cursor"
    )

    vim.api.nvim_win_set_buf(winid, scratch_bufnr)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    assert_equal(image_paste.current_image(scratch_bufnr).source, stored_path, "image action cursor reference")
    assert_equal(image_paste.remove_image_reference(scratch_bufnr), true, "remove image reference")
    assert_equal(
      vim.api.nvim_buf_get_lines(scratch_bufnr, 0, -1, false),
      { "", "@" .. hidden_stored_path, "" },
      "removed image keeps surrounding scratch lines"
    )
    assert_equal(image_paste.capability(scratch_bufnr).status, "supported", "supported ACP capability")

    state.sessions.Codex.acp_supports_image = false
    assert_equal(image_paste.capability(scratch_bufnr).status, "unsupported", "unsupported ACP capability")
    state.sessions.Codex.backend = "tmux"
    assert_equal(image_paste.capability(scratch_bufnr).status, "path", "legacy CLI attachment capability")

    local recent = image_paste.recent_images()
    assert(vim.tbl_contains(vim.tbl_map(function(item) return item.path end, recent), stored_path),
      "stored attachment appears in recent images")
    assert_equal(image_paste.attach_url_into_buffer(scratch_bufnr, "ftp://example.test/image.png"), nil,
      "non-HTTP image URL is rejected")
  end, debug.traceback)

  cleanup()
  if not ok then
    error(err)
  end
end

return M
