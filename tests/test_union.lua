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

local function Sections(k)
    local out = {}
    for _, header in ipairs(k.ns.UnionPane.frames.headers) do
        if header:IsShown() then out[#out + 1] = header.title end
    end
    return out
end

T.test("union: на вкладке видны только непустые разделы", function()
    local w, k, _, v = Build()
    local L = k.ns.L
    k.ns.UI.Toggle("union")
    T.same(Sections(k), { L.UNION_SECTION_MEMBERS }, "пока есть только главная гильдия")
    T.ok(v.ns.Security.Link(k:Name()))
    w:Run(5)
    k.ns.UnionPane.Render()
    T.same(Sections(k), { L.UNION_SECTION_REQUESTS, L.UNION_SECTION_MEMBERS }, "пришёл запрос связи")
    T.ok(k.ns.Security.Accept(v:Name()))
    w:Run(45)
    k.ns.UnionPane.Render()
    T.same(Sections(k), { L.UNION_SECTION_MEMBERS }, "запрос принят")
    T.ok(k.ns.Security.RemoveGuild(v.guild))
    w:Run(40)
    k.ns.UnionPane.Render()
    T.same(Sections(k), { L.UNION_SECTION_MEMBERS, L.UNION_SECTION_KNOWN }, "исключённая гильдия стала известной")
    local headers, shown = k.ns.UnionPane.frames.headers, {}
    T.no(rawget(headers[1], "tip"), "у состава подсказки нет") -- заглушка кадра отвечает на любое поле
    k.env.GameTooltip = { SetOwner = function() end, Show = function() end, Hide = function() end,
        AddLine = function(_, text) shown[#shown + 1] = text end }
    headers[2].scripts.OnEnter(headers[2])
    T.same(shown, { L.UNION_KNOWN_TIP }, "подсказка объясняет раздел")
    T.eq(#k.ns.db.errors, 0)
end)

T.test("union: вкладка управления исчезает при передаче главы", function()
    local _, k, o, v = Build()
    k.ns.UI.Toggle("union")
    T.ok(k.ns.UI.tabs.union:IsShown())
    o.ns.UI.Toggle("union")
    v.ns.UI.Toggle("union")
    T.no(o.ns.UI.tabs.union:IsShown())
    T.ok(k.ns.UnionPane.frames.input:IsShown(), "главе доступно поле имени")
    T.no(v.ns.UnionPane.frames.input:IsShown(), "другой гильдии управление не показано")
    T.no(o.ns.UI.Current() == "union")
    k.rank, o.rank = 1, 0
    k.ns.Roster.Scan(); o.ns.Roster.Scan()
    k.ns.UI.Render(); o.ns.UI.Render()
    T.no(k.ns.UI.tabs.union:IsShown())
    T.ok(o.ns.UI.tabs.union:IsShown())
    T.no(k.ns.UI.Current() == "union")
end)

T.test("union: офицер гильдии вне объединения запрашивает связь с вкладки", function()
    local w, k, o, v = Build()
    local officer = w:Client({ first = "Мира", surname = "Северная", guild = "Северный союз", rank = 1 })
    local member = w:Client({ first = "Рядовой", surname = "Северный", guild = "Северный союз", rank = 3 })
    w:Run(30)
    local L, U = v.ns.L, v.ns.Util
    v.ns.Config.MAIN_GUILD_LEADER = k:Name()
    for _, c in ipairs({ o, v, officer, member }) do c.ns.UI.Toggle("union") end
    T.ok(v.ns.UI.tabs.union:IsShown(), "глава гильдии вне объединения")
    T.ok(officer.ns.UI.tabs.union:IsShown(), "её офицер")
    T.no(member.ns.UI.tabs.union:IsShown(), "рядовой")
    T.no(o.ns.UI.tabs.union:IsShown(), "офицер главной гильдии")
    T.eq(member.ns.UI.Current(), "join", "рядовому остаётся экран вступления")
    T.eq(v.ns.UI.Current(), "union", "экран вступления не перекрывает вкладку")
    local ui = v.ns.UnionPane.frames
    T.ok(ui.pane:IsShown())
    T.no(ui.input:IsShown(), "имя главы вводить не нужно")
    T.no(ui.connect:IsShown())
    T.same(Sections(v), { L.UNION_SECTION_CONNECT:format(v.guild) })
    T.eq(ui.rows[1].label:GetText(), L.UNION_ROOT:format(U.Display(v.ns.me)))
    T.no(ui.rows[1].action:IsShown(), "корень уже задан")
    local ask, target = ui.rows[2], U.TellName(k:Name())
    T.eq(ask.label:GetText(), L.UNION_LEADER:format(U.Display(target)))
    T.eq(ask.action:GetText(), L.UNION_CONNECT)
    T.eq(ask.action.enabled, true)
    ask.action.scripts.OnClick()
    w:Run(5)
    T.eq(ask.label:GetText(), L.UNION_LEADER_WAITING:format(U.Display(target)))
    T.eq(ask.action.enabled, false, "пока ждём ответа, второй запрос не отправить")
    T.eq(ui.message:GetText(), L.AUTH_SENT:format(target))
    T.eq(#k.ns.Security.UnionRequests(), 1, "заявка дошла до главы")
    T.ok(k.ns.Security.Accept(v:Name()))
    w:Run(60)
    T.ok(v.ns.IsMember(), "гильдия подключена")
    T.no(v.ns.UI.tabs.union:IsShown(), "подключённой гильдии запрашивать нечего")
    T.no(v.ns.UI.Current() == "union")
    T.no(ui.pane:IsShown())
    T.eq(#v.ns.db.errors, 0)
end)

T.test("union: офицер задаёт корень с вкладки и только потом запрашивает связь", function()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Северный союз")
    w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0 })
    local v = w:Client({ first = "Вера", surname = "Верная", guild = "Северный союз", rank = 1 })
    w:Run(30)
    local L, U = v.ns.L, v.ns.Util
    v.ns.UI.Toggle("union")
    local ui = v.ns.UnionPane.frames
    T.eq(ui.rows[1].label:GetText(), L.UNION_NO_ROOT)
    T.eq(ui.rows[1].action:GetText(), L.UNION_INIT)
    T.eq(ui.rows[2].label:GetText(), L.UNION_LEADER:format("Вован Дубан"), "адрес записан в настройках")
    T.eq(ui.rows[2].action.enabled, false, "без корня запрос не отправить")
    ui.rows[1].action.scripts.OnClick()
    w:Run(12)
    T.eq(ui.rows[1].label:GetText(), L.UNION_ROOT:format(U.Display(v.ns.me)))
    T.no(ui.rows[1].action:IsShown(), "кнопка больше не нужна")
    T.eq(ui.message:GetText(), L.UNION_INIT_OK, "дальше кнопка, а не команда")
    for _, key in ipairs({ "UNION_INIT_OK", "AUTH_INIT_ASK", "AUTH_INIT_WAIT", "AUTH_INIT_DONE", "AUTH_CERT_WAIT",
        "AUTH_CERT_PENDING", "AUTH_ROOT_KEY_CHANGED" }) do
        T.no(L[key]:find("/chillzone", 1, true), key .. ": кнопка не отсылает к команде")
    end
    T.eq(ui.rows[2].action.enabled, true)
    T.eq(#v.ns.db.errors, 0)
end)

T.test("union: итог запроса связи виден на вкладке офицера", function()
    local w, k, _, v = Build()
    local L, U = v.ns.L, v.ns.Util
    v.ns.Config.MAIN_GUILD_LEADER = v:Name()
    v.ns.UI.Toggle("union")
    local ui = v.ns.UnionPane.frames
    local ask = ui.rows[2]
    ask.action.scripts.OnClick()
    T.eq(ui.message:GetText(), L.AUTH_LINK_NAME, "отказ объяснён на вкладке")
    v.ns.Config.MAIN_GUILD_LEADER = k:Name()
    v.ns.UnionPane.Render()
    ask.action.scripts.OnClick()
    w:Run(200)
    T.eq(ui.message:GetText(), L.AUTH_LINK_EXPIRED:format(U.TellName(k:Name())), "глава не ответил")
    T.eq(ask.label:GetText(), L.UNION_LEADER:format(U.Display(k:Name())), "запрос больше не ждёт ответа")
    T.eq(ask.action.enabled, true, "запрос можно повторить")
    T.eq(#v.ns.db.errors, 0)
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
    math.randomseed(14)
    local w, k, _, v = Build()
    -- Без переписи от гильдии мост не опрашивает контакт. Здесь недоступность
    -- должна обнаружиться именно на отправке подписанного решения главы.
    local getRow = k.ns.Data.Row
    k.ns.Data.Row = function(guild)
        if guild ~= v.guild then return getRow(guild) end
    end
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

T.test("union: каталоги KA из 0.8 удаляются при входе и не рассылаются", function()
    local w, k, o, v = Build()
    w:Pair(v, k)
    w:Run(60)
    local U = o.ns.Util
    local gk, old = U.GuildKey(v.guild), U.GuildKey("Старая гильдия")
    T.ok(o.ns.store.security.policies[gk], "действующий каталог у офицера")
    -- Запись 0.8: те же поля, но без ревизии; сам каталог в 7 полей новые клиенты не примут.
    local legacy = "KA~c3RhcnlpLXNlcnQ~c3RhcnlqLWthdGFsb2c~c3RhcmF5YS1wb2RwaXM"
    local now = o.ns.ServerTime()
    o.ns.store.security.policies[old] = { wire = legacy, issued = now - 60, expires = now + 3 * 86400, guild = "Старая гильдия" }
    local db = o.ns.db
    o:Logout()
    local back = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, db = db })
    w:Run(1)
    local policies = back.ns.store.security.policies
    T.eq(policies[old], nil, "каталог 0.8 удалён при входе")
    T.ok(policies[gk], "каталог с ревизией сохранился")
    back.ns.Security.SendPolicies(v:Name())
    back.ns.Security.ShareTrust()
    w:Run(10)
    local sent = 0
    for _, e in ipairs(w.log) do if e.msg:find(legacy, 1, true) then sent = sent + 1 end end
    T.eq(sent, 0, "каталог 0.8 никому не ушёл")
    T.eq(#back.ns.db.errors, 0)
end)

T.test("union: игрок неподключённой гильдии видит, почему ему предложено вступить", function()
    local w, k, _, v = Build()
    local loner = w:Client({ first = "Одинокий", surname = "Странник" })
    w:Run(5)
    local L = v.ns.L
    v:Slash("/chillzone")
    T.eq(v.ns.UI.Current(), "join")
    T.eq(v.ns.RecruitPane.frames.intro:GetText(), L.RECRUIT_UNCONNECTED:format(v.guild), "своя гильдия названа")
    loner:Slash("/chillzone")
    T.eq(loner.ns.UI.Current(), "join")
    T.eq(loner.ns.RecruitPane.frames.intro:GetText(), L.RECRUIT_INTRO, "без гильдии — обычное вступление")
    w:Pair(v, k)
    w:Run(60)
    v.ns.UI.Render()
    T.no(v.ns.UI.Current() == "join", "после подключения экрана вступления нет")
    for _, c in ipairs({ v, loner }) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end)

-- Системные строки, которые увидел игрок: событие прошло через фильтры чата.
local function Shown(client)
    local box = { n = 0 }
    local fire = client.Fire
    client.Fire = function(self, event, text, ...)
        local result = fire(self, event, text, ...)
        if event == "CHAT_MSG_SYSTEM" then
            local hidden = false
            for _, fn in ipairs(self.filters["CHAT_MSG_SYSTEM"] or {}) do
                if fn(nil, "CHAT_MSG_SYSTEM", text) then hidden = true end
            end
            if not hidden then box.n = box.n + 1 end
        end
        return result
    end
    return box
end

T.test("union: офицер не подкладывает корень посторонней гильдии", function()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Северный союз")
    w:Guild("Новая гильдия")
    local k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0 })
    local o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1 })
    local v = w:Client({ first = "Вера", surname = "Верная", guild = "Северный союз", rank = 0 })
    local vo = w:Client({ first = "Ваня", surname = "Офицер", guild = "Северный союз", rank = 1 })
    local vm = w:Client({ first = "Варя", surname = "Рядовая", guild = "Северный союз", rank = 3 })
    local n = w:Client({ first = "Нина", surname = "Новая", guild = "Новая гильдия", rank = 0 })
    w:Run(30)
    w:Init(k, v, n)
    w:Pair(v, k)
    w:Run(90)
    T.ok(vm.ns.IsMember())
    local U, gk = k.ns.Util, k.ns.Util.GuildKey("Новая гильдия")
    -- Офицеры шлют своим гильдиям корень гильдии, которой нет в объединении.
    local fake = vm.ns.store.security.roots[U.GuildKey("Северный союз")].public
    o.ns.Comm.Send("GUILD", "KT~Новая гильдия~" .. o:Name() .. "~" .. fake)
    vo.ns.Comm.Send("GUILD", "KT~Новая гильдия~" .. vo:Name() .. "~" .. fake)
    w:Run(5)
    T.eq(k.ns.store.security.roots[gk], nil, "у главы корень не записан")
    T.eq(#k.ns.Security.KnownGuilds(), 0, "и не появился среди известных")
    T.eq(vm.ns.store.security.roots[gk], nil, "у участника другой гильдии тоже")
    w:Pair(n, k)
    w:Run(90)
    for _, c in ipairs({ k, o, vm }) do
        T.ok(c.ns.Util.IsMemberGuild("Новая гильдия"), c:Name() .. ": настоящая гильдия подключена")
        T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок")
    end
end)

T.test("union: второй персонаж главы не шепчет главе, пока его гильдию не добавили", function()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Северный союз")
    local alt = w:Client({ first = "Альт", surname = "Северный", guild = "Северный союз", rank = 0 })
    w:Run(30)
    w:Init(alt)
    w:Run(15)
    local db = alt.ns.db
    alt:Logout()
    local k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, db = db })
    w:Run(30)
    w:Init(k)
    w:Run(15)
    k:Logout()
    local back = w:Client({ first = "Альт", surname = "Северный", guild = "Северный союз", rank = 0, db = db })
    local shown, from = Shown(back), #w.log
    w:Run(20 * 60)
    local whispers = 0
    for i = from + 1, #w.log do
        if w.log[i].from == back:Name() and w.log[i].target == k:Name() then whispers = whispers + 1 end
    end
    T.no(back.ns.IsMember(), "гильдия ещё не добавлена")
    T.eq(whispers, 0, "главе на том же аккаунте не шепчем")
    T.eq(shown.n, 0, "строк «нет такого игрока» нет")
    T.eq(#back.ns.db.errors, 0)
end)
