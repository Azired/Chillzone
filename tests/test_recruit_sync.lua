-- Общая очередь заявок, синхронизация офицеров и отдельная вкладка.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	w:Guild("Чиллзон")
	local c = {}
	c.O = w:Client({ first = "Ольга", surname = "Северная", guild = "Чиллзон Север", rank = 0 })
	c.P = w:Client({ first = "Пётр", surname = "Северный", guild = "Чиллзон Север", rank = 1 })
	c.M = w:Client({ first = "Миша", surname = "Северный", guild = "Чиллзон Север", rank = 3 })
	c.N = w:Client({ first = "Нина", surname = "Северная", guild = "Чиллзон Север", rank = 3 })
	c.K = w:Client({ first = "Король", surname = "Чиллзона", guild = "Чиллзон", rank = 0 })
	c.R = w:Client({ first = "Новый", surname = "Игрок", level = 27 })
	-- Общая очередь проверяется в уже подключённой гильдии, отдельно от её допуска. Гильдия
	-- подключена с самого входа, до первого w:Run, как прежде по названию.
	for _, client in pairs(c) do
		client.ns.store.security.union[client.ns.Util.GuildKey("Чиллзон Север")] = { guild = "Чиллзон Север", active = true }
	end
	w:Run(15)
	return w, c
end

