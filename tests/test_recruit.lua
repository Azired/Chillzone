-- Заявки: поиск сервером, адресный шёпот, очередь и действия из окна.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Другая гильдия")
	local c = {}
	c.O = w:Client({ first = "Ольга", surname = "Северная", guild = "Чиллзон Север", rank = 0 })
	c.M = w:Client({ first = "Миша", surname = "Северный", guild = "Чиллзон Север", rank = 3 })
	c.K = w:Client({ first = "Король", surname = "Чиллзона", guild = "Чиллзон", rank = 0 })
	c.R = w:Client({ first = "Новый", surname = "Игрок", guild = "Другая гильдия", level = 27 })
	c.H = w:Client({ first = "Враг", surname = "Ордынский", guild = "Чиллзон Север", faction = "Horde" })
	w:Run(8)
	return w, c
end

local function Search(w, c)
	T.ok(c.R.ns.Who.Search())
	w:Run(5)
end

local function Request(w, c, target)
	Search(w, c)
	local contact = c.R.ns.Recruit.NextContact(target or "Чиллзон Север")
	T.ok(contact)
	T.ok(c.R.ns.Recruit.Ask(contact, "Привет! Хочу вступить."))
	w:Run(5)
	return c.O.ns.Recruit.requests[1]
end

local function Errors(c)
	for name, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, name .. ": " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, name .. ": глобалы")
	end
end

