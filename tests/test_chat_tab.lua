-- Вкладка союза: штатное окно и отдельное поле ввода.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	local world = Wow.World()
	world:Guild("Чиллзон")
	local c = world:Client({ first = "Автор", surname = "Чата", guild = "Чиллзон" })
	local env, ns = c.env, c.ns
	local h = { client = c, opened = 0 }
	h.tab = c:ChatWindow(3, "", true)
	h.tab.editBox = env.CreateFrame("EditBox")
	h.tab.editBox.IsVisible = h.tab.editBox.IsShown
	h.tab.editBox.alpha = 0.35
	function h.tab.editBox.GetAlpha(self) return self.alpha end
	function h.tab.editBox.SetAlpha(self, alpha) self.alpha = alpha end
	h.tab.IsVisible = h.tab.IsShown
	env.ChatFrame3Tab = env.CreateFrame("Button")
	h.selected = env.ChatFrame1

	local create = env.CreateFrame
	env.CreateFrame = function(kind, name, parent, ...)
		local f = create(kind, name, parent, ...)
		f.shown = true
		function f.GetParent() return parent end
		function f.IsVisible(self)
			return self:IsShown() and (not parent or type(parent.IsVisible) ~= "function" or parent:IsVisible())
		end
		if kind == "EditBox" then
			h.box = f
			function f.ClearAllPoints(self)
				self.covered, self.below = nil, nil
			end
			function f.SetAllPoints(self, target) self.covered = target end
			function f.SetPoint(self, point, target, relativePoint)
				if point == "TOPLEFT" and relativePoint == "BOTTOMLEFT" then self.below = target end
			end
			function f:CreateFontString()
				local label = create("FontString")
				function label.GetStringWidth() return 50 end
				return label
			end
		elseif kind == "Button" and parent and parent == h.box then
			h.smileButton = f
		elseif kind == "ScrollingMessageFrame" then
			h.messages = f
		end
		return f
	end
	env.UIParent = env.UIParent or create("Frame")
	env.UIParent:Show()
	env.GameTooltip = { Hide = function() end }
	env.GENERAL_CHAT_DOCK = { IsVisible = function() return true end }
	env.FCFDock_GetSelectedWindow = function() return h.selected end
	env.FCF_SelectDockFrame = function(frame) h.selected = frame end
	env.FCF_OpenNewWindow = function(name, noDefaultChannels)
		h.opened = h.opened + 1
		T.ok(noDefaultChannels, "не включаем в новую вкладку обычные каналы")
		local frame = c:ChatWindow(3, name)
		frame.isDocked = true
		frame:Show()
		h.selected = frame
		return frame
	end
	function h:Tick()
		world:Run(0.2)
	end
	return h, ns, env
end

