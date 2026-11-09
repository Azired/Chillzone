-- Отдельная вкладка общего чата. У неактивной штатной строки временно меняем только прозрачность.
local ADDON, ns = ...

local Chat, L, U = ns.Chat, ns.L, ns.Util
local ChatTab = {}
ns.ChatTab = ChatTab

local input, anchor, layoutAnchor, hostedAnchor, ticker
local mutedNative, nativeAlpha
local inputInset, smileButton, smileTarget, hookedPicker
local selectionHooks = {}
local stopped = false

-- OpenChat сам направляет Enter в это поле, а команды со слэшем оставляет игре.
local function FocusAPI()
	local api = rawget(_G, "ChatFrameUtil")
	if type(api) == "table" and type(api.SetChatFocusOverride) == "function"
		and type(api.GetChatFocusOverride) == "function" and type(api.ClearChatFocusOverride) == "function" then
		return api
	end
end

local function ReleaseFocusOverride()
	local api = FocusAPI()
	if api and input and api.GetChatFocusOverride() == input then api.ClearChatFocusOverride() end
end

local function FindWindow(name)
	for _, window in ipairs(Chat.Windows()) do
		if U.Fold(window.name) == U.Fold(name) then return window end
	end
end

-- В некоторых клиентах штатная функция при полном ряду может перезаписать последнюю вкладку.
local function HasFreeWindow()
	local info = rawget(_G, "FCF_GetChatWindowInfo") or rawget(_G, "GetChatWindowInfo")
	if type(info) ~= "function" then return nil end
	local constants = rawget(_G, "Constants")
	local chatConstants = type(constants) == "table" and constants.ChatFrameConstants
	local count = type(chatConstants) == "table" and tonumber(chatConstants.MaxChatWindows)
	count = count or tonumber(rawget(_G, "NUM_CHAT_WINDOWS")) or 10
	local builtin = rawget(_G, "IsBuiltinChatWindow")
	for i = 3, count do
		local frame = rawget(_G, "ChatFrame" .. i)
		local tab = rawget(_G, "ChatFrame" .. i .. "Tab")
		if type(frame) == "table" and tab and not rawget(frame, "isDocked")
			and (type(builtin) ~= "function" or not builtin(frame)) then
			local ok, name, _, _, _, _, _, shown, _, docked = pcall(info, i)
			if ok and type(name) == "string" and not shown and not docked then return true end
		end
	end
	return false
end

local function SelectedInDock(dock)
	local get = rawget(_G, "FCFDock_GetSelectedWindow")
	if dock and type(get) == "function" then return get(dock) end
	return rawget(_G, "SELECTED_DOCK_FRAME") or rawget(_G, "SELECTED_CHAT_FRAME")
end

local function NativeInputFocused(box)
	return box and box:IsVisible() and (type(box.HasFocus) ~= "function" or box:HasFocus())
end

local function ChattynatorLoaded()
	return type(rawget(_G, "Chattynator")) == "table"
end

local function HostedWindow()
	if not ns.ChattynatorTab then return end
	if FocusAPI() then return ns.ChattynatorTab.InputHost() end
	return ns.ChattynatorTab.ActiveHost(), true
end

local function IsSelected(frame, hosted)
	if not frame or not frame:IsVisible() then return false end
	if hosted then return HostedWindow() == frame end
	return SelectedInDock(rawget(_G, "GENERAL_CHAT_DOCK")) == frame
end

local function NativeInput(frame, hosted)
	if hosted then
		-- Chattynator держит штатную строку только у первого окна.
		local holder = frame:GetParent()
		local window = holder and holder:GetParent()
		if window and type(window.GetID) == "function" and window:GetID() == 1 then
			local native = rawget(_G, "ChatFrame1EditBox")
			if native and native:IsVisible() then return native end
		end
		return
	end
	local native = rawget(frame, "editBox")
	if native and native:IsVisible() then return native end
	-- В режиме постоянной строки её может держать последняя активная вкладка этого ряда.
	local last = rawget(_G, "LAST_ACTIVE_CHAT_EDIT_BOX")
	local owner = last and rawget(last, "chatFrame")
	if owner and rawget(owner, "isDocked") and last:IsVisible() then return last end
end

