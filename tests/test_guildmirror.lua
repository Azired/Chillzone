-- Копия общего чата в /g: без аддона её видно, с аддоном остаётся одна строка.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local PREFIX = "[Чиллзон] "
local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт]|h|r"

-- Игра рисует обычный чат независимо от событий аддона и применяет только фильтры чата.
local function NativeChat(c)
	c.handlers.CHAT_MSG_GUILD = c.handlers.CHAT_MSG_GUILD or {}
	table.insert(c.handlers.CHAT_MSG_GUILD, { scripts = { OnEvent = function(_, event, text, sender)
		for _, filter in ipairs(c.filters[event] or {}) do
			if filter(nil, event, text, sender) then return end
		end
		c.printed[#c.printed + 1] = "[Гильдия] " .. text
	end } })
end

-- У этого получателя нет окружения, таймеров и обработчиков аддона: только обычный /g.
local function PlainClient(w, guild)
	local c = { first = "Без", surname = "Аддона", realm = "CAMWOWUS2Realm7PvE", faction = "Alliance",
		guild = guild, rank = 3, level = 60, class = "MAGE", zone = "Штормград", online = true, lines = {} }
	function c:Fire(event, text)
		if event == "CHAT_MSG_GUILD" then self.lines[#self.lines + 1] = text end
	end
	w.clients[#w.clients + 1] = c
	return c
end

local function Build()
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local a = w:Client({ first = "Автор", surname = "Чата", guild = "Чиллзон", rank = 0 })
	local b = w:Client({ first = "Читатель", surname = "Свой", guild = "Чиллзон", rank = 3 })
	local other = w:Client({ first = "Глава", surname = "Севера", guild = "Чиллзон Север", rank = 0 })
	local plain = PlainClient(w, "Чиллзон")
	local foreign = PlainClient(w, "Чиллзон Север")
	NativeChat(a); NativeChat(b); NativeChat(other)
	w:Run(30)
	w:Init(a, other)
	w:Pair(other, a)
	w:Run(200)
	return w, a, b, other, plain, foreign
end

T.test("guildmirror: /cz виден без аддона, с аддоном одна строка независимо от порядка доставки", function()
	local w, a, b, other, plain, foreign = Build()
	local original = w.GuildSay
	for i, delay in ipairs({ 0, 12 }) do
		w.GuildSay = function(self, from, text, kind)
			self:Schedule(self.now + delay, function() original(self, from, text, kind) end, from)
		end
		local text = "общее сообщение " .. i
		a:Slash("/cz", text)
		w:Run(30)
		T.eq(plain.lines[i], PREFIX .. text, "без аддона читаемая копия")
		for _, c in ipairs({ a, b, other }) do
			T.eq(c:Saw(text), 1, "с аддоном видно ровно один раз")
			T.eq(#c.ns.Chat.History("G"), 0, "копия не попала в историю гильдии")
			T.eq(#c.ns.db.errors, 0, "нет ошибок")
		end
	end
	T.eq(#plain.lines, 2, "каждую строку отправил только автор")
	T.eq(#foreign.lines, 0, "в /g другой гильдии копии не отправляются")
end)

T.test("guildmirror: длинный текст и ссылка целы, обычный /g не скрывается", function()
	local w, a, b, _, plain = Build()
	local text = string.rep("Привет всем! ", 10) .. LINK
	local parts = a.ns.Codec.SplitChat(text, a.ns.Config.CHAT_PART, a.ns.Config.CHAT_PARTS)
	T.ok(a.ns.Chat.Send("A", text))
	w:Run(30)
	T.eq(#plain.lines, #parts, "копия каждой части")
	local restored = {}
	for i, line in ipairs(plain.lines) do
		T.ok(#line <= 255, "игровой предел строки")
		T.eq(line, PREFIX .. parts[i], "часть без обрезания")
		restored[#restored + 1] = line:sub(#PREFIX + 1)
		T.eq(b:Saw(parts[i]), 1, "без дублей частей")
	end
	T.eq(table.concat(restored, " "), text, "текст и ссылка целы")
	T.ok(a.ns.GuildChat.Send("G", "обычное сообщение гильдии"))
	w:Run(2)
	T.eq(b:Saw("обычное сообщение гильдии"), 1, "обычный /g виден")
	T.eq(#b.ns.Chat.History("G"), 1, "обычный /g сохранён")
end)

T.test("guildmirror: офицеры, главы и отказ подписи не публикуются в /g", function()
	local w, a, _, _, plain = Build()
	for _, tier in ipairs({ "C", "L" }) do
		T.ok(a.ns.Chat.Send(tier, "строка закрытого канала"))
		w:Run(5)
	end
	a.ns.Security.Seal = function() return false, "busy" end
	T.no(a.ns.Chat.Send("A", "не подписано"))
	w:Run(5)
	T.eq(#plain.lines, 0, "никакой публикации в общий чат гильдии")
end)

T.test("guildmirror: выключенный чат и игнор не обходятся копией в /g", function()
	local w, a, b, _, plain = Build()
	b.ns.char.chatOn = false
	a.ns.Chat.Send("A", "скрыто настройкой")
	w:Run(10)
	T.eq(b:Saw("скрыто настройкой"), 0)
	b.ns.char.chatOn = true
	b.ns.store.ignore[a.ns.myKey] = a:Name()
	a.ns.Chat.Send("A", "скрыто игнором")
	w:Run(10)
	T.eq(b:Saw("скрыто игнором"), 0)
	T.eq(#b.ns.Chat.History("G"), 0)
	T.eq(#plain.lines, 2, "получатель без аддона видит обе копии")
end)
