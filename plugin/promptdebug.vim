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

func PromptDebugGoToCapture()
  let ids = win_findbuf(s:capture_bufnr)
  if empty(ids)
    exe "tabnew " . s:capture_bufname
  else
    call win_gotoid(ids[0])
  endif
endfunc

func PromptDebugGoToOutput()
  if exists('s:host')
    echo "TODO: No output available for remote targets"
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

func PromptDebugSendCommands(...)
  for cmd in a:000
    call PromptDebugSendCommand(cmd)
  endfor
endfunc

func PromptDebugSendCommand(cmd)
  if !PromptDebugIsStopped()
    echo "Cannot send command. Program is running."
    return
  endif
  let msg = '-interpreter-exec console ' .. s:EscapeMIArgument(a:cmd)
  call s:SendMICommandNoOutput(msg)
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
  let s:callbacks[token] = a:Callback
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

function s:SendMICommandNoOutput(cmd)
  let IgnoreOutput = {_ -> {}}
  return s:SendMICommand(a:cmd, IgnoreOutput)
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

func s:SwitchAsmMode(asm_mode)
  if s:asm_mode != a:asm_mode
    let s:asm_mode = a:asm_mode
    call s:ClearCursorSign()
    let cmd = printf('-stack-info-frame --thread %d --frame %d', s:selected_thread, s:selected_frame)
    call s:SendMICommand(cmd, {dict -> s:PlaceCursorSign(dict['frame'])})
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
  for varname in keys(s:)
    if varname != "command_hist"
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
        \ ['s:PrettyPrinterOptional', 'std::optional']
        \ ]
  " Set defaults for required variables
  let s:vars = #{}
  let s:thread_ids = #{}
  let s:breakpoints = #{}
  let s:multi_brs = #{}
  let s:callbacks = #{}
  let s:floating_output = 0
  let s:source_bufnr = -1
  let s:pid = 0
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
  return s:LaunchGdb()
endfunc

