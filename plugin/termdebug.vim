" Debugger plugin using gdb.
"
" Author: Bram Moolenaar
" Copyright: Vim license applies, see ":help license"
" Last Change: 2021 Nov 27
"
" WORK IN PROGRESS - Only the basics work
" Note: On MS-Windows you need a recent version of gdb.  The one included with
" MingW is too old (7.6.1).
" I used version 7.12 from http://www.equation.com/servlet/equation.cmd?fa=gdb
"
" There are two ways to run gdb:
" - In a terminal window; used if possible, does not work on MS-Windows
"   Not used when g:termdebug_use_prompt is set to 1.
" - Using a "prompt" buffer; may use a terminal window for the program
"
" For both the current window is used to view source code and shows the
" current statement from gdb.
"
" USING A TERMINAL WINDOW
"
" Opens two visible terminal windows:
" 1. runs a pty for the debugged program, as with ":term NONE"
" 2. runs gdb, passing the pty of the debugged program
" A third terminal window is hidden, it is used for communication with gdb.
"
" USING A PROMPT BUFFER
"
" Opens a window with a prompt buffer to communicate with gdb.
" Gdb is run as a job with callbacks for I/O.
" On Unix another terminal window is opened to run the debugged program
" On MS-Windows a separate console is opened to run the debugged program
"
" The communication with gdb uses GDB/MI.  See:
" https://sourceware.org/gdb/current/onlinedocs/gdb/GDB_002fMI.html
"
" For neovim compatibility, the vim specific calls were replaced with neovim
" specific calls:
"   term_start -> term_open
"   term_sendkeys -> chansend
"   term_getline -> getbufline
"   job_info && term_getjob -> using linux command ps to get the tty
"   balloon -> nvim floating window
"
" The code for opening the floating window was taken from the beautiful
" implementation of LanguageClient-Neovim:
" https://github.com/autozimu/LanguageClient-neovim/blob/0ed9b69dca49c415390a8317b19149f97ae093fa/autoload/LanguageClient.vim#L304
"
" Neovim terminal also works seamlessly on windows, which is why the ability
" Author: Bram Moolenaar
" Copyright: Vim license applies, see ":help license"

" In case this gets sourced twice.
if exists(':Termdebug')
  finish
endif

" The terminal feature does not work with gdb on win32.
if !has('win32')
  let s:way = 'terminal'
else
  let s:way = 'prompt'
endif

let s:keepcpo = &cpo
set cpo&vim

" The command that starts debugging, e.g. ":Termdebug vim".
" To end type "quit" in the gdb window.
command -nargs=* -complete=file -bang Termdebug call s:StartDebug(<bang>0, <f-args>)
command -nargs=+ -complete=file -bang TermdebugCommand call s:StartDebugCommand(<bang>0, <f-args>)

function! TermDebugIsOpen()
  return exists('s:gdbwin')
endfunction

function! TermDebugGoToPC()
  for signsData in sign_getplaced()
    let signDebugPC = filter(signsData['signs'], {_, s -> s['name'] == "debugPC"})
    if !empty(signDebugPC)
      let lnum = signDebugPC[0]['lnum']
      let bufnr = signsData['bufnr']
      let col = getpos('.')[2]
      exe "buffer " . bufnr
      call cursor(lnum, col)
      return
    endif
  endfor
endfunc

func TermDebugSendCommand(cmd)
  if s:way == 'prompt'
    call chansend(s:gdbjob, a:cmd . "\n")
  else
    if !s:stopped
      echoerr "Cannot send command '" . a:cmd . "'. Program is running."
      return
    endif
    call chansend(s:gdb_job_id, a:cmd . "\r")
  endif
endfunc

" Name of the gdb command, defaults to "gdb".
if !exists('g:termdebugger')
  let g:termdebugger = 'gdb'
endif

let s:pc_id = 12
let s:asm_id = 13
let s:break_id = 14  " breakpoint number is added to this
let s:stopped = 1

let s:parsing_disasm_msg = 0
let s:asm_lines = []
let s:asm_addr = ''

" Take a breakpoint number as used by GDB and turn it into an integer.
func s:Breakpoint2SignNumber(id)
  return s:break_id + a:id
endfunction

func s:Highlight(init, old, new)
  let default = a:init ? 'default ' : ''
  if a:new ==# 'light' && a:old !=# 'light'
    exe "hi " . default . "debugPC term=reverse ctermbg=lightblue guibg=lightblue"
  elseif a:new ==# 'dark' && a:old !=# 'dark'
    exe "hi " . default . "debugPC term=reverse ctermbg=darkblue guibg=darkblue"
  endif
endfunc

call s:Highlight(1, '', &background)
hi default debugBreakpoint gui=reverse guibg=red
hi default debugBreakpointDisabled gui=reverse guibg=gray

func s:StartDebug(bang, ...)
  " First argument is the command to debug, second core file or process ID.
  call s:StartDebug_internal({'gdb_args': a:000, 'bang': a:bang})
endfunc

func s:StartDebugCommand(bang, ...)
  " First argument is the command to debug, rest are run arguments.
  call s:StartDebug_internal({'gdb_args': [a:1], 'proc_args': a:000[1:], 'bang': a:bang})
endfunc

