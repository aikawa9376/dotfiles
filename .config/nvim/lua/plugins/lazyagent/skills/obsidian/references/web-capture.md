# Web Capture

Use this workflow to turn an article or documentation URL into durable
knowledge. Do not save a full article unless the user explicitly requests an
archive copy.

## Extract

Prefer the bundled Defuddle launcher:

```sh
"$LAZYAGENTBIN/defuddle" parse "https://example.com/article" --markdown
```

For metadata:

```sh
"$LAZYAGENTBIN/defuddle" parse "https://example.com/article" --json
```

The launcher uses a pinned Defuddle version through `npx`. Its first run may
need network access and populate the npm cache. If it is unavailable, use the
agent's normal web-reading tool and continue with the same note workflow.

Do not use Defuddle for a URL that already returns raw Markdown.

## Distill

1. Preserve the canonical URL, title, author, and publication date when known.
2. Summarize the central claim in the agent's own words.
3. Capture only reusable details, examples, and caveats.
4. Add a short “Why this matters” section tied to existing projects or notes.
5. Separate the source's claims from the agent's inference.

## Save

Create or update a `type: reference` note with:

```yaml
source: web
status: seed
source_url: https://example.com/article
```

Link related permanent notes and add the reference note to today's daily note.
Use short quotations only when exact wording is important.
