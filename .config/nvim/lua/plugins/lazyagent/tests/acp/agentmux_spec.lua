local M = {}

function M.run()
  local Agentmux = require("lazyagent.integrations.agentmux")
  local identity = Agentmux.identity_for("Codex", {
    agent_status = "waiting",
    agent_status_message = "Permission",
    acp_transcript_path = "/tmp/thread.md",
  }, "%7")
  assert(identity.pane_id == "%7", "agentmux pane identity")
  assert(identity.kind == "codex", "agentmux kind")
  assert(identity.name == "Codex (ACP)", "agentmux display name")
  assert(identity.state == "blocked", "agentmux normalized state")
  assert(identity.message == "Permission", "agentmux status message")
  assert(identity.preview_path == "/tmp/thread.md", "agentmux preview identity")
end

return M
