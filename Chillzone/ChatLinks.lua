-- Ссылки в собственных окнах чата. Игровое поле ввода остаётся под управлением WoW.
local ADDON, ns = ...

local Codec, U = ns.Codec, ns.Util
local ChatLinks = {}
ns.ChatLinks = ChatLinks

local itemLinks = { item = true, spell = true, enchant = true, quest = true, talent = true }

local function LinkType(link)
	return type(link) == "string" and link:match("^([^:]+)") or nil
end

local function Insert(box, text)
	if not box or type(text) ~= "string" or Codec.LinkAt(text, 1) ~= #text then return false end
	box:Insert(text)
	return true
end

function ChatLinks.Whisper(box, name)
	if not box or type(name) ~= "string" or name == "" then return end
	box:SetText("/w " .. Codec.Plain(U.TellName(name) or name) .. " ")
	box:SetFocus()
end

local function OpenItem(link)
	local tooltip = rawget(_G, "ItemRefTooltip")
	if not tooltip or type(tooltip.ItemRefSetHyperlink) ~= "function" then return end
	if not tooltip:IsShown() then tooltip:SetOwner(UIParent, "ANCHOR_PRESERVE") end
	tooltip:ItemRefSetHyperlink(link)
	tooltip:Show()
end

local function OnClick(getBox, link, text, button)
	local kind = LinkType(link)
	if kind == "addon" and button == "RightButton" then
		ns.Chat.TagClick(link, text, button)
	elseif kind == "addon" and ns.Chat.TagTier(link, button) == "A" then
		local box = getBox()
		if box then box:SetFocus() end
	elseif kind == "player" then
		local name = link:match("^player:([^:]+)")
		if not name then return end
		if button == "RightButton" then
			-- Меню получает имя без привязки к нашему ScrollingMessageFrame.
			local menu = rawget(_G, "FriendsFrame_ShowDropdown")
			if type(menu) == "function" then menu(U.TellName(name) or name, 1) end
		elseif not button or button == "LeftButton" then
			ChatLinks.Whisper(getBox(), name)
		end
	elseif itemLinks[kind or ""] and (not button or button == "LeftButton") then
		local modified = rawget(_G, "IsModifiedClick")
		local linking = type(modified) == "function" and modified("CHATLINK")
		if type(modified) ~= "function" and IsShiftKeyDown then linking = IsShiftKeyDown() end
		if linking then
			local box = getBox()
			if Insert(box, text) then box:SetFocus() end
		else
			OpenItem(link)
		end
	end
end

function ChatLinks.Attach(messages, getBox)
	messages:SetScript("OnHyperlinkEnter", function(self, link)
		if not itemLinks[LinkType(link) or ""] then return end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
	end)
	messages:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	messages:SetScript("OnHyperlinkClick", function(_, link, text, button)
		ns.SafeCall("chat link", OnClick, getBox, link, text, button)
	end)
end

local function OnInsertLink(text)
	local box = ns.ChatTab and ns.ChatTab.FocusedInput()
	if not box and ns.ChatPane then box = ns.ChatPane.FocusedInput() end
	Insert(box, text)
end

ns.On("LOGIN", function()
	local hook = rawget(_G, "hooksecurefunc")
	if type(hook) ~= "function" then return end
	-- В Forever сумки вызывают метод напрямую. Старый глобал — запасной путь.
	local chat = rawget(_G, "ChatFrameUtil")
	if type(chat) == "table" and type(chat.InsertLink) == "function" then
		pcall(hook, chat, "InsertLink", OnInsertLink)
	else
		pcall(hook, "ChatEdit_InsertLink", OnInsertLink)
	end
end)
