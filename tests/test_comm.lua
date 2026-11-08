-- Системные ошибки служебных шёпотов: локализация, очередь и повторная связь.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local TARGET = "Ника Маковка"

local function Fresh()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local c = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север" })
	w.now = 100
	local sent = {}
	c.env.C_ChatInfo.SendAddonMessage = function(_, msg, dist, target)
		sent[#sent + 1] = { msg = msg, dist = dist, target = target }
		return 0
	end
	return w, c, c.ns.Comm, sent
end

local function Hidden(c, text)
	for _, filter in ipairs(c.filters.CHAT_MSG_SYSTEM or {}) do
		if filter(nil, "CHAT_MSG_SYSTEM", text) then return true end
	end
	return false
end

for _, template in ipairs({
	"No player named '%s' is currently playing.",
	'Персонаж по имени "%s" в игре не найден.',
}) do
	local format = template
	T.test("comm: недоступный адресат — " .. format, function()
		local _, c, comm = Fresh()
		local text = format:format(TARGET)
		T.no(Hidden(c, text), "без служебного шёпота ошибка видна")
		T.ok(comm.SendNow("WHISPER", "KQ~test", TARGET))
		T.ok(Hidden(c, text), "ошибка скрыта ещё до обработчика события")
		c:Fire("CHAT_MSG_SYSTEM", text)
		T.ok(Hidden(c, text), "ошибка скрыта и после обработчика события")
		T.no(comm.Send("WHISPER", "KQ~again", { target = TARGET }), "новые задания не копятся")
		T.no(comm.SendNow("WHISPER", "KQ~again", TARGET), "прямая отправка тоже остановлена")
	end)
end

T.test("comm: недоступный адресат — отмена очереди и продолжение остальных", function()
	local _, c, comm, sent = Fresh()
	local results = {}
	local function Done(ok, why) results[#results + 1] = { ok, why } end
	comm.Send("WHISPER", string.rep("x", 1000), { target = TARGET, done = Done })
	comm.Send("WHISPER", "KQ~test", { target = TARGET, done = Done })
	comm.Send("WHISPER", "KQ~other", { target = "Другой Игрок" })
	comm.Send("GUILD", "H1~test")
	comm.Pump()
	T.eq(#sent, 1, "отправлен первый кусок")
	c:Fire("CHAT_MSG_SYSTEM", ('Персонаж по имени "%s" в игре не найден.'):format(TARGET))
	T.eq(comm.QueueSize(), 2, "убраны и начатое сообщение, и следующее тому же игроку")
	T.same(results, { { false, "offline" }, { false, "offline" } }, "отмена вызывает done ровно один раз")
	comm.Pump(); comm.Pump()
	T.eq(#sent, 3, "остальная очередь работает")
	T.eq(sent[2].target, "Другой Игрок")
	T.eq(sent[3].dist, "GUILD")
end)

T.test("comm: недоступный адресат — срок ошибки и повторной попытки", function()
	local w, c, comm = Fresh()
	local text = c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET)
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", text)
	w.now = w.now + 11
	T.no(Hidden(c, text), "давняя ошибка не скрывает обычный шёпот игрока")
	T.no(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "пауза ещё действует")
	w.now = w.now + c.ns.Config.RELAY_DOWN
	T.ok(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "после паузы можно проверить доступность")
end)

T.test("comm: недоступный адресат — ответ снимает паузу", function()
	local _, c, comm = Fresh()
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET))
	c:Fire("CHAT_MSG_ADDON", "OTHER", "ZZ~test", "WHISPER", TARGET)
	T.no(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "чужой префикс не снимает паузу")
	c:Fire("CHAT_MSG_ADDON", c.ns.PREFIX, "ZZ~test", "WHISPER", TARGET)
	T.ok(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "свой ответ подтверждает доступность")
end)

T.test("comm: недоступный адресат — чужие и просроченные ошибки видны", function()
	local w, c, comm = Fresh()
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	local text = c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format("Другой Игрок")
	T.no(Hidden(c, text))
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.ok(comm.Send("WHISPER", "KQ~test", { target = "Другой Игрок" }))
	w.now = w.now + 11
	text = c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET)
	T.no(Hidden(c, text))
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.ok(comm.Send("WHISPER", "KQ~test", { target = TARGET }))
end)
