"""Real TUI: public/private PR split markers stay on their own code windows."""
import fcntl
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

plugin = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='git-pr-split-tui-') as directory:
    root = pathlib.Path(directory)
    script = r"""
vim.opt.swapfile=false; vim.opt.shadafile='NONE'
package.path=PLUGIN..'/lua/?.lua;'..PLUGIN..'/tests/?.lua;'..package.path
vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.schedule(function()
 local ok,err=pcall(function()
  local f=require('helpers.pr_fixture').new()
  local ui=require('helpers.pr_ui').new(f)
  local api=vim.api
  f.reviews={{id=88,node_id='REVIEW88',commit_id=f.head,state='PENDING',body='',
   user={login=f.viewer},comments={{id=601,body='Draft',user={login=f.viewer},
    path='file name.txt',line=3,start_line=2,side='RIGHT',commit_id=f.head,subject_type='line'}}}}
  f.resolved={[201]=true}
  ui.open(); ui.key('d',ui.row('M file name.txt'))
  local bridge=require('git.features.pr_split')
  local s=assert(bridge._states[api.nvim_get_current_tabpage()])
  ui.wait(function() return s.coordinates and not s.loading end)
  local left,right=s.panes[1],s.panes[2]
  vim.cmd('rightbelow vsplit');local ordinary=api.nvim_get_current_win();vim.cmd('diffoff')
  for _,win in ipairs({left.win,right.win,ordinary}) do
   vim.wo[win].number=false;vim.wo[win].relativenumber=false;vim.wo[win].foldcolumn='0'
   vim.wo[win].foldenable=false;vim.wo[win].signcolumn='no';vim.wo[win].cursorline=false;vim.wo[win].wrap=false
  end
  local function snapshot()
   vim.cmd('redraw!');api.nvim__inspect_cell(1,0,0);vim.cmd('redraw!')
   local result={}
   for key,win in pairs({left=left.win,right=right.win,ordinary=ordinary}) do
    local rows={}
    for line=1,api.nvim_buf_line_count(api.nvim_win_get_buf(win)) do
     local pos=vim.fn.screenpos(win,line,1);local text=''
     assert(pos.row>0,'Code row hidden')
     for col=pos.col-1,pos.col+api.nvim_win_get_width(win)-2 do
      local cell=api.nvim__inspect_cell(1,pos.row-1,col)
      text=text..(cell[1] or '')
     end
     rows[line]=text
    end
    result[key]=rows
   end
   return result
  end
  local first=snapshot()
  api.nvim_set_current_win(right.win)
  vim.fn.maparg('q','n',false,true).callback()
  assert(api.nvim_win_is_valid(ordinary),'q closed ordinary window')
  api.nvim_set_current_win(ordinary);vim.cmd('redraw!')
  local rows={}
  for line=1,api.nvim_buf_line_count(0) do
   local pos=vim.fn.screenpos(ordinary,line,1);local text=''
   for col=pos.col-1,pos.col+api.nvim_win_get_width(ordinary)-2 do
    local cell=api.nvim__inspect_cell(1,pos.row-1,col);text=text..(cell[1] or '')
   end
   rows[line]=text
  end
  vim.fn.writefile({vim.json.encode({first=first,closed=rows})},OUTPUT)
  f.cleanup()
 end)
 if not ok then vim.fn.writefile({tostring(err)},ERROR);vim.cmd('cquit 1') else vim.cmd('qa!') end
end) end})
""".replace('PLUGIN', json.dumps(str(plugin))).replace('OUTPUT', json.dumps(str(root / 'rows.json'))).replace('ERROR', json.dumps(str(root / 'error.txt')))
    (root / 'ui.lua').write_text(script)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 180, 0, 0))
    process = subprocess.Popen(['nvim', '--clean', '-u', str(root / 'ui.lua'), '-i', 'NONE', '-n'],
                               stdin=slave, stdout=slave, stderr=slave,
                               env={**os.environ, 'TERM': 'xterm-256color'})
    os.close(slave)
    deadline, output = time.monotonic() + 20, b''
    while process.poll() is None and time.monotonic() < deadline:
        if select.select([master], [], [], .1)[0]:
            try:
                output += os.read(master, 65536)
            except OSError:
                break
    if process.poll() is None:
        process.kill()
    process.wait()
    os.close(master)
    error = (root / 'error.txt').read_text() if (root / 'error.txt').exists() else output[-2000:].decode(errors='replace')
    assert process.returncode == 0 and (root / 'rows.json').exists(), error
    result = json.loads((root / 'rows.json').read_text())
    assert '💬 1' in result['first']['left'][1] and '✅ 1' in result['first']['left'][1], result
    assert '💬 1' in result['first']['right'][1], result
    assert '📝 1 [pending]' in result['first']['right'][2], result
    for rows in (result['first']['ordinary'], result['closed']):
        assert all('💬' not in row and '📝' not in row and '✅' not in row for row in rows), rows
print('PASS: actual PR split public/private/resolved markers and ordinary-window isolation')
