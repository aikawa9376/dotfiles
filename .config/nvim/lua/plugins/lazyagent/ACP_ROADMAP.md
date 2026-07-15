# LazyAgent ACP roadmap

> Status: in progress — Milestone 0
> Last reviewed: 2026-07-15

この文書は、LazyAgent の ACP 機能を Zed の External Agent 相当まで高めつつ、
tmux / agentmux、provider 切替、mobile、brain 連携といった既存の強みを伸ばすための実装計画です。

一般的な保守・削除候補・multi-instance 課題は [TODO.md](TODO.md) で管理します。

## Target

まず Zed Native Agent 固有機能ではなく、External ACP client として次を実現します。

- 同じ provider でも複数の conversation thread を並列実行できる。
- Neovim を終了しても thread 一覧と native session identity が残り、再開できる。
- agent が加えた変更を turn / file / hunk 単位で確認し、安全に Keep / Reject できる。
- ACP stable v1 の capability に応じて session、config、auth、multimodal、MCP を提供する。
- project / worktree / status を横断して確認できる Session Cockpit を持つ。
- ACP未対応機能を表示せず、unstable機能は feature flag の後ろに隔離する。

## Current baseline

すでに実装済みの主な土台:

- ACP JSON-RPC、streaming transcript、prompt / cancel。
- `session/new`, `list`, `load`, `resume`, `close`。
- filesystem read/write、terminal lifecycle、permission request。
- message / thought / plan / tool / config / usage update の表示。
- model / mode / config picker、slash command palette。
- native session import、conversation carryover、provider switch。
- transcript compaction、tool timeline、quickfix annotation、diff preview。
- buffer / tmux view、agentmux integration、mobile prompt / interrupt。

主な構造的不足:

- session が agent 名を主キーとしており、同じ provider の複数threadを第一級に扱えない。
- native resume と、transcript を次promptへ注入するlocal carryoverが同じ「再開」として見えやすい。
- ACP edit review はreadonly diff中心で、変更を安全に戻すtransaction journalがない。
- ACP stable v1の新しいcapabilityとJSON-RPC lifecycleに未対応部分がある。
- filesystem root boundary、mobile認証、multi-instance teardownに安全性課題がある。
- ACP専用のprotocol / lifecycle regression testがない。

## Design decisions

### Thread identityをprocess/providerから分離する

永続化の主キーはlocal UUIDの`thread_id`とし、最低限次を保持します。

- `thread_id`
- `provider_id`
- `native_session_id`（providerが返す場合のみ）
- `process_id`（thread identityとは別物）
- `cwd` / `additional_directories`
- `title`, `status`, `created_at`, `updated_at`, `archived_at`
- transcript path、draft、unread state
- model / mode / config snapshot
- checkpoint / change journal metadata

process-per-threadと、1 ACP connection内のmulti-sessionのどちらも選べるようにし、
UIや永続データがprocess構成へ依存しない設計にします。

### Capability-drivenを徹底する

- capabilityが省略または`false`なら非対応として扱う。
- session list/load/resume/delete、image、audio、embedded context、boolean config、MCP、authを個別判定する。
- unsupported UIはdisabled表示より、原則として非表示にする。
- provider固有拡張はnormalized stateのmetadataへ隔離する。

### ProtocolとUIの間にnormalized stateを置く

ACPイベントを直接view stateへ書き込まず、次の内部モデルへ正規化します。

- Thread / Turn / Message
- ToolCall / Permission / Terminal
- Plan / ConfigOption / Usage
- ContentBlock / ContextItem
- FileChange / Checkpoint

当面はstable v1 adapterだけをproduction経路とし、ACP v2は別adapter + feature flagにします。

### Checkpointの意味を分ける

- workspace checkpoint: client側で実装し、agentが変更したfile stateだけを戻す。
- model history rewind: providerに明示的な能力がある場合だけ提供する。

generic ACP agentに対して、会話履歴まで巻き戻ったようには見せません。

## Milestone 0 — Safety and protocol kernel

目標: 新機能を載せても壊れ方を検出でき、host境界を越えて操作できない状態にする。

### Contract tests

