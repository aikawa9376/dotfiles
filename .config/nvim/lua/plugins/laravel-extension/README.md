# Laravel extension

Navigation and refactoring for the Laravel conventions that sit outside PHP LSP
symbols. Requires ripgrep, the PHP Tree-sitter parser and fzf-lua. Completion uses
the `laravel_extension` Blink provider (`[LV]`) configured in `plugins/blink.lua`.

## References and routes

- `gr` in a Blade view lists its callers, with preview, split actions and Ctrl-Q
  to quickfix. On a view-name literal or component tag, it searches that target.
- `gr` on a Blade component PHP class name merges PHP LSP references and Blade
  tags. Livewire class declarations also support tag/directive usage search.
- `gr` on a controller method declaration lists matching route definitions,
  showing HTTP methods, URI and route name. Inside an ordinary PHP expression,
  `gr` keeps its normal LSP behavior.
- `:LaravelReferences` invokes the same reference dispatcher.
- `:LaravelControllerRoutes` works anywhere inside a controller method.

View searches cover static `view()`, `View::make/first`, `Route::view`,
`response()->view`, Blade include/extends/each/component directives, and
Blade/Livewire tags. Comments, verbatim blocks, unrelated strings and dynamic
expressions are excluded. Loaded unsaved source buffers participate in searches.

Route lookup supports conventional controller paths, imported class aliases,
array/invokable/legacy string actions, controller groups, nested static
prefix/name groups, match/any, resource/apiResource and only/except filters.
Resource URI labels use `{id}` as a placeholder; custom route registration,
macros, computed prefixes and resource parameter/name overrides are not resolved.
This lookup does not boot the application or execute Artisan.

## Blade and Livewire members

- In `<x-alert ...>`, constructor inputs and public properties become kebab-case
  attribute candidates. Anonymous components use `@props`. Existing attributes
  are omitted, including bound `:attributes`.
- Livewire tag attributes complete public properties. Inside a Livewire view,
  `wire:model.*` completes properties and action directives such as `wire:click`
  and `wire:submit` complete public methods. `$wire.member` also completes,
  including inside Alpine attributes.
- `gd` (and the extension's existing `df`) on a component attribute or Livewire
  member jumps to its PHP declaration or `@props` entry.

Livewire ownership uses standard class/view conventions and static render-view
references, including custom view names. Public members inherited from local
PSR-4 parent classes are included. Trait/vendor inheritance, runtime registrations,
Volt anonymous classes and nested form-object member types are not inferred.

## Rename and move a Blade view

Open the view and press `<Leader>rn`, or run:

```vim
:LaravelRenameView users.list
:LaravelRenameView components.forms.panel
```

The new name is relative to `resources/views` and uses Laravel dot notation.
Namespaced overrides accept `package::view.name`. Quickfix previews the move and
every static reference, followed by an Apply/Cancel picker. Renaming an anonymous
component updates its opening and closing tags. Moving a class-backed render view
updates the class's view string while retaining the PHP class/tag identity.

All participating buffers must be saved. Destination collisions, symbolic-link
files and stale previews are rejected. Source edits are restored if a write or
move fails. Existing line endings are preserved and loaded buffers follow the
move. Anonymous components must stay under their component directory.

Use this command for a coordinated move; external file-manager moves are not
watched. PHP class renames remain with the PHP LSP. Dynamic view expressions and
custom registrations require separate review.

## Validation

```sh
nvim --headless -u NONE -l .config/nvim/lua/plugins/laravel-extension/tests/run.lua
```

The tests use temporary Laravel projects, real rg and PHP parsers, and check
reference dispatch, route resolution, Blink responses, declaration jumps and
refactoring including cancellation, dirty buffers, stale previews and rollback.
They do not execute a Laravel application.
