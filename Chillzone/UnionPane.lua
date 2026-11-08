-- Chillzone: управление составом объединения, только текущему главе главной гильдии.
local ADDON, ns = ...
local L, S = ns.L, ns.Security
local P = {}
ns.UnionPane = P
local pane, child, input, message
-- confirming: "add:Гильдия" или "remove:Гильдия" — какой кнопке нужен второй щелчок.
local rows, headers, confirming = {}, {}, nil
local ROW_HEIGHT, HEADER_HEIGHT, HEADER_GAP, SECTION_GAP = 32, 24, 6, 18

local function Button(parent, text, width, fn)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", function() ns.SafeCall("объединение", fn) end)
    return b
end
local function Connect()
    if not S.CanManageUnion() then return end
    local ok, why = S.Link(ns.Util.Trim(input:GetText()))
    if ok then
        input:SetText("")
        input:ClearFocus()
        message:SetText(L.UNION_SENT)
    else
        message:SetText(why or L.UNION_LINK_FAILED)
    end
end
function P.Build(parent)
    pane = CreateFrame("Frame", nil, parent)
    pane:SetAllPoints(parent)
    local caption = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("TOPLEFT", 16, -16)
    caption:SetText(L.UNION_NAME)
    input = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    input:SetSize(290, 24)
    input:SetPoint("TOPLEFT", 22, -32)
    input:SetAutoFocus(false)
    input:SetMaxLetters(64)
    input:SetScript("OnEnterPressed", Connect)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local connect = Button(pane, L.UNION_CONNECT, 180, Connect)
    connect:SetPoint("LEFT", input, "RIGHT", 12, 0)
    message = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    message:SetPoint("TOPLEFT", 16, -62)
    message:SetPoint("RIGHT", -16, 0)
    message:SetJustifyH("LEFT")
    local scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -96)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(730, 10)
    scroll:SetScrollChild(child)
    P.frames = { pane = pane, input = input, connect = connect, rows = rows, headers = headers }
    pane:Hide()
end
local function RowAt(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Frame", nil, child)
    row:SetSize(730, 30)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 4, 0)
    row.label:SetPoint("RIGHT", -200, 0)
    row.label:SetJustifyH("LEFT")
    row.action = Button(row, "", 180, function()
        if not S.CanManageUnion() then return end
        local entry = row.entry
        local key = (entry.known and "add:" or "remove:") .. entry.guild
        if entry.request then
            local ok, why = S.Accept(entry.contact)
            if not ok then message:SetText(why or L.UNION_ACCEPT_FAILED) end
        elseif confirming ~= key then
            confirming = key
        elseif entry.known then
            confirming = nil
            message:SetText(S.AddKnown(entry.guild) and L.UNION_KNOWN_ADDED:format(entry.guild)
                or L.UNION_KNOWN_FAILED)
        else
            S.RemoveGuild(entry.guild)
            confirming = nil
        end
        P.Render()
    end)
    row.action:SetPoint("RIGHT", -4, 0)
    rows[i] = row
    return row
end
local function HeaderAt(i)
    if headers[i] then return headers[i] end
    local header = CreateFrame("Frame", nil, child)
    header:SetSize(730, HEADER_HEIGHT)
    header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.label:SetPoint("LEFT", 4, 0)
    local line = header:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.08)
    line:SetPoint("BOTTOMLEFT", 4, 0)
    line:SetPoint("BOTTOMRIGHT", -4, 0)
    line:SetHeight(1)
    header:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:AddLine(self.tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    header:SetScript("OnLeave", function() GameTooltip:Hide() end)
    headers[i] = header
    return header
end
local function Fill(row, item)
    row.entry = item
    local label, action = item.guild, L.UNION_REMOVE
    if item.request then
        label, action = L.UNION_REQUEST:format(item.guild, ns.Util.Display(item.contact)), L.UNION_ADD
    elseif item.known then
        label = L.UNION_KNOWN:format(item.guild, ns.Util.Display(item.root))
        action = confirming == "add:" .. item.guild and L.UNION_CONFIRM_ADD or L.UNION_ADD
    elseif confirming == "remove:" .. item.guild then
        action = L.UNION_CONFIRM_REMOVE
    end
    row.label:SetText(label)
    row.action:SetShown(not item.main)
    row.action:SetText(action)
end
local function Place(frame, y)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", 0, -y)
    frame:Show()
end
function P.Render()
    if not pane or not S.CanManageUnion() then P.Hide(); return end
    local requests, known = {}, {}
    for _, r in ipairs(S.UnionRequests()) do
        requests[#requests + 1] = { guild = r.guild, contact = r.contact, request = true }
    end
    for _, r in ipairs(S.KnownGuilds()) do
        known[#known + 1] = { guild = r.guild, root = r.root, known = true }
    end
    local y, rowCount, headerCount = 0, 0, 0
    for _, section in ipairs({
        { title = L.UNION_SECTION_REQUESTS, items = requests },
        { title = L.UNION_SECTION_MEMBERS, items = S.UnionGuilds() },
        { title = L.UNION_SECTION_KNOWN, tip = L.UNION_KNOWN_TIP, items = known },
    }) do
        if #section.items > 0 then
            if headerCount > 0 then y = y + SECTION_GAP end
            headerCount = headerCount + 1
            local header = HeaderAt(headerCount)
            header.title, header.tip = section.title, section.tip
            header.label:SetText(section.tip and section.title .. " |cff808080(?)|r" or section.title)
            header:EnableMouse(section.tip ~= nil)
            Place(header, y)
            y = y + HEADER_HEIGHT + HEADER_GAP
            for _, item in ipairs(section.items) do
                rowCount = rowCount + 1
                local row = RowAt(rowCount)
                Fill(row, item)
                Place(row, y)
                y = y + ROW_HEIGHT
            end
        end
    end
    for i = rowCount + 1, #rows do rows[i]:Hide() end
    for i = headerCount + 1, #headers do headers[i]:Hide() end
    child:SetHeight(math.max(10, y))
end
function P.Show()
    if not S.CanManageUnion() then return end
    pane:Show()
    P.Render()
end
function P.Hide()
    if pane then pane:Hide(); input:ClearFocus() end
    confirming = nil
end
