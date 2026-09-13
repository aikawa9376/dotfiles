local M = {}
local A = '123e4567-e89b-42d3-a456-426614174001'
local B = '123e4567-e89b-42d3-a456-426614174002'

function M.run()
  local ThreadStore = require('lazyagent.acp.thread_store')
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname() .. '-thread-store-cache'
  local store = ThreadStore.new({ dir = root })
  local encode, decode = vim.json.encode, vim.json.decode
  local readfile, writefile, rename = vim.fn.readfile, vim.fn.writefile, uv.fs_rename
  local function disk()
    return decode(table.concat(readfile(store.path), '\n'))
  end
  local function replace(manifest)
    local path = store.path .. '.external'
    assert(writefile({ encode(manifest) }, path) == 0)
    assert(rename(path, store.path))
  end
  local ok, err = xpcall(function()
    assert(store:create({ thread_id = A, provider_id = 'fixture', title = 'one', process_id = 10,
      metadata = { nested = { keep = 'original' } } }))
    assert(store:create({ thread_id = B, provider_id = 'fixture', title = 'two',
      metadata = { padding = string.rep('unrelated history ', 1000) } }))

    -- Warm getters and one-record mutations do not decode/encode unrelated history.
    local decodes, records_encoded = 0, {}
    vim.json.decode = function(...)
      decodes = decodes + 1
      return decode(...)
    end
    vim.json.encode = function(value, ...)
      if type(value) == 'table' and value.thread_id then
        records_encoded[#records_encoded + 1] = value.thread_id
      end
      return encode(value, ...)
    end
    local other = ThreadStore.new({ dir = root })
    for _ = 1, 10 do assert(other:get(B)) end
    assert(other:update(A, { draft = 'draft', metadata = { added = true } }))
    assert(store:get(A).draft == 'draft', 'another Store instance observed stale state')
    assert(decodes == 0, 'warm access decoded the entire manifest')
    assert(vim.deep_equal(records_encoded, { A }), 'update serialized unrelated conversations')
    vim.json.encode, vim.json.decode = encode, decode
    assert(disk().schema_version == 1, 'on-disk schema changed')
    assert(#disk().threads == 2 and disk().threads[2].metadata.padding ~= nil)

    -- No mutable public result may escape into the shared cache.
    local thread = assert(store:get(A))
    thread.metadata.nested.keep = 'mutated'
    local manifest = assert(store:load())
    manifest.threads[1].title = 'mutated'
    local listed = assert(store:list({ include_archived = true }))
    listed[1].metadata.nested = { keep = 'mutated' }
    assert(store:with_manifest_lock(function(value)
      value.threads[1].draft = 'mutated'
      return true
    end))
    assert(store:get(A).metadata.nested.keep == 'original')
    assert(store:get(A).title == 'one' and store:get(A).draft == 'draft')

    -- Atomic external replacement, including same-size content, invalidates the cache.
    local external = disk()
    external.threads[1].title = 'six'
    replace(external)
    assert(other:get(A).title == 'six', 'external replacement was hidden by cache')
    assert(store:update(A, { metadata = { parent = true } }))
    assert(disk().threads[1].title == 'six', 'update overwrote an external change')

    -- A real second Neovim uses the same lock and v1 file, preserving both writers.
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local plugin = vim.fn.fnamemodify(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))), ':p')
    local child = root .. '/writer.lua'
    assert(writefile({
      'vim.opt.rtp:prepend(' .. string.format('%q', plugin) .. ')',
      'local s = require("lazyagent.acp.thread_store").new({dir=' .. string.format('%q', root) .. '})',
      'assert(s:update(' .. string.format('%q', A) .. ', {draft="child draft", process_id=20}))',
    }, child) == 0)
    local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-l', child }, { text = true }):wait(5000)
    assert(result.code == 0, result.stderr)
    local rejected, stale = store:update(A, { draft = 'stale writer' }, { expected_process_id = 10 })
    assert(rejected == nil and stale.code == 'stale_process', 'cached ownership bypassed process guard')
    assert(store:update(A, { metadata = { after_child = true } }, { expected_process_id = 20 }))
    local persisted = disk().threads[1]
    assert(persisted.draft == 'child draft' and persisted.metadata.parent and persisted.metadata.after_child)

    -- Failed writes and renames must not publish the attempted record to any cache.
    for _, failure in ipairs({ 'return', 'throw', 'rename' }) do
      local before = table.concat(readfile(store.path), '\n')
      vim.fn.writefile = function(lines, path, ...)
        if path:find('/manifest.json.tmp.', 1, true) then
          if failure == 'return' then return -1 end
          if failure == 'throw' then error('fixture write failure') end
        end
        return writefile(lines, path, ...)
      end
      uv.fs_rename = function(from, to)
        if failure == 'rename' and to == store.path then return nil, 'fixture rename failure' end
        return rename(from, to)
      end
      local updated = store:update(A, { title = 'must not persist' })
      vim.fn.writefile, uv.fs_rename = writefile, rename
      assert(updated == nil, 'failed write reported success')
      assert(other:get(A).title == 'six', 'failed write poisoned shared cache')
      assert(table.concat(readfile(store.path), '\n') == before, 'failed write changed disk data')
      assert(vim.fn.filereadable(store.lock_path) == 0, 'failed write leaked lock')
      assert(#vim.fn.glob(store.path .. '.tmp.*', false, true) == 0, 'failed write leaked temporary file')
    end

    -- A replacement during a cold read cannot label old data with the new fingerprint.
    external = disk()
    external.threads[1].title = 'old snapshot'
    replace(external)
    local exchanged = false
    vim.fn.readfile = function(path, ...)
      local lines = readfile(path, ...)
      if path == store.path and not exchanged then
        exchanged = true
        external.threads[1].title = 'new snapshot'
        replace(external)
      end
      return lines
    end
    assert(store:get(A).title == 'old snapshot')
    vim.fn.readfile = readfile
    assert(store:get(A).title == 'new snapshot', 'read race cached a stale generation')

    assert(store:delete(B))
    assert(other:get(B) == nil)
    assert(other:get(A).draft == 'child draft')
    -- Deleting/recreating the entire manifest must invalidate cached records too.
    assert(uv.fs_unlink(store.path))
    assert(#store:list({ include_archived = true }) == 0)
    assert(store:create({ thread_id = B, provider_id = 'fixture' }))
    assert(other:get(A) == nil and other:get(B) ~= nil)
  end, debug.traceback)
  vim.json.encode, vim.json.decode = encode, decode
  vim.fn.readfile, vim.fn.writefile, uv.fs_rename = readfile, writefile, rename
  vim.fn.delete(root, 'rf')
  if not ok then error(err) end
end

return M
