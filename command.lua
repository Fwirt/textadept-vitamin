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

registers = require('vitamin.registers')
FuncTable = require('vitamin.functable')

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
--  Called if `command.before` is not defined. Should be called from
--  any `before` function that does not return a value by default.
Command.default_before = function (command)
	return command.arg
end

--- Default prompt value for anonymous commands.
--  Used in the object metatable.
Command.default_prompt = "Vitamin: "

--- Save the `view.current_pos` to `command.pos`.
--  Use in `command.before` of subcommand to save `view.current_pos` to
--  `command.pos`, then use `Command.load_pos` in `command.after` of parent
--  command to prevent cursor from moving.
Command.save_pos = function (command)
	command.pos = view.current_pos
	return Command.default_before(command)
end

--- Load the previous pos from the subcommand.
--  Use in `command.before` of parent to restore position after selection is processed.
--  Calls existing `command.after` before restoring position.
Command.restore_pos_after = function (command)
	local after_pos = command.sub and command.sub.pos or view.current_pos
	local current_after = command.after
	command.after = function (...)
		if current_after then current_after(...) end
		view:goto_pos(after_pos)
	end
	return Command.default_before(command)
end

--- Shorthand to allow use of existing movement commands to extend selection
Command.extend = function (command)
	local after_extend = view.move_extends_selection
	local current_after = command.after
	view.move_extends_selection = true
	command.after = function (...)
		if current_after then current_after(...) end
		view.move_extends_selection = after_extend
	end
	return Command.default_before(command)
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
		-- re-initialize public command fields
		command.before = nil -- prevent circular calls
		for key, field in pairs(command) do command[key] = nil end
		-- write in new definition
		for key, field in pairs(command.def) do command[key] = field end
		command.def = {}
		-- pretend we just copied the first def, we may need to process an arg
		if not command.needs then return command.before(command) end
	end
end

--- Returns the command register contents as text to be used by view methods.
--  To be assigned to `command.before`. Also returns `reg.mode` for use by p.
Command.get_reg = function (command)
	return command.reg()
end

--- Multiply the count by the count of the parent command.
--  For subcommands (motions) the total motion should be multiplied by the
--  parent's `command.count`. Then sets parent count to 1 since it shouldn't
--  be used by the parent command.
Command.parent_times = function (command)
	command.count = (command.count or 1) * (command.parent and command.parent.count or 1)
	if command.parent then command.parent.count = 1 end
end

local function split_lines(text)
	local result = {}
	for line in string.gmatch(text, get_eol()) do
		table.insert(result, line)
	end
	return result
end

local function ensure_string(s) return type(s) == 'string' and s or '' end

--- Invoke the command object.
--  See the command object definition for how the command elements affect
--  its invocation. 
--  @param subcommand The subcommand argument should be provided if this
--  command is being recursively invoked from the child, so that the parent command can
--  examine the subcommand object's fields to determine what action was performed.
local function call(command, subcommand)
	-- insert and override values from definition
	-- do before `before` so `before` can override
	for key, field in pairs(command.def) do command[key] = field end
	command.def = {} -- clear so we don't overwrite subsequent calls
	if command.sub then -- if a command definition contains a subcommand
		command.sub.parent = command
		command.sub.reg = command.reg
		subcommand = command.sub() -- invoke it first
		if command.sub.needs then return command.sub end -- and then switch to it if needed
	end
	if command.needs then return command end
	-- prevent circular references for gc and make subcommand available for `command.before`
	if subcommand then command.sub = subcommand ; subcommand.parent = nil end
	-- execute "before" function(s).
	local args = {view, FuncTable(command.before)(command)}
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
	-- execute "after" function(s)
	local r = {FuncTable(command.after)(args)}
	for _, s in ipairs(r) do results = results .. ensure_string(s) end
	-- set the register(s) to the command results, if any
	if #results > 0 then
		command.reg.text = results
		registers[''].text = results -- always set the unnamed register
	end
	command.needs = nil
	return command.parent and command.parent(command) or command
end

--- Command object constructor.
--  @param def A table containing either a mapping of keycodes to definition tables,
--  or the definition of an anonymous command.
function Command.new(def)
	local def = def or Command.commands
	if type(def) ~= 'table' then error('argument must be a table', 2) end
	
	local register = registers['']
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
			elseif index == 'before' then return Command.default_before
			elseif index == 'prompt' then return keycode or Command.default_prompt
			elseif index then return rawget(self, index)
			end
		end,
		__newindex = function (self, index, value)
			if index == 'status' then
				status = value
				Command.output(tostring(status))
			elseif index == 'def' then
				if type(value) ~= 'table' then error('command.def must be a table', 2) end
				def = value
			elseif index == 'keycode' then
				if not def[value] then error('undefined command "'..tostring(value)..'"', 0)
				else keycode = value ; def = def[value] end
			elseif index == 'reg' then
				if type(value) == 'table' then
					if value.name then
						register = registers[value.name]
					end
					for i, v in pairs(value) do
						register[i] = v
						registers[''][i] = v
					end
				else register = registers[value] end
			elseif index then
				return rawset(self, index, value)
			end
		end
	})
	return command
end

return setmetatable(Command, {
	__call = function (self, ...) return Command.new(...) end,
})
