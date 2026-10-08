--!strict
-- End-to-end check: every scene through the real renderer (Raster, Clawd,
-- Render3d), frames at several times, output shape verified.


local COLS, ROWS = 64, 12

local function strip(s: string): string
	-- Drop escape sequences so the frame reads as plain cells.
	local out = {}
	local i = 1
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == '\27' then
			local j = i + 1
			while j <= #s and not string.match(string.sub(s, j, j), '[A-Za-z]') do
				j += 1
			end
			i = j + 1
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

local failures = 0
local sawSay = 0
local saw3d = 0

for index, entry in scenes do
	local runner, err = scene.load(entry.code, COLS, ROWS, 'the build')
	if not runner then
		failures += 1
		print(string.format('FAIL load #%d [%s]: %s', index, entry.phase, tostring(err)))
	else
		local ok = true
		local message = ''
		for step = 0, 5 do
			local t = step * 0.37
			local dt = 0.037
			local callOk, frame = pcall(scene.draw, runner, t, dt)
			if not callOk then
				ok = false
				message = tostring(frame)
				break
			end
			-- encode() ends every row with \n; the frame must cover exactly ROWS.
			local _, newlines = string.gsub(frame, '\n', '')
			if newlines ~= ROWS then
				ok = false
				message = string.format('rows %d expected %d', newlines, ROWS)
				break
			end
		end
		if not ok then
			failures += 1
			print(string.format('FAIL draw #%d [%s / %s]: %s', index, entry.phase, entry.world, message))
		end
		if string.find(entry.code, 'say(', 1, true) then
			sawSay += 1
		end
	end
end

print(string.format('rendered %d scenes x 6 frames, %d failures', #scenes, failures))

-- A few frames for the eye: one with speech, one 3D, one pixel art.
local function show(which: number, at: number)
	local entry = scenes[which]
	local runner = scene.load(entry.code, COLS, ROWS, 'the build')
	if not runner then
		return
	end
	scene.draw(runner, at, 0.037)
	local frame = scene.draw(runner, at + 0.037, 0.037)
	print(string.format('--- #%d %s / %s (%s) at t=%.2f', which, entry.phase, entry.world, entry.style, at + 0.037))
	print(strip(frame))
end

show(1, 2.0)
show(2, 1.0)
show(70, 3.0)

if failures == 0 then
	print('ALL RENDER CHECKS PASSED')
end