T.test("заявки: экран вступления и поиск без сертификата", function()
	local w, c = Build()
	c.R:Slash("/chillzone")
	T.eq(c.R.ns.UI.Current(), "join")
	T.ok(c.R.ns.RecruitPane.frames.pane:IsShown())
	c.R.ns.UI.OpenChat("A", true)
	T.eq(c.R.ns.UI.Current(), "join")
	T.no(c.R.ns.ChatPane.frames.box:HasFocus(), "скрытый чат не забирает ввод")
	Search(w, c)
	T.eq(#c.R.ns.Recruit.found, 3, "только своя фракция")
	T.eq(#c.R.ns.Recruit.Guilds(), 2)
	for _, channel in ipairs(c.R.ns.Chat.Channels()) do T.no(channel == "A" or channel == "C" or channel == "L", "общий чат закрыт") end
	Errors(c)
end)

T.test("заявки: адресат найден сервером, текст и метаданные доставлены", function()
	local w, c = Build()
	local req = Request(w, c)
	T.ok(req)
	T.eq(req.name, c.R.ns.Util.Normal(c.R.ns.me))
	T.eq(req.level, 27)
	T.eq(req.class, "MAGE")
	T.eq(req.text, "Привет! Хочу вступить.")
	T.eq(#c.M.ns.Recruit.requests, 0, "не рассылка всей гильдии")
	T.no(c.R.ns.Recruit.Ask({ name = "Подставной Игрок", guild = "Чиллзон Север" }, "текст"))
	T.no(c.R.ns.Recruit.Ask(c.R.ns.Recruit.NextContact("Чиллзон"), "слишком рано"))
	Errors(c)
end)

T.test("заявки: маршрут лишь упорядочивает найденных сервером", function()
	local w, c = Build()
	Search(w, c)
	local R, U = c.R.ns.Recruit, c.R.ns.Util
	T.no(R.OnRoute("J2~y~~0~Чиллзон=999=Подставной Игрок", "Незнакомый Игрок", "WHISPER"))
	R.route = { t = w.now, byName = { [U.GuildKey("Чиллзон Север")] = { free = 900, contacts = { "Подставной Игрок", c.O:Name() } } } }
	T.eq(U.Key(R.NextContact("Чиллзон Север").name), U.Key(c.O:Name()))
	T.no(R.NextContact("Вымышленный Чиллзон"))
	Errors(c)
end)

T.test("заявки: не беспокоить закрывает уже открытое письмо", function()
	local w, c = Build()
	Search(w, c)
	c.O.ns.Recruit.SetNoContact(true)
	local R = c.R.ns.Recruit
	local contact = R.NextContact("Чиллзон Север")
	T.ok(R.Prompt(contact))
	w:Run(5)
	T.no(R.pending)
	T.no(c.R.ns.RecruitPane.frames.dialog:IsShown())
	T.no(R.Ask(contact, "не должно уйти"))
	T.eq(R.NextContact("Чиллзон Север").name, c.M.ns.me)
	T.eq(#c.O.ns.Recruit.requests, 0)
	Errors(c)
end)

T.test("заявки: офицер приглашает по игровому праву", function()
	local w, c = Build()
	local req = Request(w, c)
	c.O.canInvite = false
	T.no(c.O.ns.Recruit.Accept(req))
	c.O.canInvite = true
	T.ok(c.O.ns.Recruit.Accept(req))
	T.eq(c.O.invites[1], c.R:Name(), "имя без реалма")
	T.eq(#c.O.ns.Recruit.requests, 0)
	T.no(c.O.ns.Recruit.Accept(req), "повторный щелчок")
	Errors(c)
end)

T.test("заявки: отказ адресный, устаревшие действия молчат", function()
	local w, c = Build()
	local req = Request(w, c)
	T.ok(c.O.ns.Recruit.Decline(req))
	w:Run(1)
	T.ok(c.R.ns.Recruit.replied[c.O.ns.Util.Key(c.O.ns.me)])
	T.no(c.O.ns.Recruit.Decline(req))
	T.eq(#c.O.ns.Recruit.requests, 0)
	Errors(c)
end)

T.test("заявки: смена гильдии отменяет приглашение", function()
	local w, c = Build()
	local req = Request(w, c)
	c.O.guild = "Чиллзон"
	T.no(c.O.ns.Recruit.Accept(req))
	T.no(c.O.ns.Recruit.Decline(req))
	c.O.guild = "Чиллзон Север"
	T.no(c.O.ns.Recruit.Accept(req))
	T.eq(#c.O.invites, 0)
	Errors(c)
end)

T.test("заявки: фильтры, повторы, очередь без лимитов и порядок шёпота", function()
	local _, c = Build()
	local R = c.O.ns.Recruit
	T.no(R.OnJoinRequest("J3~Чиллзон~27~MAGE", c.R.ns.me, "WHISPER"))
	T.no(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "GUILD"))
	T.no(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.M.ns.me, "WHISPER"))
	T.ok(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"))
	R.OnWhisper("письмо после J3", c.R.ns.me)
	T.eq(R.requests[1].text, "письмо после J3")
	T.no(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"))
	for i = 1, 40 do R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", "Новичок " .. i, "WHISPER") end
	T.eq(#R.requests, 41, "новые заявки не вытесняют старые")
	T.eq(R.requests[1].name, c.R.ns.me, "первая заявка сохранена")
	T.eq(R.requests[1].text, "письмо после J3", "старый текст сохранён")
	T.no(R.Accept({ name = "Новичок 40", guild = "Чиллзон Север", t = 8 }), "поддельный объект")
	Errors(c)
end)

T.test("заявки: старую заявку можно обработать через несколько часов", function()
	local w, c = Build()
	local R = c.O.ns.Recruit
	T.ok(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"))
	local req = R.requests[1]
	w.now = w.now + 2 * 3600
	c.O.ns.Roster.Scan()
	T.eq(#R.Requests(), 1, "заявка не истекла через час")
	T.ok(R.Accept(req))
	T.eq(c.O.invites[1], c.R:Name())
	Errors(c)
end)

T.test("заявки: окно отправляет отредактированное письмо и показывает очередь", function()
	local w, c = Build()
	Search(w, c)
	local R = c.R.ns.Recruit
	R.Prompt(R.NextContact("Чиллзон Север"))
	local f = c.R.ns.RecruitPane.frames
	f.box:SetText("Мой текст")
	f.send:GetScript("OnClick")(f.send)
	w:Run(5)
	T.eq(c.O.ns.Recruit.requests[1].text, "Мой текст")
	c.O.ns.UI.Toggle("census")
	local rows = c.O.ns.RecruitPane.requestRows
	T.ok(rows[1]:IsShown())
	local tip = {}
	c.O.stubs.GameTooltip = true
	c.O.env.GameTooltip = {
		SetOwner = function() end, Show = function() end,
		AddLine = function(_, text) tip[#tip + 1] = text end,
	}
	rows[1]:GetScript("OnEnter")(rows[1])
	T.eq(tip[2], "Мой текст", "полный текст доступен в подсказке")
	rows[1].accept:GetScript("OnClick")(rows[1].accept)
	T.eq(c.O.invites[1], c.R:Name())
	Errors(c)
end)

T.test("заявки: поиск ограничивает частоту, продолжает диапазоны и убирает дубли", function()
	local w, c = Build()
	c.R.whoRows = {}
	for i = 1, 50 do c.R.whoRows[i] = { fullName = "Игрок " .. i, fullGuildName = "Чиллзон Север", level = i, filename = "MAGE" } end
	T.ok(c.R.ns.Who.Search())
	T.no(c.R.ns.Who.Search())
	w:Run(11)
	T.eq(#c.R.ns.Recruit.found, 50)
	T.ok(c.R.ns.Who.missing)
	T.ok(c.R.ns.Who.Search())
	T.ok(c.R.whoQueries[2]:find("%d+%-%d+"))
	w:Run(2)
	T.eq(#c.R.ns.Recruit.found, 50)
	Errors(c)
end)

T.test("заявки: обычный участник направляет к офицеру, скрытие ничего не отправляет", function()
	local w, c = Build()
	local R = c.M.ns.Recruit
	T.ok(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"))
	local req = R.requests[1]
	T.no(R.Accept(req))
	T.ok(R.Point(req))
	w:Run(1)
	local pointed = false
	for _, entry in ipairs(w.log) do
		if entry.dist == "CHAT_WHISPER" and entry.msg:find(c.O:Name(), 1, true) then pointed = true end
	end
	T.ok(pointed)
	w:Run(601)
	T.ok(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"))
	local before = #w.log
	T.ok(R.Dismiss(R.requests[1]))
	T.eq(#w.log, before)
	Errors(c)
end)

T.test("заявки: secret-шёпот не читается, J3 из реле и неизвестные классы отклоняются", function()
	local _, c = Build()
	local R = c.O.ns.Recruit
	local secret = {}
	c.O.env.issecretvalue = function(v) return v == secret end
	R.OnWhisper(secret, secret)
	T.no(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER", { via = "RL" }))
	T.no(R.OnJoinRequest("J3~Чиллзон Север~27~FAKE", c.R.ns.me, "WHISPER"))
	T.eq(#R.requests, 0)
	Errors(c)
end)

T.test("заявки: тайм-аут поиска и посторонний поиск не подменяют адресата", function()
	local w, c = Build()
	c.R.whoTimeout = true
	T.ok(c.R.ns.Who.Search())
	w:Run(7)
	T.no(c.R.ns.Who.IsPending())
	c.R:Fire("WHO_LIST_UPDATE")
	T.eq(#c.R.ns.Recruit.found, 0)
	w:Run(4)
	T.no(c.R.ns.Who.Search(), "после тайм-аута старый ответ ещё может прийти")
	w:Run(30)
	c.R.whoTimeout = false
	T.ok(c.R.ns.Who.Search())
	c.R.env.C_FriendList.SendWho('n-"Совсем другой"')
	T.no(c.R.ns.Who.IsPending(), "посторонний запрос отменяет ожидание")
	w:Run(2)
	T.eq(#c.R.ns.Recruit.found, 0, "ответ чужого поиска не наш")
	Errors(c)
end)

T.test("заявки: legacy API поиска, приглашения и кириллица без обрезанной буквы", function()
	local w, c = Build()
	local api = c.R.env.C_FriendList
	c.R.env.C_FriendList = nil
	c.R.env.SendWho, c.R.env.GetWhoInfo = api.SendWho, function(i)
		local row = api.GetWhoInfo(i)
		return row.fullName, row.fullGuildName, row.level, "Человек", "Маг", "Штормград", row.filename
	end
	c.R.env.GetNumWhoResults = api.GetNumWhoResults
	Search(w, c)
	local contact = c.R.ns.Recruit.NextContact("Чиллзон Север")
	T.ok(c.R.ns.Recruit.Ask(contact, string.rep("я", 140)))
	w:Run(5)
	T.eq(c.O.ns.Recruit.requests[1].text, string.rep("я", 125))
	c.O.env.C_GuildInfo.Invite = nil
	T.ok(c.O.ns.Recruit.Accept(c.O.ns.Recruit.requests[1]))
	T.eq(c.O.invites[1], c.R:Name())
	Errors(c)
end)

T.test("заявки: вступивший уже игрок исчезает из очереди", function()
	local w, c = Build()
	local req = Request(w, c)
	c.R.guild = "Чиллзон Север"
	c.O.ns.Roster.Scan()
	T.eq(#c.O.ns.Recruit.Requests(), 0)
	T.no(c.O.ns.Recruit.Accept(req))
	c.R:Fire("PLAYER_GUILD_UPDATE", "player")
	w:Run(3)
	c.R.ns.UI.Toggle("census")
	T.eq(c.R.ns.UI.Current(), "census")
	T.no(c.R.ns.Recruit.pending)
	Errors(c)
end)

T.test("заявки: отключение обращений сохраняется для аккаунта, как в Olympus", function()
	local w, c = Build()
	c.O:Slash("/chillzone", "nocontact on")
	local alt = w:Client({ first = "Другой", surname = "Персонаж", guild = "Чиллзон Север", db = c.O.ns.db })
	T.ok(alt.ns.Recruit.NoContactMe())
	alt:Slash("/chillzone", "nocontact off")
	T.no(c.O.ns.Recruit.NoContactMe())
	Errors(c)
end)
