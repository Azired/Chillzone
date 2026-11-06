-- Codec: отчёт, куски, чат, выборы.
local T = ...

local function fresh()
	local ns = T.load({ "Config.lua", "Util.lua", "Codec.lua" })
	return ns, ns.Codec
end

local function sample()
	return {
		guild = "Чиллзон Север",
		total = 87,
		online = 12,
		leader = "Фаладориэль Скайланс",
		leaderOnline = true,
		leaderDays = 0,
		leaderClass = "PALADIN",
		leaderLevel = 60,
		users = 5,
		zones = { m1453 = 6, ["tМёртвые копи"] = 2 },
		classes = { WARRIOR = 4, MAGE = 3, PRIEST = 2 },
		levels = { 1, 0, 2, 0, 3, 1, 5 },
		ranks = { { name = "Глава", count = 1 }, { name = "Офицер", count = 3 }, { name = "Рядовой", count = 83 } },
		officers = {
			{ name = "Иван Петров", online = true, days = 0, class = "MAGE", level = 60, rank = 1 },
			{ name = "Анна Ёлкина", online = false, days = 3, class = "PRIEST", level = 58, rank = 1 },
		},
		veterans = {
			{ name = "Пётр Связной", online = true, days = 0, class = "ROGUE", level = 60, rank = 2 },
		},
		inactive7 = 20,
		inactive30 = 9,
		avgLevel = 41.3,
		faction = "Horde",
		st = 1793000000,
	}
end

T.test("codec: отчёт туда и обратно с кириллицей", function()
	local _, Codec = fresh()
	local r = sample()
	local s = Codec.EncodeReport(r)
	local d = Codec.DecodeReport(s)
	T.ok(d, "декодировался")
	T.same(d, r, "round-trip")
end)

