-- Chillzone: окно — как «Гильдия и сообщества»: рамка ButtonFrameTemplate с портретом, вкладки-
-- значки на правом краю (Чат, Перепись, Королевство, Настройки, а главам и офицерам ещё Заявки и Отладка).
-- Вкладка «Объединение» (UnionPane.lua): глава главной гильдии управляет составом,
-- офицер гильдии вне объединения запрашивает связь.
-- Чат рисует ChatPane.lua, Перепись — CensusPane.lua, остальные вкладки — список строк из Views.lua
-- и Debug.lua во вставке окна. Кнопка у миникарты — по образцу Olympus UI.lua.
local ADDON, ns = ...

local L = ns.L
local U = ns.Util

local UI = {}
ns.UI = UI

local ROW_H = 18
local WIDTH, HEIGHT = 814, 426
-- Значок аддона: логотип «Chill Zone», обрезанный по золотому кольцу (media/icon.tga, 64×64 TGA
-- с прозрачностью). Он уже круглый, маска не нужна. Логотип целиком — media/logo.tga, для списка аддонов (toc).
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\media\\icon"
local TABS = {
	{ key = "chat", text = "TAB_CHAT", icons = { "Interface\\Icons\\UI_Chat", "Interface\\Icons\\INV_Letter_15" } },
	{ key = "census", text = "TAB_CENSUS", icons = { "Interface\\Icons\\achievement_guildperk_everybodysfriend", "Interface\\Icons\\INV_Misc_Book_09" } },
	{ key = "requests", text = "TAB_REQUESTS", icons = { "Interface\\Icons\\INV_Letter_15" } },
	{ key = "kingdom", text = "TAB_KINGDOM", icons = { "Interface\\Icons\\achievement_guildperk_honorablemention", "Interface\\Icons\\INV_Misc_Note_01" } },
	{ key = "settings", text = "TAB_SETTINGS", icons = { "Interface\\Icons\\INV_Misc_Gear_01" } },
	{ key = "debug", text = "TAB_DEBUG", icons = { "Interface\\Icons\\Trade_Engineering", "Interface\\Icons\\INV_Misc_Spyglass_03" } },
	{ key = "union", text = "TAB_UNION", icons = { "Interface\\Icons\\INV_Misc_GroupLooking" } },
}
local DEBUG_EVERY = 5 -- «Отладка» обновляется чаще остальных: там счётчики и состояние реле
local frame, body, scroll, child, settings = nil, nil, nil, nil, nil
local status, heading -- шапка (крупно и мелко) и название вкладки слева вверху
local titleText -- свой текст заголовка, если у рамки нет SetTitle
local tabs, rows, checks = {}, {}, {}
local current = "chat"
local minimapButton

local function SetTip(owner, tip)
	owner:SetScript("OnEnter", function(self)
		if not self.tip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		ns.SafeCall("tooltip", self.tip, GameTooltip)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
	owner.tip = tip
end

local function Exists(path)
	local f = rawget(_G, "GetFileIDFromPath")
	if type(f) ~= "function" then return true end
	local ok, id = pcall(f, path)
	return not ok or id ~= nil
end

local function FirstIcon(paths)
	for _, p in ipairs(paths) do
		if Exists(p) then return p end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

---------------------------------------------------------------------------
-- Строки «Королевства» и «Отладки»
---------------------------------------------------------------------------
local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, child)
	r:SetHeight(ROW_H)
	r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.left:SetJustifyH("LEFT")
	r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.right:SetJustifyH("RIGHT")
	r.right:SetPoint("RIGHT", -4, 0)
	r.left:SetPoint("LEFT", 4, 0)
	r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
	r.left:SetWordWrap(false)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	SetTip(r, nil)
	rows[i] = r
	return r
end

