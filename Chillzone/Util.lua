-- Chillzone: чистые помощники (без вызовов игры при загрузке): регистр кириллицы,
-- правило «своей» гильдии, имена WoW: Forever, хеш. Имена портированы из Olympus Core.lua.
local ADDON, ns = ...

local U = {}
ns.Util = U

local byte, char = string.byte, string.char

---------------------------------------------------------------------------
-- Регистр. string.lower в игре трогает только ASCII, поэтому заглавные А–Я и Ё
-- в UTF-8 переводятся вручную: А–П = D0 90–9F → D0 B0–BF, Р–Я = D0 A0–AF → D1 80–8F,
-- Ё = D0 81 → D1 91. Строчные буквы и всё прочее остаются как есть.
---------------------------------------------------------------------------
local function upperAP(c) return "\208" .. char(byte(c) + 32) end
local function upperRYa(c) return "\209" .. char(byte(c) - 32) end

function U.Fold(s)
	s = tostring(s or ""):lower()
	s = s:gsub("\208([\144-\159])", upperAP)
	s = s:gsub("\208([\160-\175])", upperRYa)
	s = s:gsub("\208\129", "\209\145")
	return s
end

-- Русская форма слова для числа: 1 участник, 2 участника, 5 участников (11–14 — как 5).
function U.Plural(n, one, few, many)
	n = math.abs(math.floor(tonumber(n) or 0))
	local d, dd = n % 10, n % 100
	if d == 1 and dd ~= 11 then return one end
	if d >= 2 and d <= 4 and (dd < 12 or dd > 14) then return few end
	return many
end

