local M = {}

local state = require("lazyagent.logic.state")
local util = require("lazyagent.util")

local uv = vim.loop

local function module_root()
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if src and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  return (src and src:match("(.*/lazyagent/)lua/lazyagent/logic/skills%.lua$")) or ""
end

local function is_list(value)
  return vim.islist and vim.islist(value) or vim.tbl_islist(value)
end

local function ensure_dir(path)
  if not path or path == "" then
    return
  end
  pcall(vim.fn.mkdir, path, "p")
end

local function path_exists(path)
  if not path or path == "" then
    return false
  end
  return uv.fs_lstat(path) ~= nil
end

local function is_directory(path)
  if not path or path == "" then
    return false
  end
  return vim.fn.isdirectory(path) == 1
end

local function is_readable_file(path)
  if not path or path == "" then
    return false
  end
  return vim.fn.filereadable(path) == 1
end

local function is_executable_file(path)
  if not path or path == "" then
    return false
  end
  return vim.fn.executable(path) == 1
end

local function delete_path(path)
  if not path or path == "" then
    return
  end
  if path_exists(path) then
    pcall(vim.fn.delete, path, "rf")
  end
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local ok, decoded = pcall(vim.fn.json_decode, file:read("*a"))
  file:close()
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function write_json(path, value)
  local file = io.open(path, "w")
  if not file then
    return false
  end
  file:write(vim.fn.json_encode(value))
  file:close()
  return true
end

local function hash_text(text)
  local ok, value = pcall(vim.fn.sha256, tostring(text or ""))
  if ok and type(value) == "string" and value ~= "" then
    return value:sub(1, 12)
  end
  return util.sanitize_filename_component(text):sub(1, 48)
end

local function normalize_mode(value)
  local mode = tostring(value or "auto"):lower()
  if mode == "mount" or mode == "flag" or mode == "auto" then
    return mode
  end
  return "auto"
end

local function normalize_override(value)
  if value == nil then
    return {}
  end
  if type(value) == "boolean" then
    return { enabled = value }
  end
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  return {}
end

