-- Copyright (c) 2025 Fwirt. See LICENSE.

-- vitamin
-- vi textadept modal interface
-- Based on the POSIX standard for vi commands:
-- https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html
-- Uses a custom event handler to implement a state machine instead
-- of the built-in chain handler

-- vi incompatibilites:
-- - not implemented:
-- 		[[, ]], ctrl+l, ctrl+r, ctrl+], Q, U, z
-- - q, ZZ close buffer instead of editor
-- - a, A enter insert mode (same as vim, does not prevent deletion)
-- - Input mode uses TA keybinds instead of vi keybinds
--   	i.e. input mode commands that duplicate existing functionality are not implemented
--   	(ctrl+d, ctrl+h, ctrl+j, ctrl+m, ctrl+u, ctrl+w)

-- TODO:
-- +TA bookmarks only mark lines so implement character marking
-- +Implement all the stubbed and commented out functions
-- +Implement input mode repetition w/ count
-- +Implement useful vim features (select mode comes to mind)
-- +Add flag to include style bytes in argument to M.output

local State = require('vitamin.state')
local Command = require('vitamin.command')

local M = {}

-- the keycode to exit input mode or cancel current command
M.escape_keycode = 'esc'

-- the keycode to exit Vitamin mode
M.exit_mode_keycode = 'ctrl+esc'

-- where to put command output, override this to set different destination.
M.output = function (text) ui.statusbar_text = tostring(text) end

-- if true, text argument to M.output will be Scintilla cells instead of plain text
M.output_include_style = false

-- the current state of the state machine
local current_state

-- ### New Scintilla movement functions ###

-- move without wrapping.
-- setting vs_no_wrap_line_start would work for left but not right
function M.char_left_not_line(view) -- h
	local line, pos = view:get_cur_line()
	if pos > 1 then
		view:char_left()
	end
end
function M.char_right_not_line(view) -- l
	local line = view:line_from_position(view.current_pos)
	if view.current_pos < view.line_end_position[line] then
		view:char_right()
	end
end

-- move by bigword /[\s\t\n]+.*[\s\t\n]/
-- default word definition already matches vi
function M.bigword_right(view) -- W
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:search_in_target('[ \t\n]+')
	view:goto_pos(view.target_end+1)
end
function M.bigword_left(view) -- B
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = 0 -- search backwards
	view:search_in_target('[^ \t\n]*[ \t\n]+')
	view:goto_pos(view.target_start)
end
function M.bigword_right_end(view) -- E
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:search_in_target('.[ \t\n]+')
	view:goto_pos(view.target_start)
end

-- select by bigword /[\s\t\n]+.*[\s\t\n]/ for motions
function M.bigword_right_extend(view) -- W
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:search_in_target('[ \t\n]+')
	view.current_pos = view.target_end+1
end
function M.bigword_left_extend(view) -- B
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = 0 -- search backwards
	view:search_in_target('[^ \t\n]*[ \t\n]+')
	view.current_pos = view.target_start
end
function M.bigword_right_end_extend(view) -- E
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:search_in_target('.[ \t\n]+')
	view.current_pos = view.target_start
end

-- move by sentence /.*[\.\!\?][\)\]\"\']*\s/
function M.sentence_last(view) -- (
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = 0 -- search backwards
	view:search_in_target('[\\.\\!\\?][\\)\\]\\"\\\']* [^ \t\n]')
	view:goto_pos(view.target_end+1)
end
function M.sentence_next(view) -- )
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:search_in_target('[\\.\\!\\?][\\)\\]\\"\\\']* [^ \t\n]')
	view:goto_pos(view.target_end)
end

-- select by sentence /.*[\.\!\?][\)\]\"\']*\s/ for motions
function M.sentence_last_extend(view) -- (
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = 0 -- search backwards
	view:search_in_target('[\\.\\!\\?][\\)\\]\\"\\\']* [^ \t\n]')
	view.current_pos = view.target_end+1
end
function M.sentence_next_extend(view) -- )
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:search_in_target('[\\.\\!\\?][\\)\\]\\"\\\']* [^ \t\n]')
	view.current_pos = view.target_end
end

-- move cursor to position in current window
function M.screen_top(view) -- H
	view:goto_pos(view:position_from_line(view.first_visible_line))
end
function M.screen_middle(view) -- M
	view:goto_pos(view:position_from_line(
		view.first_visible_line + view.lines_on_screen // 2
	))
end
function M.screen_bottom(view) -- L
	view:goto_pos(view:position_from_line(
		view.first_visible_line + view.lines_on_screen
	))
end

