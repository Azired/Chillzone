-- Chillzone: чтение ростера своей гильдии и отчёт переписи о ней.
-- Устроено как Olympus Roster.lua, без рас и построчного кэша.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config

local Roster = {}
ns.Roster = Roster

Roster.byKey = {} -- [Key] = rankIndex
Roster.rankKnown = {} -- [Key] = ранг действительно прочитан, а не заменён запасным значением
Roster.rankNames = {} -- [Key] = название звания
Roster.online = {} -- [Key] = в игре ли по последнему чтению ростера
Roster.members = {} -- строки ростера: { name, key, rank, rankName, level, class, zone, online, days }
Roster.report = nil -- последний отчёт о своей гильдии
Roster.guild = nil

local MIN_GAP = 20
local lastScan, pending = 0, false

local function RequestServerRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

local function DaysOffline(i, isOnline)
	if isOnline or not GetGuildRosterLastOnline then return 0 end
	local y, m, d, h = GetGuildRosterLastOnline(i)
	if not y then return 0 end
	return (y or 0) * 365 + (m or 0) * 30 + (d or 0) + (h or 0) / 24
end

-- Ранг игрока в моей гильдии (0 — глава) или nil, если его в ней нет.
function Roster.RankOf(name)
	local key = U.Key(name)
	return key and Roster.byKey[key] or nil
end

function Roster.MyRank()
	local _, rank = ns.MyGuild()
	return rank
end

function Roster.Fresh()
	local guild = ns.MyGuild()
	return guild ~= nil and Roster.guild == guild and Roster.scannedAt ~= nil
		and ns.Now() - Roster.scannedAt <= C.AUTH_ROSTER_TTL
end

-- Вышел ли согильдиец из игры после привета, услышанного в heardAt: свежий ростер прочитан
-- заметно позже привета и показывает его вне игры. Привет новее чтения важнее ростера: тот
-- мог не успеть узнать о входе, а снять с выборов живого репортёра хуже, чем подождать
-- следующего чтения.
function Roster.LeftGame(key, heardAt)
	if Roster.online[key] ~= false or not Roster.Fresh() then return false end
	return Roster.scannedAt - heardAt > C.ROSTER_LAG
end

---------------------------------------------------------------------------
-- Офицерские звания. Как в ChillZoneUnion 0.6: офицер — не ранг 0–1, а звание с игровым
-- флагом «офицер» (галочка OfficerCheckbox в настройках гильдии, флаг 22 у
-- C_GuildInfo.GuildControlGetRankFlags; звания там считаются с 1, ранги ростера — с 0).
-- Если игра флаг не сказала (нет API, ошибка, пустая или secret-таблица), офицер — звание
-- с номером не больше Config.OFFICER_RANK, как до подписей: иначе офицером остался бы один глава.
---------------------------------------------------------------------------
local OFFICER_FLAG = 22
local rankOfficer = {} -- [rankIndex] = true/false, сбрасывается при каждом скане

local function Secret(v)
	return type(issecretvalue) == "function" and issecretvalue(v)
end

-- Флаг «офицер» звания rankIndex в моей гильдии: true, false или nil (игра не сказала).
function Roster.RankFlagOfficer(rank)
	local info = rawget(_G, "C_GuildInfo")
	local get = type(info) == "table" and info.GuildControlGetRankFlags
	if type(get) ~= "function" then return nil end
	local ok, flag = pcall(function()
		local flags = get(rank + 1)
		if Secret(flags) or type(flags) ~= "table" or next(flags) == nil then return nil end
		local v = flags[OFFICER_FLAG]
		if Secret(v) or type(v) ~= "boolean" then return nil end
		return v
	end)
	if ok then return flag end
	return nil
end

