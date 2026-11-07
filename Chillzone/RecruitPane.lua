-- Chillzone: экран вступления, собственное окно письма и отдельная вкладка заявок.
-- Порядок действий — из Olympus Recruit.lua (MIT); игровые popup и поле чата не трогаем.
local ADDON, ns = ...

local L, U, R = ns.L, ns.Util, ns.Recruit
local Pane = { frames = {}, requestRows = {} }
ns.RecruitPane = Pane
local guildRows, replyRows = {}, {}
local pane, child, note, inbox, inboxChild, inboxHint, inboxEmpty, inboxRefresh

local function Label(parent, x, y, width, font)
	local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	f:SetPoint("TOPLEFT", x, -y)
	f:SetWidth(width)
	f:SetJustifyH("LEFT")
	return f
end
local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("заявки: щелчок", fn) end)
	return b
end

function Pane.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	Label(pane, 16, 12, 720, "GameFontNormalLarge"):SetText(L.RECRUIT_TITLE)
	Label(pane, 16, 40, 740):SetText(L.RECRUIT_INTRO)
	local search = Button(pane, L.RECRUIT_SEARCH, 190, function() ns.Who.Search() end)
	search:SetPoint("TOPLEFT", 16, -78)
	note = Label(pane, 222, 83, 530)
	local scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -112)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(740, 10)
	scroll:SetScrollChild(child)
	Pane.frames.pane, Pane.frames.search = pane, search
	pane:Hide()
	return pane
end

