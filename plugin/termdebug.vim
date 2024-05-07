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

func TermDebugGoToBreakpoint(id)
  let id = a:id
  if !has_key(s:breakpoints, id)
    echo "No breakpoint " . id
    return
  endif

  let breakpoint = s:breakpoints[id]
  let lnum = breakpoint['lnum']
  let fullname = breakpoint['fullname']
  if !filereadable(fullname)
    echo "No source for " . id
    return
  endif

  if expand("%:p") != fullname
    exe "e " . fnameescape(fullname)
  endif
  call cursor(lnum, 0)
endfunc

func TermDebugGoToCapture()
  let ids = win_findbuf(s:capture_bufnr)
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
  let wids = win_findbuf(s:prompt_bufnr)
  if !empty(wids)
    call win_gotoid(wids[0])
  else
    above new
    exe "b " . s:prompt_bufnr
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
  let escaped = '"'
  for char in a:arg
    if char == '\'
      let escaped ..= '\\'
    elseif char == '"'
      let escaped ..= '\"'
    else
      let escaped ..= char
    endif
  endfor
  return escaped .. '"'
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
  const s:float_edit_exception = "FloatEditException"
  " Set defaults for required variables
  let s:vars = []
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
  if a:0 > 1
    let s:user = a:2
  endif
  " GDB settings
  let s:scheduler_locking = "replay"
  let s:max_completions = 20

  call s:CreateSpecialBuffers()

  augroup TermDebug
    autocmd! BufRead * call s:BufRead()
  augroup END

  call s:LaunchGdb()
endfunc

func s:LaunchGdb()
  let gdb_cmd = [g:termdebugger]
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  call add(gdb_cmd, '-quiet')
  " Communicate with GDB in the background via MI interface
  call add(gdb_cmd, '--interpreter=mi')
  " Disable pagination, it causes everything to stop at the gdb
  call extend(gdb_cmd, ['-iex', 'set pagination off'])
  " Ignore inferior stdout 
  call extend(gdb_cmd, ['-iex', 'set inferior-tty /dev/null'])
  " Remove the (gdb) prompt
  call extend(gdb_cmd, ['-iex', 'set prompt'])
  " Limit completions for faster TAB autocomplete
  call extend(gdb_cmd, ['-iex', 'set max-completions ' . s:max_completions])
  " Do not open a shell to run inferior
  call extend(gdb_cmd, ['-iex', 'set startup-with-shell off'])
  " Launch GDB through ssh
  if exists("s:host")
    let gdb_str = join(map(gdb_cmd, 'shellescape(v:val)'), ' ')
    " Also change the effective user
    if exists("s:user")
      let gdb_str = printf("sudo -u %s %s", s:user, gdb_str)
    endif
    let gdb_cmd = ['ssh', '-T', '-o', 'ConnectTimeout 1', s:host, gdb_str]
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

  augroup TermDebug
    autocmd! BufModifiedSet <buffer> noautocmd setlocal nomodified
  augroup END

  inoremap <buffer> <expr> <C-d> <SID>CtrlD_Map()
  inoremap <buffer> <expr> <C-c> <SID>CtrlC_Map()
  inoremap <buffer> <expr> <C-w> <SID>CtrlW_Map()
  inoremap <buffer> <C-Space> <cmd>call <SID>CtrlSpace_Map()<CR>
  inoremap <buffer> <C-n> <cmd>call <SID>ScrollPreview("+1")<CR>
  inoremap <buffer> <C-p> <cmd>call <SID>ScrollPreview("-1")<CR>
  inoremap <buffer> <expr> <C-y> <SID>TabMap()
  inoremap <buffer> <expr> <Up> <SID>ArrowMap("-1")
  inoremap <buffer> <expr> <Down> <SID>ArrowMap("+1")
  inoremap <buffer> <expr> <Tab> <SID>TabMap()
  inoremap <buffer> <expr> <CR> <SID>EnterMap()
  nnoremap <buffer> <CR> <cmd>call <SID>ExpandCursor(line('.'))<CR>

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

  " Do this once now for convenience
  let s:capture_bufnr = bufnr(s:capture_bufname)
  let s:asm_bufnr = bufnr(s:asm_bufname)
  let s:prompt_bufnr = bufnr(s:prompt_bufname)
  
  " Options for asm window
  call setbufvar(s:asm_bufnr, '&ft', 'asm')
  " Options for prompt window
  call setbufvar(s:prompt_bufnr, '&buftype', 'prompt')
  " Display tabs properly in asm/source windows
  for nr in [s:asm_bufnr, s:prompt_bufnr]
    call setbufvar(nr, '&expandtab', v:false)
    call setbufvar(nr, '&smarttab', v:false)
    call setbufvar(nr, '&softtabstop', 0)
    call setbufvar(nr, '&tabstop', 8)
  endfor
