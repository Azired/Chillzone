-- Chillzone: управление составом объединения, только текущему главе главной гильдии.
local ADDON, ns = ...
local L, S = ns.L, ns.Security
local P = {}
ns.UnionPane = P
local pane, child, input, message
-- confirming: "add:Гильдия" или "remove:Гильдия" — какой кнопке нужен второй щелчок.
local rows, confirming = {}, nil

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
    local hint = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 16, -14)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(L.UNION_HINT)
    input = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    input:SetSize(290, 24)
    input:SetPoint("TOPLEFT", 22, -65)
    input:SetAutoFocus(false)
    input:SetMaxLetters(64)
    input:SetScript("OnEnterPressed", Connect)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local connect = Button(pane, L.UNION_CONNECT, 180, Connect)
    connect:SetPoint("LEFT", input, "RIGHT", 12, 0)
    message = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    message:SetPoint("TOPLEFT", 16, -98)
    message:SetPoint("RIGHT", -16, 0)
    message:SetJustifyH("LEFT")
    local scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -130)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(730, 10)
    scroll:SetScrollChild(child)
    P.frames = { pane = pane, input = input, connect = connect, rows = rows }
    pane:Hide()
end
function P.Render()
    if not pane or not S.CanManageUnion() then P.Hide(); return end
    local list = {}
    for _, r in ipairs(S.UnionRequests()) do
        list[#list + 1] = { guild = r.guild, contact = r.contact, request = true }
    end
    for _, r in ipairs(S.UnionGuilds()) do list[#list + 1] = r end
    for _, r in ipairs(S.KnownGuilds()) do
        list[#list + 1] = { guild = r.guild, root = r.root, known = true }
    end
    for i, item in ipairs(list) do
        local row = rows[i]
        if not row then
            row = CreateFrame("Frame", nil, child)
            row:SetSize(730, 30)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * 32)
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
        end
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
        row:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    child:SetHeight(math.max(10, #list * 32))
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