local function RenderRows(lines)
	child:SetWidth(scroll:GetWidth() or (WIDTH - 50))
	local y = 0
	for i, line in ipairs(lines) do
		local r = Row(i)
		if line.gap then y = y + 8 end
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", child, "TOPLEFT", (line.indent or 0) * 18, -y)
		r:SetPoint("RIGHT", child, "RIGHT", 0, 0)
		r.left:SetFontObject(line.header and "GameFontNormal" or "GameFontHighlightSmall")
		r.left:SetText(line.text or "")
		r.right:SetText(line.right or "")
		r.tip = line.tip
		r:EnableMouse(line.tip ~= nil)
		r:Show()
		y = y + ROW_H
	end
	for i = #lines + 1, #rows do rows[i]:Hide() end
	child:SetHeight(math.max(y, 10))
end

---------------------------------------------------------------------------
-- Настройки
---------------------------------------------------------------------------
local settingsY = 16 -- отступ сверху для следующей строки настроек

local function Check(key, text, tip, get, set)
	local c = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
	c:SetSize(26, 26)
	c:SetPoint("TOPLEFT", settings, "TOPLEFT", 16, -settingsY)
	settingsY = settingsY + 30
	local label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("LEFT", c, "RIGHT", 4, 0)
	label:SetText(text)
	c.get = get
	c:SetScript("OnClick", function(self) ns.SafeCall("check " .. key, set, self:GetChecked() and true or false) end)
	SetTip(c, function(tt)
		tt:AddLine(text, 1, 0.82, 0)
		tt:AddLine(tip, 1, 1, 1, true)
	end)
	checks[#checks + 1] = c
	return c
end

-- Вкладка чата игры для копий строк: кнопка и свой список открытых вкладок. Не UIDropDownMenu:
-- его общие глобалы на Forever дают taint, как и стандартные popup. Окна чата только читаем.
local ITEM_H = 20
local picker = { items = {} } -- label, button, list, empty, items
UI.picker = picker

local function RenderPicker()
	local b = picker.button
	if not b then return end
	local name, open = ns.Chat.Window()
	if not name then
		b:SetText(L.WINDOW_MAIN)
	elseif open then
		b:SetText(name)
	else
		b:SetText("|cffff6060" .. L.WINDOW_GONE:format(name) .. "|r")
	end
	local mirror = ns.char.chatMirror ~= false
	b:SetEnabled(mirror)
	picker.label:SetFontObject(mirror and "GameFontHighlight" or "GameFontDisable")
	if not mirror then picker.list:Hide() end
end

local function Pick(value)
	picker.list:Hide()
	ns.Chat.SetWindow(value)
	RenderPicker()
end

local function PickerItem(i)
	local it = picker.items[i]
	if it then return it end
	it = CreateFrame("Button", nil, picker.list)
	it:SetHeight(ITEM_H)
	it:SetPoint("TOPLEFT", picker.list, "TOPLEFT", 6, -6 - (i - 1) * ITEM_H)
	it:SetPoint("RIGHT", picker.list, "RIGHT", -6, 0)
	it.check = it:CreateTexture(nil, "ARTWORK")
	it.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
	it.check:SetSize(16, 16)
	it.check:SetPoint("LEFT", 0, 0)
	it.text = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	it.text:SetPoint("LEFT", 20, 0)
	it.text:SetPoint("RIGHT", -4, 0)
	it.text:SetJustifyH("LEFT")
	it.text:SetWordWrap(false)
	local hl = it:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.1)
	it:SetScript("OnClick", function(self) ns.SafeCall("window pick", Pick, self.value) end)
	picker.items[i] = it
	return it
end

