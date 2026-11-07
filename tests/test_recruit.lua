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
	T.no(R.NextContact("Чиллзон Север"), "рядовой не предлагается вместо офицера")
	T.eq(#c.O.ns.Recruit.requests, 0)
	Errors(c)
end)

T.test("заявки: поиск показывает офицеров, рядовым просьба не уходит", function()
	local w, c = Build()
	c.R:Slash("/chillzone")
	Search(w, c)
	local R, U = c.R.ns.Recruit, c.R.ns.Util
	local asked = {}
	for _, entry in ipairs(w.log) do
		if entry.from == "Новый Игрок" and entry.msg:find("J1~1", 1, true) then asked[entry.target] = true end
	end
	T.ok(asked[c.K:Name()], "J1 участнику второй гильдии")
	T.ok(asked[c.O:Name()] and asked[c.M:Name()], "J1 нескольким из гильдии без известных офицеров")
	-- Ответы J2 складываются: ответ Короля (своя гильдия без контактов) не стирает офицеров Севера.
	local officers = R.Officers("Чиллзон Север")
	T.eq(#officers, 1, "только глава, рядовой Миша не офицер")
	T.eq(U.Key(officers[1].name), U.Key(c.O:Name()))
	T.eq(#R.Officers("Чиллзон"), 0, "Король не адресат")
	local guilds = R.Guilds()
	T.eq(guilds[1].name, "Чиллзон Север", "гильдия с офицерами — первой")
	T.ok(guilds[1].free and guilds[2].free, "места известны для обеих гильдий")
	local rows = c.R.ns.RecruitPane.guildRows
	T.ok(rows[1].sub:GetText():find(U.Display(c.O:Name()), 1, true), "в строке гильдии — имя офицера")
	T.no(rows[1].sub:GetText():find(U.Display(c.M:Name()), 1, true), "рядового в строке нет")
	T.ok(rows[2].sub:GetText():find(c.R.ns.L.RECRUIT_OFFICERS_UNKNOWN, 1, true))
	T.eq(rows[2].ask:GetText(), c.R.ns.L.RECRUIT_NO_OFFICERS, "без офицеров писать некому")
	T.no(R.NextContact("Чиллзон"))
	R.asked[U.Key(c.O:Name())] = w.now
	T.no(R.NextContact("Чиллзон Север"), "после главы рядовому не пишем")
	T.no(R.NextContact())
	local logged = false
	for _, line in ipairs(c.R.ns.db.log) do logged = logged or line:find("J2 от", 1, true) ~= nil end
	T.ok(logged, "ответ J2 виден в логе")
	Errors(c)
end)

T.test("заявки: заполненная гильдия видна внизу, но просьба в неё не уходит", function()
	local w, c = Build()
	c.R:Slash("/chillzone")
	-- У участников «Чиллзон Север» гильдия заполнена: мест 0.
	local caps = {}
	for _, m in ipairs({ c.O, c.M }) do
		for _, s in ipairs(m.ns.Data.Summary()) do
			if s.mine then caps[m] = m.ns.Codec.GUILD_CAP; m.ns.Codec.GUILD_CAP = s.total end
		end
	end
	T.ok(caps[c.O] and caps[c.M], "у участников есть свой отчёт")
	Search(w, c)
	for m, cap in pairs(caps) do m.ns.Codec.GUILD_CAP = cap end
	local R, U = c.R.ns.Recruit, c.R.ns.Util
	local officers = R.Officers("Чиллзон Север")
	T.eq(#officers, 1)
	T.eq(U.Key(officers[1].name), U.Key(c.O:Name()))
	local north
	for _, g in ipairs(R.Guilds()) do if g.name == "Чиллзон Север" then north = g end end
	T.eq(north.free, 0, "мест нет, но офицеры видны")
	T.eq(R.Guilds()[#R.Guilds()].name, "Чиллзон Север", "заполненная гильдия — последней")
	T.no(R.NextContact("Чиллзон Север"))
	T.no(R.Prompt(officers[1]))
	T.no(R.Ask(officers[1], "Мест нет, не отправлять."))
	local L, rows = c.R.ns.L, c.R.ns.RecruitPane.guildRows
	T.eq(rows[2].title:GetText(), "Чиллзон Север")
	T.ok(rows[2].sub:GetText():find(U.Display(c.O:Name()), 1, true), "имя офицера видно")
	T.eq(rows[2].ask:GetText(), L.RECRUIT_NO_PLACES)
	T.no(R.NextSearch(), "офицеров заполненной гильдии не проверяем")
	R.route = nil
	T.ok(R.HasSpace("Чиллзон Север"), "неизвестное число мест — не ноль")
	w:Run(5)
	T.eq(#c.O.ns.Recruit.requests, 0)
	Errors(c)
end)

T.test("заявки: заполнение гильдии закрывает письмо и блокирует старый контакт", function()
	local w, c = Build()
	Search(w, c)
	local R = c.R.ns.Recruit
	local contact = R.NextContact("Чиллзон Север")
	T.ok(contact)
	-- Адресат отвечает на повторный J1 после своей минутной паузы: мест уже нет.
	w:Run(61)
	c.O.ns.Recruit.RouteAnswer = function() return "J2~y~~0~Чиллзон Север=0=" .. c.O:Name() end
	T.ok(R.Prompt(contact))
	w:Run(5)
	T.no(R.pending)
	T.no(c.R.ns.RecruitPane.frames.dialog:IsShown())
	T.eq(c.R:Saw(c.R.ns.L.RECRUIT_FULL:format("Чиллзон Север")), 1)
	T.no(R.Prompt(contact))
	T.no(R.Ask(contact, "Не отправлять в заполненную гильдию."))
	w:Run(5)
	T.eq(#c.O.ns.Recruit.requests, 0)
	T.ok(R.OnRoute("J2~y~~0~Чиллзон Север=10=" .. c.O:Name(), c.O:Name(), "WHISPER"))
	T.ok(R.NextContact("Чиллзон Север"), "появились места — гильдия снова доступна")
	Errors(c)
end)

T.test("заявки: офицер вне выдачи поиска по гильдии проверяется по имени", function()
	local w, c = Build()
	c.R:Slash("/chillzone")
	local leader = c.O:Name()
	-- В большой гильдии /who по гильдии отдаёт 50 строк: глава в них не попал.
	c.R.whoRows = function(query, rows)
		if not query:find("g%-") then return rows end
		local out = {}
		for _, row in ipairs(rows) do
			if not row.fullName:find(leader, 1, true) then out[#out + 1] = row end
		end
		return out
	end
	Search(w, c)
	local R, U = c.R.ns.Recruit, c.R.ns.Util
	T.eq(#R.Officers("Чиллзон Север"), 0, "глава назван, но не найден")
	local kind, name, hint = R.NextSearch()
	T.eq(kind, "verify")
	T.eq(U.Key(name), U.Key(leader))
	T.eq(hint.name, "Чиллзон Север")
	w:Run(11)
	T.ok(R.Search())
	T.eq(c.R.whoQueries[#c.R.whoQueries], '"' .. leader .. '"', "запрос по имени, как /who \"Имя Фамилия\"")
	w:Run(1)
	local officers = R.Officers("Чиллзон Север")
	T.eq(#officers, 1, "найден по имени")
	T.eq(U.Key(officers[1].name), U.Key(leader))
	T.no(R.NextSearch())
	w:Run(11)
	T.ok(R.Search())
	T.ok(c.R.whoQueries[#c.R.whoQueries]:find("g-", 1, true), "дальше обычный поиск")
	Errors(c)
end)

-- Большая заполненная главная гильдия: общий поиск по GUILD_TOKEN отдаёт 50 её строк, и
-- «Чиллзон Север» в них не попадает. Перепись главной гильдии знает «Север» и его места;
-- officers — кого из офицеров «Севера» она может назвать (по сертификатам).
local function FullMain(officers)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Другая гильдия")
	local c = {}
	c.K = w:Client({ first = "Король", surname = "Чиллзона", guild = "Чиллзон", rank = 0 })
	c.KO = w:Client({ first = "Капитан", surname = "Главный", guild = "Чиллзон", rank = 1 })
	c.O = w:Client({ first = "Ольга", surname = "Северная", guild = "Чиллзон Север", rank = 0 })
	c.M = w:Client({ first = "Миша", surname = "Северный", guild = "Чиллзон Север", rank = 3 })
	c.R = w:Client({ first = "Новый", surname = "Игрок", guild = "Другая гильдия", level = 27 })
	w:Run(8)
	local answer = ("J2~y~~0~Чиллзон=0=%s;Чиллзон Север=40=%s"):format(c.KO:Name(), officers or "")
	for _, m in ipairs({ c.K, c.KO }) do m.ns.Recruit.RouteAnswer = function() return answer end end
	c.R.whoRows = function(query, rows)
		if query ~= 'g-"Чиллзон"' then return rows end
		local out = {}
		for _, row in ipairs(rows) do
			if row.fullGuildName == "Чиллзон" then out[#out + 1] = row end
		end
		for i = #out + 1, 50 do out[i] = { fullName = "Рядовой Номер" .. i, fullGuildName = "Чиллзон", level = 60, filename = "WARRIOR" } end
		return out
	end
	c.R:Slash("/chillzone")
	return w, c
end

local function GuildNames(R)
	local out = {}
	for _, g in ipairs(R.Guilds()) do out[#out + 1] = g.name end
	return table.concat(out, ",")
end

T.test("заявки: заполненная главная гильдия не заслоняет гильдию с местами", function()
	local w, c = FullMain()
	local R, U, L = c.R.ns.Recruit, c.R.ns.Util, c.R.ns.L
	T.ok(R.Search())
	T.eq(c.R.whoQueries[1], 'g-"Чиллзон"')
	w:Run(5)
	local guilds = R.Guilds()
	T.eq(GuildNames(R), "Чиллзон Север,Чиллзон", "гильдия с местами из подсказки J2 — первой")
	T.eq(#guilds[1].members, 0, "/who её участников ещё не нашёл")
	T.eq(guilds[1].free, 40)
	T.eq(guilds[2].free, 0)
	local rows = c.R.ns.RecruitPane.guildRows
	T.eq(rows[1].ask:GetText(), L.RECRUIT_NO_OFFICERS)
	T.eq(rows[2].ask:GetText(), L.RECRUIT_NO_PLACES, "офицер главной гильдии найден, но мест нет")
	T.no(R.NextContact(), "писать пока некому")
	T.no(c.R.ns.Who.Covered("Чиллзон"), "выдача обрезана до 50 строк")
	local kind, name = R.NextSearch()
	T.eq(kind, "guild", "следующий щелчок ищет гильдию с местами из подсказки J2")
	T.eq(name, "Чиллзон Север")
	T.eq(c.R.ns.RecruitPane.frames.note:GetText(), L.RECRUIT_GUILD_NEXT:format("Чиллзон Север", 40))
	local asked = #w.log
	w:Run(6)
	T.ok(R.Search())
	T.eq(c.R.whoQueries[2], 'g-"Чиллзон Север"')
	w:Run(10)
	-- J1 участникам «Севера» уходит после паузы между пачками, без нового щелчка.
	local north = {}
	for i = asked + 1, #w.log do
		local e = w.log[i]
		if e.from == "Новый Игрок" and e.msg == "J1~1" then
			T.ok(e.target == c.O:Name() or e.target == c.M:Name(), "J1 не уходит заполненной гильдии: " .. e.target)
			north[e.target] = true
		end
	end
	T.ok(north[c.O:Name()], "J1 участнику «Севера»")
	T.eq(GuildNames(R), "Чиллзон Север,Чиллзон", "гильдия с местами выше заполненной")
	T.eq(U.Key(R.NextContact().name), U.Key(c.O:Name()), "первым предлагается офицер гильдии с местами")
	T.eq(#c.R.whoQueries, 2, "хватило двух щелчков")
	Errors(c)
end)

T.test("заявки: офицер гильдии с местами из чужой подсказки проверяется по имени", function()
	local w, c = FullMain("Ольга Северная")
	local R, U, L = c.R.ns.Recruit, c.R.ns.Util, c.R.ns.L
	T.ok(R.Search())
	w:Run(5)
	local kind, name = R.NextSearch()
	T.eq(kind, "verify", "названный офицер проверяется раньше поиска по гильдии")
	T.eq(U.Key(name), U.Key(c.O:Name()))
	T.eq(c.R.ns.RecruitPane.frames.note:GetText(), L.RECRUIT_VERIFY_NEXT:format("Чиллзон Север", 40))
	w:Run(6)
	T.ok(R.Search())
	T.eq(c.R.whoQueries[2], '"' .. c.O:Name() .. '"')
	w:Run(1)
	T.eq(GuildNames(R), "Чиллзон Север,Чиллзон")
	T.eq(U.Key(R.NextContact().name), U.Key(c.O:Name()))
	Errors(c)
end)

T.test("заявки: поиск гильдии без ответа /who повторяется следующим щелчком", function()
	local w, c = FullMain()
	local R = c.R.ns.Recruit
	T.ok(R.Search())
	w:Run(11)
	c.R.whoTimeout = true
	T.ok(R.Search())
	T.eq(c.R.whoQueries[2], 'g-"Чиллзон Север"')
	w:Run(7)
	T.no(c.R.ns.Who.IsPending(), "тайм-аут")
	local kind, name = R.NextSearch()
	T.eq(kind, "guild", "неудачный запрос не засчитан")
	T.eq(name, "Чиллзон Север")
	c.R.whoTimeout = nil
	w:Run(31)
	T.ok(R.Search())
	T.eq(c.R.whoQueries[3], 'g-"Чиллзон Север"')
	w:Run(1)
	T.ok(R.Guilds()[1].name == "Чиллзон Север")
	Errors(c)
end)

T.test("заявки: гильдию, найденную общим поиском целиком, отдельно не ищем", function()
	local w, c = Build()
	Search(w, c)
	local R, U = c.R.ns.Recruit, c.R.ns.Util
	T.ok(c.R.ns.Who.Covered("Чиллзон Север"), "выдача не обрезана")
	R.route = { t = w.now, byName = {
		[U.GuildKey("Чиллзон Север")] = { name = "Чиллзон Север", free = 900, contacts = {} },
	} }
	T.no(R.NextSearch(), "все участники «Севера» в игре уже найдены")
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
	c.O.ns.UI.Toggle("requests")
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

T.test("заявки: поиск находит гильдию из EXTRA_GUILDS следующим запросом", function()
	local w, c = Build()
	w:Guild("Запомни Навсегда")
	c.Z = w:Client({ first = "Зоя", surname = "Навсегдашняя", guild = "Запомни Навсегда", rank = 0 })
	w:Run(8)
	T.ok(c.R.ns.Who.Search())
	w:Run(11)
	T.eq(c.R.whoQueries[1], 'g-"Чиллзон"')
	local function Has(guild)
		for _, g in ipairs(c.R.ns.Recruit.Guilds()) do
			if g.name == guild then return true end
		end
		return false
	end
	T.ok(Has("Чиллзон Север"))
	T.no(Has("Запомни Навсегда"), "по токену не находится")
	T.ok(c.R.ns.Who.missing, "раунд не закончен")
	T.ok(c.R.ns.Who.Search())
	w:Run(11)
	T.eq(c.R.whoQueries[2], 'g-"Запомни Навсегда"')
	T.ok(Has("Запомни Навсегда"))
	T.ok(Has("Чиллзон Север"), "найденное раньше остаётся")
	T.no(c.R.ns.Who.missing, "раунд закончен")
	T.ok(c.R.ns.Who.Search())
	T.eq(c.R.whoQueries[3], 'g-"Чиллзон"', "новый раунд")
	w:Run(2)
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
