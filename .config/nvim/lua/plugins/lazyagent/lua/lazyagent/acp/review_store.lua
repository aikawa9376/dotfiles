local M = {}

local uv = vim.uv or vim.loop

local Store = {}
Store.__index = Store

local function decode(text)
  return vim.json and vim.json.decode(text) or vim.fn.json_decode(text)
end

local function encode(value)
  return vim.json and vim.json.encode(value) or vim.fn.json_encode(value)
end

local function write_all(fd, payload)
  local offset = 0
  while offset < #payload do
    local written, err = uv.fs_write(fd, payload:sub(offset + 1), offset)
    if not written or written <= 0 then return nil, err or "short review store write" end
    offset = offset + written
  end
  return true
end

function Store:_read()
  if vim.fn.filereadable(self.path) ~= 1 then return { schema_version = 1, reviews = {} } end
  local ok, value = pcall(decode, table.concat(vim.fn.readfile(self.path), "\n"))
  if not ok or type(value) ~= "table" or type(value.reviews) ~= "table" then
    return nil, "invalid Git review store"
  end
  return value
end

function Store:_write(data)
  vim.fn.mkdir(self.dir, "p", 448)
  local temporary = self.path .. ".tmp-" .. tostring(vim.fn.getpid())
  local fd, err = uv.fs_open(temporary, "w", 384)
  if not fd then return nil, err end
  local payload = encode(data)
  local written, write_err = write_all(fd, payload)
  uv.fs_close(fd)
  if not written then uv.fs_unlink(temporary); return nil, write_err end
  local renamed, rename_err = uv.fs_rename(temporary, self.path)
  if not renamed then uv.fs_unlink(temporary); return nil, rename_err end
  return true
end

function Store:list()
  local data, err = self:_read()
  return data and vim.deepcopy(data.reviews) or nil, err
end

function Store:get(id)
  local reviews, err = self:list()
  if not reviews then return nil, err end
  for _, review in ipairs(reviews) do
    if review.review_id == id then return review end
  end
  return nil, "review not found: " .. tostring(id)
end

function Store:save(review)
  local data, err = self:_read()
  if not data then return nil, err end
  local replaced = false
  for index, existing in ipairs(data.reviews) do
    if existing.review_id == review.review_id then
      data.reviews[index] = vim.deepcopy(review)
      replaced = true
      break
    end
  end
  if not replaced then data.reviews[#data.reviews + 1] = vim.deepcopy(review) end
  local ok, write_err = self:_write(data)
  return ok and vim.deepcopy(review) or nil, write_err
end

function M.new(opts)
  opts = opts or {}
  local dir = tostring(opts.dir or (vim.fn.stdpath("cache") .. "/lazyagent/acp/reviews"))
  return setmetatable({ dir = dir, path = dir .. "/manifest.json" }, Store)
end

return M
