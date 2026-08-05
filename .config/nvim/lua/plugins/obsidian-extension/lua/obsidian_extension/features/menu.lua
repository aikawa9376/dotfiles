local M = {}

local items = {
  {
    label = "Search",
    description = "Vault 全体から本文を検索する",
    command = "ObsidianSearch",
  },
  {
    label = "Quick switch",
    description = "ノート名を曖昧検索して開く",
    command = "ObsidianQuickSwitch",
  },
  {
    label = "Related notes",
    description = "現在のproject・branchに関連するノートを表示する",
    command = "ObsidianRelated",
  },
  {
    label = "Today's note",
    description = "今日の Daily Note を開く",
    command = "ObsidianToday",
  },
  {
    label = "Daily notes",
    description = "Daily Note の一覧から選んで開く",
    command = "ObsidianDailies",
  },
  {
    label = "Branch note",
    description = "現在の Git ブランチ用プロジェクトノートを開く",
    command = "ObsidianBranchNote",
  },
  {
    label = "Backlinks",
    description = "現在のノートを参照しているノートを探す",
    command = "ObsidianBacklinks",
  },
  {
    label = "New note",
    description = "notes/ に新しいノートを作る",
    command = "ObsidianNew",
  },
  {
    label = "New from template",
    description = "テンプレートを選んでノートを作る",
    command = "ObsidianNewFromTemplate",
  },
  {
    label = "Rename note",
    description = "ノート名と参照リンクをまとめて変更する",
    command = "ObsidianRename",
  },
  {
    label = "Repository note",
    description = "現在のリポジトリ用プロジェクトノートを開く",
    command = "ObsidianRepoNote",
  },
  {
    label = "Knowledge base",
    description = "知識ノートの Seeds / Evergreen 一覧を開く",
    command = "ObsidianKnowledgeBase",
  },
  {
    label = "Open artifact",
    description = "現在のノートに紐づく HTML などを開く",
    command = "ObsidianOpenArtifact",
  },
  {
    label = "Open in Obsidian",
    description = "現在のノートを Obsidian アプリで開く",
    command = "ObsidianOpen",
  },
  {
    label = "Sidebar",
    description = "見出し・リンク・バックリンクを右側に表示する",
    command = "ObsidianSidebar",
  },
}

local function open_menu()
  vim.ui.select(items, {
    prompt = "Obsidian action",
    kind = "obsidian-menu",
    format_item = function(item)
      return ("%-19s  %s"):format(item.label, item.description)
    end,
  }, function(item)
    if not item then
      return
    end

    vim.schedule(function()
      vim.cmd(item.command)
    end)
  end)
end

function M.setup()
  for _, command in ipairs({ "Obsidian", "ObsidianMenu" }) do
    vim.api.nvim_create_user_command(command, open_menu, {
      desc = "Select a useful Obsidian action",
    })
  end
end

return M
