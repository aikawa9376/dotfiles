# Obsidian extension

## ローカルグラフ

ノートを開いて `:ObsidianLocalGraph` を実行すると、右側に現在のノートを中心としたリンクのツリーを表示します。
`:ObsidianLocalGraph 2` のように、表示する深さを指定することもできます（1〜10、初期値1）。
メニューの `Local graph` からも開けます。

- `→` は親ノートから子ノートへのリンク、`←` は子ノートから親ノートへのリンク、`↔` は相互リンクです。
- 深さ2以上では、接続先のノートからさらにリンクをたどります。ノートは最短距離で一度だけ配置します。
- 中心は黄色、各枝は青・緑・黄・シアン・紫で色分けし、同じ枝のノートは深さに合わせて淡く表示します。
  矢印も枝と同じ色・淡さに揃え、リンクの方向は `→`・`←`・`↔` の形で区別します。パスは控えめに表示します。
  配色は `lua/config/colorScheme.lua` の `ObsidianLocalGraph*` ハイライトで調整できます。
- 枝をまたぐリンクや循環は、下部の `NEIGHBOR LINKS` に表示します。各行の移動先は矢印の右側のノートです。
- ノートを切り替えると中心が追従します。`f` で追従を止め、`c` で選択したノートを中心にできます。
- Wikiリンク・Markdownリンク・埋め込みノートを対象とし、見出しやブロックへのリンクは所属ノートにまとめます。
  URL、添付ファイル、コード、HTML・Obsidianコメント内のリンクは対象外です。
- 未作成ノートは `(missing)` として表示し、開く操作では作成しません。`e` で非表示にできます。
- 未保存の編集も反映します。外部での追加・変更は `R` で読み直せます。

| 操作 | 動作 |
| --- | --- |
| `Enter` / ダブルクリック | 選択ノートを編集ウィンドウで開く |
| `c` | 選択ノートを中心にする |
| `+` / `=` / `-` | 深さを増減する |
| `i` | リンク元の探索を切り替える |
| `o` | リンク先の探索を切り替える |
| `n` | 枝同士の追加リンク表示を切り替える |
| `e` | 実在するノートのみ表示する |
| `f` | 現在のノートへの追従を切り替える |
| `/` / `Esc` | 名前・パス・別名による部分一致検索 / 検索解除 |
| `R` | Vaultを再走査する |
| `q` | 閉じる |

検索は指定した深さの範囲内に適用し、該当ノートまでの枝を残します。
大量の接続がある場合は初期設定で500ノートまで表示し、上限到達を画面に表示します。

`obsidian-extension` の `opts.local_graph` で初期設定を変更できます。

```lua
local_graph = {
  depth = 1,
  incoming = true,
  outgoing = true,
  neighbor_links = true,
  existing_only = false,
  follow = true,
  width = 64,
  max_nodes = 500,
},
```

Obsidian本体の[ローカルグラフ](https://obsidian.md/help/plugins/graph)を参考に、
深さと入出力リンクの探索をNeovimのテキスト表示で扱います。
物理演算レイアウト、タグ・添付ファイルのノード、色分けグループ、Obsidianの高度な検索構文には対応していません。

## Tests

インストール済みの `obsidian.nvim` と `plenary.nvim` をruntimepathに加えて実行します。
ローカルグラフのテストは、通常のLazyインストール先にある両プラグインを自動で読み込みます。

```sh
for spec in .config/nvim/lua/plugins/obsidian-extension/tests/*_spec.lua; do
  nvim --headless --clean -u NONE \
    --cmd 'set rtp+=/home/aikawa/.local/share/nvim/lazy/plenary.nvim' \
    --cmd 'set rtp+=/home/aikawa/.local/share/nvim/lazy/obsidian.nvim' \
    -l "$spec" || break
done
```
