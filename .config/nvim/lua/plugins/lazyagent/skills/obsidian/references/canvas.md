# JSON Canvas

Use `.canvas` for mind maps, architecture maps, research maps, and other
spatial views. Prefer Markdown or Mermaid for a small linear diagram.

## Shape

```json
{
  "nodes": [],
  "edges": []
}
```

Each node needs a unique `id`, `type`, `x`, `y`, `width`, and `height`.
Generate lowercase 16-character hexadecimal IDs for consistency with
Obsidian, while recognizing that JSON Canvas itself only requires unique
strings. Supported node types are:

- `text` with a `text` field
- `file` with a vault-relative `file` path and optional `subpath` beginning
  with `#`
- `link` with a `url`
- `group` with optional `label`, `background`, and `backgroundStyle`

All nodes may have a `color`. Group `backgroundStyle` is `cover`, `ratio`, or
`repeat`. Array order controls z-index: earlier nodes are behind later nodes,
so place group nodes before their contents.

Each edge needs a unique `id`, `fromNode`, and `toNode`. It may include
`fromSide`, `toSide`, arrow ends, a label, and a color.

```json
{
  "id": "0123456789abcdef",
  "fromNode": "6f0ad84f44ce9c17",
  "fromSide": "right",
  "fromEnd": "none",
  "toNode": "a1b2c3d4e5f67890",
  "toSide": "left",
  "toEnd": "arrow",
  "label": "leads to"
}
```

Sides are `top`, `right`, `bottom`, or `left`; ends are `none` or `arrow`.
`fromEnd` defaults to `none` and `toEnd` defaults to `arrow`.

## Colors

A node or edge color is a CSS-style hex string or one of the presets `"1"`
through `"6"`. Presets conventionally represent red, orange, yellow, green,
cyan, and purple, but applications choose their exact display colors.

## Editing Workflow

1. Parse the existing JSON before changing it.
2. Address the node or edge by `id`, not by array position or visible label.
3. Generate an ID that does not collide with any node or edge.
4. Preserve unknown properties for forward compatibility.
5. Re-check edge endpoints and layout after adding, removing, or moving nodes.

For text nodes, encode actual line breaks as JSON `\n` escapes. Do not store a
literal backslash followed by `n`, which Obsidian displays as text.

## Layout

- Leave 50–100 pixels between nodes.
- Coordinates may be negative; `x` grows right and `y` grows down from the
  node's top-left corner.
- Align coordinates and sizes to multiples of 10 or 20 when practical.
- Keep related nodes inside labeled groups.
- Leave 20–50 pixels of padding between a group boundary and its contents.
- Use file nodes to make the Canvas an entry point into permanent notes.
- Use edge labels only when the relationship is not obvious.

## Validation

1. Parse the output as JSON.
2. Ensure node and edge IDs are globally unique.
3. Ensure every edge endpoint refers to an existing node.
4. Ensure required fields exist for each node type.
5. Validate side, arrow-end, color, and group-background enum values.
6. Ensure JSON string newlines and quotes are escaped correctly.
7. Ensure nodes do not overlap unintentionally and groups are behind their
   contents.

## Authoritative References

- <https://jsoncanvas.org/spec/1.0/>
- <https://github.com/obsidianmd/jsoncanvas>
