local M = {}

local function component(value)
  return tostring(value or "unknown"):gsub("[^%w._-]", "_")
end

function M.platform(os_name, arch)
  os_name = (os_name or jit.os):lower()
  arch = (arch or jit.arch):lower()
  local os_map = { osx = "darwin", macos = "darwin", linux = "linux", windows = "windows" }
  local arch_map = { x64 = "x86_64", amd64 = "x86_64", arm64 = "aarch64" }
  local normalized_os = os_map[os_name]
  local normalized_arch = arch_map[arch]
  return normalized_os and normalized_arch and (normalized_os .. "-" .. normalized_arch) or nil
end

function M.archive_kind(url)
  local path = tostring(url or ""):lower():match("^[^?]+") or ""
  if path:match("%.tar%.gz$") or path:match("%.tgz$") then return "tar.gz" end
  if path:match("%.zip$") then return "zip" end
  return "raw"
end

function M.validate_entries(output)
  for _, entry in ipairs(vim.split(output or "", "\n", { plain = true, trimempty = true })) do
    entry = entry:gsub("\\", "/")
    if entry:sub(1, 1) == "/" or entry:match("^%a:/") then
      return nil, "archive contains an absolute path"
    end
    for part in entry:gmatch("[^/]+") do
      if part == ".." then return nil, "archive contains a parent path" end
    end
  end
  return true
end

function M.plan(agent, root, platform)
  platform = platform or M.platform()
  if not platform then return nil, "unsupported operating system or architecture" end
  local binary = agent and agent.distribution and agent.distribution.binary
  local spec = type(binary) == "table" and binary[platform] or nil
  if type(spec) ~= "table" then return nil, "no binary distribution for " .. platform end
  if type(spec.archive) ~= "string" or not spec.archive:match("^https://") then
    return nil, "binary archive must use HTTPS"
  end
  local relative_cmd = tostring(spec.cmd or ""):gsub("\\", "/"):gsub("^%./", "")
  if relative_cmd == "" or relative_cmd:sub(1, 1) == "/" or relative_cmd:match("^%a:/") then
    return nil, "binary command must be a relative path"
  end
  for part in relative_cmd:gmatch("[^/]+") do
    if part == ".." then return nil, "binary command escapes install directory" end
  end
  root = root or (vim.fn.stdpath("data") .. "/lazyagent/acp/registry/agents")
  local target = table.concat({ root, component(agent.id), component(agent.version), platform }, "/")
  return {
    archive = spec.archive,
    args = vim.deepcopy(spec.args or {}),
    env = vim.deepcopy(spec.env or {}),
    sha256 = spec.sha256 and spec.sha256:lower() or nil,
    kind = M.archive_kind(spec.archive),
    platform = platform,
    relative_cmd = relative_cmd,
    target = target,
  }
end

local function run(command, done)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function() done(result) end)
  end)
end

local function checksum_command(path)
  if vim.fn.executable("sha256sum") == 1 then return { "sha256sum", path } end
  if vim.fn.executable("shasum") == 1 then return { "shasum", "-a", "256", path } end
  if vim.fn.executable("certutil") == 1 then return { "certutil", "-hashfile", path, "SHA256" } end
end

function M.parse_checksum(output)
  for _, line in ipairs(vim.split((output or ""):lower(), "\n", { plain = true })) do
    local first = line:match("^%s*([0-9a-f]+)")
    if first and #first >= 64 then return first:sub(1, 64) end
    local compact = line:gsub("%s", "")
    if #compact == 64 and compact:match("^[0-9a-f]+$") then return compact end
  end
end

local function verify_checksum(path, expected, done)
  if not expected then done(true); return end
  local command = checksum_command(path)
  if not command then done(nil, "no SHA-256 verifier is available"); return end
  run(command, function(result)
    if result.code ~= 0 then done(nil, vim.trim(result.stderr or "checksum failed")); return end
    local actual = M.parse_checksum(result.stdout)
    if not actual then done(nil, "could not parse SHA-256 checksum"); return end
    done(actual == expected, actual == expected and nil or "binary archive checksum mismatch")
  end)
end

local function archive_commands(plan, download)
  if plan.kind == "tar.gz" then
    return { "tar", "-tzf", download }, { "tar", "-xzf", download, "-C", plan.staging, "--no-same-owner", "--no-same-permissions" }
  end
  if plan.kind == "zip" then
    return { "unzip", "-Z1", download }, { "unzip", "-q", download, "-d", plan.staging }
  end
end

function M.install(agent, done, opts)
  done = done or function() end
  opts = opts or {}
  local plan, plan_err = M.plan(agent, opts.root, opts.platform)
  if not plan then done(nil, plan_err); return end
  if not plan.sha256 and not opts.allow_unverified then
    done(nil, "binary archive has no sha256; confirmation required")
    return
  end
  if vim.fn.executable("curl") ~= 1 then done(nil, "curl is required for binary installation"); return end

  plan.staging = plan.target .. ".tmp-" .. tostring(vim.uv.os_getpid())
  local download = plan.staging .. ".download"
  vim.fn.delete(plan.staging, "rf")
  vim.fn.delete(download)
  vim.fn.mkdir(plan.staging, "p")

  local function finish(launcher, err)
    vim.fn.delete(download)
    if not launcher then vim.fn.delete(plan.staging, "rf") end
    done(launcher, err)
  end

  local download_target = plan.kind == "raw" and (plan.staging .. "/" .. plan.relative_cmd) or download
  vim.fn.mkdir(vim.fs.dirname(download_target), "p")
  run({ "curl", "-fL", "--max-time", "120", "-o", download_target, plan.archive }, function(result)
    if result.code ~= 0 then finish(nil, vim.trim(result.stderr or "binary download failed")); return end
    verify_checksum(download_target, plan.sha256, function(valid, checksum_err)
      if not valid then finish(nil, checksum_err); return end

      local function activate()
        local command = plan.staging .. "/" .. plan.relative_cmd
        local stat = vim.uv.fs_stat(command)
        if not stat or stat.type ~= "file" then finish(nil, "binary command is missing from archive"); return end
        vim.uv.fs_chmod(command, 493)
        local real_command = vim.uv.fs_realpath(command)
        local real_staging = vim.uv.fs_realpath(plan.staging)
        if not real_command or not real_staging or real_command:sub(1, #real_staging + 1) ~= real_staging .. "/" then
          finish(nil, "binary command resolves outside install directory")
          return
        end
        vim.fn.mkdir(vim.fs.dirname(plan.target), "p")
        vim.fn.delete(plan.target, "rf")
        local renamed, rename_err = vim.uv.fs_rename(plan.staging, plan.target)
        if not renamed then finish(nil, rename_err); return end
        finish({
          kind = "binary",
          command = vim.list_extend({ plan.target .. "/" .. plan.relative_cmd }, plan.args),
          env = plan.env,
          platform = plan.platform,
          verified = plan.sha256 ~= nil,
        })
      end

      local list_command, extract_command = archive_commands(plan, download_target)
      if not list_command then activate(); return end
      if vim.fn.executable(list_command[1]) ~= 1 then finish(nil, list_command[1] .. " is required for binary installation"); return end
      run(list_command, function(list_result)
        if list_result.code ~= 0 then finish(nil, vim.trim(list_result.stderr or "archive listing failed")); return end
        local safe, safe_err = M.validate_entries(list_result.stdout)
        if not safe then finish(nil, safe_err); return end
        run(extract_command, function(extract_result)
          if extract_result.code ~= 0 then finish(nil, vim.trim(extract_result.stderr or "archive extraction failed")); return end
          activate()
        end)
      end)
    end)
  end)
end

return M
