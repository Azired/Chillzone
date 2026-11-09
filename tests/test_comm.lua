-- Системные ошибки служебных шёпотов: локализация, очередь и повторная связь.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local TARGET = "Ника Маковка"

local function Fresh(chatFilterAPI)
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local c = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", chatFilterAPI = chatFilterAPI })
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

-- Сборщик основной ветки 0.11.1 (8f9013) ничего не знает об импорте G1.
local function LegacyReceiver(c, sent)
	local ns = { Util = c.ns.Util, Config = c.ns.Config }
	local chunk = assert(loadfile(T.ROOT .. "/tests/legacy/0.11.1/Codec.lua"))
	setfenv(chunk, c.env)("Chillzone", ns)
	local codec, cursor, complete = ns.Codec, 0, {}
	local asm = codec.NewAssembler()
	local function Deliver(now)
		while cursor < #sent do
			cursor = cursor + 1
			local msg = sent[cursor].msg
			if msg:sub(1, 1) == "C" then msg = codec.Feed(asm, "отправитель", msg, now) end
			if msg then complete[#complete + 1] = msg end
		end
	end
	return codec, asm, complete, Deliver
end

local function ImportPayload()
	return "S1~" .. ("f"):rep(16) .. "~1793000100~1~" .. ("s"):rep(86)
		.. "~G1~Чиллзон Север~event~1793000100~Автор Строки~MA~" .. ("x"):rep(510)
end

T.test("comm: начатый G1 завершается после TTL и остаётся ниже обычного чата", function()
	local w, c, comm, sent = Fresh()
	local _, asm, complete, deliver = LegacyReceiver(c, sent)
	local payload, checked, finished = ImportPayload(), 0, 0
	T.eq(#c.ns.Codec.Chunk(payload, "1"), 4)
	comm.Send("WHISPER", payload, { target = TARGET, prio = comm.PRIO_IMPORT,
		guard = function() checked = checked + 1; return w.now < 130 end,
		done = function(ok) T.ok(ok); finished = finished + 1 end })
	comm.Pump(); deliver(w.now)
	T.eq(asm.open, 1, "старый клиент хранит первую часть")
	w.now = 131
	local ordinary = "M1~A~Чиллзон Север~1~MA~обычный чат"
	comm.Send("WHISPER", ordinary, { target = TARGET, prio = true })
	comm.Pump(); deliver(w.now)
	T.eq(complete[1], ordinary, "обычный чат обгоняет начатый низкоприоритетный импорт")
	for _ = 1, 3 do comm.Pump(); deliver(w.now) end
	T.eq(complete[2], payload, "истёкший G1 полностью собран старым Codec")
	T.eq(asm.open, 0, "обрывка в старом сборщике не осталось")
	T.eq(checked, 1, "guard импорта проверен только до первой части")
	T.eq(finished, 1)
	T.eq(comm.QueueSize(), 0)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("comm: полная обычная очередь сохраняет один начатый G1", function()
	local w, c, comm, sent = Fresh()
	local _, asm, complete, deliver = LegacyReceiver(c, sent)
	local payload, finished = ImportPayload(), 0
	comm.Send("WHISPER", payload, { target = TARGET, prio = comm.PRIO_IMPORT,
		done = function(ok) T.ok(ok, "переполнение не отменяет начатый импорт"); finished = finished + 1 end })
	comm.Pump(); deliver(w.now)
	for i = 1, comm.MAX_QUEUE do
		T.ok(comm.Send("GUILD", "M1~A~Чиллзон~" .. i .. "~MA~строка", { prio = true }))
	end
	T.eq(comm.QueueSize(), comm.MAX_QUEUE + 1, "200 обычных и один завершаемый импорт")
	T.eq(comm.ImportQueued(), 1)
	T.no(comm.Send("GUILD", "M1~A~Чиллзон~999~MA~сверх предела", { prio = true }), "обычный предел остаётся ограниченным")
	T.eq(comm.QueueSize(), comm.MAX_QUEUE + 1)
	for _ = 1, comm.MAX_QUEUE do comm.Pump(); deliver(w.now) end
	T.eq(finished, 0, "импорт не обгоняет обычные задания")
	T.eq(#complete, comm.MAX_QUEUE)
	for _ = 1, 3 do comm.Pump(); deliver(w.now) end
	T.eq(complete[#complete], payload)
	T.eq(finished, 1)
	T.eq(asm.open, 0)
	T.eq(comm.QueueSize(), 0)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("comm: не начатый просроченный G1 не отправляет ни одного фрагмента", function()
	local _, _, comm, sent = Fresh()
	local finished = 0
	comm.Send("WHISPER", ImportPayload(), { target = TARGET, prio = comm.PRIO_IMPORT,
		guard = function() return false end,
		done = function(ok, why)
			T.no(ok); T.eq(why, "authority changed"); finished = finished + 1
		end })
	comm.Pump()
	T.eq(#sent, 0)
	T.eq(finished, 1)
	T.eq(comm.QueueSize(), 0)
end)

T.test("comm: повторные длинные паузы G1 не блокируют R1 в старом сборщике", function()
	local w, c, comm, sent = Fresh()
	local codec, asm, complete, deliver = LegacyReceiver(c, sent)
	local nextGc = 120
	local function Advance(seconds)
		local stop = w.now + seconds
		while nextGc <= stop do
			w.now = nextGc
			codec.Gc(asm, w.now)
			nextGc = nextGc + 30
		end
		w.now = stop
	end
	for cycle = 1, 12 do
		comm.Send("WHISPER", ImportPayload(), { target = TARGET, prio = comm.PRIO_IMPORT })
		comm.Pump(); deliver(w.now)
		Advance(61)
		local report = "R1~Чиллзон Север~" .. cycle .. "~" .. ("r"):rep(450)
		comm.Send("WHISPER", report, { target = TARGET, prio = true })
		local before = #complete
		for _ = 1, #c.ns.Codec.Chunk(report, "1") do comm.Pump(); deliver(w.now) end
		T.eq(complete[before + 1], report, "обычный R1 собран после длинной паузы")
		for _ = 1, 3 do comm.Pump(); deliver(w.now) end
		T.ok(asm.open <= 2, "GC ограничивает число старых хвостов")
		T.eq(asm.refused, 0, "ни один фрагмент не отвергнут из-за импорта")
		T.eq(comm.QueueSize(), 0)
	end
end)

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

T.test("comm: Forever — фильтр через ChatFrameUtil без старой глобальной функции", function()
	local _, c, comm = Fresh("modern")
	T.eq(c.env.ChatFrame_AddMessageEventFilter, nil, "в клиенте нет старой функции")
	T.eq(type(c.env.ChatFrameUtil.AddMessageEventFilter), "function")
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	local text = ('Персонаж по имени "%s" в игре не найден.'):format(TARGET)
	T.ok(Hidden(c, text), "фильтр зарегистрирован через актуальный API")
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.ok(Hidden(c, text), "строка скрыта и после отмены очереди")
end)

for _, logged in ipairs({ false, true }) do
	local useLogged = logged
	T.test("comm: Forever — TargetOffline прекращает отправки, logged=" .. tostring(useLogged), function()
		local _, c, comm = Fresh("modern")
		local calls, cancelled, failures = 0, 0, 0
		local function Offline()
			calls = calls + 1
			return 12 -- Enum.SendAddonMessageResult.TargetOffline
		end
		c.env.C_ChatInfo.SendAddonMessage = Offline
		c.env.C_ChatInfo.SendAddonMessageLogged = Offline
		local function Done(ok, why)
			T.no(ok)
			T.eq(why, "offline")
			cancelled = cancelled + 1
		end
		c.ns.On("WHISPER_UNAVAILABLE", function() failures = failures + 1 end)
		comm.Send("WHISPER", string.rep("x", 1000), { target = TARGET, logged = useLogged, done = Done })
		comm.Send("WHISPER", "KQ~test", { target = TARGET, logged = useLogged, done = Done })
		-- Текстовая строка вообще не приходит: достаточно результата API.
		comm.Pump(); comm.Pump()
		T.eq(calls, 1, "остальная очередь недоступному персонажу не отправляется")
		T.eq(comm.QueueSize(), 0)
		T.eq(cancelled, 2, "каждый callback вызван ровно один раз")
		T.eq(failures, 1, "маршрутизация узнаёт о недоступности сразу")
		T.eq(comm.stats.dropped, 2)
		T.no(comm.Send("WHISPER", "KQ~again", { target = TARGET }))
		T.eq(#c.ns.db.errors, 0, "без скрытых ошибок callback")
	end)
end

T.test("comm: Forever — синхронная ошибка не вызывает callback повторно", function()
	local _, c, comm = Fresh("modern")
	local cancelled = 0
	c.env.C_ChatInfo.SendAddonMessage = function()
		c:Fire("CHAT_MSG_SYSTEM", c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET))
		return 0
	end
	comm.Send("WHISPER", "KQ~test", { target = TARGET, done = function(ok, why)
		T.no(ok)
		T.eq(why, "offline")
		cancelled = cancelled + 1
	end })
	comm.Pump()
	T.eq(cancelled, 1)
	T.eq(comm.QueueSize(), 0)
	T.eq(comm.stats.dropped, 1)
	T.eq(#c.ns.db.errors, 0, "насос не завершает отменённое задание повторно")
end)

T.test("comm: диагностика — принятый API шёпот виден с адресатом и кодом", function()
	local _, c, comm = Fresh()
	c.ns.db.settings.debug = true
	T.ok(comm.SendNow("WHISPER", "KQ~private-payload", TARGET))
	local log = table.concat(c.ns.db.log, "\n")
	T.ok(log:find(TARGET, 1, true), "виден фактический адресат")
	T.ok(log:find("KQ", 1, true), "виден тип пакета")
	T.ok(log:find("результат 0", 1, true), "успех API не выдаётся за подтверждённую доставку")
	T.no(log:find("private-payload", 1, true), "содержимое пакета не записывается")
end)

T.test("comm: диагностика — нераспознанная системная строка после шёпота", function()
	local w, c, comm = Fresh()
	c.ns.db.settings.debug = true
	local text = 'Неизвестный ответ |cffffff00"Ника Маковка"|r'
	local before = #c.ns.db.log
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.eq(#c.ns.db.log, before, "до служебного шёпота системные строки не собираются")
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", text)
	local log = table.concat(c.ns.db.log, "\n")
	T.ok(log:find("ответ системы после шёпота", 1, true))
	T.ok(log:find("||cffffff00", 1, true), "разметка видна в журнале, а не применяется")
	local n = #c.ns.db.log
	w.now = w.now + 11
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.eq(#c.ns.db.log, n, "давние шёпоты не включают запись посторонних строк")
end)

T.test("comm: диагностика — закрытая строка не читается и не скрывается", function()
	local _, c, comm = Fresh()
	c.ns.db.settings.debug = true
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	local secret = setmetatable({}, { __tostring = function() error("чтение закрытого текста") end })
	c.env.issecretvalue = function(value) return rawequal(value, secret) end
	c:Fire("CHAT_MSG_SYSTEM", secret)
	T.ok(table.concat(c.ns.db.log, "\n"):find("защищённая строка", 1, true))
	T.no(Hidden(c, secret), "нельзя скрывать неизвестную закрытую строку")
	T.eq(#c.ns.db.errors, 0, "защищённый текст не индексируется и не форматируется")
end)

T.test("comm: диагностика — без debug подробные записи отключены", function()
	local _, c, comm = Fresh()
	local before = #c.ns.db.log
	comm.SendNow("WHISPER", "KQ~private-payload", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", "Неизвестный ответ системы")
	T.eq(#c.ns.db.log, before)
end)
