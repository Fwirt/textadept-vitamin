-- Copyright (c) 2025 Fwirt. See LICENSE.

-- vitamin
-- vi textadept modal interface
-- Based on the POSIX standard for vi commands:
-- https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html
-- Uses a custom event handler to implement a state machine instead
-- of the built-in chain handler

-- vi incompatibilites:
-- - not implemented:
-- - ctrl+l, ctrl+r, z serve no purpose for Scintilla
-- - Q, since there is no way to "exit visual mode", although I suppose
--      this could enter a command loop...
-- - U, if I can figure out how to hack this in, maybe someday
-- - q, ZZ close buffer instead of editor
-- - a, A do not prevent text deletion
-- - Input mode uses TA keybinds instead of vi keybinds
--   	i.e. input mode commands that duplicate existing functionality are not implemented
--   	(ctrl+d, ctrl+h, ctrl+j, ctrl+m, ctrl+u, ctrl+w)

-- TODO:
-- +TA bookmarks only mark lines so implement character marking
-- +Implement all the stubbed and commented out functions
-- +Implement input mode repetition w/ count
-- +Add flag to include style bytes in argument to M.output
-- +Line undo mode?
-- +ctags? (needs ex commands)

local fetch = require('vitamin.fetch')
local Command = require('vitamin.command')

local M = {}

--- Map fetch events to Vitamin events for user handlers
M.ENTERED = fetch.CONNECT
M.EXITED = fetch.DISCONNECT

-- nroff paragraph and section macros for [[,]],{,}.
-- These get dropped into a regex so the pipes are necessary
-- I did not think I would implement this...
M.sections = 'SH|NH|H |HU|nh|sh'
M.paragraphs = 'IP|LP|PP|QP|P |TP|HP|LI|Pp|Lp|It|pp|lp|ip|bp'
local sect_regex = '^(\012|\\{|\\.(%s))'
local para_regex = '^($|\012|\\{|\\.(%s))'
-- for vi compatibility this should actually have 2 spaces after the sentence.
local sent_regex = '[\\.\\!\\?][\\)\\]\\"\\\']*( |$)'

-- the keycode to exit Vitamin mode
M.exit_mode_keycode = 'ctrl+esc'

-- where to put command output, override this to set different destination.
M.output = function (text) ui.statusbar_text = tostring(text) end

-- if true, text argument to M.output will be Scintilla cells instead of plain text
M.output_include_style = false

-- The keycode that exits Vitamin mode
fetch.exit_keycode = 'ctrl+esc'

-- the keycode to exit input mode or cancel current command
fetch.escape_keycode = 'esc'

-- the current state of the state machine
local current_state

-- the current command of the keychain
local current_command

--  ### New Scintilla movement functions ###
--  Most movements use regex because it works with UTF-8
--  automatically.

--- Search by C++11 ECMAScript regex in the active view.
--  Start from view.current_pos +/- offset, end at specified
--  location.
local function regex_search(regex, start_offset, target_end)
	view.search_flags = view.FIND_REGEXP | view.FIND_CXX11REGEX
	view.target_start = view.current_pos + start_offset
	view.target_end = target_end or view.length
	return view:search_in_target(regex)
end

--- Move without wrapping.
--  Because setting vs_no_wrap_line_start would work for left but not right.
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

--- Goto visible column number (not character).
function M.goto_column(view, column)
	view:goto_pos(view:find_column(view:line_from_position(view.current_pos), column or 1))
end

--- Move by bigword /[\s\t\n]+.*[\s\t\n]/.
-- The default Scintilla word definition already matches vi.
function M.bigword_right(view) -- W
	if regex_search('(\\s+|^)\\S', view.column[view.current_pos] == 1 and 1 or 0) == -1 then view:home()
	else view:goto_pos(view.target_end-1) end
end
function M.bigword_left(view) -- B
	if regex_search('\\S+', 0, 0) == -1 then view:home()
	else view:goto_pos(view.target_start) end
end
function M.bigword_right_end(view) -- E
	if regex_search('\\S(\\s|$)', 1) == -1 then view:line_end()
	else view:goto_pos(view.target_start) end
end

