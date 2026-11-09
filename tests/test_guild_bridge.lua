-- Мост гильдейского чата проверяем через обычные события WoW и доставку аддон-сообщений.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

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

local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 11)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local headA = w:Client({ first = "Глава", surname = "Юга", guild = "Чиллзон", rank = 0 })
	local headB = w:Client({ first = "Глава", surname = "Севера", guild = "Чиллзон Север", rank = 0 })
	local a = w:Client({ first = "Связной", surname = "Юга", guild = headA.guild, rank = 3 })
	local b = w:Client({ first = "Связной", surname = "Севера", guild = headB.guild, rank = 3 })
	local observer = w:Client({ first = "Яков", surname = "Юга", guild = a.guild, rank = 3 })
	local plainA = PlainClient(w, a.guild, "Юга")
	local plainB = PlainClient(w, b.guild, "Севера")
	w:Run(30)
	w:Init(headA, headB)
	w:Pair(headB, headA)
	w:Run(180)
	-- Для успешной смены репортёров штатный транспорт должен знать живое
	-- реле главной гильдии. Передаём настоящий сертификат до выхода глав.
	T.ok(Wait(w, function() return a.ns.Security.MyCertificate() end, 60),
		"запасное реле получило сертификат")
	a.ns.Security.Introduce(b:Name(), nil, true)
	T.ok(Wait(w, function() return b.ns.Security.Member(a.guild, a:Name()) end, 60),
		"соседняя гильдия знает сертификат запасного реле")
	return w, a, b, observer, plainA, plainB, headA, headB
end

local function Pair(w, a, b, headA, headB)
	headA:Logout()
	headB:Logout()
	T.ok(Wait(w, function() return a.ns.GuildBridge.Ready(b.guild) and b.ns.GuildBridge.Ready(a.guild) end, 1600),
		"рядовые участники стали связными при двух офлайн-главах")
end

local function History(c, guild, author, text)
	local count = 0
	for _, e in ipairs(c.ns.Chat.History("A")) do
		if e.x == text then
			T.eq(e.s, author:Name(), "исходное имя, не имя связного")
			T.eq(e.g, guild, "исходная гильдия")
			count = count + 1
		end
	end
	return count
end

local function FireGuild(c, author, text, lineID)
	local stamp = author:Name() .. "-" .. author.realm
	c:Fire("CHAT_MSG_GUILD", text, stamp, "", "", stamp, "", 0, 0, "", 0, lineID, author:Guid())
end

