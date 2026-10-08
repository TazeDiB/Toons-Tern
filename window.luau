--!strict
-- Window half of the toons plugin: the palette command that opens the
-- cartoon block, one opened automatically when a window starts, and a
-- status-line segment showing the phase the blocks are drawing.
--
-- Chrome formatters have a 4 ms budget and are cached per input, so the
-- formatter never touches `tern.kv` (a file read): the timer below reads
-- the kv the blocks publish into `cached`, and calls
-- `tern.chrome.refresh()` when it moved.

local BLOCK = 'toons.cartoon'
local ACTION = 'plugin.toons.open'
local TICK_MS = 500

local function openBlock(cx: WindowCx): ()
	-- Focus a cartoon this window already shows, else open one.
	for _, pane in cx.session:panes() do
		if string.find(pane.title, '^Toons:') then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(BLOCK, nil, 'tab') == nil then
		cx:toast('error', 'Toons is unavailable', 'The toons host half is not loaded on this host.')
	end
end

tern.command({
	id = 'open',
	title = 'Toons: open the cartoon block',
	icon = 'puzzle',
	keys = { 'ctrl+alt+shift+h' },
	run = openBlock,
})

-- The latest state a cartoon block published, refreshed by the tick and by
-- command events; the formatter only reads this local table.
local cached: { phase: string, concept: string, busy: boolean }? = nil
local lastSignature = ''

local function refreshCache(): boolean
	local value = tern.kv.get('toons')
	if type(value) ~= 'table' or type(value.phase) ~= 'string' then
		cached = nil
		return false
	end
	local concept = if type(value.concept) == 'string' then value.concept else ''
	local busy = value.busy == true
	cached = { phase = value.phase :: string, concept = concept, busy = busy }
	local signature = string.format('%s\1%s\1%s', concept, if busy then '1' else '0', value.phase)
	if signature == lastSignature then
		return false
	end
	lastSignature = signature
	return true
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local shown = cached
	if shown == nil or shown.phase == 'idle' then
		return nil
	end
	local mark = if shown.busy then '▶' else '·'
	return {
		{
			text = if shown.concept ~= ''
				then string.format('%s %s %s', mark, shown.phase, shown.concept)
				else string.format('%s %s', mark, shown.phase),
			icon = if shown.busy then 'activity' else 'puzzle',
			tone = if shown.busy then 'accent' else 'muted',
			command = ACTION,
		},
	}
end)

-- One re-arming tick while a cartoon is busy, so the segment keeps up with
-- the phase the blocks are drawing.
local tick: TimerHandle? = nil

local function schedule(): ()
	if tick ~= nil then
		return
	end
	tick = tern.timer(TICK_MS, function(_cx: WindowCx?)
		tick = nil
		local moved = refreshCache()
		local busy = cached ~= nil and cached.busy
		if moved then
			tern.chrome.refresh()
		end
		if busy then
			schedule()
		end
	end)
end

local function onCommand(): ()
	if refreshCache() then
		tern.chrome.refresh()
	end
	schedule()
end

tern.on('command_started', function(_ev: CommandStartedEvent, _cx: WindowCx)
	onCommand()
end)

tern.on('command_finished', function(_ev: CommandFinishedEvent, _cx: WindowCx)
	onCommand()
end)

tern.on('window_start', function(cx: WindowCx)
	-- The cartoons are ambient: a window that starts gets one drawing,
	-- unless it already shows a cartoon or the host half is missing.
	openBlock(cx)
	refreshCache()
	schedule()
end)
