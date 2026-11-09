-- Обычный /г попадает в канал A только в аддоне через существующий подписанный Relay.
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
	local headA = w:Client({ first = "Глава", surname = "Юга", guild = "Чиллзон", rank = 0, bridge = opts.bridgeA or opts.bridge })
	local headB = w:Client({ first = "Глава", surname = "Севера", guild = "Чиллзон Север", rank = 0, bridge = opts.bridgeB or opts.bridge })
	local a = w:Client({ first = "Связной", surname = "Юга", guild = headA.guild, rank = 3, bridge = opts.bridge })
	local b = w:Client({ first = "Связной", surname = "Севера", guild = headB.guild, rank = 3, bridge = opts.bridge })
	local observer = w:Client({ first = "Яков", surname = "Юга", guild = a.guild, rank = 3, bridge = opts.bridge })
	local plainA = PlainClient(w, a.guild, "Юга")
	local plainB = PlainClient(w, b.guild, "Севера")
	w:Run(30)
	w:Init(headA, headB)
	w:Pair(headB, headA)
	w:Run(180)
	return w, a, b, observer, plainA, plainB, headA, headB
end

-- Ready знает только локально доступное реле. Для проверки доставки ждём также,
-- пока обычные RR зарегистрируют обоих репортёров на реальном маршруте.
local function NetworkReady(w, ...)
	local reporters = { ... }
	local function leased(relay, reporter)
		local held = relay.ns.Relay.Reporters()[relay.ns.Util.GuildKey(reporter.guild)]
		return held and held.key == reporter.ns.myKey and w.now - held.t <= relay.ns.Relay.REG_TTL
	end
	for _, source in ipairs(reporters) do
		if not source.ns.Relay.CanSendImport() then return false end
		for _, target in ipairs(reporters) do
			if source ~= target then
				local selfRoute = source.ns.Relay.IAmRelay() and source.ns.Relay.Serving() and leased(source, target)
				local selected = source.ns.Relay.Pick()
				local relay = selected and w:FindByTell(source.ns.Util.TellName(selected.name))
				local remoteRoute = relay and leased(relay, target)
					and (source.ns.Util.IsMainGuild(source.guild) or leased(relay, source))
				if not selfRoute and not remoteRoute then return false end
			end
		end
	end
	return true
end

