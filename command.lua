-- Copyright (c) 2025 Fwirt. See LICENSE.

-- Command class for vitamin

Command = {}

--- A command object describes a vi command. A vi command is composed of
-- an optional read/write register, an optional count, the command keycode,
-- and any additional arguments that the command requires, such as a character
-- specifying a mark, printable character, or subcommand
-- (commonly a motion, or subcommand that specifies a range to operate on).
-- A command's fields should be filled with the values needed to describe the
-- operation of the command, and then its `call()` method should be invoked.
-- This can also be accomplished by calling the command object as a function.
-- @field keycode The keycode of the command. If `command.keycode` is an index in
-- `command.def` when the function is called, `command.def` will be replaced with
-- `command.def[command.keycode] before `command.def` is loaded. If it is not in
-- `command.def`, but `command.def.lookup ~= nil`, then throw an error for an
-- unhandled key.
-- @field def The command definition table. All values from this table
-- are loaded into elements in the command object at the time the
-- command is called, and override any existing values. The value of this field
-- is then set to `{}` to prevent mutation on subsequent calls.
-- @field before The argument preparation function. Takes the command object
-- as its only argument. This function is called after the definition
-- table is loaded and can mutate the command object elements as needed.
-- The results of this function are passed to all the numeric elements
-- of the command object after `view`. The default value of func returns `command.arg`.
-- @field needs The parameter collection function. This field is checked for a
-- function value after `command.def` is loaded and after `command.before` is called.
-- If a value is found, the command immediately returns itself. This value
-- should contain a function that when called, will collect additional parameters from
-- the user (such as `command.sub` or `command.arg`), mutate the command as needed,
-- set its needs field to `nil`, and then call the returned command again.
-- @parent The parent command. This element should be set on subcommands. The parent
-- command object will be recursively invoked after this command object has finished
-- execution, and the subcommand provided as an argument.
-- @field 1..#command The numeric elements of command should form a sequence
-- of functions that take view as the first parameter, and any number of arguments
-- as the second parameter. The functions are called in ascending order, and the
-- final function [#command] is called `command.count` times. If the return values
-- of a function is type `string`, its value is concatenated with other string values,
-- and the result is stored in `command.reg`.
-- @field after A function that is called once after `command[#command]`. Its
-- is passed the same arguments as the numeric element functions.
-- @field parent 
-- @field reg The register object that this command should write/read.
-- @field count The number of times to execute `command[#command]`. If not specified
-- then `command.count` is assumed to be 1.
-- @field arg Optional argument required by some commands.
-- @field text Text entered in input mode or returned from a prompt.
-- @field status Output to display in the statusbar. When this field is assigned,
-- `Command.output` is called with its new value.
-- @table command

--- Holds the vi registers (buffers).
--  Indexed on register name (In this implementation, any single printable
--  character is a valid register name.)
--  If an element is a table it is in line mode, otherwise it is converted
--  to a string and is in char mode. This allows registers to be portable
--  across buffers with different line endings.
Command.registers = {}

--- Definitions that map a keycode to a sequence of functions to be executed.
-- Each element in this table is indexed on a keycode and contains a table of Command
-- properties to be set when the Command is identified.
Command.commands = {}

--- Subcommand definitions that select text before the definition of the command executes.
-- The format of a motion definition is the same as the format of a command definition.
Command.motions = {}

--- Output the status of a command.
--  By default this function outputs to the statusbar, override it to output
--  to a location of your choice. This function will be called whenever
--  command.status is assigned.
--  @param text The text to output to the desired location.
Command.output = function (text)
	ui.statusbar_text = text
end

--- Default value of `command.before`.
--  Defined here to be used by `Command.multikey`. Also used in the
--  object constructor.
local function default_before(command)
	return command.arg
end

--- Allows the command and motion tables to contain longer keycodes.
--  Append the arg to the keycode which will update the command def.
--  Then re-run the command field replacement. Since this gets called
--  from `command.before` then return the new value of command.before if
--  needed, or exit early so new needs can be handled.
Command.multikey = function (newdef)
	return function(command)
		if not command.arg then error('command "'..command.keycode..'" requires a second key', 0) end
		command.def = newdef
		command.keycode = command.keycode .. command.arg
		-- re-initialize command (except for special fields)
		for key, field in pairs(command) do command[key] = nil end
		command.before = default_before
		command.text = ''
		-- write in new definition
		for key, field in pairs(command.def) do command[key] = field end
		command.def = {}
		-- pretend we just ran the first def, we may need to process an arg
		if not command.needs then return command.before(command) end
	end
end

local function is_upper(char)
	local byte = string.byte(char or '')
	return byte <= 90 and byte >= 65
end

local function get_eol_chars(text)
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

local function split_lines(text)
	local result = {}
	for line in string.gmatch(text, "([^\r\n]*)") do
		table.insert(result, line)
	end
	return result
end

local function ensure_string(s) return type(s) == 'string' and s or '' end

--- Invoke the command object.
--  See the command object definition for how the command elements affect
--  its invocation. The subcommand argument should be provided if this
--  command is being recursively invoked, so that the parent command can
--  examine the subcommand object's fields to determine what action was
--  performed.
local function call(command, subcommand)
	-- insert and override values from definition
	-- do before `before` so `before` can override
	for key, field in pairs(command.def) do command[key] = field end
	command.def = {}
	if command.needs then return command end
	-- load arguments for functions and mutate command
	local args = {view, command.before(command)}
	if command.needs then return command end
	-- check count after func so func can check for nil and set 0
	command.count = type(command.count) == 'number' and command.count or 1
	-- execute function list
	local results = ''
	if #command > 0 then
		for i = 1, #command - 1 do
			results = results .. ensure_string(command[i](table.unpack(args)))
		end
		-- repeat last function "count" times
		for i = 1, command.count do
			results = results .. ensure_string(command[#command](table.unpack(args)))
		end
	end
	-- execute "after" function
	if type(command.after) == 'function' then
		results = results .. ensure_string(command.after(table.unpack(args)))
	end
	-- set the register(s) to the command results, if any
	if #results > 0 then 
		Command.registers[''] = results -- set the default register
		if command.reg then
			if is_upper(command.reg.key) then -- append if register is uppercase
				if command.reg.mode == 'line' then
					for _, v in split_lines(results) do table.insert(register.text, v) end
				else
					register.text = register.text .. results
				end
			else
				register.text = results
			end
		end
	end
	command.needs = nil
	return command.parent and command.parent(command) or command
end

local reg_meta = {
	__index = function (self, index)
		if index == 'key' then return rawget(self, 'key') or '' end
		local reg = Command.registers[self.key]
		if index == 'text' then
			return reg
		elseif index == 'mode' then
			return type(reg) == 'table' and 'line' or 'char'
		else
			return rawget(self, index)
		end
	end,
	__newindex = function (self, index, value)
		if index == 'key' then rawset(self, index, value) ; return end
		local reg = Command.registers[self.key]
		if index == 'mode' and value == 'line' and self.mode == 'char' then
			Command.registers[self.key] = split_lines(reg)
		elseif index == 'mode' and value == 'char' and self.mode == 'line' then
			Command.registers[self.key] = table.concat(reg, ' ')
		elseif index == 'text' then
			Command.registers[self.key] = value
		else
			rawset(self, index, value)
		end
	end,
	__tostring = function (self) return self.key end,
}

--- Command object constructor.
--  @param def A table containing either a mapping of keycodes to definition tables,
--  or the definition of an anonymous command.
function Command.new(def)
	local def = def or Command.commands
	if type(def) ~= 'table' then error('argument must be a table', 2) end
	
	local register = setmetatable({}, reg_meta)
	-- Prevent parent definition table from being modified
	local def_meta = {
		__index = function (self, index)
			return def[index]
		end,
		__newindex = function () error('def fields are read-only', 2) end,
		__pairs = function (t) return pairs(def) end,
	}
	local shadow_def = setmetatable({}, def_meta)
	local status = ''
	local keycode = nil
	
	local command = setmetatable({}, {
		__call = function (self, ...)
			return call(self, ...)
		end,
		__index = function (self, index)
			if index == 'status' then return status
			elseif index == 'keycode' then return keycode
			elseif index == 'def' then return shadow_def
			elseif index == 'reg' then return register
			elseif index then return rawget(self, index)
			end
		end,
		__newindex = function (self, index, value)
			if index == 'reg' then
				register.key = tostring(value)
			elseif index == 'status' then
				status = value
				Command.output(tostring(status))
			elseif index == 'def' then
				if type(value) ~= 'table' then error('command.def must be a table', 2) end
				def = value
			elseif index == 'keycode' then
				if not def[value] then error('undefined command "'..tostring(value)..'"', 0)
				else keycode = value ; def = def[value] end
			elseif index then
				return rawset(self, index, value)
			end
		end
	})
	command.before = default_before
	command.text = ''
	return command
end

return setmetatable(Command, {
	__call = function (self, ...) return Command.new(...) end,
})
