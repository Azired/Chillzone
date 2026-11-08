-- Вкладка союза в контейнере, который выдаёт публичный API Chattynator.
local ADDON, ns = ...

local Chat, L = ns.Chat, ns.L
local ChattynatorTab = {}
ns.ChattynatorTab = ChattynatorTab

local panels, active, registered = {}, nil, nil
local tooltipLinks = { item = true, spell = true, enchant = true, quest = true, talent = true }

local function CanRead()
	return ns.char and ns.char.chatOn and ns.IsMember()
end

local function AddLine(messages, entry)
	messages:AddMessage(Chat.Format("A", entry.g, entry.s, entry.c, entry.x), Chat.Color("A"))
end

local function Render(panel)
	local messages = panel.messages
	messages:Clear()
	if CanRead() then
		for _, entry in ipairs(Chat.History("A")) do AddLine(messages, entry) end
	else
		messages:AddMessage(ns.IsMember() and L.CHAT_TAB_DISABLED or L.CHAT_TAB_NOT_MEMBER)
	end
	messages:ScrollToBottom()
	panel.dirty = false
end

local function SelectPanel(panel)
	if not panel:IsVisible() then return end
	if panel.dirty then Render(panel) end
	if active ~= panel then
		active = panel
		ns.Fire("CHATTYNATOR_TAB")
	end
end

local function OnHide(panel)
	if active ~= panel then return end
	active = nil
	for _, other in pairs(panels) do
		if other ~= panel and other:IsVisible() then active = other; break end
	end
	ns.Fire("CHATTYNATOR_TAB")
end

local function Install(parent)
	local panel = panels[parent]
	if not panel then
		panel = CreateFrame("Frame", nil, parent)
		panel:SetAllPoints(parent)
		local messages = CreateFrame("ScrollingMessageFrame", nil, panel)
		messages:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -3)
		-- Снизу остаётся место для собственного поля ввода Chillzone.
		messages:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 30)
		messages:SetFontObject(ChatFontNormal)
		messages:SetJustifyH("LEFT")
		messages:SetMaxLines(ns.Config.CHAT_HISTORY)
		messages:SetFading(false)
		messages:SetHyperlinksEnabled(true)
		messages:EnableMouseWheel(true)
		messages:SetScript("OnMouseWheel", function(self, delta)
			if delta > 0 then self:ScrollUp() else self:ScrollDown() end
		end)
		messages:SetScript("OnHyperlinkEnter", function(self, link)
			if type(link) ~= "string" or not tooltipLinks[link:match("^([^:]+)") or ""] then return end
			GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
			if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
		end)
		messages:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
		panel.messages, panel.dirty = messages, true
		panels[parent] = panel
		panel:SetScript("OnShow", function(self) ns.SafeCall("chattynator tab show", SelectPanel, self) end)
		panel:SetScript("OnHide", OnHide)
	end
	panel:Show()
	SelectPanel(panel)
end

local function API()
	local addon = rawget(_G, "Chattynator")
	local api = type(addon) == "table" and addon.API
	if type(api) == "table" and type(api.RegisterCustomTab) == "function" then return api end
end

function ChattynatorTab.Available()
	return registered ~= nil and registered == API()
end

function ChattynatorTab.ActiveHost()
	if active and active:IsVisible() then return active end
end

function ChattynatorTab.Register()
	local api = API()
	if not api then return false end
	if registered == api then return true end
	local ok = pcall(api.RegisterCustomTab, L.CHAT_TAB_NAME, "chillzone_union", function(parent)
		if parent then ns.SafeCall("chattynator tab install", Install, parent) end
	end)
	if ok then registered = api end
	return ok
end

local function Refresh()
	for _, panel in pairs(panels) do
		if panel:IsVisible() then Render(panel) else panel.dirty = true end
	end
end

ns.On("CHAT", function(channel, entry)
	if channel ~= "A" then return end
	for _, panel in pairs(panels) do
		if panel:IsVisible() and CanRead() then AddLine(panel.messages, entry) else panel.dirty = true end
	end
end)
ns.On("SETTINGS", Refresh)
ns.On("GUILD_CHANGED", Refresh)
ns.On("LOGIN", function()
	ChattynatorTab.Register()
	Refresh()
end)
ns.RegisterEvent("ADDON_LOADED", function(name)
	if name == ADDON or name == "Chattynator" then ChattynatorTab.Register() end
end)
ChattynatorTab.Register()
