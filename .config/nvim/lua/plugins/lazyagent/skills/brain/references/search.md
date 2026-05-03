# brain search

Retrieve related knowledge from past conversations using hybrid search (Vector + Full-Text).

## Syntax

```bash
BRAIN="$LAZYAGENTBIN/ai-memory-cli"
$BRAIN search "<query>" [--current-project]
```

## Instructions for Use

### Autonomous Scenarios
- **Start of Task**: Search for "How did I implement [feature] last time?" or "[library] usage examples".
- **Facing Errors**: Search the exact error message or a description of the bug.
- **Decision Retrieval**: Search for "Why did we choose [X] over [Y]?"

### Query Best Practices
- **Use Natural Language**: "Fastembed を使ったベクトル検索の実装例"
- **Be Specific**: Include library names, error codes, or specific logic.
- **Language**: Optimized for Japanese (ruri-v3), but English also works.

## Examples

```bash
# Search across everything
$BRAIN search "Playwright を使った SPA のログイン自動化"

# Search in current project context
$BRAIN search "embedding model dimension" --current-project
```