- [x] newline分割、複数message同時受信、invalid/unknown updateを再現するfake ACP agentを追加する。
- [x] initialize、new/prompt/cancel、load/resume/close、permission、terminal、filesystemのgolden testを追加する。
- [x] process exit、timeout、late update、pending permission中cancelのtestを追加する。
- [ ] repeated open/close、provider switch、resession、2 Neovim instanceのlifecycle testを追加する。
  - [x] 反復open/closeと並列2 connectionでprocess/timer/callbackのzero-leakを検証する。
- [x] timer、callback、session view、transcript、child processの残存数をdebug表示できるようにする。
  - [x] client process、stdio、timer、callback、permission、stdout bufferをruntime debug snapshotへ追加する。
  - [x] backend全体のsession / transcript ownership / terminal / child processとbuffer viewのresource snapshotを追加する。

### Stable v1 completion

- [x] capabilityの`false`をsupport扱いしない。
- [x] initialize responseのprotocol versionを検証し、不一致時はagent processを停止する。
- [x] JSON-RPC request timeoutと`$/cancel_request`を実装する。
- [x] cancel後のlate update、tool、permissionを正しく終端するstate machineを実装する。
- [x] optionalな`messageId`でassistant / thought messageを束ね、未対応agentは従来heuristicへfallbackする。
- [x] `session/delete`と`additionalDirectories`をclient APIへ実装する。
- [x] authentication method picker、auth-required retry、capability-gated logout flowを実装する。
- [x] `session.configOptions.boolean`をadvertiseし、select / booleanを共通UIで扱う。
- [ ] image / audio / resource / resource_linkを入力・出力とも完全に扱う。
  - [x] `@media`をcapability-gated Image/Audio blockへloweringし、output payloadを安全にmetadata表示する。
- [x] unknown method / update variantをbounded protocol logへ残しつつconnectionを維持する。

### Host security

- [x] filesystem pathをrealpath化し、cwd / additional roots外とsymlink escapeを拒否する。
- [x] writeをatomic化し、unsaved buffer・encoding・改行・同時編集の競合を検出する。
- [x] terminal cwdとpermission scopeを検証し、cancel時にkill/releaseまで保証する。
  - [x] terminal cwdをfilesystem roots内に制限し、cancel/close/process exitでkill/releaseする。
  - [x] filesystem・terminal・permission requestをactive/pending session IDへ束縛する。
- [x] mobileにrandom bearer token、Origin/CORS検証、request body上限を追加する。
- [x] mobileの既定bindをlocalhostに固定し、LAN公開時は警告と明示設定を要求する。

### Exit criteria

- fake agentのprotocol/lifecycle suiteがheadless Neovimで安定して通る。
- root外read/writeと未認証mobile操作が失敗する。
- 異常終了、cancel、100回のopen/close後にprocess/timer/callbackが残らない。

## Milestone 1 — Thread kernel and seamless resume

目標: `agent名 = active session`から`thread UUID = conversation`へ移行する。

- [x] `ThreadStore`とversion付きmanifest schemaを追加する。
  - [x] atomic publishに加えてmulti-Neovim read-modify-write lock、timeout、stale lock回収を追加する。
- [x] current session stateをthread-scoped stateへ分割する。
  - [x] backend sessionへlocal `thread_id`を割り当て、native session / process / transcript lifecycleを永続同期する。
- [x] provider process、native ACP session、view bufferをthreadから分離する。
- [x] 同じproviderの複数threadを同時起動できるようにする。
- [x] threadのnew / open / close / archive / restore / rename / deleteを実装する。
  - [x] atomic manifest上のcreate / update / archive / restore / rename / delete contractを追加する。
  - [x] 既存UUIDのprovider検証付きopenとtranscript再利用、stale process exitの競合防止をbackendへ統合する。
  - [x] `:LazyAgentACPThreads` pickerと`:LazyAgentACPThreadNew` / `ThreadOpen` commandを追加する。
- [x] provider native sessionのlist/importをthread storeへ統合する。
  - [x] native session pickerからprovider / native session IDで重複排除してThreadStoreへimportする。
- [x] 再開時は`resume`、`load`、local carryoverの順にcapability-drivenで選ぶ。
- [x] native resumeとlocal carryoverをUI上で明確に区別する。
- [x] draft、scroll position、selected config、unread stateをthread単位で保存する。
  - [x] draft、selected config、read/unreadをThreadStoreへ同期し、scratch open/closeとbackground outputへ接続する。
  - [x] buffer viewのcursor / topline / horizontal scroll / follow-outputをthread単位でcapture / restoreする。
