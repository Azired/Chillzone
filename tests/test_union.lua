-- Объединение: состав задаёт только текущий глава главной гильдии.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Северный союз")
    local k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0 })
    local o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1 })
    local v = w:Client({ first = "Вера", surname = "Верная", guild = "Северный союз", rank = 0 })
    w:Run(30)
    w:Init(k, v)
    w:Run(15)
    return w, k, o, v
end

T.test("union: управляет ровно текущий глава Чиллзон", function()
    local w, k, o, v = Build()
    T.ok(k.ns.Security.CanManageUnion(), "глава главной гильдии")
    T.no(o.ns.Security.CanManageUnion(), "офицер главной гильдии")
    T.no(v.ns.Security.CanManageUnion(), "глава другой гильдии")
    k.rank, o.rank = 1, 0
    k.ns.Roster.Scan(); o.ns.Roster.Scan()
    w:Run(1)
    T.no(k.ns.Security.CanManageUnion(), "прежний глава сразу теряет управление")
    T.ok(o.ns.Security.CanManageUnion(), "новый глава получает управление")
end)

T.test("union: название не даёт членства, глава добавляет произвольную гильдию", function()
    local w, k, o, v = Build()
    T.no(k.ns.Util.IsMemberGuild("Чиллзон Подделка"), "подстроки недостаточно")
    T.no(v.ns.IsMember(), "до подтверждения не участник")
    T.ok(v.ns.Security.Link(o:Name()), "представитель может попросить соединения")
    w:Run(5)
    T.no(o.ns.Security.Accept(v:Name()), "офицер не добавляет гильдию")
    T.ok(v.ns.Security.Link(k:Name()))
    w:Run(5)
    T.eq(#k.ns.Security.UnionRequests(), 1, "заявка видна главе")
    T.ok(k.ns.Security.Accept(v:Name()), "глава подтверждает гильдию")
    w:Run(55)
    for _, c in ipairs({ k, o, v }) do
        T.ok(c.ns.Util.IsMemberGuild("СЕВЕРНЫЙ СОЮЗ"), c:Name() .. ": подписанный состав дошёл")
        T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок")
    end
    T.ok(v.ns.IsMember(), "подключённая гильдия получила доступ")
    T.eq(#k.ns.Security.UnionRequests(), 0, "подтверждённая заявка убрана")
    v:Slash("/cz1", "сообщение подключённой гильдии")
    w:Run(40)
    T.eq(k:Saw("сообщение подключённой гильдии"), 1, "глава видит сообщение гильдии с произвольным названием")
    T.eq(o:Saw("сообщение подключённой гильдии"), 1, "сообщение доставлено в главную гильдию")
end)

T.test("union: удаление подписано, старое добавление не возвращает гильдию", function()
    local w, k, o, v = Build()
    w:Pair(v, k)
    w:Run(55)
    local gk = k.ns.Util.GuildKey(v.guild)
    local old = k.ns.store.security.policies[gk].wire
    T.no(o.ns.Security.RemoveGuild(v.guild), "офицер не удаляет")
    T.no(v.ns.Security.RemoveGuild(v.guild), "чужой глава не удаляет")
    T.no(k.ns.Security.RemoveGuild("Чиллзон"), "главную гильдию не удалить")
    T.ok(k.ns.Security.RemoveGuild(v.guild))
    w:Run(40)
    k.ns.Security.SendPolicies(v:Name())
    w:Run(15)
    for _, c in ipairs({ k, o, v }) do
        T.no(c.ns.Util.IsMemberGuild(v.guild), c:Name() .. ": гильдия исключена")
        c.ns.Comm.Dispatch(old, k:Name(), "WHISPER")
    end
    w:Run(5)
    for _, c in ipairs({ k, o, v }) do T.no(c.ns.Util.IsMemberGuild(v.guild), "повтор старого каталога отклонён") end
    local signed = false
    T.no(v.ns.Security.Seal(v.ns.Codec.EncodeChat("A", v.guild, 10001, "MAGE", "после исключения"),
        function() signed = true end), "исключённая гильдия не отправляет чат")
    w:Run(2)
    T.no(signed)
    w:Pair(v, k)
    w:Run(40)
    for _, c in ipairs({ k, o, v }) do T.ok(c.ns.Util.IsMemberGuild(v.guild), "гильдию можно снова добавить") end
end)

T.test("union: подключение и удаление через кнопки вкладки", function()
    local w, k, _, v = Build()
    k.ns.UI.Toggle("union")
    local ui = k.ns.UnionPane.frames
    T.ok(ui.pane:IsShown())
    ui.input:SetText(v:Name())
    ui.connect.scripts.OnClick()
    w:Run(5)
    T.eq(ui.input:GetText(), "", "имя отправлено, поле очищено")
    T.ok(v.ns.Security.Accept(k:Name()), "представитель принимает запрос главы")
    w:Run(45)
    T.ok(v.ns.IsMember())
    local action
    for _, row in ipairs(ui.rows) do if row.entry.guild == v.guild then action = row.action end end
    T.ok(action, "подключённая гильдия показана в списке")
    action.scripts.OnClick()
    T.ok(v.ns.IsMember(), "первый щелчок только просит подтверждение")
    action.scripts.OnClick()
    w:Run(40)
    T.no(v.ns.IsMember(), "подтверждённое удаление дошло до гильдии")
    T.eq(#k.ns.db.errors, 0)
end)

T.test("union: вкладка управления исчезает при передаче главы", function()
    local _, k, o, v = Build()
    k.ns.UI.Toggle("union")
    T.ok(k.ns.UI.tabs.union:IsShown())
    o.ns.UI.Toggle("union")
    v.ns.UI.Toggle("union")
    T.no(o.ns.UI.tabs.union:IsShown())
    T.no(v.ns.UI.tabs.union:IsShown())
    T.no(o.ns.UI.Current() == "union")
    k.rank, o.rank = 1, 0
    k.ns.Roster.Scan(); o.ns.Roster.Scan()
    k.ns.UI.Render(); o.ns.UI.Render()
    T.no(k.ns.UI.tabs.union:IsShown())
    T.ok(o.ns.UI.tabs.union:IsShown())
    T.no(k.ns.UI.Current() == "union")
end)

T.test("union: решение офицера с настоящей подписью не меняет состав", function()
    local w, k, o, v = Build()
    w:Pair(v, k)
    w:Run(30)
    local Ed, cred = o.ns.Ed25519, o.ns.Security.MyCertificate()
    T.ok(cred and cred.role == "officer")
    local now = o.ns.ServerTime()
    local values = { o.ns.group, o.ns.faction, "Чиллзон Подделка", v:Name(),
        v.ns.Security.MyCertificate().public, now, now + 600, "1", 1 }
    local parts = { "GUILDROOT:" }
    for _, value in ipairs(values) do
        value = tostring(value)
        parts[#parts + 1] = #value .. ":" .. value
    end
    local body, seed = table.concat(parts)
    for _, key in pairs(o.ns.db.securityKeys) do seed = Ed.FromB64(key.seed) end
    T.ok(seed, "настоящий личный ключ офицера")
    local wire = "KA~" .. Ed.ToB64(cred.raw) .. "~" .. Ed.ToB64(body) .. "~" .. Ed.ToB64(Ed.Sign(seed, body))
    for _, c in ipairs({ k, v }) do c.ns.Comm.Dispatch(wire, o:Name(), "WHISPER") end
    w:Run(5)
    for _, c in ipairs({ k, v }) do T.no(c.ns.Util.IsMemberGuild("Чиллзон Подделка"), "одной подписи офицера недостаточно") end
end)

T.test("union: новый глава подписывает состав, новый читатель узнаёт его без личного подтверждения", function()
    local w, k, o, v = Build()
    w:Pair(v, k)
    w:Run(60)
    k.rank, o.rank = 1, 0
    k.ns.Roster.Scan(); o.ns.Roster.Scan()
    w:Run(65)
    T.no(k.ns.Security.RemoveGuild(v.guild), "прежний глава не управляет")
    local reader = w:Client({ first = "Новый", surname = "Читатель", guild = v.guild, rank = 3 })
    v.ns.Roster.Scan()
    w:Run(60)
    T.ok(reader.ns.IsMember(), "состав передан новичку внутри гильдии")
    T.ok(o.ns.Security.RemoveGuild(v.guild), "новый глава исключает гильдию")
    w:Run(90)
    for _, c in ipairs({ k, o, v, reader }) do
        T.no(c.ns.Util.IsMemberGuild(v.guild), c:Name() .. ": решение нового главы дошло")
        T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок")
    end
end)