-- Офицерское ли звание rankIndex в моей гильдии. Глава (0) — всегда. Без флага игры —
-- по номеру звания (Config.OFFICER_RANK).
function Roster.IsOfficerRank(rank)
	if type(rank) ~= "number" then return false end
	if rank == 0 then return true end
	local v = rankOfficer[rank]
	if v == nil then
		v = Roster.RankFlagOfficer(rank)
		if v == nil then v = rank <= C.OFFICER_RANK end
		rankOfficer[rank] = v
	end
	return v
end
-- Отсутствие строки или ранга не доказывает разжалование: ростер может скрывать офлайн.
function Roster.OfficerDemoted(name)
	local key = U.Key(name)
	return Roster.Fresh() and key ~= nil and Roster.rankKnown[key] == true
		and Roster.byKey[key] ~= nil and not Roster.IsOfficerRank(Roster.byKey[key])
end

-- Роль согильдийца в связи (U.TrustRole) по моему ростеру; nil — не в гильдии или рядовой
-- (когда Config.TRUST_ANY_MEMBER выключен).
function Roster.TrustOfKey(key)
	local rank = key and Roster.byKey[key]
	if rank == nil then return nil end
	return U.TrustRole(rank, Roster.rankNames[key], Roster.IsOfficerRank(rank))
end

function Roster.TrustOf(name)
	return Roster.TrustOfKey(U.Key(name))
end

