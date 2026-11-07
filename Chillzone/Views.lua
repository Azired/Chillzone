-- Chillzone: содержимое вкладок окна — список гильдий и карточка гильдии «Переписи», дерево
-- «Королевства» (строки { text, right, indent, tip(tooltip) }, их рисует UI.lua), шапка окна,
-- строки и люди чата, подсказки.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Views = {}
ns.Views = Views

local ICON_ON = "|TInterface\\FriendsFrame\\StatusIcon-Online:12|t"
local ICON_OFF = "|TInterface\\FriendsFrame\\StatusIcon-Offline:12|t"
local ICON_KING = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:14|t"
local ICON_OFFICER = "|TInterface\\GroupFrame\\UI-Group-AssistantIcon:12|t"
local GOLD, GREY, RED, WHITE = "|cffffd100", "|cff999999", "|cffff4040", "|cffffffff"
local GREEN = "|cff40ff40"

function Views.Ago(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds < 60 then return L.AGO_NOW end
	if seconds < 3600 then return L.AGO_MIN:format(math.floor(seconds / 60)) end
	if seconds < 86400 then return L.AGO_HOUR:format(math.floor(seconds / 3600)) end
	return L.AGO_DAY:format(math.floor(seconds / 86400))
end

-- Имя цветом класса (имена из чужих отчётов — только простой текст).
function Views.Name(name, class)
	name = Codec.Plain(name or "?")
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.colorStr then return "|c" .. color.colorStr .. name .. "|r" end
	return name
end

local function Dot(online)
	return online and ICON_ON or ICON_OFF
end

local function GuildLabel(s)
	local name = Codec.Plain(s.guild)
	if s.main then name = GOLD .. name .. "|r" end
	if s.mine then name = name .. " " .. GREY .. L.MINE_MARK .. "|r" end
	if s.conflict then name = name .. " " .. RED .. "!|r" end
	return name
end

---------------------------------------------------------------------------
-- Карточка гильдии на «Переписи» (CensusPane.lua рисует её справа от списка)
---------------------------------------------------------------------------
local function SortedMap(map)
	local list = {}
	for k, v in pairs(map or {}) do list[#list + 1] = { k = k, v = v } end
	table.sort(list, function(a, b)
		if a.v ~= b.v then return a.v > b.v end
		return tostring(a.k) < tostring(b.k)
	end)
	return list
end

-- «в игре», «не в игре меньше дня», «не в игре 3 дн.»
function Views.State(online, days)
	if online then return L.ONLINE end
	days = math.floor(days or 0)
	if days < 1 then return L.OFFLINE_TODAY end
	return L.OFFLINE_DAYS:format(days)
end

-- 13.5 → «13,5»: в русском дробная часть — через запятую.
function Views.Decimal(x)
	return (("%.1f"):format(tonumber(x) or 0):gsub("%.", ","))
end

local LEVEL_LABELS = { "1-9", "10-19", "20-29", "30-39", "40-49", "50-59", "60" }
local ZONES_SHOWN = 8

-- Всё, что знаем о гильдии s (строка Data.Summary), разложенное для карточки:
-- { guild, marks, updated, conflict, stats = { {value, label, green} x4 }, extra, people,
--   classes = { {class, name, count} }, classTotal, levels = { {label, count} x7 }, levelMax,
--   zones = { {name, count} }, zoneMax, zonesNote, staleNote }.
-- Классы, уровни и зоны — только из свежего отчёта (кто в игре сейчас).
function Views.GuildCard(s)
	local r = s.r
	local card = { guild = Codec.Plain(s.guild), main = s.main, mine = s.mine, conflict = s.conflict }
	local marks = {}
	if s.main then marks[#marks + 1] = L.CARD_MAIN end
	if s.mine then marks[#marks + 1] = L.CARD_MINE end
	card.marks = table.concat(marks, ", ")
	card.updated = s.mine and L.TIP_FROM_ROSTER or L.TIP_UPDATED:format(Views.Ago(s.age))
	local officers = #(r.officers or {})
	card.stats = {
		{ value = s.total and U.Num(s.total) or "?", label = U.Plural(s.total or 0, L.HEAD_MEMBER_1, L.HEAD_MEMBER_2, L.HEAD_MEMBER_5) },
		{ value = s.online and U.Num(s.online) or "?", label = L.CARD_ONLINE, green = s.online ~= nil },
		{ value = U.Num(officers), label = U.Plural(officers, L.CARD_OFFICER_1, L.CARD_OFFICER_2, L.CARD_OFFICER_5) },
		{ value = Views.Decimal(r.avgLevel), label = L.CARD_AVG },
	}
	card.extra = L.CARD_EXTRA:format(r.users or 0, r.inactive7 or 0, r.inactive30 or 0)
	card.people = {}
	local function person(p, role)
		card.people[#card.people + 1] = {
			name = p.name, class = p.class, level = p.level, days = p.days, role = role,
			online = (s.fresh and p.online) and true or false, guild = s.guild, main = s.main,
		}
	end
	if r.leader then
		person({ name = r.leader, class = r.leaderClass, level = r.leaderLevel, online = r.leaderOnline, days = r.leaderDays }, "leader")
	end
	for _, o in ipairs(r.officers or {}) do person(o, "officer") end
	if s.fresh then
		card.classes, card.classTotal = {}, 0
		for _, e in ipairs(SortedMap(r.classes)) do
			card.classes[#card.classes + 1] = { class = e.k, name = L.CLASS[e.k] or tostring(e.k), count = e.v }
			card.classTotal = card.classTotal + e.v
		end
		card.levels, card.levelMax = {}, 0
		for i, label in ipairs(LEVEL_LABELS) do
			local n = (r.levels or {})[i] or 0
			card.levels[i] = { label = label, count = n }
			if n > card.levelMax then card.levelMax = n end
		end
		card.zones, card.zoneMax = {}, 0
		for i, e in ipairs(SortedMap(r.zones)) do
			if i > ZONES_SHOWN then break end
			card.zones[i] = { name = ns.Zones.NameForKey(e.k), count = e.v }
			if e.v > card.zoneMax then card.zoneMax = e.v end
		end
		if #card.zones == 0 then card.zonesNote = s.mine and L.CARD_NO_ZONES or L.TIP_NO_ZONES end
	else
		card.staleNote = L.CARD_STALE
	end
	return card
end

---------------------------------------------------------------------------
-- Вкладка «Перепись»
---------------------------------------------------------------------------
-- Шапка окна, как у Olympus: крупно — сколько всего участников во всех гильдиях «Чиллзон»,
-- мелко — сколько в игре, сколько гильдий и когда пришёл самый свежий отчёт.
-- { big, small, guilds, total, online, newest (возраст в секундах) }.
function Views.Status(now)
	now = now or ns.ServerTime()
	local st = { guilds = 0, total = 0, online = 0 }
	for _, s in ipairs(ns.Data.Summary(now)) do
		if s.recent then
			st.guilds = st.guilds + 1
			st.total = st.total + (s.total or 0)
			st.online = st.online + (s.online or 0)
			if not st.newest or s.age < st.newest then st.newest = s.age end
		end
	end
	if st.guilds == 0 then
		st.big, st.small = L.HEAD_WAIT, L.HEAD_WAIT_SUB
		return st
	end
	st.big = U.Num(st.total) .. " " .. U.Plural(st.total, L.HEAD_MEMBER_1, L.HEAD_MEMBER_2, L.HEAD_MEMBER_5)
	st.small = L.HEAD_SUB:format(
		GREEN .. U.Num(st.online) .. "|r",
		WHITE .. st.guilds .. "|r " .. U.Plural(st.guilds, L.HEAD_GUILD_1, L.HEAD_GUILD_2, L.HEAD_GUILD_5),
		Views.Ago(st.newest))
	return st
end

-- Подсказка шапки: по гильдиям, сколько в игре из скольких.
function Views.StatusTip(tt, now)
	now = now or ns.ServerTime()
	local st = Views.Status(now)
	tt:AddLine(st.big, 1, 0.82, 0)
	tt:AddLine(st.small, 0.7, 0.7, 0.7)
	local list = ns.Data.Summary(now)
	if #list > 0 then tt:AddLine(" ") end
	for _, s in ipairs(list) do
		if s.recent then
			local name = Codec.Plain(s.guild) .. (s.mine and (" " .. L.MINE_MARK) or "")
			local online = s.online and (GREEN .. U.Num(s.online) .. "|r") or (GREY .. "?|r")
			local r, g, b = 1, 1, 1
			if s.main then r, g, b = 1, 0.82, 0 end
			tt:AddDoubleLine(name, online .. GREY .. " / |r" .. U.Num(s.total or 0), r, g, b, 1, 1, 1)
		end
	end
	tt:AddLine(" ")
	tt:AddLine(L.HEAD_TIP_MORE, 0.6, 0.6, 0.6)
end

-- Список гильдий слева на «Переписи»: { key, s, text, right, sub }. Подробности — Views.GuildCard.
function Views.CensusRows(now)
	local out = {}
	for _, s in ipairs(ns.Data.Summary(now)) do
		local right
		if s.recent then
			right = (s.online and (GREEN .. U.Num(s.online) .. "|r") or (GREY .. "?|r")) .. GREY .. " / |r" .. U.Num(s.total or 0)
		else
			right = GREY .. L.CENSUS_OLD:format(Views.Ago(s.age)) .. "|r"
		end
		local leader = s.r.leader and (Dot(s.fresh and s.r.leaderOnline) .. Views.Name(s.r.leader, s.r.leaderClass)) or GREY .. "—|r"
		out[#out + 1] = {
			key = U.GuildKey(s.guild), s = s, text = GuildLabel(s), right = right,
			sub = GREY .. L.CENSUS_LEADER .. "|r " .. leader,
		}
	end
	return out
end

---------------------------------------------------------------------------
-- Вкладка «Королевство»
---------------------------------------------------------------------------
local function PersonTip(p, role, guild)
	return function(tt)
		tt:AddLine(Views.Name(p.name, p.class))
		tt:AddLine(role .. ", " .. Codec.Plain(guild), 0.8, 0.8, 0.8)
		if p.level and p.level > 0 then tt:AddLine(L.TIP_LEVEL:format(p.level), 0.8, 0.8, 0.8) end
		tt:AddLine(Views.State(p.online, p.days), 0.6, 0.6, 0.6)
	end
end

local function Captains(lines, node, indent)
	for _, c in ipairs(node.captains) do
		lines[#lines + 1] = {
			text = ICON_OFFICER .. " " .. Dot(c.online) .. Views.Name(c.name, c.class),
			right = GREY .. L.ROLE_CAPTAIN .. "|r", indent = indent,
			tip = PersonTip(c, L.ROLE_CAPTAIN, node.guild),
		}
	end
end

function Views.Kingdom()
	local lines = {}
	local tree = ns.Data.Kingdom()
	lines[#lines + 1] = { text = GOLD .. L.KINGDOM_KING .. "|r", header = true }
	local king = tree.king
	if king then
		lines[#lines + 1] = {
			text = ICON_KING .. " " .. Dot(king.leaderOnline) .. Views.Name(king.leader, king.leaderClass) .. "  " .. GREY .. "<" .. Codec.Plain(king.guild) .. ">|r" .. (king.conflict and (" " .. RED .. "!|r") or ""),
			right = GOLD .. L.ROLE_KING .. "|r",
			tip = PersonTip({ name = king.leader, class = king.leaderClass, level = king.leaderLevel, online = king.leaderOnline, days = king.leaderDays }, L.ROLE_KING, king.guild),
		}
		Captains(lines, king, 1)
	else
		lines[#lines + 1] = { text = GREY .. L.KINGDOM_NO_KING:format(C.MAIN_GUILD) .. "|r", wrap = true }
	end
	local lords = 0
	for _, node in ipairs(tree.guilds) do
		if not node.main then
			if lords == 0 then lines[#lines + 1] = { text = GOLD .. L.KINGDOM_LORDS .. "|r", header = true, gap = true } end
			lords = lords + 1
			local lord = node.leader and (Dot(node.leaderOnline) .. Views.Name(node.leader, node.leaderClass)) or (GREY .. "—|r")
			lines[#lines + 1] = {
				text = lord .. "  " .. GREY .. "<" .. Codec.Plain(node.guild) .. ">|r" .. (node.conflict and (" " .. RED .. "!|r") or ""),
				right = GREY .. L.ROLE_LORD .. "|r",
				tip = node.leader and PersonTip({ name = node.leader, class = node.leaderClass, level = node.leaderLevel, online = node.leaderOnline, days = node.leaderDays }, L.ROLE_LORD, node.guild) or nil,
			}
			Captains(lines, node, 1)
		end
	end
	if lords == 0 then
		lines[#lines + 1] = { text = GOLD .. L.KINGDOM_LORDS .. "|r", header = true, gap = true }
		lines[#lines + 1] = { text = GREY .. L.KINGDOM_NO_LORDS .. "|r", wrap = true }
	end
	return lines
end

---------------------------------------------------------------------------
-- Окно чата: строки сообщений и список людей справа
---------------------------------------------------------------------------
local ACTIVE_WINDOW = 3600 -- «писал за последний час»
local ROLE_ORDER = { leader = 0, officer = 1, member = 2, active = 3 }

-- Строка канала для окна: [время] [Имя] <Гильдия>: текст. Имя — ссылка player.
function Views.ChatLine(e, channel, showTime)
	local link = "|Hplayer:" .. (U.TellName(e.s) or "?") .. "|h[" .. Views.Name(e.s, e.c) .. "]|h"
	local guild = ""
	if not ns.Chat.GUILD_CHANNELS[channel] and e.g then guild = " " .. GREY .. "<" .. ns.Chat.GuildTag(e.g) .. ">|r" end
	local stamp = (showTime and date) and (GREY .. date("%H:%M", e.t or 0) .. "|r ") or ""
	return stamp .. link .. guild .. ": " .. Codec.SanitizeChat(e.x)
end

local function ByRole(a, b)
	if ROLE_ORDER[a.role] ~= ROLE_ORDER[b.role] then return ROLE_ORDER[a.role] < ROLE_ORDER[b.role] end
	if a.role == "active" then return (a.wrote or 0) > (b.wrote or 0) end
	if (a.online and 1 or 0) ~= (b.online and 1 or 0) then return a.online and true or false end
	if (a.rank or 9) ~= (b.rank or 9) then return (a.rank or 9) < (b.rank or 9) end
	return a.name < b.name
end

-- Аддон у согильдийца по приветам H1 (Census.Addon). «Нет» — только про того, кто в игре:
-- от вышедшего привета и не должно быть.
local function GuildAddon(key, online)
	local has, version = ns.Census.Addon(key)
	if has == false and not online then has = nil end
	return has, version
end

-- Кто из других гильдий точно с аддоном: писал в общие каналы или прислал отчёт переписи.
-- Остальных не знаем: приветы H1 ходят только внутри гильдии.
local function AddonKnown(summary)
	local known = {}
	for tier in pairs(ns.Chat.TIER_LEVEL) do
		for _, e in ipairs(ns.Chat.History(tier)) do
			local k = U.Key(e.s)
			if k then known[k] = true end
		end
	end
	for _, s in ipairs(summary) do
		local k = U.Key(s.origin)
		if k then known[k] = true end
	end
	return known
end

-- Своя гильдия по ростеру: в G — кто в игре, в O — офицеры (в игре первыми).
local function GuildPeople(channel)
	local list = {}
	for _, m in ipairs(ns.Roster.members or {}) do
		local rank = m.rank or 9
		local officer = ns.Roster.IsOfficerRank(rank)
		if (channel == "G" and m.online) or (channel == "O" and officer) then
			local addon, version = GuildAddon(m.key, m.online)
			list[#list + 1] = {
				name = U.Display(m.name), class = m.class, level = m.level, online = m.online, days = m.days,
				rank = rank, rankName = m.rankName, zone = m.zone, guild = ns.Roster.guild,
				role = rank == 0 and "leader" or (officer and "officer" or "member"),
				addon = addon, version = version,
			}
		end
	end
	table.sort(list, function(a, b)
		if (a.online and 1 or 0) ~= (b.online and 1 or 0) then return a.online and true or false end
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.name < b.name
	end)
	return list
end

-- Люди канала для правой панели: { header = true, guild, main, count } и строки людей
-- { name, class, level, online, days, role, guild, wrote, addon, version }. Второе значение —
-- сколько в сети. addon: true — аддон есть, false — нет, nil — неизвестно.
-- Уровни «Чиллзон»: главы и офицеры гильдий из переписи (в «Главах» — только главы и офицеры
-- главной гильдии) плюс те, кто писал в канал за последний час.
function Views.People(channel, now)
	now = now or ns.ServerTime()
	local out, online = {}, 0
	local function add(p)
		out[#out + 1] = p
		if p.online then online = online + 1 end
	end
	if ns.Chat.GUILD_CHANNELS[channel] then
		for _, p in ipairs(GuildPeople(channel)) do add(p) end
		return out, online
	end
	local level = ns.Chat.TIER_LEVEL[channel] or 1
	local active, seen = {}, {}
	for _, e in ipairs(ns.Chat.History(channel)) do
		local k = U.Key(e.s)
		if k and now - (e.t or 0) <= ACTIVE_WINDOW then active[k] = e end
	end
	local groups, order = {}, {}
	local function group(guild, main)
		local gk = U.GuildKey(guild) or "?"
		if not groups[gk] then
			groups[gk] = { guild = guild, main = main, people = {} }
			order[#order + 1] = gk
		end
		return groups[gk]
	end
	local summary = ns.Data.Summary(now)
	local known, mine = AddonKnown(summary), U.GuildKey(ns.MyGuild())
	local function addon(k, guild, inGame)
		if mine and U.GuildKey(guild) == mine then
			local has, version = GuildAddon(k, inGame)
			if has ~= nil then return has, version end
		end
		return known[k] or nil
	end
	for _, s in ipairs(summary) do
		if s.recent then
			local g = group(s.guild, s.main)
			local r = s.r
			local function person(p, role)
				local k = U.Key(p.name)
				if not k or seen[k] then return end
				seen[k] = true
				local on = (s.fresh and p.online) and true or false
				local has, version = addon(k, s.guild, on)
				g.people[#g.people + 1] = {
					name = p.name, class = p.class, level = p.level, online = on,
					days = p.days, role = role, rank = p.rank, guild = s.guild, main = s.main, wrote = active[k] and active[k].t,
					addon = has, version = version,
				}
			end
			if r.leader then person({ name = r.leader, class = r.leaderClass, level = r.leaderLevel, online = r.leaderOnline, days = r.leaderDays, rank = 0 }, "leader") end
			if level < 3 or s.main then
				for _, o in ipairs(r.officers or {}) do person(o, "officer") end
			end
		end
	end
	for k, e in pairs(active) do
		if not seen[k] then
			seen[k] = true
			local g = group(e.g or "?", U.IsMainGuild(e.g or ""))
			local on = now - (e.t or 0) <= C.FRESH
			local has, version = addon(k, e.g, on)
			g.people[#g.people + 1] = { name = e.s, class = e.c, online = on, role = "active", guild = e.g, wrote = e.t, addon = has, version = version }
		end
	end
	for _, gk in ipairs(order) do
		local g = groups[gk]
		if #g.people > 0 then
			table.sort(g.people, ByRole)
			out[#out + 1] = { header = true, guild = g.guild, main = g.main, count = #g.people }
			for _, p in ipairs(g.people) do add(p) end
		end
	end
	return out, online
end

-- Подпись роли человека в списке справа.
function Views.Role(p)
	if p.role == "active" then return L.ROLE_ACTIVE end
	if p.rankName then return Codec.Plain(p.rankName) end -- своя гильдия: ранг из ростера
	if p.role == "leader" then return p.main and L.ROLE_KING or L.ROLE_LORD end
	if p.role == "officer" then return L.ROLE_CAPTAIN end
	return ""
end

function Views.PersonTip(tt, p)
	tt:AddLine(Views.Name(p.name, p.class))
	local role = Views.Role(p)
	tt:AddLine((role ~= "" and (role .. ", ") or "") .. Codec.Plain(p.guild or "?"), 0.8, 0.8, 0.8)
	if p.level and p.level > 0 then
		tt:AddLine(L.TIP_LEVEL:format(p.level) .. (p.class and L.CLASS[p.class] and (", " .. L.CLASS[p.class]) or ""), 0.8, 0.8, 0.8)
	end
	if p.zone and p.online then tt:AddLine(Codec.Plain(p.zone), 0.8, 0.8, 0.8) end
	if p.role ~= "active" then tt:AddLine(Views.State(p.online, p.days), 0.6, 0.6, 0.6) end
	if p.wrote then tt:AddLine(L.TIP_WROTE:format(Views.Ago(ns.ServerTime() - p.wrote)), 0.6, 0.6, 0.6) end
	if p.addon then
		tt:AddLine(Views.AddonText(p), 0.25, 1, 0.25)
	else
		tt:AddLine(Views.AddonText(p), 0.6, 0.6, 0.6)
	end
	tt:AddLine(L.TIP_CLICK_WHISPER, 0.5, 0.83, 0.76)
end

-- Строка подсказки про аддон у человека из списка: есть (с версией, если знаем), нет, неизвестно.
function Views.AddonText(p)
	if p.addon then
		local version = Codec.Plain(p.version)
		if version ~= "" then return L.TIP_ADDON_VERSION:format(version) end
		return L.TIP_ADDON_YES
	end
	if p.addon == false then return L.TIP_ADDON_NO end
	return L.TIP_ADDON_UNKNOWN
end

---------------------------------------------------------------------------
-- Кнопка у миникарты: подсказка
---------------------------------------------------------------------------
function Views.MinimapTip(tt)
	local status = Views.Status()
	tt:AddLine("Chillzone", 0.5, 0.83, 0.76)
	tt:AddLine(status.big, 1, 0.82, 0)
	tt:AddLine(status.small, 0.7, 0.7, 0.7)
	local tree = ns.Data.Kingdom()
	if tree.king then tt:AddLine(L.ROLE_KING .. ": " .. Views.Name(tree.king.leader, tree.king.leaderClass), 1, 0.82, 0) end
	tt:AddLine(" ")
	tt:AddLine(L.MINIMAP_LEFT, 0.6, 0.6, 0.6)
	tt:AddLine(L.MINIMAP_RIGHT, 0.6, 0.6, 0.6)
	tt:AddLine(L.MINIMAP_DRAG, 0.6, 0.6, 0.6)
end
