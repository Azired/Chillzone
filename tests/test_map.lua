-- Карта: поведение фреймов, общий ряд кнопок и переносимые метки OpenMap.
local T = ...

local function Near(a, b, message)
	T.ok(type(a) == "number" and math.abs(a - b) < 0.00001, message or "близкие координаты")
end

local function Harness(opts)
	opts = opts or {}
	local h = { frames = {}, callbacks = {}, events = {}, after = {}, libraries = {}, commands = {}, messages = {}, errors = {} }
	h.member, h.shift, h.combat, h.gamepad = true, false, false, false
	h.cursorX, h.cursorY = 400, 500
	local methods = {}
	local function Frame(parent, kind)
		local f = setmetatable({ parent = parent, kind = kind, shown = true, scripts = {}, width = 0, height = 0, scale = 1, level = 1 }, { __index = methods })
		h.frames[#h.frames + 1] = f
		return f
	end
	local function Script(f, name, ...)
		if f.scripts[name] then return f.scripts[name](f, ...) end
	end
	local function VisibilityChange(change)
		local before = {}
		for _, frame in ipairs(h.frames) do before[frame] = frame:IsVisible() end
		change()
		for _, frame in ipairs(h.frames) do
			local shown = frame:IsVisible()
			if before[frame] ~= shown then Script(frame, shown and "OnShow" or "OnHide") end
		end
	end
	function methods:SetScript(name, fn) self.scripts[name] = fn end
	function methods:GetScript(name) return self.scripts[name] end
	function methods:HookScript(name, fn)
		local old = self.scripts[name]
		self.scripts[name] = function(frame, ...)
			if old then old(frame, ...) end
			fn(frame, ...)
		end
	end
	function methods:Show()
		if not self.shown then VisibilityChange(function() self.shown = true end) end
	end
	function methods:Hide()
		if self.shown then VisibilityChange(function() self.shown = false end) end
	end
	function methods:SetShown(on) if on then self:Show() else self:Hide() end end
	function methods:IsShown() return self.shown end
	function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
	function methods:SetParent(parent) VisibilityChange(function() self.parent = parent end) end
	function methods:GetParent() return self.parent end
	function methods:GetEffectiveScale() return self.scale * (self.parent and self.parent:GetEffectiveScale() or 1) end
	function methods:SetScale(scale) self.scale = scale end
	function methods:GetScale() return self.scale end
	function methods:SetSize(w, height)
		local changed = self.width ~= w or self.height ~= height
		self.width, self.height = w, height
		if changed then Script(self, "OnSizeChanged", w, height) end
	end
	function methods:SetWidth(w) self:SetSize(w, self.height) end
	function methods:SetHeight(height) self:SetSize(self.width, height) end
	function methods:GetWidth() return self.width end
	function methods:GetHeight() return self.height end
	function methods:ClearAllPoints() self.point = nil; self.clears = (self.clears or 0) + 1 end
	function methods:SetPoint(point, relative, relativePoint, x, y)
		if type(relative) == "number" then x, y, relative, relativePoint = relative, relativePoint, self.parent, point end
		self.point = { point, relative or self.parent, relativePoint or point, x or 0, y or 0 }
		self.anchors = (self.anchors or 0) + 1
	end
	function methods:GetPoint() return unpack(self.point or {}) end
	function methods:SetAllPoints(parent) self.allPoints = parent or self.parent end
	function methods:GetLeft() return self.left or (self.parent and self.parent:GetLeft()) or 0 end
	function methods:GetTop() return self.top or (self.parent and self.parent:GetTop()) or self.height end
	function methods:GetRight() return self:GetLeft() + self.width end
	function methods:GetBottom() return self:GetTop() - self.height end
	function methods:GetCenter() return self:GetLeft() + self.width / 2, self:GetTop() - self.height / 2 end
	function methods:GetFrameLevel() return self.level end
	function methods:SetFrameLevel(level) self.level = level end
	function methods:EnableMouse(on) self.mouse = on end
	function methods:RegisterForClicks(...) self.clicks = { ... } end
	function methods:RegisterForDrag(...) self.drags = { ... } end
	function methods:SetTexture(path) self.texture = path end
	function methods:SetVertexColor(...) self.color = { ... } end
	function methods:SetTexCoord(...) self.texcoords = { ... } end
	function methods:SetAlpha(alpha) self.alpha = alpha end
	function methods:SetDesaturated(on) self.desaturated = on end
	function methods:SetBlendMode(mode) self.blend = mode end
	function methods:SetText(text) self.text = text end
	function methods:GetText() return self.text end
	function methods:SetTextColor(...) self.textColor = { ... } end
	function methods:CreateTexture() return Frame(self, "Texture") end
	function methods:CreateFontString() return Frame(self, "FontString") end
	function methods:SetHighlightTexture(path) self.highlight = Frame(self, "Texture"); self.highlight.texture = path end
	function methods:GetHighlightTexture() return self.highlight end
	function methods:SetNormalTexture(path) self.normal = Frame(self, "Texture"); self.normal.texture = path end
	function methods:GetNormalTexture() return self.normal end
	function methods:SetPushedTexture(path) self.pushed = Frame(self, "Texture"); self.pushed.texture = path end
	function methods:SetFrameStrata(strata) self.strata = strata end
	function methods:SetClampedToScreen(on) self.clamped = on end
	function methods:SetMovable(on) self.movable = on end
	function methods:StartMoving() self.moving = true end
	function methods:StopMovingOrSizing() self.moving = false end
	function methods:RegisterEvent() end
	function methods:GetCanvasContainer() return self.canvas end

	local env = setmetatable({}, { __index = _G })
	env._G = env
	h.env = env
	env.UIParent = Frame(nil, "Frame")
	env.UIParent:SetSize(1920, 1080)
	env.UIParent.left, env.UIParent.top = 0, 1080
	env.CreateFrame = function(kind, _, parent) return Frame(parent, kind) end
	env.GetCursorPosition = function() return h.cursorX, h.cursorY end
	env.IsShiftKeyDown = function() return h.shift end
	env.InCombatLockdown = function() return h.combat end
	env.C_InputInterfaceStyle = { GetCurrentStyle = function() return h.gamepad and 1 or 0 end }
	env.Enum = { InputDeviceInterfaceType = { Gamepad = 1 } }
	env.C_Map = { GetMapInfo = function() return nil end }
	env.LibStub = function(name) return h.libraries[name] end
	env.hooksecurefunc = function(object, key, hook)
		local original = object[key]
		object[key] = function(...)
			local values = { original(...) }
			hook(...)
			return unpack(values)
		end
	end
	env.GameTooltip = Frame(nil, "Tooltip")
	function env.GameTooltip:SetOwner(owner) self.owner = owner; self.lines = {} end
	function env.GameTooltip:GetOwner() return self.owner end
	function env.GameTooltip:ClearLines() self.lines = {} end
	function env.GameTooltip:AddLine(text) self.lines[#self.lines + 1] = { text } end
	function env.GameTooltip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = { left, right } end
	env.GameTooltip:Hide()
	function h:CreateMap()
		local map = Frame(env.UIParent, "Frame")
		map:SetSize(1000, 650)
		map.left, map.top = 100, 900
		map.canvas = Frame(map, "Frame")
		map.canvas:SetSize(800, 500)
		map.canvas.left, map.canvas.top = 110, 870
		map.ScrollContainer, map.overlayFrames = map.canvas, {}
		env.WorldMapFrame, self.map, self.canvas = map, map, map.canvas
		return map
	end
	if not opts.lateMap then h:CreateMap() end
	local pins = { entries = {}, adds = 0 }
	function pins:AddWorldMapIconMap(_, anchor, mapID, x, y, flag)
		local holder = Frame(h.canvas, "Frame")
		holder:SetScale(1.2)
		anchor:SetParent(holder)
		anchor:ClearAllPoints()
		anchor:SetPoint("CENTER", holder, "CENTER", 0, 0)
		anchor:Show()
		self.entries[#self.entries + 1] = { anchor = anchor, holder = holder, mapID = mapID, x = x, y = y, flag = flag }
		self.adds = self.adds + 1
	end
	function pins:RemoveAllWorldMapIcons()
		for _, pin in ipairs(self.entries) do pin.anchor:Hide() end
		self.entries = {}
	end
	h.libraries["HereBeDragons-Pins-2.0"], h.pins = pins, pins
	function h:InstallKrowi(compatible)
		local manager = { Buttons = {}, HasNoOverlay = not compatible, reflows = 0, adds = 0 }
		local other = Frame(self.map, "Button")
		other:SetSize(32, 32)
		manager.Buttons[1] = other
		function manager.SetPoints()
			manager.reflows = manager.reflows + 1
			local row = 0
			for _, frame in ipairs(manager.Buttons) do
				if frame:IsShown() then
					frame:ClearAllPoints()
					frame:SetPoint("TOPLEFT", h.canvas, "TOPLEFT", 3, -row * 32)
					row = row + 1
				end
			end
		end
		function manager.Add(lib, _, kind)
			local slot = Frame(h.map, kind)
			lib.Buttons[#lib.Buttons + 1] = slot
			lib.adds = lib.adds + 1
			manager.SetPoints()
			return slot
		end
		self.manager, self.otherButton = manager, other
		self.libraries["Krowi_WorldMapButtons-1.4"] = manager
		return manager
	end
	if opts.krowi then h:InstallKrowi(true) end
	local ns = { db = { settings = { showMap = true, mapButton = opts.position, mapOpenMapWide = opts.wide } } }
	function ns.On(name, fn) h.callbacks[name] = h.callbacks[name] or {}; table.insert(h.callbacks[name], fn) end
	function ns.Fire(name, ...) for _, fn in ipairs(h.callbacks[name] or {}) do fn(...) end end
	function ns.RegisterEvent(name, fn) h.events[name] = h.events[name] or {}; table.insert(h.events[name], fn) end
	function ns.SafeCall(_, fn, ...) fn(...); return true end
	function ns.CaptureError(where, err) error(where .. ": " .. tostring(err)) end
	function ns.Print(message) h.messages[#h.messages + 1] = message end
	function ns.After(_, _, fn) h.after[#h.after + 1] = fn end
	function ns.IsMember() return h.member end
	function ns.Command(name, fn) h.commands[name] = fn end
	ns.Zones = { MapID = function() return 42 end, NameForKey = function() return "Ясеневый лес" end }
	ns.Codec = { Plain = function(value) return value end }
	ns.Data = { ZoneCounts = function() return { m42 = { total = 3, guilds = { Chillzone = 2, Ally = 1 } } } end }
	ns.Util = { Fold = string.lower, Trim = function(value) return value:match("^%s*(.-)%s*$") end }
	h.ns = ns
	function h:Event(name, ...) for _, fn in ipairs(self.events[name] or {}) do fn(...) end end
	function h:Flush()
		local pending = self.after
		self.after = {}
		for _, fn in ipairs(pending) do fn() end
	end
	function h:Tick()
		local frames = {}
		for _, frame in ipairs(self.frames) do frames[#frames + 1] = frame end
		for _, frame in ipairs(frames) do if frame:IsVisible() then Script(frame, "OnUpdate", 0.016) end end
	end
	function h:Click(button, mouse) return Script(button, "OnClick", mouse or "LeftButton") end
	function h:Drag(button, x, y)
		self.shift = true
		Script(button, "OnDragStart")
		self.cursorX, self.cursorY = x, y
		self:Tick()
		Script(button, "OnDragStop")
		self:Click(button)
		self.shift = false
	end
	T.load({ "Locale.lua", "Map.lua", "MapControls.lua" }, env, ns)
	if not opts.noLogin then ns.Fire("LOGIN") end
	return h
end

T.test("map: кнопка без других аддонов переключает общую настройку сразу", function()
	local h = Harness()
	local b = h.ns.MapControls.button
	T.ok(b and b:IsVisible())
	T.no(b.icon.desaturated)
	h.ns.Map.RefreshNow()
	T.eq(#h.pins.entries, 1)
	h:Click(b)
	T.no(h.ns.db.settings.showMap)
	T.eq(#h.pins.entries, 0)
	T.ok(b:IsVisible(), "выключенные кружки не скрывают кнопку")
	T.ok(b.icon.desaturated)
	T.ok(b.icon.alpha < 1)
	b.scripts.OnEnter(b)
	T.eq(h.env.GameTooltip.lines[2][1], h.ns.L.MAP_BUTTON_SHOW)
	h:Click(b)
	T.ok(h.ns.db.settings.showMap)
	T.no(b.icon.desaturated)
	T.eq(h.env.GameTooltip.lines[2][1], h.ns.L.MAP_BUTTON_HIDE)
	T.eq(#h.pins.entries, 1)
	h.commands.map("off")
	T.no(h.ns.db.settings.showMap)
	T.ok(b:IsVisible())
	T.ok(b.icon.desaturated, "команда и кнопка используют одно состояние")
end)

T.test("map: общий ряд даёт отдельное место и сохраняет чужую кнопку", function()
	local h = Harness({ krowi = true })
	local controls = h.ns.MapControls
	T.ok(controls.slot and controls.slot:IsShown())
	T.eq(h.manager.adds, 1)
	T.eq(#h.manager.Buttons, 2)
	T.ok(h.otherButton:IsShown())
	T.no(controls.slot.point[5] == h.otherButton.point[5])
	h:Drag(controls.button, 510, 620)
	T.no(controls.slot:IsShown(), "ручное положение освобождает общий ряд")
	T.ok(controls.button:IsVisible())
	T.ok(h.otherButton:IsShown())
	T.ok(h.ns.db.settings.showMap, "завершение переноса не переключает кружки")
	h:Flush()
	h.shift = true
	h:Click(controls.button, "RightButton")
	T.eq(h.ns.db.settings.mapButton, nil)
	T.ok(controls.slot:IsShown())
	T.eq(h.manager.adds, 1, "сброс использует прежнее место")
end)

T.test("map: перенос ограничен картой и сохраняется при изменении размеров", function()
	local h = Harness()
	local controls = h.ns.MapControls
	h:Drag(controls.button, -2000, 3000)
	local saved = h.ns.db.settings.mapButton
	T.ok(saved and saved.x >= 0 and saved.x <= 1 and saved.y >= 0 and saved.y <= 1)
	T.ok(h.ns.db.settings.showMap)
	h:Flush()
	h:Drag(controls.button, 510, 620)
	saved = h.ns.db.settings.mapButton
	Near(saved.x, 0.5)
	Near(saved.y, 0.5)
	h.canvas:SetSize(400, 250)
	controls.Refresh()
	local point = controls.button.point
	Near(math.abs(point[4]), 200)
	Near(math.abs(point[5]), 125)
	h.map:Hide()
	T.no(controls.button:IsVisible(), "родитель прячет кнопку")
	h.map:Show()
	Near(h.ns.db.settings.mapButton.x, 0.5)
	local again = Harness({ position = saved })
	Near(math.abs(again.ns.MapControls.button.point[4]), 400)
	Near(math.abs(again.ns.MapControls.button.point[5]), 250)
end)

T.test("map: карта и менеджер могут загрузиться после входа", function()
	local h = Harness({ lateMap = true })
	T.eq(h.ns.MapControls.button, nil)
	h:CreateMap()
	h:Event("ADDON_LOADED", "Blizzard_WorldMap")
	local b = h.ns.MapControls.button
	T.ok(b)
	h:InstallKrowi(true)
	h:Event("ADDON_LOADED", "Questie")
	T.ok(h.ns.MapControls.slot)
	h:Event("ADDON_LOADED", "AnotherAddon")
	T.eq(h.ns.MapControls.button, b)
	T.eq(h.manager.adds, 1)
	h.env.OpenMapAPI = { major = 1, IsStitched = function() return true end }
	h:Tick()
	local circle = h.pins.entries[1].anchor.circle
	T.ok(circle.point[4] < 0, "у карты, загруженной поздно, работает обновление OpenMap")
end)

T.test("map: бой откладывает создание и изменение размещения кнопки", function()
	local h = Harness({ noLogin = true })
	h.combat = true
	h.ns.Fire("LOGIN")
	T.eq(h.ns.MapControls.button, nil)
	h.combat = false
	h:Event("PLAYER_REGEN_ENABLED")
	local b = h.ns.MapControls.button
	T.ok(b)
	local anchors = b.anchors
	h.combat = true
	h.ns.db.settings.mapButton = { x = 0.8, y = 0.8 }
	h.ns.MapControls.Refresh()
	T.eq(b.anchors, anchors)
	h.shift = true
	b.scripts.OnDragStart(b)
	T.eq(b:GetScript("OnUpdate"), nil, "перенос не начинается в бою")
	h:Click(b, "RightButton")
	Near(h.ns.db.settings.mapButton.x, 0.8, "боевой сброс положения отклонён")
	h.shift = false
	h:Click(b)
	T.no(h.ns.db.settings.showMap, "в бою переключатель продолжает работать")
	T.ok(b.icon.desaturated)
	T.eq(b.anchors, anchors, "переключение не передвигает кнопку в бою")
	h.combat = false
	h:Event("PLAYER_REGEN_ENABLED")
	T.ok(b.anchors > anchors)
end)

T.test("map: закрытие карты завершает перенос и прячет подсказку", function()
	local h = Harness()
	local b = h.ns.MapControls.button
	b.scripts.OnEnter(b)
	h.shift = true
	b.scripts.OnDragStart(b)
	h.cursorX, h.cursorY = 510, 620
	h:Tick()
	h.map:Hide()
	T.eq(b:GetScript("OnUpdate"), nil)
	T.no(h.env.GameTooltip:IsShown())
	Near(h.ns.db.settings.mapButton.x, 0.5)
	Near(h.ns.db.settings.mapButton.y, 0.5)
	h.map:Show()
	T.ok(b:IsVisible())
end)

T.test("map: смена способа ввода скрывает кнопку без повторного открытия карты", function()
	local h = Harness({ krowi = true })
	local b = h.ns.MapControls.button
	local reflows = h.manager.reflows
	h.gamepad = true
	h:Event("INPUT_DEVICE_INTERFACE_TRANSITION")
	T.no(b:IsShown())
	T.no(h.ns.MapControls.slot:IsShown())
	T.eq(h.manager.reflows, reflows, "при геймпаде не передвигаются чужие кнопки")
	h.gamepad = false
	h:Event("INPUT_DEVICE_INTERFACE_TRANSITION")
	T.ok(b:IsVisible())
	T.ok(h.manager.reflows > reflows, "после возврата к мыши ряд пересчитывается")
end)

T.test("map: кнопка выше рисунка OpenMap, смена слоя в бою откладывается", function()
	local h = Harness()
	local b, callbacks = h.ns.MapControls.button, {}
	local normal, art, stitched = b:GetFrameLevel(), 200, true
	h.env.OpenMapAPI = {
		major = 1,
		IsStitched = function() return stitched end,
		ArtTopLevel = function() return art end,
		RegisterCallback = function(owner, event, method)
			callbacks[event] = function(...)
				if type(method) == "string" then owner[method](owner, event, ...) else method(event, ...) end
			end
		end,
	}
	local function Changed(event)
		if callbacks[event] then callbacks[event]() end
		h:Tick()
	end
	h:Event("ADDON_LOADED", "OpenMap")
	T.ok(b:GetFrameLevel() > art, "отдельная кнопка не прячется под рисунком карты")
	stitched = false
	Changed("OpenMap_StitchedChanged")
	T.eq(b:GetFrameLevel(), normal)
	stitched = true
	Changed("OpenMap_StitchedChanged")
	T.ok(b:GetFrameLevel() > art)
	local level, anchors = b:GetFrameLevel(), b.anchors
	h.combat, art = true, 300
	Changed("OpenMap_ViewChanged")
	T.eq(b:GetFrameLevel(), level, "боевой callback не меняет слой фрейма")
	T.eq(b.anchors, anchors, "боевой callback не меняет якорь кнопки")
	h.combat = false
	h:Event("PLAYER_REGEN_ENABLED")
	T.ok(b:GetFrameLevel() > art)
end)

T.test("map: посторонняя гильдия и геймпад скрывают кнопку и кружки", function()
	local h = Harness({ krowi = true })
	for _, flag in ipairs({ "member", "gamepad" }) do
		h.member, h.gamepad = true, false
		h[flag] = flag == "gamepad"
		h.ns.MapControls.Refresh()
		h.ns.Map.RefreshNow()
		T.no(h.ns.MapControls.button:IsShown())
		T.no(h.ns.MapControls.slot:IsShown())
		T.eq(#h.pins.entries, 0)
	end
end)

T.test("map: повреждённое положение и старый менеджер не ломают кнопку", function()
	for _, position in ipairs({ false, "wrong", { x = 0 / 0, y = 0.5 }, { x = math.huge, y = 0.5 }, { x = "0.5", y = 0.5 } }) do
		local h = Harness({ position = position })
		h:InstallKrowi(false)
		h:Event("ADDON_LOADED", "OldMapButtons")
		T.ok(h.ns.MapControls.button:IsVisible())
		T.eq(h.ns.MapControls.slot, nil)
		T.eq(h.manager.adds, 0)
	end
end)

T.test("map: OpenMap сдвигает кружок с подсказкой, сохраняя координаты зоны", function()
	local h = Harness()
	h.env.OpenMapAPI = { major = 1, IsStitched = function() return true end }
	h.ns.Map.RefreshNow()
	local entry = h.pins.entries[1]
	local circle = entry.anchor.circle
	T.eq(entry.x, 0.5); T.eq(entry.y, 0.5); T.eq(entry.mapID, 42)
	T.no(entry.anchor.mouse)
	T.ok(circle.mouse)
	T.eq(circle.count, 3)
	T.same(circle.guilds, { Chillzone = 2, Ally = 1 })
	local function CheckGap()
		local ratio = circle:GetEffectiveScale() / h.map:GetEffectiveScale()
		local rightEdge = (circle.point[4] + circle:GetWidth() / 2 + 2) * ratio
		Near(-9 - rightEdge, 2, "между обводкой CZ и обычной меткой OpenMap остаётся небольшой зазор")
	end
	CheckGap()
	circle.scripts.OnEnter(circle)
	T.eq(h.env.GameTooltip:GetOwner(), circle)
	T.eq(h.env.GameTooltip.lines[1][1], "Ясеневый лес")
	T.eq(#h.env.GameTooltip.lines, 4)
	local anchors, adds = circle.anchors, h.pins.adds
	h:Tick()
	T.eq(circle.anchors, anchors, "без изменения масштаба якорь не переписывается")
	entry.holder:SetScale(2)
	h:Tick()
	CheckGap()
	T.eq(h.pins.adds, adds, "зум не перерегистрирует метки")
	entry.anchor:ClearAllPoints()
	entry.anchor:SetPoint("CENTER", entry.holder, "CENTER", 0, 0)
	CheckGap()
	h.env.OpenMapAPI.IsStitched = function() return false end
	h:Tick()
	T.eq(circle.point[4], 0)
	T.eq(h.pins.adds, adds)
end)

T.test("map: компактный и увеличенный отступ разделяют метки при разных масштабах", function()
	local h = Harness()
	h.env.OpenMapAPI = { major = 1, IsStitched = function() return true end }
	h.ns.Map.RefreshNow()
	local entry = h.pins.entries[1]
	local circle = entry.anchor.circle
	local badge = h.env.CreateFrame("Frame", nil, h.map)
	badge:SetSize(18, 18)
	for _, wide in ipairs({ false, true }) do
		h.ns.db.settings.mapOpenMapWide = wide
		h.ns.Fire("SETTINGS")
		for _, uiScale in ipairs({ 0.75, 1, 1.25 }) do
			h.map:SetScale(uiScale)
			for _, pinScale in ipairs({ 1, 1.2 }) do
				entry.holder:SetScale(pinScale)
				local previous
				for _, width in ipairs({ 16, 25, 34 }) do
					circle:SetSize(width, width)
					h:Tick()
					local ratio = circle:GetEffectiveScale() / h.map:GetEffectiveScale()
					local distance = -circle.point[4] * ratio
					T.ok(distance < (wide and 43 or 34), "компактный режим не резервирует место под двойной размер OpenMap")
					if previous then T.ok(distance > previous, "маленький кружок ближе к центру зоны") end
					previous = distance
					for _, iconScale in ipairs(wide and { 0.6, 1, 1.5, 2 } or { 0.6, 1 }) do
						badge:SetScale(iconScale)
						local leftEdge = -badge:GetWidth() / 2 * badge:GetEffectiveScale() / h.map:GetEffectiveScale()
						local rightEdge = (circle.point[4] + width / 2 + 2) * ratio
						T.ok(leftEdge - rightEdge >= 2 - 0.00001, "обводка и обе области наведения разделены")
					end
				end
			end
		end
	end
end)

T.test("map: смена отступа сразу передвигает метки без перерегистрации", function()
	local h = Harness()
	h.env.OpenMapAPI = { major = 1, IsStitched = function() return true end }
	h.ns.Map.RefreshNow()
	local entry = h.pins.entries[1]
	local circle, adds = entry.anchor.circle, h.pins.adds
	local function Distance()
		return -circle.point[4] * circle:GetEffectiveScale() / h.map:GetEffectiveScale()
	end
	local compact = Distance()
	h.ns.db.settings.mapOpenMapWide = true
	h.ns.Fire("SETTINGS")
	Near(Distance() - compact, 9, "галочка увеличивает отступ сразу, до следующего кадра")
	T.eq(h.pins.adds, adds, "переключение настройки сохраняет метки HBD")
	h.map:Hide()
	local anchors = circle.anchors
	h.ns.db.settings.mapOpenMapWide = false
	h.ns.Fire("SETTINGS")
	T.eq(circle.anchors, anchors, "закрытая карта не переставляет метки")
	h.map:Show()
	Near(Distance(), compact, "изменение при закрытой карте видно после открытия")
	T.eq(h.pins.adds, adds)
	T.eq(entry.x, 0.5); T.eq(entry.y, 0.5)
	anchors = circle.anchors
	h.gamepad = true
	h.ns.db.settings.mapOpenMapWide = true
	h.ns.Fire("SETTINGS")
	h:Tick()
	T.eq(circle.anchors, anchors, "при геймпаде настройка не переставляет оставшиеся метки")
	h.gamepad = false
	h:Tick()
	Near(Distance() - compact, 9, "после возврата к мыши применяется сохранённый режим")
end)

T.test("map: сохранённый увеличенный отступ переживает скрытие кругов и обычную карту", function()
	local h = Harness({ wide = true })
	local stitched = true
	h.env.OpenMapAPI = { major = 1, IsStitched = function() return stitched end }
	h.ns.Map.RefreshNow()
	local circle = h.pins.entries[1].anchor.circle
	local wideOffset = circle.point[4]
	local ratio = circle:GetEffectiveScale() / h.map:GetEffectiveScale()
	Near(-18 - (wideOffset + circle:GetWidth() / 2 + 2) * ratio, 2, "сохранённый режим применяется при первом построении")
	h.ns.Map.SetEnabled(false)
	T.eq(#h.pins.entries, 0)
	h.ns.Map.SetEnabled(true)
	T.eq(h.pins.entries[1].anchor.circle, circle, "повторно используется прежний кружок")
	Near(circle.point[4], wideOffset)
	stitched = false
	h:Tick()
	T.eq(circle.point[4], 0, "обычная карта остаётся без смещения")
	T.eq(h.ns.db.settings.mapOpenMapWide, true)
	stitched = true
	h:Tick()
	Near(circle.point[4], wideOffset, "возврат в OpenMap восстанавливает выбранный отступ")
end)

T.test("map: обычная карта и неисправный OpenMap оставляют кружки в центре", function()
	local h = Harness()
	for _, api in ipairs({ false, { major = 2, IsStitched = function() return true end }, { major = 1, IsStitched = function() error("disabled") end } }) do
		h.env.OpenMapAPI = api
		h.ns.Map.RefreshNow()
		local entry = h.pins.entries[1]
		T.eq(entry.anchor.circle.point[4], 0)
		T.eq(entry.x, 0.5); T.eq(entry.y, 0.5)
		T.ok(entry.anchor.circle:IsVisible(), "пул повторно показывает дочерний кружок")
	end
end)
