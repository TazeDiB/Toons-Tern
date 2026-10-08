--!strict
-- A small 3D renderer for scene code, ported from claude-toons' render3d.ts.
-- The world is sampled at a finer grid than the cells (2 across, 4 down),
-- each sample is lit with a smoothly interpolated normal, and each cell is
-- drawn from its samples: whole coverage is a solid cell, partial coverage
-- is the block glyph for the quarters covered, and an `ascii` mesh is the
-- glyph whose density matches its brightness.
--
-- Colors cross the API boundary packed (Color values); inside the sample
-- buffer they are three floats.

local Color = require('./color')

export type Vec3 = { number }
export type Mesh = { verts: { number }, faces: { number } }
export type Camera = { eye: Vec3, target: Vec3, fov: number }
export type Light = { dir: Vec3, ambient: number }
export type Fog = { near: number, far: number, color: Color.Color }
export type Transform = { at: Vec3, rot: Vec3, scale: Vec3 }
export type Style = { color: Color.Color, wire: boolean, unlit: boolean, ascii: boolean? }

type Frame = {
	cols: number,
	rows: number,
	w: number,
	h: number,
	depth: { number },
	color: { number },
	owner: { number },
	dirty: { number },
	triangles: number,
	tick: (() -> ())?,
}

local DEFAULT_CAMERA: Camera = { eye = { 0, 2.5, 9 }, target = { 0, 1, 0 }, fov = 90 }
local DEFAULT_LIGHT: Light = { dir = { 0.4, 1, 0.6 }, ambient = 0.25 }
local DEFAULT_FOG: Fog = { near = 8, far = 40, color = Color.CLEAR }

-- The strip is wide and only 9 rows tall, so the field of view is measured
-- over this many columns whatever the terminal's width.
local NOMINAL_COLS = 120

-- Samples per cell, across and down.
local SX = 2
local SY = 4

-- Nothing nearer than this draws.
local NEAR = 0.05

-- The most triangles one frame draws, over every mesh.
local MOST_TRIANGLES = 20000

local SURFACE = 1
local SPRITE = 2
local ASCII = 3
local function isSurface(owner: number): boolean
	return owner == SURFACE or owner == ASCII
end

local function sub(a: Vec3, b: Vec3): Vec3
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function dot(a: Vec3, b: Vec3): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function cross(a: Vec3, b: Vec3): Vec3
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

local function norm(a: Vec3): Vec3
	local l = math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
	if l == 0 or l ~= l then
		l = 1
	end

	return { a[1] / l, a[2] / l, a[3] / l }
end

local function clamp01(v: number): number
	return math.min(1, math.max(0, v))
end

local function smoothstep(lo: number, hi: number, v: number): number
	local k = if hi == lo then (if v >= hi then 1 else 0) else clamp01((v - lo) / (hi - lo))

	return k * k * (3 - 2 * k)
end

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

-- ---------------------------------------------------------------- camera

type View = { eye: Vec3, right: Vec3, up: Vec3, forward: Vec3, f: number, w: number, h: number }

local function resolve(cam: Camera, w: number, h: number): View
	local forward = norm(sub(cam.target, cam.eye))
	local worldUp: Vec3 = if math.abs(forward[2]) > 0.99 then { 0, 0, -1 } else { 0, 1, 0 }
	local right = norm(cross(forward, worldUp))
	local up = cross(right, forward)
	local fov = (math.max(10, math.min(170, cam.fov)) * math.pi) / 180
	-- The focal length in samples: pixels over the nominal width, times the
	-- samples per column.
	local f = ((NOMINAL_COLS / 2) * SX) / math.tan(fov / 2)

	return { eye = cam.eye, right = right, up = up, forward = forward, f = f, w = w, h = h }
end

-- A point in the camera's frame: across, up, and its depth ahead.
type ViewPoint = { r: number, u: number, d: number }
type Projected = { x: number, y: number, depth: number }

local function toView(view: View, p: Vec3): ViewPoint
	local d = sub(p, view.eye)

	return { r = dot(d, view.right), u = dot(d, view.up), d = dot(d, view.forward) }
end

local function toScreen(view: View, v: ViewPoint): Projected
	return {
		x = (v.r * view.f) / v.d + view.w / 2,
		y = view.h / 2 - (v.u * view.f) / v.d,
		depth = v.d,
	}
end

-- A world point on the sample grid, or nil when behind the camera.
local function project(view: View, p: Vec3): Projected?
	local v = toView(view, p)
	if v.d < NEAR then
		return nil
	end

	return toScreen(view, v)
