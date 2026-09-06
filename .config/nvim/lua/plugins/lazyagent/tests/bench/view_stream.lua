-- Real visible-buffer streaming, including the transcript-limit rebuild path.
local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local output_path = assert(vim.env.LAZYAGENT_BENCH_OUT, 'set LAZYAGENT_BENCH_OUT')
vim.opt.rtp:prepend(root)
local uv=vim.uv
local updates=require('lazyagent.acp.view_buffer.updates')
local new=updates.new
local funcs
updates.new=function(ctx) funcs=new(ctx);return funcs end
local state=require('lazyagent.logic.state')
state.opts={acp={footer_animation=false}}
local view=require('lazyagent.acp.view_buffer')
local out={}
local reads,fullsets,tailcalls=0,0,0
local getlines,setlines,systemlist=vim.api.nvim_buf_get_lines,vim.api.nvim_buf_set_lines,vim.fn.systemlist
local counting=false
vim.api.nvim_buf_get_lines=function(...)
  local result=getlines(...)
  if counting then reads=reads+#result end
  return result
end
vim.api.nvim_buf_set_lines=function(b,s,e,...)
  if counting and s==0 and e==-1 then fullsets=fullsets+1 end
  return setlines(b,s,e,...)
end
vim.fn.systemlist=function(cmd,...)
  if counting and type(cmd)=='table' and cmd[1]=='tail' then tailcalls=tailcalls+1 end
  return systemlist(cmd,...)
end
for _, case in ipairs({{1000,12000},{12020,12000},{12020,0}}) do
  local count,limit,diffs=unpack(case)
  local path=vim.fn.tempname() .. '-stream.log'
  local lines={'─ Assistant ─'}
  for i=2,count do
    local row=i%10
    lines[i]=diffs and (row==1 and ' ```diff' or row==9 and ' ```' or ' +added line '..i) or ' text '..i
  end
  vim.fn.writefile(lines,path)
  local pane, pane_state
  view.create_pane({transcript_path=path,size=12,acp={agent_name='audit',transcript_max_lines=limit,source_winid=vim.api.nvim_get_current_win()}},function(id, created_state) pane=id; pane_state=created_state end)
  assert(vim.wait(1000,function() return pane~=nil end,10))
  local session={pane_id=pane,agent_name='audit',transcript_path=path,view_state={}}
  view.on_session_created(session)
  vim.wait(160)
  view.configure_pane(pane,{follow_output=false})
  collectgarbage('collect')
  local heap_before = collectgarbage('count')
  local samples={}
  reads,fullsets,tailcalls=0,0,0
  for i=1,16 do
    local text=' token '..i..'\n'
    local file=assert(io.open(path,'a'));file:write(text);file:close()
    view.on_transcript_updated(session,text,'a')
    counting=true
    local started=uv.hrtime()
    funcs.flush_pending_append(session)
    samples[#samples+1]=(uv.hrtime()-started)/1e6
    counting=false
    local bufnr = pane_state.bufnr
    local visible = table.concat(getlines(bufnr, 0, -1, false), '\n')
    assert(visible:find('token '..i, 1, true), 'latest appended text remains visible')
    if limit > 0 then assert(funcs.transcript_line_count(bufnr) <= limit + 1, 'display stays bounded') end
  end
  collectgarbage('collect')
  local retained_kib = collectgarbage('count') - heap_before
  table.sort(samples)
  out[#out+1]={lines=count,max_lines=limit,diffs=diffs==true,p50_ms=samples[8],max_ms=samples[#samples],read_lines=reads,full_replacements=fullsets,tail_processes=tailcalls,flushes=16,retained_lua_kib=retained_kib}
  view.kill_pane(pane,session)
  vim.wait(20)
  vim.fn.delete(path)
end
vim.fn.writefile({vim.json.encode(out)},output_path)