-- Список собирается заново при каждом открытии: вкладки могли создать, закрыть или переименовать.
local function ToggleList()
	local list = picker.list
	if list:IsShown() then
		list:Hide()
		return
	end
	local entries = { { text = L.WINDOW_MAIN, value = "" } }
	for _, w in ipairs(ns.Chat.MirrorWindows()) do
		if not w.frame or w.frame ~= DEFAULT_CHAT_FRAME then
			entries[#entries + 1] = { text = w.name, value = w.name }
		end
	end
	local chosen = U.Fold(ns.Chat.Window() or "")
	for i, e in ipairs(entries) do
		local it = PickerItem(i)
		it.value = e.value
		it.text:SetText(e.text)
		it.check:SetShown(U.Fold(e.value) == chosen)
		it:Show()
	end
	for i = #entries + 1, #picker.items do picker.items[i]:Hide() end
	local h = 12 + #entries * ITEM_H
	local empty = picker.empty
	empty:ClearAllPoints()
	empty:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -h)
	empty:SetShown(#entries == 1)
	if #entries == 1 then h = h + math.max(28, empty:GetStringHeight() or 0) + 6 end
	list:SetHeight(h)
	list:Show()
end

local function BuildPicker()
	local label = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("TOPLEFT", settings, "TOPLEFT", 46, -settingsY - 6)
	label:SetText(L.WINDOW_TITLE .. ":")
	local b = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
	b:SetSize(220, 22)
	b:SetPoint("LEFT", label, "RIGHT", 8, 0)
	b:SetScript("OnClick", function() ns.SafeCall("window list", ToggleList) end)
	SetTip(b, function(tt)
		tt:AddLine(L.WINDOW_TITLE, 1, 0.82, 0)
		tt:AddLine(L.WINDOW_TIP, 1, 1, 1, true)
		if type(rawget(_G, "Chattynator")) == "table" then
			tt:AddLine(L.WINDOW_CHATTYNATOR_TIP, 1, 1, 1, true)
		end
	end)
	local list = CreateFrame("Frame", nil, settings)
	list:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
	list:SetWidth(260)
	list:SetFrameStrata("DIALOG")
	list:EnableMouse(true)
	local edge = list:CreateTexture(nil, "BACKGROUND", nil, -1)
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)
	edge:SetColorTexture(0.5, 0.5, 0.5, 0.9)
	local bg = list:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.06, 0.06, 0.06, 0.96)
	local empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty:SetWidth(240)
	empty:SetJustifyH("LEFT")
	empty:SetText(L.WINDOW_NONE)
	list:Hide()
	-- Список — ребёнок настроек: без этого он снова появится вместе с ними.
	settings:SetScript("OnHide", function() list:Hide() end)
	picker.label, picker.button, picker.list, picker.empty = label, b, list, empty
	settingsY = settingsY + 30
end

-- Цвет текста общего чата: своя палитра. ColorPickerFrame — такой же общий глобал игры, как UIDropDownMenu.
local SWATCH = 20
local swatches = {}
UI.swatches = swatches

local function RenderSwatches()
	local chosen = ns.Chat.TextColor()
	for _, s in ipairs(swatches) do s.ring:SetShown(s.hex == chosen) end
end

local function PickColor(hex)
	ns.db.settings.chatColor = hex
	RenderSwatches()
	ns.ChatPane.Reload()
end

local function Swatch(i, hex)
	local s = CreateFrame("Button", nil, settings)
	s:SetSize(SWATCH, SWATCH)
	s.hex = hex
	s.ring = s:CreateTexture(nil, "BACKGROUND", nil, -1)
	s.ring:SetAllPoints()
	s.ring:SetColorTexture(1, 1, 1, 1)
	-- Чёрный зазор: иначе рамка выбранного сливается с белым и жёлтым квадратом.
	local gap = s:CreateTexture(nil, "BACKGROUND")
	gap:SetPoint("TOPLEFT", 2, -2)
	gap:SetPoint("BOTTOMRIGHT", -2, 2)
	gap:SetColorTexture(0, 0, 0, 1)
	local fill = s:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", 3, -3)
	fill:SetPoint("BOTTOMRIGHT", -3, 3)
	fill:SetColorTexture(ns.Chat.HexToRGB(hex))
	local hl = s:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.2)
	s:SetScript("OnClick", function(self) ns.SafeCall("chat color", PickColor, self.hex) end)
	SetTip(s, function(tt)
		tt:AddLine(L.CHAT_COLOR, 1, 0.82, 0)
		tt:AddLine(L.CHAT_COLOR_TIP, 1, 1, 1, true)
	end)
	swatches[i] = s
	return s
end

-- Палитра стоит справа на строке следующей настройки: отдельный ряд в окно по высоте не помещается.
local function BuildSwatches()
	local label = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("TOPLEFT", settings, "TOPLEFT", 260, -settingsY - 6)
	label:SetText(L.CHAT_COLOR .. ":")
	local prev, gap = label, 8
	for i, hex in ipairs(ns.Chat.COLORS) do
		local s = Swatch(i, hex)
		s:SetPoint("LEFT", prev, "RIGHT", gap, 0)
		prev, gap = s, 4
	end
