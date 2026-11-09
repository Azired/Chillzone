-- Настройки общего чата в панели каналов игры: только свои кадры и свои данные.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	local w = Wow.World()
	local c = w:Client({ first = "Автор", surname = "Чата" })
	return c
end

local function Panel(c)
	local env = c.env
	local panel = env.CreateFrame("Frame")
	panel:Show()
	local list = env.CreateFrame("Frame")
	local background = env.CreateFrame("Frame")
	list.GetWidth = function() return 530 end
	list.GetBottom = function() return 300 end
	background.GetBottom = function() return 40 end
	-- Изменять игровые кадры и их обработчики запрещено даже при установке.
	for _, f in ipairs({ panel, list, background }) do
		f.SetScript = function() error("запись в игровой обработчик") end
		f.HookScript = function() error("хук игрового обработчика") end
		f.SetPoint = function() error("перестановка игрового кадра") end
	end
	env.ChatConfigChannelSettings = panel
	env.ChatConfigChannelSettingsLeft = list
	env.ChatConfigBackgroundFrame = background
	for _, key in ipairs({ "ChatConfigChannelSettings", "ChatConfigChannelSettingsLeft", "ChatConfigBackgroundFrame" }) do
		c.stubs[key] = true
	end
	c.currentChatFrame = env.DEFAULT_CHAT_FRAME
	c:Fire("ADDON_LOADED", "Blizzard_ChatFrame")
	return panel, list, background
end

local function Tick(c)
	local config = c.ns.ChatConfig
	T.ok(config, "модуль настроек загружен")
	T.ok(config.watcher, "наблюдатель создан")
	config.watcher:GetScript("OnUpdate")(config.watcher, 1)
	return config
end

local function Click(check, on)
	check:SetChecked(on)
	check:GetScript("OnClick")(check)
end

