-- Вкладка союза в контейнере, который выдаёт публичный API Chattynator.
local ADDON, ns = ...

local Chat, Codec, L = ns.Chat, ns.Codec, ns.L
local ChattynatorTab = {}
ns.ChattynatorTab = ChattynatorTab

local panels, active, registered = {}, nil, nil

local function ReadWarning()
	if not ns.IsMember() then return L.CHAT_TAB_NOT_MEMBER end
	if not ns.char or not ns.char.chatOn then return L.CHAT_TAB_DISABLED end
	return false
end

local function ReplaceEmotes(body, addon, messages)
	local size = addon:GetChatEmoteSize(messages)
	local function Replace(word)
		local emote = addon.Lookup[word]
		if emote and addon:IsEnabled(word) then
			return addon:GetEmoteMarkup(emote, size, 0)
		end
	end

	-- Текст уже очищен. Обрабатываем слова между ссылками, сохраняя ссылки целиком.
	local parts, start, pos = {}, 1, 1
	while true do
		local pipe = body:find("|", pos, true)
		if not pipe then break end
		if body:sub(pipe + 1, pipe + 1) == "|" then
			pos = pipe + 2
		else
			local length = Codec.LinkAt(body, pipe)
			pos = pipe + (length or 1)
			if length then
				parts[#parts + 1] = body:sub(start, pipe - 1):gsub("%S+", Replace)
				parts[#parts + 1] = body:sub(pipe, pos - 1)
				start = pos
			end
		end
	end
	parts[#parts + 1] = body:sub(start):gsub("%S+", Replace)
	return table.concat(parts)
end

local function FormatEmotes(body, messages)
	local addon = rawget(_G, "ForeverSmileChat")
	if type(addon) ~= "table" or addon.VERSION ~= "0.9.0" or type(addon.DB) ~= "table"
		or not addon.DB.enabled or type(addon.Lookup) ~= "table"
		or type(addon.IsEnabled) ~= "function" or type(addon.GetChatEmoteSize) ~= "function"
		or type(addon.GetEmoteMarkup) ~= "function" then return body end
	local ok, formatted = pcall(ReplaceEmotes, body, addon, messages)
	return ok and formatted or body
end

local function AddLine(messages, entry)
	local line = Chat.Format("A", entry.g, entry.s, entry.c, entry.x, function(body)
		return FormatEmotes(body, messages)
	end)
	if ns.char and ns.char.chatTime and date then
		line = "|cff999999" .. date("%H:%M", entry.t) .. "|r " .. line
	end
	messages:AddMessage(line, Chat.Color("A"))
end

local function Render(panel, warning)
	local messages = panel.messages
	messages:Clear()
	if warning then
		messages:AddMessage(warning)
	else
		for _, entry in ipairs(Chat.History("A")) do AddLine(messages, entry) end
	end
	messages:ScrollToBottom()
	panel.dirty, panel.readWarning = false, warning
end

local function SelectPanel(panel)
	if not panel:IsVisible() then return end
	if panel.dirty then Render(panel, ReadWarning()) end
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
		ns.ChatLinks.Attach(messages, function() return ns.ChatTab.InputFor(panel) end)
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

local function Refresh(onlyChanged)
	local warning = ReadWarning()
	for _, panel in pairs(panels) do
		if not onlyChanged or panel.readWarning ~= warning then
			if panel:IsVisible() then Render(panel, warning) else panel.dirty = true end
		end
	end
end

ns.On("CHAT", function(channel, entry)
	if channel ~= "A" then return end
	local warning = ReadWarning()
	for _, panel in pairs(panels) do
		if panel:IsVisible() and not warning then AddLine(panel.messages, entry) else panel.dirty = true end
	end
end)
ns.On("SETTINGS", function() Refresh() end)
ns.On("GUILD_CHANGED", function() Refresh() end)
-- Продление решения о составе союза не должно сбрасывать прокрутку открытой вкладки.
ns.On("UNION", function() Refresh(true) end)
ns.On("LOGIN", function()
	ChattynatorTab.Register()
	Refresh()
end)
ns.RegisterEvent("ADDON_LOADED", function(name)
	if name == ADDON or name == "Chattynator" then ChattynatorTab.Register() end
end)
ChattynatorTab.Register()
