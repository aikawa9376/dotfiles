local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message)
  end
end

function M.run()
  local state = require("lazyagent.logic.state")
  state.opts = state.opts or {}

  local previous_image_opts = state.opts.image_paste
  local previous_snacks = package.loaded["snacks"]
  local previous_bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local placements = {}
  local scratch_bufnr
  local acp_bufnr
  local replacement_bufnr
  local image_path = vim.fn.tempname() .. ".png"

  local function cleanup()
    local image_paste = package.loaded["lazyagent.logic.image_paste"]
    if image_paste then
      pcall(image_paste.clear_buffer_previews, scratch_bufnr)
      pcall(image_paste.clear_buffer_previews, acp_bufnr)
    end
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(previous_bufnr) then
      pcall(vim.api.nvim_win_set_buf, winid, previous_bufnr)
    end
    for _, bufnr in ipairs({ scratch_bufnr, acp_bufnr, replacement_bufnr }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    package.loaded["snacks"] = previous_snacks
    state.opts.image_paste = previous_image_opts
    vim.fn.delete(image_path)
  end

  local ok, err = xpcall(function()
    vim.fn.writefile({ "image-preview-fixture" }, image_path, "b")
    state.opts.image_paste = {
      enabled = true,
      drop = { enabled = false },
      preview = {
        enabled = true,
        auto_resize = true,
        max_width = 80,
        max_height = 20,
        acp_max_previews = 6,
        acp_prefetch_lines = 0,
        acp_refresh_debounce_ms = 0,
      },
    }

    package.loaded["snacks"] = {
      image = {
        placement = {
          new = function(bufnr, src, opts)
            local placement = {
              buf = bufnr,
              src = src,
              opts = opts,
              closed = false,
              hidden = false,
              update_count = 0,
              show_count = 0,
            }
            function placement:update()
              self.update_count = self.update_count + 1
            end
            function placement:show()
              self.show_count = self.show_count + 1
              self.hidden = false
            end
            function placement:hide()
              self.hidden = true
            end
            function placement:close()
              self.closed = true
            end
            placements[#placements + 1] = placement
            return placement
          end,
        },
      },
    }

    local image_paste = require("lazyagent.logic.image_paste")

    scratch_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch_bufnr].buftype = "nofile"
    vim.b[scratch_bufnr].lazyagent_is_scratch = true
    local scratch_line = "日本語 prefix @" .. image_path .. " suffix"
    vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, { scratch_line })
    vim.api.nvim_win_set_buf(winid, scratch_bufnr)

    image_paste.attach_buffer(scratch_bufnr)
    assert(vim.wait(500, function()
      return #placements == 1
    end, 10), "attaching a scratch buffer restores its managed image preview")
    assert_equal(#placements, 1, "scratch restores an existing managed image reference")
    local scratch_placement = placements[1]
    local reference_start = assert(scratch_line:find("@", 1, true))
    local reference_end = reference_start + #("@" .. image_path) - 1
    assert_equal(
      scratch_placement.opts.range,
      { 1, reference_start - 1, 1, reference_end },
      "preview range uses the image reference byte columns"
    )

    image_paste.refresh_buffer_previews(scratch_bufnr)
    assert_equal(#placements, 1, "unchanged scratch refresh reuses its placement")
    assert_equal(scratch_placement.closed, false, "reused scratch placement stays open")

    local updates_before_move = scratch_placement.update_count
    vim.api.nvim_buf_set_lines(scratch_bufnr, 0, 0, false, { "inserted before image" })
    image_paste.refresh_buffer_previews(scratch_bufnr)
    assert_equal(#placements, 1, "moving an image reference keeps its placement")
    assert_equal(scratch_placement.opts.pos[1], 2, "moved image placement follows its extmark")
    assert_truthy(
      scratch_placement.update_count > updates_before_move,
      "moving an image reference updates the renderer placement"
    )

    local shifted_line = "さらに長い日本語 prefix @" .. image_path .. " suffix"
    vim.api.nvim_buf_set_lines(scratch_bufnr, 1, 2, false, { shifted_line })
    image_paste.refresh_buffer_previews(scratch_bufnr)
    assert_equal(#placements, 1, "moving a reference within its line keeps its placement")
    local shifted_start = assert(shifted_line:find("@", 1, true))
    assert_equal(
      scratch_placement.opts.pos,
      { 2, shifted_start - 1 },
      "same-line reference movement updates the renderer position"
    )

    vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, {
      "replacement header",
      "another replacement line",
      shifted_line,
    })
    image_paste.refresh_buffer_previews(scratch_bufnr)
    assert_equal(#placements, 1, "a full buffer refresh reuses the image placement")
    assert_equal(scratch_placement.opts.pos[1], 3, "reused placement follows a full buffer refresh")

    image_paste.clear_buffer_previews(scratch_bufnr)
    acp_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[acp_bufnr].buftype = "nofile"
    vim.b[acp_bufnr].lazyagent_acp_transcript = true
    vim.api.nvim_buf_set_lines(acp_bufnr, 0, -1, false, {
      "[image] @" .. image_path .. " image/png",
    })
    vim.api.nvim_win_set_buf(winid, acp_bufnr)

    image_paste.refresh_buffer_previews(acp_bufnr)
    local acp_placement = placements[#placements]
    local acp_placement_count = #placements
    image_paste.refresh_buffer_previews(acp_bufnr)
    assert_equal(#placements, acp_placement_count, "unchanged ACP refresh reuses its placement")
    assert_equal(acp_placement.closed, false, "reused ACP placement stays open")

    replacement_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(winid, replacement_bufnr)
    assert(vim.wait(500, function()
      return acp_placement.closed
    end, 10), "hiding an ACP buffer closes its terminal placement")

    vim.api.nvim_win_set_buf(winid, acp_bufnr)
    assert(vim.wait(500, function()
      return #placements > acp_placement_count
    end, 10), "showing an ACP buffer recreates its preview")
  end, debug.traceback)

  cleanup()
  if not ok then
    error(err)
  end
end

return M