T.test("codec: отчёт прежней версии без связных читается", function()
	local _, Codec = fresh()
	local r = sample()
	local s = Codec.EncodeReport(r):gsub("~[^~]*$", "")
	local d = Codec.DecodeReport(s)
	T.ok(d, "декодировался")
	T.eq(#d.veterans, 0, "связных нет")
	T.eq(#d.officers, 2, "офицеры на месте")
end)

T.test("codec: невозможный отчёт отклоняется", function()
	local _, Codec = fresh()
	local r = sample()
	r.zones = { m1 = 50 }
	T.no(Codec.DecodeReport(Codec.EncodeReport(r)), "зон больше, чем онлайн")
	T.no(Codec.DecodeReport("R1~x"), "короткий")
	r = sample()
	r.total = 5000
	T.no(Codec.DecodeReport(Codec.EncodeReport(r)), "слишком большая гильдия")
	r = sample()
	r.guild = ("Ж"):rep(30)
	T.no(Codec.DecodeReport(Codec.EncodeReport(r)), "длинное название")
end)

T.test("codec: Shareable убирает зоны без согласия", function()
	local _, Codec = fresh()
	local r = sample()
	T.eq(next(Codec.Shareable(r, false).zones), nil, "без согласия")
	T.ok(next(Codec.Shareable(r, true).zones), "с согласием")
	T.ok(next(r.zones), "оригинал не тронут")
end)

T.test("codec: куски в любом порядке, дубли, сборка мусора", function()
	local _, Codec = fresh()
	local payload = Codec.EncodeReport(sample()) .. ("~" .. ("я"):rep(400))
	local parts = Codec.Chunk(payload, "a1")
	T.ok(#parts >= 4, "несколько кусков")
	for _, p in ipairs(parts) do T.ok(#p <= 255, "кусок влезает") end
	local asm = Codec.NewAssembler()
	local got
	for i = #parts, 1, -1 do
		got = Codec.Feed(asm, "Кто-то", parts[i], 0) or got
		if i == 2 then T.no(Codec.Feed(asm, "Кто-то", parts[i], 0), "дубль не завершает") end
	end
	T.eq(got, payload, "собрано")
	T.eq(asm.open, 0, "ничего не открыто")
	Codec.Feed(asm, "Б", parts[1], 0)
	T.eq(asm.open, 1, "открыто")
	T.eq(Codec.Gc(asm, 30), 0, "рано")
	T.eq(Codec.Gc(asm, 61), 1, "выброшено")
	T.eq(asm.open, 0, "закрыто")
end)

T.test("codec: сборщик ограничен на отправителя", function()
	local _, Codec = fresh()
	local asm = Codec.NewAssembler()
	for i = 1, Codec.OPEN_PER_SENDER + 2 do Codec.Feed(asm, "Спамер", ("C%d:1:2:x"):format(i), 0) end
	T.eq(asm.bySender["Спамер"], Codec.OPEN_PER_SENDER, "не больше лимита")
	T.eq(asm.refused, 2, "лишние отклонены")
end)

T.test("codec: Pack режет только длинное", function()
	local _, Codec = fresh()
	T.eq(#Codec.Pack("H1~0.1.0~z", "1"), 1, "короткое целиком")
	T.ok(#Codec.Pack(("я"):rep(200), "1") > 1, "длинное кусками")
end)

local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт, Благословенный клинок Искателя Ветра]|h|r"

T.test("codec: SanitizeChat пропускает ссылку и экранирует остальное", function()
	local _, Codec = fresh()
	T.eq(Codec.SanitizeChat("смотри " .. LINK .. " !"), "смотри " .. LINK .. " !", "ссылка цела")
	T.eq(Codec.SanitizeChat("|TInterface\\x:0|t"), "||TInterface\\x:0||t", "текстура — текстом")
	T.eq(Codec.SanitizeChat("a\nb"), "ab", "перевод строки убран")
	local once = Codec.SanitizeChat("x | y " .. LINK)
	T.eq(Codec.SanitizeChat(once), once, "идемпотентно")
end)

T.test("codec: SplitChat режет 600 байт кириллицы по буквам", function()
	local ns, Codec = fresh()
	local word = "привет "
	local s = Codec.SanitizeChat(word:rep(43)) -- ~600 байт
	local parts, cut = Codec.SplitChat(s, 200, 3)
	T.eq(#parts, 3, "три части")
	T.ok(cut == false or cut == true, "флаг")
	for _, p in ipairs(parts) do
		T.ok(#p <= 200, "часть влезает")
		T.eq(ns.Util.Cut(p, #p), p, "целые буквы")
		T.no(p:find("^%s") or p:find("%s$"), "без пробелов по краям")
	end
	local parts2 = Codec.SplitChat(("я"):rep(150) .. " " .. LINK, 200, 3)
	for _, p in ipairs(parts2) do
		if p:find("|H", 1, true) then T.ok(p:find(LINK, 1, true), "ссылка не разрезана") end
	end
end)

T.test("codec: чат туда и обратно", function()
	local _, Codec = fresh()
	local m = Codec.EncodeChat("A", "Чиллзон", 12345, "MAGE", "привет ~ всем: " .. LINK)
	T.ok(m and #m <= 255, "влезает")
	local d = Codec.DecodeChat(m)
	T.eq(d.tier, "A", "уровень")
	T.eq(d.guild, "Чиллзон", "гильдия")
	T.eq(d.id, 2345, "id по модулю")
	T.eq(d.class, "MAGE", "класс")
	T.eq(d.text, "привет ~ всем: " .. LINK, "текст")
	T.no(Codec.DecodeChat("M1~X~g~1~~t"), "неверный уровень")
end)

T.test("codec: привет и конверты реле", function()
	local _, Codec = fresh()
	local fp = "0123456789abcdef"
	local h = Codec.DecodeHello(Codec.EncodeHello("0.1.0", true, false, fp))
	T.ok(h.zones and not h.relay, "флаги")
	T.eq(h.fp, fp, "сертификат объявлен в H1")
	T.eq(Codec.DecodeHello("H1~0.4.1~zr").fp, nil, "старый H1 читается без сертификата")
	T.no(Codec.DecodeHello("H1~0.4.1~zr~short"), "неверный отпечаток отклонён")
	local inner = Codec.EncodeChat("A", "Чиллзон", 1, "", "ссылка " .. LINK)
	local kind, _, _, got = Codec.DecodeRelay(Codec.EncodeRL("P", inner))
	T.eq(kind, "RL", "RL")
	T.eq(got, inner, "RL байт в байт")
	local _, _, origin, gotM = Codec.DecodeRelay(Codec.EncodeRM("RM", "P", "Иван Петров", inner))
	T.eq(origin, "Иван Петров", "origin")
	T.eq(gotM, inner, "RM байт в байт")
	T.no(Codec.DecodeRelay(Codec.EncodeRL("P", "H1~0.1.0~")), "внутри только R1 и M1")
	local list = Codec.DecodeRelayList(Codec.EncodeRelayList({ "Иван Петров", "Анна Ёлкина" }))
	T.eq(#list, 2, "gossip")
	T.eq(list[2], "Анна Ёлкина", "имя")
end)

T.test("codec: выборы одинаковы у всех и предпочитают делящихся зонами", function()
	local _, Codec = fresh()
	local now = 1000
	local all = { ["анна"] = { z = false }, ["борис"] = { z = false }, ["вера"] = { z = false } }
	local function pick(me, zonesOf)
		local peers = {}
		for k in pairs(all) do
			if k ~= me then peers[k] = { t = now - 10, z = zonesOf[k] or false } end
		end
		return Codec.PickReporter(me, zonesOf[me] or false, peers, now, 180)
	end
	for me in pairs(all) do T.eq(pick(me, {}), "анна", "наименьший ключ у " .. me) end
	for me in pairs(all) do T.eq(pick(me, { ["вера"] = true }), "вера", "делящийся зонами у " .. me) end
	for me in pairs(all) do T.eq(pick(me, { ["вера"] = true, ["борис"] = true }), "борис", "наименьший из делящихся у " .. me) end
	local stale = { ["аааа"] = { t = now - 500, z = true } }
	T.eq(Codec.PickReporter("борис", false, stale, now, 180), "борис", "старый пир не в счёт")
end)

T.test("codec: репортёр — только из доверенных", function()
	local _, Codec = fresh()
	local now = 1000
	local all = { ["анна"] = true, ["борис"] = true, ["вера"] = true }
	local trusted = { ["борис"] = true, ["вера"] = true }
	local function ok(k) return trusted[k] == true end
	local function pick(me, zonesOf)
		local peers = {}
		for k in pairs(all) do
			if k ~= me then peers[k] = { t = now - 10, z = zonesOf[k] or false } end
		end
		return Codec.PickReporter(me, zonesOf[me] or false, peers, now, 180, ok)
	end
	for me in pairs(all) do T.eq(pick(me, {}), "борис", "рядовая Анна не выбирается у " .. me) end
	for me in pairs(all) do T.eq(pick(me, { ["анна"] = true }), "борис", "зоны рядовой не в счёт у " .. me) end
	for me in pairs(all) do T.eq(pick(me, { ["вера"] = true }), "вера", "делящийся зонами доверенный у " .. me) end
	T.eq(Codec.PickReporter("анна", false, {}, now, 180, ok), nil, "одна рядовая — репортёра нет")
end)

T.test("codec: выбор реле стабилен в окне", function()
	local _, Codec = fresh()
	local keys = { "в", "а", "б" }
	local a = Codec.PickRelay("чиллзон север", keys, 1200)
	T.eq(Codec.PickRelay("чиллзон север", { "б", "в", "а" }, 1799), a, "порядок не важен")
	T.eq(Codec.PickRelay("x", {}, 0), nil, "пусто")
end)
