-- Copyright (c) 2025 Fwirt. See LICENSE.

-- vi state machine class for vitamin

local Command = require('vitamin.command')

local M = {}

M.escape_keycode = 'esc'
M.exit_mode_keycode = 'ctrl+esc'

-- definition tables for commands and motions, should be
-- initialized prior to installing the key handler.
M.commands = {}
M.motions = {}

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

M.start = function (key, command)
	if #key == 1 then
		if key == '"' then
			return true, M.register
		elseif key ~= 0 and match_digit(key) then
			return M.count(key, command)
		end
	end
	return M.command(key, command)
end

M.register = function (key, command)
	if #key == 1 and match_alphanum(key) then
		command.output = command.output .. key
		command.register = key
		return true, M.count
	else
		return M.error(key, command)
	end
end

M.count = function (key, command)
	if #key == 1 and match_digit(key) then
		command.output = command.output .. key
		command.count = command.count * 10 + tonumber(key)
		return true, M.count
	else
		return M.command(key, command)
	end
end

M.command = function (key, command)
	-- since this state passes unhandled keys we need an escape hatch
	if key == M.escape_keycode then
		command.output = M.escape_keycode
		return true, M.start
	end
	local def = M.commands[key]
	if def == nil then -- undefined function
		if command.register or command.count > 0 then -- invalid
			return M.error(key, command)
		else
			return true, M.start
		end
	else
		command.output = command.output .. key
		command.def = def
		if def.state then
		    return true, def.state
		else
			return M.complete(key, command)
		end
	end
end

-- for m ` ' @ t T f F
M.arg = function (key, command)
	if #key == 1 and match_printable(key) then -- #key implicitly filters tab
		command.output = command.output .. key
		if type(command.arg) == 'table' then
			command.motion.arg = key
		else
			command.arg = key
		end
		return M.complete(key, command)
	end
end

-- combined count and motion into one state for clarity
M.motion = function (key, command)
	if #key == 1 and match_digit(key) then
		command.output = command.output .. key
		command.motion_count = command.motion_count * 10 + tonumber(key)
	else
		local def = M.motions[key]
		if def == nil then
			return M.error(key, command)
		else
			command.motion = def
			command.output = command.output .. key
			if def.state then
				return true, func.state
			else
				return M.complete(key, command)
			end
		end
	end
end

-- in input mode, passthrough everything but escape keycode
-- but catch printable chars for repetition.
M.input = function (key, command)
	command.output = command.def.output
	-- need to install/remove an event handler that catches
	-- text added to the Scintilla element so we can replay it.
	if key == M.escape_keycode then
		return M.complete(key, command)
	else
		-- TODO: handle Unicode
		return false, M.input
	end
end

-- command is ready for execution
M.complete = function (key, command)
	if key == M.exit_mode_keycode then return true, nil end
	command()
	M.history[#history+1] = command
	return true, M.start
end

-- command was improperly formatted or escaped
M.error = function (key, command)
	-- cancelling command is not an error
	if key == M.escape_keycode then return true, M.start end
	command.output = "error"
	-- TODO: identify the error here
	return true, M.start
end

return M
