" vim: set cc=111 sw=2 ts=2 sts=2 foldmethod=marker et:

" In case this gets sourced twice.
if exists('*PromptDebugStart')
  finish
endif

""""""""""""""""""""""""""""""""Options"""""""""""""""""""""""""""""""""""""""{{{
func s:DefineOption(name, def)
  if !exists(a:name)
    if type(a:def) == v:t_number
      exe printf("let %s = %d", a:name, a:def)
    else
      exe printf("let %s = %s", a:name, string(a:def))
    endif
  endif
endfunc

" Name of the gdb command
call s:DefineOption('g:promptdebugger', 'gdb')

" Whether :commands should be installed
call s:DefineOption('g:promptdebug_commands', 1)

" Custom handling of gdb commands
call s:DefineOption('g:promptdebug_override_finish_and_return', 1)
call s:DefineOption('g:promptdebug_override_up_and_down', 1)
call s:DefineOption('g:promptdebug_override_s_and_n', 1)
call s:DefineOption('g:promptdebug_override_p', 1)
call s:DefineOption('g:promptdebug_override_f_and_bt', 1)
call s:DefineOption('g:promptdebug_override_t', 1)
call s:DefineOption('g:promptdebug_override_info', 1)

" Display source lines when program stops
call s:DefineOption('g:promptdebug_show_source', 1)

" Check if executable is out of date
call s:DefineOption('g:promptdebug_check_timestamps', 1)

" Create an additional terminal which will capture inferior stdout
call s:DefineOption('g:promptdebug_program_output', 1)

" Filter 'info threads' output by displaying jumpable threads only
call s:DefineOption('g:promptdebug_thread_filter', 1)

" Enable binary reverse engineering features.
call s:DefineOption('g:promptdebug_reverse_eng', 1)

" Silently execute unsupported commands. Alternative is to show them in a floating window.
" Enabled by default because it is slightly buggy/annoying.
call s:DefineOption('g:promptdebug_silent_mode', 1)

" Highlights for sign column
hi default link debugPrompt Bold
hi default link debugPC CursorLine
hi default link debugBreakpoint @text.danger
hi default link debugBreakpointDisabled @text.note
hi default link debugJumpable markdownLinkText
hi default link debugExpandable markdownLinkText
hi default link debugIdentifier Italic
hi default link debugLocation Normal
hi default link debugValue markdownCode
hi default link debugMarkedInst Error
"}}}

""""""""""""""""""""""""""""""""Go to"""""""""""""""""""""""""""""""""""""""""{{{
func PromptDebugGoToPC()
  if bufexists(s:source_bufnr)
    exe "b " . s:source_bufnr
    let ns = nvim_create_namespace('PromptDebugPC')
    let pos = nvim_buf_get_extmarks(0, ns, 0, -1, #{})[0]
    call cursor(pos[1] + 1, 0)
  end
endfunc

func PromptDebugGoToBreakpoint(id)
  let id = a:id
  if !has_key(s:breakpoints, id)
    echo "No breakpoint " . id
    return
  endif

  let breakpoint = s:breakpoints[id]
  let lnum = breakpoint['lnum']
  if !has_key(breakpoint, 'fullname')
    echo "No source for " . id
    return
  endif
  let fullname = breakpoint['fullname']
  if expand("%:p") != fullname
    exe "e " . fnameescape(fullname)
  endif
  call cursor(lnum, 0)
endfunc

func PromptDebugPlaceBreakpoint(args)
  if bufnr() == s:asm_bufnr
    let addr = matchstr(getline('.'), '^0x\x\+')
    if !empty(addr)
      let loc = "*" .. addr
    else
      return s:ShowError("Cannot a breakpoint here.")
    endif
  else
    let basename = expand("%:t")
    let lnum = line(".")
    let loc = printf("%s:%d", basename, lnum)
  endif
  let cmd = '-break-insert '
  if has_key(a:args, 'temp') || has_key(a:args, 'until')
    let cmd ..= '-t '
  endif
  if has_key(a:args, 'pending')
    let cmd ..= '-f '
  endif
  if has_key(a:args, 'thread')
    let cmd ..= '-p ' .. s:selected_thread
  endif
  if has_key(a:args, 'disabled')
    let cmd ..= '-d '
  endif
  let cmd ..= s:EscapeMIArgument(loc)
  if has_key(a:args, 'until')
    call s:SendMIChainedNoOutput([cmd, '-exec-continue'])
  else
    let Cb = function('s:HandleNewBreakpoint')
    call s:SendMICommand(cmd, Cb)
  endif
endfunc

func PromptDebugMarkInstruction(inst_pat)
  if !s:asm_mode
    return s:ShowError('Not in assembly mode!')
  endif
  let s:hl_inst = a:inst_pat
  let reg_ns = nvim_create_namespace('PromptDebugRegister')
  for idx in range(nvim_buf_line_count(s:asm_bufnr))
    let line = getbufoneline(s:asm_bufnr, idx + 1)
    let col_idx = stridx(line, ':')
    call assert_true(col_idx > 0)
    let inst = line[col_idx+1:]
    if match(inst, s:hl_inst) >= 0
      let opts = #{end_col: col_idx + 1, hl_group: "debugMarkedInst"}
      call nvim_buf_set_extmark(s:asm_bufnr, reg_ns, idx, 0, opts)
    endif
  endfor
endfunc

func PromptDebugClearMarks()
  let reg_ns = nvim_create_namespace('PromptDebugRegister')
  call nvim_buf_clear_namespace(s:asm_bufnr, reg_ns, 0, -1)
endfunc

func PromptDebugGoToCapture()
  let ids = win_findbuf(s:capture_bufnr)
  if empty(ids)
    exe "tabnew " . s:capture_bufname
  else
    call win_gotoid(ids[0])
  endif
endfunc

func PromptDebugGoToOutput()
  if !exists('s:tty_job_id')
    echo "Program output is disabled."
    return
  endif

  let ids = win_findbuf(s:io_bufnr)
  if empty(ids)
    exe "tabnew " . s:io_bufname
  else
    call win_gotoid(ids[0])
  endif
endfunc

func PromptDebugGoToSource()
  if !win_gotoid(s:sourcewin)
    below new
    let s:sourcewin = win_getid(winnr())
  endif
endfunc

func PromptDebugGoToGdb()
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
func PromptDebugIsOpen()
  if !exists('s:gdb_job_id')
    return v:false
  endif
  silent! return jobpid(s:gdb_job_id) > 0
endfunc

func PromptDebugIsStopped()
  if !exists('s:stopped')
    return v:false
  endif
  return s:stopped
endfunc

func PromptDebugQuit()
  call s:SendMICommandNoOutput('-gdb-exit')
endfunc

func PromptDebugGetPid()
  if !exists('s:pid')
    return 0
  endif
  return s:pid
endfunc

func PromptDebugShowPwd()
  call s:SendMICommand('-environment-pwd', function('s:HandlePwd'))
endfunc

func PromptDebugSendCommand(cmd)
  call s:StopFloatingOutput()
  if PromptDebugIsStopped()
    call s:PromptOutput(a:cmd)
  else
    echo "Cannot send command. Program is running."
  endif
endfunc

func PromptDebugGetHistory()
  return deepcopy(s:command_hist)
endfunc

func PromptDebugGetBreakpoints()
  return deepcopy(s:breakpoints)
endfunc

func PromptDebugGetState()
  return s:
endfunc

func PromptDebugEnableTimings()
  call s:SendMICommandNoOutput('-enable-timings')
endfunc

func PromptDebugPrettyPrinter(regs, func)
  if type(a:regs) == v:t_list
    call add(s:pretty_printers, [a:func] + a:regs)
  else
    echo "Expecting a list of regular expressions as first argument"
  endif
endfunc

func PromptDebugFindSym(func)
  let cmd = '-symbol-info-functions --include-nondebug --max-results 20 --name ' . a:func
  call s:SendMICommand(cmd, function('s:HandleSymbolInfo'))
endfunc

func PromptDebugEvaluate(what)
  let cmd = '-data-evaluate-expression ' .. s:EscapeMIArgument(a:what)
  let Cb = function('s:HandleEvaluate')
  call s:SendMICommand(cmd, Cb)
endfunc

func PromptDebugPrintMICommand(cmd)
  call s:SendMICommand(a:cmd, {dict -> nvim_echo([[string(dict), 'Normal']], 1, #{})})
endfunc
" }}}

""""""""""""""""""""""""""""""""SendMICommand"""""""""""""""""""""""""""""""""{{{
func s:SendMICommand(cmd, Callback)
  let token = s:token_counter
  let s:token_counter += 1
  let s:callbacks[token] = [a:cmd, a:Callback, reltime()]
  let cmd = printf("%d%s", token, a:cmd)
  " Log command to capture buffer
  if s:EmptyBuffer(s:capture_bufnr)
    call setbufline(s:capture_bufnr, 1, '<--- ' .. cmd)
  else
    call appendbufline(s:capture_bufnr, "$", '')
    call appendbufline(s:capture_bufnr, "$", '<--- ' .. cmd)
  endif
  " Send command to GDB
  call chansend(s:gdb_job_id, cmd . "\n")
endfunc

func s:SendMIChained(cmds, Callback)
  if len(a:cmds) == 1
    let Cb = a:Callback
  else
    let Cb = {-> s:SendMIChained(a:cmds[1:], a:Callback)}
  endif
  call s:SendMICommand(a:cmds[0], Cb)
endfunc

function s:SendMICommandNoOutput(cmd)
  let IgnoreOutput = {_ -> {}}
  return s:SendMICommand(a:cmd, IgnoreOutput)
endfunction

func s:SendMIChainedNoOutput(cmds)
  let IgnoreOutput = {_ -> {}}
  return s:SendMIChained(a:cmds, IgnoreOutput)
endfunc

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

func s:SwitchAsmMode(asm_mode)
  if s:asm_mode != a:asm_mode
    let s:asm_mode = a:asm_mode
    call s:ClearCursorSign()
  endif
endfunc
"}}}

""""""""""""""""""""""""""""""""Launching GDB"""""""""""""""""""""""""""""""""{{{
let s:command_hist = []

func PromptDebugStart(...)
  if PromptDebugIsOpen()
    echo 'Terminal debugger already running, cannot run two'
    return v:false
  endif
  if !executable(g:promptdebugger)
    echo 'Cannot execute debugger program "' .. g:promptdebugger .. '"'
    return v:false
  endif

  if exists('#User#PromptDebugStartPre')
    doauto <nomodeline> User PromptDebugStartPre
  endif

  " Remove all prior variables
  let persistent_vars = ["command_hist", "user_saved_brs", "auto_saved_brs"]
  for varname in keys(s:)
    if index(persistent_vars, varname) < 0
      exe "silent! unlet s:" . varname
    endif
  endfor

  " Names for created buffers
  const s:capture_bufname = "Gdb capture"
  const s:asm_bufname = "Gdb disas"
  const s:prompt_bufname = "Gdb terminal"
  const s:io_bufname = "Program output"
  let s:bufvars = ["capture_bufname", "asm_bufname", "prompt_bufname", "io_bufname"]
  " Exceptions thrown
  const s:eval_exception = "EvalFailedException"
  " Custom pretty printers (can be expanded by user)
  let s:pretty_printers = [
        \ ['s:PrettyPrinterVector', 'std::vector'],
        \ ['s:PrettyPrinterString', 'std::string', 'std::__cxx11::basic_string<char'],
        \ ['s:PrettyPrinterFilesystem', 'std::filesystem::path'],
        \ ['s:PrettyPrinterOptional', 'std::optional'],
        \ ['s:PrettyPrinterUniquePtr', 'std::unique_ptr'],
        \ ['s:PrettyPrinterSharedPtr', 'std::shared_ptr'],
        \ ['s:PrettyPrinterSharedCount', 'std::_Sp_counted_deleter'],
        \ ['s:PrettyPrinterAtomicInt', 'std::atomic_int', 'std::atomic_uint'],
        \ ['s:PrettyPrinterAtomicBool', 'std::atomic_bool'],
        \ ['s:PrettyPrinterBitset', 'std::bitset'],
        \ ['s:PrettyPrinterFunction', 'std::function'],
        \ ['s:PrettyPrinterThread', 'std::thread'],
        \ ['s:PrettyPrinterPair', 'std::pair'],
        \ ]
  " Set defaults for required variables
  let s:vars = #{}
  let s:thread_ids = #{}
  let s:breakpoints = #{}
  let s:libraries = #{}
  let s:multi_brs = #{}
  let s:callbacks = #{}
  let s:files_warned = #{}
  let s:hl_inst = ''
  let s:floating_output = 0
  let s:source_bufnr = -1
  let s:stopped = 1
  let s:asm_mode = 0
  let s:sourcewin = win_getid()
  let s:comm_buf = ""
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
  return s:LaunchGdbAndTerminal()
endfunc

func s:LaunchGdbAndTerminal()
  if g:promptdebug_program_output
    " Open terminal controlling inferior i/o
    sp
    enew
    setlocal nobuflisted
    if !exists("s:host")
      let s:tty_job_id = termopen("tail -f /dev/null", #{on_stdout: function('s:ProgramOutput')})
      let tty = nvim_get_chan_info(s:tty_job_id)['pty']
      quit
      call s:LaunchGdb(tty)
    else
      let cmd = ["ssh", "-t", s:host, "tty; tail -f /dev/null"]
      let s:tty_job_id = termopen(cmd, #{on_stdout: function('s:ProgramOutput')})
      " Wait for terminal to be resolved...
      quit
    endif
  else
    call s:LaunchGdb("/dev/null")
  endif
endfunc

func s:LaunchGdb(tty)
  let gdb_cmd = [g:promptdebugger]
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  call add(gdb_cmd, '-quiet')
  " Communicate with GDB in the background via MI interface
  call add(gdb_cmd, '--interpreter=mi')
  " Disable pagination, it causes everything to stop
  call extend(gdb_cmd, ['-iex', 'set pagination off'])
  " Ignore inferior stdout 
  call extend(gdb_cmd, ['-iex', 'set inferior-tty ' .. a:tty])
  " Remove the (gdb) prompt
  call extend(gdb_cmd, ['-iex', 'set prompt'])
  " Limit completions for faster autocomplete
  call extend(gdb_cmd, ['-iex', 'set max-completions ' . s:max_completions])
  " Disable shell on remote where support might be limited
  let use_shell = exists("s:host") ? "off" : "on"
  call extend(gdb_cmd, ['-iex', 'set startup-with-shell ' .. use_shell])
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
        \ 'on_exit': function('s:EndPromptDebug'),
        \ 'pty': v:false
        \ })
  if s:gdb_job_id == 0
    echo 'Invalid argument (or job table is full) while opening gdb terminal window'
    return v:false
  elseif s:gdb_job_id == -1
    echo 'Failed to open the gdb terminal window'
    return v:false
  endif

  " Open the prompt window
  exe "above sp " . s:prompt_bufname
  call setbufvar(bufnr(), '&list', v:false)
  call setbufvar(bufnr(), '&so', 0)
  call matchadd('debugPrompt', '^(gdb)')
  call prompt_setprompt(bufnr(), '(gdb) ')
  call prompt_setcallback(bufnr(), function('s:PromptOutput'))

  augroup PromptDebug
    autocmd! BufModifiedSet <buffer> noautocmd setlocal nomodified
  augroup END

  inoremap <buffer> <C-d> <cmd>call PromptDebugQuit()<CR>
  inoremap <buffer> <C-c> <cmd>call <SID>CtrlC_Map()<CR>
  inoremap <buffer> <expr> <C-w> <SID>CtrlW_Map()
  inoremap <buffer> <expr> <C-l> "<C-o>zt"
  inoremap <buffer> <C-n> <cmd>call <SID>ScrollPreview("+1")<CR>
  inoremap <buffer> <C-p> <cmd>call <SID>ScrollPreview("-1")<CR>
  inoremap <buffer> <C-y> <cmd>call <SID>AcceptPreview()<CR>
  inoremap <buffer> <Up> <cmd>call <SID>ArrowMap("-1")<CR>
  inoremap <buffer> <Down> <cmd>call <SID>ArrowMap("+1")<CR>
  inoremap <buffer> <Tab> <cmd>call <SID>TabMap("+1")<CR>
  inoremap <buffer> <S-Tab> <cmd>call <SID>TabMap("-1")<CR>
  inoremap <buffer> <CR> <cmd>call <SID>EnterMap()<CR>
  nnoremap <buffer> <CR> <cmd>call <SID>ExpandCursor(line('.'))<CR>

  " Issue autocmds
  if exists('#User#PromptDebugStartPost')
    doauto <nomodeline> User PromptDebugStartPost
  endif

  startinsert
endfunc

func s:CreateSpecialBuffers()
  for bufvar in s:bufvars
    let bufname = s:[bufvar]
    let nr = bufnr(bufname)
    if nr > 0
      exe "bwipe! " . nr
    endif
    let nr = bufadd(bufname)
    " Add a corresponding '_bufnr' variable as well for convenience
    let number_var = substitute(bufvar, 'bufname', 'bufnr', '')
    let s:[number_var] = nr

    call setbufvar(nr, "&buftype", "nofile")
    call setbufvar(nr, "&swapfile", 0)
    call setbufvar(nr, "&buflisted", 1)
    call setbufvar(nr, "&wrap", 0)
    call setbufvar(nr, "&modifiable", 1)
    call bufload(nr)
  endfor

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

func s:ProgramOutput(job_id, msgs, event)
  for msg in a:msgs
    let msg = substitute(msg, '\r\n\?$', '', 'g')
    let msg = substitute(msg, '\e\[[0-9;]*m', '', 'g')
    if empty(msg) || msg[0:1] == '&"'
      continue
    endif
    if !exists('s:gdb_job_id') && msg =~# '/dev/pts/[0-9]\+'
      let tty = msg
      if exists('s:user')
        call system(["ssh", s:host, "chmod", "666", tty])
        if v:shell_error
          call s:ShowWarning("Failed to change permissions for controlling tty.")
        endif
      endif
      call s:LaunchGdb(tty)
    else
      if s:EmptyBuffer(s:io_bufnr)
        call setbufline(s:io_bufnr, 1, msg)
      else
        call appendbufline(s:io_bufnr, "$", msg)
      endif
    endif
  endfor
endfunc

func s:CommReset(timer_id)
  let s:comm_buf = ""
  call s:ShowWarning("Communication with GDB reset")
endfunc

func s:CommJoin(job_id, msgs, event)
  " Only not exact when EvalFailedException is thrown, which is
  " 1) Rare.
  " 2) Outside the control of this plugin.
  let then = reltime()
  for msg in a:msgs
    " Append to capture buf
    if !empty(msg) && msg != '(gdb) '
      if s:EmptyBuffer(s:capture_bufnr)
        call setbufline(s:capture_bufnr, 1, strtrans(msg))
      else
        call appendbufline(s:capture_bufnr, "$", strtrans(msg))
      endif
    endif
    " Process message
    let msg = s:comm_buf .. msg
    try
      call s:CommOutput(then, msg)
      let s:comm_buf = ""
      if exists('s:comm_timer')
        call timer_stop(s:comm_timer)
        unlet s:comm_timer
      endif
    catch /EvalFailedException/
      let s:comm_buf = msg
      if !exists('s:comm_timer')
        " Vim has not passed enough data in this invocation. Wait for a maximum of 4 seconds and accumulate
        " messages
        let s:comm_timer = timer_start(4000, function('s:CommReset'))
      endif
    endtry
  endfor
endfunc

func s:EmptyBuffer(nr)
  return nvim_buf_line_count(a:nr) == 1 && empty(nvim_buf_get_lines(a:nr, 0, 1, v:true)[0])
endfunc

func s:CtrlC_Map()
  if !empty(s:GetPrompt())
    let input = getbufline(s:prompt_bufnr, '$')[0]
    call s:ShowMessage([[input, "Normal"], ["^C", "Cursor"]])
    call s:SetPrompt("")
  elseif exists('s:pid')
    " Send interrupt
    let interrupt = 2
    if !exists('s:host')
      let pid = jobpid(s:gdb_job_id)
      call v:lua.vim.loop.kill(pid, interrupt)
    else
      let kill = printf("kill -%d %d", interrupt, s:pid)
      call system(["ssh", s:host, kill])
    endif
  else
    call s:ShowError("Program is not started")
  endif
endfunc

func s:CtrlW_Map()
  let [cmd_pre, cmd_post] = s:GetPrompt(2)
  let n = len(matchstr(cmd_pre, '\S*\s*$'))
  return repeat("\<BS>", n)
endfunc

func s:TabMap(expr)
  if s:IsOpenPreview('Completion') || s:IsOpenPreview('History')
    call s:ScrollPreview(a:expr)
  elseif empty(s:GetPrompt())
    call s:OpenHistory()
  else
    call s:OpenCompletion()
  endif
endfunc

func s:OpenHistory()
  if !empty(s:command_hist)
    call s:OpenScrollablePreview("History", copy(s:command_hist))
    call s:ScrollPreview("$")
    call s:ClosePreviewOn('InsertLeave', 'CursorMovedI')
  endif
endfunc

func s:OpenCompletion()
  let cmd = s:GetPrompt()
  let context = split(cmd, " ", 1)[-1]
  " If possible, avoid asking GDB about completions
  if s:IsOpenPreview('Completion')
    let nr = nvim_win_get_buf(s:preview_win)
    if nvim_buf_line_count(nr) < s:max_completions
      if stridx(cmd, s:previous_cmd) == 0 && cmd[-1:-1] !~ '\s'
        let matches = filter(getbufline(nr, 1, '$'), 'stridx(v:val, context) == 0')
        " Just refresh the preview
        if empty(matches)
          call s:EndCompletion()
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
  call s:SendMICommand('-complete ' . s:EscapeMIArgument(cmd), Cb)
endfunc

func s:ArrowMap(expr)
  if s:IsOpenPreview('Completion') || s:IsOpenPreview('History')
    return s:ScrollPreview(a:expr)
  endif
  if empty(s:command_hist)
    return
  endif
  " Quickly scroll history (no window)
  if a:expr == '-1'
    if !exists('s:command_hist_idx')
      let s:command_hist_idx = len(s:command_hist)
      call add(s:command_hist, s:GetPrompt())
      augroup PromptDebugHistory
        autocmd! InsertLeave * call s:EndHistory(v:false)
        autocmd! CursorMovedI * call s:EndHistory(v:true)
      augroup END
    endif
    let s:command_hist_idx = max([s:command_hist_idx - 1, 0])
  elseif a:expr == '+1'
    if !exists('s:command_hist_idx')
      return ''
    endif
    let s:command_hist_idx = min([s:command_hist_idx + 1, len(s:command_hist) - 1])
  endif
  return s:SetPrompt(s:command_hist[s:command_hist_idx])
endfunc

func s:EndHistory(allow_drift)
  call s:ClosePreview()
  if !exists('s:command_hist_idx')
    return
  endif
  let [lhs, rhs] = s:GetPrompt(2)
  if a:allow_drift && empty(rhs) && lhs .. rhs == s:command_hist[s:command_hist_idx]
    " Cursor is positioned at the correct position and the command is the same.
    return
  endif
  call remove(s:command_hist, -1)
  unlet s:command_hist_idx
  au! PromptDebugHistory
endfunc

func s:AcceptPreview()
  if s:IsOpenPreview('Completion')
    let completion = s:GetPreviewLine('.')
    let cmd_parts = split(s:GetPrompt(), " ", 1)
    let cmd_parts[-1] = completion
    call s:SetPrompt(join(cmd_parts, " "))
    call s:EndCompletion()
  elseif s:IsOpenPreview('History')
    call s:SetPrompt(s:GetPreviewLine('.'))
    call s:EndHistory(v:false)
  endif
endfunc

func s:EnterMap()
  if s:IsOpenPreview('Completion') || s:IsOpenPreview('History')
    return s:AcceptPreview()
  endif

  call s:EndHistory(v:false)
  call s:EndCompletion()
  call s:EndPrinting()

  if !PromptDebugIsStopped()
    return
  endif
  let cmd = s:GetPrompt()
  call s:ShowNormal(getline('$'))
  call s:SetPrompt('')
  if cmd =~ '\S'
    " Add to history and run command
    call add(s:command_hist, cmd)
    call s:PromptOutput(cmd)
  else
    " Rerun last command
    if !empty(s:command_hist)
      let cmd = get(s:command_hist, -1, "")
      call s:PromptOutput(cmd)
    endif
  endif
endfunc

func s:GetPrompt(...)
  let line = getbufline(s:prompt_bufnr, '$')[0]
  let offset = len(prompt_getprompt(s:prompt_bufnr))
  let parts = get(a:000, 0, 1)
  if parts == 1
    return line[offset:]
  else
    let col = getcurpos()[2] - 1
    return [line[offset:col-1], line[col:]]
  endif
endfunc

func s:SetPrompt(cmd)
  let prompt = prompt_getprompt(s:prompt_bufnr)
  let line = prompt .. a:cmd
  call setbufline(s:prompt_bufnr, '$', line)
  call cursor('$', len(line) + 1)
endfunc
" }}}

""""""""""""""""""""""""""""""""PromptDebugStart""""""""""""""""""""""""""""""{{{
function! s:CmdlineCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let parts = split(a:CmdLine, '\s', 1)
  if len(parts) == 2
    " Exe completion
    let pat = ".*" . a:ArgLead . ".*"
    let cmd = ["find", ".", "(", "-path", "**/.git", "-prune", "-false", "-o", "-regex", pat, ")"]
    let cmd += ["-type", "f", "-executable", "-printf", "%P\n"]
    let compl = systemlist(cmd)
    return v:shell_error ? [] : compl
  elseif get(parts, -2, '') == '<'
    " Filename completion
    let root = fnamemodify(a:ArgLead, ':h')
    let cmd_pre = printf('find %s -maxdepth 1 -mindepth 1', root)
    if fnamemodify(a:ArgLead, ':t') == a:ArgLead
      let cmd_post = '-printf "%P\n"'
    else
      let cmd_post = ''
    endif
    let dirs = systemlist(cmd_pre .. " -type d " .. cmd_post)
    if v:shell_error
      return []
    endif
    let dirs = map(dirs, 'v:val .. "/"')
    let files = systemlist(cmd_pre .. " -type f " .. cmd_post)
    if v:shell_error
      return []
    endif
    return filter(dirs + files, 'stridx(v:val, a:ArgLead) == 0')
  endif
  return []
endfunction

func s:InterpreterExec(cmd)
  let msg = '-interpreter-exec console ' .. s:EscapeMIArgument(a:cmd)
  call s:SendMICommandNoOutput(msg)
endfunc

func s:StartLocally(str_args)
  if PromptDebugStart()
    let cmd_args = split(a:str_args, '\s')
    if len(cmd_args) >= 1
      call s:InterpreterExec("file " .. cmd_args[0])
      call s:InterpreterExec("start " .. join(cmd_args[1:]))
    endif
  endif
endfunc

func s:RunLocally(str_args)
  let filename = expand("%:t")
  let lnum = line('.')

  if !PromptDebugStart()
    return
  endif
  let cmd_args = split(a:str_args, '\s')
  if len(cmd_args) <= 0
    return
  endif
  call s:InterpreterExec("file " .. cmd_args[0])
  " Add a breakpoint with the current cursor position
  if !empty(filename)
    let br = printf("tbr %s:%d", filename, lnum)
    call s:InterpreterExec(br)
  endif
  call s:InterpreterExec("run " .. join(cmd_args[1:]))
endfunc

function! s:AttachCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  if len(split(a:CmdLine, '\s', 1)) > 2
    return []
  endif

  let cmdlines = systemlist(["ps", "h", "-U", $USER, "-o", "command"])
  let compl = []
  for cmdline in cmdlines
    let name = split(cmdline, " ")[0]
    if executable(name) && stridx(name, a:ArgLead) >= 0
      call add(compl, name)
    endif
  endfor
  let compl = uniq(sort(compl))
  return compl
endfunction

func s:AttachLocally(proc)
  " Resolve to pid
  if str2nr(a:proc) != 0
    let pid = a:proc
  else
    let pids = systemlist(["pgrep", "-f", a:proc])
    if len(pids) == 0
      echo "No processes found"
      return
    elseif len(pids) > 1
      echo "Multiple processes found, specify pid"
      return
    endif
    let pid = pids[0]
  endif
  call PromptDebugStart()
  call s:InterpreterExec("attach " .. pid)
endfunc

if g:promptdebug_commands
  command -nargs=? -complete=customlist,s:CmdlineCompl PromptDebugStart call s:StartLocally(<q-args>)
  command -nargs=? -complete=customlist,s:CmdlineCompl PromptDebugRun call s:RunLocally(<q-args>)
  command -nargs=? -complete=customlist,s:AttachCompl PromptDebugAttach call s:AttachLocally(<q-args>)
  command -nargs=0 Source call PromptDebugGoToSource()
  command -nargs=0 Gdb call PromptDebugGoToGdb()
  command -nargs=0 Output call PromptDebugGoToOutput()
endif
" }}}

""""""""""""""""""""""""""""""""Custom commands"""""""""""""""""""""""""""""""{{{
func s:IsCommand(str, req, len)
  return stridx(a:req, a:str) == 0 && len(a:str) >= a:len
endfunc

func s:PromptOutput(cmd)
  if empty(a:cmd)
    return
  endif

  let cmd = split(a:cmd, " ")
  let name = cmd[0]

  " Special commands (HEREDOC input)
  if name->s:IsCommand("commands", 3)
    return s:CommandsCommand(cmd[1:])
  endif

  " Unsupported commands
  if name->s:IsCommand("python", 2)
    return s:ShowError("No python support!")
  elseif name[0] == "!" || name->s:IsCommand("shell", 3)
    return s:ShowError("No shell support!")
  elseif name->s:IsCommand("edit", 2)
    return s:ShowError("No edit support!")
  endif

  " Custom commands
  if name == "brsave"
    return s:SaveBreakpoints('user_saved_brs')
  elseif name == "brsource"
    if exists('s:user_saved_brs')
      return s:RestoreBreakpoints('user_saved_brs')
    elseif exists('s:auto_saved_brs')
      return s:RestoreBreakpoints('auto_saved_brs')
    else
      return s:ShowError("No breakpoints from previous are saved!")
    endif
  endif

  " Overriding GDB commands
  if g:promptdebug_override_finish_and_return
    if name->s:IsCommand("finish", 3) || name->s:IsCommand("return", 3)
      return s:FinishCommand()
    endif
  endif
  if g:promptdebug_override_up_and_down
    if name == "up"
      return s:UpCommand()
    elseif name == "down"
      return s:DownCommand()
    endif
  endif
  if g:promptdebug_override_s_and_n
    if name == "asm"
      return s:AsmCommand()
    elseif name == "si" || name == "stepi"
      call s:SwitchAsmMode(1)
      return s:SendMICommandNoOutput('-exec-step-instruction')
    elseif name == "ni" || name == "nexti"
      call s:SwitchAsmMode(1)
      return s:SendMICommandNoOutput('-exec-next-instruction')
    elseif name == "s" || name == "step"
      call s:SwitchAsmMode(0)
      return s:SendMICommandNoOutput('-exec-step')
    elseif name == "n" || name == "next"
      call s:SwitchAsmMode(0)
      return s:SendMICommandNoOutput('-exec-next')
    endif
  endif
  if g:promptdebug_override_p
    if cmd[0] == "p" || cmd[0][:1] == 'p/' ||
          \ cmd[0] == "print" || cmd[0][:5] == 'print/'
      return s:PrintCommand(cmd[0], join(cmd[1:], " "))
    endif
  endif
  if g:promptdebug_override_f_and_bt
    if cmd[0]->s:IsCommand("frame", 1)
      return s:FrameCommand(get(cmd, 1, ''))
    elseif cmd[0] == "bt" || cmd[0]->s:IsCommand("backtrace", 1)
      return s:BacktraceCommand(get(cmd, 1, ''))
    elseif cmd[0]->s:IsCommand("where", 3)
      return s:WhereCommand()
    endif
  endif
  if g:promptdebug_override_t
    if cmd[0]->s:IsCommand("thread", 1)
      return s:ThreadCommand(get(cmd, 1, ''))
    endif
  endif

  if g:promptdebug_override_info
    if cmd[0]->s:IsCommand("info", 3)
      if len(cmd) == 1
        return s:InfoCommand()
      endif
      if cmd[1]->s:IsCommand("threads", 2)
        return s:InfoThreadsCommand(get(cmd, 2, ''))
      elseif cmd[1]->s:IsCommand("breakpoints", 1)
        return s:InfoBreakpointsCommand(get(cmd, 2, ''))
      elseif cmd[1]->s:IsCommand("stack", 1) || cmd[1] == 's'
        return s:BacktraceCommand(get(cmd, 2, ''))
      elseif cmd[1]->s:IsCommand('locals', 2)
        return s:InfoLocalsCommand(get(cmd, 2, ''))
      elseif cmd[1]->s:IsCommand('args', 2)
        return s:InfoArgsCommand(get(cmd, 2, ''))
      elseif cmd[1]->s:IsCommand('variables', 2)
        return s:InfoVarsCommand()
      elseif cmd[1]->s:IsCommand('symbol', 2)
        return s:PrintCommand("p", join(cmd[2:]))
      endif
    endif
  endif

  if cmd[0]->s:IsCommand("show", 3)
    return s:ShowCommand(join(cmd[1:]))
  elseif cmd[0]->s:IsCommand("set", 3)
    return s:SetCommand(join(cmd[1:]))
  endif

  if g:promptdebug_reverse_eng
    if cmd[0] == "bl" || cmd[0] == "cl"
      return s:ContinueLinkCommand()
    elseif cmd[0]->s:IsCommand("mount", 3)
      return s:MountCommand(cmd[1:])
    elseif cmd[0]->s:IsCommand("maps", 3)
      if cmd[1] == "find"
        return s:MapFindCommand(cmd[2:])
      else
        return s:MapsCommand(cmd[1:])
      endif
    elseif cmd[0] == 'lsof'
      return s:FileDescriptorsCommand()
    endif
  endif

  " Good 'ol GDB commands
  let cmd_console = '-interpreter-exec console ' . s:EscapeMIArgument(a:cmd)
  if g:promptdebug_silent_mode
    " Run silently and report errors only.
    return s:SendMICommandNoOutput(cmd_console)
  else
    " Run command and redirect output to floating window
    let s:floating_output = 1
    return s:SendMICommand(cmd_console, function('s:StopFloatingOutput'))
  endif
endfunc

func s:StopFloatingOutput(...)
  let s:floating_output = 0
endfunc

func s:CommandsCommand(brs)
  if len(a:brs) > 1
    return s:ShowError("Expecting 1 breakpoint at most.")
  endif
  if empty(a:brs)
    let bp = string(max(keys(s:breakpoints)))
  else
    let bp = a:brs[0]
  endif
  if !has_key(s:breakpoints, bp)
    call s:ShowError("Cannot set commands for breakpoint " .. bp)
  else
    let script = s:Get(s:breakpoints, bp, 'script', [])
    call s:OpenFloatEdit(30, 3, script)
    augroup PromptDebugFloatEdit
      exe printf("autocmd! WinClosed * call s:OnEditComplete(%d)", bp)
    augroup END
    $ " Go to end of float window
  endif
endfunc

func s:SaveBreakpoints(where)
  let valid_brs = filter(values(s:breakpoints), 'has_key(v:val, "fullname")')
  if empty(valid_brs)
    return s:ShowError("No breakpoints.")
  endif
  let saved_br_locs = map(copy(valid_brs), 'v:val.fullname .. ":" .. v:val.lnum')
  let saved_br_cmds = map(valid_brs, 'get(v:val, "script", [])')
  let s:[a:where] = [saved_br_locs, saved_br_cmds]
endfunc

func s:RestoreBreakpoints(where)
  let br_state = get(s:, a:where, [])
  if empty(br_state)
    return s:ShowError("No breakpoints are saved!")
  endif
  let locs = br_state[0]
  let cmds = br_state[1]
  for idx in range(len(locs))
    let Cb = function('s:HandleRestoredBreakpoint', [cmds[idx]])
    call s:SendMICommand("-break-insert " .. s:EscapeMIArgument(locs[idx]), Cb)
  endfor
  call s:ShowNormal("Inserted " .. len(locs) .. " breakpoint(s).")
endfunc

func s:ContinueLinkCommand()
  if !exists('s:lr_wpt_number')
    call s:ShowNormal("A special watchpoint is going to be inserted to service the request.")
    call s:SendMICommand('-break-watch $x30', function('s:HandleLinkRegisterWatch'))
  else
    call s:ContinueToLinkRegister()
  endif
endfunc

func s:ContinueToLinkRegister()
  let cmds = []
  call add(cmds, '-break-enable ' .. s:lr_wpt_number)
  call add(cmds, '-gdb-set scheduler-locking on')
  call add(cmds, '-exec-continue')
  call add(cmds, '-gdb-set scheduler-locking ' .. s:scheduler_locking)
  call s:SendMIChainedNoOutput(cmds)
endfunc

func s:MountCommand(arg)
  let arg = join(a:arg)
  let cmd = printf('-stack-list-frames --thread %d', s:selected_thread)
  call s:SendMICommand(cmd, function('s:HandleFrameMount', [arg]))
endfunc

func s:GetMaps()
  let pid = PromptDebugGetPid()
  if pid <= 0
    call s:ShowError('No pid!')
    return []
  endif
  let cmd = printf("cat /proc/%d/maps", pid)
  if exists('s:host')
    let cmd = ["ssh", s:host, cmd]
  endif
  let lines = systemlist(cmd)
  return v:shell_error ? [] : lines
endfunc

func s:MapsCommand(arg)
  let pat = join(a:arg)
  let lines = s:GetMaps()
  call filter(lines, 'stridx(v:val, pat) >= 0')
  for line in lines
    call s:ShowNormal(line)
  endfor
endfunc

func s:FileDescriptorsCommand()
  let pid = PromptDebugGetPid()
  if pid <= 0
    call s:ShowError('No pid!')
    return []
  endif
  let cmd = printf('ls /proc/%d/fd', pid)
  if exists('s:host')
    let cmd = ["ssh", s:host, cmd]
  endif
  if v:shell_error
    return s:ShowError("Command failed!")
  endif
  let fds = systemlist(cmd)
  call sort(fds, 'N')

  let cmd = 'readlink -f'
  for fd in fds
    let cmd ..= printf(' /proc/%d/fd/%s', pid, fd)
  endfor
  if exists('s:host')
    let cmd = ["ssh", s:host, cmd]
  endif
  let followed = systemlist(cmd)
  if v:shell_error
    return s:ShowError("Command failed!")
  endif
  for i in range(len(fds))
    call s:ShowNormal(printf('%s: %s', fds[i], followed[i]))
  endfor
endfunc

func s:MapFindCommand(expr)
  let expr = join(a:expr)
  let Cb = function('s:HandleMapFindVar')
  call s:SendMICommand('-var-create - * ' . s:EscapeMIArgument(a:expr), Cb)
endfunc

func s:FinishCommand()
  let cmds = []
  call add(cmds, '-gdb-set scheduler-locking on')
  call add(cmds, '-exec-finish')
  call add(cmds, '-gdb-set scheduler-locking ' .. s:scheduler_locking)
  call s:SendMIChainedNoOutput(cmds)
endfunc

func s:UpCommand()
  call s:SendMICommand('-stack-list-frames', function('s:HandleFrameChange', [v:true]))
endfunc

func s:DownCommand()
  call s:SendMICommand('-stack-list-frames', function('s:HandleFrameChange', [v:false]))
endfunc

func s:AsmCommand()
  call s:SwitchAsmMode(s:asm_mode ? 0 : 1)
  call s:WhereCommand()
endfunc

func s:FrameCommand(level)
  let level = empty(a:level) ? s:selected_frame : a:level
  let cmd = printf('-stack-info-frame --frame %d --thread %d', level, s:selected_thread)
  call s:SendMICommand(cmd, function('s:HandleFrameJump', [level]))
endfunc

func s:BacktraceCommand(max_levels)
  if !empty(a:max_levels)
    call s:SendMICommand('-stack-list-frames 0 ' .. a:max_levels, function('s:HandleFrameList'))
  else
    call s:SendMICommand('-stack-list-frames', function('s:HandleFrameList'))
  endif
endfunc

func s:WhereCommand()
  let cmd = printf('-stack-info-frame --thread %d --frame %d', s:selected_thread, s:selected_frame)
  call s:SendMICommand(cmd, {dict -> s:PlaceCursorSign(dict['frame'])})
endfunc

func s:ThreadCommand(id)
  let Cb = function('s:HandleThreadSelect')
  call s:SendMICommand('-thread-select ' .. s:EscapeMIArgument(a:id), Cb)
endfunc

func s:InfoThreadsCommand(filter)
  let ids = sort(keys(s:thread_ids), 'N')
  for id in ids
    if !empty(a:filter)
      let Cb = function('s:HandleThreadFilter', [id, a:filter])
    else
      let Cb = function('s:HandleThreadStack', [id])
    endif
    call s:SendMICommand('-stack-list-frames --thread ' .. id, Cb)
  endfor
endfunc

func s:ParseFlags(str, flags)
  let str = a:str
  let res = #{}
  while !empty(str)
    if !has_key(a:flags, str[0])
      return #{error: "Unknown flag " .. str[0]}
    endif
    let flag_name = str[0]
    let str = str[1:]
    let flag_args = a:flags[flag_name]
    if len(str) < flag_args
      return #{error: printf("Flag %s expects %d arguments", flag_name, flag_args)}
    endif
    let res[flag_name] = str[:flag_args-1]
    let str = str[flag_args:]
  endwhile
  return res
endfunc

func s:InfoBreakpointsCommand(id)
  if !empty(a:id)
    let Cb = function('s:HandleBreakpointTable', [v:true])
    call s:SendMICommand('-break-info ' .. a:id, Cb)
  else
    let Cb = function('s:HandleBreakpointTable', [v:false])
    call s:SendMICommand('-break-info', Cb)
  endif
endfunc

func s:InfoLocalsCommand(pat)
  let Cb = function('s:HandleStackVariables', ["0", a:pat])
  call s:SendMICommand('-stack-list-variables --no-frame-filters --skip-unavailable --no-values', Cb)
endfunc

func s:InfoArgsCommand(pat)
  let Cb = function('s:HandleStackVariables', ["1", a:pat])
  call s:SendMICommand('-stack-list-variables --no-frame-filters --no-values', Cb)
endfunc

func s:InfoVarsCommand()
  let msg = "Command is disabled because it is slow."
  let msg ..= " Did you mean 'info locals' or 'info args'?"
  call s:ShowError(msg)
endfunc

func s:ShowCommand(what)
  call s:SendMICommand('-gdb-show ' .. a:what, function('s:HandleShow', [0]))
endfunc

func s:SetCommand(what)
  call s:SendMICommandNoOutput('-gdb-set ' .. a:what)
endfunc

func s:InfoCommand()
  call s:ShowNormal("Current overrides are in place:")
  let enabled = [["Disabled", "DiagnosticError"], ["OK", "DiagnosticOk"]]

  let feature = ["  brsave and brsource to reuse breakpoints between sessions: ", "Normal"]
  call s:ShowMessage([feature, enabled[v:true]])
  let feature = ["  finish and return are locked to the same thread: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_finish_and_return]])
  let feature = ["  up and down skip frames with no symbols: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_up_and_down]])
  let feature = ["  stepping switches between assembly and source: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_s_and_n]])
  let feature = ["  print via expansion: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_p]])
  let feature = ["  frame and backtrace with jumps: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_f_and_bt]])
  let feature = ["  thread with jumps: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_t]])
  let feature = ["  info (partial): ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_override_info]])
  let feature = ["  Enable reverse engineering commands: ", "Normal"]
  call s:ShowMessage([feature, enabled[g:promptdebug_reverse_eng]])

  call s:ShowNormal("Current options are set:")
  let option = ["  Execute unsupported commands silently: ", "Normal"]
  call s:ShowMessage([option, enabled[g:promptdebug_silent_mode]])
  let option = ["  Display source tags when program stops: ", "Normal"]
  call s:ShowMessage([option, enabled[g:promptdebug_show_source]])
  let option = ["  Check if executable is out-of-date: ", "Normal"]
  call s:ShowMessage([option, enabled[g:promptdebug_check_timestamps]])
  let option = ["  Capture stdout in a buffer: ", "Normal"]
  call s:ShowMessage([option, enabled[g:promptdebug_program_output]])
  let option = ["  Filter 'info threads' with jumpable threads only: ", "Normal"]
  call s:ShowMessage([option, enabled[g:promptdebug_thread_filter]])
endfunc
" }}}

""""""""""""""""""""""""""""""""Printing""""""""""""""""""""""""""""""""""""""{{{
func s:ShowMessage(msg)
  let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
  call s:AppendMessage(lnum, a:msg)
endfunc

func s:AppendMessage(lnum, msg)
  let line = join(map(copy(a:msg), "v:val[0]"), '')
  call appendbufline(s:prompt_bufnr, a:lnum, line)

  let ns = nvim_create_namespace('PromptDebugHighlight')
  let end_col = 0
  for [msg, hl_group] in a:msg
    let start_col = end_col
    let end_col = start_col + len(msg)
    if end_col > start_col
      let opts = #{end_col: end_col, hl_group: hl_group}
      call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, start_col, opts)
    endif
  endfor
endfunc

func s:ShowNormal(msg)
  call s:ShowMessage([[a:msg, "Normal"]])
endfunc

func s:ShowWarning(msg)
  call s:ShowMessage([[a:msg, "WarningMsg"]])
endfunc

func s:ShowError(msg)
  call s:ShowMessage([[a:msg, "ErrorMsg"]])
endfunc

func s:ShowSourceLine(tag_string)
  let lnum = line('.')
  let source_line = getline(lnum)
  let leading_spaces = len(matchstr(source_line, '^\s*'))
  " Copy source line with syntax
  let text = ""
  let text_hl = ""
  let items = [[a:tag_string, "debugJumpable"], ["\t", "Normal"]]
  for idx in range(leading_spaces, len(source_line) - 1)
    let hl = synID(lnum, idx + 1, 1)->synIDattr("name")
    if hl == text_hl
      let text ..= source_line[idx]
    else
      call add(items, [text, text_hl])
      let text = source_line[idx]
      let text_hl = hl
    endif
  endfor
  call add(items, [text, text_hl])
  call s:ShowMessage(items)

  const col_reshift = len(items[0][0]) + len(items[1][0]) - leading_spaces
  const col_max = len(join(map(items, "v:val[0]"), ""))
  " Apply extmarks to prompt line
  let extmarks = s:GetLineExtmarks(0, -1, lnum - 1)
  let ns = nvim_create_namespace('PromptDebugHighlight')
  let prompt_lnum = nvim_buf_line_count(s:prompt_bufnr) - 2
  for extm in extmarks
    let start_col = extm[2] + col_reshift
    let opts = extm[3]
    " Ignore breakpoint signs
    if has_key(opts, 'sign_text')
      continue
    endif
    " Perform some gymnastics on options
    let row = extm[1]
    if get(opts, 'end_row', row) != row
      continue
    endif
    silent! unlet opts['end_row']
    if !has_key(opts, 'end_col')
      continue
    endif
    let opts['end_col'] += col_reshift
    silent! unlet opts['ns_id']
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, prompt_lnum, start_col, opts)
  endfor
  " Mark for jumping
  call s:ConcealJump(expand("%:p"), lnum)
endfunc

func s:GetLineExtmarks(b, ns, idx)
  let line = nvim_buf_get_lines(a:b, a:idx, a:idx + 1, v:true)[0]
  return nvim_buf_get_extmarks(a:b, a:ns, [a:idx, 0], [a:idx, len(line)], #{details: v:true})
endfunc

func s:PrintCommand(cmd, expr)
  let format = 'natural'
  let slash = stridx(a:cmd, '/')
  if slash > 0
    let key = a:cmd[slash+1:]
    let format_map = {'x': 'hexadecimal', 'd': 'decimal',
          \ 'o': 'octal', 't': 'binary', 'z': 'zero-hexadecimal'}
    if !has_key(format_map, key)
      return s:ShowWarning("Unkown format: " .. a:cmd)
    endif
    let format = format_map[key]
  endif

  let Cb = function('s:ShowFormatVar', [format, a:expr])
  call s:SendMICommand('-var-create - * ' . s:EscapeMIArgument(a:expr), Cb)
endfunc

func s:FindPrettyPrinter(dict)
  if has_key(a:dict, 'type')
    let type = a:dict['type']
    for [printer; pats] in s:pretty_printers
      for pat in pats
        let disallow_templates_pat = "^[^<]*" .. pat
        if type =~# disallow_templates_pat
          return printer
        endif
      endfor
    endfor
  endif
  return ""
endfunc

func s:RegisterNewVar(dict, display_name, ...)
  let new_var = #{}

  let value = get(a:dict, "value", "")
  if empty(value)
    let value = "???"
  endif
  let new_var["value"] = value
  let new_var["type"] = get(a:dict, 'type', '')
  let new_var['expandable'] = a:dict['numchild'] > 0
  let new_var['nesting'] = get(a:000, 0, 0)
  let new_var['display_name'] = a:display_name
  let new_var['created'] = !has_key(a:dict, 'exp')
  let new_var['gdb_handle'] = a:dict['name']

  let s:vars[new_var['gdb_handle']] = new_var
  return new_var
endfunc

func s:ShowVarAt(lnum, nesting, display_name, dict)
  call s:RegisterNewVar(a:dict, a:display_name, a:nesting)
  call s:ShowElided(a:lnum, a:dict['name'])
endfunc

func s:ShowFormatVar(format, display_name, dict)
  let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
  call s:RegisterNewVar(a:dict, a:display_name)
  if a:format == 'natural'
    call s:ShowElided(lnum, a:dict['name'])
  else
    let Cb = function('s:ShowEvaluation', [lnum, 0, a:display_name]) 
    let cmd = printf('-var-set-format %s %s', a:dict['name'], a:format)
    call s:SendMICommand(cmd, Cb)
  endif
endfunc

func s:HandleMapFindVar(dict)
  let gdb_handle = a:dict['name']
  let cmd = printf('-var-set-format %s hexadecimal', gdb_handle)
  call s:SendMICommand(cmd, function('s:MapFindVar', [gdb_handle]) )
endfunc

func s:MapFindVar(name, dict)
  let value = str2nr(a:dict['value'], 16)
  call s:SendMICommandNoOutput('-var-delete ' . a:name)
  if value <= 0
    return s:ShowError("Invalid value: " .. a:dict['value'])
  endif
  let lines = s:GetMaps()
  for line in lines
    let m = matchlist(line, '^\(\x\+\)-\(\x\+\)\s\S\+\s\(\x\+\)')
    if !empty(m)
      let from = str2nr(m[1], 16)
      let to = str2nr(m[2], 16)
      let map_offset = str2nr(m[3], 16)
      if from <= value && value < to
        call s:ShowMessage([[line, 'debugValue']])
      endif
    endif
  endfor
endfunc

func s:ShowEvaluation(lnum, nesting, display_name, dict)
  let width = getbufvar(s:prompt_bufnr, '&sw')
  let indent = repeat(" ", a:nesting * width)

  let indent_item = [indent, "Normal"]
  let name_item = [a:display_name .. " = ", "Normal"]
  let value_item = [a:dict['value'], "debugValue"]
  call s:AppendMessage(a:lnum, [indent_item, name_item, value_item])
  return [len(indent_item[0]), len(name_item[0]), len(value_item[0])]
endfunc

func s:ShowElided(lnum, var_name)
  let var = s:vars[a:var_name]
  let [indent_len, name_len, value_len] = s:ShowEvaluation(a:lnum, var.nesting, var.display_name, var)

  if var.expandable
    let items = [[var['gdb_handle'], 'EndOfBuffer']]
    let ns = nvim_create_namespace('PromptDebugConcealVar')
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, 0, #{virt_text: items})
    " Highlight 'value_item' as debugExpandable
    let col = indent_len + name_len
    let end_col = col + value_len
    let opts = #{end_col: end_col, hl_group: 'debugExpandable', priority: 10000}
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, col, opts)
  endif
endfunc

" Perform an action based on a hidden string message at line
func s:ExpandCursor(lnum)
  " Is it a location tag that should be jumped to?
  if s:JumpCursor(a:lnum)
    return
  endif
  " If not, then it must be a variable that should be printed
  let ns = nvim_create_namespace('PromptDebugConcealVar')
  let extmarks = s:GetLineExtmarks(0, ns, a:lnum - 1)
  let virt_extmark = filter(copy(extmarks), 'has_key(v:val[3], "virt_text")')
  if empty(virt_extmark)
    return
  endif
  " Find variable based on concealed string.
  let varname = map(extmarks[0][3]['virt_text'], 'v:val[0]')[0]
  " Remove highlights to signal that the link is inactive
  call map(extmarks, 'nvim_buf_del_extmark(0, ns, v:val[0])')
  " Determine variable type
  let var = s:vars[varname]
  if empty(var['type'])
    let Cb = function('s:ExpandVariable', [a:lnum, varname])
    return s:SendMICommand('-var-info-type ' .. s:EscapeMIArgument(varname), Cb)
  else
    " Determine type of variable from 'var' directly
    call s:ExpandVariable(a:lnum, varname, var)
  endif
endfunc

func s:ExpandVariable(lnum, varname, dict)
  const pretty_fun = s:FindPrettyPrinter(a:dict)
  let var = s:vars[a:varname]
  if empty(pretty_fun)
    " Regular printing, fetch the children and print them recursively.
    let Cb = function('s:HandleVarChildren', [a:lnum, var])
    return s:SendMICommand('-var-list-children 1 ' .. s:EscapeMIArgument(a:varname), Cb)
  else
    " Pretty printing, evaluate custom expressions based on printer.
    let var['pretty_fun'] = pretty_fun
    let Cb = function('s:ShowPrettyVar', [a:lnum, var])
    call s:SendMICommand('-var-info-path-expression ' .. s:EscapeMIArgument(a:varname), Cb)
  endif
endfunc

func s:JumpCursor(lnum)
  let ns = nvim_create_namespace('PromptDebugConcealJump')
  let extmarks = s:GetLineExtmarks(0, ns, a:lnum - 1)
  if empty(extmarks)
    return v:false
  endif
  let keys = map(extmarks[0][3]['virt_text'], 'v:val[0]')
  if len(keys) == 1
    " Frame jump
    call s:ShowNormal(prompt_getprompt(s:prompt_bufnr))
    call s:ShowNormal("Jumping to frame #" .. keys[0])
    call s:FrameCommand(keys[0])
  elseif len(keys) == 2
    if keys[0] =~ '^[0-9]' && keys[1] =~ '^[0-9]'
      " Thread jump
      call s:ShowNormal(prompt_getprompt(s:prompt_bufnr))
      call s:ShowNormal("Jumping to thread ~" .. keys[0])
      let Cb = function('s:HandleThreadJump', [keys[1]])
      call s:SendMICommand('-thread-select ' .. s:EscapeMIArgument(keys[0]), Cb)
    else
      " Source jump
      call PromptDebugGoToSource()
      if expand("%:p") != keys[0]
        exe "e " . fnameescape(keys[0])
      endif
      exe keys[1]
      normal z.
    endif
  endif
  return v:true
endfunc

func s:ConcealJumpAt(pos, ...)
  let ns = nvim_create_namespace('PromptDebugConcealJump')
  if a:0 > 0 && type(a:1) == v:t_list
    let items = copy(a:1)
  else
    let items = copy(a:000)
  endif
  call map(items, 'type(v:val) == v:t_number ? string(v:val) : v:val')
  call map(items, '[v:val, "EndOfBuffer"]')
  call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:pos, 0, #{virt_text: items})
endfunc

func s:ConcealJump(...)
  let pos = nvim_buf_line_count(s:prompt_bufnr) - 2
  return s:ConcealJumpAt(pos, a:000)
endfunc

func s:PrettyPrinterVector(expr)
  let start_expr = printf('%s._M_impl._M_start', a:expr)
  let length_expr = printf('%s._M_impl._M_finish-%s._M_impl._M_start', a:expr, a:expr)
  return [[1, 'start', start_expr], [0, 'length', length_expr]]
endfunc

func s:PrettyPrinterString(expr)
  let str_expr = printf('%s._M_dataplus._M_p', a:expr)
  let length_expr = printf('%s._M_string_length', a:expr)
  return [[0, 'string', str_expr], [0, 'length', length_expr]]
endfunc

func s:PrettyPrinterFilesystem(expr)
  let str_expr = printf('%s.string()', a:expr)
  return [[0, 'pathname', str_expr]]
endfunc

func s:PrettyPrinterOptional(expr)
  let has_value_expr = printf('%s._M_payload._M_engaged', a:expr)
  let value_expr = printf('%s._M_payload._M_payload._M_value', a:expr)
  return [[0, 'has_value', has_value_expr], [1, 'value', value_expr]]
endfunc

func s:PrettyPrinterUniquePtr(expr)
  let expr = printf('%s._M_t._M_ptr()', a:expr)
  return [[1, 'ptr', expr]]
endfunc

func s:PrettyPrinterSharedPtr(expr)
  let ptr = printf('%s._M_ptr', a:expr)
  let control = printf('%s._M_refcount._M_pi', a:expr)
  return [[1, 'ptr', ptr], [1, 'control', control]]
endfunc

func s:PrettyPrinterSharedCount(expr)
  let count = printf('%s->_M_use_count', a:expr)
  return [[0, 'use_count', count]]
endfunc

func s:PrettyPrinterAtomicInt(expr)
  let expr = printf('%s._M_i', a:expr)
  return [[0, 'value', expr]]
endfunc

func s:PrettyPrinterAtomicBool(expr)
  let expr = printf('%s._M_base._M_i', a:expr)
  return [[0, 'value', expr]]
endfunc

func s:PrettyPrinterBitset(expr)
  let expr = printf('%s._M_w', a:expr)
  return [[0, 'word', expr]]
endfunc

func s:PrettyPrinterFunction(expr)
  let invoker = printf('%s._M_invoker', a:expr)
  return [[0, 'invoker', invoker]]
endfunc

func s:PrettyPrinterThread(expr)
  let id = printf('%s._M_id._M_thread', a:expr)
  return [[0, 'running_thread', id]]
endfunc

func s:PrettyPrinterPair(expr)
  let first = printf('%s.first', a:expr)
  let second = printf('%s.second', a:expr)
  return [[1, 'first', first], [1, 'second', second]]
endfunc

func s:EndPrinting()
  for var in values(s:vars)
    if var['created']
      call s:SendMICommandNoOutput('-var-delete ' . var['gdb_handle'])
    endif
  endfor
  let s:vars = #{}
  " Disable expansion of all variables
  let ns = nvim_create_namespace('PromptDebugConcealVar')
  call nvim_buf_clear_namespace(0, ns, 0, -1)
endfunc
"}}}

""""""""""""""""""""""""""""""""Record handlers"""""""""""""""""""""""""""""""{{{
func s:CommOutput(start_time, msg)
  " Stream record
  if !empty(a:msg) && stridx("~@&", a:msg[0]) == 0
    return s:HandleStream(a:msg)
  endif
  " Async record
  let async = s:GetAsyncClass(a:msg)
  if !empty(async)
    " XXX: Not sure how to integrate timings with async methods...
    return s:HandleAsync(a:msg)
  endif
  " Result record
  let result = s:GetResultClass(a:msg)
  if !empty(result)
    return s:HandleResult(a:start_time, a:msg)
  endif
endfunc

func s:HandleAsync(msg)
  let async = s:GetAsyncClass(a:msg)
  let dict = EvalCommaResults(a:msg)
  if async == 'stopped' || async == 'running' || async == 'thread-selected'
    return s:HandleCursor(async, dict)
  elseif async == 'thread-group-started'
    return s:HandleProgramRun(dict)
  elseif async == 'thread-created' || async == 'thread-exited'
    return s:HandleThreadChanged(async, dict)
  elseif async == 'breakpoint-created' || async == 'breakpoint-modified'
    return s:HandleNewBreakpoint(dict)
  elseif async == 'breakpoint-deleted'
    return s:HandleBreakpointDelete(dict)
  elseif async == 'cmd-param-changed'
    return s:HandleOption(dict)
  elseif async == 'library-loaded'
    return s:HandleLibraryLoaded(dict)
  elseif async == 'library-unloaded'
    return s:HandleLibraryUnloaded(dict)
  endif
endfunc

func s:HandleResult(start_time, msg)
  let result = s:GetResultClass(a:msg)
  let token = s:GetResultToken(a:msg)
  let dict = EvalCommaResults(a:msg)
  if result == 'done'
    if str2nr(token) > 0 && has_key(s:callbacks, token)
      let cmd = s:callbacks[token][0]
      if has_key(dict, 'time')
        " Who though up of this syntax?
        let secs_total = reltimefloat(reltime(s:callbacks[token][2], reltime()))
        let secs_us = reltimefloat(reltime(a:start_time, reltime()))
        let percent_us = float2nr(100.0 * secs_us / secs_total)
        if secs_us > 0.1 && percent_us > 30
          call s:ShowWarning(printf('Command "%s" took %fs (%d%% by us).', cmd, secs_total, percent_us))
          let secs_gdb = str2float(dict['time']['wallclock'])
          call s:ShowWarning(printf('Time spend internally in Gdb: %fs', secs_gdb))
        endif
      endif
      let Callback = s:callbacks[token][1]
      return Callback(dict)
    else
      echom "Unhandled record!"
    endif
  elseif result == 'error'
    return s:HandleError(dict)
  endif
endfunc

func s:HandleStream(msg)
  execute printf('let msg = %s', a:msg[1:])
  let lines = split(msg, "\n", 1)
  if s:floating_output
    " Lazily open the window
    if !exists('s:edit_win')
      call s:OpenFloatEdit(20, 1, [])
      augroup PromptDebugFloatEdit
        autocmd! WinClosed * call s:StopFloatingOutput()
        autocmd! WinClosed * call s:CloseFloatEdit()
      augroup END
    endif
    " Append message
    let bufnr = winbufnr(s:edit_win)
    let last_line = getbufoneline(bufnr, '$') .. lines[0]
    call setbufline(bufnr, '$', last_line)
    call appendbufline(bufnr, '$', lines[1:])
    " Resize float window
    let widths = map(getbufline(bufnr, 1, '$'), 'len(v:val)')
    call s:OpenFloatEdit(max(widths) + 1, len(widths))
    stopinsert
  endif
endfunc

func s:OnInferiorStopped(dict)
  let reason = get(a:dict, 'reason', '')
  if reason == 'breakpoint-hit'
    let bkptno = a:dict['bkptno']
    " Execute breakpoint commands
    if has_key(s:breakpoints, bkptno)
      let bkpt = s:breakpoints[bkptno]
      for cmd in bkpt['script']
        call s:PromptOutput(cmd)
      endfor
    endif
  elseif reason == 'watchpoint-trigger'
    if exists('s:lr_wpt_number') && s:lr_wpt_number == a:dict['wpt']['number']
      call s:SendMICommandNoOutput('-break-disable ' .. s:lr_wpt_number)
    endif
  endif
endfunc

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(class, dict)
  " Update stopped state
  if a:class == 'thread-selected'
    let s:selected_thread = a:dict['id']
  elseif a:class == 'stopped'
    call s:ShowStopReason(a:dict)
    " Key might be missing when e.g. stopped due do signal (thread group exited)
    if has_key(a:dict, 'thread-id')
      " Show a message that the thread has changed
      if !exists('s:selected_thread') || s:selected_thread != a:dict['thread-id']
        call s:ShowNormal("Switching to thread ~" .. a:dict['thread-id'])
      endif
      let s:selected_thread = a:dict['thread-id']
    endif
    let s:stopped = 1
    let s:selected_frame = 0
    call s:OnInferiorStopped(a:dict)
  elseif a:class == 'running'
    let id = a:dict['thread-id']
    if id == 'all' || (exists('s:selected_thread') && id == s:selected_thread)
      let s:stopped = 0
    endif
  endif
  " Gray out '(gdb)' prompt if running
  let ns = nvim_create_namespace('PromptDebugPrompt')
  call nvim_buf_clear_namespace(s:prompt_bufnr, ns, 0, -1)
  if !s:stopped
    let lines = nvim_buf_line_count(s:prompt_bufnr)
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, lines - 1, 0, #{line_hl_group: 'Comment'})
  endif
  " Update cursor
  call s:ClearCursorSign()
  if has_key(a:dict, 'frame') && s:stopped
    call s:PlaceCursorSign(a:dict['frame'])
  endif
endfunc

func s:ShowStopReason(dict)
  let reason = get(a:dict, 'reason', '???')
  if reason == 'function-finished' || reason == 'end-stepping-range'
    " Ignore common reasons for GDB to stop
    return
  endif

  " This makes a huge difference visually
  call s:ShowNormal("")

  if reason == 'breakpoint-hit'
    let msg = "Breakpoint hit."
  elseif reason == 'watchpoint-scope'
    let msg = "Watchpoint out of scope!"
  elseif reason == 'no-history'
    let msg = "Cannot continue reverse execution!"
  elseif reason =~ 'watchpoint'
    let msg = "Watchpoint hit"
  elseif reason == 'exited-signalled'
    return s:ShowWarning("Process exited due to signal: " .. a:dict['signal-name'])
  elseif reason == 'exited'
    return s:ShowWarning("Process exited with code " .. a:dict['exit-code'])
  elseif reason == 'exited-normally'
    return s:ShowNormal("Process exited normally. ")
  elseif reason == 'signal-received'
    return s:ShowNormal("Process received signal: " .. a:dict['signal-name'])
  elseif reason == 'solib-event' || reason =~ 'fork' || reason =~ 'syscall' || reason == 'exec'
    let msg = "Event " .. string(reason)
  else
    let msg = reason
  endif
  let items = [["Stopped", "Italic"], [", reason: " .. msg, "Normal"]]
  call s:ShowMessage(items)
endfunc

func s:PlaceCursorSign(dict)
  if s:asm_mode
    call s:PlaceAsmCursor(a:dict)
  else
    call s:PlaceSourceCursor(a:dict)
  endif
endfunc

" Save executable timestamp. Use this to detect if it's out of date.
func s:CreateExeTimestamp()
  if exists('s:exe_timestamp')
    return
  endif

  let cmd = ['stat', '-L', '--printf=%Y', '/proc/' .. s:pid .. '/exe']
  if exists('s:host')
    let cmd = ["ssh", s:host, join(cmd, ' ')]
  endif
  let s:exe_timestamp = system(cmd)
  if v:shell_error
    call s:ShowWarning("Failed to determine executable timestamp")
    let s:exe_timestamp = localtime()
  endif
endfunc

func s:WarnFileOnce(file, msg)
  if !has_key(s:files_warned, a:file)
    let s:files_warned[a:file] = 1
    call s:ShowWarning(a:msg)
  endif
endfunc

func s:PlaceSourceCursor(dict)
  let ns = nvim_create_namespace('PromptDebugPC')
  let filename = get(a:dict, 'fullname', '')
  let lnum = get(a:dict, 'line', '')
  if filereadable(filename) && str2nr(lnum) > 0
    if g:promptdebug_check_timestamps
      " Lazily create the stamp. There is a race condition where the parent process will fork but not exe yet.
      " This the executable will appear as if it's the parent process. At least that's what I tell myself.
      call s:CreateExeTimestamp()
      if getftime(filename) > s:exe_timestamp
        call s:WarnFileOnce(filename, "File is more recent than executable")
      endif
    endif
    let origw = win_getid()
    call PromptDebugGoToSource()
    if expand("%:p") != filename
      exe "e " . fnameescape(filename)
    endif
    if lnum > nvim_buf_line_count(0)
      return s:ShowWarning("Cannot place cursor. Is executable up to date?")
    endif
    exe lnum
    normal z.
    " Display a hint where we stopped
    if g:promptdebug_show_source
      let tag = string(line('.'))
      call s:ShowSourceLine(tag)
    endif
    " Highlight stopped line
    call nvim_buf_set_extmark(0, ns, lnum - 1, 0, #{line_hl_group: 'debugPC'})
    let s:source_bufnr = bufnr()
    call win_gotoid(origw)
  elseif !empty(filename)
    call s:WarnFileOnce(filename, "Unknown file: " .. filename)
  else
    call s:ShowNormal("???\tNo source available.")
  endif
endfunc

" TODO integrate find!

func s:PlaceAsmCursor(dict)
  let addr = get(a:dict, 'addr', '')
  let line = get(a:dict, 'line', '')
  if !s:SelectAsmAddr(addr, line)
    " Reload disassembly
    if a:dict['func'] != '??'
      let cmd = printf("-data-disassemble -a %s 0", addr)
      let Cb = function('s:HandleDisassemble', [addr, line])
      call s:SendMICommand(cmd, Cb)
    elseif g:promptdebug_reverse_eng
      let cmd = printf("-data-disassemble -s 0x%x -e 0x%x 0", addr - 100, addr + 300)
      let Cb = function('s:HandleDisassemble', [addr, line])
      call s:SendMICommand(cmd, Cb)
    endif
  endif
endfunc

func s:SelectAsmAddr(addr, line)
  let origw = win_getid()
  call PromptDebugGoToSource()
  if bufname() != s:asm_bufname
    exe "e " . s:asm_bufname
    call setbufvar("%", '&list', v:false)
  endif
  let lnum = search('^' . a:addr)
  if lnum > 0
    normal z.
    let ns = nvim_create_namespace('PromptDebugPC')
    " Display a hint where we stopped
    if g:promptdebug_show_source
      let tag = a:line
      call s:ShowSourceLine(tag)
    endif
    call nvim_buf_set_extmark(0, ns, lnum - 1, 0, #{line_hl_group: 'debugPC'})
    let s:source_bufnr = bufnr()
    call win_gotoid(origw)
  endif
  call win_gotoid(origw)
  return lnum > 0
endfunc

func s:ClearCursorSign()
  let ns = nvim_create_namespace('PromptDebugPC')
  if bufexists(s:source_bufnr)
    call nvim_buf_clear_namespace(s:source_bufnr, ns, 0, -1)
  endif
endfunc

func s:RefreshCursorSign(frame)
  call s:ClearCursorSign()
  call s:PlaceCursorSign(a:frame)
endfunc

" Handle the debugged program starting to run.
" Will store the process ID in s:pid
func s:HandleProgramRun(dict)
  let s:pid = a:dict['pid']
  " Add a few introductory lines
  if exists('s:host')
    call s:ShowNormal("Remote debugging " .. s:host)
  else
    call s:ShowNormal("Local debugging")
  endif
  call s:ShowNormal("Process id: " .. s:pid)
  let cmd = ['stat', '--printf=%G', '/proc/' .. s:pid]
  if exists('s:host')
    let cmd = ["ssh", s:host, join(cmd, ' ')]
  endif
  let user = system(cmd)
  if !v:shell_error
    call s:ShowNormal("Running as: " .. user)
  endif

  " Issue autocmds
  if exists('#User#PromptDebugRunPost') && !exists('s:program_run_once')
    doauto <nomodeline> User PromptDebugRunPost
    let s:program_run_once = v:true
  endif
endfunc

func s:HandleThreadChanged(async, dict)
  let id = a:dict['id']
  if a:async == 'thread-created'
    let s:thread_ids[id] = a:dict['group-id']
  elseif a:async == 'thread-exited'
    silent! unlet s:thread_ids[id]
  endif
endfunc

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(dict)
  let bkpt = a:dict['bkpt']
  if bkpt['type'] != 'breakpoint'
    " Display a message to the user
    if bkpt['type'] == 'catchpoint'
      let msg = printf('Catchpoint %s (%s)', bkpt['number'], bkpt['what'])
      call s:ShowNormal(msg)
    elseif stridx(bkpt['type'], 'watchpoint') >= 0
      " Add an exception to not show this message every time we execute "bl" command
      if bkpt['number'] != get(s:, 'lr_wpt_number', -1)
        let msg = printf('Watchpoint %s (%s)', bkpt['number'], bkpt['what'])
        call s:ShowNormal(msg)
      endif
    endif
    return
  endif
  if has_key(bkpt, 'pending')
    let normal = 'Breakpoint ' . bkpt['number'] . ' (' . bkpt['pending']  . ') pending.'
    call s:ShowNormal(normal)
    return
  endif

  call s:ClearBreakpointSign(bkpt['number'], 0)
  if has_key(bkpt, 'addr') && bkpt['addr'] == '<MULTIPLE>'
    for location in bkpt['locations']
      let [id, new] = s:AddBreakpoint(location, bkpt)
      call s:PlaceBreakpointSign(id)
      if new && exists('s:pid')
        call s:FormatBreakpointMessage(location, bkpt)
      endif
    endfor
  else
    let [id, new] = s:AddBreakpoint(bkpt, #{})
    call s:PlaceBreakpointSign(id)
    if new && exists('s:pid')
      call s:FormatBreakpointMessage(bkpt, #{})
    endif
  endif
endfunc

func s:HandleRestoredBreakpoint(cmds, dict)
  call s:HandleNewBreakpoint(a:dict)
  let bkpt = a:dict['bkpt']
  let id = bkpt['number']
  if has_key(bkpt, 'addr') && bkpt['addr'] == '<MULTIPLE>'
    call s:ShowWarning(printf('Breakpoint %s has multiple locations, ignoring commands', id))
  else
    call assert_true(has_key(s:breakpoints, id))
    let s:breakpoints[id]['script'] = a:cmds
  endif
endfunc

func s:AddBreakpoint(bkpt, parent)
  let id = a:bkpt['number']
  let new = v:false
  if !has_key(s:breakpoints, id)
    let new = v:true
    let s:breakpoints[id] = #{script: []}
  endif
  let item = s:breakpoints[id]
  let item['enabled'] = a:bkpt['enabled'] == 'y'
  if has_key(a:bkpt, 'fullname')
    let item['fullname'] = a:bkpt['fullname']
    let item['lnum'] = a:bkpt['line']
  endif
  if !empty(a:parent)
    let parent_id = a:parent['number']
    let item['parent'] = parent_id
    if !has_key(s:multi_brs, parent_id)
      let s:multi_brs[parent_id] = [id]
    else
      call add(s:multi_brs[parent_id], id)
    endif
    let item['enabled'] = item['enabled'] && a:parent['enabled'] == 'y'
  endif
  let s:breakpoints[id] = item
  return [id, new]
endfunc

" Handle deleting a breakpoint
" Will remove the sign that shows the breakpoint
func s:HandleBreakpointDelete(dict)
  let id = a:dict['id']
  call s:ClearBreakpointSign(id, 1)
  " We internally create this watchpoint to service "bl" command. Update
  " state to reflect that the watchpoint must be created anew.
  if id == get(s:, 'lr_wpt_number', -1)
    unlet s:lr_wpt_number
  endif
endfunc

func s:ClearBreakpointSign(id, delete)
  let ns = nvim_create_namespace('PromptDebugBr')
  if has_key(s:multi_brs, a:id)
    let ids = s:multi_brs[a:id]
    if a:delete
      unlet s:multi_brs[a:id]
    endif
  else
    let ids = [a:id]
  endif
  for id in ids
    " Might be watchpoint that was deleted, so check first
    if !has_key(s:breakpoints, id)
      continue
    endif
    let breakpoint = s:breakpoints[id]
    if has_key(breakpoint, "extmark")
      let extmark = breakpoint['extmark']
      let bufnr = bufnr(breakpoint['fullname'])
      if bufnr > 0
        call nvim_buf_del_extmark(bufnr, ns, extmark)
      endif
    endif
    if a:delete
      unlet s:breakpoints[id]
    elseif has_key(s:breakpoints[id], 'extmark')
      unlet s:breakpoints[id]['extmark']
    endif
  endfor
endfunc

func s:PlaceBreakpointSign(id)
  let breakpoint = s:breakpoints[a:id]
  if !has_key(breakpoint, 'fullname')
    return
  endif
  let fullname = breakpoint['fullname']
  if !filereadable(fullname)
    return s:WarnFileOnce(fullname, "Unknown file: " .. fullname)
  endif

  let bufnr = bufnr(fullname)
  let placed = has_key(breakpoint, 'extmark')
  if bufnr > 0 && !placed
    call bufload(bufnr)
    if breakpoint['lnum'] > nvim_buf_line_count(bufnr)
      return s:ShowWarning("Cannot place breakpoint sign. Is executable up to date?")
    endif
    let ns = nvim_create_namespace('PromptDebugBr')
    let text = has_key(breakpoint, 'parent') ? breakpoint['parent'] : a:id
    if len(text) > 2
      let text = "*"
    endif
    let hl_group = breakpoint['enabled'] ? 'debugBreakpoint' : 'debugBreakpointDisabled'
    let opts = #{sign_text: text, sign_hl_group: hl_group}
    let extmark = nvim_buf_set_extmark(bufnr, ns, breakpoint['lnum'] - 1, 0, opts)
    let s:breakpoints[a:id]['extmark'] = extmark
  endif
endfunc

func s:HandleOption(dict)
  if a:dict['param'] == 'scheduler-locking'
    let s:scheduler_locking = a:dict['value']
  elseif a:dict['param'] == 'max-completions'
    let s:max_completions = a:dict['value']
  endif
endfunc

func s:HandleLibraryLoaded(dict)
  let id = a:dict['id']
  let str_ranges = a:dict['ranges']
  let ranges = []
  for str_range in str_ranges
    let from = str2nr(str_range['from'], 16)
    let to = str2nr(str_range['to'], 16)
    call add(ranges, [from, to])
  endfor
  let s:libraries[id] = ranges
endfunc

func s:HandleLibraryUnloaded(dict)
  let id = a:dict['id']
  unlet s:libraries[id]
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

func s:Get(dict, ...) abort
  if type(a:dict) != v:t_dict
    throw "Invalid arguments, expecting dictionary as first argument"
  endif
  let result = a:dict
  let default = a:000[-1]
  for key in a:000[:-2]
    if type(key) != v:t_string
      throw "Invalid arguments, expecting string"
    endif
    if type(result) != v:t_dict || !has_key(result, key)
      return default
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
func s:HandleBreakpointTable(show_times, dict)
  let table = s:GetListWithKeys(a:dict['BreakpointTable'], 'body')
  if empty(table)
    call s:ShowError("No breakpoints.")
    return
  endif
  for bkpt in table
    if has_key(bkpt, 'locations')
      for location in bkpt['locations']
        call s:FormatBreakpointMessage(location, bkpt)
        if a:show_times
          let str_times = bkpt['times'] == 1 ? "time" : "times"
          call s:ShowNormal(printf("Breakpoint hit %d %s", bkpt['times'], str_times))
        endif
      endfor
    else
      call s:FormatBreakpointMessage(bkpt, #{})
      if a:show_times
        let str_times = bkpt['times'] == 1 ? "time" : "times"
        call s:ShowNormal(printf("Breakpoint hit %d %s", bkpt['times'], str_times))
      endif
    endif
  endfor
endfunc

func s:FormatBreakpointMessage(bkpt, parent)
  let nr = a:bkpt['number']
  let enabled = a:bkpt['enabled'] == 'y'
  if !empty(a:parent)
    let enabled = enabled && a:parent['enabled'] == 'y'
  endif
  let number_item = ["*" .. nr, 'debugIdentifier']
  let jumpable = has_key(a:bkpt, 'fullname') && filereadable(a:bkpt['fullname'])

  let type = get(a:bkpt, 'type', '')
  if stridx(type, "watchpoint") >= 0
    let what_item = [string(a:bkpt['what']), 'Bold']
    if type[:2] == "acc"
      let cond_item = [" is accessed", "Normal"]
    elseif type[:3] == "read"
      let cond_item = [" is read", "Normal"]
    else
      let cond_item = [" is written", "Normal"]
    endif
    call s:ShowMessage([number_item, [" when ", "Normal"], what_item, cond_item])
  elseif type == "catchpoint"
    let what_item = [a:bkpt['what'], 'Bold']
    call s:ShowMessage([number_item, [" on ", "Normal"], what_item])
  else
    if has_key(a:bkpt, 'at')
      let location = a:bkpt['at']
    elseif has_key(a:bkpt, 'func')
      let location = a:bkpt['func']
    elseif jumpable
      let basename = fnamemodify(a:bkpt['fullname'], ':t')
      let location = basename .. ":" .. a:bkpt['line']
    else
      let location = get(a:bkpt, 'addr', '???')
    endif

    let in_item = [" in ", 'Normal']
    let location_item = [location, jumpable && enabled ? 'debugJumpable' : 'debugLocation']

    call s:ShowMessage([number_item, in_item, location_item])
  endif

  if !enabled
    let ns = nvim_create_namespace('PromptDebugHighlight')
    let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
    let chars = len(getbufoneline(s:prompt_bufnr, lnum))
    let opts = #{end_col: chars, hl_group: '@markup.strikethrough'}
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, lnum - 1, 0, opts)
  endif
  if jumpable
    call s:ConcealJump(a:bkpt['fullname'], a:bkpt['line'])
  endif
endfunc

func s:HandleThreadSelect(dict)
  let s:selected_thread = a:dict['new-thread-id']
  let s:selected_frame = a:dict['frame']['level']
  call s:RefreshCursorSign(a:dict['frame'])
endfunc

func s:HandleThreadJump(level, dict)
  let s:selected_thread = a:dict['new-thread-id']
  call s:FrameCommand(a:level)
endfunc

func s:HandleThreadStack(id, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')

  let prefix = "/home/" .. $USER
  for frame in frames
    let fullname = get(frame, 'fullname', '')
    if filereadable(fullname) && stridx(fullname, prefix) == 0
      return s:ShowThreadFrame(a:id, frame)
    endif
  endfor
  " Try a second time without the prefix
  for frame in frames
    let fullname = get(frame, 'fullname', '')
    if filereadable(fullname)
      return s:ShowThreadFrame(a:id, frame)
    endif
  endfor

  if g:promptdebug_thread_filter
    return
  endif
  " One more try with just a function name
  for frame in frames
    if has_key(frame, 'func')
      return s:ShowThreadFrame(a:id, frame)
    endif
  endfor
  " If all else fails...
  if !empty(frames)
    call s:ShowThreadFrame(a:id, frames[0])
  endif
endfunc

func s:HandleThreadFilter(id, func, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    if stridx(frame['func'], a:func) >= 0
      call s:ShowThreadFrame(a:id, frame)
    endif
  endfor
endfunc

func s:HandleStackVariables(arg, pat, dict)
  let vars = a:dict['variables']
  call filter(vars, 'get(v:val, "arg", "0") == a:arg')
  call map(vars, "v:val.name")
  call filter(vars, "stridx(v:val, a:pat) >= 0")
  for var in vars
    call s:PrintCommand("p", var)
  endfor
endfunc

func s:HandleShow(depth, dict)
  let width = getbufvar(s:prompt_bufnr, '&sw')
  let indent = repeat(" ", a:depth * width)

  if has_key(a:dict, 'value')
    call s:ShowNormal(indent .. a:dict['value'])
  elseif has_key(a:dict, 'showlist')
    let options = s:GetListWithKeys(a:dict, 'showlist')
    let child_indent = indent .. repeat(" ", width)
    for option in options
      if has_key(option, 'showlist')
        call s:ShowNormal(indent .. option['prefix'])
        call s:HandleShow(a:depth + 1, option)
      else
        let value = printf('%s = %s', option['name'], option['value'])
        call s:ShowNormal(child_indent .. value)
      endif
    endfor
  endif
endfunc

func s:HandleVarChildren(lnum, parent_var, dict)
  if !has_key(a:dict, "children")
    return
  endif
  let nesting = a:parent_var['nesting'] + 1
  let children = s:GetListWithKeys(a:dict, "children")
  " Optimize output by removing indirection
  let optimized_exps = ['public', 'private', 'protected']
  let optimized = []
  for child in reverse(children)
    if index(optimized_exps, child['exp']) >= 0
      call add(optimized, child)
    else
      let display_name = child['exp']
      call s:ShowVarAt(a:lnum, nesting, display_name, child)
    endif
  endfor
  for child in optimized
    let Cb = function('s:HandleVarChildren', [a:lnum, a:parent_var])
    let name = child['name']
    call s:SendMICommand('-var-list-children 1 ' .. s:EscapeMIArgument(name), Cb)
  endfor
endfunc

func s:ShowPrettyVar(lnum, var, dict)
  let nesting = a:var['nesting'] + 1
  let pretty_fun = a:var['pretty_fun']
  let fields = function(pretty_fun)(a:dict['path_expr'])
  for field in reverse(fields)
    let [recurse, name, expr] = field
    if !recurse
      let Cb = function('s:ShowEvaluation', [a:lnum, nesting, name])
      call s:SendMICommand('-data-evaluate-expression ' . s:EscapeMIArgument(expr), Cb)
    else
      let Cb = function('s:ShowVarAt', [a:lnum, nesting, name])
      call s:SendMICommand('-var-create - * ' . s:EscapeMIArgument(expr), Cb)
    endif
  endfor
endfunc

func s:OnEditComplete(bp)
  let nr = winbufnr(s:edit_win)
  let commands = getbufline(nr, 1, '$')
  call s:CloseFloatEdit()
  let s:breakpoints[a:bp]['script'] = commands
  call s:ShowNormal("Breakpoint commands updated.")
endfunc

func s:HandleSymbolInfo(dict)
  let list = []
  " Look in debug section
  let dbg = s:Get(a:dict, 'symbols', 'debug', [])
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
  let nondebug = s:Get(a:dict, 'symbols', 'nondebug', [])
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

func s:HandleEvaluate(dict)
  let lines = split(a:dict['value'], "\n")
  call s:OpenPreview("Value", lines)
  call s:ClosePreviewOn('CursorMoved', 'WinScrolled', 'WinResized')
endfunc

func s:HandleCompletion(cmd, dict)
  if bufname() != s:prompt_bufname
    return
  endif

  let context = split(a:cmd, " ", 1)[-1]
  let matches = a:dict['matches']
  call filter(matches, "stridx(v:val, a:cmd) == 0")
  call map(matches, "context .. v:val[len(a:cmd):]")
  if len(matches) == 0
    return s:EndCompletion()
  endif

  call s:OpenScrollablePreview("Completion", matches)
  call s:ScrollPreview("1")
  augroup PromptDebugCompletion
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
  if exists('#PromptDebugCompletion')
    au! PromptDebugCompletion
  endif
endfunc

func s:HandlePwd(dict)
  " Doesn't have a consistent name...
  let pwd = values(a:dict)[0]
  echo "Path: " . pwd
endfunc

func s:HandleDisassemble(addr, line, dict)
  let asm_insns = a:dict['asm_insns']

  call deletebufline(s:asm_bufnr, 1, '$')
  let reg_ns = nvim_create_namespace('PromptDebugRegister')
  call nvim_buf_clear_namespace(s:asm_bufnr, reg_ns, 0, -1)
  if empty(asm_insns)
    call appendbufline(s:asm_bufnr, 0, "No disassembler output")
    return
  endif

  if has_key(asm_insns[0], 'func-name')
    let intro = printf("Disassembly of %s:", asm_insns[0]['func-name'])
  else
    let intro = printf("Linear disassembly:")
  endif
  call appendbufline(s:asm_bufnr, 0, intro)

  for asm_ins in asm_insns
    let address = asm_ins['address']
    let inst = asm_ins['inst']
    if has_key(asm_ins, 'offset')
      let offset = asm_ins['offset']
      let line = printf("%s<%d>: %s", address, offset, inst)
      let endcol = len(address) + len(offset) + 3
    else
      let line = printf("%s: %s", address, inst)
      let endcol = len(address) + 1
    endif
    call appendbufline(s:asm_bufnr, "$", line)
    if !empty(s:hl_inst) && match(inst, s:hl_inst) >= 0
      let lines = nvim_buf_line_count(s:asm_bufnr)
      let opts = #{end_col: endcol, hl_group: "debugMarkedInst"}
      call nvim_buf_set_extmark(s:asm_bufnr, reg_ns, lines - 1, 0, opts)
    endif
  endfor
  call s:SelectAsmAddr(a:addr, a:line)
endfunc

func s:FormatFrameMessageWithTag(tag, dict)
  let frame = a:dict
  const jumpable = has_key(frame, 'fullname') && filereadable(frame['fullname'])
  let location = "???"
  if has_key(frame, 'fullname')
    let location = fnamemodify(frame['fullname'], ":t")
  elseif has_key(frame, 'from')
    let location = frame['from']
  endif

  let tag_item = [a:tag, 'debugIdentifier']
  let in_item = [" in ", 'Normal']
  let func_item = [frame["func"], jumpable ? 'debugJumpable' : 'Normal']
  let addr_item = [frame["addr"], 'Normal']
  let at_item = [" at ", 'Normal']
  let loc_item = [location, 'debugLocation']
  let where_item = (func_item[0] == "??" ? addr_item : func_item)
  return [jumpable, [tag_item, in_item, where_item, at_item, loc_item]]
endfunc

func s:ShowFrame(dict)
  let tag = "#" .. a:dict['level']
  let [jumpable, items] = s:FormatFrameMessageWithTag(tag, a:dict)
  call s:ShowMessage(items)
  if jumpable
    call s:ConcealJump(a:dict['level'])
  endif
endfunc

func s:ShowThreadFrame(id, dict)
  let tag = "~" .. a:id
  let [jumpable, items] = s:FormatFrameMessageWithTag(tag, a:dict)
  call s:ShowMessage(items)
  if jumpable
    call s:ConcealJump(a:id, a:dict['level'])
  endif
endfunc

func s:HandleFrameJump(level, dict)
  let frame = a:dict['frame']
  call s:ClearCursorSign()
  call s:PlaceCursorSign(frame)
  let s:selected_frame = a:level
  call s:SendMICommandNoOutput('-stack-select-frame ' .. s:selected_frame)
endfunc

func s:HandleLinkRegisterWatch(dict)
  let s:lr_wpt_number = a:dict['wpt']['number']
  call s:ContinueToLinkRegister()
endfunc

func s:HandleFrameMount(dir, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  let files_bunch = s:LocateFrameFiles(frames, a:dir)
  let failed_basenames = #{}
  let rules = []
  for frame in frames
    if !has_key(frame, 'fullname')
      continue
    endif
    let fullname = frame['fullname']
    if filereadable(fullname)
      continue
    endif
    let fullname = resolve(fullname)
    let basename = fnamemodify(fullname, ':t')
    if has_key(failed_basenames, basename)
      continue
    endif
    let targets = filter(copy(files_bunch), 'fnamemodify(v:val, ":t") == basename')
    if empty(targets)
      continue
    endif
    if len(targets) > 1
      call s:ShowWarning("Multiple substitutions possible for " .. basename)
      for target in targets[:3]
        call s:ShowNormal("Found in " .. target)
      endfor
      let failed_basenames[basename] = 1
    else
      let rule = s:PathSubstitute(fullname, targets[0])
      if index(rules, rule) < 0
        call add(rules, rule)
      endif
    endif
  endfor
  let total_failed = len(failed_basenames)
  if total_failed > 0
    call s:ShowWarning("Failed to make " .. total_failed .. " mounts!")
  endif
  for rule in rules
    let [from, to] = rule
    let cmd = printf('-gdb-set substitute-path %s %s', from, to)
    call s:ShowNormal(printf('Map %s -> %s.', from, to))
    call s:SendMICommandNoOutput(cmd)
  endfor
  if len(rules) > 0
    call s:ShowNormal("Total " .. len(rules) .. " mounts made.")
    call s:WhereCommand()
  else
    call s:ShowNormal("No mounts possible.")
  endif
endfunc

func s:LocateFrameFiles(frames, dir)
  let frames = filter(copy(a:frames), 'has_key(v:val, "fullname")')
  let basenames = map(frames, 'fnamemodify(v:val.fullname, ":t")')
  if empty(basenames)
    return []
  endif

  let cmd = printf("find %s ! -readable -prune", a:dir)
  for name in basenames
    let cmd ..= printf(" -o -name %s -print", string(name))
  endfor
  let ret = systemlist(cmd)
  if v:shell_error
    return []
  else
    return ret
  endif
endfunc

func s:PathSubstitute(from_fullname, to_fullname)
  let from_fullname = a:from_fullname
  let to_fullname = a:to_fullname
  while v:true
    let from_tail = fnamemodify(from_fullname, ':t')
    let to_tail = fnamemodify(to_fullname, ':t')
    if from_tail != to_tail
      break
    endif
    let next_from_fullname = fnamemodify(from_fullname, ':h')
    if next_from_fullname == from_fullname
      break
    endif
    let next_to_fullname = fnamemodify(to_fullname, ':h')
    if next_to_fullname == to_fullname
      break
    endif
    let from_fullname = next_from_fullname
    let to_fullname = next_to_fullname
  endwhile
  return [from_fullname, to_fullname]
endfunc

func s:HandleFrameList(dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    call s:ShowFrame(frame)
  endfor
endfunc

func s:HandleFrameChange(going_up, dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  if a:going_up
    call filter(frames, "str2nr(v:val.level) > s:selected_frame")
  else
    call filter(frames, "str2nr(v:val.level) < s:selected_frame")
    call reverse(frames)
  endif
  if s:asm_mode
    " Switch directly
    if !empty(frames)
      call s:ShowMessage([["Switching to frame #" .. frames[0]['level'], "Normal"]])
      call s:RefreshCursorSign(frames[0])
      let s:selected_frame = frames[0]['level']
      return s:SendMICommandNoOutput('-stack-select-frame ' .. s:selected_frame)
    endif
  else
    for frame in frames
      let fullname = get(frame, 'fullname', '')
      if filereadable(fullname)
        call s:ShowMessage([["Switching to frame #" .. frame['level'], "Normal"]])
        call s:RefreshCursorSign(frame)
        let s:selected_frame = frame['level']
        return s:SendMICommandNoOutput('-stack-select-frame ' .. s:selected_frame)
      endif
    endfor
  endif
  if a:going_up
    call s:ShowError("At topmost frame")
  else
    call s:ShowError("At bottom of stack")
  endif
endfunc

func s:HandleError(dict)
  call s:ClosePreview()
  call s:CloseFloatEdit()
  call s:StopFloatingOutput()
  let lines = split(a:dict['msg'], "\n")
  for line in lines
    call s:ShowError(line)
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

func s:OpenFloatEdit(width, height, ...)
  if &lines > a:height
    let row = (&lines - a:height) / 2
  else
    let row = 0
  endif
  if &columns > a:width
    let col = (&columns - a:width) / 2
  else
    let col = 0
  endif

  let opts = #{
        \ relative: "editor",
        \ row: row,
        \ col: col,
        \ width: a:width,
        \ height: a:height,
        \ focusable: 1,
        \ style: "minimal",
        \ border: "single",
        \ }

  if exists("s:edit_win")
    let nr = nvim_win_get_buf(s:edit_win)
    call nvim_win_set_config(s:edit_win, opts)
  else
    let nr = nvim_create_buf(0, 0)
    call nvim_buf_set_option(nr, "buftype", "nofile")
    let opts['noautocmd'] = 1
    let s:edit_win = nvim_open_win(nr, v:true, opts)
  endif

  call nvim_win_set_option(s:edit_win, 'wrap', v:false)
  if a:0 >= 1
    call setbufline(nr, 1, a:1)
  endif
  return s:edit_win
endfunc

func s:CloseFloatEdit()
  if exists('#PromptDebugFloatEdit')
    au! PromptDebugFloatEdit
  endif
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
    call nvim_win_set_option(winid, 'hlsearch', v:false)
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
  augroup PromptDebugPreview
    for event in a:000
      exe printf("autocmd! %s * call s:ClosePreview()", event)
    endfor
  augroup END
endfunc

func s:ClosePreview()
  if exists('#PromptDebugPreview')
    au! PromptDebugPreview
  endif
  if exists("s:preview_win")
    let nr = winbufnr(s:preview_win)
    call nvim_win_close(s:preview_win, 1)
    call nvim_buf_delete(nr, #{force: 1})
    unlet s:preview_win
  endif
endfunc
"}}}

""""""""""""""""""""""""""""""""Ending the session""""""""""""""""""""""""""""{{{
func s:EndPromptDebug(job_id, exit_code, event)
  if exists('#User#PromptDebugStopPre')
    doauto <nomodeline> User PromptDebugStopPre
  endif

  " In case user forgot to type brsave
  call s:SaveBreakpoints('auto_saved_brs')

  silent! autocmd! PromptDebug
  silent! autocmd! PromptDebugPreview
  silent! autocmd! PromptDebugFloatEdit
  silent! autocmd! PromptDebugHistory
  silent! autocmd! PromptDebugCompletion

  call s:ClosePreview()
  call s:CloseFloatEdit()

  " Clear signs
  call s:ClearCursorSign()
  for id in keys(s:breakpoints)
    call s:ClearBreakpointSign(id, 0)
  endfor

  " Clear buffers
  for bufvar in s:bufvars
    let bufname = s:[bufvar]
    let nr = bufnr(bufname)
    if nr >= 0
      exe 'bwipe!' . nr
    endif
  endfor

  " Stop dependent jobs
  if exists('s:tty_job_id')
    let buffer = get(nvim_get_chan_info(s:tty_job_id), 'buffer', -1)
    call jobstop(s:tty_job_id)
    call jobwait([s:tty_job_id])
    if buffer >= 0
      exe "bwipe! " . buffer
    endif
  endif

  if exists('#User#PromptDebugStopPost')
    doauto <nomodeline> User PromptDebugStopPost
  endif
endfunc

" }}}
