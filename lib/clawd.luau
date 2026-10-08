--!strict
-- Clawd, the mascot, in pixel art: a rounded orange block with two eyes and
-- four little feet, 14 pixels wide and 8 tall at scale 1 (4 rows of cells).
-- Port of claude-toons' hooks/clawd.ts. Colors are packed Color values.

local Color = require('./color')
local Render3d = require('./render3d')

local CLAWD_W = 14
local CLAWD_H = 8

-- The body: B is the body, E an eye (its resting place, 1 wide and 2 tall).
-- The claws are drawn per pose beside it.
local BODY = {
	'..BBBBBBBBBB..',
	'..BBBBBBBBBB..',
	'.BBBEBBBBBEBB.',
	'.BBBEBBBBBEBB.',
	'.BBBBBBBBBBBB.',
	'..BBBBBBBBBB..',
}

local ARMS = { 'up', 'out', 'down' }

-- A claw's pixels for each pose, for the left side (x from the body's left
-- edge at 1, so 0 is just outside it); the right side mirrors them. Each
-- ends at its tip, where things are held.
type ClawShape = { pixels: { { number } }, tip: { number } }
local CLAWS: { [string]: ClawShape } = {
	up = { pixels = { { 0, 1 }, { 0, 2 } }, tip = { 0, 0 } },
	out = { pixels = { { -1, 2 }, { 0, 2 } }, tip = { -2, 2 } },
	down = { pixels = { { 0, 3 }, { 0, 4 } }, tip = { 0, 5 } },
}
local BODY_H = #BODY
-- The feet: two pairs under the body, each foot a pixel wide and two tall.
local FEET = { 3, 5, 8, 10 }
local EYES = { 4, 9 }
local EYE_ROW = 2

local CLAWD_ORANGE = Color.pack(217, 119, 87)
local EYE_DARK = Color.pack(42, 22, 16)

export type Pixel = { x: number, y: number, c: Color.Color }
export type Point = { x: number, y: number }
export type Anchors = {
	w: number,
	h: number,
	top: Point,
	left: Point,
	right: Point,
	feet: Point,
	eyes: { x: number, y: number, w: number },
}
export type ClawdLook = {
	pose: string,
	-- Which walk frame (0 to 3) while walking: a step cycle.
	stride: number,
	-- -1 left, 0 ahead, 1 right.
	facing: number,
	eyes: string,
	-- The eyes shifted from where they rest, in pixels: a glance.
	look: Point,
	isBlinking: boolean,
	color: Color.Color,
	eyeColor: Color.Color,
	-- Whole pixels per pixel: 1 is 14x8, 2 is 28x16.
	scale: number,
	-- Where each claw is held.
	arms: { left: string, right: string },
}

local LOOK: ClawdLook = {
	pose = 'stand',
	stride = 0,
	facing = 0,
	eyes = 'open',
	look = { x = 0, y = 0 },
	isBlinking = false,
	color = CLAWD_ORANGE,
	eyeColor = EYE_DARK,
	scale = 1,
	arms = { left = 'up', right = 'up' },
}

-- The sprite's pixels at scale 1, body first and eyes last so a body pixel
-- never covers an eye that glanced aside.
local function pixelsAtOne(look: ClawdLook): { Pixel }
	local body: { Pixel } = {}
	local eyes: { Pixel } = {}
	-- Sitting, the body rests on the ground where the feet would be.
	local drop = if look.pose == 'sit' then CLAWD_H - BODY_H else 0
	for y = 1, BODY_H do
		local row = BODY[y]
		for x = 1, #row do
			if string.sub(row, x, x) ~= '.' then
				table.insert(body, { x = x - 1, y = y - 1 + drop, c = look.color })
			end
		end
	end
	local claws = CLAWS[look.arms.left] or CLAWS.up
	for _, pair in claws.pixels do
		table.insert(body, { x = pair[1], y = pair[2] + drop, c = look.color })
	end
	claws = CLAWS[look.arms.right] or CLAWS.up
	for _, pair in claws.pixels do
		table.insert(body, { x = CLAWD_W - 1 - pair[1], y = pair[2] + drop, c = look.color })
	end
	local ex = Color.clamp(math.round(look.look.x), -1, 1)
	if ex == 0 then
		ex = look.facing
	end
	local ey = Color.clamp(math.round(look.look.y), -1, 1)
	for _, x0 in EYES do
		local x = x0 + ex
		local y = EYE_ROW + ey + drop
		if look.eyes == 'closed' or look.isBlinking then
			-- A line where the eye's lower pixel was.
			local out = if x0 == EYES[1] then 1 else -1
			table.insert(eyes, { x = x, y = y + 1, c = look.eyeColor })
			table.insert(eyes, { x = x + out, y = y + 1, c = look.eyeColor })
		elseif look.eyes == 'wide' then
			for dx = -1, 0 do
				for dy = 0, 1 do
					table.insert(eyes, { x = x + dx, y = y + dy, c = look.eyeColor })
				end
			end
		else
			table.insert(eyes, { x = x, y = y, c = look.eyeColor })
			table.insert(eyes, { x = x, y = y + 1, c = look.eyeColor })
		end
	end
	local feet: { Pixel } = {}
	if look.pose ~= 'sit' then
		local top = BODY_H
		local ground = CLAWD_H - 1
		local dir = if look.facing ~= 0 then look.facing else 1
		for i = 1, 4 do
			local x0 = FEET[i]
			-- The left pair and the right pair swing against each other.
			local isFront = i <= 2
			local swing = 0
			local isLifted = false
			if look.pose == 'walk' then
				-- A four-beat step: the pairs swing past each other, and the
				-- pair mid-swing is off the ground.
				local beat = ((math.round(look.stride) % 4) + 4) % 4
				if beat == 0 then
					swing = if isFront then 1 else -1
				elseif beat == 2 then
					swing = if isFront then -1 else 1
				else
					isLifted = if beat == 1 then not isFront else isFront
				end
			elseif look.pose == 'jump' then
				isLifted = true
			end
			local x = x0 - 1 + swing * dir
			local last = if isLifted then ground - 1 else ground
			for y = top, last do
				table.insert(feet, { x = x, y = y, c = look.color })
			end
		end
	end
	-- A claw held out reaches a pixel past the box on either side.
	local out: { Pixel } = {}
	local function add(p: Pixel)
		if p.x >= -1 and p.x <= CLAWD_W and p.y >= 0 and p.y < CLAWD_H then
			table.insert(out, p)
		end
	end
	for _, p in body do
		add(p)
	end
	for _, p in feet do
		add(p)
	end
	for _, p in eyes do
		add(p)
	end

	return out
