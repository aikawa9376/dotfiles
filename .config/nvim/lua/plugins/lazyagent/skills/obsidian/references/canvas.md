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

Each node needs a unique lowercase 16-character hexadecimal `id`, `type`,
`x`, `y`, `width`, and `height`. Supported node types are:

- `text` with a `text` field
- `file` with a vault-relative `file` path
- `link` with a `url`
- `group` with an optional `label`

Each edge needs a unique `id`, `fromNode`, and `toNode`. It may include
`fromSide`, `toSide`, arrow ends, a label, and a color.

## Layout

- Leave 50–100 pixels between nodes.
- Keep related nodes inside labeled groups.
- Use file nodes to make the Canvas an entry point into permanent notes.
- Use edge labels only when the relationship is not obvious.

## Validation

1. Parse the output as JSON.
2. Ensure node and edge IDs are globally unique.
3. Ensure every edge endpoint refers to an existing node.
4. Ensure required fields exist for each node type.
5. Ensure nodes do not overlap unintentionally.
