# Human-facing Notes

Use this reference when the user requests regular documentation or promotion
of agent knowledge into a human-facing specification. Answering or investigating
in conversation does not itself request a regular note; agent memory can still
be maintained.

Search regular `notes/` for the canonical owner and update it before creating
another document. Match scope to the knowledge's lifetime:

- Project behavior and accepted design belong in the project specification.
- Branch-specific proposals, deviations, and unfinished designs stay scoped to
  that branch. Integrate accepted behavior into the project specification and
  remove or supersede the temporary version.
- When a specification needs several files, provide an index identifying their
  responsibilities.

Verify the promoted content against current evidence, then make agent memory
point to the specification, retaining only missing durable context.
