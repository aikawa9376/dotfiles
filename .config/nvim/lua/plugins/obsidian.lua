return {
  "epwalsh/obsidian.nvim",
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
    "ObsidianRelated",
    "ObsidianKnowledgeBase",
    "ObsidianNoteStatus",
    "ObsidianOpenArtifact",
    "Obsidian",
    "ObsidianMenu",
    "ObsidianSidebar",
    "ObsidianDashboard",
  },
  dependencies = "obsidian-extension",
  opts = function()
    local vault = vim.env.OBSIDIAN_VAULT
    if not vault or vault == "" then
      vault = "~/gdrive/share/obsidian"
    end
    vault = vim.fs.normalize(vim.fn.expand(vault))

    return {
      workspaces = {
        {
          name = "main",
          path = vault,
        },
      },
      notes_subdir = "notes",
      new_notes_location = "notes_subdir",
      preferred_link_style = "wiki",
      note_frontmatter_func = function(note)
        return require("obsidian_extension").note_frontmatter(note)
      end,
      picker = {
        name = "fzf-lua",
      },
      sort_by = "modified",
      sort_reversed = true,
      completion = {
        -- Register obsidian.nvim's sources for blink.compat.
        nvim_cmp = true,
        min_chars = 2,
      },
      daily_notes = {
        folder = "daily",
        date_format = "%Y-%m-%d",
        alias_format = "%Y-%m-%d",
        default_tags = { "daily-notes" },
      },
      templates = vim.fn.isdirectory(vim.fs.joinpath(vault, "templates")) == 1 and {
        folder = "templates",
        date_format = "%Y-%m-%d",
        time_format = "%H:%M",
      } or nil,
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
    }
  end,
  config = function(_, opts)
    require("obsidian").setup(opts)
  end,
}
