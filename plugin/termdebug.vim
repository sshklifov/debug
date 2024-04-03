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

""""""""""""""""""""""""""""""""""""Go to"""""""""""""""""""""""""""""""""""""{{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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

"""""""""""""""""""""""""""""""Global functions"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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

func TermDebugGetPid()
  if !TermDebugIsOpen()
    return 0
  endif
  return s:pid
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

func TermDebugForceCommand(cmd)
  let Cb = function('s:HandleInterrupt', [a:cmd])
  call TermDebugSendMICommand(s:interrupt_token, "-exec-interrupt --all", Cb)
endfunc

func TermDebugEvaluate(what)
  let cmd = printf('-data-evaluate-expression "%s"', a:what)
  call TermDebugSendMICommand(s:eval_token, cmd, function('s:HandleEvaluate'))
endfunc

func TermDebugToggleAsm()
  let s:asm_mode = s:asm_mode ? 0 : 1
  call s:ClearCursorSign()
  call TermDebugSendMICommand(s:frame_info_token, '-stack-info-frame', function('s:PlaceCursorSign'))
endfunc

func TermDebugGoUp()
  call TermDebugSendMICommand(s:frame_list_token, '-stack-list-frames', function('s:HandleFrame'))
endfunc

func TermDebugBacktrace()
  call TermDebugSendMICommand(s:backtrace_token, '-stack-list-frames', function('s:HandleBacktrace'))
endfunc

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
" }}}

