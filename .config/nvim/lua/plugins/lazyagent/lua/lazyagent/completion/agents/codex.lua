local function command(label, desc, doc)
  return {
    label = label,
    desc = desc,
    doc = doc,
  }
end

return {
  slash = {
    command("/exec", "Run Codex non-interactively.", "codex exec: Run Codex non-interactively. Alias: e."),
    command("/review", "Run a code review non-interactively.", "codex review: Run a code review non-interactively."),
    command("/login", "Manage login.", "codex login: Manage login."),
    command(
      "/logout",
      "Remove stored authentication credentials.",
      "codex logout: Remove stored authentication credentials."
    ),
    command("/mcp", "Manage external MCP servers for Codex.", "codex mcp: Manage external MCP servers for Codex."),
    command("/plugin", "Manage Codex plugins.", "codex plugin: Manage Codex plugins."),
    command(
      "/mcp-server",
      "Start Codex as an MCP server over stdio.",
      "codex mcp-server: Start Codex as an MCP server (stdio)."
    ),
    command(
      "/app-server",
      "Run the experimental app server or related tooling.",
      "codex app-server: [experimental] Run the app server or related tooling."
    ),
    command(
      "/remote-control",
      "Manage the app-server daemon with remote control enabled.",
      "codex remote-control: [experimental] Manage the app-server daemon with remote control enabled."
    ),
    command(
      "/completion",
      "Generate shell completion scripts.",
      "codex completion: Generate shell completion scripts."
    ),
    command("/update", "Update Codex to the latest version.", "codex update: Update Codex to the latest version."),
    command(
      "/doctor",
      "Diagnose local Codex installation, config, auth, and runtime health.",
      "codex doctor: Diagnose local Codex installation, config, auth, and runtime health."
    ),
    command(
      "/sandbox",
      "Run commands within a Codex-provided sandbox.",
      "codex sandbox: Run commands within a Codex-provided sandbox."
    ),
    command("/debug", "Open Codex debugging tools.", "codex debug: Debugging tools."),
    command(
      "/apply",
      "Apply the latest Codex agent diff to the local working tree.",
      "codex apply: Apply the latest diff produced by Codex agent as a git apply. Alias: a."
    ),
    command(
      "/resume",
      "Resume a previous interactive session.",
      "codex resume: Resume a previous interactive session. Use --last to continue the most recent."
    ),
    command(
      "/archive",
      "Archive a saved session by id or session name.",
      "codex archive: Archive a saved session by id or session name."
    ),
    command(
      "/unarchive",
      "Unarchive a saved session by id or session name.",
      "codex unarchive: Unarchive a saved session by id or session name."
    ),
    command(
      "/fork",
      "Fork a previous interactive session.",
      "codex fork: Fork a previous interactive session. Use --last to fork the most recent."
    ),
    command(
      "/cloud",
      "Browse Codex Cloud tasks and apply changes locally.",
      "codex cloud: [EXPERIMENTAL] Browse tasks from Codex Cloud and apply changes locally."
    ),
    command(
      "/exec-server",
      "Run the standalone exec-server service.",
      "codex exec-server: [EXPERIMENTAL] Run the standalone exec-server service."
    ),
    command("/features", "Inspect Codex feature flags.", "codex features: Inspect feature flags."),
    command(
      "/help",
      "Print Codex help or subcommand help.",
      "codex help: Print this message or the help of the given subcommand(s)."
    ),
  },
  at = {
    "@file",
    "@repo",
    "@api",
  },
}
