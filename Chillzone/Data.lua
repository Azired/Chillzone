-- Chillzone: хранилище отчётов переписи, проверки, ранги чужих гильдий, сводки для
-- окон и карты. Время — серверное (ns.ServerTime), чтобы отчёты разных клиентов сравнивались.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec

local Data = {}
ns.Data = Data

local claims = {} -- [originKey] = { g = guildKey, t = время }: одна гильдия на отправителя
Data.rejected = {} -- [причина] = сколько (для /chillzone status)

local function Guilds()
	return ns.store and ns.store.guilds or {}
end

local function Reject(why)
	Data.rejected[why] = (Data.rejected[why] or 0) + 1
	return false, why
end

-- Подпись руководства: глава, офицеры и связные. Разные свежие подписи от разных
-- отправителей — повод пометить гильдию «!».
function Data.Signature(r)
	local keys, vets = {}, {}
	for _, o in ipairs(r.officers or {}) do keys[#keys + 1] = (U.Key(o.name) or "?") .. ":" .. (o.rank or 1) end
	for _, o in ipairs(r.veterans or {}) do vets[#vets + 1] = U.Key(o.name) or "?" end
	table.sort(keys)
	table.sort(vets)
	return (U.Key(r.leader) or "") .. "|" .. table.concat(keys, ",") .. "|" .. table.concat(vets, ",")
end

function Data.ClaimGuild(originKey, guildKey, now)
	local c = claims[originKey]
	if c and c.g ~= guildKey and now - c.t < C.CLAIM_TTL then return false end
	claims[originKey] = { g = guildKey, t = now }
	return true
end

function Data.ResetClaims()
	claims = {}
end

local function MyGuildKey()
	local g = ns.MyGuild()
	return g and U.GuildKey(g) or nil
end

-- Свой отчёт (из своего ростера). Только он описывает мою гильдию.
function Data.SetLocal(r)
	if not r or not r.guild then return end
	local gk = U.GuildKey(r.guild)
	local guilds = Guilds()
	for k, row in pairs(guilds) do
		if row.mine and k ~= gk then row.mine = nil end
	end
	local now = ns.ServerTime()
	local row = guilds[gk] or {}
	row.guild, row.r, row.st, row.at, row.mine = r.guild, r, r.st or now, now, true
	row.raw, row.origin, row.sigs, row.conflict = nil, ns.me, nil, nil
	guilds[gk] = row
	ns.Fire("DATA")
end

-- Чужой отчёт: r — декодированный, raw — его текст R1, origin — автор (имя, как его
-- подписал сервер). Возвращает true или false, причина.
function Data.Take(r, raw, origin, now, ctx)
	now = now or ns.ServerTime()
	if not r or not origin then return Reject("пусто") end
	if not U.IsMemberGuild(r.guild) then return Reject("чужое название") end
	local gk = U.GuildKey(r.guild)
	if gk == MyGuildKey() then return Reject("своя гильдия") end
	if r.faction ~= ns.faction then return Reject("другая фракция") end
	local st = r.st or now
	if st > now + 300 then return Reject("время из будущего") end
	local ok = Data.ClaimGuild(U.Key(origin), gk, now)
	if not ok then return Reject("вторая гильдия") end
	local guilds = Guilds()
	local row = guilds[gk]
	if row and row.mine then return Reject("своя гильдия") end
	if row and row.st and st < row.st then return Reject("старее") end
	if row and row.st == st and row.raw == raw then return false, "повтор" end
	row = row or { sigs = {} }
	row.sigs = row.sigs or {}
	-- Подписи: свежие от разных отправителей должны совпадать.
	local sig = Data.Signature(r)
	row.sigs[U.Key(origin)] = { s = sig, t = now }
	local conflict, first = false, nil
	for k, e in pairs(row.sigs) do
		if now - e.t > C.FRESH then
			row.sigs[k] = nil
		elseif first == nil then
			first = e.s
		elseif e.s ~= first then
			conflict = true
		end
	end
	row.guild, row.r, row.raw, row.origin, row.st, row.at, row.conflict = r.guild, r, raw, U.Display(origin), st, now, conflict or nil
	row.signed = ctx and ctx.authenticated and ctx.wire or nil
	guilds[gk] = row
	ns.Fire("DATA")
	return true
end

function Data.Prune(now)
	now = now or ns.ServerTime()
	local guilds = Guilds()
	for k, row in pairs(guilds) do
		if type(row) ~= "table" or not row.r or now - (row.st or 0) > C.KEEP then guilds[k] = nil end
	end
end

function Data.Row(guild)
	return guild and Guilds()[U.GuildKey(guild)] or nil
end

function Data.IsFresh(row, now)
	return row ~= nil and (now or ns.ServerTime()) - (row.st or 0) <= C.FRESH
end

-- Отчёт главной гильдии (не старше суток) или nil.
function Data.Main(now)
	now = now or ns.ServerTime()
	local row = Data.Row(C.MAIN_GUILD)
	if row and now - (row.st or 0) <= C.TOTAL_KEEP then return row end
	return nil
end

---------------------------------------------------------------------------
-- Сводки
---------------------------------------------------------------------------

-- Строки для вкладки «Перепись»: главная гильдия первой, затем по онлайну и численности.
function Data.Summary(now)
	now = now or ns.ServerTime()
	local out = {}
	for _, row in pairs(Guilds()) do
		if row.r and U.IsMemberGuild(row.guild) and now - (row.st or 0) <= C.KEEP then
			local fresh = now - (row.st or 0) <= C.FRESH or row.mine
			local recent = now - (row.st or 0) <= C.TOTAL_KEEP or row.mine
			out[#out + 1] = {
				guild = row.guild, r = row.r, mine = row.mine, main = U.IsMainGuild(row.guild),
				fresh = fresh, recent = recent, age = now - (row.st or now), conflict = row.conflict,
				online = fresh and row.r.online or nil, total = recent and row.r.total or nil,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.main ~= b.main then return a.main end
		if (a.online or -1) ~= (b.online or -1) then return (a.online or -1) > (b.online or -1) end
		if (a.total or -1) ~= (b.total or -1) then return (a.total or -1) > (b.total or -1) end
		return a.guild < b.guild
	end)
	return out
end

function Data.Totals(now)
	local guilds, total, online = 0, 0, 0
	for _, s in ipairs(Data.Summary(now)) do
		if s.recent then
			guilds = guilds + 1
			total = total + (s.total or 0)
			online = online + (s.online or 0)
		end
	end
	return guilds, total, online
end

-- Дерево королевства: король (глава главной гильдии), его капитаны, лорды остальных
-- гильдий с их капитанами.
function Data.Kingdom(now)
	local tree = { king = nil, guilds = {} }
	for _, s in ipairs(Data.Summary(now)) do
		if s.recent then
			local r = s.r
			local node = {
				guild = s.guild, main = s.main, conflict = s.conflict, fresh = s.fresh,
				leader = r.leader, leaderOnline = s.fresh and r.leaderOnline or false,
				leaderClass = r.leaderClass, leaderLevel = r.leaderLevel, leaderDays = r.leaderDays,
				captains = {},
			}
			for _, o in ipairs(r.officers or {}) do
				node.captains[#node.captains + 1] = { name = o.name, online = s.fresh and o.online or false, class = o.class, level = o.level, rank = o.rank, days = o.days }
			end
			if s.main and r.leader then tree.king = node end
			tree.guilds[#tree.guilds + 1] = node
		end
	end
	return tree
end

-- Для карты: [zoneKey] = { total = n, guilds = { [название] = n } } по свежим отчётам.
function Data.ZoneCounts(now)
	local out = {}
	for _, s in ipairs(Data.Summary(now)) do
		if s.fresh then
			for zk, n in pairs(s.r.zones or {}) do
				local z = out[zk]
				if not z then
					z = { total = 0, guilds = {} }
					out[zk] = z
				end
				z.total = z.total + n
				z.guilds[s.guild] = (z.guilds[s.guild] or 0) + n
			end
		end
	end
	return out
end

-- Ответ на Q1: тексты последних чужих отчётов (не старше суток) с их авторами.
function Data.Cached(now)
	now = now or ns.ServerTime()
	local out = {}
	for gk, row in pairs(Guilds()) do
		if not row.mine and row.signed and row.origin and U.IsMemberGuild(row.guild) and now - (row.st or 0) <= C.TOTAL_KEEP then
			out[#out + 1] = { key = gk, raw = row.signed, origin = row.origin }
		end
	end
	return out
end

ns.On("LOGIN", function()
	Data.Prune()
	-- Сохранённые с прошлой сессии строки проверяются заново: декодер чистит поля.
	for k, row in pairs(Guilds()) do
		if row.raw and not row.mine then
			local r = Codec.DecodeReport(row.raw)
			if r then row.r = r else Guilds()[k] = nil end
		end
	end
end)