- [x] 既存のagent名ベースcommandを互換adapter経由で動かす。
  - [x] `provider::thread_uuid` runtime keyと直近active threadへのprovider aliasをlaunch / send / ACP targetへ統合する。

### Exit criteria

- 同じproviderの2threadを並列実行できる。
- Neovim再起動後に一覧から元のnative sessionを継続できる。
- 片方のNeovim/sessionを閉じても、別instanceの同名providerに影響しない。
- providerがresume非対応の場合、fallback方式がユーザーへ明示される。

## Milestone 2 — Transactional changes and review

目標: userの既存変更とagent変更を分離して確認・復元できるようにする。

- [x] prompt開始時にworkspace manifestとdirty/untracked stateを記録する。
  - [x] Git HEAD / tracked / untracked / index・worktree statusとfile statをturn baselineとしてThreadStoreへ永続化する。
  - [x] 非Git workspaceは上限付きfilesystem manifestへfallbackし、採取失敗でprompt送信を止めない。
- [x] ACP filesystem edit、tool location、buffer eventをturn/tool callへ紐付ける。
  - [x] tool call/updateをID単位でturnへupsertし、path / location / statusを永続化する。
  - [x] ACP filesystem writeをadded / modified eventとして現在のturnへ紐付ける。
  - [x] active turn中の`BufWritePost`をworkspaceで絞り、単一active toolがあればそのIDへ紐付ける。
- [x] shell経由の変更をfilesystem watcherとturn終了後scanで補足する。
  - [x] active turn中はworkspace rootのfilesystem eventを候補として記録し、終了時manifest diffを正本としてadded / modified / deletedを確定する。
- [x] before/after blobをcontent-addressed storageへ保存する。
  - [x] workspace fileをSHA-256 CASへatomic保存し、turn changeにはbefore / after参照とbinary判定を保持する。
- [x] file changeをadded / modified / deleted / moved / binaryで表現する。
  - [x] baseline以後に発生したGit renameだけをold/new pathとbefore/after blob付き`moved` changeへ統合する。
- [x] changed files drawerとmulti-buffer reviewを実装する。
  - [x] `:LazyAgentACPChanges`とthread actionから最新turnの一覧を開き、Enterでbefore/after diff、`a`で全fileをtab reviewする。
- [x] hunk / file / all単位のKeep / Rejectを実装する。
  - [x] file / all Keepをdecisionとして永続化し、Rejectはcurrent == after blobのpreflight後だけbefore blobをatomic復元する。
  - [x] added / modified / deleted / moved / binaryのfile Rejectとall事前検証を実装する。
  - [x] text modified / moved changeはstable hunk IDとreview blobを保持し、複数hunkを順次Keep / Rejectできる。
- [x] Follow Agentで現在のtool location / changed fileへ追従できるようにする。
  - [x] `:LazyAgentACPFollow [agent]`でthread単位に切替え、location > tool path > changed fileの順に通常windowへ追従する。
- [x] agent変更後にuserが再編集した場合は3-way applyし、競合時は上書きしない。
  - [x] text modified / moved Rejectはagent afterをbaseにuser currentとbeforeをmergeし、競合・binaryは変更せず報告する。
- [x] filesystem checkpointのrestore / redoとcheckpointからのclient-local branchを追加する。
  - [x] turn changeの反転でRestore / Redoし、親thread / turn metadataとtranscript copyを持つnative非共有branchを作成する。

### Exit criteria

- prompt前から存在したuser diffを保持したまま、agent差分だけRejectできる。
- terminal commandが直接編集したfileもreviewへ現れる。
- concurrent user editがあるfileはsilent overwriteされず、conflictとして表示される。

## Milestone 3 — Composer, context, and message UX

目標: Zed相当のcontext添付と、生成中でも扱いやすいprompt queueを提供する。

### ContextItem

- [x] file / range / directory / selectionを共通`ContextItem`へ移行する。
  - [x] `@file[:range]` ACP loweringと`{selection}` Markdown loweringを共通model / note / content sliceへ統合する。