end

-- The sprite's pixels at its scale, each pixel of the small sprite drawn as
-- a block of scale by scale.
local function clawdPixels(look: ClawdLook): { Pixel }
	local scale = math.max(1, math.min(4, math.round(look.scale)))
	local small = pixelsAtOne(look)
	if scale == 1 then
		return small
	end
	local out: { Pixel } = {}
	for _, p in small do
		for dy = 0, scale - 1 do
			for dx = 0, scale - 1 do
				table.insert(out, { x = p.x * scale + dx, y = p.y * scale + dy, c = p.c })
			end
		end
	end

	return out
end

local function clawdAnchors(look: ClawdLook): Anchors
	local s = math.max(1, math.min(4, math.round(look.scale)))
	local drop = if look.pose == 'sit' then CLAWD_H - BODY_H else 0
	-- The claws' tips, where things are held.
	local leftTip = (CLAWS[look.arms.left] or CLAWS.up).tip
	local rightTip = (CLAWS[look.arms.right] or CLAWS.up).tip

	return {
		w = CLAWD_W * s,
		h = CLAWD_H * s,
		top = { x = math.floor((CLAWD_W / 2) * s), y = drop * s - 1 },
		left = { x = leftTip[1] * s - (s - 1), y = (leftTip[2] + drop) * s },
		right = { x = (CLAWD_W - 1 - rightTip[1]) * s + (s - 1), y = (rightTip[2] + drop) * s },
		feet = { x = math.floor((CLAWD_W / 2) * s), y = CLAWD_H * s },
		eyes = { x = EYES[1] * s, y = (EYE_ROW + drop) * s, w = (EYES[2] - EYES[1] + 1) * s },
	}
end

-- Clawd as a solid for 3D scenes, in the sprite's pixel units: x across its
-- middle, y up from its feet, z toward the viewer. The eyes are not part of
-- it: a scene draws them flat on its face, where clawdPoints puts them.
local meshes: { [string]: Render3d.Mesh } = {}
local BODY_DEPTH = 3

