-- Copyright (c) 2025 Fwirt. See LICENSE.

--- A set of functions for `Command.needs` that implement an input handling
--  state machine for Vitamin.

-- For reference, the POSIX vi grammar is as follows:
-- [register][count]command
--
-- register := "CHAR
-- count := [1-9][0-9]*
-- command := COMMAND [args]
-- args := EMPTY | mark | char | motion
-- mark := [0-9a-zA-Z]
-- char := CHAR
-- motion = [1-9][0-9]*MOTION[args]
-- COMMAND := keycode in commands table
-- MOTION := keycode in motions table
-- CHAR := printable character (ASCII 37 - 126 or TAB)
-- EMPTY := the empty string

local Command = require('vitamin.command')
local registers = require('vitamin.registers')

local fetch = {}

--- The keycode to exit input mode
fetch.escape_keycode = 'esc'

--- The keycode to exit the state machine
fetch.exit_keycode = 'ctrl+esc'

fetch.CONNECT = 'vitamin_entered'
fetch.DISCONNECT = 'vitamin_exited'

--- Mappings of subcommands to their "dittos".
--  For commands that take a subcommand, invoking the command again as the subcommand
--  is a valid subcommand, but only for that command. This table maps that second
--  invocation to a subcommand. If not in this table, the sub is assumed to be
--  `fetch.default_sub`
fetch.dittos = {}
fetch.default_sub = '_'

--- The default prompt if one is not specified.
fetch.default_prompt = 'Vitamin:'

--- Event handler to capture chars that are typed into the buffer in input mode.
--  To prevent memory leaks, we just attach this to the event that's currently
--  collecting input and then (hopefully) detach it when the user is finished, or
--  when a new command is initialized.
local input_command
local function input_handler(code)
	if input_command then
		if input_command.text == nil then input_command.text = '' end
		input_command.text = input_command.text .. utf8.char(code)
	end
end

-- little pattern matching functions because
-- string.match is overkill for single chars
local function match_alpha(char)
	local byte = string.byte(char)
	if (byte >= 97 and byte <= 122) or
	   (byte >= 65 and byte <= 90)
			then return true end
	return false
end

local function match_digit(char)
	local byte = string.byte(char)
	if (byte >= 48 and byte <= 57) 
		then return true end
	return false
end

local function match_alphanum(char)
	local byte = string.byte(char)
	if (byte >= 97 and byte <= 122) or
	   (byte >= 65 and byte <= 90) or
	   (byte >= 48 and byte <= 57)
			then return true end
	return false
end

local function match_printable(char)
	local byte = string.byte(char)
	if byte >= 32 or byte <= 126
	   or byte == 9 -- tab
			then return true end
	return false
end

function fetch.start(command, key)
	command = Command(Command.commands)
	input_command = nil
	if #key == 1 then
		if key == '"' then
			command.status = command.status .. key
			command.needs = fetch.register
			return true, command
		elseif key ~= '0' and match_digit(key) then
			command.needs = fetch.count
			return fetch.count(command, key)
		end
	end
	return fetch.command(command, key)
end

function fetch.register(command, key)
	if #key == 1 and match_printable(key) then
		command.status = command.status .. key
		command.reg = key
		command.needs = fetch.count
		return true, command
	elseif key ~= fetch.escape_keycode then
		error('register must be a single printable ASCII character')
	else
		command.needs = fetch.start
		return true, command
	end
end

function fetch.count(command, key)
	if #key == 1 and match_digit(key) then
		command.status = command.status .. key
		if not command.count then command.count = 0 end
		command.count = command.count * 10 + tonumber(key)
		command.needs = fetch.count
		return true, command
	else
		command.needs = fetch.command
		return command.needs(command, key)
	end
end

function fetch.command(command, key)
	-- handle subcommand "dittos"
	if command.parent and command.parent.keycode == key then
		key = fetch.dittos[key] or fetch.default_sub
	end
	command.status = command.status .. key
	command.needs = nil
	command.keycode = command.keycode .. key
	command = command()
	return true, command
end

