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
  call s:SendMICommandNoOutput('-gdb-exit')
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

function s:SendMICommandNoOutput(cmd)
  let IgnoreOutput = {_ -> {}}
  return TermDebugSendMICommand(a:cmd, IgnoreOutput)
endfunction

" Accepts either a console command or a C++ expression
func s:EscapeMIArgument(arg)
  " TODO buggy
  return "\"" .. a:arg .. "\""
endfunc

func TermDebugSendCommand(cmd)
  if !TermDebugIsStopped()
    echo "Cannot send command. Program is running."
    return
  endif
  let msg = '-interpreter-exec console ' .. s:EscapeMIArgument(a:cmd)
  call s:SendMICommandNoOutput(msg)
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

func TermDebugSetAsmMode(asm_mode)
  if s:asm_mode != a:asm_mode
    let s:asm_mode = a:asm_mode
    call s:ClearCursorSign()
    call TermDebugSendMICommand('-stack-info-frame', function('s:PlaceCursorSign'))
  endif
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
    call s:SendMICommandNoOutput("-break-insert " . loc)
  endfor
  cclose
endfunc

func TermDebugEditCommands(...)
  if a:0 > 0 
    let br = a:1
  else
    let br = max(map(keys(s:breakpoints), "str2nr(v:val)"))
  endif
  let Cb = function('s:HandleBreakpointEdit', [br])
  call TermDebugSendMICommand("-break-info " . br, Cb)
endfunc

func TermDebugFindSym(func)
  let cmd = '-symbol-info-functions --include-nondebug --max-results 20 --name ' . a:func
  call TermDebugSendMICommand(cmd, function('s:HandleSymbolInfo'))
endfunc