- [x] symbol、diagnostics、branch diff、previous thread、terminal、URLを追加する。
  - [x] `@diagnostics`でsource bufferのLSP diagnosticsを位置・severity付きContextItemとして添付する。
  - [x] `@branch-diff`でworkspaceのtracked HEAD差分をsize上限付きContextItemとして添付する。
  - [x] `@symbol`でsource cursorを囲むTreesitter function / class nodeをContextItemとして添付する。
  - [x] `@previous-thread`で同provider・workspaceの直近thread transcriptをContextItemとして添付する。
  - [x] `@terminal`で最新のretained ACP terminal output・command・exit statusをContextItemとして添付する。
  - [x] `@https://...` / `@url:https://...`をclient-side fetchせずACP ResourceLinkとして添付する。
- [x] content hash、source version、size/token estimate、previewを保持する。
  - [x] text itemはSHA-256 / changedtickまたはfile stat / byte÷4 token概算 / whitespace compact previewを生成する。
- [x] capabilityに応じてText / Image / EmbeddedResource / ResourceLinkへloweringする。
  - [x] selection / media / file・range / directoryのloweringをContextItemへ集約し、非対応mediaは送信せず理由をText表示する。
- [x] input imageをfirst-class ACP Image blockとして送信する。
  - [x] paste / screenshotの`@path`をagent capabilityに応じてACP Imageへloweringし、非対応agentにはpayloadを送らず理由をText表示する。
- [x] assistant/tool outputのimage、audio、resourceをNeovim上で表示する。
  - [x] base64 payloadをcontent hash付きcacheへmaterializeし、imageはinline preview参照、audio/resourceはlocal file参照とmetadataを表示する。
- [x] slash commandのdescriptionとargument hintをcomposer completionへ表示する。
  - [x] ACP command metadataのhint / placeholder / requiredを保持し、nvim-cmp / blink.cmpのdetailとdocumentationへ表示する。

### Queue and thread UX

- [x] queued promptのedit / remove / reorder / Send Nowを実装する。
  - [x] stable queue item ID、backend API、action menu pickerを追加する。
- [x] ACP agent向けSend Nowはcancel-and-sendであることを表示する。
- [x] thread内searchをmessage / thought / expanded tool outputへ対応させる。
  - [x] runtime refsを含むsearch indexと、message jump / tool detail pickerをaction menuへ追加する。
- [x] user/assistant messageのcopy、thread Markdown exportを追加する。
  - [x] message body copyとruntime/tool refsを展開する欠落のないMarkdown exporterをaction menuへ追加する。
- [x] pending permission / elicitation / completionをvisual・sound notificationへ接続する。
  - [x] manual permission、auth elicitation、turn completionを共通notification layerへ接続し、sound commandをopt-inにする。

### Exit criteria

- capability非対応のagentへimage/audio/embedを送らない。
- queueを編集しても送信順・cancel state・transcript順序が壊れない。
- context reportで各itemのtoken概算と送信方式を確認できる。

## Milestone 4 — Session Cockpit and parallel work

目標: 複数project・thread・agentを1画面から運用する。

- [x] project/worktreeでgroup化したthread一覧bufferを追加する。
  - [x] `:LazyAgentACPCockpit`でgrouped read-only bufferを開き、thread open / store refreshを提供する。
- [x] title、provider、model、status、unread、usage/cost、changed filesを表示する。
  - [x] title / provider / model / persisted status / unread / unique changed file countをthread cardへ表示する。
- [x] running / waiting / permission / idle / disconnectedを共通statusにする。
  - [x] persisted threadとactive runtime snapshotをthread IDでjoinし、status / current model / cumulative usageを上書き表示する。
- [x] search、pin、archive、restore、delete、bulk closeを追加する。
  - [x] Cockpit buffer-local filter / pin / lifecycle / confirmed bulk-close keymapsを追加する。
- [x] agentmux identity/statusをthread modelへ統合する。
  - [x] publish identityをactive thread metadataへdeep-mergeし、Cockpit status fallbackに利用する。
- [x] opt-inのgit worktree作成、復元、cleanupを追加する。
  - [x] explicit create command、thread-open時path検証、stopped+clean限定cleanupを実装しbranchは自動削除しない。
