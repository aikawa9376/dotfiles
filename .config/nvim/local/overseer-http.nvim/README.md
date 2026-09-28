# overseer-http.nvim

Run requests from `.http` or `.rest` files as [overseer.nvim](https://github.com/stevearc/overseer.nvim) tasks. Requires Neovim, Overseer, and `curl`.

```http
### Get users
GET {{base_url}}/users
Accept: application/json

### Create user
POST {{base_url}}/users
Content-Type: application/json

{"name":"foo"}
```

The local plugin is loaded as an Overseer dependency in this dotfiles repository. Its setup is called from `lua/plugins/overseer.lua` after `overseer.setup()`.

For another Lazy configuration, the equivalent setup is:

```lua
{
  'stevearc/overseer.nvim',
  dependencies = {
    { dir = '/path/to/overseer-http.nvim', name = 'overseer-http.nvim', lazy = true },
  },
  cmd = { 'OverseerRun', 'OverseerHttpRun', 'OverseerHttpSelect', 'OverseerHttpRunAll' },
  config = function()
    local actions = require('overseer_http.actions').build()
    require('overseer').setup({ actions = actions })
    require('overseer_http').setup()
  end,
}
```

Commands:

- `:OverseerHttpRun` runs the request at the cursor.
- `:OverseerHttpSelect` selects a request from the current file.
- `:OverseerHttpRunAll` runs every request in the current file in parallel.
- `:OverseerRun` also lists requests from the current `.http` or `.rest` buffer.

The dotfiles install adds these normal-mode maps only to file-backed `http` and `rest` buffers:

| Key | Action |
| --- | --- |
| `<CR>`, `<leader>Rs` | Send current request |
| `<leader>Ra` | Send all requests |
| `<leader>Rf` | Select a request |
| `<leader>Rn`, `<leader>Rp` | Jump to next or previous request |
| `<leader>Rr` | Repeat the most recent request from this file |
| `<leader>Rt` | Alternate between response body and headers |
| `<leader>Rb`, `<leader>Rh` | Open response body or headers |
| `<leader>Rc` | Copy the most recent request as cURL |
| `<leader>Ro` | Toggle the Overseer task list |

Each request becomes an Overseer task. The task name shows the HTTP status after completion. Responses with status 200–399 succeed by default; HTTP 400–599 and curl transport failures fail. The task's `result.http` records `status_code`, `curl_exit`, `headers_path`, and `body_path`. Overseer's restart action resends the captured request. The response files are removed when the task is disposed.

HTTP request lines, headers, variables, and JSON request bodies have fallback syntax highlighting even when the HTTP Tree-sitter parser is unavailable. When a request receives an HTTP response, its Overseer output pane shows the body by default, including 4xx/5xx responses. Body/Headers actions switch that same pane without opening another split. Curl transport failures leave the original task output visible. The response view uses Content-Type as its filetype. JSON responses are pretty-printed by `jq` when available; the response file on disk remains unchanged. Invalid JSON and systems without `jq` display the original body.

Open the task action menu (`<CR>` in the Overseer task list) for **HTTP: Open Body**, **HTTP: Open Headers**, **HTTP: Copy cURL**, **HTTP: Repeat Request**, and **HTTP: Open Source Request**. A copied cURL command can contain credentials; treat the clipboard accordingly.

Configuration defaults:

```lua
require('overseer_http').setup({
  env_files = { '.env', '.env.local' },
  variables = {},
  curl = { executable = 'curl' },
  response = { pretty_json = true },
  success_status = function(code) return code >= 200 and code < 400 end,
})
```

Variables expand in the URL, header values, and body. Configuration variables take precedence, followed by `.env` files (later files override earlier ones), then process environment. `.env` files are resolved beside the request file and support simple `KEY=value` lines. Missing variables stop execution before curl starts. The parser accepts `###` separators, optional request names, the methods GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, headers, and a body after the first blank line. Body blank lines are preserved.

The task command uses an argv array, so execution does not go through a shell. Response files are kept for the life of the task. Request bodies and headers may contain secrets; they are not used in generated task titles, but cURL arguments, task metadata, and copied commands can contain them. This version targets text request and response bodies; binary response display in a Neovim buffer is not byte preserving.

Run `:checkhealth overseer_http` after loading the plugin to check Overseer and curl availability.

Run the core tests with:

```sh
nvim --headless --clean -u NONE -l tests/core.lua
nvim --headless --clean -u NONE -l tests/integration.lua
nvim --headless --clean -u NONE -l tests/lazy.lua
```
