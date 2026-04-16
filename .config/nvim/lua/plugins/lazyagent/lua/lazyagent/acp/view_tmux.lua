local M = {}

local tmux = require("lazyagent.tmux")

local function build_tail_command(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  local quoted_dir = vim.fn.shellescape(dir)
  local quoted_path = vim.fn.shellescape(path)
  local inner = "mkdir -p " .. quoted_dir .. " && touch " .. quoted_path .. " && exec tail -n +1 -F " .. quoted_path
  return "sh -lc " .. vim.fn.shellescape(inner)
end

function M.create_pane(args, on_split)
  local tmux_opts = vim.tbl_deep_extend("force", {}, args.opts or {}, {
    on_split = function(pane_id)
      if on_split then
        on_split(pane_id, {})
      end
    end,
  })

  tmux.split(build_tail_command(args.transcript_path), args.size, args.is_vertical, tmux_opts)
end

function M.configure_pane(pane_id, opts)
  return tmux.configure_pane(pane_id, opts)
end

function M.clear_pane_config(pane_id)
  return tmux.clear_pane_config(pane_id)
end

function M.pane_exists(pane_id)
  return tmux.pane_exists(pane_id)
end

function M.kill_pane(pane_id)
  return tmux.kill_pane(pane_id)
end

function M.get_pane_info(pane_id, on_info)
  return tmux.get_pane_info(pane_id, on_info)
end

function M.break_pane(pane_id)
  return tmux.break_pane(pane_id)
end

function M.break_pane_sync(pane_id)
  return tmux.break_pane_sync(pane_id)
end

function M.join_pane(pane_id, size, is_vertical, on_done)
  return tmux.join_pane(pane_id, size, is_vertical, on_done)
end

function M.copy_mode(pane_id)
  return tmux.copy_mode(pane_id)
end

function M.scroll_up(pane_id)
  return tmux.scroll_up(pane_id)
end

function M.scroll_down(pane_id)
  return tmux.scroll_down(pane_id)
end

function M.cleanup_if_idle()
  return tmux.cleanup_if_idle()
end

return M