--- Get a single character.
--  For m ` ' @ t T f F (or other commands)
function fetch.arg(command, key)
	if utf8.len(key) == 1 then -- #key implicitly filters tab
		command.status = command.status .. key
		command.needs = nil
		command.arg = key
		command = command()
		return true, command
	end
	error('arg to "'..command.keycode..'" must be a single char', 0)
end

--- Subcommand is being specified.
--  A subcommand replaces the current command in the chain, but
--  only takes an optional count, and inherits its register from the
--  parent. The subcommand will recursively call the parent after it
--  finishes its action.
function fetch.subcommand(command, key)
	command.needs = nil
	local sub = Command(Command.motions)
	sub.status = command.status
	sub.parent = command
	sub.reg = command.reg
	sub.needs = fetch.count
	return sub.needs(sub, key)
end

--- In input mode, passthrough everything but escape keycode.
--  Also catch printable characters for repetition.
function fetch.input(command, key) -- TODO: Maybe break out a second state?
	if key == fetch.escape_keycode then
		input_command = nil
		command.needs = nil
		command.status = key
		command = command()
		return true, command
	else
		input_command = command
		command.needs = fetch.input
		return nil, command
	end
end

--- Open the command entry and store the result in a register.
--  To be called from `command.before`. If the user runs the prompt,
--  the text entered will be stored in both the `command.prompt_result`
--  field and the specified register, or the 'prompt' register if none
--  is specified.
function fetch.prompt(command, reg)
	if not command.prompt_result then
		ui.command_entry.run(command.prompt, function (text)
			command.needs = nil
			registers[reg or 'prompt'] = text
			command.prompt_result = text
			command = command()
		end)
		command.needs = fetch.prompt_wait
		return nil, command
	else return true, command end
end

--- Do nothing until the command entry closes.
--  When the keypress handler fires and the command entry is open, it should
--  block while we wait for command input. If the user cancels the
--  command entry then the prompt function will never fire, and we should
--  cancel the command. The command entry always emits an 'esc' keycode when
--  it is closed, whether or not the user cancelled it, and this handler will
--  consume it. If the user pressed enter, the command function should fire before
--  the keypress handler is invoked again. Otherwise this handler will cancel the
--  command by setting `command.needs` to `fetch.start`
function fetch.prompt_wait(command, key)
	if ui.command_entry.active then
		return nil, command
	else
		command.needs = fetch.start 
		command.prompt_result = nil
		return true, command
	end
end

--- State variable for keypress handler
local current_command = nil

local safe_handle_keypress
--- Vitamin events.KEYPRESS handler.
local function handle_keypress(key)
	--ui.print_silent_to('debug', 'before..'..tostring(current_command)..' '..tostring(current_command and current_command.needs))
	if ui.command_entry.active then return nil end -- prevent command entry/find dialog blocking
	if key == fetch.exit_keycode then
		events.emit(fetch.DISCONNECT)
		--events.disconnect(events.KEYPRESS, handle_keypress)
		events.disconnect(events.KEYPRESS, safe_handle_keypress)
		return true
	end
	if not current_command then current_command = Command() end
	local success, handled
	success, handled, current_command = pcall(current_command.needs or fetch.start, current_command, key)
	--ui.print_silent_to('debug', 'after..'..tostring(success)..' '..tostring(handled)..' '..tostring(current_command)..' '..tostring(current_command and current_command.needs))
	if not success then 
		Command.output('ERROR: '..handled)
		current_command = Command()
		return true
	else
		return handled
	end
end

--- Prevent key handler errors from locking up Textadept
safe_handle_keypress = function (key)
	local success, result = pcall(handle_keypress, key)
	if not success then
		ui.statusbar_text = tostring(result)
		events.emit(fetch.DISCONNECT)
		events.disconnect(events.KEYPRESS, safe_handle_keypress)
		return true
	else
		return result
	end
end

function fetch.connect()
	events.emit(fetch.CONNECT)
	current_command = Command()
	events.connect(events.KEYPRESS, safe_handle_keypress, 1)
end

return fetch