func TermDebugPrintMICommand(cmd)
  call TermDebugSendMICommand(a:cmd, {dict -> nvim_echo([[string(dict), 'Normal']], 1, #{})})
endfunc

func TermDebugEvaluate(what)
  let cmd = '-data-evaluate-expression ' .. s:EscapeMIArgument(a:what)
  let Cb = function('s:HandleEvaluate', [win_getid()])
  call TermDebugSendMICommand(cmd, Cb)
endfunc

func TermDebugBacktrace()
  call TermDebugSendMICommand('-stack-list-frames', function('s:HandleBacktrace'))
endfunc

func TermDebugThreadInfo(...)
  let pat = get(a:000, 0, '')
  let Cb = function('s:HandleThreadList', [pat])
  call TermDebugSendMICommand('-thread-list-ids', Cb)
endfunc
"}}}

""""""""""""""""""""""""""""""""Launching GDB"""""""""""""""""""""""""""""""""{{{
let s:command_hist = []
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
    if varname != "command_hist"
      exe "silent! unlet s:" . varname
    endif
  endfor

  " Names for created buffers
  const s:capture_bufname = "Gdb capture"
  const s:asm_bufname = "Gdb disas"
  const s:prompt_bufname = "Gdb terminal"
  " Exceptions thrown
  const s:eval_exception = "EvalFailedException"
  " Set defaults for required variables
  let s:breakpoints = #{}
  let s:callbacks = #{}
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
  let s:scheduler_locking = "replay"

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
  " Ignore inferior stdout 
  let gdb_cmd .= ' -iex "set inferior-tty /dev/null"'
  " Remove the (gdb) prompt
  let gdb_cmd .= ' -iex "set prompt"'
  " Launch GDB through ssh
  if exists("s:host")
    let gdb_cmd = ['ssh', '-t', '-o', 'ConnectTimeout 1', s:host, gdb_cmd]
  endif

  let s:gdbwin = win_getid(winnr())
  let s:gdb_job_id = jobstart(gdb_cmd, {
        \ 'on_stdout': function('s:CommJoin'),
        \ 'on_exit': function('s:EndTermDebug'),
        \ 'pty': v:false
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
  call setbufvar(bufnr(), '&list', v:false)
  call prompt_setprompt(bufnr(), '(gdb) ')
  call prompt_setcallback(bufnr(), function('s:PromptOutput'))
  call prompt_setinterrupt(bufnr(), function('s:PromptInterrupt'))
  augroup TermDebug
    autocmd! BufModifiedSet <buffer> noautocmd setlocal nomodified
  augroup END
  inoremap <buffer> <C-d> <cmd>call TermDebugQuit()<CR>
  inoremap <buffer> <C-w> <cmd>call <SID>DeleteWord()<CR>
  inoremap <buffer> <Up> <cmd>call <SID>ArrowMap("-1")<CR>
  inoremap <buffer> <Down> <cmd>call <SID>ArrowMap("+1")<CR>
  inoremap <buffer> <Tab> <cmd>call <SID>TabMap("+1")<CR>
  inoremap <buffer> <S-Tab> <cmd>call <SID>TabMap("-1")<CR>
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
  " Display tabs properly
  call setbufvar(nr, '&expandtab', v:false)
  call setbufvar(nr, '&smarttab', v:false)
  call setbufvar(nr, '&softtabstop', 0)
  call setbufvar(nr, '&tabstop', 8)
endfunc

func s:CommReset(timer_id)
  let s:comm_buf = ""
  call s:PromptShowWarning("Communication with GDB reset")
endfunc

func s:CommJoin(job_id, msgs, event)
  let capture = bufnr(s:capture_bufname)
  for msg in a:msgs
    " Append to capture buf
    let empty = nvim_buf_line_count(capture) == 1 && empty(nvim_buf_get_lines(capture, 0, 1, v:true)[0])
    if empty
      call setbufline(capture, 1, strtrans(msg))
    else
      call appendbufline(capture, "$", strtrans(msg))
    endif
    " Process message
    let msg = s:comm_buf .. msg
    if !empty(msg) && msg !~ "^(gdb)"
      try
        call s:CommOutput(msg)
        let s:comm_buf = ""
        if exists('s:comm_timer')
          call timer_stop(s:comm_timer)
          unlet s:comm_timer
        endif
      catch /EvalFailedException/
        let s:comm_buf = msg
        if !exists('s:comm_timer')
          let s:comm_timer = timer_start(4000, function('s:CommReset'))
        endif
      endtry
    endif
  endfor
endfunc

func s:CommOutput(msg)
  " Stream record
  if !empty(a:msg) && stridx("~@&", a:msg[0]) == 0
    return s:HandleStream(a:msg)
  endif
  " Async record
  let async = s:GetAsyncClass(a:msg)
  if !empty(async)
    return s:HandleAsync(a:msg)
  endif
  " Result record
  let result = s:GetResultClass(a:msg)
  if !empty(result)
    return s:HandleResult(a:msg)
  endif
endfunc

func s:PromptOutput(cmd)
  " Check if in "command>" mode
  if exists('s:prompt_commands')
    if a:cmd == 'end'
      let msg = printf('-break-commands %s', join(s:prompt_commands, " "))
      call s:SendMICommandNoOutput(msg)
      call prompt_setprompt(bufnr(), '(gdb) ')
      unlet s:prompt_commands
    else
      call add(s:prompt_commands, s:EscapeMIArgument(a:cmd))
    endif
    return
  endif

  let cmd = split(a:cmd, " ")
  " Special commands

  if stridx("commands", cmd[0]) == 0 && len(cmd[0]) >= 3
    let brs = cmd[1:]
    if empty(brs)
      if empty(s:breakpoints)
        call s:PromptShowNormal("No breakpoints")
        return
      else
        call add(brs, max(map(keys(s:breakpoints), "str2nr(v:val)")))
      endif
    endif
    for brk in brs
      if !has_key(s:breakpoints, brk)
        call s:PromptShowNormal("No breakpoint number " . brk)
        return
      endif
    endfor
    let s:prompt_commands = brs
    call prompt_setprompt(bufnr(), 'command> ')
    return
  endif

  if exists('g:termdebug_override_finish_and_return') && g:termdebug_override_finish_and_return
    if stridx("finish", cmd[0]) == 0 && len(cmd[0]) >= 3
      let was_option = s:scheduler_locking
      call s:SendMICommandNoOutput('-gdb-set scheduler-locking on')
      call s:SendMICommandNoOutput('-exec-finish')
      call s:SendMICommandNoOutput('-gdb-set scheduler-locking ' . was_option)
      return
    endif

    if stridx("return", cmd[0]) == 0 && len(cmd[0]) >= 3
      let was_option = s:scheduler_locking
      call s:SendMICommandNoOutput('-gdb-set scheduler-locking on')
      call s:SendMICommandNoOutput('-interpreter-exec console finish')
      call s:SendMICommandNoOutput('-gdb-set scheduler-locking ' . was_option)
      return
    endif
  endif

  if exists("g:termdebug_override_up_and_down") && g:termdebug_override_up_and_down
    if cmd[0] == "up"
      return TermDebugSendMICommand('-stack-info-frame', function('s:HandleFrameLevel', [v:true]))
    endif
    if cmd[0] == "down"
      return TermDebugSendMICommand('-stack-info-frame', function('s:HandleFrameLevel', [v:false]))
    endif
  endif

  if exists("g:termdebug_override_s_and_n") && g:termdebug_override_s_and_n
    if cmd[0] == "asm"
      return TermDebugSetAsmMode(s:asm_mode ? 0 : 1)
    endif
    " Toggle asm mode based on instruction stepping
    if cmd[0] == "si" || cmd[0] == "stepi" || cmd[0] == "ni" || cmd[0] == "nexti"
      call TermDebugSetAsmMode(1)
    elseif cmd[0] == "s" || cmd[0] == "step" || cmd[0] == "n" || cmd[0] == "next"
      call TermDebugSetAsmMode(0)
    endif
  endif

  " Regular command
  let msg = '-interpreter-exec console ' . s:EscapeMIArgument(a:cmd)
  call s:SendMICommandNoOutput(msg)
endfunc

func s:PromptInterrupt()
  if TermDebugIsStopped()
    " Clear command line
    let nr = bufnr(s:prompt_bufname)
    let input = getbufline(nr, '$')[0]
    call s:PromptShowMessage([[input, "Normal"], ["^C", "Cursor"]])
  else
    " Send interrupt
    let interrupt = 2
    if !exists('s:host')
      let pid = jobpid(s:gdb_job_id)
      call v:lua.vim.loop.kill(pid, interrupt)
    else
      let kill = printf("kill -%d %d", interrupt, s:pid)
      call system(["ssh", s:host, kill])
    endif
  endif
  call s:SetCommandLine("")
endfunc

func s:PromptShowMessage(msg)
  let nr = bufnr(s:prompt_bufname)
  let lnum = nvim_buf_line_count(nr) - 1
  let line = join(map(copy(a:msg), "v:val[0]"), '')
  call appendbufline(nr, lnum, line)

  let ns = nvim_create_namespace('TermDebugHighlight')
  let end_col = 0
  for [msg, hl_group] in a:msg
    let start_col = end_col
    let end_col = start_col + len(msg)
    call nvim_buf_set_extmark(nr, ns, lnum, start_col, #{end_col: end_col, hl_group: hl_group})
  endfor
endfunc

func s:PromptShowNormal(msg)
  call s:PromptShowMessage([[a:msg, "Normal"]])
endfunc

func s:PromptShowWarning(msg)
  call s:PromptShowMessage([[a:msg, "WarningMsg"]])
endfunc

func s:PromptShowError(msg)
  call s:PromptShowMessage([[a:msg, "ErrorMsg"]])
endfunc

func s:DeleteWord()
  let [cmd_pre, cmd_post] = s:GetCommandLine(2)
  let cmd_pre = substitute(cmd_pre, '\S*\s*$', '', '')
  call s:SetCommandLine(cmd_pre . cmd_post, len(cmd_pre))
endfunc

func s:TabMap(expr)
  if s:IsOpenPreview('Completion')
    call s:ScrollPreview(a:expr)
  elseif s:IsOpenPreview('History')
    let inv_expr = (a:expr == "-1" ? "+1" : "-1")
    call s:ScrollPreview(inv_expr)
  elseif empty(s:GetCommandLine())
    if !empty(s:command_hist)
      call s:OpenScrollablePreview("History", s:command_hist)
      call s:ScrollPreview("$")
      call s:ClosePreviewOn('InsertLeave', 'CursorMovedI')
    endif
  else
    call s:OpenCompletion()
  endif
endfunc

func s:ArrowMap(expr)
  if s:IsOpenPreview("Completion") || s:IsOpenPreview("History")
    call s:ScrollPreview(a:expr)
    return
  endif
  if empty(s:command_hist)
    return
  endif

  " Quickly go to older history item
  if a:expr == '-1'
    if !exists('s:command_hist_idx')
      let s:command_hist_idx = len(s:command_hist)
      call add(s:command_hist, s:GetCommandLine())
      augroup TermDebugHistory
        autocmd! InsertLeave * call s:EndHistoryScrolling(1)
        autocmd! CursorMovedI * call s:EndHistoryScrolling(0)
      augroup END
    endif
    let s:command_hist_idx = max([s:command_hist_idx - 1, 0])
  elseif a:expr == '+1'
    if !exists('s:command_hist_idx')
      return
    endif
    let s:command_hist_idx = min([s:command_hist_idx + 1, len(s:command_hist) - 1])
  endif
  call s:SetCommandLine(s:command_hist[s:command_hist_idx])
endfunc

func s:EndHistoryScrolling(force)
  if exists('s:command_hist_idx')
    let parts = s:GetCommandLine(2)
    if a:force || parts[1] != '' || join(parts, '') != s:command_hist[s:command_hist_idx]
      call remove(s:command_hist, -1)
      unlet s:command_hist_idx
      autocmd! TermDebugHistory
    endif
  endif
endfunc

func s:EnterMap()
  let nr = bufnr(s:prompt_bufname)
  if s:IsOpenPreview('Completion')
    let complete = s:GetPreviewLine('.')
    call s:ClosePreview()
    let cmd_parts = split(s:GetCommandLine(), " ", 1)
    let cmd_parts[-1] = complete
    call s:SetCommandLine(join(cmd_parts, " "))
    return
  elseif s:IsOpenPreview('History')
    call s:SetCommandLine(s:GetPreviewLine('.'))
    call s:ClosePreview()
    return
  endif

  call s:EndHistoryScrolling(1)
  if !TermDebugIsStopped()
    return
  endif

  let cmd = s:GetCommandLine()
  if empty(cmd) || empty(split(cmd, '\s'))
    " Silently rerun last command
    if !empty(s:command_hist)
      let cmd = get(s:command_hist, -1, "")
      call s:PromptOutput(cmd)
    endif
  else
    " Add to history and input and actual <CR>
    call add(s:command_hist, cmd)
    call feedkeys("\n")
  endif
endfunc

func s:OpenCompletion()
  let cmd = s:GetCommandLine()
  let Cb = function('s:HandleCompletion', [cmd])
  call TermDebugSendMICommand('-complete ' . s:EscapeMIArgument(cmd), Cb)
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

func s:SetCommandLine(cmd, ...)
  let nr = bufnr(s:prompt_bufname)
  let prefix = prompt_getprompt(nr)
  let line = prefix . a:cmd
  let col = len(prefix) + get(a:000, 0, len(a:cmd))
  call setbufline(nr, '$', line)
  let view = winsaveview()
  if view['col'] != col
    let view['col'] = col
    call winrestview(view)
  endif
endfunc
" }}}

""""""""""""""""""""""""""""""""Record handlers"""""""""""""""""""""""""""""""{{{
func s:HandleAsync(msg)
  let async = s:GetAsyncClass(a:msg)
  let dict = EvalCommaResults(a:msg)
  if async == "stopped" || async == "running" || async == "thread-selected"
    return s:HandleCursor(async, dict)
  elseif async == "thread-group-started"
    return s:HandleProgramRun(dict)
  elseif async == 'breakpoint-created' || async == 'breakpoint-modified'
    return s:HandleNewBreakpoint(dict)
  elseif async == 'breakpoint-deleted'
    return s:HandleBreakpointDelete(dict)
  elseif async == 'cmd-param-changed'
    return s:HandleOption(dict)
  endif
endfunc

func s:HandleResult(msg)
  let result = s:GetResultClass(a:msg)
  let dict = EvalCommaResults(a:msg)
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

func s:HandleStream(msg)
  " Ignore textual output from target
  if a:msg[0] == '@'
    return
  endif
  execute printf('let msg = %s', a:msg[1:])
  " Join with messages from previous stream record
  let total = split(s:stream_buf . msg, "\n", 1)
  let lines = total[:-2]
  let s:stream_buf = total[-1]
  " Apply a custom filter
  if exists('g:termdebug_ignore_no_such') && g:termdebug_ignore_no_such
    call filter(lines, 'stridx(v:val, "No such file") < 0')
    call filter(lines, {k, v -> v !~ '^\d\+\s*in\s*\f\+'})
    call filter(lines, {k, v -> v !~ '^0x\x\+\s*\d*\s*in\s*\f\+'})
  endif
  " Show as normal text
  for line in lines
    call s:PromptShowNormal(line)
  endfor
endfunc

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(class, dict)
  " Update stopped state
  if a:class == 'thread-selected'
    let s:selected_thread = a:dict['id']
  elseif a:class == 'stopped'
    " Key might be missing when e.g. stopped due do signal (thread group exited)
    if has_key(a:dict, 'thread-id')
      let s:selected_thread = a:dict['thread-id']
    endif
    let s:stopped = 1
  elseif a:class == 'running'
    let id = a:dict['thread-id']
    if id == 'all' || (exists('s:selected_thread') && id == s:selected_thread)
      let s:stopped = 0
    endif
  endif
  " Update prompt
  let ns = nvim_create_namespace('TermDebugPrompt')
  let nr = bufnr(s:prompt_bufname)
  call nvim_buf_clear_namespace(nr, ns, 0, -1)
  if !s:stopped
    let lines = nvim_buf_line_count(nr)
    call nvim_buf_set_extmark(nr, ns, lines - 1, 0, #{line_hl_group: 'Comment'})
  endif
  " Update cursor
  call s:ClearCursorSign()
  if s:stopped
    call s:PlaceCursorSign(a:dict)
  endif
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
  let filename = s:Get('', a:dict, 'frame', 'fullname')
  let lnum = s:Get('', a:dict, 'frame', 'line')
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
  let addr = s:Get('', a:dict, 'frame', 'addr')
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

  if has_key(bkpt, 'addr') && bkpt['addr'] == '<MULTIPLE>'
    for location in bkpt['locations']
      let id = location['number']
      call s:ClearBreakpointSign(id)
      let s:breakpoints[id] = #{
            \ fullname: location['fullname'],
            \ lnum: location['line'],
            \ enabled: location['enabled'] == 'y' && bkpt['enabled'] == 'y',
            \ parent: bkpt['number']
            \ }
      call s:PlaceBreakpointSign(id)
    endfor
  elseif has_key(bkpt, 'fullname')
    let id = bkpt['number']
    call s:ClearBreakpointSign(id)
    let s:breakpoints[id] = #{
          \ fullname: bkpt['fullname'],
          \ lnum: bkpt['line'],
          \ enabled: bkpt['enabled'] == 'y'
          \ }
    call s:PlaceBreakpointSign(id)
  endif
endfunc

" Handle deleting a breakpoint
" Will remove the sign that shows the breakpoint
func s:HandleBreakpointDelete(dict)
  let id = a:dict['id']
  call s:ClearBreakpointSign(id)
  call s:ClearMultiBreakpointSigns(id)
endfunc

func s:ClearBreakpointSign(id)
  " Might be watchpoint that was deleted, so check first
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
    unlet s:breakpoints[a:id]
  endif
endfunc

func s:ClearMultiBreakpointSigns(id)
  let brks = filter(copy(s:breakpoints), 'has_key(v:val, "parent") && v:val.parent == a:id')
  for id in keys(brks)
    call s:ClearBreakpointSign(id)
  endfor
endfunc

func s:PlaceBreakpointSign(id)
  if has_key(s:breakpoints, a:id)
    let breakpoint = s:breakpoints[a:id]
    let bufnr = bufnr(breakpoint['fullname'])
    let placed = has_key(breakpoint, 'extmark')
    if bufnr > 0 && !placed
      call bufload(bufnr)
      let ns = nvim_create_namespace('TermDebugBr')
      let text = has_key(breakpoint, 'parent') ? breakpoint['parent'] : a:id
      if len(text) > 2
        let text = "*"
      endif
      let hl_group = breakpoint['enabled'] ? 'debugBreakpoint' : 'debugBreakpointDisabled'
      let opts = #{sign_text: text, sign_hl_group: hl_group}
      let extmark = nvim_buf_set_extmark(bufnr, ns, breakpoint['lnum'] - 1, 0, opts)
      let s:breakpoints[a:id]['extmark'] = extmark
    endif
  endif
endfunc

func s:HandleOption(dict)
  if a:dict['param'] == 'scheduler-locking'
    let s:scheduler_locking = a:dict['value']
  endif
endfunc
" }}}

""""""""""""""""""""""""""""""""Eval""""""""""""""""""""""""""""""""""""""""""{{{
function s:EvalThrow(msg, ...)
  if a:0 == 1
    let msg = printf(a:msg, a:1)
  elseif a:0 == 2
    let msg = printf(a:msg, a:1, a:2)
  else
    let msg = a:msg
  endif
  throw s:eval_exception .. ": " .. msg
endfunction

func EvalCommaResults(msg) abort
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
  if !empty(rest)
    call s:EvalThrow("Trailing characters: %s", rest[0:4])
  endif
  return dict
endfunc

func s:EvalResult(msg) abort
  let varname = matchstr(a:msg, '^[a-z_-]\+')
  if len(varname) == 0
    call s:EvalThrow("Expecting variable name but got: %s", a:msg[0:0])
  endif
  let eq_idx = len(varname)
  if a:msg[eq_idx] != '='
    call s:EvalThrow("Expecting assignment but got: %s", a:msg[eq_idx:eq_idx])
  endif
  let [value, rest] = s:EvalValue(a:msg[eq_idx+1:])
  let result = {varname: value}
  return [result, rest]
endfunc

func s:EvalValue(msg) abort
  if a:msg[0] == '"'
    return s:EvalString(a:msg)
  elseif a:msg[0] == '{' || a:msg[0] == '['
    if a:msg[1] == '"' || a:msg[1] == '{' || a:msg[1] == '['
      " No keys, just values
      return s:EvalList(a:msg)
    else
      " Key=Value pairs
      return s:EvalTuple(a:msg)
    endif
  else
    call s:EvalThrow("Expecting value but got: %s", a:msg[0:0])
  endif
endfunc

func s:EvalString(msg) abort
  let idx = 1
  let len = len(a:msg)
  while idx < len
    if a:msg[idx] == '\'
      let idx += 1
    elseif a:msg[idx] == '"'
      return [eval(a:msg[:idx]), a:msg[idx+1:]]
    endif
    let idx += 1
  endwhile
  call s:EvalThrow("Unterminated c-string")
endfunc

func s:CheckBracketsMatch(open, close) abort
  if a:open == '[' && a:close == ']'
    return v:true
  elseif a:open == '{' && a:close == '}'
    return v:true
  endif
  call s:EvalThrow("Bracket mismatch: %s and %s", a:open, a:close)
endfunc

func s:EvalTuple(msg) abort
  if a:msg[1] == ']' || a:msg[1] == '}'
    call s:CheckBracketsMatch(a:msg[0], a:msg[1])
    let rest = a:msg[2:]
    return [[], rest]
  endif

  let [head, rest] = s:EvalResult(a:msg[1:])
  let keys = keys(head)
  let values = values(head)
  while rest[0] == ','
    let [head, rest] = s:EvalResult(rest[1:])
    call extend(keys, keys(head))
    call extend(values, values(head))
  endwhile
  call s:CheckBracketsMatch(a:msg[0], rest[0])
  let rest = rest[1:]

  " Patch GDB's weird idea of a tuple
  let dup_keys = len(keys) > 1 && keys[0] == keys[1]
  if dup_keys
    return [values, rest]
  endif
  let dict = s:Zip(keys, values)
  return [dict, rest]
endfunc

func s:EvalList(msg) abort
  if a:msg[1] == ']' || a:msg[1] == '}'
    call s:CheckBracketsMatch(a:msg[0], a:msg[1])
    let rest = a:msg[2:]
    return [[], rest]
  endif

  let [head, rest] = s:EvalValue(a:msg[1:])
  let list = [head]
  while rest[0] == ','
    let [head, rest] = s:EvalValue(rest[1:])
    call add(list, head)
  endwhile
  call s:CheckBracketsMatch(a:msg[0], rest[0])
  let rest = rest[1:]
  return [list, rest]
endfunc

func s:Zip(keys, values) abort
  let dict = #{}
  for i in range(len(a:keys))
    let dict[a:keys[i]] = a:values[i]
  endfor
  return dict
endfunc

func s:Get(def, dict, ...) abort
  if type(a:dict) != v:t_dict
    throw "Invalid arguments, expecting dictionary as second argument"
  endif
  let result = a:dict
  for key in a:000
    if type(key) != v:t_string
      throw "Invalid arguments, expecting string at third parameter and onwards"
    endif
    if type(result) != v:t_dict || !has_key(result, key)
      return a:def
    endif
    let result = result[key]
  endfor
  return result
endfunc

func s:GetListWithKeys(dict, key) abort
  let res = a:dict[a:key]
  if type(res) == v:t_dict
    return values(res)
  else
    return res
  endif
endfunc

func s:MatchGetCapture(string, pat) abort
  let res = matchlist(a:string, a:pat)
  if empty(res)
    return ""
  endif
  return res[1]
endfunc

func s:GetAsyncClass(msg) abort
  return s:MatchGetCapture(a:msg, '^[0-9]*[*+=]\([^,]*\),\?')
endfunc

func s:GetResultToken(msg) abort
  return s:MatchGetCapture(a:msg, '^\([0-9]\+\)\^')
endfunc

func s:GetResultClass(msg) abort
  return s:MatchGetCapture(a:msg, '^[0-9]*\^\([^,]*\),\?')
endfunc
"}}}

""""""""""""""""""""""""""""""""Result handles""""""""""""""""""""""""""""""""{{{
func s:HandleBreakpointEdit(bp, dict)
  let script = s:Get([], a:dict, 'BreakpointTable', 'body', 'bkpt', 'script')
  if !empty(script) && bufname() == s:prompt_bufname
    call s:OpenFloatEdit(script)
    augroup TermDebugFloatEdit
      exe printf("autocmd! WinClosed * ++once call s:OnBrEditComplete(%d)", a:bp)
    augroup END
  endif
endfunc

func s:OnBrEditComplete(bp)
  let winid = expand("<amatch>")
  let nr = winbufnr(winid)
  let commands = getbufline(nr, 1, '$')
  call s:CloseFloatEdit(winid)

  let commands = map(commands, {k, v -> '"' . v . '"'})
  let msg = printf("-break-commands %d %s", a:bp, join(commands, " "))
  call TermDebugSendMICommand(msg, {_ -> s:PromptShowNormal("Breakpoint commands updated")})
endfunc

func s:HandleSymbolInfo(dict)
  let list = []
  " Look in debug section
  let dbg = s:Get([], a:dict, 'symbols', 'debug')
  for location in dbg
    let filename = location['fullname']
    let valid = filereadable(filename)
    for symbol in location['symbols']
      let lnum = symbol['line']
      let text = symbol['name']
      if valid
        call add(list, #{filename: filename, lnum: lnum, text: text})
      else
        call add(list, #{text: text, valid: 0})
      endif
    endfor
  endfor
  if !empty(list)
    call setqflist([], ' ', #{title: "Debug", items: list})
    copen
    return
  endif
  " Look in nondebug section
  let nondebug = s:Get([], a:dict, 'symbols', 'nondebug')
  for symbol in nondebug
    let address = symbol['address']
    let text = symbol['name']
    call add(list, #{filename: address, text: text, valid: 0})
  endfor
  if !empty(list)
    call setqflist([], ' ', #{title: "Nondebug", items: list})
    copen
    echo "Found nondebug symbols only"
  else
    echo "Symbol not found"
  endif
endfunc

func s:HandleEvaluate(winid, dict)
  let lines = split(a:dict['value'], "\n")
  let was_win = win_getid()
  call win_gotoid(a:winid)
  call s:OpenPreview("Value", lines)
  call s:ClosePreviewOn('CursorMoved', 'WinScrolled', 'WinResized')
endfunc

func s:HandleCompletion(cmd, dict)
  let matches = a:dict['matches']
  let matches = filter(matches, "stridx(v:val, a:cmd) == 0 && len(v:val) > len(a:cmd)")
  if len(a:cmd) > 0 && len(matches) > 0 && (bufname() == s:prompt_bufname)
    let context = split(a:cmd, " ", 1)[-1]
    let matches = map(matches, "context .. v:val[len(a:cmd):]")
    call s:OpenScrollablePreview("Completion", matches)
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
    call appendbufline(nr, 0, "No disassembler output")
    return
  endif

  let intro = printf("Disassembly of %s:", asm_insns[0]['func-name'])
  call appendbufline(nr, 0, intro)

  for asm_ins in asm_insns
    let address = asm_ins['address']
    let offset = asm_ins['offset']
    let inst = asm_ins['inst']
    let line = printf("%s<%d>: %s", address, offset, inst)
    call appendbufline(nr, "$", line)
  endfor
  call s:SelectAsmAddr(a:addr)
endfunc

func s:HandleFrameLevel(going_up, dict)
  let level = s:Get(0, a:dict, 'frame', 'level')
  call TermDebugSendMICommand('-stack-list-frames', function('s:HandleFrameList', [a:going_up, level]))
endfunc

func s:HandleFrameList(going_up, level, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  if a:going_up
    call filter(frames, "v:val.level > a:level")
  else
    call filter(frames, "v:val.level < a:level")
    call reverse(frames)
  endif
  let prefix = "/home/" .. $USER
  for frame in frames
    let fullname = s:Get('', frame, 'fullname')
    if filereadable(fullname) && stridx(fullname, prefix) == 0
      if TermDebugIsStopped()
        let cmd = printf('-interpreter-exec console "frame %d"', frame['level'])
        call s:SendMICommandNoOutput(cmd)
      endif
      return
    endif
  endfor
endfunc

func s:HandleBacktrace(dict)
  let list = []
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    let fullname = s:Get('', frame, 'fullname')
    if filereadable(fullname)
      call add(list, #{text: frame['func'], filename: fullname, lnum: frame['line']})
    endif
  endfor
  call TermDebugGoToSource()
  call setqflist([], ' ', #{title: "Backtrace", items: list})
  copen
endfunc

func s:HandleThreadList(pat, dict)
  let ids = s:GetListWithKeys(a:dict, 'thread-ids')
  let s:pending_threads = len(ids)
  let s:collected = #{}
  for id in ids
    let Cb = function('s:CollectThreads', [a:pat, id])
    call TermDebugSendMICommand('-stack-list-frames --thread ' . id, Cb)
  endfor
endfunc

func s:CollectThreads(pat, id, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  let s:collected[a:id] = frames
  if len(s:collected) != s:pending_threads
    return
  endif
  " Wait for all threads

  let list = []
  for key in keys(s:collected)
    for frame in s:collected[key]
      let fullname = s:Get('', frame, 'fullname')
      if filereadable(fullname) && match(fullname, a:pat) >= 0
        let text = printf('Thread %d at frame %d', key, frame['level'])
        call add(list, #{text: text, filename: frame['fullname'], lnum: frame['line']})
      endif
    endfor
  endfor

  unlet s:collected
  unlet s:pending_threads
  call setqflist([], ' ', #{title: 'Threads', items: list})
  copen
endfunc

func s:HandleError(dict)
  let lines = split(a:dict['msg'], "\n")
  for line in lines
    call s:PromptShowError(line)
  endfor
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

func s:OpenFloatEdit(lines)
  const width = 20
  const height = 5
  let row = (nvim_win_get_height(0) - height) / 2
  let col = (nvim_win_get_width(0) - width) / 2
  let opts = #{
        \ relative: "win",
        \ row: row,
        \ col: col,
        \ width: width,
        \ height: height,
        \ focusable: 1,
        \ style: "minimal",
        \ border: "single",
        \ noautocmd: 1
        \ }

  let nr = nvim_create_buf(0, 0)
  call nvim_buf_set_option(nr, "buftype", "nofile")
  call setbufline(nr, 1, a:lines)
  let winid = nvim_open_win(nr, v:true, opts)
  call nvim_win_set_option(winid, 'wrap', v:false)
  return winid
endfunc

func s:CloseFloatEdit(winid)
  let nr = winbufnr(a:winid)
  call nvim_buf_delete(nr, #{force: 1})
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
    let row = 0
    let anchor = 'SW'
    let title_pos = "left"
  else
    let row = 1
    let anchor = 'NW'
    let title_pos = "right"
  endif

  let opts = #{
        \ relative: "cursor",
        \ anchor: anchor,
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
  if line('$', s:preview_win) > 1
    call deletebufline(nr, 1, '$')
  endif
  call setbufline(nr, 1, a:lines)
  return s:preview_win
endfunc

func s:OpenScrollablePreview(title, lines)
  let winid = s:OpenPreview(a:title, a:lines)
  call nvim_win_set_option(winid, 'cursorline', v:true)
  call nvim_win_set_option(winid, 'scrolloff', 2)
endfunc

func s:IsOpenPreview(title)
  if !exists('s:preview_win')
    return v:false
  endif
  let config = nvim_win_get_config(s:preview_win)
  let title = join(map(config['title'], "v:val[0]"), '')
  return has_key(config, 'title') && title == a:title
endfunc

func s:ScrollPreview(expr)
  let num_lines = line('$', s:preview_win)
  let curr = line('.', s:preview_win)
  if a:expr == '1'
    let line = 1
  elseif a:expr == '$'
    let line = num_lines
  elseif a:expr == '-1'
    let line = curr - 1
  elseif a:expr == '+1'
    let line = curr + 1
  else
    let line = str2nr(a:expr)
  endif
  " Make it loop
  if line < 1
    let line = num_lines
  elseif line > num_lines
    let line = 1
  endif
  call nvim_win_set_cursor(s:preview_win, [line, 0])
endfunc

func s:GetPreviewLine(expr)
  let nr = winbufnr(s:preview_win)
  let pos = line(a:expr, s:preview_win)
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
" }}}
