-- Chillzone: формат сообщений. Чистые функции без API игры (покрыты tests/).
-- Очистка и нарезка чата, сборка кусков и поля отчёта портированы из Olympus Codec.lua.
--
-- Отчёт:  R1~guild~total~online~leader~leaderOn~leaderDays~leaderClass~leaderLevel~users
--            ~zones~classes~levels~ranks~officers~inact7~inact30~avg10~faction~st
--   zones    "m1453=20,tМёртвые копи=3" (m = uiMapID, t = текст зоны) — только по согласию
--   classes  "WA=4,MA=2" (двухбуквенные коды классов)
--   levels   7 чисел: 1-9, 10-19, ..., 50-59, 60+
--   ranks    "Глава=1,Офицер=3,..." по порядку рангов
--   officers "имя:онлайн:дней:класс:уровень:ранг,..."
--   st       серверное время отчёта, base36
-- Кусок:  C<id>:<i>:<n>:<piece>                (аддон-сообщение не длиннее 255 байт)
-- Привет: H1~<версия>~<флаги>[~<fp>|~0]        (z — зоны, r — реле, fp — сертификат; 0 — без него)
-- Запрос: Q1~
-- Ответ:  Q2~<id>~B|E                        (необязательное начало/окончание ответа, id 1-999999)
-- Чат:    M1~tier~guild~id~class~text          (tier A|C|L, id 0-9999, class — 2 буквы)
-- Реле:   RP~fp · RY~Имя1,Имя2 · RR~guild~fp · RU~guild~преемник · RL~mode~inner
--         RM~mode~origin~inner · RG~mode~origin~inner     (fp — отпечаток сертификата)
local ADDON, ns = ...

local Codec = {}
ns.Codec = Codec

local floor, concat = math.floor, table.concat

Codec.CHUNK = 220
Codec.MAX_CHUNKS = 32 -- полный отчёт переписи с подписью и запасом; предел всё же есть
Codec.MAX_MSG = 250 -- длиннее — режется на куски
Codec.GUILD_CAP = 1000
local MAX_COUNT = 10000

local function clean(s)
	return (tostring(s or ""):gsub("[~=,:|%c]", ""))
end
Codec.Clean = clean

