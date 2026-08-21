# Obsidian Bases

Use a `.base` file for dynamic views over note properties. Standardize the
properties in `conventions.md` before building a dashboard.

Use `:ObsidianKnowledgeBase` inside Neovim to open or create the standard
`bases/knowledge.base` dashboard. Create a custom Base only when its scope or
views differ materially from that dashboard.

## Minimal Shape

```yaml
filters:
  and:
    - 'file.ext == "md"'
    - file.inFolder("notes")

views:
  - type: table
    name: "Knowledge"
    order:
      - file.name
      - type
      - status
      - project
      - updated
```

Available view types are `table`, `cards`, `list`, and `map`. Use a global
filter for the Base's overall scope and per-view filters for variants such as
“Seeds”, “Evergreen”, or one project.

The complete top-level schema may also contain `formulas`, `properties`, and
`summaries`. Views may define `limit`, `filters`, `groupBy`, `order`, and
property-to-summary mappings:

```yaml
properties:
  status:
    displayName: "Status"
  formula.age_days:
    displayName: "Age"
summaries:
  mean: 'values.mean().round(1)'
views:
  - type: table
    name: "Evergreen"
    limit: 50
    groupBy:
      property: project
      direction: ASC
    summaries:
      formula.age_days: mean
```

## Filters and Properties

A filter can be one expression or a recursive object with exactly one of
`and`, `or`, or `not`. Global filters apply to every view; view filters narrow
only that view.

```yaml
filters:
  and:
    - 'file.ext == "md"'
    - or:
        - 'status == "seed"'
        - 'status == "evergreen"'
    - not:
        - 'file.hasTag("archived")'
```

Expressions support `==`, `!=`, `>`, `<`, `>=`, `<=`, `&&`, `||`, and `!`.
Use note properties directly (`status`) or as `note.status`; computed
properties use `formula.name`.

Useful file properties include `file.name`, `file.basename`, `file.path`,
`file.folder`, `file.ext`, `file.size`, `file.ctime`, `file.mtime`,
`file.tags`, `file.links`, `file.backlinks`, `file.embeds`, and
`file.properties`. Common file predicates include `file.hasTag()`,
`file.hasLink()`, and `file.inFolder()`.

`this` refers to the Base file in the main content area, the embedding note
when the Base is embedded, and the active main-content file when viewed in the
sidebar. Use it for context-sensitive dashboards rather than hard-coding a
note name.

## Useful Dashboards

- Knowledge garden: group `type: knowledge` by `status`.
- Reading inbox: show `type: reference` and `status: seed`.
- Project knowledge: filter by `project`.
- Recent captures: sort by `updated`.

## Formulas

Define a formula before referencing it as `formula.<name>`. Guard optional
properties with `if()`.

```yaml
formulas:
  age_days: 'if(created, (today() - date(created)).days, "")'
```

Date subtraction returns a duration; select `.days` before numeric operations.

Common constructors and helpers are `date()`, `now()`, `today()`, `if()`,
`duration()`, `file()`, and `link()`. Date subtraction returns a Duration with
numeric fields such as `.days`, `.hours`, `.minutes`, `.seconds`, and
`.milliseconds`; methods like `.round()` apply only after selecting a numeric
field.

```yaml
formulas:
  status_icon: 'if(status == "evergreen", "🌳", "🌱")'
  days_old: '(now() - file.ctime).days.round(0)'
  due_link: 'if(due, link(file.path, date(due).format("YYYY-MM-DD")), "")'
```

Guard optional values with `if()` before parsing, formatting, or doing date
math. Do not divide a Duration by milliseconds to obtain days.

## Views and Summaries

- `table` is best for comparing several properties and supports per-property
  summaries.
- `cards` is best for cover images and compact metadata.
- `list` is best for a lightweight index.
- `map` requires latitude/longitude data and the Maps community plugin.

Built-in summaries include `Average`, `Min`, `Max`, `Sum`, `Range`, `Median`,
`Stddev`, `Earliest`, `Latest`, `Checked`, `Unchecked`, `Empty`, `Filled`, and
`Unique`. A custom summary is defined under top-level `summaries` and receives
the column's `values` list.

Embed an entire Base with `![[knowledge.base]]` or one view with
`![[knowledge.base#View Name]]`.

## YAML and Formula Troubleshooting

- Quote strings containing YAML-significant characters such as `:`, `#`,
  `{}`, `[]`, `!`, `%`, or `@`.
- Prefer single quotes around formulas containing double-quoted strings.
- A formula referenced as `formula.X` must exist under `formulas: X:`.
- A property may be missing on some notes; add a null guard rather than
  assuming every row has it.
- If valid YAML does not render, reduce the Base to one filter and one view,
  then reintroduce formulas and view options incrementally.

## Validation

1. Parse the file as YAML.
2. Quote filter and formula expressions.
3. Ensure every displayed property exists in the conventions or is a valid
   `file.*` property.
4. Ensure every `formula.*` reference has a matching definition.
5. Check that recursive filter objects contain only one logical key at each
   level.
6. Open the Base in Obsidian to verify rendering and view-specific options.

## Authoritative References

- <https://help.obsidian.md/bases/syntax>
- <https://help.obsidian.md/bases/functions>
- <https://help.obsidian.md/bases/views>
- <https://help.obsidian.md/formulas>
