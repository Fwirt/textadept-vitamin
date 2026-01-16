-- Copyright (c) 2025 Fwirt. See LICENSE.

--- Line marking support module for Vitamin.
--  Textadept supports basic bookmarking of lines, but it uses Scintilla's
--  mark feature, which does not support character marking, and merges
--  deleted lines rather than removing them. Both are incompatible with vi
--  standard behavior, so this module implements vi marks, while also taking
--  advantage of Scintilla's margin and annotation features to make finding
--  existing marks easier.

-- TODO:
-- Sort marks by position on insertion/position set, to optimize loop and allow
-- jumping to next/previous mark (not a vi feature but still nice to have)

marks = {}

local style = {}
--- The indicator number to use.
style.indic_number = _SCINTILLA.new_indic_number()
--- The color of mark indicators.
style.indic_color = 0x0000ff
--- The style of mark indicators (which appear around the marked character)
style.indic_style = buffer.INDIC_POINTCHARACTER
--- Which margin number to display the line mark in
style.margin_n = 2
--- The color of margin markers.
style.marker_color = 0x0000ff
--- The symbol used for margin markers.
style.marker_symbol = buffer.MARK_BOOKMARK
--- The width of the margin needed to display the symbol
style.marker_width = 10
--- The marker number to use.
style.marker_number = _SCINTILLA.new_marker_number()

--- Set the marker and symbol style to the desired values on the given view
local function setup_view(view)
	if view == nil then view = _G.view end

	view.indic_style[style.indic_number] = style.indic_style
	view.indic_fore[style.indic_number] = style.indic_color
	
	view._marks_margins_before = view.margins
	if style.margin_n > view.margins then view.margins = style.margin_n end
	
	view._marks_type_before = view.margin_type_n[style.margin_n]
	view._marks_mask_before = view.margin_mask_n[style.margin_n]
	view._marks_width_before = view.margin_width_n[style.margin_n]
	
	view.margin_type_n[style.margin_n] = view.MARGIN_SYMBOL
	view.margin_mask_n[style.margin_n] = view.margin_mask_n[style.margin_n] | style.marker_symbol
	view.margin_width_n[style.margin_n] = style.marker_width
	
	view:marker_define(style.marker_number, style.marker_symbol)
	view.marker_fore[style.marker_number] = style.marker_color
	view.marker_back[style.marker_number] = style.marker_color
end

--- Restore a view's previous margin settings
local function restore_view(view)
	if view == nil then view = _G.view end
	view.margin_type_n[style.margin_n] = view._marks_type_before or view.margin_type_n[style.margin_n]
	view.margin_mask_n[style.margin_n] = view._marks_mask_before or view.margin_mask_n[style.margin_n]
	view.margin_width_n[style.margin_n] = view._marks_width_before or view.margin_width_n[style.margin_n]
	view.margins = view._marks_margins_before or view.margins
end

local function clear(buffer)
	buffer.indicator_current = style.indic_number
	buffer:indicator_clear_range(1, buffer.length)
	buffer:marker_delete_all(style.marker_number)
end

local function show(mark)
	if mark.visible then
		local buffer = mark.buffer
		buffer.indicator_current = style.indic_number
		buffer:indicator_fill_range(mark.pos, 1)
		buffer:marker_add(mark.line, style.marker_number)
	end
end

local function show_all(buffer)
	for _, mark in pairs(buffer.marks) do
		show(mark)
	end
end

marks.style = setmetatable({}, {
	__index = style,
	__newindex = function (self, index, value)
		for _, buffer in ipairs(_BUFFERS) do clear(buffer) end
		for _, view in ipairs(_VIEWS) do restore_view(view) end
		style[index] = value
		for _, view in ipairs(_VIEWS) do setup_view(view) end
		for _, buffer in ipairs(_BUFFERS) do show(buffer) end
	end,
})

--- Go to a mark, switching to the buffer it is located in if necessary.
local function jump(self)
	local buffer = self.buffer
	if self.pos < 0 then error("mark not found") end
	if view.buffer ~= buffer then for _, view in ipairs(_VIEWS) do
		if view.buffer == buffer then ui.goto_view(view) ; break end
	end end
	if view.buffer ~= buffer then view:goto_buffer(buffer) end
	view:goto_pos(self.pos)
end

local function new_mark(...)
	local buffer, visible = buffer, true
	local pos, line
	for _, v in ipairs({...}) do
		if type(v) == 'boolean' then visible = v
		elseif type(v) == 'number' then pos = v
		elseif type(v) == 'table' then buffer = v
		end
	end
	local mark = setmetatable({
		-- methods
		jump = jump, undo = undo, redo = redo,
		-- fields
		_undos = {}, _redos = {}, visible = visible, _type = 'mark',
		}, {
		__index = function (self, index)
			if index == 'pos' then return pos
			elseif index == 'line' then return line
			elseif index == 'visible' then return visible
			elseif index == 'buffer' then return buffer
			else rawget(self, index)
			end
		end,
		__newindex = function (self, index, value)
			if index == 'pos' then
				pos = assert_type(value, 'number', 'pos')
				if pos > 0 then
					line = buffer:line_from_position(value)
					-- prevent mark from being on newline (if possible)
					local line_end = buffer:position_before(buffer.line_end_position[line])
					if pos > line_end and buffer:position_from_line(line) <= line_end then pos = line_end end
				else line = -1 end
			elseif index == 'line' then
				line = assert_type(value, 'number', 'line')
				if line > 0 then pos = buffer:position_from_line(value)
				else pos = -1 end
			elseif index == 'buffer' then
				error('buffer is read-only', 2)
			else
				rawset(self, index, value)
			end
		end,
		__call = jump,
	})
	mark.pos = pos or buffer.current_pos -- ensure that position is valid by setting after object creation
	show(mark)
	return mark
end

--- Add the marks table to a buffer
local function new_marks(buffer)
	assert(type(buffer) == 'table', "new_marks requires buffer argument", 2)
	local t = {}
	local function reset()
		clear(buffer)
		t = {}
	end
	return setmetatable({reset = reset}, {
		__index = t,
		__newindex = function (self, index, value)
			if type(value) == 'number' or type(value) == 'boolean' then
				t[index] = new_mark(buffer, value)
			elseif type(value) == 'table' and value._type == 'mark' then
				t[index] = value
			else
				error("Mark assignment must be a mark, an integer or a boolean", 2)
			end
		end,
		__pairs = function () return pairs(t) end
	})
end

