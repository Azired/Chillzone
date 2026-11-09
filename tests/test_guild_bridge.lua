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
	for _, c in ipairs({ headA, headB, a, b, observer }) do
		c.env.C_GuildInfo.GetInfoText = function() return w.guilds[c.guild].info or "" end
	end
	w:Run(30)
	w:Init(headA, headB)
	w:Pair(headB, headA)
	w:Run(180)
	return w, a, b, observer, plainA, plainB, headA, headB
end

local function SetPolicy(w, own, peer)
	w.guilds[own.guild].info = "Правила гильдии\n[CZBRIDGE1] " .. peer.guild
end

local function Wait(w, ready, seconds)
	for _ = 1, seconds / 10 do
		if ready() then return true end
		w:Run(10)
	end
	return ready()
end

local function Pair(w, a, b, headA, headB)
	SetPolicy(w, a, b)
	headA:Logout()
	SetPolicy(w, b, a)
	headB:Logout()
	T.ok(Wait(w, function() return a.ns.GuildBridge.Ready() and b.ns.GuildBridge.Ready() end, 1600),
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

T.test("guild bridge: выключен изначально и ждёт согласия двух гильдий", function()
	local w, a, b, observer, plainA, plainB, headA, headB = Build()
	T.no(a.ns.GuildBridge.Ready())
	T.no(b.ns.GuildBridge.Ready())
	SetPolicy(w, a, b)
	headA:Logout()
	headB:Logout()
	T.ok(Wait(w, function() return a.ns.Census.IsReporter() and b.ns.Census.IsReporter() end, 230))
	w:Run(90)
	T.no(a.ns.GuildBridge.Ready())
	T.no(observer.ns.GuildBridge.Ready(), "второй участник не стал связным")
	w:GuildSay(plainA, "только местный чат", "GUILD")
	w:Run(15)
	T.same(plainA.lines, { "только местный чат" })
	T.eq(#plainB.lines, 0)
	T.eq(History(a, a.guild, plainA, "только местный чат"), 0)
	T.eq(History(b, a.guild, plainA, "только местный чат"), 0)
	for _, packet in ipairs(w.log) do
		T.no(packet.dist == "WHISPER" and packet.msg:find("только местный чат", 1, true),
			"без согласия не передаётся даже текст пакета")
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

	T.ok(Wait(w, function() return observer.ns.GuildBridge.Ready() and b.ns.GuildBridge.Ready() end, 1600),
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

	w.guilds[b.guild].info = "Мост выключен"
	T.no(b.ns.GuildBridge.Ready(), "при удалении отметки назначение сразу прекращается")
	w:Run(50)
	T.no(observer.ns.GuildBridge.Ready())
end)
