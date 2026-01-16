-- Copyright (c) 2025 Fwirt. See LICENSE.

-- Make sequences of functions executable.

FuncTable = {}

local function ft_call(self, ...)
	local rt = {}
	local r
	for _, v in ipairs(self) do
		if type(v) == 'function' then r = {v(...)}
		else r = {v} end
		for _, v in ipairs(r) do
			rt[#rt+1] = v -- this isn't working for some reason
		end
	end
	return table.unpack(rt)
end

local ft_meta = {
	__call = ft_call,
	__tostring = function (self) table.concat(ft_call(self), '') end,
}

function FuncTable.new(t)
	local ft
	if type(t) == 'function' then
		ft = {t}
	elseif type(t) == 'table' then
		ft = t
	elseif t then
		ft = {function () return t end}
	else
		ft = {}
	end
	return setmetatable(ft, ft_meta)
end

return setmetatable(FuncTable, {
	__call = function (self, ...) return FuncTable.new(...) end,
})
