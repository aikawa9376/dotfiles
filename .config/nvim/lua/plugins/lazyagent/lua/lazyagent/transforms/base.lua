return {
  {
    name = "analysis",
    desc = "Analyze the current state and provide insights",
    trans = "- Analyze the current changes and provide concise insights or next steps."
  },
  {
    name = "ask",
    desc = "Ask a question about the code without requesting changes",
    trans = "- This is a question, not a request for code changes. Please explain the code or investigate the issue as requested."
  },
  {
    name = "refactor",
    desc = "Refactor code across a path or the entire repository while preserving behavior",
    trans = "- Refactor selected code to improve readability, remove duplication, and improve naming while preserving behavior.\n- If a filename or directory path is provided after the token, restrict the refactor to that path; if no path is provided, operate on the entire repository (git root)."
  },
  {
    name = "generate-tests",
    desc = "Generate unit tests for the files under a path or the whole repository",
    trans = "- Generate unit test stubs or examples for the given file/path.\n- If no path is provided, consider generating tests for the repository's public modules or the main code paths; detect the project's test framework and conventions where possible."
  },
  {
    name = "cleanup",
    desc = "Detect and suggest removal of dead or unused code and tidy imports",
    trans = "- Detect obvious dead/unused code, unreachable branches, and unused imports/variables; propose suggested removals or simplifications with example snippets."
  },
  {
    name = "explain",
    desc = "Explain the code or function in simple terms with usage examples",
    trans = "- Explain the selected code or the file's main responsibilities in human-friendly terms and include examples when useful."
  },
  {
    name = "optimize",
    desc = "Suggest performance/memory improvements for critical code paths",
    trans = "- Suggest optimizations focusing on time and memory usage for hot paths in the provided path or repository; include a short complexity analysis when appropriate."
  },
  {
    name = "document",
    desc = "Generate or improve docstrings and README examples for the project",
    trans = "- Add or improve docstrings for functions, methods, and modules and update README or usage examples if relevant."
  },
  {
    name = "obsidian",
    desc = "Turn the durable result into a linked Markdown note in the Obsidian vault",
    trans = table.concat({
      "- After completing the requested work, use the `obsidian` skill to turn the durable result into reusable Markdown knowledge in the Obsidian vault.",
      "- Treat the surrounding request as the subject to capture. If an exact title, path, or body is requested, honor it; otherwise distill the result instead of copying the raw conversation.",
      "- Search the vault before writing. Update and link an existing note when it covers the same concept; otherwise create a small permanent note under `notes/` using the vault's frontmatter and H1 conventions.",
      "- Capture the conclusion, reasoning or decisions worth remembering, useful references, and concrete follow-ups. Omit transient logs and chat scaffolding.",
      "- Add useful `[[wiki links]]` to related notes and link the permanent note from today's daily note.",
      "- When Git repository context is available, set `source: lazyagent`, `project`, and `branch` properties on the permanent note. Do not encode repository or branch names as tags.",
      "- For repository work, open or create the matching `notes/projects/<repo>/<branch>.md` branch note and add the permanent note once under `## AI notes`; do not skip this because the branch note is missing.",
      "- When the subject includes a web URL, follow the skill's web-capture workflow. Use a Base for a property-driven overview or a Canvas for a spatial map only when the request benefits from that form.",
      "- Save this transform as Markdown only. Do not create an HTML artifact unless the user chooses the separate obsidian-html transform.",
      "- Report which note files were created or updated and which navigation links were added.",
    }, "\n")
  },
  {
    name = "obsidian-html",
    aliases = { "obsiditan-html" },
    desc = "Create an Obsidian Markdown summary with a polished companion HTML artifact",
    trans = table.concat({
      "- After completing the requested work, use the `obsidian` skill and follow its HTML-artifact workflow.",
      "- Treat the surrounding request as the subject. Search the vault first and update an existing matching report when possible.",
      "- Create a concise canonical Markdown summary under `notes/` containing the durable conclusions, sources, follow-ups, and useful `[[wiki links]]`.",
      "- Create or update its polished self-contained HTML companion under `assets/html/`, and set the Markdown note's `type: report` and vault-relative `artifact` property.",
      "- Link the Markdown summary from today's daily note.",
      "- When Git repository context is available, set `source: lazyagent`, `project`, and `branch` properties on the Markdown summary. Do not encode repository or branch names as tags.",
      "- For repository work, open or create the matching `notes/projects/<repo>/<branch>.md` branch note and add the Markdown summary once under `## AI notes`; do not skip this because the branch note is missing.",
      "- Report both Markdown and HTML paths and the navigation links added.",
    }, "\n")
  },
  {
    name = "format",
    desc = "Format files using canonical language-specific formatters",
    trans = "- Reformat code according to common formatting tools (e.g., black, prettier, gofmt) or the project's configured style."
  },
  {
    name = "lint",
    desc = "Run quick static analysis heuristics and provide suggested fixes",
    trans = "- Analyze code for common lints and stylistic issues; present a list of problems and suggested fixes, including example snippets if helpful."
  },
  {
    name = "security",
    desc = "Perform a brief security-focused scan",
    trans = "- Scan for common security pitfalls (e.g., insecure deserialization, unsafe eval, neglected input validation) and propose mitigations when applicable."
  },
  {
    name = "changelog",
    desc = "Produce a concise commit message or changelog entry summarizing changes",
    trans = "- Summarize the intended or actual changes into a short commit message (one-line subject and 1–2 sentence body) and a changelog bullet point that explains the motivation and effect of the change."
  },
  {
    name = "commit",
    desc = "Commit staged changes with a descriptive message",
    trans = "- Stage all changes and commit them with a concise and descriptive message, following project conventions."
  },
  {
    name = "diffstyle-code",
    desc = "Propose changes using git conflict markers",
    trans = "- Do not apply changes directly. Instead, insert git conflict markers (<<<<<<<, =======, >>>>>>>) into the file to show the proposed changes (incoming) against the current code (current). This allows the user to review and resolve the changes using a conflict resolution tool."
  },
  {
    name = "small-fix",
    desc = "Request a small, targeted fix with minimal scope",
    trans = "- Make minimal changes to correct the issue. Avoid refactoring, style changes, or modifying unrelated code. Keep the scope of the change as small as possible. This is a light fix intended to be finished within 5 seconds. Prioritize speed."
  }
}
