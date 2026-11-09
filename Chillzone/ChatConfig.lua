-- Чиллзон в настройках каналов игры. Только свои дочерние кадры: без хуков,
-- изменений игровых таблиц, обработчиков, палитры ColorPickerFrame и поля ввода.
-- Разметка сверена с Blizzard_ChatFrame/Classic/ChatConfigFrame.xml и
-- ChatConfigFrame_Shared.lua (Gethe/wow-ui-source, ветка classic).
local ADDON, ns = ...
local Chat, L = ns.Chat, ns.L
local Config = {}
ns.ChatConfig = Config

local panel, list, background
local target, elapsed = nil, 0

local function CurrentWindow()
	-- Chattynator хранит собственные вкладки: штатная панель не управляет ими.
	if type(rawget(_G, "Chattynator")) == "table" then return nil end
	local get = FCF_GetCurrentChatFrame
	if type(get) ~= "function" then return nil end
	local ok, frame = pcall(get)
	if not ok or not frame then return nil end
	for _, w in ipairs(Chat.Windows()) do
		if w.frame == frame then return frame == DEFAULT_CHAT_FRAME and "" or w.name end
	end
end

local function Refresh()
	local row = Config.row
	if not row then return end
	local name = CurrentWindow()
	if name ~= target then Config.palette:Hide() end
	target = name
	local anchor = rawget(_G, "ChatConfigChannelSettingsAvailable")
	if not anchor or not anchor:IsShown() then anchor = list end
	local bottom, floor, width = anchor:GetBottom(), background:GetBottom(), list:GetWidth()
	-- Панель игры может отличаться или быть заполнена каналами. В таком случае
	-- оставляем только обычные настройки аддона, не перекрывая элементы игры.
	if not ns.char or InCombatLockdown() or not panel:IsVisible() or name == nil
		or type(bottom) ~= "number" or type(floor) ~= "number" or type(width) ~= "number"
		or width < 360 or bottom - floor < 70 then
		row:Hide()
		Config.palette:Hide()
		return
	end
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
	row:SetSize(width, 26)
	Config.check:SetChecked(ns.char.chatMirror ~= false and Chat.WindowSelected(name))
	Config.color.hex = Chat.TextColor()
	Config.color.fill:SetColorTexture(Chat.HexToRGB(Config.color.hex))
	for _, s in ipairs(Config.swatches) do s.ring:SetShown(s.hex == Config.color.hex) end
	row:Show()
end

local function Update()
	if not ns.SafeCall("chat config", Refresh) and Config.row then
		Config.row:Hide()
		Config.palette:Hide()
	end
end

local function Changed()
	if ns.UI then ns.UI.Render() end
	Update()
end

local function Toggle(self)
	local checked = self:GetChecked()
	Update()
	if not Config.row:IsShown() then return end
	local selected = Chat.WindowSelected(target)
	if checked then
		if ns.char.chatMirror == false then
			Chat.SetWindow(target)
			ns.char.chatMirror = true
		elseif not selected then
			Chat.ToggleWindow(target)
		end
	elseif selected then
		if #Chat.SelectedWindows() == 1 then ns.char.chatMirror = false
		else Chat.ToggleWindow(target) end
	end
	ns.Fire("CHAT_WINDOWS")
	Changed()
end

local function ColorButton(parent, size)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size, size)
	local border = b:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(0.6, 0.6, 0.6, 1)
	b.fill = b:CreateTexture(nil, "ARTWORK")
	b.fill:SetPoint("TOPLEFT", 2, -2)
	b.fill:SetPoint("BOTTOMRIGHT", -2, 2)
	return b
end

local function Tooltip(owner, title, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(title, 1, 0.82, 0)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Install()
	if Config.watcher or not ns.char or InCombatLockdown() then return end
	panel = rawget(_G, "ChatConfigChannelSettings")
	list = rawget(_G, "ChatConfigChannelSettingsLeft")
	background = rawget(_G, "ChatConfigBackgroundFrame")
	if not panel or not list or not background or type(FCF_GetCurrentChatFrame) ~= "function" then return end
	local watcher = CreateFrame("Frame", nil, panel)
	watcher:SetSize(1, 1)
	watcher:SetPoint("TOPLEFT")
	Config.watcher = watcher
	local row = CreateFrame("Frame", nil, watcher)
	Config.row = row
	row:Hide()
	local check = CreateFrame("CheckButton", nil, row)
	Config.check = check
	check:SetSize(24, 24)
	check:SetPoint("LEFT", 3, 0)
	check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	check:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	check:SetScript("OnClick", function(self) ns.SafeCall("chat config toggle", Toggle, self) end)
	Tooltip(check, L.TIER_A, L.CHAT_CONFIG_TIP)
	local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("LEFT", check, "RIGHT", 2, 0)
	label:SetText(L.TIER_A)
	local color = ColorButton(row, 16)
	Config.color = color
	color:SetPoint("LEFT", row, "LEFT", 344, 0)
	Tooltip(color, L.CHAT_COLOR, L.CHAT_COLOR_TIP)
	local palette = CreateFrame("Frame", nil, row)
	Config.palette = palette
	palette:SetSize(#Chat.COLORS * 24 + 8, 30)
	palette:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -2)
	palette:SetFrameLevel(row:GetFrameLevel() + 5)
	local bg = palette:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.05, 1)
	palette:Hide()
	Config.swatches = {}
	for i, hex in ipairs(Chat.COLORS) do
		local s = ColorButton(palette, 22)
		s.hex = hex
		s:SetPoint("LEFT", 4 + (i - 1) * 24, 0)
		s.fill:SetColorTexture(Chat.HexToRGB(hex))
		s.ring = s:CreateTexture(nil, "OVERLAY")
		s.ring:SetAllPoints()
		s.ring:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		s.ring:SetBlendMode("ADD")
		s:SetScript("OnClick", function(self)
			ns.SafeCall("chat config color", function()
				Update()
				if not row:IsShown() or not palette:IsShown() then return end
				ns.db.settings.chatColor = self.hex
				palette:Hide()
				if ns.ChatPane then ns.ChatPane.Reload() end
				Changed()
			end)
		end)
		Config.swatches[i] = s
	end
	color:SetScript("OnClick", function()
		Update()
		if row:IsShown() then palette:SetShown(not palette:IsShown()) end
	end)
	row:SetScript("OnHide", function() palette:Hide() end)
	watcher:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.2 then return end
		elapsed = 0
		Update()
	end)
	watcher:Show()
	Update()
end

ns.On("LOGIN", Install)
ns.RegisterEvent("ADDON_LOADED", Install)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", Install)
