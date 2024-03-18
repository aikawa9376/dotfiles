#NoEnv  ; Recommended for performance and compatibility with future AutoHotkey releases.
SendMode Input  ; Recommended for new scripts due to its superior speed and reliability.
SetWorkingDir %A_ScriptDir%  ; Ensures a consistent starting directory.
SetTitleMatchMode,2
SetKeyDelay 0
#InstallKeybdHook
#UseHook

$LControl::
  if LControl_guard = True   ;スペースキーガード
      return
  LControl_guard = True      ;スペースキーにガードをかける
  Send,{LControl Down}    ;シフトキーを仮想的に押し下げる
  ifNotEqual LControl_key    ;既に入力済みの場合は抜ける
      return
  LControl_key=
  Input,LControl_key,L1 V    ;1文字入力を受け付け（入力有無判定用）
return

$LControl up::             ;スペース解放時
  input                   ;既存のInputコマンドの終了
  if LControl_guard = False  ;ガードがかかってなかった場合（修飾キー＋Spaceのリリース）
      return
  LControl_guard = False     ;スペースキーガードを外す
  Send,{LControl Up}      ;シフトキー解放
  ifEqual LControl_key       ;LControl文字入力なし
      Send,{ESC}          ;スペースを発射
      IME_SET(0)
  LControl_key=
return

$RShift::
  if RShift_guard = True   ;スペースキーガード
      return
  RShift_guard = True      ;スペースキーにガードをかける
  Send,{RShift Down}    ;シフトキーを仮想的に押し下げる
  ifNotEqual RShift_key    ;既に入力済みの場合は抜ける
      return
  RShift_key=
  Input,RShift_key,L1 V    ;1文字入力を受け付け（入力有無判定用）
return

$RShift up::             ;スペース解放時
  input                   ;既存のInputコマンドの終了
  if RShift_guard = False  ;ガードがかかってなかった場合（修飾キー＋Spaceのリリース）
      return
  RShift_guard = False     ;スペースキーガードを外す
  Send,{RShift Up}      ;シフトキー解放
  ifEqual RShift_key       ;RShift文字入力なし
      Send,^+{Space}          ;スペースを発射
  RShift_key=
return

$LShift::
  if LShift_guard = True   ;スペースキーガード
      return
  LShift_guard = True      ;スペースキーにガードをかける
  Send,{LShift Down}    ;シフトキーを仮想的に押し下げる
  ifNotEqual LShift_key    ;既に入力済みの場合は抜ける
      return
  LShift_key=
  Input,LShift_key,L1 V    ;1文字入力を受け付け（入力有無判定用）
return

$LShift up::             ;スペース解放時
  input                   ;既存のInputコマンドの終了
  if LShift_guard = False  ;ガードがかかってなかった場合（修飾キー＋Spaceのリリース）
      return
  LShift_guard = False     ;スペースキーガードを外す
  Send,{LShift Up}      ;シフトキー解放
  ifEqual LShift_key       ;LShift文字入力なし
      IME_SET(1)
  LShift_key=
return

$Tab::
  if Tab_guard = True   ;スペースキーガード
      return
  Tab_guard = True      ;スペースキーにガードをかける
  Send,{RAlt Down}    ;シフトキーを仮想的に押し下げる
  ifNotEqual Tab_key    ;既に入力済みの場合は抜ける
      return
  Tab_key=
  Input,Tab_key,L1 V    ;1文字入力を受け付け（入力有無判定用）
return

$Tab up::             ;スペース解放時
  input                   ;既存のInputコマンドの終了
  if Tab_guard = False  ;ガードがかかってなかった場合（修飾キー＋Spaceのリリース）
      return
  Tab_guard = False     ;スペースキーガードを外す
  Send,{RAlt Up}      ;シフトキー解放
  ifEqual Tab_key       ;Tab文字入力なし
      Send,{Tab}          ;スペースを発射
  Tab_key=
return