--- Move by section (nroff section macros, or a form feed or {)
function M.section_last(view) -- [[
	local result = regex_search(string.format(sect_regex, M.sections), -1, 0)
	view:goto_pos(result < 0 and 1 or view.target_start)
end
function M.section_next(view) -- ]]
	local result = regex_search(string.format(sect_regex, M.sections), 1)
	view:goto_pos(result < 0 and view.length or result)
end

--- Move by paragraphs (section & paragraph boundaries & blank lines)
function M.paragraph_last(view) -- {
	local result = regex_search(string.format(para_regex, M.paragraphs..'|'..M.sections), 0, 0)
	if result == view.current_pos then -- if we're already on a boundary then find the nearest non-whitespace
		regex_search('\\S', -1, 0)
		result = regex_search(string.format(para_regex, M.paragraphs..'|'..M.sections), view.target_start - view.current_pos, 0)
	end
	view:goto_pos(result < 0 and 1 or view.target_start)
end
function M.paragraph_next(view) -- }
	regex_search('\\S', 0)
	view:goto_pos(view.target_end)
	local result = regex_search(string.format(para_regex, M.paragraphs..'|'..M.sections), 0)
	view:goto_pos(result < 0 and view.length or view.target_start)
end

--- Move by sentence.
--  Sentence boundary is paragraph boundary or first non-blank after
--  (paragraph boundary or /[\.\!\?][\)\]\"\']*( |$)/).
--  This is ugly and I hate it.
--  Backwards search is annoying because we might be inside a sentence boundary
--  and C++11 regex doesn't support lookbehind, so we have to search twice.
function M.sentence_last(view) -- (
	regex_search(sent_regex, 0, 0) -- search backward for sentence boundary
	local sentence = view.target_start -- get location of [.!?]
	local after_sentence = regex_search('\\S', view.target_end - view.current_pos) -- find first non-blank
	if after_sentence >= view.current_pos then -- if caret is inside the boundary...
		sentence = regex_search(sent_regex, sentence - view.current_pos - 1, 0) -- find the next boundary
		after_sentence = regex_search('\\S', view.target_end - view.current_pos) -- and the next non-blank
	end
	-- and now the paragraph backward-search dance...
	local paragraph = regex_search(string.format(para_regex, M.paragraphs..'|'..M.sections), 0, 0)
	if paragraph == view.current_pos then
		regex_search('\\S', 0, 0) -- make sure we're not already on a paragraph boundary
		local paragraph = regex_search(string.format(para_regex, M.paragraphs..'|'..M.sections), view.target_start - view.current_pos, 0)
	end
	local after_paragraph = regex_search('\\S', view.target_end - view.current_pos) -- nearest non-blank after paragraph
	local closest = 0
	for _, v in ipairs({after_sentence, paragraph, after_paragraph}) do
		if v > closest and v < view.current_pos then closest = v end
	end
	view:goto_pos(closest)
end
--  Forward search is *slightly* more straightforward, we just need to find the
--  nearest paragraph boundary (even if we're on it), the nearest non-blank after
--  the paragraph boundary, and the nearest non-blank after the next sentence boundary.
function M.sentence_next(view) -- )
	regex_search(sent_regex, 0)
	local sentence = view.target_end
	local after_sentence = regex_search('\\S', view.target_end - view.current_pos)
	local paragraph = regex_search(string.format(para_regex, M.paragraphs..'|'..M.sections), 0)
	local after_paragraph = regex_search('\\S', view.target_end - view.current_pos)
	local closest = view.length
	for _, v in ipairs({after_sentence, paragraph, after_paragraph}) do
		if v < closest and v > view.current_pos then closest = v end
	end
	view:goto_pos(closest)
end

-- move cursor to position in current window
function M.screen_top(view) -- H
	view:goto_pos(view:position_from_line(view.first_visible_line))
end
function M.screen_middle(view) -- M
	view:goto_pos(view:position_from_line(
		view.first_visible_line + (view.lines_on_screen-1)//2
	))
end
function M.screen_bottom(view) -- L
	view:goto_pos(view:position_from_line(
		view.first_visible_line + view.lines_on_screen-1
	))
end

-- select to position in current window for motions
function M.screen_top_extend(view) -- H
	view.current_pos = view:position_from_line(view.first_visible_line)
end
function M.screen_middle_extend(view) -- M
	view.current_pos = view:position_from_line(
		view.first_visible_line + (view.lines_on_screen-1)//2
	)
end
function M.screen_bottom_extend(view) -- L
	view.current_pos = view:position_from_line(
		view.first_visible_line + view.lines_on_screen-1
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
function M.half_page_down(view)
	local length =  view.lines_on_screen // 2
	local range_end = view:position_from_line(view.first_visible_line + view.lines_on_screen + length)
	local range_start = view:position_from_line(view.first_visible_line + length)
	view:scroll_range(range_end, range_start)
	view:goto_pos(view:position_from_line(view:line_from_position(view.current_pos) + length))
end -- ctrl+d
function M.half_page_up(view)
	local length =  view.lines_on_screen // 2
	local range_end = view:position_from_line(view.first_visible_line + view.lines_on_screen - length)
	local range_start = view:position_from_line(view.first_visible_line - length)
	view:scroll_range(range_start, range_end)
	view:goto_pos(view:position_from_line(view:line_from_position(view.current_pos) - length))
end -- ctrl

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

function M.count_or_last(command)
	return command.count == nil and view.line_count or command.count
end

-- file, path, current line, total lines, modified, readonly
function M.display_info(command)
	local name = buffer.filename or '[no name]'
	local line = view:line_from_position(view.current_pos)
	local modified = buffer.modify and 'modified' or ''
	command.status = string.format("%s Line: %d/%d %s", name, line, view.line_count, modified)
end

function M.dec_count(command)
	command.count = command.count == nil and 0 or command.count - 1
end

function M.get_count(command)
	return command.count == nil and 1 or command.count
end

--- View alias to make definitions shorter
-- I suppose I could use the trick from command_entry where you map view's
-- metatable onto _ENV to shorten this up even more.
local v = view

--- A definition is a sequence of functions with optional fields
--  numeric indices will be called in order, with the last index called [count] times
--  all functions are called with the active view as the first parameter
--  if arg is specified it will be passed as the second parameter
-- @field state indicates next state to call, for commands with args or motions
-- @field func called with command as argument, result is packed,
--	view inserted at front, unpacked and passed to all functions
-- @field after called with argfunc as argument after the last command is repeated
-- @field getreg if true, pass the text of the specified register to the command as the second argument
local commands = {
	h = {M.char_left_not_line}, ['ctrl+h'] = {M.char_left_not_line}, ['\b'] = {M.char_left_not_line},
	j = {v.line_down}, ['\n'] = {v.line_down}, ['ctrl+j'] = {v.line_down}, ['ctrl+n'] = {v.line_down},
	k = {v.line_up}, ['ctrl+p'] = {v.line_up},
	l = {M.char_right_not_line}, [' '] = {M.char_right_not_line},
	w = {v.word_right},
	W = {M.bigword_right},
	b = {v.word_left},
	B = {M.bigword_left},
	e = {v.char_right, v.word_right_end, after = v.char_left},
	E = {M.bigword_right_end},
	H = {M.screen_top, v.line_down, before = M.dec_count, after = v.vc_home},
	M = {M.screen_middle, after = v.vc_home, count = 1},
	L = {M.screen_bottom, v.line_up, before = M.dec_count, after = v.vc_home},
	G = {after = v.goto_line, before = M.count_or_last},
	['0'] = {v.home, count = 1},
	['$'] = {v.line_down, before = M.dec_count, after = v.line_end},
	['^'] = {v.vc_home, count = 1}, -- FIXME: shouldn't go home on second press
	['+'] = {v.line_down, after = v.vc_home}, ['ctrl+m'] = {v.line_down, after = v.vc_home}, -- FIXME: shouldn't go home on second press
	['-'] = {v.line_up, after = v.vc_home}, -- FIXME: shouldn't go home on second press
	['|'] = {M.goto_column, before = M.get_count},
	['%'] = {M.brace_right_match, count = 1},
	['_'] = {v.line_down, before = M.dec_count, after = v.vc_home},
	['('] = {M.sentence_last},
	[')'] = {M.sentence_next},
	['{'] = {M.paragraph_last},
	['}'] = {M.paragraph_next},
	-- see below for multikey definitions
	['[['] = {M.section_last},
	[']]'] = {M.section_next},
	['ctrl+f'] = {v.page_down, after = M.screen_top},
	['ctrl+b'] = {v.page_up, after = M.screen_bottom},
	['ctrl+d'] = {M.half_page_down},
	['ctrl+u'] = {M.half_page_up},
	['ctrl+e'] = {v.line_scroll_down},
	['ctrl+y'] = {v.line_scroll_up},
	['up'] = {v.line_up},
	['down'] = {v.line_down},
	['left'] = {v.char_left},
	['right'] = {v.char_right},
	['home'] = {v.vc_home},
	['end'] = {v.line_end},
	['pgup'] = {v.page_up},
	['pgdn'] = {v.page_down},
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
	['ctrl+g'] = {before = M.display_info},
	['ctrl+^'] = {ui.switch_buffer, M.nop},
-- editing
	J = {textadept.editing.join_lines},
	['~'] = {M.reverse_case},
-- buffer commands
	p = {v.add_text, before = function (c) return c:reg_text() end},
	P = {v.add_text, before = function (c) return c:reg_text() end},
	s = {command = 'c', motion = Motion.new(' ')}, -- {buffer}{count} c<space>
	S = {command = 'c', motion = Motion.new('_')}, -- {buffer}{count} c_
	x = {M.char_right_extend_not_line, after = M.buffer_cut}, -- but don't join lines
	X = {M.char_left_extend_not_line, after = M.buffer_cut}, -- but don't join lines, figure that out
-- mark commands
	m = {mark, 0, needs = fetch.mark}
	["'"] = {return_to_mark, vc_home, 0, needs = fetch.arg},
	['`'] = {return_to_mark, 0, needs = fetch.arg},
-- char commands
	f = {needs = fetch.arg},
	F = {needs = fetch.arg},
	t = {needs = fetch.arg},
	T = {needs = fetch.arg},
	r = {needs = fetch.arg},
	['@'] = {eval_buffer, needs = needs.char}, -- run the contents of a buffer as if it was typed
-- motion commands
	d = {v.cut},
	D = {command = 'd', motion = Motion.new('$')}, -- {buffer} d$
	y = {},
	Y = {command = 'y', motion = Motion.new('_')}, -- {buffer}{count} y_
	['!'] = {}, -- open command entry and run a system command
	['<'] = {},
	['>'] = {},
-- motion, buffer, and mode change
	c = {needs = fetch.motion},
	C = {command = 'c', motion = Motion.new('$')}, -- {buffer}{count} c$
-- input mode commands
]]
--	a = {needs = fetch.input},
--	A = {needs = fetch.input},
--	i = {needs = fetch.input, output = '-- INSERT --'},
--	I = {needs = fetch.input},
--	o = {needs = fetch.input},
--	O = {needs = fetch.input},
--	R = {needs = fetch.input},
}
-- circular references won't work until the table is populated
commands['['] = {needs = fetch.arg, before = Command.multikey(commands)}
commands[']'] = {needs = fetch.arg, before = Command.multikey(commands)}
Command.commands = commands

-- Valid motions for ! < > c d y
-- Set view.move_extends_selection = true before and = false after
-- Motion definitions format is the same as command definition.
local motions = {
	h = {M.char_left_extend_not_line}, 	['ctrl+h'] = {M.char_left_extend_not_line},
	j = {v.home, v.line_down_extend, after = v.end_extend},
	['ctrl+n'] = {v.home, v.line_down_extend, after = v.end_extend},
	['\n'] = {v.home, v.line_down_extend, after = v.end_extend},
	k = {v.line_end, v.home_extend, v.line_up_extend},
	['ctrl+p'] = {v.line_end, v.home_extend, v.line_up_extend},
	l = {M.char_right_extend_not_line}, [' '] = {M.char_right_extend_not_line},
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
	['_'] = {v.home, v.line_down_extend},
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
}
Command.motions = motions

local dittos = {}
Command.dittos = dittos
Command.default_motion = '_'

--- Save off user preferences and setup view style to look
--  like a terminal, since that's what vi expects.
local function save_set_view_style(viewarg)
	local view = viewarg or _G.view
	view._vitamin_save = {}
	local vs = view._vitamin_save
	vs.caret_period = view.caret_period
	vs.caret_style = view.caret_style
	
	view.caret_period = 0
	view.caret_style = view.CARETSTYLE_BLOCK
	-- unfortunately it's not possible to save this
	view:set_y_caret_policy(view.CARET_EVEN, -1)
end
--- Restore saved preferences. Caret policy will have to be
--  reset to default by user.
local function restore_view_style(viewarg)
	local view = viewarg or _G.view
	local vs = view._vitamin_save
	if vs then
		view.caret_period = vs.caret_period
		view.caret_style = vs.caret_style
	end
end

local function disconnect()
	for _, view in pairs(_VIEWS) do restore_view_style() end
	events.disconnect(events.VIEW_BEFORE_SWITCH, restore_view_style)
	events.disconnect(events.VIEW_AFTER_SWITCH, save_set_view_style)
	events.disconnect(fetch.DISCONNECT, disconnect)
	ui.statusbar_text = "Vitamin exited"
end

local function connect()
	save_set_view_style()
	events.connect(events.VIEW_BEFORE_SWITCH, restore_view_style)
	events.connect(events.VIEW_AFTER_SWITCH, save_set_view_style)
	events.connect(fetch.DISCONNECT, disconnect)
	fetch.connect()
	ui.statusbar_text = "Vitamin entered"
end

--- Read-only local variables
local locals = {commands = commands, motions = motions, dittos = dittos}

return setmetatable(M, {
	__call = connect,
	__newindex = function (self, index, value)
		if index == 'commands' or index == 'motions' or index == 'dittos' then
			error('command tables cannot be assigned, only mutated', 2)
		else
			rawset(self, index, value)
		end
	end,
	__index = function (self, index)
		return locals[index] or rawget(self, index)
	end
})
