local windowCenterCursor = {}

local skipApps = {
    ["Raycast"] = true,
    ["Alfred"] = true,
    ["Spotlight"] = true,
}

local lastClickTime = 0
local lastClickWindowID = nil
local CLICK_THRESHOLD = 0.5

local mouseTap = nil
local appWatcher = nil

local function createMouseTap()
    if mouseTap then
        mouseTap:stop()
    end

    mouseTap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown}, function(event)
        local clickPoint = event:location()
        local win = nil

        local windows = hs.window.orderedWindows()
        for _, w in ipairs(windows) do
            if w:isStandard() and w:isVisible() then
                local frame = w:frame()
                if clickPoint.x >= frame.x and clickPoint.x <= frame.x + frame.w and
                   clickPoint.y >= frame.y and clickPoint.y <= frame.y + frame.h then
                    win = w
                    break
                end
            end
        end

        if win then
            local app = win:application()
            if app and skipApps[app:name()] then
                return false
            end

            lastClickTime = hs.timer.absoluteTime() / 1000000000
            lastClickWindowID = win:id()
        end
        return false
    end)

    if mouseTap then
        mouseTap:start()
    end
end

createMouseTap()

function windowCenterCursor.moveToCenter(win)
    win = win or hs.window.focusedWindow()
    if not win then
        return
    end

    local windowControlModule = package.loaded["window-control"]
    if windowControlModule and windowControlModule.isDraggingOrResizing then
        if windowControlModule.isDraggingOrResizing() then
            return
        end
    end

    local app = win:application()
    if app and skipApps[app:name()] then
        return
    end

    local frame = win:frame()
    local centerX = frame.x + frame.w / 2
    local centerY = frame.y + frame.h / 2

    hs.mouse.setAbsolutePosition({x = centerX, y = centerY})
end

local function createAppWatcher()
    if appWatcher then
        appWatcher:stop()
    end

    appWatcher = hs.application.watcher.new(function(appName, eventType, app)
        if eventType == hs.application.watcher.activated then
            if app then
                if skipApps[appName] then
                    return
                end

                local win = app:mainWindow()
                if not win then
                    local windows = app:allWindows()
                    if windows and #windows > 0 then
                        win = windows[1]
                    end
                end

                if win then
                    local currentTime = hs.timer.absoluteTime() / 1000000000
                    local timeSinceClick = currentTime - lastClickTime

                    if timeSinceClick < CLICK_THRESHOLD and lastClickWindowID and win:id() == lastClickWindowID then
                        return
                    end

                    hs.timer.doAfter(0.1, function()
                        windowCenterCursor.moveToCenter(win)
                    end)
                end
            end
        end
    end)

    if appWatcher then
        appWatcher:start()
    end
end

createAppWatcher()

-- イベントタップとウォッチャーの状態を定期的にチェックして、停止していたら再起動する
local monitorTimer = hs.timer.new(5.0, function()
    if mouseTap and not mouseTap:isEnabled() then
        hs.logger.new("window-center-cursor"):w("Mouse tap was disabled, restarting...")
        createMouseTap()
    end

    if appWatcher and not appWatcher:isRunning() then
        hs.logger.new("window-center-cursor"):w("App watcher was stopped, restarting...")
        createAppWatcher()
    end
end)
monitorTimer:start()

return windowCenterCursor
