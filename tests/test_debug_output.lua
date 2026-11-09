-- Отладка использует вкладки общего чата, сохраняя цвета и порядок строк.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Fresh()
	local w = Wow.World()
	w:Guild("Чиллзон")
	return w:Client({ first = "Автор", surname = "Отладки", guild = "Чиллзон", rank = 0 })
end

local function Has(lines, text)
	local count = 0
	for _, line in ipairs(lines or {}) do
		if line:find(text, 1, true) then count = count + 1 end
	end
	return count
end

T.test("debug-output: живой журнал и переключение идут в выбранную вкладку", function()
	local c = Fresh()
	local selected = c:ChatWindow(3, "Чиллзон")
	local other = c:ChatWindow(4, "Другая")
	T.ok(c.ns.Chat.SetWindow("Чиллзон"))
	c.ns.char.chatMirror = false
	c:Slash("/chillzone", "debug")
	c.ns.Log("диагностика %s", "шёпота")
	c:Slash("/chillzone", "debug")
	for _, text in ipairs({ c.ns.L.DEBUG_ON, "диагностика шёпота", c.ns.L.DEBUG_OFF }) do
		T.eq(Has(selected.lines, text), 1, text)
		T.eq(c:Saw(text), 0, "основная вкладка не получает отладку")
	end
	T.eq(#other.lines, 0, "невыбранная вкладка не получает отладку")
	T.ok(c.ns.Chat.SetWindow("Другая"))
	c:Slash("/chillzone", "debug")
	c.ns.Log("после смены вкладки")
	T.eq(Has(other.lines, "после смены вкладки"), 1)
	T.eq(Has(selected.lines, "после смены вкладки"), 0)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("debug-output: сохранённый журнал и ошибки идут в выбранную вкладку", function()
	local c = Fresh()
	local first = c:ChatWindow(3, "Чиллзон")
	local second = c:ChatWindow(4, "Союз")
	T.ok(c.ns.Chat.SetWindow("Чиллзон"))
	c.ns.Log("первая строка")
	c.ns.Log("вторая строка")
	c.ns.db.errors = { "сохранённая ошибка" }
	c:Slash("/chillzone", "log 2")
	T.same(first.lines, {
		"|cff999999" .. c.ns.db.log[#c.ns.db.log - 1] .. "|r",
		"|cff999999" .. c.ns.db.log[#c.ns.db.log] .. "|r",
		"|cffff6060сохранённая ошибка|r",
	})
	T.eq(#second.lines, 0, "невыбранная вкладка не получает журнал")
	T.eq(c:Saw("первая строка"), 0)
	T.eq(c:Saw("сохранённая ошибка"), 0)
end)

T.test("debug-output: закрытая вкладка и ранний вывод используют основную", function()
	local c = Fresh()
	c:ChatWindow(3, "Чиллзон")
	T.ok(c.ns.Chat.SetWindow("Чиллзон"))
	c:ChatWindow(3, "Чиллзон", true)
	c.ns.db.settings.debug = true
	c.ns.Log("после закрытия вкладки")
	T.eq(c:Saw("после закрытия вкладки"), 1)
	local chat = c.ns.Chat
	c.ns.Chat = nil
	c.ns.Log("до загрузки чата")
	c.ns.Chat = chat
	T.eq(c:Saw("до загрузки чата"), 1)
	T.eq(#c.ns.db.errors, 0)
end)