function Pane.Render()
	if not pane then return end
	local guilds, y = R.Guilds(), 0
	if ns.Who.IsPending() then note:SetText(L.RECRUIT_SEARCHING)
	elseif #guilds == 0 then note:SetText(L.RECRUIT_EMPTY)
	else note:SetText(ns.Who.missing and L.RECRUIT_MORE_SEARCH or L.RECRUIT_SEARCH_DONE) end
	for i, g in ipairs(guilds) do
		local row = guildRows[i]
		if not row then
			row = CreateFrame("Frame", nil, child)
			row:SetSize(730, 54)
			row.title = Label(row, 0, 1, 480, "GameFontNormal")
			row.sub = Label(row, 0, 23, 480)
			row.ask = Button(row, L.RECRUIT_ASK, 210, function()
				local p = R.NextContact(row.guild)
				if p then R.Prompt(p) else ns.Print(L.RECRUIT_NOBODY) end
			end)
			row.ask:SetPoint("TOPRIGHT", 0, -5)
			guildRows[i] = row
		end
		row.guild = g.name
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
		row.title:SetText(ns.Codec.Plain(g.name))
		row.sub:SetText(L.RECRUIT_GUILD:format(#g.members, g.free and tostring(g.free) or "?"))
		local contact = R.NextContact(g.name)
		row.ask:SetText(contact and L.RECRUIT_ASK or L.RECRUIT_NOBODY)
		row.ask:SetEnabled(contact ~= nil)
		row:Show()
		y = y + 54
	end
	for i = #guilds + 1, #guildRows do guildRows[i]:Hide() end
	local replies = {}
	for key, text in pairs(R.replied) do replies[#replies + 1] = { key = key, text = text } end
	table.sort(replies, function(a, b) return a.key < b.key end)
	for i, reply in ipairs(replies) do
		local label = replyRows[i] or Label(child, 0, 0, 725)
		replyRows[i] = label
		label:ClearAllPoints()
		label:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
		label:SetText(L.RECRUIT_REPLY:format(R.replyNames[reply.key] or reply.key, reply.text))
		label:SetTextColor(0.4, 1, 0.4)
		label:Show()
		y = y + math.max(36, label:GetStringHeight() or 0) + 6
	end
	for i = #replies + 1, #replyRows do replyRows[i]:Hide() end
	child:SetHeight(math.max(10, y))
end
function Pane.Show() if pane then pane:Show(); Pane.Render() end end
function Pane.Hide() if pane then pane:Hide() end; R.Cancel() end

function Pane.CloseDialog()
	local d = Pane.frames.dialog
	if d then d:Hide() end
end
function Pane.ShowDialog(contact, message)
	local f = Pane.frames
	if not f.dialog then
		local d = CreateFrame("Frame", "ChillzoneRecruitDialog", UIParent, "BasicFrameTemplateWithInset")
		d:SetSize(480, 226)
		d:SetPoint("CENTER")
		d:SetFrameStrata("DIALOG")
		if d.TitleText then d.TitleText:SetText(L.RECRUIT_TITLE) end
		f.to = Label(d, 16, 36, 448, "GameFontNormal")
		local box = CreateFrame("EditBox", nil, d)
		box:SetMultiLine(true)
		box:SetAutoFocus(false)
		box:SetFontObject("ChatFontNormal")
		box:SetTextInsets(6, 6, 6, 6)
		box:SetSize(448, 94)
		box:SetPoint("TOPLEFT", 16, -62)
		box:SetMaxBytes(250)
		local bg = box:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.55)
		local function Send()
			if R.pending then R.Ask(R.pending, box:GetText()) end
		end
		f.send = Button(d, L.RECRUIT_SEND, 120, Send)
		f.send:SetPoint("BOTTOMRIGHT", -148, 16)
		local cancel = Button(d, L.RECRUIT_CANCEL, 120, R.Cancel)
		cancel:SetPoint("BOTTOMRIGHT", -16, 16)
		box:SetScript("OnEscapePressed", R.Cancel)
		box:SetScript("OnEnterPressed", Send)
		d:SetScript("OnHide", function() R.pending = nil; box:ClearFocus() end)
		table.insert(UISpecialFrames, "ChillzoneRecruitDialog")
		f.dialog, f.box = d, box
	end
	f.to:SetText(L.RECRUIT_TO:format(U.Display(contact.name), contact.guild))
	f.box:SetText(message)
	f.dialog:Show()
	f.box:SetFocus()
end

function Pane.BuildInbox(parent)
	inbox = CreateFrame("Frame", nil, parent)
	inbox:SetAllPoints(parent)
	inboxHint = Label(inbox, 16, 14, 570)
	inboxRefresh = Button(inbox, L.RECRUIT_REFRESH, 135, function() ns.RecruitSync.RequestSync() end)
	inboxRefresh:SetPoint("TOPRIGHT", -16, -10)
	local scroll = CreateFrame("ScrollFrame", nil, inbox, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -58)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	inboxChild = CreateFrame("Frame", nil, scroll)
	inboxChild:SetSize(740, 10)
	scroll:SetScrollChild(inboxChild)
	inboxEmpty = Label(inboxChild, 0, 12, 730, "GameFontDisable")
	inboxEmpty:SetText(L.RECRUIT_INBOX_EMPTY)
	inbox:SetScript("OnShow", function() ns.RecruitSync.RequestSync() end)
	Pane.frames.inbox, Pane.frames.inboxEmpty = inbox, inboxEmpty
	inbox:Hide()
end

function Pane.RenderInbox()
	if not inbox then return end
	local reqs = {}
	for _, req in ipairs(R.Requests()) do reqs[#reqs + 1] = req end
	table.sort(reqs, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.name < b.name
	end)
	local shared = ns.RecruitSync.IsOfficer()
	inboxHint:SetText(shared and (R.CanInvite() and L.RECRUIT_INBOX_SHARED or L.RECRUIT_INBOX_NO_INVITE) or L.RECRUIT_INBOX_PERSONAL)
	inboxRefresh:SetShown(shared)
	inboxEmpty:SetShown(#reqs == 0)
	local y = 0
	for count, req in ipairs(reqs) do
		local row = Pane.requestRows[count]
		if not row then
			row = CreateFrame("Frame", nil, inboxChild)
			row:SetSize(730, 98)
			row:EnableMouse(true)
			row:SetScript("OnEnter", function(self)
				if not self.req then return end
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(L.RECRUIT_TO:format(U.Display(self.req.name), self.req.guild), 1, 0.82, 0, true)
				GameTooltip:AddLine(self.req.text or L.RECRUIT_NO_TEXT, 1, 1, 1, true)
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", function() GameTooltip:Hide() end)
			row.title = Label(row, 0, 0, 730, "GameFontNormal")
			row.message = Label(row, 0, 20, 730)
			row.message:SetHeight(26)
			row.source = Label(row, 0, 48, 730, "GameFontDisableSmall")
			row.accept = Button(row, L.RECRUIT_INVITE, 140, function() R.Accept(row.req) end)
			row.accept:SetPoint("TOPLEFT", 0, -66)
			row.decline = Button(row, L.RECRUIT_DECLINE, 130, function() R.Decline(row.req) end)
			row.decline:SetPoint("TOPLEFT", 148, -66)
			row.point = Button(row, L.RECRUIT_POINT, 226, function() R.Point(row.req) end)
			row.point:SetPoint("TOPLEFT", 0, -66)
			row.dismiss = Button(row, L.RECRUIT_DISMISS, 170, function() R.Dismiss(row.req) end)
			row.dismiss:SetPoint("TOPLEFT", 300, -66)
			Pane.requestRows[count] = row
		end
		row.req = req
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", inboxChild, "TOPLEFT", 0, -y)
		row.title:SetText(L.RECRUIT_REQUEST:format(U.Display(req.name), req.level, L.CLASS[req.class] or "", ns.Views.Ago(ns.Now() - req.t)))
		row.message:SetText(req.text or L.RECRUIT_NO_TEXT)
		row.source:SetText(L.RECRUIT_SOURCE:format(U.Display(req.origin or ns.me)))
		row.accept:SetShown(R.CanInvite())
		row.decline:SetShown(R.CanInvite())
		row.point:SetShown(not R.CanInvite() and R.Officer() ~= nil)
		row.dismiss:SetText(shared and L.RECRUIT_CLOSE or L.RECRUIT_DISMISS)
		row:Show()
		y = y + 98
	end
	for i = #reqs + 1, #Pane.requestRows do Pane.requestRows[i]:Hide() end
	inboxChild:SetHeight(math.max(y, 60))
end
function Pane.ShowInbox() if inbox then inbox:Show(); Pane.RenderInbox() end end
function Pane.HideInbox() if inbox then inbox:Hide() end end
