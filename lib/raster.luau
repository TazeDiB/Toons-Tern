--!nonstrict
-- The cell canvas: a grid of terminal cells, each holding two pixel rows.
-- Port of the raster half of claude-toons' hooks/script.ts plus the backdrop
-- painting in hooks/effects.ts.
--
-- Cells are indexed `row * cols + col + 1` with `row` and `col` 0-based, as in
-- the original. Each cell keeps a glyph codepoint, a foreground and a
-- background color; CLEAR means the terminal's own color. Half blocks carry
-- the two pixel halves: ▀ shows fg above bg, ▄ below, █ both fg, a space with
-- a background fills both halves with it.

local Color = require('./color')

local CLEAR = Color.CLEAR
local SPACE = 0x20
local UPPER = 0x2580
local LOWER = 0x2584
local FULL = 0x2588
local QUARTER = 0x2596
-- Which half each quarter-block glyph covers: bit 1 the top, bit 2 the bottom.
local QUARTER_HALVES = { 2, 2, 1, 3, 3, 3, 3, 1, 3, 3 }

local ESC = '\27'

local Raster = {}
-- Procedural effects, filled in below; declared early so painting can use it.
local Effects = {}

export type Color = number?
export type Raster = {
	cols: number,
	rows: number,
	glyph: { [number]: number },
	fg: { [number]: number },
	bg: { [number]: number },
	-- Rows the band has risen far enough to show; set by the scene runtime.
	shown: (row: number) -> boolean?,
	-- While scenes dissolve, which cells this pass may touch.
	gate: ((col: number, row: number) -> boolean)?,
}

-- First codepoint of a string, as a number. Hand-rolled so the module runs
-- under any Luau build.
local function codepointOf(s: string): number
	local b1 = string.byte(s, 1) or SPACE
	if b1 < 0x80 then
		return b1
	elseif b1 < 0xE0 then
		return (b1 - 0xC0) * 0x40 + (string.byte(s, 2) or 0x80) - 0x80
	elseif b1 < 0xF0 then
		return (b1 - 0xE0) * 0x1000 + ((string.byte(s, 2) or 0x80) - 0x80) * 0x40 + (string.byte(s, 3) or 0x80) - 0x80
	else
		return (b1 - 0xF0) * 0x40000 + ((string.byte(s, 2) or 0x80) - 0x80) * 0x1000 + ((string.byte(s, 3) or 0x80) - 0x80) * 0x40
			+ (string.byte(s, 4) or 0x80) - 0x80
	end
end