-- select to position in current window for motions
function M.screen_top_extend(view) -- H
	view.current_pos = view:position_from_line(view.first_visible_line)
end
function M.screen_middle_extend(view) -- M
	view.current_pos = view:position_from_line(
		view.first_visible_line + view.lines_on_screen // 2
	)
end
function M.screen_bottom_extend(view) -- L
	view.current_pos = view:position_from_line(
		view.first_visible_line + view.lines_on_screen
	)
end

-- move to next brace position and match
function M.brace_right_match(view) -- %
	view.search_flags = view.FIND_REGEXP
	view.target_start = view.current_pos
	view.target_end = view.length
	view:goto_pos(view:brace_match(view:search_in_target('[\\(\\[\\{\\)\\]\\}]'), 0))
end

-- scroll keeping the cursor at the same location on screen
function M.half_page_down(view) ; end -- ctrl+d
function M.half_page_up(view) ; end -- ctrl+u

-- move a line and then home (not possible to repeat)
function M.line_up_vc_home(view) ; end -- -
function M.line_down_vc_home(view) ; end -- +
function M.line_down_end(view) ; end -- $

-- extend without wrapping
function M.char_left_extend_not_line(view) -- X
	local line, pos = view:get_cur_line()
	if pos > 1 then
		view:char_left_extend()
	end
end
function M.char_right_extend_not_line(view) -- x
	local line = view:line_from_position(view.current_pos)
	if view.current_pos < view.line_end_position[line] then
		view:char_right_extend()
	end
end

-- buffer cut/copy commands
function M.reg_cut(view) -- d
	local text = view:get_sel_text()
	view:clear()
	return text
end
function M.reg_copy(view) -- y
	local text = view:get_sel_text()
	view.current_pos = view.anchor
	return text
end

-- file, path, current line, total lines, modified, readonly
function M.display_information(view) ; end

-- This should probably be moved to init.lua for clarity.

--- A definition is a sequence of functions with optional fields
--  numeric indices will be called in order, with the last index called [count] times
--  all functions are called with the active view as the first parameter
--  if arg is specified it will be passed as the second parameter
-- @field state indicates next state to call, for commands with args or motions
-- @field func called with command as argument, result is packed,
--	view inserted at front, unpacked and passed to all functions
-- @field after called with argfunc as argument after the last command is repeated
-- @field getreg if true, pass the text of the specified register to the command as the second argument
local v = view
M.commands = {
	h = {M.char_left_not_line}, ['ctrl+h'] = {M.char_left_not_line}, ['\b'] = {M.char_left_not_line},
	j = {v.line_down}, ['\n'] = {v.line_down}, ['ctrl+j'] = {v.line_down}, ['ctrl+n'] = {v.line_down},
	k = {v.line_up}, ['ctrl+p'] = {v.line_up},
	l = {M.char_right_not_line}, [' '] = {M.char_right_not_line},
	w = {v.word_right},
	W = {M.bigword_right},
	b = {v.word_left},
	B = {M.bigword_left},
	e = {v.word_right_end},
	E = {M.bigword_right_end},
	H = {M.screen_top, v.line_up, v.line_down, after = v.vc_home},
	M = {M.screen_middle, after = v.vc_home},
	L = {M.screen_bottom, v.line_up, after = v.vc_home},
	G = {after = v.goto_line, func = function (self) return self.count end},
	['0'] = {v.home, count = 1},
	['$'] = {v.line_end, v.line_down_end},
	['^'] = {v.vc_home, count = 1},
	['+'] = {v.line_down, after = v.vc_home}, ['ctrl+m'] = {v.line_down, after = v.vc_home},
	['-'] = {v.line_up, after = v.vc_home},
	['|'] = {v.home, v.char_right},
	['%'] = {M.brace_right_match, count = 1},
	['_'] = {v.line_up, v.line_down, after = v.vc_home},
	['('] = {M.sentence_last},
	[')'] = {M.sentence_next},
	['{'] = {v.para_up},
	['}'] = {v.para_down},
	['ctrl+f'] = {v.page_down},
	['ctrl+b'] = {v.page_up},
	['ctrl+d'] = {M.half_page_down},
	['ctrl+u'] = {M.half_page_up},
	['ctrl+e'] = {v.line_scroll_down},
	['crtl+y'] = {v.line_scroll_up},
--[[ search
	[';'] = {M.repeat_find},
	[','] = {M.reverse_find},
	['/'] = {M.search, count = 1},
	['?'] = {M.search_back, count = 1},
	n = {M.repeat_search, count = 1},
	N = {M.reverse_search, count = 1},
-- editor
	['.'] = {M.repeat_edit}, --
	[':'] = {M.ex_command, 0},
	['&'] = {M.nop} -- repeat last ex s command
	['ctrl+g'] = {display_information, M.nop},
	['ctrl+^'] = {ui.switch_buffer, M.nop},
-- editing
	J = {textadept.editing.join_lines},
	['~'] = {M.reverse_case},
-- buffer commands
	p = {v.add_text, func = function (c) return c:reg_text() end},
	P = {v.add_text, func = function (c) return c:reg_text() end},
	s = {command = 'c', motion = Motion.new(' ')}, -- {buffer}{count} c<space>
	S = {command = 'c', motion = Motion.new('_')}, -- {buffer}{count} c_
	x = {M.char_right_extend_not_line, after = M.buffer_cut}, -- but don't join lines
	X = {M.char_left_extend_not_line, after = M.buffer_cut}, -- but don't join lines, figure that out
-- mark commands
	m = {mark, 0, state = State.mark}
	["'"] = {return_to_mark, vc_home, 0, state = State.arg},
	['`'] = {return_to_mark, 0, state = State.arg},
-- char commands
	f = {state = State.arg},
	F = {state = State.arg},
	t = {state = State.arg},
	T = {state = State.arg},
	r = {state = State.arg},
	['@'] = {eval_buffer, state = state.char}, -- run the contents of a buffer as if it was typed
-- motion commands
	d = {v.cut},
	D = {command = 'd', motion = Motion.new('$')}, -- {buffer} d$
	y = {},
	Y = {command = 'y', motion = Motion.new('_')}, -- {buffer}{count} y_
	['!'] = {}, -- open command entry and run a system command
	['<'] = {},
	['>'] = {},
-- motion, buffer, and mode change
	c = {state = State.motion},
	C = {command = 'c', motion = Motion.new('$')}, -- {buffer}{count} c$
-- input mode commands
]]
--	a = {state = State.input},
--	A = {state = State.input},
--	i = {state = State.input, output = '-- INSERT --'},
--	I = {state = State.input},
--	o = {state = State.input},
--	O = {state = State.input},
--	R = {state = State.input},
}
State.commands = M.commands

