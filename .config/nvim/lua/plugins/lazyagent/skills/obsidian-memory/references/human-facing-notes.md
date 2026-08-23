# Human-facing Notes

Read this reference only when the user explicitly asks for agent knowledge to
be summarized into a regular note, documented for people, promoted, or made
into a human-facing specification. This boundary does not apply to maintaining
agent memory. A request to answer, investigate, or summarize within the
conversation is not authorization to create a regular human-facing note.

Keep durable specifications and designs in agent memory by default. When the
user requests a human-facing document:

1. Search the regular `notes/` hierarchy for the canonical owner and update it
   before creating another note.
2. Choose scope by the lifetime of the knowledge:
   - project-wide or branch-independent knowledge belongs to project-level
     canonical notes;
   - branch-specific proposals, temporary deviations, and unfinished designs
     belong to the corresponding project or branch note;
   - once accepted as project behavior, promote branch-scoped design into the
     project-level specification and remove or supersede the temporary version.
3. When several files are required, create a coherent specification directory
   with a clear index identifying the canonical documents.
4. Keep agent memory concise and link it to the human-facing specification
   instead of duplicating the full text.
5. Replace stale statements and verify the promoted content against current
   code, tests, and authoritative sources.
