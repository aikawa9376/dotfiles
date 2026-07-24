local M = {}

local acp_logic = require("lazyagent.logic.acp")
local cache_logic = require("lazyagent.logic.cache")
local state = require("lazyagent.logic.state")

local uv = vim.uv or vim.loop
local drop_processing = {}
local paste_hook_installed = false

local MIME_EXTENSIONS = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/jpg"] = "jpg",
  ["image/webp"] = "webp",
  ["image/gif"] = "gif",
  ["image/bmp"] = "bmp",
  ["image/tiff"] = "tiff",
  ["image/svg+xml"] = "svg",
  ["image/x-png"] = "png",
  ["image/x-bmp"] = "bmp",
  ["image/x-ms-bmp"] = "bmp",
}

local MIME_CANDIDATES = {
  "image/png",
  "image/jpeg",
  "image/jpg",
  "image/webp",
  "image/gif",
  "image/bmp",
  "image/tiff",
  "image/svg+xml",
  "image/x-png",
  "image/x-bmp",
  "image/x-ms-bmp",
}

local IMAGE_FILE_EXTENSIONS = {
  png = true,
  jpg = true,
  jpeg = true,
  webp = true,
  gif = true,
  bmp = true,
  tif = true,
  tiff = true,
  svg = true,
}

local IMAGE_EXTENSION_SUFFIXES = {
  ".png",
  ".jpg",
  ".jpeg",
  ".webp",
  ".gif",
  ".bmp",
  ".tif",
  ".tiff",
  ".svg",
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "lazyagent image paste" })
end

local function image_paste_opts()
  return (state.opts and state.opts.image_paste) or {}
end

local function buffer_var(bufnr, name)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  if ok then
    return value
  end
  return nil
end

local function is_scratch_buffer(bufnr)
  return bufnr
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.b[bufnr]
    and vim.b[bufnr].lazyagent_is_scratch == true
end

local function is_acp_transcript_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and buffer_var(bufnr, "lazyagent_acp_transcript") == true
end

local function file_exists(path)
  local stat = path and uv.fs_stat(path) or nil
  return stat and stat.type == "file" and (stat.size or 0) > 0
end

local function ensure_dir(path)
  if type(path) ~= "string" or path == "" then
    return nil, "image_paste.dir is empty"
  end
  local ok = vim.fn.mkdir(path, "p")
  if ok == 0 and vim.fn.isdirectory(path) ~= 1 then
    return nil, "failed to create directory: " .. path
  end
  if vim.fn.isdirectory(path) ~= 1 then
    return nil, "directory is not available: " .. path
  end
  return path
end

local function write_binary_file(path, data)
  local fd, open_err = uv.fs_open(path, "w", 420)
  if not fd then
    return nil, open_err or ("failed to open " .. path)
  end

  local ok, write_err = pcall(uv.fs_write, fd, data, 0)
  uv.fs_close(fd)
  if not ok then
    return nil, write_err or ("failed to write " .. path)
  end
  return true
end

local function read_binary_file(path)
  local fd, open_err = uv.fs_open(path, "r", 420)
  if not fd then
    return nil, open_err or ("failed to open " .. path)
  end

  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err or ("failed to stat " .. path)
  end

  local data, read_err = uv.fs_read(fd, stat.size or 0, 0)
  uv.fs_close(fd)
  if data == nil then
    return nil, read_err or ("failed to read " .. path)
  end
  return data
end

local function sanitize_filename_component(text)
  if text == nil then
    return ""
  end
  return tostring(text):gsub("[^%w-_]+", "-")
end

local function load_snacks()
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks and Snacks.image and Snacks.image.placement then
    return Snacks
  end

  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy and lazy and type(lazy.load) == "function" then
    pcall(lazy.load, { plugins = { "snacks.nvim" } })
  end

  ok, Snacks = pcall(require, "snacks")
  if ok and Snacks and Snacks.image and Snacks.image.placement then
    return Snacks
  end
  return nil
end

local function load_snacks_picker()
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks and Snacks.picker and type(Snacks.picker.files) == "function" then
    return Snacks
  end

  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy and lazy and type(lazy.load) == "function" then
    pcall(lazy.load, { plugins = { "snacks.nvim" } })
  end

  ok, Snacks = pcall(require, "snacks")
  if ok and Snacks and Snacks.picker and type(Snacks.picker.files) == "function" then
    return Snacks
  end
  return nil
end

local function system_binary(cmd)
  local result = vim.system(cmd, { text = false }):wait()
  if result.code ~= 0 then
    local stderr = result.stderr and vim.trim(result.stderr) or ""
    return nil, stderr ~= "" and stderr or ("command failed: " .. table.concat(cmd, " "))
  end
  if not result.stdout or result.stdout == "" then
    return nil, "clipboard does not contain image data"
  end
  return result.stdout
end