local function BuildChattynator()
	local h, ns, env = Build()
	h.registrations = 0
	env.Chattynator = { API = { RegisterCustomTab = function(label, id, install)
		h.registrations = h.registrations + 1
		T.eq(label, ns.L.CHAT_TAB_NAME)
		T.eq(id, "chillzone_union")
		h.install = install
	end } }
	h.client:Fire("ADDON_LOADED", "Chattynator")
	function h:Mount(windowID)
		local window = env.CreateFrame("Frame", nil, env.UIParent)
		function window.GetID() return windowID end
		local holder = env.CreateFrame("Frame", nil, window)
		self.install(holder)
		T.eq(#ns.db.errors, 0, ns.db.errors[1])
		return holder
	end
	return h, ns, env
end

-- Поведение штатного OpenChat: обычный Enter использует override, ввод со слэшем — поле WoW.
local function EnableFocusAPI(h, ns, env)
	local current
	local api = env.ChatFrameUtil
	api.SetChatFocusOverride = function(box) current = box end
	api.GetChatFocusOverride = function() return current end
	api.ClearChatFocusOverride = function() current = nil end
	api.OpenChat = function(text, frame)
		if not frame and current and (current.supportsSlashCommands or not text or text:sub(1, 1) ~= "/") then
			current:SetFocus()
			if text then current:SetText(text) end
			return
		end
		local native = env.ChatFrame1EditBox
		native:Show()
		native:SetFocus()
		native:SetText(text or "")
		env.ACTIVE_CHAT_EDIT_BOX = native
	end
	env.ChatFrame1.IsVisible = function() return true end
	env.ChatFrame1.GetFrameLevel = function() return 0 end
	function h:Select(frame)
		self.selected = frame
		self.client:CallHooks("FCF_SelectDockFrame", frame)
	end
	function h:CloseNative()
		env.ChatFrame1EditBox:ClearFocus()
		env.ChatFrame1EditBox:Hide()
		env.ACTIVE_CHAT_EDIT_BOX = nil
	end
	ns.Fire("SETTINGS")
	return api
end

T.test("chat input: Enter отправляет во всех выбранных вкладках, включая основную", function()
	local h, ns, env = Build()
	local first = h.client:ChatWindow(3, "Чиллзон")
	local second = h.client:ChatWindow(4, "Гильдия")
	local other = h.client:ChatWindow(5, "Торговля")
	first:Show(); second:Show(); other:Show()
	ns.Chat.SetWindow("Чиллзон")
	ns.Chat.ToggleWindow("Гильдия")
	ns.Chat.ToggleWindow("")
	local api, sent = EnableFocusAPI(h, ns, env), {}
	ns.Chat.Send = function(tier, text) sent[#sent + 1] = { tier, text }; return true end
	for _, frame in ipairs({ env.ChatFrame1, first, second }) do
		h:Select(frame)
		T.ok(h.box and api.GetChatFocusOverride() == h.box, "смена вкладки сразу обновляет адресата Enter")
		api.OpenChat("")
		T.ok(h.box:HasFocus())
		h.box:SetText("В союз")
		h.box.scripts.OnEnterPressed(h.box)
		T.same(sent[#sent], { "A", "В союз" })
	end
	T.eq(#sent, 3)
	h:Select(other)
	T.eq(api.GetChatFocusOverride(), nil, "невыбранная вкладка возвращает штатный Enter")
	api.OpenChat("")
	T.ok(env.ChatFrame1EditBox:HasFocus())
	T.eq(h.client.bindings.ENTER, nil, "бинды Enter не подменяются")
	h:CloseNative()
	h:Select(first)
	h.client.combat = true
	api.OpenChat("")
	T.ok(h.box:HasFocus(), "готовая строка принимает Enter и в бою")
	h.box:SetText("Из боя")
	h.box.scripts.OnEnterPressed(h.box)
	T.same(sent[4], { "A", "Из боя" })
	api.OpenChat("/cast Ледяная стрела")
	T.eq(env.ChatFrame1EditBox:GetText(), "/cast Ледяная стрела")
	T.ok(env.ChatFrame1EditBox:HasFocus(), "явная команда попала в штатное поле")
	T.eq(#sent, 4, "команда не ушла в союз")
	h:Tick()
	T.eq(api.GetChatFocusOverride(), nil, "ввод WoW с фокусом сохраняет управление")
	T.eq(#ns.db.errors, 0, ns.db.errors[1])
end)

T.test("chat input: снятие галочки, выход из союза и чужой override", function()
	local h, ns, env = Build()
	local first = h.client:ChatWindow(3, "Чиллзон")
	local second = h.client:ChatWindow(4, "Гильдия")
	first:Show(); second:Show()
	ns.Chat.SetWindow("Чиллзон")
	ns.Chat.ToggleWindow("Гильдия")
	local api = EnableFocusAPI(h, ns, env)
	h:Select(first)
	T.ok(api.GetChatFocusOverride())
	ns.Chat.ToggleWindow("Чиллзон")
	T.eq(api.GetChatFocusOverride(), nil, "снятие галочки действует сразу")
	h:Select(second)
	T.ok(api.GetChatFocusOverride())
	local box = h.box
	local foreign = env.CreateFrame("EditBox")
	api.SetChatFocusOverride(foreign)
	h:Tick()
	T.eq(api.GetChatFocusOverride(), foreign, "настройка другого аддона не перехватывается")
	ns.char.chatOn = false
	ns.Fire("SETTINGS")
	T.eq(api.GetChatFocusOverride(), foreign, "при отключении чужой override не очищается")
	ns.char.chatOn = true
	api.ClearChatFocusOverride()
	ns.Fire("SETTINGS")
	T.eq(api.GetChatFocusOverride(), box)
	ns.IsMember = function() return false end
	ns.Fire("UNION")
	T.eq(api.GetChatFocusOverride(), nil, "потеря доступа возвращает штатный Enter сразу")
	ns.IsMember = function() return true end
	ns.Fire("UNION")
	T.eq(api.GetChatFocusOverride(), box)
	h.client:Fire("PLAYER_LOGOUT")
	T.eq(api.GetChatFocusOverride(), nil)
	h:Tick()
	T.eq(api.GetChatFocusOverride(), nil, "таймер не возвращает перехват после выхода")
	T.eq(#ns.db.errors, 0, ns.db.errors[1])
end)

T.test("chat input: смена вкладки до таймера не отправляет старый черновик", function()
	local h, ns, env = Build()
	T.ok(ns.ChatTab.Open())
	local api = EnableFocusAPI(h, ns, env)
	h:Tick()
	local box, sent = h.box, 0
	api.OpenChat("")
	box:SetText("Черновик")
	ns.Chat.Send = function() sent = sent + 1; return true end
	h.selected = env.ChatFrame2
	box.scripts.OnEnterPressed(box)
	T.eq(sent, 0)
	T.eq(api.GetChatFocusOverride(), nil)
	T.eq(box:GetText(), "Черновик")
	T.eq(#ns.db.errors, 0, ns.db.errors[1])
end)

T.test("chat input: выбранные вкладки Chattynator направляют Enter в союз", function()
	local h, ns, env = BuildChattynator()
	local api = env.Chattynator.API
	env.GUILD = "Гильдия"
	api.GetWindowsAndTabs = function() return { { "GENERAL", "GUILD" }, { "Торговля", "Союз" } } end
	api.AddMessageToWindowAndTab = function() end
	local handler = env.CreateFrame("Frame")
	local function Window(id)
		local window = env.CreateFrame("Frame", nil, handler)
		window.tabIndex = 1
		function window.GetID() return id end
		function window.SetTabSelectedAndFilter(self, index) self.tabIndex = index end
		function window.SetTabSelectedOnly(self, index) self.tabIndex = index end
		local wrapper = env.CreateFrame("Frame", nil, window)
		window.ScrollingMessages = env.CreateFrame("Frame", nil, wrapper)
		return window
	end
	local first, second = Window(1), Window(2)
	function handler.GetChildren() return first, second end
	api.GetHyperlinkHandler = function() return handler end
	ns.Chat.SetWindow("Гильдия")
	ns.Chat.ToggleWindow("Союз")
	local focus = EnableFocusAPI(h, ns, env)
	local sent = {}
	ns.Chat.Send = function(tier, text) sent[#sent + 1] = { tier, text }; return true end
	first:SetTabSelectedAndFilter(2)
	T.ok(h.box and focus.GetChatFocusOverride() == h.box, "обычная выбранная вкладка, не специальная")
	focus.OpenChat("")
	h.box:SetText("Из гильдии")
	h.box.scripts.OnEnterPressed(h.box)
	T.same(sent, { { "A", "Из гильдии" } })
	second:SetTabSelectedAndFilter(2)
	T.eq(focus.GetChatFocusOverride(), h.box, "ввод переключился в выбранную вкладку второго окна")
	focus.OpenChat("")
	h.box:SetText("Из второго окна")
	h.box.scripts.OnEnterPressed(h.box)
	T.same(sent[2], { "A", "Из второго окна" })
	second:SetTabSelectedAndFilter(1)
	T.eq(focus.GetChatFocusOverride(), nil, "посторонняя вкладка второго окна сохраняет штатный Enter")
	first:SetTabSelectedAndFilter(1)
	T.eq(focus.GetChatFocusOverride(), nil)
	ns.Chat.ToggleWindow("")
	T.eq(focus.GetChatFocusOverride(), h.box, "основная вкладка Chattynator тоже выбирается для ввода")
	T.eq(#ns.db.errors, 0, ns.db.errors[1])
end)

T.test("chat input: ПКМ по метке работает внутри специальной вкладки Chattynator", function()
	local h, ns = BuildChattynator()
	h:Mount(1)
	h.messages.scripts.OnHyperlinkClick(h.messages, ns.Chat.TAG_LINK .. "A", "[Чиллзон]", "RightButton")
	T.ok(ns.UI.TagMenu():IsShown())
	T.eq(h.opened, 0, "ПКМ пока только открывает меню")
	T.no(ns.Chat.CreateWindow(), "нативное окно не создаётся за скрытым чатом Chattynator")
	T.eq(h.opened, 0)
	T.eq(#ns.db.errors, 0, ns.db.errors[1])
end)

T.test("chat tab: копия союза идёт в выбранную вкладку Chattynator", function()
	local h, ns, env = BuildChattynator()
	local native = h.client:ChatWindow(4, "Гильдия")
	ns.char.chatWindow = "Гильдия" -- Сохранённый выбор из штатного чата.
	ns.char.chatWindows = nil
	ns.char.chatMirror = true
	env.GUILD = "Гильдия"
	local tabs = { { "GENERAL", ns.L.CHAT_TAB_NAME }, { "GUILD" } }
	local delivered = {}
	local api = env.Chattynator.API
	api.GetWindowsAndTabs = function() return tabs end
	api.AddMessageToWindowAndTab = function(window, tab, line, r, g, b)
		delivered[#delivered + 1] = { window, tab, line, r, g, b }
	end
	h:Mount(1)
	local function Show(message)
		ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", message)
	end
	Show("Копия союза")
	local line = ns.Chat.Format("A", "Чиллзон", "Автор Чата", "MAGE", "Копия союза")
	T.same(delivered, { { 2, 1, line, ns.Chat.Color("A") } })
	T.eq(#native.lines, 0)
	T.eq(h.client:Saw("Копия союза"), 0)
	T.same(h.messages.lines, { line })
	T.eq(#ns.Chat.History("A"), 1)
	T.ok(ns.Chat.SetWindow("GUILD"))
	T.same(ns.Chat.SelectedWindows(), { "Гильдия" })
	T.no(ns.Chat.SetWindow(ns.L.CHAT_TAB_NAME), "специальная вкладка получает строки отдельно")

	ns.char.chatMirror = false
	Show("Только специальная вкладка")
	T.eq(#delivered, 1)
	T.eq(#h.messages.lines, 2)

	ns.char.chatMirror = true
	tabs[2] = nil
	Show("Вкладка закрыта")
	T.eq(#delivered, 1)
	T.eq(h.client:Saw("Вкладка закрыта"), 1, "при закрытии вкладки копия идёт в основное окно")
	T.eq(#native.lines, 0)
	T.eq(#h.messages.lines, 3)
end)

T.test("chat tab: несколько вкладок Chattynator получают чат и историю, журнал остаётся отдельным", function()
	local h, ns, env = BuildChattynator()
	env.GUILD = "Гильдия"
	local tabs = { { "GENERAL", "GUILD", ns.L.CHAT_TAB_NAME }, { "Торговля" } }
	local delivered = {}
	local api = env.Chattynator.API
	api.GetWindowsAndTabs = function() return tabs end
	api.AddMessageToWindowAndTab = function(window, tab, line)
		T.ok(debug.getinfo(2, "S").source:find("Chillzone/Chat.lua", 1, true), "источник для фильтров Chattynator — Chillzone")
		delivered[#delivered + 1] = { window, tab, line }
	end
	T.ok(ns.Chat.SetWindow("Гильдия"))
	T.ok(ns.Chat.ToggleWindow("Торговля"))
	ns.UI.Toggle("settings")
	local p = ns.UI.picker
	T.eq(p.button:GetText(), "Выбрано вкладок: 2")
	p.button.scripts.OnClick(p.button)
	T.eq(p.items[3].text:GetText(), "Гильдия")
	T.ok(p.items[3].check:IsShown())
	T.eq(p.items[4].text:GetText(), "Торговля")
	T.ok(p.items[4].check:IsShown())
	T.no(p.items[5] and p.items[5]:IsShown(), "специальная вкладка не дублируется в списке")
	T.ok(ns.Chat.ToggleWindow("GUILD"), "ключ Chattynator снимает выбранную вкладку")
	T.same(ns.Chat.SelectedWindows(), { "Торговля" })
	T.ok(ns.Chat.ToggleWindow("GUILD"))
	T.same(ns.Chat.SelectedWindows(), { "Торговля", "Гильдия" })
	ns.char.chatTime = true
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Во все выбранные")
	local line = "|cff999999" .. env.date("%H:%M", ns.ServerTime()) .. "|r "
		.. ns.Chat.Format("A", "Чиллзон", "Автор Чата", "MAGE", "Во все выбранные")
	T.same(delivered, { { 2, 1, line }, { 1, 2, line } })
	T.eq(h.client:Saw("Во все выбранные"), 0)
	h.client:Slash("/chillzone", "history 1")
	T.same(delivered[3], delivered[1])
	T.same(delivered[4], delivered[2])
	ns.char.chatMirror = false
	local printedBefore = #h.client.printed
	ns.Diagnostics.SetEnabled(true)
	ns.Log("Журнал союза")
	T.eq(#delivered, 4, "запись журнала не попадает во вкладки Chattynator")
	T.eq(#h.client.printed, printedBefore, "запись журнала не попадает в штатный чат")
	ns.Diagnostics.SetEnabled(false)
	ns.db.errors = { "Сохранённая ошибка" }
	h.client:Slash("/chillzone", "log 1")
	T.eq(ns.UI.Current(), "journal", "команда открывает отдельный журнал")
	local journal = ns.JournalPane.frames
	journal.copy.scripts.OnClick(journal.copy)
	T.ok(journal.box:GetText():find("Журнал союза", 1, true), "отчёт содержит запись")
	T.ok(journal.box:GetText():find("Сохранённая ошибка", 1, true), "отчёт содержит сохранённую ошибку")
	T.eq(#delivered, 4, "команда log не выводит отчёт в Chattynator")
	T.eq(#h.client.printed, printedBefore, "команда log не выводит отчёт в штатный чат")
	ns.db.errors = {}

	ns.char.chatMirror = true
	tabs[2] = nil
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Оставшаяся вкладка")
	T.eq(delivered[#delivered][1], 1)
	T.eq(h.client:Saw("Оставшаяся вкладка"), 0)
	ns.UI.Toggle("settings")
	p.button.scripts.OnClick(p.button)
	T.eq(p.items[4].text:GetText(), "|cffff6060«Торговля» закрыта|r")
	p.items[4].scripts.OnClick(p.items[4])
	T.same(ns.Chat.SelectedWindows(), { "Гильдия" })
	T.no(p.items[4]:IsShown())
	T.eq(#ns.db.errors, 0)
end)

T.test("chat tab: защиты Chattynator исключают журнал боя и вкладку поиска", function()
	local h, ns, env = BuildChattynator()
	env.GENERAL, env.COMBAT_LOG = "Общая", "Журнал боя"
	local search = "|TInterface\\Icons\\INV_Misc_Spyglass_03:0|t"
	local api = env.Chattynator.API
	api.GetWindowsAndTabs = function() return { { "GENERAL", "COMBAT_LOG", search, ns.L.CHAT_TAB_NAME, "Торговля" }, { "Гильдия" } } end
	api.AddMessageToWindowAndTab = function() error("служебная вкладка не должна получать строки") end
	local windows = ns.Chat.MirrorWindows()
	T.eq(#windows, 3, "в списке только обычные вкладки")
	T.eq(windows[1].name, "Общая")
	T.eq(windows[2].name, "Торговля")
	T.eq(windows[2].window, 1)
	T.eq(windows[2].tab, 5, "индексы API не меняются после фильтрации")
	T.eq(windows[3].name, "Гильдия")
	T.eq(windows[3].window, 2)
	T.eq(windows[3].tab, 1)
	for i, name in ipairs({ "COMBAT_LOG", "Журнал боя", search }) do
		T.no(ns.Chat.SetWindow(name), "служебная вкладка не выбирается: " .. name)
		ns.char.chatWindows = { name } -- Выбор, сохранённый до добавления защиты.
		ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Запасной вывод " .. i)
		T.eq(h.client:Saw("Запасной вывод " .. i), 1)
	end
	T.eq(#ns.db.errors, 0)
end)

T.test("chat tab: защиты Chattynator сохраняют строку при ошибке API", function()
	local h, ns, env = BuildChattynator()
	local api, delivered, fallback = env.Chattynator.API, {}, {}
	api.GetWindowsAndTabs = function() return { { "Гильдия", "Торговля" } } end
	local failing = true
	api.AddMessageToWindowAndTab = function(window, tab, line)
		local caller = debug.getinfo(2, "S")
		T.eq(caller.what, "Lua")
		T.ok(caller.source:find("Chillzone/Chat.lua", 1, true), "источник строки сохранён для фильтров")
		if failing == true or failing == tab then error("Chattynator ещё не готов") end
		delivered[#delivered + 1] = { window, tab, line }
	end
	local original = env.DEFAULT_CHAT_FRAME.AddMessage
	env.DEFAULT_CHAT_FRAME.AddMessage = function(frame, ...)
		fallback[#fallback + 1] = { ... }
		original(frame, ...)
	end
	T.ok(ns.Chat.SetWindow("Гильдия"))
	ns.char.chatTime = true
	local function Show(text)
		ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", text)
	end
	Show("Ошибка одной вкладки")
	local stamp = "|cff999999" .. env.date("%H:%M", ns.ServerTime()) .. "|r "
	local line = stamp .. ns.Chat.Format("A", "Чиллзон", "Автор Чата", "MAGE", "Ошибка одной вкладки")
	T.same(fallback, { { line, ns.Chat.Color("A") } }, "в основное окно приходит вся строка с цветом и временем")
	T.ok(ns.Chat.ToggleWindow("Торговля"))
	Show("Ошибка двух вкладок")
	T.eq(h.client:Saw("Ошибка двух вкладок"), 1, "несколько ошибок не создают дубли")
	T.ok(ns.Chat.ToggleWindow(""))
	Show("Основное тоже выбрано")
	T.eq(h.client:Saw("Основное тоже выбрано"), 1)
	ns.char.chatWindows = { "", "Гильдия", "Торговля" }
	Show("Основное выбрано первым")
	T.eq(h.client:Saw("Основное выбрано первым"), 1)
	T.same(ns.Chat.SelectedWindows(), { "", "Гильдия", "Торговля" }, "ошибка не сбрасывает выбор")

	ns.char.chatWindows = { "Гильдия", "Торговля" }
	h.client:Slash("/chillzone", "history 1")
	T.eq(h.client:Saw("Ошибка одной вкладки"), 2, "каждая строка истории тоже сохраняется")
	T.eq(h.client:Saw("Ошибка двух вкладок"), 2)
	T.eq(h.client:Saw("Основное тоже выбрано"), 2)
	T.eq(h.client:Saw("Основное выбрано первым"), 2)
	local failures = 0
	for _, record in ipairs(ns.db.log) do
		if record:find("Chattynator не принял строку", 1, true) then failures = failures + 1 end
	end
	T.eq(failures, 1, "ошибка API записывается один раз за сеанс")
	T.eq(#ns.db.errors, 0, "временная ошибка API не считается ошибкой Chillzone")

	failing = false
	Show("API восстановился")
	T.eq(#delivered, 2, "обе выбранные вкладки снова получают строку")
	T.eq(h.client:Saw("API восстановился"), 0)
	failing = 2
	Show("Ошибка только второй вкладки")
	T.eq(#delivered, 3, "исправная вкладка продолжает получать строки")
	T.eq(delivered[3][2], 1)
	T.eq(h.client:Saw("Ошибка только второй вкладки"), 1)
	ns.char.chatMirror = false
	failing = true
	Show("Копии выключены")
	T.eq(h.client:Saw("Копии выключены"), 0)
	T.eq(#delivered, 3)
end)

T.test("chat tab: время видно в специальной вкладке Chattynator и её истории", function()
	local h, ns, env = BuildChattynator()
	ns.char.chatMirror = false
	ns.char.chatTime = true
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Из истории")
	h:Mount(1)
	local prefix = "|cff999999" .. env.date("%H:%M", ns.ServerTime()) .. "|r "
	T.eq(h.messages.lines[1]:sub(1, #prefix), prefix)
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Новая строка")
	T.eq(h.messages.lines[2]:sub(1, #prefix), prefix)
	ns.char.chatTime = false
	ns.Fire("SETTINGS")
	T.no(h.messages.lines[1]:sub(1, #prefix) == prefix)
	T.no(h.messages.lines[2]:sub(1, #prefix) == prefix)
	T.eq(#ns.db.errors, 0)
end)

T.test("chat tab: метка союза фокусирует ввод в штатной вкладке", function()
	local h, ns = Build()
	ns.ChatTab.Open()
	h:Tick()
	local box = h.box
	box:SetText("Черновик союза")
	h.client:CallHooks("SetItemRef", ns.Chat.TAG_LINK .. "A", "[Чиллзон]", "RightButton", h.tab)
	T.no(box:HasFocus())
	h.client:CallHooks("SetItemRef", ns.Chat.TAG_LINK .. "A", "[Чиллзон]", "LeftButton", h.tab)
	T.ok(box:HasFocus())
	T.eq(box:GetText(), "Черновик союза")
	T.no(ns.UI.Current(), "окно аддона не открывается поверх вкладки")

	local tier, focused
	ns.UI.OpenChat = function(channel, focus) tier, focused = channel, focus end
	box:ClearFocus()
	h.client:CallHooks("SetItemRef", ns.Chat.TAG_LINK .. "C", "[Чиллзон]", "LeftButton", h.tab)
	T.eq(tier, "C", "закрытый канал открывается в своём окне")
	T.ok(focused)
	T.no(box:HasFocus())
end)

T.test("chat tab: метка союза фокусирует ввод в Chattynator", function()
	local h, ns = BuildChattynator()
	h:Mount(1)
	h:Tick()
	local box, messages = h.box, h.messages
	local click = messages.scripts.OnHyperlinkClick
	box:SetText("Черновик союза")
	click(messages, ns.Chat.TAG_LINK .. "A", "[Чиллзон]", "RightButton")
	click(messages, ns.Chat.TAG_LINK .. "AA", "[Чиллзон]", "LeftButton")
	T.no(box:HasFocus())
	click(messages, ns.Chat.TAG_LINK .. "A", "[Чиллзон]", "LeftButton")
	T.ok(box:HasFocus())
	T.eq(box:GetText(), "Черновик союза")
	T.no(ns.UI.Current(), "окно аддона не открывается поверх вкладки")
end)

T.test("chat tab: специальная вкладка Chattynator показывает историю и новые строки со смайлами", function()
	local h, ns, env = BuildChattynator()
	T.ok(ns.ChattynatorTab.Available())
	h.client:Fire("ADDON_LOADED", "Chattynator")
	T.eq(h.registrations, 1)
	local emote = { frames = 2 }
	local markup = "|TInterface\\AddOns\\Hepega\\HYPE.tga:18:18|t"
	local hepega = {
		VERSION = "0.9.0", DB = { enabled = true }, Lookup = { HYPE = emote, HIDDEN = {} },
		IsEnabled = function(_, name) return name ~= "HIDDEN" end,
		GetChatEmoteSize = function(_, frame)
			T.eq(frame, h.messages)
			return 18
		end,
		GetEmoteMarkup = function(_, entry, size, frame)
			T.eq(entry, emote)
			T.eq(size, 18)
			T.eq(frame, 0)
			return markup
		end,
	}
	env.ForeverSmileChat = hepega
	local link = "|cff1eff00|Hitem:25|h[HYPE монета]|h|r"
	local body = "HYPE " .. link .. " HYPE, HIDDEN |Tfake|t"
	local function Show()
		ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", body)
	end
	ns.char.chatMirror = false
	Show()
	ns.Chat.Show("C", "Чиллзон", "Автор Чата", "MAGE", "Офицерская строка")
	local holder = h:Mount(1)
	local panel = ns.ChattynatorTab.ActiveHost()
	T.ok(panel and panel:IsVisible())
	T.eq(#h.messages.lines, 1)
	ns.char.chatMirror = true
	Show()
	local messages = h.messages.lines
	local rendered = markup .. " " .. link .. " HYPE, HIDDEN ||Tfake||t"
	T.eq(#messages, 2)
	T.eq(messages[1]:sub(-#rendered), rendered)
	T.eq(messages[2], messages[1])
	T.eq(ns.Chat.History("A")[2].x, body)
	local native = h.client.printed
	T.eq(native[#native], ns.Chat.Format("A", "Чиллзон", "Автор Чата", "MAGE", body))
	holder:Hide()
	T.no(ns.ChattynatorTab.ActiveHost())
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Пока вкладка скрыта")
	holder:Show()
	h.install(holder)
	messages = h.messages.lines
	T.eq(#messages, 3, "при возврате обновляем историю без повторов")
	T.ok(messages[3]:find("Пока вкладка скрыта", 1, true))
	hepega.DB.enabled = false
	Show()
	T.eq(messages[4], native[#native])
	hepega.DB.enabled = true
	hepega.GetEmoteMarkup = function() error("Hepega unavailable") end
	Show()
	T.eq(messages[5], native[#native])
	T.eq(#ns.db.errors, 0)
end)

T.test("chat tab: Chattynator обновляет историю при изменении доступа к союзу", function()
	local h, ns = BuildChattynator()
	local member = true
	ns.IsMember = function() return member end
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Строка истории")
	h:Mount(1)
	local messages = h.messages
	local line = messages.lines[1]
	T.ok(line and line:find("Строка истории", 1, true))
	local scrolls = 0
	function messages.ScrollToBottom() scrolls = scrolls + 1 end

	ns.Fire("UNION")
	T.same(messages.lines, { line })
	T.eq(scrolls, 0, "продление решения не сбрасывает прокрутку")

	member = false
	ns.Fire("UNION")
	T.same(messages.lines, { ns.L.CHAT_TAB_NOT_MEMBER })
	T.eq(scrolls, 1, "история скрыта сразу")
	ns.Fire("UNION")
	T.eq(scrolls, 1)

	member = true
	ns.Fire("UNION")
	T.same(messages.lines, { line })
	T.eq(scrolls, 2, "история возвращается сразу")
end)

T.test("chat tab: ввод в Chattynator отправляет в союз и возвращает штатную строку", function()
	local h, ns, env = BuildChattynator()
	ns.char.chatWindow = "Гильдия"
	ns.char.chatMirror = false
	ns.ChatTab.Open()
	local native = env.ChatFrame1EditBox
	native.IsVisible = native.IsShown
	native.alpha = 0.35
	function native.GetAlpha(self) return self.alpha end
	function native.SetAlpha(self, alpha) self.alpha = alpha end
	native:SetText("Черновик игры")
	native:Show()
	local holder = h:Mount(1)
	h:Tick()
	local box, sent = h.box, {}
	T.ok(box and box:IsShown())
	T.eq(native:GetAlpha(), 0, "в основном окне видна только строка союза")
	ns.Chat.Send = function(tier, message)
		sent[#sent + 1] = { tier, message }
		return true
	end
	box:SetFocus()
	box:SetText("Ищу хила")
	box.scripts.OnEnterPressed(box)
	T.same(sent, { { "A", "Ищу хила" } })
	T.eq(box:GetText(), "")

	local messages = h.messages
	local click = messages.scripts.OnHyperlinkClick
	local item = "|cffffffff|Hitem:25|h[Меч]|h|r"
	T.ok(click, "специальная вкладка обрабатывает щелчки по ссылкам")
	T.eq(env.ChatFrameUtil.InsertLink(item), false, "пост-хук не меняет ответ игры")
	T.eq(box:GetText(), "", "ввод без фокуса не принимает ссылку из сумки")
	box:SetFocus()
	T.eq(env.ChatFrameUtil.InsertLink(item), false)
	T.eq(box:GetText(), item, "предмет из сумки вставляется один раз")
	box:SetText("")
	box:ClearFocus()
	h.client.shift = true
	click(messages, "item:25", item, "LeftButton")
	h.client.shift = false
	T.eq(box:GetText(), item, "Shift-клик по ссылке переносит её в поле союза")
	T.ok(box:HasFocus())
	local inspected
	env.ItemRefTooltip = env.CreateFrame("GameTooltip")
	env.ItemRefTooltip.ItemRefSetHyperlink = function(_, link) inspected = link end
	click(messages, "item:25", item, "LeftButton")
	T.eq(inspected, "item:25", "обычный щелчок открывает подсказку предмета")
	T.eq(box:GetText(), item)

	local menus, whispers = {}, {}
	env.FriendsFrame_ShowDropdown = function(name, connected) menus[#menus + 1] = { name, connected } end
	env.SendChatMessage = function(message, channel, _, target)
		whispers[#whispers + 1] = { message, channel, target }
	end
	local player = "player:Глеб Гордый"
	click(messages, player, "[Глеб Гордый]", "RightButton")
	T.same(menus, { { "Глеб Гордый", 1 } })
	T.eq(box:GetText(), item, "ПКМ открывает меню и сохраняет черновик")
	click(messages, player, "[Глеб Гордый]", "LeftButton")
	T.eq(box:GetText(), "/w Глеб Гордый ", "ЛКМ подготавливает шёпот в поле союза")
	T.ok(box:HasFocus())
	box:Insert("Привет")
	box.scripts.OnEnterPressed(box)
	T.same(whispers, { { "Привет", "WHISPER", "Глеб Гордый" } })
	T.eq(#sent, 1, "личное сообщение не попадает в общий канал")
	T.eq(box:GetText(), "")

	box:SetFocus()
	box:SetText("Черновик союза")
	holder:Hide()
	T.eq(env.ChatFrameUtil.InsertLink(item), false)
	T.eq(box:GetText(), "Черновик союза", "скрытая вкладка не принимает ссылку из сумки")
	box.scripts.OnUpdate(box)
	T.no(box:IsShown())
	T.eq(native:GetAlpha(), 0.35)
	T.eq(native:GetText(), "Черновик игры")
	h:Mount(2)
	h:Tick()
	T.ok(box:IsShown())
	T.eq(native:GetAlpha(), 0.35, "отдельное окно не меняет строку основного")
	T.eq(h.opened, 0, "штатную вкладку при активном Chattynator не создаём")
	T.eq(ns.char.chatWindow, "Гильдия")
	T.eq(ns.char.chatMirror, false)
	T.no(ns.char.chatTab)
	T.eq(#ns.db.errors, 0)
end)

T.test("chat tab: кнопка доступна прямо в общем канале Chillzone", function()
	local h, ns = Build()
	ns.UI.OpenChat("G", false)
	local button = ns.ChatPane.frames.openTab
	T.ok(button)
	T.no(button:IsShown())
	ns.ChatPane.Select("A")
	T.ok(button:IsShown())
	h.client.combat = true
	button.scripts.OnClick(button)
	T.eq(ns.UI.Current(), "chat", "при отказе остаёмся в текущем окне")
	h.client.combat = false
	button.scripts.OnClick(button)
	T.eq(h.opened, 1)
	T.eq(ns.UI.Current(), nil, "переход к игровой вкладке закрывает большое окно")
end)

T.test("chat tab: видна одна строка, штатная возвращается при фокусе и смене вкладки", function()
	local h, ns, env = Build()
	local native = h.tab.editBox
	native:Show()
	T.ok(ns.ChatTab.Open())
	h:Tick()
	local box = h.box
	T.ok(box:IsShown())
	T.eq(box.covered, native)
	T.ok(native:IsShown(), "штатное поле остаётся готовым принять фокус")
	T.eq(native:GetAlpha(), 0, "не рисуем штатную строку под полем союза")
	box:SetText("Черновик")
	native:SetFocus()
	native:SetAlpha(1) -- WoW обновляет видимость поля при фокусе.
	box.scripts.OnUpdate(box)
	T.no(box:IsShown(), "поле союза уступает место штатному вводу с фокусом")
	T.ok(native:HasFocus())
	T.eq(native:GetAlpha(), 1, "не подменяем новую прозрачность от игры")
	native:ClearFocus()
	native:SetAlpha(0.35)
	h:Tick()
	T.ok(box:IsShown())
	T.eq(native:GetAlpha(), 0)
	h.selected = env.ChatFrame1
	box.scripts.OnUpdate(box)
	T.no(box:IsShown())
	T.eq(native:GetAlpha(), 0.35, "уход со вкладки восстанавливает исходную прозрачность")
	h.selected = h.tab
	native:Hide()
	h:Tick()
	T.ok(box:IsShown())
	T.eq(rawget(box, "covered"), nil)
	T.eq(box.below, h.tab)
	T.eq(box:GetText(), "Черновик")
	native:Show()
	function native.SetAlpha() end -- Клиент не применил изменение прозрачности.
	h:Tick()
	T.no(box:IsShown(), "если штатную строку не удалось скрыть, второй строки нет")
	T.eq(native:GetAlpha(), 0.35)
end)

T.test("chat tab: открытие вкладки не меняет настройки дублирования", function()
	local h, ns, env = Build()
	h.client:ChatWindow(4, "Гильдия")
	T.ok(ns.Chat.SetWindow("Гильдия"))
	ns.char.chatMirror = false
	ns.char.chatTime = true
	T.ok(ns.ChatTab.Open())
	h:Tick()
	T.eq(h.opened, 1)
	T.same(ns.Chat.SelectedWindows(), { "Гильдия" })
	T.eq(ns.char.chatTab, ns.L.CHAT_TAB_NAME)
	T.eq(ns.char.chatMirror, false)
	T.ok(h.box and h.box:IsShown())
	T.no(h.smileButton, "без Hepega кнопка смайликов не появляется")
	T.eq(h.client.bindings.ENTER, nil, "клавиша открытия игрового чата не меняется")

	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Проверка новой вкладки")
	T.eq(#h.tab.lines, 1, "строка видна во вкладке союза при выключенном дублировании")
	local prefix = "|cff999999" .. env.date("%H:%M", ns.ServerTime()) .. "|r "
	T.eq(h.tab.lines[1]:sub(1, #prefix), prefix)
	T.ok(h.tab.lines[1]:find("Проверка новой вкладки", 1, true))
	T.eq(#env.ChatFrame4.lines, 0)
	T.eq(h.client:Saw("Проверка новой вкладки"), 0)
	h.selected = env.ChatFrame1
	T.ok(ns.ChatTab.Open())
	T.eq(h.opened, 1, "повторное нажатие не создаёт вторую вкладку")
	T.eq(h.selected, h.tab)
end)

T.test("chat tab: смайлик из окна Hepega попадает только в активную вкладку союза", function()
	local h, ns, env = Build()
	local native = env.ChatFrame1EditBox
	native:Show()
	native:SetText("Штатный черновик")
	local picker = env.CreateFrame("Frame", "ForeverSmileChatPicker", env.UIParent)
	picker:Hide()
	local original = function() return native end
	local smile = {
		VERSION = "0.9.0",
		PATH = "Interface\\AddOns\\HepegaTeamSmileChatWowForever\\",
		DB = { enabled = true },
		GetActiveEditBox = original,
		TogglePicker = function() picker:SetShown(not picker:IsShown()) end,
	}
	env.ForeverSmileChat = smile
	env.ForeverSmileChatPicker = picker
	-- Повторяем выбор адресата и вставку из установленного Picker.lua.
	local function pick()
		local target = smile:GetActiveEditBox()
		if not target or not target:IsShown() then target = native end
		target:SetFocus()
		target:Insert("peepoAlliance ")
	end

	T.ok(ns.ChatTab.Open())
	h:Tick()
	local box, button = h.box, h.smileButton
	T.ok(button and button:IsShown())
	T.eq(smile.GetActiveEditBox, original, "штатный выбор поля не меняется до открытия окна")
	button.scripts.OnClick(button)
	T.ok(picker:IsShown())
	pick()
	T.eq(box:GetText(), "peepoAlliance ")
	T.eq(native:GetText(), "Штатный черновик")
	picker:Hide()
	T.eq(smile.GetActiveEditBox, original, "закрытие окна восстанавливает штатный выбор поля")

	button.scripts.OnClick(button)
	T.ok(picker:IsShown())
	h.selected = env.ChatFrame1
	pick() -- Щелчок по смайлику до следующего обновления поля.
	T.eq(box:GetText(), "peepoAlliance ")
	T.eq(native:GetText(), "Штатный черновик", "устаревший выбор не попадает в обычный чат")
	box.scripts.OnUpdate(box)
	T.no(picker:IsShown())
	T.eq(smile.GetActiveEditBox, original)
	T.eq(#ns.db.errors, 0)
end)

T.test("chat tab: строки идут в две открытые вкладки без повторов внутри одной", function()
	local h, ns = Build()
	local guildTab = h.client:ChatWindow(4, "Гильдия")
	T.ok(ns.Chat.SetWindow("Гильдия"))
	ns.char.chatMirror = true
	ns.db.settings.chatColor = "ffb347"
	T.ok(ns.ChatTab.Open())
	h.selected = guildTab
	h.tab:Hide()
	h.client.windows[3].shown = false -- Вкладка не выбрана, но по-прежнему в панели.

	local history = ns.Chat.History("A")
	local before = #history
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Строка для двух вкладок")
	T.eq(#h.tab.lines, 1)
	T.eq(#guildTab.lines, 1)
	T.eq(h.tab.lines[1], guildTab.lines[1])
	T.same(h.tab.color, { 1, 179 / 255, 71 / 255 }, "вкладка союза использует выбранный цвет")
	T.same(guildTab.color, h.tab.color, "копия использует тот же цвет")
	T.eq(#history, before + 1)

	T.ok(ns.Chat.SetWindow(ns.L.CHAT_TAB_NAME))
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Строка без повтора")
	T.eq(#h.tab.lines, 2, "совпавшие назначения дают только одну строку")
	T.eq(#guildTab.lines, 1)
	T.eq(#history, before + 2)

	h.client:ChatWindow(3, ns.L.CHAT_TAB_NAME, true)
	h.tab.isDocked = nil
	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Строка после закрытия")
	T.eq(#h.tab.lines, 2, "в закрытую вкладку строка не идёт")
	T.eq(h.client:Saw("Строка после закрытия"), 1, "настройка вывода использует прежний запасной вариант")
end)

T.test("chat tab: не перезаписывает занятое окно и не меняет настройки в бою", function()
	local h, ns, env = Build()
	local c = h.client
	c:ChatWindow(3, "Торговля")
	ns.char.chatMirror = false
	T.no(ns.ChatTab.Open())
	T.eq(h.opened, 0)
	T.eq(c.windows[3].name, "Торговля")
	c:ChatWindow(3, "", true)
	c.combat = true
	T.no(ns.ChatTab.Open())
	T.eq(h.opened, 0)
	c.combat = false
	env.FCF_OpenNewWindow = nil
	T.no(ns.ChatTab.Open())
	T.eq(h.opened, 0)
	T.no(ns.char.chatWindow)
	T.no(ns.char.chatTab)
	T.no(ns.char.chatMirror)
end)

T.test("chat tab: простой текст идёт в союз только из выбранной вкладки", function()
	local h, ns, env = Build()
	T.ok(ns.ChatTab.Open())
	ns.char.chatMirror = false
	h:Tick()
	local box, sent, accept = h.box, {}, false
	ns.Chat.Send = function(tier, message)
		sent[#sent + 1] = { tier, message }
		return accept
	end
	box:SetFocus()
	box:SetText("Ищу хила в тюрьму")
	box.scripts.OnEnterPressed(box)
	T.same(sent[1], { "A", "Ищу хила в тюрьму" })
	T.eq(box:GetText(), "Ищу хила в тюрьму", "ошибка отправки сохраняет текст")

	h.selected = env.ChatFrame1
	-- Переключение ещё не заметил таймер, но Enter уже не должен отправлять.
	box.scripts.OnEnterPressed(box)
	T.eq(#sent, 1)
	h:Tick()
	T.no(box:IsShown())
	T.no(box:HasFocus())
	h.selected = h.tab
	h:Tick()
	T.ok(box:IsShown())
	T.eq(box:GetText(), "Ищу хила в тюрьму")

	accept = true
	box:SetFocus()
	box.scripts.OnEnterPressed(box)
	T.eq(#sent, 2)
	T.same(sent[2], { "A", "Ищу хила в тюрьму" })
	T.eq(box:GetText(), "")
	T.eq(env.ChatFrame1EditBox:GetText(), "", "штатный ввод не используется")
	T.eq(#ns.db.errors, 0)
end)