func s:StartDebug_internal(dict)
  if exists('s:gdbwin')
    echoerr 'Terminal debugger already running, cannot run two'
    return
  endif
  if !executable(g:termdebugger)
    echoerr 'Cannot execute debugger program "' .. g:termdebugger .. '"'
    return
  endif

  let s:ptywin = 0
  let s:pid = 0
  let s:asmwin = 0

  if exists('#User#TermdebugStartPre')
    doauto <nomodeline> User TermdebugStartPre
  endif

  " Uncomment this line to write logging in "debuglog".
  " call ch_logfile('debuglog', 'w')

  let s:sourcewin = win_getid(winnr())

  " Remember the old value of 'signcolumn' for each buffer that it's set in, so
  " that we can restore the value for all buffers.
  let b:save_signcolumn = &signcolumn
  let s:signcolumn_buflist = [bufnr()]

  let s:save_columns = 0
  let s:allleft = 0
  if exists('g:termdebug_wide')
    if &columns < g:termdebug_wide
      let s:save_columns = &columns
      let &columns = g:termdebug_wide
      " If we make the Vim window wider, use the whole left halve for the debug
      " windows.
      let s:allleft = 1
    endif
    let s:vertical = 1
  else
    let s:vertical = 0
  endif

  " Override using a terminal window by setting g:termdebug_use_prompt to 1.
  let use_prompt = exists('g:termdebug_use_prompt') && g:termdebug_use_prompt
  if !has('win32') && !use_prompt
    let s:way = 'terminal'
   else
    let s:way = 'prompt'
   endif

  if s:way == 'prompt'
    call s:StartDebug_prompt(a:dict)
  else
    call s:StartDebug_term(a:dict)
  endif

  if exists('g:termdebug_disasm_window')
    if g:termdebug_disasm_window
      let curwinid = win_getid(winnr())
      call s:GotoAsmwinOrCreateIt()
      call win_gotoid(curwinid)
    endif
  endif

  if exists('#User#TermdebugStartPost')
    doauto <nomodeline> User TermdebugStartPost
  endif
endfunc

" Use when debugger didn't start or ended.
func s:CloseBuffers()
  exe 'bwipe! ' . s:ptybuf
  unlet! s:gdbwin
endfunc

func s:CheckGdbRunning()
  if nvim_get_chan_info(s:gdb_job_id) == {}
      echoerr string(g:termdebugger) . ' exited unexpectedly'
      call s:CloseBuffers()
      return ''
  endif
  return 'ok'
endfunc

func s:StartDebug_term(dict)
  " Open a terminal window without a job, to run the debugged program in.
  execute s:vertical ? 'vnew' : 'new'
  let s:pty_job_id = termopen('tail -f /dev/null')
  if s:pty_job_id == 0
    echoerr 'invalid argument (or job table is full) while opening terminal window'
    return
  elseif s:pty_job_id == -1
    echoerr 'Failed to open the program terminal window'
    return
  endif
  let pty_job_info = nvim_get_chan_info(s:pty_job_id)
  let s:ptybuf = pty_job_info['buffer']
  let pty = pty_job_info['pty']
  let s:ptywin = win_getid(winnr())
  if s:vertical
    " Assuming the source code window will get a signcolumn, use two more
    " columns for that, thus one less for the terminal window.
    exe (&columns / 2 - 1) . "wincmd |"
    if s:allleft
      " use the whole left column
      wincmd H
    endif
  endif

  " Create a hidden terminal window to communicate with gdb
  let s:comm_job_id = jobstart('tail -f /dev/null;#gdb communication', {
        \ 'on_stdout': function('s:CommOutput'),
        \ 'pty': v:true,
        \ })
  " hide terminal buffer
  if s:comm_job_id == 0
    echoerr 'invalid argument (or job table is full) while opening communication terminal window'
    exe 'bwipe! ' . s:ptybuf
    return
  elseif s:comm_job_id == -1
    echoerr 'Failed to open the communication terminal window'
    exe 'bwipe! ' . s:ptybuf
    return
  endif
  let comm_job_info = nvim_get_chan_info(s:comm_job_id)
  let commpty = comm_job_info['pty']

  let gdb_args = get(a:dict, 'gdb_args', [])
  let proc_args = get(a:dict, 'proc_args', [])

  let gdb_cmd = [g:termdebugger]
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  let gdb_cmd += ['-quiet']
  " Disable pagination, it causes everything to stop at the gdb
  let gdb_cmd += ['-iex', 'set pagination off']
  " Interpret commands while the target is running.  This should usually only
  " be exec-interrupt, since many commands don't work properly while the
  " target is running (so execute during startup).
  let gdb_cmd += ['-iex', 'set mi-async on']
  " Open a terminal window to run the debugger.
  let gdb_cmd += ['-tty', pty]
  " Command executed _after_ startup is done, provides us with the necessary feedback
  let gdb_cmd += ['-ex', 'echo startupdone\n']

  " Adding arguments requested by the user
  let gdb_cmd += gdb_args

  execute 'new'
  " call ch_log('executing "' . join(gdb_cmd) . '"')
  let s:gdb_job_id = termopen(gdb_cmd, {'on_exit': function('s:EndTermDebug')})
  if s:gdb_job_id == 0
    echoerr 'invalid argument (or job table is full) while opening gdb terminal window'
    exe 'bwipe! ' . s:ptybuf
    return
  elseif s:gdb_job_id == -1
    echoerr 'Failed to open the gdb terminal window'
    call s:CloseBuffers()
    return
  endif
  let gdb_job_info = nvim_get_chan_info(s:gdb_job_id)
  let s:gdbbuf = gdb_job_info['buffer']
  let s:gdbwin = win_getid(winnr())

  " Wait for the "startupdone" message before sending any commands.
  let try_count = 0
  while 1
    if s:CheckGdbRunning() != 'ok'
      return
    endif

    for lnum in range(1, 200)
      if get(getbufline(s:gdbbuf, lnum), 0, '') =~ 'startupdone'
        let try_count = 9999
        break
      endif
    endfor
    let try_count += 1
    if try_count > 300
      " done or give up after five seconds
      break
    endif
    sleep 10m
  endwhile

  " Set arguments to be run.
  if len(proc_args)
    call chansend(s:gdb_job_id, 'server set args ' . join(proc_args) . "\r")
  endif

  " Connect gdb to the communication pty, using the GDB/MI interface.
  " Prefix "server" to avoid adding this to the history.
  call chansend(s:gdb_job_id, 'server new-ui mi ' . commpty . "\r")

  " Wait for the response to show up, users may not notice the error and wonder
  " why the debugger doesn't work.
  let try_count = 0
  while 1
    if s:CheckGdbRunning() != 'ok'
      return
    endif

    let response = ''
    for lnum in range(1, 200)
      let line1 = get(getbufline(s:gdbbuf, lnum), 0, '')
      let line2 = get(getbufline(s:gdbbuf, lnum + 1), 0, '')
      if line1 =~ 'new-ui mi '
        " response can be in the same line or the next line
        let response = line1 . line2
        if response =~ 'Undefined command'
          echoerr 'Sorry, your gdb is too old, gdb 7.12 is required'
          " CHECKME: possibly send a "server show version" here
          call s:CloseBuffers()
          return
        endif
        if response =~ 'New UI allocated'
          " Success!
          break
        endif
      elseif line1 =~ 'Reading symbols from' && line2 !~ 'new-ui mi '
        " Reading symbols might take a while, try more times
        let try_count -= 1
      endif
    endfor
    if response =~ 'New UI allocated'
      break
    endif
    let try_count += 1
    if try_count > 100
      echoerr 'Cannot check if your gdb works, continuing anyway'
      break
    endif
    sleep 10m
  endwhile

  " Set the filetype, this can be used to add mappings.
  set filetype=termdebug

  call s:StartDebugCommon(a:dict)
