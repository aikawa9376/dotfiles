#!/usr/bin/env python3
"""Real Nvim/lualine in a PTY; emulate DEC 2026 support to check cursor output.

Run: python3 tests/status_animation_ui.py (requires installed lualine.nvim).
The unsupported-terminal case records the cursor hide/show cost of TUI output;
the synchronized case must animate without hiding or showing the cursor.
"""
import fcntl,json,os,pathlib,pty,select,struct,subprocess,tempfile,termios,time
plugin=pathlib.Path(__file__).resolve().parents[1]
for synchronized in [False,True]:
 with tempfile.TemporaryDirectory(prefix='lazyagent-status-ui-') as d:
  root=pathlib.Path(d)
  script=r'''
vim.opt.rtp:prepend(PLUGIN)
vim.opt.rtp:prepend(vim.fn.stdpath('data')..'/lazy/lualine.nvim')
vim.o.laststatus=3;vim.o.showcmd=false;vim.o.ruler=false;vim.o.swapfile=false
local status=require('lazyagent.logic.status')
local spinner=require('lazyagent.logic.status_spinner')
local lualine=require('lualine')
local metrics={component_calls=0,ticks=0,redraw_ms=0,frames={},heap=0}
local task=status.start_task('Fixture')
local original=vim.api.nvim__redraw
local started=false;local all_ticks=0
vim.api.nvim__redraw=function(opts)
 local t=vim.uv.hrtime();original(opts);all_ticks=all_ticks+1
 if started then
  metrics.redraw_ms=metrics.redraw_ms+(vim.uv.hrtime()-t)/1e6
  metrics.ticks=metrics.ticks+1
  local cells={};for c=0,79 do cells[#cells+1]=vim.api.nvim__inspect_cell(1,22,c)[1] end
  metrics.frames[#metrics.frames+1]=table.concat(cells)
 end
end
lualine.setup({options={globalstatus=true,theme='auto',component_separators='',section_separators=''},
 sections={lualine_a={},lualine_b={},lualine_c={{function() metrics.component_calls=metrics.component_calls+1;return 'EXPENSIVE' end}},lualine_x={{status.get_statusline}},lualine_y={},lualine_z={}}})
vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.defer_fn(function()
 metrics.component_calls=0;started=true
 local changedtick=vim.b.changedtick;local cursor=vim.api.nvim_win_get_cursor(0);local view=vim.fn.winsaveview()
 collectgarbage('collect');local heap=collectgarbage('count')
 io.stdout:write('PROBE_START');io.stdout:flush()
 vim.defer_fn(function()
  io.stdout:write('PROBE_END');io.stdout:flush();started=false
  metrics.changedtick_same=changedtick==vim.b.changedtick
  metrics.cursor_same=vim.deep_equal(cursor,vim.api.nvim_win_get_cursor(0))
  metrics.view_same=vim.deep_equal(view,vim.fn.winsaveview())
  collectgarbage('collect');metrics.heap=collectgarbage('count')-heap
  status.stop_task(task)
  lualine.refresh({place={'statusline'},force=true})
  local count=all_ticks
  vim.defer_fn(function()
   metrics.stopped=all_ticks==count
   vim.fn.writefile({vim.json.encode(metrics)},OUTPUT)
   vim.cmd('qa!')
  end,250)
 end,1200)
end,500) end})
'''.replace('PLUGIN',json.dumps(str(plugin))).replace('OUTPUT',json.dumps(str(root/'result.json')))
  (root/'init.lua').write_text(script)
  m,s=pty.openpty();fcntl.ioctl(s,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
  p=subprocess.Popen(['nvim','--clean','-n','-i','NONE','-u',str(root/'init.lua')],stdin=s,stdout=s,stderr=s,env={**os.environ,'TERM':'xterm-256color'})
  os.close(s);out=b'';deadline=time.monotonic()+10;responded=False
  while time.monotonic()<deadline:
   if select.select([m],[],[],.1)[0]:
    try: data=os.read(m,65536)
    except OSError:break
    out+=data
    if synchronized and not responded and b'\x1b[?2026$p' in out:
     os.write(m,b'\x1b[?2026;2$y');responded=True
   if p.poll() is not None:break
  if p.poll() is None:p.kill()
  p.wait();os.close(m)
  assert p.returncode==0 and (root/'result.json').exists(),out[-3000:].decode(errors='replace')
  metrics=json.loads((root/'result.json').read_text())
  data=out.split(b'PROBE_START')[-1].split(b'PROBE_END')[0]
  metrics.update(synchronized=synchronized,hide=data.count(b'\x1b[?25l'),show=data.count(b'\x1b[?25h'),sync_frames=data.count(b'\x1b[?2026h'),bytes=len(data))
  frames=metrics.pop('frames');metrics['unique_frames']=len(set(frames))
  print(json.dumps(metrics,ensure_ascii=False))
  assert metrics['ticks']>=10 and metrics['component_calls']<=4
  assert len(set(frames))==10, 'spinner must visit every frame on the native screen'
  assert metrics['changedtick_same'] and metrics['cursor_same'] and metrics['view_same'] and metrics['stopped']
  if synchronized:assert metrics['hide']==metrics['show']==0 and metrics['sync_frames']>=10
