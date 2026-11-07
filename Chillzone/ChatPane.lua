-- Chillzone: панель чата в окне Chillzone — как чат окна «Гильдия и сообщества»: каналы
-- слева, сообщения (ScrollingMessageFrame) в центре, поле ввода снизу, люди справа.
-- Размеры и текстуры — из Blizzard_Communities (classic_era): CommunitiesFrame.xml,
-- CommunitiesList.xml, CommunitiesChatFrame.xml, CommunitiesMemberList.xml.
--
-- Чего панель не делает (правила Olympus ChatWindow.lua — иначе следующий /cast или /target
-- игрока блокируется как «испорченный» аддоном):
-- - не трогает поле ввода и окна чата игры: не вызывает ChatFrame_OpenChat, ChatFrame_SendTell,
--   ChatFrameUtil.*, ChatEdit_*, SetItemRef, HandleModifiedItemClick и не меняет их скрипты;
-- - своё поле ввода само фокус не берёт: только щелчок, клик по метке или Enter, пока окно открыто;
-- - Enter («Открыть чат») перехватывается своей кнопкой только при открытом окне и не в бою,
--   в режиме геймпада — никогда.
local ADDON, ns = ...

local U = ns.Util
local L = ns.L
local Codec = ns.Codec
local Chat = ns.Chat
local Views = ns.Views

local ChatPane = {}
ns.ChatPane = ChatPane

