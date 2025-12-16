-- Copyright (c) 2025 Fwirt. See LICENSE.

-- vitamin
-- vi textadept mode interface
-- Based on the POSIX standard for vi commands:
-- https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html
-- Uses a custom event handler to implement a state machine instead
-- of the built-in chain handler because vi commands are nuanced

-- vi incompatibilites:
-- - not implemented:
-- 		[[, ]], ctrl+l, ctrl+r, ctrl+], Q, U, z
-- - q, ZZ close buffer instead of editor
-- - 0-9 are also allowed as marks
-- - Input mode uses TA keybinds instead of vi keybinds
--   	i.e. input mode commands that duplicate existing functionality are not implemented
--   	(ctrl+d, ctrl+h, ctrl+j, ctrl+m, ctrl+u, ctrl+w)

-- TODO:
-- +TA bookmarks only mark lines so implement character marking
-- +Implement all the stubbed and commented out functions
-- +Implement input mode repetition w/ count

local M = {}

-- the keycode to exit input mode
M.escape_keycode = 'esc'

-- where to put command output, override this to set different destination.
M.output = function (text) ui.statusbar_text = text end

-- buffer implementation:
-- just a table keyed on character.
-- if the field is a string it's a "character mode" buffer
-- if the field is a table it's a "line mode" buffer
M.buffers = {}

-- whether or not the event handler is registered
local registered = false

-- little pattern matching functions because
-- string.match is overkill for single chars
function M.match_alpha(char)
	local byte = string.byte(char)
	if (byte >= 97 and byte <= 122) or
	   (byte >= 65 and byte <= 90)
			then return true end
	return false
end

function M.match_digit(char)
	local byte = string.byte(char)
	if (byte >= 48 and byte <= 57) 
		then return true end
	return false
end

function M.match_alphanum(char)
	local byte = string.byte(char)
	if (byte >= 97 and byte <= 122) or
	   (byte >= 65 and byte <= 90) or
	   (byte >= 48 and byte <= 57)
			then return true end
	return false
end

function M.match_printable(char)
	local byte = string.byte(char)
	if byte >= 32 or byte <= 126
	   or byte == 9 -- tab
			then return true end
	return false
end

function M.to_lower(char)
	local byte = string.byte(char)
	if byte >= 65 and byte <= 90
		then return string.char(byte + 32) end
	return char
end

--
-- The following is an implementation of a state
-- machine that implements the vi command grammar:
--
-- [buffer][count]command
--
-- buffer := "[0-9a-zA-Z]
-- count := [1-9][0-9]*
-- command := COMMAND args
-- args := EMPTY | mark | char | motion
-- mark := [0-9a-zA-Z]
-- char := CHAR
-- motion = [1-9][0-9]*MOTION[args]
-- COMMAND := keycode in commands table
-- MOTION := keycode in motions table
-- CHAR := printable character (ASCII 37 - 126 or TAB)
-- EMPTY := the empty string

local state = {}
--[[local state.start, state.complete, state.error
local state.buffer
local state.count
local state.command, state.mark, state.char
local state.motion
local state.input -- input mode]]

local command -- the current command and all its arguments
local last_command -- the previous command (for .)

state.start = function (key)
	command = {}
	command.buffer = nil
	command.count = 0
	command.command = nil
	command.arg = nil
	command.motion_count = 0
	command.motion = nil
	command.motion_arg = nil
	command.input_text = {}
	if #key == 1 then
		if key == '"' and buffer == nil then
			return true, state.buffer
		elseif key ~= 0 and M.match_digit(key) then
			return state.count(key)
		end
	end
	return state.command(key)
end

state.buffer = function (key)
	if #key == 1 and M.match_alphanum(key) then
		command.buffer = key
		return true, state.count
	else
		return state.error(key)
	end
end

state.count = function (key)
	if #key == 1 and M.match_digit(key) then
		command.count = command.count * 10 + tonumber(key)
		return true, state.count
	else
		return state.command(key)
	end
end

state.command = function (key)
	local func = M.commands[key]
	if func == nil then -- undefined function
		if command.buffer or command.count > 0 then -- invalid
			return state.error(key)
		else -- unhandled key, reset and pass to event handlers
			return false, state.start
		end
	else
		command.command = func
		if func.state then
		    return true, func.state
		else
			return state.complete(key)
		end
	end
end

