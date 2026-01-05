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
-- +Implement all the stubbed and commented out functions
-- +Merge motions and commands table into one (just make motion keycodes be
-- multikeys with some untypeable character at the front like \0)
-- +TA bookmarks only mark lines so implement character marking
-- +Implement input mode repetition w/ count
-- +Add flag to include style bytes in argument to M.output
-- +Line undo mode?
-- +ctags? (needs ex commands)

local fetch = require('vitamin.fetch')
local registers = require('vitamin.registers')
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

--- The register that stores the previous search regex
M.search_register = '/'

--- The register that stores the previous find character
M.find_register = ';'

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
	-- cursor is not allowed to move onto newline
	if view.current_pos < view.line_end_position[line] - 1 then
		view:char_right()
	end
end

--- Move without wrapping.
--  Because setting vs_no_wrap_line_start would work for left but not right.
function M.char_left_extend_not_line(view) -- h
	local line, pos = view:get_cur_line()
	if pos > 1 then
		view:char_left_extend()
	end
end
function M.char_right_extend_not_line(view) -- l
	local line = view:line_from_position(view.current_pos)
	-- extension is allowed onto line end
	if view.current_pos < view.line_end_position[line] then
		view:char_right_extend()
	end
end

--- Goto visible column number (not character).
function M.goto_column(view, column)
	view:goto_pos(view:find_column(view:line_from_position(view.current_pos), column or 1))
end

--- Search by C++11 ECMAScript regex in the active view.
--  Start from view.current_pos +/- offset, end at specified
--  location.
local function regex_search(regex, start_offset, target_end)
	view.search_flags = view.FIND_MATCHCASE | view.FIND_REGEXP | view.FIND_CXX11REGEX
	view.target_start = view.current_pos + (start_offset or 1)
	view.target_end = target_end or view.length
	return view:search_in_target(regex)
end

--- Perform a vi search or find operation.
--  This function uses some extra fields stored on the register table to determine
--  additional search parameters. `registers[reg].search_start` optionally begins the
--  search from the specified position. `registers[reg].find_offset` optionally indicates
--  that the cursor is offset the specified position from where the search should start.
--  @param view view to search in.
--  @param reg register name that contains the search/find regular expression.
--  @param prev if true, search in the opposite direction of the previous search.
M.search_find = function (view, reg, prev)
	local reg = registers[reg]
	local regex = reg.text
	if regex ~= '' then
		local ts, te
		local back = reg.back
		back = (back and not prev) or (prev and not back)
		if back then te = 0 end
		if reg.search_start then ts = reg.search_start - view.current_pos
		else ts = 0 end
		if reg.find_offset then ts = ts + reg.find_offset * (prev and 1 or -1) end
		ts = ts + (back and -1 or 1) -- start search offset
		if regex_search(regex, ts, te) >= 0 then view:goto_pos(view.target_start)
		else error('No match found for "'..regex..'"', 0) end
	else error('No search/find specified', 0) end
end

M.search_prompt = function (command)
	if fetch.prompt(command) then
		if not command.prompt_result then
			command.needs = fetch.start
			command.status = ''
			return
		elseif command.prompt_result ~= '' then
			registers[M.search_register].text = command.prompt_result
		end
		registers[M.search_register].back = command.back
	end
	return Command.default_before(command)
end
M.search = function (view, prev)
	M.search_find(view, M.search_register, prev)
	registers[M.search_register].search_start = view.current_pos
end
M.search_prev = function (view)
	M.search(view, true)
end

M.find_arg = function (command)
	if type(command.arg) ~= 'string' and utf.len(command.arg) ~= 1 then
		error('Invalid character for find command', 0)
	end
	local char = '['..string.gsub(command.arg, '[%[%]%^]', '\\%0')..']'
	-- transform command.arg into a regex
	-- or just use Scintilla literal search??
	-- store it in ;
	registers[M.find_register] = char
	registers[M.find_register].back = command.back
	registers[M.find_register].find_offset = command.offset or 0
end
M.find = function (view, prev)
	M.search_find(view, ';', prev)
	local move = registers[';'].find_offset or 0
	if prev then move = move * -1 end
	view.goto_pos(view.current_pos + move)
