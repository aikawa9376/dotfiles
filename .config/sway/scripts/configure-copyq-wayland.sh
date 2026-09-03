#!/bin/sh
set -eu

if ! command -v copyq >/dev/null 2>&1 || ! command -v wtype >/dev/null 2>&1; then
    exit 0
fi

# CopyQ can own the Wayland clipboard, but Wayland does not let it synthesize
# the paste shortcut. Register an idempotent script command which keeps CopyQ's
# normal activation flow and sends Shift+Insert through Sway's virtual keyboard.
attempt=0
until copyq eval '1' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -ge 50 ] && exit 1
    sleep 0.1
done

copyq eval - >/dev/null <<'COPYQ_SCRIPT'
var commandName = "Wayland Paste Support (wtype)";
var commandScript = [
    "copyq:",
    "global.focusPrevious = function() { hide(); };",
    "global.paste = function() {",
    "    sleep(150);",
    "    var p = execute('wtype', '-M', 'shift', '-P', 'Insert', '-p', 'Insert', '-m', 'shift');",
    "    if (!p || p.exit_code !== 0) { throw 'wtype paste failed'; }",
    "};"
].join(String.fromCharCode(10));
var commandList = commands();
var replacement = {
    name: commandName,
    cmd: commandScript,
    isScript: true,
    enable: true
};
var found = false;
for (var i = 0; i < commandList.length; ++i) {
    if (commandList[i].name === commandName) {
        commandList[i] = replacement;
        found = true;
        break;
    }
}
if (!found) {
    commandList.unshift(replacement);
}
setCommands(commandList);
COPYQ_SCRIPT