state.arg = function (key)
	if #key == 1 and M.match_alphanum(key) then
		if command.arg == '' then
			command.arg = key
		else
			command.motion_letter = key
		end
		return state.complete(key)
	else
		return state.error(key)
	end
end

-- m ` ' @
state.mark = function (key)
	if #key == 1 and M.match_alphanum(key) then
		if not command.letter then
			command.arg = key
		else
			command.motion_letter = key
		end
		return state.complete(key)
	else
		return state.error(key)
	end
end

-- t T f F
state.char = function (key)
	if #key == 1 and M.match_printable(key) then
		command.letter = key
		return state.complete(key)
	else
		return state.error(key)
	end
end

-- combined count and motion into one state for clarity
state.motion = function (key)
	if #key == 1 and M.match_digit(key) then
		command.motion_count = command.motion_count * 10 + tonumber(key)
	else
		local func = motions[key]
		if func == nil then
			return state.error(key)
		else
			command.motion = func
			if func.state then
				return true, func.state
			else
				return state.complete(key)
			end
		end
	end
end

-- in input mode, passthrough everything but escape keycode
state.input = function (key)
	-- need to install/remove an event handler that catches
	-- text added to the Scintilla element so we can replay it.
	if key == M.escape_keycode then
		return true, state.complete(key)
	else
		return false, state.input
	end
end

-- command is ready for execution
state.complete = function (key)
	last_command = command -- for .
	for i = 1, #command - 1 do
		command[i](view)
	end
	if command.count > 1 then
		for i = 1, command.count do
			command[#command](view)
		end
	end
	return true, state.start
end

-- command was improperly formatted
state.error = function (key)
	-- return command error here
	return true, state.start
end

-- Command definition tables below

-- Commands that aren't Scintilla native:

-- move without wrapping.
-- vs_no_wrap_line_start would work for left but not right
function M.char_left_not_line(view) ; end -- h
function M.char_right_not_line(view) ; end -- l

-- move by bigword /.*[/s/n]/
-- default word definition already matches vi
function M.bigword_right(view) ; end -- W
function M.bigword_left(view) ; end -- B
function M.bigword_right_end(view) ; end -- E

-- move by sentence /.*[\.\!\?][\)\]\"\']*\s/
function M.sentence_last(view) ; end -- (
function M.sentence_next(view) ; end -- )

-- move cursor to position in current window
function M.screen_top(view) ; end -- H
function M.screen_middle(view) ; end -- M
function M.screen_bottom(view) ; end -- L

-- scroll keeping the cursor at the same location on screen
function M.half_page_down(view) ; end -- ctrl+d
function M.half_page_up(view) ; end -- ctrl+u

-- move a line and then home (not possible to repeat)
function M.line_up_vc_home(view) ; end -- -
function M.line_down_vc_home(view) ; end -- +
function M.line_down_end(view) ; end -- $

-- buffer cut/copy commands
function M.buffer_cut_char_right(view) ; end -- x
function M.buffer_cut_char_left(view) ; end -- X
function M.buffer_cut(view) ; end -- d
function M.buffer_copy(view) ; end -- y
function M.buffer_paste(view) ; end -- p

-- file, path, current line, total lines, modified, readonly
function M.display_information(view) ; end

-- a command is a sequence of functions and optional fields
-- numeric indices will be called in order, with the last index called [count] times
-- if the last index is non-function then count is ignored
-- all functions are called with the active view as the first parameter
-- state field indicates next state for state machine, for commands with args or motions
-- args field is unpacked and passed to all functions (after view)
-- any fields with the same key as command parts overwrite those command parts (for aliases such as D)
local v = view
M.commands = {
	h = {M.char_left_not_line}, ['ctrl+h'] = {M.char_left_not_line}, ['\b'] = {M.char_left_not_line},
	j = {v.line_down}, ['\n'] = {v.line_down}, ['ctrl+j'] = {v.line_down}, ['ctrl+n'] = {v.line_down},
	k = {v.line_up}, ['ctrl+p'] = {v.line_up},
	l = {M.char_right_not_line(view)}, [' '] = {M.char_right_not_line(view)},
	w = {v.word_right},
	W = {M.bigword_right},
	b = {v.word_left},
	B = {M.bigword_left},
	e = {v.word_right_end},
	E = {M.bigword_right_end},
	H = {M.screen_top, v.line_down},
	M = {M.screen_middle},
	L = {M.screen_bottom, v.line_up},
	G = {v.goto_line},
	['0'] = {v.home, 0},
	['$'] = {v.line_end, v.line_down_end},
	['^'] = {v.vc_home, 0},
	['+'] = {v.line_down_vc_home}, ['ctrl+m'] = {v.line_down_vc_home},
	['-'] = {v.line_up_vc_home},
	['|'] = {v.home, v.char_right},
	['ctrl+f'] = {v.page_down},
	['ctrl+b'] = {v.page_up},
	['ctrl+d'] = {M.half_page_down},
	['ctrl+u'] = {M.half_page_up},
	['ctrl+e'] = {v.line_scroll_down},
	['crtl+y'] = {v.line_scroll_up},
	['esc'] = {0}, -- cancel current chain
--	['%'] = {v.brace_match, 0, args = {v.current_pos}},
	['_'] = {v.vc_home, line_down_vc_home},
	['('] = {M.sentence_last},
	[')'] = {M.sentence_next},
	['{'] = {v.para_up},
	['}'] = {v.para_down},
-- search
--[[	[';'] = {repeat_find},
	[','] = {reverse_find},
	['/'] = {search, 0},
	['?'] = {search_back, 0},
	n = {repeat_find, 0},
	N = {reverse_find, 0},
-- editor
	['.'] = {last_command},
	[':'] = {ex_command, 0},
	['ctrl+g'] = {display_information, 0},
	['ctrl+^'] = {ui.switch_buffer, 0},
	['&'] = {0} -- repeat last ex s command
-- editing
	['~'] = {reverse_case},
	J = {textadept.editing.join_lines},
-- buffer commands
	p = {},
	P = {},
	s = {command = 'c', motion = ' '}, -- {buffer}{count} c<space>
	S = {command = 'c', motion = '_'}, -- {buffer}{count} c_
	x = {cut_char_left}, -- but don't join lines
	X = {cut_char_right}, -- but don't join lines, figure that out
-- mark commands
	m = {mark, 0, state = state.mark}
	["'"] = {return_to_mark, vc_home, 0, state = state.mark},
	['`'] = {return_to_mark, 0, state = state.mark},
