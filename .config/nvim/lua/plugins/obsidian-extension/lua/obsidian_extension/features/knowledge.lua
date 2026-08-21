local M = {}

local context = require("obsidian_extension.context")
local statuses = { "seed", "evergreen", "archived" }

local knowledge_base_lines = {
  "filters:",
  "  and:",
  '    - \'file.ext == "md"\'',
  '    - file.inFolder("notes")',
  "",
  "views:",
  "  - type: table",
  '    name: "Seeds"',
  '    filters: \'status == "seed" && type != "agent-memory"\'',
  "    order:",
  "      - file.name",
  "      - type",
  "      - project",
  "      - source",
  "      - updated",
  "",
  "  - type: table",
  '    name: "Evergreen"',
  '    filters: \'status == "evergreen" && type != "agent-memory"\'',
  "    order:",
  "      - file.name",
  "      - type",
  "      - project",
  "      - updated",
  "",
  "  - type: table",
  '    name: "References"',
  '    filters: \'type == "reference"\'',
  "    order:",
  "      - file.name",
  "      - status",
  "      - project",
  "      - source_url",
  "      - updated",
  "",
  "  - type: table",
  '    name: "Reports"',
  '    filters: \'type == "report"\'',
  "    order:",
  "      - file.name",
  "      - status",
  "      - project",
  "      - artifact",
  "      - updated",
  "",
  "  - type: table",
  '    name: "Agent Memory"',
  '    filters: \'type == "agent-memory"\'',
  "    order:",
  "      - file.name",
  "      - project",
  "      - updated",
}

local function open_knowledge_base()
  local vault_path = context.vault_path()
  if not vault_path then
    vim.notify("Could not resolve the current Obsidian vault", vim.log.levels.ERROR)
    return
  end

  local path = vault_path .. "/bases/knowledge.base"
  if vim.fn.filereadable(path) ~= 1 then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local ok, err = pcall(vim.fn.writefile, knowledge_base_lines, path)
    if not ok then
      vim.notify("Failed to create Obsidian knowledge Base: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

local function set_note_status(status)
  if not vim.tbl_contains(statuses, status) then
    vim.notify("Obsidian note status must be seed, evergreen, or archived", vim.log.levels.ERROR)
    return
  end

  local client = require("obsidian").get_client()
  local note = client:current_note(0)
  if not note then
    vim.notify("Current buffer is not an Obsidian note", vim.log.levels.ERROR)
    return
  end

  note:add_field("status", status)
  if client:update_frontmatter(note, 0) then
    vim.notify("Obsidian note status: " .. status, vim.log.levels.INFO)
  end
end

local function open_target(target)
  if vim.ui.open then
    local ok, result = pcall(vim.ui.open, target)
    if ok then
      return result
    end
  end
  return vim.fn.jobstart({ "xdg-open", target }, { detach = true })
end

local function open_note_artifact()
  local client = require("obsidian").get_client()
  local note = client:current_note(0)
  if not note then
    vim.notify("Current buffer is not an Obsidian note", vim.log.levels.ERROR)
    return
  end

  local artifact = note:get_field("artifact")
  if type(artifact) ~= "string" or artifact == "" then
    vim.notify("Current Obsidian note has no artifact property", vim.log.levels.ERROR)
    return
  end

  if artifact:match("^https?://") then
    open_target(artifact)
    return
  end

  local vault_path = context.vault_path()
  if not vault_path then
    vim.notify("Could not resolve the current Obsidian vault", vim.log.levels.ERROR)
    return
  end

  local root = vim.fs.normalize(vault_path)
  local relative = artifact:gsub("^/+", "")
  local path = vim.fs.normalize(root .. "/" .. relative)
  if path:sub(1, #root + 1) ~= root .. "/" then
    vim.notify("Obsidian artifact points outside the vault", vim.log.levels.ERROR)
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("Obsidian artifact does not exist: " .. relative, vim.log.levels.ERROR)
    return
  end

  open_target(path)
end

function M.setup()
  vim.api.nvim_create_user_command("ObsidianKnowledgeBase", open_knowledge_base, {
    desc = "Open or create the knowledge garden Base",
  })

  vim.api.nvim_create_user_command("ObsidianNoteStatus", function(opts)
    set_note_status(opts.args)
  end, {
    nargs = 1,
    complete = function(arg_lead)
      return vim.tbl_filter(function(status)
        return status:sub(1, #arg_lead) == arg_lead
      end, statuses)
    end,
    desc = "Set the current note status",
  })

  vim.api.nvim_create_user_command("ObsidianOpenArtifact", open_note_artifact, {
    desc = "Open the current note's artifact property",
  })
end

M._knowledge_base_lines = knowledge_base_lines

return M
