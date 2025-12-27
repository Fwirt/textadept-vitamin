-- Copyright (c) 2025 Fwirt. See LICENSE.

-- vitamin command field utility functions

local Command = require('vitamin.command')

local fetch = {}

fetch.escape_keycode = 'esc'

-- The following is an implementation of a state
-- machine that implements the vi command grammar:
--
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

fetch.start = function (key, command)
	command = Command(Command.commands)
	if #key == 1 then
		if key == '"' then
			return true, fetch.register
		elseif key ~= '0' and match_digit(key) then
			return fetch.count(key, command)
		end
	end
	return fetch.command(key, command)
end

fetch.register = function (key, command)
	if #key == 1 and match_printable(key) then
		command.status = command.status .. key
		command.register = key
		return true, fetch.count
	end
	error('register must be a single printable character')
end

fetch.count = function (key, command)
	if #key == 1 and match_digit(key) then
		command.status = command.status .. key
		if not command.count then command.count = 0 end
		command.count = command.count * 10 + tonumber(key)
		return true, fetch.count
	else
		return fetch.command(key, command)
	end
end

--- Command is being specified
fetch.command = function (key, command)
	command.keycode = key
	command.status = command.status .. key
	command = command()
	if command.needs then
		return true, command.needs
	end
	return true, fetch.start
end

--- Command argument is being specified.
-- for m ` ' @ t T f F (or special commands)
fetch.arg = function (key, command)
	if #key == 1 and match_printable(key) then -- #key implicitly filters tab
		command.status = command.status .. key
		command.arg = key
		command.needs = nil
		command = command()
		if command.needs then
			return true, command.needs
		end
		return true, fetch.complete(key, command)
	end
	error('arg to '..command.keycode..' must be a printable char')
end

--- Command motion is being specified.
fetch.motion = function (key, command)
	command.sub = Command(Command.motions)
	command = command.sub()
	if command.needs then
		return true, command.needs
	end
	return true, fetch.start
end

--- In input mode, passthrough everything but escape keycode.
--  Also catch printable characters for repetition.
fetch.input = function (key, command)
	-- TODO: install/remove an event handler that catches
	-- text added to the Scintilla element so we can replay it.
	-- TODO: handle Unicode text entry?
	if key == Command.escape_keycode then
		return fetch.complete(key, command)
	else
		return false, fetch.input
	end
end

--- When prompting for input, pop the command entry and have the
--  keypress handler wait to do anything until the entry function
--  returns.
fetch.prompt = function (key, command)
	ui.command_entry.prompt(command.prompt, function (text)
		command.text = text
		command = command()
		if not command.needs then 
	end)
	return true, 
end

--- Do nothing until the current command finishes.
--  This is used for the command entry. When the command entry function
--  finishes, it should set `command.needs` to an appropriate value,
--  presumably fetch.start
fetch.wait = function (key, command)
	return true, command.needs
end


return fetch
