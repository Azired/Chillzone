-- Chillzone: переключатель кругов на карте. Общий ряд кнопок используется только
-- через уже загруженный Krowi; ручное положение не зависит от других аддонов.
local ADDON, ns = ...

local L = ns.L
local Controls = {}
ns.MapControls = Controls

local SIZE = 31
local ready, hooked, manager, dragging, hover, blocked = false, nil, nil, nil, false, false
local refreshing = false
local reflow, openMapAPI = false, nil

local function Locked()
	return InCombatLockdown and InCombatLockdown()
end

local function Number(n)
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function Saved()
	local pos = ns.db.settings.mapButton
	if type(pos) == "table" and Number(pos.x) and Number(pos.y) then return pos end
end

local function Canvas()
	local map = WorldMapFrame
	return (map.GetCanvasContainer and map:GetCanvasContainer()) or map.ScrollContainer or map
end

local function Clamp(value, extent)
	local margin = math.min(SIZE / 2 + 3, extent / 2)
	return math.max(margin / extent, math.min(1 - margin / extent, value))
end

local function Place(pos)
	local canvas, b = Canvas(), Controls.button
	local w, h = canvas:GetWidth(), canvas:GetHeight()
	if not (Number(w) and w > 0 and Number(h) and h > 0) then return end
	local x, y = Clamp(pos.x, w), Clamp(pos.y, h)
	b:ClearAllPoints()
	b:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
	return { x = x, y = y }
end

local function SlotShown(on)
	local slot = Controls.slot
	if not slot then return end
	if slot:IsShown() ~= on then slot:SetShown(on); reflow = true end
	-- Менеджер переставляет и штатные кнопки карты: с геймпадом их не трогаем.
	if reflow and not Locked() and not ns.Map.GamepadUI() then
		manager.SetPoints()
		reflow = false
	end
end

local function AttachManager()
	if Controls.slot or not LibStub then return end
	local lib = LibStub("Krowi_WorldMapButtons-1.4", true)
	-- Старые варианты считают Forever старой картой и меняют родителей её кнопок.
	if not (type(lib) == "table" and lib.HasNoOverlay == false and type(lib.Add) == "function"
		and type(lib.SetPoints) == "function") then return end
	local slot = lib:Add(nil, "Frame")
	slot:SetSize(32, 32)
	slot:EnableMouse(false)
	slot.Refresh = Controls.Refresh
	Controls.slot, manager = slot, lib
end