end
M.find_prev = function (view)
	M.find(view, true)
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
	view:goto_pos(view:brace_match(regex_search('[\\(\\[\\{\\)\\]\\}]'), 0))
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

--- Decrement `commmand.count` before using it as repetition.
--  If `command.count` is not set then assume 0 instead of 1.
function M.dec_count(command)
	command.count = command.count == nil and 0 or command.count - 1
end

--- Get `command.count` for use as an argument to `view` functions.
--  Used for e.g. `view.goto_line` for the G command.
function M.get_count(command)
	return command.count == nil and 1 or command.count
end

--- Cursor movement based on register mode for the p command.
function M.move_p(view, text, mode)
	if mode == 'line' then view:line_end()
	else M.char_right_not_line(view) end
end
--- Cursor movement based on register mode for the P command.
function M.move_P(view, text, mode)
	if mode == 'line' then view:line_up() view:line_end() end
end
--- Extend by count but throw an error if line end is hit, for r
function M.extend_r(command)
	local line_end = view.line_end_position[view:line_from_position(view.current_pos)]
	local end_pos = view.current_pos + (command.count or 1)
	if end_pos > line_end then error('too few characters to replace.', 0)
	else view.current_pos = end_pos end
	dp(Command.default_before(command))
	return Command.default_before(command)
end

function M.clear_selection(view)
	view.set_empty_selection(view, view.current_pos)
end

function M.get_and_clear(view)
	local text = view:get_sel_text()
	view:clear()
	return text
end

--- View alias to make definitions shorter.
-- TODO: I suppose I could use the trick from command_entry where you map view's
-- metatable onto _ENV to shorten this up even more.
local v = view

--- Command alias to make definitions shorter.
-- TODO: You should probably be able to call class methods from the table automatically.
local C = Command

--- Utility to allow commands to call arbitrary functions.
local f = function (f, ...) args = {...} return function () f(table.unpack(args)) end end

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
	['['] = {needs = fetch.command, def = {
		['[['] = {M.section_last}}},
	[']'] = {needs = fetch.command, def = {
		[']]'] = {M.section_next}}},
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
-- search
	[';'] = {M.find},
	[','] = {M.find_prev},
	['/'] = {before = M.search_prompt, M.search},
	['?'] = {before = M.search_prompt, M.search, back = true},
	n = {M.search, count = 1},
	N = {M.search_prev, count = 1},
-- editor
	u = {v.undo},
	U = {v.redo},
--	['.'] = {M.repeat_edit},
--	[':'] = {M.ex_command, 0},
--	['&'] = {M.nop} -- repeat last ex s command
	['ctrl+g'] = {before = M.display_info},
--	['ctrl+^'] = {ui.switch_buffer},
-- editing
--	J = {textadept.editing.join_lines},
--	['~'] = {M.reverse_case},
-- buffer commands
	p = {before = C.get_reg, M.move_p, v.add_text, after = M.char_left_not_line},
	P = {before = C.get_reg, M.move_P, v.add_text, after = M.char_left_not_line},
--	s = {command = 'c', motion = Motion.new(' ')}, -- {buffer}{count} c<space>
--	S = {command = 'c', motion = Motion.new('_')}, -- {buffer}{count} c_
	x = {M.char_right_extend_not_line, after = {v.get_sel_text, v.clear}},
	X = {M.char_left_extend_not_line, after = {v.get_sel_text, v.clear}},
-- mark commands
--	m = {mark, 0, needs = fetch.mark}
--	["'"] = {return_to_mark, vc_home, 0, needs = fetch.arg},
--	['`'] = {return_to_mark, 0, needs = fetch.arg},
-- char commands
	f = {needs = fetch.arg, before = M.find_arg, M.find},
	F = {needs = fetch.arg, before = M.find_arg, back = true, M.find},
	t = {needs = fetch.arg, before = M.find_arg, offset = -1, M.find},
	T = {needs = fetch.arg, before = M.find_arg, back = true, offset = -1, M.find},
	r = {needs = fetch.arg, before = M.extend_r, v.clear, v.add_text},
