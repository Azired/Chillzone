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

T.test("union: новый участник главной гильдии получает состав при входе", function()
    local w, k, _, v = Build()
    w:Pair(v, k)
    w:Run(40)
    local reader = w:Client({ first = "Новый", surname = "Главный", guild = k.guild, rank = 3 })
    k.ns.Roster.Scan()
    w:Run(60)
    T.ok(reader.ns.Util.IsMemberGuild(v.guild), "главная гильдия тоже запрашивает состав при первом объявлении")
    T.eq(#reader.ns.db.errors, 0)
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

-- Корень гильдии в хранилище клиента, как после подключения в прежней версии.
local function KnowRoot(client, owner)
    local gk = owner.ns.Util.GuildKey(owner.guild)
    local root = owner.ns.Security.Roots()[gk]
    client.ns.store.security.roots[gk] = { guild = root.guild, name = root.name, public = root.public }
end

-- Сколько раз глава шепнул решение контакту гильдии.
local function CountContact(client)
    local box, send = { n = 0 }, client.ns.Comm.Send
    client.ns.Comm.Send = function(dist, msg, opts)
        if dist == "WHISPER" and opts and type(opts.key) == "string" and opts.key:find("^union%-contact:") then
            box.n = box.n + 1
        end
        return send(dist, msg, opts)
    end
    return box
end

T.test("union: глава добавляет известную гильдию без запроса связи, со вторым щелчком", function()
    local w, k, o, v = Build()
    T.eq(#k.ns.Security.KnownGuilds(), 0, "чужой корень сам в списке не появляется")
    KnowRoot(k, v); KnowRoot(o, v); KnowRoot(v, k)
    T.eq(#o.ns.Security.KnownGuilds(), 0, "офицеру список не показывается")
    T.no(o.ns.Security.AddKnown(v.guild), "офицер не добавляет известную гильдию")
    local known = k.ns.Security.KnownGuilds()
    T.eq(#known, 1)
    T.eq(known[1].guild, v.guild)
    T.eq(known[1].root, v:Name(), "показан корень гильдии")
    k.ns.UI.Toggle("union")
    local action
    for _, row in ipairs(k.ns.UnionPane.frames.rows) do
        if row:IsShown() and row.entry.known and row.entry.guild == v.guild then action = row.action end
    end
    T.ok(action, "известная гильдия показана на вкладке")
    action.scripts.OnClick()
    T.no(k.ns.Util.IsMemberGuild(v.guild), "первый щелчок только просит подтверждение")
    T.eq(action:GetText(), k.ns.L.UNION_CONFIRM_ADD)
    action.scripts.OnClick()
    T.ok(k.ns.Util.IsMemberGuild(v.guild), "второй щелчок добавляет")
    w:Run(30)
    T.ok(v.ns.IsMember(), "корень гильдии получил решение шёпотом")
    T.ok(o.ns.Util.IsMemberGuild(v.guild), "главная гильдия получила решение")
    T.eq(#k.ns.Security.KnownGuilds(), 0, "добавленная гильдия ушла из списка известных")
    T.no(k.ns.Security.AddKnown(v.guild), "повторно не добавляется")
    for _, c in ipairs({ k, o, v }) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end)

T.test("union: глава с одним аккаунтом подключает гильдию своего второго персонажа", function()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Северный союз")
    local alt = w:Client({ first = "Альт", surname = "Северный", guild = "Северный союз", rank = 0 })
    local member = w:Client({ first = "Рядовой", surname = "Северный", guild = "Северный союз", rank = 3 })
    w:Run(30)
    w:Init(alt)
    w:Run(15)
    local db = alt.ns.db
    alt:Logout()
    -- Тот же игрок входит главой «Чиллзон»: SavedVariables у персонажей аккаунта общие.
    local k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, db = db })
    w:Run(30)
    w:Init(k)
    w:Run(15)
    local known = k.ns.Security.KnownGuilds()
    T.eq(#known, 1, "корень гильдии второго персонажа уже известен аккаунту")
    T.eq(known[1].guild, "Северный союз")
    local whispers = CountContact(k)
    T.ok(k.ns.Security.AddKnown("Северный союз"))
    w:Run(25 * 60)
    T.eq(whispers.n, 0, "второму персонажу того же аккаунта решение не шепчется")
    T.no(member.ns.IsMember(), "пока второй персонаж не вошёл, гильдия решения не знает")
    k:Logout()
    local back = w:Client({ first = "Альт", surname = "Северный", guild = "Северный союз", rank = 0, db = db })
    w:Run(5)
    T.ok(back.ns.IsMember(), "подписанный состав уже в общем хранилище")
    w:Run(120)
    T.ok(member.ns.IsMember(), "второй персонаж раздал состав своей гильдии")
    for _, c in ipairs({ back, member }) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end)

T.test("union: представителю не в игре решение не шепчется каждые 10 минут", function()
    local w, k, _, v = Build()
    w:Pair(v, k)
    w:Run(60)
    T.ok(v.ns.IsMember())
    v:Logout()
    local whispers = CountContact(k)
    -- Следующая подпись — через AUTH_RENEW после прежней; шаг мелкий, чтобы застать ответ сервера.
    for _ = 1, 15 * 60 do
        if whispers.n > 0 then break end
        w:Run(1)
    end
    T.eq(whispers.n, 1, "переподписанное решение ушло представителю")
    w:Run(2)
    local hidden = false
    for _, fn in ipairs(k.filters["CHAT_MSG_SYSTEM"] or {}) do
        if fn(nil, "CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(v:Name())) then hidden = true end
    end
    T.ok(hidden, "строка «нет такого игрока» про контакт скрыта")
    w:Run(25 * 60)
    T.eq(whispers.n, 1, "после ответа «нет такого игрока» контакт пропускается")
    w:Run(20 * 60)
    T.eq(whispers.n, 2, "через полчаса глава пробует снова")
    T.eq(#k.ns.db.errors, 0)
end)
