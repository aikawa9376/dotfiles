---@diagnostic disable: duplicate-set-field
local M = {}
local function eq(a, b, message)
  assert(vim.deep_equal(a, b), (message or "values differ") .. "\nexpected: " .. vim.inspect(b) .. "\nactual: " .. vim.inspect(a))
end
local function labels(items)
  return vim.tbl_map(function(item) return item.label end, items)
end

function M.run()
  local S = require("laravel_extension.syntax")
  local I = require("laravel_extension.index")
  local P = require("laravel_extension.php")
  local members = require("laravel_extension.features.members")
  local routes = require("laravel_extension.features.routes")
  local refs = require("laravel_extension.features.references")
  local rename = require("laravel_extension.features.rename")
  local root = vim.fn.tempname() .. "-laravel-workflows"
  local created = {}
  local function put(path, text)
    path = root .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb")); assert(f:write(text)); f:close()
    created[#created + 1] = path
    return path
  end
  local function edit(path, text, needle)
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    if text then vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n", { plain = true })) end
    if needle then
      local source = assert(I.read(path))
      local offset = assert(source:find(needle, 1, true), needle)
      local row, col = S.position(source, offset)
      vim.api.nvim_win_set_cursor(0, {row, col - 1})
    end
  end
  local function scan()
    local files, failure, done
    I.scan(root, function(found, err) files, failure, done = found, err, true end)
    assert(vim.wait(4000, function() return done end, 10), "scan timeout")
    assert(files, failure)
    return files
  end
  local function reference_items(target)
    local items, failure, done
    I.references(target, function(found, err) items, failure, done = found, err, true end)
    assert(vim.wait(4000, function() return done end, 10), "reference timeout")
    assert(items, failure)
    return items
  end
  put("artisan", "#!/usr/bin/env php\n")
  put("composer.json", '{"autoload":{"psr-4":{"App\\\\":"app/"}}}\n')
  local view = put("resources/views/users/index.blade.php", "<main>Hello</main>\n")
  local card = put("resources/views/components/card.blade.php", "@props(['heading', 'tone' => 'info', 'options' => ['one', 'two']])\n<div>{{ $heading }}</div>\n")
  local alert = put("app/View/Components/Alert.php", [[<?php
namespace App\View\Components;
class Alert {
  public function __construct(public string $title, string $alertType = 'info', private string $secret = '') {}
  public bool $dismissible = false;
  protected string $hidden;
  public function render() { return view('components.alert'); }
}
]])
  put("resources/views/components/alert.blade.php", "<div>{{ $title }}</div>\n")
  local caller = put("resources/views/pages/show.blade.php", [[@include('users.index')
@includeWhen($ready, 'users.index')
@includeFirst(['missing', 'users.index'])
@extends(
  'users.index'
)
{{-- @include('users.index') <x-card /> --}}
<x-card heading="Hello" />
<x-card></x-card>
<x-card-extra />
<x-alert :title="$a > $b" />
<livewire:edit-user />
@livewire('edit-user')
]])
  put("vendor/package/ignored.php", "<?php view('users.index');\n")
  put("storage/framework/views/ignored.php", "<?php view('users.index');\n")
  local consumer = put("app/Http/Controllers/Consumer.php", [[<?php
view('users.index');
View::make("users.index");
Route::view('/users', 'users.index');
response()->view('users.index');
// view('users.index');
$note = "view('users.index')";
view('users.index' . $suffix);
view("users.$name");
$object->view('users.index');
$doc = <<<'TEXT'
view('users.index');
TEXT;
]])
  put("app/Livewire/BaseEditor.php", [[<?php
namespace App\Livewire;
class BaseEditor { public string $inherited; public function refreshPage() {} }
]])
  local livewire = put("app/Livewire/EditUser.php", [[<?php
namespace App\Livewire;
class EditUser extends BaseEditor {
  public string $name;
  private string $secret;
  public function save() {}
  protected function hidden() {}
  public function render() { return view('custom.editor'); }
}
]])
  local editor = put("resources/views/custom/editor.blade.php", '<button wire:click="save">Save</button>\n<input wire:model.live="name" />\n')
  local controller = put("app/Http/Controllers/UserController.php", [[<?php
namespace App\Http\Controllers;
class UserController {
  public function index() { $service->work(); }
  public function update() {}
  public function __invoke() {}
}
]])
  local route_file = put("routes/web.php", [[<?php
use App\Http\Controllers\UserController as Users;
use App\Http\Controllers\OtherController;
Route::prefix('admin')->name('admin.')->controller(Users::class)->group(function () {
  Route::get('/users', 'index')->name('users');
  Route::prefix('nested')->group(function () {
    Route::patch('/users/{user}', [Users::class, 'update']);
  });
});
Route::resource('users', Users::class)->only(['index', 'update']);
Route::get('/invokable', Users::class);
Route::get('/other', [OtherController::class, 'index']);
Route::match(['get', 'post'], '/both', [Users::class, 'index']);
// Route::get('/fake', [Users::class, 'index']);
]])

  local previous_state = _G.laravel_nvim
  _G.laravel_nvim = { project_root = "/some/other/project" }
  edit(view)
  eq(require("laravel_extension.utils").project_root(0), root, "buffer project wins over stale global Laravel state")
  _G.laravel_nvim = previous_state
  local static = S.references([[<?php
use Illuminate\Support\Facades\View as Views;
Views::make('pages.home');
view(view: 'pages.home');
/* view('ignored'); */
$string = "view('ignored')";
]])
  eq(vim.tbl_map(function(r) return r.name end, static), {"pages.home", "pages.home"}, "facade aliases and named view arguments")
  eq(#S.references("@@include('ignored')\n<!-- <x-hidden /> -->\n"), 0, "escaped directives and comments excluded")
  local blade_expr = S.references([[<p>view('not-code')</p>
<a title="{{ view('actual') }}">{{ view('other') }}</a>
@if(view('condition')) yes @endif
@verbatim <x-hidden /> {{ view('ignored') }} @endverbatim
]], {blade=true})
  eq(vim.tbl_map(function(r) return r.name end,blade_expr), {"actual", "other", "condition"}, "only executable Blade expressions are references")

  local files = scan()
  for _, file in ipairs(files) do
    assert(not file.path:find("/vendor/", 1, true), "vendor excluded")
    assert(not file.path:find("/storage/", 1, true), "compiled views excluded")
  end
  local found = reference_items(assert(I.file_target(view, root)))
  eq(#found, 8, "four directive and four PHP call references; skip comments, dynamic expressions and unrelated calls")
  local card_items = reference_items(assert(I.file_target(card, root)))
  eq(#card_items, 3, "anonymous component references include open/close tags, avoid prefix collisions")
  eq(S.tags('<x-alert :title="$a > $b" /><x-card />')[2].name, "card", "quoted > does not end attribute")
  edit(caller, nil, "users.index")
  eq(I.at_cursor({root=root}).path, view, "view identity from directive")
  edit(caller, nil, "x-card")
  vim.api.nvim_win_set_cursor(0, {8, 4})
  eq(I.at_cursor({root=root}).path, card, "identity from anonymous tag")
  edit(view)
  local picked
  assert(refs.goto_at_cursor({root=root,picker=function(items) picked=items end}))
  assert(vim.wait(4000,function() return picked ~= nil end,10))
  eq(#picked, 8, "Blade gr routes to picker without LSP")
  edit(consumer, "<?php\nview('users.index');\nview('users.index');", "view")
  eq(#reference_items(assert(I.file_target(view, root))), 6, "reference search reads unsaved source buffers")
  vim.cmd("edit!")

  local properties = members.component_props("alert", root)
  eq(vim.tbl_map(function(p) return p.name end, properties), {"title", "alertType", "dismissible"}, "constructor and public props, no private members")
  eq(vim.tbl_map(function(p) return p.name end, members.component_props("card", root)), {"heading", "tone", "options"}, "@props keys; exclude defaults")
  local complete_path = put("resources/views/completion.blade.php", "<x-alert\n :al\n />\n")
  edit(complete_path)
  local text = assert(I.read(complete_path))
  local end_offset = assert(text:find(":al",1,true)) + 3
  local completions = members.completions(0,text,end_offset)
  eq(labels(completions), {"alert-type"}, "kebab prop completion across lines")
  eq(completions[1].textEdit.range.start.character, 2, "bound : prefix preserved")
  local partial = '<x-card heading="Hello" '
  eq(labels(members.completions(0,partial,#partial+1)), {"options", "tone"}, "omit already supplied props")
  edit(editor)
  eq(members.livewire_owners(editor,root), {livewire}, "custom render view mapped to class")
  local before = '<button wire:click="sa'
  eq(labels(members.completions(0,before,#before+1)), {"save"}, "Livewire action completion")
  before = '<input wire:model.live="in'
  eq(labels(members.completions(0,before,#before+1)), {"inherited"}, "Livewire inherited public property")
  before = '{{ $wire.na'
  eq(labels(members.completions(0,before,#before+1)), {"name"}, "$wire completion")
  before = '<button x-on:click="$wire.sa'
  eq(labels(members.completions(0,before,#before+1)), {"save"}, "$wire inside Alpine attribute")
  eq(labels(members.completions(0,'<button title="sa',18)), {}, "no members in ordinary HTML values")
  edit(editor,nil,"save")
  assert(members.goto_at_cursor(), "jump to Livewire method")
  eq(vim.api.nvim_buf_get_name(0),livewire,"Livewire member destination")
  edit(complete_path,"<x-alert :alert-type=\"$kind\" />", "alert-type")
  assert(members.goto_at_cursor(), "jump to component prop")
  eq(vim.api.nvim_buf_get_name(0),alert,"constructor prop destination")
  edit(complete_path)
  vim.cmd("edit!")
  local blink_source = require("laravel_extension.blink").new()
  local response
  blink_source:get_completions({bufnr=vim.api.nvim_get_current_buf(),cursor={2,4}},function(r) response=r end)
  eq(labels(response.items), {"alert-type"}, "Blink provider returns actual component props")

  require("laravel_extension").setup()
  vim.bo.filetype="blade"
  eq(vim.fn.maparg("gr","n",false,true).desc,"Laravel/LSP references","Blade mapping without LSP attachment")
  eq(vim.fn.maparg("gd","n",false,true).desc,"Laravel/LSP definition","Blade definition mapping without LSP")
  eq(vim.fn.maparg("<Leader>rn","n",false,true).desc,"Rename Blade view and references","Blade rename mapping")
  assert(vim.fn.exists(":LaravelControllerRoutes")==2 and vim.fn.exists(":LaravelRenameView")==2,"commands registered")

  local route_items = routes.in_source(route_file,I.read(route_file))
  local index_routes = vim.tbl_filter(function(r) return r.controller == "App\\Http\\Controllers\\UserController" and r.action == "index" end,route_items)
  eq(#index_routes,3,"alias, controller group, resource and match route resolution")
  eq(index_routes[1].url,"/admin/users","group prefix")
  eq(index_routes[1].name,"admin.users","route name prefix")
  local patch
  for _, route in ipairs(route_items) do
    if route.method == "PATCH" then patch = route end
    assert(route.action ~= "create", "resource only filter")
  end
  eq(assert(patch).url,"/admin/nested/users/{user}","nested prefix")
  edit(controller,nil,"index")
  eq(P.method_at_cursor(root).method,"index","controller method recognition")
  local route_picked
  assert(refs.goto_at_cursor({root=root,picker=function(items) route_picked=items end}))
  assert(vim.wait(4000,function() return route_picked ~= nil end,10))
  eq(#route_picked,3,"controller gr picks route definitions")
  edit(controller,nil,"work")
  eq(refs.goto_at_cursor({root=root}),false,"ordinary PHP method reference retains LSP fallback")

  edit(card)
  files = scan()
  local plan, err = rename.plan(I.file_target(card,root),"components.forms.panel",files)
  assert(plan,err)
  eq(#plan.items,3,"rename includes both tags")
  assert(rename.apply(plan))
  local moved = root .. "/resources/views/components/forms/panel.blade.php"
  eq(vim.fn.filereadable(card),0,"old view removed")
  eq(vim.fn.filereadable(moved),1,"view moved to nested directory")
  eq(vim.api.nvim_buf_get_name(0),moved,"loaded buffer follows moved file")
  local updated = assert(I.read(caller))
  assert(updated:find("<x-forms.panel>",1,true) and updated:find("</x-forms.panel>",1,true),"paired tag names updated")
  assert(updated:find("<x-card-extra />",1,true),"unrelated tag unchanged")
  assert(updated:find("{{-- @include('users.index') <x-card /> --}}",1,true),"comments unchanged")
  local bad, why = rename.plan(I.file_target(moved,root),"users.index",scan())
  eq(bad,nil,"destination collision refused")
  assert(assert(why):find("exists",1,true))
  eq(rename.plan(I.file_target(moved,root),"..escape",scan()),nil,"path traversal refused")
  eq(rename.plan(I.file_target(moved,root),"not-a-component",scan()),nil,"moving anonymous component out of component directory refused")

  files=scan()
  plan,err=rename.plan(I.file_target(view,root),"users.list",files)
  assert(plan,err)
  eq(#plan.items,8,"view rename has exact static references")
  put("app/Http/Controllers/Consumer.php",I.read(consumer) .. "// changed after preview\n")
  local applied, failure=rename.apply(plan)
  eq(applied,nil,"stale plan refused")
  assert(assert(failure):find("stale",1,true))
  eq(vim.fn.filereadable(view),1,"stale rename leaves source intact")
  edit(consumer)
  vim.cmd("edit!")
  vim.api.nvim_buf_set_lines(0,0,0,false,{"<?php // unsaved"})
  plan,err=rename.plan(I.file_target(view,root),"users.list",scan())
  eq(plan,nil,"unsaved reference buffers refused")
  assert(assert(err):find("Save modified",1,true))
  vim.cmd("edit!")
  plan,err=rename.plan(I.file_target(view,root),"users.list",scan())
  assert(plan,err)
  local original_rename = vim.uv.fs_rename
  vim.uv.fs_rename = function() return nil,"test move failure" end
  local failed, reason = rename.apply(plan)
  vim.uv.fs_rename = original_rename
  eq(failed,nil,"failed move aborts refactor")
  assert(assert(reason):find("test move failure",1,true))
  assert(I.read(consumer):find("view('users.index');",1,true),"failed rename rolls source edits back")
  eq(vim.fn.filereadable(view),1,"failed move retains original file")
  local original_select = vim.ui.select
  vim.ui.select = function(_,_,callback) callback("Cancel") end
  rename.preview(plan)
  eq(vim.fn.filereadable(view),1,"cancelled preview does not mutate files")
  eq(#vim.fn.getqflist(),#plan.items+1,"preview lists move and every reference")
  vim.ui.select = function(_,_,callback) callback("Apply rename") end
  rename.preview(plan)
  vim.ui.select = original_select
  vim.cmd("cclose")
  eq(vim.fn.filereadable(view),0,"confirmed preview applies rename")
  assert(I.read(consumer):find("view('users.list');",1,true),"PHP caller updated")
  assert(I.read(caller):find("@extends(\n  'users.list'",1,true),"multiline directive updated")
  assert(I.read(consumer):find("view('users.index' . $suffix)",1,true),"dynamic expression left unchanged")

  -- A class-backed component's render view can move without renaming its tag.
  local render_view=root .. "/resources/views/components/alert.blade.php"
  plan,err=rename.plan(I.file_target(render_view,root),"components.notifications.alert",scan())
  assert(plan,err); assert(rename.apply(plan))
  assert(I.read(alert):find("view('components.notifications.alert')",1,true),"class render reference updated")
  assert(I.read(caller):find("<x-alert",1,true),"class-backed tag identity retained")

  local dos = put("resources/views/windows.blade.php", "<p>日本語</p>\r\n")
  local dos_caller = put("resources/views/windows-caller.blade.php", "@include('windows')\r\n")
  edit(dos)
  plan,err=rename.plan(I.file_target(dos,root),"windows-renamed",scan())
  assert(plan,err); assert(rename.apply(plan))
  eq(I.read(dos_caller),"@include('windows-renamed')\r\n","CRLF references preserved")
  local linked = root .. "/resources/views/linked.blade.php"
  assert(vim.uv.fs_symlink(dos_caller,linked))
  plan,err=rename.plan(I.file_target(linked,root),"linked-new",scan())
  eq(plan,nil,"symbolic link source refused")
  local broken = root .. "/resources/views/broken.blade.php"
  assert(vim.uv.fs_symlink(root .. "/missing",broken))
  plan,err=rename.plan(I.file_target(root .. "/resources/views/windows-renamed.blade.php",root),"broken",scan())
  eq(plan,nil,"dangling destination symlink counts as collision")

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):sub(1,#root+1)==root .. "/" then vim.api.nvim_buf_delete(b,{force=true}) end
  end
  vim.fn.delete(root,"rf")
end
return M