local function charOf(codepoint: number): string
	if codepoint < 0x80 then
		return string.char(codepoint)
	elseif codepoint < 0x800 then
		return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
	elseif codepoint < 0x10000 then
		return string.char(0xE0 + math.floor(codepoint / 0x1000), 0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
	else
		return string.char(
			0xF0 + math.floor(codepoint / 0x40000),
			0x80 + math.floor(codepoint / 0x1000) % 0x40,
			0x80 + math.floor(codepoint / 0x40) % 0x40,
			0x80 + codepoint % 0x40
		)
	end
end

function Raster.new(cols: number, rows: number): Raster
	local count = math.max(1, cols * rows)
	local glyph = table.create(count, SPACE)
	local fg = table.create(count, CLEAR)
	local bg = table.create(count, CLEAR)
	for i = 1, count do
		glyph[i] = SPACE
		fg[i] = CLEAR
		bg[i] = CLEAR
	end

	return { cols = cols, rows = rows, glyph = glyph, fg = fg, bg = bg }
end

local function allowed(r: Raster, col: number, row: number): boolean
	if col < 0 or col >= r.cols or row < 0 or row >= r.rows then
		return false
	end
	if r.shown and not r.shown(row) then
		return false
	end
	if r.gate and not r.gate(col, row) then
		return false
	end

	return true
end

function Raster.put(r: Raster, col: number, row: number, glyph: string, fg: Color, bg: Color)
	if not allowed(r, col, row) then
		return
	end
	local at = math.floor(row) * r.cols + math.floor(col) + 1
	r.glyph[at] = codepointOf(glyph)
	r.fg[at] = if fg == nil or fg == CLEAR then CLEAR else fg
	r.bg[at] = if bg == nil or bg == CLEAR then CLEAR else bg
end

function Raster.putCode(r: Raster, col: number, row: number, codepoint: number, fg: Color, bg: Color)
	if not allowed(r, col, row) then
		return
	end
	local at = math.floor(row) * r.cols + math.floor(col) + 1
	r.glyph[at] = codepoint
	r.fg[at] = if fg == nil or fg == CLEAR then CLEAR else fg
	r.bg[at] = if bg == nil or bg == CLEAR then CLEAR else bg
end

-- One pixel, two to a cell: the cell keeps whatever its other half holds (a
-- backdrop pixel, an earlier pixel) and shows the new one in its half.
function Raster.plot(r: Raster, col: number, py: number, color: Color)
	local row = math.floor(py / 2)
	if not allowed(r, col, row) then
		return
	end
	col = math.floor(col)
	local at = row * r.cols + col + 1
	local ch = r.glyph[at]
	local fg = r.fg[at]
	local bg = r.bg[at]
	local top: number?
	local bottom: number?
	if ch == UPPER then
		top = fg
		bottom = if bg == CLEAR then nil else bg
	elseif ch == LOWER then
		bottom = fg
		top = if bg == CLEAR then nil else bg
	elseif ch == FULL then
		top = fg
		bottom = fg
	elseif ch == SPACE and bg ~= CLEAR then
		top = bg
		bottom = bg
	elseif ch >= QUARTER and ch <= QUARTER + 9 then
		-- A quarter-block edge from the 3D world: each half counts as the
		-- glyph's color where the glyph has anything in it.
		local q = QUARTER_HALVES[ch - QUARTER + 1] or 0
		if bit32.band(q, 1) == 1 then
			top = fg
		end
		if bit32.band(q, 2) == 2 then
			bottom = fg
		end
	end
	if py % 2 == 0 then
		top = color
	else
		bottom = color
	end
	if top ~= nil then
		r.glyph[at] = UPPER
		r.fg[at] = top
		r.bg[at] = bottom or CLEAR
	else
		r.glyph[at] = LOWER
		r.fg[at] = bottom or CLEAR
		r.bg[at] = CLEAR
	end
end

function Raster.clearBox(r: Raster, x0: number, y0: number, x1: number, y1: number)
	for row = math.max(0, math.floor(y0)), math.min(r.rows - 1, math.floor(y1)) do
		for col = math.max(0, math.floor(x0)), math.min(r.cols - 1, math.floor(x1)) do
			if not r.gate or r.gate(col, row) then
				local at = row * r.cols + col + 1
				r.glyph[at] = SPACE
				r.fg[at] = CLEAR
				r.bg[at] = CLEAR
			end
		end
	end
end

local function sgr(parts: { string }, attr: string, c: number)
	local rr, gg, bb = Color.unpack(c)
	parts[#parts + 1] = ESC .. '[' .. attr .. ';2;' .. tostring(rr) .. ';' .. tostring(gg) .. ';' .. tostring(bb) .. 'm'
end

-- The quarter blocks as the coarser styles see them: top quarters fold to
-- ▀, bottom to ▄, three or more to a solid, diagonals to the top half.
local COLLAPSED = {
	['▘'] = '▀',
	['▝'] = '▀',
	['▖'] = '▄',
	['▗'] = '▄',
	['▞'] = '▀',
	['▚'] = '▀',
	['▛'] = '█',
	['▜'] = '█',
	['▙'] = '█',
	['▟'] = '█',
}

-- The frame as escape sequences: one line per cell row, colors only where
-- they change, reset at the end of each row. `style` is 'pixel' (everything),
-- 'color' (no quarter blocks) or 'ascii' (no color, no quarter blocks).
function Raster.encode(r: Raster, style: string?): string
	local parts = {}
	local isAscii = style == 'ascii'
	local coarse = isAscii or style == 'color'
	for row = 0, r.rows - 1 do
		local prevFg = CLEAR
		local prevBg = CLEAR
		for col = 0, r.cols - 1 do
			local at = row * r.cols + col + 1
			local fg = r.fg[at]
			local bg = r.bg[at]
			if not isAscii and (fg ~= prevFg or bg ~= prevBg) then
				parts[#parts + 1] = ESC .. '[m'
				if fg ~= CLEAR then
					sgr(parts, '38', fg)
				end
				if bg ~= CLEAR then
					sgr(parts, '48', bg)
				end
				prevFg = fg
				prevBg = bg
			end
			local glyph = charOf(r.glyph[at])
			if coarse then
				glyph = COLLAPSED[glyph] or glyph
			end
			parts[#parts + 1] = glyph
		end
		parts[#parts + 1] = ESC .. '[m\n'
	end

	return table.concat(parts)
end

-- The ambient layer behind a scene: one effect, faint and see-through,
-- thinning toward the band's edges and its rising front.
function Raster.paintEffect(
	r: Raster,
	t: number,
	background: any,
	previous: any,
	fade: number,
	reveal: number,
	strength: number
)
	if not background then
		return
	end
	local cols = r.cols
	local rows = r.rows
	local h = rows * 2
	local stops = {}
	for i, c in ipairs(background.palette) do
		stops[i] = Color.parse(c)
	end
	local oldStops = stops
	if previous then
		oldStops = {}
		for i, c in ipairs(previous.palette) do
			oldStops[i] = Color.parse(c)
		end
	end
	local function pixel(x: number, y: number): (number, number)
		local v = Effects.field(background.effect, x, y, t * background.speed, cols, h)
		local c = Color.shade(stops, 0.15 + 0.85 * v)
		local a = Color.smooth(0.2, 0.75, v) * (0.55 + 0.45 * background.intensity)
		if previous and fade < 1 then
			local pv = Effects.field(previous.effect, x, y, t * previous.speed, cols, h)
			c = Color.mix(Color.shade(oldStops, 0.15 + 0.85 * pv), c, fade)
			a = a * fade + Color.smooth(0.2, 0.75, pv) * (0.55 + 0.45 * previous.intensity) * (1 - fade)
		end
		local edge = Color.smooth(0, cols * 0.14, math.min(x, cols - 1 - x)) * Color.smooth(0, 2.5, math.min(y + 0.5, h - 0.5 - y))
		local rise = (h - 1 - y) / math.max(1, h - 1)
		local front = reveal * 1.35 - 0.3 * Color.noise(x * 0.18, t * 1.5)
		a = a * strength * edge * Color.smooth(0, 0.25, front - rise)

		return c, a
	end
	for row = 0, rows - 1 do
		local at = row * cols + 1
		for col = 0, cols - 1 do
			local topC, topA = pixel(col, row * 2)
			local bottomC, bottomA = pixel(col, row * 2 + 1)
			local isTop = topA > Color.bayer(col, row * 2)
			local isBottom = bottomA > Color.bayer(col, row * 2 + 1)
			if isTop or not isBottom then
				r.glyph[at] = if isTop then UPPER else SPACE
				r.fg[at] = if isTop then topC else if isBottom then bottomC else CLEAR
				r.bg[at] = if isTop and isBottom then bottomC else CLEAR
			else
				r.glyph[at] = LOWER
				r.fg[at] = bottomC
				r.bg[at] = CLEAR
			end
			at = at + 1
		end
	end
end

-- Procedural effects: each one a field from a pixel to a value in [0, 1].
-- Port of hooks/effects.ts FIELDS; kept here because it paints into a Raster.

Effects.EFFECTS = {
	'plasma',
	'fire',
	'starfield',
	'rain',
	'tunnel',
	'lava',
	'glitch',
	'aurora',
	'waves',
	'pulse',
	'fireworks',
}

local function polar(x: number, y: number, w: number, h: number): (number, number)
	local dx = (x - w / 2) * 0.5
	local dy = y - h / 2

	return math.sqrt(dx * dx + dy * dy), math.atan2(dy, dx)
end

local FIELDS: { [string]: (number, number, number, number, number) -> number } = {
	plasma = function(x, y, t)
		return (math.sin(x * 0.08 + t) + math.sin(y * 0.3 + t * 1.3) + math.sin((x + y) * 0.05 + t * 0.7) + math.sin(math.sqrt((x * 0.5) * (x * 0.5) + y * y) * 0.2 - t)) / 8
			+ 0.5
	end,
	fire = function(x, y, t, _w, h)
		return Color.clamp(Color.noise(x * 0.15, y * 0.45 + t * 3) * 1.5 * (y / h) ^ 1.3 + Color.noise(x * 0.4, t * 5) * 0.15 * (y / h))
	end,
	starfield = function(x, y, t, w, h)
		local r, a = polar(x, y, w, h)
		local ray = math.floor((a + math.pi) * 24)
		local z = Color.fract(Color.hash(ray, 3) + t * 0.25)
		local reach = math.sqrt((w * 0.25) * (w * 0.25) + (h * 0.5) * (h * 0.5))

		return Color.clamp(math.exp(-math.abs(r - z * reach) * 1.2) * z * 1.6)
	end,
	rain = function(x, y, t, _w, h)
		local head = Color.fract(Color.hash(x, 2) + t * (0.3 + Color.hash(x, 1) * 0.5)) * (h + 12)
		local d = head - y

		return if d >= 0 and d < 10 then 1 - d / 10 else Color.hash(x, math.floor(y + t * 4)) * 0.08
	end,
	tunnel = function(x, y, t, w, h)
		local r, a = polar(x, y, w, h)

		return 0.5 + 0.5 * math.sin(30 / (r + 2) + t * 4) * math.cos(a * 3 + t)
	end,
	lava = function(x, y, t, w, h)
		local sum = 0
		for i = 0, 5 do
			local bx = (0.5 + 0.45 * math.sin(t * (0.3 + i * 0.11) + i * 2.1)) * w
			local by = (0.5 + 0.45 * math.cos(t * (0.4 + i * 0.07) + i * 1.3)) * h
			local dx = (x - bx) * 0.5
			local dy = y - by
			sum += 6 / (math.sqrt(dx * dx + dy * dy) + 0.5)
		end

		return Color.clamp((sum - 2.2) / 2)
	end,
	glitch = function(x, y, t)
		local frame = math.floor(t * 9)
		local shift = if Color.hash(math.floor(y / 2), frame) > 0.75 then math.floor(Color.hash(y, frame) * 24) else 0
		local block = Color.hash(math.floor((x + shift) / 5), math.floor(y / 3) + frame * 7)

		return if block > 0.6 then block else 0.5 + 0.5 * math.sin((x + shift) * 0.1 + t * 2) * 0.4
	end,
	aurora = function(x, y, t, _w, h)
		local center = h * (0.45 + 0.25 * math.sin(x * 0.04 + t * 0.6) + 0.12 * math.sin(x * 0.11 - t * 1.4))
		local band = (y - center) / (2.5 + 3 * Color.noise(x * 0.05, t * 0.5))

		return Color.clamp(math.exp(-band * band) * (0.6 + 0.4 * Color.noise(x * 0.2, t * 2)))
	end,
	waves = function(x, y, t, _w, h)
		local surface = h * (0.5 + 0.3 * math.sin(x * 0.09 - t * 2) * math.sin(x * 0.023 + t * 0.7))

		return if y > surface
			then Color.clamp(0.55 + 0.45 * math.sin(x * 0.2 + y * 0.6 - t * 3))
			else 0.1 * Color.noise(x * 0.1, y * 0.3 + t)
	end,
	pulse = function(x, y, t, w, h)
		local r = polar(x, y, w, h)
		local ring = Color.fract(t * 0.6) * math.sqrt((w * 0.25) * (w * 0.25) + (h * 0.5) * (h * 0.5))

		return Color.clamp(math.exp(-math.abs(r - ring) * 0.6) + 0.15 * math.sin(r * 0.5 - t * 3))
	end,
	fireworks = function(x, y, t, w, h)
		local v = 0
		for k = 0, 3 do
			local cycle = math.floor(t / 1.6 + k * 0.37)
			local age = Color.fract(t / 1.6 + k * 0.37)
			local cx = Color.hash(k, cycle) * w
			local cy = (0.2 + Color.hash(cycle, k) * 0.6) * h
			local dx = (x - cx) * 0.5
			local dy = y - cy
			local r = math.sqrt(dx * dx + dy * dy)
			local sparkle = if Color.hash(math.floor(math.atan2(dy, dx) * 6), cycle) > 0.4 then 1 else 0.3
			v += math.exp(-math.abs(r - age * 14) * 1.3) * (1 - age) * sparkle
		end

		return Color.clamp(v)
	end,
}

function Effects.field(effect: string, x: number, y: number, t: number, w: number, h: number): number
	local f = FIELDS[effect]

	return if f then f(x, y, t, w, h) else 0
end

-- A scene's ambient layer, checked: what the model sent may not be usable.
function Effects.cleanBackground(raw: any): any
	if typeof(raw) ~= 'table' then
		return nil
	end
	local effect = raw.effect
	if typeof(effect) ~= 'string' or not FIELDS[effect] then
		return nil
	end
	local palette = {}
	if typeof(raw.palette) == 'table' then
		for _, c in ipairs(raw.palette) do
			if typeof(c) == 'string' and #palette < 6 and Color.isHex(c) then
				palette[#palette + 1] = c
			end
		end
	end
	if #palette < 2 then
		return nil
	end

	return {
		effect = effect,
		palette = palette,
		speed = Color.clamp(if typeof(raw.speed) == 'number' then raw.speed else 1, 0.1, 4),
		intensity = Color.clamp(if typeof(raw.intensity) == 'number' then raw.intensity else 0.6),
	}
end

Raster.Effects = Effects

return Raster