endfunc

func s:CommReset(timer_id)
  let s:comm_buf = ""
  call s:PromptShowWarning("Communication with GDB reset")
endfunc

func s:CommJoin(job_id, msgs, event)
  for msg in a:msgs
    " Append to capture buf
    if s:EmptyBuffer(s:capture_bufnr)
      call setbufline(s:capture_bufnr, 1, strtrans(msg))
    else
      call appendbufline(s:capture_bufnr, "$", strtrans(msg))
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

func s:EmptyBuffer(nr)
  return nvim_buf_line_count(a:nr) == 1 && empty(nvim_buf_get_lines(a:nr, 0, 1, v:true)[0])
endfunc

func s:CtrlD_Map()
  call TermDebugQuit()
  return ''
endfunc

func s:CtrlC_Map()
  if TermDebugIsStopped()
    let input = getbufline(s:prompt_bufnr, '$')[0]
    call s:PromptShowMessage([[input, "Normal"], ["^C", "Cursor"]])
    s:SetCommandLine("")
    return ''
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
  return ''
endfunc

func s:CtrlW_Map()
  let [cmd_pre, cmd_post] = s:GetCommandLine(2)
  let n = len(matchstr(cmd_pre, '\S*\s*$'))
  return repeat("\<BS>", n)
endfunc

func s:TabMap(expr)
  " XXX: CAN'T close preview window here because of <expr> map
  if s:IsOpenPreview('Completion')
    let cmp = s:GetPreviewLine('.')
    let cmd_parts = split(s:GetCommandLine(), " ", 1)
    let cmd_parts[-1] = cmp
    return s:SetCommandLine(join(cmd_parts, " "))
  elseif s:IsOpenPreview('History')
    let cmdline = s:SetCommandLine(s:GetPreviewLine('.'))
    return cmdline
  else
    return ""
  endif
endfunc

func s:CtrlSpace_Map()
  if empty(s:GetCommandLine())
    call s:OpenHistory()
  else
    call s:OpenCompletion()
  endif
endfunc

func s:OpenHistory()
  if !empty(s:command_hist)
    call s:OpenScrollablePreview("History", reverse(copy(s:command_hist)))
    call s:ScrollPreview("1")
    call s:ClosePreviewOn('InsertLeave', 'CursorMovedI')
  endif
endfunc

func s:OpenCompletion()
  let cmd = s:GetCommandLine()
  let context = split(cmd, " ", 1)[-1]
  if exists('s:preview_win')
    let nr = nvim_win_get_buf(s:preview_win)
    if nvim_buf_line_count(nr) < s:max_completions
      if stridx(cmd, s:previous_cmd) == 0 && cmd[-1:-1] !~ '\s'
        let matches = filter(getbufline(nr, 1, '$'), 'stridx(v:val, context) == 0 && v:val != context')
        " Just refresh the preview
        if empty(matches)
          call s:ClosePreview()
        else
          call s:OpenScrollablePreview("Completion", matches)
          call s:ScrollPreview("1")
          let s:previous_cmd = cmd
        endif
        return
      endif
    endif
  endif
  " Need to refetch completions from GDB
  let Cb = function('s:HandleCompletion', [cmd])
  call TermDebugSendMICommand('-complete ' . s:EscapeMIArgument(cmd), Cb)
endfunc

func s:ArrowMap(expr)
  if s:IsOpenPreview("Completion") || s:IsOpenPreview("History")
    call s:ScrollPreview(a:expr)
    return ''
  endif
  if empty(s:command_hist)
    return ''
  endif

  " Quickly scroll history (no preview)
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
      return ''
    endif
    let s:command_hist_idx = min([s:command_hist_idx + 1, len(s:command_hist) - 1])
  endif
  return s:SetCommandLine(s:command_hist[s:command_hist_idx])
