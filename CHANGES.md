**Bugfixes**

- Fixed breakpoint signs not updating
- Fixed breakpoint signs overflowing signcolumn width
- Removed spurious continues
- Proper detection when program has stopped
- Removed stray symbols from asm window

**Quality of life**

- Quickly navigate to breakpoints (_TermDebugGoToBreakpoint_)
- Place a breakpoint at each entry in quickfix(_TermDebugQfToBr_, _TermDebugBrToQf_)
- Jump to line of execution(_TermDebugGoToPC_)
- Close all windows on exit
- Replace signs with extmarks
- Go to frame matching regex (_TermDebugGoUp_)
- Show backtrace in quickfix (_TermDebugBacktrace_)
- Load backtrace of all threads in quickfix (_TermDebugThreadInfo_)
- Echo pwd (_TermDebugShowPwd_)
- Check for debugging symbols (_TermDebugFindSym_)
- Edit breakpoint commands (_TermDebugEditCommands_)
- Quickly exit debugging session (_TermDebugQuit_)

**Run GDB in a prompt buffer**

- Less buggy than terminal buffers
- Most useful mappings work: C-W, C-U, C-D, C-C
- More intuitive history scrolling
- Preview history in a pop up window (press <TAB> on an empty command line)
- Command completion (trigged by pressing <TAB>)
- Gray out prompt if gdb is running
- Custom handling of commands command
- Filter spam gdb messages

**Remove unnecessary startup delay**

- GDB starts cleanly and does not need previous :sleep commands

**Support for remote debugging**

- Works without path substitutions or gdb servers
- Add host to _TermDebugStart_ to run in ssh mode
- GDB is ran remotely on the device through ssh

**Simplified parsing of GDB messages**

- Parse grammar from the documentation
- Handle quirky cases when GDB emits incorrect messages

**Auto switch between Asm and Source code mode**

- Switch to assembly code on si or ni commands.
- More screen space by showing only 1 window

**Command playground**

- Ability to run arbitrary GDB MI commands

**Simplified plugin debugging process:**

- Even if something is buggy, all messages are captured and can be inspected.
- _TermDebugPrintMICommand_ to see the output of MI commands
- Open logs with _TermDebugGoToCapture_
