" vim: set sw=2 ts=2 sts=2 foldmethod=marker et:

" In case this gets sourced twice.
if exists('*TermDebugStart')
  finish
endif

" Name of the gdb command, defaults to "gdb".
if !exists('g:termdebugger')
  let g:termdebugger = 'gdb'
endif

" Highlights for sign column
hi default link debugPC CursorLine
hi default debugBreakpoint gui=reverse guibg=red
hi default debugBreakpointDisabled gui=reverse guibg=gray

""""""""""""""""""""""""""""""""Go to"""""""""""""""""""""""""""""""""""""""""{{{
func TermDebugGoToPC()
  if bufexists(s:pcbuf)
    exe "b " . s:pcbuf
    let ns = nvim_create_namespace('TermDebugPC')
    let pos = nvim_buf_get_extmarks(0, ns, 0, -1, #{})[0]
    call cursor(pos[1] + 1, 0)
  end
endfunc

func TermDebugGoToBreakpoint(...)
  let id = get(a:000, 0, "")
  " No argument supplied, load breakpoints into quickfix
  if id == ""
    call TermDebugBrToQf()
    return
  endif

  if !has_key(s:breakpoints, id)
    echo "No breakpoint " . id
    return
  endif

  let breakpoint = s:breakpoints[id]
  let lnum = breakpoint['lnum']
  let fullname = breakpoint['fullname']
  if expand("%:p") != fullname
    exe "e " . fnameescape(fullname)
  endif
  call cursor(lnum, 0)
endfunc

func TermDebugGoToCapture()
  let ids = win_findbuf(bufnr(s:capture_bufname))
  if empty(ids)
    exe "tabnew " . s:capture_bufname
  else
    call win_gotoid(ids[0])
  endif
endfunc

func TermDebugGoToSource()
  if !win_gotoid(s:sourcewin)
    below new
    let s:sourcewin = win_getid(winnr())
  endif
endfunc

func TermDebugGoToGdb()
  let nr = bufnr(s:prompt_bufname)
  let wids = win_findbuf(nr)
  if !empty(wids)
    call win_gotoid(wids[0])
  else
    above new
    exe "b " . nr
  endif
endfunc
"}}}

""""""""""""""""""""""""""""""""Global functions""""""""""""""""""""""""""""""{{{
func TermDebugIsOpen()
  if !exists('s:gdb_job_id')
    return v:false
  endif
  silent! return jobpid(s:gdb_job_id) > 0
endfunc

func TermDebugIsStopped()
  if !TermDebugIsOpen()
    return v:true
  endif
  return s:stopped
endfunc

func TermDebugQuit()
  call TermDebugSendMICommand('-gdb-exit', function("s:Ignore"))
endfunc

func TermDebugGetPid()
  if !TermDebugIsOpen()
    return 0
  endif
  return s:pid
endfunc

func TermDebugShowPwd()
  call TermDebugSendMICommand('-environment-pwd', function('s:HandlePwd'))
endfunc

func TermDebugSendMICommand(cmd, Callback)
  let token = s:token_counter
  let s:token_counter += 1
  let s:callbacks[token] = a:Callback
  let cmd = printf("%d%s", token, a:cmd)
  call chansend(s:gdb_job_id, cmd . "\n")
endfunc

func TermDebugSendCommand(cmd)
  if !TermDebugIsStopped()
    echo "Cannot send command. Program is running."
    return
  endif
  let msg = printf('-interpreter-exec console "%s"', a:cmd)
  call TermDebugSendMICommand(msg, function('s:Ignore'))
endfunc

func TermDebugSendCommands(...)
  if !TermDebugIsStopped()
    echo "Cannot send command. Program is running."
    return
  endif
  for cmd in a:000
    call chansend(s:gdb_job_id, cmd . "\n")
  endfor
endfunc

func TermDebugToggleAsm()
  let s:asm_mode = s:asm_mode ? 0 : 1
  call s:ClearCursorSign()
  call TermDebugSendMICommand('-stack-info-frame', function('s:PlaceCursorSign'))
endfunc
" }}}

""""""""""""""""""""""""""""""""Sugar"""""""""""""""""""""""""""""""""""""""""{{{
func TermDebugBrToQf()
  let items = map(items(s:breakpoints), {_, item -> {
        \ "text": "Breakpoint " . item[0],
        \ "filename": item[1]['fullname'],
        \ "lnum": item[1]['lnum']
        \ }})
  if empty(items)
    echo "No breakpoints"
  else
    call setqflist([], ' ', {"title": "Breakpoints", "items": items})
    copen
  endif
endfunc

func TermDebugQfToBr()
  if !TermDebugIsStopped()
    echo "Cannot set breakpoints. Program is running."
    return
  endif
  for item in getqflist()
    let fname = fnamemodify(bufname(item['bufnr']), ":p")
    let lnum = item['lnum']
    let loc = fname . ":" . lnum
    call TermDebugSendMICommand("-break-insert " . loc)
  endfor
  cclose
endfunc

func TermDebugForceCommand(cmd)
  if TermDebugIsStopped()
    call TermDebugSendCommand(cmd)
  else
    let Cb = function('s:HandleInterrupt', [a:cmd])
    call TermDebugSendMICommand("-exec-interrupt --all", Cb)
  endif
endfunc

func TermDebugPrintMICommand(cmd)
  call TermDebugSendMICommand(a:cmd, {dict -> nvim_echo([[string(dict), 'Normal']], 1, #{})})
endfunc

func TermDebugEvaluate(what)
  let cmd = printf('-data-evaluate-expression "%s"', a:what)
  let Cb = function('s:HandleEvaluate', [win_getid()])
  call TermDebugSendMICommand(cmd, Cb)
endfunc

func TermDebugGoUp(regex)
  let Cb = function('s:HandleFrame', [a:regex])
  call TermDebugSendMICommand('-stack-list-frames', Cb)
endfunc

func TermDebugBacktrace()
  call TermDebugSendMICommand('-stack-list-frames', function('s:HandleBacktrace'))
endfunc

func TermDebugThreadInfo()
  call TermDebugSendMICommand('-thread-list-ids', function('s:HandleThreadList'))
endfunc
"}}}

""""""""""""""""""""""""""""""""Launching GDB"""""""""""""""""""""""""""""""""{{{
func TermDebugStart(...)
  if TermDebugIsOpen()
    echo 'Terminal debugger already running, cannot run two'
    return
  endif
  if !executable(g:termdebugger)
    echo 'Cannot execute debugger program "' .. g:termdebugger .. '"'
    return
  endif

  if exists('#User#TermDebugStartPre')
    doauto <nomodeline> User TermDebugStartPre
  endif

  " Remove all prior variables
  for varname in keys(s:)
    exe "silent! unlet s:" . varname
  endfor

  " Names for created buffers
  const s:capture_bufname = "Gdb capture"
  const s:asm_bufname = "Gdb disas"
  const s:prompt_bufname = "Gdb terminal"
  " Set defaults for required variables
  let s:breakpoints = #{}
  let s:callbacks = #{}
  let s:command_hist = []
  let s:pcbuf = -1
  let s:pid = 0
  let s:stopped = 1
  let s:asm_mode = 0
  let s:sourcewin = win_getid()
  let s:comm_buf = ""
  let s:stream_buf = ""
  let s:token_counter = 1
  if a:0 > 0
    let s:host = a:1
  endif

  call s:CreateSpecialBuffers()

  augroup TermDebug
    autocmd! BufRead * call s:BufRead()
  augroup END

  call s:LaunchGdb()
endfunc

func s:LaunchGdb()
  let gdb_cmd = g:termdebugger
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  let gdb_cmd .= ' -quiet'
  " Communicate with GDB in the background via MI interface
  let gdb_cmd .= ' --interpreter=mi'
  " Disable pagination, it causes everything to stop at the gdb
  let gdb_cmd .= ' -iex "set pagination off"'
  " Launch GDB through ssh
  if exists("s:host")
    let gdb_cmd = ['ssh', '-t', '-o', 'ConnectTimeout 1', s:host, gdb_cmd]
  endif

  let s:gdbwin = win_getid(winnr())
  let s:gdb_job_id = jobstart(gdb_cmd, {
        \ 'on_stdout': function('s:CommJoin'),
        \ 'on_exit': function('s:EndTermDebug'),
        \ 'pty': v:true
        \ })
  if s:gdb_job_id == 0
    echo 'Invalid argument (or job table is full) while opening gdb terminal window'
    return
  elseif s:gdb_job_id == -1
    echo 'Failed to open the gdb terminal window'
    return
  endif

  " Open the prompt window
  exe "above sp " . s:prompt_bufname
  call prompt_setprompt(bufnr(), '(gdb) ')
  call prompt_setcallback(bufnr(), function('s:PromptOutput'))
  call prompt_setinterrupt(bufnr(), function('s:PromptInterrupt'))
  augroup TermDebug
    autocmd! BufModifiedSet <buffer> noautocmd setlocal nomodified
  augroup END
  inoremap <buffer> <C-d> <cmd>call TermDebugQuit()<CR>
  inoremap <buffer> <C-w> <cmd>call <SID>DeleteWord()<CR>
  inoremap <buffer> <Up> <cmd>call <SID>ScrollHistory("-1")<CR>
  inoremap <buffer> <Down> <cmd>call <SID>ScrollHistory("+1")<CR>
  inoremap <buffer> <Tab> <cmd>call <SID>ScrollCompletion("+1")<CR>
  inoremap <buffer> <S-Tab> <cmd>call <SID>ScrollCompletion("-1")<CR>
  inoremap <buffer> <CR> <cmd>call <SID>EnterMap()<CR>
  startinsert
endfunc

func s:CreateSpecialBuffers()
  let bufnames = [s:capture_bufname, s:asm_bufname, s:prompt_bufname]
  for bufname in bufnames
    let nr = bufnr(bufname)
    if nr > 0
      exe "bwipe! " . nr
    endif
    let nr = bufadd(bufname)
    call setbufvar(nr, "&buftype", "nofile")
    call setbufvar(nr, "&swapfile", 0)
    call setbufvar(nr, "&buflisted", 1)
    call setbufvar(nr, "&wrap", 0)
    call setbufvar(nr, "&modifiable", 1)
    call bufload(nr)
  endfor
  
  " Options for asm window
  let nr = bufnr(s:asm_bufname)
  call setbufvar(nr, '&ft', 'asm')
  " Options for prompt
  let nr = bufnr(s:prompt_bufname)
  call setbufvar(nr, '&buftype', 'prompt')
  call setbufvar(nr, '&ft', 'gdb')
endfunc

func s:CommJoin(job_id, msgs, event)
  let s:comm_buf .= join(a:msgs, '')
  let commands = split(s:comm_buf, "\r", 1)
  if len(commands) > 1
    for cmd in commands[:-2]
      call s:CommOutput(cmd)
    endfor
    let s:comm_buf = commands[-1]
  endif
endfunc

func s:CommOutput(msg)
  let bnr = bufnr(s:capture_bufname)
  if bnr > 0
    let newline = substitute(a:msg, "[^[:print:]]", "", "g")
    call appendbufline(bnr, "$", newline)
  endif
  call s:RecordHandler(a:msg)
endfunc

func s:PromptOutput(command)
  if !TermDebugIsStopped()
    return
  endif

  if empty(a:command)
    " Rerun last command
    if !empty(s:command_hist)
      let cmd = s:command_hist[-1]
    else
      " No command to rerun, do nothing
      return
    endif
  else
    let cmd = a:command
    call add(s:command_hist, cmd)
  endif
  let msg = printf('-interpreter-exec console "%s"', cmd)
  call TermDebugSendMICommand(msg, function('s:Ignore'))
endfunc

func s:PromptInterrupt()
  " Cancel partially written command
  call s:SetCommandLine("", 0)
  " Send interrupt to GDB
  let interrupt = 2
  if !exists('s:host')
    let pid = jobpid(s:gdb_job_id)
    call v:lua.vim.loop.kill(pid, interrupt)
  else
    let progname = fnamemodify(g:termdebugger, ':t')
    let kill = printf("pkill -%d %s", interrupt, progname)
    call system(["ssh", a:host, kill])
  endif
endfunc

func s:DeleteWord()
  let [cmd_pre, cmd_post] = s:GetCommandLine(2)
  let cmd_pre = substitute(cmd_pre, '\S*\s*$', '', '')
  call s:SetCommandLine(cmd_pre . cmd_post, len(cmd_pre))
endfunc

func s:ScrollCompletion(expr)
  if s:IsOpenPreview()
    call s:ScrollPreview(a:expr)
  else
    call s:OpenCompletion()
  endif
endfunc

func s:ScrollHistory(expr)
  if s:IsOpenPreview()
    call s:ScrollPreview(a:expr)
  elseif len(s:command_hist) > 0
    call s:OpenPreview("History", s:command_hist)
    call s:ScrollPreview("$")
    call s:ClosePreviewOn('CursorMovedI', 'InsertLeave')
  endif
endfunc

func s:EnterMap()
  let nr = bufnr(s:prompt_bufname)
  if s:IsOpenPreview()
    let cmd = s:AcceptPreview()
    call s:SetCommandLine(cmd, len(cmd))
  elseif TermDebugIsStopped()
    call feedkeys("\n")
  endif
endfunc

func s:OpenCompletion()
  let cmd = s:GetCommandLine()
  let Cb = function('s:HandleCompletion', [cmd])
  call TermDebugSendMICommand(printf('-complete "%s"', cmd), Cb)
endfunc

func s:GetCommandLine(...)
  let nr = bufnr(s:prompt_bufname)
  let line = getbufline(nr, '$')[0]
  let off = len(prompt_getprompt(nr))
  let parts = get(a:000, 0, 1)
  if parts == 1
    return line[off:]
  else
    let col = getcurpos()[2] - 1
    return [line[off:col-1], line[col:]]
  endif
endfunc

func s:SetCommandLine(cmd, col)
  let nr = bufnr(s:prompt_bufname)
  let prefix = prompt_getprompt(nr)
  let line = prefix . a:cmd
  let col = len(prefix) + a:col
  call setbufline(nr, '$', line)
  let view = winsaveview()
  if view['col'] != col
    let view['col'] = col
    call winrestview(view)
  endif
endfunc
" }}}

""""""""""""""""""""""""""""""""Record handlers"""""""""""""""""""""""""""""""{{{
func s:RecordHandler(msg)
  " Stream record
  if stridx("~@&", a:msg[0]) >= 0
    return s:HandleStream(a:msg)
  endif

  let dict = s:GetResultRecord(a:msg)

  " Async record
  let async = s:GetAsyncClass(a:msg)
  if async == "stopped" || async == "running" || async == "thread-selected"
    return s:HandleCursor(async, dict)
  elseif async == "thread-group-started"
    return s:HandleProgramRun(dict)
  elseif async == 'breakpoint-created' || async == 'breakpoint-modified'
    return s:HandleNewBreakpoint(dict)
  elseif async == 'breakpoint-deleted'
    return s:HandleBreakpointDelete(dict)
  endif

  " Result record
  let result = s:GetResultClass(a:msg)
  if result == 'done'
    let token = s:GetResultToken(a:msg)
    if str2nr(token) > 0 && has_key(s:callbacks, token)
      let Callback = s:callbacks[token]
      return Callback(dict)
    else
      echom "Unhandled record!"
    endif
  elseif result == 'error'
    return s:HandleError(dict)
  endif
endfunc

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(class, dict)
  if a:class == 'stopped'
    let s:stopped = 1
  elseif a:class == 'running'
    let s:stopped = 0
  endif

  call s:ClearCursorSign()
  if a:class == 'running'
    return
  endif
  call s:PlaceCursorSign(a:dict)
endfunc

func s:PlaceCursorSign(dict)
  if s:asm_mode
    call s:PlaceAsmCursor(a:dict)
  else
    call s:PlaceSourceCursor(a:dict)
  endif
endfunc

func s:PlaceSourceCursor(dict)
  let ns = nvim_create_namespace('TermDebugPC')
  let filename = s:Get(a:dict, 'frame', 'fullname')
  let lnum = s:Get(a:dict, 'frame', 'line')
  if filereadable(filename) && str2nr(lnum) > 0
    let origw = win_getid()
    call TermDebugGoToSource()
    if expand("%:p") != filename
      exe "e " . fnameescape(filename)
    endif
    exe lnum
    normal z.
    call nvim_buf_set_extmark(0, ns, lnum - 1, 0, #{line_hl_group: 'debugPC'})
    let s:pcbuf = bufnr()
    call win_gotoid(origw)
  endif
endfunc

func s:PlaceAsmCursor(dict)
  let addr = s:Get(a:dict, 'frame', 'addr')
  if !s:SelectAsmAddr(addr)
    " Reload disassembly
    let cmd = printf("-data-disassemble -a %s 0", addr)
    let Cb = function('s:HandleDisassemble', [addr])
    call TermDebugSendMICommand(cmd, Cb)
  endif
endfunc

func s:SelectAsmAddr(addr)
  let origw = win_getid()
  call TermDebugGoToSource()
  if bufname() != s:asm_bufname
    exe "e " . s:asm_bufname
  endif

  let lnum = search('^' . a:addr)
  if lnum > 0
    normal z.
    let ns = nvim_create_namespace('TermDebugPC')
    call nvim_buf_set_extmark(0, ns, lnum - 1, 0, #{line_hl_group: 'debugPC'})
    let s:pcbuf = bufnr()
    call win_gotoid(origw)
  endif

  call win_gotoid(origw)
  return lnum > 0
endfunc

func s:ClearCursorSign()
  let ns = nvim_create_namespace('TermDebugPC')
  if bufexists(s:pcbuf)
    call nvim_buf_clear_namespace(s:pcbuf, ns, 0, -1)
  endif
endfunc

" Handle the debugged program starting to run.
" Will store the process ID in s:pid
func s:HandleProgramRun(dict)
  if has_key(a:dict, 'pid')
    let s:pid = a:dict['pid']
    if exists('#User#TermDebugRunPost')
      doauto <nomodeline> User TermDebugRunPost
    endif
  endif
endfunc

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(dict)
  let bkpt = a:dict['bkpt']
  if has_key(bkpt, 'pending') && has_key(bkpt, 'number')
    echomsg 'Breakpoint ' . bkpt['number'] . ' (' . bkpt['pending']  . ') pending.'
    return
  endif

  let id = bkpt['number']
  call s:ClearBreakpointSign(id)

  if has_key(bkpt, 'fullname')
    let s:breakpoints[id] = #{
          \ fullname: bkpt['fullname'],
          \ lnum: bkpt['line'],
          \ enabled: bkpt['enabled'] == 'y'
          \ }
    call s:PlaceBreakpointSign(id)
  elseif has_key(bkpt, 'addr') && bkpt['addr'] == '<MULTIPLE>'
    for location in bkpt['locations']
      let id = location['number']
      call s:ClearBreakpointSign(id)
      let s:breakpoints[id] = #{
            \ fullname: location['fullname'],
            \ lnum: location['line'],
            \ enabled: location['enabled'] == 'y' && bkpt['enabled'] == 'y'
            \ }
      call s:PlaceBreakpointSign(id)
    endfor
  endif
endfunc

" Handle deleting a breakpoint
" Will remove the sign that shows the breakpoint
func s:HandleBreakpointDelete(dict)
  let id = a:dict['id']
  call s:ClearBreakpointSign(id)
endfunc

func s:ClearBreakpointSign(id)
  if has_key(s:breakpoints, a:id)
    let breakpoint = s:breakpoints[a:id]
    if has_key(breakpoint, "extmark")
      let extmark = breakpoint['extmark']
      let bufnr = bufnr(breakpoint['fullname'])
      if bufnr > 0
        let ns = nvim_create_namespace('TermDebugBr')
        call nvim_buf_del_extmark(bufnr, ns, extmark)
      endif
    endif
  endif
endfunc

func s:PlaceBreakpointSign(id)
  if has_key(s:breakpoints, a:id)
    let breakpoint = s:breakpoints[a:id]
    let bufnr = bufnr(breakpoint['fullname'])
    let placed = has_key(breakpoint, 'extmark')
    if bufnr > 0 && !placed
      call bufload(bufnr)
      let ns = nvim_create_namespace('TermDebugBr')
      let text = len(a:id) <= 2 ? a:id : "*"
      let hl_group = breakpoint['enabled'] ? 'debugBreakpoint' : 'debugBreakpointDisabled'
      let opts = #{sign_text: text, sign_hl_group: hl_group}
      let extmark = nvim_buf_set_extmark(bufnr, ns, breakpoint['lnum'] - 1, 0, opts)
      let s:breakpoints[a:id]['extmark'] = extmark
    endif
  endif
endfunc
" }}}

""""""""""""""""""""""""""""""""Eval""""""""""""""""""""""""""""""""""""""""""{{{
func s:GetResultRecord(msg)
  let idx = stridx(a:msg, ',')
  if idx < 0
    return #{}
  endif
  let [head, rest] = s:EvalResult(a:msg[idx+1:])
  let dict = head
  while rest[0] == ','
    let [head, rest] = s:EvalResult(rest[1:])
    let k = keys(head)[0]
    let v = values(head)[0]
    let dict[k] = v
  endwhile
  return dict
endfunc

func s:EvalResult(msg)
  let eq = stridx(a:msg, '=')
  let varname = a:msg[:eq-1]
  let [value, rest] = s:EvalValue(a:msg[eq+1:])
  let result = {varname: value}
  return [result, rest]
endfunc

func s:EvalValue(msg)
  if a:msg[0] == '"'
    return s:EvalString(a:msg)
  elseif a:msg[1] == '"' || a:msg[1] == '{' || a:msg[1] == '['
    " No keys, just values
    return s:EvalList(a:msg)
  else
    " Key=Value pairs
    return s:EvalTuple(a:msg)
  endif
endfunc

func s:EvalString(msg)
  let idx = 1
  let len = len(a:msg)
  while idx < len
    if a:msg[idx] == '\'
      let idx += 1
    elseif a:msg[idx] == '"'
      break
    endif
    let idx += 1
  endwhile
  return [eval(a:msg[:idx]), a:msg[idx+1:]]
endfunc

func s:EvalTuple(msg)
  if a:msg[1] == ']' || a:msg[1] == '}'
    let empty = []
    let rest = a:msg[2:]
    return [empty, rest]
  endif

  let [head, rest] = s:EvalResult(a:msg[1:])
  let keys = keys(head)
  let values = values(head)
  while rest[0] == ','
    let [head, rest] = s:EvalResult(rest[1:])
    call extend(keys, keys(head))
    call extend(values, values(head))
  endwhile
  let rest = rest[1:]

  " Patch GDB's weird idea of a tuple
  let equal_keys = len(keys) > 1 && keys[0] == keys[1]
  if equal_keys
    return [values, rest]
  endif
  let dict = s:Zip(keys, values)
  return [dict, rest]
endfunc

func s:EvalList(msg)
  if a:msg[1] == ']' || a:msg[1] == '}'
    let empty = []
    let rest = a:msg[2:]
    return [empty, rest]
  endif

  let [head, rest] = s:EvalValue(a:msg[1:])
  let list = [head]
  while rest[0] == ','
    let [head, rest] = s:EvalValue(rest[1:])
    call add(list, head)
  endwhile
  let rest = rest[1:]
  return [list, rest]
endfunc

func s:Zip(keys, values)
  let dict = #{}
  for i in range(len(a:keys))
    let dict[a:keys[i]] = a:values[i]
  endfor
  return dict
endfunc

func s:Get(dict, ...)
  let result = a:dict
  for key in a:000
    if !has_key(result, key)
      return ""
    endif
    let result = result[key]
  endfor
  return result
endfunc

func s:GetListWithKeys(dict, key)
  let res = a:dict[a:key]
  if type(res) == v:t_dict
    return values(res)
  else
    return res
  endif
endfunc

func s:MatchGetCapture(string, pat)
  let res = matchlist(a:string, a:pat)
  if empty(res)
    return ""
  endif
  return res[1]
endfunc

func s:GetAsyncClass(msg)
  return s:MatchGetCapture(a:msg, '^[0-9]*[*+=]\([^,]*\),\?')
endfunc

func s:GetResultToken(msg)
  return s:MatchGetCapture(a:msg, '^\([0-9]\+\)\^')
endfunc

func s:GetResultClass(msg)
  return s:MatchGetCapture(a:msg, '^[0-9]*\^\([^,]*\),\?')
endfunc
"}}}

""""""""""""""""""""""""""""""""Result handles""""""""""""""""""""""""""""""""{{{
func s:HandleEvaluate(winid, dict)
  let lines = split(a:dict['value'], "\n")
  let was_win = win_getid()
  call win_gotoid(a:winid)
  call s:OpenPreview("Value", lines)
  call s:ClosePreviewOn('CursorMoved', 'WinScrolled', 'WinResized')
endfunc

func s:HandleCompletion(cmd, dict)
  let matches = a:dict['matches']
  let matches = filter(matches, "v:val != a:cmd")
  if len(matches) > 0 && (bufname() == s:prompt_bufname)
    call s:OpenPreview("Completion", matches)
    call s:ScrollPreview("1")
    call s:ClosePreviewOn('InsertLeave')
    augroup TermDebugCompletion
      autocmd! TextChangedI <buffer> call s:OpenCompletion()
    augroup END
  else
    call s:ClosePreview()
  endif
endfunc

func s:HandleInterrupt(cmd, dict)
  call chansend(s:gdb_job_id, a:cmd . "\n")
endfunc

func s:HandlePwd(dict)
  " Doesn't have a consistent name...
  let pwd = values(a:dict)[0]
  echo "Path: " . pwd
endfunc

func s:HandleDisassemble(addr, dict)
  let asm_insns = a:dict['asm_insns']

  let nr = bufnr(s:asm_bufname)
  call deletebufline(nr, 1, '$')
  if empty(asm_insns)
    call appendbufline(nr, "0", "No disassembler output")
    return
  endif

  let intro = printf("Disassembly of %s:", asm_insns[0]['func-name'])
  call appendbufline(nr, "0", intro)

  for asm_ins in asm_insns
    let address = asm_ins['address']
    let offset = asm_ins['offset']
    let inst = asm_ins['inst']
    let line = printf("%s<%d>: %s", address, offset, inst)
    call appendbufline(nr, "$", line)
  endfor
  call s:SelectAsmAddr(a:addr)
endfunc

func s:HandleStream(msg)
  if a:msg[0] != '~' && a:msg[0] != '&'
    return
  endif

  execute printf('let msg = %s', a:msg[1:])
  " Substitute tabs with spaces
  let msg = substitute(msg, "\t", "  ", "g")
  " Remove escape sequence
  let msg = substitute(msg, "\x1b\\[[0-9;]*m", "", "g")
  " Join with messages from previous stream record
  let total = split(s:stream_buf . msg, "\n", 1)
  let lines = total[:-2]
  let s:stream_buf = total[-1]

  let nr = bufnr(s:prompt_bufname)
  let pos = nvim_buf_line_count(nr) - 1
  call appendbufline(nr, pos, lines)
endfunc

func s:HandleFrame(regex, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    let fullname = s:Get(frame, 'fullname')
    if filereadable(fullname) && match(fullname, a:regex) >= 0
      let cmd = "-stack-select-frame " . frame['level']
      call TermDebugSendMICommand(cmd, function('s:Ignore'))
      return
    endif
  endfor
endfunc

func s:HandleBacktrace(dict)
  let list = []
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    let fullname = s:Get(frame, 'fullname')
    if filereadable(fullname)
      call add(list, #{text: frame['func'], filename: fullname, lnum: frame['line']})
    endif
  endfor
  call TermDebugGoToSource()
  call setqflist([], ' ', #{title: "Backtrace", items: list})
  copen
endfunc

func s:HandleThreadList(dict)
  let ids = s:GetListWithKeys(a:dict, 'thread-ids')
  let s:pending_threads = len(ids)
  let s:collected = #{}
  for id in ids
    let Cb = function('s:CollectThreads', [id])
    call TermDebugSendMICommand('-stack-list-frames --thread ' . id, Cb)
  endfor
endfunc

func s:CollectThreads(id, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  let s:collected[a:id] = frames
  if len(s:collected) != s:pending_threads
    " Wait for all threads
    return
  endif

  let list = []
  for key in keys(s:collected)
    let thread_frames = 0
    for frame in s:collected[key]
      let fullname = s:Get(frame, 'fullname')
      if filereadable(fullname)
        let text = printf('Thread %d at frame %d', key, frame['level'])
        call add(list, #{text: text, filename: frame['fullname'], lnum: frame['line']})
        let thread_frames += 1
        if thread_frames > 3
          break
        endif
      endif
    endfor
  endfor

  unlet s:collected
  unlet s:pending_threads
  call setqflist([], ' ', #{title: 'Threads', items: list})
  copen
endfunc

func s:HandleError(dict)
  let msg = a:dict['msg']
  " Do it this way to print the new lines
  exe "echo " . string(msg)
endfunc
"}}}

""""""""""""""""""""""""""""""""Preview window""""""""""""""""""""""""""""""""{{{
func s:TraverseLayout(stack)
  if a:stack[0] == 'leaf'
    if a:stack[1] == win_getid()
      return [1, winline()]
    else
      return [0, nvim_win_get_height(a:stack[1])]
    endif
  endif
  let accum = 0
  for tail in a:stack[1]
    let result = s:TraverseLayout(tail)
    if result[0]
      return [1, accum + result[1]]
    elseif a:stack[0] == 'col'
      let accum += result[1]
    endif
  endfor
  return [0, accum]
endfunc

func s:WinAbsoluteLine()
  let tree = winlayout(tabpagenr())
  let result = s:TraverseLayout(tree)
  return result[0] ? result[1] : 0
endfunc

func s:OpenPreview(title, lines)
  const max_width = 60
  const max_height = 10

  let sizes = map(copy(a:lines), "len(v:val)")
  call add(sizes, len(a:title))
  let width = min([max(sizes), max_width]) + 1
  let height = min([len(a:lines), max_height])

  " Will height lines + title fit in the OS window?
  if s:WinAbsoluteLine() > height + 2
    let row = -height - 2
    let title_pos = "left"
  else
    let row = 1
    let title_pos = "right"
  endif

  let opts = #{
        \ relative: "cursor",
        \ row: row,
        \ col: 0,
        \ width: width,
        \ height: height,
        \ focusable: 0,
        \ style: "minimal",
        \ border: "rounded",
        \ title: a:title,
        \ title_pos: title_pos
        \ }
  if exists("s:preview_win")
    let nr = nvim_win_get_buf(s:preview_win)
    call nvim_win_set_config(s:preview_win, opts)
  else
    let nr = nvim_create_buf(0, 0)
    call nvim_buf_set_option(nr, "buftype", "nofile")
    let opts['noautocmd'] = 1
    let s:preview_win = nvim_open_win(nr, v:false, opts)
  endif

  call nvim_win_set_option(s:preview_win, 'wrap', v:false)
  call nvim_win_set_option(s:preview_win, 'cursorline', v:true)
  call nvim_win_set_option(s:preview_win, 'scrolloff', 2)
  if line('$', s:preview_win) > 1
    call deletebufline(nr, 1, '$')
  endif
  call setbufline(nr, 1, a:lines)
  return s:preview_win
endfunc

func s:IsOpenPreview()
  if !exists('s:preview_win')
    return v:false
  endif
  let config = nvim_win_get_config(s:preview_win)
  return has_key(config, 'title')
endfunc

func s:ScrollPreview(expr)
  let lines = line('$', s:preview_win)
  let curr = line('.', s:preview_win)
  if a:expr == '1'
    call nvim_win_set_cursor(s:preview_win, [1, 0])
  elseif a:expr == '$'
    call nvim_win_set_cursor(s:preview_win, [lines, 0])
  elseif a:expr == '-1' && curr > 1
    call nvim_win_set_cursor(s:preview_win, [curr - 1, 0])
  elseif a:expr == '+1' && curr < lines
    call nvim_win_set_cursor(s:preview_win, [curr + 1, 0])
  endif
endfunc

func s:AcceptPreview()
  let nr = winbufnr(s:preview_win)
  let pos = line('.', s:preview_win)
  let res = getbufline(nr, pos)[0]
  call s:ClosePreview()
  return res
endfunc

func s:ClosePreviewOn(...)
  augroup TermDebug
    for event in a:000
      exe printf("autocmd! %s * ++once call s:ClosePreview()", event)
    endfor
  augroup END
endfunc

func s:ClosePreview()
  if exists("s:preview_win")
    let nr = winbufnr(s:preview_win)
    call nvim_win_close(s:preview_win, 1)
    call nvim_buf_delete(nr, #{force: 1})
    unlet s:preview_win
  endif
  let nr = bufnr(s:prompt_bufname)
  if exists('#TermDebugCompletion')
    au! TermDebugCompletion
  endif
endfunc
"}}}

""""""""""""""""""""""""""""""""Ending the session""""""""""""""""""""""""""""{{{
func s:EndTermDebug(job_id, exit_code, event)
  if exists('#User#TermDebugStopPre')
    doauto <nomodeline> User TermDebugStopPre
  endif

  silent! autocmd! TermDebug
  silent! autocmd! TermDebugCompletion

  " Clear signs
  call s:ClearCursorSign()
  for id in keys(s:breakpoints)
    call s:ClearBreakpointSign(id)
  endfor

  " Clear buffers
  let bufnames = [s:capture_bufname, s:asm_bufname, s:prompt_bufname]
  for bufname in bufnames
    let nr = bufnr(bufname)
    if nr >= 0
      exe 'bwipe!' . nr
    endif
  endfor

  if exists('#User#TermDebugStopPost')
    doauto <nomodeline> User TermDebugStopPost
  endif
endfunc

" Handle a BufRead autocommand event: place breakpoint signs.
func s:BufRead()
  let fullname = expand('<afile>:p')
  for [key, breakpoint] in items(s:breakpoints)
    if breakpoint['fullname'] == fullname
      call s:PlaceBreakpointSign(key)
    endif
  endfor
endfunc

func s:Ignore(...)
endfunc
" }}}
