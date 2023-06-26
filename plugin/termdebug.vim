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
" - Prompt mode is deprecated, sorry MS-Windows
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

" Name of the gdb command, defaults to "gdb".
if !exists('g:termdebugger')
  let g:termdebugger = 'gdb'
endif

let s:keepcpo = &cpo
set cpo&vim

"""""""""""""""""""""""""""""""Global functions"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
func TermDebugStart()
  call s:TermDebugStartCommon({})
endfunc

func TermDebugStartSSH(ssh)
  call s:TermDebugStartCommon({'ssh': a:ssh})
endfunc

function! TermDebugIsOpen()
  return exists('s:gdbwin')
endfunction

function! TermDebugIsStopped()
  if !exists("s:stopped")
    return 1
  endif
  return s:stopped
endfunction

function! TermDebugGetPid()
  return s:pid
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
  if !TermDebugIsStopped()
    echoerr "Cannot send command '" . a:cmd . "'. Program is running."
    return
  endif
  call chansend(s:gdb_job_id, a:cmd . "\r")
endfunc

func TermDebugToggleMessages()
  if exists("s:capture_buf")
    unlet s:capture_buf
  else
    let bufname = "Gdb messages"
    let s:capture_buf = bufnr(bufname)
    if s:capture_buf < 0
      let s:capture_buf = bufadd("Gdb messages")
    endif
    call bufload(s:capture_buf)
    call setbufvar(s:capture_buf, "&buftype", "nofile")
    call setbufvar(s:capture_buf, "&swapfile", 0)
    call setbufvar(s:capture_buf, "&buflisted", 1)
  endif
endfunc

func s:Compare(a, b)
  let alen = len(a:a)
  let blen = len(a:b)
  if alen < blen
    return -1
  elseif blen < alen
    return 1
  elseif a:a < a:b
    return -1
  elseif a:b < a:a
    return 1
  else
    return 0
  endif
endfunc

func TermDebugBrToQf()
  let brs = sort(items(s:breakpoints), {a, b -> <SID>Compare(a[0], b[0])})
  let brs = filter(brs, {_, p -> ! has_key(p[1], 'pending')})
  let items = map(brs, {_, i -> {
        \ "filename": i[1]['fname'],
        \ "lnum": i[1]['lnum'],
        \ "col": 1,
        \ "text": "Breakpoint " . i[0]
        \ } })
  if empty(items)
    echoerr "No breakpoints to show"
    return
  endif
  call setqflist([], ' ', {"title": "Breakpoints", "items": items})
  copen
endfunc

func TermDebugQfToBr()
	let items = getqflist()
	for item in items
		let fname = fnamemodify(bufname(item['bufnr']), ":p")
		let lnum = item['lnum']
		call TermDebugSendCommand("break " . fname . ":" . lnum)
	endfor
	cclose
endfunc
" }}}

"""""""""""""""""""""""""""""""Variables to remove"""""""""""""""""""""""""""""""{{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let s:pc_id = 12
let s:asm_id = 13
let s:break_id = 14  " breakpoint number is added to this

let s:parsing_disasm_msg = 0
let s:asm_lines = []
let s:asm_addr = ''
"}}}

"""""""""""""""""""""""""""""""Launching GDB"""""""""""""""""""""""""""""""{{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
func s:TermDebugStartCommon(opts)
  if exists('s:gdbwin')
    echoerr 'Terminal debugger already running, cannot run two'
    return
  endif
  if !executable(g:termdebugger)
    echoerr 'Cannot execute debugger program "' .. g:termdebugger .. '"'
    return
  endif

  if exists('#User#TermdebugStartPre')
    doauto <nomodeline> User TermdebugStartPre
  endif

  " Sign used to highlight the line where the program has stopped.
  " There can be only one.
  sign define debugPC linehl=debugPC

  augroup TermDebug
    au BufRead * call s:BufRead()
    au OptionSet background call s:Highlight(0, v:option_old, v:option_new)
  augroup END

  " Remember the old value of 'signcolumn' for each buffer that it's set in, so
  " that we can restore the value for all buffers.
  let b:save_signcolumn = &signcolumn
  let s:signcolumn_buflist = [bufnr()]

  " Contains breakpoints that have been placed, key is a string with the GDB
  " breakpoint number.
  let s:breakpoints = {}

  let s:pid = 0
  let s:asmwin = 0
  let s:sourcewin = win_getid(winnr())

  let s:gdb_startup_state = a:opts
  call s:LaunchGdb()
  call s:InstallCommands()

  call win_gotoid(s:gdbwin)
  " Set the filetype, this can be used to add mappings.
  set filetype=termdebug
  startinsert
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
  " Command executed _after_ startup is done, provides us with the necessary feedback
  let gdb_cmd .= ' -ex "echo startupdone\n"'
  " Launch GDB through ssh
  if has_key(s:gdb_startup_state, "ssh")
    let gdb_cmd = ['ssh', '-t', '-o', 'ConnectTimeout 1', s:gdb_startup_state['ssh'], gdb_cmd]
  endif

  execute 'new'
  let s:gdb_job_id = termopen(gdb_cmd, {
        \ 'on_exit': function('s:EndTermDebug'),
        \ 'on_stdout': function('s:GdbOutput')
        \ })
  if s:gdb_job_id == 0
    echoerr 'invalid argument (or job table is full) while opening gdb terminal window'
    return
  elseif s:gdb_job_id == -1
    echoerr 'Failed to open the gdb terminal window'
    return
  endif
  let gdb_job_info = nvim_get_chan_info(s:gdb_job_id)
  let s:gdbbuf = gdb_job_info['buffer']
  let s:gdbwin = win_getid(winnr())

  " Rename the Gdb buffer
  call win_gotoid(s:gdbwin)
  let name = "Gdb terminal"
  let nr = bufnr(name)
  if nr >= 0
    exe "bwipe " . nr
  endif
  exe "file " . name
endfunc

func s:GdbOutput(job_id, msgs, event)
  for msg in a:msgs
    if msg =~ "startupdone"
      " If this key exists, we don't know the tty of the communication job yet.
      " MI interface has not yet been set up.
      let s:gdb_startup_state['missing_mi'] = 1

      " Create a hidden terminal window to communicate with gdb
      let comm_cmd = "tty; tail -f /dev/null"
      if has_key(s:gdb_startup_state, "ssh")
        let comm_cmd = 'ssh -o "ConnectTimeout 1" -t ' . s:gdb_startup_state['ssh'] . ' "' . comm_cmd . '"'
      endif
      let s:comm_job_id = jobstart(comm_cmd, {
            \ 'on_stdout': function('s:CommOutput'),
            \ 'pty': v:true,
            \ })
      if s:comm_job_id == 0
        echoerr 'invalid argument (or job table is full) while opening communication terminal window'
        return
      elseif s:comm_job_id == -1
        echoerr 'Failed to open the communication terminal window'
        return
      endif
    endif

    if msg =~ 'New UI allocated'
      if exists('#User#TermdebugStartPost')
        doauto <nomodeline> User TermdebugStartPost
      endif
    endif
  endfor
endfunc

func s:CommOutput(job_id, msgs, event)
  for msg in a:msgs
    " remove prefixed NL
    if msg[0] == "\n"
      let msg = msg[1:]
    endif

    if exists("s:capture_buf")
      let m = substitute(msg, "[^[:print:]]", "", "g")
      call appendbufline(s:capture_buf, "$", m)
    endif

    if exists('#User#TermdebugCommOutput')
      let g:termdebug_comm_msg = msg
      doauto <nomodeline> User TermdebugCommOutput
    endif

    if has_key(s:gdb_startup_state, "missing_mi")
      " Capture device name of communication terminal.
      " The first command executed in the terminal will be "tty" and the output will be parsed here.
      let pty = s:MatchGetCapture(msg, '\(' . '/dev/pts/[0-9]\+' . '\)')
      if pty != ""
        unlet s:gdb_startup_state["missing_mi"]
        " Connect gdb to the communication pty, using the GDB/MI interface.
        " Prefix "server" to avoid adding this to the history.
        call chansend(s:gdb_job_id, 'server new-ui mi ' . pty . "\r")
      endif
    elseif s:parsing_disasm_msg
      call s:HandleDisasmMsg(msg)
    elseif msg != ''
      if msg =~ '^\(\*stopped\|\*running\|=thread-selected\)'
        call s:HandleCursor(msg)
      elseif msg =~ '^\^done,bkpt=' || msg =~ '^=breakpoint-created,' || msg =~ '^=breakpoint-modified,'
        call s:HandleNewBreakpoint(msg)
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
  command! -nargs=1 Break call s:GoToBreakpoint(<f-args>)

  let &cpo = save_cpo
endfunc
" }}}

"""""""""""""""""""""""""""""""Ending the session"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function s:EndTermDebug(job_id, exit_code, event)
  if exists('#User#TermdebugStopPre')
    doauto <nomodeline> User TermdebugStopPre
  endif

  unlet s:gdb_startup_state
  unlet s:gdbwin

  call s:EndDebugCommon()
endfunc

func s:EndDebugCommon()
  let curwinid = win_getid(winnr())

  if exists("s:stopped")
    unlet s:stopped
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

  if exists('#User#TermdebugStopPost')
    doauto <nomodeline> User TermdebugStopPost
  endif

  au! TermDebug
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
" }}}

"""""""""""""""""""""""""""""""Message handlers"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

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

" Send a command to gdb.  "cmd" is the string without line terminator.
func s:SendCommand(cmd)
  call chansend(s:comm_job_id, a:cmd . "\r")
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

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(msg)
  let wid = win_getid(winnr())

  if a:msg =~ '^\*stopped'
    let s:stopped = 1
  elseif a:msg =~ '^\*running,thread-id="all"'
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
  elseif !TermDebugIsStopped() || fname != ''
    exe 'sign unplace ' . s:pc_id
  endif

  call win_gotoid(wid)
endfunc

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(msg)
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
endfunc

" Handle an error.
func s:HandleError(msg)
  let msgVal = s:MatchGetCapture(a:msg, 'msg="\([^"]*\)"')
  echoerr substitute(msgVal, '\\"', '"', 'g')
endfunc

function s:MatchGetCapture(string, pat)
  let res = matchlist(a:string, a:pat)
  if empty(res)
    return ""
  endif
  return res[1]
endfunction
"}}}

"""""""""""""""""""""""""""""""Go to win or create it"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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
  endif

  if s:asm_addr != ''
    let lnum = search('^' . s:asm_addr)
    if lnum == 0
      if TermDebugIsStopped()
        call s:SendCommand('disassemble $pc')
      endif
    else
      exe 'sign unplace ' . s:asm_id
      exe 'sign place ' . s:asm_id . ' line=' . lnum . ' name=debugPC'
      exe 'normal ' . lnum . 'z.'
    endif
  endif
endfunc
" }}}

"""""""""""""""""""""""""""""""Breakpoint signs"""""""""""""""""""""""""""""""{{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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

" Take a breakpoint number as used by GDB and turn it into an integer.
func s:Breakpoint2SignNumber(id)
  return s:break_id + a:id
endfunction

func s:DefineBreakpointSign(id)
  let enabled = s:breakpoints[a:id]["enabled"]
  let nr = printf('%d', a:id)
  if enabled == "n"
    let hiName = "debugBreakpointDisabled"
  else
    let hiName = "debugBreakpoint"
  endif
  let signText = substitute(nr, '\..*', '', '')
  if len(signText) > 2
    let signText = "*"
  end
  exe "sign define debugBreakpoint" . nr . " text=" . signText . " texthl=" . hiName
endfunc

func! s:GoToBreakpoint(id)
  if !has_key(s:breakpoints, a:id)
    echoerr "No entry for breakpoint " . a:id
    return
  endif

  let entry = s:breakpoints[a:id]
  if has_key(entry, "pending")
    echoerr "Cannot go to pending breakpoint " . a:id
    return
  endif

  let lnum = entry['lnum']
  let fname = entry['fname']
  call win_gotoid(s:sourcewin)
  exe "edit " . fnameescape(fname)
  exe "normal " . lnum . "G"
endfunc

func s:PlaceBreakpointSign(id, entry)
  let nr = printf('%d', a:id)
  exe 'sign place ' . s:Breakpoint2SignNumber(a:id) . ' line=' . a:entry['lnum'] . ' name=debugBreakpoint' . nr . ' priority=110 file=' . a:entry['fname']
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
" }}}

let &cpo = s:keepcpo
unlet s:keepcpo

" vim: set sw=2 ts=2 sts=2 foldmethod=marker et:
