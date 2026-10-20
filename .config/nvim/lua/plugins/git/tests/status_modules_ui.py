"""Real TUI: shelf labels suppress Git syntax without pinning window backgrounds."""
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
with tempfile.TemporaryDirectory(prefix='git-shelf-tui-') as directory:
    root = pathlib.Path(directory)
    script = r"""
vim.opt.termguicolors=true;vim.opt.swapfile=false;vim.opt.shadafile='NONE'
vim.opt.rtp:prepend(PLUGIN);vim.cmd('syntax enable')
local api=vim.api
api.nvim_set_hl(0,'Normal',{fg=0x839496,bg=0x002b36})
api.nvim_set_hl(0,'NormalNC',{bg=0x073642})
api.nvim_set_hl(0,'Type',{fg=0xe6a852})
api.nvim_set_hl(0,'Identifier',{fg=0xe6a852})
api.nvim_set_hl(0,'Comment',{fg=0x586e75,italic=true})
api.nvim_set_hl(0,'WarningMsg',{fg=0xff00ff})
api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.schedule(function()
 local ok,err=pcall(function()
  local modules=require('git.features.status_modules')
  local items={
   {id='done',text='done planning',detail='2026-10-20'},
   {id='hash',text='deadbeef guide'},
   {id='modifier',text='M note'},
   {id='custom',text='Custom color',highlight='WarningMsg'},
  }
  modules.setup({{id='notes',title='Related notes',load=function(_,done) done(items) end}})
  local buf=api.nvim_create_buf(false,true);api.nvim_win_set_buf(0,buf)
  vim.bo[buf].filetype='gitstatus'
  local notes=api.nvim_get_current_win()
  modules.attach(buf,function()
   local lines,_,rows=modules.compose(buf,{'Commits (1)','deadbeef Commit subject',''})
   api.nvim_buf_set_lines(buf,0,-1,false,lines);modules.commit(buf,rows)
  end)
  modules.refresh(buf,{root='/fixture',branch='main'})
  assert(vim.wait(1000,function() return not require('git.features.loading').busy(buf) end,10))
  vim.cmd('rightbelow vsplit');vim.cmd('enew');local other=api.nvim_get_current_win()
  for _,win in ipairs({notes,other}) do
   for _,option in ipairs({'number','relativenumber','cursorline','foldenable'}) do vim.wo[win][option]=false end
   vim.wo[win].signcolumn='no';vim.wo[win].foldcolumn='0';vim.wo[win].wrap=false
  end
  local function check(background,foreground)
   vim.cmd('redraw!');api.nvim__inspect_cell(1,0,0);vim.cmd('redraw!')
   local position=api.nvim_win_get_position(notes)
   local normal=api.nvim_get_hl(0,{name='Normal'})
   local function cell(row,col)
    return api.nvim__inspect_cell(1,position[1]+row-1,position[2]+col)[2]
   end
   assert((cell(2,0).foreground or normal.fg)==0xe6a852,'Native Git hash lost syntax color')
   for row,info in pairs(modules.rows(buf)) do if info.kind=='item' then
    local item=info.item
    for col=0,#item.text-1 do
     local actual=cell(row,col)
     assert((actual.foreground or normal.fg)==(item.highlight and 0xff00ff or foreground),
      'Git syntax leaked into shelf label: '..item.text)
     assert((actual.background or normal.bg)==background,'Shelf text pinned its background')
    end
    assert((cell(row,40).background or normal.bg)==background,'Shelf row tail pinned its background')
    if item.detail then
     local date=cell(row,#item.text+2)
     assert(date.foreground==0x586e75,'Date lost Comment color')
     assert((date.background or normal.bg)==background,'Date pinned its background')
    end
   end end
  end
  check(0x073642,0x839496)
  api.nvim_set_current_win(notes);check(0x002b36,0x839496)
  api.nvim_set_hl(0,'Normal',{fg=0xaabbcc,bg=0x193549})
  api.nvim_exec_autocmds('ColorScheme',{});check(0x193549,0xaabbcc)
  api.nvim_set_current_win(other);check(0x073642,0xaabbcc)
  modules.cleanup(buf)
 end)
 vim.fn.writefile({ok and 'PASS: shelf text/date/custom colors, Git syntax isolation, focus backgrounds and theme refresh' or tostring(err)},OUTPUT)
 vim.cmd(ok and 'qa!' or 'cquit 1')
end) end})
""".replace('PLUGIN', json.dumps(str(plugin))).replace('OUTPUT', json.dumps(str(root / 'result')))
    (root / 'ui.lua').write_text(script)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 140, 0, 0))
    process = subprocess.Popen(['nvim', '--clean', '-u', str(root / 'ui.lua'), '-i', 'NONE', '-n'],
                               stdin=slave, stdout=slave, stderr=slave,
                               env={**os.environ, 'TERM': 'xterm-256color'})
    os.close(slave)
    deadline, output = time.monotonic() + 15, b''
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
    result = (root / 'result').read_text().strip() if (root / 'result').exists() else output[-2000:].decode(errors='replace')
    assert process.returncode == 0, result
    print(result)