- [ ] 同じrootを共有するthread間で変更衝突を警告する。
- [ ] worktreeごとのtest commandと結果をthread cardへ表示する。

### Exit criteria

- 複数projectのthreadを状態・未読・変更数で絞り込める。
- worktree隔離したthreadを並列実行し、元workspaceを変更しない。
- agentmux/mobile/Neovimのstatus表示が同じthread stateを参照する。

## Milestone 5 — Ecosystem and polish

- [ ] ACP Registryのbrowse / install / update UIを追加する。
- [ ] Zed/Neovim側MCP server configをnew/load/resume時にagentへforwardする。
- [ ] permissionにonce / session / project / global scopeとaudit logを追加する。
- [ ] mobileからpermission、diff review、Keep/Reject、interruptを操作できるようにする。
- [ ] protocol log viewer、capability inspector、session health reportを追加する。
- [ ] event logからtranscript/runtime UIを再構築できるreplay modeを追加する。
- [ ] ACP v2 adapterをoff-by-defaultのfeature flagとして試作する。

## Experimental ideas

### Agent handoff / reviewer

既存のprovider switchを、明示的なhandoffへ発展させます。

1. implementation threadが変更と要約を生成する。
2. 別providerのreview threadがdiffをread-onlyで確認する。
3. findingをquickfix / review cardへ集約する。
4. 選択したfindingだけを元threadへ返す。

### Context budget broker

diagnostics、diff、selection、terminal、関連fileをtoken予算内で自動選択し、
content hashで未変更contextを再送しないようにします。自動選択結果は送信前に確認・除外できます。

### Worktree tournament

同じtaskを複数agent/modelへ隔離worktreeで投入し、test結果、変更量、時間、costを比較して
採用するthreadを選べるようにします。

### Secure mobile cockpit

スマートフォンを単なるprompt送信UIではなく、permission承認、diff確認、Keep/Reject、
interrupt、完了通知を扱う安全なcontrol planeにします。

### Turn flight recorder

protocol event、permission、tool、filesystem before/after、時間、token、costを記録し、
障害再現、agent比較、UI replayに使います。

## Deliberately deferred

- ACP `session/fork`、elicitation、plan operations、Next Edit Suggestionsはstable確認までfeature flag扱いにする。
- ACP v2をproduction defaultにしない。
- generic External ACPにnative-onlyのSteerやmodel history rewindがあるように見せない。
- session/project scopedで代替できるglobal Cursor/Copilot config rewriteを増やさない。
- change journalが完成するまで、既存user diffを自動revertしない。

## Suggested PR order

1. Fake ACP agent + protocol/lifecycle test harness
2. Filesystem/mobile security + timeout/cancel/teardown
3. Normalized event/content/capability layer
4. Thread schema/store + compatibility adapter
5. Native resume/import + basic thread picker
6. Turn change journal + conflict-safe restore
7. Review buffer + hunk/file/all Keep/Reject
8. ContextItem + native image + editable queue
9. Session Cockpit + worktree isolation
10. Registry/MCP/mobile/replay and experimental adapters

各PRは新しいUIより先にheadless contract testとteardown testを追加し、
既存のbuffer/tmux viewとagent名ベースcommandを壊さない単位に分けます。

## Success criteria

- 同じproviderで2つ以上のthreadを並列実行できる。
- Neovim再起動後にnative sessionを選択して継続できる。
- userの既存変更を保持したままagent変更だけをhunk単位でRejectできる。
- root外filesystem accessと未認証mobile requestを拒否できる。
- configured agentごとのcapability matrixとcontract testがある。
- repeated lifecycleとmulti-instance testでresource leak/collisionが再現しない。
- v1 adapterからUI stateを分離し、将来のv2 adapterを追加できる。

## References

- [Zed Agent Panel](https://zed.dev/docs/ai/agent-panel)
- [Zed External Agents](https://zed.dev/docs/ai/external-agents)
- [Zed Parallel Agents](https://zed.dev/docs/ai/parallel-agents)
- [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization)
- [ACP prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)
- [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup)
- [ACP content](https://agentclientprotocol.com/protocol/v1/content)
- [ACP v2 overview](https://agentclientprotocol.com/rfds/v2/overview)
