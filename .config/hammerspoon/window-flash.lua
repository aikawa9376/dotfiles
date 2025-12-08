-- -----------------------------------------------------
-- アクティブウィンドウを一瞬暗くして光って見えるようにする
-- -----------------------------------------------------

-- 現在表示中のオーバーレイを保持
local currentOverlay = nil

local function flashWindow(win)
    if not win then return end
    
    -- 前回のオーバーレイが残っていたら削除
    if currentOverlay then
        currentOverlay:delete()
        currentOverlay = nil
    end
    
    -- ウィンドウの位置とサイズを取得
    local winFrame = win:frame()
    local screen = win:screen()
    local screenFrame = screen:frame()
    
    -- ウィンドウの上に暗いオーバーレイを作成
    local overlay = hs.canvas.new(screenFrame)
    
    -- ウィンドウ部分だけを暗くする
    overlay[1] = {
        type = "rectangle",
        action = "fill",
        fillColor = { red = 0, green = 0, blue = 0, alpha = 0.4 },
        frame = {
            x = winFrame.x - screenFrame.x,
            y = winFrame.y - screenFrame.y,
            w = winFrame.w,
            h = winFrame.h
        }
    }
    
    -- ウィンドウの上に表示
    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:show()
    
    -- 現在のオーバーレイとして保存
    currentOverlay = overlay
    
    -- 0.1秒後に消す（一瞬暗くなって戻る = 光って見える）
    hs.timer.doAfter(0.1, function()
        if overlay then
            overlay:delete()
        end
        if currentOverlay == overlay then
            currentOverlay = nil
        end
    end)
end

-- 外部から呼び出せるようにエクスポート
return {
    flashWindow = flashWindow
}
