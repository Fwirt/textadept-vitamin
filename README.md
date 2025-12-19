# Vitamin

__this module is a WIP and doesn't even run yet__

__VI__ __T__ext__A__dept __M__odal __IN__terface. Your daily dose of vi  
bindings for Textadept.

vi/ex motion and command bindings are somewhat esoteric and non-intuitive, but  
if you're acclimated they can be a highly efficient way of navigating and  
modifying a document.

Planned features are based on [the POSIX standard for vi commands](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html)  
plus a handful Vim features that I think are too good to miss.

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

- Command and motion definitions are available through the tables `.commands` and `motions`
- Each table is keyed on the keycode that defines the command
- After requiring Vitamin in your init.lua, to remap a command:
  ```lua
  -- remap { to [
  vitamin.commands['['] = vitamin.commands['{']
  -- swap j and k
  vitamin.commands['j'], vitamin.commands['k'] = vitamin.commands['k'], vitamin.commands['j']
  -- remove B
  vitamin.commands['B'] = nil
  ```
- To add a new command, add an entry to the table following the `Command.definitions` structure
  
### Command and Motion Definition Tables

The Definition data structure may seem daunting, but it is designed to allow the user  
to easily add new Scintilla key commands or user functions to Vitamin. A definition may
be as simple as `{view.char_left}`. But it can also execute complex user defined behavior
while maintaining the same familiar command syntax.

- When a `Command` or `Motion` is executed, its `def` field is retrieved from the
  `Definition.commands` or `Definition.motions` table. The `def` field is then evaluated
  according to the following rules:
- Each `Definition` `def` is a table with the following structure
  - `def[1..#def]` a list of functions to be executed when the command is invoked.  
    Each function is called in sequence, and then the last function is called `command.count`  
    times. `command.count` is initialized to `1` if not specified by the user.  
    Each function is called with `view` as its first parameter, and `command.arg` as its  
    second parameter, unless `def.func` is defined (see below).
  - `def.func` if defined, call `def.func` before `def[1..#def]` and `def.after` are called. `def` receives  
    a `command` object as its only parameter, and may modify any fields in `command`  
    as desired. The return values of `func` are passed as additional arguments to  
    all subsequent functions `[0..n]` and `after`
  - `def.after` if defined, execute `after` once after `[#def]` has been invoked  
    `command.count` times.
  - `def.state` if defined, instead of immediately executing the command, pass the next  
    keystroke to the `State` function `state`, to allow to the collection of an additional
    argument or motion.
  - `def[{command field}]` if `{command field}` is a field of the `command` object currently  
    under evaluation, replace the value of `command[{command field}]` with the value of  
    `def[{command field}]`
  - the return values of `def.func`, `def[1..#def]`, and `def.after` are type checked. If  
    they are of type `string`, they are concatenated, and stored in the default register
    and `command.register`, if defined.
    
### Example Definitions

## Currently Implemented

###Commands:

h j k l w W b B e E H M L G 0 $ ^ + - | % _ ( ) { } ctrl+f ctrl+b ctrl+d ctrl+u ctrl+e crtl+y ctrl+h backspace enter ctrl+j ctrl+n ctrl+p space

##Motions:

work in progress

## Planned Features

Any vi standard commands not listed above, including
- ex commands
- search
- input mode
And maybe some Vim features like
- special registers

## Incompatibilities with POSIX vi

- not implemented:
  - ctrl+l ctrl+r ctrl+] Q U z (not compatible with Scintilla)
  - [[ ]] (not useful enough to bother with)
- :quit, :xit, ZZ close the buffer instead of editor
- a, A do not prevent text from being deleted (as in Vim)
- Input mode uses TA keybinds instead of vi keybinds
  - i.e. input mode commands that duplicate existing functionality are not implemented
  - ctrl+d, ctrl+h, ctrl+j, ctrl+m, ctrl+u, ctrl+w
- Internally, vi _buffers_ are referred to as _registers_ (as in Vim) to avoid confusion with Textadept buffers
