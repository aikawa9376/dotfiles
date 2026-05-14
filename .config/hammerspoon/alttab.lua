-- -----------------------------------------------------
-- 全ウィンドウをMRU順でサイクルする（同じアプリの複数ウィンドウも個別に扱う）
-- -----------------------------------------------------

local windowFlash = require("window-flash")

-- リロード時に古い監視を止める
if altTabFlagWatcher then
    altTabFlagWatcher:stop()
    altTabFlagWatcher = nil
end
if altTabCycleTimer then
    altTabCycleTimer:stop()
    altTabCycleTimer = nil
end
if altTabFocusPollTimer then
    altTabFocusPollTimer:stop()
    altTabFocusPollTimer = nil
end
if altTabWindowFilter and altTabWindowFilter.unsubscribeAll then
    altTabWindowFilter:unsubscribeAll()
    altTabWindowFilter = nil
end

-- MRU履歴を自分で管理（ウィンドウIDのリスト、最近使った順）
local mruHistory = {}
local MAX_MRU_HISTORY = 50
local FOCUS_POLL_INTERVAL = 0.2

-- Alt+Tabサイクル中かどうかのフラグ
local isCycling = false
local cycleStartWindowId = nil
local cycleWindowList = nil
local focusPollTimer = nil
local lastObservedFocusedWindowId = nil

local function removeFromHistory(winId)
    for i, id in ipairs(mruHistory) do
        if id == winId then
            table.remove(mruHistory, i)
            return
        end
    end
end

local function isTrackableWindow(win)
    return win and win:id() and win:isStandard() and win:isVisible() and win:application()
end

local function focusedTrackableWindow()
    local win = hs.window.focusedWindow()
    if isTrackableWindow(win) then
        return win
    end
    return nil
end

local function touchMru(win)
    if isCycling or not isTrackableWindow(win) then
        return
    end

    local winId = win:id()
    removeFromHistory(winId)
    table.insert(mruHistory, 1, winId)

    while #mruHistory > MAX_MRU_HISTORY do
        table.remove(mruHistory)
    end
end

-- ウィンドウフォーカス変更を監視してMRU履歴を更新
local windowFilter = hs.window.filter.new()
altTabWindowFilter = windowFilter
windowFilter:subscribe(hs.window.filter.windowFocused, function(win)
    touchMru(win)
end)

local cycleTimer = nil

local function finalizeCycle()
    if not isCycling then return end

    if cycleTimer then
        cycleTimer:stop()
        cycleTimer = nil
        altTabCycleTimer = nil
    end

    local focusedWin = focusedTrackableWindow()
    local finalizedWinId = focusedWin and focusedWin:id() or cycleStartWindowId
    if finalizedWinId then
        removeFromHistory(finalizedWinId)
        table.insert(mruHistory, 1, finalizedWinId)
        while #mruHistory > MAX_MRU_HISTORY do
            table.remove(mruHistory)
        end
        lastObservedFocusedWindowId = finalizedWinId
    end

    isCycling = false
    cycleStartWindowId = nil
    cycleWindowList = nil
end

altTabFlagWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    if not isCycling then return false end
    local flags = event:getFlags()
    if not flags.alt then
        finalizeCycle()
    end
    return false
end)
altTabFlagWatcher:start()

local function startFocusPoll()
    if focusPollTimer then
        focusPollTimer:stop()
        focusPollTimer = nil
    end

    local currentWin = focusedTrackableWindow()
    lastObservedFocusedWindowId = currentWin and currentWin:id() or nil

    focusPollTimer = hs.timer.new(FOCUS_POLL_INTERVAL, function()
        local win = focusedTrackableWindow()
        local winId = win and win:id() or nil

        if winId == lastObservedFocusedWindowId then
            return
        end

        lastObservedFocusedWindowId = winId
        if win then
            touchMru(win)
        end
    end)

    focusPollTimer:start()
    altTabFocusPollTimer = focusPollTimer
end

startFocusPoll()

local function cycleRawWindows(reverse)
    -- サイクル開始時にウィンドウリストを固定
    if not isCycling then
        local currentWin = focusedTrackableWindow()
        if currentWin then
            touchMru(currentWin)
        end
        isCycling = true

        -- 現在見えている実ウィンドウを前面順で取得
        local visibleWindows = hs.window.orderedWindows()
        local windowMap = {}
        local orderedWindowList = {}
        local addedWindowIds = {}
        for _, win in ipairs(visibleWindows) do
            if isTrackableWindow(win) then
                local app = win:application()
                local item = {
                    window = win,
                    id = win:id(),
                    appName = app:name(),
                    title = win:title() or "No Title",
                }
                windowMap[item.id] = item
                table.insert(orderedWindowList, item)
            end
        end

        -- MRU履歴順に表示可能なウィンドウのリストを作成
        cycleWindowList = {}
        for _, winId in ipairs(mruHistory) do
            if windowMap[winId] then
                table.insert(cycleWindowList, windowMap[winId])
                addedWindowIds[winId] = true
            end
        end

        -- 履歴にないウィンドウは現在の前面順で追加
        for _, item in ipairs(orderedWindowList) do
            if not addedWindowIds[item.id] then
                table.insert(cycleWindowList, item)
            end
        end

        if #cycleWindowList < 2 then
            isCycling = false
            cycleWindowList = nil
            return
        end

        local currentWinId = currentWin and currentWin:id() or nil
        if currentWinId and windowMap[currentWinId] ~= nil then
            cycleStartWindowId = currentWinId
        else
            cycleStartWindowId = cycleWindowList[1].id
        end
    end

    -- 現在のウィンドウの位置を探す
    local currentIndex = 1
    for i, item in ipairs(cycleWindowList) do
        if item.id == cycleStartWindowId then
            currentIndex = i
            break
        end
    end

    -- 次のウィンドウにフォーカスを移す
    local nextIndex
    if reverse then
        -- 逆方向
        nextIndex = currentIndex - 1
        if nextIndex < 1 then
            nextIndex = #cycleWindowList
        end
    else
        -- 順方向
        nextIndex = currentIndex + 1
        if nextIndex > #cycleWindowList then
            nextIndex = 1
        end
    end

    local nextItem = cycleWindowList[nextIndex]
    local nextWin = nextItem.window
    if not isTrackableWindow(nextWin) then
        finalizeCycle()
        return
    end

    -- 次のサイクルのために更新
    cycleStartWindowId = nextItem.id

    -- 別アプリへ移るときは先にアプリを前面化し、その後ターゲットウィンドウを確定させる
    local app = nextWin:application()
    if app and not app:isFrontmost() then
        app:activate()
    end
    nextWin:raise()
    nextWin:becomeMain()
    nextWin:focus()

    -- フラッシュエフェクトを表示
    windowFlash.flashWindow(nextWin)

    -- サイクル終了を検出するためのタイマー（1秒キー入力がなければ終了）
    if cycleTimer then
        cycleTimer:stop()
    end
    cycleTimer = hs.timer.doAfter(1.0, finalizeCycle)
    altTabCycleTimer = cycleTimer
end

-- Alt+Tab: 順方向にサイクル
hs.hotkey.bind({"alt"}, "tab", function()
    cycleRawWindows(false)
end)

-- Alt+Shift+Tab: 逆方向にサイクル
hs.hotkey.bind({"alt", "shift"}, "tab", function()
    cycleRawWindows(true)
end)