local function system_text(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return result.stdout or ""
end

local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function is_macos()
  return vim.fn.has("macunix") == 1
end

local function powershell_executable()
  if not is_windows() then
    return nil
  end

  for _, candidate in ipairs({ "powershell", "powershell.exe", "pwsh" }) do
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

local function xclip_mime_candidates()
  local seen = {}
  local ordered = {}
  local function add(mime)
    mime = tostring(mime or ""):lower()
    if mime == "" or seen[mime] or MIME_EXTENSIONS[mime] == nil then
      return
    end
    seen[mime] = true
    ordered[#ordered + 1] = mime
  end

  local targets = system_text({ "xclip", "-selection", "clipboard", "-o", "-t", "TARGETS" }) or ""
  for line in targets:gmatch("[^\r\n]+") do
    if line:match("^image/") then
      add(line)
    end
  end
  for _, mime in ipairs(MIME_CANDIDATES) do
    add(mime)
  end
  return ordered
end

local function unique_stem()
  local stamp = os.date("%Y%m%d-%H%M%S")
  local tail = tostring(uv.hrtime()):sub(-6)
  return "pasted-image-" .. stamp .. "-" .. tail
end

local function image_dir_layout()
  local value = image_paste_opts().dir_layout
  if type(value) == "string" and value ~= "" then
    return value
  end
  return "conversation"
end

local function image_storage_root()
  local cfg = image_paste_opts()
  if type(cfg.dir) == "string" and cfg.dir ~= "" then
    return cfg.dir
  end
  if image_dir_layout() == "flat" then
    return vim.fn.stdpath("cache") .. "/lazyagent/images"
  end
  return cache_logic.get_conversation_dir()
end

local function image_file_extension(path)
  local ext = vim.fn.fnamemodify(path or "", ":e")
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function image_extension_from_content_type(content_type)
  local mime = tostring(content_type or ""):match("^%s*([^;]+)")
  if not mime then
    return ""
  end
  mime = vim.trim(mime):lower()
  return MIME_EXTENSIONS[mime] or ""
end

local function url_decode(text)
  local decoded = tostring(text or ""):gsub("+", " ")
  decoded = decoded:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return decoded
end

local function image_extension_from_text(text)
  local lower = tostring(text or ""):lower()
  for _, suffix in ipairs(IMAGE_EXTENSION_SUFFIXES) do
    local init = 1
    while true do
      local start_pos, end_pos = lower:find(suffix, init, true)
      if not start_pos then
        break
      end
      local next_char = lower:sub(end_pos + 1, end_pos + 1)
      if next_char == "" or next_char:match("[%?%#\"'`<>)%]%}%s]") then
        return suffix:sub(2)
      end
      init = start_pos + 1
    end
  end
  return ""
end

local function image_extension_from_url(url)
  local text = tostring(url or "")
  local stripped = text:gsub("[?#].*$", "")
  local ext = image_extension_from_text(stripped)
  if ext ~= "" then
    return ext
  end

  local query = text:match("%?(.*)") or ""
  if query ~= "" then
    for part in query:gmatch("[^&]+") do
      local key, value = part:match("^([^=]+)=(.*)$")
      if key then
        key = url_decode(key):lower()
        value = url_decode(value)
        if key == "response-content-type" or key == "content-type" or key == "mime" or key == "type" then
          ext = image_extension_from_content_type(value)
          if ext ~= "" then
            return ext
          end
        end
        if key == "response-content-disposition" or key == "content-disposition" or key == "filename" or key == "file" then
          ext = image_extension_from_text(value)
          if ext ~= "" then
            return ext
          end
        end
      end
    end
  end

  return ""
end

local function is_image_file(path)
  return file_exists(path) and IMAGE_FILE_EXTENSIONS[image_file_extension(path)] == true
end

local function build_destination(dir, ext)
  local filename = unique_stem() .. "." .. ext
  return vim.fs.joinpath(dir, filename)
end

local function path_scope_name(path)
  local stem = vim.fn.fnamemodify(path or "", ":t:r")
  stem = sanitize_filename_component(stem)
  if stem == "" then
    return nil
  end
  return stem
end

local function fallback_scope_name(bufnr)
  local source_bufnr = buffer_var(bufnr, "lazyagent_source_bufnr")
  if type(source_bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(source_bufnr) then
    source_bufnr = bufnr
  end

  local parts = {}
  local prefix = cache_logic.build_cache_prefix(source_bufnr or 0):gsub("%-+$", "")
  if prefix ~= "" then
    parts[#parts + 1] = prefix
  end

  local agent_name = buffer_var(bufnr, "lazyagent_acp_agent") or buffer_var(bufnr, "lazyagent_agent")
  local sanitized_agent = sanitize_filename_component(agent_name)
  if sanitized_agent ~= "" then
    parts[#parts + 1] = sanitized_agent
  end

  if is_acp_transcript_buffer(bufnr) then
    parts[#parts + 1] = "acp"
  elseif is_scratch_buffer(bufnr) then
    parts[#parts + 1] = "scratch"
  else
    parts[#parts + 1] = "buffer"
  end

  local session_name = sanitize_filename_component(state.current_session_name)
  if session_name ~= "" then
    parts[#parts + 1] = session_name
  else
    parts[#parts + 1] = tostring(vim.fn.getpid())
    parts[#parts + 1] = tostring(bufnr)
  end

  return table.concat(parts, "-")
end

local function resolve_image_dir(bufnr)
  local root, root_err = ensure_dir(image_storage_root())
  if not root then
    return nil, root_err
  end

  if image_dir_layout() == "flat" then
    local cached = buffer_var(bufnr, "lazyagent_image_dir")
    if type(cached) == "string" and cached ~= "" and vim.fn.isdirectory(cached) == 1 then
      return cached
    end
    vim.b[bufnr].lazyagent_image_dir = root
    return root
  end

  local scope_name = nil
  local candidate_paths = {
    buffer_var(bufnr, "lazyagent_conversation_log_path"),
    buffer_var(bufnr, "lazyagent_acp_transcript_path"),
  }

  local agent_name = buffer_var(bufnr, "lazyagent_acp_agent") or buffer_var(bufnr, "lazyagent_agent")
  local session = agent_name and state.sessions and state.sessions[agent_name] or nil
  if session then
    candidate_paths[#candidate_paths + 1] = session.last_save_path
    candidate_paths[#candidate_paths + 1] = session.transcript_path
  end

  for _, path in ipairs(candidate_paths) do
    if type(path) == "string" and path ~= "" then
      scope_name = path_scope_name(path)
      if scope_name then
        break
      end
    end
  end

  if not scope_name then
    scope_name = fallback_scope_name(bufnr)
  end

  local desired = vim.fs.joinpath(root, scope_name, "images")
  local cached = buffer_var(bufnr, "lazyagent_image_dir")
  if type(cached) == "string" and cached == desired and vim.fn.isdirectory(cached) == 1 then
    return cached
  end

  local dir, dir_err = ensure_dir(desired)
  if not dir then
    return nil, dir_err
  end

  vim.b[bufnr].lazyagent_image_dir = dir
  return dir
end

local function copy_file(source_path, destination_path)
  local ok, copied = pcall(uv.fs_copyfile, source_path, destination_path)
  if ok and copied then
    return true
  end

  local data, read_err = read_binary_file(source_path)
  if not data then
    return nil, read_err
  end
  return write_binary_file(destination_path, data)
end

local function import_image_file(dir, source_path)
  local source_dir = vim.fs.dirname(source_path)
  if source_dir and vim.fs.normalize(source_dir) == vim.fs.normalize(dir) then
    return source_path
  end

  local ext = image_file_extension(source_path)
  if ext == "" then
    ext = "png"
  end

  local destination_path = build_destination(dir, ext)
  local ok, copy_err = copy_file(source_path, destination_path)
  if ok then
    return destination_path
  end

  if file_exists(destination_path) then
    uv.fs_unlink(destination_path)
  end
  return nil, copy_err
end

local function strip_wrapping_delimiters(text)
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  local closing = {
    ['"'] = '"',
    ["'"] = "'",
    ["`"] = "`",
    ["<"] = ">",
  }
  if closing[first] and closing[first] == last then
    return text:sub(2, -2)
  end
  return text
end

local function normalize_image_path_text(text)
  local candidate = vim.trim(text or "")
  if candidate == "" then
    return nil
  end

  candidate = candidate:gsub("^%[image%]%s*", "")
  if candidate:sub(1, 1) == "@" then
    candidate = vim.trim(candidate:sub(2))
  end
  candidate = strip_wrapping_delimiters(candidate)
  candidate = candidate:gsub("\\ ", " ")

  if candidate:match("^file://") then
    local ok, fname = pcall(vim.uri_to_fname, candidate)
    if ok and type(fname) == "string" and fname ~= "" then
      candidate = fname
    end
  end

  local ok_expand, expanded = pcall(vim.fn.expand, candidate)
  if ok_expand and type(expanded) == "string" and expanded ~= "" then
    candidate = expanded
  end
  local ok_normalize, normalized = pcall(vim.fs.normalize, candidate)
  if ok_normalize and type(normalized) == "string" and normalized ~= "" then
    candidate = normalized
  end

  if not is_image_file(candidate) then
    return nil
  end
  return candidate
end

local function normalize_image_url_text(text)
  local candidate = vim.trim(text or "")
  if candidate == "" then
    return nil
  end

  if candidate:sub(1, 1) == "@" then
    candidate = vim.trim(candidate:sub(2))
  end
  candidate = strip_wrapping_delimiters(candidate)
  if not candidate:match("^https?://") then
    return nil
  end

  if image_extension_from_url(candidate) == "" then
    return nil
  end

  return candidate
end

local function normalize_explicit_image_url(text)
  local candidate = strip_wrapping_delimiters(vim.trim(text or ""))
  if candidate == "" or not candidate:match("^https?://") or candidate:match("%s") then
    return nil
  end
  return candidate
end

local function line_candidate_starts(line, ext_start)
  local starts = {}

  local function add(pos)
    if type(pos) ~= "number" or pos < 1 or pos > ext_start then
      return
    end
    local prefix = line:sub(pos, ext_start)
    if
      line:sub(pos, pos) == "@"
      or line:sub(pos - 1, pos - 1) == "@"
      or prefix:match("^%[image%]%s*@")
    then
      return
    end
    starts[pos] = true
  end

  local idx = 1
  local lower = line:lower()
  while true do
    local pos = lower:find("https://", idx, true)
    if not pos or pos > ext_start then
      break
    end
    add(pos)
    idx = pos + 1
  end

  idx = 1
  while true do
    local pos = lower:find("http://", idx, true)
    if not pos or pos > ext_start then
      break
    end
    add(pos)
    idx = pos + 1
  end

  idx = 1
  while true do
    local pos = lower:find("file://", idx, true)
    if not pos or pos > ext_start then
      break
    end
    add(pos)
    idx = pos + 1
  end

  idx = 1
  while true do
    local pos = line:find("/", idx, true)
    if not pos or pos > ext_start then
      break
    end
    add(pos)
    idx = pos + 1
  end

  idx = 1
  while true do
    local pos = line:find("~", idx, true)
    if not pos or pos > ext_start then
      break
    end
    local next_char = line:sub(pos + 1, pos + 1)
    if next_char == "/" then
      add(pos)
    end
    idx = pos + 1
  end

  add(1)
  for pos = 2, ext_start do
    if line:sub(pos - 1, pos - 1):match("[%s\"'`<%(%[%{]") then
      add(pos)
    end
  end

  local ordered = {}
  for pos in pairs(starts) do
    ordered[#ordered + 1] = pos
  end
  table.sort(ordered)
  return ordered
end

local function preview_line_candidate_starts(line, ext_start)
  local starts = {}
  for _, pos in ipairs(line_candidate_starts(line, ext_start)) do
    starts[pos] = true
  end

  local idx = 1
  while true do
    local pos = line:find("@", idx, true)
    if not pos or pos > ext_start then
      break
    end

    starts[pos] = true
    idx = pos + 1
  end

  local ordered = {}
  for pos in pairs(starts) do
    ordered[#ordered + 1] = pos
  end
  table.sort(ordered)
  return ordered
end

local function url_candidate_starts(line)
  local starts = {}
  local lower = line:lower()

  local function collect(prefix)
    local idx = 1
    while true do
      local pos = lower:find(prefix, idx, true)
      if not pos then
        break
      end
      if line:sub(pos - 1, pos - 1) ~= "@" then
        starts[#starts + 1] = pos
      end
      idx = pos + 1
    end
  end

  collect("https://")
  collect("http://")
  table.sort(starts)
  return starts
end

local function preview_url_candidate_starts(line)
  local starts = {}
  for _, pos in ipairs(url_candidate_starts(line)) do
    starts[pos] = true
  end

  local lower = line:lower()
  local idx = 1
  while true do
    local pos = line:find("@", idx, true)
    if not pos then
      break
    end
    local rest = lower:sub(pos + 1)
    if rest:sub(1, 7) == "http://" or rest:sub(1, 8) == "https://" then
      starts[pos] = true
    end
    idx = pos + 1
  end

  local ordered = {}
  for pos in pairs(starts) do
    ordered[#ordered + 1] = pos
  end
  table.sort(ordered)
  return ordered
end

local function candidate_end_position(line, ext_end)
  local pos = ext_end
  while pos < #line do
    local ch = line:sub(pos + 1, pos + 1)
    if ch:match("[%s\"'`<>%]%)}]") then
      break
    end
    pos = pos + 1
  end
  return pos
end

local function extract_image_reference(line, opts)
  opts = opts or {}
  local path_starts = opts.include_managed_refs and preview_line_candidate_starts or line_candidate_starts
  local url_starts = opts.include_managed_refs and preview_url_candidate_starts or url_candidate_starts
  local lower = line:lower()
  local best = nil

  for _, suffix in ipairs(IMAGE_EXTENSION_SUFFIXES) do
    local init = 1
    while true do
      local ext_start, ext_end = lower:find(suffix, init, true)
      if not ext_start then
        break
      end

      local candidate_stop = candidate_end_position(line, ext_end)
      for _, start_pos in ipairs(path_starts(line, ext_start)) do
        local raw = line:sub(start_pos, candidate_stop)
        local source_path = normalize_image_path_text(raw)
        local source_url = source_path == nil and normalize_image_url_text(raw) or nil
        if source_path or source_url then
          local candidate = {
            start_col = start_pos,
            end_col = candidate_stop,
            raw = raw,
            source_path = source_path,
            source_url = source_url,
            is_remote = source_url ~= nil,
          }
          if not best or #candidate.raw > #best.raw then
            best = candidate
          end
        end
      end

      init = ext_start + 1
    end
  end

  if best == nil then
    for _, start_pos in ipairs(url_starts(line)) do
      local candidate_stop = candidate_end_position(line, start_pos + 7)
      local raw = line:sub(start_pos, candidate_stop)
      local source_url = normalize_image_url_text(raw)
      if source_url then
        local candidate = {
          start_col = start_pos,
          end_col = candidate_stop,
          raw = raw,
          source_path = nil,
          source_url = source_url,
          is_remote = true,
        }
        if not best or #candidate.raw > #best.raw then
          best = candidate
        end
      end
    end
  end

  return best
end

local function capture_from_pngpaste(dir)
  if vim.fn.executable("pngpaste") ~= 1 then
    return nil
  end

  local path = build_destination(dir, "png")
  local result = vim.system({ "pngpaste", path }, { text = false }):wait()
  if result.code == 0 and file_exists(path) then
    return path, "pngpaste"
  end
  if file_exists(path) then
    uv.fs_unlink(path)
  end
  return nil, (result.stderr and vim.trim(result.stderr)) or "pngpaste failed"
end

local function capture_from_osascript_format(path, image_class)
  local cmd = {
    "osascript",
    "-e",
    "on run argv",
    "-e",
    "set outFile to POSIX file (item 1 of argv)",
    "-e",
    "set fileRef to missing value",
    "-e",
    "try",
    "-e",
    "set imageData to the clipboard as " .. image_class,
    "-e",
    "set fileRef to open for access outFile with write permission",
    "-e",
    "set eof fileRef to 0",
    "-e",
    "write imageData to fileRef",
    "-e",
    "close access fileRef",
    "-e",
    "return POSIX path of outFile",
    "-e",
    "on error errMsg number errNum",
    "-e",
    "try",
    "-e",
    "if fileRef is not missing value then close access fileRef",
    "-e",
    "end try",
    "-e",
    "error errMsg number errNum",
    "-e",
    "end try",
    "-e",
    "end run",
    path,
  }

  local result = vim.system(cmd, { text = true }):wait()
  if result.code == 0 and file_exists(path) then
    return path
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end
  local stderr = result.stderr and vim.trim(result.stderr) or ""
  local stdout = result.stdout and vim.trim(result.stdout) or ""
  return nil, stderr ~= "" and stderr or stdout ~= "" and stdout or "osascript failed"
end

local function capture_from_osascript(dir)
  if vim.fn.executable("osascript") ~= 1 then
    return nil
  end

  local formats = {
    { ext = "png", image_class = "«class PNGf»" },
    { ext = "tiff", image_class = "TIFF picture" },
  }

  local last_err = nil
  for _, format in ipairs(formats) do
    local path = build_destination(dir, format.ext)
    local captured_path, err = capture_from_osascript_format(path, format.image_class)
    if captured_path then
      return captured_path, "osascript"
    end
    last_err = err
  end

  return nil, last_err
end

local function download_image_url(dir, url)
  if vim.fn.executable("curl") ~= 1 then
    return nil, "downloading dropped image URLs requires curl"
  end

  local ext = image_extension_from_url(url)
  local provisional_ext = ext ~= "" and ext or "download"
  local path = build_destination(dir, provisional_ext)
  local result = vim.system({
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--write-out",
    "\n%{content_type}",
    "--output",
    path,
    url,
  }, { text = true }):wait()

  if result.code == 0 and file_exists(path) then
    local content_type = vim.trim(result.stdout or "")
    local response_ext = image_extension_from_content_type(content_type)
    local response_mime = tostring(content_type):match("^%s*([^;]+)")
    response_mime = response_mime and vim.trim(response_mime):lower() or ""
    local generic_binary = response_mime == "application/octet-stream" or response_mime == "binary/octet-stream"
    if response_mime ~= "" and response_ext == "" and not (generic_binary and ext ~= "") then
      uv.fs_unlink(path)
      return nil, "URL returned an unsupported image content type: " .. response_mime
    end
    ext = response_ext ~= "" and response_ext or ext
    if ext == "" then
      uv.fs_unlink(path)
      return nil, "URL did not provide a supported image extension or content type"
    end

    if provisional_ext ~= ext then
      local renamed = build_destination(dir, ext)
      local ok, rename_err = uv.fs_rename(path, renamed)
      if not ok then
        if file_exists(path) then
          uv.fs_unlink(path)
        end
        return nil, rename_err or "failed to finalize downloaded image"
      end
      path = renamed
    end
    return path
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end
  local stderr = result.stderr and vim.trim(result.stderr) or ""
  return nil, stderr ~= "" and stderr or "failed to download dropped image URL"
end

local function capture_from_binary_command(dir, cmd)
  local mime_candidates = MIME_CANDIDATES
  if cmd[1] == "xclip" then
    mime_candidates = xclip_mime_candidates()
  end

  local last_err = nil
  for _, mime in ipairs(mime_candidates) do
    local data, err = system_binary(vim.list_extend(vim.deepcopy(cmd), { mime }))
    if data then
      local ext = MIME_EXTENSIONS[mime] or "png"
      local path = build_destination(dir, ext)
      local ok, write_err = write_binary_file(path, data)
      if ok then
        return path
      end
      if file_exists(path) then
        uv.fs_unlink(path)
      end
      return nil, write_err
    end
    last_err = err
  end
  return nil, last_err
end

local function capture_from_powershell_clipboard(dir)
  local shell = powershell_executable()
  if not shell then
    return nil
  end

  local path = build_destination(dir, "png")
  local script = [[
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$image = $null
for ($i = 0; $i -lt 10; $i++) {
  try {
    $image = [System.Windows.Forms.Clipboard]::GetImage()
  } catch {
    $image = $null
  }
  if ($null -ne $image) { break }
  Start-Sleep -Milliseconds 100
}
if ($null -eq $image) { exit 2 }
$image.Save($args[0], [System.Drawing.Imaging.ImageFormat]::Png)
]]

  local result = vim.system({ shell, "-NoProfile", "-STA", "-Command", script, path }, { text = true }):wait()
  if result.code == 0 and file_exists(path) then
    return path, "powershell"
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end

  if result.code == 2 then
    return nil, "clipboard does not contain image data"
  end

  local stderr = result.stderr and vim.trim(result.stderr) or ""
  local stdout = result.stdout and vim.trim(result.stdout) or ""
  local msg = stderr ~= "" and stderr or stdout ~= "" and stdout or "powershell clipboard capture failed"
  return nil, msg
end

local function capture_clipboard_image(dir)
  local path, source = capture_from_pngpaste(dir)
  if path then
    return path, source
  end
  local last_err = source

  path, last_err = capture_from_osascript(dir)
  if path then
    return path, "osascript"
  end

  if vim.fn.executable("wl-paste") == 1 then
    path, last_err = capture_from_binary_command(dir, { "wl-paste", "--no-newline", "--type" })
    if path then
      return path, "wl-paste"
    end
  end

  if vim.fn.executable("xclip") == 1 then
    path, last_err = capture_from_binary_command(dir, { "xclip", "-selection", "clipboard", "-o", "-t" })
    if path then
      return path, "xclip"
    end
  end

  path, last_err = capture_from_powershell_clipboard(dir)
  if path then
    return path, "powershell"
  end

  if last_err and last_err ~= "" then
    return nil, last_err
  end
  return nil, "clipboard image backend not found. Install wl-paste, xclip, pngpaste, use macOS osascript, or use Windows PowerShell clipboard access."
end

local function capture_from_screencapture(dir)
  if not is_macos() or vim.fn.executable("screencapture") ~= 1 then
    return nil
  end

  local path = build_destination(dir, "png")
  local result = vim.system({ "screencapture", "-i", "-x", path }, { text = true }):wait()
  if result.code == 0 and file_exists(path) then
    return path, "screencapture"
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end

  local stderr = result.stderr and vim.trim(result.stderr) or ""
  local stdout = result.stdout and vim.trim(result.stdout) or ""
  local msg = stderr ~= "" and stderr or stdout ~= "" and stdout or "screencapture failed (canceled?)"
  return nil, msg
end

local function capture_from_import(dir)
  if vim.fn.executable("import") ~= 1 then
    return nil
  end

  local path = build_destination(dir, "png")
  local result = vim.system({ "import", path }, { text = true }):wait()
  if result.code == 0 and file_exists(path) then
    return path, "import"
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end

  local stderr = result.stderr and vim.trim(result.stderr) or ""
  local stdout = result.stdout and vim.trim(result.stdout) or ""
  local msg = stderr ~= "" and stderr or stdout ~= "" and stdout or "import failed (canceled?)"
  return nil, msg
end

local function capture_from_grim_slurp(dir)
  if vim.fn.executable("grim") ~= 1 or vim.fn.executable("slurp") ~= 1 then
    return nil
  end

  local path = build_destination(dir, "png")
  local cmd = string.format('grim -g "$(slurp)" %s', vim.fn.shellescape(path))
  local result = vim.system({ "sh", "-c", cmd }, { text = true }):wait()
  if result.code == 0 and file_exists(path) then
    return path, "grim+slurp"
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end

  local stderr = result.stderr and vim.trim(result.stderr) or ""
  local stdout = result.stdout and vim.trim(result.stdout) or ""
  local msg = stderr ~= "" and stderr or stdout ~= "" and stdout or "grim+slurp failed (canceled?)"
  return nil, msg
end

local function capture_from_windows_snipping(dir)
  local shell = powershell_executable()
  if not shell then
    return nil
  end

  local path = build_destination(dir, "png")
  local script = [[
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
$started = $false
foreach ($candidate in @("SnippingTool.exe", "snippingtool")) {
  $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
  if ($cmd) {
    Start-Process -FilePath $cmd.Source -ArgumentList "/clip"
    $started = $true
    break
  }
}
if (-not $started) {
  try {
    Start-Process "ms-screenclip:"
    $started = $true
  } catch {
  }
}
if (-not $started) { exit 4 }
for ($i = 0; $i -lt 240; $i++) {
  Start-Sleep -Milliseconds 250
  try {
    $image = [System.Windows.Forms.Clipboard]::GetImage()
  } catch {
    $image = $null
  }
  if ($null -ne $image) {
    $image.Save($args[0], [System.Drawing.Imaging.ImageFormat]::Png)
    exit 0
  }
}
exit 3
]]

  local result = vim.system({ shell, "-NoProfile", "-STA", "-Command", script, path }, { text = true }):wait()
  if result.code == 0 and file_exists(path) then
    return path, "snippingtool"
  end

  if file_exists(path) then
    uv.fs_unlink(path)
  end

  if result.code == 3 then
    return nil, "snipping tool timed out or was canceled"
  end
  if result.code == 4 then
    return nil, "windows screen clipping backend not found"
  end

  local stderr = result.stderr and vim.trim(result.stderr) or ""
  local stdout = result.stdout and vim.trim(result.stdout) or ""
  local msg = stderr ~= "" and stderr or stdout ~= "" and stdout or "snipping tool capture failed"
  return nil, msg
end

local function capture_screenshot_image(dir)
  local path, source_or_err = capture_from_screencapture(dir)
  if path then
    return path, source_or_err
  end
  local last_err = source_or_err

  local path, source_or_err = capture_from_import(dir)
  if path then
    return path, source_or_err
  end
  if source_or_err ~= nil then
    last_err = source_or_err
  end

  path, source_or_err = capture_from_grim_slurp(dir)
  if path then
    return path, source_or_err
  end
  if source_or_err ~= nil then
    last_err = source_or_err
  end

  path, source_or_err = capture_from_windows_snipping(dir)
  if path then
    return path, source_or_err
  end
  if source_or_err ~= nil then
    last_err = source_or_err
  end

  if last_err and last_err ~= "" then
    return nil, last_err
  end
  return nil, "screenshot backend not found. Install ImageMagick (import), grim+slurp, use macOS screencapture, or use Windows Snipping Tool."
end

local function resize_with_convert(path, max_dimension)
  local tmp = path .. ".resized." .. vim.fn.fnamemodify(path, ":e")
  local result = vim.system({
    "convert",
    path,
    "-resize",
    string.format("%dx%d>", max_dimension, max_dimension),
    tmp,
  }, { text = false }):wait()

  if result.code ~= 0 then
    if file_exists(tmp) then
      uv.fs_unlink(tmp)
    end
    local stderr = result.stderr and vim.trim(result.stderr) or ""
    return nil, stderr ~= "" and stderr or "convert failed"
  end

  if not file_exists(tmp) then
    return nil, "convert did not produce an output file"
  end

  uv.fs_unlink(path)
  local ok, rename_err = uv.fs_rename(tmp, path)
  if not ok then
    if file_exists(tmp) then
      uv.fs_unlink(tmp)
    end
    return nil, rename_err or "failed to replace resized image"
  end
  return true
end

local function resize_image(path, max_dimension)
  if image_file_extension(path) == "svg" then
    return true
  end

  if type(max_dimension) ~= "number" or max_dimension <= 0 then
    return true
  end

  local size_arg = string.format("%dx%d>", max_dimension, max_dimension)
  if vim.fn.executable("magick") == 1 then
    local result = vim.system({ "magick", "mogrify", "-resize", size_arg, path }, { text = false }):wait()
    if result.code == 0 then
      return true
    end
    local stderr = result.stderr and vim.trim(result.stderr) or ""
    return nil, stderr ~= "" and stderr or "magick mogrify failed"
  end

  if vim.fn.executable("mogrify") == 1 then
    local result = vim.system({ "mogrify", "-resize", size_arg, path }, { text = false }):wait()
    if result.code == 0 then
      return true
    end
    local stderr = result.stderr and vim.trim(result.stderr) or ""
    return nil, stderr ~= "" and stderr or "mogrify failed"
  end

  if vim.fn.executable("convert") == 1 then
    return resize_with_convert(path, max_dimension)
  end

  return nil, "resize requires ImageMagick (magick, mogrify, or convert)"
end

local process_dropped_image_lines
local image_preview = require("lazyagent.logic.image_preview").new({
  opts = function()
    return image_paste_opts().preview or {}
  end,
  load_snacks = load_snacks,
  extract_reference = extract_image_reference,
  is_acp_buffer = is_acp_transcript_buffer,
  on_buffer_changed = function(bufnr)
    if process_dropped_image_lines then
      process_dropped_image_lines(bufnr)
    end
  end,
})
process_dropped_image_lines = function(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) or drop_processing[bufnr] then
    return
  end
  if is_acp_transcript_buffer(bufnr) then
    return
  end

  local cfg = image_paste_opts()
  local drop_cfg = cfg.drop or {}
  if drop_cfg.enabled == false then
    return
  end

  drop_processing[bufnr] = true

  local imported_count = 0
  local ok, process_err = pcall(function()
    local dir = nil
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for row, line in ipairs(lines) do
      local candidate = extract_image_reference(line)
      if candidate then
        local image_path = candidate.source_path
        if not dir then
          local dir_err = nil
          dir, dir_err = resolve_image_dir(bufnr)
          if not dir then
            notify(dir_err, vim.log.levels.ERROR)
            break
          end
        end

        if candidate.is_remote then
          local downloaded_path, download_err = download_image_url(dir, candidate.source_url)
          if not downloaded_path then
            notify(download_err, vim.log.levels.ERROR)
            goto continue
          end
          image_path = downloaded_path
        elseif drop_cfg.copy ~= false then
          local imported_path, import_err = import_image_file(dir, candidate.source_path)
          if not imported_path then
            notify(import_err, vim.log.levels.ERROR)
            goto continue
          end
          image_path = imported_path
        end

        local resized, resize_err = resize_image(image_path, tonumber(cfg.max_dimension))
        if resized == nil then
          notify(resize_err, vim.log.levels.WARN)
        end

        local replacement = "@" .. image_path
        local ref_text = line:sub(1, candidate.start_col - 1) .. replacement .. line:sub(candidate.end_col + 1)
        if line ~= ref_text then
          vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { ref_text })
        end

        imported_count = imported_count + 1
      end

      ::continue::
    end
  end)

  drop_processing[bufnr] = nil
  if not ok then
    notify("failed to process dropped image: " .. tostring(process_err), vim.log.levels.ERROR)
    return
  end

  if imported_count > 0 and cfg.notify ~= false then
    local suffix = imported_count == 1 and "" or "s"
    notify("imported " .. imported_count .. " dropped image" .. suffix)
  end
end

local function first_window_for_buffer(bufnr)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
    return current_win
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function insert_reference_line(bufnr, ref_text)
  local target_win = first_window_for_buffer(bufnr)
  local row = target_win and vim.api.nvim_win_get_cursor(target_win)[1] or vim.api.nvim_buf_line_count(bufnr)
  local current = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""

  if current:match("^%s*$") then
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { ref_text, "" })
    if target_win then
      vim.api.nvim_win_set_cursor(target_win, { row + 1, 0 })
    end
    return row
  end

  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { ref_text, "" })
  if target_win then
    vim.api.nvim_win_set_cursor(target_win, { row + 2, 0 })
  end
  return row + 1
end

local function image_reference_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local win = first_window_for_buffer(bufnr)
  if not win then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local reference = extract_image_reference(line, { include_managed_refs = true })
  if not reference then
    return nil
  end
  local cursor_col = cursor[2] + 1
  if cursor_col < reference.start_col or cursor_col > reference.end_col + 1 then
    return nil
  end
  reference.bufnr = bufnr
  reference.row = cursor[1]
  reference.line = line
  reference.source = reference.source_path or reference.source_url
  return reference
end

local function attachment_context(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    notify("scratch buffer is not available", vim.log.levels.ERROR)
    return nil, nil
  end

  local cfg = image_paste_opts()
  if cfg.enabled == false then
    notify("image paste is disabled", vim.log.levels.WARN)
    return nil, nil
  end

  local dir, dir_err = resolve_image_dir(bufnr)
  if not dir then
    notify(dir_err, vim.log.levels.ERROR)
    return nil, nil
  end
  return cfg, dir
end

local function image_capability(bufnr)
  local agent_name = buffer_var(bufnr, "lazyagent_agent")
  if type(agent_name) ~= "string" or agent_name == "" then
    agent_name = state.open_agent
  end
  local session = agent_name and state.sessions and state.sessions[agent_name] or nil
  if not session then
    return {
      status = "unknown",
      label = "image capability unknown",
      agent_name = agent_name,
    }
  end
  if not acp_logic.is_acp_backend(session.backend) then
    return {
      status = "path",
      label = "CLI @path attachment",
      agent_name = agent_name,
    }
  end
  if session.acp_ready ~= true then
    return {
      status = "pending",
      label = "ACP image capability pending",
      agent_name = agent_name,
    }
  end
  if session.acp_supports_image == true then
    return {
      status = "supported",
      label = "ACP image input supported",
      agent_name = agent_name,
    }
  end
  return {
    status = "unsupported",
    label = "ACP image input unavailable",
    agent_name = agent_name,
  }
end

local function finalize_attachment(bufnr, image_path, source, cfg, opts)
  opts = opts or {}
  if opts.resize ~= false then
    local resized, resize_err = resize_image(image_path, tonumber(cfg.max_dimension))
    if resized == nil then
      notify(resize_err, vim.log.levels.WARN)
    end
  end

  insert_reference_line(bufnr, "@" .. image_path)
  image_preview.refresh(bufnr)

  if cfg.notify ~= false then
    local capability = image_capability(bufnr)
    local message = "attached image from " .. tostring(source or "image")
    if capability.status == "unsupported" then
      local agent = capability.agent_name and (" for " .. capability.agent_name) or ""
      notify(message .. "; ACP image input is unavailable" .. agent .. " and the image will be omitted on send", vim.log.levels.WARN)
    else
      notify(message)
    end
  end

  return image_path
end

local function recent_image_files()
  local cfg = image_paste_opts()
  local picker_cfg = type(cfg.picker) == "table" and cfg.picker or {}
  local limit = math.max(1, math.floor(tonumber(picker_cfg.recent_limit) or 20))
  local max_depth = math.max(0, math.floor(tonumber(picker_cfg.recent_scan_depth) or 4))
  local scan_limit = math.max(limit, math.floor(tonumber(picker_cfg.recent_scan_limit) or 2000))
  local root = image_storage_root()
  if vim.fn.isdirectory(root) ~= 1 then
    return {}
  end

  local images = {}
  local scanned = 0
  local function scan(dir, depth)
    if scanned >= scan_limit then
      return
    end
    local handle = uv.fs_scandir(dir)
    if not handle then
      return
    end
    while scanned < scan_limit do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      scanned = scanned + 1
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" and depth < max_depth then
        scan(path, depth + 1)
      elseif kind == "file" and IMAGE_FILE_EXTENSIONS[image_file_extension(path)] then
        local stat = uv.fs_stat(path)
        if stat and (stat.size or 0) > 0 then
          local modified = stat.mtime
          images[#images + 1] = {
            path = path,
            mtime = type(modified) == "table" and tonumber(modified.sec) or tonumber(modified) or 0,
          }
        end
      end
    end
  end
  scan(root, 0)
  table.sort(images, function(a, b)
    if a.mtime == b.mtime then
      return a.path < b.path
    end
    return a.mtime > b.mtime
  end)
  while #images > limit do
    table.remove(images)
  end
  return images
end

function M.capability(bufnr)
  return image_capability(bufnr or vim.api.nvim_get_current_buf())
end

function M.paste_into_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg, dir = attachment_context(bufnr)
  if not cfg then
    return nil
  end

  local image_path, source_or_err = capture_clipboard_image(dir)
  if not image_path then
    notify(source_or_err, vim.log.levels.ERROR)
    return nil
  end
  return finalize_attachment(bufnr, image_path, source_or_err, cfg)
end

function M.attach_file_into_buffer(bufnr, path, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local cfg, dir = attachment_context(bufnr)
  if not cfg then
    return nil
  end

  local source_path = normalize_image_path_text(path)
  if not source_path then
    notify("not a readable supported image file: " .. tostring(path or ""), vim.log.levels.ERROR)
    return nil
  end

  local import_cfg = type(cfg.import) == "table" and cfg.import or {}
  local image_path = source_path
  if import_cfg.copy ~= false then
    local import_err
    image_path, import_err = import_image_file(dir, source_path)
    if not image_path then
      notify(import_err, vim.log.levels.ERROR)
      return nil
    end
  end
  return finalize_attachment(bufnr, image_path, opts.source or "file", cfg, {
    resize = image_path ~= source_path,
  })
end

function M.attach_url_into_buffer(bufnr, url)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg, dir = attachment_context(bufnr)
  if not cfg then
    return nil
  end

  local source_url = normalize_explicit_image_url(url)
  if not source_url then
    notify("image URL must use http:// or https:// and contain no whitespace", vim.log.levels.ERROR)
    return nil
  end
  local image_path, download_err = download_image_url(dir, source_url)
  if not image_path then
    notify(download_err, vim.log.levels.ERROR)
    return nil
  end
  return finalize_attachment(bufnr, image_path, "URL", cfg)
end

function M.recent_images()
  return recent_image_files()
end

function M.paste_current_buffer()
  return M.paste_into_buffer(vim.api.nvim_get_current_buf())
end

function M.screenshot_into_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg, dir = attachment_context(bufnr)
  if not cfg then
    return nil
  end

  local image_path, source_or_err = capture_screenshot_image(dir)
  if not image_path then
    notify(source_or_err, vim.log.levels.ERROR)
    return nil
  end
  return finalize_attachment(bufnr, image_path, source_or_err, cfg)
end

function M.screenshot_current_buffer()
  return M.screenshot_into_buffer(vim.api.nvim_get_current_buf())
end

local image_picker
local function picker_controller()
  if image_picker then
    return image_picker
  end
  image_picker = require("lazyagent.logic.image_picker").new({
    capability = M.capability,
    attach_clipboard = M.paste_into_buffer,
    attach_screenshot = M.screenshot_into_buffer,
    attach_file = M.attach_file_into_buffer,
    attach_url = M.attach_url_into_buffer,
    recent_images = M.recent_images,
    load_snacks = load_snacks_picker,
    notify = notify,
  })
  return image_picker
end

function M.choose_into_buffer(bufnr, opts)
  return picker_controller().open(bufnr or vim.api.nvim_get_current_buf(), opts)
end

function M.choose_current_buffer(opts)
  return M.choose_into_buffer(vim.api.nvim_get_current_buf(), opts)
end

function M.current_image(bufnr)
  return image_reference_at_cursor(bufnr or vim.api.nvim_get_current_buf())
end

function M.preview_image(bufnr, reference)
  reference = reference or image_reference_at_cursor(bufnr)
  if not reference then
    return false
  end
  local Snacks = load_snacks()
  if Snacks and Snacks.image and type(Snacks.image.hover) == "function" then
    local ok = pcall(Snacks.image.hover)
    if ok then
      return true
    end
  end
  notify("larger image preview requires Snacks.image hover support", vim.log.levels.WARN)
  return false
end

function M.open_image(_, reference)
  reference = reference or image_reference_at_cursor(vim.api.nvim_get_current_buf())
  local source = reference and reference.source or nil
  if not source or type(vim.ui.open) ~= "function" then
    notify("system image viewer is not available", vim.log.levels.WARN)
    return false
  end
  local ok, process_or_err, open_err = pcall(vim.ui.open, source)
  if not ok then
    open_err = process_or_err
  end
  if not ok or open_err then
    notify("failed to open image: " .. tostring(open_err or "unknown error"), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.copy_image_path(_, reference)
  reference = reference or image_reference_at_cursor(vim.api.nvim_get_current_buf())
  local source = reference and reference.source or nil
  if not source then
    return false
  end
  vim.fn.setreg('"', source)
  pcall(vim.fn.setreg, "+", source)
  notify("copied image path")
  return true
end

function M.remove_image_reference(bufnr, reference)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  reference = reference or image_reference_at_cursor(bufnr)
  if not reference or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if not vim.bo[bufnr].modifiable then
    notify("image reference buffer is not modifiable", vim.log.levels.WARN)
    return false
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, reference.row - 1, reference.row, false)[1] or ""
  if line:sub(reference.start_col, reference.end_col) ~= reference.raw then
    notify("image reference changed; place the cursor on it and try again", vim.log.levels.WARN)
    return false
  end
  local replacement = line:sub(1, reference.start_col - 1) .. line:sub(reference.end_col + 1)
  vim.api.nvim_buf_set_lines(bufnr, reference.row - 1, reference.row, false, { replacement })
  local win = first_window_for_buffer(bufnr)
  if win then
    local col = math.min(vim.api.nvim_win_get_cursor(win)[2], #replacement)
    vim.api.nvim_win_set_cursor(win, { reference.row, col })
  end
  image_preview.refresh(bufnr)
  notify("removed image reference")
  return true
end

local image_actions
local function action_controller()
  if image_actions then
    return image_actions
  end
  image_actions = require("lazyagent.logic.image_actions").new({
    current_image = M.current_image,
    preview = M.preview_image,
    open = M.open_image,
    copy = M.copy_image_path,
    remove = M.remove_image_reference,
    notify = notify,
  })
  return image_actions
end

function M.actions_at_cursor(bufnr, opts)
  return action_controller().open(bufnr or vim.api.nvim_get_current_buf(), opts)
end

function M.attach_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  return image_preview.attach(bufnr)
end

function M.process_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  image_preview.attach(bufnr)
  if not is_acp_transcript_buffer(bufnr) then
    process_dropped_image_lines(bufnr)
  end
  return image_preview.refresh(bufnr)
end

function M.refresh_buffer_previews(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  return image_preview.refresh(bufnr)
end

function M.clear_buffer_previews(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr then
    return false
  end
  return image_preview.clear(bufnr)
end

function M.setup()
  if paste_hook_installed then
    return
  end

  local overridden = vim.paste
  vim.paste = function(lines, phase)
    local bufnr = vim.api.nvim_get_current_buf()
    local should_process = is_scratch_buffer(bufnr)
    local result = overridden(lines, phase)

    if should_process and (phase == -1 or phase == 3) then
      vim.schedule(function()
        if not is_scratch_buffer(bufnr) then
          return
        end
        M.process_buffer(bufnr)
      end)
    end

    return result
  end

  paste_hook_installed = true
end

return M
