local windowCenterCursor = {}

local skipApps = {
    ["Raycast"] = true,
    ["Alfred"] = true,
    ["Spotlight"] = true,
}

local lastClickTime = 0
local lastClickWindowID = nil
local lastMoveTime = 0
local lastMoveWindowID = nil
local CLICK_THRESHOLD = 0.5
local MOVE_DEDUP_THRESHOLD = 0.35
local FOCUS_LOSS_GRACE = 0.25
local SAME_WINDOW_REARM_DISTANCE = 72
local SAME_WINDOW_TARGET_DELTA = 24

local RIPPLE_DURATION = 0.6
local RIPPLE_INTERVAL = 1 / 60
local RIPPLE_START_RADIUS = 1
local RIPPLE_END_RADIUS = 78
local RIPPLE_SECOND_RING_DELAY = 0.18
local RIPPLE_STROKE_WIDTH = 4
local RIPPLE_STROKE_COLOR = { red = 0.42, green = 0.79, blue = 1.0, alpha = 0.62 }
local RIPPLE_SECOND_STROKE_ALPHA = 0.34
local RIPPLE_CENTER_DOT_COLOR = { red = 0.42, green = 0.79, blue = 1.0, alpha = 0.18 }
local RIPPLE_CENTER_DOT_RADIUS = 5

local mouseTap = nil
local appWatcher = nil
local windowWatcher = nil
local monitorTimer = nil
local fullRestartTimer = nil
local pendingMoveTimer = nil
local focusPollTimer = nil
local rippleCanvas = nil
local rippleTimer = nil
local lastObservedFocusedWindowID = nil
local lastFocusLossStartedAt = nil
local lastMoveTargetPoint = nil
local logger = hs.logger.new("window-center-cursor")
logger.setLogLevel("warning")

local function nowSeconds()
    return hs.timer.absoluteTime() / 1000000000
end

-- ウィンドウが有効かチェック
local function isValidWindow(win)
    return win and win:isStandard() and win:isVisible()
end

-- フレームが有効かチェック
local function isValidFrame(frame)
    return frame and frame.w > 0 and frame.h > 0
end

local function pointDistance(a, b)
    if not a or not b then
        return math.huge
    end

    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function windowCenterPoint(win)
    if not isValidWindow(win) then
        return nil
    end

    local frame = win:frame()
    if not isValidFrame(frame) then
        return nil
    end

    return {
        x = frame.x + frame.w / 2,
        y = frame.y + frame.h / 2,
    }
end

-- アプリがスキップ対象かチェック
local function shouldSkipApp(app)
    return app and skipApps[app:name()]
end

-- クリックから一定時間以内で同じウィンドウかチェック
local function shouldSkipDueToClick(winID)
    local currentTime = nowSeconds()
    local timeSinceClick = currentTime - lastClickTime
    return timeSinceClick < CLICK_THRESHOLD and lastClickWindowID and winID == lastClickWindowID
end

-- 直前と同じウィンドウへの移動を短時間で繰り返さない
local function shouldSkipDueToRecentMove(winID)
    local currentTime = nowSeconds()
    local timeSinceMove = currentTime - lastMoveTime
    return timeSinceMove < MOVE_DEDUP_THRESHOLD and lastMoveWindowID and winID == lastMoveWindowID
end

-- クリックされたウィンドウを記録
local function recordClick(win)
    local winID = win:id()
    if winID then
        lastClickTime = nowSeconds()
        lastClickWindowID = winID
    end
end

-- カーソル移動を記録
local function recordMove(winID, targetPoint)
    if winID then
        lastMoveTime = nowSeconds()
        lastMoveWindowID = winID
        lastMoveTargetPoint = targetPoint and {
            x = targetPoint.x,
            y = targetPoint.y,
        } or nil
    end
end

local function shouldSkipDueToSmallSameWindowMovement(winID, targetPoint)
    if not winID or winID ~= lastMoveWindowID or not targetPoint or not lastMoveTargetPoint then
        return false
    end

    if pointDistance(targetPoint, lastMoveTargetPoint) > SAME_WINDOW_TARGET_DELTA then
        return false
    end

    return pointDistance(hs.mouse.absolutePosition(), lastMoveTargetPoint) < SAME_WINDOW_REARM_DISTANCE
end