local function Pair(w, a, b, headA, headB)
	T.ok(b.ns.Security.Member(a.guild, a:Name()),
		"будущий связной заранее получил проверенный сертификат запасного реле от своей гильдии")
	headA:Logout()
	headB:Logout()
	T.ok(Wait(w, function() return NetworkReady(w, a, b) end, 1600),
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

local function Capture(c)
	local packets, send = {}, c.ns.Relay.Out
	c.ns.Relay.Out = function(mode, wire)
		if wire:find("~G1~", 1, true) then packets[#packets + 1] = { mode = mode, wire = wire } end
		return send(mode, wire)
	end
	return packets
end

local replaySeq = 0
local function DeliverWire(w, from, to, wire, dist)
	replaySeq = replaySeq + 1
	for _, part in ipairs(from.ns.Codec.Pack(wire, from.ns.Codec.Base36(replaySeq))) do
		w:Deliver(from, dist or "WHISPER", from.ns.PREFIX, part, to and to:Name(), true)
	end
end

local function NoSecondTransport(w)
	for _, packet in ipairs(w.log) do
		local kind = packet.msg:sub(1, 2)
		T.no(kind == "BH" or kind == "BM" or kind == "BT", "импорт использует только существующий транспорт")
	end
end

local function LegacyAssembler(c)
	local legacy = { Util = c.ns.Util }
	local chunk = assert(loadfile(T.ROOT .. "/tests/legacy/0.11.1/Codec.lua"))
	setfenv(chunk, c.env)("Chillzone", legacy)
	c.ns.Codec.Feed, c.ns.Codec.Gc = legacy.Codec.Feed, legacy.Codec.Gc
end

T.test("guild import: локальный /г сразу виден в A без сертификата и соседей", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Читатель", surname = "Первый", guild = "Чиллзон", rank = 3 })
	local plain = PlainClient(w, c.guild, "Безаддона")
	w:Run(10)
	T.no(c.ns.Security.MyCertificate())
	T.no(c.ns.GuildImport.Ready())
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

T.test("guild import: старый выбранный репортёр не мешает локальному импорту", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build({ bridgeA = "none" })
	T.eq(a.ns.Census.Reporter(), headA.ns.myKey)
	T.eq(headA.ns.GuildImport, nil)
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

T.test("guild import: поздний читатель узнаёт запасное реле по Q1 и заменяет ушедших связных", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	T.ok(Wait(w, function()
		return headA.ns.GuildImport.Ready() and headB.ns.GuildImport.Ready()
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
		return NetworkReady(w, a, late)
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

T.test("guild import: подписанное членство ограничивает получателей импорта", function()
	local w, a, b, _, plainA, plainB, headA, headB = Build()
	local outside = w:Guild("Чиллзон Восток").name
	local headX = w:Client({ first = "Глава", surname = "Востока", guild = outside, rank = 0 })
	local plainX = PlainClient(w, outside, "Востока")
	w:Run(30)
	w:Init(headX)
	T.no(headX.ns.IsMember(), "похожее название не даёт членства")
	T.ok(Wait(w, function()
		return headA.ns.GuildImport.Ready() and headB.ns.GuildImport.Ready()
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
	local removed = "после исключения"
	w:GuildSay(plainA, removed, "GUILD")
	w:Run(15)
	T.eq(History(a, a.guild, plainA, removed), 1)
	T.eq(History(b, a.guild, plainA, removed), 0)
	NoSecondTransport(w)
end)

T.test("guild import: чужая и своя реплики, повторы событий и пакетов не дублируют A", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	T.no(observer.ns.GuildImport.Ready())
	local packetsA, packetsB = Capture(a), Capture(b)
	local foreign, own = "реплика без аддона", "реплика связного"
	local sentAt = a.ns.ServerTime()
	w:GuildSay(plainA, foreign, "GUILD")
	local lineID = w.guildLineID
	w:Run(10)
	T.eq(#packetsA, 1, "репортёр подписал одну исходную реплику")
	T.same(plainA.lines, { foreign })
	T.eq(#plainB.lines, 0)
	for _, c in ipairs({ a, b, observer }) do T.eq(History(c, a.guild, plainA, foreign, "MAGE", sentAt), 1) end
	FireGuild(a, plainA, foreign, lineID)
	FireGuild(observer, plainA, foreign, lineID)
	T.ok(b.ns.ServerTime() - sentAt < 30, "повтор свежий, его должен остановить дедуп, не срок")
	DeliverWire(w, a, b, a.ns.Codec.EncodeRM("RM", packetsA[1].mode, a:Name(), packetsA[1].wire))
	-- Собственная гильдия уже получила нативное событие: S1 не должен рисовать вторую копию.
	DeliverWire(w, a, nil, packetsA[1].wire, "GUILD")
	local ownAt = b.ns.ServerTime()
	w:GuildSay(b, own, "GUILD")
	w:Run(10)
	T.eq(#packetsB, 1)
	T.ok(observer.ns.ServerTime() - ownAt < 30, "повтор RG свежий")
	DeliverWire(w, a, nil, a.ns.Codec.EncodeRM("RG", packetsB[1].mode, b:Name(), packetsB[1].wire), "GUILD")
	w:Run(1)
	T.same(plainA.lines, { foreign })
	T.same(plainB.lines, { own })
	T.eq(NativeCount(w), 2)
	for _, c in ipairs({ a, b, observer }) do
		T.eq(History(c, a.guild, plainA, foreign), 1)
		T.eq(History(c, b.guild, b, own, "MAGE", ownAt), 1, "повтор RG не меняет историю")
		T.eq(c:Saw(foreign), 0, "импорт только в окне аддона")
		T.eq(c:Saw(own), 0)
	end
	NoSecondTransport(w)
	NoErrors(a, b, observer)
end)

T.test("guild import: одинаковые тексты разных сообщений доходят дважды со ссылкой и классом", function()
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

T.test("guild import: игнор и chat off действуют локально, пересылка другим продолжается", function()
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

T.test("guild import: /о и старые читаемые копии не импортируются в A", function()
	local w, a, b, observer, plainA, _, headA, headB = Build()
	T.ok(Wait(w, function() return headA.ns.GuildImport.Ready() and headB.ns.GuildImport.Ready() end, 1600))
	local officer = "только офицерам"
	w:GuildSay(headA, officer, "OFFICER")
	local mirror = headA.ns.L.GUILD_MIRROR_PREFIX .. "старая копия A"
	w:GuildSay(plainA, mirror, "GUILD")
	w:Run(20)
	for _, c in ipairs({ headA, headB, a, b, observer }) do
		T.eq(History(c, a.guild, headA, officer), 0)
		T.eq(History(c, a.guild, plainA, mirror), 0)
	end
	T.eq(headA.ns.Chat.History("O")[1].x, officer)
	NoSecondTransport(w)
end)

T.test("guild import: /cz1 доставляется один раз и не создаёт обычных сообщений /г", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	T.ok(Wait(w, function() return headA.ns.GuildImport.Ready() and headB.ns.GuildImport.Ready() end, 1600))
	local text = "написано непосредственно в A"
	T.ok(headA.ns.Chat.Send("A", text))
	w:Run(30)
	for _, c in ipairs({ headA, headB, a, b, observer }) do T.eq(History(c, a.guild, headA, text), 1) end
	T.eq(#plainA.lines, 0)
	T.eq(#plainB.lines, 0)
	T.eq(NativeCount(w), 0)
	NoSecondTransport(w)
end)

T.test("guild import: новый связной восстанавливает импорт без повтора старых строк", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local first, gap, last = "до смены связного", "во время смены связного", "после смены связного"
	w:GuildSay(plainA, first, "GUILD")
	w:Run(15)
	T.eq(History(b, a.guild, plainA, first), 1)
	a:Logout()
	T.no(observer.ns.GuildImport.Ready())
	w:GuildSay(plainA, gap, "GUILD")
	w:Run(15)
	T.eq(History(observer, a.guild, plainA, gap), 1, "локальная A работает во время выборов")
	T.eq(History(b, a.guild, plainA, gap), 0)
	T.ok(Wait(w, function()
		return NetworkReady(w, observer, b)
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

T.test("guild import: без готового Relay локальная A работает, старые реплики не догоняют", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local pick = b.ns.Relay.Pick
	b.ns.Relay.Pick = function() return nil end
	T.no(b.ns.GuildImport.Ready())
	local text = "пока реле недоступно"
	w:GuildSay(plainB, text, "GUILD")
	w:Run(40)
	T.eq(History(b, b.guild, plainB, text), 1)
	T.eq(History(a, b.guild, plainB, text), 0)
	b.ns.Relay.Pick = pick
	T.ok(Wait(w, function() return a.ns.GuildImport.Ready() and b.ns.GuildImport.Ready() end, 1600))
	w:Run(30)
	T.eq(History(a, b.guild, plainB, text), 0, "импорт не ждёт в Relay.Hold")
	T.eq(History(observer, b.guild, plainB, text), 0)
	T.eq(#plainA.lines, 0)
	NoErrors(a, b, observer)
end)

T.test("guild import: задержанный блокировкой пакет не публикуется после истечения срока", function()
	local w, a, b, _, plainA, _, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	a.lockdown = true
	local text = "задержанная реплика"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(0.1)
	T.eq(History(a, a.guild, plainA, text), 1)
	w:Run(40)
	a.lockdown = false
	T.ok(Wait(w, function() return a.ns.GuildImport.Ready() and b.ns.GuildImport.Ready() end, 1600))
	w:Run(30)
	T.eq(History(b, a.guild, plainA, text), 0)
	T.eq(NativeCount(w), 1)
end)

T.test("guild import: изменённый текст подписанного пакета не выдаётся за слова автора", function()
	local w, a, b, observer, plainA, _, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local packet, send = nil, a.ns.Relay.Out
	a.ns.Relay.Out = function(mode, wire)
		if wire:find("~G1~", 1, true) then packet = { mode = mode, wire = wire }; return false end
		return send(mode, wire)
	end
	local text, forged = "подлинная реплика", "подменённая реплика"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(2)
	T.ok(packet)
	a.ns.Relay.Out = send
	local altered = packet.wire:gsub(text, forged)
	DeliverWire(w, a, b, a.ns.Codec.EncodeRM("RM", packet.mode, a:Name(), altered))
	w:Run(5)
	T.eq(History(b, a.guild, plainA, forged), 0, "подпись связного не позволяет подменить исходные слова")
	DeliverWire(w, a, b, a.ns.Codec.EncodeRM("RM", packet.mode, a:Name(), packet.wire))
	w:Run(10)
	T.eq(History(b, a.guild, plainA, text), 1, "настоящий пакет принимается после подделки")
	NoErrors(a, b, observer)
end)

T.test("guild import: одна исходная реплика идёт в две гильдии и нигде не пишет в /г", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	local third = w:Guild("Чиллзон Запад").name
	local headC = w:Client({ first = "Глава", surname = "Запада", guild = third, rank = 0 })
	local plainC = PlainClient(w, third, "Запада")
	w:Run(30)
	w:Init(headC)
	w:Pair(headC, headA)
	T.ok(Wait(w, function()
		return headA.ns.GuildImport.Ready()
			and headB.ns.GuildImport.Ready() and headC.ns.GuildImport.Ready()
	end, 1600))
	local outgoing = Capture(headA)
	local text = "одна реплика для всего союза"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(30)
	T.same(plainA.lines, { text })
	T.eq(#plainB.lines, 0)
	T.eq(#plainC.lines, 0)
	T.eq(NativeCount(w), 1)
	T.eq(#outgoing, 1, "репортёр отдаёт Relay одну подписанную реплику для всего союза")
	NoSecondTransport(w)
	for _, c in ipairs({ headA, a, observer, headB, b, headC }) do T.eq(History(c, a.guild, plainA, text, "MAGE"), 1) end
	NoErrors(headA, a, observer, headB, b, headC)
end)

T.test("guild import: клиент без G1 продолжает получать обычный M1", function()
	local w, a, b, observer, plainA, _, headA, headB = Build()
	local old = w:Client({ first = "Старый", surname = "Севера", guild = b.guild, rank = 3, bridge = "none" })
	LegacyAssembler(old)
	w:Run(180)
	T.eq(old.ns.GuildImport, nil)
	T.ok(Wait(w, function() return headA.ns.GuildImport.Ready() and headB.ns.GuildImport.Ready() end, 1600))
	local imported, regular = "импорт для новых клиентов", "обычный чат для всех версий"
	w:GuildSay(plainA, imported, "GUILD")
	w:Run(15)
	T.eq(History(b, a.guild, plainA, imported), 1)
	T.eq(History(old, a.guild, plainA, imported), 0, "нет обработчика нового типа")
	T.ok(headA.ns.Chat.Send("A", regular))
	w:Run(20)
	for _, c in ipairs({ a, b, observer, old }) do T.eq(History(c, a.guild, headA, regular), 1) end
	NoErrors(a, b, observer, old)
end)

-- Два одинаковых мира: обычный чат и перепись идут в обоих, /ги импортируется
-- только в одном. Время получения берём из события CHAT, а не из времени истории.
local function MixedLoad(enabled, throttled)
	local mode = not enabled and "none" or nil
	local w, a, b, observer, _, plainB, headA, headB = Build({ bridge = mode })
	local guildC = w:Guild("Чиллзон Запад").name
	local headC = w:Client({ first = "Глава", surname = "Запада", guild = guildC, rank = 0, bridge = mode })
	local readerC = w:Client({ first = "Читатель", surname = "Запада", guild = guildC, rank = 3, bridge = mode })
	local old = w:Client({ first = "Старый", surname = "Запада", guild = guildC, rank = 3, bridge = "none" })
	LegacyAssembler(old)
	w:Run(30)
	w:Init(headC)
	w:Pair(headC, headA)
	w:Run(180)
	T.ok(Wait(w, function()
		return NetworkReady(w, headA, headB, headC)
	end, 1600))
	local clients = { a, b, observer, headA, headB, headC, readerC, old }
	local readers = { a, observer, readerC, old }
	local start, sent, received = w.now, {}, {}
	local result = { maxLatency = 0, maxQueue = 0, maxImport = 0, refused = 0 }
	for _, c in ipairs(readers) do
		local reader = c
		received[reader] = {}
		reader.ns.On("CHAT", function(channel, entry)
			if channel == "A" and sent[entry.x] then
				received[reader][entry.x] = (received[reader][entry.x] or 0) + 1
				result.maxLatency = math.max(result.maxLatency, w.now - sent[entry.x])
			end
		end)
	end
	for _, c in ipairs(clients) do
		local api = c.env.C_ChatInfo
		for _, name in ipairs({ "SendAddonMessage", "SendAddonMessageLogged" }) do
			local send = api[name]
			api[name] = function(...)
				local age = w.now - start
				if throttled and ((age >= 20 and age < 24) or (age >= 80 and age < 84)) then
					result.refused = result.refused + 1
					return 3 -- Штатный AddonMessageThrottle, общий backoff остаётся настоящим.
				end
				return send(...)
			end
		end
	end
	local imported = {}
	local expectedTotal
	for second = 0, 119 do
		if second % 8 == 0 then
			local short = throttled and second % 24 == 0
			local text = "нагрузка /ги " .. second .. " " .. (short and "короткая строка " or string.rep("длинный текст ", 15)) .. LINK
			T.ok(#text <= 510 and (short or #text > 255), "есть короткие и многокусковые строки")
			imported[#imported + 1] = text
			w:GuildSay(plainB, text, "GUILD")
		end
		if second % 20 == 0 then
			local text = "контрольный общий чат " .. second
			sent[text] = w.now
			T.ok(headB.ns.Chat.Send("A", text), "обычный чат принят при нагрузке /ги")
		end
		if second == 30 or second == 90 then
			w:AddOffline(headB.guild, "Новый " .. second .. "-CAMWOWUS2Realm7PvE", 3, 60, "MAGE", 0)
			headB.ns.Roster.Scan()
			expectedTotal = headB.ns.Roster.report.total
			headB.ns.Census.MaybeReport(true)
		end
		w:Run(1)
		for _, c in ipairs(clients) do
			result.maxQueue = math.max(result.maxQueue, c.ns.Comm.QueueSize())
			result.maxImport = math.max(result.maxImport, c.ns.Comm.ImportQueued())
			T.ok(c.ns.Comm.ImportQueued() <= c.ns.Config.IMPORT_QUEUE_MAX)
		end
	end
	w:Run(30)
	for _, c in ipairs(readers) do
		for text in pairs(sent) do T.eq(received[c][text], 1, c:Name() .. ": обычный M1 дошёл ровно один раз") end
		local row = c.ns.Data.Row(headB.guild)
		T.ok(row and row.r, "перепись доставлена")
		T.eq(row.r.total, expectedTotal, "новый состав не потерялся среди импортируемых строк")
	end
	if enabled then
		local remote = 0
		for _, text in ipairs(imported) do
			T.eq(History(b, b.guild, plainB, text, "MAGE"), 1, "локальный импорт не зависит от очереди")
			remote = remote + History(readerC, b.guild, plainB, text, "MAGE")
			T.eq(History(old, b.guild, plainB, text), 0, "старый обработчик не показывает G1")
		end
		if not throttled then T.ok(remote > 0, "длинный импорт доставлен внутри смешанной нагрузки") end
		local recovery = "свежая длинная строка после нагрузки " .. string.rep("длинный текст ", 14) .. LINK
		w:GuildSay(plainB, recovery, "GUILD")
		w:Run(30)
		T.eq(History(readerC, b.guild, plainB, recovery, "MAGE"), 1, "после отказов свежий импорт снова доставляется")
	end
	T.ok(result.maxQueue <= headB.ns.Comm.MAX_QUEUE)
	if throttled then T.ok(result.refused > 0, "игра действительно отказала в отправке") end
	NoSecondTransport(w)
	NoErrors(a, b, observer, headA, headB, headC, readerC, old)
	return result
end

for _, throttled in ipairs({ false, true }) do
	local refuse = throttled
	T.test("guild import load: /ги, /cz и перепись вместе" .. (refuse and " при throttling" or " без throttling"), function()
		local baseline, loaded = MixedLoad(false, refuse), MixedLoad(true, refuse)
		T.ok(loaded.maxLatency <= baseline.maxLatency + 6,
			("импорт не добавил больше 6 с задержки M1: %.2f против %.2f"):format(loaded.maxLatency, baseline.maxLatency))
		T.ok(loaded.maxLatency <= 20, "обычный чат не ждёт истечения срока импортируемых строк")
		T.ok(loaded.maxImport <= 8, "ограничение проверено на всей цепочке RL/RM/RG")
	end)
end

T.test("guild import load: накопившийся импорт уступает чату и переписи после блокировки", function()
	local w, a, b, observer, _, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	T.ok(Wait(w, function()
		return NetworkReady(w, a, b) and a.ns.Comm.QueueSize() == 0
			and b.ns.Comm.QueueSize() == 0 and observer.ns.Comm.QueueSize() == 0
	end, 1600), "начальная синхронизация закончилась до измерения очереди")
	b.lockdown = true
	local texts = {}
	for i = 1, 12 do
		local text = "очередь /ги " .. i .. " " .. string.rep("длинная строка ", 14) .. LINK
		texts[#texts + 1] = text
		w:GuildSay(plainB, text, "GUILD")
		w:Run(1)
		T.ok(b.ns.Comm.ImportQueued() <= 8, "очередь ограничена во время блокировки")
	end
	T.eq(b.ns.Comm.ImportQueued(), 8, "восемь настоящих G1 заняли весь лимит")
	T.ok(b.ns.GuildImport.stats.limited >= 4, "лишние строки ограничены до отправки")
	for _, text in ipairs(texts) do T.eq(History(b, b.guild, plainB, text), 1, "все строки остались локально") end
	local regular = "срочный обычный чат после очереди /ги"
	T.ok(b.ns.Chat.Send("A", regular))
	w:AddOffline(b.guild, "Новый Послеочереди-CAMWOWUS2Realm7PvE", 3, 60, "MAGE", 0)
	b.ns.Roster.Scan()
	local total = b.ns.Roster.report.total
	b.ns.Census.MaybeReport(true)
	w:Run(1)
	b.lockdown = false
	w:Run(14)
	T.eq(History(observer, b.guild, b, regular), 1, "M1 обогнал многокусковый импорт")
	T.eq(observer.ns.Data.Row(b.guild).r.total, total, "R1 обогнал многокусковый импорт")
	w:Run(40)
	T.eq(b.ns.Comm.ImportQueued(), 0, "просроченный хвост не остаётся в очереди")
	NoErrors(a, b, observer)
end)

T.test("guild import load: полная обычная очередь не вытесняется импортом", function()
	local w, a, b, observer, _, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	T.ok(Wait(w, function()
		return NetworkReady(w, a, b) and a.ns.Comm.QueueSize() == 0
			and b.ns.Comm.QueueSize() == 0 and observer.ns.Comm.QueueSize() == 0
	end, 1600), "начальная синхронизация закончилась до насыщения очереди")
	b.lockdown = true
	local cancelled = 0
	for _ = 1, b.ns.Comm.MAX_QUEUE do
		b.ns.Comm.Send("GUILD", "Q1~", { done = function(ok) if not ok then cancelled = cancelled + 1 end end })
	end
	T.eq(b.ns.Comm.QueueSize(), b.ns.Comm.MAX_QUEUE)
	local send, attempted, displaced = b.ns.Comm.Send, false, 0
	b.ns.Comm.Send = function(dist, wire, opts)
		if opts and opts.prio == b.ns.Comm.PRIO_IMPORT then
			attempted = true
			local before = cancelled
			local accepted = send(dist, wire, opts)
			displaced = displaced + cancelled - before
			return accepted
		end
		return send(dist, wire, opts)
	end
	local text = "импорт при заполненной обычной очереди"
	w:GuildSay(plainB, text, "GUILD")
	w:Run(1)
	T.eq(History(b, b.guild, plainB, text), 1)
	T.ok(attempted, "настоящий G1 попытался встать в полную очередь")
	T.eq(displaced, 0, "именно вставка G1 не вытеснила обычные задания; фоновый RR учитывается отдельно")
	T.eq(b.ns.Comm.ImportQueued(), 0, "места для низкоприоритетного импорта нет")
	T.eq(b.ns.Comm.QueueSize(), b.ns.Comm.MAX_QUEUE)
	local regular = "обычный чат принимается при полной очереди"
	T.ok(b.ns.Chat.Send("A", regular))
	w:Run(1)
	b.lockdown = false
	w:Run(14)
	T.eq(History(observer, b.guild, b, regular), 1, "приоритетный M1 доставлен через заполненную очередь")
	T.eq(History(observer, b.guild, plainB, text), 0, "отброшенный импорт не догоняет")
	NoErrors(a, b, observer)
end)

T.test("guild import: начатая сборка завершается после TTL без публикации старой строки", function()
	local w, a, b, observer, _, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local deliver, chunkID, parts = w.Deliver
	function w:Deliver(from, dist, prefix, msg, target, logged)
		local result = deliver(self, from, dist, prefix, msg, target, logged)
		if from == b and not chunkID and msg:find("~G1~", 1, true) then
			local id, n = msg:match("^C(%w+):1:(%d+):")
			if id then
				chunkID, parts = id, tonumber(n)
				b.lockdown = true
			end
		end
		return result
	end
	local text = "начатый длинный импорт " .. string.rep("строка ", 25) .. LINK
	w:GuildSay(plainB, text, "GUILD")
	T.ok(Wait(w, function() return chunkID ~= nil end, 30), "первая часть действительно ушла")
	T.ok(parts > 1)
	w:Run(40)
	T.eq(History(b, b.guild, plainB, text), 1)
	T.eq(History(observer, b.guild, plainB, text), 0)
	b.lockdown = false
	local regular = "чат после незавершённой старой строки"
	T.ok(b.ns.Chat.Send("A", regular))
	w:Run(20)
	local delivered = 0
	for _, packet in ipairs(w.log) do
		if packet.from == b:Name() and packet.msg:match("^C" .. chunkID .. ":%d+:") then delivered = delivered + 1 end
	end
	T.eq(delivered, parts, "оставшиеся части освобождают сборку также у старого клиента")
	T.eq(History(observer, b.guild, plainB, text), 0, "полный, но просроченный G1 не публикуется")
	T.eq(History(observer, b.guild, b, regular), 1, "M1 доставлен после блокировки")
	T.eq(b.ns.Comm.ImportQueued(), 0)
	NoErrors(a, b, observer)
end)

T.test("guild import: шесть импортов не вытесняют повтор обычного чата при смене реле", function()
	local w, a, b, observer, _, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	w:Run(30)
	local old = assert(b.ns.Relay.Pick())
	local target = b.ns.Util.TellName(old.name)
	local deliver, blocked = w.Deliver, 0
	function w:Deliver(from, dist, prefix, msg, to, logged)
		if from == b and dist == "WHISPER" and to == target then
			blocked = blocked + 1
			return 0 -- API принял пакет, ответ о вышедшем игроке придёт позже.
		end
		return deliver(self, from, dist, prefix, msg, to, logged)
	end
	local regular = "повтор обычного чата важнее импорта"
	T.ok(b.ns.Chat.Send("A", regular))
	w:Run(3)
	T.eq(History(a, b.guild, b, regular), 0, "первый маршрут не доставил M1")
	local outgoing, texts = Capture(b), {}
	for i = 1, 6 do
		local text = "импорт до отказа реле " .. i
		texts[#texts + 1] = text
		w:GuildSay(plainB, text, "GUILD")
		w:Run(1)
	end
	T.eq(#outgoing, 6, "шесть G1 прошли через тот же Relay.Out после M1")
	T.ok(blocked > 0, "сеть действительно потеряла исходящие пакеты")
	b.ns.Fire("WHISPER_UNAVAILABLE", old.key)
	w:Run(20)
	T.eq(History(a, b.guild, b, regular), 1, "M1 сохранился в последних пяти обычных отправках и повторился")
	T.eq(History(observer, b.guild, b, regular), 1)
	for _, text in ipairs(texts) do
		T.eq(History(a, b.guild, plainB, text), 0, "потерянный G1 не занимает очередь повторов")
	end
	NoErrors(a, b, observer)
end)
