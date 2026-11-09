-- Обычный /г попадает в канал A только в аддоне; сеть проверяем настоящей доставкой.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт]|h|r"

local function PlainClient(w, guild, surname)
	local c = { first = "Игрок", surname = surname, realm = "CAMWOWUS2Realm7PvE", faction = "Alliance",
		guild = guild, rank = 3, level = 60, class = "MAGE", zone = "Штормград", online = true, lines = {} }
	function c:Name() return self.first .. " " .. self.surname end
	function c:Guid() return "Player-" .. self.surname end
	function c:Fire(event, text)
		if event == "CHAT_MSG_GUILD" then self.lines[#self.lines + 1] = text end
	end
	w.clients[#w.clients + 1] = c
	return c
end

local function Wait(w, ready, seconds)
	for _ = 1, seconds / 10 do
		if ready() then return true end
		w:Run(10)
	end
	return ready()
end

local function Build(opts)
	opts = opts or {}
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 11)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local headA = w:Client({ first = "Глава", surname = "Юга", guild = "Чиллзон", rank = 0, bridge = opts.bridgeA })
	local headB = w:Client({ first = "Глава", surname = "Севера", guild = "Чиллзон Север", rank = 0, bridge = opts.bridgeB })
	local a = w:Client({ first = "Связной", surname = "Юга", guild = headA.guild, rank = 3 })
	local b = w:Client({ first = "Связной", surname = "Севера", guild = headB.guild, rank = 3 })
	local observer = w:Client({ first = "Яков", surname = "Юга", guild = a.guild, rank = 3 })
	local plainA = PlainClient(w, a.guild, "Юга")
	local plainB = PlainClient(w, b.guild, "Севера")
	w:Run(30)
	w:Init(headA, headB)
	w:Pair(headB, headA)
	w:Run(180)
	return w, a, b, observer, plainA, plainB, headA, headB
end

local function Pair(w, a, b, headA, headB)
	T.ok(b.ns.Security.Member(a.guild, a:Name()),
		"будущий связной заранее получил проверенный сертификат запасного реле от своей гильдии")
	headA:Logout()
	headB:Logout()
	T.ok(Wait(w, function() return a.ns.GuildBridge.Ready(b.guild) and b.ns.GuildBridge.Ready(a.guild) end, 1600),
		"рядовые участники стали связными без ручной передачи сертификатов")
end

local function History(c, guild, author, text, class, at)
	local count = 0
	for _, e in ipairs(c.ns.Chat.History("A")) do
		if e.x == text then
			T.eq(e.s, author:Name(), "исходное имя, не имя связного")
			T.eq(e.g, guild, "исходная гильдия")
			if class then T.eq(e.c, class, "сохранился класс автора") end
			if at then T.eq(e.t, at, "время исходной реплики, не время пересылки") end
			count = count + 1
		end
	end
	return count
end

local function FireGuild(c, author, text, lineID)
	local stamp = author:Name() .. "-" .. author.realm
	c:Fire("CHAT_MSG_GUILD", text, stamp, "", "", stamp, "", 0, 0, "", 0, lineID, author:Guid())
end

local function NativeCount(w)
	local count = 0
	for _, packet in ipairs(w.log) do if packet.native and packet.dist == "GUILD" then count = count + 1 end end
	return count
end

local function NoErrors(...)
	for _, c in ipairs({ ... }) do T.eq(#c.ns.db.errors, 0, table.concat(c.ns.db.errors, " | ")) end
end

T.test("guild bridge: локальный /г сразу виден в A без сертификата и соседей", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Читатель", surname = "Первый", guild = "Чиллзон", rank = 3 })
	local plain = PlainClient(w, c.guild, "Безаддона")
	w:Run(10)
	T.no(c.ns.Security.MyCertificate())
	T.no(c.ns.GuildBridge.Ready())
	local text = "местная реплика " .. LINK
	FireGuild(c, plain, text, 100)
	T.eq(History(c, c.guild, plain, text, "MAGE"), 1, "не ждём таймер, подпись или связь")
	T.eq(c:Saw(text), 0, "импорт не копируется в игровой чат")
	T.eq(c.ns.Chat.History("G")[1].x, text, "история гильдии сохранена")
	FireGuild(c, plain, text, 100)
	T.eq(History(c, c.guild, plain, text), 1, "повтор игрового события не дублирует A")
	FireGuild(c, plain, text, 101)
	T.eq(History(c, c.guild, plain, text), 2, "новая одинаковая реплика сохраняется")
	NoErrors(c)
end)

T.test("guild bridge: старый выбранный репортёр не мешает локальному импорту", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build({ bridgeA = "none" })
	T.eq(a.ns.Census.Reporter(), headA.ns.myKey)
	T.eq(headA.ns.GuildBridge, nil)
	local text = "репортёр ещё не обновлён"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(0.1)
	T.eq(History(a, a.guild, plainA, text, "MAGE"), 1)
	T.eq(History(observer, a.guild, plainA, text), 1)
	w:Run(30)
	T.eq(History(b, a.guild, plainA, text), 0, "обычный клиент не захватывает роль связного")
	T.eq(#plainB.lines, 0)
	T.eq(NativeCount(w), 1)
	NoErrors(a, b, observer, headA, headB)
end)

T.test("guild bridge: поздний читатель узнаёт запасное реле по Q1 и заменяет ушедших связных", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	T.ok(Wait(w, function()
		return headA.ns.GuildBridge.Ready(b.guild) and headB.ns.GuildBridge.Ready(a.guild)
	end, 1600))
	-- Сертификаты тройки уже разосланы, а до их очередного продления ещё далеко.
	-- Новичку нужны они из ответа своей гильдии на Q1, не личный случайный опрос корня.
	w:Run(180)
	local late = w:Client({ first = "Новый", surname = "Севера", guild = b.guild, rank = 3 })
	T.no(late.ns.Security.Member(a.guild, a:Name()), "до синхронизации сертификата нет")
	w:Run(180)
	T.ok(late.ns.Security.MyCertificate())
	T.no(late.ns.Census.IsReporter(), "пока глава в сети, новичок остаётся читателем")
	T.ok(late.ns.Security.Member(a.guild, a:Name()), "Q1 принёс проверенный сертификат живого запасного реле")
	local requested = false
	for _, packet in ipairs(w.log) do
		if packet.from == late:Name() and packet.dist == "GUILD" and packet.msg == "Q1~" then requested = true end
	end
	T.ok(requested, "новичок запросил снимок обычным Q1")
	headA:Logout()
	headB:Logout()
	b:Logout()
	T.ok(Wait(w, function()
		return a.ns.GuildBridge.Ready(late.guild) and late.ns.GuildBridge.Ready(a.guild)
	end, 1600), "поздний читатель сам восстановил связь после выхода прежнего руководства")
	local text = "поздний читатель продолжил связь"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(15)
	T.eq(History(late, a.guild, plainA, text, "MAGE"), 1)
	T.eq(History(observer, a.guild, plainA, text, "MAGE"), 1)
	T.eq(#plainB.lines, 0)
	T.eq(NativeCount(w), 1)
	NoErrors(a, late, observer)
end)

T.test("guild bridge: подписанное членство ограничивает получателей импорта", function()
	local w, a, b, _, plainA, plainB, headA, headB = Build()
	local outside = w:Guild("Чиллзон Восток").name
	local headX = w:Client({ first = "Глава", surname = "Востока", guild = outside, rank = 0 })
	local plainX = PlainClient(w, outside, "Востока")
	w:Run(30)
	w:Init(headX)
	T.no(headX.ns.IsMember(), "похожее название не даёт членства")
	T.ok(Wait(w, function()
		return headA.ns.GuildBridge.Ready(b.guild) and headB.ns.GuildBridge.Ready(a.guild)
	end, 1600))
	local text = "переслать только в союз"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(15)
	T.eq(History(b, a.guild, plainA, text), 1)
	T.eq(History(headX, a.guild, plainA, text), 0)
	T.same(plainA.lines, { text })
	T.eq(#plainB.lines, 0, "игрок без аддона не читает союз")
	T.eq(#plainX.lines, 0)
	T.eq(NativeCount(w), 1, "мост ничего не пишет в /г")
	T.ok(headA.ns.Security.RemoveGuild(b.guild))
	T.no(headA.ns.GuildBridge.Ready(b.guild))
	local removed = "после исключения"
	w:GuildSay(plainA, removed, "GUILD")
	w:Run(15)
	T.eq(History(a, a.guild, plainA, removed), 1)
	T.eq(History(b, a.guild, plainA, removed), 0)
	for _, packet in ipairs(w.log) do
		T.no(packet.msg:sub(1, 5) == "BM~2~" and packet.msg:find(removed, 1, true))
	end
end)

T.test("guild bridge: чужая и своя реплики, повторы событий и пакетов не дублируют A", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	T.no(observer.ns.GuildBridge.Ready())
	local packet, historyPacket, deliver = nil, nil, w.Deliver
	function w:Deliver(from, dist, prefix, msg, target, logged)
		if from == a and dist == "WHISPER" and msg:sub(1, 5) == "BM~2~" then
			packet = msg
			-- Подмена пересылающего отбрасывается даже при верном содержимом.
			deliver(self, observer, dist, prefix, msg, target, logged)
		end
		if from == a and dist == "GUILD" and msg:sub(1, 5) == "BT~2~" then historyPacket = msg end
		return deliver(self, from, dist, prefix, msg, target, logged)
	end
	local foreign, own = "реплика без аддона", "реплика связного"
	local sentAt = a.ns.ServerTime()
	w:GuildSay(plainA, foreign, "GUILD")
	local lineID = w.guildLineID
	w:Run(5)
	T.ok(packet)
	T.same(plainA.lines, { foreign })
	T.eq(#plainB.lines, 0)
	for _, c in ipairs({ a, b, observer }) do T.eq(History(c, a.guild, plainA, foreign, "MAGE", sentAt), 1) end
	FireGuild(a, plainA, foreign, lineID)
	FireGuild(observer, plainA, foreign, lineID)
	local packetAt = assert(tonumber(a.ns.Util.Split(packet, "~")[8]))
	T.ok(b.ns.ServerTime() - packetAt < 15, "повтор BM свежий, его должен остановить дедуп, не срок")
	deliver(w, a, "WHISPER", a.ns.PREFIX, packet, b:Name(), true)
	local ownAt = b.ns.ServerTime()
	w:GuildSay(b, own, "GUILD")
	w:Run(10)
	T.ok(historyPacket, "принимающая гильдия получила BT")
	local historyAt = assert(tonumber(a.ns.Util.Split(historyPacket, "~")[7]))
	T.ok(observer.ns.ServerTime() - historyAt < 30, "повтор BT свежий, его должен остановить дедуп, не срок")
	deliver(w, a, "GUILD", a.ns.PREFIX, historyPacket, nil, true)
	w:Run(1)
	T.same(plainA.lines, { foreign })
	T.same(plainB.lines, { own })
	T.eq(NativeCount(w), 2)
	for _, c in ipairs({ a, b, observer }) do
		T.eq(History(c, a.guild, plainA, foreign), 1)
		T.eq(History(c, b.guild, b, own, "MAGE", ownAt), 1, "повтор BT не меняет историю")
		T.eq(c:Saw(foreign), 0, "импорт только в окне аддона")
		T.eq(c:Saw(own), 0)
	end
	NoErrors(a, b, observer)
end)

T.test("guild bridge: одинаковые тексты разных сообщений доходят дважды со ссылкой и классом", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	plainA.class = "WARRIOR"
	a.ns.Roster.Scan()
	observer.ns.Roster.Scan()
	local text = "Смотри " .. LINK .. " ~ : , ="
	w:GuildSay(plainA, text, "GUILD")
	w:Run(2)
	w:GuildSay(plainA, text, "GUILD")
	w:Run(20)
	for _, c in ipairs({ a, b, observer }) do T.eq(History(c, a.guild, plainA, text, "WARRIOR"), 2) end
	T.same(plainA.lines, { text, text })
	T.eq(#plainB.lines, 0)
	T.eq(NativeCount(w), 2)
	NoErrors(a, b, observer)
end)

T.test("guild bridge: игнор и chat off действуют локально, пересылка другим продолжается", function()
	local w, a, b, observer, plainA, _, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local key = a.ns.Util.Key(plainA:Name())
	a.ns.store.ignore[key] = plainA:Name()
	b.ns.store.ignore[key] = plainA:Name()
	observer.ns.char.chatOn = false
	local first = "скрытая по настройкам"
	w:GuildSay(plainA, first, "GUILD")
	w:Run(15)
	for _, c in ipairs({ a, b, observer }) do T.eq(History(c, a.guild, plainA, first), 0) end
	b.ns.store.ignore[key] = nil
	local second = "доставка при игноре у связного"
	w:GuildSay(plainA, second, "GUILD")
	w:Run(15)
	T.eq(History(a, a.guild, plainA, second), 0)
	T.eq(History(observer, a.guild, plainA, second), 0)
	T.eq(History(b, a.guild, plainA, second), 1, "связной скрывает строку только для себя")
	NoErrors(a, b, observer)
end)

T.test("guild bridge: /о и старые читаемые копии не импортируются в A", function()
	local w, a, b, observer, plainA, _, headA, headB = Build()
	T.ok(Wait(w, function() return headA.ns.GuildBridge.Ready(b.guild) and headB.ns.GuildBridge.Ready(a.guild) end, 1600))
	local officer = "только офицерам"
	w:GuildSay(headA, officer, "OFFICER")
	local mirror = headA.ns.L.GUILD_MIRROR_PREFIX .. "старая копия A"
	local bridge = headA.ns.L.GUILD_BRIDGE_PREFIX .. "старая копия моста"
	w:GuildSay(plainA, mirror, "GUILD")
	w:GuildSay(plainA, bridge, "GUILD")
	w:Run(20)
	for _, c in ipairs({ headA, headB, a, b, observer }) do
		T.eq(History(c, a.guild, headA, officer), 0)
		T.eq(History(c, a.guild, plainA, mirror), 0)
		T.eq(History(c, a.guild, plainA, bridge), 0)
	end
	T.eq(headA.ns.Chat.History("O")[1].x, officer)
	for _, packet in ipairs(w.log) do
		if packet.msg:sub(1, 5) == "BM~2~" then
			T.no(packet.msg:find(officer, 1, true) or packet.msg:find(mirror, 1, true) or packet.msg:find(bridge, 1, true))
		end
	end
end)

T.test("guild bridge: /cz1 доставляется один раз и не создаёт обычных сообщений /г", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	T.ok(Wait(w, function() return headA.ns.GuildBridge.Ready(b.guild) and headB.ns.GuildBridge.Ready(a.guild) end, 1600))
	local text = "написано непосредственно в A"
	T.ok(headA.ns.Chat.Send("A", text))
	w:Run(30)
	for _, c in ipairs({ headA, headB, a, b, observer }) do T.eq(History(c, a.guild, headA, text), 1) end
	T.eq(#plainA.lines, 0)
	T.eq(#plainB.lines, 0)
	T.eq(NativeCount(w), 0)
	for _, packet in ipairs(w.log) do
		T.no(packet.msg:sub(1, 5) == "BM~2~" and packet.msg:find(text, 1, true), "M1 не проходит импорт повторно")
	end
end)

T.test("guild bridge: новый связной восстанавливает импорт без повтора старых строк", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local first, gap, last = "до смены связного", "во время смены связного", "после смены связного"
	w:GuildSay(plainA, first, "GUILD")
	w:Run(15)
	T.eq(History(b, a.guild, plainA, first), 1)
	a:Logout()
	T.no(observer.ns.GuildBridge.Ready())
	w:GuildSay(plainA, gap, "GUILD")
	w:Run(15)
	T.eq(History(observer, a.guild, plainA, gap), 1, "локальная A работает во время выборов")
	T.eq(History(b, a.guild, plainA, gap), 0)
	T.ok(Wait(w, function()
		return observer.ns.GuildBridge.Ready(b.guild) and b.ns.GuildBridge.Ready(a.guild)
	end, 1600), "импорт восстановился автоматически")
	w:GuildSay(plainA, last, "GUILD")
	w:Run(30)
	T.same(plainA.lines, { first, gap, last })
	T.eq(#plainB.lines, 0)
	T.eq(History(observer, a.guild, plainA, last), 1)
	T.eq(History(b, a.guild, plainA, first), 1)
	T.eq(History(b, a.guild, plainA, gap), 0, "пропущенная реплика не догоняет как новая")
	T.eq(History(b, a.guild, plainA, last), 1)
	NoErrors(b, observer)
end)

T.test("guild bridge: без свежей переписи локальная A работает, старые реплики не догоняют", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local getRow = a.ns.Data.Row
	local fresh = getRow(b.guild)
	local stale = { origin = fresh.origin, signed = fresh.signed, st = a.ns.ServerTime() - a.ns.Config.FRESH - 1 }
	local unavailable = false
	a.ns.Data.Row = function(guild)
		if guild == b.guild then if unavailable then return nil end; return stale end
		return getRow(guild)
	end
	local first, second = "устаревшая перепись", "нет переписи"
	w:GuildSay(plainA, first, "GUILD")
	w:Run(15)
	T.no(a.ns.GuildBridge.Ready())
	unavailable = true
	w:GuildSay(plainA, second, "GUILD")
	w:Run(15)
	for _, c in ipairs({ a, observer }) do
		T.eq(History(c, a.guild, plainA, first), 1)
		T.eq(History(c, a.guild, plainA, second), 1)
	end
	a.ns.Data.Row = getRow
	T.ok(Wait(w, function() return a.ns.GuildBridge.Ready(b.guild) and b.ns.GuildBridge.Ready(a.guild) end, 1600))
	w:Run(30)
	T.eq(History(b, a.guild, plainA, first), 0)
	T.eq(History(b, a.guild, plainA, second), 0)
	T.eq(#plainB.lines, 0)
end)

T.test("guild bridge: задержанный блокировкой пакет не публикуется после истечения срока", function()
	local w, a, b, _, plainA, _, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	a.lockdown = true
	local text = "задержанная реплика"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(0.1)
	T.eq(History(a, a.guild, plainA, text), 1)
	w:Run(40)
	a.lockdown = false
	T.ok(Wait(w, function() return a.ns.GuildBridge.Ready(b.guild) and b.ns.GuildBridge.Ready(a.guild) end, 1600))
	w:Run(30)
	T.eq(History(b, a.guild, plainA, text), 0)
	T.eq(NativeCount(w), 1)
end)

T.test("guild bridge: BT с чужим сертификатом или собственной гильдией не дублирует A", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local wrong = observer.ns.Security.MyCertificate()
	local mine = a.ns.Security.MyCertificate()
	T.ok(wrong and mine)
	local text = "строка с чужим сертификатом"
	local wire = table.concat({ "BT", "2", wrong.fp, b.guild, "1-2-3", "99",
		observer.ns.ServerTime(), plainB:Name(), "MA", text }, "~")
	w:Deliver(a, "GUILD", a.ns.PREFIX, wire, nil, true)
	local own = "исходная строка без дубля BT"
	w:GuildSay(plainA, own, "GUILD")
	w:Run(0.1)
	local source = table.concat({ "BT", "2", mine.fp, a.guild, "1-2-4", "100",
		a.ns.ServerTime(), plainA:Name(), "MA", own }, "~")
	w:Deliver(a, "GUILD", a.ns.PREFIX, source, nil, true)
	w:Run(15)
	T.eq(History(observer, b.guild, plainB, text), 0)
	T.eq(History(observer, a.guild, plainA, own), 1)
	NoErrors(a, b, observer)
end)

T.test("guild bridge: одна исходная реплика идёт в две гильдии и нигде не пишет в /г", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	local third = w:Guild("Чиллзон Запад").name
	local headC = w:Client({ first = "Глава", surname = "Запада", guild = third, rank = 0 })
	local plainC = PlainClient(w, third, "Запада")
	w:Run(30)
	w:Init(headC)
	w:Pair(headC, headA)
	T.ok(Wait(w, function()
		return headA.ns.GuildBridge.Ready(b.guild) and headA.ns.GuildBridge.Ready(third)
			and headB.ns.GuildBridge.Ready(a.guild) and headC.ns.GuildBridge.Ready(a.guild)
	end, 1600))
	local text = "одна реплика для всего союза"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(30)
	T.same(plainA.lines, { text })
	T.eq(#plainB.lines, 0)
	T.eq(#plainC.lines, 0)
	T.eq(NativeCount(w), 1)
	local sent = 0
	for _, packet in ipairs(w.log) do
		if packet.msg:sub(1, 5) == "BM~2~" and packet.msg:find(text, 1, true) then
			T.eq(packet.from, headA:Name(), "пересылает только исходный связной")
			sent = sent + 1
		end
		T.no(packet.from == headA:Name() and packet.msg:sub(1, 5) == "BT~2~" and packet.msg:find(text, 1, true),
			"исходная гильдия уже получила штатное событие")
	end
	T.eq(sent, 2)
	for _, c in ipairs({ headA, a, observer, headB, b, headC }) do T.eq(History(c, a.guild, plainA, text, "MAGE"), 1) end
	NoErrors(headA, a, observer, headB, b, headC)
end)

for _, side in ipairs({ "A", "B" }) do
	local legacySide = side
	T.test("guild bridge: настоящий мост v1 на стороне " .. legacySide .. " не соединяется с v2", function()
		local opts = {}
		opts["bridge" .. legacySide] = "legacy"
		local w, a, b, observer, plainA, plainB, headA, headB = Build(opts)
		w:Run(300)
		T.no(headA.ns.GuildBridge.Ready(b.guild))
		T.no(headB.ns.GuildBridge.Ready(a.guild))
		local first, second = "из южной гильдии", "из северной гильдии"
		w:GuildSay(plainA, first, "GUILD")
		w:GuildSay(plainB, second, "GUILD")
		w:Run(30)
		T.same(plainA.lines, { first })
		T.same(plainB.lines, { second })
		T.eq(NativeCount(w), 2)
		T.eq(History(a, a.guild, plainA, first), 1)
		T.eq(History(observer, a.guild, plainA, first), 1)
		T.eq(History(b, b.guild, plainB, second), 1)
		T.eq(History(b, a.guild, plainA, first), 0)
		T.eq(History(a, b.guild, plainB, second), 0)
		NoErrors(a, b, observer, headA, headB)
	end)
end