end

local function BuildSettings(parent)
	settings = CreateFrame("Frame", nil, parent)
	settings:SetAllPoints(parent)
	Check("map", L.CHECK_MAP, L.CHECK_MAP_TIP, function() return ns.db.settings.showMap end, function(on) ns.Map.SetEnabled(on) end)
	Check("mapOpenMapWide", L.CHECK_MAP_OPENMAP_WIDE, L.CHECK_MAP_OPENMAP_WIDE_TIP,
		function() return ns.db.settings.mapOpenMapWide == true end, function(on)
			ns.db.settings.mapOpenMapWide = on
			ns.Fire("SETTINGS")
		end)
	Check("zones", L.CHECK_ZONES, L.CHECK_ZONES_TIP, function() return ns.char.shareZones end, function(on)
		ns.char.shareZones = on
		ns.Print(on and L.ZONES_ON or L.ZONES_OFF)
		ns.Census.SendHello()
	end)
	Check("chat", L.CHECK_CHAT, L.CHECK_CHAT_TIP, function() return ns.char.chatOn end, function(on)
		ns.char.chatOn = on
		ns.Print(on and L.CHAT_ON or L.CHAT_OFF)
	end)
	Check("mirror", L.CHECK_MIRROR, L.CHECK_MIRROR_TIP, function() return ns.char.chatMirror end, function(on)
		ns.char.chatMirror = on
		RenderPicker()
	end)
	BuildPicker()
	BuildSwatches()
	Check("time", L.CHECK_TIME, L.CHECK_TIME_TIP, function() return ns.char.chatTime end, function(on)
		ns.char.chatTime = on
		ns.ChatPane.Reload()
	end)
	Check("minimap", L.CHECK_MINIMAP, L.CHECK_MINIMAP_TIP, function() return not ns.db.settings.minimap.hide end, function(on)
		ns.db.settings.minimap.hide = not on
		UI.UpdateMinimapButton()
	end)
	Check("recruits", L.CHECK_RECRUITS, L.CHECK_RECRUITS_TIP,
		function() return not ns.Recruit.NoContactMe() end, function(on) ns.Recruit.SetNoContact(not on) end)
	local hint = settings:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	hint:SetPoint("TOPLEFT", settings, "TOPLEFT", 20, -settingsY - 8)
	hint:SetPoint("RIGHT", settings, "RIGHT", -20, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText(L.SETTINGS_HINT)
	settings:Hide()
end

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------
-- Заголовок окна (Views.Title): с просьбой обновиться, когда вышла версия новее.
function UI.RenderTitle()
	if not frame then return end
	local text = ns.Views.Title()
	if titleText then
		titleText:SetText(text)
	else
		pcall(frame.SetTitle, frame, text)
	end
end

-- Шапка окна: текст из Views.Status (общий счёт всех гильдий «Чиллзон»).
function UI.RenderStatus()
	if not status or not frame:IsShown() then return end
	local st = ns.Views.Status()
	status.big:SetText(st.big)
	status.small:SetText(st.small)
	-- Наведение — на ширину текста, а не на все 300 точек.
	local w = math.max(status.big:GetStringWidth() or 0, status.small:GetStringWidth() or 0)
	if w > 0 then status:SetWidth(math.ceil(w) + 4) end
end

-- «Заявки» (общая очередь, RecruitSync.IsOfficer) и «Отладка» (Debug.Allowed) — только главам и
-- офицерам: звание могли поменять при открытом окне. Видимые вкладки идут подряд, без дыр.
local function Allowed(key)
	if key == "requests" then return ns.RecruitSync.IsOfficer() end
	if key == "debug" then return ns.Debug.Allowed() end
	if key == "union" then return ns.Security.CanManageUnion() or ns.Security.CanRequestUnion() end
	return true
end

local function SyncTabs()
	local prev
	for _, def in ipairs(TABS) do
		local b, allowed = tabs[def.key], Allowed(def.key)
		b:SetShown(allowed)
		if allowed then
			b:ClearAllPoints()
			if prev then
				b:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -20)
			else
				b:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, -36)
			end
			prev = b
		elseif current == def.key then
			current = "chat"
		end
	end