local function stopRipple()
    if rippleTimer then
        rippleTimer:stop()
        rippleTimer = nil
    end

    if rippleCanvas then
        rippleCanvas:delete()
        rippleCanvas = nil
    end
end

local function lerp(startValue, endValue, progress)
    return startValue + (endValue - startValue) * progress
end

local function smoothstep(progress)
    progress = math.max(0, math.min(1, progress))
    return progress * progress * (3 - 2 * progress)
end

local function rippleCenter()
    return {
        x = RIPPLE_END_RADIUS,
        y = RIPPLE_END_RADIUS,
    }
end

local function updateRipple(canvas, progress)
    local dotProgress = math.min(progress / 0.28, 1)
    local dotEase = smoothstep(dotProgress)
    canvas[1] = {
        type = "circle",
        action = "fill",
        center = rippleCenter(),
        radius = lerp(RIPPLE_START_RADIUS, RIPPLE_CENTER_DOT_RADIUS, dotEase),
        fillColor = {
            red = RIPPLE_CENTER_DOT_COLOR.red,
            green = RIPPLE_CENTER_DOT_COLOR.green,
            blue = RIPPLE_CENTER_DOT_COLOR.blue,
            alpha = RIPPLE_CENTER_DOT_COLOR.alpha * (1 - dotProgress * 0.7),
        },
    }

    local primaryEase = smoothstep(progress)
    canvas[2] = {
        type = "circle",
        action = "stroke",
        center = rippleCenter(),
        radius = lerp(RIPPLE_START_RADIUS, RIPPLE_END_RADIUS, primaryEase),
        strokeWidth = RIPPLE_STROKE_WIDTH,
        strokeColor = {
            red = RIPPLE_STROKE_COLOR.red,
            green = RIPPLE_STROKE_COLOR.green,
            blue = RIPPLE_STROKE_COLOR.blue,
            alpha = RIPPLE_STROKE_COLOR.alpha * (1 - progress),
        },
    }

    local delayedProgress = (progress - RIPPLE_SECOND_RING_DELAY) / (1 - RIPPLE_SECOND_RING_DELAY)
    if delayedProgress > 0 then
        local secondaryEase = smoothstep(delayedProgress)
        canvas[3] = {
            type = "circle",
            action = "stroke",
            center = rippleCenter(),
            radius = lerp(RIPPLE_START_RADIUS + 4, RIPPLE_END_RADIUS, secondaryEase),
            strokeWidth = math.max(1, RIPPLE_STROKE_WIDTH - 1),
            strokeColor = {
                red = RIPPLE_STROKE_COLOR.red,
                green = RIPPLE_STROKE_COLOR.green,
                blue = RIPPLE_STROKE_COLOR.blue,
                alpha = RIPPLE_SECOND_STROKE_ALPHA * (1 - delayedProgress),
            },
        }
    else
        canvas[3] = {
            type = "circle",
            action = "skip",
            center = rippleCenter(),
            radius = RIPPLE_START_RADIUS,
            strokeWidth = math.max(1, RIPPLE_STROKE_WIDTH - 1),
            strokeColor = {
                red = RIPPLE_STROKE_COLOR.red,
                green = RIPPLE_STROKE_COLOR.green,
                blue = RIPPLE_STROKE_COLOR.blue,
                alpha = 0,
            },
        }
    end
end

local function showRipple(point)
    if not point or not point.x or not point.y then
        return
    end

    stopRipple()

    local diameter = RIPPLE_END_RADIUS * 2
    rippleCanvas = hs.canvas.new({
        x = point.x - RIPPLE_END_RADIUS,
        y = point.y - RIPPLE_END_RADIUS,
        w = diameter,
        h = diameter,
    })

    if not rippleCanvas then
        return
    end

    rippleCanvas:level(hs.canvas.windowLevels.overlay)
    updateRipple(rippleCanvas, 0)
    rippleCanvas:show()

    local startedAt = nowSeconds()
    rippleTimer = hs.timer.doEvery(RIPPLE_INTERVAL, function()
        if not rippleCanvas then
            return
        end

        local progress = (nowSeconds() - startedAt) / RIPPLE_DURATION
        if progress >= 1 then
            stopRipple()
            return
        end

        updateRipple(rippleCanvas, progress)
    end)
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

