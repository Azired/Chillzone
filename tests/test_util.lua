-- Util: регистр кириллицы, правило гильдии, имена Forever.
local T = ...

local function fresh()
	local ns = T.load({ "Config.lua", "Util.lua" })
	return ns, ns.Util
end

T.test("util: Fold переводит все заглавные А–Я и Ё", function()
	local _, U = fresh()
	local upper = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
	local lower = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
	T.eq(U.Fold(upper), lower, "алфавит")
	T.eq(U.Fold(lower), lower, "строчные не меняются")
	T.eq(U.Fold("ABC xyz 123"), "abc xyz 123", "ascii")
	T.eq(U.Fold("Чиллзон Север"), "чиллзон север", "смешанное")
end)

T.test("util: правило своей гильдии", function()
	local _, U = fresh()
	T.ok(U.IsMemberGuild("Чиллзон"), "Чиллзон")
	T.no(U.IsMemberGuild("ЧИЛЛЗОН Север"), "без решения главы не участник")
	T.no(U.IsMemberGuild("Орден Чиллзона"), "название не даёт членства")
	T.ok(U.IsMemberGuild("чиллзон"), "строчные")
	T.no(U.IsMemberGuild("Chillzone"), "латиница")
	T.no(U.IsMemberGuild("Чилзон"), "одна л")
	T.no(U.IsMemberGuild("Чиллз" .. "o" .. "н"), "латинская o")
	T.no(U.IsMemberGuild(""), "пусто")
	T.no(U.IsMemberGuild(nil), "nil")
	T.ok(U.IsMainGuild("ЧИЛЛЗОН"), "главная без учёта регистра")
	T.no(U.IsMainGuild("Чиллзон Север"), "не главная")
end)

T.test("util: сохранённый состав объединения", function()
	local ns, U = fresh()
	ns.store = { security = { union = { [U.GuildKey("Чиллзон Север")] = { active = true },
		[U.GuildKey("Другая гильдия")] = { active = true } } } }
	T.ok(U.IsMemberGuild("чиллзон север"), "в списке")
	T.ok(U.IsMemberGuild("Другая гильдия"), "любое название")
	T.no(U.IsMemberGuild("Орден Чиллзона"), "не в списке")
	T.no(U.IsMemberGuild("Запомни Навсегда"), "без решения главы не участник")
end)

T.test("util: добавленная гильдия без токена в названии", function()
	local ns, U = fresh()
	ns.store = { security = { union = { [U.GuildKey("Запомни Навсегда")] = { active = true } } } }
	T.ok(U.IsMemberGuild("Запомни Навсегда"), "Запомни Навсегда")
	T.ok(U.IsMemberGuild("ЗАПОМНИ НАВСЕГДА"), "без учёта регистра")
	T.no(U.IsMemberGuild("Запомни"), "только название целиком")
	T.no(U.IsMemberGuild("Запомни Навсегда 2"), "не подстрока")
	T.no(U.IsMainGuild("Запомни Навсегда"), "не главная")
	ns.store.security.union = {}
	T.no(U.IsMemberGuild("Запомни Навсегда"), "без списка не подходит")
end)

T.test("util: Cut не режет букву пополам", function()
	local _, U = fresh()
	T.eq(U.Cut("Привет", 3), "П", "3 байта → одна буква")
	T.eq(U.Cut("Привет", 4), "Пр", "4 байта")
	T.eq(U.Cut("abc", 10), "abc", "короче")
end)

T.test("util: семья реалмов Forever", function()
	local _, U = fresh()
	T.eq(U.ForeverFamily("CAMWOWUS2Realm7PvE"), "ForeverPvE", "PvE")
	T.eq(U.GroupOf("CAMWOWEU1Realm12PvP"), "ForeverPvP", "PvP")
	T.eq(U.GroupOf("Gehennas"), "Gehennas", "обычный реалм")
end)

T.test("util: имена Forever", function()
	local ns, U = fresh()
	local home = "CAMWOWUS2Realm7PvE"
	ns.realm = home
	local full, split = U.ParsePlayer("Фаладориэль", "Скайланс", home)
	T.ok(split, "splitNames")
	T.eq(full, "Фаладориэль Скайланс-" .. home, "полное имя")
	ns.splitNames = split
	T.eq(U.Normal("Фаладориэль-Скайланс"), "Фаладориэль Скайланс", "имя из события")
	T.eq(U.Normal("Фаладориэль-Скайланс-CAMWOWUS2Realm3PvE"), "Фаладориэль Скайланс-CAMWOWUS2Realm3PvE", "с реалмом")
	T.eq(U.Normal("Фаладориэль Скайланс-CAMWOWUS2Realm3PvE"), "Фаладориэль Скайланс-CAMWOWUS2Realm3PvE", "как пишет сервер")
	local k = U.Key("Фаладориэль Скайланс-CAMWOWUS2Realm3PvE")
	T.eq(k, U.Key("фаладориэль-скайланс"), "Key одинаков")
	T.eq(k, U.Key(full), "Key своего имени")
	T.eq(U.TellName("Фаладориэль Скайланс-CAMWOWUS2Realm3PvE"), "Фаладориэль Скайланс", "шёпот без реалма")
	T.eq(U.Display("Фаладориэль-Скайланс"), "Фаладориэль Скайланс", "показ")
	T.no(U.SameName("Иван Петров", "Иван Сидоров"), "разные")
end)

T.test("util: имена обычного реалма", function()
	local ns, U = fresh()
	ns.realm = "Gehennas"
	local full, split = U.ParsePlayer("Arthas", nil, "Gehennas")
	T.no(split, "без деления")
	T.eq(full, "Arthas-Gehennas", "полное")
	T.eq(U.TellName("Arthas-Gehennas"), "Arthas", "свой реалм")
	T.eq(U.TellName("Jaina-Firemaw"), "Jaina-Firemaw", "чужой реалм")
	T.eq(U.Key("Arthas-Gehennas"), "arthas", "Key")
end)

T.test("util: Split и Hash", function()
	local _, U = fresh()
	local p = U.Split("a~~b~", "~")
	T.eq(#p, 4, "пустые поля")
	T.eq(p[3], "b", "третье")
	T.eq(U.Hash("abc"), U.Hash("abc"), "детерминирован")
	T.ok(U.Hash("abc") ~= U.Hash("abd"), "различает")
	T.ok(U.Hash(("я"):rep(500)) < 4294967296, "32 бита")
end)

T.test("util: Plural и Num", function()
	local _, U = fresh()
	local function p(n) return U.Plural(n, "гильдия", "гильдии", "гильдий") end
	T.eq(p(1), "гильдия", "1")
	T.eq(p(2), "гильдии", "2")
	T.eq(p(4), "гильдии", "4")
	T.eq(p(5), "гильдий", "5")
	T.eq(p(0), "гильдий", "0")
	T.eq(p(11), "гильдий", "11")
	T.eq(p(12), "гильдий", "12")
	T.eq(p(14), "гильдий", "14")
	T.eq(p(21), "гильдия", "21")
	T.eq(p(22), "гильдии", "22")
	T.eq(p(111), "гильдий", "111")
	T.eq(p(966), "гильдий", "966")
	T.eq(U.Num(0), "0", "ноль")
	T.eq(U.Num(966), "966", "сотни")
	T.eq(U.Num(1000), "1 000", "тысяча")
	T.eq(U.Num(40830), "40 830", "как у Olympus")
	T.eq(U.Num(1234567), "1 234 567", "миллион")
	T.eq(U.Num(-1500), "-1 500", "минус")
end)
