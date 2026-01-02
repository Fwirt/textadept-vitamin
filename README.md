# Vitamin

**This module is a work-in-progress. Most features do not work or are buggy.**

**vi** **T**ext**a**dept **M**odal **In**terface. Your daily dose of vi
bindings for Textadept.

vi/ex motion and command bindings are somewhat esoteric and non-intuitive, but
if you're acclimated they can be a highly efficient way of navigating and
modifying a document.

Planned features are based on [the POSIX standard for vi commands](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html)
plus any other features I think may be useful.

## HOWTO:

### Enter Vitamin Mode

- Clone this repo to your _~/.textadept/modules_ directory (or download and copy it there)
- In your _~/.textadept/init.lua_, `require` it and bind it to a key to enter the mode, e.g.
```lua
  vitamin = require 'vitamin'
  keys[ctrl+V] = vitamin
```
- In command mode, press the _mode exit key_ to exit Vitamin (default is ctrl+esc)

### Change Keybinds / Extend Vitamin

One of the features that sets Vitamin apart from other vi modes is that Vitamin is designed
with user extensibility and modification in mind, in line with the Textadept ethos.

- Command and motion definitions are available through the tables `commands` and `motions`.
- Each table is keyed on the keycode that defines the command.
- After requiring Vitamin in your init.lua, to remap a command:
  ```lua
  -- remap { to [
  vitamin.commands['['] = vitamin.commands['{']
  -- swap j and k
  vitamin.commands['j'], vitamin.commands['k'] = vitamin.commands['k'], vitamin.commands['j']
  -- remove B
  vitamin.commands['B'] = nil
  ```
- To add a new command, add an entry to the table following the command table structure
  
### Command and Motion Definition Tables

**This has changed a lot and needs to be rewritten.**

The command definition data structure is designed to allow the user to easily add new Scintilla
key commands or user functions to Vitamin, while taking advantage of the vi command grammar's
repeat and motion functionality. A definition may be as simple as `{view.char_left}`. But it
can also execute complex user defined behavior while maintaining the same familiar vi command grammar.

- A Command object contains all of the information that the vi command grammar can encode.
  - Commands are built by the Vitamin state machine key handlers, which fill in its mandatory
    fields (`count`, `buffer`), as well as optional fields based upon its `def` field.
  - The `def` field is retrieved from the `commands` table based on the keycode
    associated with the command.
- Each definition `def` is a table with the following structure:
  - `def[1..#def]` - a list of functions to be executed when the command is invoked.
    Each function is called in sequence, and then the last function is called `command.count`
    times. `command.count` is initialized to `1` if not specified by the user.
    Each function is called with `view` as its first parameter, and `command.arg` as its
    second parameter, unless `def.func` is defined (see below).
  - `def.func` - if defined, call `def.func` before `def[1..#def]` and `def.after` are called. `def` receives
    a `command` object as its only parameter, and may modify any fields in `command`
    as desired. The return values of `func` are passed as additional arguments to
    all subsequent functions `[0..n]` and `after`
  - `def.after` - if defined, execute `after` once after `[#def]` has been invoked
    `command.count` times.
  - `def.state` - if defined, instead of immediately executing the command, pass the next
    keystroke to the `State` function `state`, to allow to the collection of an additional
    argument or motion, or transition to a different input mode.
  - `def[{command field}]` - if `{command field}` is a field of the `command` at call time,
    replace the value of `command[{command field}]` with the value of `def[{command field}]`
    when the complete command is invoked.
- When a command is evaluated...
    - The return values of `def.func`, `def[1..#def]`, and `def.after` are type checked. If
    they are of type `string`, they are concatenated, and stored in the default register
    and `command.register`, if defined. If the results contain any line ending characters,
    the register is set to "line mode". Otherwise the register is initialized to "char mode".
    
Although the Command class was designed for use with the Vitamin state machine, commands can be mapped
independently to Textadept keybinds. Simply pass a definition table to the command constructor. Or use
Vitamin's built-in command tables to map pre-defined vi bindings.

```lua
keys['alt+u'] = vitamin.Command({v.line_down, count = 10}) -- move down 10 lines
keys['alt+H'] = vitamin.Command(vitamin.commands['H']) -- execute the vi 'H' command
```

### Example Definitions

## Currently Implemented

###Commands:

h j k l w W b B e E H M L G 0 $ ^ + - | % _ ( ) { } [[ ]] backspace space enter

x X y d p P

ctrl+  
f b d u e y h j n p

###Motions:

h j k l w W b B e E _

## Planned Features

Any vi standard features not listed above, including
- input mode
- search
- ex commands
- ctags
- line undo
- a, A should prevent text deletion (optionally)
And maybe some Vim features like
- special registers

## Incompatibilities with POSIX vi that I do not plan to fix

- not implemented:
  - ctrl+l, ctrl+r, z are not compatible with Scintilla
  - Q since there is no way to "exit visual mode" (although I suppose this could be a command loop?)
- some features work like vim:
    - vi q, zz close the current buffer instead of the entire editor (vi does not support views/tabs)
    - ex :quit, :xit, ZZ close the buffer instead of editor
    - Internally, vi _buffers_ are referred to as _registers_ (as in Vim) to avoid confusion with Textadept buffers
