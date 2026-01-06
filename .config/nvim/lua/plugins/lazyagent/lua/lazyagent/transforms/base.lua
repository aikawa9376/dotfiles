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
    trans = "- Make minimal changes to correct the issue. Avoid refactoring, style changes, or modifying unrelated code. Keep the scope of the change as small as possible."
  }
}