endfunc

func s:StartDebug_prompt(dict)
  " Open a window with a prompt buffer to run gdb in.
  if s:vertical
    vertical new
  else
    new
  endif
  let s:gdbwin = win_getid(winnr())
  let s:promptbuf = bufnr('')
  call prompt_setprompt(s:promptbuf, 'gdb> ')
  set buftype=prompt
  file gdb
  call prompt_setcallback(s:promptbuf, function('s:PromptCallback'))
  call prompt_setinterrupt(s:promptbuf, function('s:PromptInterrupt'))

  if s:vertical
    " Assuming the source code window will get a signcolumn, use two more
    " columns for that, thus one less for the terminal window.
    exe (&columns / 2 - 1) . "wincmd |"
  endif

  let gdb_args = get(a:dict, 'gdb_args', [])
  let proc_args = get(a:dict, 'proc_args', [])

  let gdb_cmd = [g:termdebugger]
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  let gdb_cmd += ['-quiet']
  " Disable pagination, it causes everything to stop at the gdb, needs to be run early
  let gdb_cmd += ['-iex', 'set pagination off']
  " Interpret commands while the target is running.  This should usually only
  " be exec-interrupt, since many commands don't work properly while the
  " target is running (so execute during startup).
  let gdb_cmd += ['-iex', 'set mi-async on']
  " directly communicate via mi2
  let gdb_cmd += ['--interpreter=mi2']

  " Adding arguments requested by the user
  let gdb_cmd += gdb_args

  " call ch_log('executing "' . join(gdb_cmd) . '"')
  let s:gdbjob = jobstart(gdb_cmd, {
    \ 'on_exit': function('s:EndPromptDebug'),
    \ 'on_stdout': function('s:GdbOutCallback'),
    \ })
  if s:gdbjob == 0
    echoerr 'invalid argument (or job table is full) while starting gdb job'
    exe 'bwipe! ' . s:ptybuf
    return
  elseif s:gdbjob == -1
    echoerr 'Failed to start the gdb job'
    call s:CloseBuffers()
    return
  endif

  let s:ptybuf = 0
  if has('win32')
    " MS-Windows: run in a new console window for maximum compatibility
    call s:SendCommand('set new-console on')
  else
    " Unix: Run the debugged program in a terminal window.  Open it below the
    " gdb window.
    execute 'new'
    wincmd x | wincmd j
    belowright let s:pty_job_id = termopen('tail -f /dev/null;#gdb program')
    if s:pty_job_id == 0
      echoerr 'invalid argument (or job table is full) while opening terminal window'
      return
    elseif s:pty_job_id == -1
      echoerr 'Failed to open the program terminal window'
      return
    endif
    let pty_job_info = nvim_get_chan_info(s:pty_job_id)
    let s:ptybuf = pty_job_info['buffer']
    let pty = pty_job_info['pty']
    let s:ptywin = win_getid(winnr())
    call s:SendCommand('tty ' . pty)

    " Since GDB runs in a prompt window, the environment has not been set to
    " match a terminal window, need to do that now.
    call s:SendCommand('set env TERM = xterm-color')
    call s:SendCommand('set env ROWS = ' . winheight(s:ptywin))
    call s:SendCommand('set env LINES = ' . winheight(s:ptywin))
    call s:SendCommand('set env COLUMNS = ' . winwidth(s:ptywin))
    call s:SendCommand('set env COLORS = ' . &t_Co)
    call s:SendCommand('set env VIM_TERMINAL = ' . v:version)
  endif
  call s:SendCommand('set print pretty on')
  call s:SendCommand('set breakpoint pending on')

  " Set arguments to be run
  if len(proc_args)
    call s:SendCommand('set args ' . join(proc_args))
  endif

  call s:StartDebugCommon(a:dict)
