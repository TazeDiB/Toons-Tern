--!strict
-- The scene runtime: what a scene's code draws through, and how a frame of a
-- script gets composited into terminal cells. Port of claude-toons'
-- hooks/script.ts.
--
-- A script is a backdrop, sprite actors, particle swarms, and a program with
-- a frame(t, dt) function that draws on the strip every frame. The strip is
-- `rows` cells tall; pixels are two to a cell.

local Color = require('./color')
local Raster = require('./raster')
local Clawd = require('./clawd')
local Render3d = require('./render3d')
local Engine = require('./engine')

local CLEAR = Color.CLEAR
local Effects = Raster.Effects

local function fract(v: number): number
	return v - math.floor(v)
end

local function mod(a: number, b: number): number
	if b == 0 then
		return 0
	end

	return ((a % b) + b) % b
end

local FUNCTIONS = {
	sin = math.sin,
	cos = math.cos,
	tan = math.tan,
	abs = math.abs,
	min = function(...)
		return math.min(...)
	end,
	max = function(...)
		return math.max(...)
	end,
	floor = math.floor,
	ceil = math.ceil,
	round = math.round,
	sqrt = function(v)
		return math.sqrt(math.max(0, v))
	end,
	pow = math.pow,
	exp = math.exp,
	sign = math.sign,
	mod = mod,
	fract = fract,
	clamp = function(v: number, lo: number?, hi: number?)
		return math.min(hi or 1, math.max(lo or 0, v))
	end,
	lerp = function(a: number, b: number, k: number): number
		return a + (b - a) * k
	end,
	-- 0 up to 1 and back down over each unit of x.
	tri = function(v: number): number
		return 1 - math.abs(2 * fract(v) - 1)
	end,
	-- A steady pseudo-random number in [0, 1) for each x.
	rand = function(v: number): number
		return Color.hash(v, 17)
	end,
	step = function(edge: number, v: number): number
		return if v >= edge then 1 else 0
	end,
	-- 1 while lo <= v < hi.
	between = function(v: number, lo: number, hi: number): number
		return if v >= lo and v < hi then 1 else 0
	end,
	-- 0 below a, 1 above b, eased in between.
	smoothstep = function(a: number, b: number, v: number): number
		local k = Color.clamp(if b == a then (if v >= b then 1 else 0) else (v - a) / (b - a))

		return k * k * (3 - 2 * k)
	end,
	atan2 = math.atan2,
	hypot = function(...: number): number
		local total = 0
		for _, v in { ... } do
			total += v * v
		end
		return math.sqrt(total)
	end,
	-- Smooth wandering noise in [0, 1) along x.
	noise = function(v)
		local i = math.floor(v)
		local k = fract(v)

		return Color.hash(i, 17) + (Color.hash(i + 1, 17) - Color.hash(i, 17)) * k * k * (3 - 2 * k)
	end,
}

-- The helpers scene code's arguments pass through, then the frame runner.

local BUBBLE_MS = 32
local SETUP_FUEL = 1_000_000
local SETUP_MS = 500
local FRAME_FUEL = 150_000
local FRAME_MS = 80
local MOST_TRIANGLES = Render3d.MOST_TRIANGLES
local SX, SY = Render3d.SX, Render3d.SY
local CLAWD_W, CLAWD_H = Clawd.CLAWD_W, Clawd.CLAWD_H
local WHITE = Color.pack(255, 255, 255)
local BLACK = Color.pack(0, 0, 0)

-- Whether a codepoint is drawable in a cell.
local function drawable(cp: number): boolean
	if cp >= 0x21 and cp <= 0x7e then
		return true
	end
	if cp >= 0x2500 and cp <= 0x26ff then
		return true
	end
	if cp >= 0x2800 and cp <= 0x28ff then
		return true
	end
	if cp >= 0x2b00 and cp <= 0x2bff then
		return true
	end
	return false
end

-- The characters of a string, one entry per codepoint.
local function chars(s: string): { string }
	local out: { string } = {}
	local i = 1
	while i <= #s do
		local b = string.byte(s, i)
		local n = if b < 0x80 then 1 elseif b < 0xE0 then 2 elseif b < 0xF0 then 3 else 4
		table.insert(out, string.sub(s, i, i + n - 1))
		i += n
	end
	return out
end

local function firstCodepoint(s: string): number?
	local b = string.byte(s, 1)
	if not b then
		return nil
	end
	if b < 0x80 then
		return b
	end
	local n = if b < 0xE0 then 2 elseif b < 0xF0 then 3 else 4
	local cp = if b < 0xE0 then b - 0xC0 elseif b < 0xF0 then b - 0xE0 else b - 0xF0
	for k = 2, n do
		cp = cp * 0x40 + ((string.byte(s, k) or 0x80) - 0x80)
	end
	return cp
end


