# brain search

Retrieve related knowledge from past conversations using hybrid search (Vector + Full-Text).

## Syntax

```bash
BRAIN="$LAZYAGENTBIN/ai-memory-cli"
$BRAIN search "<query>" [--current-project]
```

## Instructions for Use

### Appropriate Scenarios

- **Missing Context**: Search when the user refers to prior work that is not explained in the current conversation.
- **Repeated or Unclear Errors**: Search the exact error message or a description when a prior investigation is likely.
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
