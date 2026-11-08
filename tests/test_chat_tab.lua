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
		return holder
	end
	return h, ns, env
end

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

T.test("chat tab: ввод в Chattynator отправляет в союз и возвращает штатную строку", function()
	local h, ns, env = BuildChattynator()
	h.client:ChatWindow(4, "Гильдия")
	T.ok(ns.Chat.SetWindow("Гильдия"))
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
	T.ok(ns.ChatTab.Open())
	h:Tick()
	T.eq(h.opened, 1)
	T.eq(ns.char.chatWindow, "Гильдия")
	T.eq(ns.char.chatTab, ns.L.CHAT_TAB_NAME)
	T.eq(ns.char.chatMirror, false)
	T.ok(h.box and h.box:IsShown())
	T.no(h.smileButton, "без Hepega кнопка смайликов не появляется")
	T.eq(h.client.bindings.ENTER, nil, "клавиша открытия игрового чата не меняется")

	ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "Проверка новой вкладки")
	T.eq(#h.tab.lines, 1, "строка видна во вкладке союза при выключенном дублировании")
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
