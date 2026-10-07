#!/usr/bin/env python3
"""Real TUI: native diff masks, syntax colors and window-only span projection."""
import fcntl, json, os, pathlib, pty, select, struct, subprocess, tempfile, termios, time
plugin = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='git-split-tui-') as directory:
    root = pathlib.Path(directory)
    script = r"""
vim.opt.swapfile=false; vim.opt.shadafile='NONE'; vim.opt.termguicolors=true
vim.opt.rtp:prepend('PLUGIN')
vim.opt.rtp:append(vim.fn.stdpath('data')..'/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data')..'/lazy/nvim-treesitter/runtime')
vim.cmd('syntax enable')
vim.api.nvim_set_hl(0,'Normal',{fg=0xeeeeee,bg=0x002b36})
vim.api.nvim_set_hl(0,'NormalNC',{fg=0xeeeeee,bg=0x002b36})
vim.api.nvim_set_hl(0,'DiffAdd',{bg=0xff0000,fg=0xffffff})
vim.api.nvim_set_hl(0,'DiffChange',{bg=0xff0000,fg=0xffffff})
vim.api.nvim_set_hl(0,'DiffText',{bg=0xff0000,fg=0xffffff})
vim.api.nvim_set_hl(0,'DiffTextAdd',{bg=0xff0000,fg=0xffffff})
vim.api.nvim_set_hl(0,'@keyword.function.lua',{fg=0xee77aa})
vim.api.nvim_set_hl(0,'@variable.parameter.lua',{fg=0x88bbcc})
vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.schedule(function()
 local split=require('git.features.split_diff'); local syntax=require('git.features.syntax_highlight')
 local old={'function calculate(value)','  return value + 1','end'}
 local new={'function calculate(value, extra)','  return value + 1','end'}
 local function source(name, lines)
  local buf=vim.api.nvim_create_buf(false,true)
  vim.api.nvim_buf_set_name(buf,'git-diff://tui/'..name..'/file.lua')
  vim.api.nvim_buf_set_lines(buf,0,-1,false,lines); vim.bo[buf].filetype='lua'
  return buf
 end
 local left=source('old',old); local right=source('new',new)
 vim.api.nvim_win_set_buf(0,left); local lw=vim.api.nvim_get_current_win(); vim.cmd('diffthis')
 vim.cmd('rightbelow vsplit'); local rw=vim.api.nvim_get_current_win()
 vim.api.nvim_win_set_buf(rw,right); vim.cmd('diffthis')
 local s=split.attach(lw,rw)
 vim.cmd('rightbelow vsplit');local ordinary=vim.api.nvim_get_current_win(); vim.cmd('diffoff')
 for _,win in ipairs({lw,rw,ordinary}) do
  vim.wo[win].number=false;vim.wo[win].relativenumber=false;vim.wo[win].foldcolumn='0'
  vim.wo[win].foldenable=false;vim.wo[win].signcolumn='no';vim.wo[win].cursorline=false;vim.wo[win].wrap=false
 end
 local function snapshot()
  vim.cmd('redraw!');vim.api.nvim__inspect_cell(1,0,0);vim.cmd('redraw!')
  local result={}
  for key,win in pairs({old=lw,new=rw,ordinary=ordinary}) do
   local p=vim.api.nvim_win_get_position(win);local cells={}
   for col=0,40 do cells[col+1]=vim.api.nvim__inspect_cell(1,p[1],p[2]+col) end
   result[key]=cells
  end
  return result
 end
 local cold=snapshot();local deadline=vim.uv.hrtime()+10e9
 local result={cold=cold};local phase=0
 local function finish()
  assert(vim.uv.hrtime()<deadline,'split TUI timeout')
  if s.pending then vim.defer_fn(finish,10);return end
  if phase==0 then result.ready=snapshot();syntax.toggle_changed_fg();phase=1
  elseif phase==1 then result.foreground=snapshot();syntax.set_word_diff_style('delta');phase=2
  elseif phase==2 then
   result.delta=snapshot();vim.fn.writefile({vim.json.encode(result)},'OUTPUT');vim.cmd('qa!');return
  end
  vim.defer_fn(finish,10)
 end
 vim.defer_fn(finish,10)
end) end})
""".replace('PLUGIN', str(plugin)).replace('OUTPUT', str(root/'cells.json'))
    (root/'ui.lua').write_text(script)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',35,180,0,0))
    process = subprocess.Popen(['nvim','--clean','-u',str(root/'ui.lua'),'-i','NONE','-n'],
        stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'})
    os.close(slave); deadline=time.monotonic()+20; output=b''
    while process.poll() is None and time.monotonic()<deadline:
        if select.select([master],[],[],.1)[0]:
            try: output+=os.read(master,65536)
            except OSError: break
    if process.poll() is None: process.kill()
    process.wait();os.close(master)
    assert process.returncode==0 and (root/'cells.json').exists(), output[-2000:].decode(errors='replace')
    results=json.loads((root/'cells.json').read_text())
    def bg(cell): return cell[1].get('background',0x002b36)
    for phase in ['cold','ready','foreground']:
        result=results[phase]
        assert all(bg(cell)==0x002b36 for cell in result['old']), (phase,'unchanged old line received native tint')
        assert all(bg(cell)==0x002b36 for cell in result['new'][:24]), (phase,'unchanged new prefix received tint')
        assert all(bg(cell)==0x002b36 for cell in result['new'][len('function calculate(value, extra)'):]), (phase,'row tail received tint')
        assert all(bg(cell)==0x002b36 for cell in result['ordinary']), (phase,'split tint leaked to ordinary window')
        assert result['new'][0][0]=='f', (phase,'split unexpectedly has a gutter overlay')
    assert results['ready']['new'][0][1]['foreground']==0xee77aa, 'Tree-sitter keyword color lost'
    assert results['ready']['new'][26][1]['foreground']==0x88bbcc, 'Tree-sitter parameter color lost'
    assert bg(results['ready']['new'][26])==0x1f4534, 'new argument has no structural background'
    assert results['foreground']['new'][26][1]['foreground'] != 0x88bbcc, 'foreground option ignored'
    assert bg(results['foreground']['new'][26])==0x1f4534, 'foreground changed background classification'
    assert bg(results['delta']['new'][0])==0x23384c, 'delta did not restore ordinary line background'
    assert bg(results['delta']['new'][26])==0x005f5f, 'delta word accent missing'
    assert all(bg(cell)==0x002b36 for cell in results['delta']['ordinary']), 'delta leaked to ordinary window'
print('PASS: split TUI pending/ready spans, syntax/native foregrounds, delta and ordinary-window isolation')