local MENU = "Interface\\Common\\bluemenu-main"
local ENTRY_H = 56
local PEOPLE_ROW = 20
local MAX_LINES = 500
local SENT_KEEP = 20
local BYTES = { G = 255, O = 255, A = 600, C = 600, L = 600 }
local ICONS = {
	G = { "Interface\\Icons\\INV_Shirt_GuildTabard_01" },
	O = { "Interface\\Icons\\Ability_Warrior_BattleShout" },
	A = { "Interface\\Icons\\Spell_Nature_Tranquility" },
	C = { "Interface\\Icons\\INV_Banner_02", "Interface\\Icons\\INV_Misc_Note_01" },
	L = { "Interface\\Icons\\INV_Crown_01", "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
}
local ROLE_ICON = {
	leader = "Interface\\GroupFrame\\UI-Group-LeaderIcon",
	officer = "Interface\\GroupFrame\\UI-Group-AssistantIcon",
	active = "Interface\\GossipFrame\\GossipGossipIcon",
}
-- Отметка «есть аддон» в списке людей — значок Chillzone, как у кнопки у миникарты.
local ADDON_ICON = "Interface\\Icons\\Spell_Nature_Tranquility"
local ADDON_SIZE = 12
local TEXT_RIGHT, TEXT_RIGHT_ADDON = -24, -24 - ADDON_SIZE - 2
local TIP_LINKS = { item = true, spell = true, enchant = true, quest = true, talent = true }

local pane, list, chatArea, messages, jump, box, prompt, title, scope, count, people, peopleChild, empty
local entries, rows = {}, {}
local current = "A"
local shown = false
local unread = {} -- [канал] = непрочитанные строки
local sent, sentPos = {}, 0 -- мои последние строки для ↑/↓
local peopleDirty, peopleElapsed = true, 0
local keyButton, keysPending, keysCombatSaid = nil, false, false

ChatPane.unread = unread

---------------------------------------------------------------------------
-- Мелочи
---------------------------------------------------------------------------
local function Exists(path)
	local f = rawget(_G, "GetFileIDFromPath")
	if type(f) ~= "function" then return true end
	local ok, id = pcall(f, path)
	return not ok or id ~= nil
end

local function SetIcon(tex, paths)
	for _, p in ipairs(paths) do
		if Exists(p) then
			tex:SetTexture(p)
			return
		end
	end
	tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
end

local function Atlas(tex, name)
	local CT = rawget(_G, "C_Texture")
	if type(CT) ~= "table" or type(CT.GetAtlasInfo) ~= "function" then return false end
	local ok, info = pcall(CT.GetAtlasInfo, name)
	if not ok or not info then return false end
	return pcall(tex.SetAtlas, tex, name) and true or false
end

local function Menu(tex, l, r, t, b)
	tex:SetTexture(MENU)
	tex:SetTexCoord(l, r, t, b)
end

local function Template(kind, parent, template)
	local ok, f = pcall(CreateFrame, kind, nil, parent, template)
	if ok and f then return f, true end
	return CreateFrame(kind, nil, parent), false
end

function ChatPane.Gamepad()
	local CII, E = rawget(_G, "C_InputInterfaceStyle"), rawget(_G, "Enum")
	if type(CII) ~= "table" or type(CII.GetCurrentStyle) ~= "function" or type(E) ~= "table" then return false end
	local t = E.InputDeviceInterfaceType
	if type(t) ~= "table" then return false end
	local ok, style = pcall(CII.GetCurrentStyle)
	return ok and style ~= nil and style == t.Gamepad
end

local function InCombat()
	local f = rawget(_G, "InCombatLockdown")
	return type(f) == "function" and f() and true or false
end

local function Tooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	return GameTooltip
end

function ChatPane.Visible(channel)
	return shown and pane ~= nil and (channel == nil or channel == current)
end

function ChatPane.Current() return current end

---------------------------------------------------------------------------
-- Каналы слева (CommunitiesListFrameTemplate / CommunitiesListEntryTemplate)
---------------------------------------------------------------------------
local function Entry(i)
	local e = entries[i]
	if e then return e end
	e = CreateFrame("Button", nil, list)
	e:SetHeight(ENTRY_H)
	e:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -54 - (i - 1) * (ENTRY_H + 2))
	e:SetPoint("RIGHT", list, "RIGHT", -2, 0)
	e.bg = e:CreateTexture(nil, "BACKGROUND")
	Menu(e.bg, 0.00390625, 0.87890625, 0.75195313, 0.83007813)
	e.bg:SetPoint("LEFT")
	e.bg:SetPoint("RIGHT")
	e.bg:SetHeight(ENTRY_H + 12)
	e.sel = e:CreateTexture(nil, "BORDER")
	Menu(e.sel, 0.00390625, 0.87890625, 0.59179688, 0.66992188)
	e.sel:SetPoint("LEFT")
	e.sel:SetPoint("RIGHT")
	e.sel:SetHeight(ENTRY_H + 12)
	e.sel:Hide()
	e:SetHighlightTexture(MENU, "ADD")
	local hl = e:GetHighlightTexture()
	if hl then
		hl:SetTexCoord(0.00390625, 0.87890625, 0.75195313, 0.83007813)
		hl:SetAlpha(0.8)
	end
	e.icon = e:CreateTexture(nil, "ARTWORK")
	e.icon:SetSize(34, 34)
	e.icon:SetPoint("LEFT", 11, 0)
	if e.icon.SetMask then pcall(e.icon.SetMask, e.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
	e.ring = e:CreateTexture(nil, "OVERLAY")
	e.ring:SetSize(44, 44)
	e.ring:SetPoint("CENTER", e.icon, "CENTER", 0, 0)
	if not Atlas(e.ring, "communities-ring-gold") then e.ring:Hide() end
	-- Название и под ним, цветом канала, чей он: «чат гильдии» или «все гильдии, /cz1».
	e.name = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	e.name:SetJustifyH("LEFT")
	e.name:SetPoint("BOTTOMLEFT", e.icon, "RIGHT", 9, 1)
	e.name:SetPoint("BOTTOMRIGHT", e, "RIGHT", -30, 1)
	e.sub = e:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	e.sub:SetJustifyH("LEFT")
	e.sub:SetPoint("TOPLEFT", e.icon, "RIGHT", 9, -2)
	e.sub:SetPoint("TOPRIGHT", e, "RIGHT", -30, -2)
	for _, fs in ipairs({ e.name, e.sub }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	e.dot = e:CreateTexture(nil, "OVERLAY")
	e.dot:SetSize(17, 17)
	e.dot:SetPoint("RIGHT", -10, 0)
	if not Atlas(e.dot, "communities-icon-notification") then e.dot:SetColorTexture(1, 0.3, 0.1, 0.9) end
	e.num = e:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	e.num:SetPoint("RIGHT", e.dot, "LEFT", -2, 0)
	e:SetScript("OnClick", function(self) ns.SafeCall("channel click", ChatPane.Select, self.channel) end)
	entries[i] = e
	return e
end

function ChatPane.RenderList()
	if not list then return end
	local chans = Chat.Channels()
	for i, ch in ipairs(chans) do
		local e = Entry(i)
		e.channel = ch
		SetIcon(e.icon, ICONS[ch])
		-- В узком списке «Офицеры гильдии» не влезают: короче, гильдию и так называет подпись.
		e.name:SetText(ch == "O" and L.CHAN_OFFICER_SHORT or Codec.Plain(Chat.Label(ch)))
		e.sub:SetText(Chat.Scope(ch))
		e.sub:SetTextColor(Chat.Color(ch))
		if ch == current then e.sel:Show() else e.sel:Hide() end
		local n = unread[ch] or 0
		e.dot:SetShown(n > 0)
		e.num:SetText(n > 0 and tostring(math.min(n, 99)) or "")
		e:Show()
	end
	for i = #chans + 1, #entries do entries[i]:Hide() end
end

---------------------------------------------------------------------------
-- Сообщения
---------------------------------------------------------------------------
local function AtBottom()
	if not messages or type(messages.AtBottom) ~= "function" then return true end
	return messages:AtBottom() and true or false
end

local function UpdateJump()
	if jump then jump:SetShown(not AtBottom()) end
end

local function AddLine(e)
	local r, g, b = Chat.Color(current)
	messages:AddMessage(Views.ChatLine(e, current, ns.char and ns.char.chatTime), r, g, b)
end

-- Перерисовать сообщения текущего канала из истории.
function ChatPane.Reload()
	if not messages then return end
	messages:Clear()
	local hist = Chat.History(current)
	for i = math.max(1, #hist - MAX_LINES + 1), #hist do AddLine(hist[i]) end
	if messages.ScrollToBottom then messages:ScrollToBottom() end
	if empty then empty:SetShown(#hist == 0) end
	UpdateJump()
end

local function LinkType(link)
	return type(link) == "string" and link:match("^([^:]+)") or nil
end

local function OnLinkEnter(self, link)
	if not TIP_LINKS[LinkType(link) or ""] then return end
	GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
	if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
end

local function OnLinkClick(_, link, text)
	local kind = LinkType(link)
	if kind == "player" then
		local name = link:match("^player:([^:]+)")
		if name then ChatPane.WhisperTo(name) end
	elseif TIP_LINKS[kind or ""] and IsShiftKeyDown and IsShiftKeyDown() and box then
		box:Insert(text)
		box:SetFocus()
	end
end

---------------------------------------------------------------------------
-- Люди справа (CommunitiesMemberListEntryTemplate)
---------------------------------------------------------------------------
local function PeopleRow(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, peopleChild)
	r:SetHeight(PEOPLE_ROW)
	r:SetPoint("TOPLEFT", peopleChild, "TOPLEFT", 0, -(i - 1) * PEOPLE_ROW)
	r:SetPoint("RIGHT", peopleChild, "RIGHT", 0, 0)
	r:SetNormalTexture("Interface\\GuildFrame\\GuildFrame")
	local nt = r:GetNormalTexture()
	if nt then nt:SetTexCoord(0.36230469, 0.38183594, 0.95898438, 0.99804688) end
	r:SetHighlightTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar", "ADD")
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(12, 12)
	r.icon:SetPoint("LEFT", 4, 0)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	r.text:SetPoint("LEFT", 20, 0)
	r.text:SetPoint("RIGHT", TEXT_RIGHT, 0)
	r.right = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	r.right:SetPoint("RIGHT", -4, 0)
	-- Своя колонка между именем и уровнем: имя у тех, у кого аддон есть, короче на значок.
	r.addon = r:CreateTexture(nil, "ARTWORK")
	r.addon:SetSize(ADDON_SIZE, ADDON_SIZE)
	r.addon:SetPoint("RIGHT", TEXT_RIGHT + 2, 0)
	r.addon:SetTexture(ADDON_ICON)
	if r.addon.SetMask then pcall(r.addon.SetMask, r.addon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
	r.addon:Hide()
	r:SetScript("OnEnter", function(self)
		if not self.person then return end
		ns.SafeCall("person tip", Views.PersonTip, Tooltip(self), self.person)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		if self.person then ns.SafeCall("person click", ChatPane.WhisperTo, self.person.name) end
	end)
	rows[i] = r
	return r
end

function ChatPane.RenderPeople()
	peopleDirty = false
	if not peopleChild then return end
	local items, online = Views.People(current)
	for i, p in ipairs(items) do
		local r = PeopleRow(i)
		if p.header then
			r.person = nil
			r.icon:Hide()
			r.addon:Hide()
			r.text:SetPoint("RIGHT", TEXT_RIGHT, 0)
			r.text:SetFontObject("GameFontNormalSmall")
			r.text:SetText(Codec.Plain(p.guild or "?"))
			r.right:SetText(tostring(p.count or ""))
			r:EnableMouse(false)
		else
			r.person = p
			r.text:SetFontObject("GameFontHighlightSmall")
			local name = Codec.Plain(p.name)
			if p.online then
				name = Views.Name(p.name, p.class)
			else
				name = "|cff808080" .. name .. "|r"
			end
			r.text:SetText(name)
			r.addon:SetShown(p.addon == true)
			r.text:SetPoint("RIGHT", p.addon and TEXT_RIGHT_ADDON or TEXT_RIGHT, 0)
			r.right:SetText(p.level and p.level > 0 and tostring(p.level) or "")
			local icon = ROLE_ICON[p.role]
			if icon then
				r.icon:SetTexture(icon)
				r.icon:Show()
			else
				r.icon:Hide()
			end
			r:EnableMouse(true)
		end
		r:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	peopleChild:SetHeight(math.max(#items * PEOPLE_ROW, 10))
	if count then count:SetText(L.WIN_ONLINE:format(ChatPane.Counts(current, items, online))) end
end

-- «В сети: X из Y» под списком людей — про людей этого канала. В чате гильдии — согильдийцы по
-- ростеру (в списке только те, кто в игре); в остальных — люди списка: офицеры гильдии, главы
-- и офицеры гильдий «Чиллзон», писавшие за час. Общий счёт всех гильдий — в шапке окна (UI.lua).
function ChatPane.Counts(channel, items, online)
	if channel == "G" then
		local r = ns.Roster.report
		if r then return r.online or 0, r.total or 0 end
		return 0, 0
	end
	if not items then items, online = Views.People(channel) end
	local n = 0
	for _, p in ipairs(items) do
		if not p.header then n = n + 1 end
	end
	return online or 0, n
end

local function RenderHeader()
	if not title then return end
	title:SetText(Codec.Plain(Chat.Label(current)))
	scope:SetText(Chat.Scope(current, true))
	scope:SetTextColor(Chat.Color(current))
end

---------------------------------------------------------------------------
-- Поле ввода (CommunitiesChatEditBoxTemplate)
---------------------------------------------------------------------------
local function SetPrompt()
	if not box then return end
	local r, g, b = Chat.Color(current)
	prompt:SetText(Codec.Plain(Chat.Prompt(current)) .. ":")
	prompt:SetTextColor(r, g, b)
	box:SetTextColor(r, g, b)
	box:SetTextInsets((prompt:GetStringWidth() or 0) + 8, 4, 0, 0)
	box:SetMaxBytes(BYTES[current] or 255)
end

local function Drafts()
	return ns.char and ns.char.drafts or {}
end

function ChatPane.SubmitBox()
	if not box then return end
	local text = box:GetText() or ""
	if U.Trim(text) == "" then
		box:ClearFocus()
		return
	end
	local ok = Chat.Submit(current, text)
	if ok then
		table.insert(sent, text)
		while #sent > SENT_KEEP do table.remove(sent, 1) end
		sentPos = #sent + 1
		box:SetText("")
		Drafts()[current] = nil
	end
	if ChatPane.Gamepad() then box:ClearFocus() end
end

local function OnArrow(self, key)
	if #sent == 0 then return end
	if key == "UP" then
		sentPos = math.max(1, sentPos - 1)
	elseif key == "DOWN" then
		sentPos = math.min(#sent + 1, sentPos + 1)
	else
		return
	end
	self:SetText(sent[sentPos] or "")
end

-- Шёпот из окна: «/w Имя Фамилия » в нашем поле, курсор в конце.
function ChatPane.WhisperTo(name)
	if not box or type(name) ~= "string" then return end
	name = U.TellName(name) or name
	box:SetText("/w " .. Codec.Plain(name) .. " ")
	box:SetFocus()
end

function ChatPane.Focus()
	if box and shown then box:SetFocus() end
end

-- Дописать в наш черновик текст, вставленный вместе с короткой командой в чат игры.
function ChatPane.Insert(text)
	if box and shown then
		box:Insert(text)
		Drafts()[current] = box:GetText()
	end
end

---------------------------------------------------------------------------
-- Enter при открытом окне — в наше поле (как в Olympus ChatWindow.lua:2721-2766)
---------------------------------------------------------------------------
local boundKeys, syncing = {}, false

local function WantedKeys()
	local keys = rawget(_G, "GetBindingKey")
	local out = {}
	if not shown or ChatPane.Gamepad() or type(keys) ~= "function" then return out end
	for _, key in ipairs({ keys("OPENCHAT") }) do
		if type(key) == "string" and key ~= "" then out[#out + 1] = key end
	end
	return out
end

local function SameKeys(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Привязка Enter к своей кнопке, пока окно открыто; снимается при закрытии. В бою — после боя.
-- Своя же смена привязки шлёт UPDATE_BINDINGS: повтор отсекают SameKeys и флаг syncing.
function ChatPane.SyncKeys()
	if not keyButton or syncing then return end
	local wanted = WantedKeys()
	if SameKeys(wanted, boundKeys) then
		keysPending = false
		return
	end
	if InCombat() then
		keysPending = true
		return
	end
	local clear, set = rawget(_G, "ClearOverrideBindings"), rawget(_G, "SetOverrideBindingClick")
	if type(clear) ~= "function" or type(set) ~= "function" then return end
	syncing = true
	local ok, err = pcall(function()
		clear(keyButton)
		for _, key in ipairs(wanted) do set(keyButton, false, key, "ChillzoneChatKey", "LeftButton") end
	end)
	boundKeys = wanted
	syncing, keysPending = false, false
	if not ok then error(err, 0) end
end

local function KeyPressed()
	if shown and box then
		box:SetFocus()
	elseif not keysCombatSaid then
		-- Окно закрыли в бою: привязку снимем после боя, а пока подскажем один раз.
		keysCombatSaid = true
		ns.Print(L.CHAT_KEY_COMBAT)
	end
end

---------------------------------------------------------------------------
-- Сборка
---------------------------------------------------------------------------
function ChatPane.Build(host)
	if pane then return pane end
	pane = CreateFrame("Frame", nil, host)
	pane:SetAllPoints(host)

	-- Каналы слева: TOPLEFT (-1,-23) → BOTTOMLEFT (170,29).
	list = CreateFrame("Frame", nil, pane)
	list:SetPoint("TOPLEFT", host, "TOPLEFT", -1, -23)
	list:SetPoint("BOTTOMRIGHT", host, "BOTTOMLEFT", 170, 29)
	local bg = list:CreateTexture(nil, "BACKGROUND")
	Menu(bg, 0.00390625, 0.82421875, 0.18554688, 0.58984375)
	bg:SetPoint("TOPLEFT", 2, 0)
	bg:SetPoint("BOTTOMRIGHT", -2, 0)
	local top = list:CreateTexture(nil, "BORDER")
	Menu(top, 0.00390625, 0.72656250, 0.12988281, 0.18359375)
	top:SetSize(155, 55)
	top:SetPoint("TOPLEFT", 14, -6)
	local bottom = list:CreateTexture(nil, "BORDER")
	Menu(bottom, 0.26171875, 0.98437500, 0.06542969, 0.11914063)
	bottom:SetSize(155, 55)
	bottom:SetPoint("BOTTOMLEFT", 14, 1)
	local listInset, real = Template("Frame", list, "InsetFrameTemplate")
	listInset:SetPoint("TOPLEFT", 3, 1)
	listInset:SetPoint("BOTTOMRIGHT", 0, -3)
	if real and listInset.Bg then listInset.Bg:Hide() end
	listInset:EnableMouse(false)

	-- Люди справа: TOPLEFT (-165,-63) → BOTTOMRIGHT (-26,28).
	people = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	people:SetPoint("TOPLEFT", host, "TOPRIGHT", -165, -63)
	people:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -26, 28)
	peopleChild = CreateFrame("Frame", nil, people)
	peopleChild:SetSize(139, 10)
	people:SetScrollChild(peopleChild)
	local peopleBg = people:CreateTexture(nil, "BACKGROUND")
	peopleBg:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
	peopleBg:SetAllPoints(people)
	-- Сколько людей канала в сети — под списком: над ним, справа вверху, шапка окна (UI.lua).
	count = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	count:SetPoint("TOPLEFT", people, "BOTTOMLEFT", 2, -7)

	-- Сообщения: TOPLEFT списка каналов TOPRIGHT (31,-46) → BOTTOMLEFT людей (-22,28).
	chatArea = CreateFrame("Frame", nil, pane)
	chatArea:SetPoint("TOPLEFT", list, "TOPRIGHT", 31, -46)
	chatArea:SetPoint("BOTTOMRIGHT", people, "BOTTOMLEFT", -22, 28)
	local inset, insetReal = Template("Frame", chatArea, "InsetFrameTemplate")
	inset:SetPoint("TOPLEFT", -10, 7)
	inset:SetPoint("BOTTOMRIGHT", 10, -28)
	if not insetReal then
		local shade = inset:CreateTexture(nil, "BACKGROUND")
		shade:SetAllPoints()
		shade:SetColorTexture(0, 0, 0, 0.4)
	end
	title = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("BOTTOMLEFT", inset, "TOPLEFT", 8, 8)
	scope = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	scope:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)

	messages = CreateFrame("ScrollingMessageFrame", nil, chatArea)
	messages:SetAllPoints(chatArea)
	messages:SetFading(false)
	messages:SetFontObject(ChatFontNormal)
	messages:SetJustifyH("LEFT")
	messages:SetHyperlinksEnabled(true)
	if messages.SetIndentedWordWrap then pcall(messages.SetIndentedWordWrap, messages, true) end
	if messages.SetTextCopyable then pcall(messages.SetTextCopyable, messages, true) end
	messages:SetMaxLines(MAX_LINES)
	local chatFrame = rawget(_G, "DEFAULT_CHAT_FRAME")
	if chatFrame and type(chatFrame.GetFont) == "function" then
		local ok, font, size, flags = pcall(chatFrame.GetFont, chatFrame)
		if ok and font then messages:SetFont(font, size, flags) end
	end
	messages:EnableMouseWheel(true)
	messages:SetScript("OnMouseWheel", function(self, delta)
		for _ = 1, 3 do
			if delta > 0 then self:ScrollUp() else self:ScrollDown() end
		end
		UpdateJump()
	end)
	messages:SetScript("OnHyperlinkEnter", OnLinkEnter)
	messages:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	messages:SetScript("OnHyperlinkClick", function(...) ns.SafeCall("chat link", OnLinkClick, ...) end)
	local bar, barReal = Template("EventFrame", chatArea, "MinimalScrollBar")
	local SU = rawget(_G, "ScrollUtil")
	if barReal and type(SU) == "table" and type(SU.InitScrollingMessageFrameWithScrollBar) == "function" then
		bar:SetPoint("TOPLEFT", messages, "TOPRIGHT", 4, 0)
		bar:SetPoint("BOTTOMLEFT", messages, "BOTTOMRIGHT", 4, 0)
		if not pcall(SU.InitScrollingMessageFrameWithScrollBar, messages, bar) then bar:Hide() end
	else
		bar:Hide()
	end
	jump = CreateFrame("Button", nil, chatArea, "UIPanelButtonTemplate")
	jump:SetSize(120, 22)
	jump:SetPoint("BOTTOMRIGHT", messages, "BOTTOMRIGHT", -10, 4)
	jump:SetText(L.WIN_JUMP)
	jump:SetScript("OnClick", function()
		messages:ScrollToBottom()
		UpdateJump()
	end)
	jump:Hide()
	empty = chatArea:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("CENTER", chatArea, "CENTER", 0, 0)
	empty:SetText(L.WIN_EMPTY)

	-- Поле ввода: под сообщениями, рамка UI-ChatInputBorder-*2.
	box = CreateFrame("EditBox", nil, pane)
	box:SetPoint("TOPLEFT", chatArea, "BOTTOMLEFT", -4, -4)
	box:SetPoint("TOPRIGHT", chatArea, "BOTTOMRIGHT", 3, -4)
	box:SetHeight(32)
	box:SetFrameLevel((pane:GetFrameLevel() or 1) + 20)
	local left = box:CreateTexture(nil, "BACKGROUND")
	left:SetTexture("Interface\\ChatFrame\\UI-ChatInputBorder-Left2")
	left:SetSize(32, 32)
	left:SetPoint("LEFT", -10, 0)
	local right = box:CreateTexture(nil, "BACKGROUND")
	right:SetTexture("Interface\\ChatFrame\\UI-ChatInputBorder-Right2")
	right:SetSize(32, 32)
	right:SetPoint("RIGHT", 10, 0)
	local mid = box:CreateTexture(nil, "BACKGROUND")
	mid:SetTexture("Interface\\ChatFrame\\UI-ChatInputBorder-Mid2", true)
	if mid.SetHorizTile then mid:SetHorizTile(true) end
	mid:SetHeight(32)
	mid:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
	mid:SetPoint("TOPRIGHT", right, "TOPLEFT", 0, 0)
	box:SetFontObject(ChatFontNormal)
	box:SetAutoFocus(false)
	box:SetAltArrowKeyMode(false)
	box:SetHistoryLines(0)
	prompt = box:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	prompt:SetPoint("LEFT", 4, 0)
	box:SetScript("OnEnterPressed", function() ns.SafeCall("chat box", ChatPane.SubmitBox) end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnTabPressed", function()
		local chans, at = Chat.Channels(), 1
		for i, ch in ipairs(chans) do if ch == current then at = i end end
		local step = (IsShiftKeyDown and IsShiftKeyDown()) and -1 or 1
		local nextCh = chans[(at - 1 + step) % #chans + 1]
		if nextCh then ns.SafeCall("chat tab", ChatPane.Select, nextCh, true) end
	end)
	box:SetScript("OnArrowPressed", OnArrow)
	box:SetScript("OnTextChanged", function(self, user)
		if user then Drafts()[current] = self:GetText() end
	end)

	-- Shift-клик предмета из сумки, пока наше поле в фокусе (пост-хук — функция игры остаётся её).
	local hook = rawget(_G, "hooksecurefunc")
	if type(hook) == "function" then
		pcall(hook, "ChatEdit_InsertLink", function(text)
			if box and shown and type(text) == "string" and box:HasFocus() then box:Insert(text) end
		end)
	end

	keyButton = CreateFrame("Button", "ChillzoneChatKey", UIParent)
	keyButton:RegisterForClicks("AnyDown")
	keyButton:SetScript("OnClick", function() ns.SafeCall("chat key", KeyPressed) end)

	pane:SetScript("OnUpdate", function(_, dt)
		peopleElapsed = peopleElapsed + (dt or 0)
		if peopleDirty and peopleElapsed >= 1 then
			peopleElapsed = 0
			ns.SafeCall("people", ChatPane.RenderPeople)
			RenderHeader()
		end
	end)
	pane:Hide()
	ChatPane.frames = { pane = pane, messages = messages, box = box, keyButton = keyButton, entries = entries, rows = rows, title = title, scope = scope, prompt = prompt, count = count }
	return pane
end

-- Выбрать канал. Недоступный канал заменяется первым доступным.
function ChatPane.Select(channel, keepFocus)
	local chans = Chat.Channels()
	local ok = false
	for _, ch in ipairs(chans) do if ch == channel then ok = true end end
	if not ok then channel = chans[1] or "A" end
	if box and channel ~= current then Drafts()[current] = box:GetText() end
	current = channel
	if ns.char then ns.char.chatChannel = channel end
	unread[channel] = 0
	if not pane then return end
	ChatPane.Reload()
	if box then
		box:SetText(Drafts()[channel] or "")
		SetPrompt()
		if #chans == 0 then box:Hide() else box:Show() end
		if keepFocus then box:SetFocus() end
	end
	if #chans == 0 and empty then
		empty:SetText(L.WIN_NO_CHANNELS)
		empty:Show()
	elseif empty then
		empty:SetText(L.WIN_EMPTY)
	end
	ChatPane.RenderList()
	RenderHeader()
	ChatPane.RenderPeople()
end

function ChatPane.Show()
	if not pane then return end
	shown = true
	pane:Show()
	ChatPane.Select(current ~= "" and current or "A")
	ChatPane.SyncKeys()
end

function ChatPane.Hide()
	shown = false
	if not pane then return end
	if box then box:ClearFocus() end
	pane:Hide()
	ChatPane.SyncKeys()
end

---------------------------------------------------------------------------
-- События
---------------------------------------------------------------------------
ns.On("CHAT", function(channel, e)
	if ChatPane.Visible(channel) then
		local bottom = AtBottom()
		AddLine(e)
		if empty then empty:Hide() end
		if not bottom then UpdateJump() end
		peopleDirty = true
		return
	end
	if e and ns.IsMe(e.s) then return end
	unread[channel] = (unread[channel] or 0) + 1
	if shown then ChatPane.RenderList() end
end)

local function Dirty()
	peopleDirty = true
	if shown then ChatPane.RenderList() end
end
ns.On("DATA", Dirty)
ns.On("ROSTER", Dirty)
ns.On("PEERS", function() peopleDirty = true end)
ns.On("GUILD_CHANGED", function()
	if shown then ChatPane.Select(current) end
end)

ns.On("LOGIN", function()
	local saved = ns.char and ns.char.chatChannel
	if type(saved) == "string" and saved ~= "" then current = saved end
end)

ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
	keysCombatSaid = false
	if keysPending then ChatPane.SyncKeys() end
end)
ns.RegisterEvent("UPDATE_BINDINGS", function()
	if keyButton and (shown or #boundKeys > 0) then ChatPane.SyncKeys() end
end)
