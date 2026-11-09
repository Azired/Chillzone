-- Источник шёпотов, самостоятельный журнал и копирование отчёта обычным игроком.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local TARGET = "Azog Defiler"

local function Fresh(guild)
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Читатель", surname = "Журнала", guild = guild, rank = 3 })
	w.now = 100
	return w, c
end

local function Log(c) return table.concat(c.ns.db.log, "\n") end

T.test("diagnostics: обычный игрок открывает журнал, запись не засоряет чат", function()
	for _, guild in ipairs({ "Чиллзон", false }) do
		local _, c = Fresh(guild or nil)
		local tab = c:ChatWindow(3, "Чиллзон")
		c.ns.Chat.SetWindow("Чиллзон")
		c:Slash("/chillzone", "debug")
		T.eq(c.ns.UI.Current(), "journal")
		T.ok(c.ns.UI.tabs.journal:IsShown())
		c.ns.Log("запись только в журнале")
		T.eq(c:Saw("запись только в журнале"), 0)
		T.eq(#tab.lines, 0)
		T.ok(Log(c):find("запись только в журнале", 1, true))
		c:Slash("/chillzone", "log 40")
		T.eq(c.ns.UI.Current(), "journal")
		local f = c.ns.JournalPane.frames
		f.copy.scripts.OnClick(f.copy)
		T.ok(f.box:GetText():find("запись только в журнале", 1, true))
		T.ok(f.box:GetText():find(c.ns.VERSION, 1, true))
		local snapshot = f.box:GetText()
		c.ns.Log("новое событие при копировании")
		f.pane.scripts.OnUpdate(f.pane, 1)
		T.eq(f.box:GetText(), snapshot, "новые события не сбивают выделение отчёта")
		f.back.scripts.OnClick(f.back)
		T.ok(table.concat(f.messages.lines, "\n"):find("новое событие при копировании", 1, true))
		T.eq(#c.ns.db.errors, 0)
	end
end)

T.test("diagnostics: прокрутка и Escape не теряют новые события", function()
	local _, c = Fresh("Чиллзон")
	c.ns.UI.Toggle("journal")
	local f = c.ns.JournalPane.frames
	f.messages.AtBottom = function() return false end
	local before = table.concat(f.messages.lines, "\n")
	c.ns.Log("при чтении старых строк")
	f.pane.scripts.OnUpdate(f.pane, 1)
	T.eq(table.concat(f.messages.lines, "\n"), before)
	f.copy:Click()
	T.ok(f.box:HasFocus())
	f.box.scripts.OnEscapePressed(f.box)
	T.no(f.box:HasFocus())
	T.no(f.export:IsShown())
	T.ok(table.concat(f.messages.lines, "\n"):find("при чтении старых строк", 1, true))
	T.eq(#c.ns.db.errors, 0)
end)

T.test("diagnostics: чужой шёпот и системная ошибка видны без отправок Chillzone", function()
	local w, c = Fresh("Чиллзон")
	c.env.debugstack = function() return 'Interface\\AddOns\\OtherAddon\\Sender.lua:42: in function <Sender.lua:40>' end
	c.ns.Diagnostics.SetEnabled(true)
	c.env.C_ChatInfo.SendAddonMessage("OTHER", "private-payload", "WHISPER", TARGET)
	w.now = w.now + 20
	c:Fire("CHAT_MSG_SYSTEM", ('Персонаж по имени "%s" в игре не найден.'):format(TARGET))
	local log = Log(c)
	for _, text in ipairs({ TARGET, "OTHER", "OtherAddon", "Sender.lua:42", "CHAT_MSG_SYSTEM" }) do
		T.ok(log:find(text, 1, true), text)
	end
	T.no(log:find("private-payload", 1, true))
	T.eq(c.ns.Comm.lastWhisper[c.ns.Util.Key(TARGET)], nil, "чужие отправки не выдаются за наши")
	T.eq(#c.ns.db.errors, 0)
end)

T.test("diagnostics: обычный шёпот и logged API сохраняют только метаданные", function()
	local _, c = Fresh("Чиллзон")
	c.ns.Diagnostics.SetEnabled(true)
	c.env.SendChatMessage("private-conversation", "WHISPER", nil, TARGET)
	c.env.C_ChatInfo.SendAddonMessageLogged("OTHERLOG", "private-wire", "WHISPER", TARGET)
	local log = Log(c)
	T.ok(log:find("SendChatMessage", 1, true))
	T.ok(log:find("SendAddonMessageLogged", 1, true))
	T.no(log:find("private-conversation", 1, true))
	T.no(log:find("private-wire", 1, true))
	T.eq(#c.ns.db.errors, 0)
end)

T.test("diagnostics: чужая отправка тому же игроку не скрывает его ошибку", function()
	local _, c = Fresh("Чиллзон")
	c.ns.Diagnostics.SetEnabled(true)
	c.ns.Comm.SendNow("WHISPER", "KQ~test", TARGET)
	c.env.C_ChatInfo.SendAddonMessage("OTHER", "data", "WHISPER", TARGET)
	local text = ('Персонаж по имени "%s" в игре не найден.'):format(TARGET)
	for _, filter in ipairs(c.filters.CHAT_MSG_SYSTEM or {}) do
		T.no(filter(nil, "CHAT_MSG_SYSTEM", text), "ошибка последней чужой отправки остаётся видимой")
	end
end)

T.test("diagnostics: синхронная ошибка нашей отправки сохраняет адресата и результат", function()
	local _, c = Fresh("Чиллзон")
	c.ns.Diagnostics.SetEnabled(true)
	c.env.C_ChatInfo.SendAddonMessage = function()
		c:Fire("CHAT_MSG_SYSTEM", ('Персонаж по имени "%s" в игре не найден.'):format(TARGET))
		return 12
	end
	c.ns.Comm.SendNow("WHISPER", "KQ~private-key-data", TARGET)
	local log = Log(c)
	T.ok(log:find("Chillzone/Comm", 1, true))
	T.ok(log:find("CHAT_MSG_SYSTEM", 1, true))
	T.ok(log:find("результат 12", 1, true))
	T.no(log:find("private-key-data", 1, true))
	T.eq(#c.ns.db.errors, 0)
end)

T.test("diagnostics: очередь сохраняет исходный тип и место постановки сообщения", function()
	local _, c = Fresh("Чиллзон")
	c.ns.Diagnostics.SetEnabled(true)
	c.env.debugstack = function()
		return "Interface\\AddOns\\Chillzone\\Comm.lua:220: Send\nInterface\\AddOns\\Chillzone\\Relay.lua:247: Ask"
	end
	c.ns.Comm.Send("WHISPER", "KP~" .. string.rep("private", 60), { target = TARGET })
	c.env.debugstack = function() return "Interface\\AddOns\\Chillzone\\Core.lua:100: таймер" end
	c.ns.Comm.Pump()
	local log = Log(c)
	T.ok(log:find("Relay.lua:247", 1, true), "место постановки не заменено таймером отправки")
	T.ok(log:find("тип KP", 1, true), "виден тип целого сообщения, а не только C-куска")
	T.no(log:find("private", 1, true))
end)

T.test("diagnostics: выключенная запись и защищённые значения не читаются", function()
	local _, c = Fresh("Чиллзон")
	local calls = 0
	c.env.debugstack = function() calls = calls + 1; error("стек недоступен") end
	local before = Log(c)
	c.env.C_ChatInfo.SendAddonMessage("OTHER", "data", "WHISPER", TARGET)
	T.eq(Log(c), before)
	T.eq(calls, 0)
	c.ns.Diagnostics.SetEnabled(true)
	local secret = setmetatable({}, { __tostring = function() error("чтение секрета") end })
	c.env.issecretvalue = function(v) return rawequal(v, secret) end
	c:CallHooks("SendChatMessage", secret, "WHISPER", nil, secret)
	c:Fire("CHAT_MSG_SYSTEM", secret)
	c.env.C_ChatInfo.SendAddonMessage("OTHER", "data", "WHISPER", TARGET)
	T.ok(Log(c):find("защищён", 1, true))
	T.eq(#c.ns.db.errors, 0, "ошибка чтения стека не выходит из диагностического хука")
end)

T.test("diagnostics: свежие ошибки датированы, старые явно помечены, очистка работает", function()
	local _, c = Fresh("Чиллзон")
	c.ns.db.errors = { "event CHAT_MSG_GUILD: GuildChat.lua:49: старая ошибка" }
	c.ns.SafeCall("свежий сбой", function() error("новая ошибка") end)
	local report = c.ns.Diagnostics.Report()
	T.ok(report:find("время и версия неизвестны", 1, true))
	T.ok(report:find("v" .. c.ns.VERSION, 1, true))
	T.ok(Log(c):find("новая ошибка", 1, true), "новый сбой попал в хронологию")
	c.ns.UI.Toggle("journal")
	local f = c.ns.JournalPane.frames
	f.clear.scripts.OnClick(f.clear)
	T.eq(#c.ns.db.errors, 0)
	T.no(c.ns.Diagnostics.Report():find("старая ошибка", 1, true))
	T.no(c.ns.Diagnostics.Report():find("новая ошибка", 1, true))
end)

T.test("diagnostics: длинный отчёт копируется целиком, журнал ограничен", function()
	local _, c = Fresh("Чиллзон")
	for i = 1, 1020 do c.ns.Log("строка %s: %s", i, string.rep("Диагностика ", 8)) end
	T.eq(#c.ns.db.log, 1000)
	c.ns.UI.Toggle("journal")
	local report = c.ns.Diagnostics.Report()
	local f = c.ns.JournalPane.frames
	f.copy:Click()
	T.eq(f.box:GetText(), report)
	T.ok(report:find("строка 1020:", 1, true))
	T.no(report:find("строка 1:", 1, true))
	T.eq(#c.ns.db.errors, 0)
end)
