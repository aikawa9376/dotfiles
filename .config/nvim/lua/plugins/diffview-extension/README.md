# Diffview context and GitHub integration

The lualine component describes the displayed comparison rather than only its
rightmost commit. Git metadata is loaded asynchronously and cached per view/tab;
rendering the statusline performs no Git or GitHub queries. Commit subjects remain
visible: long range labels and counts shorten first to reserve message space,
then long subjects shorten to fit. Both endpoint hashes remain in compact range
labels; the left panel retains full endpoints and subjects.

| Comparison | Statusline context |
| --- | --- |
| Single commit (`SHA^!`, first-parent `SHA^..SHA` / `parentSHA..SHA`) | Short hash and subject |
| Commit range (`A..B`) | Both endpoints, commit count and tip subject |
| Three-dot range (`A...B`) | Requested range and count; left panel identifies the actual merge-base hash |
| Divergent endpoints | `-N/+M commits`, the left-only/right-only counts |
| Default working-tree diff | `index → working tree` |
| Staged diff / selected staged file | `HEAD → index`, or the actual chosen base |
| A revision against the working tree | Revision → working tree and its subject |
| FileHistory | Currently selected commit and subject, following commit selection |
| FileHistory pinned to local | Selected historical revision → working tree |
| Saved/custom review snapshot | `Snapshot` and its captured endpoints |
| Conflict view | Comparison plus conflicting-file count |

Counts describe commit reachability between the actual endpoints. They are not
changed-file/line counts, and a file-filtered comparison still describes the
whole revision range. Custom snapshots identify their provenance, not a live
working-tree diff. Displayed comparison context and async requests are replaced
when either endpoint, repository, selected FileHistory commit or view changes.

The left file/history panel adds `Comparison` and `Related PRs` components after
the native entries. Native file/directory identity maps remain intact. PR rows
show a colored state icon, number and title, and participate in normal `j` / `k`
navigation. Enter/double-click on a PR opens the native Git PR screen; Enter on
a file keeps Diffview's file action.

| Key | Action |
| --- | --- |
| `gp` | Open a related PR, selecting among several when needed |
| `gA` | Existing GitHub action menu for the selected related PR |
| `gR` | Refresh related PRs |

These keys work in diff buffers, the file panel and the history panel. The PR
screen provides conversation, reviews, metadata and CI operations. Its `D`
action opens Diffview with that PR association preserved. Changing the range
invalidates this explicit association and discovers relationships for the new
comparison instead.

Relationships use GitHub's paginated
[commit-associated PR endpoint](https://docs.github.com/en/rest/commits/commits#list-pull-requests-associated-with-a-commit).
Single/history comparisons check the chosen commit; ranges check up to the most
recent 20 commits differing between the endpoints (both sides for divergent
or reversed comparisons), with at most four concurrent reads. The panel states
the scanned count and explicitly marks bounded or incomplete lookups. Mutable
views additionally include an open PR for the captured branch, including a local
head that has not been pushed. Results are deduplicated by PR URL and cached for
two minutes; `gR` and native `GitHubChanged` events refresh them. Repository/host
come from the captured view, and historical comparisons skip current-branch PR
URL inference. Closing or changing a view cancels obsolete reads; GitHub failures
leave the diff readable and provide a retry action.

Verification uses real temporary Git repositories and installed Diffview with
mocked GitHub responses; it does not perform live GitHub mutations. Run:

```sh
nvim --headless --clean -u NONE -i NONE -l tests/run.lua
nvim --headless --clean -u NONE -i NONE -l tests/comparison.lua
nvim --headless --clean -u NONE -i NONE -l tests/github_context.lua
```

The existing custom-review and commit-navigation smoke checks require the full
Neovim configuration. Review annotations retain their existing ownership and
are separate from GitHub PR discovery.