T.test("guild bridge: подписанного членства достаточно, посторонняя гильдия не получает чат", function()
	local w, a, b, _, plainA, plainB, headA, headB = Build()
	local outside = w:Guild("Чиллзон Восток").name
	local headX = w:Client({ first = "Глава", surname = "Востока", guild = outside, rank = 0 })
	local plainX = PlainClient(w, outside, "Востока")
	w:Run(30)
	w:Init(headX)
	T.no(headX.ns.IsMember(), "похожее название и свой корень не дают членства")
	T.ok(Wait(w, function()
		return headA.ns.GuildBridge.Ready(b.guild) and headB.ns.GuildBridge.Ready(a.guild)
	end, 1600), "мост включился без изменений в описаниях гильдий")
	T.no(headA.ns.GuildBridge.Ready(outside))
	T.no(headX.ns.GuildBridge.Ready())

	local text = "переслать только в союз"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(15)
	T.same(plainA.lines, { text })
	T.eq(#plainB.lines, 1)
	T.eq(#plainX.lines, 0)
	T.eq(History(headX, a.guild, plainA, text), 0)
	for _, packet in ipairs(w.log) do
		if packet.msg:sub(1, 3) == "BM~" and packet.msg:find(text, 1, true) then
			T.eq(w:FindByTell(packet.target), headB, "пакет адресован только связному из союза")
		end
	end

	T.ok(headA.ns.Security.RemoveGuild(b.guild))
	T.no(headA.ns.GuildBridge.Ready(b.guild), "новое решение сразу исключает гильдию из рассылки")
	local removed = "после исключения"
	w:GuildSay(plainA, removed, "GUILD")
	w:Run(15)
	T.same(plainA.lines, { text, removed })
	T.eq(#plainB.lines, 1, "исключённая гильдия не получает новые строки")
	for _, packet in ipairs(w.log) do
		T.no(packet.msg:sub(1, 3) == "BM~" and packet.msg:find(removed, 1, true),
			"текст не передаётся исключённой гильдии даже пакетом")
	end
end)

T.test("guild bridge: чужая и своя реплики, одна строка в /g и исходный автор в окне", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	T.no(observer.ns.GuildBridge.Ready(), "неизбранный участник не пересылает")
	local packet, deliver = nil, w.Deliver
	function w:Deliver(from, dist, prefix, msg, target, logged)
		if from == a and dist == "WHISPER" and msg:sub(1, 3) == "BM~" then
			packet = msg
			-- Тот же пакет сначала отправляет другой игрок через реальный игровой транспорт.
			deliver(self, observer, dist, prefix, msg, target, logged)
		end
		return deliver(self, from, dist, prefix, msg, target, logged)
	end
	local foreign, own = "реплика без аддона", "реплика связного"
	w:GuildSay(plainA, foreign, "GUILD")
	local lineID = w.guildLineID
	w:Run(15)
	T.ok(packet, "мост передал исходную реплику")
	T.same(plainA.lines, { foreign }, "исходная гильдия получает только оригинал")
	T.eq(#plainB.lines, 1, "соседи видят одну копию")
	T.ok(plainB.lines[1]:find(foreign, 1, true))
	T.ok(plainB.lines[1]:find(plainA:Name(), 1, true))
	for _, c in ipairs({ a, b, observer }) do
		T.eq(History(c, a.guild, plainA, foreign), 1)
	end

	-- И игровой сервер, и сеть аддона могут повторить уже полученное событие.
	FireGuild(a, plainA, foreign, lineID)
	deliver(w, a, "WHISPER", a.ns.PREFIX, packet, b:Name(), false)
	w:GuildSay(b, own, "GUILD")
	w:Run(30)
	T.eq(#plainA.lines, 2)
	T.eq(#plainB.lines, 2)
	T.eq(plainB.lines[2], own)
	T.ok(plainA.lines[2]:find(own, 1, true))
	for _, c in ipairs({ a, b, observer }) do
		T.eq(History(c, a.guild, plainA, foreign), 1, "повтор не попал в окно")
		T.eq(History(c, b.guild, b, own), 1, "собственная реплика связного тоже попала в окно")
		T.eq(#c.ns.db.errors, 0, table.concat(c.ns.db.errors, " | "))
	end
end)

T.test("guild bridge: новый связной выбирается после выхода, строки не повторяются", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local first, gap, last = "до смены связного", "во время смены связного", "после смены связного"
	w:GuildSay(plainA, first, "GUILD")
	w:Run(15)
	T.eq(#plainB.lines, 1)
	a:Logout()
	T.no(observer.ns.GuildBridge.Ready(), "пока не прошли выборы, второй игрок молчит")
	w:GuildSay(plainA, gap, "GUILD")
	w:Run(15)
	T.eq(#plainB.lines, 1)

	T.ok(Wait(w, function()
		return observer.ns.GuildBridge.Ready(b.guild) and b.ns.GuildBridge.Ready(a.guild)
	end, 1600),
		"мост восстановился автоматически")
	w:GuildSay(plainA, last, "GUILD")
	w:Run(30)
	T.same(plainA.lines, { first, gap, last })
	T.eq(#plainB.lines, 2, "по одной копии до и после смены")
	T.ok(plainB.lines[1]:find(first, 1, true))
	T.ok(plainB.lines[2]:find(last, 1, true))
	T.eq(History(observer, a.guild, plainA, last), 1)
	T.eq(History(b, a.guild, plainA, first), 1)
	T.eq(History(b, a.guild, plainA, gap), 0, "старая строка не была переслана после восстановления")
	T.eq(History(b, a.guild, plainA, last), 1)
end)

T.test("guild bridge: без свежей переписи реплики остаются в исходной гильдии", function()
	local w, a, b, _, plainA, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	local getRow = a.ns.Data.Row
	local fresh = getRow(b.guild)
	local stale = { origin = fresh.origin, signed = fresh.signed,
		st = a.ns.ServerTime() - a.ns.Config.FRESH - 1 }
	local unavailable = false
	a.ns.Data.Row = function(guild)
		if guild == b.guild then
			if unavailable then return nil end
			return stale
		end
		return getRow(guild)
	end

	local first, second = "устаревшая перепись", "нет переписи"
	w:GuildSay(plainA, first, "GUILD")
	w:Run(15)
	T.no(a.ns.GuildBridge.Ready())
	unavailable = true
	w:GuildSay(plainA, second, "GUILD")
	w:Run(15)
	T.no(a.ns.GuildBridge.Ready())
	T.same(plainA.lines, { first, second })
	T.eq(#plainB.lines, 0)
	for _, packet in ipairs(w.log) do
		T.no(packet.dist == "WHISPER" and packet.msg:sub(1, 3) == "BM~",
			"без свежей подписанной переписи даже текст пакета не уходит")
	end
end)

T.test("guild bridge: сертификат другого игрока не даёт записать строку в историю", function()
	local w, a, b, observer, _, plainB, headA, headB = Build()
	Pair(w, a, b, headA, headB)
	T.eq(observer.ns.Census.Reporter(), a.ns.myKey)
	local cert = observer.ns.Security.MyCertificate()
	T.ok(cert, "сертификат другого участника действителен")
	local text = "строка с чужим сертификатом"
	local wire = table.concat({ "BT", cert.fp, b.guild, b.guild, "1-2-3", "99",
		observer.ns.ServerTime(), plainB:Name(), text }, "~")
	w:Deliver(a, "GUILD", a.ns.PREFIX, wire, nil, true)
	w:Run(2)
	T.eq(History(observer, b.guild, plainB, text), 0)
end)

T.test("guild bridge: одна исходная реплика идёт в две гильдии без повторов в истории", function()
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
	end, 1600), "у главной гильдии два активных соседа")

	local text = "одна реплика для всего союза"
	w:GuildSay(plainA, text, "GUILD")
	w:Run(30)
	T.same(plainA.lines, { text })
	T.eq(#plainB.lines, 1)
	T.eq(#plainC.lines, 1)
	T.ok(plainB.lines[1]:find(text, 1, true))
	T.ok(plainC.lines[1]:find(text, 1, true))
	local sent = 0
	for _, packet in ipairs(w.log) do
		if packet.msg:sub(1, 3) == "BM~" and packet.msg:find(text, 1, true) then
			T.eq(packet.from, headA:Name(), "реплику пересылает только исходный связной")
			sent = sent + 1
		end
	end
	T.eq(sent, 2, "по одному пакету каждой соседней гильдии")
	for _, c in ipairs({ headA, a, observer, headB, b, headC }) do
		T.eq(History(c, a.guild, plainA, text), 1, c:Name() .. ": в истории одна реплика")
		T.eq(#c.ns.db.errors, 0, table.concat(c.ns.db.errors, " | "))
	end
end)