-- Чистая сборка отчёта из строк ростера (для тестов и для Scan).
-- rows: { name, rank, rankName, officer, level, class, zoneKey, online, days }; officer nil —
-- по Config.OFFICER_RANK.
function Roster.Build(guild, rows, numOnline, faction, st)
	local r = {
		guild = guild, total = #rows, online = 0, users = 0,
		zones = {}, classes = {}, levels = { 0, 0, 0, 0, 0, 0, 0 },
		ranks = {}, officers = {}, veterans = {}, inactive7 = 0, inactive30 = 0,
		faction = faction, st = st,
	}
	local levelSum = 0
	for _, m in ipairs(rows) do
		local rank = m.rank or 9
		local slot = r.ranks[rank + 1]
		if not slot then
			slot = { name = m.rankName or ("Ранг " .. (rank + 1)), count = 0 }
			r.ranks[rank + 1] = slot
		end
		slot.count = slot.count + 1
		levelSum = levelSum + (m.level or 1)
		local days = m.days or 0
		if days >= 7 then r.inactive7 = r.inactive7 + 1 end
		if days >= 30 then r.inactive30 = r.inactive30 + 1 end
		local short = U.Display(m.name)
		local officer = m.officer
		if officer == nil then officer = rank <= C.OFFICER_RANK end
		if rank == 0 then
			r.leader, r.leaderOnline, r.leaderDays = short, m.online and true or false, math.floor(days)
			r.leaderClass, r.leaderLevel = m.class, m.level
		elseif officer then
			r.officers[#r.officers + 1] = { name = short, online = m.online and true or false, days = math.floor(days), class = m.class, level = m.level, rank = rank }
		elseif U.IsRelayRankName(m.rankName) then
			-- Связные: по ним другие гильдии узнают реле главной гильдии.
			r.veterans[#r.veterans + 1] = { name = short, online = m.online and true or false, days = math.floor(days), class = m.class, level = m.level, rank = rank }
		end
		if m.online then
			r.online = r.online + 1
			if m.zoneKey then r.zones[m.zoneKey] = (r.zones[m.zoneKey] or 0) + 1 end
			if m.class then r.classes[m.class] = (r.classes[m.class] or 0) + 1 end
			local b = math.min(7, math.floor((m.level or 1) / 10) + 1)
			r.levels[b] = r.levels[b] + 1
		end
	end
	-- Ранги без людей (дыры в нумерации) заполняются, чтобы список шёл по порядку.
	local maxRank = 0
	for k in pairs(r.ranks) do if k > maxRank then maxRank = k end end
	for i = 1, maxRank do r.ranks[i] = r.ranks[i] or { name = "Ранг " .. i, count = 0 } end
	if numOnline and numOnline > r.online then r.online = math.min(numOnline, r.total) end
	r.avgLevel = #rows > 0 and math.floor(levelSum / #rows * 10 + 0.5) / 10 or 0
	table.sort(r.officers, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.name < b.name
	end)
	table.sort(r.veterans, function(a, b) return a.name < b.name end)
	return r
end

function Roster.Scan()
	pending = false
	local guild = ns.MyGuild()
	if not guild or not GetNumGuildMembers then return end
	local numTotal, numOnline = GetNumGuildMembers()
	if not numTotal or numTotal == 0 then return end
	lastScan = ns.Now()
	rankOfficer = {} -- права званий могли поменяться
	local rows, byKey, rankNames, onlineByKey, rankKnown = {}, {}, {}, {}, {}
	for i = 1, numTotal do
		local name, rankName, rankIndex, level, _, zone, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
		if name then
			local key = U.Key(name)
			if key and byKey[key] == nil then
				rankKnown[key] = type(rankIndex) == "number"
				rankIndex = rankIndex or 9
				byKey[key] = rankIndex
				rankNames[key] = rankName
				local online = isOnline and true or false
				onlineByKey[key] = online
				rows[#rows + 1] = {
					name = U.Normal(name), key = key, rank = rankIndex, rankName = rankName,
					officer = Roster.IsOfficerRank(rankIndex),
					level = level or 1, class = classFile, online = online,
					zone = online and zone or nil,
					zoneKey = online and ns.Zones.KeyForName(zone) or nil,
					days = DaysOffline(i, isOnline),
				}
			end
		end
	end
	Roster.byKey, Roster.rankNames, Roster.members, Roster.guild = byKey, rankNames, rows, guild
	Roster.online = onlineByKey
	Roster.rankKnown = rankKnown
	Roster.scannedAt = ns.Now()
	local r = Roster.Build(guild, rows, numOnline, ns.faction, ns.ServerTime())
	if ns.Census then r.users = ns.Census.Users() end
	Roster.report = r
	ns.Fire("ROSTER", r)
end

function Roster.TryScan()
	if ns.Now() - lastScan < MIN_GAP and not pending then return end
	Roster.Scan()
end

function Roster.RequestScan(force)
	if not (IsInGuild and IsInGuild()) then return end
	if force then lastScan = 0 end
	pending = true
	RequestServerRoster()
	ns.After(4, "roster fallback", function()
		if pending then Roster.Scan() end
	end)
end

ns.RegisterEvent("GUILD_ROSTER_UPDATE", function()
	if pending then ns.After(1, "roster update", Roster.TryScan) end
end)

local guildChangeQueued = false
ns.RegisterEvent("PLAYER_GUILD_UPDATE", function(unit)
	if unit and unit ~= "player" then return end
	if guildChangeQueued or not ns.me then return end
	guildChangeQueued = true
	ns.After(2, "guild changed", function()
		guildChangeQueued = false
		if not ns.MyGuild() then
			Roster.byKey, Roster.rankNames, Roster.members, Roster.report, Roster.guild = {}, {}, {}, nil, nil
			Roster.online = {}
			Roster.rankKnown = {}
		end
		rankOfficer = {}
		Roster.RequestScan(true)
		ns.Fire("GUILD_CHANGED")
	end)
end)

-- Глава поменял права званий: офицеры могли стать другими.
local function RanksChanged()
	rankOfficer = {}
	if ns.me then Roster.RequestScan(true) end
end
ns.RegisterEvent("GUILD_RANKS_UPDATE", RanksChanged)
ns.RegisterEvent("GUILD_RANKS_UPDATE_ACTIVE_PLAYER", RanksChanged)

ns.On("LOGIN", function()
	ns.After(6, "first scan", function() Roster.RequestScan(true) end)
	ns.Every(C.SCAN_EVERY, "scan ticker", function() Roster.RequestScan() end)
end)