""""""""""""""""""""""""""""""""Launching GDB"""""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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
  " Sync tokens
  const s:eval_token = 1
  const s:disas_token = 2
  const s:frame_info_token = 3
  const s:frame_list_token = 4
  const s:interrupt_token = 5
  const s:backtrace_token = 6
  " Set defaults for required variables
  let s:breakpoints = #{}
  let s:callbacks = #{}
  let s:pcbuf = -1
  let s:pid = 0
  let s:stopped = 1
  let s:asm_mode = 0
  let s:sourcewin = win_getid()
  let s:comm_buf = ""
  if a:0 > 0
    let s:host = a:1
  endif

  call s:CreateSpecialBuffers()

  augroup TermDebug
    au BufRead * call s:BufRead()
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
  for msg in filter(a:msgs, "!empty(v:val)")
    let s:comm_buf .= msg
    if s:comm_buf[-1:] == "\r"
      call s:CommOutput(s:comm_buf[0:-2])
      let s:comm_buf = ""
    endif
  endfor
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
  " Async record
  let async = s:GetAsyncClass(a:msg)
  if async == "stopped" || async == "running" || async == "thread-selected"
    return s:HandleCursor(a:msg)
  elseif async == "thread-group-started"
    return s:HandleProgramRun(a:msg)
  elseif async == 'breakpoint-created' || async == 'breakpoint-modified'
    return s:HandleNewBreakpoint(a:msg)
  elseif async == 'breakpoint-deleted'
    return s:HandleBreakpointDelete(a:msg)
  endif

  " Stream record
  if stridx("~@&", a:msg[0]) >= 0
    return s:HandleStream(a:msg)
  endif

  " Result record
  let token = s:GetResultToken(a:msg)
  if str2nr(token) > 0
    let Callback = s:callbacks[token][0]
    call remove(s:callbacks[token], 0)
  endif
  let result = s:GetResultClass(a:msg)
  if result == 'done' && exists('Callback')
    return Callback(a:msg)
  elseif result == 'error'
    return s:HandleError(a:msg)
  endif
endfunc

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(msg)
  let class = s:GetAsyncClass(a:msg)
  if class == 'stopped'
    let s:stopped = 1
  elseif class == 'running'
    let s:stopped = 0
  endif

  call s:ClearCursorSign()
  if class == 'running'
    return
  endif
  call s:PlaceCursorSign(a:msg)
endfunc

func s:PlaceCursorSign(msg)
  if s:asm_mode
    call s:PlaceAsmCursor(a:msg)
  else
    call s:PlaceSourceCursor(a:msg)
  endif
endfunc

func s:PlaceSourceCursor(msg)
  let ns = nvim_create_namespace('TermDebugPC')
  let filename = s:GetRecordVar(a:msg, 'fullname')
  let lnum = s:GetRecordVar(a:msg, 'line')
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

func s:PlaceAsmCursor(msg)
  let addr = s:GetRecordVar(a:msg, 'addr')
  if !s:SelectAsmAddr(addr)
    " Reload disassembly
    let cmd = printf("-data-disassemble -a %s 0", addr)
    let Cb = function('s:HandleDisassemble', [addr])
    call TermDebugSendMICommand(s:disas_token, cmd, Cb)
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
func s:HandleProgramRun(msg)
  let nr = str2nr(s:GetRecordVar(a:msg, 'pid'))
  if nr > 0
    let s:pid = nr
    if exists('#User#TermDebugRunPost')
      doauto <nomodeline> User TermDebugRunPost
    endif
  endif
endfunc

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(msg)
  " Handle script={cmd1, cmd2, ...} dictionaries
  let msg = substitute(a:msg, ',\?script={.\{-}}', '', 'g')
  let bkpt = s:GetRecordDict(msg, 'bkpt')

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
func s:HandleBreakpointDelete(msg)
  let id = s:GetRecordVar(a:msg, 'id')
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

"""""""""""""""""""""""""""""""Utility handlers"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
func s:HandleEvaluate(msg)
  let value = s:GetRecordVar(a:msg, 'value')
  exe printf('let lines = split("%s", "\n")', value)
  " let lines = split(value, '\\n')
  call v:lua.vim.lsp.util.open_floating_preview(lines)
endfunc

func s:HandleFrame(msg)
  let frames = s:GetRecordStack(a:msg)
  for frame in frames
    if has_key(frame, 'fullname') && filereadable(frame['fullname'])
      call TermDebugSendCommand("frame " . frame['level'])
      return
    endif
  endfor
endfunc

func s:HandleBacktrace(msg)
  let list = []
  let frames = s:GetRecordStack(a:msg)
  for frame in frames
    if has_key(frame, 'fullname') && filereadable(frame['fullname'])
      call add(list, #{text: frame['level'], filename: frame['fullname'], lnum: frame['line']})
    endif
  endfor
  call TermDebugGoToSource()
  call setqflist([], ' ', #{title: "Backtrace", items: list})
  copen
endfunc

func s:GetRecordStack(msg)
  let msg = substitute(a:msg, ',frame=', ',', 'g')
  let msg = substitute(msg, '[frame=', '[', 'g')
  return s:GetRecordDict(msg, 'stack')
endfunc

func s:HandleInterrupt(cmd, msg)
  call chansend(s:gdb_job_id, a:cmd . "\n")
endfunc

func s:HandleDisassemble(addr, msg)
  let asm_insns = s:GetRecordDict(a:msg, 'asm_insns')

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
    let inst = substitute(asm_ins['inst'], '\t', ' ', 'g')

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

func s:HandleError(msg)
  let err = s:GetRecordVar(a:msg, 'msg')
  echom err
endfunc

func TermDebugSendMICommand(token, cmd, Callback)
  if !has_key(s:callbacks, a:token)
    let s:callbacks[a:token] = []
  endif
  call add(s:callbacks[a:token], a:Callback)

  let cmd = printf("%d%s", a:token, a:cmd)
  call chansend(s:comm_job_id, cmd . "\n")
endfunc

func s:MatchGetCapture(string, pat)
  let res = matchlist(a:string, a:pat)
  if empty(res)
    return ""
  endif
  return res[1]
endfunc

func s:GetRecordVar(msg, var_name)
  let regex = printf('%s="\([^"]*\)"', a:var_name)
  let msg = substitute(a:msg, '\\"', "'", "g")
  return s:MatchGetCapture(msg, regex)
endfunc

func s:GetRecordDict(msg, var_name)
  let start = matchend(a:msg, a:var_name . '=')
  let msg = a:msg[start:]
  let msg = substitute(msg, '=', ':', 'g')
  let msg = substitute(msg, '{', '#{', 'g')
  return eval(msg)
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

""""""""""""""""""""""""""""""Ending the session""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
func s:EndTermDebug(job_id, exit_code, event)
  if exists('#User#TermDebugStopPre')
    doauto <nomodeline> User TermDebugStopPre
  endif

  silent! au! TermDebug

  " Clear signs
  call s:ClearCursorSign()
  for id in keys(s:breakpoints)
    call s:ClearBreakpointSign(id)
  endfor

  " Clear buffers
  let bufnames = [s:capture_bufname, s:gdb_bufname, s:asm_bufname, s:log_bufname]
  for bufname in bufnames
    let capture_buf = bufnr(s:capture_bufname)
    if capture_buf >= 0
      exe 'bwipe!' . capture_buf
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