local function split(s, sep)
	local out, start = {}, 1
	while true do
		local i = s:find(sep, start, true)
		if not i then
			out[#out + 1] = s:sub(start)
			return out
		end
		out[#out + 1] = s:sub(start, i - 1)
		start = i + #sep
	end
end
Codec.Split = split

-- Название гильдии — до 24 символов (не байт).
local function LongGuild(guild)
	return #guild > 72 or select(2, guild:gsub("[^\128-\191]", "")) > 24
end
Codec.LongGuild = LongGuild

local function num(v)
	local n = tonumber(v)
	if not n or n ~= n then return nil end
	n = floor(n)
	if n < 0 then n = 0 elseif n > MAX_COUNT then n = MAX_COUNT end
	return n
end
Codec.Num = num

---------------------------------------------------------------------------
-- Классы: двухбуквенные коды на проводе
---------------------------------------------------------------------------
Codec.CLASS_CODE = {
	WARRIOR = "WA", PALADIN = "PA", HUNTER = "HU", ROGUE = "RO", PRIEST = "PR",
	SHAMAN = "SH", MAGE = "MA", WARLOCK = "WL", DRUID = "DR", DEATHKNIGHT = "DK",
}
Codec.CLASS_FILE = {}
for file, code in pairs(Codec.CLASS_CODE) do Codec.CLASS_FILE[code] = file end

local function classCode(file)
	return Codec.CLASS_CODE[file or ""] or ""
end
local function classFile(code)
	return Codec.CLASS_FILE[code or ""]
end

---------------------------------------------------------------------------
-- Поля отчёта
---------------------------------------------------------------------------

-- "key=count", самые большие первыми, не больше max.
local function encMap(t, max)
	local list = {}
	for k, v in pairs(t or {}) do
		local key = clean(k)
		if key ~= "" and v and v > 0 then list[#list + 1] = { key, floor(v) } end
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then return a[2] > b[2] end
		return a[1] < b[1]
	end)
	local parts = {}
	for i = 1, math.min(#list, max or 60) do parts[i] = list[i][1] .. "=" .. list[i][2] end
	return concat(parts, ",")
end

local function decMap(s, maxEntries)
	local t, n = {}, 0
	for k, v in (s or ""):gmatch("([^,=]+)=(%d+)") do
		n = n + 1
		if n > maxEntries then break end
		t[k:sub(1, 48)] = num(v)
	end
	return t
end

-- Упорядоченный список "name=count" (ранги в своём порядке).
local function encList(list, max)
	local parts = {}
	for i = 1, math.min(#(list or {}), max) do
		local e = list[i]
		parts[#parts + 1] = clean(e.name) .. "=" .. floor(e.count or 0)
	end
	return concat(parts, ",")
end

local function decList(s, max)
	local out = {}
	for k, v in (s or ""):gmatch("([^,=]+)=(%d+)") do
		if #out >= max then break end
		out[#out + 1] = { name = k:sub(1, 48), count = num(v) or 0 }
	end
	return out
end

-- Офицер: "имя:онлайн:дней:класс:уровень:ранг".
local function encPerson(o)
	return ("%s:%d:%d:%s:%d:%d"):format(clean(o.name), o.online and 1 or 0, floor(o.days or 0),
		classCode(o.class), floor(o.level or 0), floor(o.rank or 1))
end

local function decPerson(entry)
	local p = split(entry, ":")
	if not p[1] or p[1] == "" or not p[2] then return nil end
	return {
		name = p[1]:sub(1, 48),
		online = p[2] == "1",
		days = num(p[3]) or 0,
		class = classFile(p[4]),
		level = num(p[5]),
		rank = num(p[6]) or 1,
	}
end

Codec.MAX_OFFICERS = 30
Codec.MAX_VETERANS = 30
Codec.MAX_RANKS = 10
Codec.MAX_ZONES = 60

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function Codec.Base36(n)
	n = floor(tonumber(n) or -1)
	if n < 0 then return nil end
	local out = ""
	repeat
		local d = n % 36
		out = B36:sub(d + 1, d + 1) .. out
		n = floor(n / 36)
	until n == 0
	return out
end
local function unBase36(s)
	if type(s) ~= "string" or #s > 8 or not s:find("^[0-9a-z]+$") then return nil end
	return tonumber(s, 36)
end
Codec.UnBase36 = unBase36

function Codec.EncodeReport(r)
	local levels = {}
	for i = 1, 7 do levels[i] = floor((r.levels and r.levels[i]) or 0) end
	local officers = {}
	for i = 1, math.min(#(r.officers or {}), Codec.MAX_OFFICERS) do officers[i] = encPerson(r.officers[i]) end
	local veterans = {}
	for i = 1, math.min(#(r.veterans or {}), Codec.MAX_VETERANS) do veterans[i] = encPerson(r.veterans[i]) end
	local classes = {}
	for file, n in pairs(r.classes or {}) do
		local code = classCode(file)
		if code ~= "" then classes[code] = (classes[code] or 0) + n end
	end
	return concat({
		"R1",
		clean(r.guild),
		floor(r.total or 0),
		floor(r.online or 0),
		clean(r.leader or ""),
		r.leaderOnline and 1 or 0,
		floor(r.leaderDays or 0),
		classCode(r.leaderClass),
		floor(r.leaderLevel or 0),
		floor(r.users or 0),
		encMap(r.zones, Codec.MAX_ZONES),
		encMap(classes, 12),
		concat(levels, ","),
		encList(r.ranks, Codec.MAX_RANKS),
		concat(officers, ","),
		floor(r.inactive7 or 0),
		floor(r.inactive30 or 0),
		floor((r.avgLevel or 0) * 10 + 0.5),
		r.faction == "Horde" and "H" or "A",
		Codec.Base36(r.st) or "",
		concat(veterans, ","), -- с 0.2: связные (звание Config.RELAY_RANK)
	}, "~")
end

function Codec.DecodeReport(s)
	if type(s) ~= "string" or #s > Codec.CHUNK * Codec.MAX_CHUNKS then return nil end
	local f = split(s, "~")
	if f[1] ~= "R1" or #f < 20 then return nil end
	local guild = f[2]
	if guild == "" or LongGuild(guild) or guild:find("[|%c]") then return nil end
	local total, online = num(f[3]), num(f[4])
	if not total or not online or total > Codec.GUILD_CAP then return nil end
	online = math.min(online, total)
	local zones, classes = decMap(f[11], 120), decMap(f[12], 20)
	local cls = {}
	for code, n in pairs(classes) do
		local file = classFile(code)
		if file then cls[file] = n end
	end
	local levels = {}
	local lv = split(f[13], ",")
	for i = 1, 7 do levels[i] = num(lv[i]) or 0 end
	-- Каждая разбивка считает онлайн-участников не больше одного раза.
	for _, counts in ipairs({ zones, cls, levels }) do
		local sum = 0
		for _, count in pairs(counts) do sum = sum + count end
		if sum > online then return nil end
	end
	local function people(field, max)
		local out = {}
		for entry in (field or ""):gmatch("[^,]+") do
			if #out >= max then break end
			local o = decPerson(entry)
			if o then out[#out + 1] = o end
		end
		return out
	end
	local officers = people(f[15], Codec.MAX_OFFICERS)
	local veterans = people(f[21], Codec.MAX_VETERANS)
	return {
		guild = guild,
		total = total,
		online = online,
		leader = f[5] ~= "" and f[5]:sub(1, 48) or nil,
		leaderOnline = f[6] == "1",
		leaderDays = num(f[7]) or 0,
		leaderClass = classFile(f[8]),
		leaderLevel = num(f[9]),
		users = math.min(num(f[10]) or 0, total),
		zones = zones,
		classes = cls,
		levels = levels,
		ranks = decList(f[14], Codec.MAX_RANKS),
		officers = officers,
		veterans = veterans,
		inactive7 = math.min(num(f[16]) or 0, total),
		inactive30 = math.min(num(f[17]) or 0, total),
		avgLevel = (num(f[18]) or 0) / 10,
		faction = f[19] == "H" and "Horde" or "Alliance",
		st = unBase36(f[20]),
	}
end

-- Отчёт в том виде, в каком он может уйти: без зон, если репортёр не согласился.
function Codec.Shareable(r, sharesZones)
	local out = {}
	for k, v in pairs(r) do out[k] = v end
	if not sharesZones then out.zones = {} end
	return out
end

---------------------------------------------------------------------------
-- Привет и запрос
---------------------------------------------------------------------------
function Codec.EncodeHello(version, sharesZones, isRelay, fp)
	local hello = ("H1~%s~%s%s"):format(clean(version), sharesZones and "z" or "", isRelay and "r" or "")
	if type(fp) == "string" and #fp == 16 and fp:match("^[%w_-]+$") then return hello .. "~" .. fp end
	return hello .. "~0"
end

function Codec.DecodeHello(s)
	if type(s) ~= "string" then return nil end
	local version, flags, fp = s:match("^H1~([^~]*)~([^~]*)~([^~]*)")
	if not version then version, flags = s:match("^H1~([^~]*)~?([^~]*)") end
	if not version or (fp and fp ~= "0" and (#fp ~= 16 or not fp:match("^[%w_-]+$"))) then return nil end
	return { version = version:sub(1, 16), zones = flags:find("z", 1, true) ~= nil,
		relay = flags:find("r", 1, true) ~= nil, fp = fp ~= "0" and fp or nil, legacy = fp == nil }
end

---------------------------------------------------------------------------
-- Конверты реле
---------------------------------------------------------------------------
Codec.RELAY_MODES = { L = true, P = true } -- L: новый заменяет старый того же автора; P: каждое
Codec.INNER = { R1 = true, M1 = true, S1 = true }

function Codec.InnerType(inner)
	local t = type(inner) == "string" and inner:sub(1, 2)
	return (t and Codec.INNER[t]) and t or nil
end

function Codec.EncodeRelayList(names)
	local out = {}
	for _, n in ipairs(names or {}) do
		local c = clean(n)
		if c ~= "" then out[#out + 1] = c end
	end
	return "RY~" .. concat(out, ",")
end

function Codec.DecodeRelayList(s, max)
	local body = type(s) == "string" and s:match("^RY~(.*)$")
	if not body then return nil end
	local out = {}
	for n in body:gmatch("[^,]+") do
		if #out >= (max or 8) then break end
		if #n <= 48 and not n:find("[|%c]") then out[#out + 1] = n end
	end
	return out
end

-- RL~mode~inner (автор → реле).
function Codec.EncodeRL(mode, inner)
	return "RL~" .. mode .. "~" .. inner
end

-- RM/RG~mode~origin~inner (реле → репортёр, репортёр → гильдия).
function Codec.EncodeRM(kind, mode, origin, inner)
	return kind .. "~" .. mode .. "~" .. clean(origin) .. "~" .. inner
end

-- Разбор любого конверта: kind, mode, origin (nil у RL), inner.
function Codec.DecodeRelay(s)
	if type(s) ~= "string" then return nil end
	local kind = s:sub(1, 2)
	local mode, rest
	if kind == "RL" then
		mode, rest = s:match("^RL~(%u)~(.+)$")
		if not mode or not Codec.RELAY_MODES[mode] or not Codec.InnerType(rest) then return nil end
		return kind, mode, nil, rest
	elseif kind == "RM" or kind == "RG" then
		local origin, inner
		mode, origin, inner = s:match("^R[MG]~(%u)~([^~]+)~(.+)$")
		if not mode or not Codec.RELAY_MODES[mode] or #origin > 64 or origin:find("[|%c]") or not Codec.InnerType(inner) then return nil end
		return kind, mode, origin, inner
	end
	return nil
end

---------------------------------------------------------------------------
-- Чат. Текст — последнее поле, в нём могут быть ~ : , = как набраны.
---------------------------------------------------------------------------
Codec.CHAT_MAX = 250
Codec.CHAT_TIERS = { A = true, C = true, L = true }
local LINK_TYPES = { item = true, spell = true, enchant = true, quest = true }

-- Данные ссылки как их пишет игра: id от 1, затем до 31 поля — пустое или целое.
local function LinkData(data)
	if #data > 120 then return false end
	local n = 0
	for field in (data .. ":"):gmatch("([^:]*):") do
		n = n + 1
		if n == 1 and not field:find("^[1-9]%d?%d?%d?%d?%d?%d?%d?%d?$") then return false end
		if n > 32 or #field > 11 or not (field == "" or field:find("^%-?%d+$")) then return false end
	end
	return true
end

-- Длина допустимой ссылки, начинающейся в i, или nil: необязательный цвет,
-- |Htype:data|h[текст]|h и |r, если был цвет.
local function LinkAt(s, i)
	local j = i
	local color = s:match("^|c%x%x%x%x%x%x%x%x", j) or s:match("^|cn[%w_]+:", j)
	if color then
		if #color > 40 then return nil end
		j = j + #color
	end
	local kind, data, text = s:match("^|H(%a+):([^|]*)|h%[([^|%[%]%c]*)%]|h", j)
	if not kind or not LINK_TYPES[kind] or not LinkData(data) or text == "" or #text > 100 then return nil end
	j = j + #kind + #data + #text + 9
	if color then
		if s:sub(j, j + 1) ~= "|r" then return nil end
		j = j + 2
	end
	return j - i
end
Codec.LinkAt = LinkAt

-- Текст чата, как его можно показать: разрешённые ссылки и "||" остаются, любая другая
-- "|" становится "||" (текстуры, цвета, поддельные ссылки — простым текстом), управляющие
-- байты убираются. Идемпотентно.
function Codec.SanitizeChat(s)
	s = tostring(s or "")
	local out, i, n = {}, 1, #s
	while i <= n do
		local j = s:find("[%z\1-\31|\127]", i)
		if not j then
			out[#out + 1] = s:sub(i)
			break
		end
		if j > i then out[#out + 1] = s:sub(i, j - 1) end
		if s:byte(j) ~= 124 then
			i = j + 1
		elseif s:byte(j + 1) == 124 then
			out[#out + 1] = "||"
			i = j + 2
		else
			local len = LinkAt(s, j)
			out[#out + 1] = len and s:sub(j, j + len - 1) or "||"
			i = j + (len or 1)
		end
	end
	return (concat(out):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Любой другой текст от другого игрока: без "|" и управляющих байтов.
function Codec.Plain(s)
	return (tostring(s or ""):gsub("[|%c]", ""))
end

function Codec.ChatBudget(guild, class)
	return Codec.CHAT_MAX - (12 + #clean(guild) + #clean(class))
end

local function IsContinuation(b)
	return b ~= nil and b >= 128 and b < 192
end

-- Делит очищенный текст на не больше maxParts частей по budget байт. Разрез не попадает
-- внутрь буквы UTF-8, ссылки или "||" и по возможности приходится на пробел.
-- Возвращает parts, cut (true — хвост потерян).
function Codec.SplitChat(s, budget, maxParts)
	local parts = {}
	s = (s or ""):gsub("^%s+", "")
	while s ~= "" and #parts < maxParts do
		if #s <= budget then
			parts[#parts + 1] = s
			s = ""
			break
		end
		local cut, i, space = 0, 1, nil
		while i <= #s do
			local len = 1
			if s:byte(i) == 124 then len = s:byte(i + 1) == 124 and 2 or LinkAt(s, i) or 1 end
			if i + len - 1 > budget then break end
			if len == 1 and s:byte(i) == 32 then space = i end
			cut = i + len - 1
			i = i + len
		end
		if cut < 1 then cut = budget end
		while cut > 1 and IsContinuation(s:byte(cut + 1)) do cut = cut - 1 end
		if space and space > 1 and space <= cut and space > cut - 40 then cut = space - 1 end
		parts[#parts + 1] = (s:sub(1, cut):gsub("%s+$", ""))
		s = s:sub(cut + 1):gsub("^%s+", "")
	end
	return parts, s ~= ""
end

-- text уже очищен и нарезан.
function Codec.EncodeChat(tier, guild, id, class, text)
	local msg = ("M1~%s~%s~%d~%s~"):format(tier, clean(guild), id % 10000, classCode(class)) .. text
	if #msg > 255 then return nil end
	return msg
end

function Codec.DecodeChat(s)
	if type(s) ~= "string" or #s > 255 then return nil end
	local tier, guild, id, code, text = s:match("^M1~(%u)~([^~|]+)~(%d%d?%d?%d?)~(%u?%u?)~(.+)$")
	if not tier or not Codec.CHAT_TIERS[tier] or LongGuild(guild) or guild:find("%c") then return nil end
	text = Codec.SanitizeChat(text)
	if text == "" then return nil end
	return { tier = tier, guild = guild, id = tonumber(id), class = classFile(code), text = text }
end

---------------------------------------------------------------------------
-- Куски. Сборщик ограничен: несколько открытых сообщений на отправителя и
-- несколько сотен всего; при переполнении закрывается самое старое сообщение
-- того, кто держит больше всех.
---------------------------------------------------------------------------
function Codec.Chunk(payload, id)
	local n = math.max(1, math.ceil(#payload / Codec.CHUNK))
	local out = {}
	for i = 1, n do
		out[i] = ("C%s:%d:%d:"):format(id, i, n) .. payload:sub((i - 1) * Codec.CHUNK + 1, i * Codec.CHUNK)
	end
	return out
end

-- Сообщение целиком или куски (если длинное).
function Codec.Pack(payload, id)
	if #payload <= Codec.MAX_MSG and payload:sub(1, 1) ~= "C" then return { payload } end
	return Codec.Chunk(payload, id)
end

Codec.OPEN_PER_SENDER = 4
Codec.OPEN_MAX = 200

function Codec.NewAssembler()
	return { buf = {}, open = 0, bySender = {}, refused = 0, evicted = 0 }
end

function Codec.Close(asm, key)
	local e = asm.buf[key]
	if not e then return end
	asm.buf[key] = nil
	asm.open = math.max(0, asm.open - 1)
	local left = (asm.bySender[e.sender] or 1) - 1
	asm.bySender[e.sender] = left > 0 and left or nil
end

local function Evict(asm, sender)
	local who, most = nil, 1
	for s, held in pairs(asm.bySender) do
		if s ~= sender and (held > most or (held == most and who and s < who)) then who, most = s, held end
	end
	if not who then return false end
	local victim
	for key, e in pairs(asm.buf) do
		if e.sender == who and (not victim or e.t < asm.buf[victim].t or (e.t == asm.buf[victim].t and key < victim)) then victim = key end
	end
	if not victim then return false end
	Codec.Close(asm, victim)
	asm.evicted = asm.evicted + 1
	return true
end

-- Целое сообщение, когда пришли все куски от этого отправителя с этим id.
function Codec.Feed(asm, sender, msg, now)
	local id, i, n, body = msg:match("^C(%w+):(%d+):(%d+):(.*)$")
	if not id then return nil end
	i, n = tonumber(i), tonumber(n)
	if n < 1 or n > Codec.MAX_CHUNKS or i < 1 or i > n then return nil end
	local key = sender .. "#" .. id
	local e = asm.buf[key]
	if not e or e.n ~= n then
		if not e then
			local mine = asm.bySender[sender] or 0
			if mine < Codec.OPEN_PER_SENDER and asm.open >= Codec.OPEN_MAX then Evict(asm, sender) end
			if mine >= Codec.OPEN_PER_SENDER or asm.open >= Codec.OPEN_MAX then
				asm.refused = asm.refused + 1
				return nil
			end
			asm.bySender[sender], asm.open = mine + 1, asm.open + 1
		end
		e = { n = n, parts = {}, got = 0, t = now, sender = sender }
		asm.buf[key] = e
	end
	if not e.parts[i] then
		e.parts[i] = body
		e.got = e.got + 1
	end
	if e.got == n then
		Codec.Close(asm, key)
		return concat(e.parts)
	end
	return nil
end

-- Выбрасывает сборки старше 60 с.
function Codec.Gc(asm, now)
	local dropped = 0
	for k, e in pairs(asm.buf) do
		if now - e.t > 60 then
			dropped = dropped + 1
			Codec.Close(asm, k)
		end
	end
	return dropped
end

---------------------------------------------------------------------------
-- Выборы
---------------------------------------------------------------------------

-- Один репортёр на гильдию: наименьший Key среди тех, кто на связи и кому гильдия доверяет
-- связь (trusted(key); nil — всем). Если хоть кто-то из них делится зонами, выбирают только
-- из делящихся. Все считают одинаково — переговоры не нужны. Нет ни одного доверенного — nil.
-- peers: [key] = { t = последний H1, z = делится зонами }.
function Codec.PickReporter(selfKey, selfShares, peers, now, window, trusted)
	local function ok(key) return trusted == nil or trusted(key) == true end
	local selfOk = selfKey ~= nil and ok(selfKey)
	local anyShares = selfOk and selfShares and true or false
	for key, p in pairs(peers) do
		if now - p.t <= window and p.z and ok(key) then anyShares = true end
	end
	local best = selfOk and (not anyShares or selfShares) and selfKey or nil
	for key, p in pairs(peers) do
		if now - p.t <= window and (p.z or not anyShares) and ok(key) and (not best or key < best) then best = key end
	end
	return best
end

-- Реле для гильдии: по хешу гильдии и 10-минутного окна среди names (упорядоченных по Key).
function Codec.PickRelay(guildKey, keys, now, window)
	if #keys == 0 then return nil end
	local sorted = {}
	for i, k in ipairs(keys) do sorted[i] = k end
	table.sort(sorted)
	local h = ns.Util.Hash(guildKey .. "#" .. floor(now / (window or 600)))
	return sorted[h % #sorted + 1]
end

-- Ключ дедупликации реле.
function Codec.DedupeKey(originKey, inner)
	-- Хеш до 2^32 - 1 не помещается в знаковый %d клиента игры.
	return ("%s|%d|%.0f"):format(originKey or "?", #inner, ns.Util.Hash(inner))
end

