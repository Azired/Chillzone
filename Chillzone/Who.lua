-- Chillzone: поиск участников сервером для вступления. Поиск и обход лимита 50 строк
-- адаптированы из Olympus Who.lua (MIT). Один запрос только из щелчка игрока.
-- Результат идёт в штатный список /who: чужие фреймы и их события не меняем.
local ADDON, ns = ...

local U, L = ns.Util, ns.L
local Who = { COOLDOWN = 10, TIMEOUT = 6, LATE = 30, ROUND_TTL = 900, MAX = 50, MAX_FOUND = 1000 }
ns.Who = Who
Who.found = {}
local lastSend, pending, roundAt, step, brackets = -math.huge, nil, nil, 0, nil
local target = 1
local byKey = {}
-- Гильдии, все участники которых в игре уже в списке: их нашёл запрос без диапазона
-- уровней, и сервер не обрезал выдачу до 50 строк.
local covered = {}
local hooked, legacyHooked, sending = nil, false, false
local lateUntil = -math.huge

-- Пост-хук не заменяет игровой поиск. Чужой /who отменяет ожидание нашего ответа,
-- иначе его строки могли бы попасть в наш список адресатов.
local function HookSearch()
	if type(hooksecurefunc) ~= "function" then return end
	local function OtherSearch()
		if sending then return end
		local p = pending
		if p then lateUntil = ns.Now() + Who.LATE end
		pending, lastSend = nil, ns.Now()
		if p and p.failed then p.failed() end
		ns.Fire("RECRUIT")
	end
	if C_FriendList and type(C_FriendList.SendWho) == "function" then
		if hooked == C_FriendList then return end
		hooked = C_FriendList
		hooksecurefunc(C_FriendList, "SendWho", OtherSearch)
	elseif type(SendWho) == "function" and not legacyHooked then
		legacyHooked = true
		hooksecurefunc("SendWho", OtherSearch)
	end
end

local function Plain(v)
	if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
	return v
end

local function Info(i)
	if C_FriendList and C_FriendList.GetWhoInfo then
		local row = C_FriendList.GetWhoInfo(i)
		if type(row) ~= "table" then return end
		return Plain(row.fullName), Plain(row.fullGuildName), Plain(row.level), Plain(row.filename) or Plain(row.classStr)
	elseif GetWhoInfo then
		local name, guild, level, _, class, _, file = GetWhoInfo(i)
		return Plain(name), Plain(guild), Plain(level), Plain(file) or Plain(class)
	end
end

