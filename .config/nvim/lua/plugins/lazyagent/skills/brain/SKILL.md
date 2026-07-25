---
name: brain
description: Search past conversation history with ai-memory-cli. Use when the user's request lacks context likely captured in prior sessions, when they ask about earlier decisions, or when a repeated or unclear failure may have a known prior resolution. Do not use routinely at the start of a task.
---

# brain

Leverage past experiences and solutions using the `ai-memory-cli` tool. This allows you to perform hybrid (vector + full-text) searches across all previous sessions and projects. First try `ai-memory-cli` directly; if it is not on `PATH`, use `$LAZYAGENTBIN/ai-memory-cli`.

## Instructions

Use this skill only when the current conversation and repository do not provide enough context and past sessions are likely to contain the missing information. Typical cases include:

- The user refers to earlier work or asks why a previous decision was made.
- A repeated or unclear error may already have been investigated.
- Important historical constraints cannot be recovered from the current code or documentation.

Do not use it merely because a task has started, code is being edited, or local patterns need to be found.

### Available Commands

- **[search](references/search.md)**: Perform a hybrid search for past Q&A.
- **[save](references/save.md)**: Manual save or ACP auto-save setup.
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