endfunc

func s:EndHistoryScrolling(force)
  if exists('s:command_hist_idx')
    let parts = s:GetCommandLine(2)
    if a:force || parts[1] != '' || join(parts, '') != s:command_hist[s:command_hist_idx]
      call remove(s:command_hist, -1)
      unlet s:command_hist_idx
    endif
  endif
  if exists('#TermDebugHistory')
    au! TermDebugHistory
  endif
endfunc

func s:EnterMap()
  call s:EndHistoryScrolling(1)
  call s:EndCompletion()
  call s:EndPrinting()
  if !TermDebugIsStopped()
    return ''
  endif

  let cmd = s:GetCommandLine()
  if cmd =~ '\S'
    " Add to history and run command
    call add(s:command_hist, cmd)
    return "\n"
  else
    " Silently rerun last command
    if !empty(s:command_hist)
      let cmd = get(s:command_hist, -1, "")
      call s:PromptOutput(cmd)
    endif
    let silent = exists('g:termdebug_silent_rerun') && g:termdebug_silent_rerun
    return silent ? "" : "\n"
  endif
endfunc

func s:GetCommandLine(...)
  let line = getbufline(s:prompt_bufnr, '$')[0]
  let off = len(prompt_getprompt(s:prompt_bufnr))
  let parts = get(a:000, 0, 1)
  if parts == 1
    return line[off:]
  else
    let col = getcurpos()[2] - 1
    return [line[off:col-1], line[col:]]
  endif
endfunc

func s:SetCommandLine(cmd)
  return "\<C-U>" .. a:cmd
endfunc
" }}}

""""""""""""""""""""""""""""""""Custom commands"""""""""""""""""""""""""""""""{{{
func s:PromptOutput(cmd)
  if empty(a:cmd)
    return
  endif
  " Check if in command> mode
  if prompt_getprompt(s:prompt_bufnr) =~ 'command>'
    return s:CommandsOutput(a:cmd)
  endif

  let cmd = split(a:cmd, " ")

  " Remapped commands (required in order to work)
  if stridx("commands", cmd[0]) == 0 && len(cmd[0]) >= 3
    return s:CommandsCommand(cmd)
  endif

  " Unsupported commands (need remapping)
  if stridx("python", cmd[0]) == 0 && len(cmd[0]) >= 2
    return s:PromptShowError("No python support yet!")
  elseif stridx("!", cmd[0]) == 0 || (stridx("shell", cmd[0]) == 0 && len(cmd[0]) >= 3)
    return s:PromptShowError("No shell support yet!")
  elseif stridx("edit", cmd[0]) == 0 && len(cmd[0]) >= 2
    return s:PromptShowError("No edit support (ever)!")
  endif

  " Custom commands
  if cmd[0] == "hostname" && len(cmd[0]) >= 4
    return s:HostnameCommand()
  elseif cmd[0] == "whoami" && len(cmd[0]) >= 3
    return s:WhoamiCommand()
  elseif cmd[0] == "qfsave"
    return s:QfSaveCommand()
  elseif cmd[0] == "qfsource"
    return s:QfSourceCommand()
  endif

  " Overriding GDB commands
  if exists('g:termdebug_override_finish_and_return') && g:termdebug_override_finish_and_return
    if stridx("finish", cmd[0]) == 0 && len(cmd[0]) >= 3
      return s:FinishCommand()
    elseif stridx("return", cmd[0]) == 0 && len(cmd[0]) >= 3
      return s:ReturnCommand()
    endif
  endif
  if exists("g:termdebug_override_up_and_down") && g:termdebug_override_up_and_down
    if cmd[0] == "up"
      return s:UpCommand()
    elseif cmd[0] == "down"
      return s:DownCommand()
    endif
  endif
  if exists("g:termdebug_override_s_and_n") && g:termdebug_override_s_and_n
    if cmd[0] == "asm"
      return s:AsmCommand()
    elseif cmd[0] == "si" || cmd[0] == "stepi"
      call TermDebugSetAsmMode(1)
      return s:SendMICommandNoOutput('-exec-step-instruction')
    elseif cmd[0] == "ni" || cmd[0] == "nexti"
      call TermDebugSetAsmMode(1)
      return s:SendMICommandNoOutput('-exec-next-instruction')
    elseif cmd[0] == "s" || cmd[0] == "step"
      call TermDebugSetAsmMode(0)
      return s:SendMICommandNoOutput('-exec-step')
    elseif cmd[0] == "n" || cmd[0] == "next"
      call TermDebugSetAsmMode(0)
      return s:SendMICommandNoOutput('-exec-next')
    endif
  endif
  if exists("g:termdebug_override_p") && g:termdebug_override_p
    if cmd[0] == "p" || cmd[0] == "print"
      return s:PrintCommand(join(cmd[1:], " "))
    endif
  endif

  " Regular command
  let msg = '-interpreter-exec console ' . s:EscapeMIArgument(a:cmd)
  call s:SendMICommandNoOutput(msg)