end

-- The part of a polygon in front of the near plane (Sutherland-Hodgman
-- against one plane), each vertex carrying its attributes along.
type Vertex = { v: ViewPoint, p: Vec3, n: Vec3 }

local function mixv(a: Vec3, b: Vec3, k: number): Vec3
	return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k }
end

local function clipNear(poly: { Vertex }): { Vertex }
	local allIn = true
	for _, x in poly do
		if x.v.d < NEAR then
			allIn = false
			break
		end
	end
	if allIn then
		return poly
	end
	local out: { Vertex } = {}
	local count = #poly
	for i = 1, count do
		local a = poly[i]
		local b = poly[i % count + 1]
		local aIn = a.v.d >= NEAR
		local bIn = b.v.d >= NEAR
		if aIn then
			table.insert(out, a)
		end
		if aIn ~= bIn then
			local k = (NEAR - a.v.d) / (b.v.d - a.v.d)
			table.insert(out, {
				v = { r = a.v.r + (b.v.r - a.v.r) * k, u = a.v.u + (b.v.u - a.v.u) * k, d = NEAR },
				p = mixv(a.p, b.p, k),
				n = mixv(a.n, b.n, k),
			})
		end
	end

	return out
end

-- ---------------------------------------------------------------- meshes

-- A rotation as a row-major 3x3 matrix (Rz * Ry * Rx, so x applies first).
local function rotation(rot: Vec3): { number }
	local cx, sx = math.cos(rot[1]), math.sin(rot[1])
	local cy, sy = math.cos(rot[2]), math.sin(rot[2])
	local cz, sz = math.cos(rot[3]), math.sin(rot[3])

	return {
		cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx,
		sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx,
		-sy, cy * sx, cy * cx,
	}
end

local function apply(m: { number }, p: Vec3): Vec3
	return {
		m[1] * p[1] + m[2] * p[2] + m[3] * p[3],
		m[4] * p[1] + m[5] * p[2] + m[6] * p[3],
		m[7] * p[1] + m[8] * p[2] + m[9] * p[3],
	}
end

local function placed(t: Transform, m: { number }, p: Vec3): Vec3
	local v = apply(m, { p[1] * t.scale[1], p[2] * t.scale[2], p[3] * t.scale[3] })

	return { v[1] + t.at[1], v[2] + t.at[2], v[3] + t.at[3] }
end

local function transformPoint(t: Transform, p: Vec3): Vec3
	return placed(t, rotation(t.rot), p)
end

-- A normal under a transform: the inverse of the scale, then the rotation.
local function transformNormal(t: Transform, m: { number }, n: Vec3): Vec3
	return apply(
		m,
		norm({ n[1] / (t.scale[1] ~= 0 and t.scale[1] or 1), n[2] / (t.scale[2] ~= 0 and t.scale[2] or 1), n[3] / (t.scale[3] ~= 0 and t.scale[3] or 1) })
	)
end

-- A mesh with a normal for each corner of each face: faces meeting at a
-- gentle angle share smoothed normals, faces meeting at a crease keep their
-- own. And its edges to draw as wire, each once, without the seams inside
-- flat polygons.
type Prepared = { faceNormals: { Vec3 }, cornerNormals: { Vec3 }, edges: { number } }

local prepared: { [Mesh]: Prepared } = setmetatable({}, { __mode = 'k' })
local CREASE = math.cos((50 * math.pi) / 180)
local FLAT = 0.999
-- The most faces around one vertex that smoothing considers.
local MOST_AROUND = 24