local function clawdMesh(look: ClawdLook): Render3d.Mesh
	local drop = if look.pose == 'sit' then CLAWD_H - BODY_H else 0
	local beat = if look.pose == 'walk' then ((math.round(look.stride) % 4) + 4) % 4 else -1
	local key = look.pose .. '|' .. beat .. '|' .. look.arms.left .. '|' .. look.arms.right
	local done = meshes[key]
	if done then
		return done
	end
	local verts: { number } = {}
	local faces: { number } = {}
	local function vert(x: number, y: number, z: number): number
		table.insert(verts, x)
		table.insert(verts, y)
		table.insert(verts, z)

		return math.floor(#verts / 3) - 1
	end
	local function poly(ids: { number })
		for i = 2, #ids - 1 do
			table.insert(faces, ids[1])
			table.insert(faces, ids[i])
			table.insert(faces, ids[i + 1])
		end
	end
	local function block(x0: number, x1: number, y0: number, y1: number, z0: number, z1: number)
		local c = {
			vert(x0, y0, z0), vert(x1, y0, z0), vert(x1, y1, z0), vert(x0, y1, z0),
			vert(x0, y0, z1), vert(x1, y0, z1), vert(x1, y1, z1), vert(x0, y1, z1),
		}
		local quads = {
			{ 0, 1, 2, 3 }, { 5, 4, 7, 6 }, { 4, 0, 3, 7 },
			{ 1, 5, 6, 2 }, { 3, 2, 6, 7 }, { 4, 5, 1, 0 },
		}
		for _, q in quads do
			local ids = {}
			for _, i in q do
				table.insert(ids, c[i + 1])
			end
			poly(ids)
		end
	end
	-- The body: 12 wide, 10 at its top and bottom rows, as a chamfered prism.
	local bottom = CLAWD_H - BODY_H - drop
	local top = CLAWD_H - drop
	local outline = {
		{ -5, bottom }, { 5, bottom }, { 6, bottom + 1 }, { 6, top - 1 },
		{ 5, top }, { -5, top }, { -6, top - 1 }, { -6, bottom + 1 },
	}
	local front: { number } = {}
	local back: { number } = {}
	for _, pair in outline do
		table.insert(front, vert(pair[1], pair[2], BODY_DEPTH))
		table.insert(back, vert(pair[1], pair[2], -BODY_DEPTH))
	end
	poly(front)
	local reversed = {}
	for i = #back, 1, -1 do
		table.insert(reversed, back[i])
	end
	poly(reversed)
	local count = #outline
	for i = 0, count - 1 do
		local j = (i + 1) % count
		poly({ front[i + 1], back[i + 1], back[j + 1], front[j + 1] })
	end
	-- Feet at the corners; walking lifts one diagonal pair, then the other.
	if look.pose ~= 'sit' then
		local corners = {
			{ -2.5, 1.5, 0 }, { 2.5, -1.5, 0 }, { -2.5, -1.5, 1 }, { 2.5, 1.5, 1 },
		}
		for _, corner in corners do
			local fx, fz, diagonal = corner[1], corner[2], corner[3]
			local isLifted = look.pose == 'jump' or (beat == 1 and diagonal == 0) or (beat == 3 and diagonal == 1)
			block(fx - 0.5, fx + 0.5, if isLifted then 1 else 0, bottom, fz - 0.5, fz + 0.5)
		end
	end
	-- The claws, each pixel a block, mirrored for the right side.
	local sides: { { dir: number, arm: string } } = {
		{ dir = -1, arm = look.arms.left },
		{ dir = 1, arm = look.arms.right },
	}
	for _, pair in sides do
		local side, arm = pair.dir, pair.arm
		local claws = CLAWS[arm] or CLAWS.up
		for _, pixel in claws.pixels do
			local px = pixel[1]
			local py = pixel[2]
			local col = if side < 0 then px else CLAWD_W - 1 - px
			block(col - CLAWD_W / 2, col - CLAWD_W / 2 + 1, CLAWD_H - py - 1 - drop, CLAWD_H - py - drop, -0.5, 0.5)
		end
	end
	local mesh = { verts = verts, faces = faces }
	meshes[key] = mesh

	return mesh
end

-- Where things attach on the solid, in its pixel units (z toward the viewer).
local function clawdPoints(look: ClawdLook)
	local drop = if look.pose == 'sit' then CLAWD_H - BODY_H else 0
	local ex = Color.clamp(math.round(look.look.x), -1, 1)
	if ex == 0 then
		ex = look.facing
	end
	local ey = Color.clamp(math.round(look.look.y), -1, 1)
	local half = CLAWD_W / 2
	local function tipAt(side: number, tip: { number }): { x: number, y: number, z: number }
		local col = if side < 0 then tip[1] else CLAWD_W - 1 - tip[1]
		return {
			x = col + 0.5 - half + (if side < 0 then -0.5 else 0.5),
			y = CLAWD_H - tip[2] - 0.5 - drop,
			z = 0,
		}
	end
	local eyeY = CLAWD_H - EYE_ROW - ey - 1 - drop
	local shut = look.eyes == 'closed' or look.isBlinking
	local kind = if shut then 'shut' elseif look.eyes == 'wide' then 'wide' else 'open'

	return {
		top = { x = 0, y = CLAWD_H - drop, z = 0 },
		left = tipAt(-1, (CLAWS[look.arms.left] or CLAWS.up).tip),
		right = tipAt(1, (CLAWS[look.arms.right] or CLAWS.up).tip),
		feet = { x = 0, y = 0, z = 0 },
		eyes = {
			{ x = EYES[1] + ex - half, y = eyeY, z = BODY_DEPTH, kind = kind },
			{ x = EYES[2] + ex - half, y = eyeY, z = BODY_DEPTH, kind = kind },
		},
		eyeSpan = { x = EYES[1] + ex - half, y = eyeY, z = BODY_DEPTH, w = EYES[2] - EYES[1] + 1 },
	}
end

return {
	CLAWD_W = CLAWD_W,
	CLAWD_H = CLAWD_H,
	ARMS = ARMS,
	CLAWD_ORANGE = CLAWD_ORANGE,
	LOOK = LOOK,
	clawdPixels = clawdPixels,
	clawdAnchors = clawdAnchors,
	clawdMesh = clawdMesh,
	clawdPoints = clawdPoints,
}