local function RestoreNative()
	if not mutedNative then return true end
	-- При получении фокуса WoW сам ставит новую прозрачность. Она важнее сохранённой.
	if mutedNative:GetAlpha() == 0 then
		pcall(mutedNative.SetAlpha, mutedNative, nativeAlpha)
		if mutedNative:GetAlpha() == 0 then return false end
	end
	mutedNative, nativeAlpha = nil, nil
	return true
end

local function MuteNative(native)
	if mutedNative ~= native and not RestoreNative() then return false end
	if not native then return true end
	if type(native.GetAlpha) ~= "function" or type(native.SetAlpha) ~= "function" then return false end
	local alpha = native:GetAlpha()
	if type(alpha) ~= "number" then return false end
	if alpha == 0 then return true end
	local ok = pcall(native.SetAlpha, native, 0)
	if native:GetAlpha() ~= 0 then return false end
	mutedNative, nativeAlpha = native, alpha
	return ok
end

-- Открытая вкладка союза принимает строки и в фоне, независимо от дополнительных копий.
function ChatTab.OutputFrame()
	local char = ns.char
	if ChattynatorLoaded() or not char or type(char.chatTab) ~= "string"
		or not char.chatOn or not ns.IsMember() then return end
	local window = FindWindow(char.chatTab)
	return window and window.frame
end

local function SelectedWindow()
	local char = ns.char
	if not char or not char.chatOn or not ns.IsMember() then return end
	local host, hosted = HostedWindow()
	local frame = host or ChatTab.OutputFrame()
	if not host then hosted = false end
	-- Выбор вкладок для копий не меняет их штатный ввод.
	if not IsSelected(frame, hosted) then return end
	-- Штатный ввод с фокусом остаётся доступным для команд игры.
	local native = NativeInput(frame, hosted)
	if NativeInputFocused(rawget(_G, "ACTIVE_CHAT_EDIT_BOX")) or NativeInputFocused(native) then return end
	return frame, native, hosted
end

function ChatTab.InputFor(frame)
	if input and input:IsShown() and anchor and (not frame or frame == anchor)
		and SelectedWindow() == anchor then return input end
end

function ChatTab.FocusedInput()
	local box = ChatTab.InputFor()
	if box and box:HasFocus() then return box end
end

-- Hepega 0.9.0 уже рисует свои смайлы в строках Chillzone. Его окно выбора
-- ищет поле ввода через GetActiveEditBox, отдельного API для стороннего поля нет.
local function SmilePicker()
	local addon = rawget(_G, "ForeverSmileChat")
	local picker = rawget(_G, "ForeverSmileChatPicker")
	if type(addon) == "table" and addon.VERSION == "0.9.0" and type(addon.DB) == "table"
		and type(addon.PATH) == "string" and type(addon.GetActiveEditBox) == "function"
		and type(addon.TogglePicker) == "function" and picker and type(picker.HookScript) == "function" then
		return addon, picker
	end
end

local function ReleaseSmilePicker(close)
	local target = smileTarget
	if not target then return end
	smileTarget = nil
	if target.addon.GetActiveEditBox == target.route then
		target.addon.GetActiveEditBox = target.original
	end
	if close and target.picker:IsShown() then target.picker:Hide() end
end

-- При клике сразу после смены вкладки Hepega не должен искать запасное поле в обычном чате.
local discardedSmile = {
	IsShown = function() return true end,
	SetFocus = function() end,
	Insert = function() end,
}

local function ToggleSmilePicker()
	if smileTarget then ReleaseSmilePicker(true); return end
	if not input:IsShown() or SelectedWindow() ~= anchor then return end
	local addon, picker = SmilePicker()
	if not addon then return end
	if hookedPicker ~= picker then
		picker:HookScript("OnHide", function(self)
			if smileTarget and smileTarget.picker == self then ReleaseSmilePicker(false) end
		end)
		hookedPicker = picker
	end
	local target = { addon = addon, picker = picker, original = addon.GetActiveEditBox }
	function target.route(self, ...)
		if smileTarget ~= target then return target.original(self, ...) end
		if input:IsShown() and SelectedWindow() == anchor then return input end
		return discardedSmile
	end
	smileTarget = target
	addon.GetActiveEditBox = target.route
	if not picker:IsShown() then
		local ok = pcall(addon.TogglePicker, addon)
		if not ok or not picker:IsShown() then ReleaseSmilePicker(true) end
	end