IME_SET(SetSts, WinTitle="A")    {
  ControlGet,hwnd,HWND,,,%WinTitle%
  if  (WinActive(WinTitle)) {
    ptrSize := !A_PtrSize ? 4 : A_PtrSize
      VarSetCapacity(stGTI, cbSize:=4+4+(PtrSize*6)+16, 0)
      NumPut(cbSize, stGTI,  0, "UInt")   ; DWORD   cbSize;
      hwnd := DllCall("GetGUIThreadInfo", Uint,0, Uint,&stGTI)
      ? NumGet(stGTI,8+PtrSize,"UInt") : hwnd
  }

  return DllCall("SendMessage"
    , UInt, DllCall("imm32\ImmGetDefaultIMEWnd", Uint,hwnd)
    , UInt, 0x0283  ;Message : WM_IME_CONTROL
    ,  Int, 0x006   ;wParam  : IMC_SETOPENSTATUS
    ,  Int, SetSts) ;lParam  : 0 or 1
}

plus_all(original_key) {
  IF GetKeyState("Shift", "p")
  {
    SendEvent, +%original_key%
  }
  ELSE IF GetKeyState("Ctrl", "p")
  {
    SendEvent, ^%original_key%
  }
  ELSE IF GetKeyState("Alt", "p")
  {
    SendEvent, !%original_key%
  }
  ELSE
  {
    SendEvent, %original_key%
  }
  Return
}

plus_shift(original_key) {
  IF GetKeyState("Shift", "p")
  {
    SendEvent, +%original_key%
  }
  ELSE IF GetKeyState("Alt", "p")
  {
    SendEvent, !%original_key%
  }
  ELSE
  {
    SendEvent, %original_key%
  }
  Return
}

