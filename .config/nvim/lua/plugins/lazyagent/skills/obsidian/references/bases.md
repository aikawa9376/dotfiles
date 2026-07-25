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

## Validation

1. Parse the file as YAML.
2. Quote filter and formula expressions.
3. Ensure every displayed property exists in the conventions or is a valid
   `file.*` property.
4. Ensure every `formula.*` reference has a matching definition.
5. Open the Base in Obsidian to verify rendering.
