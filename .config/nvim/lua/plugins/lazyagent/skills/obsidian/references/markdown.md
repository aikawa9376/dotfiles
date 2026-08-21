# Obsidian Markdown

Use standard Markdown for prose and add Obsidian syntax only when it improves
navigation or scanning.

## Links

```markdown
[[Note title]]
[[Note title|display text]]
[[Note title#Heading]]
[[Note title#^block-id]]
[[#Heading in this note]]
```

Use wiki links for vault content and normal Markdown links for external URLs.
Add a stable block ID such as `^decision-auth` only when a paragraph or list
must be addressed directly.

## Embeds

```markdown
![[Note title]]
![[Note title#Heading]]
![[assets/imgs/diagram.png|600]]
![[document.pdf#page=3]]
```

Prefer a link over an embed when readers only need optional detail.

Use `#Heading` and `#^block-id` to embed only part of a note. Image embeds may
specify width (`|600`) or width and height (`|600x400`). Audio, video, PDF, and
other supported vault files use the same `![[path]]` form.

## Callouts

```markdown
> [!summary] Conclusion
> The durable conclusion.

> [!warning]- Caveat
> Collapsed details.
```

Use callouts sparingly for conclusions, warnings, examples, or actionable
follow-ups. Do not turn every section into a callout.

Callout type names are case-insensitive. Common built-in types include
`note`, `abstract`, `info`, `todo`, `tip`, `success`, `question`, `warning`,
`failure`, `danger`, `bug`, `example`, and `quote`. Use `+` after the title to
make a foldable callout initially expanded and `-` to make it collapsed.

## Properties

Properties are YAML frontmatter at the very top of the note. Supported values
include text, numbers, checkboxes, dates, date-times, lists, and links. A
property must keep one type across the vault so Bases and Properties views can
interpret it consistently.

```yaml
---
aliases:
  - Alternate title
tags:
  - project/example
status: seed
created: 2026-08-21
published: false
related:
  - "[[Another note]]"
---
```

Quote wikilinks in YAML. Do not use Markdown formatting in property keys, and
do not place blank content before the opening `---`. Follow `conventions.md`
for this vault's standard properties and preserve unknown properties when
editing an existing note.

## Tags, Comments, and Footnotes

- Tags may contain letters, numbers, `_`, `-`, and `/`; they cannot be only
  numeric. Nested tags use `/`, such as `#project/lazyagent`.
- Use properties for stable facets and wikilinks for concepts. Avoid creating
  a large tag taxonomy when links or properties are clearer.
- Hide non-rendered text with `%% inline comment %%` or a multiline `%%` block.
- Create footnotes with `[^1]` and `[^1]: Definition`. Inline footnotes use
  `^[text]`.

## Math and Diagrams

Inline math uses `$...$`; display math uses `$$...$$`. Mermaid diagrams use a
fenced `mermaid` block. To link a Mermaid node to a vault note, use an
`internal-link` class and a note URL only when the target renderer supports it.
Keep diagrams small enough to remain understandable in source form; use a
Canvas for a primarily spatial, navigable map.

## Other Useful Syntax

- Highlight a short phrase with `==text==`.
- Hide editor-only context with `%% comment %%`.
- Use `~~text~~` for strikethrough and `<u>text</u>` only when underlining is
  semantically necessary.
- Use Mermaid for small diagrams that belong inside one note.
- Use a Canvas instead when the diagram is primarily a navigable map of notes.

## Validation

1. Keep frontmatter at the top and valid YAML.
2. Ensure every intended internal link uses `[[...]]`.
3. Check that embed paths are relative to the vault.
4. Avoid links to nonexistent notes unless creating a deliberate future note.
5. Keep the note readable as plain Markdown outside Obsidian.
6. Preserve property types and quote YAML values containing wikilinks, colons,
   `#`, or other YAML-significant characters.
7. Verify callouts, embeds, math, and Mermaid in Reading view when used.

## Authoritative References

- <https://help.obsidian.md/obsidian-flavored-markdown>
- <https://help.obsidian.md/links>
- <https://help.obsidian.md/embeds>
- <https://help.obsidian.md/callouts>
- <https://help.obsidian.md/properties>
