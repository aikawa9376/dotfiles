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
local windowWatcher = nil
local monitorTimer = nil
local fullRestartTimer = nil
local logger = hs.logger.new("window-center-cursor")
logger.setLogLevel("warning")

-- ウィンドウが有効かチェック
local function isValidWindow(win)
    return win and win:isStandard() and win:isVisible()
end

-- フレームが有効かチェック
local function isValidFrame(frame)
    return frame and frame.w > 0 and frame.h > 0
end

-- アプリがスキップ対象かチェック
local function shouldSkipApp(app)
    return app and skipApps[app:name()]
end

-- クリックから一定時間以内で同じウィンドウかチェック
local function shouldSkipDueToClick(winID)
    local currentTime = hs.timer.absoluteTime() / 1000000000
    local timeSinceClick = currentTime - lastClickTime
    return timeSinceClick < CLICK_THRESHOLD and lastClickWindowID and winID == lastClickWindowID
end

-- クリックされたウィンドウを記録
local function recordClick(win)
    local winID = win:id()
    if winID then
        lastClickTime = hs.timer.absoluteTime() / 1000000000
        lastClickWindowID = winID
    end
end

-- クリック位置からウィンドウを検出
local function findWindowAtPoint(point)
    for _, w in ipairs(hs.window.orderedWindows()) do
        if isValidWindow(w) then
            local frame = w:frame()
            if isValidFrame(frame) then
                if point.x >= frame.x and point.x <= frame.x + frame.w and
                   point.y >= frame.y and point.y <= frame.y + frame.h then
                    return w
                end
            end
        end
    end
    return nil
end

-- フォーカスされたウィンドウを検出
local function findFocusedWindow(appName)
    local focusedWin = hs.window.focusedWindow()
    if focusedWin then
        local app = focusedWin:application()
        if app and app:name() == appName and isValidWindow(focusedWin) then
            return focusedWin
        end
    end
    return nil
end

-- Z-order順で最前面のウィンドウを検出
local function findTopWindow(appName)
    for _, w in ipairs(hs.window.orderedWindows()) do
        local app = w:application()
        if app and app:name() == appName and isValidWindow(w) then
            return w
        end
    end
    return nil
end

-- ウィンドウの中央にカーソルを移動
function windowCenterCursor.moveToCenter(win)
    win = win or hs.window.focusedWindow()
    if not isValidWindow(win) then
        return
    end

    local windowControlModule = package.loaded["window-control"]
    if windowControlModule and windowControlModule.isDraggingOrResizing and windowControlModule.isDraggingOrResizing() then
        return
    end

    if shouldSkipApp(win:application()) then
        return
    end

    local frame = win:frame()
    if not isValidFrame(frame) then
        return
    end

    local centerX = frame.x + frame.w / 2
    local centerY = frame.y + frame.h / 2

    if centerX < 0 or centerY < 0 then
        return
    end

    local success, err = pcall(function()
        hs.mouse.setAbsolutePosition({x = centerX, y = centerY})
    end)
    
    if not success then
        logger:e("Failed to move cursor: " .. tostring(err))
    end
end

-- ウィンドウにカーソルを移動（共通処理）
local function moveCursorToWindow(win, delay)
    delay = delay or 0.1
    if not win then
        return
    end

    hs.timer.doAfter(delay, function()
        if not isValidWindow(win) then
            return
        end

        local frame = win:frame()
        if not isValidFrame(frame) then
            return
        end

        local winID = win:id()
        if shouldSkipDueToClick(winID) then
            return
        end

        windowCenterCursor.moveToCenter(win)
    end)
end

-- マウスタップの作成
local function createMouseTap()
    if mouseTap then
        mouseTap:stop()
        mouseTap = nil
    end

    mouseTap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown}, function(event)
        local win = findWindowAtPoint(event:location())
        if win and not shouldSkipApp(win:application()) then
            recordClick(win)
        end
        return false
    end)

    if mouseTap then
        local success = mouseTap:start()
        if not success then
            logger:e("Failed to start mouse tap")
            mouseTap = nil
        end
    end
end

createMouseTap()

-- アプリウォッチャーの作成
local function createAppWatcher()
    if appWatcher then
        appWatcher:stop()
        appWatcher = nil
    end

    appWatcher = hs.application.watcher.new(function(appName, eventType, app)
        if eventType == hs.application.watcher.activated and app and not skipApps[appName] then
            hs.timer.doAfter(0.2, function()
                local win = findFocusedWindow(appName) or findTopWindow(appName)
                if win then
                    moveCursorToWindow(win)
                end
            end)
        end
    end)

    if appWatcher then
        appWatcher:start()
    end
end

createAppWatcher()

-- ウィンドウウォッチャーの作成
local function createWindowWatcher()
    if windowWatcher then
        windowWatcher:unsubscribeAll()
        windowWatcher = nil
    end

    windowWatcher = hs.window.filter.new()
    windowWatcher:setDefaultFilter({})
    
    windowWatcher:subscribe({hs.window.filter.windowFocused}, function(win)
        if isValidWindow(win) and not shouldSkipApp(win:application()) then
            moveCursorToWindow(win)
        end
    end)
end

createWindowWatcher()

-- ウォッチャーの状態チェックと再起動
local function checkAndRestart()
    local needsRestart = false
    
    if not mouseTap or not mouseTap:isEnabled() then
        logger:w("Mouse tap needs restart")
        needsRestart = true
    end
    
    if not appWatcher then
        logger:w("App watcher is nil, restarting...")
        needsRestart = true
    end
    
    if not windowWatcher then
        logger:w("Window watcher is nil, restarting...")
        needsRestart = true
    end
    
    if needsRestart then
        if not mouseTap or not mouseTap:isEnabled() then
            createMouseTap()
        end
        if not appWatcher then
            createAppWatcher()
        end
        if not windowWatcher then
            createWindowWatcher()
        end
    end
end

monitorTimer = hs.timer.new(3.0, checkAndRestart)
monitorTimer:start()

fullRestartTimer = hs.timer.new(1800.0, function()
    logger:i("Performing full restart of watchers...")
    createMouseTap()
    createAppWatcher()
    createWindowWatcher()
end)
fullRestartTimer:start()

-- クリーンアップ関数
function windowCenterCursor.cleanup()
    if mouseTap then mouseTap:stop(); mouseTap = nil end
    if appWatcher then appWatcher:stop(); appWatcher = nil end
    if windowWatcher then windowWatcher:unsubscribeAll(); windowWatcher = nil end
    if monitorTimer then monitorTimer:stop(); monitorTimer = nil end
    if fullRestartTimer then fullRestartTimer:stop(); fullRestartTimer = nil end
end

return windowCenterCursor