local function handle_before(flagf, pos, length)
	clear(buffer)
	local t = flagf
	local is_undo, is_redo = t(buffer.PERFORMED_UNDO), t(buffer.PERFORMED_REDO)
	for name, mark in pairs(buffer.marks) do
		if not is_undo then table.insert(mark._undos, mark.pos) end
		if is_undo and not is_redo then table.insert(mark._redos, mark.pos) end
		-- If buffer undo/redo goes back before mark was created then still move the mark
		-- and update the history.
		if not(is_undo and #mark._undos > 1) and not(is_redo and #mark._redos > 1) then
			if t(buffer.MOD_BEFOREDELETE) and mark.pos >= pos and mark.pos < pos + length then
				local line = mark.line
				local line_start = buffer:position_from_line(line)
				local line_end = line_start + buffer:line_length(line)
				if pos <= line_start and pos + length >= line_end then
					mark.pos = -1
				else
					mark.pos = pos
				end
			end
		end
	end
end

local function handle_after(flagf, pos, length)
	local t = flagf
	local is_undo, is_redo = t(buffer.PERFORMED_UNDO), t(buffer.PERFORMED_REDO)
	for name, mark in pairs(buffer.marks) do
		local restore
		if is_undo then restore = table.remove(mark._undos)
		elseif is_redo then restore = table.remove(mark._redos)
		end
		if restore then mark.pos = restore end
		if t(buffer.MOD_INSERTTEXT) and not restore then
			if mark.pos >= pos then mark.pos = mark.pos + length end
			if not (is_undo or is_redo) then mark._redos = {} end
		elseif t(buffer.MOD_DELETETEXT) and not restore then
			if mark.pos > pos then mark.pos = mark.pos - length
			else mark.pos = mark.pos end -- workaround for deletes ending up on EOL, reuse position check logic
			if not (is_undo or is_redo) then mark._redos = {} end
		end
		show(mark)
	end
end

-- debug stuff, delete when done
--[[
local flags = {undo = buffer.PERFORMED_UNDO, redo = buffer.PERFORMED_REDO, before_insert = buffer.MOD_BEFOREINSERT,
	after_insert = buffer.MOD_INSERTTEXT, before_delete = buffer.MOD_BEFOREDELETE, after_delete = buffer.MOD_DELETETEXT,
	container = buffer.MOD_CONTAINER}
local function checkflags(t)
	local s = ''
	for k, v in pairs(flags) do
		if t & v == v then s = s..k..' ' end
	end
	return s
end]]

--- Helper function to make bitwise flag checks shorter.
--  (Because modified events make heavy use of them.)
local function flagf(t)
	return function (f)
		return t & f == f
	end
end

-- events.MODIFIED argument order:
-- [2008]={"modified","position","modification_type","text","length","lines_added",
--  "line","fold_level_now","fold_level_prev","token","annotation_lines_added"}
-- this is split because line deletion has to be checked before any text is deleted, whereas marks
-- should be moved to the correct position only after text has been inserted/deleted.
local function handle_modified(pos, type, text, length, lines_added, _, _, _, token, _)
	local t = flagf(type)
	if t(buffer.MOD_BEFOREINSERT) or t(buffer.MOD_BEFOREDELETE) then handle_before(t, pos, length) end
	if t(buffer.MOD_INSERTTEXT) or t(buffer.MOD_DELETETEXT) then handle_after(t, pos, length) end
end

--- Resync a view's marks to its buffer's marks.
-- We have no way of knowing if a view was modified unless it is focused,
-- so after we focus a new view, give it a clean slate to re-sync everything.
local function handle_view_after_switch() ; clear(view.buffer) ; show_all(view.buffer) end

--- Add the marks table to every new buffer.
local function handle_buffer_new()
	if not buffer.marks then buffer.marks = new_marks(buffer) end
end

--- Teardown event handlers and hide mark displays.
function marks.off()
	events.disconnect(events.BUFFER_NEW, handle_buffer_new)
	events.disconnect(events.VIEW_NEW, setup_view)
	events.disconnect(events.VIEW_AFTER_SWITCH, handle_view_after_switch)
	events.disconnect(events.MODIFIED, handle_modified)
	for _, buffer in ipairs(_BUFFERS) do clear(buffer) end
	for _, view in ipairs(_VIEWS) do restore_view(view) end
end

--- Setup event handlers and add marks to existing buffers
function marks.on()
	events.connect(events.BUFFER_NEW, handle_buffer_new)
	events.connect(events.VIEW_NEW, setup_view)
	events.connect(events.VIEW_AFTER_SWITCH, handle_view_after_switch)
	events.connect(events.MODIFIED, handle_modified)
	for _, view in ipairs(_VIEWS) do setup_view(view) end
	for _, buffer in ipairs(_BUFFERS) do
		if not buffer.marks then buffer.marks = new_marks(buffer)
		else for name, mark in pairs(buffer.marks) do
			-- keep existing marks but clear state
			buffer.marks[name] = new_mark(buffer, mark.pos, mark.visible)
		end end
		clear(buffer) ; show_all(buffer)
	end
end

return setmetatable(marks, {
	__index = function (self, index) 
		if index == 'style' then return style
		else return _G.buffer.marks[index] end end,
	__newindex = function (self, index, value) _G.buffer.marks[index] = value end,
})
