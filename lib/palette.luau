--!strict
-- Style and size presets for the toons block.

export type Style = 'ascii' | 'color' | 'pixel'

local styles: { [Style]: { color: boolean, quarter: boolean } } = {
	ascii = { color = false, quarter = false },
	color = { color = true, quarter = false },
	pixel = { color = true, quarter = true },
}

local sizes: { [string]: { cols: number, rows: number } } = {
	small = { cols = 40, rows = 10 },
	medium = { cols = 64, rows = 16 },
	large = { cols = 80, rows = 20 },
}

local function styleOf(name: any): Style
	if name == 'ascii' or name == 'pixel' then
		return name
	end
	return 'color'
end

local function sizeOf(name: any): { cols: number, rows: number }
	local s = sizes[tostring(name)]
	if s then
		return s
	end
	return sizes.medium
end

return {
	styles = styles,
	sizes = sizes,
	styleOf = styleOf,
	sizeOf = sizeOf,
}