end

local function AddSmileButton()
	if smileButton then return end
	local addon = SmilePicker()
	if not addon then return end
	local button = CreateFrame("Button", nil, input)
	button:SetSize(16, 16)
	button:SetPoint("RIGHT", -6, 0)
	button:SetNormalTexture(addon.PATH .. "Textures\\button.tga")
	button:SetScript("OnClick", function() ns.SafeCall("chat tab smiles", ToggleSmilePicker) end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L.CHAT_TAB_SMILES)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	input:SetTextInsets(inputInset, 28, 0, 0)
	smileButton = button
end

local function HideInput()
	ReleaseFocusOverride()
	ReleaseSmilePicker(true)
	if input and input:IsShown() then
		input:ClearFocus()
		input:Hide()
	end
	RestoreNative()
end

-- Слэш можно набрать уже после Enter: собственное поле не разбирает команды WoW.
-- Передаём текст штатному OpenChat, не меняя скрипты, атрибуты и методы игрового поля.
local function OpenNativeCommand()
	if not input:IsShown() or not input:HasFocus() or SelectedWindow() ~= anchor then return false end
	local text = input:GetText() or ""
	if text:sub(1, 1) ~= "/" then return false end
	local api = rawget(_G, "ChatFrameUtil")
	local open = type(api) == "table" and api.OpenChat
	if type(open) ~= "function" then open = rawget(_G, "ChatFrame_OpenChat") end
	if type(open) ~= "function" then return false end
	local cursor = type(input.GetCursorPosition) == "function" and input:GetCursorPosition() or nil
	-- Контейнер Chattynator не является штатным ChatFrame.
	local frame = hostedAnchor and DEFAULT_CHAT_FRAME or anchor
	HideInput()
	open(text, frame, cursor)
	input:SetText("")
	return true
end

local function Submit()
	if not input:IsShown() or SelectedWindow() ~= anchor then
		HideInput()
		return
	end
	if OpenNativeCommand() then return end
	local text = input:GetText() or ""
	if U.Trim(text) == "" then input:ClearFocus(); return end
	if Chat.Submit("A", text) then
		input:SetText("")
		input:ClearFocus()
		ReleaseSmilePicker(true)
	end
end

local function CreateInput()
	local box = CreateFrame("EditBox", nil, UIParent, "InputBoxTemplate")
	box.supportsSlashCommands = false
	box:SetAutoFocus(false)
	box:EnableMouse(true)
	box:SetHeight(24)
	box:SetClampedToScreen(true)
	box:SetFrameStrata("DIALOG")
	box:SetFontObject(ChatFontNormal)
	box:SetMaxBytes(ns.Config.CHAT_PART * ns.Config.CHAT_PARTS)
	local prompt = box:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	prompt:SetPoint("LEFT", 7, 0)
	prompt:SetText(L.CHAT_TAB_PROMPT)
	prompt:SetTextColor(Chat.Color("A"))
	inputInset = prompt:GetStringWidth() + 14
	box:SetTextInsets(inputInset, 6, 0, 0)
	box:SetScript("OnTextChanged", function(_, user)
		if user then ns.SafeCall("chat tab command", OpenNativeCommand) end
	end)
	box:SetScript("OnEnterPressed", function() ns.SafeCall("chat tab input", Submit) end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- Убираем своё поле сразу при смене вкладки или открытии штатного ввода.
	box:SetScript("OnUpdate", function()
		local native = anchor and NativeInput(anchor, hostedAnchor)
		local target = hostedAnchor == true and anchor or native or anchor
		if not IsSelected(anchor, hostedAnchor) or target ~= layoutAnchor
			or NativeInputFocused(rawget(_G, "ACTIVE_CHAT_EDIT_BOX"))
			or NativeInputFocused(native) or not MuteNative(native) then
			HideInput()
		end
	end)
	box:Hide()
	return box
end

local function Refresh()
	local frame, native, hosted = SelectedWindow()
	if not frame then HideInput(); return end
	if not input then input = CreateInput() end
	AddSmileButton()
	local target = hosted == true and frame or native or frame
	if layoutAnchor ~= target or not input:IsShown() then
		input:ClearAllPoints()
		if hosted == true then
			input:SetHeight(24)
			input:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 3)
			input:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 3)
		elseif native then
			input:SetAllPoints(native)
		else
			input:SetHeight(24)
			input:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 4, -5)
			input:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -4, -5)
		end
		input:SetFrameLevel((target:GetFrameLevel() or 0) + 1)
	end
	if not MuteNative(native) then HideInput(); return end
	anchor, layoutAnchor, hostedAnchor = frame, target, hosted
	if not input:IsShown() then input:Show() end
	local api = FocusAPI()
	if api then
		local current = api.GetChatFocusOverride()
		if not current or current == input then api.SetChatFocusOverride(input) end
	end
