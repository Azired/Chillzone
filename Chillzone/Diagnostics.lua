-- Диагностика исходящих шёпотов всех аддонов. Только безопасные пост-хуки:
-- аргументы и результат отправки не меняем, текст сообщений и пакетов не читаем.
local ADDON, ns = ...
local D = { coverage = {} }
ns.Diagnostics = D
local L, U = ns.L, ns.Util
local recent, installed = {}, {}
local ownDepth = 0
local RECENT_TTL, RECENT_MAX = 60, 200

local function Secret(value)
	return type(issecretvalue) == "function" and issecretvalue(value)
end

local function Text(value)
	return not Secret(value) and type(value) == "string" and value or nil
end

function D.Enabled()
	return ns.db and ns.db.settings.debug == true
end

local function Source(skipComm)
	if type(debugstack) ~= "function" then return L.JOURNAL_SOURCE_UNKNOWN end
	local ok, stack = pcall(debugstack, 3, 12, 0)
	stack = ok and Text(stack)
	if stack then
		for line in stack:gmatch("[^\r\n]+") do
			local path = line:gsub("\\", "/")
			if line:find("AddOns", 1, true) and not line:find("Diagnostics.lua", 1, true)
				and not (skipComm and path:find("/" .. ADDON .. "/Comm.lua", 1, true)) then
				return (line:sub(1, 400):gsub("|", "||"))
			end
		end
	end
	return L.JOURNAL_SOURCE_UNKNOWN
end

function D.Callsite()
	return D.Enabled() and Source(true) or nil
end

local function Remember(api, prefix, target, owned, origin)
	if not D.Enabled() then return end
	target = Text(target)
	if not target then ns.Log("исходящий шёпот: %s, защищённый адресат", api); return end
	local now, count, oldest, oldestAt = ns.Now(), 0, nil, math.huge
	for key, entry in pairs(recent) do
		if now - entry.at > RECENT_TTL then recent[key] = nil
		else
			count = count + 1
			if entry.at < oldestAt then oldest, oldestAt = key, entry.at end
		end
	end
	local key = U.Key(target)
	if not key then return end
	if not recent[key] and count >= RECENT_MAX then recent[oldest] = nil end
	local source = owned and (origin or "Chillzone/Comm") or Source()
	prefix = Text(prefix) or L.JOURNAL_PROTECTED
	recent[key] = { at = now, owned = owned, api = api, prefix = prefix, source = source }
	ns.Log("исходящий шёпот: API=%s, адресат=%s, префикс=%s, источник=%s", api, target, prefix, source)
end

function D.LastSend(key)
	local entry = recent[key]
	return entry and ns.Now() - entry.at <= RECENT_TTL and entry or nil
end

-- Наш вызов записывается до API: системная ошибка может прийти синхронно.
-- Пост-хук его пропускает, поэтому запись не дублируется.
function D.SendAddon(send, prefix, msg, dist, target, logged, origin)
	if dist == "WHISPER" then
		Remember(logged and "SendAddonMessageLogged" or "SendAddonMessage", prefix, target, true, origin)
	end
	ownDepth = ownDepth + 1
	local ok, result = pcall(send, prefix, msg, dist, target)
	ownDepth = ownDepth - 1
	return ok, result
end

local function Observe(api, prefix, dist, target)
	if ownDepth > 0 or not D.Enabled() or Secret(dist) or dist ~= "WHISPER" then return end
	Remember(api, prefix, target, false)
end

function D.Install()
	if type(hooksecurefunc) ~= "function" then
		D.coverage.hooksecurefunc = L.JOURNAL_HOOK_FAILED
		return
	end
	local function hook(owner, name, chat)
		local api = owner == _G and name or "C_ChatInfo." .. name
		if type(owner) ~= "table" or type(owner[name]) ~= "function" or installed[api] then return end
		local callback
		if chat then
			callback = function(_, dist, language, target) Observe(api, "—", dist, target) end
		else
			callback = function(prefix, _, dist, target) Observe(api, prefix, dist, target) end
		end
		local ok = pcall(hooksecurefunc, owner, name, callback)
		installed[api] = ok or nil
		D.coverage[api] = ok and L.JOURNAL_HOOK_OK or L.JOURNAL_HOOK_FAILED
	end
	for _, name in ipairs({ "SendAddonMessage", "SendAddonMessageLogged", "SendChatMessage" }) do
		hook(C_ChatInfo, name, name == "SendChatMessage")
		hook(_G, name, name == "SendChatMessage")
	end
end

function D.SetEnabled(on)
	D.Install()
	ns.db.settings.debug = on and true or false
	recent = {}
	ns.Log("v%s: %s", ns.VERSION, on and L.DEBUG_ON or L.DEBUG_OFF)
end

function D.Clear()
	ns.db.log, ns.db.errors, recent = {}, {}, {}
	ns.Log(L.JOURNAL_CLEARED)
end

-- Ответы системы пишутся независимо от наличия и давности наших отправок.
-- Привязка к шёпоту означает совпадение адресата, а не доказанную доставку.
ns.RegisterEvent("CHAT_MSG_SYSTEM", function(text)
	if not D.Enabled() then return end
	text = Text(text)
	if not text then ns.Log("CHAT_MSG_SYSTEM: защищённая строка"); return end
	ns.Log("CHAT_MSG_SYSTEM, ответ системы после шёпота или другого события: %q", (text:gsub("|", "||")))
	local key = ns.Comm.NotFoundKey(text)
	local entry = key and D.LastSend(key)
	if entry then
		ns.Log("совпадение адресата %s: последняя отправка %s с назад, API=%s, префикс=%s, источник=%s",
			key, math.floor(ns.Now() - entry.at), entry.api, entry.prefix, entry.source)
	elseif key then
		ns.Log("адресат %s: исходящей отправки в записи нет", key)
	end
end)

function D.Report(limit)
	local lines = { L.JOURNAL_REPORT:format(ns.VERSION, ns.me or "?", ns.realm or "?") }
	local coverage = {}
	for api, state in pairs(D.coverage) do coverage[#coverage + 1] = api .. ": " .. state end
	table.sort(coverage)
	lines[#lines + 1] = L.JOURNAL_HOOKS .. table.concat(coverage, "; ")
	local s = ns.Comm.stats
	lines[#lines + 1] = L.STATUS_COMM:format(s.sent, s.recv, ns.Comm.QueueSize(), s.fails, s.dropped)
	lines[#lines + 1] = L.JOURNAL_EVENTS
	local log = ns.db and ns.db.log or {}
	for i = math.max(1, #log - (limit or #log) + 1), #log do lines[#lines + 1] = log[i] end
	lines[#lines + 1] = L.JOURNAL_ERRORS
	for _, err in ipairs(ns.db and ns.db.errors or {}) do
		lines[#lines + 1] = err:match("^%[%d%d%-%d%d ") and err or (L.JOURNAL_OLD_ERROR .. err)
	end
	return table.concat(lines, "\n")
end

ns.On("LOGIN", function()
	D.Install()
	if D.Enabled() then ns.Log("v%s: %s", ns.VERSION, L.DEBUG_ON) end
end)
