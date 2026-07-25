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

## Callouts

```markdown
> [!summary] Conclusion
> The durable conclusion.

> [!warning]- Caveat
> Collapsed details.
```

Use callouts sparingly for conclusions, warnings, examples, or actionable
follow-ups. Do not turn every section into a callout.

## Other Useful Syntax

- Highlight a short phrase with `==text==`.
- Hide editor-only context with `%% comment %%`.
- Use Mermaid for small diagrams that belong inside one note.
- Use a Canvas instead when the diagram is primarily a navigable map of notes.

## Validation

1. Keep frontmatter at the top and valid YAML.
2. Ensure every intended internal link uses `[[...]]`.
3. Check that embed paths are relative to the vault.
4. Avoid links to nonexistent notes unless creating a deliberate future note.
5. Keep the note readable as plain Markdown outside Obsidian.
