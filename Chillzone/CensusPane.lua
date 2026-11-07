-- Chillzone: вкладка «Перепись» — слева список гильдий, справа карточка выбранной, как вкладка
-- «Сведения» окна гильдии: крупные числа, руководство, полоса классов, гистограмма уровней,
-- зоны полосками. Данные — Views.CensusRows и Views.GuildCard; здесь только рисование.
-- Живёт во вставке окна (UI.lua body, 804×340), ширины заданы числами: окно не меняет размер.
local ADDON, ns = ...

local L = ns.L
local Views = ns.Views

local CensusPane = {}
ns.CensusPane = CensusPane

local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local ROLE_ICON = {
	leader = "Interface\\GroupFrame\\UI-Group-LeaderIcon",
	officer = "Interface\\GroupFrame\\UI-Group-AssistantIcon",
}
local LIST_W, ROW_H = 236, 38
local CARD_X, CARD_W = 288, 486
local TILE_GAP = 8
local COL_L_W, COL_R_X = 200, 220
local COL_R_W = CARD_W - COL_R_X
local LEVEL_BAR_H, PERSON_H, ZONE_H = 40, 16, 16
local ZONE_NAME_W = 170

local pane, list, listChild, empty, card, cardChild
local rows, people, segments, levels, zones, legend = {}, {}, {}, {}, {}, {}
local LEGEND_COLS, LEGEND_H = 2, 14
local w = {} -- надписи карточки
local selected -- U.GuildKey выбранной гильдии

local function FS(parent, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

-- Высота надписи после SetText (у переносимых — по ширине); fallback — если клиент не знает.
local function Height(fs, fallback)
	local h = fs:GetStringHeight()
	return (type(h) == "number" and h > 0) and h or fallback
end

local function Place(region, x, y)
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", cardChild, "TOPLEFT", x, -y)
end

local function ClassRGB(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 0.6, 0.6, 0.6
end

local function Tooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	return GameTooltip
end

-- Щелчок по имени в карточке — шёпот в поле окна чата.
local function Whisper(name)
	ns.UI.Toggle("chat")
	ns.ChatPane.WhisperTo(name)
end

---------------------------------------------------------------------------
-- Список гильдий
---------------------------------------------------------------------------
local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, listChild)
	r:SetSize(LIST_W, ROW_H)
	r:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -(i - 1) * (ROW_H + 2))
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:SetColorTexture(1, 1, 1, 0.03)
	r.sel = r:CreateTexture(nil, "BORDER")
	r.sel:SetAllPoints()
	r.sel:SetColorTexture(1, 0.82, 0, 0.14)
	r.sel:Hide()
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	r.right = FS(r, "GameFontHighlightSmall", "RIGHT")
	r.right:SetPoint("TOPRIGHT", -6, -6)
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 6, -5)
	r.name:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 6, 5)
	r.sub:SetPoint("BOTTOMRIGHT", -6, 5)
	for _, fs in ipairs({ r.name, r.sub }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self) ns.SafeCall("census select", CensusPane.Select, self.key) end)
	rows[i] = r
	return r
end