local function strOf(v: any): string
	if v == nil then
		return ''
	end
	local tv = type(v)
	if tv == 'table' then
		local parts: { string } = {}
		for i = 1, math.min(400, #v) do
			parts[i] = strOf(v[i])
		end
		if #v > 0 then
			return table.concat(parts, ',')
		end
		return '[object Object]'
	elseif tv == 'function' then
		return 'function'
	end
	return tostring(v)
end

local function charOf(v: any): string?
	local s = strOf(v)
	local cp = firstCodepoint(s)
	if not cp then
		return nil
	end
	local one = string.sub(s, 1, #chars(s)[1])
	if one == ' ' or drawable(cp) then
		return one
	end
	return nil
end

local function num(v: any, fallback: number?): number
	if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return fallback or 0
end

local function jsBool(v: any): boolean
	return v ~= nil and v ~= false and v ~= 0 and v ~= ''
end

-- A color from the code: a packed number, or a hex string. Parsed once and
-- remembered, since a fill names the same one for every cell.
local COLORS: { [string]: number } = {}
local colorCount = 0
local function colorOf(v: any, fallback: number?): number
	if type(v) == 'number' and v == v then
		return Color.pack(math.floor(v / 0x10000) % 256, math.floor(v / 0x100) % 256, v % 256)
	end
	if type(v) ~= 'string' then
		return fallback or WHITE
	end
	local cached = COLORS[v]
	if cached then
		return cached
	end
	local parsed = Color.parse(v)
	if parsed == nil then
		return fallback or WHITE
	end
	if colorCount >= 512 then
		COLORS = {}
		colorCount = 0
	end
	COLORS[v] = parsed
	colorCount += 1
	return parsed
end

-- Text the Raster can draw: printable, single-width characters only.
local function cleanText(text: string, most: number): string
	local s = string.gsub(text, '[‘’]', "'")
	s = string.gsub(s, '[“”]', '"')
	s = string.gsub(s, '[–—]', '-')
	s = string.gsub(s, '…', '...')
	s = string.gsub(s, '[^\32-\126]', '')
	s = string.gsub(s, '%s+', ' ')
	s = string.gsub(s, '^%s+', '')
	s = string.gsub(s, '%s+$', '')
	return string.sub(s, 1, most)
end

-- Words wrapped to lines no wider than `width` (in characters).
local function wrap(text: string, width: number): { string }
	local lines: { string } = {}
	local lineParts: { string } = {}
	local lineWidth = 0
	local function flush()
		if #lineParts > 0 then
			table.insert(lines, table.concat(lineParts, ' '))
			lineParts = {}
			lineWidth = 0
		end
	end
	for word in string.gmatch(text, '%S+') do
		local wl = #chars(word)
		local next = lineWidth + 1 + wl
		if next <= width then
			table.insert(lineParts, word)
			lineWidth = next
		else
			flush()
			local rest = word
			while #chars(rest) > width do
				local cs = chars(rest)
				local head = table.concat({ table.unpack(cs, 1, width) })
				table.insert(lines, head)
				rest = table.concat({ table.unpack(cs, width + 1) })
			end
			lineParts = { rest }
			lineWidth = #chars(rest)
		end
	end
	flush()
	return lines
end

-- A bubble's text as typed out so far, and its size.
local function typedBubble(text: string, age: number, cols: number)
	local all = wrap(text, math.max(10, math.min(30, cols - 6)))
	local left = math.floor((age * 1000) / BUBBLE_MS)
	local lines: { string } = {}
	local widest = 0
	for _, line in all do
		local cs = chars(line)
		local take = math.max(0, math.min(#cs, left))
		table.insert(lines, table.concat({ table.unpack(cs, 1, take) }))
		left -= #cs + 1
		widest = math.max(widest, #cs)
	end
	return { lines = lines, wide = widest + 4, tall = #all + 2 }
end

type Box = { x0: number, y0: number, x1: number, y1: number }

-- Where a bubble goes: the clearest spot near its speaker, scored by how
-- many drawn cells it would cover and how far it strays; the last spot
-- keeps its place unless a clearly better one opens. The tail notches the
-- border on the side that faces the speaker.
local function placeBubble(
	speaker: Box,
	wide: number,
	tall: number,
	cols: number,
	rows: number,
	covered: { [number]: number },
	last: { x: number, y: number }?
)
	local bottom = rows - 1
	local cx = (speaker.x0 + speaker.x1 + 1) / 2
	local function cost(x: number, y: number): number
		local blocked = 0
		for row = y, y + tall - 1 do
			for col = x, x + wide - 1 do
				if covered[row * cols + col + 1] then
					blocked += 1
				end
			end
		end
		local gap = if y + tall <= speaker.y0 then speaker.y0 - (y + tall) elseif y > speaker.y1 then y - speaker.y1 - 1 else 0
		local side = if x + wide <= speaker.x0 then speaker.x0 - (x + wide) elseif x > speaker.x1 then x - speaker.x1 - 1 else 0
		return blocked * 10 + math.abs(x + wide / 2 - cx) * 0.08 + gap * 0.6 + side * 0.15
	end
	local bestX = math.max(0, math.min(cols - wide, math.floor(cx - wide / 2 + 0.5)))
	local bestY = math.max(0, speaker.y0 - tall)
	local bestCost = math.huge
	local lo = math.max(0, math.floor(cx + 0.5) - 50)
	local hi = math.min(cols - wide, math.floor(cx + 0.5) + 50)
	for y = 0, bottom - tall + 1 do
		local x = lo
		while x <= hi + 1 do
			local xx = math.min(x, hi)
			local c = cost(xx, y)
			if c < bestCost then
				bestCost = c
				bestX, bestY = xx, y
			end
			x += 2
		end
	end
	if last and last.x >= 0 and last.x <= cols - wide and last.y >= 0 and last.y + tall - 1 <= bottom and cost(last.x, last.y) <= bestCost + 3 then
		bestX, bestY = last.x, last.y
	end
	local x, y = bestX, bestY
	local tailCol = math.max(x + 2, math.min(x + wide - 3, math.floor(cx + 0.5)))
	local tailRow = math.max(y + 1, math.min(y + tall - 2, math.floor((speaker.y0 + speaker.y1) / 2 + 0.5)))
	local tail: { col: number, row: number, char: string }? = nil
	if y + tall - 1 < speaker.y0 then
		tail = { col = tailCol, row = y + tall - 1, char = '┬' }
	elseif y > speaker.y1 then
		tail = { col = tailCol, row = y, char = '┴' }
	elseif x + wide - 1 < speaker.x0 then
		tail = { col = x + wide - 1, row = tailRow, char = '├' }
	elseif x > speaker.x1 then
		tail = { col = x, row = tailRow, char = '┤' }
	end
	for row = y, y + tall - 1 do
		for col = x, x + wide - 1 do
			covered[row * cols + col + 1] = 1
		end
	end
	return { x = x, y = y, tail = tail }
end

-- Clawd's look from a call's arguments: an options object, or the short
-- form's facing, stride, blink and color.
local function lookOf(facing: any, stride: any, blink: any, color: any): Clawd.ClawdLook
	if type(facing) == 'table' then
		local o = facing
		local strideIn = num(o.stride, -1)
		local pose = if o.pose == 'stand' or o.pose == 'walk' or o.pose == 'jump' or o.pose == 'sit' then o.pose elseif strideIn >= 0 then 'walk' else 'stand'
		local lookIn = if type(o.look) == 'table' then o.look else {}
		local function armOf(v: any, fallback: string): string
			return if v == 'up' or v == 'out' or v == 'down' then v else fallback
		end
		local armsIn = o.arms
		local arms = if type(armsIn) == 'table' then { left = armOf(armsIn.left, 'up'), right = armOf(armsIn.right, 'up') } else { left = armOf(armsIn, 'up'), right = armOf(armsIn, 'up') }
		return {
			pose = pose,
			arms = arms,
			stride = math.max(0, math.floor(strideIn + 0.5)),
			facing = if num(o.facing) > 0 then 1 elseif num(o.facing) < 0 then -1 else 0,
			eyes = if o.eyes == 'open' or o.eyes == 'closed' or o.eyes == 'wide' then o.eyes else 'open',
			look = { x = num(lookIn.x, num(o.lookX)), y = num(lookIn.y, num(o.lookY)) },
			isBlinking = jsBool(o.blink),
			color = colorOf(o.color, Clawd.CLAWD_ORANGE),
			eyeColor = colorOf(o.eyeColor, Clawd.LOOK.eyeColor),
			scale = math.min(4, math.max(1, math.floor(num(o.scale, 1) + 0.5))),
		}
	end
	local strideIn = math.floor(num(stride, -1) + 0.5)
	local f = num(facing)
	return {
		pose = if strideIn >= 0 then 'walk' else 'stand',
		arms = Clawd.LOOK.arms,
		stride = math.max(0, strideIn),
		facing = if f > 0 then 1 elseif f < 0 then -1 else 0,
		eyes = Clawd.LOOK.eyes,
		look = Clawd.LOOK.look,
		isBlinking = jsBool(blink),
		color = colorOf(color, Clawd.CLAWD_ORANGE),
		eyeColor = Clawd.LOOK.eyeColor,
		scale = Clawd.LOOK.scale,
	}
end

type ScreenAnchor = { x: number, py: number, row: number, w: number }
type ScreenAnchors = {
	x: number,
	py: number,
	row: number,
	w: number,
	h: number,
	top: ScreenAnchor,
	left: ScreenAnchor,
	right: ScreenAnchor,
	feet: ScreenAnchor,
	eyes: ScreenAnchor,
}
-- Anchors as the code reads them: absolute pixel positions.
local function anchorsOut(a: Clawd.Anchors?, left: number, top: number): ScreenAnchors?
	if not a then
		return nil
	end
	local function at(p: Clawd.Point)
		local py = top + p.y
		return { x = left + p.x, py = py, row = math.floor(py / 2), w = 0 }
	end
	local eyes = at(a.eyes)
	eyes.w = a.eyes.w
	return {
		x = left,
		py = top,
		row = math.floor(top / 2),
		w = a.w,
		h = a.h,
		top = at(a.top),
		left = at(a.left),
		right = at(a.right),
		feet = at(a.feet),
		eyes = eyes,
	}
end

-- A primitive the code asked for, the same object for the same arguments:
-- code that builds sphere(1, 48) inside frame() would otherwise read and
-- prepare a fresh mesh every frame.
local PRIMITIVES: { [string]: { verts: { number }, faces: { number } } } = {}
local primitiveCount = 0
local MESHES: { [string]: Render3d.Mesh } = {}
local function meshOut(kind: string, args: { number }, make: (...any) -> Render3d.Mesh)
	local key = kind .. '|' .. table.concat(args, ',')
	local out = PRIMITIVES[key]
	if not out then
		if primitiveCount >= 64 then
			PRIMITIVES = {}
			MESHES = {}
			primitiveCount = 0
		end
		local m = make(table.unpack(args))
		out = { verts = m.verts, faces = m.faces }
		MESHES[key] = m
		PRIMITIVES[key] = out
		primitiveCount += 1
	end
	return out
end

-- A mesh as the code gives it: verts flat, faces flat triangles or lists of
-- indices (polygons, fanned into triangles).
local function readMesh(o: any): Render3d.Mesh
	if type(o) ~= 'table' or type(o.verts) ~= 'table' or type(o.faces) ~= 'table' then
		return { verts = {}, faces = {} }
	end
	local count = math.floor(#o.verts / 3)
	local function index(v: any): number
		local i = math.floor(num(v, -1) + 0.5)
		return if i >= 0 and i < count then i else -1
	end
	local verts: { number } = {}
	for i = 1, math.min(60000, #o.verts) do
		verts[i] = num(o.verts[i])
	end
	local faces: { number } = {}
	local allPoly = true
	for i = 1, math.min(60000, #o.faces) do
		if type(o.faces[i]) ~= 'table' then
			allPoly = false
			break
		end
	end
	if allPoly then
		for _, poly in o.faces do
			if #faces >= 3 * MOST_TRIANGLES then
				break
			end
			local ids: { number } = {}
			for i = 1, math.min(3 * MOST_TRIANGLES, #poly) do
				ids[i] = index(poly[i])
			end
			local bad = false
			for _, i in ids do
				if i < 0 then
					bad = true
					break
				end
			end
			if not bad then
				for i = 2, #ids - 1 do
					if #faces >= 3 * MOST_TRIANGLES then
						break
					end
					table.insert(faces, ids[1])
					table.insert(faces, ids[i])
					table.insert(faces, ids[i + 1])
				end
			end
		end
	else
		local ids: { number } = {}
		for i = 1, math.min(60000, #o.faces) do
			ids[i] = index(o.faces[i])
		end
		local i = 1
		while i + 2 <= #ids do
			if ids[i] >= 0 and ids[i + 1] >= 0 and ids[i + 2] >= 0 then
				table.insert(faces, ids[i])
				table.insert(faces, ids[i + 1])
				table.insert(faces, ids[i + 2])
			end
			i += 3
		end
	end
	return { verts = verts, faces = faces }
end

-- What a scene's code runs against: its parsed program plus the 3D state it
-- sets, and the speech it has said (so bubbles type out and keep their place).
export type Runner = {
	program: any,
	cols: number,
	rows: number,
	isStarted: boolean,
	cam: any?,
	light: any?,
	fog: any?,
	said: { [string]: number },
	saidCount: number,
	bubblesAt: { [string]: { x: number, y: number } },
	bubblesCount: number,
	lastT: number,
}

local function baseGlobals(runner: Runner, cols: number, rows: number, t: number, dt: number)
	local g: { [string]: any } = {}
	for name, fn in pairs(FUNCTIONS) do
		g[name :: string] = fn :: any
	end
	g.t = t
	g.dt = dt
	g.w = cols
	g.h = rows
	return g
end

-- Parse a scene. Its top level runs on the first frame, against that frame's
-- canvas, the way the original does. `{what}` becomes the word the agent is
-- working on.
local function load(code: string, cols: number, rows: number, word: string?): (Runner?, string?)
	local source = string.gsub(code, '%{what%}', tostring(word or 'the build'))
	local program, err = Engine.parse(source)
	if not program then
		return nil, Engine.errmsg(err)
	end
	local runner: Runner = {
		program = program,
		cols = cols,
		rows = rows,
		isStarted = false,
		said = {},
		saidCount = 0,
		bubblesAt = {},
		bubblesCount = 0,
		lastT = 0,
	}
	return runner, nil
end

-- One frame: a fresh canvas, the program's frame(t, dt), then its speech on
-- top. Returns the frame as escape sequences; `style` is 'pixel', 'color' or
-- 'ascii' (see Raster.encode).
local function draw(runner: Runner, t: number, dt: number, style: string?): string
	local cols, rows = runner.cols, runner.rows
	local r = Raster.new(cols, rows)
	local inked: { [number]: number } = {}
	local bubbled: { [number]: number } = {}
	local lastClawd: Box? = nil
	local isFilling = false
	local frame3d: any = nil
	local isDirty3d = false
	local scene3d: { frame: any, view: any, light: any, fog: any }? = nil
	local bubbles: { { lines: { string }, x: number, y: number, wide: number, tall: number, base: number, tail: any } } = {}
	local saidNow: { [string]: number } = {}
	local saidNowCount = 0
	local frameOf = function()
		if not frame3d then
			frame3d = Render3d.createFrame(cols, rows)
		end
		return frame3d
	end
	local function put(col: number, row: number, glyph: string, fg: number, bg: number?)
		Raster.put(r, col, row, glyph, fg, bg)
	end
	local function flush3d()
		if frame3d and isDirty3d then
			Render3d.composite(frame3d, put)
			isDirty3d = false
		end
	end
	local function scene3dOf(isDrawing: boolean?): { frame: any, view: any, light: any, fog: any }
		if isDrawing ~= false then
			isDirty3d = true
		end
		if not scene3d then
			scene3d = {
				frame = frameOf(),
				view = Render3d.resolve(runner.cam or Render3d.DEFAULT_CAMERA, cols * SX, rows * SY),
				light = runner.light or Render3d.DEFAULT_LIGHT,
				fog = runner.fog or Render3d.DEFAULT_FOG,
			}
		end
		return scene3d :: { frame: any, view: any, light: any, fog: any }
	end
	local function ink(col: number, row: number)
		if not isFilling and col >= 0 and col < cols and row >= 0 and row < rows then
			inked[math.floor(row) * cols + math.floor(col) + 1] = 1
		end
	end
	local function mark(box: Box)
		lastClawd = box
		for row = math.max(0, box.y0), math.min(rows - 1, box.y1) do
			for col = math.max(0, box.x0), math.min(cols - 1, box.x1) do
				ink(col, row)
			end
		end
	end
	local function paintClawd(x: number, py: number, look: Clawd.ClawdLook): Clawd.Anchors
		for _, px in Clawd.clawdPixels(look) do
			Raster.plot(r, x + px.x, py + px.y, px.c)
		end
		return Clawd.clawdAnchors(look)
	end
	local function underlying(col: number, row: number): number?
		if col < 0 or col >= cols or row < 0 or row >= rows then
			return nil
		end
		local at = math.floor(row) * cols + math.floor(col) + 1
		local ch = r.glyph[at]
		local fg = r.fg[at]
		local bg = r.bg[at]
		if bg ~= CLEAR and ch == 0x20 then
			return bg
		end
		local isBlock = ch == 0x2580 or ch == 0x2584 or ch == 0x2588
		if isBlock and fg ~= CLEAR then
			return if bg ~= CLEAR then Color.mix(fg, bg, 0.5) else fg
		end
		if bg ~= CLEAR then
			return bg
		end
		return nil
	end

	local API: { [string]: any } = {}
	API.put = function(x: any, y: any, ch: any, color: any, back: any)
		local glyph = charOf(ch)
		if glyph then
			flush3d()
			local col = math.floor(num(x) + 0.5)
			local row = math.floor(num(y) + 0.5)
			put(col, row, glyph, colorOf(color), if back == nil then nil else colorOf(back))
			ink(col, row)
		end
	end
	API.text = function(x: any, y: any, str: any, color: any, back: any)
		local col = math.floor(num(x) + 0.5)
		local row = math.floor(num(y) + 0.5)
		local cs = chars(strOf(str))
		for i = 1, math.min(400, #cs) do
			API.put(col + i - 1, row, cs[i] or ' ', color, back)
		end
	end
	API.sprite = function(x: any, y: any, art: any, color: any, back: any)
		local col = math.floor(num(x) + 0.5)
		local row = math.floor(num(y) + 0.5)
		local lineNo = 0
		for line in string.gmatch(strOf(art), '[^\n]*\n?') do
			if lineNo >= 40 then
				break
			end
			lineNo += 1
			local body = string.gsub(line, '\n', '')
			local cs = chars(body)
			local start = 0
			for i = 1, #cs do
				if cs[i] ~= ' ' then
					start = i
					break
				end
			end
			if start > 0 then
				local endAt = #cs
				while endAt > start and cs[endAt] == ' ' do
					endAt -= 1
				end
				endAt = math.min(#cs, endAt)
				for dx = start, math.min(300, endAt) do
					local c = charOf(cs[dx]) or ' '
					if c == ' ' and back == nil then
						flush3d()
						Raster.clearBox(r, col + dx - 1, row + lineNo - 1, col + dx - 1, row + lineNo - 1)
					else
						API.put(col + dx - 1, row + lineNo - 1, c, color, back)
					end
				end
			end
		end
	end
	API.fill = function(x: any, y: any, w: any, h: any, ch: any, color: any, back: any)
		local x0 = math.floor(num(x) + 0.5)
		local y0 = math.floor(num(y) + 0.5)
		isFilling = true
		local glyph = charOf(ch) or ' '
		for row = y0, y0 + math.min(60, math.floor(num(h) + 0.5)) - 1 do
			for col = x0, x0 + math.min(400, math.floor(num(w) + 0.5)) - 1 do
				API.put(col, row, glyph, color, back)
			end
		end
		isFilling = false
	end
	API.clear = function(x: any, y: any)
		flush3d()
		local col = math.floor(num(x) + 0.5)
		local row = math.floor(num(y) + 0.5)
		Raster.clearBox(r, col, row, col, row)
	end
	API.line = function(x0: any, y0: any, x1: any, y1: any, ch: any, color: any)
		local ax, ay = num(x0), num(y0)
		local bx, by = num(x1), num(y1)
		local steps = math.min(800, math.ceil(math.max(math.abs(bx - ax), math.abs(by - ay), 0)))
		local glyph = charOf(ch) or '*'
		for i = 0, steps do
			local k = if steps == 0 then 0 else i / steps
			API.put(ax + (bx - ax) * k, ay + (by - ay) * k, glyph, color)
		end
	end
	API.circle = function(cx: any, cy: any, rr: any, ch: any, color: any)
		local radius = math.min(100, math.abs(num(rr)))
		local steps = math.max(8, math.ceil(radius * 12))
		local glyph = charOf(ch) or 'o'
		for i = 0, steps - 1 do
			local a = (i / steps) * math.pi * 2
			API.put(num(cx) + math.cos(a) * radius * 2, num(cy) + math.sin(a) * radius, glyph, color)
		end
	end
	API.disc = function(cx: any, cy: any, rr: any, ch: any, color: any, back: any)
		local radius = math.min(60, math.abs(num(rr)))
		local glyph = charOf(ch) or '█'
		local cxc = math.floor(num(cx) + 0.5)
		local cyc = math.floor(num(cy) + 0.5)
		for dy = -math.ceil(radius), math.ceil(radius) do
			for dx = -math.ceil(radius * 2), math.ceil(radius * 2) do
				if (dx / 2) * (dx / 2) + dy * dy <= radius * radius then
					API.put(cxc + dx, cyc + dy, glyph, color, back)
				end
			end
		end
	end
	API.clawd = function(x: any, y: any, facing: any, stride: any, blink: any, color: any)
		flush3d()
		local look = lookOf(facing, stride, blink, color)
		local col = math.floor(num(x) + 0.5)
		local py = math.floor(num(y) * 2 + 0.5)
		local a = paintClawd(col, py, look)
		mark({ x0 = col - 1, y0 = math.floor(py / 2), x1 = col + a.w, y1 = math.floor((py + a.h - 1) / 2) })
		return anchorsOut(a, col, py)
	end
	API.pixel = function(x: any, py: any, color: any)
		flush3d()
		local col = math.floor(num(x) + 0.5)
		local row = math.floor(num(py) + 0.5)
		Raster.plot(r, col, row, colorOf(color))
		ink(col, math.floor(row / 2))
	end
	API.pixels = function(x: any, py: any, art: any, palette: any)
		flush3d()
		local col = math.floor(num(x) + 0.5)
		local row = math.floor(num(py) + 0.5)
		local map = if type(palette) == 'table' then palette else {}
		local lineNo = 0
		for line in string.gmatch(strOf(art), '[^\n]*\n?') do
			if lineNo >= 80 then
				break
			end
			lineNo += 1
			local cs = chars(string.gsub(line, '\n', ''))
			for dx = 1, math.min(300, #cs) do
				local c = cs[dx]
				if c ~= ' ' and c ~= '.' then
					Raster.plot(r, col + dx - 1, row + lineNo - 1, colorOf(map[c]))
					ink(col + dx - 1, math.floor((row + lineNo - 1) / 2))
				end
			end
		end
	end
	API.camera = function(ex: any, ey: any, ez: any, tx: any, ty: any, tz: any, fov: any)
		runner.cam = { eye = { num(ex), num(ey, 2.5), num(ez, 9) }, target = { num(tx), num(ty, 1), num(tz) }, fov = num(fov, 90) }
	end
	API.light = function(dx: any, dy: any, dz: any, ambient: any)
		runner.light = { dir = { num(dx, 0.4), num(dy, 1), num(dz, 0.6) }, ambient = Color.clamp(num(ambient, 0.35)) }
	end
	API.fog = function(near: any, far: any, color: any)
		local n = num(near, 8)
		runner.fog = { near = n, far = math.max(n + 0.01, num(far, 40)), color = colorOf(color, BLACK) }
	end
	API.box = function(w: any, h: any, d: any)
		return meshOut('box', { num(w, 1), num(h, 1), num(d, 1) }, Render3d.box)
	end
	API.sphere = function(rr: any, segments: any)
		return meshOut('sphere', { num(rr, 1), num(segments, 8) }, Render3d.sphere)
	end
	API.cylinder = function(rr: any, h: any, segments: any)
		return meshOut('cylinder', { num(rr, 1), num(h, 1), num(segments, 8) }, function(a: number, b: number, c: number)
			return Render3d.cylinder(a, a, b, c)
		end)
	end
	API.cone = function(rr: any, h: any, segments: any)
		return meshOut('cone', { num(rr, 1), num(h, 1), num(segments, 8) }, function(a: number, b: number, c: number)
			return Render3d.cylinder(a, 0, b, c)
		end)
	end
	API.plane = function(w: any, d: any)
		return meshOut('plane', { num(w, 1), num(d, 1) }, Render3d.plane)
	end
	API.mesh3d = function(mesh: any, options: any)
		local m = if type(mesh) == 'table' and type(mesh.verts) == 'table' and type(mesh.faces) == 'table' then readMesh(mesh) else nil
		if not m then
			return
		end
		local o = if type(options) == 'table' then options else {}
		local scale = o.scale
		local sc
		if type(scale) == 'table' then
			sc = { num(scale[1], 1), num(scale[2], 1), num(scale[3], 1) }
		else
			local uniform = num(scale, 1)
			sc = { uniform, uniform, uniform }
		end
		local s = scene3dOf(true)
		Render3d.drawMesh(s.frame, s.view, s.light, s.fog, m, {
			at = { num(o.x), num(o.y), num(o.z) },
			rot = { num(o.rx), num(o.ry), num(o.rz) },
			scale = sc,
		}, { color = colorOf(o.color), wire = jsBool(o.wire), unlit = jsBool(o.unlit), ascii = jsBool(o.ascii) })
	end
	API.line3d = function(x0: any, y0: any, z0: any, x1: any, y1: any, z1: any, color: any)
		local s = scene3dOf(true)
		Render3d.drawLine(s.frame, s.view, s.fog, { num(x0), num(y0), num(z0) }, { num(x1), num(y1), num(z1) }, colorOf(color))
	end
	API.point3d = function(x: any, y: any, z: any, color: any)
		local s = scene3dOf(true)
		Render3d.drawPoint(s.frame, s.view, s.fog, { num(x), num(y), num(z) }, colorOf(color))
	end
	API.project = function(x: any, y: any, z: any): any
		local s = scene3dOf(false)
		local p = Render3d.project(s.view, { num(x), num(y), num(z) })
		if not p then
			return nil
		end
		return {
			x = math.floor(p.x / SX + 0.5),
			y = math.floor(p.y / SY + 0.5),
			px = math.floor(p.x / SX + 0.5),
			py = math.floor(p.y / (SY / 2) + 0.5),
			depth = p.depth,
			scale = s.view.f / p.depth / SX,
		}
	end
	API.clawd3d = function(x: any, y: any, z: any, options: any): any
		local s = scene3dOf(true)
		local atv = { num(x), num(y), num(z) }
		local p = Render3d.project(s.view, atv)
		if not p then
			return nil
		end
		local o = if type(options) == 'table' then options else {}
		local look = lookOf(o)
		local perUnit = s.view.f / p.depth / (SY / 2)
		local size = math.min(num(o.size, 0.9), (rows * 2 * 0.7) / perUnit)
		local u = size / CLAWD_H
		local sc = (size * perUnit) / CLAWD_H
		local below = p.y / (SY / 2) - rows * 2
		if below > 0 then
			atv[2] += below / perUnit
		end
		local ry = math.atan2(s.view.eye[1] - atv[1], s.view.eye[3] - atv[3])
		local sin, cos = math.sin(ry), math.cos(ry)
		local function place(q: { x: number, y: number, z: number }): { x: number, py: number, depth: number }?
			local w = Render3d.project(s.view, {
				atv[1] + (q.x * cos + q.z * sin) * u,
				atv[2] + q.y * u,
				atv[3] + (q.z * cos - q.x * sin) * u,
			})
			if not w then
				return nil
			end
			return { x = w.x / SX, py = w.y / (SY / 2), depth = w.depth }
		end
		Render3d.drawMesh(s.frame, s.view, s.light, s.fog, Clawd.clawdMesh(look), { at = atv, rot = { 0, ry, 0 }, scale = { u, u, u } }, {
			color = look.color,
			wire = false,
			unlit = false,
			ascii = false,
		})
		local points = Clawd.clawdPoints(look)
		local feet = place(points.feet)
		if not feet then
			return nil
		end
		local ew = math.max(1, math.floor(sc + 0.5))
		local one, two = points.eyes[1], points.eyes[2]
		local between = if one and two then place({ x = (one.x + two.x) / 2, y = (one.y + two.y) / 2, z = (one.z + two.z) / 2 }) else nil
		if sc * CLAWD_H >= 3 and between then
			for _, eye in points.eyes do
				local e = place(eye)
				if e then
					local wide = if eye.kind == 'open' then ew else 2 * ew
					local col0 = math.floor(e.x - wide / 2 + 0.5)
					local row0 = 2 * math.floor((between.py - ew) / 2 + 0.5)
					local from = if eye.kind == 'shut' then row0 + ew else row0
					for prow = from, row0 + 2 * ew - 1 do
						for col = col0, col0 + wide - 1 do
							flush3d()
							if Render3d.claimPixel(frameOf(), col, prow, e.depth * 0.98) then
								Raster.plot(r, col, prow, look.eyeColor)
								ink(col, math.floor(prow / 2))
							end
						end
					end
				end
			end
		end
		local w = math.floor(CLAWD_W * sc + 0.5)
		local h = math.floor(CLAWD_H * sc + 0.5)
		local left = math.floor(feet.x - w / 2 + 0.5)
		local top = math.floor(feet.py - h + 0.5)
		mark({ x0 = left - 1, y0 = math.floor(top / 2), x1 = left + w, y1 = math.floor((top + h - 1) / 2) })
		local function anchor(q: { x: number, y: number, z: number }): { x: number, py: number, row: number, w: number }
			local e = place(q) or feet
			local py = math.floor(e.py + 0.5)
			return { x = math.floor(e.x + 0.5), py = py, row = math.floor(py / 2), w = 0 }
		end
		local eyeSpan = anchor(points.eyeSpan)
		eyeSpan.w = math.floor(points.eyeSpan.w * sc + 0.5)
		return {
			x = left,
			py = top,
			row = math.floor(top / 2),
			w = w,
			h = h,
			top = anchor(points.top),
			left = anchor(points.left),
			right = anchor(points.right),
			feet = anchor(points.feet),
			eyes = eyeSpan,
		}
	end
	API.say = function(text: any, x: any, y: any, color: any)
		local line = cleanText(strOf(text), 70)
		if line == '' then
			return
		end
		flush3d()
		if saidNow[line] then
			return
		end
		saidNowCount += 1
		saidNow[line] = 1
		-- A new line types out; one that only changed from a line already
		-- typed (a live count, a timer) shows whole rather than restarting.
		local first = runner.said[line]
		if first == nil then
			local isTyped = function(old: string, at: number)
				return (t - at) * 1000 >= #chars(old) * BUBBLE_MS
			end
			local found = false
			for old, at in runner.said do
				if isTyped(old, at) then
					found = true
					break
				end
			end
			first = if found then -math.huge else t
			if runner.saidCount >= 32 then
				runner.said = {}
				runner.saidCount = 0
			end
			runner.said[line] = first
			runner.saidCount += 1
		end
		local bubble = typedBubble(line, t - first, cols)
		if bubble.wide > cols or bubble.tall > rows then
			return
		end
		-- The speaker is the Clawd last drawn when the point is on or beside
		-- it; otherwise the point itself.
		local px, py = math.floor(num(x) + 0.5), math.floor(num(y) + 0.5)
		local near = lastClawd ~= nil and px >= lastClawd.x0 - 2 and px <= lastClawd.x1 + 2 and py >= lastClawd.y0 - 1 and py <= lastClawd.y1 + 1
		local speaker = if near and lastClawd then lastClawd else { x0 = px, y0 = py, x1 = px, y1 = py }
		-- The bubble keeps clear of what is drawn in runs, not of a
		-- scattering of rain, snow or sparks.
		local covered: { [number]: number } = {}
		local drawn = function(col: number, row: number): boolean
			return col >= 0 and col < cols and row >= 0 and row < rows and inked[row * cols + col + 1] == 1
		end
		for row = 0, rows - 1 do
			for col = 0, cols - 1 do
				local i = row * cols + col + 1
				if bubbled[i] or (inked[i] and ((drawn(col - 1, row) and drawn(col + 1, row)) or (drawn(col, row - 1) and drawn(col, row + 1)))) then
					covered[i] = 1
				end
			end
		end
		local placed = placeBubble(speaker, bubble.wide, bubble.tall, cols, rows, covered, runner.bubblesAt[line])
		for i, v in covered do
			bubbled[i] = v
		end
		if runner.bubblesCount >= 32 then
			runner.bubblesAt = {}
			runner.bubblesCount = 0
		end
		runner.bubblesAt[line] = { x = placed.x, y = placed.y }
		runner.bubblesCount += 1
		table.insert(bubbles, {
			lines = bubble.lines,
			x = placed.x,
			y = placed.y,
			wide = bubble.wide,
			tall = bubble.tall,
			base = colorOf(color, Clawd.CLAWD_ORANGE),
			tail = placed.tail,
		})
	end
	API.rgb = function(rr: any, gg: any, bb: any)
		return Color.pack(num(rr), num(gg), num(bb))
	end
	API.hsl = function(hue: any, sat: any, light: any)
		local hh = (((num(hue) % 360) + 360) % 360) / 60
		local ss = Color.clamp(num(sat))
		local ll = Color.clamp(num(light))
		local c = (1 - math.abs(2 * ll - 1)) * ss
		local x = c * (1 - math.abs((hh % 2) - 1))
		local rr, gg, bb = if hh < 1 then { c, x, 0 } elseif hh < 2 then { x, c, 0 } elseif hh < 3 then { 0, c, x } elseif hh < 4 then { 0, x, c } elseif hh < 5 then { x, 0, c } else { c, 0, x }
		local m = ll - c / 2
		return Color.pack((rr[1] + m) * 255, (rr[2] + m) * 255, (rr[3] + m) * 255)
	end
	API.mix = function(a: any, b: any, k: any)
		return Color.mix(colorOf(a), colorOf(b), Color.clamp(num(k)))
	end
	API.cloud = API.say
	API.sign = API.text

	local globals = baseGlobals(runner, cols, rows, t, dt)
	for name, fn in API do
		globals[name] = fn
	end

	local ok, err = pcall(function()
		if not runner.isStarted then
			runner.isStarted = true
			Engine.start(runner.program, globals, SETUP_FUEL, SETUP_MS / 1000)
		end
		Engine.call(runner.program, 'frame', { t, dt }, globals, FRAME_FUEL, FRAME_MS / 1000)
	end)
	if not ok then
		flush3d()
		error(Engine.errmsg(err))
	end
	flush3d()

	-- Speech on top of everything: a rounded box in the speaker's color,
	-- filled with a dark tint of it so nothing behind shows through.
	for _, b in bubbles do
		b.y = Color.clamp(b.y, 0, math.max(0, rows - b.tall))
		b.x = Color.clamp(b.x, 0, math.max(0, cols - b.wide))
		local edge = Color.mix(b.base, WHITE, 0.35)
		local inkColor = Color.mix(b.base, WHITE, 0.85)
		local function panel(col: number, row: number): number
			local under = underlying(col, row)
			return if under then Color.mix(Color.dim(under, 0.3), Color.dim(b.base, 0.18), 0.35) else Color.dim(b.base, 0.18)
		end
		local right = b.x + b.wide - 1
		local bottomRow = b.y + b.tall - 1
		for row = b.y, bottomRow do
			for col = b.x, right do
				local isTop = row == b.y
				local isBottom = row == bottomRow
				local isLeft = col == b.x
				local isRight = col == right
				local glyph = if isTop and isLeft then '╭' elseif isTop and isRight then '╮' elseif isBottom and isLeft then '╰' elseif isBottom and isRight then '╯' elseif isTop or isBottom then '─' elseif isLeft or isRight then '│' else ' '
				put(col, row, glyph, if glyph == ' ' then inkColor else edge, panel(col, row))
			end
		end
		if b.tail then
			put(b.tail.col, b.tail.row, b.tail.char, edge, panel(b.tail.col, b.tail.row))
		end
		for dy, line in b.lines do
			local cs = chars(line)
			for dx, c in cs do
				put(b.x + 2 + dx - 1, b.y + 1 + dy - 1, c, inkColor, panel(b.x + 2 + dx - 1, b.y + 1 + dy - 1))
			end
		end
	end

	return Raster.encode(r, style)
end

return {
	FUNCTIONS = FUNCTIONS,
	load = load,
	draw = draw,
	errmsg = Engine.errmsg,
}