end

function UI.Render()
	if not frame or not frame:IsShown() then return end
	SyncTabs()
	if current ~= "union" then ns.UnionPane.Hide() end
	if not ns.IsMember() and current ~= "settings" and current ~= "union" then current = "join"
	elseif ns.IsMember() and current == "join" then current = "census" end
	for key, tab in pairs(tabs) do tab:SetChecked(key == current) end
	if current ~= "requests" then ns.RecruitPane.HideInbox() end
	UI.RenderStatus()
	if current == "join" then
		heading:SetText(L.RECRUIT_TITLE)
		ns.ChatPane.Hide()
		body:Show()
		scroll:Hide()
		settings:Hide()
		ns.CensusPane.Hide()
		ns.RecruitPane.Show()
		return
	end
	ns.RecruitPane.Hide()
	local def
	for _, t in ipairs(TABS) do
		if t.key == current then def = t end
	end
	heading:SetText(current ~= "chat" and def and L[def.text] or "")
	if current == "chat" then
		body:Hide()
		ns.ChatPane.Show()
		return
	end
	ns.ChatPane.Hide()
	body:Show()
	if current == "settings" then
		scroll:Hide()
		ns.CensusPane.Hide()
		settings:Show()
		for _, c in ipairs(checks) do c:SetChecked(c.get() and true or false) end
		RenderPicker()
		RenderSwatches()
		return
	end
	settings:Hide()
	if current == "requests" then
		scroll:Hide()
		ns.CensusPane.Hide()
		ns.RecruitPane.ShowInbox()
		return
	end
	if current == "union" then
		scroll:Hide()
		ns.CensusPane.Hide()
		ns.UnionPane.Show()
		return
	end
	if current == "census" then
		scroll:Hide()
		ns.CensusPane.Show()
		return
	end
	ns.CensusPane.Hide()
	scroll:Show()
	if current == "debug" then
		ns.SafeCall("debug tab", function() RenderRows(ns.Debug.Lines()) end)
	else
		RenderRows(ns.Views.Kingdom())
	end
end

local function SelectTab(key)
	current = key
	if scroll then scroll:SetVerticalScroll(0) end
	UI.Render()
end

-- Вкладки-значки на правом краю, как у окна гильдии (32×32, фон вкладки книги заклинаний).
-- Места вкладкам раздаёт SyncTabs.
local function SideTab(def)
	local b = CreateFrame("CheckButton", nil, frame)
	b:SetSize(32, 32)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	bg:SetSize(64, 64)
	bg:SetPoint("TOPLEFT", -3, 11)
	-- Значок — своя текстура, а не NormalTexture: её не прячет ни нажатие, ни выбор вкладки.
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(32, 32)
	icon:SetPoint("LEFT")
	icon:SetTexture(FirstIcon(def.icons))
	b.icon = icon
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	-- SetCheckedTexture режим наложения не принимает: без ADD чёрная середина рамки закрывает значок.
	b:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
	local checked = b.GetCheckedTexture and b:GetCheckedTexture()
	if checked and checked.SetBlendMode then checked:SetBlendMode("ADD") end
	b:SetScript("OnClick", function() ns.SafeCall("tab " .. def.key, SelectTab, def.key) end)
	SetTip(b, function(tt)
		-- Число заявок — в подсказке: подпись рядом со значком растягивала вкладку.
		local count = def.key == "requests" and #ns.Recruit.Requests() or 0
		tt:AddLine(count > 0 and L.TAB_REQUESTS_COUNT:format(count) or L[def.text], 1, 1, 1)
	end)
	tabs[def.key] = b
end

local function Portrait(f)
	local tex = f.portrait or f.Portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
	if tex then tex:SetTexture(ICON) end
end

local function SavePosition(f)
	local point, _, rel, x, y = f:GetPoint(1)
	if point then ns.db.settings.frame = { point = point, rel = rel or point, x = x or 0, y = y or 0 } end