local function normalize_sources(value)
  if value == nil then
    return {}
  end
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  if type(value) == "table" then
    if is_list(value) then
      local out = {}
      for _, item in ipairs(value) do
        if type(item) == "string" and item ~= "" then
          out[#out + 1] = item
        end
      end
      return out
    end
    if type(value.source) == "string" and value.source ~= "" then
      return { value.source }
    end
    if type(value.sources) == "table" then
      return normalize_sources(value.sources)
    end
  end
  return {}
end

local function resolve_boolean(agent_value, global_value, default_value)
  if agent_value ~= nil then
    return agent_value == true
  end
  if global_value ~= nil then
    return global_value == true
  end
  return default_value == true
end

local function join_path(base, child)
  if not base or base == "" then
    return child
  end
  if not child or child == "" then
    return base
  end
  if child:sub(1, 1) == "/" then
    return child
  end
  if base:sub(-1) == "/" then
    return base .. child
  end
  return base .. "/" .. child
end

local function resolve_path(root_dir, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local expanded = vim.fn.expand(path)
  if expanded == "" then
    return nil
  end
  if expanded:sub(1, 1) ~= "/" then
    expanded = join_path(root_dir, expanded)
  end
  return vim.fn.fnamemodify(expanded, ":p"):gsub("/$", "")
end

local function collect_skill_entries(source_dir)
  local out = {}
  local seen = {}

  local function add_candidate(path)
    if not is_directory(path) or not is_readable_file(join_path(path, "SKILL.md")) then
      return
    end
    local name = vim.fn.fnamemodify(path, ":t")
    if name == "" or seen[name] then
      return
    end
    seen[name] = true
    out[#out + 1] = {
      name = name,
      path = path,
    }
  end

  add_candidate(source_dir)

  local ok, entries = pcall(vim.fn.readdir, source_dir)
  if not ok or type(entries) ~= "table" then
    return out
  end
  table.sort(entries)
  for _, entry in ipairs(entries) do
    add_candidate(join_path(source_dir, entry))
  end

  return out
end

local function sync_symlink(target, link_path)
  local stat = uv.fs_lstat(link_path)
  if stat and stat.type == "link" then
    local existing = uv.fs_readlink(link_path)
    if existing == target then
      return true
    end
  end
  delete_path(link_path)
  local ok, err = pcall(uv.fs_symlink, target, link_path)
  if ok then
    return true
  end
  vim.notify(
    string.format("LazyAgent skills: failed to link %s -> %s (%s)", link_path, target, tostring(err)),
    vim.log.levels.WARN
  )
  return false
end

local function build_aggregate_dir(source_dirs, target_dir)
  delete_path(target_dir)
  ensure_dir(target_dir)

  local skill_entries = {}
  local seen = {}
  for _, source_dir in ipairs(source_dirs) do
    for _, entry in ipairs(collect_skill_entries(source_dir)) do
      if not seen[entry.name] then
        seen[entry.name] = true
        skill_entries[#skill_entries + 1] = entry
      end
    end
  end

  for _, entry in ipairs(skill_entries) do
    sync_symlink(entry.path, join_path(target_dir, entry.name))
  end

  return skill_entries
end

local function sync_mount_dir(aggregate_dir, mount_dir)
  local stat = uv.fs_lstat(mount_dir)
  if stat and stat.type == "link" then
    local target = uv.fs_readlink(mount_dir)
    if target == aggregate_dir then
      return true
    end
    vim.notify(
      "LazyAgent skills: existing symlink at " .. mount_dir .. " is not managed by lazyagent",
      vim.log.levels.WARN
    )
    return false
  end

  ensure_dir(mount_dir)

  local ok, aggregate_entries = pcall(vim.fn.readdir, aggregate_dir)
  if not ok or type(aggregate_entries) ~= "table" then
    return false
  end

  local aggregate_lookup = {}
  for _, entry in ipairs(aggregate_entries) do
    aggregate_lookup[entry] = true
    sync_symlink(join_path(aggregate_dir, entry), join_path(mount_dir, entry))
  end

  local ok_mount, mount_entries = pcall(vim.fn.readdir, mount_dir)
  if ok_mount and type(mount_entries) == "table" then
    for _, entry in ipairs(mount_entries) do
      if not aggregate_lookup[entry] then
        local link_path = join_path(mount_dir, entry)
        local link_stat = uv.fs_lstat(link_path)
        if link_stat and link_stat.type == "link" then
          local target = uv.fs_readlink(link_path)
          if type(target) == "string" and target:sub(1, #aggregate_dir) == aggregate_dir then
            delete_path(link_path)
          end
        end
      end
    end
  end

  return true
end

local function sync_dir_links(source_dir, target_dir, opts)
  opts = type(opts) == "table" and opts or {}
  local exclude = type(opts.exclude) == "table" and opts.exclude or {}

  ensure_dir(target_dir)

  local ok_source, source_entries = pcall(vim.fn.readdir, source_dir)
  if not ok_source or type(source_entries) ~= "table" then
    return false
  end

  local source_lookup = {}
  for _, entry in ipairs(source_entries) do
    if not exclude[entry] then
      source_lookup[entry] = true
      sync_symlink(join_path(source_dir, entry), join_path(target_dir, entry))
    end
  end

  local ok_target, target_entries = pcall(vim.fn.readdir, target_dir)
  if ok_target and type(target_entries) == "table" then
    for _, entry in ipairs(target_entries) do
      if not source_lookup[entry] then
        local link_path = join_path(target_dir, entry)
        local link_stat = uv.fs_lstat(link_path)
        if link_stat and link_stat.type == "link" then
          local target = uv.fs_readlink(link_path)
          if type(target) == "string" and target:sub(1, #source_dir) == source_dir then
            delete_path(link_path)
          end
        end
      end
    end
  end

  return true
end

local function runtime_base_dir()
  local cache_dir = (state.opts and state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  local base = join_path(cache_dir, "skills-runtime")
  ensure_dir(base)
  return base
end

local function cache_agent_dir(agent_name)
  local cache_dir = (state.opts and state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  local dir = join_path(join_path(cache_dir, "agents"), tostring(agent_name or ""):lower())
  ensure_dir(dir)
  return dir
end

local function default_skill_sources()
  local root = module_root()
  if root == "" then
    return {}
  end
  local skills_dir = join_path(root:gsub("/$", ""), "skills")
  if is_directory(skills_dir) then
    return { skills_dir }
  end
  return {}
end

local function default_bin_dir()
  local root = module_root()
  if root == "" then
    return nil
  end
  local bin_dir = join_path(root:gsub("/$", ""), "bin")
  if is_directory(bin_dir) then
    return bin_dir
  end
  return nil
end

local function current_platform_os()
  local uname = uv.os_uname and uv.os_uname() or {}
  local sysname = tostring(uname and uname.sysname or ""):lower()
  if sysname:find("windows", 1, true) then
    return "windows"
  end
  if sysname:find("darwin", 1, true) or sysname:find("mac", 1, true) then
    return "darwin"
  end
  if sysname:find("linux", 1, true) then
    return "linux"
  end
  return sysname ~= "" and sysname or "unknown"
end

local function current_platform_arch()
  local uname = uv.os_uname and uv.os_uname() or {}
  local machine = tostring(uname and uname.machine or ""):lower()
  if machine == "x86_64" or machine == "amd64" then
    return "x64"
  end
  if machine == "arm64" or machine == "aarch64" then
    return "arm64"
  end
  if machine:match("^armv7") then
    return "armv7"
  end
  return machine ~= "" and machine or "unknown"
end

local function platform_tag_aliases()
  local os_name = current_platform_os()
  local arch_name = current_platform_arch()
  local os_aliases = { os_name }
  local arch_aliases = { arch_name }

  if os_name == "darwin" then
    os_aliases[#os_aliases + 1] = "macos"
  elseif os_name == "windows" then
    os_aliases[#os_aliases + 1] = "win32"
  end

  if arch_name == "x64" then
    arch_aliases[#arch_aliases + 1] = "x86_64"
    arch_aliases[#arch_aliases + 1] = "amd64"
  elseif arch_name == "arm64" then
    arch_aliases[#arch_aliases + 1] = "aarch64"
  end

  local tags = {}
  local seen = {}
  for _, os_alias in ipairs(os_aliases) do
    for _, arch_alias in ipairs(arch_aliases) do
      local tag = os_alias .. "-" .. arch_alias
      if not seen[tag] then
        seen[tag] = true
        tags[#tags + 1] = tag
      end
    end
  end
  return tags, os_aliases, arch_aliases
end

local function resolve_platform_bin_dir(bin_dir)
  if not is_directory(bin_dir) then
    return nil
  end

  local tags, os_aliases, arch_aliases = platform_tag_aliases()
  for _, tag in ipairs(tags) do
    local candidate = join_path(bin_dir, tag)
    if is_directory(candidate) then
      return candidate
    end
  end

  for _, os_alias in ipairs(os_aliases) do
    for _, arch_alias in ipairs(arch_aliases) do
      local candidate = join_path(join_path(bin_dir, os_alias), arch_alias)
      if is_directory(candidate) then
        return candidate
      end
    end
  end

  return bin_dir
end

local function resolve_bin_dir_from(root_dir, value)
  local bin_dir = resolve_path(root_dir, value)
  if not bin_dir then
    return nil
  end
  return resolve_platform_bin_dir(bin_dir)
end

local function executable_name_candidates(name)
  if current_platform_os() == "windows" and not name:match("%.exe$") then
    return { name .. ".exe", name }
  end
  return { name }
end

local function default_mount_dir()
  return vim.fn.expand("~/.agents/skills")
end

local function build_binary_env(cfg)
  local env = {}
  local root = module_root()
  if root == "" then
    root = vim.fn.getcwd()
  else
    root = root:gsub("/$", "")
  end
  local bin_dir = resolve_bin_dir_from(root, cfg.bin_dir)
  if not bin_dir or not is_directory(bin_dir) then
    return env, nil
  end

  if type(cfg.bin_env) == "string" and cfg.bin_env ~= "" then
    env[cfg.bin_env] = bin_dir
  end

  return env, bin_dir
end

local function prepare_gemini_hidden_runtime(agent_name, aggregate_dir)
  local runtime_home = cache_agent_dir(agent_name)
  local runtime_gemini_dir = join_path(runtime_home, ".gemini")
  local runtime_agent_skills_dir = join_path(runtime_home, ".agents/skills")
  local user_gemini_dir = vim.fn.expand("~/.gemini")

  ensure_dir(runtime_home)
  ensure_dir(runtime_gemini_dir)

  if is_directory(user_gemini_dir) then
    sync_dir_links(user_gemini_dir, runtime_gemini_dir, {
      exclude = {
        skills = true,
      },
    })
  end

  sync_mount_dir(aggregate_dir, join_path(runtime_gemini_dir, "skills"))
  sync_mount_dir(aggregate_dir, runtime_agent_skills_dir)

  return {
    home_dir = runtime_home,
    user_skills_dir = join_path(runtime_gemini_dir, "skills"),
    agent_skills_dir = runtime_agent_skills_dir,
  }
end

local function resolve_agent_config(agent_name, agent_cfg)
  local global_cfg = type(state.opts and state.opts.skills) == "table" and vim.deepcopy(state.opts.skills) or {}
  local global_agent_cfg = normalize_override(global_cfg.agents and global_cfg.agents[agent_name])
  local local_agent_cfg = normalize_override(agent_cfg and agent_cfg.skills)
  local inherited_enabled = global_cfg.enabled
  local configured_mount_dir = type(global_cfg.mount_dir) == "string" and vim.fn.expand(global_cfg.mount_dir) or global_cfg.mount_dir
  local mount_dir_explicit = local_agent_cfg.mount_dir ~= nil
    or global_agent_cfg.mount_dir ~= nil
    or (configured_mount_dir ~= nil and configured_mount_dir ~= default_mount_dir())

  global_cfg.agents = nil

  local merged = vim.tbl_deep_extend("force", {}, global_cfg, global_agent_cfg, local_agent_cfg)
  if global_agent_cfg.enabled ~= nil then
    inherited_enabled = global_agent_cfg.enabled
  end
  merged.enabled = resolve_boolean(local_agent_cfg.enabled, inherited_enabled, false)
  merged.mode = normalize_mode(merged.mode)
  merged.sources = normalize_sources(merged.sources or merged.source)
  if #merged.sources == 0 then
    merged.sources = default_skill_sources()
  end
  merged.bin_dir = merged.bin_dir or default_bin_dir()
  merged.mount_dir_explicit = mount_dir_explicit
  if merged.bin_env == nil then
    merged.bin_env = "LAZYAGENTBIN"
  end
  merged.mount_dir = merged.mount_dir or default_mount_dir()
  merged.flag = merged.flag
  merged.env = merged.env
  return merged
end

local function resolve_mode(agent_name, cfg)
  local mode = normalize_mode(cfg and cfg.mode)
  if mode == "auto" then
    if agent_name == "Copilot" then
      return "flag"
    end
    return "mount"
  end
  if mode == "flag" and agent_name ~= "Copilot" then
    return "mount"
  end
  return mode
end

local function resolve_source_dirs(root_dir, cfg)
  local out = {}
  local seen = {}
  for _, source in ipairs(cfg.sources or {}) do
    local resolved = resolve_path(root_dir, source)
    if resolved and is_directory(resolved) and not seen[resolved] then
      seen[resolved] = true
      out[#out + 1] = resolved
    end
  end
  return out
end

local function write_copilot_plugin_manifest(plugin_dir)
  ensure_dir(plugin_dir)
  local plugin_path = join_path(plugin_dir, "plugin.json")
  local plugin = read_json(plugin_path) or {}
  plugin.name = plugin.name or "lazyagent-skills"
  plugin.description = plugin.description or "LazyAgent runtime skills"
  plugin.version = plugin.version or "0.0.1"
  plugin.skills = "skills"
  write_json(plugin_path, plugin)
end

function M.apply_command(command, append_args)
  if type(append_args) ~= "table" or vim.tbl_isempty(append_args) then
    return command
  end

  if type(command) == "table" then
    local updated = vim.deepcopy(command)
    vim.list_extend(updated, append_args)
    return updated
  end

  if type(command) == "string" and command ~= "" then
    local parts = { command }
    for _, arg in ipairs(append_args) do
      parts[#parts + 1] = vim.fn.shellescape(tostring(arg))
    end
    return table.concat(parts, " ")
  end

  return command
end

function M.prepare(agent_name, agent_cfg, opts)
  opts = opts or {}
  local root_dir = opts.root_dir or vim.fn.getcwd()
  local cfg = resolve_agent_config(agent_name, agent_cfg)
  if not cfg.enabled then
    return nil
  end

  local source_dirs = resolve_source_dirs(root_dir, cfg)
  if vim.tbl_isempty(source_dirs) then
    return nil
  end

  local source_key = table.concat(source_dirs, "\n")
  local base_dir = join_path(runtime_base_dir(), hash_text(root_dir .. "\0" .. source_key))
  local mode = resolve_mode(agent_name, cfg)
  local env, bin_dir = build_binary_env(cfg)

  if mode == "flag" and agent_name == "Copilot" then
    local plugin_dir = join_path(base_dir, "copilot-plugin")
    local aggregate_dir = join_path(plugin_dir, "skills")
    local entries = build_aggregate_dir(source_dirs, aggregate_dir)
    if vim.tbl_isempty(entries) then
      return nil
    end
    write_copilot_plugin_manifest(plugin_dir)

    local append_args = {}
    if cfg.flag ~= false then
      append_args = {
        type(cfg.flag) == "string" and cfg.flag or "--plugin-dir",
        plugin_dir,
      }
    end

    if type(cfg.env) == "string" and cfg.env ~= "" then
      env[cfg.env] = aggregate_dir
    end

    return {
      mode = "flag",
      env = env,
      append_args = append_args,
      root_dir = root_dir,
      source_dirs = source_dirs,
      aggregate_dir = aggregate_dir,
      plugin_dir = plugin_dir,
      bin_dir = bin_dir,
    }
  end

  local aggregate_dir = join_path(base_dir, "mount")
  local entries = build_aggregate_dir(source_dirs, aggregate_dir)
  if vim.tbl_isempty(entries) then
    return nil
  end

  if agent_name == "Gemini" and not cfg.mount_dir_explicit then
    local runtime = prepare_gemini_hidden_runtime(agent_name, aggregate_dir)
    env.GEMINI_CLI_HOME = runtime.home_dir
    return {
      mode = "mount",
      env = env,
      append_args = {},
      root_dir = root_dir,
      source_dirs = source_dirs,
      aggregate_dir = aggregate_dir,
      mount_dir = nil,
      bin_dir = bin_dir,
      gemini_home_dir = runtime.home_dir,
      gemini_skills_dir = runtime.user_skills_dir,
    }
  end

  local mount_dir = resolve_path(root_dir, cfg.mount_dir)
  if mount_dir then
    sync_mount_dir(aggregate_dir, mount_dir)
  end

  return {
    mode = "mount",
    env = env,
    append_args = {},
    root_dir = root_dir,
    source_dirs = source_dirs,
    aggregate_dir = aggregate_dir,
    mount_dir = mount_dir,
    bin_dir = bin_dir,
  }
end

function M.resolve_bin_dir()
  local cfg = type(state.opts and state.opts.skills) == "table" and vim.deepcopy(state.opts.skills) or {}
  local root = module_root()
  if root == "" then
    root = vim.fn.getcwd()
  else
    root = root:gsub("/$", "")
  end
  local configured = cfg.bin_dir or default_bin_dir()
  local bin_dir = resolve_bin_dir_from(root, configured)
  if bin_dir and is_directory(bin_dir) then
    return bin_dir
  end
  return nil
end

function M.find_binary(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local bin_dir = M.resolve_bin_dir()
  if not bin_dir then
    return nil
  end
  for _, candidate in ipairs(executable_name_candidates(name)) do
    local path = join_path(bin_dir, candidate)
    if is_executable_file(path) then
      return path
    end
  end
  return nil
end

return M
