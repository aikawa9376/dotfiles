-- Measure repeated image-reference detection in an unchanged ACP viewport.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local output_path = assert(vim.env.LAZYAGENT_BENCH_OUT, "set LAZYAGENT_BENCH_OUT")
vim.opt.rtp:prepend(root)

local state = require("lazyagent.logic.state")
state.opts = {
  image_paste = { preview = { enabled = true, acp_prefetch_lines = 0, acp_refresh_debounce_ms = 0 } },
}
local baseline = vim.env.LAZYAGENT_IMAGE_SCAN_BASELINE
local image = baseline and dofile(baseline) or require("lazyagent.logic.image_paste")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "lazyagent_acp"
vim.b[bufnr].lazyagent_acp_transcript = true
vim.api.nvim_win_set_buf(0, bufnr)

local uv = vim.uv or vim.loop
local stat = uv.fs_stat
local stat_calls = 0
uv.fs_stat = function(...)
  stat_calls = stat_calls + 1
  return stat(...)
end

local samples = {}
local ok, err = xpcall(function()
  -- These paths intentionally do not exist; no renderer or provider is needed.
  for _, kind in ipairs({ "quoted", "bare", "bare_unique" }) do
    for _, count in ipairs({ 16, 64, 128, 256 }) do
      local parts = {}
      for idx = 1, count do
        parts[idx] = kind == "quoted" and 'local value = "lazyagent-image-scan-missing/path/icon.svg"; '
          or kind == "bare" and "lazyagent-image-scan-missing/path/icon.svg "
          or ("lazyagent-image-scan-missing/path/icon_" .. idx .. ".svg ")
      end
      local line = table.concat(parts)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
      local sample = { kind = kind, references = count, source_bytes = #line, refreshes = {} }
      for _ = 1, 2 do
        stat_calls = 0
        local started = uv.hrtime()
        image.refresh_buffer_previews(bufnr)
        sample.refreshes[#sample.refreshes + 1] = {
          elapsed_ms = (uv.hrtime() - started) / 1e6,
          filesystem_probes = stat_calls,
        }
      end
      samples[#samples + 1] = sample
    end
  end
end, debug.traceback)

uv.fs_stat = stat
image.clear_buffer_previews(bufnr)
vim.api.nvim_buf_delete(bufnr, { force = true })
assert(ok, err)
vim.fn.writefile({ vim.json.encode({ samples = samples }) }, output_path)