end

local function Create()
	local ok, f = pcall(CreateFrame, "Frame", "ChillzoneFrame", UIParent, "ButtonFrameTemplate")
	if not ok or not f then f = CreateFrame("Frame", "ChillzoneFrame", UIParent, "BasicFrameTemplateWithInset") end
	frame = f
	UI.frame = f
	f:SetSize(WIDTH, HEIGHT)
	local pos = ns.db.settings.frame
	if pos and pos.point then
		f:SetPoint(pos.point, UIParent, pos.rel or pos.point, pos.x or 0, pos.y or 0)
	else
		f:SetPoint("CENTER", 0, 40)
	end
	f:SetFrameStrata("MEDIUM")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition(self)
	end)
	f:Hide()
	if type(f.SetTitle) ~= "function" then
		titleText = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText) or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		if not f.TitleText then titleText:SetPoint("TOP", 0, -5) end
	end
	UI.RenderTitle()
	Portrait(f)
	-- Крестик закрывает окно без HideUIPanel (та в бою не работает).
	local close = f.CloseButton or rawget(_G, "ChillzoneFrameCloseButton")
	if close then close:SetScript("OnClick", function() f:Hide() end) end
	if f.Inset then f.Inset:Hide() end
	tinsert(UISpecialFrames, "ChillzoneFrame")

	-- Шапка, как у Olympus: справа вверху крупно — все участники гильдий «Чиллзон», мелко — сколько
	-- в игре, гильдий и когда обновлено. Одна на все вкладки; наведение — по гильдиям.
	status = CreateFrame("Frame", nil, f)
	status:SetPoint("TOPRIGHT", f, "TOPRIGHT", -26, -25)
	status:SetSize(300, 34)
	status.big = status:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	status.big:SetPoint("TOPRIGHT", 0, -2)
	status.big:SetJustifyH("RIGHT")
	status.small = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status.small:SetPoint("TOPRIGHT", status.big, "BOTTOMRIGHT", 0, -3)
	status.small:SetJustifyH("RIGHT")
	status.small:SetTextColor(0.7, 0.7, 0.7)
	status:EnableMouse(true)
	SetTip(status, function(tt) ns.Views.StatusTip(tt) end)
	-- За шапку окно тоже можно таскать.
	status:RegisterForDrag("LeftButton")
	status:SetScript("OnDragStart", function() f:StartMoving() end)
	status:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		SavePosition(f)
	end)
	-- Название вкладки слева вверху (у чата там название канала — ChatPane).
	heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	heading:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 70, -54)
	UI.status, UI.heading = status, heading

	-- Перепись, Королевство и Настройки — во вставке, как Inset у ButtonFrameTemplate: (4,-60) → (-6,26).
	local okInset, inset = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
	body = okInset and inset or CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -60)
	body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 26)
	scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -30, 8)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WIDTH - 50, 10)
	scroll:SetScrollChild(child)
	BuildSettings(body)
	ns.RecruitPane.Build(body)
	ns.RecruitPane.BuildInbox(body)
	ns.CensusPane.Build(body)
	ns.UnionPane.Build(body)
	body:Hide()

	ns.ChatPane.Build(f)
	for _, def in ipairs(TABS) do SideTab(def) end
	UI.tabs = tabs

	f:SetScript("OnShow", function() UI.Render() end)
	f:SetScript("OnHide", function() ns.ChatPane.Hide(); ns.Recruit.Cancel(); ns.UnionPane.Hide() end)
	local elapsed, debugElapsed = 0, 0
	f:SetScript("OnUpdate", function(_, dt)
		elapsed, debugElapsed = elapsed + (dt or 0), debugElapsed + (dt or 0)
		if current == "debug" and debugElapsed >= DEBUG_EVERY then
			elapsed, debugElapsed = 0, 0
			UI.Render()
		elseif elapsed >= 30 then
			elapsed, debugElapsed = 0, 0
			if current == "census" or current == "kingdom" or current == "join" or current == "requests" or current == "union" then
				UI.Render()
			else UI.RenderStatus() end
		end
	end)