-- char commands
	f = {state = state.char},
	F = {state = state.char},
	t = {state = state.char},
	T = {state = state.char},
	r = {state = state.char},
	['@'] = {eval_buffer, state = state.char}, -- run the contents of a buffer as if it was typed
-- motion commands
	d = {v.cut},
	D = {command = 'd', motion = '$'}, -- {buffer} d$
	y = {},
	Y = {command = 'y', motion = '_'}, -- {buffer}{count} y_
	['!'] = {}, -- open command entry and run a system command
	['<'] = {},
	['>'] = {},
-- motion, buffer, and mode change
	c = {state = state.motion},
	C = {command = 'c', motion = '$'}, -- {buffer}{count} c$
-- input mode commands
]]
--	a = {state = state.input},
--	A = {state = state.input},
	i = {state = state.input},
--	I = {state = state.input},
--	o = {state = state.input},
--	O = {state = state.input},
--	R = {state = state.input},
}

-- Valid motions for ! < > c d y
-- Motion table format is same as command format.
-- "move extends selection" is set to true after first command
-- and restored after last command has been repeated.
M.motions = {
	"'",         
	',',
	'ctrl+h',
	'ctrl+n',
	'ctrl+p',
	'`',
	'\n',
	' ',
	'0',
	'(',
	')',
	'[',
	']',
	'{',
	'}',
	'^',
	'+',
	'|',
	'/',
	'-',
	'$',
	'%',
	'_',
	';',
	'?',
	'b',
	'e',
	'f',
	'h',
	'j',
	'k',
	'l',
	'n',
	't',
	'w',
	'B',
	'E',
	'F',
	'G',
	'H',
	'L',
	'M',
	'N',
	'T',
	'W',
}

-- module functions below

-- function to allow vi_mode to be assigned to a keycode
local current_state = state.start
local function handle_keypress(key)
	if current_state == nil then
		registered = false
		events.disconnect(handle_keypress)
		return false
	end
	local handled
	handled, current_state = current_state(key)
	return handled
end

meta = {__call =
	function ()
		if not registered then
			events.connect(events.KEYPRESS, handle_keypress, 1)
			registered = true
		end
	end,
}
setmetatable(M, meta)

return M