endfunc

func s:StartDebugCommon(dict)
  " Sign used to highlight the line where the program has stopped.
  " There can be only one.
  sign define debugPC linehl=debugPC

  call s:InstallCommands()
  call win_gotoid(s:gdbwin)
  exe "file Gdb terminal"

  " Contains breakpoints that have been placed, key is a string with the GDB
  " breakpoint number.
  let s:breakpoints = {}

  augroup TermDebug
    au BufRead * call s:BufRead()
    au OptionSet background call s:Highlight(0, v:option_old, v:option_new)
  augroup END

  call win_gotoid(s:ptywin)
  exe "file Communication terminal"
  q "Close the command window
  call win_gotoid(s:gdbwin)
  startinsert
endfunc

" Send a command to gdb.  "cmd" is the string without line terminator.
func s:SendCommand(cmd)
  "call ch_log('sending to gdb: ' . a:cmd)
  if s:way == 'prompt'
    call chansend(s:gdbjob, a:cmd . "\n")
  else
    call chansend(s:comm_job_id, a:cmd . "\r")
  endif
endfunc

" Function called when entering a line in the prompt buffer.
func s:PromptCallback(text)
  call s:SendCommand(a:text)
endfunc

" Function called when pressing CTRL-C in the prompt buffer and when placing a
" breakpoint.
func s:PromptInterrupt()
  " call ch_log('Interrupting gdb')
  if has('win32')
    " Using job_stop() does not work on MS-Windows, need to send SIGTRAP to
    " the debugger program so that gdb responds again.
    if s:pid == 0
      echoerr 'Cannot interrupt gdb, did not find a process ID'
    else
      call debugbreak(s:pid)
    endif
  else
    call jobstop(s:gdbjob)
  endif
endfunc