end

-- Окно на вкладке tab (без tab — открыть или закрыть).
function UI.Toggle(tab)
	if not frame then Create() end
	if tab then current = tab end
	if frame:IsShown() and not tab then
		frame:Hide()
	else
		frame:Show()
		UI.Render()
	end
end

-- Окно на чате, на канале channel; focus — курсор в поле ввода.
function UI.OpenChat(channel, focus)
	if not frame then Create() end
	current = "chat"
	frame:Show()
	UI.Render()
	if ns.IsMember() then ns.ChatPane.Select(channel, focus) end
end

-- Открытая вкладка или nil, если окно закрыто.
function UI.Current()
	return frame and frame:IsShown() and current or nil
end

local function TabsChanged()
	for key, b in pairs(tabs) do
		if (b:IsShown() and true or false) ~= (Allowed(key) and true or false) then return true end
	end
	return false
end

local function Refresh()
	if not frame or not frame:IsShown() then return end
	if current == "census" or current == "kingdom" or current == "debug" or current == "union" or current == "requests"
		or TabsChanged() then
		UI.Render()
	else
		UI.RenderStatus()
	end
end
ns.On("DATA", Refresh)
ns.On("ROSTER", Refresh)
ns.On("RELAYS", Refresh)
ns.On("SETTINGS", Refresh)
ns.On("UNION", Refresh)
ns.On("GUILD_CHANGED", Refresh)
ns.On("RECRUIT", function() if frame and frame:IsShown() then UI.Render() end end)
ns.On("UPDATE", function() UI.RenderTitle() end)

---------------------------------------------------------------------------
-- Кнопка у миникарты: левый щелчок — окно, правый — круги на карте, перетаскивание — место.
---------------------------------------------------------------------------
local function PlaceButton()
	if not (minimapButton and rawget(_G, "Minimap")) then return end
	local angle = math.rad(ns.db.settings.minimap.angle or 200)
	local radius = (Minimap:GetWidth() / 2) + 5
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateButton()
	local b = CreateFrame("Button", "ChillzoneMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", 6, -6)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(18, 18)
	icon:SetPoint("TOPLEFT", 7, -7)
	local ring = b:CreateTexture(nil, "OVERLAY")
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	ring:SetSize(53, 53)
	ring:SetPoint("TOPLEFT")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(_, button)
		ns.SafeCall("minimap click", function()
			if button == "RightButton" then ns.Map.SetEnabled(not ns.db.settings.showMap) else UI.Toggle() end
		end)
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			ns.db.settings.minimap.angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
			PlaceButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		ns.SafeCall("minimap tip", ns.Views.MinimapTip, GameTooltip)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

function UI.UpdateMinimapButton()
	if not rawget(_G, "Minimap") then return end
	minimapButton = minimapButton or CreateButton()
	PlaceButton()
	minimapButton:SetShown(not ns.db.settings.minimap.hide)
end

ns.On("LOGIN", function()
	UI.UpdateMinimapButton()
end)

ns.Command("minimap", function()
	ns.db.settings.minimap.hide = not ns.db.settings.minimap.hide
	UI.UpdateMinimapButton()
	ns.Print(ns.db.settings.minimap.hide and L.MINIMAP_HIDDEN or L.MINIMAP_SHOWN)
end, L.HELP_MINIMAP)

ns.Command("kingdom", function() UI.Toggle("kingdom") end, L.HELP_KINGDOM)
ns.Command("census", function() UI.Toggle("census") end, L.HELP_CENSUS)
ns.Command("requests", function()
	if not ns.RecruitSync.IsOfficer() then
		ns.Print(L.REQUESTS_ONLY_OFFICERS)
		return
	end
	UI.Toggle("requests")
end, L.HELP_REQUESTS)
ns.Command("settings", function() UI.Toggle("settings") end, L.HELP_SETTINGS)
ns.Command("diag", function()
	if not ns.Debug.Allowed() then
		ns.Print(L.DIAG_ONLY_OFFICERS)
		return
	end
	UI.Toggle("debug")
end, L.HELP_DIAG)
