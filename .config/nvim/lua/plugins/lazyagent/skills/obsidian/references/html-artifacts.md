# HTML Artifacts

Use this workflow for `#obsidian-html` or an explicit request for an HTML
companion. Create two coordinated files:

1. A canonical Markdown note under `notes/` for search, properties, wiki links,
   Bases, and long-term editing.
2. A standalone HTML artifact under `assets/html/` for polished reading,
   printing, or interaction.

Unless the user explicitly asks for HTML only, always create the Markdown
companion. A plain `#obsidian` request is Markdown-only and must not trigger
this workflow.

## Pairing

Use a stable, descriptive slug for the artifact:

```text
notes/<note-id>.md
assets/html/<topic-slug>.html
```

Set these properties on the Markdown note:

```yaml
type: report
artifact: assets/html/<topic-slug>.html
```

Include a correctly resolved Markdown link to the artifact in the note. Add
the durable summary, conclusions, sources, and related `[[wiki links]]` to the
Markdown note; do not make the HTML file the only place where knowledge lives.

## HTML Defaults

- Produce a single self-contained file with inline CSS and, when needed,
  inline JavaScript.
- Use semantic HTML, responsive layout, readable typography, accessible
  contrast, keyboard-friendly controls, and print styles.
- Support light and dark color schemes with `prefers-color-scheme`.
- Avoid frameworks, build steps, remote fonts, CDNs, and external runtime
  dependencies unless the user requests them.
- Treat scripts as executable content. Never include untrusted third-party
  scripts or copied inline event handlers.
- Prefer static HTML when interaction does not materially improve the document.

## Validation

1. Verify the HTML has a title, one main region, logical heading order, and no
   broken local asset references.
2. Verify the Markdown `artifact` property points to the generated file.
3. Confirm the Markdown note remains useful when the HTML cannot be opened.
4. Open the artifact in a browser when possible and check narrow and wide
   layouts plus print output.
5. Report both created or updated paths.

In Neovim, use `:ObsidianOpenArtifact` from the companion note to open its
`artifact` property with the system browser.