--	['@'] = {needs = fetch.arg, M.eval_buffer}, -- run the contents of a buffer as if it was typed
-- motion commands
	d = {needs = fetch.subcommand, M.get_and_clear},
	y = {needs = fetch.subcommand, before = C.restore_pos_after, v.get_sel_text},
--	q = {needs = fetch.subcommand}, -- debug command, TODO: remove
--	['!'] = {}, -- open command entry and run a system command
	['>'] = {needs = fetch.subcommand, v.line_indent},
	['<'] = {needs = fetch.subcommand, v.line_dedent},
-- motion, buffer, and mode change
	c = {sub = Command{needs = fetch.subcommand, M.get_and_clear}, needs = fetch.input},
--	C = {command = 'c', motion = Motion.new('$')}, -- {buffer}{count} c$
-- input mode commands

--	a = {needs = fetch.input},
--	A = {needs = fetch.input},
	i = {needs = fetch.input, status = '-- INSERT --'},
--	I = {needs = fetch.input},
--	o = {needs = fetch.input},
--	O = {needs = fetch.input},
--	R = {needs = fetch.input},
}
Command.commands = commands
-- Shortcuts to make motion definition simpler
local l = {mode = 'line'}
local c = {mode = 'char'}
local b = {C.parent_times, C.save_pos}
local bd = {C.parent_times, C.save_pos, M.dec_count}
local be = {C.parent_times, C.save_pos, C.extend}

-- Valid motions for ! < > c d y
-- Set view.move_extends_selection = true before and = false after
-- Motion definitions format is the same as command definition.
-- Since all of these will use `Command.parent_times`, it is implied
-- and set in a loop after the definition.
local motions = {
	h = {reg=c, before=b, M.char_left_extend_not_line},
	['ctrl+h'] = {reg=c, before=b, M.char_left_extend_not_line},
	j = {reg=l, before=b, v.home, v.line_down_extend, after = v.end_extend},
	['ctrl+n'] = {reg=l, before=b, v.home, v.line_down_extend, after = v.end_extend},
	['\n'] = {reg=l, before=b, v.home, v.line_down_extend, after = v.end_extend},
	k = {reg=l, before=b, v.line_end, v.home_extend, v.line_up_extend},
	['ctrl+p'] = {reg=l, before=b, v.line_end, v.home_extend, v.line_up_extend},
	l = {reg=c, before=b, M.char_right_extend_not_line},
	[' '] = {reg=c, before=b, M.char_right_extend_not_line},
	w = {reg=c, before=be, v.word_right},
	W = {reg=c, before=be, M.bigword_right},
	b = {reg=c, before=be, v.word_left},
	B = {reg=c, before=be, M.bigword_left_extend},
	e = {reg=c, before=be, v.char_right, v.word_right_end, after = v.char_left},
	E = {reg=c, before=be, M.bigword_right_end_extend},
--	H = {v.home, v.line_down, M.screen_top_extend, v.line_up_extend, v.line_down_extend},
--	M = {},
--	L = {v.line_end, M.screen_bottom_extend, v.line_down_extend, v.line_down_extend, v.line_up_extend},
--	G = {},
--	['0'] = {},
--	['('] = {},
--	[')'] = {},
--	['{'] = {},
--	['}'] = {},
--	['^'] = {},
--	['+'] = {},
--	['|'] = {},
--	['-'] = {},
	['$'] = {reg=c, before=bd, v.line_down_extend, after = v.line_end_extend},
--	['%'] = {},
	['_'] = {reg=l, before=b, v.home, v.line_down_extend},
-- search motions
--	n = {},
--	N = {},
--	[','] = {},
--	[';'] = {},
--	['/'] = {},
--	['?'] = {},
-- char motions
--	f = {},
--	t = {},
--	F = {},
--	T = {},
--	["'"] = {},
--	['`'] = {},
}
Command.motions = motions

--commands['D'] = {sub = Command(motions['$']), M.get_and_clear}
--commands['Y'] = {before = C.restore_pos_after, v.get_sel_text, sub = Command(motions['_'])} -- {buffer}{count} y_

local dittos = {}
Command.dittos = dittos
Command.default_motion = '_'

--- Save off user preferences and setup view style.
--  Make it look like a terminal, since that's how vi
--  is supposed to behave.
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