" Function called when gdb outputs text.
func s:GdbOutCallback(job_id, msgs, event)
  "call ch_log('received from gdb: ' . a:text)

  " Drop the gdb prompt, we have our own.
  " Drop status and echo'd commands.
  call filter(a:msgs, { index, val ->
        \ val !=# '(gdb)' && val !=# '^done' && val[0] !=# '&'})

  let lines = []
  let index = 0

  for msg in a:msgs
    if msg =~ '^\^error,msg='
      if exists('s:evalexpr')
            \ && s:DecodeMessage(msg[11:])
            \    =~ 'A syntax error in expression, near\|No symbol .* in current context'
        " Silently drop evaluation errors.
        call remove(a:msgs, index)
        unlet s:evalexpr
        continue
      endif
    elseif msg[0] == '~'
      call add(lines, s:DecodeMessage(msg[1:]))
      call remove(a:msgs, index)
      continue
    endif
    let index += 1
  endfor

  let curwinid = win_getid(winnr())
  call win_gotoid(s:gdbwin)

  " Add the output above the current prompt.
  for line in lines
    call append(line('$') - 1, line)
  endfor
  if !empty(lines)
    set modified
  endif

  call win_gotoid(curwinid)
  call s:CommOutput(a:job_id, a:msgs, a:event)
endfunc

" Decode a message from gdb.  quotedText starts with a ", return the text up
" to the next ", unescaping characters:
" - remove line breaks
" - change \\t to \t
" - change \0xhh to \xhh
" - change \ooo to octal
" - change \\ to \
func s:DecodeMessage(quotedText)
  if a:quotedText[0] != '"'
    echoerr 'DecodeMessage(): missing quote in ' . a:quotedText
    return
  endif
  return a:quotedText
        \->substitute('^"\|".*\|\\n', '', 'g')
        \->substitute('\\t', "\t", 'g')
        \->substitute('\\0x\(\x\x\)', {-> eval('"\x' .. submatch(1) .. '"')}, 'g')
        \->substitute('\\\o\o\o', {-> eval('"' .. submatch(0) .. '"')}, 'g')
        \->substitute('\\\\', '\', 'g')
endfunc

" Extract the "name" value from a gdb message with fullname="name".
func s:GetFullname(msg)
  if a:msg !~ 'fullname'
    return ''
  endif
  let name = s:DecodeMessage(substitute(a:msg, '.*fullname=', '', ''))
  if has('win32') && name =~ ':\\\\'
    " sometimes the name arrives double-escaped
    let name = substitute(name, '\\\\', '\\', 'g')
  endif
  return name
endfunc

" Extract the "addr" value from a gdb message with addr="0x0001234".
func s:GetAsmAddr(msg)
  if a:msg !~ 'addr='
    return ''
  endif
  let addr = s:DecodeMessage(substitute(a:msg, '.*addr=', '', ''))
  return addr
endfunc

function s:EndTermDebug(job_id, exit_code, event)
  if exists('#User#TermdebugStopPre')
    doauto <nomodeline> User TermdebugStopPre
  endif

  unlet s:gdbwin

  call s:EndDebugCommon()
endfunc

func s:EndDebugCommon()
  let curwinid = win_getid(winnr())

  if exists('s:ptybuf') && s:ptybuf
    exe 'bwipe! ' . s:ptybuf
  endif

  if exists('s:gdbbuf') && s:gdbbuf
    exe 'bwipe! ' . s:gdbbuf
  endif

  let asmbuf = bufnr('Termdebug-asm-listing')
  if asmbuf > 0
    exe 'bwipe! ' . asmbuf
  endif

  " Restore 'signcolumn' in all buffers for which it was set.
  call win_gotoid(s:sourcewin)
  let was_buf = bufnr()
  for bufnr in s:signcolumn_buflist
    if bufexists(bufnr)
      exe bufnr .. "buf"
      if exists('b:save_signcolumn')
        let &signcolumn = b:save_signcolumn
        unlet b:save_signcolumn
      endif
    endif
  endfor
  exe was_buf .. "buf"

  call s:DeleteCommands()

  call win_gotoid(curwinid)

  if s:save_columns > 0
    let &columns = s:save_columns
  endif

  if exists('#User#TermdebugStopPost')
    doauto <nomodeline> User TermdebugStopPost
  endif

  au! TermDebug
endfunc

func s:EndPromptDebug(job_id, exit_code, event)
  if exists('#User#TermdebugStopPre')
    doauto <nomodeline> User TermdebugStopPre
  endif

  let curwinid = win_getid(winnr())
  call win_gotoid(s:gdbwin)
  close
  if curwinid != s:gdbwin
    call win_gotoid(curwinid)
  endif

  call s:EndDebugCommon()
  unlet s:gdbwin
  "call ch_log("Returning from EndPromptDebug()")
endfunc

" - CommOutput: disassemble $pc
" - CommOutput: &"disassemble $pc\n"
" - CommOutput: ~"Dump of assembler code for function main(int, char**):\n"
" - CommOutput: ~"   0x0000555556466f69 <+0>:\tpush   rbp\n"
" ...
" - CommOutput: ~"   0x0000555556467cd0:\tpop    rbp\n"
" - CommOutput: ~"   0x0000555556467cd1:\tret    \n"
" - CommOutput: ~"End of assembler dump.\n"
" - CommOutput: ^done

" - CommOutput: disassemble $pc
" - CommOutput: &"disassemble $pc\n"
" - CommOutput: &"No function contains specified address.\n"
" - CommOutput: ^error,msg="No function contains specified address."
func s:HandleDisasmMsg(msg)
  if a:msg =~ '^\^done'
    let curwinid = win_getid(winnr())
    if win_gotoid(s:asmwin)
      silent normal! gg0"_dG
      call setline(1, s:asm_lines)
      set nomodified
      set filetype=asm

      let lnum = search('^' . s:asm_addr)
      if lnum != 0
        exe 'sign unplace ' . s:asm_id
        exe 'sign place ' . s:asm_id . ' line=' . lnum . ' name=debugPC'
        exe 'normal ' . lnum . 'z.'
      endif

      call win_gotoid(curwinid)
    endif

    let s:parsing_disasm_msg = 0
    let s:asm_lines = []
  elseif a:msg =~ '^\^error,msg='
    if s:parsing_disasm_msg == 1
      " Disassemble call ran into an error. This can happen when gdb can't
      " find the function frame address, so let's try to disassemble starting
      " at current PC
      call s:SendCommand('disassemble $pc,+100')
    endif
    let s:parsing_disasm_msg = 0
  elseif a:msg =~ '\&\"disassemble \$pc'
    if a:msg =~ '+100'
      " This is our second disasm attempt
      let s:parsing_disasm_msg = 2
    endif
  else
    let value = substitute(a:msg, '^\~\"[ ]*', '', '')
    let value = substitute(value, '^=>[ ]*', '', '')
    let value = substitute(value, '\\n\"\r$', '', '')
    let value = substitute(value, '\r', '', '')
    let value = substitute(value, '\\t', ' ', 'g')

    if value != '' || !empty(s:asm_lines)
      call add(s:asm_lines, value)
    endif
  endif
endfunc

func s:CommOutput(job_id, msgs, event)

  for msg in a:msgs
    " remove prefixed NL
    if msg[0] == "\n"
      let msg = msg[1:]
    endif

    if s:parsing_disasm_msg
      call s:HandleDisasmMsg(msg)
    elseif msg != ''
      if msg =~ '^\(\*stopped\|\*running\|=thread-selected\)'
        call s:HandleCursor(msg)
      elseif msg =~ '^\^done,bkpt=' || msg =~ '^=breakpoint-created,'
        call s:HandleNewBreakpoint(msg, 0)
      elseif msg =~ '^=breakpoint-modified,'
        call s:HandleNewBreakpoint(msg, 1)
      elseif msg =~ '^=breakpoint-deleted,'
        call s:HandleBreakpointDelete(msg)
      elseif msg =~ '^=thread-group-started'
        call s:HandleProgramRun(msg)
      elseif msg =~ '^\^done,value='
        call s:HandleEvaluate(msg)
      elseif msg =~ '^\^error,msg='
        call s:HandleError(msg)
      elseif msg =~ '^disassemble'
        let s:parsing_disasm_msg = 1
        let s:asm_lines = []
      endif
    endif
  endfor
endfunc

" Install commands in the current window to control the debugger.
func s:InstallCommands()
  let save_cpo = &cpo
  set cpo&vim

  command! Gdb call s:GotoGdbwinOrCreateIt()
  command! Source call s:GotoSourcewinOrCreateIt()
  command! Asm call s:GotoAsmwinOrCreateIt()
  command! Com call s:GotoComwinOrCreateIt()
  command! -nargs=1 Break call s:GoToBreakpoint(<f-args>)

  let &cpo = save_cpo
endfunc

" Delete installed debugger commands in the current window.
func s:DeleteCommands()
  delcommand Gdb
  delcommand Source
  delcommand Asm
  delcommand Break

  exe 'sign unplace ' . s:pc_id
  sign undefine debugPC

  for [id, entry] in items(s:breakpoints)
    exe 'sign unplace ' . s:Breakpoint2SignNumber(id)
    if !has_key(entry, 'pending')
      exe "sign undefine debugBreakpoint" . id
    endif
  endfor

  unlet s:breakpoints
endfunc

func s:Run(args)
  if a:args != ''
    call s:SendCommand('-exec-arguments ' . a:args)
  endif
  call s:SendCommand('-exec-run')
endfunc

func s:SendEval(expr)
  " check for "likely" boolean expressions, in which case we take it as lhs
  if a:expr =~ "[=!<>]="
    let exprLHS = a:expr
  else
    " remove text that is likely an assignment
    let exprLHS = substitute(a:expr, ' *=.*', '', '')
  endif

  " encoding expression to prevent bad errors
  let expr = a:expr
  let expr = substitute(expr, '\\', '\\\\', 'g')
  let expr = substitute(expr, '"', '\\"', 'g')
  call s:SendCommand('-data-evaluate-expression "' . expr . '"')
  let s:evalexpr = exprLHS
endfunc

let s:ignoreEvalError = 0
let s:evalFromBalloonExpr = 0
let s:evalFromBalloonExprResult = ''

" Handle the result of data-evaluate-expression
func s:HandleEvaluate(msg)
  let value = substitute(a:msg, '.*value="\(.*\)"', '\1', '')
  let value = substitute(value, '\\"', '"', 'g')
  " multi-byte characters arrive in octal form
  let value = substitute(value, '\\\o\o\o', {-> eval('"' .. submatch(0) .. '"')}, 'g')
  let value = substitute(value, '', '\1', '')
  if s:evalFromBalloonExpr
    if s:evalFromBalloonExprResult == ''
      let s:evalFromBalloonExprResult = s:evalexpr . ': ' . value
    else
      let s:evalFromBalloonExprResult .= ' = ' . value
    endif
    let s:evalFromBalloonExprResult = split(s:evalFromBalloonExprResult, '\\n')
    call s:OpenHoverPreview(s:evalFromBalloonExprResult, v:null)
    let s:evalFromBalloonExprResult = ''
  else
    echomsg '"' . s:evalexpr . '": ' . value
  endif

  if s:evalexpr[0] != '*' && value =~ '^0x' && value != '0x0' && value !~ '"$'
    " Looks like a pointer, also display what it points to.
    let s:ignoreEvalError = 1
    call s:SendEval('*' . s:evalexpr)
  else
    let s:evalFromBalloonExprResult = ''
  endif
endfunc

function! s:ShouldUseFloatWindow() abort
  if exists('*nvim_open_win') && (get(g:, 'termdebug_useFloatingHover', 1) == 1)
    return v:true
  else
    return v:false
  endif
endfunction

function! s:CloseFloatingHoverOnCursorMove(win_id, opened) abort
  if getpos('.') == a:opened
    " Just after opening floating window, CursorMoved event is run.
    " To avoid closing floating window immediately, check the cursor
    " was really moved
    return
  endif
  autocmd! nvim_termdebug_close_hover
  let winnr = win_id2win(a:win_id)
  if winnr == 0
    return
  endif
  call nvim_win_close(a:win_id, v:true)
endfunction

function! s:CloseFloatingHoverOnBufEnter(win_id, bufnr) abort
    let winnr = win_id2win(a:win_id)
    if winnr == 0
        " Float window was already closed
        autocmd! nvim_termdebug_close_hover
        return
    endif
    if winnr == winnr()
        " Cursor is moving into floating window. Do not close it
        return
    endif
    if bufnr('%') == a:bufnr
        " When current buffer opened hover window, it's not another buffer. Skipped
        return
    endif
    autocmd! nvim_termdebug_close_hover
    call nvim_win_close(a:win_id, v:true)
  endfunction

" Open preview window. Window is open in:
"   - Floating window on Neovim (0.4.0 or later)
"   - Preview window on Neovim (0.3.0 or earlier) or Vim
function! s:OpenHoverPreview(lines, filetype) abort
    " Use local variable since parameter is not modifiable
    let lines = a:lines
    let bufnr = bufnr('%')

    let use_float_win = s:ShouldUseFloatWindow()
    if use_float_win
      let pos = getpos('.')

      " Calculate width and height
      let width = 0
      for index in range(len(lines))
        let line = lines[index]
        let lw = strdisplaywidth(line)
        if lw > width
          let width = lw
        endif
        let lines[index] = line
      endfor

      let height = len(lines)

      " Calculate anchor
      " Prefer North, but if there is no space, fallback into South
      let bottom_line = line('w0') + winheight(0) - 1
      if pos[1] + height <= bottom_line
        let vert = 'N'
        let row = 1
      else
        let vert = 'S'
        let row = 0
      endif

      " Prefer West, but if there is no space, fallback into East
      if pos[2] + width <= &columns
        let hor = 'W'
        let col = 0
      else
        let hor = 'E'
        let col = 1
      endif

      let buf = nvim_create_buf(v:false, v:true)
      call nvim_buf_set_lines(buf, 0, -1, v:true, lines)
      " using v:true for second argument of nvim_open_win make the floating
      " window disappear
      let float_win_id = nvim_open_win(buf, v:false, {
            \   'relative': 'cursor',
            \   'anchor': vert . hor,
            \   'row': row,
            \   'col': col,
            \   'width': width,
            \   'height': height,
            \   'style': 'minimal',
            \ })

      if a:filetype isnot v:null
        call nvim_win_set_option(float_win_id, 'filetype', a:filetype)
      endif

      call nvim_buf_set_option(buf, 'modified', v:false)
      call nvim_buf_set_option(buf, 'modifiable', v:false)

      " Unlike preview window, :pclose does not close window. Instead, close
      " hover window automatically when cursor is moved.
      let call_after_move = printf('<SID>CloseFloatingHoverOnCursorMove(%d, %s)', float_win_id, string(pos))
      let call_on_bufenter = printf('<SID>CloseFloatingHoverOnBufEnter(%d, %d)', float_win_id, bufnr)
      augroup nvim_termdebug_close_hover
        execute 'autocmd CursorMoved,CursorMovedI,InsertEnter <buffer> call ' . call_after_move
        execute 'autocmd BufEnter * call ' . call_on_bufenter
      augroup END
    else
      echomsg a:lines[0]
    endif
endfunction

" Handle an error.
func s:HandleError(msg)
  if s:ignoreEvalError
    " Result of s:SendEval() failed, ignore.
    let s:ignoreEvalError = 0
    let s:evalFromBalloonExpr = 0
    return
  endif
  let msgVal = s:MatchGetCapture(a:msg, 'msg="\([^"]*\)"')
  echoerr substitute(msgVal, '\\"', '"', 'g')
endfunc

func s:GotoSourcewinOrCreateIt()
  if !win_gotoid(s:sourcewin)
    below new
    let s:sourcewin = win_getid(winnr())
    call TermDebugGoToPC()
  endif
endfunc

func s:GotoGdbwinOrCreateIt()
  if !win_gotoid(s:gdbwin)
    above new
    let s:gdbwin = win_getid(winnr())
    exe "b " . s:gdbbuf
  endif
endfunc

func s:GotoAsmwinOrCreateIt()
  if !win_gotoid(s:asmwin)
    if win_gotoid(s:sourcewin)
      exe 'rightbelow new'
    else
      exe 'new'
    endif

    let s:asmwin = win_getid(winnr())

    setlocal nowrap
    setlocal number
    setlocal noswapfile
    setlocal buftype=nofile
    setlocal modifiable

    let asmbuf = bufnr('Termdebug-asm-listing')
    if asmbuf > 0
      exe 'buffer' . asmbuf
    else
      exe 'file Termdebug-asm-listing'
    endif

    if exists('g:termdebug_disasm_window')
      if g:termdebug_disasm_window > 1
        exe 'resize ' . g:termdebug_disasm_window
      endif
    endif
  endif

  if s:asm_addr != ''
    let lnum = search('^' . s:asm_addr)
    if lnum == 0
      if s:stopped
        call s:SendCommand('disassemble $pc')
      endif
    else
      exe 'sign unplace ' . s:asm_id
      exe 'sign place ' . s:asm_id . ' line=' . lnum . ' name=debugPC'
      exe 'normal ' . lnum . 'z.'
    endif
  endif
endfunc

func s:GotoComwinOrCreateIt()
  if !win_gotoid(s:ptywin)
    tabnew
    let s:ptywin = win_getid(winnr())
    exe "b " . s:ptybuf
  endif
endfunc

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(msg)
  let wid = win_getid(winnr())

  if a:msg =~ '^\*stopped'
    "call ch_log('program stopped')
    let s:stopped = 1
  elseif a:msg =~ '^\*running'
    "call ch_log('program running')
    let s:stopped = 0
  endif

  if a:msg =~ 'fullname='
    let fname = s:GetFullname(a:msg)
  else
    let fname = ''
  endif

  if a:msg =~ 'addr='
    let asm_addr = s:GetAsmAddr(a:msg)
    if asm_addr != ''
      let s:asm_addr = asm_addr

      let curwinid = win_getid(winnr())
      if win_gotoid(s:asmwin)
      let lnum = search('^' . s:asm_addr)
      if lnum == 0
        call s:SendCommand('disassemble $pc')
      else
        exe 'sign unplace ' . s:asm_id
        exe 'sign place ' . s:asm_id . ' line=' . lnum . ' name=debugPC'
        exe 'normal ' . lnum . 'z.'
      endif

      call win_gotoid(curwinid)
      endif
    endif
  endif

  if a:msg =~ '^\(\*stopped\|=thread-selected\)' && filereadable(fname)
    let lnum = s:MatchGetCapture(a:msg, 'line="\([^"]*\)"')
    if lnum =~ '^[0-9]*$'
      call s:GotoSourcewinOrCreateIt()
      if expand('%:p') != fnamemodify(fname, ':p')
        exe 'edit ' . fnameescape(fname)
      endif
      exe lnum
      normal! zv
      exe 'sign unplace ' . s:pc_id
      exe 'sign place ' . s:pc_id . ' line=' . lnum . ' name=debugPC file=' . fname
      exe 'normal ' . lnum . 'z.'
      if !exists('b:save_signcolumn')
        let b:save_signcolumn = &signcolumn
        call add(s:signcolumn_buflist, bufnr())
      endif
      setlocal signcolumn=yes
    endif
  elseif !s:stopped || fname != ''
    exe 'sign unplace ' . s:pc_id
  endif

  call win_gotoid(wid)
endfunc

func s:DefineBreakpointSign(id)
  let enabled = s:breakpoints[a:id]["enabled"]
  let nr = printf('%d', a:id)
  if enabled == "n"
    let hiName = "debugBreakpointDisabled"
  else
    let hiName = "debugBreakpoint"
  endif
  let signText = substitute(nr, '\..*', '', '')
  exe "sign define debugBreakpoint" . nr . " text=" . signText . " texthl=" . hiName
endfunc

func! s:GoToBreakpoint(id)
  if !has_key(s:breakpoints, a:id)
    echoerr "No entry for breakpoint " . a:id
    return
  endif

  let entry = s:breakpoints[a:id]
  let lnum = entry['lnum']
  let fname = entry['fname']
  call win_gotoid(s:sourcewin)
  exe "edit " . fnameescape(fname)
  exe "normal " . lnum . "G"
endfunc

function s:MatchGetCapture(string, pat)
  let res = matchlist(a:string, a:pat)
  if empty(res)
    return ""
  endif
  return res[1]
endfunction

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(msg, modifiedFlag)
  if a:msg !~ 'fullname='
    " A watch or a pending breakpoint does not have a file name
    if a:msg =~ 'pending='
      let nr = s:MatchGetCapture(a:msg, 'number=\"\([0-9.]*\)\"')
      let target = s:MatchGetCapture(a:msg, 'pending=\"\([^"]*\)\"')
      " Mark breakpoint as pending.
      let entry = {'pending': 1}
      let s:breakpoints[nr] = entry
      echomsg 'Breakpoint ' . nr . ' (' . target  . ') pending.'
    endif
    return
  endif
  for msg in split(a:msg, '{.\{-}}\zs')
    let fname = s:GetFullname(msg)
    let id = s:MatchGetCapture(msg, 'number="\([0-9]*\)[."]')
    let enabled = tolower(s:MatchGetCapture(msg, 'enabled="\([ynN]\)"'))
    let addr = s:MatchGetCapture(msg, 'addr="\([^"]*\)"')
    let lnum = s:MatchGetCapture(msg, 'line="\([^"]*\)"')

    if empty(id)
      continue
    endif

    " Handle multi breakpoint
    if has_key(s:breakpoints, id)
      let entry = s:breakpoints[id]
    else
      let entry = {}
      let s:breakpoints[id] = entry
    endif

    if addr == "<MULTIPLE>"
      let entry['multiple'] = 1
      let entry['enabled'] = enabled
    endif

    if empty(fname) || empty(lnum)
      continue
    endif

    " Sanity check (for multi breakpoints mainly)
    if !a:modifiedFlag
      if has_key(entry, 'fname') && entry['fname'] != fname
        echoerr "Assert failed, breakpoint " . id " changed its location. "
              \ . entry['fname'] . " -> " . fname
      endif
      if has_key(entry, 'lnum') && entry['lnum'] != lnum
        echoerr "Assert failed, breakpoint " . id " changed its location. "
              \ . entry['lnum'] . " -> " . lnum
      endif
    endif

    let entry['fname'] = fname
    let entry['lnum'] = lnum
    " For multi breakpoints, look at enable state of main breakpoint (e.g. "9" instead of "9.1")
    if !has_key(entry, 'multiple')
      let entry['enabled'] = enabled
    endif

    call s:DefineBreakpointSign(id)
    if bufloaded(fname)
      call s:PlaceBreakpointSign(id, entry)
    endif

    let wasPending = has_key(entry, "pending")
    if wasPending
      unlet entry["pending"]
      echomsg 'Pending breakpoint ' . id . ' loaded'
    endif
  endfor
endfunc

func s:PlaceBreakpointSign(id, entry)
  let nr = printf('%d', a:id)
  exe 'sign place ' . s:Breakpoint2SignNumber(a:id) . ' line=' . a:entry['lnum'] . ' name=debugBreakpoint' . nr . ' priority=110 file=' . a:entry['fname']
endfunc

" Handle deleting a breakpoint
" Will remove the sign that shows the breakpoint
func s:HandleBreakpointDelete(msg)
  let id = s:MatchGetCapture(a:msg, 'id="\([0-9]*\)\"')
  if empty(id)
    return
  endif
  if has_key(s:breakpoints, id)
    let entry = s:breakpoints[id]
    exe 'sign unplace ' . s:Breakpoint2SignNumber(id)
    unlet s:breakpoints[id]
    echomsg 'Breakpoint ' . id . ' cleared.'
  endif
endfunc

" Handle the debugged program starting to run.
" Will store the process ID in s:pid
func s:HandleProgramRun(msg)
  let nr = s:MatchGetCapture(a:msg, 'pid="\([0-9]*\)\"') + 0
  if nr == 0
    return
  endif
  let s:pid = nr
  "call ch_log('Detected process ID: ' . s:pid)
endfunc

" Handle a BufRead autocommand event: place any signs.
func s:BufRead()
  let fname = expand('<afile>:p')
  for [id, entry] in items(s:breakpoints)
    if has_key(entry, 'fname') && entry['fname'] == fname
      call s:PlaceBreakpointSign(id, entry)
    endif
  endfor
endfunc

let &cpo = s:keepcpo
unlet s:keepcpo

" vim: set sw=2 ts=2 sts=2 et:
