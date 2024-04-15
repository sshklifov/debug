Here is an example config:
```
function! s:Debug(file)
  if TermDebugIsOpen()
    echoerr 'Terminal debugger already running, cannot run two'
    return
  endif

  autocmd! User TermDebugStopPre call s:DebugStopPre()
  autocmd! User TermDebugRunPost call s:DebugRunPost()

  call TermDebugStart()

  command! -nargs=0 Capture call TermDebugGoToCapture()
  command! -nargs=0 Gdb call TermDebugGoToGdb()
  command! -nargs=0 Up call TermDebugGoUp("/home/" . $USER)
  command! -nargs=0 Pwd call TermDebugShowPwd()
  command! -nargs=0 Backtrace call TermDebugBacktrace()
  command! -nargs=? Threads call TermDebugThreadInfo(<q-args>)
  command! -nargs=0 DebugSym call TermDebugFindSym(expand('<cword>'))
  command! -nargs=? Break call TermDebugGoToBreakpoint(<q-args>)
  command! -nargs=? Commands call TermDebugEditCommands(<f-args>)

  nnoremap <silent> <leader>v <cmd>call TermDebugEvaluate(expand('<cword>'))<CR>
  nnoremap <silent> <leader>br :call TermDebugSendCommand("br " . <SID>GetDebugLoc())<CR>
  nnoremap <silent> <leader>tbr :call TermDebugSendCommand("tbr " . <SID>GetDebugLoc())<CR>
  nnoremap <silent> <leader>unt :call TermDebugSendCommands("tbr " . <SID>GetDebugLoc(), "c")<CR>
  nnoremap <silent> <leader>pc :call TermDebugGoToPC()<CR>

  call TermDebugSendCommand("set debug-file-directory /dev/null")
  call TermDebugSendCommand("set print asm-demangle on")
  call TermDebugSendCommand("set print pretty on")
  call TermDebugSendCommand("set print frame-arguments none")
  call TermDebugSendCommand("set print raw-frame-arguments off")
  call TermDebugSendCommand("set print entry-values no")
  call TermDebugSendCommand("set print inferior-events off")
  call TermDebugSendCommand("set print thread-events off")
  call TermDebugSendCommand("set print object on")
  call TermDebugSendCommand("set breakpoint pending on")
  call TermDebugSendCommand("set max-completions 20")
  
  let args = split(a:file, " ")
  call TermDebugSendCommand("file " . args[0])
  if len(args) > 1
    call TermDebugSendCommand("set args " . join(args[1:], " "))
  endif
  call TermDebugSendCommand("start")
endfunction

function! s:GetDebugLoc()
  let basename = expand("%:t")
  let lnum = line(".")
  return printf("%s:%d", basename, lnum)
endfunction

function! s:DebugRunPost()
  call TermDebugSendCommand("set scheduler-locking step")
endfunction

function! s:DebugStopPre()
  silent! nunmap <leader>v
  silent! nunmap <leader>br
  silent! nunmap <leader>tbr
  silent! nunmap <leader>unt
  silent! nunmap <leader>pc

  silent! delcommand Capture
  silent! delcommand Gdb
  silent! delcommand Up
  silent! delcommand Pwd
  silent! delcommand Backtrace
  silent! delcommand Threads
  silent! delcommand DebugSym
  silent! delcommand Break
  silent! delcommand Commands
endfunction

function! ExeCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let pat = "*" . a:ArgLead . "*"
  let cmd = ["find", ".", "(", "-path", "**/.git", "-prune", "-false", "-o", "-name", pat, ")"]
  let cmd += ["-type", "f", "-executable", "-printf", "%P\n"]
  return systemlist(cmd)
endfunction

command! -nargs=? -complete=customlist,ExeCompl Start call s:Debug(<q-args>)
```
