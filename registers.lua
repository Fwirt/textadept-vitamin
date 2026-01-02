-- Copyright (c) 2025 Fwirt. See LICENSE.

--- Get the line ending of the current buffer for registers.
local function get_eol(buffer)
	local view = buffer or view
	local mode = view.eol_mode
	if mode == view.EOL_LF then
		return '\n'
	elseif mode == view.EOL_CRLF then
		return '\r\n'
	elseif mode == view.EOL_CR then
		return '\r'
	else
		return ''
	end
end

--- Simple way to tell if latin character is upper.
--  @param char Character to check.
--  TODO: Unicode support for uppercase mappings.
local function is_upper(char)
	local byte = string.byte(char) or 0
	return byte <= 90 and byte >= 65
end

--- Simple lowercase function for single char strings.
--  Does not do any bounds checking so make sure to only
--  call this on a verified uppercase char!
--  @param char Character to lowercase.
local function lower(char)
	return string.byte(char) - 32
end

--- Simple way to tell if character is arabic digit.
--  @param char Character to check.
local function is_digit(char)
	local byte = type(char) == 'string' and string.byte(char) or 0
	if (byte >= 48 and byte <= 57) 
		then return true end
	return false
end

--- Simple way to get numeric value of single digit.
--  Make sure to only call this on a verified digit!
local function value_of(char)
	return string.byte(char) - 48
end

local contents

--- Return a register object that points at a single register.
--  The registers module will return a table that maintains the value of
--  a single string when indexed. This table's methods ensure that the
--  register behaves according to vi standards and is portable across line
--  endings. This function also handles special register behavior.
--  @param name Register name (needed to alias uppercase registers)
local function new(name)
	local name = name
	-- For uppercase registers, just a simple wrapper object that references the
	-- lowercase register and appends on text assignment.
	if is_upper(name) then
		local reg = contents[lower(name)]
		return setmetatable({}, {
			__index = function(self, index)
				if index == 'name' then return name end
				return reg[index]
			end,
			__newindex = function(self, index, value)
				if index == 'text' then reg.text = (reg.mode == 'line' and reg.eol or '') .. value
				else reg[index] = value
				end
			end
		})
	end
	local text, eol = '', ''
	-- For numeric registers, a wrapper that will insert the contents into the queue.
	-- Assigning to these registers is unspecified behavior, so we treat it as insertion.
	-- References string registers to underlying numerically indexed registers.
	if is_digit(name) then
		local numeric = value_of(name)
		return setmetatable({}, {
			__index = function(self, index)
				if index == 'name' then return name end
				return contents[numeric][index] end,
			__newindex = function(self, index, value)
				local numeric = value_of(value)
				if index == 'text' then
					for i = 8, numeric, -1 do
						local next, current = i + 1, i
						contents[next].text = contents[current].text
						contents[next].eol = contents[current].eol
						contents[next].mode = contents[current].mode
					end
				else reg[index] = value
				end
			end,
		})
	end
	-- For everything else return a normal register object
	return setmetatable({}, {
		__index = function (self, index)
			if index == 'text' then -- return text with the current view's line endings
				local buffer_eol = get_eol()
				if eol ~= buffer_eol then
					text = string.gsub(text, eol, buffer_eol)
					eol = buffer_eol
				end
				return (self.mode == 'line' and eol or '') .. text
			elseif index == 'eol' then return eol
			elseif index == 'name' then return name
			else return rawget(self, index)
			end
		end,
		__newindex = function (self, index, value)
			if index == 'text' then
				local buffer_eol = get_eol()
				eol = buffer_eol
				-- Prevent extra newlines
				if string.sub(value, -1*#eol, -1) == eol then
					text = string.sub(value, 1, -1*#eol-1)
				else
					text = value
				end
			elseif index == 'eol' then
				text = string.gsub(text, eol, value)
				eol = value
			elseif index == 'name' then
				error('name is read-only', 2)
			else
				rawset(self, index, value)
			end
		end,
		__tostring = function (self) return self.text end,
		__call = function (self) return self.text, self.mode end,
	})
end

--- Holds the vi registers (buffers).
--  Indexed on register name (In this implementation, any single printable
--  character is a valid register name.) Each register is a sequence of lines
--  and a `mode` element. The lines will be concatenated with the EOL characters
--  of the current view upon retrieval, and an extra newline will be appended
--  if the register is in "line" mode.
contents = setmetatable({}, {
	__index = function (self, index)
		rawset(self, index, new(index)) -- accessing an empty register creates it
		return self[index]
	end,
	__newindex = function (self, index, value) -- setting a register just sets its text
		self[index].text = value
	end
})

-- Setup underlying numeric registers.
-- Vitamin only uses 1-9 but we create 0 as well.
for i = 0, 9 do
	contents[i] = ''
end

--- Module metatable, prevents user from corrupting internal state.
--  Prevents modifying numeric registers directly.
--  Note that this means any value is a valid register key, even though Vitamin
--  will only use single printable characters.
registers = setmetatable({}, {
	__index = function (self, index) return contents[tostring(index)] end,
	__newindex = function (self, index, value) contents[tostring(index)].text = value end,
})

return registers
