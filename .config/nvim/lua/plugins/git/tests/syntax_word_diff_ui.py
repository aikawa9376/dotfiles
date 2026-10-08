#!/usr/bin/env python3
"""Verify actual TUI foreground composition before and after async highlighting.

Run with Python; uses the installed Neovim and Tree-sitter parsers, stdlib only.
"""
import os,pty,subprocess,select,time,fcntl,termios,struct,json,pathlib,sys
plugin=pathlib.Path(__file__).resolve().parents[1]
workspace=__import__('tempfile').TemporaryDirectory(prefix='git-highlight-tui-')
root=pathlib.Path(workspace.name)
fixture=json.loads((plugin/'tests/fixtures/difftastic_word_diff.json').read_text())
(root/'notices.patch').write_text('\n'.join(fixture['patches']['reported_notices']))
script=r'''
vim.opt.swapfile=false;vim.opt.shadafile='NONE';vim.opt.termguicolors=true
vim.opt.rtp:prepend('/home/aikawa/dotfiles/.config/nvim/lua/plugins/git')
vim.opt.rtp:append(vim.fn.stdpath('data')..'/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data')..'/lazy/nvim-treesitter/runtime')
vim.opt.rtp:prepend(vim.fn.stdpath('data')..'/lazy/nightfox.nvim')
if 'TEST_COLORSCHEME'=='nordfox' then
 local config=dofile('/home/aikawa/dotfiles/.config/nvim/lua/plugins/git/../nightfox.lua')
 config.opts.options.compile_path='/tmp/git-ts-followup/nightfox'
 require('nightfox').setup(config.opts)
end
vim.cmd('colorscheme TEST_COLORSCHEME');vim.cmd('syntax enable')
vim.api.nvim_set_hl(0,'diffAdded',{fg=0x00cc20});vim.api.nvim_set_hl(0,'diffRemoved',{fg=0xe00020})
vim.api.nvim_set_hl(0,'GitSignsAdd',{fg=0x00cc20});vim.api.nvim_set_hl(0,'GitSignsDelete',{fg=0xe00020})
vim.g.terminal_color_9='#f07178';vim.g.terminal_color_10='#c3e88d'
vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function()vim.schedule(function()
 local syntax=require('git.features.syntax_highlight');local buf=vim.api.nvim_get_current_buf()
 assert(syntax.config.changed_fg=='syntax','diff foreground must be opt-in');syntax.config.changed_fg='difft'
 local lines={'Head: master','Unstaged changes (3)','M lazy-lock.json','@@ -2 +2 @@',
 '-  "blink-ripgrep.nvim": { "branch": "main", "commit": "a7804525b1d52bd9709d7b78ae23d8152f967ae6" },',
 '+  "blink-ripgrep.nvim": { "branch": "main", "commit": "ed56dfc1bfd72aed054ca100b5c137285fdee1ee" },',
 'M sample.lua','@@ -1 +1 @@','-function Utils.extract_change_groups(hunk_lines)',
 '+function Utils.extract_change_groups(hunk_lines, include_one_sided)',
 'M mixed.lua','@@ -3,6 +3,6 @@',' end',' ',
 '-function Mixed(', '+function Mixed(', '-  value', '+  value, extra', ' )', '   local kept = value',
 'M THIRD_PARTY_NOTICES.md','@@ -86,3 +86,48 @@'}
 for _,line in ipairs(vim.fn.readfile('/tmp/git-ts-followup/notices.patch'))do
  if line:sub(1,1)=='+' and line:sub(1,3)~='+++' then lines[#lines+1]=line end
 end
 vim.api.nvim_buf_set_lines(buf,0,-1,false,lines);vim.bo.filetype='gitstatus'
 vim.wo.foldenable=false;vim.wo.number=false;vim.wo.relativenumber=false;vim.wo.signcolumn='no';vim.wo.foldcolumn='0';vim.wo.cursorline=false
 syntax.attach(buf,{diff_source=function(hunk)
  if hunk.filename=='lazy-lock.json' then
   return {old={text='{\n'..lines[5]:sub(2)..'\n  "following": {}\n}\n'},new={text='{\n'..lines[6]:sub(2)..'\n  "following": {}\n}\n'}}
  elseif hunk.filename=='sample.lua' then
   return {old={text=lines[9]:sub(2)..'\nend\n'},new={text=lines[10]:sub(2)..'\nend\n'}}
  elseif hunk.filename=='mixed.lua' then
   local function full(parameter)return 'function Before()\n  return 1\nend\n\nfunction Mixed(\n  '..parameter..'\n)\n  local kept = value\n  return kept\nend\n'end
   return {old={text=full('value')},new={text=full('value, extra')}}
  end
 end})
 local function snapshot()
  vim.cmd('redraw!');vim.api.nvim__inspect_cell(1,0,0);vim.cmd('redraw!')
  local results={normal=vim.api.nvim_get_hl(0,{name='Normal',link=false}),lines=lines,rows={}}
  for key,name in pairs({keyword_fg='@keyword.function.lua',property_fg='@property.json',parameter_fg='@variable.parameter.lua',add_fg='GitExtNovelAdd',delete_fg='GitExtNovelDelete'})do
   results[key]=vim.api.nvim_get_hl(0,{name=name,link=false}).fg
  end
  for row=0,#lines-1 do
   local cells={};for col=0,#lines[row+1]+4 do cells[col+1]=vim.api.nvim__inspect_cell(1,row,col) end
   results.rows[#results.rows+1]=cells
  end
  return results
 end
 local cold=snapshot();local started=vim.uv.hrtime();local ready;local syntax_ready;local inspect=vim.treesitter.language.inspect
 local function finish()
  if syntax.is_pending(buf) then
   assert((vim.uv.hrtime()-started)/1e9<30,'timed out waiting for highlights');vim.defer_fn(finish,10);return
  end
  if not ready then
   ready=snapshot()
   syntax.config.changed_fg='syntax';syntax.refresh(buf);vim.defer_fn(finish,10);return
  end
  if not syntax_ready then
   syntax_ready=snapshot()
   vim.treesitter.language.inspect=function(lang)if lang=='lua'then error('parser unavailable')end;return inspect(lang)end
   syntax.refresh(buf);vim.defer_fn(finish,10);return
  end
  local legacy=snapshot();legacy.keyword=vim.fn.synIDattr(vim.fn.synID(9,2,1),'name')
  legacy.cluster=vim.fn.execute('silent! syntax list @GitExt_lua');legacy.fun=vim.fn.execute('silent! syntax list luaFunctionBlock');legacy.iskeyword=vim.bo.iskeyword
  legacy.keyword_fg=vim.api.nvim_get_hl(0,{name=legacy.keyword,link=false}).fg
  vim.treesitter.language.inspect=inspect
  vim.fn.writefile({vim.json.encode({cold=cold,ready=ready,syntax_ready=syntax_ready,legacy=legacy})},'/tmp/git-ts-followup/cells.json');vim.cmd('qa!')
 end
 vim.defer_fn(finish,10)
end)end})
'''
theme=sys.argv[1] if len(sys.argv)>1 else 'default'
assert theme in ('default','nordfox')
script=script.replace('TEST_COLORSCHEME',theme).replace('/home/aikawa/dotfiles/.config/nvim/lua/plugins/git',str(plugin)).replace('/tmp/git-ts-followup',str(root))
(root/'ui.lua').write_text(script)
m,s=pty.openpty();fcntl.ioctl(s,termios.TIOCSWINSZ,struct.pack('HHHH',90,220,0,0))
p=subprocess.Popen(['nvim','--clean','-u',str(root/'ui.lua'),'-i','NONE','-n'],stdin=s,stdout=s,stderr=s,env={**os.environ,'TERM':'xterm-256color'})
os.close(s);deadline=time.monotonic()+35;data=b''
while p.poll() is None and time.monotonic()<deadline:
 if select.select([m],[],[],.1)[0]:
  try:data+=os.read(m,65536)
  except OSError:break
