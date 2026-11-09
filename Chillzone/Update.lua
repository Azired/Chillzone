-- Chillzone: предупреждение об устаревшем аддоне. Версии других игроков приходят в приветах
-- H1 своей гильдии и в отчётах R1 репортёров всех гильдий (Census.lua). Версия считается
-- вышедшей, когда новее моей её назвали не меньше Config.UPDATE_SOURCES разных игроков:
-- одна тестовая сборка до релиза или один шутник предупреждения не вызывают. Подделку
-- несколькими персонажами это не исключает: номер версии ничем не подтверждён.
-- Модуль ничего не отправляет. Игрок видит строку в чате раз за сессию, заголовок окна
-- (Views.Title) и строку в /chillzone status. Обновился — предупреждение уходит само.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local L = ns.L

local Update = {}
ns.Update = Update

local ready = false -- после входа прошло UPDATE_TELL_AFTER: строку в чат можно показывать
local told = false -- строка в чат уже была в этой сессии

-- Названные версии новее моей: [ключ игрока] = { v = версия, t = серверное время }. Хранятся
-- на весь аккаунт: обновился один согильдиец сегодня, другой завтра — это тоже два игрока.
local function Heard()
	local db = ns.db
	if not db then return {} end
	if type(db.versions) ~= "table" then db.versions = {} end
	return db.versions
end

-- Убрать устаревшее: версии не новее моей (я обновился), старше UPDATE_KEEP и сверх UPDATE_MAX
-- (сначала самые давние).
local function Prune(list, now)
	local n = 0
	for k, e in pairs(list) do
		if type(e) ~= "table" or type(e.t) ~= "number" or not U.VersionNewer(e.v, ns.VERSION) or now - e.t > C.UPDATE_KEEP then
			list[k] = nil
		else
			n = n + 1
		end
	end
	while n > C.UPDATE_MAX do
		local oldest
		for k, e in pairs(list) do
			if not oldest or e.t < list[oldest].t then oldest = k end
		end
		list[oldest] = nil
		n = n - 1
	end
end

-- Сколько игроков назвали версию v или новее.
local function Sources(list, v)
	local n = 0
	for _, e in pairs(list) do
		if U.ParseVersion(e.v) and not U.VersionNewer(v, e.v) then n = n + 1 end
	end
	return n
end

-- Вышедшая версия новее моей или nil: самая новая из тех, что назвали (или обогнали) не меньше
-- UPDATE_SOURCES игроков. 0.9.1 у одного и 0.9.0 у другого — это 0.9.0.
function Update.Available()
	local list, best = Heard(), nil
	for _, e in pairs(list) do
		if U.VersionNewer(e.v, ns.VERSION) and (not best or U.VersionNewer(e.v, best))
			and Sources(list, e.v) >= C.UPDATE_SOURCES then
			best = e.v
		end
	end
	return best
end

-- Самая новая названная версия новее моей и сколько игроков её назвали (для /chillzone status).
function Update.Newest()
	local list, best = Heard(), nil
	for _, e in pairs(list) do
		if U.VersionNewer(e.v, ns.VERSION) and (not best or U.VersionNewer(e.v, best)) then best = e.v end
	end
	return best, best and Sources(list, best) or 0
end

-- Строка в чат, раз за сессию.
function Update.Tell()
	if told or not ready then return end
	local v = Update.Available()
	if not v then return end
	told = true
	ns.Print(L.UPDATE_CHAT, v, ns.VERSION)
end

-- Игрок key назвал версию своего аддона. Своя версия, нераспознанная (сборка с хвостом) или
-- не новее моей снимает то, что он называл раньше.
function Update.Heard(key, version)
	if not key or key == ns.myKey or not ns.db then return end
	local list = Heard()
	local newer = U.VersionNewer(version, ns.VERSION)
	if not newer and not list[key] then return end
	local before = Update.Available()
	local now = ns.ServerTime()
	list[key] = newer and { v = version, t = now } or nil
	Prune(list, now)
	local after = Update.Available()
	if after ~= before then ns.Fire("UPDATE", after) end
	Update.Tell()
end

ns.On("LOGIN", function()
	Prune(Heard(), ns.ServerTime())
	ns.After(C.UPDATE_TELL_AFTER, "update notice", function()
		ready = true
		Update.Tell()
	end)
end)

ns.Status(function()
	local v = Update.Available()
	if v then return L.STATUS_UPDATE_BEHIND:format(ns.VERSION, v) end
	local newest, n = Update.Newest()
	if newest then return L.STATUS_UPDATE_PENDING:format(ns.VERSION, newest, n, C.UPDATE_SOURCES) end
	return L.STATUS_UPDATE_OK:format(ns.VERSION)
end)