-- ### Motion definition table ###

-- Valid motions for ! < > c d y
-- Set view.move_extends_selection = true before and = false after
-- Motion definitions format is the same as command definition.
M.motions = {
	h = {M.char_left_extend_not_line}, 	['ctrl+h'] = {M.char_left_extend_not_line},
	j = {v.home, v.line_down_extend, after = v.end_extend},
	['ctrl+n'] = {v.home, v.line_down_extend, after = v.end_extend},
	['\n'] = {v.home, v.line_down_extend, after = v.end_extend},
	k = {v.line_end, v.home_extend, v.line_up_extend},
	['ctrl+p'] = {v.line_end, v.home_extend, v.line_up_extend},
	l = {M.char_right_extend_not_line},
	[' '] = {M.char_right_extend_not_line},
	w = {v.word_right_extend},
	W = {M.bigword_right_extend},
	b = {v.word_left_extend},
	B = {M.bigword_left_extend},
	e = {v.word_right_end_extend},
	E = {M.bigword_right_end_extend},
	H = {v.home, v.line_down, M.screen_top_extend, v.line_up_extend, v.line_down_extend},
	M = {},
	L = {v.line_end, M.screen_bottom_extend, v.line_down_extend, v.line_down_extend, v.line_up_extend},
	G = {},
	['0'] = {},
	['('] = {},
	[')'] = {},
	['{'] = {},
	['}'] = {},
	['^'] = {},
	['+'] = {},
	['|'] = {},
	['-'] = {},
	['$'] = {},
	['%'] = {},
	['_'] = {},
-- search motions
	n = {},
	N = {},
	[','] = {},
	[';'] = {},
	['/'] = {},
	['?'] = {},
-- char motions
	f = {},
	t = {},
	F = {},
	T = {},
	["'"] = {},
	['`'] = {},
-- convenience motions
	y = {},
	d = {},
	c = {},
	['>'] = {},
	['<'] = {},
	['!'] = {},
}
State.motions = M.motions

local installed = false
-- function to allow vi_mode to be assigned to a keycode
current_state = State.start
local function handle_keypress(key)
	if current_state == nil then
		events.disconnect(handle_keypress)
		return false
	end
	local handled
	handled, current_state = current_state(key)
	return handled
end

meta = {__call =
	function ()
		events.connect(events.KEYPRESS, handle_keypress, 1)
	end,
}
setmetatable(M, meta)

return M
