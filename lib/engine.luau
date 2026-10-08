-- The language scene code runs in: a JavaScript-like interpreter, ported from
-- hooks/lang.ts. Scenes are code a model writes, so it runs here rather than
-- in any host runtime: it sees only its own values and the functions handed to
-- it, every step spends fuel, and a runaway loop stops the scene, not the
-- terminal.
--
-- What it knows: let/const, functions and arrow functions (closures), if/else,
-- for, for-of, break/continue/return, numbers, strings, arrays, plain objects,
-- object spread and array destructuring, the usual operators (including ++,
-- **, | and >>), Math, and a whitelist of array and string methods.

local Color = require('./color')

local Engine = {}

local NULL = setmetatable({ null = true }, { __tostring = function() return 'null' end })
local NULLMT = getmetatable(NULL)
local ArrayMT = { __index = function(t, k) if k == 'length' then return #t end return nil end }
local ObjectMT = { __index = function() return nil end }
local SignalMT = {}

local function isArray(v)
	return type(v) == 'table' and getmetatable(v) == ArrayMT
end
local function isObj(v)
	return type(v) == 'table' and getmetatable(v) == ObjectMT
end
local function isSignal(v)
	return type(v) == 'table' and getmetatable(v) == SignalMT
end
local function mkArray(t)
	return setmetatable(t, ArrayMT)
end
local function mkObject(t)
	return setmetatable(t, ObjectMT)
end
local function mkReturn(value)
	return setmetatable({ value = value }, SignalMT)
end

local MAX_LENGTH = 100000

local function checkLength(n)
	if n > MAX_LENGTH then
		error({ msg = 'an array or string grew too big' })
	end

end

local fuel = 0
local deadline = math.huge
-- The clock the deadlines read. Tern's plugin runtime may not have `os`, so
-- the host sets its own with Engine.setClock.
local clockFn = if os and os.clock then os.clock else function()
	return 0
end
local function late()
	if clockFn() > deadline then
		error({ msg = 'the scene code took too long to run' })
	end
end
local function burn()
	fuel -= 1
	if fuel < 0 then
		error({ msg = 'the scene code took too long to run' })
	end
	if fuel % 256 == 0 then
		late()
	end
end
local function cost(n)
	fuel -= math.min(n, 2 ^ 31 - 1) // 32
	if fuel < 0 then
		error({ msg = 'the scene code took too long to run' })
	end
	if n >= 1024 then
		late()
	end
end

-- Strings count characters, not bytes: a scene indexes '▀' as one cell.
local function charCount(s)
	local n = 0
	local i = 1
	while i <= #s do
		local b = string.byte(s, i)
		local step = 1
		if b >= 240 then
			step = 4
		elseif b >= 224 then
			step = 3
		elseif b >= 192 then
			step = 2
		end
		i += step
		n += 1
	end

	return n
end
local function charAt(s, i)
	if i < 1 then
		return ''
	end
	local off = 1
	local function stepAt(pos)
		local b = string.byte(s, pos)
		if b >= 240 then
			return 4
		elseif b >= 224 then
			return 3
		elseif b >= 192 then
			return 2
		end

		return 1
	end
	for _ = 1, i - 1 do
		off += stepAt(off)
		if off > #s then
			return ''
		end
	end

	return string.sub(s, off, off + stepAt(off) - 1)
end
local function nextCharEnd(s: string, off: number)
	local b = string.byte(s, off)
	if not b then
		return off + 1
	end
	if b >= 240 then
		return off + 3
	elseif b >= 224 then
		return off + 2
	elseif b >= 192 then
		return off + 1
	end

	return off
end
local function sliceChars(s, a, b)
	local n = charCount(s)
	local from = a < 0 and math.max(n + a, 0) or math.min(a or 0, n)
	local to = b == nil and n or (b < 0 and math.max(n + b, 0) or math.min(b, n))
	if to <= from then
		return ''
	end
	local out = {}
	local off = 1
	for _ = 1, from do
		off = nextCharEnd(s, off) + 1
	end
	for _ = from + 1, to - 1 do
		local last = nextCharEnd(s, off)
		table.insert(out, string.sub(s, off, last))
		off = last + 1
	end

	return table.concat(out)
end
local function findChar(s, sub, from)
	if sub == '' then
		return from == nil and 0 or math.max(math.min(from, charCount(s)), 0)
	end
	local off = 1
	local index = 0
	local skip = from or 0
	while index < skip and off <= #s do
		off = nextCharEnd(s, off) + 1
		index += 1
	end
	local first = string.find(s, sub, off, true)
	if first == nil then
		return -1
	end
	local n = 0
	local at = 1
	while at < first do
		at = nextCharEnd(s, at) + 1
		n += 1
	end

	return n
end

local str, joinAll
local function joinAllAt(a, sep, depth)
	cost(#a)
	local out = {}
	for i = 1, #a do
		if i > 1 then
			table.insert(out, sep)
		end
		local v = a[i]
		if v ~= nil and v ~= NULL then
			table.insert(out, str(v, depth))
		end
		checkLength(#table.concat(out))
	end

	return table.concat(out)
end
joinAll = joinAllAt
function str(v, depth)
	depth = depth or 0
	if isArray(v) then
		if depth > 8 then
			return ''
		end

		return joinAll(v, ',', depth + 1)
	end
	if isObj(v) then
		return '[object Object]'
	end
	if v == NULL then
		return 'null'
	end
	if v == nil then
		return 'undefined'
	end
	if type(v) == 'function' then
		return 'function () {}'
	end

	return tostring(v)
end

local function num(v): number
	local tv = type(v)
	if tv == 'number' then
		return v
	end
	if tv == 'boolean' then
		return v and 1 or 0
	end
	if v == nil then
		return 0 / 0
	end
	if v == NULL then
		return 0
	end
	if tv == 'string' then
		cost(#v)
		local s = string.gsub(v, '^%s+', '')
		s = string.gsub(s, '%s+$', '')
		if s == '' then
			return 0
		end
		local low = string.lower(s)
		local radix = 10
		if string.sub(low, 1, 2) == '0x' then
			radix = 16
			s = string.sub(s, 3)
		elseif string.sub(low, 1, 2) == '0b' then
			radix = 2
			s = string.sub(s, 3)
		elseif string.sub(low, 1, 2) == '0o' then
			radix = 8
			s = string.sub(s, 3)
		end
		if string.find(low, '^inf') == 1 then
			return math.huge
		end
		if string.find(low, '^-inf') == 1 then
			return -math.huge
		end
		if string.find(low, '^nan') == 1 then
			return 0 / 0
		end
		local n = tonumber(s, radix)
		if n == nil or string.find(s, '^[%+%-]?%d*%.?%d*[eE]?[%+%-]?%d*$') ~= 1 and radix == 10 then
			return 0 / 0
		end

		return n
	end
	if tv == 'table' then
		return num(str(v))
	end

	return 0 / 0
end

local function truthy(v)
	if v == nil or v == false or v == NULL then
		return false
	end
	local tv = type(v)
	if tv == 'number' then
		return v ~= 0 and v == v
	end
	if tv == 'string' then
		return #v > 0
	end

	return true
end

local function isPrimitive(v)
	return v == nil or v == NULL or (type(v) ~= 'table' and type(v) ~= 'function')
end

local function operand(v)
	if type(v) == 'string' then
		cost(#v)

		return v
	end
	if isArray(v) or isObj(v) then
		return str(v)
	end

	return v
end

local TWO32 = 4294967296
local function toInt32(v): number
	local n = num(v)
	if n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	n = n > 0 and math.floor(n) or math.ceil(n)
	n = n % TWO32
	if n >= 2147483648 then
		n -= TWO32
	end

	return n
end
local function toUint32(v): number
	local n = toInt32(v)

	return n < 0 and n + TWO32 or n
end

local function jsLoose(x, y)
	if x == nil or x == NULL then
		return y == nil or y == NULL
	end
	if y == nil or y == NULL then
		return false
	end
	local tx = type(x)
	local ty = type(y)
	if tx == 'number' and ty == 'number' then
		return x == y
	end
	if tx == 'string' and ty == 'string' then
		return x == y
	end
	if tx == 'boolean' or ty == 'boolean' then
		return num(x) == num(y)
	end
	if tx == 'string' or ty == 'string' then
		return num(x) == num(y)
	end

	return false
end
local function looseEq(a, b)
	if isPrimitive(a) or isPrimitive(b) then
		return jsLoose(operand(a), operand(b))
	end

	return a == b
end
local function strictEq(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) == 'number' then
		return a == b
	end

	return a == b
end

local OPS = {
	'>>>=', '<<=', '>>=', '**=', '...', '===', '!==',
	'**', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '+=', '-=', '*=', '/=',
	'%=', '&=', '|=', '^=', '<<', '>>', '++', '--', '=>',
	'<', '>', '+', '-', '*', '/', '%', '&', '|', '^', '!', '~', '?', ':', '=',
	'(', ')', '{', '}', '[', ']', ';', ',', '.', '@', '#',
}

local function escapeAt(s, i)
	local c = string.sub(s, i + 1, i + 1)
	if c == 'n' then
		return '\n', i + 2
	elseif c == 'r' then
		return '\r', i + 2
	elseif c == 't' then
		return '\t', i + 2
	elseif c == 'b' then
		return '\b', i + 2
	elseif c == 'f' then
		return '\f', i + 2
	elseif c == 'v' then
		return '\v', i + 2
	elseif c == 'x' then
		local n = tonumber(string.sub(s, i + 2, i + 3), 16)
		if n == nil then
			error({ msg = 'bad escape' })
		end

		return utf8.char(n), i + 4
	elseif c == 'u' then
		if string.sub(s, i + 2, i + 2) == '{' then
			local close = string.find(s, '}', i + 3, true)
			local n = tonumber(string.sub(s, i + 3, close - 1), 16)
			if close == nil or n == nil then
				error({ msg = 'bad escape' })
			end

			return utf8.char(n), close + 1
		end
		local n = tonumber(string.sub(s, i + 2, i + 5), 16)
		if n == nil then
			error({ msg = 'bad escape' })
		end

		return utf8.char(n), i + 6
	end

	return c, i + 2
end

local function lex(src)
	local tokens = {}
	local i = 1
	local function emit(k, v, at)
		table.insert(tokens, { k = k, v = v, at = at })
	end
	while i <= #src do
		local prev = i
		local c = string.sub(src, i, i)
		local n = string.sub(src, i + 1, i + 1)
		if c == '\n' or c == ' ' or c == '\t' or c == '\r' then
			i += 1
		elseif c == '/' and n == '/' then
			while i <= #src and string.sub(src, i, i) ~= '\n' do
				i += 1
			end
		elseif c == '/' and n == '*' then
			local close = string.find(src, '*/', i + 2, true)
			i = (close or #src + 1) + 2
		elseif c == '0' and (n == 'x' or n == 'X') then
			local last = string.find(src, '[^0-9a-fA-F]', i + 2, true) or #src + 1
			emit('num', tonumber(string.sub(src, i + 2, last - 1), 16) or 0, i)
			i = last
		elseif c:match('%d') or (c == '.' and n:match('%d')) then
			local last = i
			while string.sub(src, last, last):match('[%d%.]') do
				last += 1
			end
			if string.sub(src, last, last):match('[eE]') and string.sub(src, last + 1, last + 1):match('[%d%+%-]') then
				last += 1
				if string.sub(src, last, last):match('[%+%-]') then
					last += 1
				end
				while string.sub(src, last, last):match('%d') do
					last += 1
				end
			end
			emit('num', tonumber(string.sub(src, i, last - 1)) or 0, i)
			i = last
		elseif c == '"' or c == "'" or c == '`' then
			local out = {}
			local at = i
			i += 1
			while true do
				local ch = string.sub(src, i, i)
				if ch == '' then
					error({ msg = 'unterminated string' })
				end
				if ch == c then
					i += 1
					break
				end
				if ch == '\\' then
					local e, next = escapeAt(src, i)
					table.insert(out, e)
					i = next
				else
					table.insert(out, ch)
					i += 1
				end
			end
			local value = table.concat(out)
			checkLength(#value)
			emit('str', value, at)
		elseif c:match('[A-Za-z_$]') then
			local last = i
			while string.sub(src, last, last):match('[%w_$]') do
				last += 1
			end
			emit('id', string.sub(src, i, last - 1), i)
			i = last
		else
			local matched
			for _, op in OPS do
				if string.sub(src, i, i + #op - 1) == op then
					matched = op
					break
				end
			end
			if matched == nil then
				error({ msg = 'unexpected character ' .. c })
			end
			emit('op', matched, i)
			i += #matched
		end
		if i == prev then
			error({ msg = 'lex stuck at ' .. prev .. ' near ' .. string.gsub(string.sub(src, prev, prev + 24), '\n', '\\n') })
		end
	end
	emit('eof', '', #src + 1)

	return tokens
end

local function parsePattern(p)
	if p.tok.k == 'id' then
		local name = p.tok.v
		p.next()

		return { t = 'name', n = name }
	end
	if p.tok.k == 'op' and p.tok.v == '[' then
		p.next()
		local parts = {}
		while not (p.tok.k == 'op' and p.tok.v == ']') do
			if p.tok.k == 'op' and p.tok.v == ',' then
				p.next()
				table.insert(parts, nil)
			else
				local pat = parsePattern(p)
				if p.tok.k == 'op' and p.tok.v == '=' then
					p.next()
					pat = { t = 'default', pat = pat, d = p.parseExpr(0) }
				end
				table.insert(parts, pat)
				if p.tok.k == 'op' and p.tok.v == ',' then
					p.next()
				else
					break
				end
			end
		end
		p.eat(']')

		return { t = 'arr', parts = parts }
	end
	if p.tok.k == 'op' and p.tok.v == '{' then
		p.next()
		local parts = {}
		while not (p.tok.k == 'op' and p.tok.v == '}') do
			local key
			if p.tok.k == 'id' then
				key = p.tok.v
				p.next()
			elseif p.tok.k == 'str' then
				key = p.tok.v
				p.next()
			else
				error({ msg = 'bad object pattern' })
			end
			local inner
			if p.tok.k == 'op' and p.tok.v == ':' then
				p.next()
				inner = parsePattern(p)
			else
				inner = { t = 'name', n = key }
			end
			if p.tok.k == 'op' and p.tok.v == '=' then
				p.next()
				inner = { t = 'default', pat = inner, d = p.parseExpr(0) }
			end
			table.insert(parts, { key = key, pat = inner })
			if p.tok.k == 'op' and p.tok.v == ',' then
				p.next()
			else
				break
			end
		end
		p.eat('}')

		return { t = 'obj', parts = parts }
	end

	error({ msg = 'expected a name to bind' })
end

local function parseBlock(p)
	p.eat('{')
	local body = {}
	while not (p.tok.k == 'op' and p.tok.v == '}') do
		if p.tok.k == 'eof' then
			error({ msg = 'unterminated block' })
		end
		table.insert(body, p.parseStatement())
	end
	p.eat('}')

	return body
end

local function parseStatement(p)
	local tok = p.tok
	if tok.k == 'op' and tok.v == ';' then
		p.next()

		return { t = 'empty' }
	end
	if tok.k == 'op' and tok.v == '{' then
		return { t = 'block', body = parseBlock(p) }
	end
	if tok.k == 'id' and (tok.v == 'const' or tok.v == 'let' or tok.v == 'var') then
		local kind = tok.v
		local decls = {}
		repeat
			p.next()
			local pat = parsePattern(p)
			local init
			if p.tok.k == 'op' and p.tok.v == '=' then
				p.next()
				init = p.parseExpr(0)
			else
				if kind == 'const' then
					error({ msg = 'a binding needs a value' })
				end
			end
			table.insert(decls, { pat = pat, init = init })
		until not (p.tok.k == 'op' and p.tok.v == ',')
		if p.tok.k == 'op' and p.tok.v == ';' then
			p.next()
		end

		return { t = 'decl', kind = kind, decls = decls }
	end
	if tok.k == 'id' and tok.v == 'function' then
		p.next()
		local name = p.tok.v
		p.eat('id')
		local params = p.parseParams()
		local body = parseBlock(p)

		return { t = 'fn', name = name, params = params, body = body }
	end
	if tok.k == 'id' and tok.v == 'if' then
		p.next()
		p.eat('(')
		local test = p.parseExpr(0)
		p.eat(')')
		local thenBody = p.parseStatement()
		local elseBody
		if p.tok.k == 'id' and p.tok.v == 'else' then
			p.next()
			elseBody = p.parseStatement()
		end

		return { t = 'if', test = test, thenBranch = thenBody, elseBranch = elseBody }
	end
	if tok.k == 'id' and tok.v == 'for' then
		p.next()
		p.eat('(')
		local head
		if p.tok.k == 'id' and (p.tok.v == 'const' or p.tok.v == 'let' or p.tok.v == 'var') then
			p.next()
			head = parsePattern(p)
			if p.tok.k == 'id' and p.tok.v == 'of' then
				p.next()
				local obj = p.parseExpr(7)
				p.eat(')')

				return { t = 'forof', pat = head, obj = obj, body = p.parseStatement() }
			end
			if p.tok.k == 'op' and p.tok.v == '=' then
				p.next()
				head = { t = 'decl', kind = 'let', decls = { { pat = head, init = p.parseExpr(0) } } }
			else
				error({ msg = 'a for binding needs a value' })
			end
		else
			head = p.parseExpr(0)
			if p.tok.k == 'id' and p.tok.v == 'of' then
				p.next()
				local obj = p.parseExpr(7)
				p.eat(')')

				return { t = 'forof', pat = head, obj = obj, body = p.parseStatement() }
			end
		end
		p.eat(';')
		local test
		if not (p.tok.k == 'op' and p.tok.v == ';') then
			test = p.parseExpr(0)
		end
		p.eat(';')
		local update
		if not (p.tok.k == 'op' and p.tok.v == ')') then
			update = p.parseExpr(0)
		end
		p.eat(')')

		return { t = 'for', init = head, test = test, update = update, body = p.parseStatement() }
	end
	if tok.k == 'id' and tok.v == 'while' then
		p.next()
		p.eat('(')
		local test = p.parseExpr(0)
		p.eat(')')

		return { t = 'while', test = test, body = p.parseStatement() }
	end
	if tok.k == 'id' and tok.v == 'break' then
		p.next()
		if p.tok.k == 'op' and p.tok.v == ';' then
			p.next()
		end

		return { t = 'break' }
	end
	if tok.k == 'id' and tok.v == 'continue' then
		p.next()
		if p.tok.k == 'op' and p.tok.v == ';' then
			p.next()
		end

		return { t = 'continue' }
	end
	if tok.k == 'id' and tok.v == 'return' then
		p.next()
		local arg
		if not (p.tok.k == 'op' and (p.tok.v == ';' or p.tok.v == '}')) and p.tok.k ~= 'eof' then
			arg = p.parseExpr(0)
		end
		if p.tok.k == 'op' and p.tok.v == ';' then
			p.next()
		end

		return { t = 'return', arg = arg }
	end
	local e = p.parseExpr(0)
	if p.tok.k == 'op' and p.tok.v == ';' then
		p.next()
	end

	return { t = 'expr', e = e }
end

local BINARY = {
	['||'] = 1, ['??'] = 1, ['&&'] = 2,
	['|'] = 3, ['^'] = 4, ['&'] = 5,
	['=='] = 6, ['!='] = 6, ['==='] = 6, ['!=='] = 6,
	['<'] = 7, ['>'] = 7, ['<='] = 7, ['>='] = 7,
	['<<'] = 8, ['>>'] = 8, ['>>>'] = 8,
	['+'] = 9, ['-'] = 9,
	['*'] = 10, ['/'] = 10, ['%'] = 10,
}

local function isAssignTarget(e)
	return e.t == 'id' or e.t == 'member' or e.t == 'index' or e.t == 'arr' or e.t == 'obj'
end

local function parseParams(p)
	local params = {}
	if p.tok.k == 'op' and p.tok.v == '(' then
		p.next()
		while not (p.tok.k == 'op' and p.tok.v == ')') do
			table.insert(params, parsePattern(p))
			if p.tok.k == 'op' and p.tok.v == ',' then
				p.next()
			else
				break
			end
		end
		p.eat(')')
	else
		table.insert(params, parsePattern(p))
	end

	return params
end
local function looksLikeArrow(p)
	if p.tok.k == 'id' then
		local after = p.tokens[p.index + 1]

		return after.k == 'op' and after.v == '=>'
	end
	if not (p.tok.k == 'op' and p.tok.v == '(') then
		return false
	end
	local depth = 0
	local at = p.index
	while at <= #p.tokens do
		local tok = p.tokens[at]
		if tok.k == 'op' then
			if tok.v == '(' then
				depth += 1
			elseif tok.v == ')' then
				depth -= 1
				if depth == 0 then
					local after = p.tokens[at + 1]

					return after ~= nil and after.k == 'op' and after.v == '=>'
				end
			end
		end
		if tok.k == 'eof' then
			return false
		end
		at += 1
	end

	return false
end

local function parseArray(p)
	p.eat('[')
	local items = {}
	while not (p.tok.k == 'op' and p.tok.v == ']') do
		if p.tok.k == 'op' and p.tok.v == ',' then
			p.next()
			table.insert(items, nil)
		else
			local e = p.parseExpr(0)
			if e.t == 'spread' then
				e.hole = true
			end
			table.insert(items, e)
			if p.tok.k == 'op' and p.tok.v == ',' then
				p.next()
			else
				break
			end
		end
	end
	p.eat(']')

	return { t = 'arr', items = items }
end
local function parseObject(p)
	p.eat('{')
	local props = {}
	while not (p.tok.k == 'op' and p.tok.v == '}') do
		if p.tok.k == 'op' and p.tok.v == '...' then
			p.next()
			table.insert(props, { kind = 'sp', e = p.parseExpr(0) })
		else
			local key
			if p.tok.k == 'id' or p.tok.k == 'str' or p.tok.k == 'num' then
				key = tostring(p.tok.v)
				p.next()
			else
				error({ msg = 'bad object key' })
			end
			if p.tok.k == 'op' and p.tok.v == ':' then
				p.next()
				table.insert(props, { kind = 'kv', key = key, v = p.parseExpr(0) })
			elseif p.tok.k == 'op' and p.tok.v == '(' then
				local params = parseParams(p)
				local body = parseBlock(p)
				table.insert(props, { kind = 'fn', key = key, params = params, body = body })
			else
				table.insert(props, { kind = 'kv', key = key, v = { t = 'id', n = key } })
			end
		end
		if p.tok.k == 'op' and p.tok.v == ',' then
			p.next()
		else
			break
		end
	end
	p.eat('}')

	return { t = 'obj', props = props }
end
local function parsePrimary(p)
	local tok = p.tok
	if tok.k == 'num' then
		p.next()

		return { t = 'num', v = tok.v }
	end
	if tok.k == 'str' then
		p.next()

		return { t = 'str', v = tok.v }
	end
	if tok.k == 'id' then
		if tok.v == 'true' then
			p.next()

			return { t = 'bool', v = true }
		end
		if tok.v == 'false' then
			p.next()

			return { t = 'bool', v = false }
		end
		if tok.v == 'null' then
			p.next()

			return { t = 'null' }
		end
		if tok.v == 'undefined' then
			p.next()

			return { t = 'undef' }
		end
		if tok.v == 'function' then
			p.next()
			local name
			if p.tok.k == 'id' then
				name = p.tok.v
				p.next()
			end
			local params = parseParams(p)

			return { t = 'fnexpr', name = name, params = params, body = parseBlock(p) }
		end
		if looksLikeArrow(p) then
			local params = parseParams(p)
			p.eat('=>')
			if p.tok.k == 'op' and p.tok.v == '{' then
				return { t = 'arrow', params = params, body = parseBlock(p) }
			end

			return { t = 'arrow', params = params, body = { t = 'expr', e = p.parseExpr(0) }, expr = true }
		end
		local name = tok.v
		p.next()

		return { t = 'id', n = name }
	end
	if tok.k == 'op' and tok.v == '(' then
		if looksLikeArrow(p) then
			local params = parseParams(p)
			p.eat('=>')
			if p.tok.k == 'op' and p.tok.v == '{' then
				return { t = 'arrow', params = params, body = parseBlock(p) }
			end

			return { t = 'arrow', params = params, body = { t = 'expr', e = p.parseExpr(0) }, expr = true }
		end
		p.next()
		local parts = { p.parseExpr(0) }
		while p.tok.k == 'op' and p.tok.v == ',' do
			p.next()
			table.insert(parts, p.parseExpr(0))
		end
		p.eat(')')
		if #parts == 1 then
			return parts[1]
		end

		return { t = 'seq', parts = parts }
	end
	if tok.k == 'op' and tok.v == '[' then
		return parseArray(p)
	end
	if tok.k == 'op' and tok.v == '{' then
		return parseObject(p)
	end
	error({ msg = 'unexpected ' .. (tok.v ~= '' and tostring(tok.v) or 'end of scene') })
end

local COMPOUND = {
	['+='] = '+', ['-='] = '-', ['*='] = '*', ['/='] = '/', ['%='] = '%',
	['&='] = '&', ['|='] = '|', ['^='] = '^', ['<<='] = '<<', ['>>='] = '>>',
	['>>>='] = '>>>', ['**='] = '**',
}
BINARY['**'] = 11

local function parsePostfix(p)
	local e = parsePrimary(p)
	while true do
		local tok = p.tok
		if tok.k ~= 'op' then
			break
		end
		if tok.v == '(' then
			p.next()
			local args = {}
			while not (p.tok.k == 'op' and p.tok.v == ')') do
				local a = p.parseExpr(0)
				if a.t == 'spread' then
					a.hole = true
				end
				table.insert(args, a)
				if p.tok.k == 'op' and p.tok.v == ',' then
					p.next()
				else
					break
				end
			end
			p.eat(')')
			e = { t = 'call', fn = e, args = args }
		elseif tok.v == '.' then
			p.next()
			local name = p.tok.v
			p.eat('id')
			e = { t = 'member', obj = e, name = name }
		elseif tok.v == '[' then
			p.next()
			local key = p.parseExpr(0)
			p.eat(']')
			e = { t = 'index', obj = e, key = key }
		elseif tok.v == '++' or tok.v == '--' then
			p.next()
			e = { t = 'update', op = tok.v, e = e, pre = false }
		else
			break
		end
	end

	return e
end
local function parseUnary(p)
	local tok = p.tok
	if tok.k == 'op' then
		if tok.v == '!' or tok.v == '-' or tok.v == '+' or tok.v == '~' then
			p.next()

			return { t = 'unop', op = tok.v, e = parseUnary(p) }
		end
		if tok.v == '...' then
			p.next()

			return { t = 'spread', e = p.parseExpr(0) }
		end
		if tok.v == '++' or tok.v == '--' then
			p.next()

			return { t = 'update', op = tok.v, e = parseUnary(p), pre = true }
		end
	end

	return parsePostfix(p)
end
local function parseExpr(p, min)
	local left = parseUnary(p)
	while true do
		local tok = p.tok
		if tok.k ~= 'op' then
			break
		end
		local op = tok.v
		if min <= 0 and op == '?' then
			p.next()
			local a = p.parseExpr(0)
			p.eat(':')
			left = { t = 'cond', test = left, a = a, b = p.parseExpr(0) }
			continue
		end
		if min <= 0 and op == '=' and isAssignTarget(left) then
			p.next()
			left = { t = 'assign', op = '=', target = left, v = p.parseExpr(0) }
			continue
		end
		if min <= 0 and COMPOUND[op] ~= nil and isAssignTarget(left) then
			p.next()
			left = { t = 'assign', op = COMPOUND[op], target = left, v = p.parseExpr(0) }
			continue
		end
		local prec = BINARY[op]
		if prec == nil or prec < min then
			break
		end
		p.next()
		local right
		if op == '**' then
			right = parseExpr(p, 11)
		else
			right = parseExpr(p, prec + 1)
		end
		left = { t = 'binop', op = op, a = left, b = right }
	end

	return left
end

local function parseProgram(src)
	local tokens = lex(src)
	local p = { tokens = tokens, index = 1, tok = tokens[1] }
	function p.next()
		p.index += 1
		p.tok = p.tokens[p.index] or { k = 'eof', v = '', at = #src + 1 }
	end
	function p.eat(want)
		local tok = p.tok
		if (tok.k == 'op' and tok.v == want) or tok.k == want then
			p.next()
		else
			error({ msg = 'expected ' .. want })
		end
	end
	p.parseExpr = function(min)
		return parseExpr(p, min)
	end
	p.parseStatement = function()
		return parseStatement(p)
	end
	p.parseParams = function()
		return parseParams(p)
	end
	local body = {}
	while p.tok.k ~= 'eof' do
		table.insert(body, p.parseStatement())
	end

	return body
end

local rootScope

local function newScope(parent, isFunction)
	return { vars = {}, has = {}, consts = {}, parent = parent, isFunction = isFunction }
end
local function declare(s, name, value, isConst)
	s.vars[name] = value
	s.has[name] = true
	if isConst then
		s.consts[name] = true
	end
end
local function lookup(s, name)
	local cur = s
	while cur do
		if cur.has[name] then
			return cur.vars[name]
		end
		cur = cur.parent
	end

	return nil
end
local function assignTo(s, name, value)
	local cur = s
	while cur do
		if cur.has[name] then
			if cur.consts[name] then
				error({ msg = 'cannot assign to ' .. name })
			end
			cur.vars[name] = value

			return
		end
		cur = cur.parent
	end
	declare(rootScope, name, value, false)
end

local eval, exec, execBody, bindPattern, callValue, get, set, callMethod

local function mkSignal(kind, value)
	return setmetatable({ kind = kind, value = value }, SignalMT)
end

function bindPattern(pat, value, scope, isConst)
	if pat.t == 'name' then
		declare(scope, pat.n, value, isConst)
		return
	end
	if pat.t == 'default' then
		if value == nil then
			value = eval(pat.d, scope)
		end
		bindPattern(pat.pat, value, scope, isConst)

		return
	end
	if pat.t == 'arr' then
		if value == nil or value == NULL then
			error({ msg = 'cannot destructure ' .. str(value) })
		end
		if type(value) == 'string' then
			value = mkArray({})
			for i = 1, charCount(value) do
				table.insert(value, charAt(value, i - 1))
			end
		end
		if not isArray(value) then
			error({ msg = 'cannot destructure this value' })
		end
		for i, part in pat.parts do
			if part ~= nil then
				bindPattern(part, value[i], scope, isConst)
			end
		end

		return
	end
	if pat.t == 'obj' then
		if value == nil or value == NULL then
			error({ msg = 'cannot destructure ' .. str(value) })
		end
		for _, part in pat.parts do
			bindPattern(part.pat, get(value, part.key), scope, isConst)
		end

		return
	end
	error({ msg = 'bad pattern' })
end

local function makeFunction(params, body, scope, name, isArrow)
	local f
	f = function(...)
		burn()
		local s = newScope(scope, true)
		if name then
			s.vars[name] = f
			s.has[name] = true
		end
		local args = {}
		local count = select('#', ...)
		for i = 1, count do
			args[i] = select(i, ...)
		end
		for i, pat in params do
			if pat.t == 'default' and args[i] == nil then
				args[i] = eval(pat.d, s)
			end
		end
		for i, pat in params do
			bindPattern(pat, args[i], s)
		end
		local signal = execBody(body, s)
		if isSignal(signal) then
			return signal.value
		end

		return nil
	end

	return f
end

function execBody(body, scope)
	for _, stmt in body do
		local signal = exec(stmt, scope)
		if signal ~= nil then
			return signal
		end
	end

	return nil
end
local function hoist(body, scope)
	for _, stmt in body do
		if stmt.t == 'fn' then
			local f = makeFunction(stmt.params, stmt.body, scope, stmt.name, false)
			declare(scope, stmt.name, f, false)
		end
	end
end

function exec(stmt, scope)
	local t = stmt.t
	if t == 'empty' then
		return nil
	end
	if t == 'decl' then
		burn()
		local isConst = stmt.kind == 'const'
		for _, d in stmt.decls do
			local value = if d.init then eval(d.init, scope) else nil
			bindPattern(d.pat, value, scope, isConst)
		end

		return nil
	end
	if t == 'fn' then
		return nil
	end
	if t == 'expr' then
		eval(stmt.e, scope)

		return nil
	end
	if t == 'block' then
		local s = newScope(scope, false)
		hoist(stmt.body, s)

		return execBody(stmt.body, s)
	end
	if t == 'if' then
		burn()
		if truthy(eval(stmt.test, scope)) then
			return exec(stmt.thenBranch, scope)
		end
		if stmt.elseBranch then
			return exec(stmt.elseBranch, scope)
		end

		return nil
	end
	if t == 'break' then
		return mkSignal('break')
	end
	if t == 'continue' then
		return mkSignal('continue')
	end
	if t == 'return' then
		return mkSignal('return', stmt.arg and eval(stmt.arg, scope) or nil)
	end
	if t == 'while' then
		local turns = 0
		while truthy(eval(stmt.test, scope)) do
			turns += 1
			if turns > 400000 then
				error({ msg = 'runaway loop' })
			end
			burn()
			local signal = exec(stmt.body, scope)
			if isSignal(signal) then
				if signal.kind == 'break' then
					break
				end
				if signal.kind == 'return' then
					return signal
				end
			end
		end

		return nil
	end
	if t == 'for' then
		local outer = newScope(scope, false)
		if stmt.init then
			if stmt.init.t == 'decl' then
				exec(stmt.init, outer)
			else
				eval(stmt.init, outer)
			end
		end
		local isPerTurn = stmt.init ~= nil and stmt.init.t == 'decl' and stmt.init.kind ~= 'var'
		local turns = 0
		while true do
			turns += 1
			if turns > 400000 then
				error({ msg = 'runaway loop' })
			end
			burn()
			if stmt.test and not truthy(eval(stmt.test, outer)) then
				break
			end
			local signal = exec(stmt.body, newScope(outer, false))
			if isSignal(signal) then
				if signal.kind == 'break' then
					break
				end
				if signal.kind == 'return' then
					return signal
				end
			end
			if isPerTurn then
				local copy = newScope(scope, false)
				for k, v in outer.vars do
					copy.vars[k] = v
					copy.has[k] = true
				end
				for k in outer.consts do
					copy.consts[k] = true
				end
				outer = copy
			end
			if stmt.update then
				eval(stmt.update, outer)
			end
		end

		return nil
	end
	if t == 'forof' then
		local obj = eval(stmt.obj, scope)
		local outer = newScope(scope, false)
		local function step(value)
			burn()
			local s = newScope(outer, false)
			bindPattern(stmt.pat, value, s, false)

			return exec(stmt.body, s)
		end
		if isArray(obj) then
			for i = 1, #obj do
				local signal = step(obj[i])
				if isSignal(signal) then
					if signal.kind == 'break' then
						break
					end
					if signal.kind == 'return' then
						return signal
					end
				end
			end
		elseif type(obj) == 'string' then
			for i = 1, charCount(obj) do
				local signal = step(charAt(obj, i - 1))
				if isSignal(signal) then
					if signal.kind == 'break' then
						break
					end
					if signal.kind == 'return' then
						return signal
					end
				end
			end
		else
			error({ msg = 'cannot loop over ' .. str(obj) })
		end

		return nil
	end
	error({ msg = 'unsupported statement' })
end

function callValue(f, args)
	local tf = type(f)
	if tf == 'function' or tf == 'table' then
		burn()
		cost(#args)

		return f(table.unpack(args))
	end
	error({ msg = str(f) .. ' is not a function' })
end

local function assignTarget(target, value, scope)
	local t = target.t
	if t == 'id' then
		assignTo(scope, target.n, value)
	elseif t == 'member' then
		set(eval(target.obj, scope), target.name, value)
	elseif t == 'index' then
		set(eval(target.obj, scope), eval(target.key, scope), value)
	elseif t == 'arr' or t == 'obj' then
		bindPattern(target, value, scope, false)
	else
		error({ msg = 'cannot assign to this' })
	end

	return value
end

local function binop(op, a, b)
	if op == '&&' then
		return truthy(a) and b or a
	end
	if op == '||' then
		return truthy(a) and a or b
	end
	if op == '??' then
		return (a == nil or a == NULL) and b or a
	end
	if op == '==' then
		return looseEq(a, b)
	end
	if op == '!=' then
		return not looseEq(a, b)
	end
	if op == '===' then
		return strictEq(a, b)
	end
	if op == '!==' then
		return not strictEq(a, b)
	end
	local oa = operand(a)
	local ob = operand(b)
	if op == '+' then
		if type(oa) == 'number' and type(ob) == 'number' then
			return oa + ob
		end
		if isPrimitive(oa) and isPrimitive(ob) then
			if type(oa) == 'string' or type(ob) == 'string' then
				local out = str(oa) .. str(ob)
				checkLength(#out)

				return out
			end
			local out = num(oa) + num(ob)

			return out
		end
		local out = str(oa) .. str(ob)
		checkLength(#out)

		return out
	end
	if op == '-' then
		return num(oa) - num(ob)
	end
	if op == '*' then
		return num(oa) * num(ob)
	end
	if op == '/' then
		return num(oa) / num(ob)
	end
	if op == '%' then
		return math.fmod(num(oa), num(ob))
	end
	if op == '**' then
		return num(oa) ^ num(ob)
	end
	if op == '<' or op == '>' or op == '<=' or op == '>=' then
		if type(oa) == 'string' and type(ob) == 'string' then
			if op == '<' then
				return oa < ob
			end
			if op == '>' then
				return oa > ob
			end
			if op == '<=' then
				return oa <= ob
			end

			return oa >= ob
		end
		local na = num(oa)
		local nb = num(ob)
		if na ~= na or nb ~= nb then
			return false
		end
		if op == '<' then
			return na < nb
		end
		if op == '>' then
			return na > nb
		end
		if op == '<=' then
			return na <= nb
		end

		return na >= nb
	end
	if op == '&' then
		return bit32.band(toInt32(oa), toInt32(ob))
	end
	if op == '|' then
		return bit32.bor(toInt32(oa), toInt32(ob))
	end
	if op == '^' then
		return bit32.bxor(toInt32(oa), toInt32(ob))
	end
	if op == '<<' then
		return bit32.lshift(toUint32(oa), toUint32(ob) % 32)
	end
	if op == '>>' then
		return bit32.arshift(toUint32(oa), toUint32(ob) % 32)
	end
	if op == '>>>' then
		return bit32.rshift(toUint32(oa), toUint32(ob) % 32)
	end
	error({ msg = 'unsupported operator ' .. op })
end

function eval(e, scope)
	local t = e.t
	if t == 'num' then
		return e.v
	end
	if t == 'str' then
		cost(#e.v)

		return e.v
	end
	if t == 'bool' then
		return e.v
	end
	if t == 'null' then
		return NULL
	end
	if t == 'undef' then
		return nil
	end
	if t == 'id' then

		return lookup(scope, e.n)
	end
	if t == 'arr' then
		local out = mkArray({})
		for _, item in e.items do
			if item == nil then
				continue
			end
			if item.t == 'spread' then
				local v = eval(item.e, scope)
				if isArray(v) then
					for i = 1, #v do
						table.insert(out, v[i])
					end
				elseif type(v) == 'string' then
					for i = 1, charCount(v) do
						table.insert(out, charAt(v, i - 1))
					end
				else
					error({ msg = 'cannot spread ' .. str(v) })
				end
				checkLength(#out)
			else
				table.insert(out, (eval(item, scope)))
				checkLength(#out)
			end
		end

		return out
	end
	if t == 'obj' then
		local out = mkObject({})
		for _, prop in e.props do
			if prop.kind == 'sp' then
				local v = eval(prop.e, scope)
				if isObj(v) or isArray(v) then
					for k, val in pairs(v) do
						if type(k) == 'number' then
							out[tostring(k)] = val
						else
							out[tostring(k)] = val
						end
					end
				elseif type(v) == 'string' then
					for i = 1, charCount(v) do
						out[tostring(i - 1)] = charAt(v, i - 1)
					end
				end
			elseif prop.kind == 'fn' then
				out[prop.key] = makeFunction(prop.params, prop.body, scope, prop.key, false)
			else
				out[prop.key] = eval(prop.v, scope)
			end
		end

		return out
	end
	if t == 'seq' then
		local last
		for _, part in e.parts do
			last = eval(part, scope)
		end

		return last
	end
	if t == 'unop' then
		local v = eval(e.e, scope)
		if e.op == '!' then
			return not truthy(v)
		end
		if e.op == '-' then
			return -num(v)
		end
		if e.op == '+' then
			return num(v)
		end

		return bit32.bnot(toInt32(v))
	end
	if t == 'update' then
		local old = num(eval(e.e, scope))
		local new = e.op == '++' and old + 1 or old - 1
		assignTarget(e.e, new, scope)

		return e.pre and new or old
	end
	if t == 'binop' then
		if e.op == '&&' then
			local a = eval(e.a, scope)
			if not truthy(a) then
				return a
			end

			return eval(e.b, scope)
		end
		if e.op == '||' then
			local a = eval(e.a, scope)
			if truthy(a) then
				return a
			end

			return eval(e.b, scope)
		end
		if e.op == '??' then
			local a = eval(e.a, scope)
			if a == nil or a == NULL then
				return eval(e.b, scope)
			end

			return a
		end
		local a = eval(e.a, scope)
		local b = eval(e.b, scope)

		return binop(e.op, a, b)
	end
	if t == 'assign' then
		if e.op == '=' then
			return assignTarget(e.target, eval(e.v, scope), scope)
		end
		local old = eval(e.target, scope)

		return assignTarget(e.target, binop(e.op, old, eval(e.v, scope)), scope)
	end
	if t == 'cond' then
		if truthy(eval(e.test, scope)) then
			return eval(e.a, scope)
		end

		return eval(e.b, scope)
	end
	if t == 'call' then
		local fn = eval(e.fn, scope)
		local args = {}
		for _, item in e.args do
			if item.t == 'spread' then
				local v = eval(item.e, scope)
				if isArray(v) then
					for i = 1, #v do
						table.insert(args, v[i])
					end
				else
					error({ msg = 'cannot spread ' .. str(v) })
				end
			else
				table.insert(args, (eval(item, scope)))
			end
		end


		return callValue(fn, args)
	end
	if t == 'member' then
		return get(eval(e.obj, scope), e.name)
	end
	if t == 'index' then
		return get(eval(e.obj, scope), eval(e.key, scope))
	end
	if t == 'fnexpr' then
		return makeFunction(e.params, e.body, scope, e.name, false)
	end
	if t == 'arrow' then
		local f
		f = function(...)
			burn()
			local s = newScope(scope, true)
			local args = {}
			local count = select('#', ...)
			for i = 1, count do
				args[i] = select(i, ...)
			end
			for i, pat in e.params do
				if pat.t == 'default' and args[i] == nil then
					args[i] = eval(pat.d, s)
				end
			end
			for i, pat in e.params do
				bindPattern(pat, args[i], s)
			end
			if e.expr then
				return eval(e.body.e, s)
			end
			local signal = execBody(e.body, s)
			if isSignal(signal) then
				return signal.value
			end

			return nil
		end

		return f
	end
	error({ msg = 'unsupported expression' })
end

local function trunc(n: number): number
	return n > 0 and math.floor(n) or math.ceil(n)
end
local function normIndex(v, len)
	if v == nil then
		return 0
	end
	local n = num(v)
	if n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	n = trunc(n)
	if n < 0 then
		return math.max(len + n, 0)
	end

	return math.min(n, len)
end
local function normEnd(v, len)
	if v == nil then
		return len
	end
	local n = num(v)
	if n ~= n or n == math.huge then
		return len
	end
	if n == -math.huge then
		return 0
	end
	n = trunc(n)
	if n < 0 then
		return math.max(len + n, 0)
	end

	return math.min(n, len)
end

local ARRAY = {}
function ARRAY.push(a, ...)
	local count = select('#', ...)
	checkLength(#a + count)
	for i = 1, count do
		a[#a + 1] = select(i, ...)
	end

	return #a
end
function ARRAY.pop(a)
	local last = a[#a]
	a[#a] = nil

	return last
end
function ARRAY.shift(a)
	local first = a[1]
	table.remove(a, 1)

	return first
end
function ARRAY.unshift(a, ...)
	local count = select('#', ...)
	checkLength(#a + count)
	table.move(a, 1, #a, count + 1)
	for i = 1, count do
		a[i] = select(i, ...)
	end

	return #a
end
function ARRAY.slice(a, from, to)
	local start = normIndex(from, #a) + 1
	local stop = normEnd(to, #a)
	local out = mkArray({})
	for i = start, stop do
		table.insert(out, a[i])
	end

	return out
end
function ARRAY.splice(a, from, count, ...)
	local start = normIndex(from, #a) + 1
	local removeCount = math.min(count == nil and math.huge or math.max(num(count), 0), #a - start + 1)
	local removed = mkArray({})
	for i = 1, removeCount do
		table.insert(removed, a[start + i - 1])
	end
	local items = {}
	local itemCount = select('#', ...)
	for i = 1, itemCount do
		items[i] = select(i, ...)
	end
	checkLength(#a + itemCount - removeCount)
	local tail = start + removeCount
	local shiftBy = itemCount - removeCount
	if shiftBy > 0 then
		table.move(a, tail, #a, tail + shiftBy)
	end
	for i = 1, itemCount do
		a[start + i - 1] = items[i]
	end
	if shiftBy < 0 then
		for i = #a + 1, #a - shiftBy do
			a[i] = nil
		end
	end

	return removed
end
function ARRAY.concat(a, ...)
	local out = mkArray({})
	for i = 1, #a do
		table.insert(out, a[i])
	end
	local count = select('#', ...)
	for j = 1, count do
		local v = select(j, ...)
		if isArray(v) then
			for i = 1, #v do
				table.insert(out, v[i])
			end
		else
			table.insert(out, v)
		end
	end
	checkLength(#out)

	return out
end
function ARRAY.indexOf(a, v, from)
	local start = normIndex(from, #a)
	for i = start + 1, #a do
		if strictEq(a[i], v) then
			return i - 1
		end
	end

	return -1
end
function ARRAY.lastIndexOf(a, v, from)
	local stop = from == nil and #a or (normIndex(from, #a) + 1)
	for i = stop, 1, -1 do
		if strictEq(a[i], v) then
			return i - 1
		end
	end

	return -1
end
function ARRAY.includes(a, v)
	for i = 1, #a do
		if looseEq(a[i], v) then
			return true
		end
	end

	return false
end
function ARRAY.join(a, sep)
	return joinAll(a, sep == nil and ',' or str(sep), 0)
end
function ARRAY.reverse(a)
	local i, j = 1, #a
	while i < j do
		a[i], a[j] = a[j], a[i]
		i += 1
		j -= 1
	end

	return a
end
function ARRAY.fill(a, v, from, to)
	local start = normIndex(from, #a) + 1
	local stop = normEnd(to, #a)
	for i = start, stop do
		a[i] = v
	end

	return a
end
function ARRAY.at(a, i)
	local n = num(i)
	if n ~= n then
		return nil
	end
	n = trunc(n)
	if n < 0 then
		return a[#a + n + 1]
	end

	return a[n + 1]
end
function ARRAY.map(a, fn)
	local out = mkArray({})
	for i = 1, #a do
		out[i] = callValue(fn, { a[i], i - 1, a })
		checkLength(#out)
	end

	return out
end
function ARRAY.filter(a, fn)
	local out = mkArray({})
	for i = 1, #a do
		if truthy(callValue(fn, { a[i], i - 1, a })) then
			table.insert(out, a[i])
		end
	end

	return out
end
function ARRAY.forEach(a, fn)
	for i = 1, #a do
		callValue(fn, { a[i], i - 1, a })
	end
end
function ARRAY.some(a, fn)
	for i = 1, #a do
		if truthy(callValue(fn, { a[i], i - 1, a })) then
			return true
		end
	end

	return false
end
function ARRAY.every(a, fn)
	for i = 1, #a do
		if not truthy(callValue(fn, { a[i], i - 1, a })) then
			return false
		end
	end

	return true
end
function ARRAY.find(a, fn)
	for i = 1, #a do
		if truthy(callValue(fn, { a[i], i - 1, a })) then
			return a[i]
		end
	end

	return nil
end
function ARRAY.findIndex(a, fn)
	for i = 1, #a do
		if truthy(callValue(fn, { a[i], i - 1, a })) then
			return i - 1
		end
	end

	return -1
end
function ARRAY.reduce(a, fn, initial)
	local acc = initial
	local from = 1
	if acc == nil then
		if #a == 0 then
			error({ msg = 'reduce of an empty list needs a starting value' })
		end
		acc = a[1]
		from = 2
	end
	for i = from, #a do
		acc = callValue(fn, { acc, a[i], i - 1, a })
	end

	return acc
end
function ARRAY.sort(a, cmp)
	if cmp then
		table.sort(a, function(x, y)
			return num(callValue(cmp, { x, y })) < 0
		end)
	else
		table.sort(a, function(x, y)
			return str(x) < str(y)
		end)
	end

	return a
end
function ARRAY.flat(a, depth)
	local d = depth == nil and 1 or math.max(trunc(num(depth)), 0)
	local out = mkArray({})
	local function add(items, level)
		for i = 1, #items do
			local v = items[i]
			if isArray(v) and level > 0 then
				add(v, level - 1)
			else
				table.insert(out, v)
			end
		end
	end
	add(a, d)
	checkLength(#out)

	return out
end
function ARRAY.keys(a)
	local out = mkArray({})
	for i = 1, #a do
		out[i] = i - 1
	end

	return out
end
function ARRAY.entries(a)
	local out = mkArray({})
	for i = 1, #a do
		out[i] = mkArray({ i - 1, a[i] })
	end

	return out
end

local STRING = {}
function STRING.slice(s, from, to)
	return sliceChars(s, from == nil and 0 or trunc(num(from)), to)
end
function STRING.substring(s, a, b)
	local x = a == nil and 0 or math.max(trunc(num(a)), 0)
	local y = b == nil and charCount(s) or math.max(trunc(num(b)), 0)
	if x > y then
		x, y = y, x
	end

	return sliceChars(s, x, y)
end
function STRING.charAt(s, i)
	return charAt(s, trunc(num(i)))
end
function STRING.charCodeAt(s, i)
	local c = charAt(s, trunc(num(i)))
	if c == '' then
		return 0 / 0
	end

	return utf8.codepoint(c)
end
function STRING.codePointAt(s, i)
	return STRING.charCodeAt(s, i)
end
function STRING.indexOf(s, sub, from)
	return findChar(s, str(sub), from == nil and 0 or trunc(num(from)))
end
function STRING.lastIndexOf(s, sub, from)
	sub = str(sub)
	local stop = from == nil and charCount(s) or math.min(math.max(trunc(num(from)), 0), charCount(s))
	local at = 0
	local found = -1
	while true do
		local pos = findChar(s, sub, at)
		if pos == -1 or pos > stop then
			break
		end
		found = pos
		at = pos + 1
		if sub == '' then
			break
		end
	end

	return found
end
function STRING.includes(s, sub)
	return findChar(s, str(sub), 0) >= 0
end
function STRING.startsWith(s, sub, from)
	sub = str(sub)
	local start = from == nil and 0 or math.max(math.min(trunc(num(from)), charCount(s)), 0)

	return findChar(s, sub, start) == start
end
function STRING.endsWith(s, sub)
	sub = str(sub)

	return sub == '' or string.sub(s, -#sub) == sub
end
function STRING.split(s, sep, limit)
	if sep == nil then
		return mkArray({ s })
	end
	sep = str(sep)
	local out = mkArray({})
	if sep == '' then
		for i = 1, charCount(s) do
			table.insert(out, charAt(s, i - 1))
		end
	else
		local at = 1
		while true do
			local first, last = string.find(s, sep, at, true)
			if first == nil then
				table.insert(out, string.sub(s, at))
				break
			end
			table.insert(out, string.sub(s, at, first - 1))
			at = last + 1
		end
	end
	if limit ~= nil and num(limit) < #out then
		local n = math.max(trunc(num(limit)), 0)
		for i = #out, n + 1, -1 do
			out[i] = nil
		end
	end

	return out
end
STRING['repeat'] = function(s, count)
	local n = trunc(num(count))
	if n < 0 or n ~= n then
		error({ msg = 'cannot repeat a string ' .. tostring(count) .. ' times' })
	end
	checkLength(#s * n)

	return string.rep(s, n)
end
local function pad(s, target, fillWith, atStart)
	local want = trunc(num(target))
	local have = charCount(s)
	if want <= have or want > MAX_LENGTH then
		return s
	end
	local padStr = (fillWith == nil or fillWith == '') and ' ' or str(fillWith)
	local out = {}
	local need = want - have
	local at = 1
	for i = 1, need do
		out[i] = charAt(padStr, (i - 1) % charCount(padStr))
	end
	if atStart then
		return table.concat(out) .. s
	end

	return s .. table.concat(out)
end
function STRING.padStart(s, target, fillWith)
	return pad(s, target, fillWith, true)
end
function STRING.padEnd(s, target, fillWith)
	return pad(s, target, fillWith, false)
end
function STRING.toUpperCase(s)
	return string.upper(s)
end
function STRING.toLowerCase(s)
	return string.lower(s)
end
function STRING.trim(s)
	local out = string.gsub(s, '^%s+', '')

	return string.gsub(out, '%s+$', '')
end
function STRING.replace(s, pattern, replacement)
	local first, last = string.find(s, str(pattern), 1, true)
	if first == nil then
		return s
	end
	local out = string.sub(s, 1, first - 1) .. str(replacement) .. string.sub(s, last + 1)
	checkLength(#out)

	return out
end
function STRING.replaceAll(s, pattern, replacement)
	local out = string.gsub(s, string.gsub(str(pattern), '([%-%+%.%%*%?%(%)%[%]{}%$%^/\\\\])', '%%%1'), str(replacement))
	checkLength(#out)

	return out
end
function STRING.at(s, i)
	return STRING.charAt(s, num(i) < 0 and charCount(s) + trunc(num(i)) or trunc(num(i)))
end

function get(target, key)
	if target == nil or target == NULL then
		error({ msg = 'cannot read "' .. str(key) .. '" of ' .. str(target) })
	end
	local tt = type(target)
	if tt == 'string' then
		if key == 'length' then
			return charCount(target)
		end
		if type(key) == 'number' then
			return charAt(target, trunc(num(key)))
		end
		if type(key) == 'string' then
			local n = tonumber(key)
			if n ~= nil then
				return charAt(target, trunc(n))
			end
			local m = STRING[key]
			if m then
				local bound = target

				return function(...)
					return m(bound, ...)
				end
			end
		end

		return nil
	end
	if tt == 'number' then
		if key == 'toFixed' then
			local n: number = target :: number
			return function(digits)
				local d: number = if digits == nil then 0 else math.max(trunc(num(digits)) :: number, 0)

				return string.format('%.' .. d .. 'f', n)
			end
		end
		if key == 'toString' then
			local n = target

			return function()
				return str(n)
			end
		end

		return nil
	end
	if tt == 'table' then
		if isArray(target) then
			if key == 'length' then
				return #target
			end
			if type(key) == 'number' then
				local n = trunc(key)
				if n >= 0 then
					return target[n + 1]
				end

				return nil
			end
			if type(key) == 'string' then
				local n = tonumber(key)
				if n ~= nil then
					n = trunc(n)
					if n >= 0 then
						return target[n + 1]
					end

					return nil
				end
				local m = ARRAY[key]
				if m then
					local bound = target

					return function(...)
						return m(bound, ...)
					end
				end

				return nil
			end

			return nil
		end

		return target[tostring(key)]
	end

	local mt = getmetatable(target)
	if mt and mt.__index then
		return mt.__index(target, key)
	end

	return nil
end

function set(target, key, value)
	if type(target) == 'table' then
		if isArray(target) then
			if key == 'length' then
				local n = math.max(trunc(num(value)), 0)
				checkLength(n)
				for i = #target + 1, n do
					target[i] = NULL
				end
				for i = n + 1, #target do
					target[i] = nil
				end

				return value
			end
			local index
			if type(key) == 'number' then
				index = trunc(key)
			elseif type(key) == 'string' then
				index = tonumber(key)
			end
			if index ~= nil then
				if index >= 0 then
					checkLength(index + 1)
					target[index + 1] = value
				end

				return value
			end
			error({ msg = 'cannot put "' .. str(key) .. '" on an array' })
		end
		target[tostring(key)] = value

		return value
	end
	error({ msg = 'cannot put a value on ' .. str(target) })
end

local function hash(x)
	local v = math.sin(x * 127.1 + 311.7) * 43758.5453

	return v - math.floor(v)
end
local function smooth(k)
	return k * k * (3 - 2 * k)
end
local function noise(x)
	local i = math.floor(x)

	return hash(i) + (hash(i + 1) - hash(i)) * smooth(x - i)
end
local function noise2(x, y)
	local i = math.floor(x)
	local j = math.floor(y)
	local function at(a, b)
		return hash(a * 57.3 + b * 113.9)
	end
	local u = smooth(x - i)
	local v = smooth(y - j)
	local top = at(i, j) + (at(i + 1, j) - at(i, j)) * u
	local bottom = at(i, j + 1) + (at(i + 1, j + 1) - at(i, j + 1)) * u

	return top + (bottom - top) * v
end
local function builtins()
	local g = {}
	g.Math = mkObject({
		PI = math.pi,
		E = math.exp(1),
		huge = math.huge,
		floor = math.floor,
		ceil = math.ceil,
		round = function(n)
			return n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5)
		end,
		trunc = trunc,
		abs = math.abs,
		min = function(...)
			return math.min(...)
		end,
		max = function(...)
			return math.max(...)
		end,
		pow = function(a, b)
			return a ^ b
		end,
		sqrt = math.sqrt,
		cbrt = function(n)
			return n < 0 and -((-n) ^ (1 / 3)) or n ^ (1 / 3)
		end,
		hypot = function(...)
			local total = 0
			for i = 1, select('#', ...) do
				local v = num(select(i, ...))
				total += v * v
			end

			return math.sqrt(total)
		end,
		sign = function(n)
			if n > 0 then
				return 1
			end
			if n < 0 then
				return -1
			end

			return n
		end,
		sin = math.sin,
		cos = math.cos,
		tan = math.tan,
		asin = math.asin,
		acos = math.acos,
		atan = math.atan,
		atan2 = math.atan2,
		exp = math.exp,
		log = math.log,
		log2 = math.log2,
		log10 = math.log10,
		random = math.random,
	})
	g.Array = setmetatable({
		fromArray = function(v)
			return v
		end,
		toArray = function(v)
			return v
		end,
		from = function(obj, fn)
			local out = mkArray({})
			local len = 0
			if type(obj) == 'string' then
				len = charCount(obj)
				for i = 1, len do
					out[i] = charAt(obj, i - 1)
				end
			elseif isArray(obj) then
				len = #obj
				for i = 1, len do
					out[i] = obj[i]
				end
			else
				len = num(get(obj, 'length') or 0)
				for i = 1, len do
					local v = get(obj, i - 1)
					out[i] = fn ~= nil and callValue(fn, { v, i - 1 }) or v
				end
			end
			checkLength(#out)

			return out
		end,
	}, {
		__call = function(_, ...)
			local out = mkArray({})
			local count = select('#', ...)
			if count == 1 then
				local n = math.max(trunc(num(select(1, ...))), 0)
				checkLength(n)
				-- Array(n) is holes; the engine fills them with null, which
				-- every scene check reads as empty.
				for i = 1, n do
					out[i] = NULL
				end
				return out
			end
			for i = 1, count do
				out[i] = select(i, ...)
			end

			return out
		end,
	})
	g.Number = function(v)
		return num(operand(v))
	end
	g.Boolean = function(v)
		return truthy(v)
	end
	g.Object = mkObject({
		keys = function(o)
			local out = mkArray({})
			for k in pairs(o) do
				table.insert(out, k)
			end

			return out
		end,
		values = function(o)
			local out = mkArray({})
			for _, v in pairs(o) do
				table.insert(out, v)
			end

			return out
		end,
		entries = function(o)
			local out = mkArray({})
			for k, v in pairs(o) do
				table.insert(out, mkArray({ k, v }))
			end

			return out
		end,
		assign = function(...)
			local out = mkObject({})
			for i = 1, select('#', ...) do
				local v = select(i, ...)
				if isObj(v) or isArray(v) then
					for k, val in pairs(v) do
						out[tostring(k)] = val
					end
				end
			end

			return out
		end,
	})
	g.String = setmetatable({}, {
		__call = function(_, v)
			return str(v)
		end,
		__index = function(_, k)
			if k == 'fromCharCode' then
				return function(...)
					local out = {}
					for i = 1, select('#', ...) do
						local n = num(select(i, ...))
						if n ~= n then
							n = 0
						end
						out[i] = utf8.char(math.floor(n) % 0x10FFFF)
					end

					return table.concat(out)
				end
			end

			return nil
		end,
	})
	g.pi = math.pi
	g.sin = math.sin
	g.cos = math.cos
	g.tan = math.tan
	g.abs = math.abs
	g.floor = math.floor
	g.ceil = math.ceil
	g.round = function(n)
		return n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5)
	end
	g.sqrt = math.sqrt
	g.pow = function(a, b)
		return a ^ b
	end
	g.exp = math.exp
	g.sign = function(n)
		if n > 0 then
			return 1
		end
		if n < 0 then
			return -1
		end

		return n
	end
	g.atan2 = math.atan2
	g.hypot = function(...)
		local total = 0
		for i = 1, select('#', ...) do
			local v = num(select(i, ...))
			total += v * v
		end

		return math.sqrt(total)
	end
	g.min = function(...)
		return math.min(...)
	end
	g.max = function(...)
		return math.max(...)
	end
	g.parseInt = function(v, base)
		local s = string.gsub(str(v), '^%s+', '')
		local radix = base == nil and 10 or trunc(num(base))
		if radix == 0 then
			radix = 10
		end
		if radix == 16 then
			s = string.gsub(string.lower(s), '^0x', '')
		end
		local n = tonumber(s, radix)
		if n == nil then
			return 0 / 0
		end

		return trunc(n)
	end
	g.parseFloat = function(v)
		return num(v)
	end
	g.isNaN = function(v)
		return num(v) ~= num(v)
	end
	g.Infinity = math.huge
	g.NaN = 0 / 0
	g.clamp = function(n, lo, hi)
		return math.min(hi or 1, math.max(lo or 0, n))
	end
	g.lerp = function(a, b, k)
		return a + (b - a) * k
	end
	g.smoothstep = function(a, b, v)
		local k = b == a and (v >= b and 1 or 0) or (v - a) / (b - a)

		return smooth(math.min(1, math.max(0, k)))
	end
	g.fract = function(n)
		return n - math.floor(n)
	end
	g.mod = function(a, b)
		if b == 0 then
			return 0
		end

		return math.fmod(math.fmod(a, b) + b, b)
	end
	g.rand = function(v)
		local n = num(v)
		if not truthy(n) then
			n = 0
		end

		return hash(n)
	end
	g.noise = function(v)
		local n = num(v)
		if not truthy(n) then
			n = 0
		end

		return noise(n)
	end
	g.noise2 = function(x, y)
		local a = num(x)
		local b = num(y)
		if not truthy(a) then
			a = 0
		end
		if not truthy(b) then
			b = 0
		end

		return noise2(a, b)
	end
	g.Array = mkObject({
		from = function(source, fn)
			local out = mkArray({})
			local function emit(value, i)
				if value == nil then
					value = NULL
				end
				if fn then
					table.insert(out, callValue(fn, { value, i }))
				else
					table.insert(out, value)
				end
			end
			if type(source) == 'string' then
				for i = 0, charCount(source) - 1 do
					emit(charAt(source, i), i)
				end
			elseif isArray(source) then
				for i = 0, #source - 1 do
					emit(source[i + 1], i)
				end
			elseif type(source) == 'table' then
				local length = source.length or source['length']
				for i = 0, (if length then trunc(num(length)) else 0) - 1 do
					emit(nil, i)
				end
			end

			return out
		end,
	})

	return g
end

local BUILTINS = builtins()

local function declareGlobals(scope, globals)
	for k, v in pairs(BUILTINS) do
		declare(scope, k, v, false)
	end
	if globals then
		for k, v in pairs(globals) do
			declare(scope, k, v, false)
		end
	end
end

function Engine.parse(source: string): ({ body: any }?, string?)
	local ok, body = pcall(parseProgram, source)
	if not ok then
		return nil, body
	end

	return { body = body }
end
function Engine.start(program, globals, budget, ms)
	fuel = budget or 200000
	deadline = clockFn() + (ms or 0.05)
	if program.root == nil then
		program.root = newScope(nil, true)
	end
	declareGlobals(program.root, globals)
	program.scope = newScope(program.root, true)
	rootScope = program.scope
	hoist(program.body, program.scope)
	execBody(program.body, program.scope)
end
function Engine.call(program, name, args, globals, budget, ms)
	fuel = budget or 200000
	deadline = clockFn() + (ms or 0.05)
	if program.scope == nil then
		Engine.start(program, globals, budget, ms)
	end
	-- The names the scene was started with (its drawing functions) stay
	-- visible; only the frame's own values are refreshed.
	declareGlobals(program.root, globals)
	rootScope = program.scope
	local f = lookup(program.scope, name)
	if f == nil then
		error({ msg = 'the scene has no ' .. name .. '() function' })
	end

	return callValue(f, args or {})
end
function Engine.errmsg(e: any?): string
	if type(e) == 'table' then
		return (e :: any).msg or 'the scene failed'
	end

	return tostring(e)
end
function Engine.setClock(fn)
	clockFn = fn
end
function Engine.now()
	return clockFn()
end
function Engine.fuelLeft()
	return fuel
end

return Engine
