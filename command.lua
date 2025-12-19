-- Copyright (c) 2025 Fwirt. See LICENSE.

-- Command class for vitamin

M = {}

-- register implementation:

-- Just a table keyed on character.
-- If the field is a string it's a "character mode" register
-- If the field is a table it's a "line mode" register
M.registers = {}

-- Command definition list
M.definitions = {}

-- List of previous commands that have been run for repetition
M.history = {}

local function is_upper(char)
	local byte = string.byte(char or '')
	return byte <= 90 and byte >= 65
end

--- Return the text of a register and the register 'mode'
local function reg_text(self, reg)
	local key = reg or type(self) == 'table' and self.reg or self
	local val = M.registers[key]
	if type(val) == 'table' then
		return table.concat(val, '\n'), 'line'
	else
		return tostring(val), 'char'
	end
end

local function ensure_string(s) return type(s) == 'string' and s or '' end

local function call(self)
	-- Record command before any changes are made by def or func
	-- need to do a deep copy here tho.
	-- M.history[#M.history+1] = self
	local def = self.def or {}
	local count = type(self.count) == number and self.count or 1
	local args = {view}
	local results = ''
	-- override values with definition (for aliases)
	for key, field in def do
		if self[key] then self[key] = field end
	end
	-- load arguments for functions
	if type(def.func) == 'function' then
		args = {view, def.func(self)}
	else
		args = {view, self.arg}
	end
	-- commands that take a motion select an area and then
	-- execute the functions on the selection
	if self.motion then self:motion() end
	-- execute function list
	if #def > 0 then
		for i = 1, #def - 1 do
			results = results .. ensure_string(def[i](table.unpack(args)))
		end
		-- repeat last function "count" times
		for i = 1, count do
			results = results .. ensure_string(def[#func](table.unpack(args)))
		end
	end
	-- execute "after" function
	if type(func.after) == 'function' then
		results = results .. ensure_string(func.after(table.unpack(args)))
	end
	if #results > 0 then 
		M.registers[''] = results
		if self.reg then
			if is_upper(self.reg) then -- append if register is uppercase
				local current, mode = reg_text(self)
			end
		end
		if self.reg then M.registers[self.register] = results end
	end
end

command_meta = {
	__call = function (self)
		call(self)
	end,
	__index = function (self, index)
		if index == 'definitions' then
			return M.definitions
		elseif index == 'registers' then
			return M.registers
		else
			return rawget(self, index)
		end
	end
	
}

-- constructor
function M.new()
	local command = {
		reg = '', -- register to store results
		count = 1, -- repetitions of the command
		def = {}, -- command definition (see M.commands)
		arg = '', -- a mark, char, or buffer
		motion = {}, -- callable that extends the selection
		input_text = {}, -- the text that was entered in input mode
		output = '', -- text to output for this command
	}
	command.reg_text = reg_text
	setmetatable(command, command_meta)
	return command
end

mod_meta = {
	__call = M.new,
}

return M
