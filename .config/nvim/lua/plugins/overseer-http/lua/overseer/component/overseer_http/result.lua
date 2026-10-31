local STATUS = require('overseer.constants').STATUS

---@type overseer.ComponentFileDefinition
return {
  desc = 'Capture HTTP response and set status from curl exit and HTTP code',
  editable = false,
  constructor = function()
    return {
      on_output_lines = function(self, _, lines)
        for _, line in ipairs(lines) do
          local code = line:match('^%s*(%d%d%d)%s*$')
          if code then self.status_code = tonumber(code) end
        end
      end,
      on_reset = function(self, task)
        self.status_code = nil
        local info = task.metadata.overseer_http
        info.status_code = nil
        info.curl_exit = nil
        task.name = info.title
        vim.fn.delete(info.paths.headers)
        vim.fn.delete(info.paths.body)
      end,
      on_exit = function(self, task, exit_code)
        local info = task.metadata.overseer_http
        if info.request.method == 'HEAD' then
          -- curl --head writes response headers to its output file as well.
          local fd = vim.uv.fs_open(info.paths.body, 'w', 384)
          if fd then vim.uv.fs_close(fd) end
        end
        info.curl_exit = exit_code
        info.status_code = self.status_code
        if exit_code == 0 and self.status_code then
          task.name = string.format('%s [%d]', info.title, self.status_code)
        else
          task.name = string.format('%s [curl %d]', info.title, exit_code)
        end
        local success = exit_code == 0 and self.status_code ~= nil
          and require('overseer_http').config.success_status(self.status_code)
        if exit_code == 0 and self.status_code then
          require('overseer_http.result').show_default(task)
        end
        task:finalize(success and STATUS.SUCCESS or STATUS.FAILURE)
      end,
      on_pre_result = function(_, task)
        local info = task.metadata.overseer_http
        return { http = {
          status_code = info.status_code,
          curl_exit = info.curl_exit,
          headers_path = info.paths.headers,
          body_path = info.paths.body,
        } }
      end,
      on_dispose = function(_, task)
        vim.fn.delete(task.metadata.overseer_http.paths.dir, 'rf')
      end,
    }
  end,
}
