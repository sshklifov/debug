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

func TermDebugCaptureNr()
  return bufnr(s:capture_bufname)
endfunc

func TermDebugLogNr()
  return bufnr(s:log_bufname)
endfunc

func TermDebugGoToSource()
  if !win_gotoid(s:sourcewin)
    below new
    let s:sourcewin = win_getid(winnr())
  endif
endfunc

func TermDebugGoToGdb()
  let nr = bufnr(s:gdb_bufname)
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
  call TermDebugSendMICommand('-gdb-exit', luaeval("function() end"))
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
  call chansend(s:comm_job_id, cmd . "\n")
endfunc

func TermDebugSendCommand(cmd)
  if !TermDebugIsStopped()
    echo "Cannot send command. Program is running."
    return
  endif
  call chansend(s:gdb_job_id, a:cmd . "\n")
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
  for item in getqflist()
    let fname = fnamemodify(bufname(item['bufnr']), ":p")
    let lnum = item['lnum']
    call TermDebugSendCommand("break " . fname . ":" . lnum)
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
  const s:gdb_bufname = "Gdb terminal"
  const s:capture_bufname = "Gdb capture"
  const s:asm_bufname = "Gdb disas"
  const s:log_bufname = "Gdb log"
  " Set defaults for required variables
  let s:breakpoints = #{}
  let s:callbacks = #{}
  let s:pcbuf = -1
  let s:pid = 0
  let s:stopped = 1
  let s:asm_mode = 0
  let s:sourcewin = win_getid()
  let s:comm_buf = ""
  let s:token_counter = 1
  if a:0 > 0
    let s:host = a:1
  endif

  call s:CreateSpecialBuffers()

  augroup TermDebug
    autocmd! BufRead * call s:BufRead()
  augroup END

  call s:LaunchComm()
endfunc

func s:LaunchComm()
  " Create a hidden terminal window to communicate with gdb
  let comm_cmd = &shell
  if exists("s:host")
    let comm_cmd = ['ssh', '-t', '-o', 'ConnectTimeout 1', s:host]
  endif
  let s:comm_job_id = jobstart(comm_cmd, #{on_stdout: function('s:CommJoin'), pty: v:true})
  if s:comm_job_id == 0
    echo 'Invalid argument (or job table is full) while opening communication terminal window'
    return
  elseif s:comm_job_id == -1
    echo 'Failed to open the communication terminal window'
    return
  endif
  call chansend(s:comm_job_id, "tty\r")
  call chansend(s:comm_job_id, "tail -f /dev/null\r")
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

  if !exists("s:comm_tty")
    " Capture device name of communication terminal.
    " The first command executed in the terminal will be "tty" and the output will be parsed here.
    let tty = s:MatchGetCapture(a:msg, '\(' . '/dev/pts/[0-9]\+' . '\)')
    if !empty(tty)
      let s:comm_tty = tty
      call s:LaunchGdb()
    endif
  else
    call s:RecordHandler(a:msg)
  endif
endfunc

func s:LaunchGdb()
  let gdb_cmd = g:termdebugger
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  let gdb_cmd .= ' -quiet'
  " Disable pagination, it causes everything to stop at the gdb
  let gdb_cmd .= ' -iex "set pagination off"'
  " Interpret commands while the target is running.  This should usually only
  " be exec-interrupt, since many commands don't work properly while the
  " target is running (so execute during startup).
  let gdb_cmd .= ' -iex "set mi-async on"'
  " Command executed _after_ startup is done
  let gdb_cmd .= ' -ex "new-ui mi ' . s:comm_tty . '"'
  " Launch GDB through ssh
  if exists("s:host")
    let gdb_cmd = ['ssh', '-t', '-o', 'ConnectTimeout 1', s:host, gdb_cmd]
  endif

  execute 'new'
  let s:gdbwin = win_getid(winnr())
  let s:gdb_job_id = termopen(gdb_cmd, {
        \ 'on_stdout': function('s:GdbOutput'),
        \ 'on_exit': function('s:EndTermDebug')
        \ })
  if s:gdb_job_id == 0
    echo 'Invalid argument (or job table is full) while opening gdb terminal window'
    return
  elseif s:gdb_job_id == -1
    echo 'Failed to open the gdb terminal window'
    return
  endif

  " Rename the terminal window
  let nr = bufnr(s:gdb_bufname)
  if nr > 0
    exe "bwipe " . nr
  endif
  exe "file " . s:gdb_bufname

  set ft=gdb
  startinsert
endfunc

func s:GdbOutput(job_id, msgs, event)
  for msg in a:msgs
    if msg =~ 'New UI allocated'
      if exists('#User#TermDebugStartPost')
        doauto <nomodeline> User TermDebugStartPost
      endif
    endif
  endfor
endfunc

func s:CreateSpecialBuffers()
  let bufnames = [s:capture_bufname, s:log_bufname, s:asm_bufname]
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
      echom "Unhandled result: " . result
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
  augroup TermDebug
    autocmd! CursorMoved <buffer> ++once call s:ClosePreview()
    exe printf("autocmd! WinScrolled %d ++once call s:ClosePreview()", a:winid)
    autocmd! WinResized * ++once call s:ClosePreview()
  augroup END
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
  let nr = bufnr(s:log_bufname)
  let line = getbufline(nr, '$')[0]
  execute printf('let line .=  %s', a:msg[1:])
  let lines = split(line, "\n", 1)
  call setbufline(nr, "$", lines[0])
  call appendbufline(nr, '$', lines[1:])
endfunc

func s:HandleFrame(regex, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    let fullname = s:Get(frame, 'fullname')
    if filereadable(fullname) && match(fullname, a:regex) >= 0
      call TermDebugSendCommand("frame " . frame['level'])
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

""""""""""""""""""""""""""""""""Ending the session""""""""""""""""""""""""""""{{{
func s:EndTermDebug(job_id, exit_code, event)
  if exists('#User#TermDebugStopPre')
    doauto <nomodeline> User TermDebugStopPre
  endif

  silent! autocmd! TermDebug

  " Clear signs
  call s:ClearCursorSign()
  for id in keys(s:breakpoints)
    call s:ClearBreakpointSign(id)
  endfor

  " Clear buffers
  let bufnames = [s:capture_bufname, s:gdb_bufname, s:asm_bufname, s:log_bufname]
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
" }}}

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
    call nvim_win_set_option(s:preview_win, 'wrap', v:false)
  endif
  " call deletebufline(nr, 1, '$')
  call setbufline(nr, 1, a:lines)
  return s:preview_win
endfunc

func s:ClosePreview()
  if exists("s:preview_win")
    let nr = winbufnr(s:preview_win)
    call nvim_win_close(s:preview_win, 1)
    call nvim_buf_delete(nr, #{force: 1})
    unlet s:preview_win
  endif
endfunc
"}}}
