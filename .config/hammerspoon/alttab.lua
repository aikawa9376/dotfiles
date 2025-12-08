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
if altTabWindowFilter and altTabWindowFilter.unsubscribeAll then
    altTabWindowFilter:unsubscribeAll()
    altTabWindowFilter = nil
end

-- MRU履歴を自分で管理（ウィンドウIDのリスト、最近使った順）
local mruHistory = {}

-- Alt+Tabサイクル中かどうかのフラグ
local isCycling = false
local cycleStartWindowId = nil
local cycleWindowList = nil

-- ウィンドウフォーカス変更を監視してMRU履歴を更新
local windowFilter = hs.window.filter.new()
altTabWindowFilter = windowFilter
windowFilter:subscribe(hs.window.filter.windowFocused, function(win)
    -- Alt+Tabサイクル中は履歴を更新しない
    if isCycling then return end

    if not win then return end
    local winId = win:id()

    -- 既存の履歴から削除
    for i, id in ipairs(mruHistory) do
        if id == winId then
            table.remove(mruHistory, i)
            break
        end
    end

    -- 先頭に追加（最新）
    table.insert(mruHistory, 1, winId)

    -- 履歴が長くなりすぎないように制限（最大50個）
    while #mruHistory > 50 do
        table.remove(mruHistory)
    end
end)

local cycleTimer = nil

local function finalizeCycle()
    if not isCycling then return end

    if cycleTimer then
        cycleTimer:stop()
        cycleTimer = nil
        altTabCycleTimer = nil
    end

    if cycleStartWindowId then
        for i, id in ipairs(mruHistory) do
            if id == cycleStartWindowId then
                table.remove(mruHistory, i)
                break
            end
        end
        table.insert(mruHistory, 1, cycleStartWindowId)
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

local function cycleRawWindows(reverse)
    -- サイクル開始時にウィンドウリストを固定
    if not isCycling then
        isCycling = true

        -- 全ウィンドウを取得
        local allWindows = hs.window.allWindows()

        -- 標準的で表示されているウィンドウのマップを作成（ID -> window）
        local windowMap = {}
        for _, win in ipairs(allWindows) do
            if win:isStandard() and win:isVisible() then
                local app = win:application()
                if app then
                    windowMap[win:id()] = {
                        window = win,
                        id = win:id(),
                        appName = app:name(),
                        title = win:title() or "No Title"
                    }
                end
            end
        end

        -- MRU履歴順に表示可能なウィンドウのリストを作成
        cycleWindowList = {}
        for _, winId in ipairs(mruHistory) do
            if windowMap[winId] then
                table.insert(cycleWindowList, windowMap[winId])
            end
        end

        -- 履歴にないウィンドウも追加（念のため）
        for winId, item in pairs(windowMap) do
            local found = false
            for _, vw in ipairs(cycleWindowList) do
                if vw.id == winId then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(cycleWindowList, item)
            end
        end

        if #cycleWindowList < 2 then
            isCycling = false
            cycleWindowList = nil
            return
        end

        cycleStartWindowId = cycleWindowList[1].id
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

    -- 次のサイクルのために更新
    cycleStartWindowId = nextItem.id

    -- ウィンドウを前面に持ってきてからフォーカス
    nextWin:raise()
    nextWin:focus()

    -- アプリケーションもアクティブにする
    local app = nextWin:application()
    if app then
        app:activate()
    end

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