end

local function Track(defer)
	if stopped then return end
	local hook = rawget(_G, "hooksecurefunc")
	if type(hook) == "function" then
		for _, name in ipairs({ "FCF_SelectDockFrame", "FCFDock_SelectWindow", "FCF_Tab_OnClick" }) do
			local fn = rawget(_G, name)
			if type(fn) == "function" and not selectionHooks[name] then
				local ok = pcall(hook, name, function() ns.SafeCall("chat tab selection", Refresh) end)
				if ok then selectionHooks[name] = true end
			end
		end
	end
	if not ticker and ns.char and (FocusAPI() or type(ns.char.chatTab) == "string" or HostedWindow()) then
		ticker = ns.Every(0.15, "chat tab", Refresh, true)
	end
	if ticker and not defer then Refresh() end
end

local function Failed(message)
	ns.Print(message)
	return false
end

function ChatTab.Open()
	if not ns.IsMember() then return Failed(L.CHAT_TAB_NOT_MEMBER) end
	if not ns.char.chatOn then return Failed(L.CHAT_TAB_DISABLED) end
	if ChattynatorLoaded() then
		if ns.ChattynatorTab and ns.ChattynatorTab.Available() then return Failed(L.CHAT_TAB_CHATTY_HELP) end
		return Failed(L.CHAT_TAB_CHATTY_UNAVAILABLE)
	end
	if InCombatLockdown and InCombatLockdown() then return Failed(L.CHAT_TAB_COMBAT) end
	local dock = rawget(_G, "GENERAL_CHAT_DOCK")
	if not dock or type(dock.IsVisible) ~= "function" or not dock:IsVisible() then
		return Failed(L.CHAT_TAB_UNAVAILABLE)
	end
	local window = FindWindow(L.CHAT_TAB_NAME)
	if not window then
		local open = rawget(_G, "FCF_OpenNewWindow")
		if type(open) ~= "function" then return Failed(L.CHAT_TAB_UNAVAILABLE) end
		local free = HasFreeWindow()
		if free == nil then return Failed(L.CHAT_TAB_UNAVAILABLE) end
		if not free then return Failed(L.CHAT_TAB_FULL) end
		local ok, frame = pcall(open, L.CHAT_TAB_NAME, true)
		window = ok and frame and FindWindow(L.CHAT_TAB_NAME)
		if not window or window.frame ~= frame then return Failed(L.CHAT_TAB_UNAVAILABLE) end
	end
	if not rawget(window.frame, "isDocked") then return Failed(L.CHAT_TAB_DOCK) end
	if SelectedInDock(dock) ~= window.frame then
		local select = rawget(_G, "FCF_SelectDockFrame")
		local dockSelect = rawget(_G, "FCFDock_SelectWindow")
		if type(select) == "function" then pcall(select, window.frame)
		elseif type(dockSelect) == "function" then pcall(dockSelect, dock, window.frame) end
	end
	if SelectedInDock(dock) ~= window.frame or not window.frame:IsVisible() then
		return Failed(L.CHAT_TAB_UNAVAILABLE)
	end
	ns.char.chatTab = window.name
	ns.Fire("SETTINGS")
	return true
end

ns.On("LOGIN", function() stopped = false; Track(true) end)
ns.On("SETTINGS", Track)
ns.On("CHAT_WINDOWS", function() Track() end)
ns.On("UNION", function() Track() end)
ns.On("GUILD_CHANGED", Track)
ns.On("CHATTYNATOR_TAB", Track)
ns.RegisterEvent("PLAYER_LOGOUT", function()
	stopped = true
	if ticker then ticker.Cancel(); ticker = nil end
	HideInput()
end)