func s:LaunchGdb()
  " Open terminal controlling inferior i/o
  let tty = "/dev/null"
  if !exists("s:host")
    sp
    enew
    setlocal nobuflisted
    let s:tty_job_id = termopen("tail -f /dev/null", #{on_stdout: function('s:ProgramOutput')})
    let tty = nvim_get_chan_info(s:tty_job_id)['pty']
    quit
  endif

  let gdb_cmd = [g:promptdebugger]
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  call add(gdb_cmd, '-quiet')
  " Communicate with GDB in the background via MI interface
  call add(gdb_cmd, '--interpreter=mi')
  " Disable pagination, it causes everything to stop
  call extend(gdb_cmd, ['-iex', 'set pagination off'])
  " Ignore inferior stdout 
  call extend(gdb_cmd, ['-iex', 'set inferior-tty ' .. tty])
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

  " Add a few introductory lines
  if exists('s:host')
    call s:PromptShowNormal("Remote debugging " .. s:host)
  else
    call s:PromptShowNormal("Local debugging")
  endif

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

  startinsert
  return v:true
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
    if empty(msg) || msg[0:1] == '&"'
      continue
    endif
    if s:EmptyBuffer(s:io_bufnr)
      call setbufline(s:io_bufnr, 1, msg)
    else
      call appendbufline(s:io_bufnr, "$", msg)
    endif
  endfor
endfunc

func s:CommReset(timer_id)
  let s:comm_buf = ""
  call s:PromptShowWarning("Communication with GDB reset")
endfunc

func s:CommJoin(job_id, msgs, event)
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
      call s:CommOutput(msg)
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
  if PromptDebugIsStopped()
    let input = getbufline(s:prompt_bufnr, '$')[0]
    call s:PromptShowMessage([[input, "Normal"], ["^C", "Cursor"]])
    call s:SetPrompt("")
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
    call s:OpenScrollablePreview("History", reverse(copy(s:command_hist)))
    call s:ScrollPreview("1")
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
  call s:PromptShowNormal(getline('$'))
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

func s:StartLocally(str_args)
  if PromptDebugStart()
    let cmd_args = split(a:str_args, '\s')
    if len(cmd_args) >= 1
      call PromptDebugSendCommand("file " .. cmd_args[0])
      call PromptDebugSendCommand("start " .. join(cmd_args[1:]))
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
  call PromptDebugSendCommand("file " .. cmd_args[0])
  " Add a breakpoint with the current cursor position
  if !empty(filename)
    let br = printf("tbr %s:%d", filename, lnum)
    call PromptDebugSendCommand(br)
  endif
  call PromptDebugSendCommand("run " .. join(cmd_args[1:]))
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
  call PromptDebugSendCommand("attach " .. pid)
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
  let args = join(cmd[1:], " ")

  " Special commands (HEREDOC input)
  if name->s:IsCommand("commands", 3)
    return s:CommandsCommand(cmd[1:])
  endif

  " Unsupported commands
  if name->s:IsCommand("python", 2)
    return s:PromptShowError("No python support!")
  elseif name[0] == "!" || name->s:IsCommand("shell", 3)
    return s:PromptShowError("No shell support!")
  elseif name->s:IsCommand("edit", 2)
    return s:PromptShowError("No edit support!")
  endif

  " Custom commands
  if name == "qfsave"
    return s:QfSaveCommand()
  elseif name == "qfsource"
    return s:QfSourceCommand()
  endif

  " Overriding GDB commands
  if g:promptdebug_override_finish_and_return
    if name->s:IsCommand("finish", 3)
      return s:FinishCommand()
    elseif name->s:IsCommand("return", 3)
      return s:ReturnCommand()
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
    if name == "p" || name == "print"
      return s:PrintCommand(args)
    endif
  endif
  if g:promptdebug_override_f_and_bt
    if name->s:IsCommand("frame", 1)
      return s:FrameCommand(args)
    elseif name == "bt" || name->s:IsCommand("backtrace", 1)
      return s:BacktraceCommand(args)
    endif
  endif
  if g:promptdebug_override_t
    if name->s:IsCommand("thread", 1)
      return s:ThreadCommand(args)
    endif
  endif

  if g:promptdebug_override_info
    if cmd[0]->s:IsCommand("info", 3)
      if cmd[1]->s:IsCommand("threads", 2)
        return s:InfoThreadsCommand(get(cmd, 2, ''))
      elseif cmd[0]->s:IsCommand("info", 3) && cmd[1]->s:IsCommand("breakpoints", 2)
        return s:InfoBreakpointsCommand(get(cmd, 2, ''))
      endif
    endif
  endif

  " Good 'ol GDB commands
  let cmd_console = '-interpreter-exec console ' . s:EscapeMIArgument(a:cmd)

  if name->s:IsCommand("condition", 4) || name->s:IsCommand("delete", 1) ||
        \ name->s:IsCommand("disable", 3) || name->s:IsCommand("enable", 2) ||
        \ name->s:IsCommand("break", 2) || name->s:IsCommand("tbreak", 2) ||
        \ name->s:IsCommand("awatch", 2) || name->s:IsCommand("rwatch", 2) ||
        \ name->s:IsCommand("continue", 4) || name == "c" ||
        \ name->s:IsCommand("watch", 2)
    return s:SendMICommandNoOutput(cmd_console)
  endif

  " Run command and redirect output to floating window
  let s:floating_output = 1
  return s:SendMICommandNoOutput(cmd_console)
endfunc

func s:CommandsCommand(brs)
  if len(a:brs) > 1
    return s:PromptShowError("Expecting 1 breakpoint.")
  endif
  if empty(a:brs)
    let bp = max(keys(s:breakpoints))
  else
    let bp = a:brs[0]
  endif
  if !has_key(s:breakpoints, bp)
    call s:PromptShowError("Cannot set commands for breakpoint " .. bp)
  else
    let script = s:Get(s:breakpoints, bp, 'script', [])
    call s:OpenFloatEdit(30, 3, script)
    augroup PromptDebugFloatEdit
      exe printf("autocmd! WinClosed * call s:OnEditComplete(%d)", bp)
    augroup END
    $ " Go to end of float window
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
    call s:SendMICommand("-break-insert " . loc, function('s:HandleNewBreakpoint'))
  endfor
  call s:PromptShowNormal("Breakpoints loaded from quickfix")
endfunc

func s:QfSaveCommand()
  let valid_brs = filter(copy(s:breakpoints), 'has_key(v:val, "fullname")')
  let items = map(items(valid_brs), {_, item -> {
        \ "text": "Breakpoint " . item[0],
        \ "filename": item[1]['fullname'],
        \ "lnum": item[1]['lnum']
        \ }})
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
  call s:SendMICommand('-stack-list-frames', function('s:HandleFrameChange', [v:true]))
endfunc

func s:DownCommand()
  call s:SendMICommand('-stack-list-frames', function('s:HandleFrameChange', [v:false]))
endfunc

func s:AsmCommand()
  call s:SwitchAsmMode(s:asm_mode ? 0 : 1)
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

func s:ThreadCommand(id)
  let Cb = function('s:HandleThreadSelect')
  call s:SendMICommand('-thread-select ' .. s:EscapeMIArgument(a:id), Cb)
endfunc

func s:InfoThreadsCommand(id)
  if !empty(a:id)
    call s:PromptShowError("Command does not accept arguments")
  else
    let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
    let ids = sort(keys(s:thread_ids), 'N')
    for id in reverse(ids)
      let Cb = function('s:HandleThreadStack', [lnum, id])
      call s:SendMICommand('-stack-list-frames --thread ' . id, Cb)
    endfor
  endif
endfunc

func s:InfoBreakpointsCommand(id)
  if !empty(a:id)
    call s:PromptShowWarning("TODO: Command does not accept arguments")
  else
    let Cb = function('s:HandleBreakpointTable')
    call s:SendMICommand('-break-info', Cb)
  endif
endfunc
" }}}

""""""""""""""""""""""""""""""""Printing""""""""""""""""""""""""""""""""""""""{{{
func s:PromptShowMessage(msg)
  let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
  call s:PromptAppendMessage(lnum, a:msg)
endfunc

func s:PromptAppendMessage(lnum, msg)
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
  let source_line = getline(lnum)
  let leading_spaces = len(matchstr(source_line, '^\s*'))
  " Copy source line with syntax
  let text = ""
  let text_hl = ""
  let items = [[string(lnum), "debugJumpable"], ["\t", "Normal"]]
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
  call s:PromptShowMessage(items)

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

func s:PrintCommand(expr)
  let Cb = function('s:ShowVar', [a:expr])
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

func s:ShowVarAt(lnum, nesting, display_name, dict)
  let new_var = #{}

  let value = get(a:dict, "value", "")
  if empty(value)
    let value = "???"
  endif
  let new_var["value"] = value
  " TODO test
  let new_var["type"] = get(a:dict, 'type', '')
  let new_var['expandable'] = a:dict['numchild'] > 0
  let new_var['nesting'] = a:nesting
  let new_var['display_name'] = a:display_name
  let new_var['created'] = !has_key(a:dict, 'exp')
  let new_var['gdb_handle'] = a:dict['name']

  let s:vars[new_var['gdb_handle']] = new_var

  call s:ShowElided(a:lnum, new_var)
endfunc

func s:ShowVar(display_name, dict)
  let lnum = nvim_buf_line_count(s:prompt_bufnr) - 1
  call s:ShowVarAt(lnum, 0, a:display_name, a:dict)
endfunc

func s:ShowElided(lnum, var)
  let width = getbufvar(s:prompt_bufnr, '&sw')
  let indent = repeat(" ", a:var['nesting'] * width)

  let indent_item = [indent, "Normal"]
  let name_item = [a:var['display_name'] .. " = ", "Normal"]
  let value_item = [a:var['value'], "debugValue"]
  call s:PromptAppendMessage(a:lnum, [indent_item, name_item, value_item])

  " Mark the variable
  if a:var['expandable']
    let items = [[a:var['gdb_handle'], 'EndOfBuffer']]
    let ns = nvim_create_namespace('PromptDebugConcealVar')
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, 0, #{virt_text: items})
    " Highlight 'value_item' as debugExpandable
    let col = len(indent_item[0]) + len(name_item[0])
    let end_col = col + len(value_item[0])
    let opts = #{end_col: end_col, hl_group: 'debugExpandable', priority: 10000}
    call nvim_buf_set_extmark(s:prompt_bufnr, ns, a:lnum, col, opts)
  endif
endfunc

func s:ShowEvaluation(lnum, nesting, name, dict)
  let fake_var = #{
        \ nesting: a:nesting,
        \ display_name: a:name,
        \ value: a:dict['value'],
        \ expandable: v:false
        \ }
  call s:ShowElided(a:lnum, fake_var)
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
    call s:PromptShowNormal(prompt_getprompt(s:prompt_bufnr))
    call s:PromptShowNormal("Jumping to frame #" .. keys[0])
    call s:FrameCommand(keys[0])
  elseif len(keys) == 2
    if keys[0] =~ '^[0-9]' && keys[1] =~ '^[0-9]'
      " Thread jump
      call s:PromptShowNormal(prompt_getprompt(s:prompt_bufnr))
      call s:PromptShowNormal("Jumping to thread ~" .. keys[0])
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
  return [[0, 'start', start_expr], [0, 'length', length_expr]]
endfunc

func s:PrettyPrinterString(expr)
  let str_expr = printf('%s._M_dataplus._M_p', a:expr)
  let length_expr = printf('%s._M_string_length', a:expr)
  return [[0, 'string', str_expr], [0, 'length', length_expr]]
endfunc

func s:PrettyPrinterOptional(expr)
  let has_value_expr = printf('%s._M_payload._M_engaged', a:expr)
  let value_expr = printf('%s._M_payload._M_payload._M_value', a:expr)
  return [[0, 'has_value', has_value_expr], [1, 'value', value_expr]]
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
  execute printf('let msg = %s', a:msg[1:])
  let lines = split(msg, "\n", 1)
  if s:floating_output
    " Lazily open the window
    if !exists('s:edit_win')
      call s:OpenFloatEdit(20, 1, [])
      augroup PromptDebugFloatEdit
        autocmd! WinClosed * call s:DisableStream()
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

func s:DisableStream()
  let s:floating_output = 0
  call s:CloseFloatEdit()
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
        call s:PromptShowNormal("Switching to thread ~" .. a:dict['thread-id'])
      endif
      let s:selected_thread = a:dict['thread-id']
    endif
    " XXX: Not too pretty to put it here (or anywhere for that matter)
    " Execute breakpoint commands
    if get(a:dict, 'reason', '') == 'breakpoint-hit'
      let bkptno = a:dict['bkptno']
      if has_key(s:breakpoints, bkptno)
        let bkpt = s:breakpoints[bkptno]
        if has_key(bkpt, 'script')
          for cmd in bkpt['script']
            call s:PromptOutput(cmd)
          endfor
        endif
      endif
    endif
    let s:stopped = 1
    let s:selected_frame = 0
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
  call s:PromptShowNormal("")

  if reason == 'breakpoint-hit'
    let msg = "Breakpoint hit."
  elseif reason == 'watchpoint-scope'
    let msg = "Watchpoint out of scope!"
  elseif reason == 'no-history'
    let msg = "Cannot continue reverse execution!"
  elseif reason =~ 'watchpoint'
    let msg = "Watchpoint hit"
  elseif reason == 'exited-signalled'
    return s:PromptShowWarning("Process exited due to signal: " .. a:dict['signal-name'])
  elseif reason == 'exited'
    return s:PromptShowWarning("Process exited with code " .. a:dict['exit-code'])
  elseif reason == 'exited-normally'
    return s:PromptShowNormal("Process exited normally. ")
  elseif reason == 'signal-received'
    return s:PromptShowNormal("Process received signal: " .. a:dict['signal-name'])
  elseif reason == 'solib-event' || reason =~ 'fork' || reason =~ 'syscall' || reason == 'exec'
    let msg = "Event " .. string(reason)
  else
    let msg = reason
  endif
  let items = [["Stopped", "Italic"], [", reason: " .. msg, "Normal"]]
  call s:PromptShowMessage(items)
endfunc

func s:PlaceCursorSign(dict)
  if s:asm_mode
    call s:PlaceAsmCursor(a:dict)
  else
    call s:PlaceSourceCursor(a:dict)
  endif
endfunc

func s:PlaceSourceCursor(dict)
  let ns = nvim_create_namespace('PromptDebugPC')
  let filename = get(a:dict, 'fullname', '')
  let lnum = get(a:dict, 'line', '')
  if filereadable(filename) && str2nr(lnum) > 0
    let origw = win_getid()
    call PromptDebugGoToSource()
    if expand("%:p") != filename
      exe "e " . fnameescape(filename)
    endif
    exe lnum
    normal z.
    " Display a hint where we stopped
    if g:promptdebug_show_source
      call s:PromptShowSourceLine()
    endif
    " Highlight stopped line
    call nvim_buf_set_extmark(0, ns, lnum - 1, 0, #{line_hl_group: 'debugPC'})
    let s:source_bufnr = bufnr()
    call win_gotoid(origw)
  else
    call s:PromptShowNormal("???\tNo source available.")
  endif
endfunc

func s:PlaceAsmCursor(dict)
  let addr = get(a:dict, 'addr', '')
  if !s:SelectAsmAddr(addr)
    " Reload disassembly
    let cmd = printf("-data-disassemble -a %s 0", addr)
    let Cb = function('s:HandleDisassemble', [addr])
    call s:SendMICommand(cmd, Cb)
  endif
endfunc

func s:SelectAsmAddr(addr)
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
  if has_key(a:dict, 'pid')
    let s:pid = a:dict['pid']
    " Add some logs
    call s:PromptShowNormal("Process id: " .. s:pid)
    let cmd = ['stat', '--printf=%G', '/proc/' . s:pid]
    if exists('s:host')
      let cmd = ["ssh", s:host, join(cmd, ' ')]
    endif
    let user = system(cmd)
    if !v:shell_error
      call s:PromptShowNormal("Running as: " .. user)
    endif
    " Issue autocmds
    if exists('#User#PromptDebugRunPost') && !exists('s:program_run_once')
      doauto <nomodeline> User PromptDebugRunPost
      let s:program_run_once = v:true
    endif
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
    return
  endif
  if has_key(bkpt, 'pending')
    let normal = 'Breakpoint ' . bkpt['number'] . ' (' . bkpt['pending']  . ') pending.'
    call s:PromptShowNormal(normal)
    return
  endif

  call s:ClearBreakpointSign(bkpt['number'], 0)
  if has_key(bkpt, 'addr') && bkpt['addr'] == '<MULTIPLE>'
    for location in bkpt['locations']
      let id = s:AddBreakpoint(location, bkpt)
      call s:PlaceBreakpointSign(id)
    endfor
  else
    let id = s:AddBreakpoint(bkpt, #{})
    call s:PlaceBreakpointSign(id)
  endif
endfunc

func s:AddBreakpoint(bkpt, parent)
  let id = a:bkpt['number']
  if !has_key(s:breakpoints, id)
    let s:breakpoints[id] = #{}
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
  return id
endfunc

" Handle deleting a breakpoint
" Will remove the sign that shows the breakpoint
func s:HandleBreakpointDelete(dict)
  let id = a:dict['id']
  call s:ClearBreakpointSign(id, 1)
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
  let bufnr = bufnr(breakpoint['fullname'])
  let placed = has_key(breakpoint, 'extmark')
  if bufnr > 0 && !placed
    call bufload(bufnr)
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
func s:HandleBreakpointTable(dict)
  let table = s:GetListWithKeys(a:dict['BreakpointTable'], 'body')
  if empty(table)
    call s:PromptShowError("No breakpoints.")
    return
  endif
  for bkpt in table
    if has_key(bkpt, 'locations')
      for location in bkpt['locations']
        call s:FormatBreakpointMessage(location, bkpt)
      endfor
    else
      call s:FormatBreakpointMessage(bkpt, #{})
    endif
  endfor
endfunc

func s:FormatBreakpointMessage(bkpt, parent)
  let nr = a:bkpt['number']
  let enabled = a:bkpt['enabled'] == 'y'
  if !empty(a:parent)
    let enabled = enabled && a:parent['enabled'] == 'y'
  endif
  let jumpable = has_key(a:bkpt, 'fullname') && filereadable(a:bkpt['fullname'])

  if has_key(a:bkpt, 'at')
    let location = a:bkpt['at']
  elseif has_key(a:bkpt, 'func')
    let location = a:bkpt['func']
  elseif jumpable
    let basename = fnamemodify(a:bkpt['fullname'], ':t')
    let location = basename .. ":" .. a:bkpt['line']
  else
    let location = a:bkpt['addr']
  endif

  let number_item = ["*" .. nr, 'debugIdentifier']
  let in_item = [" in ", 'Normal']
  let location_item = [location, jumpable ? 'debugJumpable' : 'debugLocation']

  call s:PromptShowMessage([number_item, in_item, location_item])
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

func s:HandleThreadStack(lnum, id, dict)
  let prefix = "/home/" .. $USER
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    let fullname = get(frame, 'fullname', '')
    if filereadable(fullname) && stridx(fullname, prefix) == 0
      let jumpable = has_key(frame, 'file') && filereadable(frame['file'])
      let msg = s:FormatFrameMessage(jumpable, frame)
      " Display thread id instead of frame id
      let msg[0][0] = "~" .. a:id
      call s:PromptAppendMessage(a:lnum, msg)
      if jumpable
        call s:ConcealJumpAt(a:lnum, a:id, frame['level'])
      endif
      break
    endif
  endfor
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
  call s:PromptShowNormal("Breakpoint commands updated.")
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

func s:FormatFrameMessage(jumpable, dict)
  let frame = a:dict
  let location = "???"
  if has_key(frame, 'file')
    let location = fnamemodify(frame['file'], ":t")
  endif
  let level_item = ["#" .. frame['level'], 'debugIdentifier']
  let in_item = [" in ", 'Normal']
  let func_item = [frame["func"], a:jumpable ? 'debugJumpable' : 'Normal']
  let addr_item = [frame["addr"], 'Normal']
  let at_item = [" at ", 'Normal']
  let loc_item = [location, 'debugLocation']
  let where_item = (func_item[0] == "??" ? addr_item : func_item)
  return [level_item, in_item, where_item, at_item, loc_item]
endfunc

func s:HandleFrameJump(level, dict)
  let frame = a:dict['frame']
  call s:ClearCursorSign()
  call s:PlaceCursorSign(frame)
  let s:selected_frame = a:level
  call s:SendMICommandNoOutput('-stack-select-frame ' .. s:selected_frame)
endfunc

func s:HandleFrameList(dict)
  let frames = s:GetListWithKeys(a:dict, 'stack')
  for frame in frames
    let jumpable = has_key(frame, 'file') && filereadable(frame['file'])
    let msg = s:FormatFrameMessage(jumpable, frame)
    call s:PromptShowMessage(msg)
    if jumpable
      call s:ConcealJump(frame['level'])
    endif
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
      call s:PromptShowMessage([["Switching to frame #" .. frames[0]['level'], "Normal"]])
      call s:RefreshCursorSign(frames[0])
      let s:selected_frame = frames[0]['level']
      return s:SendMICommandNoOutput('-stack-select-frame ' .. s:selected_frame)
    endif
  else
    let prefix = "/home/" .. $USER
    for frame in frames
      let fullname = get(frame, 'fullname', '')
      if filereadable(fullname) && stridx(fullname, prefix) == 0
        call s:PromptShowMessage([["Switching to frame #" .. frame['level'], "Normal"]])
        call s:RefreshCursorSign(frame)
        let s:selected_frame = frame['level']
        return s:SendMICommandNoOutput('-stack-select-frame ' .. s:selected_frame)
      endif
    endfor
  endif
  if a:going_up
    call s:PromptShowError("At topmost frame")
  else
    call s:PromptShowError("At bottom of stack")
  endif
endfunc

func s:HandleError(dict)
  call s:ClosePreview()
  call s:CloseFloatEdit()
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
