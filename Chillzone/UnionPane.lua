-- Chillzone: вкладка «Объединение». Текущий глава главной гильдии управляет составом,
-- офицер гильдии вне объединения запрашивает связь. Права проверяет Security.
local ADDON, ns = ...
local L, S = ns.L, ns.Security
local P = {}
ns.UnionPane = P
local pane, child, scroll, caption, input, connect, message
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
local function Mode()
    if S.CanManageUnion() then return "manage" end
    if S.CanRequestUnion() then return "request" end
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
    caption = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("TOPLEFT", 16, -16)
    caption:SetText(L.UNION_NAME)
    input = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    input:SetSize(290, 24)
    input:SetPoint("TOPLEFT", 22, -32)
    input:SetAutoFocus(false)
    input:SetMaxLetters(64)
    input:SetScript("OnEnterPressed", Connect)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    connect = Button(pane, L.UNION_CONNECT, 180, Connect)
    connect:SetPoint("LEFT", input, "RIGHT", 12, 0)
    message = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    message:SetJustifyH("LEFT")
    scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(730, 10)
    scroll:SetScrollChild(child)
    P.frames = { pane = pane, caption = caption, input = input, connect = connect, message = message,
        rows = rows, headers = headers }
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
        local entry = row.entry
        if entry.init then
            S.Init(false, function(text)
                -- Этот текст написан для чата и называет команды, а здесь дальше просто кнопка.
                message:SetText(text == L.AUTH_INIT_OK and L.UNION_INIT_OK or text)
            end)
            return
        end
        if entry.ask then
            local ok, why = S.Link(ns.Config.MAIN_GUILD_LEADER)
            if not ok and why then message:SetText(why) end -- без причины итог уже показал LinkNotice
            return
        end
        if not S.CanManageUnion() then return end
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
    if item.text then
        label, action = item.text, item.action
    elseif item.request then
        label, action = L.UNION_REQUEST:format(item.guild, ns.Util.Display(item.contact)), L.UNION_ADD
    elseif item.known then
        label = L.UNION_KNOWN:format(item.guild, ns.Util.Display(item.root))
        action = confirming == "add:" .. item.guild and L.UNION_CONFIRM_ADD or L.UNION_ADD
    elseif confirming == "remove:" .. item.guild then
        action = L.UNION_CONFIRM_REMOVE
    end
    row.label:SetText(label)
    row.action:SetShown(action ~= nil and not item.main)
    row.action:SetText(action or "")
    row.action:SetEnabled(not item.disabled)
end
local function Place(frame, y)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", 0, -y)
    frame:Show()
end
local function ManageSections()
    local requests, known = {}, {}
    for _, r in ipairs(S.UnionRequests()) do
        requests[#requests + 1] = { guild = r.guild, contact = r.contact, request = true }
    end
    for _, r in ipairs(S.KnownGuilds()) do
        known[#known + 1] = { guild = r.guild, root = r.root, known = true }
    end
    return {
        { title = L.UNION_SECTION_REQUESTS, items = requests },
        { title = L.UNION_SECTION_MEMBERS, items = S.UnionGuilds() },
        { title = L.UNION_SECTION_KNOWN, tip = L.UNION_KNOWN_TIP, items = known },
    }
end
local function RequestSections()
    local root, leader = S.MyRoot(), ns.Config.MAIN_GUILD_LEADER
    local state = S.LinkState(leader)
    local text = state == "sent" and L.UNION_LEADER_WAITING or state == "queued" and L.UNION_LEADER_QUEUED or L.UNION_LEADER
    local items = {
        { text = root and L.UNION_ROOT:format(ns.Util.Display(root.name)) or L.UNION_NO_ROOT,
          action = not root and L.UNION_INIT or nil, init = true },
        { text = text:format(ns.Util.Display(leader)), action = L.UNION_CONNECT, ask = true,
          disabled = not root or state ~= nil },
    }
    return { { title = L.UNION_SECTION_CONNECT:format((ns.MyGuild())), tip = L.UNION_CONNECT_TIP, items = items } }
end
-- Глава вводит имя представителя над списком. Офицеру поле не нужно: итог запроса виден под строками.
local function Layout(mode)
    local manage = mode == "manage"
    caption:SetShown(manage)
    input:SetShown(manage)
    connect:SetShown(manage)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 12, manage and -96 or -16)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
end
local function PlaceMessage(mode, y)
    message:ClearAllPoints()
    if mode == "manage" then
        message:SetPoint("TOPLEFT", 16, -62)
        message:SetPoint("RIGHT", -16, 0)
    else
        message:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -y - 8)
        message:SetPoint("RIGHT", child, "RIGHT", -4, 0)
    end
end
function P.Render()
    local mode = pane and Mode()
    if not mode then P.Hide(); return end
    Layout(mode)
    local y, rowCount, headerCount = 0, 0, 0
    for _, section in ipairs(mode == "manage" and ManageSections() or RequestSections()) do
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
    PlaceMessage(mode, y)
end
function P.Show()
    if not Mode() then return end
    pane:Show()
    P.Render()
end
function P.Hide()
    if pane then pane:Hide(); input:ClearFocus() end
    confirming = nil
end
local function RenderIfShown()
    if pane and pane:IsShown() then P.Render() end
end
ns.On("AUTH_ROOT", RenderIfShown)
ns.On("UNION_LINK", function(text)
    if message then message:SetText(text) end
    RenderIfShown()
end)
