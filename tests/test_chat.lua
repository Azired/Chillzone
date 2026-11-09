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
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
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

T.test("slash: короткие алиасы выполняют известные команды, остальное отправляют в чат", function()
	local _, c = SlashClient()
	local sent = {}
	c.ns.Chat.Send = function(tier, text) sent[#sent + 1] = { tier, text } end
	c:Slash("/chillzone", "нетакой")
	T.eq(#sent, 0, "неизвестная команда управления не уходит в чат")
	local args = {}
	c.ns.Command("custom", function(arg) args[#args + 1] = arg end)
	for _, cmd in ipairs({ "/chillzone", "/cz", "/чз", "/чиллзон" }) do
		c:Slash(cmd, "  SeTtInGs  ")
		T.eq(c.ns.UI.Current(), "settings", cmd .. " выполняет команду")
		local before = c:Saw("перепись: репортёр")
		c:Slash(cmd, "status")
		T.eq(c:Saw("перепись: репортёр"), before + 1, cmd .. " выполняет status")
		c:Slash(cmd, "custom Имя Фамилия")
		T.eq(args[#args], "Имя Фамилия", "аргументы переданы обработчику")
	end
	T.eq(#sent, 0, "известные команды не уходят в чат")
	T.eq(#args, 4)
	for _, cmd in ipairs({ "/cz", "/чз", "/чиллзон" }) do
		for _, text in ipairs({ "привет " .. LINK, "settingsfoo текст", "нетакой" }) do
			c:Slash(cmd, text)
			T.same(sent[#sent], { "A", text }, cmd .. " отправляет обычный текст")
		end
	end
	T.eq(#sent, 9)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("slash: нумерованные каналы отправляют слова команд, ошибка команды не уходит в чат", function()
	local _, c = SlashClient()
	local sent = {}
	c.ns.Chat.Send = function(tier, text) sent[#sent + 1] = { tier, text } end
	for _, prefix in ipairs({ "/cz", "/чз" }) do
		for i, tier in ipairs({ "A", "C", "L" }) do
			c:Slash(prefix .. i, "status")
			T.same(sent[#sent], { tier, "status" })
		end
	end
	c.ns.Command("broken", function() error("ошибка команды") end)
	c:Slash("/cz", "broken")
	T.eq(#sent, 6, "ошибка не превращается в сообщение")
	T.eq(#c.ns.db.errors, 1, "ошибка перехвачена")
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
			for _, text in ipairs({ cmd, cmd .. " ", cmd .. " settings", cmd .. " status", cmd .. " привет " .. LINK }) do
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

T.test("slash: пустые команды открывают нужный канал без отправки и подсказки", function()
	local w, c = SlashClient()
	local sent = 0
	c.ns.Chat.Send = function() sent = sent + 1 end
	local aliases = { ["/cz"] = "A", ["/чз"] = "A", ["/чиллзон"] = "A",
		["/cz1"] = "A", ["/чз1"] = "A", ["/cz2"] = "C", ["/чз2"] = "C", ["/cz3"] = "L", ["/чз3"] = "L" }
	for cmd, tier in pairs(aliases) do
		c:Slash("/chillzone", "settings")
		for _, text in ipairs({ "", "   " }) do
			local before = #c.printed
			c:Slash(cmd, text)
			w:Run(0)
			T.eq(c.ns.UI.Current(), "chat", cmd .. " открывает окно")
			T.eq(c.ns.ChatPane.Current(), tier, cmd .. " выбирает канал")
			T.ok(c.ns.ChatPane.frames.box:HasFocus(), cmd .. " ставит курсор в поле")
			T.eq(#c.printed, before, cmd .. " ничего не печатает в чат")
		end
	end
	T.eq(sent, 0)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("slash: пустая команда сохраняет черновик и повторно не закрывает окно", function()
	local _, c = SlashClient()
	c:Slash("/cz", "")
	local box = c.ns.ChatPane.frames.box
	T.ok(box, "поле открытого окна")
	box:SetText("черновик " .. LINK)
	box.scripts.OnTextChanged(box, true)
	c:Slash("/cz", "")
	T.eq(c.ns.UI.Current(), "chat")
	T.eq(box:GetText(), "черновик " .. LINK)
	T.eq(c.ns.Chat.stats.sent, 0)
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
	c:Slash("/cz2", "")
	c:Slash("/cz3", "   ")
	T.eq(c:Saw("можно писать только с нужным рангом"), 4, "пустая команда тоже проверяет канал")
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

T.test("окно: теги гильдий используют выбранный регистр", function()
	local _, c = SlashClient()
	local guilds = {
		{ "ЧИЛЛЗОН", "Чз", "ЧЗ" },
		{ "Чиллзон Навсегда", "ЧзН", "ЧЗН" },
		{ "Запомни Навсегда", "Зн", "ЗН" },
		{ "Другая Гильдия", "Другая Гильдия", "Другая Гильдия" },
	}
	T.eq(c.ns.char.chatGuildTagsUpper, false, "по умолчанию смешанный регистр")
	for _, on in ipairs({ false, true, false }) do
		c.ns.char.chatGuildTagsUpper = on
		for _, row in ipairs(guilds) do
			local tag = "|cff999999<" .. row[on and 3 or 2] .. ">|r"
			T.ok(c.ns.Chat.Format("A", row[1], c:Name(), c.class, "текст"):find(tag, 1, true), "чат игры")
			T.ok(c.ns.Views.ChatLine({ g = row[1], s = c:Name(), x = "текст" }, "A", false):find(tag, 1, true), "окно Chillzone")
		end
	end
	T.eq(#c.ns.db.errors, 0)
end)

T.test("окно: теги гильдий переключаются в настройках и сохраняются", function()
	local w, c = SlashClient()
	local other = w:Client({ first = "Другой", surname = "Игрок", guild = "Чиллзон", db = c.ns.db })
	c.ns.UI.OpenChat("A")
	c.ns.Chat.Show("A", "Чиллзон", c:Name(), c.class, "старая строка")
	local messages = c.ns.ChatPane.frames.messages
	c.ns.UI.Toggle("settings")
	local check = c.ns.UI.guildTagsUpper
	T.ok(check, "есть переключатель регистра")
	T.no(check:GetChecked(), "смешанный регистр по умолчанию")
	for _, on in ipairs({ true, false }) do
		local previousLine = c.printed[#c.printed]
		check:SetChecked(on)
		check.scripts.OnClick(check)
		T.eq(c.ns.char.chatGuildTagsUpper, on)
		T.eq(other.ns.char.chatGuildTagsUpper, false, "настройка другого персонажа независима")
		local tag = on and "<ЧЗ>" or "<Чз>"
		T.ok(messages.lines[1]:find(tag, 1, true), "история окна перерисована сразу")
		T.eq(c.ns.Chat.History("A")[1].g, "Чиллзон", "в истории хранится полное имя гильдии")
		T.eq(c.printed[#c.printed], previousLine, "уже выведенная строка игры прежняя")
		c:Slash("/chillzone", "history 1")
		T.ok(c.printed[#c.printed]:find(tag, 1, true), "повторный вывод истории учитывает выбор")
		c.ns.Chat.Show("A", "Чиллзон", c:Name(), c.class, "новая строка")
		T.ok(c.printed[#c.printed]:find(tag, 1, true), "новая строка игры")
		local db = c.ns.db
		c:Logout()
		c = w:Client({ first = "Автор", surname = "Чата", guild = "Чиллзон", rank = 0, db = db })
		c.ns.UI.Toggle("settings")
		check = c.ns.UI.guildTagsUpper
		T.eq(check:GetChecked(), on, "выбор сохранён после входа")
		c.ns.UI.OpenChat("A")
		messages = c.ns.ChatPane.frames.messages
		T.ok(messages.lines[1]:find(tag, 1, true), "сохранённая история учитывает выбор")
		c.ns.UI.Toggle("settings")
	end
	T.eq(#c.ns.db.errors, 0)
end)

T.test("окно: время у строк учитывается и в чате игры", function()
	local _, c = SlashClient()
	local tab = c:ChatWindow(3, "Чиллзон")
	local stamp = "|cff999999" .. c.env.date("%H:%M", c.ns.ServerTime()) .. "|r "
	for _, tier in ipairs({ "A", "C", "L" }) do
		c.ns.UI.OpenChat(tier)
		local messages = c.ns.ChatPane.frames.messages
		for _, on in ipairs({ false, true, false }) do
			c.ns.char.chatTime = on
			c.ns.Chat.Show(tier, "Чиллзон", c:Name(), "MAGE", "проверка времени")
			local line = c.printed[#c.printed]
			T.eq(line:sub(1, #stamp) == stamp, on, "основное окно чата игры")
			T.eq(messages.lines[#messages.lines]:sub(1, #stamp) == stamp, on, "окно Chillzone")

			c.ns.Chat.SetWindow("Чиллзон")
			c.ns.Chat.Show(tier, "Чиллзон", c:Name(), "MAGE", "проверка вкладки")
			T.eq(tab.lines[#tab.lines]:sub(1, #stamp) == stamp, on, "выбранная вкладка чата игры")
			c.ns.Chat.SetWindow(nil)
		end
	end
	-- История уже добавляет время сама, поэтому не должна получать его дважды.
	c.ns.char.chatTime = true
	c:Slash("/chillzone", "history 1")
	local line = c.printed[#c.printed]
	T.eq(line:sub(1, #stamp), stamp, "у истории осталось время")
	T.no(line:find(stamp, #stamp + 1, true), "время не дублируется")
	T.eq(#c.ns.db.errors, 0)
end)

T.test("окно: цвет текста общего чата один для окна и чата игры", function()
	local w, c = Build()
	local B = c.B
	local tab = B:ChatWindow(3, "Чиллзон")
	B.ns.Chat.SetWindow("Чиллзон")
	B.ns.UI.OpenChat("A")
	local messages = B.ns.ChatPane.frames.messages
	local function Hex(color)
		return string.format("%02x%02x%02x", math.floor(color[1] * 255 + 0.5), math.floor(color[2] * 255 + 0.5), math.floor(color[3] * 255 + 0.5))
	end

	c.G:Slash("/cz1", "цвет по умолчанию")
	w:Run(30)
	T.eq(Hex(tab.color), "7fd4c1", "копия в чате игры")
	T.eq(Hex(messages.color), "7fd4c1", "окно Chillzone")

	B.ns.UI.Toggle("settings")
	local swatches = B.ns.UI.swatches
	local pick = swatches[3]
	T.ok(swatches[1].ring:IsShown(), "отмечен цвет по умолчанию")
	T.no(pick.ring:IsShown())
	pick.scripts.OnClick(pick)
	T.eq(B.ns.db.settings.chatColor, pick.hex, "выбор сохранён")
	T.ok(pick.ring:IsShown(), "отмечен выбранный")
	T.no(swatches[1].ring:IsShown(), "прежняя отметка снята")
	T.eq(Hex(messages.color), pick.hex, "окно перекрашено сразу")

	c.G:Slash("/cz1", "новый цвет")
	w:Run(30)
	T.eq(Hex(tab.color), pick.hex, "новая строка в чате игры")
	T.eq(Hex({ B.ns.Chat.Color("L") }), pick.hex, "цвет один на все уровни")

	tab.color = nil
	B:Slash("/chillzone", "history 1")
	T.eq(Hex(tab.color), pick.hex, "история в чате игры тем же цветом")

	T.eq(table.concat({ B.ns.Chat.Color("G") }, ","), "0.25,1,0.25", "чат гильдии настройка не трогает")

	B.ns.db.settings.chatColor = "мусор"
	T.eq(B.ns.Chat.TextColor(), B.ns.Chat.COLORS[1], "испорченное значение заменяется цветом по умолчанию")
	Errors(c)
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
	T.ok(p.list:IsShown(), "можно выбрать следующую вкладку, не открывая список снова")
	T.ok(p.items[1].check:IsShown(), "основное окно осталось выбрано")
	T.ok(p.items[2].check:IsShown(), "новая вкладка тоже выбрана")
	p.items[1].scripts.OnClick(p.items[1])
	T.same(B.ns.char.chatWindows, { "Чиллзон" })
	T.eq(p.button:GetText(), "Чиллзон")
	p.button.scripts.OnClick(p.button)
	T.no(p.list:IsShown(), "повторный щелчок по кнопке закрывает список")

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
	T.no(p.items[1].check:IsShown(), "резервный вывод не меняет выбор")
	T.ok(p.items[2].check:IsShown(), "закрытую выбранную вкладку можно снять")
	T.eq(p.items[2].text:GetText(), "|cffff6060«Чиллзон» закрыта|r")
	B.ns.UI.Toggle("kingdom")
	T.no(p.list:IsShown(), "список закрыт вместе с настройками")

	-- Команда: регистр не важен, опечатка перечисляет открытые вкладки, пусто — основное окно.
	B:ChatWindow(3, "Чиллзон")
	B:Slash("/chillzone", "window ЧИЛЛЗОН")
	T.same(B.ns.char.chatWindows, { "Чиллзон" }, "название — как у вкладки")
	B:Slash("/chillzone", "window Торговля")
	T.eq(B:Saw("нет вкладки чата «Торговля». Открыты: «Общий», «Чиллзон»"), 1)
	T.same(B.ns.char.chatWindows, { "Чиллзон" }, "опечатка не сбрасывает выбор")
	B:Slash("/chillzone", "window")
	T.same(B.ns.char.chatWindows, { "" })
	c.G:Slash("/cz1", "снова в основном")
	w:Run(30)
	T.eq(B:Saw("снова в основном"), 1)
	T.eq(B:Saw("вкладки чата «Чиллзон» нет"), 1, "в основном окне не предупреждаем")
	Errors(c)
end)

T.test("окно: несколько вкладок получают строки и историю без дублей", function()
	local _, c = SlashClient()
	local chat = c.ns.Chat
	local first = c:ChatWindow(3, "Чиллзон")
	local second = c:ChatWindow(4, "Союз")
	c.ns.UI.Toggle("settings")
	local p = c.ns.UI.picker
	p.button.scripts.OnClick(p.button)
	p.items[2].scripts.OnClick(p.items[2])
	p.items[3].scripts.OnClick(p.items[3])
	T.same(c.ns.char.chatWindows, { "", "Чиллзон", "Союз" })
	T.eq(p.button:GetText(), "Выбрано вкладок: 3")
	chat.Show("A", c.guild, c:Name(), c.class, "во все вкладки")
	T.eq(c:Saw("во все вкладки"), 1)
	T.eq(Has(first.lines, "во все вкладки"), 1)
	T.eq(Has(second.lines, "во все вкладки"), 1)
	T.eq(HistoryHas(c, "A", "во все вкладки"), 1, "история не размножается")
	c:Slash("/chillzone", "history 1")
	T.eq(c:Saw("во все вкладки"), 2)
	T.eq(Has(first.lines, "во все вкладки"), 2)
	T.eq(Has(second.lines, "во все вкладки"), 2)

	-- Основное окно по собственному названию не создаёт второй копии.
	T.ok(chat.SetWindow("ОБЩИЙ"))
	T.same(c.ns.char.chatWindows, { "" })
	c.ns.UI.Render()
	T.ok(p.items[1].check:IsShown(), "открытый список обновляется после изменения выбора командой")
	T.no(p.items[2].check:IsShown() or p.items[3].check:IsShown())
	T.no(chat.ToggleWindow(""), "последняя вкладка остаётся выбрана")
	T.ok(chat.ToggleWindow("ЧИЛЛЗОН"))
	T.ok(chat.ToggleWindow("Союз"))
	T.ok(chat.ToggleWindow(""))
	T.no(chat.ToggleWindow("нет такой вкладки"))
	T.same(c.ns.char.chatWindows, { "Чиллзон", "Союз" })

	-- Одна вкладка закрыта: пишем в оставшуюся, не добавляя основное окно.
	c:ChatWindow(3, "Чиллзон", true)
	chat.Show("A", c.guild, c:Name(), c.class, "в оставшуюся")
	T.eq(Has(first.lines, "в оставшуюся"), 0)
	T.eq(Has(second.lines, "в оставшуюся"), 1)
	T.eq(c:Saw("в оставшуюся"), 0)
	-- Переименовали и последнюю: одна резервная копия и по одному предупреждению.
	c:ChatWindow(4, "Другое")
	chat.Show("A", c.guild, c:Name(), c.class, "резервная копия")
	chat.Show("A", c.guild, c:Name(), c.class, "ещё резервная")
	T.eq(c:Saw("резервная копия"), 1)
	T.eq(c:Saw("ещё резервная"), 1)
	T.eq(c:Saw("вкладки чата «Чиллзон» нет"), 1)
	T.eq(c:Saw("вкладки чата «Союз» нет"), 1)
	c:ChatWindow(3, "Чиллзон")
	chat.Show("A", c.guild, c:Name(), c.class, "вкладка вернулась")
	T.eq(Has(first.lines, "вкладка вернулась"), 1)
	T.eq(c:Saw("вкладка вернулась"), 0)

	-- Закрытую вкладку можно убрать из выбора прямо в списке.
	c.ns.UI.Render()
	if p.list:IsShown() then p.button.scripts.OnClick(p.button) end
	p.button.scripts.OnClick(p.button)
	T.eq(p.items[4].text:GetText(), "|cffff6060«Союз» закрыта|r")
	p.items[4].scripts.OnClick(p.items[4])
	T.same(c.ns.char.chatWindows, { "Чиллзон" })
	T.ok(p.list:IsShown())
	T.no(p.items[4]:IsShown())
	c.ns.char.chatMirror = false
	c.ns.UI.Render()
	T.no(p.list:IsShown(), "отключение копий закрывает список")
	chat.Show("A", c.guild, c:Name(), c.class, "копии выключены")
	T.eq(Has(first.lines, "копии выключены"), 0)
	T.eq(HistoryHas(c, "A", "копии выключены"), 1)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("окно: прежняя вкладка переносится в список, выбор переживает перезагрузку", function()
	local w, c = SlashClient()
	local db, key = c.ns.db, c.ns.myKey
	c:Logout()
	db.chars[key].chatWindows = nil
	db.chars[key].chatWindow = "Старая вкладка"
	local function Login()
		return w:Client({ first = c.first, surname = c.surname, guild = c.guild, db = db })
	end
	c = Login()
	T.same(c.ns.char.chatWindows, { "Старая вкладка" }, "сохраняется даже пока вкладка не открыта")
	c:ChatWindow(3, "Старая вкладка")
	T.ok(c.ns.Chat.ToggleWindow(""))
	c:Logout()
	c = Login()
	T.same(c.ns.char.chatWindows, { "Старая вкладка", "" }, "весь выбор сохранён")
	c:Logout()
	db.chars[key].chatWindows = nil
	db.chars[key].chatWindow = false
	c = Login()
	T.same(c.ns.char.chatWindows, { "" }, "прежнее основное окно тоже перенесено")
	c:Logout()
	db.chars[key].chatWindows = nil
	db.chars[key].chatWindow = "Общий"
	c = Login()
	T.same(c.ns.char.chatWindows, { "" }, "основное окно по названию тоже переносится в основную галочку")
	T.no(c.ns.Chat.ToggleWindow("Общий"), "последнюю галочку нельзя снять и по названию окна")
	T.same(c.ns.char.chatWindows, { "" }, "повторная галочка основного окна не добавляет дубликат")
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

T.test("окно: правый щелчок в списке людей открывает меню шёпота и приглашения", function()
	local _, c = Build()
	local B = c.B
	B.ns.UI.OpenChat("G")
	B.ns.ChatPane.RenderPeople()
	local row = {}
	for _, r in ipairs(B.ns.ChatPane.frames.rows) do
		if r:IsShown() and r.person then row[r.person.name] = r end
	end
	local vera, me = row["Вера Верная"], row["Борис Быстрый"]
	T.ok(vera and vera.person.online, "Вера в списке и в игре")
	local click, menu, box = vera:GetScript("OnClick"), B.ns.ChatPane.PersonMenu(), B.ns.ChatPane.frames.box
	local function Press(item) item:GetScript("OnClick")(item) end
	local function Watch() menu:GetScript("OnUpdate")(menu) end
	box:SetText("")
	-- Левый щелчок больше ничего не делает.
	click(vera, "LeftButton")
	T.eq(box:GetText(), "", "левый щелчок не открывает шёпот")
	T.no(menu:IsShown(), "левый щелчок не открывает меню")
	-- Правый открывает меню; повторный закрывает.
	click(vera, "RightButton")
	T.ok(menu:IsShown(), "меню открыто")
	T.ok(menu.title:GetText():find("Вера Верная", 1, true), "в заголовке имя")
	click(vera, "RightButton")
	T.no(menu:IsShown(), "повторный щелчок закрывает")
	-- Приглашение и шёпот.
	click(vera, "RightButton")
	T.eq(menu.invite.enabled, true, "приглашение доступно")
	Press(menu.invite)
	T.same(B.partyInvites, { "Вера Верная" }, "приглашение по имени без реалма")
	T.no(menu:IsShown(), "меню закрылось после выбора")
	click(vera, "RightButton")
	Press(menu.whisper)
	T.eq(box:GetText(), "/w Вера Верная ", "шёпот в поле окна")
	T.eq(#B.partyInvites, 1, "шёпот не приглашает")
	-- Себя и того, кто не в игре, не приглашаем.
	click(me, "RightButton")
	T.eq(menu.invite.enabled, false, "себя пригласить нельзя")
	Press(menu.invite)
	T.no(B.ns.ChatPane.InviteToGroup({ name = "Тихий Друид", online = false }), "не в игре")
	T.eq(#B.partyInvites, 1, "других приглашений нет")
	-- Щелчок мимо и закрытие окна убирают меню, щелчок по самому меню — нет.
	click(vera, "RightButton")
	Watch()
	T.ok(menu:IsShown(), "кнопка мыши не нажата")
	B.mouseDown = "RightButton"
	menu.IsMouseOver = function() return true end
	Watch()
	T.ok(menu:IsShown(), "щелчок по самому меню")
	menu.IsMouseOver = function() return false end
	Watch()
	T.no(menu:IsShown(), "щелчок мимо закрывает")
	B.mouseDown = nil
	click(vera, "RightButton")
	vera:Hide()
	Watch()
	T.no(menu:IsShown(), "строка скрыта — меню закрыто")
	vera:Show()
	-- Подсказка предлагает приглашение только там, где оно сработает.
	local lines = {}
	local tt = setmetatable({ AddLine = function(_, t) lines[#lines + 1] = t end }, { __index = function() return function() end end })
	local function tip(p)
		lines = {}
		B.ns.Views.PersonTip(tt, p)
		return table.concat(lines, "\n")
	end
	T.ok(tip(vera.person):find(B.ns.L.TIP_MENU_INVITE, 1, true), "подсказка у Веры")
	local own = tip(me.person)
	T.no(own:find(B.ns.L.TIP_MENU_INVITE, 1, true), "у себя приглашения нет")
	T.ok(own:find(B.ns.L.TIP_MENU_WHISPER, 1, true), "у себя только шёпот")
	-- Новое API клиента важнее старого; без обоих приглашение не падает.
	local used
	B.env.C_PartyInfo = { InviteUnit = function(name) used = name end }
	T.ok(B.ns.ChatPane.InviteToGroup(vera.person), "через C_PartyInfo")
	T.eq(used, "Вера Верная", "имя без реалма")
	T.eq(#B.partyInvites, 1, "старое API не вызвано")
	B.env.C_PartyInfo, B.env.InviteUnit = nil, nil
	T.no(B.ns.ChatPane.InviteToGroup(vera.person), "API нет")
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
	-- Проверяем приветы в уже подключённой гильдии, отдельно от протокола допуска.
	for _, client in ipairs({ v, b }) do
		client.ns.store.security.union[client.ns.Util.GuildKey(client.guild)] = { guild = client.guild, active = true }
	end
	v.ns.Roster.Scan() -- в симуляторе Борис добавлен после первого чтения ростера Веры
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
	A.shift = true
	box:SetText("")
	msgs.scripts.OnHyperlinkClick(msgs, "item:19019", LINK, "LeftButton")
	A.shift = false
	T.eq(box:GetText(), LINK, "Shift-клик по ссылке — в поле")
	box:SetFocus()
	A:CallHooks("ChatEdit_InsertLink", "[Предмет из сумки]")
	T.ok(box:GetText():find("[Предмет из сумки]", 1, true), "предмет из сумки — в поле")
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
	T.eq(f.scope:GetText(), "все гильдии объединения, /cz1", "шапка общего канала — с командой")
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
	-- Руководство: глава первой, левый щелчок ничего не делает, «Шёпот» из меню — в окне чата.
	local first = f.people[1]
	T.ok(first:IsShown() and first.person.name == "Вера Верная" and first.person.role == "leader", "глава первой")
	first.scripts.OnClick(first, "LeftButton")
	T.eq(B.ns.UI.Current(), "census", "левый щелчок остаётся в переписи")
	first.scripts.OnClick(first, "RightButton")
	local menu = B.ns.ChatPane.PersonMenu()
	T.ok(menu:IsShown(), "правый щелчок открывает меню")
	menu.whisper.scripts.OnClick(menu.whisper)
	T.eq(B.ns.UI.Current(), "chat", "«Шёпот» открывает чат")
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