local function Receive(w, c, target, text)
	local r = c[target].ns.Recruit
	if text then r.OnWhisper(text, c.R.ns.me) end
	T.ok(r.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"))
	if text then T.ok(r.OnText("JT~1~Чиллзон Север~27~MAGE~" .. text, c.R.ns.me, "WHISPER")) end
	w:Run(15)
	return r.requests[1]
end

local function Errors(c)
	for name, client in pairs(c) do
		T.eq(#client.ns.db.errors, 0, name .. ": " .. table.concat(client.ns.db.errors, " | "))
		T.eq(#client:Leaks(), 0, name .. ": глобалы")
	end
end

-- Подсказка вкладки «Заявки»: число заявок теперь там, а не в подписи.
local function TabTip(client)
	local tip = {}
	client.stubs.GameTooltip = true
	client.env.GameTooltip = {
		SetOwner = function() end, Show = function() end, Hide = function() end,
		AddLine = function(_, text) tip[#tip + 1] = text end,
	}
	local tab = client.ns.UI.tabs.requests
	tab:GetScript("OnEnter")(tab)
	return tip[1]
end

T.test("общие заявки: вкладка видна главе без заявок, без подписи и с пустым состоянием", function()
	local _, c = Build()
	c.O:Slash("/chillzone", "requests")
	T.eq(c.O.ns.UI.Current(), "requests")
	T.ok(c.O.ns.UI.tabs.requests:IsShown())
	T.eq(rawget(c.O.ns.UI.tabs.requests, "label"), nil, "у значка нет подписи")
	T.eq(TabTip(c.O), "Заявки")
	T.ok(c.O.ns.RecruitPane.frames.inbox:IsShown())
	T.ok(c.O.ns.RecruitPane.frames.inboxEmpty:IsShown())
	Errors(c)
end)

T.test("общие заявки: рядовой не видит вкладку, а его заявка уходит офицерам", function()
	local w, c = Build()
	Receive(w, c, "M", "Просьба рядовому")
	T.eq(c.M:Saw("Заявку увидят глава и офицеры."), 1)
	T.eq(c.M:Saw("на вкладке «Заявки»"), 0, "рядовому не указываем на скрытую вкладку")
	T.eq(#c.O.ns.Recruit.Requests(), 1)
	c.M.ns.UI.Toggle("census")
	T.no(c.M.ns.UI.tabs.requests:IsShown())
	T.ok(c.M.ns.UI.tabs.kingdom:IsShown())
	c.M:Slash("/chillzone", "requests")
	T.eq(c.M.ns.UI.Current(), "census", "команда не открывает скрытую вкладку")
	T.eq(c.M:Saw("вкладка «Заявки» только для глав и офицеров"), 1)
	Errors(c)
end)

T.test("общие заявки: потеря звания при открытом окне прячет вкладку", function()
	local w, c = Build()
	Receive(w, c, "M", "Для офицеров")
	c.P:Slash("/chillzone", "requests")
	T.eq(c.P.ns.UI.Current(), "requests")
	c.P.rank = 3
	c.O.ns.Roster.Scan(); c.M.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	T.no(c.P.ns.UI.tabs.requests:IsShown())
	T.eq(c.P.ns.UI.Current(), "chat")
	T.no(c.P.ns.RecruitPane.frames.inbox:IsShown())
	c.P.rank = 1
	c.O.ns.Roster.Scan(); c.M.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	T.ok(c.P.ns.UI.tabs.requests:IsShown(), "звание вернули — вкладка снова видна")
	Errors(c)
end)

T.test("общие заявки: офицеры видят чужую заявку, рядовые и другая гильдия — нет", function()
	local w, c = Build()
	Receive(w, c, "O", "Хочу вступить")
	T.eq(#c.P.ns.Recruit.Requests(), 1)
	T.eq(c.P.ns.Recruit.requests[1].text, "Хочу вступить")
	T.eq(#c.M.ns.Recruit.Requests(), 0)
	T.eq(#c.N.ns.Recruit.Requests(), 0)
	T.eq(#c.K.ns.Recruit.Requests(), 0)
	c.P.ns.UI.Toggle("chat")
	T.eq(TabTip(c.P), "Заявки (1)")
	c.M.ns.UI.Toggle("chat")
	T.no(c.M.ns.UI.tabs.requests:IsShown(), "рядовым вкладка не видна")
	Errors(c)
end)

T.test("общие заявки: рядовой передаёт офицерам, другой офицер принимает", function()
	local w, c = Build()
	Receive(w, c, "M", "Моё письмо")
	T.eq(#c.O.ns.Recruit.Requests(), 1)
	T.eq(#c.P.ns.Recruit.Requests(), 1)
	local stale = c.O.ns.Recruit.requests[1]
	c.P:Slash("/chillzone", "requests")
	local accept = c.P.ns.RecruitPane.requestRows[1].accept
	T.ok(accept:IsShown())
	accept:GetScript("OnClick")(accept)
	T.eq(c.P.invites[1], c.R:Name())
	w:Run(15)
	T.eq(#c.O.ns.Recruit.Requests(), 0)
	T.eq(#c.M.ns.Recruit.Requests(), 0)
	T.no(c.O.ns.Recruit.Accept(stale), "обработанная заявка не действует")
	Errors(c)
end)

T.test("общие заявки: отложенный текст приходит всем, следующие личные реплики не пересылаются", function()
	local w, c = Build()
	Receive(w, c, "M")
	T.eq(c.P.ns.Recruit.requests[1].text, nil)
	T.ok(c.M.ns.Recruit.OnText("JT~1~Чиллзон Север~27~MAGE~Первая просьба", c.R.ns.me, "WHISPER"))
	w:Run(15)
	T.eq(c.P.ns.Recruit.requests[1].text, "Первая просьба")
	c.M.ns.Recruit.OnWhisper("Личная беседа после просьбы", c.R.ns.me)
	w:Run(15)
	T.eq(c.P.ns.Recruit.requests[1].text, "Первая просьба")
	Errors(c)
end)

T.test("общие заявки: вошедший позже офицер восстанавливает очередь", function()
	local w, c = Build()
	Receive(w, c, "M", "Ранее полученная просьба")
	c.L = w:Client({ first = "Поздний", surname = "Офицер", guild = "Чиллзон Север", rank = 1 })
	c.L.ns.store.security.union[c.L.ns.Util.GuildKey(c.L.guild)] = { active = true }
	-- Сервер сообщает старым участникам о новом офицере в ростере.
	c.O.ns.Roster.Scan(); c.M.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	w:Run(35)
	T.eq(#c.L.ns.Recruit.Requests(), 1)
	T.eq(c.L.ns.Recruit.requests[1].text, "Ранее полученная просьба")
	Errors(c)
end)

T.test("общие заявки: закрытие синхронизируется, старые снимки не оживляют заявку", function()
	local w, c = Build()
	local req = Receive(w, c, "M", "Прошлая просьба")
	local wire = c.M.ns.RecruitSync.Pack(req)
	T.ok(c.O.ns.Recruit.Dismiss(c.O.ns.Recruit.requests[1]))
	w:Run(15)
	T.eq(#c.P.ns.Recruit.Requests(), 0)
	T.no(c.P.ns.RecruitSync.OnShared(wire, c.M.ns.me, "WHISPER"))
	T.eq(#c.P.ns.Recruit.Requests(), 0)
	c.L = w:Client({ first = "Ещё", surname = "Офицер", guild = "Чиллзон Север", rank = 1 })
	w:Run(35)
	T.eq(#c.L.ns.Recruit.Requests(), 0)
	Errors(c)
end)

T.test("общие заявки: подделки рядового, постороннего, реле и другой гильдии отклоняются", function()
	local w, c = Build()
	local req = Receive(w, c, "M", "Настоящая просьба")
	local S = c.O.ns.RecruitSync
	local wire = c.M.ns.RecruitSync.Pack(req)
	T.no(S.OnShared(wire, c.N.ns.me, "WHISPER"), "рядовой не приписывает себе чужую просьбу")
	T.no(S.OnShared(wire, c.R.ns.me, "WHISPER"))
	T.no(S.OnShared(wire, c.K.ns.me, "WHISPER"))
	T.no(S.OnShared(wire, c.M.ns.me, "GUILD"))
	T.no(S.OnShared(wire, c.M.ns.me, "WHISPER", { via = "RL" }))
	local closed = "JX~1~Чиллзон Север~" .. c.R.ns.me .. "~" .. c.O.ns.ServerTime()
	T.no(S.OnClosed(closed, c.M.ns.me, "WHISPER"))
	T.no(S.OnClosed(closed, c.K.ns.me, "WHISPER"))
	T.eq(#c.O.ns.Recruit.Requests(), 1)
	Errors(c)
end)

T.test("общие заявки: потеря офицерского звания закрывает чужую очередь", function()
	local w, c = Build()
	Receive(w, c, "M", "Для офицеров")
	c.P.rank = 3
	c.O.ns.Roster.Scan(); c.M.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	T.eq(#c.P.ns.Recruit.Requests(), 0)
	c.P.rank = 1
	c.O.ns.Roster.Scan(); c.M.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	w:Run(35)
	T.eq(#c.P.ns.Recruit.Requests(), 1)
	Errors(c)
end)

T.test("общие заявки: настройка личных обращений не отключает очередь офицера", function()
	local w, c = Build()
	c.P.ns.Recruit.SetNoContact(true)
	Receive(w, c, "M", "Просьба через другого участника")
	T.eq(#c.P.ns.Recruit.Requests(), 1)
	c.P.canInvite = false
	T.no(c.P.ns.Recruit.Accept(c.P.ns.Recruit.requests[1]))
	c.P.canInvite = true
	T.ok(c.P.ns.Recruit.Accept(c.P.ns.Recruit.requests[1]))
	Errors(c)
end)

T.test("общие заявки: большой снимок не упирается в размер очереди транспорта", function()
	local w, c = Build()
	for i = 1, 205 do
		T.ok(c.M.ns.Recruit.OnJoinRequest("J3~Чиллзон Север~27~MAGE", "Новичок " .. i, "WHISPER"))
	end
	w:Run(1200)
	T.eq(#c.O.ns.Recruit.Requests(), 205)
	T.eq(#c.P.ns.Recruit.Requests(), 205)
	T.eq(#c.N.ns.Recruit.Requests(), 0)
	Errors(c)
end)

T.test("общие заявки: список позволяет просматривать все заявки, не только первые пять", function()
	local w, c = Build()
	for i = 1, 12 do
		T.ok(c.M.ns.Recruit.OnJoinRequest("J3~Чиллзон Север~27~MAGE", "Новичок " .. i, "WHISPER"))
	end
	w:Run(80)
	c.O:Slash("/chillzone", "requests")
	T.eq(#c.O.ns.RecruitPane.requestRows, 12)
	T.ok(c.O.ns.RecruitPane.requestRows[12]:IsShown())
	T.no(c.O.ns.RecruitPane.frames.inboxEmpty:IsShown())
	Errors(c)
end)

T.test("общие заявки: собственное понижение действует до очередного чтения ростера", function()
	local w, c = Build()
	Receive(w, c, "M", "Для офицеров")
	T.ok(c.M.ns.Recruit.OnJoinRequest("J3~Чиллзон Север~27~MAGE", "Другой Игрок", "WHISPER"))
	local wire = c.M.ns.RecruitSync.Pack(c.M.ns.Recruit.requests[2])
	c.P.rank = 3
	T.no(c.P.ns.RecruitSync.OnShared(wire, c.M.ns.me, "WHISPER"))
	T.eq(#c.P.ns.Recruit.Requests(), 0)
	Errors(c)
end)

T.test("общие заявки: новое обращение после закрытия не стирается старым решением", function()
	local w, c = Build()
	Receive(w, c, "M", "Первое обращение")
	local closed = "JX~1~Чиллзон Север~" .. c.R.ns.me .. "~" .. c.O.ns.ServerTime()
	T.ok(c.O.ns.Recruit.Dismiss(c.O.ns.Recruit.requests[1]))
	w:Run(601)
	Receive(w, c, "M", "Повторное обращение")
	T.eq(#c.P.ns.Recruit.Requests(), 1)
	T.eq(c.P.ns.Recruit.requests[1].text, "Повторное обращение")
	T.no(c.P.ns.RecruitSync.OnClosed(closed, c.O.ns.me, "WHISPER"))
	T.eq(#c.P.ns.Recruit.Requests(), 1)
	Errors(c)
end)

T.test("общие заявки: предыдущая личная переписка не становится текстом общей заявки", function()
	local w, c = Build()
	c.M.ns.Recruit.OnWhisper("Предыдущее личное сообщение", c.R.ns.me)
	Receive(w, c, "M")
	T.eq(c.P.ns.Recruit.requests[1].text, nil, "нельзя делиться неподтверждённым текстом обычного шёпота")
	T.ok(c.M.ns.Recruit.OnText("JT~1~Чиллзон Север~27~MAGE~Само письмо просьбы", c.R.ns.me, "WHISPER"))
	w:Run(15)
	T.eq(c.P.ns.Recruit.requests[1].text, "Само письмо просьбы")
	Errors(c)
end)

T.test("общие заявки: текст просьбы может прийти первым и не принимает чужой контекст", function()
	local w, c = Build()
	local R = c.M.ns.Recruit
	local wire = "JT~1~Чиллзон Север~27~MAGE~Письмо с символом ~ внутри"
	T.no(R.OnText(wire, c.R.ns.me, "GUILD"))
	T.no(R.OnText(wire, c.R.ns.me, "WHISPER", { via = "RL" }))
	T.ok(R.OnText(wire, c.R.ns.me, "WHISPER"))
	T.no(R.OnJoinRequest("J3~Чиллзон Север~27~MAGE", c.R.ns.me, "WHISPER"), "поздний J3 не создаёт дубль")
	T.no(R.OnText(wire, c.R.ns.me, "WHISPER"), "повтор не меняет письмо")
	w:Run(15)
	T.eq(#c.O.ns.Recruit.Requests(), 1)
	T.eq(c.O.ns.Recruit.requests[1].text, "Письмо с символом ~ внутри")
	Errors(c)
end)

T.test("общие заявки: отложенный явный текст дополняет старую заявку без смены её даты", function()
	local w, c = Build()
	local req = Receive(w, c, "M")
	local id, created = req.id, req.created
	w.now = w.now + 2 * 3600
	c.M.ns.Roster.Scan()
	T.ok(c.M.ns.Recruit.OnText("JT~1~Чиллзон Север~27~MAGE~Отложенное письмо", c.R.ns.me, "WHISPER"))
	T.eq(c.M.ns.Recruit.requests[1].id, id)
	T.eq(c.M.ns.Recruit.requests[1].created, created)
	Errors(c)
end)

T.test("общие заявки: вступление очищает фоновые копии, даже если окна закрыты", function()
	local w, c = Build()
	Receive(w, c, "M", "Обращение до вступления")
	T.ok(c.M.ns.Recruit.Dismiss(c.M.ns.Recruit.requests[1]), "рядовой скрыл только у себя")
	c.R.guild = "Чиллзон Север"
	c.M.ns.Roster.Scan(); c.O.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	c.R.guild = nil
	c.M.ns.Roster.Scan(); c.O.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	c.L = w:Client({ first = "Поздний", surname = "Офицер", guild = "Чиллзон Север", rank = 1 })
	c.M.ns.Roster.Scan(); c.O.ns.Roster.Scan(); c.P.ns.Roster.Scan()
	w:Run(35)
	T.eq(#c.L.ns.Recruit.Requests(), 0, "старая просьба после вступления не восстанавливается")
	Errors(c)
end)

T.test("общие заявки: решение не ждёт передачи большого снимка", function()
	local w, c = Build()
	Receive(w, c, "M", "Просьба для обработки")
	local req = c.O.ns.Recruit.requests[1]
	for i = 1, 80 do
		T.ok(c.O.ns.Recruit.OnJoinRequest("J3~Чиллзон Север~27~MAGE", "Фоновый Игрок " .. i, "WHISPER"))
	end
	T.ok(c.O.ns.Recruit.Accept(req))
	w:Run(8)
	for _, pending in ipairs(c.P.ns.Recruit.Requests()) do
		T.no(c.P.ns.Util.SameName(pending.name, c.R.ns.me), "решение должно обойти фоновый снимок")
	end
	Errors(c)
end)
