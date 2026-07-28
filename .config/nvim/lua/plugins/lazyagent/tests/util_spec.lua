local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local util = require("lazyagent.util")
  local normal_win = vim.api.nvim_get_current_win()
  local normal_buf = vim.api.nvim_get_current_buf()
  local scratch_buf = vim.api.nvim_create_buf(false, true)
  local previous_project_module = package.loaded.project
  package.loaded.project = {
    get_project_root = function(bufnr)
      assert_equal(bufnr, normal_buf, "project root buffer")
      return "/tmp/lazyagent-project-root", "pattern"
    end,
  }
  assert_equal(util.project_root_for_buf(normal_buf), "/tmp/lazyagent-project-root",
    "project.nvim is the Neovim root authority")
  package.loaded.project = previous_project_module

  vim.cmd("vnew")
  local transcript_win = vim.api.nvim_get_current_win()
  local transcript_buf = vim.api.nvim_get_current_buf()
  vim.bo[transcript_buf].buftype = "nofile"
  vim.bo[transcript_buf].filetype = "lazyagent_acp"
  vim.b[scratch_buf].lazyagent_prev_win = transcript_win

  local previous_window_module = package.loaded["lazyagent.window"]
  package.loaded["lazyagent.window"] = {
    get_scratch_bufnr = function()
      return scratch_buf
    end,
  }

  local path = vim.fn.tempname() .. "-raw-transcript.md"
  vim.fn.writefile({ "# User", "hello" }, path)
  local opened, bufnr, winid = util.open_in_normal_win(path)

  assert_equal(opened, true, "open raw transcript")
  assert_equal(winid, normal_win, "skip dedicated transcript window")
  assert_equal(bufnr, vim.api.nvim_win_get_buf(normal_win), "return opened buffer")
  assert_equal(vim.api.nvim_buf_get_name(bufnr), path, "open requested path")
  assert_equal(vim.bo[transcript_buf].filetype, "lazyagent_acp", "preserve ACP filetype")

  package.loaded["lazyagent.window"] = previous_window_module
  vim.api.nvim_win_close(transcript_win, true)
  pcall(vim.api.nvim_buf_delete, transcript_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if vim.api.nvim_buf_is_valid(normal_buf) then
    vim.api.nvim_win_set_buf(normal_win, normal_buf)
  end
  vim.fn.delete(path)
end

return M
