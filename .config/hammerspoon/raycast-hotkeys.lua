-- Raycast 用ホットキー:
--   Ctrl+U -> 行頭まで削除 (Cmd+Delete)
--   Ctrl+M -> Enter を送信

local function isRaycastFront()
  local focusedWindow = hs.window.focusedWindow()
  local app = focusedWindow and focusedWindow:application()
  local appName = app and app:name()
  local frontmostApp = hs.application.frontmostApplication()
  local frontmostAppName = frontmostApp and frontmostApp:name()
  return appName == "Raycast" or frontmostAppName == "Raycast"
end

local function createEventTap()
  local keymap = hs.keycodes.map

  local eventTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local keyCode = event:getKeyCode()
    local flags = event:getFlags()

    -- Ctrl 単押し判定
    local ctrlOnly = flags.ctrl and not (flags.cmd or flags.alt or flags.shift or flags.fn)
    if not ctrlOnly then
      return false
    end

    -- Raycast だけを対象
    if not isRaycastFront() then
      return false
    end

    if keyCode == keymap.u then
      hs.timer.doAfter(0.001, function()
        hs.eventtap.keyStroke({"cmd"}, "delete", 0)
      end)
      return true
    end

    if keyCode == keymap.m then
      hs.timer.doAfter(0.001, function()
        hs.eventtap.keyStroke({}, "return", 0)
      end)
      return true
    end

    return false
  end)

  return eventTap
end

-- GC に回収されないようにグローバルに保持し、リロード時は古いタップを止める
if raycastHotkeysEventTap then
  raycastHotkeysEventTap:stop()
end

raycastHotkeysEventTap = createEventTap()
if raycastHotkeysEventTap then
  raycastHotkeysEventTap:start()
end