endfunc

func s:CommandsCommand(cmd)
  let brs = a:cmd[1:]
  if empty(brs)
    if empty(s:breakpoints)
      return s:PromptShowError("No breakpoints")
    else
      let last_br = max(map(keys(s:breakpoints), "str2nr(v:val)"))
      call add(brs, last_br)
    endif
  endif

  for brk in brs
    if !has_key(s:breakpoints, brk)
      call s:PromptShowError("No breakpoint number " . brk)
      return
    endif
  endfor
  let s:prompt_commands = brs
  call prompt_setprompt(s:prompt_bufnr, 'command> ')
endfunc

func s:CommandsOutput(cmd)
  if a:cmd == 'end'
    let msg = printf('-break-commands %s', join(s:prompt_commands, " "))
    call s:SendMICommandNoOutput(msg)
    call prompt_setprompt(bufnr(), '(gdb) ')
    unlet s:prompt_commands
  else
    call add(s:prompt_commands, s:EscapeMIArgument(a:cmd))
  endif
  return
endfunc

func s:HostnameCommand()
  if exists('s:host')
    call s:PromptShowNormal("Remote debugging " .. s:host)
  else
    call s:PromptShowNormal("Local debugging")
  endif
endfunc

func s:WhoamiCommand()
  if s:pid <= 0
    call s:PromptShowError("No inferior running.")
  else
    let cmd = ['stat', '--printf=%G', '/proc/' . s:pid]
    if exists('s:host')
      let cmd = ["ssh", s:host, join(cmd, ' ')]
    endif
    let user = system(cmd)
    call s:PromptShowNormal("User of inferior process: " .. user)
  endif
endfunc

func s:QfSourceCommand()
  if empty(getqflist())
    return s:PromptShowError("No breakpoints were inserted")
  endif
  for item in getqflist()
    let fname = fnamemodify(bufname(item['bufnr']), ":p")
    let lnum = item['lnum']
    let loc = fname . ":" . lnum
    call TermDebugSendMICommand("-break-insert " . loc, function('s:HandleNewBreakpoint'))
  endfor
  call s:PromptShowNormal("Breakpoints loaded from quickfix")
endfunc

func s:QfSaveCommand()
  let items = map(items(s:breakpoints), {_, item -> {
        \ "text": "Breakpoint " . item[0],
        \ "filename": item[1]['fullname'],
        \ "lnum": item[1]['lnum'],
        \ "valid": filereadable(item[1]['fullname'])
        \ }})
  call filter(items, "v:val.valid")
  if empty(items)
    call s:PromptShowError("No breakpoints")
  endif
  call setqflist([], ' ', {"title": "Breakpoints", "items": items})
  call s:PromptShowNormal("Breakpoints saved in quickfix")
endfunc

func s:FinishCommand()
  let was_option = s:scheduler_locking
  call s:SendMICommandNoOutput('-gdb-set scheduler-locking on')
  call s:SendMICommandNoOutput('-exec-finish')
  call s:SendMICommandNoOutput('-gdb-set scheduler-locking ' . was_option)
endfunc

func s:ReturnCommand()
  let was_option = s:scheduler_locking
  call s:SendMICommandNoOutput('-gdb-set scheduler-locking on')
  call s:SendMICommandNoOutput('-interpreter-exec console finish')
  call s:SendMICommandNoOutput('-gdb-set scheduler-locking ' . was_option)
endfunc