local function prepare(mesh: Mesh): Prepared
	local done = prepared[mesh]
	if done then
		return done
	end
	local verts, faces = mesh.verts, mesh.faces
	local function at(i: number): Vec3
		return { verts[i * 3 - 2] or 0, verts[i * 3 - 1] or 0, verts[i * 3] or 0 }
	end
	local count = math.floor(#faces / 3)
	local faceNormals: { Vec3 } = {}
	local around: { [number]: { number } } = {}
	for f = 0, count - 1 do
		local a = faces[f * 3 + 1]
		local b = faces[f * 3 + 2]
		local c = faces[f * 3 + 3]
		table.insert(faceNormals, norm(cross(sub(at(b), at(a)), sub(at(c), at(a)))))
		for _, i in { a, b, c } do
			local list = around[i]
			if not list then
				list = {}
				around[i] = list
			end
			if #list < MOST_AROUND then
				table.insert(list, f)
			end
		end
	end
	local cornerNormals: { Vec3 } = {}
	for f = 0, count - 1 do
		local mine = faceNormals[f + 1]
		for k = 0, 2 do
			local i = faces[f * 3 + k + 1]
			local sum = { 0, 0, 0 }
			for _, g in (around[i] or {}) do
				local other = faceNormals[g + 1]
				if dot(mine, other) >= CREASE then
					sum[1] += other[1]
					sum[2] += other[2]
					sum[3] += other[3]
				end
			end
			table.insert(cornerNormals, norm(sum))
		end
	end
	-- Edges keyed by their two indices as one number, each with the faces
	-- along it.
	local span = math.floor(#verts / 3) + 1
	local edgeFaces: { [number]: { number } } = {}
	for f = 0, count - 1 do
		for k = 0, 2 do
			local a = faces[f * 3 + k + 1]
			local b = faces[f * 3 + (k + 1) % 3 + 1]
			local key = math.min(a, b) * span + math.max(a, b)
			local along = edgeFaces[key]
			if along then
				table.insert(along, f)
			else
				edgeFaces[key] = { f }
			end
		end
	end
	local edges: { number } = {}
	for key, along in edgeFaces do
		if #along == 2 and dot(faceNormals[along[1] + 1], faceNormals[along[2] + 1]) > FLAT then
			continue
		end
		table.insert(edges, math.floor(key / span))
		table.insert(edges, key % span)
	end
	local result = { faceNormals = faceNormals, cornerNormals = cornerNormals, edges = edges }
	prepared[mesh] = result

	return result
end

-- ---------------------------------------------------------------- drawing

local function fogged(c: { number }, fog: Fog, depth: number): { number }
	local k = smoothstep(fog.near, fog.far, depth)
	local fr, fg, fb = Color.unpack(fog.color)

	return { c[1] + (fr - c[1]) * k, c[2] + (fg - c[2]) * k, c[3] + (fb - c[3]) * k }
end

local function plot(frame: Frame, x: number, y: number, depth: number, c: { number }, owner: number?)
	local at = y * frame.w + x + 1
	frame.depth[at] = depth
	frame.owner[at] = owner or SURFACE
	local c3 = at * 3 - 2
	frame.color[c3] = c[1]
	frame.color[c3 + 1] = c[2]
	frame.color[c3 + 2] = c[3]
	frame.dirty[math.floor(y / SY) * frame.cols + math.floor(x / SX) + 1] = 1
end

-- Lights a point of a surface: ambient, diffuse by the normal against the
-- light, and a small highlight where the light reflects toward the eye.
local function lit(color: { number }, n: Vec3, p: Vec3, view: View, l: Vec3, ambient: number): { number }
	local toEye = norm(sub(view.eye, p))
	-- Two-sided: a face seen from behind shades as if it faced the eye.
	local nn: Vec3 = if dot(n, toEye) < 0 then { -n[1], -n[2], -n[3] } else n
	local diffuse = math.max(0, dot(nn, l))
	local half = norm({ l[1] + toEye[1], l[2] + toEye[2], l[3] + toEye[3] })
	local spec = math.pow(math.max(0, dot(nn, half)), 24) * 0.35
	local k = ambient + (1 - ambient) * diffuse

	return {
		math.min(255, color[1] * k + 255 * spec),
		math.min(255, color[2] * k + 255 * spec),
		math.min(255, color[3] * k + 255 * spec),
	}
end

-- Fills one triangle on the sample grid, interpolating depth (linear in
-- 1/depth), world position and normal, lighting each sample.
local function fillTriangle(
	frame: Frame,
	view: View,
	fog: Fog,
	l: Vec3,
	ambient: number,
	tri: { Vertex },
	style: Style
)
	local A, B, C = tri[1], tri[2], tri[3]
	local a = toScreen(view, A.v)
	local b = toScreen(view, B.v)
	local c = toScreen(view, C.v)
	local area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	-- A triangle too thin to show, or one with a corner at infinity.
	if math.abs(area) < 1e-9 then
		return
	end
	if not (finite(a.x + a.y) and finite(b.x + b.y) and finite(c.x + c.y)) then
		return
	end
	local x0 = math.max(0, math.floor(math.min(a.x, b.x, c.x)))
	local x1 = math.min(frame.w - 1, math.ceil(math.max(a.x, b.x, c.x)))
	local y0 = math.max(0, math.floor(math.min(a.y, b.y, c.y)))
	local y1 = math.min(frame.h - 1, math.ceil(math.max(a.y, b.y, c.y)))
	if x1 < x0 or y1 < y0 then
		return
	end
	local ia = 1 / a.depth
	local ib = 1 / b.depth
	local ic = 1 / c.depth
	local styleColor = style.color
	local base = {}
	if not style.unlit then
		local r, g, bl = Color.unpack(styleColor)
		base = { r, g, bl }
	else
		local r, g, bl = Color.unpack(styleColor)
		base = { r, g, bl }
	end
	for y = y0, y1 do
		local py = y + 0.5
		for x = x0, x1 do
			local px = x + 0.5
			local wa = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area
			local wb = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area
			local wc = 1 - wa - wb
			if wa < -1e-6 or wb < -1e-6 or wc < -1e-6 then
				continue
			end
			local depth = 1 / (wa * ia + wb * ib + wc * ic)
			local at = y * frame.w + x + 1
			if depth >= frame.depth[at] then
				continue
			end
			-- Perspective-correct weights for the attributes.
			wa *= ia * depth
			wb *= ib * depth
			wc *= ic * depth
			local color = base
			if not style.unlit then
				local n = norm({
					wa * A.n[1] + wb * B.n[1] + wc * C.n[1],
					wa * A.n[2] + wb * B.n[2] + wc * C.n[2],
					wa * A.n[3] + wb * B.n[3] + wc * C.n[3],
				})
				local p = {
					wa * A.p[1] + wb * B.p[1] + wc * C.p[1],
					wa * A.p[2] + wb * B.p[2] + wc * C.p[2],
					wa * A.p[3] + wb * B.p[3] + wc * C.p[3],
				}
				color = lit(base, n, p, view, l, ambient)
			end
			plot(frame, x, y, depth, fogged(color, fog, depth), if style.ascii then ASCII else SURFACE)
		end
	end
end

-- The share of a segment inside the frame (Liang-Barsky), as the parameters
-- where it enters and leaves, or nil when it misses.
type Span = { enter: number, exit: number }
local function clipSpan(x0: number, y0: number, x1: number, y1: number, w: number, h: number): Span?
	local k0 = 0
	local k1 = 1
	local pairsList = { { x0, x1 - x0, w }, { y0, y1 - y0, h } }
	for _, item in pairsList do
		local p, dp, hi = item[1], item[2], item[3]
		if dp == 0 then
			if p < -1 or p > hi then
				return nil
			end
			continue
		end
		local ka = (-1 - p) / dp
		local kb = (hi - p) / dp
		k0 = math.max(k0, math.min(ka, kb))
		k1 = math.min(k1, math.max(ka, kb))
	end
	if k0 > k1 then
		return nil
	end

	return { enter = k0, exit = k1 }
end

local function dab(frame: Frame, x: number, y: number, depth: number, color: { number })
	for dy = 0, 1 do
		for dx = 0, 1 do
			local sx = x + dx
			local sy = y + dy
			if sx < 0 or sx >= frame.w or sy < 0 or sy >= frame.h then
				continue
			end
			local at = sy * frame.w + sx + 1
			if depth >= frame.depth[at] then
				continue
			end
			plot(frame, sx, sy, depth, color)
		end
	end
end

-- A line between two world points, a cell's width thick, cut at the near
-- plane and depth tested along its length.
local function drawLine(frame: Frame, view: View, fog: Fog, p0: Vec3, p1: Vec3, color: Color.Color)
	local zero: Vec3 = { 0, 0, 0 }
	local ends = clipNear({
		{ v = toView(view, p0), p = p0, n = zero },
		{ v = toView(view, p1), p = p1, n = zero },
	})
	if #ends < 2 then
		return
	end
	local a = toScreen(view, ends[1].v)
	local b = toScreen(view, ends[2].v)
	-- Only the part on screen is stepped, a sample at a time, with the step
	-- still a share of the whole segment so depth follows it correctly.
	local span = clipSpan(a.x, a.y, b.x, b.y, frame.w, frame.h)
	if not span then
		return
	end
	local k0: number = span.enter
	local k1: number = span.exit
	local steps = math.min(
		frame.w + frame.h,
		math.ceil(math.max(math.abs(b.x - a.x), math.abs(b.y - a.y)) * (k1 - k0)) or 1
	)
	local r, g, bl = Color.unpack(color)
	local base = { r, g, bl }
	for i = 0, steps do
		local k = k0 + ((k1 - k0) * i) / steps
		local x = math.floor(a.x + (b.x - a.x) * k)
		local y = math.floor(a.y + (b.y - a.y) * k)
		local depth = 1 / ((1 - k) / a.depth + k / b.depth)
		-- A little nearer than the surface it lies on, so edges show on faces.
		dab(frame, x, y, depth - 0.03, fogged(base, fog, depth))
	end
end

local function drawPoint(frame: Frame, view: View, fog: Fog, p: Vec3, color: Color.Color)
	local a = project(view, p)
	if not a then
		return
	end
	local r, g, bl = Color.unpack(color)
	dab(frame, math.floor(a.x), math.floor(a.y), a.depth, fogged({ r, g, bl }, fog, a.depth))
end

-- Draws a mesh placed by a transform: filled and lit, or as wire edges.
local function drawMesh(
	frame: Frame,
	view: View,
	light: Light,
	fog: Fog,
	mesh: Mesh,
	t: Transform,
	style: Style
)
	local verts, faces = mesh.verts, mesh.faces
	local prep = prepare(mesh)
	local cornerNormals, edges = prep.cornerNormals, prep.edges
	local m = rotation(t.rot)
	local n = math.floor(#verts / 3)
	local world: { Vec3 } = {}
	local eyed: { ViewPoint } = {}
	for i = 0, n - 1 do
		local p = placed(t, m, { verts[i * 3 + 1], verts[i * 3 + 2], verts[i * 3 + 3] })
		table.insert(world, p)
		table.insert(eyed, toView(view, p))
	end
	if style.wire then
		-- Each edge once; an edge counts against the triangle budget.
		local e = 0
		while e + 1 < #edges and frame.triangles < MOST_TRIANGLES do
			local ia = edges[e + 1] + 1
			local ib = edges[e + 2] + 1
			local a = world[ia]
			local b = world[ib]
			e += 2
			if a and b then
				frame.triangles += 1
				if frame.tick then
					frame.tick()
				end
				drawLine(frame, view, fog, a, b, style.color)
			end
		end

		return
	end
	local l = norm(light.dir)
	local faceCount = math.floor(#faces / 3)
	local f = 0
	while f < faceCount and frame.triangles < MOST_TRIANGLES do
		local ids = { faces[f * 3 + 1] + 1, faces[f * 3 + 2] + 1, faces[f * 3 + 3] + 1 }
		local corners: { Vertex } = {}
		for k = 0, 2 do
			local index = ids[k + 1]
			local v = eyed[index]
			local p = world[index]
			if v and p then
				table.insert(corners, {
					v = v,
					p = p,
					n = transformNormal(t, m, cornerNormals[f * 3 + k + 1] or { 0, 1, 0 }),
				})
			end
		end
		if #corners == 3 then
			local allBehind = true
			for _, c in corners do
				if c.v.d >= NEAR then
					allBehind = false
					break
				end
			end
			if not allBehind then
				frame.triangles += 1
				if frame.tick then
					frame.tick()
				end
				local poly = clipNear(corners)
				for j = 1, #poly - 2 do
					fillTriangle(frame, view, fog, l, light.ambient, { poly[1], poly[j + 1], poly[j + 2] }, style)
				end
			end
		end
		f += 1
	end
end

-- Claims a sprite's pixel (a column and a pixel row, two to a cell) at a
-- depth: true when it is nearer than what is there.
local function claimPixel(frame: Frame, col: number, py: number, depth: number): boolean
	local x0 = col * SX
	local y0 = py * (SY / 2)
	if x0 < 0 or x0 >= frame.w or y0 < 0 or y0 >= frame.h then
		return false
	end
	local nearest = math.huge
	for dy = 0, SY / 2 - 1 do
		for dx = 0, SX - 1 do
			nearest = math.min(nearest, frame.depth[(y0 + dy) * frame.w + x0 + dx + 1])
		end
	end
	if depth >= nearest then
		return false
	end
	for dy = 0, SY / 2 - 1 do
		for dx = 0, SX - 1 do
			local at = (y0 + dy) * frame.w + x0 + dx + 1
			frame.depth[at] = depth
			frame.owner[at] = SPRITE
		end
	end

	return true
end

-- ---------------------------------------------------------------- glyphs

-- Glyphs by brightness, sparse to dense, for `ascii` meshes.
local RAMP = ' .,:;-=+*#%@'

-- The block glyph for each set of covered quarters: bit 1 top-left, 2
-- top-right, 4 bottom-left, 8 bottom-right.
local QUARTERS = {
	' ', '▘', '▝', '▀', '▖', '▌', '▞', '▛', '▗', '▚', '▐', '▜', '▄', '▙', '▟', '█',
}

-- How far a sample's depth must jump from a neighbor's to count as an edge,
-- and how much the farther side darkens there.
local EDGE = 0.06
local RIM = 0.45

-- Two groups closer than this (squared distance over the channels) are one
-- color: the cell stays solid rather than split.
local ALIKE = 20 * 20 * 3

local function bitCount(m: number): number
	return bit32.band(m, 1) + bit32.band(bit32.rshift(m, 1), 1) + bit32.band(bit32.rshift(m, 2), 1) + bit32.band(bit32.rshift(m, 3), 1)
end

local function dist(a: { number }, b: { number }): number
	return (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2
end

local function groupMean(q: { { number }? }, mask: number): { number }?
	local sum = { 0, 0, 0 }
	local n = 0
	for i = 0, 3 do
		local c = q[i + 1]
		if bit32.band(mask, bit32.lshift(1, i)) ~= 0 and c then
			sum[1] += c[1]
			sum[2] += c[2]
			sum[3] += c[3]
			n += 1
		end
	end
	if n == 0 then
		return nil
	end

	return { sum[1] / n, sum[2] / n, sum[3] / n }
end

-- Ink that stays visible: the color brightened toward its hue when dark.
local function lift(c: { number }): { number }
	local max = math.max(c[1], c[2], c[3], 1)
	local k = math.max(1, 90 / max)

	return { math.min(255, c[1] * k), math.min(255, c[2] * k), math.min(255, c[3] * k) }
end

-- A sample's color, darkened where its depth jumps away from a neighbor's
-- (the far side of an overlap). Depth is compared as 1/depth, which runs
-- straight across a flat surface on screen, so only a kink counts, not a
-- slope.
local function rimmed(frame: Frame, x: number, y: number, at: number): { number }
	local c3 = at * 3 - 2
	local c = { frame.color[c3], frame.color[c3 + 1], frame.color[c3 + 2] }
	local i = 1 / frame.depth[at]
	-- 1/depth of the surface sample k steps along an axis, if there is one.
	local function along(dx: number, dy: number, k: number): number?
		local sx = x + dx * k
		local sy = y + dy * k
		if sx < 0 or sx >= frame.w or sy < 0 or sy >= frame.h then
			return nil
		end
		local n = sy * frame.w + sx + 1

		return if isSurface(frame.owner[n]) then 1 / frame.depth[n] else nil
	end
	local function kink(dx: number, dy: number): number
		local a = along(dx, dy, 1)
		local b = along(dx, dy, -1)
		if a ~= nil and b ~= nil then
			return a + b - 2 * i
		end
		local side = if a ~= nil then 1 elseif b ~= nil then -1 else 0
		if side == 0 then
			return 0
		end
		local nearv = along(dx, dy, side) :: number
		local beyond = along(dx, dy, 2 * side)
		-- Two samples wide there is no trend to go by: the jump alone decides.
		if beyond == nil then
			return if nearv - i > EDGE * nearv then math.huge else 0
		end

		return 2 * nearv - beyond - i
	end
	local isRim = kink(1, 0) > EDGE * i or kink(0, 1) > EDGE * i

	return if isRim then { c[1] * RIM, c[2] * RIM, c[3] * RIM } else c
end

-- Draws the cells drawn on since the last composite. Each cell's four
-- quarters are split into two color groups, and the cell is the quarter-block
-- glyph of that split with a color for each group.
local function composite(
	frame: Frame,
	put: (number, number, string, Color.Color, Color.Color?) -> ()
)
	local per = SX * SY
	local half = SY / 2
	for row = 0, frame.rows - 1 do
		for col = 0, frame.cols - 1 do
			local cell = row * frame.cols + col + 1
			if frame.dirty[cell] == 0 then
				continue
			end
			frame.dirty[cell] = 0
			-- Per quarter: samples covered, their summed color; and the cell's.
			local qCount = { 0, 0, 0, 0 }
			local qSum = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
			local covered = 0
			local sprite = 0
			local ascii = 0
			local sum = { 0, 0, 0 }
			for dy = 0, SY - 1 do
				for dx = 0, SX - 1 do
					local x = col * SX + dx
					local y = row * SY + dy
					local at = y * frame.w + x + 1
					local owner = frame.owner[at]
					if owner == SPRITE then
						sprite += 1
					end
					if not isSurface(owner) then
						continue
					end
					if owner == ASCII then
						ascii += 1
					end
					local c = rimmed(frame, x, y, at)
					local q = (if dy < half then 0 else 2) + (if dx < SX / 2 then 0 else 1)
					qCount[q + 1] += 1
					qSum[q + 1][1] += c[1]
					qSum[q + 1][2] += c[2]
					qSum[q + 1][3] += c[3]
					covered += 1
					sum[1] += c[1]
					sum[2] += c[2]
					sum[3] += c[3]
				end
			end
			-- A cell a sprite holds is the sprite's, unless a surface drawn
			-- since covers more of it.
			if covered == 0 or sprite >= covered then
				continue
			end
			local mean = { sum[1] / covered, sum[2] / covered, sum[3] / covered }
			local coverage = covered / per
			if ascii > 0 then
				-- The classic look: a glyph as dense as the brightness, thinned
				-- by coverage, in ink that keeps the hue.
				local brightness = (0.299 * mean[1] + 0.587 * mean[2] + 0.114 * mean[3]) / 255
				local level = math.min(
					#RAMP - 1,
					math.round(math.pow(brightness, 0.6) * coverage * (#RAMP - 1))
				)
				local back: Color.Color? = nil
				if coverage >= 0.5 then
					back = Color.pack(mean[1] * 0.18, mean[2] * 0.18, mean[3] * 0.18)
				end
				local lifted = lift(mean)
				put(col, row, string.sub(RAMP, math.max(2, level + 1), math.max(2, level + 1)), Color.pack(lifted[1], lifted[2], lifted[3]), back)
				continue
			end
			local qMean: { { number }? } = {}
			local onMask = 0
			for q = 0, 3 do
				local n = qCount[q + 1]
				if n > 0 then
					qMean[q + 1] = { qSum[q + 1][1] / n, qSum[q + 1][2] / n, qSum[q + 1][3] / n }
					onMask = bit32.bor(onMask, bit32.lshift(1, q))
				else
					qMean[q + 1] = nil
				end
			end
			-- The split of the covered quarters into two color groups that
			-- keeps each group most alike.
			local best = onMask
			local bestCost = math.huge
			local mask = 1
			while mask <= onMask do
				if bit32.band(mask, onMask) == mask then
					local a = groupMean(qMean, mask)
					local b = groupMean(qMean, bit32.band(onMask, bit32.bnot(mask)))
					local cost = 0
					for q = 0, 3 do
						local c = qMean[q + 1]
						if c then
							local g = if bit32.band(mask, bit32.lshift(1, q)) ~= 0 then a else b
							if g then
								cost += dist(c, g)
							end
						end
					end
					if cost < bestCost - 1e-9 then
						bestCost = cost
						best = mask
					end
				end
				mask += 1
			end
			local fgColor = groupMean(qMean, best) or mean
			local rest = bit32.band(onMask, bit32.bnot(best))
			local bg = groupMean(qMean, rest)
			if onMask == 15 and (best == 15 or (bg ~= nil and dist(fgColor, bg) < ALIKE)) then
				-- Four quarters of much the same color: a solid cell.
				put(col, row, ' ', Color.pack(mean[1], mean[2], mean[3]), Color.pack(mean[1], mean[2], mean[3]))
			elseif best == 15 then
				-- Four quarters of one color: a solid cell.
				put(col, row, ' ', Color.pack(fgColor[1], fgColor[2], fgColor[3]), Color.pack(fgColor[1], fgColor[2], fgColor[3]))
			elseif bg ~= nil and bitCount(rest) > 4 - bitCount(onMask) then
				-- The second group covers more than the uncovered part: two colors.
				put(
					col,
					row,
					QUARTERS[best + 1] or '█',
					Color.pack(fgColor[1], fgColor[2], fgColor[3]),
					Color.pack(bg[1], bg[2], bg[3])
				)
			else
				put(col, row, QUARTERS[best + 1] or '█', Color.pack(fgColor[1], fgColor[2], fgColor[3]), nil)
			end
		end
	end
end

-- ---------------------------------------------------------------- shapes

local function quad(faces: { number }, a: number, b: number, c: number, d: number)
	table.insert(faces, a)
	table.insert(faces, b)
	table.insert(faces, c)
	table.insert(faces, a)
	table.insert(faces, c)
	table.insert(faces, d)
end

-- A box centered on the origin.
local function box(w: number, h: number, d: number): Mesh
	local x = w / 2
	local y = h / 2
	local z = d / 2
	local verts = {
		-x, -y, -z, x, -y, -z, x, y, -z, -x, y, -z,
		-x, -y, z, x, -y, z, x, y, z, -x, y, z,
	}
	local faces: { number } = {}
	quad(faces, 0, 1, 2, 3)
	quad(faces, 5, 4, 7, 6)
	quad(faces, 4, 0, 3, 7)
	quad(faces, 1, 5, 6, 2)
	quad(faces, 3, 2, 6, 7)
	quad(faces, 4, 5, 1, 0)

	return { verts = verts, faces = faces }
end

-- A sphere of latitude rings and longitude segments.
local function sphere(r: number, segments: number?): Mesh
	local seg = math.max(3, math.min(48, math.round(segments or 12)))
	local rings = math.max(2, math.round(seg / 2))
	local verts: { number } = {}
	local faces: { number } = {}
	for i = 0, rings do
		local phi = (i / rings) * math.pi
		for j = 0, seg - 1 do
			local theta = (j / seg) * math.pi * 2
			table.insert(verts, r * math.sin(phi) * math.cos(theta))
			table.insert(verts, r * math.cos(phi))
			table.insert(verts, r * math.sin(phi) * math.sin(theta))
		end
	end
	for i = 0, rings - 1 do
		for j = 0, seg - 1 do
			local a = i * seg + j
			local b = i * seg + (j + 1) % seg
			local c = (i + 1) * seg + (j + 1) % seg
			local d = (i + 1) * seg + j
			if i > 0 then
				table.insert(faces, a)
				table.insert(faces, b)
				table.insert(faces, c)
			end
			if i < rings - 1 then
				table.insert(faces, a)
				table.insert(faces, c)
				table.insert(faces, d)
			end
		end
	end

	return { verts = verts, faces = faces }
end

-- A cylinder (or a cone when the top radius is 0) standing on the origin.
local function cylinder(rBottom: number, rTop: number, h: number, segments: number?): Mesh
	local seg = math.max(3, math.min(48, math.round(segments or 12)))
	local verts: { number } = {}
	local faces: { number } = {}
	for j = 0, seg - 1 do
		local theta = (j / seg) * math.pi * 2
		table.insert(verts, rBottom * math.cos(theta))
		table.insert(verts, 0)
		table.insert(verts, rBottom * math.sin(theta))
		table.insert(verts, rTop * math.cos(theta))
		table.insert(verts, h)
		table.insert(verts, rTop * math.sin(theta))
	end
	-- The centers of the two caps.
	local cb = seg * 2
	local ct = seg * 2 + 1
	table.insert(verts, 0)
	table.insert(verts, 0)
	table.insert(verts, 0)
	table.insert(verts, 0)
	table.insert(verts, h)
	table.insert(verts, 0)
	for j = 0, seg - 1 do
		local a = j * 2
		local b = ((j + 1) % seg) * 2
		quad(faces, a, b, b + 1, a + 1)
		table.insert(faces, cb)
		table.insert(faces, b)
		table.insert(faces, a)
		if rTop > 0 then
			table.insert(faces, ct)
			table.insert(faces, a + 1)
			table.insert(faces, b + 1)
		end
	end

	return { verts = verts, faces = faces }
end

-- A flat rectangle on the ground (the x-z plane), centered on the origin.
local function plane(w: number, d: number): Mesh
	local x = w / 2
	local z = d / 2

	return {
		verts = { -x, 0, -z, x, 0, -z, x, 0, z, -x, 0, z },
		faces = { 0, 1, 2, 0, 2, 3 },
	}
end

local function createFrame(cols: number, rows: number): Frame
	local w = cols * SX
	local h = rows * SY
	local depth: { number } = {}
	local color: { number } = {}
	local owner: { number } = {}
	for _ = 1, w * h do
		table.insert(depth, math.huge)
		table.insert(color, 0)
		table.insert(color, 0)
		table.insert(color, 0)
		table.insert(owner, 0)
	end

	return {
		cols = cols,
		rows = rows,
		w = w,
		h = h,
		depth = depth,
		color = color,
		owner = owner,
		dirty = table.create(rows * cols, 0),
		triangles = 0,
	}
end

return {
	DEFAULT_CAMERA = DEFAULT_CAMERA,
	DEFAULT_LIGHT = DEFAULT_LIGHT,
	DEFAULT_FOG = DEFAULT_FOG,
	SX = SX,
	SY = SY,
	MOST_TRIANGLES = MOST_TRIANGLES,
	createFrame = createFrame,
	resolve = resolve,
	project = project,
	transformPoint = transformPoint,
	prepare = prepare,
	drawLine = drawLine,
	drawPoint = drawPoint,
	drawMesh = drawMesh,
	claimPixel = claimPixel,
	composite = composite,
	box = box,
	sphere = sphere,
	cylinder = cylinder,
	plane = plane,
}
