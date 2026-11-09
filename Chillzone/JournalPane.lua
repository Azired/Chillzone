-- Личный журнал доступен любому игроку. Копирование использует только наше поле,
-- не меняет игровые окна чата и удерживает снимок, пока продолжается запись.
local ADDON, ns = ...
local L = ns.L
local Pane = { frames = {} }
ns.JournalPane = Pane
local revision, limit, copying = -1, nil, false

local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("journal button", fn) end)
	return b
end

local function Render(force)
	local f = Pane.frames
	if not f.pane then return end
	f.toggle:SetText(ns.Diagnostics.Enabled() and L.JOURNAL_STOP or L.JOURNAL_START)
	if copying then return end
	if not force and revision == ns.logRevision then return end
	-- Не сбрасываем место, если игрок прокрутил журнал к старым событиям.
	if not force and not f.messages:AtBottom() then return end
	f.messages:Clear()
	local log = ns.db.log
	for i = math.max(1, #log - (limit or #log) + 1), #log do
		f.messages:AddMessage((log[i]:gsub("|", "||")), 0.8, 0.8, 0.8)
	end
	f.messages:ScrollToBottom()
	revision = ns.logRevision
end

function Pane.SetLimit(n)
	if copying then Pane.frames.back:Click() end
	limit = n
	Render(true)
end

function Pane.Build(parent)
	local f = Pane.frames
	local pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	f.pane = pane
	f.toggle = Button(pane, L.JOURNAL_START, 150, function()
		ns.Diagnostics.SetEnabled(not ns.Diagnostics.Enabled())
		Render(true)
	end)
	f.toggle:SetPoint("TOPLEFT", 10, -8)
	f.copy = Button(pane, L.JOURNAL_COPY, 160, function()
		copying = true
		f.clear:SetEnabled(false)
		f.messages:Hide()
		f.export:Show()
		local report = ns.Diagnostics.Report()
		f.measure:SetText(report)
		f.box:SetHeight(math.max(300, f.measure:GetStringHeight() + 16))
		f.box:SetText(report)
		f.export:SetVerticalScroll(0)
		f.box:SetFocus()
		f.box:HighlightText()
		f.back:Show()
		f.hint:SetText(L.JOURNAL_COPY_HINT)
	end)
	f.copy:SetPoint("LEFT", f.toggle, "RIGHT", 8, 0)
	f.clear = Button(pane, L.JOURNAL_CLEAR, 100, function()
		ns.Diagnostics.Clear()
		limit = nil
		Render(true)
	end)
	f.clear:SetPoint("LEFT", f.copy, "RIGHT", 8, 0)
	f.hint = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.hint:SetPoint("TOPLEFT", 12, -38)
	f.hint:SetPoint("TOPRIGHT", -12, -38)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetText(L.JOURNAL_HINT)
	local messages = CreateFrame("ScrollingMessageFrame", nil, pane)
	messages:SetPoint("TOPLEFT", 12, -74)
	messages:SetPoint("BOTTOMRIGHT", -12, 10)
	messages:SetFontObject("ChatFontNormal")
	messages:SetJustifyH("LEFT")
	messages:SetFading(false)
	messages:SetMaxLines(1100)
	messages:EnableMouseWheel(true)
	messages:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	f.messages = messages
	local export = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	export:SetPoint("TOPLEFT", 12, -74)
	export:SetPoint("BOTTOMRIGHT", -32, 38)
	local box = CreateFrame("EditBox", nil, export)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject("ChatFontNormal")
	box:SetTextInsets(4, 4, 4, 4)
	box:SetWidth(740)
	box:SetHeight(300)
	box:SetMaxLetters(0)
	export:SetScrollChild(box)
	box:SetScript("OnTextChanged", function() export:UpdateScrollChildRect() end)
	export:SetScript("OnSizeChanged", function(self, width) box:SetWidth(math.max(100, width)) end)
	f.export, f.box = export, box
	f.measure = pane:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	f.measure:SetWidth(732)
	f.measure:SetWordWrap(true)
	f.measure:Hide()
	f.back = Button(pane, L.JOURNAL_BACK, 180, function()
		copying = false
		f.clear:SetEnabled(true)
		box:ClearFocus()
		export:Hide()
		f.back:Hide()
		messages:Show()
		f.hint:SetText(L.JOURNAL_HINT)
		Render(true)
	end)
	f.back:SetPoint("BOTTOMLEFT", 12, 8)
	box:SetScript("OnEscapePressed", function() f.back:Click() end)
	export:Hide()
	f.back:Hide()
	local elapsed = 0
	pane:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed >= 0.5 then elapsed = 0; Render(false) end
	end)
	pane:Hide()
end

function Pane.Show()
	Pane.frames.pane:Show()
	Render(false)
end

function Pane.Hide()
	local f = Pane.frames
	if not f.pane then return end
	f.box:ClearFocus()
	copying, revision, limit = false, -1, nil
	f.export:Hide()
	f.back:Hide()
	f.clear:SetEnabled(true)
	f.messages:Show()
	f.hint:SetText(L.JOURNAL_HINT)
	f.pane:Hide()
end