func s:UpCommand()
  call TermDebugSendMICommand('-stack-info-frame', function('s:HandleFrameLevel', [v:true]))
endfunc

func s:DownCommand()
  call TermDebugSendMICommand('-stack-info-frame', function('s:HandleFrameLevel', [v:false]))
endfunc

func s:AsmCommand()
  call TermDebugSetAsmMode(s:asm_mode ? 0 : 1)
endfunc

func s:PromptShowMessage(msg)
  let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
  call s:PromptPlaceMessage(lnum, a:msg)
endfunc

" 1-based indexing
func s:PromptPlaceMessage(where, msg)
  let lnum = a:where
  let line = join(map(copy(a:msg), "v:val[0]"), '')
  call appendbufline(s:prompt_bufnr, lnum, line)

  let ns = nvim_create_namespace('TermDebugHighlight')
  let end_col = 0
  for [msg, hl_group] in a:msg
    let start_col = end_col
    let end_col = start_col + len(msg)
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, lnum, start_col, #{end_col: end_col, hl_group: hl_group})
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

func s:PromptShowSourceLine()
  let lnum = line('.')
  let line = getline(lnum)
  " Copy source line with syntax
  let text = ""
  let text_hl = ""
  let items = []
  for i in range(len(line))
    let hl = synID(lnum, i+1, 1)->synIDattr("name")
    if hl == text_hl
      let text ..= line[i]
    else
      call add(items, [text, text_hl])
      let text = line[i]
      let text_hl = hl
    endif
  endfor
  call add(items, [text, text_hl])
  call s:PromptShowMessage(items)
  " Apply extmarks to prompt line
  let extmarks = nvim_buf_get_extmarks(0, -1, [lnum - 1, 0], [lnum - 1, len(line)], #{details: v:true})
  let ns = nvim_create_namespace('TermDebugHighlight')
  let prompt_lnum = nvim_buf_line_count(s:prompt_bufnr) - 2
  for extm in extmarks
    let start_col = extm[2]
    let opts = extm[3]
    " Ignore breakpoint signs
    if get(opts, 'sign_text', 0) == 1
      continue
    endif
    " Perform some gymnastics on options
    let row = extm[1]
    if get(opts, 'end_row', row) != row
      continue
    endif
    silent! unlet opts['end_row']
    if has_key(opts, 'end_col') && opts['end_col'] > len(line)
      let opts['end_col'] = len(line)
    endif
    silent! unlet opts['ns_id']
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, prompt_lnum, start_col, opts)
  endfor
endfunc
" }}}