local function getTrackableFocusedWindow()
    local win = hs.window.focusedWindow()
    if isValidWindow(win) and not shouldSkipApp(win:application()) then
        return win
    end
    return nil
end

local function registerFocusedWindow(win)
    if not win or not isValidWindow(win) or shouldSkipApp(win:application()) then
        return false
    end

    local winID = win:id()
    if not winID then
        return false
    end

    lastFocusLossStartedAt = nil
    if winID == lastObservedFocusedWindowID then
        return false
    end

    lastObservedFocusedWindowID = winID
    return true
end

local function noteFocusLoss()
    if not lastObservedFocusedWindowID then
        return
    end

    local currentTime = nowSeconds()
    if not lastFocusLossStartedAt then
        lastFocusLossStartedAt = currentTime
        return
    end

    if currentTime - lastFocusLossStartedAt < FOCUS_LOSS_GRACE then
        return
    end

    lastFocusLossStartedAt = nil
    lastObservedFocusedWindowID = nil
end

-- ウィンドウの中央にカーソルを移動
function windowCenterCursor.moveToCenter(win, targetPoint)
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

    targetPoint = targetPoint or windowCenterPoint(win)
    if not targetPoint then
        return
    end

    local winID = win:id()
    local success, err = pcall(function()
        hs.mouse.setAbsolutePosition(targetPoint)
    end)

    if not success then
        logger:e("Failed to move cursor: " .. tostring(err))
        return
    end

    recordMove(winID, targetPoint)

    local rippleSuccess, rippleErr = pcall(function()
        showRipple(hs.mouse.absolutePosition())
    end)

    if not rippleSuccess then
        logger:e("Failed to show ripple: " .. tostring(rippleErr))
    end
end

-- ウィンドウにカーソルを移動（共通処理）
local function moveCursorToWindow(win, delay)
    delay = delay or 0.1
    if not win then
        return
    end

    if pendingMoveTimer then
        pendingMoveTimer:stop()
        pendingMoveTimer = nil
    end

    pendingMoveTimer = hs.timer.doAfter(delay, function()
        pendingMoveTimer = nil

        if not isValidWindow(win) then
            return
        end

        local targetPoint = windowCenterPoint(win)
        if not targetPoint then
            return
        end

        local winID = win:id()
        if shouldSkipDueToClick(winID)
            or shouldSkipDueToRecentMove(winID)
            or shouldSkipDueToSmallSameWindowMovement(winID, targetPoint)
        then
            return
        end

        windowCenterCursor.moveToCenter(win, targetPoint)
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
                if registerFocusedWindow(win) then
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
        if registerFocusedWindow(win) then
            moveCursorToWindow(win)
        end
    end)
end

createWindowWatcher()

-- イベントで取りこぼすケース向けに現在のフォーカスを軽くポーリング
local function createFocusPollTimer()
    if focusPollTimer then
        focusPollTimer:stop()
        focusPollTimer = nil
    end

    local currentWin = getTrackableFocusedWindow()
    lastObservedFocusedWindowID = currentWin and currentWin:id() or nil

    focusPollTimer = hs.timer.new(0.2, function()
        local focusedWin = getTrackableFocusedWindow()
        if not focusedWin then
            noteFocusLoss()
            return
        end

        if registerFocusedWindow(focusedWin) then
            moveCursorToWindow(focusedWin, 0.05)
        end
    end)

    focusPollTimer:start()
end

createFocusPollTimer()

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

    if not focusPollTimer then
        logger:w("Focus poll timer is nil, restarting...")
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
        if not focusPollTimer then
            createFocusPollTimer()
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
    createFocusPollTimer()
end)
fullRestartTimer:start()

-- クリーンアップ関数
function windowCenterCursor.cleanup()
    if mouseTap then mouseTap:stop(); mouseTap = nil end
    if appWatcher then appWatcher:stop(); appWatcher = nil end
    if windowWatcher then windowWatcher:unsubscribeAll(); windowWatcher = nil end
    if monitorTimer then monitorTimer:stop(); monitorTimer = nil end
    if fullRestartTimer then fullRestartTimer:stop(); fullRestartTimer = nil end
    if pendingMoveTimer then pendingMoveTimer:stop(); pendingMoveTimer = nil end
    if focusPollTimer then focusPollTimer:stop(); focusPollTimer = nil end
    stopRipple()
end

return windowCenterCursor
