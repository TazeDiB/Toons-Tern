--!strict
-- Host half of the toons plugin. Watches shell commands, classifies the
-- agent's phase, picks a scene from the library, and drives the cartoon
-- block's animation. Runs on the plugin's worker thread (2 s budget per
-- call), so it keeps animating while nobody is looking.

local Scene = require('./lib/scene')
local library = require('./lib/scenes')
local Palette = require('./lib/palette')

-- `tern` is injected by the plugin runtime; `tern.d.luau` (written by
-- `tern plugin types`) declares it for type-checking.

local FRAME_MS = 100

-- Keyword to phase; first hit wins.
local RULES: { { phase: string, words: { string } } } = {
	{ phase = 'testing', words = { 'test', 'spec', 'pytest', 'jest', 'vitest' } },
	{ phase = 'building', words = { 'build', 'compile', 'make', 'cargo', 'tsc', 'webpack', 'vite' } },
	{ phase = 'debugging', words = { 'debug', 'gdb', 'lldb', 'fix', 'bisect' } },
	{ phase = 'searching', words = { 'grep', 'rg ', 'search', 'find', 'locate' } },
	{ phase = 'reading', words = { 'cat ', 'read', 'head', 'less', 'view', 'open' } },
	{ phase = 'editing', words = { 'write', 'edit', 'patch', 'apply', 'sed -i' } },
	{ phase = 'git', words = { 'git ', 'commit', 'push', 'pull', 'merge', 'rebase' } },
	{ phase = 'running', words = { 'run', 'exec', 'node ', 'python ', 'serve', 'start' } },
	{ phase = 'building', words = { 'install', 'npm ', 'pip ', 'apt ', 'brew ' } },
	{ phase = 'web', words = { 'curl', 'wget', 'download', 'fetch', 'ssh ', 'ping', 'http', 'socket', 'nc ' } },
	{ phase = 'writing', words = { 'echo ', '>>', 'tee', 'printf' } },
	{ phase = 'git', words = { 'deploy', 'ship', 'release', 'docker', 'kubectl', 'fly ' } },
	{ phase = 'running', words = { 'sleep', 'wait', 'timeout' } },
}

local function classify(line: string): string
	local lower = string.lower(line)
	for _, rule in RULES do
		for _, word in rule.words do
			if string.find(lower, word, 1, true) then
				return rule.phase
			end
		end
	end
	return 'thinking'
end

-- Scenes for a phase, in library order.
local function poolFor(phase: string): { { code: string, concept: string } }
	local pool: { { code: string, concept: string } } = {}
	for _, entry in library do
		if entry.phase == phase and type(entry.code) == 'string' then
			table.insert(pool, { code = entry.code, concept = entry.concept })
		end
	end
	if #pool == 0 then
		for _, entry in library do
			if entry.phase == 'thinking' and type(entry.code) == 'string' then
				table.insert(pool, { code = entry.code, concept = entry.concept })
			end
		end
	end
	if #pool == 0 then
		for _, entry in library do
			if type(entry.code) == 'string' then
				table.insert(pool, { code = entry.code, concept = entry.concept })
			end
		end
	end
	return pool
end

