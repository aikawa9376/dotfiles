return {
  "epwalsh/obsidian.nvim",
  event = {
    "BufReadPre " .. vim.fn.expand("~/workspace/obsidian") .. "/**/*.md",
    "BufNewFile " .. vim.fn.expand("~/workspace/obsidian") .. "/**/*.md",
  },
  cmd = {
    "ObsidianOpen",
    "ObsidianNew",
    "ObsidianQuickSwitch",
    "ObsidianSearch",
    "ObsidianToday",
    "ObsidianYesterday",
    "ObsidianTomorrow",
    "ObsidianDailies",
    "ObsidianBacklinks",
    "ObsidianTags",
    "ObsidianTemplate",
    "ObsidianNewFromTemplate",
    "ObsidianLink",
    "ObsidianLinkNew",
    "ObsidianLinks",
    "ObsidianExtractNote",
    "ObsidianRename",
    "ObsidianPasteImg",
    "ObsidianTOC",
    "ObsidianWorkspace",
    "ObsidianToggleCheckbox",
    "ObsidianFollowLink",
    "ObsidianGit",
    "ObsidianBranchNote",
    "ObsidianRepoNote",
  },
  dependencies = "obsidian-extension",
  opts = {
    workspaces = {
      {
        name = "main",
        path = vim.fn.expand("~/workspace/obsidian"),
      },
    },
    notes_subdir = "notes",
    new_notes_location = "notes_subdir",
    preferred_link_style = "wiki",
    picker = {
      name = "fzf-lua",
    },
    sort_by = "modified",
    sort_reversed = true,
    completion = {
      nvim_cmp = false,
      min_chars = 2,
    },
    daily_notes = {
      folder = "daily",
      date_format = "%Y-%m-%d",
      alias_format = "%Y-%m-%d",
      default_tags = { "daily-notes" },
    },
    templates = {
      folder = "templates",
      date_format = "%Y-%m-%d",
      time_format = "%H:%M",
    },
    attachments = {
      img_folder = "assets/imgs",
    },
    mappings = {
      ["gf"] = {
        action = function()
          return require("obsidian").util.gf_passthrough()
        end,
        opts = { noremap = false, expr = true, buffer = true },
      },
    },
    follow_url_func = function(url)
      if vim.ui.open then
        return vim.ui.open(url)
      end
      return vim.fn.jobstart({ "xdg-open", url }, { detach = true })
    end,
    follow_img_func = function(img)
      if vim.ui.open then
        return vim.ui.open(img)
      end
      return vim.fn.jobstart({ "xdg-open", img }, { detach = true })
    end,
    ui = {
      enable = false,
    },
  },
  config = function(_, opts)
    require("obsidian").setup(opts)
  end,
}
