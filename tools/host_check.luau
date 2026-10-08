--!nonstrict
-- Drives the plugin's host half against a mock of the Tern runtime: hooks
-- classify a command, the block renders frames, keys change style and scene.

local handlers = {}
local timers = {}
local blockDef = nil
local renders = 0

local cx = {
	pane = 'p1',
	render = function()
		renders += 1
	end,
	exit = function()
	end,
}

local written = {}
local published = {}
local tern = {
	on = function(name, fn)
		handlers[name] = fn
	end,
	now = function()
		return 1000
	end,
	timer = function(ms, fn)
		table.insert(timers, { ms = ms, fn = fn })
	end,
	pane = {
		list = function()
			return { { pane = 'p1' } }
		end,
	},
	block = {
		define = function(name, def)
			blockDef = def
		end,
	},
	ui = {
		col = function(parts)
			return { kind = 'col', parts = parts }
		end,
		row = function(parts)
			return { kind = 'row', parts = parts }
		end,
		text = function(parts)
			return { kind = 'text', parts = parts }
		end,
		span = function(...)
			return { kind = 'span', parts = { ... } }
		end,
		ansi = function(text)
			return { kind = 'ansi', text = text }
		end,
	},
	plugin = { id = 'toons', name = 'Toons', dir = 'dir', data = 'data' },
	fs = {
		write = function(path, text)
			written[path] = text
		end,
	},
	kv = {
		get = function(key)
			return published[key]
		end,
		set = function(key, value)
			published[key] = value
		end,
	},
}
-- The bundler passes this mock to the host half as its `tern`.

local _host = require('../host')

local failures = 0
local function expect(name, ok, detail)
	if not ok then
		failures += 1
		print(string.format('FAIL %s: %s', name, tostring(detail or '')))
	else
		print('PASS ' .. name)
	end
end

expect('hooks registered', handlers.command_started ~= nil and handlers.command_finished ~= nil)
expect('block defined', blockDef ~= nil)

-- A test command starts the testing phase.
handlers.command_started({ line = 'cargo test --all' })

local state = blockDef.init(cx, nil, nil)
expect('init picks a testing scene', state.phase == 'testing', state.note)
expect('init drew a frame', state.frame ~= '')

local view = blockDef.view(state, cx)
local main = view.main.parts[1]
expect('view has an ansi main', main.kind == 'ansi', main.kind)
expect('frame covers the strip', string.find(main.text, '\27', 1, true) ~= nil)

local before = state.frame
local painted = renders
timers[1].fn()
expect('ticks advance time', state.t > 0, state.t)
expect('ticks repaint', renders > painted, renders)
expect('frame changes as it animates', state.frame ~= before)

-- A new command switches the cartoon.
handlers.command_started({ line = 'git commit -m ship' })
timers[1].fn()
expect('new command reloads the scene', state.phase == 'git', state.phase)

-- Keys: next scene, style, size, pause, resume.
local concept = state.concept
blockDef.key(state, { name = 'n' }, cx)
expect('n moves to another scene', state.concept ~= concept, state.concept)

local style = state.style
blockDef.key(state, { name = 's' }, cx)
expect('s cycles the style', state.style ~= style, state.style)

local rows = state.rows
blockDef.key(state, { name = 'z' }, cx)
expect('z changes the size', state.rows ~= rows, state.rows)

blockDef.key(state, { name = 'p' }, cx)
local held = state.frame
timers[1].fn()
expect('p pauses the animation', state.paused and state.frame == held, state.frame)
blockDef.key(state, { name = 'r' }, cx)
timers[1].fn()
expect('r resumes', not state.paused and state.frame ~= held, state.frame)

-- A failed command sends the phase to debugging.
handlers.command_finished({ line = 'cargo test --all', status = 1 })
timers[1].fn()
expect('failure shows debugging', state.phase == 'debugging', state.phase)

-- l walks the whole scene library, not just the phase pool.
local phaseBefore = state.phase
local conceptBefore = state.concept
blockDef.key(state, { name = 'l' }, cx)
expect('l walks the library', state.concept ~= conceptBefore and state.phase ~= phaseBefore, state.phase)

local shown = published.toons
expect(
	'publishes the phase for the status line',
	shown ~= nil and shown.concept == state.concept and shown.phase == state.phase,
	shown and shown.phase
)

local frameFile = written['data/latest.txt']
expect(
	'writes the drawn frame where checks can read it',
	frameFile ~= nil
		and string.find(frameFile, state.phase, 1, true) ~= nil
		and string.find(frameFile, '\27') ~= nil,
	('keys: %s'):format((function()
		local ks = {}
		for k in written do
			table.insert(ks, k)
		end
		return table.concat(ks, ',')
	end)())
)

-- Styles: ascii drops the color codes, color keeps them.
for _ = 1, 3 do
	if state.style == 'ascii' then
		break
	end
	blockDef.key(state, { name = 's' }, cx)
end
expect('ascii drops color codes', state.style == 'ascii' and not string.find(state.frame, '38;', 1, true) and not string.find(state.frame, '48;', 1, true), state.style)
blockDef.key(state, { name = 's' }, cx)
expect('color style keeps color codes', state.style == 'color' and string.find(state.frame, '38;', 1, true) ~= nil, state.style)

-- Settings survive a restart.
local saved = blockDef.save(state)
local restarted = blockDef.init(cx, nil, saved)
expect('save round-trips', restarted.style == state.style and restarted.size == state.size, restarted.style)

expect('title shows the phase', string.find(tostring(blockDef.title(state)), 'Toons:') ~= nil, blockDef.title(state))

if failures > 0 then
	print('ALL CHECKS FAILED: ' .. failures)
else
	print('ALL CHECKS PASSED')
end