-- Deterministic pick: the same command line keeps the same cartoon; new
-- lines rotate through the phase's scenes.
local function pickFor(phase: string, key: string): { code: string, concept: string }?
	local pool = poolFor(phase)
	if #pool == 0 then
		return nil
	end
	local h = 0
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 2147483647
	end
	return pool[(h % #pool) + 1]
end

-- Latest activity across all panes, shared by every cartoon block on this
-- host. Handlers run on the plugin's single worker, so plain upvalues are
-- safe here.
local activity = { phase = 'thinking', key = '', line = '', busy = false, since = 0 }

tern.on('command_started', function(ev: any)
	activity.phase = classify(tostring(ev.line or ''))
	activity.key = tostring(ev.line or '')
	activity.line = tostring(ev.line or '')
	activity.busy = true
	activity.since = tern.now()
end)

tern.on('command_finished', function(ev: any)
	activity.busy = false
	activity.line = tostring(ev.line or '')
	if tonumber(ev.status) ~= 0 then
		activity.phase = 'debugging'
		activity.key = 'failed-' .. tostring(ev.line or '')
	end
end)

type CartoonState = {
	phase: string,
	key: string,
	concept: string,
	runner: any?,
	pool: { { code: string, concept: string } },
	index: number,
	style: string,
	size: string,
	fps: number,
	paused: boolean,
	libIndex: number,
	t: number,
	frame: string,
	note: string,
	cols: number,
	rows: number,
}

-- What the window half shows in the status line; blocks write it, windows
-- read it, so the 50 ms window budget never touches the scene engine.
-- The frame goes to a file in the plugin's data directory too: it is what
-- a block last drew, readable from outside Tern for checks and debugging.
local function publish(state: CartoonState)
	tern.kv.set('toons', {
		phase = state.phase,
		concept = state.concept,
		busy = activity.busy,
		since = activity.since,
	})
	pcall(function()
		tern.fs.write(
			tern.plugin.data .. '/latest.txt',
			('%s %s %s\n%s'):format(state.phase, state.concept, state.style, state.frame)
		)
	end)
end

local function reloadScene(state: CartoonState, phase: string, key: string)
	local size = Palette.sizeOf(state.size)
	state.cols, state.rows = size.cols, size.rows
	local chosen = pickFor(phase, key)
	if not chosen then
		state.runner = nil
		state.note = 'no scene for phase ' .. phase
		publish(state)
		return
	end
	state.phase, state.key, state.concept = phase, key, chosen.concept
	state.pool = poolFor(phase)
	state.index = 0
	for i, entry in state.pool do
		if entry.concept == chosen.concept then
			state.index = i - 1
			break
		end
	end
	local runner, err = Scene.load(chosen.code, size.cols, size.rows, 'the build')
	state.runner = runner
	state.note = if runner then '' else 'scene broke: ' .. tostring(err)
	publish(state)
end

local function draw(state: CartoonState): string
	if not state.runner then
		return state.note
	end
	local ok, frame = pcall(function()
		return Scene.draw(state.runner, state.t, 1 / state.fps, state.style)
	end)
	if not ok then
		state.runner = nil
		return 'scene broke: ' .. Scene.errmsg(frame)
	end

	return tostring(frame)
end

local cartoon: BlockDef<CartoonState> = {
	init = function(cx: BlockCx, _args: { string }, saved: any): CartoonState
		local state: CartoonState = {
			phase = 'idle',
			key = '',
			concept = '',
			runner = nil,
			pool = {},
			index = 0,
			style = 'color',
			size = 'medium',
			fps = 10,
			paused = false,
			libIndex = 0,
			t = 0,
			frame = '',
			note = 'warming up',
			cols = 64,
			rows = 16,
		}
		if saved then
			state.style = tostring(saved.style or 'color')
			state.size = tostring(saved.size or 'medium')
			state.fps = math.floor(tonumber(saved.fps) or 10)
			state.paused = saved.paused == true
		end
		local size = Palette.sizeOf(state.size)
		state.cols, state.rows = size.cols, size.rows
		reloadScene(state, activity.phase, activity.key)
		state.frame = draw(state)
		publish(state)

		-- One-shot timers re-arm themselves; stop when the pane is gone.
		local function tick()
			for _, pane in tern.pane.list() do
				if pane.pane == cx.pane then
					if not state.paused and activity.key ~= state.key then
						state.t = 0
						reloadScene(state, activity.phase, activity.key)
					end
					if not state.paused then
						state.t += 1 / state.fps
						state.frame = draw(state)
					end
					publish(state)
					cx:render()
					tern.timer(math.floor(1000 / state.fps), tick)
					return
				end
			end
		end
		tern.timer(FRAME_MS, tick)
		return state
	end,

	title = function(state: CartoonState): string?
		if state.concept ~= '' then
			return 'Toons: ' .. state.phase
		end
		return nil
	end,

	view = function(state: CartoonState, _cx: BlockCx): BlockView
		return {
			main = tern.ui.col({ tern.ui.ansi(state.frame) }),
			dock = tern.ui.row({
				tern.ui.text({
					tern.ui.span(if activity.busy then '▶ ' else '· ', if activity.busy then 'accent' else 'muted'),
					tern.ui.span(state.phase, 'strong'),
					tern.ui.span(' · '),
					tern.ui.span(state.concept, 'muted'),
				}),
				tern.ui.text({
					tern.ui.span(
						('n:next s:style z:size p:%s r:resume l:scenes q:quit'):format(if state.paused then 'paused' else 'pause'),
						'muted'
					),
				}),
			}),
		}
	end,

	key = function(state: CartoonState, key: Key, blockCx: BlockCx): boolean?
		local name = key.name
		if name == 'n' then
			if #state.pool > 0 then
				state.index = (state.index + 1) % #state.pool
				local chosen = state.pool[state.index + 1]
				local runner = Scene.load(chosen.code, state.cols, state.rows, 'the build')
				if runner then
					state.runner = runner
					state.concept = chosen.concept
					state.t = 0
				end
			end
		elseif name == 'l' then
			local total = #library
			if total > 0 then
				state.libIndex = (state.libIndex + 1) % total
				local entry = library[state.libIndex + 1]
				if type(entry.code) == 'string' then
					local runner = Scene.load(entry.code, state.cols, state.rows, 'the build')
					if runner then
						state.runner = runner
						state.concept = entry.concept
						state.phase = entry.phase
						state.t = 0
						state.frame = draw(state)
						publish(state)
					end
				end
			end
		elseif name == 's' then
			state.style = if state.style == 'color' then 'pixel' elseif state.style == 'pixel' then 'ascii' else 'color'
			state.frame = draw(state)
		elseif name == 'z' then
			state.size = if state.size == 'small' then 'medium' elseif state.size == 'medium' then 'large' else 'small'
			reloadScene(state, state.phase, state.key)
			state.frame = draw(state)
		elseif name == 'p' then
			state.paused = true
			publish(state)
		elseif name == 'r' then
			state.paused = false
			publish(state)
		elseif name == 'q' then
			blockCx:exit(0)
		else
			return false
		end
		return nil
	end,

	save = function(state: CartoonState): any?
		return { style = state.style, size = state.size, fps = state.fps, paused = state.paused }
	end,
}

tern.block.define('cartoon', cartoon)
