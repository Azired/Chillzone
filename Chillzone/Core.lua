-- Chillzone: ядро — события, таймеры, сохранённые данные, кто я, команды /chillzone.
-- Шина событий и таймеры устроены как в Olympus Core.lua.
local ADDON, ns = ...

local L = ns.L
local U = ns.Util
local C = ns.Config

ns.VERSION = C.VERSION
ns.PREFIX = C.PREFIX

---------------------------------------------------------------------------
-- Вывод и журнал
---------------------------------------------------------------------------
ns.COLOR = "|cff7fd4c1"

function ns.Print(msg, ...)
	if select("#", ...) > 0 then msg = msg:format(...) end
	local frame = DEFAULT_CHAT_FRAME
	if frame then frame:AddMessage(ns.COLOR .. "Chillzone|r: " .. tostring(msg)) end
end

function ns.Log(fmt, ...)
	local msg
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		msg = ok and res or tostring(fmt)
	else
		msg = tostring(fmt)
	end
	local db = ns.db
	if not db then return end
	local log = db.log
	log[#log + 1] = (date and date("%m-%d %H:%M:%S ") or "") .. msg
	while #log > 300 do table.remove(log, 1) end
	if db.settings.debug then ns.Print("|cff999999" .. msg .. "|r") end
end

---------------------------------------------------------------------------
-- Защищённые вызовы: ошибка одного обработчика не ломает остальные.
---------------------------------------------------------------------------
local warnedError = false
function ns.SafeCall(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local db = ns.db
		if db then
			db.errors = db.errors or {}
			table.insert(db.errors, 1, ("%s: %s"):format(where, tostring(err)))
			while #db.errors > 20 do table.remove(db.errors) end
		end
		if not warnedError then
			warnedError = true
			ns.Print(L.ERROR_ONCE)
		end
	end
	return ok
end

local listeners = {}
function ns.CaptureError(where, err)
	ns.SafeCall(where, function() error(tostring(err)) end)
end

function ns.On(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
	local l = listeners[name]
	if not l then return end
	for i = 1, #l do ns.SafeCall("callback " .. name, l[i], ...) end
end

local eventFrame = CreateFrame("Frame")
local handlers = {}
function ns.RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local h = handlers[event]
	if not h then return end
	for i = 1, #h do ns.SafeCall("event " .. event, h[i], ...) end
end)

function ns.After(seconds, where, fn)
	C_Timer.After(seconds, function() ns.SafeCall(where, fn) end)
end

-- Повторяющийся таймер. Стартует со случайным сдвигом (до 10 с), чтобы десяток
-- таймеров после входа не срабатывал в одном кадре.
function ns.Every(seconds, where, fn, noSpread)
	local ticker, cancelled = nil, false
	local handle = {}
	function handle.Cancel()
		cancelled = true
		if ticker and ticker.Cancel then ticker:Cancel() end
	end
	local function Tick() if not cancelled then ns.SafeCall(where, fn) end end
	local spread = noSpread and 0 or math.min(seconds, 10) * math.random()
	C_Timer.After(spread, function()
		if not cancelled then ticker = C_Timer.NewTicker(seconds, Tick) end
	end)
	return handle
end

function ns.Now() return GetTime() end
function ns.ServerTime() return (GetServerTime and GetServerTime()) or time() end

-- Фильтр строк чата (в новых клиентах функция живёт в ChatFrameUtil).
function ns.AddChatFilter(event, fn)
	local add = rawget(_G, "ChatFrame_AddMessageEventFilter")
	if type(add) ~= "function" then
		local CFU = rawget(_G, "ChatFrameUtil")
		add = type(CFU) == "table" and rawget(CFU, "AddMessageEventFilter") or nil
	end
	if type(add) == "function" then pcall(add, event, fn) end
end

---------------------------------------------------------------------------
-- Сохранённые данные
---------------------------------------------------------------------------
local function Defaults(t, d)
	for k, v in pairs(d) do
		if type(v) == "table" then
			if type(t[k]) ~= "table" then t[k] = {} end
			Defaults(t[k], v)
		elseif t[k] == nil then
			t[k] = v
		end
	end
	return t
end

local DB_DEFAULTS = {
	schema = 1,
	settings = { showMap = true, minimap = { angle = 200, hide = false }, debug = false, frame = {} },
	chars = {},
	realms = {},
	log = {},
	errors = {},
	versions = {}, -- версии новее моей, которые называли другие игроки (Update.lua)
}

local CHAR_DEFAULTS = {
	shareZones = true, chatOn = true, chatWindow = false, warned = false,
	chatMirror = true, chatTime = false, chatChannel = false, history = { G = {}, O = {} }, historyGuild = false, drafts = {},
}
local STORE_DEFAULTS = { guilds = {}, relays = {}, manual = {}, ignore = {}, chat = { A = {}, C = {}, L = {} } }

ns.RegisterEvent("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	ChillzoneDB = Defaults(type(ChillzoneDB) == "table" and ChillzoneDB or {}, DB_DEFAULTS)
	ns.db = ChillzoneDB
	ns.Fire("INIT")
end)

function ns.Faction()
	local f = UnitFactionGroup and UnitFactionGroup("player")
	return (f == "Horde" or f == "Alliance") and f or "Neutral"
end

-- Кто я: полное имя, ключ, реалм, группа реалмов. На Forever выясняется, делит ли
-- игра имена (splitNames), — от этого зависят все сравнения имён.
function ns.Identify()
	ns.realm = U.CurrentRealm()
	local name, realm
	if UnitFullName then name, realm = UnitFullName("player") end
	local full, split = U.ParsePlayer(name, realm, ns.realm)
	if split then ns.splitNames = true end
	ns.me = full
	ns.myKey = U.Key(full)
	ns.group = U.GroupOf(ns.realm)
	ns.faction = ns.Faction()
end

function ns.IsMe(name)
	return ns.myKey ~= nil and U.Key(name) == ns.myKey
end

ns.RegisterEvent("PLAYER_LOGIN", function()
	if not ns.db then
		ChillzoneDB = Defaults(type(ChillzoneDB) == "table" and ChillzoneDB or {}, DB_DEFAULTS)
		ns.db = ChillzoneDB
	end
	ns.Identify()
	local db = ns.db
	db.chars[ns.myKey] = Defaults(db.chars[ns.myKey] or {}, CHAR_DEFAULTS)
	ns.char = db.chars[ns.myKey]
	-- Зоны стали включены по умолчанию. Тем, кто заходил раньше, включаем один раз, дальше решает игрок.
	if not ns.char.zonesDefaulted then
		ns.char.zonesDefaulted, ns.char.shareZones = true, true
	end
	db.realms[ns.group] = db.realms[ns.group] or {}
	db.realms[ns.group][ns.faction] = Defaults(db.realms[ns.group][ns.faction] or {}, STORE_DEFAULTS)
	ns.store = db.realms[ns.group][ns.faction]
	ns.loginAt = ns.Now()
	ns.Log("---- %s, v%s, реалм %s, группа %s, %s, splitNames=%s ----", ns.me, ns.VERSION, ns.realm, ns.group, ns.faction, tostring(ns.splitNames))
	ns.Fire("LOGIN")
end)

---------------------------------------------------------------------------
-- Гильдия игрока
---------------------------------------------------------------------------

-- Название моей гильдии, мой rankIndex (0 — глава) и название звания, или nil.
function ns.MyGuild()
	if not (IsInGuild and IsInGuild()) then return nil end
	local guild, rankName, rankIndex = GetGuildInfo("player")
	if not guild or guild == "" then return nil end
	return guild, rankIndex, rankName
end

-- Моя роль в связи (U.TrustRole): "leader", "officer", "rank", "member" или nil.
function ns.MyTrust()
	local g, rank, rankName = ns.MyGuild()
	if not g or not U.IsMemberGuild(g) then return nil end
	return U.TrustRole(rank, rankName, ns.Roster.IsOfficerRank(rank))
end

-- Я в «своей» гильдии.
function ns.IsMember()
	local g = ns.MyGuild()
	return g ~= nil and U.IsMemberGuild(g)
end

---------------------------------------------------------------------------
-- Управление: /chillzone <команда> [аргументы]; короткие алиасы также принимают текст чата.
---------------------------------------------------------------------------
local commands, order = {}, {}
function ns.Command(name, fn, help)
	if not commands[name] then order[#order + 1] = name end
	commands[name] = { fn = fn, help = help }
end

local statusLines = {}
-- Модули добавляют свои строки в /chillzone status.
function ns.Status(fn)
	statusLines[#statusLines + 1] = fn
end

ns.Command("help", function()
	ns.Print(L.HELP_HEADER)
	for _, name in ipairs(order) do
		local c = commands[name]
		if c.help then DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/chillzone " .. name .. "|r — " .. c.help) end
	end
	DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/cz1 /cz2 /cz3|r — " .. L.HELP_CHAT)
	DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/cz текст|r — " .. L.HELP_CHAT_TEXT)
	DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/чз /чз1 /чз2 /чз3|r — " .. L.HELP_RU)
end, L.HELP_HELP)

ns.Command("status", function()
	local guild, rank = ns.MyGuild()
	ns.Print(L.STATUS_ME, U.Display(ns.me), ns.myKey or "?", ns.realm or "?", ns.group or "?", tostring(ns.splitNames or false), ns.faction or "?")
	if guild then
		ns.Print(L.STATUS_GUILD, guild, rank or -1, U.IsMemberGuild(guild) and L.YES or L.NO, U.IsMainGuild(guild) and L.YES or L.NO)
	else
		ns.Print(L.STATUS_NO_GUILD)
	end
	for _, fn in ipairs(statusLines) do
		ns.SafeCall("status", function()
			local line = fn()
			if line then ns.Print(line) end
		end)
	end
end, L.HELP_STATUS)

ns.Command("debug", function()
	ns.db.settings.debug = not ns.db.settings.debug
	ns.Print(ns.db.settings.debug and L.DEBUG_ON or L.DEBUG_OFF)
end, L.HELP_DEBUG)

ns.Command("log", function(arg)
	local n = tonumber(arg) or 20
	local log = ns.db.log
	for i = math.max(1, #log - n + 1), #log do DEFAULT_CHAT_FRAME:AddMessage("|cff999999" .. log[i] .. "|r") end
	for i = 1, math.min(3, #(ns.db.errors or {})) do DEFAULT_CHAT_FRAME:AddMessage("|cffff6060" .. ns.db.errors[i] .. "|r") end
end, L.HELP_LOG)

-- true — команда найдена, даже если её обработчик завершился ошибкой.
-- Короткие алиасы отправляют в чат только текст, не совпавший с командой.
function ns.RunCommand(msg)
	if not ns.me then return false end
	local name, rest = U.Trim(msg):match("^(%S*)%s*(.-)$")
	name = U.Fold(name or "")
	local c = commands[name]
	if not c then return false end
	ns.SafeCall("/chillzone " .. name, c.fn, rest)
	return true
end

SLASH_CHILLZONE1 = "/chillzone"
SlashCmdList.CHILLZONE = function(msg)
	if not ns.me then return end
	if U.Trim(msg) == "" then
		if ns.UI and ns.UI.Toggle then return ns.UI.Toggle() end
	end
	if not ns.RunCommand(msg) then ns.RunCommand("help") end
end