T.test("chat config: без игровой панели ничего не создаётся и не меняется", function()
	local c = Build()
	T.ok(c.ns.ChatConfig, "модуль загружен")
	T.no(c.ns.ChatConfig.row)
	T.same(c.ns.Chat.SelectedWindows(), { "" })
	T.eq(#c.ns.db.errors, 0)
end)

T.test("chat config: поздняя загрузка, вкладки, последний флажок и вывод", function()
	local c = Build()
	local panel = Panel(c)
	local cfg = Tick(c)
	local watcher = cfg.watcher
	T.ok(cfg.row:IsShown())
	T.ok(cfg.check:GetChecked())
	local tab = c:ChatWindow(3, "Чиллзон")
	c.currentChatFrame = tab
	Tick(c)
	T.no(cfg.check:GetChecked(), "показан выбор текущей вкладки")
	Click(cfg.check, true)
	T.same(c.ns.Chat.SelectedWindows(), { "", "Чиллзон" })
	c.ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "две копии")
	T.eq(#tab.lines, 1)
	T.eq(c:Saw("две копии"), 1)
	Click(cfg.check, false)
	T.same(c.ns.Chat.SelectedWindows(), { "" })
	c.currentChatFrame = c.env.DEFAULT_CHAT_FRAME
	Tick(c)
	Click(cfg.check, false)
	T.no(c.ns.char.chatMirror, "последний флажок выключает все копии")
	c.ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "только история")
	T.eq(c:Saw("только история"), 0)
	T.eq(#c.ns.Chat.History("A"), 2, "получение и история не выключены")
	Tick(c)
	T.no(cfg.check:GetChecked())
	c.currentChatFrame = tab
	Tick(c)
	Click(cfg.check, true)
	T.ok(c.ns.char.chatMirror)
	T.same(c.ns.Chat.SelectedWindows(), { "Чиллзон" }, "включена только выбранная вкладка")
	c.ns.Chat.Show("A", "Чиллзон", "Автор Чата", "MAGE", "одна копия")
	T.eq(#tab.lines, 2)
	T.eq(c:Saw("одна копия"), 0)
	c:Fire("ADDON_LOADED", "ДругойАддон")
	T.eq(cfg.watcher, watcher, "повторной установки нет")
	panel:Hide()
	Tick(c)
	T.no(cfg.row:IsShown())
	T.eq(#c:Leaks(), 0)
	T.eq(#c.ns.db.errors, 0)
end)

T.test("chat config: цвет общий с настройками аддона, палитра закрывается", function()
	local c = Build()
	Panel(c)
	local cfg = Tick(c)
	cfg.color:GetScript("OnClick")(cfg.color)
	T.ok(cfg.palette:IsShown())
	local swatch = cfg.swatches[3]
	swatch:GetScript("OnClick")(swatch)
	T.eq(c.ns.Chat.TextColor(), c.ns.Chat.COLORS[3])
	T.no(cfg.palette:IsShown())
	c.ns.db.settings.chatColor = c.ns.Chat.COLORS[5]
	Tick(c)
	T.eq(cfg.color.hex, c.ns.Chat.COLORS[5], "изменения из другого окна видны здесь")
	cfg.color:GetScript("OnClick")(cfg.color)
	c.currentChatFrame = c:ChatWindow(3, "Союз")
	Tick(c)
	T.no(cfg.palette:IsShown(), "палитра прежней вкладки закрыта")
	T.eq(#c.ns.db.errors, 0)
end)

T.test("chat config: бой, неизвестное окно и нехватка места отключают только строку", function()
	local c = Build()
	local _, list = Panel(c)
	local cfg = Tick(c)
	c.combat = true
	Tick(c)
	T.no(cfg.row:IsShown())
	Click(cfg.check, false)
	T.ok(c.ns.char.chatMirror, "щелчок в бою ничего не меняет")
	c.combat = false
	Tick(c)
	T.ok(cfg.row:IsShown())
	c.env.Chattynator = { API = {} }
	c.stubs.Chattynator = true
	Tick(c)
	T.no(cfg.row:IsShown(), "штатная панель не меняет вкладки Chattynator")
	c.env.Chattynator = nil
	c.currentChatFrame = c.env.COMBATLOG
	Tick(c)
	T.no(cfg.row:IsShown(), "журнал боя не подходит")
	c.currentChatFrame = c.env.CreateFrame("Frame")
	Tick(c)
	T.no(cfg.row:IsShown(), "неизвестное окно не меняет основное")
	c.currentChatFrame = c.env.DEFAULT_CHAT_FRAME
	list.GetBottom = function() return 60 end
	Tick(c)
	T.no(cfg.row:IsShown(), "нет места, игровые элементы не сдвигаются")
	list.GetBottom = function() return 300 end
	Tick(c)
	T.ok(cfg.row:IsShown())
	c.env.FCF_GetCurrentChatFrame = nil
	Tick(c)
	T.no(cfg.row:IsShown(), "неподдерживаемый API")
	T.same(c.ns.Chat.SelectedWindows(), { "" })
	T.eq(#c.ns.db.errors, 0)
end)

T.test("chat config: загрузка в бою откладывает установку до его окончания", function()
	local c = Build()
	c.combat = true
	Panel(c)
	T.no(c.ns.ChatConfig.watcher)
	c.combat = false
	c:Fire("PLAYER_REGEN_ENABLED")
	T.ok(Tick(c).row:IsShown())
	T.eq(#c.ns.db.errors, 0)
end)

T.test("chat config: доступные каналы не перекрываются, ошибки API изолированы", function()
	local c = Build()
	Panel(c)
	local cfg = Tick(c)
	local available = c.env.CreateFrame("Frame")
	available.GetBottom = function() return 65 end
	available:Show()
	c.env.ChatConfigChannelSettingsAvailable = available
	c.stubs.ChatConfigChannelSettingsAvailable = true
	Tick(c)
	T.no(cfg.row:IsShown(), "список доступных каналов занял свободное место")
	available:Hide()
	Tick(c)
	T.ok(cfg.row:IsShown())
	c.env.FCF_GetCurrentChatFrame = function() error("панель другого аддона") end
	Tick(c)
	T.no(cfg.row:IsShown(), "ошибка чтения не выходит в интерфейс игры")
	T.eq(#c.ns.db.errors, 0)
	T.eq(#c:Leaks(), 0)
end)

T.test("chat config: выбор вкладки и цвет переживают перезагрузку", function()
	local c = Build()
	Panel(c)
	local cfg = Tick(c)
	local tab = c:ChatWindow(3, "Союз")
	c.currentChatFrame = tab
	Tick(c)
	Click(cfg.check, true)
	cfg.color:GetScript("OnClick")(cfg.color)
	cfg.swatches[4]:GetScript("OnClick")(cfg.swatches[4])
	local db = c.ns.db
	c:Logout()
	local w = Wow.World()
	local nextClient = w:Client({ first = "Автор", surname = "Чата", db = db })
	Panel(nextClient)
	nextClient.currentChatFrame = nextClient:ChatWindow(3, "Союз")
	local nextConfig = Tick(nextClient)
	T.ok(nextConfig.check:GetChecked())
	T.eq(nextConfig.color.hex, nextClient.ns.Chat.COLORS[4])
	T.eq(#nextClient.ns.db.errors, 0)
end)