""""""""""""""""""""""""""""""""Printing""""""""""""""""""""""""""""""""""""""{{{
func s:PrintCommand(expr)
  let Cb = function('s:ShowValue', [a:expr])
  call TermDebugSendMICommand('-var-create - * ' . s:EscapeMIArgument(a:expr), Cb)
endfunc

func s:ShowValue(expr, dict)
  let var = a:dict
  call add(s:vars, var['name'])
  let var['exp'] = a:expr
  let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
  call s:ShowElided(lnum, var)
endfunc

func s:ShowElided(lnum, var)
  let name = a:var['name']
  let uiname = a:var['exp']
  let value = a:var["value"]
  let recursive = a:var['numchild'] > 0
  let no_modifiers = substitute(name, '\.protected\|\.public\|\.private', '', 'g')
  let level = len(substitute(no_modifiers, '[^.]', '', 'g'))
  let indent = repeat(" ", level * 2)

  let indent_item = [indent, "Normal"]
  let name_item = [uiname, "Normal"]
  let value_item = [value, "markdownCode"]
  call s:PromptPlaceMessage(a:lnum, [indent_item, name_item, [" = ", "Normal"], value_item])
  if recursive
    " Mark the variable
    let ns = nvim_create_namespace('TermDebugConceal')
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, 0, #{virt_text: [[name, "EndOfBuffer"]]})
    let col = len(indent) + len(uiname) + 3
    let opts = #{end_col: col + len(value), hl_group: 'markdownLinkText', priority: 10000}
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, col, opts)
  endif
endfunc

func s:ExpandCursor(lnum)
  let lnum = a:lnum - 1
  " Index into created marks
  let ns = nvim_create_namespace('TermDebugConceal')
  let extmarks = nvim_buf_get_extmarks(0, ns, [lnum, 0], [lnum + 1, 0], #{details: 1})
  if len(extmarks) < 2
    return
  endif
  " Get the variable name from first mark
  let index = has_key(extmarks[0][3], 'virt_text') ? 0 : 1
  let opts = extmarks[index][3]
  let varname = opts['virt_text'][0][0]
  " Remove highlights to signal that the link is inactive
  call nvim_buf_del_extmark(0, ns, extmarks[0][0])
  call nvim_buf_del_extmark(0, ns, extmarks[1][0])
  " Load children of variable
  let Cb = function('s:CollectVarChildren', [lnum + 1])
  call TermDebugSendMICommand('-var-list-children 1 ' .. s:EscapeMIArgument(varname), Cb)
endfunc

func s:CollectVarChildren(lnum, dict)
  if !has_key(a:dict, "children")
    return
  endif
  let children = s:GetListWithKeys(a:dict, "children")
  " Optimize output by removing indirection
  let ignored = ['public', 'private', 'protected']
  if len(children) == 1 && index(ignored, children[0]['exp']) >= 0
    let Cb = function('s:CollectVarChildren', [a:lnum])
    let name = children[0]['name']
    return TermDebugSendMICommand('-var-list-children 1 ' .. s:EscapeMIArgument(name), Cb)
  endif
  for child in children
    call s:ShowElided(a:lnum, child)
  endfor
endfunc

func s:EndPrinting()
  for varname in s:vars
    call s:SendMICommandNoOutput('-var-delete ' . varname)
  endfor
  let s:vars = []
  let ns = nvim_create_namespace('TermDebugConceal')
  call nvim_buf_clear_namespace(0, ns, 0, -1)
endfunc
"}}}

""""""""""""""""""""""""""""""""Record handlers"""""""""""""""""""""""""""""""{{{
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
  if exists('g:termdebug_no_stream_records') && g:termdebug_no_stream_records
    return
  endif
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
  call nvim_buf_clear_namespace(s:prompt_bufnr, ns, 0, -1)
  if !s:stopped
    let lines = nvim_buf_line_count(s:prompt_bufnr)
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, lines - 1, 0, #{line_hl_group: 'Comment'})
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
    " Display a hint where we stopped
    if exists('g:termdebug_show_source') && g:termdebug_show_source
      call s:PromptShowSourceLine()
    endif
    " Highlight stopped line
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
    call setbufvar("%", '&list', v:false)
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
    if exists('#User#TermDebugRunPost') && !exists('s:program_run_once')
      doauto <nomodeline> User TermDebugRunPost
      let s:program_run_once = v:true
    endif
  endif
endfunc

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(dict)
  let bkpt = a:dict['bkpt']
  if bkpt['type'] != 'breakpoint'
    return
  endif

  if has_key(bkpt, 'pending') && has_key(bkpt, 'number')
    echomsg 'Breakpoint ' . bkpt['number'] . ' (' . bkpt['pending']  . ') pending.'
    return
  endif

  if has_key(bkpt, 'addr') && bkpt['addr'] == '<MULTIPLE>'
    for location in bkpt['locations']
      let id = location['number']
      call s:ClearBreakpointSign(id)
      let s:breakpoints[id] = #{
            \ fullname: get(location, 'fullname', location['addr']),
            \ lnum: get(location, 'line', 1),
            \ enabled: location['enabled'] == 'y' && bkpt['enabled'] == 'y',
            \ parent: bkpt['number']
            \ }
      call s:PlaceBreakpointSign(id)
    endfor
  else
    let id = bkpt['number']
    call s:ClearBreakpointSign(id)
    let s:breakpoints[id] = #{
          \ fullname: get(bkpt, 'fullname', bkpt['addr']),
          \ lnum: get(bkpt, 'line', 1),
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
  elseif a:dict['param'] == 'max-completions'
    let s:max_completions = a:dict['value']
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
    augroup TermDebugCommands
      exe printf("autocmd! WinClosed * call s:OnEditComplete(%d)", a:bp)
    augroup END
  endif
endfunc

func s:OnEditComplete(bp)
  let nr = winbufnr(s:edit_win)
  let commands = getbufline(nr, 1, '$')
  call s:CloseFloatEdit()
  let commands = map(commands, {k, v -> '"' . v . '"'})
  let msg = printf("-break-commands %d %s", a:bp, join(commands, " "))
  call TermDebugSendMICommand(msg, {_ -> s:PromptShowNormal("Breakpoint commands updated")})

  if exists('#TermDebugCommands')
    au! TermDebugCommands
  endif
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
  if bufname() != s:prompt_bufname
    return
  endif

  let context = split(a:cmd, " ", 1)[-1]
  let matches = a:dict['matches']
  call filter(matches, "stridx(v:val, a:cmd) == 0 && v:val != a:cmd")
  call map(matches, "context .. v:val[len(a:cmd):]")
  if len(matches) == 0
    return s:EndCompletion()
  endif

  call s:OpenScrollablePreview("Completion", matches)
  call s:ScrollPreview("1")
  augroup TermDebugCompletion
    autocmd! TextChangedI <buffer> call s:OpenCompletion()
    autocmd! InsertLeave <buffer> call s:EndCompletion()
  augroup END
  " Track this for optimization purposes
  let s:previous_cmd = a:cmd
endfunc

func s:EndCompletion()
  call s:ClosePreview()
  if exists('s:previous_cmd')
    unlet s:previous_cmd
  endif
  if exists('#TermDebugCompletion')
    au! TermDebugCompletion
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

  call deletebufline(s:asm_bufnr, 1, '$')
  if empty(asm_insns)
    call appendbufline(s:asm_bufnr, 0, "No disassembler output")
    return
  endif

  let intro = printf("Disassembly of %s:", asm_insns[0]['func-name'])
  call appendbufline(s:asm_bufnr, 0, intro)

  for asm_ins in asm_insns
    let address = asm_ins['address']
    let offset = asm_ins['offset']
    let inst = asm_ins['inst']
    let line = printf("%s<%d>: %s", address, offset, inst)
    call appendbufline(s:asm_bufnr, "$", line)
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
    call filter(frames, "str2nr(v:val.level) > str2nr(a:level)")
  else
    call filter(frames, "str2nr(v:val.level) < str2nr(a:level)")
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
  if exists('s:edit_win')
    throw s:float_edit_exception
  endif

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
  let s:edit_win = nvim_open_win(nr, v:true, opts)
  call nvim_win_set_option(s:edit_win, 'wrap', v:false)
  return s:edit_win
endfunc

func s:CloseFloatEdit()
  if exists('s:edit_win')
    let nr = winbufnr(s:edit_win)
    call nvim_buf_delete(nr, #{force: 1})
    unlet s:edit_win
  endif
endfunc

func s:OpenPreview(title, lines)
  const max_width = 60
  const max_height = 10

  let sizes = map(copy(a:lines), "len(v:val)")
  call add(sizes, len(a:title))
  let width = min([max(sizes), max_width]) + 1
  let height = min([max([1, len(a:lines)]), max_height])

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
  silent call deletebufline(nr, 1, '$')
  call setbufline(nr, 1, a:lines)
  return s:preview_win
endfunc

func s:OpenScrollablePreview(title, lines)
  let winid = s:OpenPreview(a:title, a:lines)
  if !s:EmptyBuffer(nvim_win_get_buf(winid)) 
    call nvim_win_set_option(winid, 'cursorline', v:true)
    call nvim_win_set_option(winid, 'scrolloff', 2)
  endif
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
  if !exists('s:preview_win')
    return
  endif
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
  return res
endfunc

func s:ClosePreviewOn(...)
  augroup TermDebugPreview
    for event in a:000
      exe printf("autocmd! %s * call s:ClosePreview()", event)
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
  if exists('#TermDebugPreview')
    au! TermDebugPreview
  endif
endfunc
"}}}

""""""""""""""""""""""""""""""""Ending the session""""""""""""""""""""""""""""{{{
func s:EndTermDebug(job_id, exit_code, event)
  if exists('#User#TermDebugStopPre')
    doauto <nomodeline> User TermDebugStopPre
  endif

  silent! autocmd! TermDebug
  silent! autocmd! TermDebugPreview
  silent! autocmd! TermDebugHistory
  silent! autocmd! TermDebugCommands
  silent! autocmd! TermDebugCompletion

  call s:ClosePreview()
  call s:CloseFloatEdit()

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