; Applications you want to disable emacs-like keybindings
; (Please comment out applications you don't use)
is_target()
{
  IfWinActive,ahk_class VirtualConsoleClass
    Return 1
  IfWinActive,ahk_class ConsoleWindowClass ; Cygwin
    Return 1
  IfWinActive,ahk_class MEADOW ; Meadow
    Return 1
  IfWinActive,ahk_class cygwin/x X rl-xterm-XTerm-0
    Return 1
  IfWinActive,ahk_class MozillaUIWindowClass ; keysnail on Firefox
    Return 1
  ; Avoid VMwareUnity with AutoHotkey
  IfWinActive,ahk_class VMwareUnityHostWndClass
    Return 1
  IfWinActive,ahk_class Vim ; GVIM
    Return 1
  ; IfWinActive,ahk_class mintty
  ;   Return 1
  Return 0
}

;----------------------------------------------------------------
;キーを送信する
; キーバインドを無効にするウィンドウでは、送信されたキーをそのまま使用する
; キーバインドを有効にするウィンドウでは、送信されたキーを置き換える
;
;  引数 original_key:キーバインドを無効にするウィンドウの場合、送信するキー
;       replace_key:キーバインドを有効にするウィンドウの場合、送信するキー
;  戻り値 なし
;----------------------------------------------------------------
send_key(original_key,replace_key)
{
  if (is_target())
  {
    SendEvent,%original_key%
    return
  }
  SendEvent,%replace_key%
  return
}

;----------------------------------------------------------------
;  エクスプローラーのモード判定
;----------------------------------------------------------------
is_exp_edit(original_key,replace_key)
{
  ControlGetFocus, focusedControl, A
  if( focusedControl == "Edit1" || focusedControl == "Edit2" || focusedControl == "NetUIHWND1" )
  {
    SendEvent, %original_key%
    Return
  }
  if( focusedControl == "SysTreeView321" )
  {
    if( original_key = "h" )
    {
      SendEvent, {Left}
      Return
    }
    if( original_key = "l" )
    {
      SendEvent, {Right}
      Return
    }
  }
  SendEvent, %replace_key%
  Return
}

;----------------------------------------------------------------
;  エクセルのモード判定
;----------------------------------------------------------------
is_excel_edit(original_key,replace_key)
{
  ControlGetFocus, focusedControl, A
  if( focusedControl == "EXCEL61" || focusedControl == "NetUIHWND1" || focusedControl == "EXCEL<1" )
  {
    SendEvent, %original_key%
    Return
  }
  SendEvent, %replace_key%
  Return
}

;----------------------------------------------------------------
;  ブラウザとターミナルをトグル
;----------------------------------------------------------------
toggle_b_to_t()
{
  WinGetClass, focusedControl, A
  if( focusedControl == "CASCADIA_HOSTING_WINDOW_CLASS")
  {
    WinActivate, ahk_exe  vivaldi.exe
    Return
  }
  if( focusedControl == "Chrome_WidgetWin_1" )
  {
    WinActivate, ahk_exe WindowsTerminal.exe
    Return
  }
  WinActivate, ahk_exe WindowsTerminal.exe
  Return
}
LWIN & Space::toggle_b_to_t()

;LControl::LAlt
LWIN::SendEvent, {vk1D}  ;左Windowsキー to 無変換キー
RWIN::SendEvent, {vk1C}  ;右Windowsキー to 変換キー

; LControl & RShift::SendEvent, !{ESC}

LWIN & 1::plus_all("{F1}")
LWIN & 2::plus_all("{F2}")
LWIN & 3::plus_all("{F3}")
LWIN & 4::plus_all("{F4}")
LWIN & 5::plus_all("{F5}")
LWIN & 6::plus_all("{F6}")
LWIN & 7::plus_all("{F7}")
LWIN & 8::plus_all("{F8}")
LWIN & 9::plus_all("{F9}")
LWIN & 0::plus_all("{F10}")
LWIN & -::plus_all("{F11}")
LWIN & =::plus_all("{F12}")
LWIN & \::plus_all("{Insert}")
LWIN & h::plus_all("{*}")
LWIN & n::plus_all("{+}")
LWIN & j::plus_all("{/}")
LWIN & m::plus_all("{-}")
LWIN & k::plus_all("{Home}")
LWIN & ,::plus_all("{End}")
LWIN & l::plus_all("{PgUp}")
LWIN & >::plus_all("{PgDn}")
LWIN & [::plus_all("{Up}")
LWIN & `;::plus_all("{Left}")
LWIN & '::plus_all("{Right}")
LWIN & /::plus_all("{Down}")
LWIN & Del::plus_all("{Backspace}")

RWIN & q::winclose A
RWIN & l::Reload
>+ESC::send_key("<+ESC","{~}")

^;::Send,#v

>!c::
  WinGet, original, , A
  if( ErrorLevel == 0 )
  {
    WinGetPos, left, top, width, height, ahk_id %original%
    MouseMove, width - width / 2, height - height / 2, 100
  }
  return

#IfWinActive,ahk_class CASCADIA_HOSTING_WINDOW_CLASS
{
  Tab & Space::send_key("Tab", "!b")
  ; Tab & j::send_key("Tab","{Down}")
  Tab & j::
    If GetKeyState("LWIN", "p") {
      send_key("Tab","!{Down}")
    } else {
      send_key("Tab","{Down}")
    }
    return
  Tab & k::
    If GetKeyState("LWIN", "p") {
      send_key("Tab","!{Up}")
    } else {
      send_key("Tab","{Up}")
    }
    return
  Tab & l::
    If GetKeyState("LWIN", "p") {
      send_key("Tab","!{Right}")
    } else {
      send_key("Tab","{Right}")
    }
    return
  Tab & h::
    If GetKeyState("LWIN", "p") {
      send_key("Tab","!{Left}")
    } else {
      send_key("Tab","{Left}")
    }
    return
  Tab & p::send_key("Tab", "^{Up}")
  Tab & n::send_key("Tab", "^{Down}")

  ; Tab & #j::send_key("Tab","#{Down}")
  ; Tab & #k::send_key("Tab","#{Up}")
  ; Tab & #l::send_key("Tab","#{Left}")
  ; Tab & #h::send_key("Tab","#{Right}")

  LWIN & v::plus_shift("+{Insert}")

  !g::
    WinGet, original, , A
    Process, Exist, chrome.exe
    If(ErrorLevel) {
      WinActivate, ahk_pid %ErrorLevel%
      Send +{F5}
      sleep 200
    }
    WinActivate ahk_id %original%
    Return
  ^!g::
    WinGet, original, , A
    Process, Exist, chrome.exe
    If(ErrorLevel) {
      WinActivate, ahk_pid %ErrorLevel%
      Send {PgUp}
      sleep 200
    }
    WinActivate ahk_id %original%
    Return
  +!g::
    WinGet, original, , A
    Process, Exist, chrome.exe
    If(ErrorLevel) {
      WinActivate, ahk_pid %ErrorLevel%
      Send {PgDn}
      sleep 200
    }
    WinActivate ahk_id %original%
    Return
  #!g::
    WinGet, original, , A
    Process, Exist, chrome.exe
    If(ErrorLevel) {
      WinActivate, ahk_pid %ErrorLevel%
      Send {Enter}
      sleep 200
    }
    WinActivate ahk_id %original%
    Return
  !Space::
    WinGet, original, , A
    Process, Exist, QuickLook.exe
    If(ErrorLevel) {
      WinActivate, ahk_pid %ErrorLevel%
      sleep 200
      Send {Space}
      sleep 200
    }
    WinActivate ahk_id %original%
    Return
}

#ifWinActive,ahk_class illustrator
{
  <^h::send_key("^h","{left}{Del}") ; イラレできかない
}
#ifWinActive,ahk_class Photoshop
{
  ^c::plus_shift("^{d}")
}

; LWINとRWIN同時押しでスタートメニューが開く 副作用があるかも

#ifWinActive,ahk_class CabinetWClass
{
  ;----------------------------------------------------------------
  ;  エクスプローラーはvimバインドも追加
  ;----------------------------------------------------------------
  j::is_exp_edit("j","{Down}")
  +j::is_exp_edit("+j","+{Down}")
  k::is_exp_edit("k","{Up}")
  +k::is_exp_edit("+k","+{Up}")
  h::is_exp_edit("h","!{Up}")
  l::is_exp_edit("l","{Enter}")
  LWIN & n::plus_shift("^{n}")
}

#ifWinActive,ahk_class XLMAIN
{
  ;----------------------------------------------------------------
  ;  エクセルはvimバインドも追加
  ;----------------------------------------------------------------
  j::is_excel_edit("j","{Down}")
  +j::is_excel_edit("+j","+{Down}")
  k::is_excel_edit("k","{Up}")
  +k::is_excel_edit("+k","+{Up}")
  h::is_excel_edit("h","{Left}")
  +h::is_excel_edit("+h","+{Left}")
  l::is_excel_edit("l","{Right}")
  +l::is_excel_edit("+l","+{Right}")
}

#ifWinNotActive,ahk_class CASCADIA_HOSTING_WINDOW_CLASS
{
  LWIN & x::plus_shift("^{x}")
  LWIN & c::plus_shift("^{c}")
  LWIN & s::plus_shift("^{s}")
  LWIN & o::plus_shift("^{o}")
  LWIN & p::plus_shift("^{p}")
  LWIN & a::plus_shift("^{a}")
  LWIN & f::plus_shift("^{f}")
  LWIN & w::plus_shift("^{w}")
  LWIN & t::plus_shift("^{t}")
  LWIN & g::plus_shift("^{g}")
  LWIN & z::plus_shift("^{z}")
  LWIN & u::plus_shift("^{z}")
  LWIN & y::plus_shift("^{y}")
  LWIN & r::plus_shift("^{r}")

  LWIN & v::plus_shift("^{v}")

  ;================================================================
  ;ctrlキーバインド
  ;================================================================

  ;----------------------------------------------------------------
  ;移動系（shiftキーとの同時押し対応）
  ;ctrl + n : 下
  ;ctrl + p : 上
  ;ctrl + f : 右
  ;ctrl + b : 左
  ;ctrl + a : Home
  ;ctrl + e : End
  ;----------------------------------------------------------------

  <^n::send_key("^n","{Down}")
  <^+n::send_key("^+n","+{Down}")
  <^p::send_key("^p","{Up}")
  <^+p::send_key("^+p","+{Up}")
  <^f::send_key("^f","{Right}")
  <^+f::send_key("^+f","+{Right}")
  <^b::send_key("^b","{Left}")
  <^+b::send_key("^+b","+{Left}")
  <^a::send_key("^a","{Home}")
  <^+a::send_key("^+a","+{Home}")
  <^e::send_key("^e","{End}")
  <^+e::send_key("^+e","+{End}")

  <^c::send_key("^+c","+{ESC}")
  <^i::send_key("^i","{Tab}")
  <^+i::send_key("^+i","+{Tab}")

  ;----------------------------------------------------------------
  ;編集系
  ;ctrl + h : BackSpace
  ;ctrl + d : Delete
  ;ctrl + m : Enter
  ;ctrl + k : カーソルから行末まで削除
  ;----------------------------------------------------------------

  <^h::send_key("^h","{BS}")
  <^d::send_key("^d","{Del}")
  <^m::send_key("^m","{Return}")
  <^+m::send_key("^+m","{End}{Return}")
  <+Enter::send_key("+Enter","{End}{Return}")
  <^w::send_key("^w","^+{Left}{Del}")
  <!w::send_key("!w","^+{Right}{Del}")
  <^k::send_key("^k","+{End}{Del}")
  <^u::send_key("^u","+{Home}{Del}")
  <^[::send_key("^[","{Esc}")
  <^r::send_key("^r","+{F10}")

  ;------------------------------------------------------------------------------
  ;   カラーピッカー
  ;------------------------------------------------------------------------------
  ; マウスカーソルの位置の色を取得し、結果をクリップボードにコピー
  ; ALT + p = マウス
  ; 場合によってはmintty以外でも使えるようにしたほうが良いかも
  <!p::
      MouseGetPos, x, y
      PixelGetColor, color, %x%, %y%
      R := mod(color, 0x100)
      G := mod(color >> 8, 0x100)
      B := color >> 16
      msg := "(R, G, B) = (" . R . ", " . G . ", " . B . ")"

      SetFormat Integer, H
      R := SubStr(R + 0, 3)
      if (StrLen(R) < 2) {
          R := "0" . R
      }
      G := SubStr(G + 0, 3)
      if (StrLen(G) < 2) {
          G := "0" . G
      }
      B := SubStr(B + 0, 3)
      if (StrLen(B) < 2) {
          B := "0" . B
      }
      CLIPBOARD = #%R%%G%%B%
  Return

  ;------------------------------------------------------------------------------
  ;  ウインドウの移動
  ;------------------------------------------------------------------------------
  Left::SendEvent, "#{Left}"
  Right::SendEvent, "#{Right}"
  Up::SendEvent, "#{Up}"
  Down::SendEvent, "#{Down}"

  +!Left::WinMove(-20,0)
  +!Right::WinMove(20,0)
  +!Up::WinMove(0,-20)
  +!Down::WinMove(0,20)
  +Left::WinMove(-200,0)
  +Right::WinMove(200,0)
  +Up::WinMove(0,-200)
  +Down::WinMove(0,200)
  WinMove(MoveX, MoveY) {
    WinGetPos, X, Y, , , A
    X += MoveX
    Y += MoveY
    WinMove, A, , %X%, %Y%
  }

  WinSizeStep(XD,YD,PARAM) {
    WinGet,win_id,ID,A
    WinGetPos,,,w,h,ahk_id %win_id%
    Step := 128
    if(PARAM = 1)
      Step := 24
    w := w + (XD * Step)
    h := h + (YD * Step)
    WinMove,ahk_id %win_id%,,,,%w%,%h%
    return
  }
  ^Left::WinSizeStep(-1,0,0)
  ^Right::WinSizeStep(1,0,0)
  ^Up::WinSizeStep(0,-1,0)
  ^Down::WinSizeStep(0,1,0)
  ^#Left::WinSizeStep(-1,0,1)
  ^#Right::WinSizeStep(1,0,1)
  ^#Up::WinSizeStep(0,-1,1)
  ^#Down::WinSizeStep(0,1,1)

  ;------------------------------------------------------------------------------
  ;  ウインドウの固定
  ;------------------------------------------------------------------------------
  Pause:: Winset, Alwaysontop, , A ; ctrl + space
  Return
}