if p.poll() is None:p.kill()
p.wait();os.close(m);(root/'ui.raw').write_bytes(data)
assert p.returncode==0, 'TUI did not finish: '+data[-1500:].decode(errors='replace')
x=json.loads((root/'cells.json').read_text())
for phase in ('cold','ready'):
 y=x[phase]; normal=y['normal']['bg']
 for line,row in zip(y['lines'],y['rows']):
  if line.startswith(('+','-')):
   assert row[0][0]=='▏', (phase,line,'gutter')
   for c in range(1,len(line)):
    assert row[c][1].get('foreground',y['normal']['fg']) not in (0x00cc20,0xe00020), (phase,line,c,row[c])
   assert all(cell[1].get('background',normal)==normal for cell in row[len(line):])
for phase in ('ready','syntax_ready'):
 y=x[phase]
 for index in (8,9):
  assert y['rows'][index][1][1]['foreground']==y['keyword_fg'], (phase,'incomplete function lacks Tree-sitter color')
 for index in (4,5):
  assert y['rows'][index][4][1]['foreground']==y['property_fg'], (phase,'incomplete JSON key lacks Tree-sitter color')
 for line,row in zip(y['lines'],y['rows']):
  if line.startswith(('-function Mixed','+function Mixed')):
   assert row[1][1]['foreground']==y['keyword_fg'], (phase,'mixed-context multiline function lacks Tree-sitter color')
parameter=x['ready']['lines'][9].index('include_one_sided')
assert x['ready']['rows'][9][parameter][1]['foreground']==x['ready']['add_fg']==0xc3e88d
assert x['syntax_ready']['rows'][9][parameter][1]['foreground']==x['syntax_ready']['parameter_fg']
assert x['ready']['rows'][9][parameter][1]['background']==x['syntax_ready']['rows'][9][parameter][1]['background']
y=x['ready'];normal=y['normal']['bg'];in_md=False
for line,row in zip(y['lines'],y['rows']):
 if line.startswith('M THIRD_'):in_md=True
 if line.startswith('+') and in_md and len(line)>1:
  assert all(cell[1].get('background',normal)==0x1f4534 for cell in row[1:len(line)]), (line,'MD prose background')
 if line.startswith(('-function Utils','+function Utils','-  "','+  "')):
  end=line.index(',') if line.startswith('+function Utils') else (line.index('{') if line.startswith(('-  "','+  "')) else len(line))
  assert all(cell[1].get('background',normal)==normal for cell in row[1:end]), (line,'unchanged foreground span received BG')
legacy=x['legacy'];assert legacy['keyword'].startswith('lua'), {key:legacy[key] for key in ('keyword','cluster','fun','iskeyword')}
assert legacy['rows'][8][1][1].get('foreground',legacy['normal']['fg'])==legacy['keyword_fg'], 'normal foreground masked Vim syntax'
print('PASS: cold/ready TUI, recovered Tree-sitter key/keyword colors, native/syntax changed foregrounds, Markdown prose and Vim fallback')
workspace.cleanup()
