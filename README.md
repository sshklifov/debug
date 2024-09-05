### Goal

The aim of this plugin is to make the debugging experience with GDB as smooth as possible. It is based on
termdebug (`:help termdebug-example`). But I've substituted the terminal window with a prompt buffer -- hence the name.

#### Bugfixes

Here is a list of bugs in termdebug that have been resolved:
- Breakpoint signs not updating
- Breakpoint signs overflowing signcolumn width (with >99 breakpoints)
- Spurious continues
- Stray symbols in disassembly

Also, the startup has been improved by removing a sneaky `:sleep`

#### Quality of life

- Quickly navigate between breakpoints (`PromptDebugGoToBreakpoint`).
- Jump to line of execution (`PromptDebugGoToPC`).
- Sanity checking if debugging symbols are loaded by searching for a specific symbol (`PromptDebugFindSym`).
- Auto switching between asm and source mode (triggered e.g. on `si` or `s`).
- Remote debugging.
- Colored output.

#### GDB command custom handling

- Displaying breakpoint `commands` in a pop-up window.
- `brsource` restores breakpoints from last session.
- `brsave` can override which breakpoints are restored with `brsource`.
- `map` can set the source file when it isn't available (akin to substitute-path).
- `asm` manually switches between asm and source code mode.
- `finish` is locked to the execution of the same thread.
- `up` and `down` jump over frames where there is no source code.
- `where` will show you where you are!
- `info threads` accepts a regex which is matched against frames.
- Custom `print`, `bt` and `info ...` with markers (activate via `<CR>`).

For more information, see `info` output.

#### Custom printing

GDB's default printing is pretty messy. You can now optionally expand fields (via `<CR>`) so the output is not so
cluttered. This has also a responsiveness advantage since less fields are evaluated.

Pretty printing is supported as well. It runs independently of the python based pretty printer and **does not** require
python as a dependency. This is on purpose due to remote targets not having python in majorty of cases. There are
registered printers for `std::vector`, `std::string`, `std::optional` etc.

#### Command completion

On an empty command line, pressing `<Tab>` will trigger completion with all the typed commands so far. This makes retyping
commands more pleasant.

Pressing `<Tab>` on an empty command line will open completion with past executed commands.

#### Starting

Analogous to termdebug. `:PromptDebugStart` accepts the executable and will run a local debugger. It has custom
completion, so feel free to press `<Tab>`.

`:PromptDebugRun` is similar, but will place a breakpoint at the cursor and run the executable.

`:PromptDebugAttach` accepts a process name and attaches to it. It also has `<Tab>` completion.

For advanced usage, see `PromptDebugStart(...)`

#### Misc

This is not a comprehensive list. You can scour the source code or open an issue if something seems off. Each function
that is intended to be run by the user is made global and prefixed with `PromptDebug`. So `:echo PromptDebug<Tab>` for
example will show you all the available functions.

Same goes for the variables: `:let g:promptdebug_<Tab>` will list all variables which control the behavior of the
plugin.
