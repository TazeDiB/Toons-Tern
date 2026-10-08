--!nonstrict
-- Colors and the small math the effects need. Port of the color half of
-- claude-toons' hooks/effects.ts.
--
-- A Color is a packed 0xRRGGBB number, or CLEAR for "the terminal's own
-- color" (what shows through wherever nothing is drawn).

local CLEAR = -1

local BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }
for i = 1, 16 do
	BAYER[i] = (BAYER[i] + 0.5) / 16
end

export type Color = number

local Color = {}

Color.CLEAR = CLEAR

function Color.clamp(v: number, lo: number?, hi: number?): number
	return math.min(hi or 1, math.max(lo or 0, v))
end

function Color.fract(v: number): number
	return v - math.floor(v)
end

function Color.mod(a: number, b: number): number
	if b == 0 then
		return 0
	end
	return ((a % b) + b) % b
end

function Color.hash(x: number, y: number): number
	return Color.fract(math.sin(x * 12.9898 + y * 78.233) * 43758.5453)
end

-- Smooth wandering value in [0, 1) over a 2D lattice.
function Color.noise(x: number, y: number): number
	local ix = math.floor(x)
	local iy = math.floor(y)
	local fx = x - ix
	local fy = y - iy
	local sx = fx * fx * (3 - 2 * fx)
	local sy = fy * fy * (3 - 2 * fy)
	local a = Color.hash(ix, iy)
	local b = Color.hash(ix + 1, iy)
	local c = Color.hash(ix, iy + 1)
	local d = Color.hash(ix + 1, iy + 1)

	return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
end

function Color.smooth(lo: number, hi: number, v: number): number
	local k = Color.clamp((v - lo) / (hi - lo))

	return k * k * (3 - 2 * k)
end

function Color.bayer(x: number, y: number): number
	return BAYER[bit32.band(math.floor(y), 3) * 4 + bit32.band(math.floor(x), 3) + 1] or 0.5
end

-- '#ff0000' | 'ff0000' | 'f00' | any other string -> 128,128,128.
function Color.parse(hex: string?): Color
	if typeof(hex) ~= 'string' then
		return 0x808080
	end
	local s = string.gsub(hex, '^%s+', '')
	s = string.gsub(s, '%s+$', '')
	s = string.gsub(s, '^#', '')
	if #s == 3 then
		s = string.format('%s%s%s%s%s%s', s:sub(1, 1), s:sub(1, 1), s:sub(2, 2), s:sub(2, 2), s:sub(3, 3), s:sub(3, 3))
	end
	if #s ~= 6 or not string.match(string.lower(s), '^[0-9a-f]+$') then
		return 0x808080
	end

	return tonumber(s:sub(1, 2), 16) * 65536 + tonumber(s:sub(3, 4), 16) * 256 + tonumber(s:sub(5, 6), 16)
end

function Color.pack(r: number, g: number, b: number): Color
	r = math.floor(Color.clamp(math.round(r), 0, 255) + 0.5)
	g = math.floor(Color.clamp(math.round(g), 0, 255) + 0.5)
	b = math.floor(Color.clamp(math.round(b), 0, 255) + 0.5)

	return r * 65536 + g * 256 + b
end

function Color.unpack(c: Color?): (number, number, number)
	if c == nil or c == CLEAR then
		return 0, 0, 0
	end
	local v = math.floor(c)

	return math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
end

-- Linear blend between two colors; k 0 keeps a, 1 keeps b.
function Color.mix(a: Color?, b: Color?, k: number): Color
	local ar, ag, ab = Color.unpack(a)
	local br, bg, bb = Color.unpack(b)

	return Color.pack(ar + (br - ar) * k, ag + (bg - ag) * k, ab + (bb - ab) * k)
end

function Color.dim(c: Color?, k: number): Color
	local r, g, b = Color.unpack(c)

	return Color.pack(r * k, g * k, b * k)
end

-- A palette ramp: stops is a list of colors, v picks along it.
function Color.shade(stops: { Color }, v: number): Color
	local n = #stops
	if n == 0 then
		return 0x000000
	end
	local p = Color.clamp(v) * (n - 1)
	local i = math.min(n - 1, math.floor(p) + 1)
	local a = stops[i] or 0
	local b = stops[math.min(n, i + 1)] or a

	return Color.mix(a, b, p - (i - 1))
end

-- Hue in degrees, saturation and lightness 0 to 1.
function Color.hsl(hue: number, sat: number, light: number): Color
	local hh = (((hue % 360) + 360) % 360) / 60
	local ss = Color.clamp(sat)
	local ll = Color.clamp(light)
	local c = (1 - math.abs(2 * ll - 1)) * ss
	local x = c * (1 - math.abs((hh % 2) - 1))
	local m = ll - c / 2
	local r, g, b
	if hh < 1 then
		r, g, b = c, x, 0
	elseif hh < 2 then
		r, g, b = x, c, 0
	elseif hh < 3 then
		r, g, b = 0, c, x
	elseif hh < 4 then
		r, g, b = 0, x, c
	elseif hh < 5 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end

	return Color.pack((r + m) * 255, (g + m) * 255, (b + m) * 255)
end

-- A color the scene code may name: '#f00', '#ff0000', 'ff0000', 'f00'.
function Color.isHex(s: string?): boolean
	if typeof(s) ~= 'string' then
		return false
	end
	local t = string.gsub(s, '^%s+', '')
	t = string.gsub(t, '%s+$', '')
	t = string.gsub(t, '^#', '')
	if #t ~= 3 and #t ~= 6 then
		return false
	end

	return string.match(string.lower(t), '^[0-9a-f]+$') ~= nil
end

-- Text the canvas can draw: printable, single-width, one line, at most `most`.
function Color.cleanText(text: string?, most: number): string
	if typeof(text) ~= 'string' then
		return ''
	end
	local out = text
	out = string.gsub(out, '\226\128\152', "'") -- ‘ ’
	out = string.gsub(out, '\226\128\153', "'")
	out = string.gsub(out, '\226\128\156', '"') -- “ ”
	out = string.gsub(out, '\226\128\157', '"')
	out = string.gsub(out, '\226\128\147', '-') -- – —
	out = string.gsub(out, '\226\128\148', '-')
	out = string.gsub(out, '\226\128\166', '...') -- …
	-- Drop everything outside printable ASCII.
	out = string.gsub(out, '[\1-\31\127\128-\255]', '')
	out = string.gsub(out, '%s+', ' ')
	out = string.gsub(out, '^ ', '')
	out = string.gsub(out, ' $', '')
	if #out > most then
		out = string.sub(out, 1, most)
	end

	return out
end

return Color