local function RenderList(items)
	for i, it in ipairs(items) do
		local r = Row(i)
		r.key = it.key
		r.name:SetText(it.text)
		r.right:SetText(it.right)
		r.sub:SetText(it.sub)
		r.sel:SetShown(it.key == selected)
		r:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	listChild:SetHeight(math.max(#items * (ROW_H + 2), 10))
	empty:SetShown(#items == 0)
end

---------------------------------------------------------------------------
-- Карточка
---------------------------------------------------------------------------
local function Person(i)
	local p = people[i]
	if p then return p end
	p = CreateFrame("Button", nil, cardChild)
	p:SetSize(COL_L_W, PERSON_H)
	local hl = p:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	p.icon = p:CreateTexture(nil, "ARTWORK")
	p.icon:SetSize(12, 12)
	p.icon:SetPoint("LEFT", 2, 0)
	p.level = FS(p, "GameFontDisableSmall", "RIGHT")
	p.level:SetPoint("RIGHT", -2, 0)
	p.name = FS(p, "GameFontHighlightSmall")
	p.name:SetPoint("LEFT", p.icon, "RIGHT", 4, 0)
	p.name:SetPoint("RIGHT", p.level, "LEFT", -4, 0)
	if p.name.SetWordWrap then p.name:SetWordWrap(false) end
	p:SetScript("OnEnter", function(self)
		if not self.person then return end
		ns.SafeCall("census person tip", Views.PersonTip, Tooltip(self), self.person)
		GameTooltip:Show()
	end)
	p:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p:SetScript("OnClick", function(self)
		if self.person then ns.SafeCall("census whisper", Whisper, self.person.name) end
	end)
	people[i] = p
	return p
end

local function Segment(i)
	local t = segments[i]
	if t then return t end
	t = w.classBar:CreateTexture(nil, "ARTWORK")
	t:SetTexture(BAR)
	t:SetHeight(10)
	segments[i] = t
	return t
end

-- Строка подписи под полосой классов: квадратик цвета класса, класс, число справа.
-- Отдельными надписями, а не одной строкой через запятую: та переносилась посреди «Жрец 6».
local function LegendItem(i)
	local e = legend[i]
	if e then return e end
	e = {}
	e.swatch = cardChild:CreateTexture(nil, "ARTWORK")
	e.swatch:SetTexture(BAR)
	e.swatch:SetSize(8, 8)
	e.name = FS(cardChild, "GameFontHighlightSmall")
	if e.name.SetWordWrap then e.name:SetWordWrap(false) end
	e.count = FS(cardChild, "GameFontHighlightSmall", "RIGHT")
	legend[i] = e
	return e
end

local function Zone(i)
	local z = zones[i]
	if z then return z end
	z = {}
	z.name = FS(cardChild, "GameFontHighlightSmall")
	z.name:SetWidth(ZONE_NAME_W)
	if z.name.SetWordWrap then z.name:SetWordWrap(false) end
	z.bar = cardChild:CreateTexture(nil, "ARTWORK")
	z.bar:SetTexture(BAR)
	z.bar:SetVertexColor(0.25, 0.6, 0.9)
	z.bar:SetHeight(10)
	z.count = FS(cardChild, "GameFontHighlightSmall", "RIGHT")
	zones[i] = z
	return z
end

-- Руководство: левая колонка с y; возвращает её высоту.
local function RenderPeople(c, y)
	Place(w.leaders, 0, y)
	local h = 20
	for i, person in ipairs(c.people) do
		local p = Person(i)
		Place(p, 0, y + h)
		p.person = person
		p.icon:SetTexture(ROLE_ICON[person.role])
		local dot = person.online and "|TInterface\\FriendsFrame\\StatusIcon-Online:10|t " or "|TInterface\\FriendsFrame\\StatusIcon-Offline:10|t "
		local name = Views.Name(person.name, person.class)
		if not person.online then name = "|cff808080" .. ns.Codec.Plain(person.name) .. "|r" end
		p.name:SetText(dot .. name)
		p.level:SetText(person.level and person.level > 0 and tostring(person.level) or "")
		p:Show()
		h = h + PERSON_H
	end
	for i = #c.people + 1, #people do people[i]:Hide() end
	w.noLeaders:SetShown(#c.people == 0)
	if #c.people == 0 then
		Place(w.noLeaders, 0, y + h)
		h = h + 14
	end
	return h
end

-- Классы и уровни: правая колонка с y; возвращает её высоту.
local function RenderMix(c, y)
	local shown = c.classes ~= nil
	for _, region in ipairs({ w.classes, w.classBar, w.classLegend, w.levels }) do region:SetShown(shown) end
	if not shown then
		for _, e in ipairs(legend) do
			for _, region in ipairs({ e.swatch, e.name, e.count }) do region:Hide() end
		end
	end
	for _, col in ipairs(levels) do
		for _, region in ipairs({ col.bar, col.count, col.label }) do region:SetShown(shown) end
	end
	w.stale:SetShown(not shown)
	if not shown then
		Place(w.stale, COL_R_X, y)
		w.stale:SetText(c.staleNote or "")
		for _, t in ipairs(segments) do t:Hide() end
		return Height(w.stale, 28)
	end
	Place(w.classes, COL_R_X, y)
	Place(w.classBar, COL_R_X, y + 20)
	-- Полоса: отрезки цветом класса, длина — доля в игре.
	local x = 0
	for i, e in ipairs(c.classes) do
		local t = Segment(i)
		local width = c.classTotal > 0 and math.floor(COL_R_W * e.count / c.classTotal + 0.5) or 0
		if i == #c.classes then width = COL_R_W - x end
		t:ClearAllPoints()
		t:SetPoint("LEFT", w.classBar, "LEFT", x, 0)
		t:SetWidth(math.max(width, 1))
		t:SetVertexColor(ClassRGB(e.class))
		t:SetShown(width > 0)
		x = x + width
	end
	for i = #c.classes + 1, #segments do segments[i]:Hide() end
	-- Подпись — таблицей в две колонки, по убыванию сверху вниз: сначала левая, потом правая.
	local n = #c.classes
	local perCol = math.ceil(n / LEGEND_COLS)
	local colW = math.floor(COL_R_W / LEGEND_COLS)
	for i, e in ipairs(c.classes) do
		local item = LegendItem(i)
		local col, line = math.floor((i - 1) / perCol), (i - 1) % perCol
		local lx, ly = COL_R_X + col * colW, y + 36 + line * LEGEND_H
		Place(item.swatch, lx, ly + 3)
		item.swatch:SetVertexColor(ClassRGB(e.class))
		item.name:SetText(Views.Name(e.name, e.class))
		item.name:ClearAllPoints()
		item.name:SetPoint("TOPLEFT", cardChild, "TOPLEFT", lx + 12, -ly)
		item.name:SetPoint("TOPRIGHT", cardChild, "TOPLEFT", lx + colW - 34, -ly)
		item.count:SetText(tostring(e.count))
		item.count:ClearAllPoints()
		item.count:SetPoint("TOPRIGHT", cardChild, "TOPLEFT", lx + colW - 10, -ly)
		for _, region in ipairs({ item.swatch, item.name, item.count }) do region:Show() end
	end
	for i = n + 1, #legend do
		for _, region in ipairs({ legend[i].swatch, legend[i].name, legend[i].count }) do region:Hide() end
	end
	w.classLegend:SetShown(n == 0)
	local legendH
	if n == 0 then
		w.classLegend:SetText(L.CARD_NOBODY)
		Place(w.classLegend, COL_R_X, y + 36)
		legendH = Height(w.classLegend, 12)
	else
		legendH = perCol * LEGEND_H
	end
	local h = 36 + legendH + 12
	-- Уровни: семь столбиков, высота — доля от самого большого.
	Place(w.levels, COL_R_X, y + h)
	h = h + 20
	local levelW = COL_R_W / #levels
	for i, col in ipairs(levels) do
		local e = c.levels[i]
		local cx = COL_R_X + (i - 1) * levelW
		local barH = c.levelMax > 0 and math.floor(LEVEL_BAR_H * e.count / c.levelMax + 0.5) or 0
		col.count:SetText(e.count > 0 and tostring(e.count) or "")
		col.count:ClearAllPoints()
		col.count:SetPoint("BOTTOM", cardChild, "TOPLEFT", cx + levelW / 2, -(y + h + 12 + LEVEL_BAR_H - barH) + 1)
		col.bar:ClearAllPoints()
		col.bar:SetPoint("BOTTOM", cardChild, "TOPLEFT", cx + levelW / 2, -(y + h + 12 + LEVEL_BAR_H))
		col.bar:SetHeight(math.max(barH, 1))
		col.bar:SetShown(barH > 0)
		col.label:SetText(e.label)
		col.label:ClearAllPoints()
		col.label:SetPoint("TOP", cardChild, "TOPLEFT", cx + levelW / 2, -(y + h + 12 + LEVEL_BAR_H + 2))
	end
	return h + 12 + LEVEL_BAR_H + 16
end

local function RenderZones(c, y)
	local shown = c.zones ~= nil
	w.zones:SetShown(shown)
	w.zonesNote:SetShown(shown and c.zonesNote ~= nil)
	local n = shown and #c.zones or 0
	for i = n + 1, #zones do
		local z = zones[i]
		z.name:Hide()
		z.bar:Hide()
		z.count:Hide()
	end
	if not shown then return 0 end
	Place(w.zones, 0, y)
	local h = 20
	local barMax = CARD_W - ZONE_NAME_W - 10 - 40
	for i, e in ipairs(c.zones) do
		local z = Zone(i)
		z.name:SetText(e.name)
		Place(z.name, 0, y + h)
		z.bar:ClearAllPoints()
		z.bar:SetPoint("LEFT", z.name, "RIGHT", 10, 0)
		z.bar:SetWidth(math.max(1, math.floor(barMax * e.count / math.max(c.zoneMax, 1) + 0.5)))
		z.count:SetText(tostring(e.count))
		z.count:ClearAllPoints()
		z.count:SetPoint("RIGHT", cardChild, "TOPRIGHT", 0, -(y + h + 6))
		z.name:Show()
		z.bar:Show()
		z.count:Show()
		h = h + ZONE_H
	end
	if c.zonesNote then
		w.zonesNote:SetText(c.zonesNote)
		Place(w.zonesNote, 0, y + h)
		h = h + Height(w.zonesNote, 14)
	end
	return h
end

local function RenderCard(c)
	card:SetShown(c ~= nil)
	if not c then return end
	w.title:SetText(c.guild)
	if c.main then w.title:SetTextColor(1, 0.82, 0) else w.title:SetTextColor(1, 1, 1) end
	w.marks:SetText(c.marks)
	w.updated:SetText(c.updated)
	local y = 28
	w.conflict:SetShown(c.conflict and true or false)
	if c.conflict then
		Place(w.conflict, 0, y)
		y = y + Height(w.conflict, 28) + 6
	end
	for i, tile in ipairs(w.tiles) do
		local st = c.stats[i]
		Place(tile, (i - 1) * (tile.width + TILE_GAP), y)
		tile.value:SetText(st.value)
		if st.green then tile.value:SetTextColor(0.25, 1, 0.25) else tile.value:SetTextColor(1, 1, 1) end
		tile.label:SetText(st.label)
	end
	y = y + 48 + 6
	w.extra:SetText(c.extra)
	Place(w.extra, 0, y)
	y = y + Height(w.extra, 12) + 14
	local left = RenderPeople(c, y)
	local right = RenderMix(c, y)
	y = y + math.max(left, right) + 12
	y = y + RenderZones(c, y)
	cardChild:SetHeight(y + 8)
end

---------------------------------------------------------------------------
-- Сборка и показ
---------------------------------------------------------------------------
function CensusPane.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)

	list = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	list:SetPoint("TOPLEFT", 8, -8)
	list:SetPoint("BOTTOMLEFT", 8, 8)
	list:SetWidth(LIST_W)
	listChild = CreateFrame("Frame", nil, list)
	listChild:SetSize(LIST_W, 10)
	list:SetScrollChild(listChild)
	empty = FS(listChild, "GameFontDisable")
	empty:SetPoint("TOPLEFT", 6, -6)
	empty:SetWidth(LIST_W - 12)
	empty:SetText(L.CENSUS_EMPTY)
	empty:Hide()

	local divider = pane:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.08)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", 276, -10)
	divider:SetPoint("BOTTOMLEFT", 276, 10)

	card = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	card:SetPoint("TOPLEFT", CARD_X, -10)
	card:SetPoint("BOTTOMRIGHT", -30, 8)
	cardChild = CreateFrame("Frame", nil, card)
	cardChild:SetSize(CARD_W, 10)
	card:SetScrollChild(cardChild)

	w.title = FS(cardChild, "GameFontNormalLarge")
	w.title:SetPoint("TOPLEFT", 0, 0)
	w.marks = FS(cardChild, "GameFontDisableSmall")
	w.marks:SetPoint("BOTTOMLEFT", w.title, "BOTTOMRIGHT", 8, 1)
	w.updated = FS(cardChild, "GameFontDisableSmall", "RIGHT")
	w.updated:SetPoint("TOPRIGHT", 0, -5)
	w.conflict = FS(cardChild, "GameFontHighlightSmall")
	w.conflict:SetWidth(CARD_W)
	w.conflict:SetTextColor(1, 0.3, 0.3)
	w.conflict:SetText(L.TIP_CONFLICT)

	-- Четыре плитки с крупными числами: участники, в игре, офицеры, средний уровень.
	w.tiles = {}
	local tileW = math.floor((CARD_W - 3 * TILE_GAP) / 4)
	for i = 1, 4 do
		local tile = CreateFrame("Frame", nil, cardChild)
		tile:SetSize(tileW, 48)
		tile.width = tileW
		local bg = tile:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, 0.05)
		tile.value = FS(tile, "GameFontNormalHuge", "CENTER")
		tile.value:SetPoint("TOP", 0, -6)
		tile.label = FS(tile, "GameFontDisableSmall", "CENTER")
		tile.label:SetPoint("BOTTOM", 0, 6)
		w.tiles[i] = tile
	end
	w.extra = FS(cardChild, "GameFontDisableSmall")
	w.extra:SetWidth(CARD_W)

	w.leaders = FS(cardChild, "GameFontNormal")
	w.leaders:SetText(L.CARD_LEADERS)
	w.noLeaders = FS(cardChild, "GameFontDisableSmall")
	w.noLeaders:SetText(L.CARD_NO_LEADERS)

	w.classes = FS(cardChild, "GameFontNormal")
	w.classes:SetText(L.CARD_CLASSES)
	w.classBar = CreateFrame("Frame", nil, cardChild)
	w.classBar:SetSize(COL_R_W, 10)
	local barBg = w.classBar:CreateTexture(nil, "BACKGROUND")
	barBg:SetAllPoints()
	barBg:SetColorTexture(0, 0, 0, 0.45)
	w.classLegend = FS(cardChild, "GameFontDisableSmall") -- «Сейчас никого нет в игре.»
	w.classLegend:SetWidth(COL_R_W)
	w.levels = FS(cardChild, "GameFontNormal")
	w.levels:SetText(L.CARD_LEVELS)
	for i = 1, 7 do
		local col = {}
		col.bar = cardChild:CreateTexture(nil, "ARTWORK")
		col.bar:SetTexture(BAR)
		col.bar:SetVertexColor(0.95, 0.75, 0.2)
		col.bar:SetWidth(22)
		col.count = FS(cardChild, "GameFontHighlightSmall", "CENTER")
		col.label = FS(cardChild, "GameFontDisableSmall", "CENTER")
		levels[i] = col
	end
	w.stale = FS(cardChild, "GameFontDisableSmall")
	w.stale:SetWidth(COL_R_W)

	w.zones = FS(cardChild, "GameFontNormal")
	w.zones:SetText(L.CARD_ZONES)
	w.zonesNote = FS(cardChild, "GameFontDisableSmall")
	w.zonesNote:SetWidth(CARD_W)

	pane:Hide()
	CensusPane.frames = { pane = pane, rows = rows, people = people, segments = segments, levels = levels, zones = zones, legend = legend, w = w, card = card }
	return pane
end

-- Перерисовать: выбор держится, пока гильдия в списке; иначе — своя гильдия, иначе первая.
function CensusPane.Render()
	if not pane then return end
	local items = Views.CensusRows()
	local pick
	for _, it in ipairs(items) do
		if it.key == selected then pick = it end
	end
	if not pick then
		for _, it in ipairs(items) do
			if it.s.mine then pick = it end
		end
	end
	pick = pick or items[1]
	selected = pick and pick.key or nil
	RenderList(items)
	RenderCard(pick and Views.GuildCard(pick.s) or nil)
end

function CensusPane.Select(key)
	if key == selected then return end
	selected = key
	if card then card:SetVerticalScroll(0) end
	CensusPane.Render()
end

function CensusPane.Selected() return selected end

function CensusPane.Show()
	if not pane then return end
	pane:Show()
	CensusPane.Render()
end

function CensusPane.Hide()
	if pane then pane:Hide() end
end
