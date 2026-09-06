-- Window placement and floating dialogs.
hl.window_rule({ name = "alacritty-workspace", match = { class = "[Aa]lacritty" }, workspace = "2" })
hl.window_rule({ name = "luakit-workspace", match = { class = "[Ll]uakit" }, workspace = "2" })
hl.window_rule({ name = "remmina-workspace", match = { class = "org.remmina.Remmina|Remmina" }, workspace = "3" })

hl.window_rule({ name = "insync-float", match = { class = "[Ii]nsync" }, float = true, center = true, size = { 640, 450 } })
hl.window_rule({ name = "copyq-float", match = { class = "([Cc]opyq|com\\.github\\.hluk\\.copyq)" }, float = true, center = true, size = { 725, 837 } })
hl.window_rule({ name = "feh-float", match = { class = "[Ff]eh" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "ssr-float", match = { class = "SimpleScreenRecorder" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "rofi-float", match = { class = "[Rr]ofi" }, float = true, center = true })
hl.window_rule({ name = "fcitx-config-float", match = { class = "fcitx5-config-qt" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "network-config-float", match = { class = "nm-connection-editor" }, float = true, center = true, size = { 800, 600 } })
hl.window_rule({ name = "mozc-tool-float", match = { class = "mozc_tool" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "modal-float", match = { modal = true }, float = true, center = true })
