---
name: brain
description: Search and retrieve knowledge from past conversation history. Use this autonomously at the start of a task, when encountering errors, or to find existing code patterns.
---

# brain

Leverage past experiences and solutions using the `ai-memory-cli` tool. This allows you to perform hybrid (vector + full-text) searches across all previous sessions and projects. First try `ai-memory-cli` directly; if it is not on `PATH`, use `$LAZYAGENTBIN/ai-memory-cli`.

## Instructions

You SHOULD use this skill **autonomously** to enhance your performance and avoid repeating past efforts.

### When to Use

- **Task Initiation**: Before starting a new feature or refactor, search for related past discussions or implementations.
- **Error Troubleshooting**: When facing an error message, search for it to see how you or the user resolved it previously.
- **API/Library Reference**: If you've used a specific library before, search for code snippets to recall the correct usage.
- **Pattern Discovery**: Find past architectural decisions or design patterns to ensure consistency.

### Available Commands

- **[search](references/search.md)**: Perform a hybrid search for past Q&A.
- **[save](references/save.md)**: Manual save (rarely needed as hooks handle this).
- **[commands](references/commands.md)**: Full command reference.

## Guidelines

- **Query Quality**: Use natural Japanese or English sentences for better vector search results.
- **Context Filtering**: Use `--current-project` when you want to focus only on the current repository's history.
- **Score Interpretation**: Higher RRF scores indicate higher relevance. Focus on the top 1-3 results.

## Examples

### 1. Searching for an error solution
```bash
$LAZYAGENTBIN/ai-memory-cli search "Rust async sqlx error: cannot borrow as mutable"
```

### 2. Finding past usage of a library
```bash
$LAZYAGENTBIN/ai-memory-cli search "How to use fastembed with custom ONNX model"
```