-- Число с пробелами между тысячами: 40830 → «40 830».
function U.Num(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local sign, digits = s:match("^(-?)(%d+)$")
	if not digits then return s end
	digits = digits:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return sign .. digits
end

function U.Trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Не больше n байт, никогда не полбуквы (кириллица — два байта).
function U.Cut(s, n)
	s = tostring(s or "")
	if #s <= n then return s end
	local b = byte(s, n + 1)
	while n > 0 and b and b >= 128 and b < 192 do
		n = n - 1
		b = byte(s, n + 1)
	end
	return s:sub(1, n)
end

-- Разбивка по разделителю (простой символ), пустые поля сохраняются.
function U.Split(s, sep)
	local out, i = {}, 1
	s = s or ""
	while true do
		local j = s:find(sep, i, true)
		if not j then
			out[#out + 1] = s:sub(i)
			return out
		end
		out[#out + 1] = s:sub(i, j - 1)
		i = j + #sep
	end
end

-- 32-битный хеш строки (djb2): одинаков у всех клиентов.
function U.Hash(s)
	local h = 5381
	s = tostring(s or "")
	for i = 1, #s do h = (h * 33 + byte(s, i)) % 4294967296 end
	return h
end

---------------------------------------------------------------------------
-- Версии аддона
---------------------------------------------------------------------------

-- «0.9.0» → { 0, 9, 0 }: от двух до четырёх чисел через точку, в каждом не больше четырёх
-- цифр. Иначе nil: сборки с хвостом («0.9.0-dev») и мусор ни с чем не сравниваются.
function U.ParseVersion(s)
	if type(s) ~= "string" or not s:find("^%d+%.%d+[%.%d]*$") or s:find("%.%.") or s:find("%.$") then return nil end
	local out = {}
	for n in s:gmatch("%d+") do
		if #n > 4 or #out == 4 then return nil end
		out[#out + 1] = tonumber(n)
	end
	return out
end

-- Версия a новее b. Сравниваются числа по порядку, недостающие — нули (0.9 = 0.9.0).
-- Нераспознанная версия не новее и не старше никакой.
function U.VersionNewer(a, b)
	local x, y = U.ParseVersion(a), U.ParseVersion(b)
	if not x or not y then return false end
	for i = 1, 4 do
		local p, q = x[i] or 0, y[i] or 0
		if p ~= q then return p > q end
	end
	return false
end

---------------------------------------------------------------------------
-- Гильдии
---------------------------------------------------------------------------
function U.IsMemberGuild(guild)
	if type(guild) ~= "string" or guild == "" then return false end
	if U.IsMainGuild(guild) then return true end
	local s = ns.store and ns.store.security
	local entry = s and s.union and s.union[U.GuildKey(guild)]
	return entry ~= nil and entry.active == true
end

function U.IsMainGuild(guild)
	return type(guild) == "string" and guild ~= "" and U.Fold(guild) == U.Fold(ns.Config.MAIN_GUILD)
end

-- Только поиск контактов для вступления. Совпадение названия не даёт членства,
-- сертификата или доступа к сети; адресат дополнительно сверяется с локальным /who.
function U.IsRecruitGuild(guild)
	local route = ns.Recruit and ns.Recruit.Route()
	return type(guild) == "string" and (U.IsMemberGuild(guild)
		or U.Fold(guild):find(U.Fold(ns.Config.GUILD_TOKEN), 1, true) ~= nil
		or (route ~= nil and route.byName[U.GuildKey(guild)] ~= nil))
end

-- Звание связного (Config.RELAY_RANK): название целиком, без учёта регистра и пробелов по краям.
function U.IsRelayRankName(rankName)
	local want = U.Trim(ns.Config.RELAY_RANK)
	if want == "" or type(rankName) ~= "string" then return false end
	return U.Fold(U.Trim(rankName)) == U.Fold(want)
end

-- Кому гильдия доверяет связь: "leader", "officer", "rank" (связной), "member" (любой
-- участник, пока Config.TRUST_ANY_MEMBER) или nil (рядовой). Только они бывают репортёрами,
-- в главной гильдии — реле, и только от них по GUILD принимаются пересланные чужие сообщения.
-- officer — офицерское ли звание (Roster.IsOfficerRank); nil — по Config.OFFICER_RANK.
function U.TrustRole(rank, rankName, officer)
	if type(rank) ~= "number" then return nil end
	if rank == 0 then return "leader" end
	if officer == nil then officer = rank <= ns.Config.OFFICER_RANK end
	if officer then return "officer" end
	if U.IsRelayRankName(rankName) then return "rank" end
	if ns.Config.TRUST_ANY_MEMBER then return "member" end
	return nil
end

-- Ключ гильдии для таблиц (регистр не важен).
function U.GuildKey(guild)
	return U.Fold(guild)
end

---------------------------------------------------------------------------
-- Реалмы и имена. На WoW: Forever имя — «Имя Фамилия», и функции игры отдают
-- фамилию на месте реалма: UnitFullName("player") = "Имя", "Фамилия", события —
-- "Имя-Фамилия", а сервер подписывает сообщения "Имя Фамилия-CAMWOWUS2Realm7PvE".
-- ns.splitNames — этот клиент так делит имена. Сравнивать имена можно только по Key.
---------------------------------------------------------------------------

-- Семья реалмов Forever: все "CAMWOW<регион><n>Realm<m><правила>" одних правил
-- делят гильдии, шёпот и перепись.
function U.ForeverFamily(realm)
	local rules = type(realm) == "string" and realm:match("^CAMWOW%u%u%d+Realm%d+(%a+)$") or nil
	return rules and ("Forever" .. rules) or nil
end

function U.GroupOf(realm)
	return U.ForeverFamily(realm) or realm
end

-- Реалм этого клиента в виде, как его пишет сервер в "Имя-Реалм".
function U.CurrentRealm()
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not realm or realm == "" then realm = ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "") end
	return realm ~= "" and realm or "?"
end

function U.IsRealmName(realm)
	if type(realm) ~= "string" or realm == "" then return false end
	if realm == ns.realm or U.ForeverFamily(realm) then return true end
	return realm == U.CurrentRealm()
end

-- Имя игрока из UnitFullName: (name, realm) → полное имя "Имя Фамилия-Реалм" и
-- признак splitNames. home — реалм клиента.
function U.ParsePlayer(name, realm, home)
	if not name or name == "" then return "?", false end
	local split = false
	if realm and realm ~= "" and realm ~= home and not U.IsRealmName(realm) then
		split = true
		name, realm = name .. " " .. realm, nil
	end
	if not realm or realm == "" then realm = home end
	if realm and realm ~= "" and realm ~= "?" then return name .. "-" .. realm, split end
	return name, split
end

-- Имя из событий игры ("Имя-Фамилия" на Forever) в виде, как его пишет сервер.
function U.Normal(name)
	if not ns.splitNames or type(name) ~= "string" then return name end
	local first, rest = name:match("^([^%-]+)%-(.+)$")
	if not first or first:find(" ", 1, true) then return name end
	local surname, realm = rest:match("^([^%-]+)%-(.+)$")
	if surname and U.IsRealmName(realm) then return first .. " " .. surname .. "-" .. realm end
	if U.IsRealmName(rest) then return name end
	return first .. " " .. rest
end

function U.ShortName(name)
	if type(name) ~= "string" then return nil end
	return (name:gsub("%-.*$", ""))
end

function U.FullName(name, realm)
	if type(name) ~= "string" or name == "" or name:find("-", 1, true) then return name end
	realm = realm or ns.realm
	if not realm or realm == "" or realm == "?" then return name end
	return name .. "-" .. realm
end

-- Имя для шёпота. На Forever сервер находит "Имя Фамилия", но не "Имя Фамилия-Реалм".
function U.TellName(name)
	if type(name) ~= "string" or name == "" then return name end
	name = U.Normal(name)
	local base, realm = name:match("^(.+)%-([^%-]+)$")
	if not realm then return name end
	if ns.splitNames then return base end
	if realm == ns.realm or realm == U.CurrentRealm() then return base end
	return name
end

-- Ключ личности: единственное, что можно сравнивать.
function U.Key(name)
	if type(name) ~= "string" or name == "" then return nil end
	return U.Fold(U.ShortName(U.Normal(name)))
end

-- Имя для показа: без реалма.
function U.Display(name)
	if type(name) ~= "string" then return "?" end
	return U.ShortName(U.Normal(name))
end

function U.SameName(a, b)
	local ka = U.Key(a)
	return ka ~= nil and ka == U.Key(b)
end