-- Делим по увиденным уровням, чтобы на молодом сервере не искать пустые 40-60.
function Who.Brackets(levels, maxLevel)
	table.sort(levels)
	local out, low = {}, 1
	for i = 1, 4 do
		local cut = #levels >= 5 and levels[math.floor(i * #levels / 5)] or math.floor(i * maxLevel / 5)
		cut = math.min(cut, maxLevel - 1)
		if cut >= low then out[#out + 1], low = { low, cut }, cut + 1 end
	end
	out[#out + 1] = { low, maxLevel }
	return out
end

-- Сначала подсказка Config.GUILD_TOKEN, затем известные гильдии объединения и
-- названия из J2. Подсказка не даёт доступа: контакты проверяются серверным /who.
function Who.Targets()
	local C = ns.Config
	local out, extra, seen, token = { C.GUILD_TOKEN }, {}, {}, U.Fold(C.GUILD_TOKEN)
	local function Add(g)
		if type(g) ~= "string" then return end
		local key = U.GuildKey(g)
		if not seen[key] and not key:find(token, 1, true) then
			seen[key], extra[#extra + 1] = true, g
		end
	end
	for _, entry in ipairs(ns.Security.UnionGuilds()) do Add(entry.guild) end
	local route = ns.Recruit and ns.Recruit.Route()
	for guild in pairs(route and route.byName or {}) do Add(guild) end
	table.sort(extra, function(a, b) return U.Fold(a) < U.Fold(b) end)
	for _, guild in ipairs(extra) do out[#out + 1] = guild end
	return out
end

function Who.IsPending() return pending ~= nil end
function Who.Fresh() return roundAt ~= nil and ns.Now() - roundAt <= Who.ROUND_TTL end
-- В раунде остались запросы: диапазоны уровней, известные гильдии объединения или названия из J2.
function Who.RoundLeft() return Who.Fresh() and target <= #Who.Targets() end
function Who.Covered(guild) return Who.Fresh() and covered[U.GuildKey(guild)] == true end

function Who.Reset()
	pending, roundAt, step, brackets, target = nil, nil, 0, nil, 1
	Who.found, byKey, Who.missing, covered = {}, {}, false, {}
	Who.rangeCapped = nil
	ns.Fire("WHO", Who.found)
end

-- Можно ли сейчас отправить запрос: функция отправки или nil (причину уже сказали игроку).
local function Ready()
	local now = ns.Now()
	if pending or now < lateUntil or now - lastSend < Who.COOLDOWN then
		ns.Print(L.RECRUIT_SEARCH_WAIT)
		return nil
	end
	HookSearch()
	local send = C_FriendList and C_FriendList.SendWho or SendWho
	if type(send) ~= "function" then ns.Print(L.RECRUIT_NO_WHO); return nil end
	return send
end

local function Send(send, query, p)
	pending, lastSend = p, ns.Now()
	-- Не читаем чужой запоздалый ответ после тайм-аута. Следующий щелчок повторит диапазон.
	ns.After(Who.TIMEOUT, "поиск: тайм-аут", function()
		if pending ~= p then return end
		pending = nil
		lateUntil = ns.Now() + Who.LATE
		if p.failed then p.failed() end
		ns.Print(L.RECRUIT_SEARCH_TIMEOUT)
		ns.Fire("RECRUIT")
	end)
	sending = true
	local ok = pcall(function()
		if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true)
		elseif SetWhoToUI then SetWhoToUI(1) end
		send(query)
	end)
	sending = false
	if not ok then pending = nil; ns.Print(L.RECRUIT_NO_WHO); return false end
	ns.Print(L.RECRUIT_SEARCHING)
	ns.Fire("RECRUIT")
	return true
end

function Who.Search()
	if ns.IsMember() then return false end
	local send = Ready()
	if not send then return false end
	local targets = Who.Targets()
	if not Who.Fresh() or target > #targets then Who.Reset() end
	local query = ('g-"%s"'):format((targets[target]:gsub('["%c]', "")))
	if step > 0 and brackets then query = query .. (" %d-%d"):format(brackets[step][1], brackets[step][2]) end
	return Send(send, query, { target = target, step = step })
end

-- Один игрок по имени (офицер из подсказки J2, которого не нашёл поиск по гильдии). Его
-- строка добавляется в тот же список, только если /who видит его в гильдии Чиллзона;
-- раунд и диапазоны уровней не сдвигаются. На Forever работает /who "Имя Фамилия",
-- а n-"Имя Фамилия" ничего не находит. Ранга /who не показывает: его назвал J2.
-- failed вызывается, если ответа не было: тайм-аут или чужой /who.
function Who.Verify(name, failed)
	if ns.IsMember() or not Who.Fresh() or type(name) ~= "string" or name == "" then return false end
	local send = Ready()
	if not send then return false end
	return Send(send, ('"%s"'):format((name:gsub('["%c]', ""))), { side = "name", failed = failed })
end

-- Одна гильдия по названию из подсказки J2, где есть свободные места. Под общий запрос
-- по GUILD_TOKEN попадает вся большая главная гильдия, и её 50 строк заслоняют маленькие
-- гильдии; под этот — нет. Раунд и диапазоны уровней не сдвигаются.
function Who.SearchGuild(guild, failed)
	if ns.IsMember() or not Who.Fresh() or type(guild) ~= "string" or guild == "" then return false end
	local send = Ready()
	if not send then return false end
	return Send(send, ('g-"%s"'):format((guild:gsub('["%c]', ""))), { side = "guild", failed = failed })
end

local function OnAnswer()
	local p = pending
	if not p or ns.IsMember() then return end
	pending = nil
	local count, total
	if C_FriendList and C_FriendList.GetNumWhoResults then count, total = C_FriendList.GetNumWhoResults()
	elseif GetNumWhoResults then count, total = GetNumWhoResults() end
	count, total = tonumber(Plain(count)) or 0, tonumber(Plain(total)) or 0
	local capped = count >= Who.MAX or total > count
	local levels, maxLevel, seen = {}, (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60, {}
	maxLevel = tonumber(Plain(maxLevel)) or 60
	for i = 1, math.min(count, Who.MAX) do
		local name, guild, level, class = Info(i)
		if type(name) == "string" and type(guild) == "string" then
			-- fullGuildName может содержать суффикс реалма. Дефис внутри названия остаётся.
			local base, realm = guild:match("^(.-)%-([^%-]+)$")
			if base and U.IsRealmName(realm) then guild = base end
			name = U.Normal(name)
			local nameRealm = name:match("%-([^%-]+)$")
			local key = U.Key(name)
			if key and U.IsRecruitGuild(guild) and (not nameRealm or U.GroupOf(nameRealm) == ns.group) then
				seen[U.GuildKey(guild)] = true
				level = tonumber(level)
				if level and level >= 1 and level <= 255 then levels[#levels + 1] = level; maxLevel = math.max(maxLevel, level) end
				if not byKey[key] and #Who.found < Who.MAX_FOUND then
					local row = { name = name, guild = guild, level = level, class = class }
					Who.found[#Who.found + 1], byKey[key] = row, row
				elseif byKey[key] then
					local row = byKey[key]
					row.name, row.guild, row.level, row.class = name, guild, level, class
				end
			end
		end
	end
	-- Поиск по имени показывает одного игрока, а диапазон уровней — часть гильдии.
	if not capped and (p.side == "guild" or p.step == 0) then
		for gk in pairs(seen) do covered[gk] = true end
	end
	if p.side then
		ns.Fire("WHO", Who.found)
		return
	end
	if p.step == 0 then
		if p.target == 1 then roundAt = ns.Now() end
		brackets = capped and Who.Brackets(levels, maxLevel) or {}
		step = 1
	else
		step = p.step + 1
		Who.rangeCapped = Who.rangeCapped or capped
	end
	-- Диапазоны этого запроса пройдены: следующий щелчок ищет следующую гильдию.
	if step > #brackets then target, step, brackets = p.target + 1, 0, nil end
	Who.missing = target <= #Who.Targets() or Who.rangeCapped or false
	ns.Fire("WHO", Who.found)
end
ns.RegisterEvent("WHO_LIST_UPDATE", OnAnswer)
ns.On("GUILD_CHANGED", Who.Reset)
