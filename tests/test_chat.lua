-- Окно чата: каналы по рангу, отправка из поля ввода, чат гильдии, метка-ссылка, люди справа,
-- непрочитанные, Enter при открытом окне — в симуляторе мира.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт, Благословенный клинок Искателя Ветра]|h|r"

local function Build(opts)
	opts = opts or {}
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 11)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	w:AddOffline("Чиллзон Север", "Тихий Друид-CAMWOWUS2Realm7PvE", 3, 41, "DRUID", 2)
	w:AddOffline("Орден Чиллзона", "Офицер Ордена-CAMWOWUS2Realm3PvE", 1, 60, "PRIEST", 1)
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR" })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID" })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER" })
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.A)
	w:Pair(c.G, c.A)
	w:Run(opts.run or 400)
	c.B.ns.Relay.PingAll(); w:Run(45)
	return w, c
end

local function Has(lines, text)
	local n = 0
	for _, l in ipairs(lines) do
		if l:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function HistoryHas(cl, channel, text)
	local n = 0
	for _, e in ipairs(cl.ns.Chat.History(channel)) do
		if e.x:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function Errors(c)
	for name, cl in pairs(c) do
		local errors = cl.ns.db.errors
		T.eq(#errors, 0, name .. ": ошибки " .. table.concat(errors, " | "))
	end
end

local function SlashClient(rank)
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Автор", surname = "Чата", guild = "Чиллзон", rank = rank or 0 })
	return w, c
end

T.test("slash: управление только через /chillzone, алиасы всегда пишут в чат", function()
	local _, c = SlashClient()
	local sent = {}
	c.ns.Chat.Send = function(tier, text) sent[#sent + 1] = { tier, text } end
	c:Slash("/chillzone", "settings")
	T.eq(c.ns.UI.Current(), "settings")
	c:Slash("/chillzone", "status")
	T.ok(c:Saw("перепись: репортёр") > 0)
	c:Slash("/chillzone", "нетакой")
	T.eq(#sent, 0, "неизвестная команда управления не уходит в чат")
	for _, cmd in ipairs({ "/cz", "/чз", "/чиллзон" }) do
		c:Slash(cmd, "settings")
		T.same(sent[#sent], { "A", "settings" }, cmd .. " не перехватывает слово команды")
		c:Slash(cmd, "")
		T.eq(c.ns.UI.Current(), "settings", "пустая команда не меняет вкладку")
	end
	T.eq(#sent, 3)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("slash: все алиасы оставляют ввод в игровом чате до Enter", function()
	local w, c = SlashClient()
	local aliases = { ["/cz"] = "A", ["/чз"] = "A", ["/чиллзон"] = "A",
		["/cz1"] = "A", ["/чз1"] = "A", ["/cz2"] = "C", ["/чз2"] = "C", ["/cz3"] = "L", ["/чз3"] = "L" }
	local sent = {}
	c.ns.Chat.Send = function(tier, text) sent[#sent + 1] = { tier, text } end
	for cmd, tier in pairs(aliases) do
		for i = 1, 2 do
			local game = c.env["ChatFrame" .. i .. "EditBox"]
			game:Show(); game:SetFocus()
			for _, text in ipairs({ cmd, cmd .. " ", cmd .. " привет " .. LINK }) do
				game:SetText(text)
				local changed = game.scripts.OnTextChanged
				if changed then changed(game, true) end
				w:Run(0)
				T.ok(game:HasFocus(), cmd .. " сохраняет фокус в игровом поле")
				T.eq(game:GetText(), text, "текст и ссылка остаются в игровом поле")
				T.eq(c.ns.UI.Current(), nil, "набор команды не открывает окно")
			end
			local before = #sent
			c:Slash(cmd, "привет " .. LINK)
			game:ClearFocus(); game:Hide()
			w:Run(0)
			T.eq(#sent, before + 1, "Enter отправляет ровно один раз")
			T.same(sent[#sent], { tier, "привет " .. LINK }, cmd)
			T.eq(c.ns.UI.Current(), nil, "отправка не открывает окно")
		end
	end
	T.eq(#c.ns.db.errors, 0)
end)

T.test("slash: отмена и исправление команды не открывают окно", function()
	local w, c = SlashClient()
	local game = c.env.ChatFrame1EditBox
	game:Show(); game:SetFocus(); game:SetText("/cz ")
	local changed = game.scripts.OnTextChanged
	if changed then changed(game, true) end
	game:SetText("/cast Заклинание")
	w:Run(0)
	T.ok(game:HasFocus())
	T.eq(c.ns.UI.Current(), nil)
	game:SetText("/cz ")
	if changed then changed(game, true) end
	game:ClearFocus(); game:Hide()
	w:Run(0)
	T.eq(c.ns.UI.Current(), nil)
end)

T.test("slash: пустые команды дают подсказку без отправки и открытия окна", function()
	local w, c = SlashClient()
	local sent = 0
	c.ns.Chat.Send = function() sent = sent + 1 end
	for _, cmd in ipairs({ "/cz", "/чз", "/чиллзон", "/cz1", "/чз1", "/cz2", "/чз2", "/cz3", "/чз3" }) do
		for _, text in ipairs({ "", "   " }) do
			local before = c:Saw(c.ns.L.CHAT_USAGE)
			c:Slash(cmd, text)
			w:Run(0)
			T.eq(c:Saw(c.ns.L.CHAT_USAGE), before + 1, cmd .. " показывает подсказку")
			T.eq(c.ns.UI.Current(), nil, cmd .. " не открывает окно")
		end
	end
	T.eq(sent, 0)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("slash: недоступный канал отклоняет отправку без открытия окна", function()
	local w, c = SlashClient(3)
	local game = c.env.ChatFrame1EditBox
	game:Show(); game:SetFocus(); game:SetText("/чз2 ")
	local changed = game.scripts.OnTextChanged
	if changed then changed(game, true) end
	w:Run(0)
	T.ok(game:HasFocus())
	T.eq(c.ns.UI.Current(), nil)
	T.eq(c:Saw("можно писать только с нужным рангом"), 0, "при наборе ещё нет отказа")
	c:Slash("/чз2", "сообщение офицерам")
	c:Slash("/cz3", "сообщение главам")
	w:Run(0)
	T.eq(c:Saw("можно писать только с нужным рангом"), 2)
	T.eq(c.ns.Chat.stats.sent, 0)
	T.eq(c.ns.UI.Current(), nil)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("окно: каналы по рангу", function()
	local _, c = Build({ run = 60 })
	local function chans(cl) return table.concat(cl.ns.Chat.Channels(), ",") end
	T.eq(chans(c.M), "G,A", "рядовой главной")
	T.eq(chans(c.B), "G,A", "ветеран Севера — не офицер")
	T.eq(chans(c.A), "G,O,A,C,L", "офицер главной — и главы")
	T.eq(chans(c.V), "G,O,A,C,L", "глава Севера")
	local stranger = c.A.world:Client({ first = "Никто", surname = "Ничей", guild = nil })
	T.eq(chans(stranger), "", "без гильдии каналов нет")
end)

T.test("окно: чат гильдии и офицеров, шёпот, команды", function()
	local w, c = Build()
	T.ok(c.B.ns.Chat.Submit("G", "привет Северу " .. LINK), "строка в гильдию ушла")
	w:Run(2)
	T.eq(HistoryHas(c.V, "G", "привет Северу"), 1, "Вера получила")
	T.eq(HistoryHas(c.B, "G", "привет Северу"), 1, "Борис видит своё эхо")
	T.eq(HistoryHas(c.A, "G", "привет Северу"), 0, "другая гильдия не видит")
	local e = c.V.ns.Chat.History("G")[1]
	T.eq(e.s, "Борис Быстрый", "имя автора")
	T.eq(e.c, "WARRIOR", "класс по GUID")
	T.ok(e.x:find(LINK, 1, true), "ссылка цела")
	T.no(c.B.ns.Chat.Submit("O", "можно?"), "не офицер не пишет в офицерский")
	T.ok(c.V.ns.Chat.Submit("O", "офицерам Севера"), "глава пишет офицерам")
	w:Run(2)
	T.eq(HistoryHas(c.V, "O", "офицерам Севера"), 1, "глава видит")
	T.eq(HistoryHas(c.B, "O", "офицерам Севера"), 0, "ветеран не видит")
	T.ok(c.B.ns.Chat.Submit("A", "/w Глеб Гордый секрет"), "шёпот ушёл")
	local whisper
	for _, l in ipairs(w.log) do
		if l.dist == "CHAT_WHISPER" then whisper = l end
	end
	T.ok(whisper and whisper.target == "Глеб Гордый" and whisper.msg == "секрет", "шёпот по «Имя Фамилия»")
	T.no(c.B.ns.Chat.Submit("A", "/dance"), "команды не выполняются")
	T.ok(c.B:Saw("команды пишите в обычном чате") >= 1, "подсказка про команды")
	T.no(c.B.ns.Chat.Submit("A", "/w Глеб"), "шёпот без текста")
	Errors(c)
end)

T.test("окно: поле ввода отправляет и держит курсор", function()
	local w, c = Build()
	local B = c.B
	B.ns.UI.OpenChat("A", true)
	local box = B.ns.ChatPane.frames.box
	T.ok(box:HasFocus(), "курсор в поле")
	box:SetText("из окна " .. LINK)
	box.scripts.OnEnterPressed(box)
	T.eq(box:GetText(), "", "поле очищено")
	T.ok(box:HasFocus(), "курсор остался")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("из окна"), 1, name .. " видит строку один раз") end
	T.eq(Has(B.ns.ChatPane.frames.messages.lines, "из окна"), 1, "строка в окне автора")
	box:SetText("")
	box.scripts.OnEnterPressed(box)
	T.no(box:HasFocus(), "пустой Enter убирает курсор")
	-- ↑ возвращает последнюю отправленную строку.
	box.scripts.OnArrowPressed(box, "UP")
	T.ok(box:GetText():find("из окна", 1, true), "история отправленного")
	-- Недоступный канал («Главы» для ветерана) заменяется первым доступным.
	B.ns.ChatPane.Select("L")
	T.eq(B.ns.ChatPane.Current(), "G", "вместо «Глав» — чат гильдии")
	Errors(c)
end)

T.test("окно: строка приходит в окно, непрочитанные", function()
	local w, c = Build()
	local B = c.B
	B.ns.UI.OpenChat("G")
	T.eq(B.ns.ChatPane.Current(), "G", "открыт чат гильдии")
	c.G:Slash("/cz1", "в окно Бориса")
	w:Run(30)
	T.eq(B.ns.ChatPane.unread.A, 1, "непрочитанная в «Чиллзон»")
	T.eq(Has(B.ns.ChatPane.frames.messages.lines, "в окно Бориса"), 0, "в чате гильдии её нет")
	B.ns.ChatPane.Select("A")
	T.eq(B.ns.ChatPane.unread.A, 0, "прочитано")
	T.eq(Has(B.ns.ChatPane.frames.messages.lines, "в окно Бориса"), 1, "строка из истории")
	T.eq(Has(B.ns.ChatPane.frames.messages.lines, "<Орден Чиллзона>"), 1, "гильдия автора у строки")
	c.V:Slash("/cz1", "сразу видно")
	w:Run(30)
	T.eq(Has(B.ns.ChatPane.frames.messages.lines, "сразу видно"), 1, "новая строка открытого канала")
	T.eq(B.ns.ChatPane.unread.A, 0, "открытый канал не копит непрочитанные")
	Errors(c)
end)

T.test("окно: метка в чате игры открывает окно", function()
	local w, c = Build()
	local B = c.B
	c.G:Slash("/cz1", "метка")
	w:Run(30)
	local line
	for _, l in ipairs(B.printed) do
		if l:find("метка", 1, true) then line = l end
	end
	T.ok(line and line:find("|Haddon:Chillzone:chan:A|h[Чиллзон]|h", 1, true), "метка — ссылка")
	B:CallHooks("SetItemRef", "addon:Chillzone:chan:A", "[Чиллзон]", "RightButton")
	T.eq(B.ns.UI.Current(), nil, "правый клик ничего не делает")
	B:CallHooks("SetItemRef", "item:19019", "[x]", "LeftButton")
	T.eq(B.ns.UI.Current(), nil, "чужие ссылки не трогаем")
	B:CallHooks("SetItemRef", "addon:Chillzone:chan:A", "[Чиллзон]", "LeftButton")
	T.eq(B.ns.UI.Current(), "chat", "окно на чате")
	T.eq(B.ns.ChatPane.Current(), "A", "канал «Чиллзон»")
	T.ok(B.ns.ChatPane.frames.box:HasFocus(), "курсор в поле")
	Errors(c)
end)

T.test("окно: без дубля в чат игры строка только в окне", function()
	local w, c = Build()
	c.B.ns.char.chatMirror = false
	c.G:Slash("/cz1", "только окно")
	w:Run(30)
	T.eq(c.B:Saw("только окно"), 0, "в чат игры не пришло")
	T.eq(HistoryHas(c.B, "A", "только окно"), 1, "в истории есть")
	T.eq(c.V:Saw("только окно"), 1, "у других дубль включён")
end)

T.test("окно: копии строк — во вкладке чата игры, выбор в настройках", function()
	local w, c = Build()
	local B = c.B
	local tab = B:ChatWindow(3, "Чиллзон")
	B:ChatWindow(4, "Торговля", true)
	local names = {}
	for _, win in ipairs(B.ns.Chat.Windows()) do names[#names + 1] = win.name end
	T.eq(table.concat(names, ","), "Общий,Чиллзон", "без журнала боя и закрытых вкладок")

	B.ns.UI.Toggle("settings")
	local p = B.ns.UI.picker
	T.eq(p.button:GetText(), "Основное окно")
	p.button.scripts.OnClick(p.button)
	T.ok(p.list:IsShown(), "список открыт")
	T.eq(p.items[1].text:GetText(), "Основное окно")
	T.ok(p.items[1].check:IsShown(), "отмечено основное окно")
	T.eq(p.items[2].text:GetText(), "Чиллзон", "основное окно второй раз не показано")
	T.no(p.items[2].check:IsShown())
	T.no(p.items[3] and p.items[3]:IsShown(), "лишних строк нет")
	p.items[2].scripts.OnClick(p.items[2])
	T.no(p.list:IsShown(), "выбор закрывает список")
	T.eq(B.ns.char.chatWindow, "Чиллзон")
	T.eq(p.button:GetText(), "Чиллзон")

	c.G:Slash("/cz1", "во вкладку")
	w:Run(30)
	T.eq(Has(tab.lines, "во вкладку"), 1, "строка во вкладке")
	T.eq(B:Saw("во вкладку"), 0, "в основном окне её нет")
	T.eq(HistoryHas(B, "A", "во вкладку"), 1, "окно Chillzone строку тоже получило")

	-- Вкладку закрыли: строки идут в основное окно, предупреждение — один раз.
	B:ChatWindow(3, "Чиллзон", true)
	c.G:Slash("/cz1", "вкладка закрыта")
	w:Run(30)
	c.G:Slash("/cz1", "ещё строка")
	w:Run(30)
	T.eq(B:Saw("вкладка закрыта"), 1)
	T.eq(B:Saw("ещё строка"), 1)
	T.eq(B:Saw("вкладки чата «Чиллзон» нет"), 1, "предупреждение один раз")
	B.ns.UI.Render()
	T.eq(p.button:GetText(), "|cffff6060«Чиллзон» закрыта|r", "кнопка говорит, что вкладки нет")
	p.button.scripts.OnClick(p.button)
	T.ok(p.list:IsShown())
	T.no(p.items[1].check:IsShown() or p.items[2].check:IsShown(), "закрытая вкладка не отмечена")
	B.ns.UI.Toggle("kingdom")
	T.no(p.list:IsShown(), "список закрыт вместе с настройками")

	-- Команда: регистр не важен, опечатка перечисляет открытые вкладки, пусто — основное окно.
	B:ChatWindow(3, "Чиллзон")
	B:Slash("/chillzone", "window ЧИЛЛЗОН")
	T.eq(B.ns.char.chatWindow, "Чиллзон", "название — как у вкладки")
	B:Slash("/chillzone", "window Торговля")
	T.eq(B:Saw("нет вкладки чата «Торговля». Открыты: «Общий», «Чиллзон»"), 1)
	T.eq(B.ns.char.chatWindow, "Чиллзон", "опечатка не сбрасывает выбор")
	B:Slash("/chillzone", "window")
	T.eq(B.ns.char.chatWindow, false)
	c.G:Slash("/cz1", "снова в основном")
	w:Run(30)
	T.eq(B:Saw("снова в основном"), 1)
	T.eq(B:Saw("вкладки чата «Чиллзон» нет"), 1, "в основном окне не предупреждаем")
	Errors(c)
end)

T.test("окно: люди справа", function()
	local w, c = Build()
	c.M:Slash("/cz1", "я тоже тут")
	w:Run(30)
	local function find(list, name)
		for _, p in ipairs(list) do
			if not p.header and p.name == name then return p end
		end
	end
	local function headers(list)
		local out = {}
		for _, p in ipairs(list) do if p.header then out[#out + 1] = p.guild end end
		return table.concat(out, ",")
	end
	local all = c.G.ns.Views.People("A")
	T.ok(headers(all):find("^Чиллзон,"), "главная гильдия первой: " .. headers(all))
	local karl = find(all, "Карл Великий")
	T.ok(karl and karl.role == "leader" and karl.online, "король в сети")
	T.eq(c.G.ns.Views.Role(karl), "Король", "подпись роли")
	T.eq(find(all, "Арагорн Светлый").role, "officer", "капитан")
	local mira = find(all, "Мира Тихая")
	T.ok(mira and mira.role == "active" and mira.wrote, "рядовая — потому что писала")
	local off = find(all, "Офицер Ордена")
	T.ok(off and not off.online, "офицер не в сети — серым")
	local lords = c.G.ns.Views.People("L")
	T.ok(find(lords, "Вера Верная") and find(lords, "Глеб Гордый") and find(lords, "Карл Великий"), "главы в «Главах»")
	T.ok(find(lords, "Арагорн Светлый"), "офицер главной в «Главах»")
	T.eq(find(lords, "Офицер Ордена"), nil, "офицер другой гильдии не в «Главах»")
	local guild = c.B.ns.Views.People("G")
	T.ok(find(guild, "Вера Верная") and find(guild, "Борис Быстрый"), "своя гильдия по ростеру")
	T.eq(find(guild, "Тихий Друид"), nil, "не в игре — не в списке чата гильдии")
	local officers = c.V.ns.Views.People("O")
	T.ok(find(officers, "Вера Верная") and not find(officers, "Борис Быстрый"), "офицеры гильдии")
	local tt = setmetatable({}, { __index = function() return function() end end })
	for _, p in ipairs(all) do
		if not p.header then c.G.ns.Views.PersonTip(tt, p) end
	end
	Errors(c)
end)

T.test("окно: отметка аддона в списке людей", function()
	local w, c = Build()
	w:AddOnline("Чиллзон Север", "Без Аддона-CAMWOWUS2Realm7PvE", 3, 30, "MAGE")
	c.B.ns.Roster.Scan()
	c.M:Slash("/cz1", "я с аддоном")
	w:Run(30)
	local function find(list, name)
		for _, p in ipairs(list) do
			if not p.header and p.name == name then return p end
		end
	end
	-- Своя гильдия — по приветам H1.
	local guild = c.B.ns.Views.People("G")
	local vera = find(guild, "Вера Верная")
	T.ok(vera and vera.addon == true, "согильдиец с аддоном")
	T.eq(vera.version, c.V.ns.VERSION, "версия из привета")
	T.eq(find(guild, "Борис Быстрый").addon, true, "я сам")
	T.eq(find(guild, "Без Аддона").addon, false, "в игре без привета — аддона нет")
	-- Общий канал: свои — по приветам, чужие — если писали в общий канал или прислали отчёт.
	local all = c.G.ns.Views.People("A")
	T.eq(find(all, "Офицер Ордена").addon, nil, "согильдиец не в игре — неизвестно")
	T.eq(find(all, "Мира Тихая").addon, true, "писала в общий канал")
	local origin = c.G.ns.Data.Row("Чиллзон").origin
	T.eq(find(all, origin).addon, true, "прислал отчёт переписи")
	local other = origin == "Карл Великий" and "Арагорн Светлый" or "Карл Великий"
	T.eq(find(all, other).addon, nil, "чужой без следов аддона — неизвестно")
	-- Подсказка.
	local lines = {}
	local tt = setmetatable({ AddLine = function(_, t) lines[#lines + 1] = t end }, { __index = function() return function() end end })
	local function tip(p)
		lines = {}
		c.B.ns.Views.PersonTip(tt, p)
		return table.concat(lines, "\n")
	end
	T.ok(tip(vera):find("Аддон Chillzone: есть, версия " .. c.V.ns.VERSION, 1, true), "есть, с версией")
	T.ok(tip(find(guild, "Без Аддона")):find("Аддон Chillzone: нет", 1, true), "нет")
	T.ok(tip(find(all, other)):find("Аддон Chillzone: неизвестно", 1, true), "неизвестно")
	T.eq(c.B.ns.Views.AddonText({ addon = true, version = "|cffff0000x|r" }), "Аддон Chillzone: есть, версия cffff0000xr", "версия — простой текст")
	-- Значок в строке окна только у тех, у кого аддон есть.
	c.B.ns.UI.OpenChat("G")
	c.B.ns.ChatPane.RenderPeople()
	local marked = {}
	for _, r in ipairs(c.B.ns.ChatPane.frames.rows) do
		if r:IsShown() and r.person then marked[r.person.name] = r.addon:IsShown() end
	end
	T.eq(marked["Вера Верная"], true, "значок у Веры")
	T.eq(marked["Без Аддона"], false, "у согильдийца без аддона значка нет")
	Errors(c)
end)

T.test("окно: «аддона нет» — только после минуты приветов", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	w:AddOnline("Чиллзон Север", "Без Аддона-CAMWOWUS2Realm7PvE", 3, 30, "MAGE")
	local v = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local b = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2 })
	w:Run(20)
	local key = v.ns.Util.Key
	T.eq(v.ns.Census.Addon(key("Без Аддона")), nil, "сразу после входа — неизвестно")
	local has, version = v.ns.Census.Addon(key(b:Name()))
	T.ok(has == true and version == b.ns.VERSION, "привет от Бориса")
	T.eq(v.ns.Census.Addon(key(v:Name())), true, "я сам")
	w:Run(80)
	T.eq(v.ns.Census.Addon(key("Без Аддона")), false, "за полторы минуты привета не было")
	T.eq(v.ns.Census.Addon(key(b:Name())), true, "Борис по-прежнему с аддоном")
	T.eq(#v.ns.db.errors, 0)
end)

T.test("окно: Enter при открытом окне и в бою", function()
	local _, c = Build({ run = 60 })
	local B = c.B
	B.ns.UI.OpenChat("A")
	local bind = B.bindings.ENTER
	T.ok(bind and bind.button == "ChillzoneChatKey", "Enter ведёт в поле окна")
	B.ns.ChatPane.frames.keyButton.scripts.OnClick()
	T.ok(B.ns.ChatPane.frames.box:HasFocus(), "клавиша ставит курсор")
	B.ns.UI.Toggle()
	T.eq(B.bindings.ENTER, nil, "окно закрыто — Enter снова у игры")
	B.combat = true
	B.ns.UI.OpenChat("A")
	T.eq(B.bindings.ENTER, nil, "в бою привязку не трогаем")
	B.combat = false
	B:Fire("PLAYER_REGEN_ENABLED")
	T.ok(B.bindings.ENTER, "после боя привязка поставлена")
	B:Fire("UPDATE_BINDINGS")
	T.ok(B.bindings.ENTER, "повторная синхронизация ничего не ломает")
	Errors(c)
end)

T.test("окно: вкладки, каналы, ссылки и шёпот без ошибок", function()
	local w, c = Build()
	local A = c.A
	c.G:Slash("/cz1", "ссылка " .. LINK)
	w:Run(30)
	for _, tab in ipairs({ "census", "kingdom", "settings", "chat" }) do A.ns.UI.Toggle(tab) end
	for _, ch in ipairs({ "G", "O", "A", "C", "L" }) do A.ns.ChatPane.Select(ch) end
	local box = A.ns.ChatPane.frames.box
	box.scripts.OnTabPressed(box)
	A.shift = true
	box.scripts.OnTabPressed(box)
	A.shift = false
	A.ns.ChatPane.Select("A")
	local msgs = A.ns.ChatPane.frames.messages
	msgs.scripts.OnHyperlinkClick(msgs, "player:Глеб Гордый", "[Глеб Гордый]", "LeftButton")
	T.eq(box:GetText(), "/w Глеб Гордый ", "клик по имени — шёпот в поле")
	local menuName
	A.env.FriendsFrame_ShowDropdown = function(name) menuName = name end
	msgs.scripts.OnHyperlinkClick(msgs, "player:Глеб Гордый", "[Глеб Гордый]", "RightButton")
	T.eq(menuName, "Глеб Гордый", "ПКМ открывает меню игрока")
	T.eq(box:GetText(), "/w Глеб Гордый ")
	A.shift = true
	box:SetText("")
	msgs.scripts.OnHyperlinkClick(msgs, "item:19019", LINK, "LeftButton")
	A.shift = false
	T.eq(box:GetText(), LINK, "Shift-клик по ссылке — в поле")
	box:SetFocus()
	local bagLink = "|Hitem:25|h[Предмет из сумки]|h"
	T.eq(A.env.ChatFrameUtil.InsertLink(bagLink), false)
	T.eq(box:GetText(), LINK .. bagLink, "предмет из сумки — в поле")
	A.ns.char.chatTime = true
	A.ns.ChatPane.Reload()
	A.ns.UI.Toggle()
	T.eq(A.ns.UI.Current(), nil, "окно закрыто")
	-- Смена гильдии стирает историю чата гильдии.
	A.ns.char.history.G[1] = { t = 0, s = "Кто-то", x = "старое" }
	A.ns.char.historyGuild = "Прежняя гильдия"
	A:Fire("PLAYER_GUILD_UPDATE")
	A.ns.Roster.Scan()
	T.eq(#A.ns.char.history.G, 0, "история прежней гильдии стёрта")
	Errors(c)
end)

-- Строки «Отладки» одним текстом, без цветов и значков.
local function DebugText(cl)
	local out = {}
	for _, l in ipairs(cl.ns.Debug.Lines()) do
		local s = (l.text or "") .. " | " .. (l.right or "")
		out[#out + 1] = (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T[^|]*|t", ""))
	end
	return table.concat(out, "\n")
end

T.test("окно: вкладка «Отладка» — главам и офицерам", function()
	local w, c = Build()
	local A, M, B, V = c.A, c.M, c.B, c.V
	A.ns.UI.Toggle("debug")
	T.eq(A.ns.UI.Current(), "debug", "офицер главной видит «Отладку»")
	T.ok(A.ns.UI.tabs.debug:IsShown(), "значок вкладки виден")
	M.ns.UI.Toggle("debug")
	T.eq(M.ns.UI.Current(), "chat", "рядовому вместо «Отладки» — чат")
	T.no(M.ns.UI.tabs.debug:IsShown(), "значка у рядового нет")
	M:Slash("/chillzone", "diag")
	T.ok(M:Saw("только для глав и офицеров") >= 1, "команда рядовому отказывает")
	T.eq(M.ns.UI.Current(), "chat", "окно осталось на чате")
	B:Slash("/chillzone", "diag")
	T.ok(B:Saw("только для глав и офицеров") >= 1, "«Ветеран» Севера без флага — тоже нет")
	V:Slash("/chillzone", "diag")
	T.eq(V.ns.UI.Current(), "debug", "глава Севера видит «Отладку»")

	-- Что видно: реле, через кого шлю, регистрации у реле, отчёты.
	local a, b = DebugText(A), DebugText(B)
	T.ok(a:find("моё реле: я сам", 1, true), "реле рассылает само")
	T.ok(a:find("Орден Чиллзона: Глеб Гордый", 1, true), "Глеб зарегистрирован у Арагорна")
	T.ok(a:find("Чиллзон Север: ", 1, true), "репортёр Севера тоже")
	T.ok(a:find("офицер: да  (по флагу «Офицер» у звания)", 1, true), "откуда известно, что офицер")
	local via = B.ns.Relay.Pick()
	T.ok(via and (via.key == "арагорн светлый" or via.key == "карл великий"), "Борис шлёт через офицера главной")
	T.ok(b:find("моё реле: " .. B.ns.Util.Display(via.name), 1, true), "через кого шлю")
	T.ok(b:find("в приоритете", 1, true) and b:find("отвечает", 1, true), "certified officer is preferred and reachable")
	T.ok(b:find("Мира Тихая", 1, true), "certified ordinary backup is visible")
	T.ok(b:find("Орден Чиллзона | от Глеб Гордый", 1, true), "откуда отчёт Ордена")
	-- Реле не в игре, отклонённые отчёты и ошибки.
	local e = B.ns.Relay.Known()["арагорн светлый"]
	e.down = B.ns.Now() + 120
	B.ns.Data.rejected["старее"] = 2
	B.ns.db.errors[1] = "проверка: |cffff0000сломалось"
	b = DebugText(B)
	T.ok(b:find("Арагорн Светлый", 1, true) and b:find("не в игре, ещё 2 мин", 1, true), "relay outage is visible")
	T.ok(b:find("отклонено: старее 2", 1, true), "отклонённые отчёты")
	T.ok(b:find("проверка: cffff0000сломалось", 1, true), "ошибка без цветового кода")
	local tt = setmetatable({}, { __index = function() return function() end end })
	for _, cl in pairs(c) do
		for _, l in ipairs(cl.ns.Debug.Lines()) do
			if l.tip then l.tip(tt) end
		end
	end
	B.ns.db.errors = {}
	e.down = nil

	-- Окно на «Отладке» обновляется само; офицер потерял флаг звания — вкладка закрылась.
	A.ns.UI.frame.scripts.OnUpdate(A.ns.UI.frame, 6)
	w.guilds["Чиллзон"].officers = { [0] = true }
	A:Fire("GUILD_RANKS_UPDATE")
	w:Run(30)
	T.eq(A.ns.UI.Current(), "chat", "без офицерского флага — снова чат")
	T.no(A.ns.UI.tabs.debug:IsShown(), "значок пропал")
	Errors(c)
end)

T.test("окно: чат гильдии «Чиллзон» и общий канал «Чиллзон» различимы", function()
	local _, c = Build({ run = 60 })
	local A = c.A
	A.ns.UI.OpenChat("G")
	local f = A.ns.ChatPane.frames
	local seen = {}
	for _, e in ipairs(f.entries) do
		if e:IsShown() then
			local text = e.name:GetText() .. " / " .. e.sub:GetText()
			T.no(seen[text], "одинаковые строки в списке каналов: " .. text)
			seen[text] = true
		end
	end
	T.ok(seen["Чиллзон / чат гильдии"], "чат гильдии подписан")
	T.ok(seen["Чиллзон / все гильдии"], "общий канал подписан")
	T.ok(seen["Офицеры / чат гильдии"] and seen["Офицеры / все гильдии"], "оба «Офицеры» различимы")
	T.ok(seen["Главы / все гильдии"], "«Главы» подписаны")
	T.eq(f.prompt:GetText(), "Гильдия:", "поле ввода чата гильдии — как в игре")
	T.eq(f.scope:GetText(), "чат гильдии", "подпись в шапке")
	A.ns.ChatPane.Select("A")
	T.eq(f.prompt:GetText(), "Чиллзон:", "поле ввода общего канала")
	T.eq(f.scope:GetText(), "все гильдии «Чиллзон», /cz1", "шапка общего канала — с командой")
	A.ns.ChatPane.Select("O")
	T.eq(f.title:GetText(), "Офицеры гильдии", "в шапке — полное название")
	Errors(c)
end)

T.test("окно: шапка — все гильдии, как у Olympus", function()
	local w, c = Build()
	local B = c.B
	local guilds, total, online = B.ns.Data.Totals()
	T.eq(guilds, 3, "три гильдии в переписи")
	local st = B.ns.Views.Status()
	T.eq(st.total, total, "всего")
	T.eq(st.online, online, "в игре")
	T.eq(st.big, B.ns.Util.Num(total) .. " " .. B.ns.Util.Plural(total, "участник", "участника", "участников"), "крупно")
	T.ok(st.small:find("3|r гильдии", 1, true), "мелко: 3 гильдии — " .. st.small)
	T.ok(st.small:find("в игре", 1, true) and st.small:find("обновлено", 1, true), "мелко: в игре, обновлено")
	B.ns.UI.OpenChat("G")
	T.eq(B.ns.UI.status.big:GetText(), st.big, "шапка в окне")
	T.eq(B.ns.UI.heading:GetText(), "", "на чате названия вкладки нет — там канал")
	B.ns.UI.Toggle("census")
	T.eq(B.ns.UI.status.big:GetText(), st.big, "та же шапка на «Переписи»")
	T.eq(B.ns.UI.heading:GetText(), "Перепись", "название вкладки")
	-- Подсказка: по строке на гильдию.
	local lines = {}
	local tt = setmetatable({
		AddLine = function(_, t) lines[#lines + 1] = t end,
		AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " = " .. r end,
	}, { __index = function() return function() end end })
	B.ns.Views.StatusTip(tt)
	local text = table.concat(lines, "\n")
	for _, g in ipairs({ "Чиллзон", "Чиллзон Север (моя)", "Орден Чиллзона" }) do
		T.ok(text:find(g .. " = ", 1, true), "в подсказке " .. g)
	end
	-- Подсказка у миникарты — те же две строки.
	lines = {}
	B.ns.Views.MinimapTip(tt)
	T.eq(lines[2], st.big, "миникарта: крупная строка")
	-- Без переписи — «ждём».
	local stranger = w:Client({ first = "Никто", surname = "Ничей", guild = nil })
	T.eq(stranger.ns.Views.Status().big, "Ждём перепись", "без данных")
	Errors(c)
end)

T.test("окно: «В сети» под списком людей — про людей канала", function()
	local _, c = Build()
	local V = c.V
	V.ns.UI.OpenChat("G")
	V.ns.ChatPane.RenderPeople()
	local r = V.ns.Roster.report
	local label = V.ns.ChatPane.frames.count
	T.eq(label:GetText(), ("В сети: %s из %s"):format(r.online, r.total), "чат гильдии — по ростеру")
	V.ns.ChatPane.Select("O")
	V.ns.ChatPane.RenderPeople()
	local items, online = V.ns.Views.People("O")
	local n = 0
	for _, p in ipairs(items) do if not p.header then n = n + 1 end end
	T.eq(label:GetText(), ("В сети: %s из %s"):format(online, n), "офицеры — только офицеры")
	T.ok(n < r.total, "офицеров меньше, чем всех")
	V.ns.ChatPane.Select("L")
	V.ns.ChatPane.RenderPeople()
	local on, all = V.ns.ChatPane.Counts("L")
	T.eq(label:GetText(), ("В сети: %s из %s"):format(on, all), "«Главы» — люди списка")
	T.ok(all >= 3 and all < V.ns.Views.Status().total, "главы, а не все участники")
	Errors(c)
end)

T.test("перепись: список гильдий и карточка выбранной", function()
	local _, c = Build()
	local B = c.B
	local P = B.ns.CensusPane
	B.ns.UI.Toggle("census")
	local f = P.frames
	local key = B.ns.Util.GuildKey
	T.eq(P.Selected(), key("Чиллзон Север"), "сразу выбрана своя гильдия")
	local shown, sel = 0, nil
	for _, r in ipairs(f.rows) do
		if r:IsShown() then
			shown = shown + 1
			if r.sel:IsShown() then sel = r.name:GetText() end
		end
	end
	T.eq(shown, 3, "три гильдии в списке")
	T.ok(sel and sel:find("Чиллзон Север", 1, true), "выделена своя: " .. tostring(sel))
	local w = f.w
	T.eq(w.title:GetText(), "Чиллзон Север", "название в карточке")
	T.eq(w.marks:GetText(), "ваша гильдия", "отметка своей")
	local row
	for _, s in ipairs(B.ns.Data.Summary()) do
		if s.mine then row = s end
	end
	T.eq(w.tiles[1].value:GetText(), B.ns.Util.Num(row.total), "плитка: участников")
	T.eq(w.tiles[2].value:GetText(), B.ns.Util.Num(row.online), "плитка: в игре")
	T.eq(w.tiles[3].value:GetText(), tostring(#row.r.officers), "плитка: офицеров")
	T.ok(not w.tiles[4].value:GetText():find(".", 1, true), "средний уровень через запятую")
	-- Подпись классов: по строке на класс, имя и число отдельно — не рвутся переносом.
	local card = B.ns.Views.GuildCard(row)
	local items = 0
	for i, e in ipairs(f.legend) do
		if e.name:IsShown() then
			items = items + 1
			T.eq(e.count:GetText(), tostring(card.classes[i].count), "число класса " .. i)
			T.ok(e.name:GetText():find(card.classes[i].name, 1, true), "имя класса " .. i)
		end
	end
	T.ok(#card.classes > 0, "в игре есть классы")
	T.eq(items, #card.classes, "строк подписи — сколько классов в игре")
	-- Руководство: глава первой, щелчок — шёпот в окне чата.
	local first = f.people[1]
	T.ok(first:IsShown() and first.person.name == "Вера Верная" and first.person.role == "leader", "глава первой")
	first.scripts.OnClick(first)
	T.eq(B.ns.UI.Current(), "chat", "щелчок по имени открывает чат")
	T.eq(B.ns.ChatPane.frames.box:GetText(), "/w Вера Верная ", "и шёпот в поле")
	-- Другая гильдия: главная.
	B.ns.UI.Toggle("census")
	P.Select(key("Чиллзон"))
	T.eq(w.title:GetText(), "Чиллзон", "выбрана главная")
	T.eq(w.marks:GetText(), "главная гильдия", "отметка главной")
	T.eq(P.Selected(), key("Чиллзон"), "выбор держится")
	B.ns.UI.Render()
	T.eq(P.Selected(), key("Чиллзон"), "и после перерисовки")
	Errors(c)
end)

T.test("перепись: данные карточки", function()
	local _, c = Build()
	local V = c.B.ns.Views
	T.eq(V.State(true, 5), "в игре", "в игре")
	T.eq(V.State(false, 0), "не в игре меньше дня", "меньше дня, а не «0 дн.»")
	T.eq(V.State(false, 3), "не в игре 3 дн.", "дни")
	T.eq(V.Decimal(13.5), "13,5", "запятая")
	T.eq(V.Decimal(60), "60,0", "целое")
	local s = {
		guild = "Тестовая Чиллзон", fresh = true, recent = true, age = 120, total = 25, online = 3,
		r = {
			leader = "Глава Тестовый", leaderClass = "MAGE", leaderOnline = true, leaderDays = 0,
			officers = { { name = "Офицер Первый", class = "ROGUE", online = false, days = 2, rank = 1 } },
			users = 2, avgLevel = 31.3, inactive7 = 4, inactive30 = 1,
			classes = { MAGE = 2, ROGUE = 1 }, levels = { 1, 0, 0, 2, 0, 0, 0 }, zones = {},
			ranks = { { name = "Глава", count = 1 }, { name = "Офицер", count = 1 }, { name = "Ранг 3", count = 0 }, { name = "Новичок", count = 23 } },
		},
	}
	local card = V.GuildCard(s)
	T.eq(card.stats[1].label, "участников", "25 участников")
	T.eq(card.stats[3].value .. " " .. card.stats[3].label, "1 офицер", "1 офицер")
	T.eq(card.stats[4].value, "31,3", "средний уровень")
	T.eq(#card.people, 2, "глава и офицер")
	T.ok(card.people[1].online and not card.people[2].online, "в игре — по свежему отчёту")
	T.eq(card.classTotal, 3, "классы в игре")
	T.eq(card.classes[1].class, "MAGE", "сначала самый частый")
	T.eq(card.levelMax, 2, "самый высокий столбик")
	T.eq(card.levels[7].label, "60", "последний столбик — 60")
	T.eq(card.zonesNote, "Репортёр этой гильдии не делится зонами.", "зоны не присланы")
	T.eq(card.ranks, nil, "строки рангов в карточке нет")
	T.ok(card.updated:find("обновлено", 1, true), "когда обновлено")
	s.fresh = false
	card = V.GuildCard(s)
	T.eq(card.classes, nil, "без свежего отчёта классов нет")
	T.ok(card.staleNote, "и есть пояснение")
	T.ok(not card.people[1].online, "без свежего отчёта никто не «в игре»")
	Errors(c)
end)