local function Tip()
	local b = Controls.button
	GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Chillzone", 0.5, 0.83, 0.76)
	GameTooltip:AddLine(ns.db.settings.showMap and L.MAP_BUTTON_HIDE or L.MAP_BUTTON_SHOW, 1, 1, 1)
	GameTooltip:AddLine(L.MAP_BUTTON_DRAG, 0.8, 0.8, 0.8)
	GameTooltip:AddLine(L.MAP_BUTTON_RESET, 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function Paint()
	local b = Controls.button
	if not b then return end
	b.icon:SetDesaturated(not ns.db.settings.showMap)
	b.icon:SetAlpha(ns.db.settings.showMap and 1 or 0.45)
	if hover then Tip() end
end

local function Layer()
	local b, api = Controls.button, OpenMapAPI
	local level = math.max(WorldMapFrame:GetFrameLevel(), Canvas():GetFrameLevel()) + 20
	if ns.Map.OpenMapActive() and type(api.ArtTopLevel) == "function" then
		local ok, top = pcall(api.ArtTopLevel)
		if ok and Number(top) then level = math.max(level, top + 2) end
	end
	level = math.min(9990, level)
	if b:GetFrameLevel() ~= level then b:SetFrameLevel(level) end
end

local function ListenOpenMap()
	local api = OpenMapAPI
	if type(api) ~= "table" or api.major ~= 1 or api == openMapAPI
		or type(api.RegisterCallback) ~= "function" then return end
	openMapAPI = api
	api.RegisterCallback(Controls, "OpenMap_StitchedChanged", Controls.Refresh)
	api.RegisterCallback(Controls, "OpenMap_ViewChanged", Controls.Refresh)
end

local function StopDrag()
	if not dragging then return end
	ns.db.settings.mapButton = { x = dragging.x, y = dragging.y }
	dragging = nil
	Controls.button:SetScript("OnUpdate", nil)
	-- Отпускание после перетаскивания не должно одновременно переключить круги.
	ns.After(0, "map drag release", function() blocked = false end)
end

local function Move()
	if Locked() then StopDrag(); return end
	local canvas = Canvas()
	local scale, w, h = canvas:GetEffectiveScale(), canvas:GetWidth(), canvas:GetHeight()
	local left, top = canvas:GetLeft(), canvas:GetTop()
	if not (Number(scale) and scale > 0 and Number(w) and w > 0 and Number(h) and h > 0
		and Number(left) and Number(top)) then return end
	local x, y = GetCursorPosition()
	if not (Number(x) and Number(y)) then return end
	dragging = Place({ x = (x / scale - left) / w, y = (top - y / scale) / h }) or dragging
end

function Controls.ResetPosition()
	if Locked() then return end
	ns.db.settings.mapButton = nil
	Controls.Refresh()
end

local function Click(_, key)
	if blocked then blocked = false; return end
	if ns.Map.GamepadUI() then return end
	if key == "RightButton" and IsShiftKeyDown() then
		Controls.ResetPosition()
	elseif key == "LeftButton" then
		ns.Map.SetEnabled(not ns.db.settings.showMap)
	end
end

local function CreateButton()
	local b = CreateFrame("Button", nil, WorldMapFrame)
	Controls.button = b
	b:SetSize(SIZE, SIZE)
	b:EnableMouse(true)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", 6, -6)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetTexture("Interface\\AddOns\\Chillzone\\media\\icon")
	b.icon:SetSize(18, 18)
	b.icon:SetPoint("TOPLEFT", 7, -7)
	local ring = b:CreateTexture(nil, "OVERLAY")
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	ring:SetSize(53, 53)
	ring:SetPoint("TOPLEFT")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(...) ns.SafeCall("map button click", Click, ...) end)
	b:SetScript("OnDragStart", function()
		ns.SafeCall("map button drag", function()
			if not IsShiftKeyDown() or Locked() or ns.Map.GamepadUI() then return end
			blocked = true
			dragging = Saved() or { x = 0, y = 0 }
			SlotShown(false)
			Move()
			b:SetScript("OnUpdate", function() ns.SafeCall("map button move", Move) end)
		end)
	end)
	b:SetScript("OnDragStop", function()
		ns.SafeCall("map button stop", StopDrag)
		Controls.Refresh()
	end)
	b:SetScript("OnEnter", function() hover = true; ns.SafeCall("map button tip", Tip) end)
	b:SetScript("OnLeave", function() hover = false; GameTooltip:Hide() end)
	b:SetScript("OnHide", function()
		ns.SafeCall("map button hide", StopDrag)
		if hover then hover = false; GameTooltip:Hide() end
	end)
end

function Controls.Refresh()
	if refreshing or not ready or not ns.db or not WorldMapFrame then return end
	if Locked() then
		if Controls.button and (ns.Map.GamepadUI() or not ns.IsMember()) then
			Controls.button:Hide()
			SlotShown(false)
		end
		ns.SafeCall("map button state", Paint)
		return
	end
	refreshing = true
	local ok, err = pcall(function()
		if hooked ~= WorldMapFrame then
			hooked = WorldMapFrame
			hooked:HookScript("OnShow", function()
				Controls.Refresh()
				-- OpenMap может поднять слои в своём более позднем OnShow.
				ns.After(0, "map button shown", Controls.Refresh)
			end)
			Canvas():HookScript("OnSizeChanged", Controls.Refresh)
		end
		ListenOpenMap()
		if ns.Map.GamepadUI() or not ns.IsMember() then
			if Controls.button then Controls.button:Hide(); SlotShown(false) end
			return
		end
		if not Controls.button then CreateButton() end
		local b, pos = Controls.button, Saved()
		Layer()
		if not pos and not dragging then AttachManager() end
		SlotShown(not pos and not dragging)
		if not dragging then
			if pos then
				Place(pos)
			else
				b:ClearAllPoints()
				if Controls.slot then
					b:SetPoint("CENTER", Controls.slot, "CENTER", 0, 0)
				else
					b:SetPoint("TOPLEFT", Canvas(), "TOPLEFT", 3, -36)
				end
			end
		end
		b:Show()
		Paint()
	end)
	refreshing = false
	if not ok then ns.CaptureError("map controls", err) end
end

ns.On("LOGIN", function() ready = true; Controls.Refresh() end)
ns.On("SETTINGS", Controls.Refresh)
ns.On("GUILD_CHANGED", Controls.Refresh)
ns.RegisterEvent("ADDON_LOADED", Controls.Refresh)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", Controls.Refresh)
ns.RegisterEvent("UI_SCALE_CHANGED", Controls.Refresh)
ns.RegisterEvent("INPUT_DEVICE_INTERFACE_TRANSITION", Controls.Refresh)
