-- Миграция: настоящий старый Security.lua продолжает работать с обновлёнными клиентами.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
    math.randomseed(37)
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Чиллзон Север")
    local c = {}
    c.k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, legacy = true })
    c.o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, legacy = true })
    c.v = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, legacy = true })
    c.b = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3, legacy = true })
    w:Run(30)
    w:Init(c.k, c.v)
    w:Pair(c.v, c.k)
    w:Run(180)
    return w, c
end
local function Upgrade(w, old)
    local db = old.ns.db
    old:Logout()
    local c = w:Client({ first = old.first, surname = old.surname, guild = old.guild, rank = old.rank, db = db })
    for _, other in ipairs(w.clients) do if other.online and other.ns then other.ns.Roster.Scan() end end
    w:Run(1) -- восстановление открытого ключа выполняется асинхронно
    return c
end
local function Errors(c)
    for _, client in pairs(c) do
        T.eq(#client.ns.db.errors, 0, client:Name() .. ": ошибки")
        T.eq(#client:Leaks(), 0, client:Name() .. ": глобалы")
    end
end

-- Север на 0.9, обновились только upgrade. Глава Севера, он же репортёр, выходит из игры:
-- как на сервере, строка ростера остаётся, но уже вне игры.
local function ReporterQuits(upgrade)
    local w, c = Build()
    c.y = w:Client({ first = "Яна", surname = "Ясная", guild = "Чиллзон Север", rank = 3, legacy = true })
    w:Run(240)
    for _, name in ipairs(upgrade) do c[name] = Upgrade(w, c[name]) end
    w:Run(200)
    T.eq(c.y.ns.Census.Reporter(), c.y.ns.Util.Key("Вера Верная"), "до выхода репортёр — Вера")
    local gone = c.v
    c.v = nil
    gone:Logout()
    w:AddOffline(gone.guild, gone:Name() .. "-" .. gone.realm, gone.rank, gone.level, gone.class, 0)
    return w, c
end

T.test("migration: участник обновляется до главы и сохраняет чат со старой версией", function()
    local w, c = Build()
    c.b = Upgrade(w, c.b)
    T.ok(c.b.ns.IsMember(), "существующая гильдия остаётся в объединении сразу после обновления")
    T.ok(c.b.ns.Security.MyCertificate(), "сохранились личный ключ и сертификат")
    w:Run(45)
    c.b:Slash("/cz1", "новый клиент пишет старому")
    w:Run(40)
    T.eq(c.k:Saw("новый клиент пишет старому"), 1, "старая версия получила подписанную строку новой")
    c.k:Slash("/cz1", "старый клиент пишет новому")
    w:Run(40)
    T.eq(c.b:Saw("старый клиент пишет новому"), 1, "новая версия получила подписанную строку старой")
    Errors(c)
end)

T.test("migration: обновлённый преемник вышедшего репортёра работает раньше старых клиентов", function()
    local w, c = ReporterQuits({ "b" })
    local config = c.b.ns.Config
    local boris = c.b.ns.Util.Key("Борис Быстрый")
    w:Run(config.SCAN_EVERY + 45)
    T.ok(c.b.ns.Census.IsReporter(), "Борис стал репортёром раньше конца окна приветов")
    c.k:Slash("/cz1", "строка до конца окна")
    w:Run(20)
    T.eq(c.k.ns.Relay.Reporters()[c.k.ns.Util.GuildKey("Чиллзон Север")].key, boris, "реле 0.9 отдало аренду Борису")
    -- Пока жила аренда Веры, реле 0.9 отказывало, но отвечало: он не считает реле недоступным.
    for _, e in pairs(c.b.ns.Relay.Known()) do T.ok(not e.down, e.name .. ": реле доступно") end
    T.eq(c.b:Saw("строка до конца окна"), 1, "новый клиент уже получает строки")
    T.eq(c.y:Saw("строка до конца окна"), 0, "старая Яна до конца окна отклоняет RG, как и раньше")
    w:Run(config.PEER_WINDOW)
    c.k:Slash("/cz1", "строка после окна")
    w:Run(20)
    T.eq(c.b:Saw("строка после окна"), 1, "Борис видит строку один раз")
    T.eq(c.y:Saw("строка после окна"), 1, "после окна старая Яна принимает нового репортёра")
    Errors(c)
end)

T.test("migration: обновлённый рядовой дожидается старого преемника вышедшего репортёра", function()
    local w, c = ReporterQuits({ "y" })
    local config = c.y.ns.Config
    w:Run(config.SCAN_EVERY + 45)
    T.eq(c.y.ns.Census.Reporter(), c.y.ns.Util.Key("Борис Быстрый"), "новая Яна уже выбрала Бориса")
    T.no(c.b.ns.Census.IsReporter(), "старый Борис до конца окна приветов не работает")
    w:Run(config.PEER_WINDOW)
    T.ok(c.b.ns.Census.IsReporter(), "после окна работает и старый клиент")
    c.k:Slash("/cz1", "строка через старого преемника")
    w:Run(20)
    T.eq(c.b:Saw("строка через старого преемника"), 1, "Борис видит строку один раз")
    T.eq(c.y:Saw("строка через старого преемника"), 1, "новая Яна принимает старого репортёра")
    Errors(c)
end)

T.test("migration: глава обновляется последним, состав подписывается автоматически", function()
    local w, c = Build()
    c.b, c.v, c.o = Upgrade(w, c.b), Upgrade(w, c.v), Upgrade(w, c.o)
    w:Run(60)
    T.ok(c.b.ns.IsMember())
    c.k = Upgrade(w, c.k)
    w:Run(90)
    for _, client in pairs(c) do
        T.ok(client.ns.Util.IsMemberGuild("Чиллзон Север"), client:Name() .. ": прежняя гильдия сохранена")
        local entry = client.ns.store.security.union[client.ns.Util.GuildKey("Чиллзон Север")]
        T.ok(entry and entry.active and not entry.legacy, "получено решение главы")
    end
    T.ok(c.k.ns.store.security.governed, "управление активировано подписью настоящего главы")
    c.b:Slash("/cz1", "после автоматического перехода")
    w:Run(40)
    T.eq(c.k:Saw("после автоматического перехода"), 1)
    Errors(c)
end)

T.test("migration: новый клиент получает старое доверие от прежней версии до обновления главы", function()
    local w, c = Build()
    c.n = w:Client({ first = "Новый", surname = "Северный", guild = "Чиллзон Север", rank = 3 })
    c.v.ns.Roster.Scan()
    w:Run(150)
    T.ok(c.n.ns.IsMember(), "старый офицер передал уже действующее доверие")
    T.ok(c.n.ns.Security.MyCertificate())
    c.n:Slash("/cz1", "новичок при старом главе")
    w:Run(50)
    T.eq(c.k:Saw("новичок при старом главе"), 1)
    Errors(c)
end)

T.test("migration: повтор прежнего каталога не расходится по гильдии снова", function()
    local w, c = Build()
    c.b = Upgrade(w, c.b)
    w:Run(45)
    local gk = c.k.ns.Util.GuildKey(c.v.guild)
    local function Spread()
        local n = 0
        for _, e in ipairs(w.log) do
            if e.from == c.b:Name() and e.dist == "GUILD"
                and (e.msg:find("^KA~") or e.msg:find("^C[^:]*:1:%d+:KA~")) then n = n + 1 end
        end
        return n
    end
    local unions = 0
    c.b.ns.On("UNION", function() unions = unions + 1 end)
    local wire = c.k.ns.store.security.policies[gk].wire
    c.o.ns.Comm.Send("WHISPER", wire, { target = c.b:Name() })
    w:Run(15)
    local spread, fired = Spread(), unions
    for _ = 1, 3 do
        c.o.ns.Comm.Send("WHISPER", wire, { target = c.b:Name() })
        w:Run(15)
    end
    T.eq(Spread(), spread, "тот же каталог гильдии повторно не рассылается")
    T.eq(unions, fired, "и не считается изменением состава")
    T.ok(c.b.ns.IsMember(), "членство на месте")
    Errors(c)
end)

-- Считает приветы, которые дошли бы до гильдии: клиент уже в объединении.
local function CountHellos(client)
    local box, census, send = { n = 0 }, client.ns.Census, client.ns.Census.SendHello
    census.SendHello = function(...)
        if client.ns.IsMember() then box.n = box.n + 1 end
        return send(...)
    end
    return box
end

T.test("migration: привет H1 уходит при входе в состав, а не на каждое продление", function()
    local w, c = Build()
    c.n = w:Client({ first = "Новый", surname = "Северный", guild = c.v.guild, rank = 3 })
    local hellos = CountHellos(c.n)
    c.v.ns.Roster.Scan()
    for _ = 1, 150 do
        w:Run(1)
        if c.n.ns.IsMember() then break end
    end
    T.ok(c.n.ns.IsMember(), "состав получен")
    T.ok(hellos.n >= 1, "вошёл в состав — сразу объявил себя")
    w:Run(1)
    local before = hellos.n
    for _ = 1, 3 do c.n.ns.Fire("UNION") end
    T.eq(hellos.n, before, "продление решения ничего не меняет")
    Errors(c)
end)

T.test("migration: корни и прежняя версия от офицера не заменяют подписанный каталог", function()
    local w, c = Build()
    c.k:Logout(); c.o:Logout()
    c.n = w:Client({ first = "Новый", surname = "Северный", guild = c.v.guild, rank = 3 })
    c.v.ns.Roster.Scan()
    w:Run(150)
    T.ok(c.n.ns.Security.Roots()[c.n.ns.Util.GuildKey(c.v.guild)], "настоящий офицер передал корень")
    T.ok(c.n.ns.Security.MyCertificate(), "личный сертификат выдан независимо от членства")
    T.no(c.n.ns.IsMember(), "членство ждёт подписи главной гильдии")
    -- Тот же офицер может переслать проверенный каталог главной гильдии, но не заменить его KT.
    c.v.ns.Security.SendPolicies(c.n:Name())
    w:Run(25)
    T.ok(c.n.ns.IsMember(), "получен настоящий подписанный каталог прежней версии")
    Errors(c)
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

T.test("migration: главного корня нет в игре — связь пробуем раз в полчаса и молча", function()
    local w, c = Build()
    c.k:Logout(); c.o:Logout()
    c.n = w:Client({ first = "Новый", surname = "Северный", guild = c.v.guild, rank = 3 })
    local shown = Shown(c.n)
    c.v.ns.Roster.Scan()
    w:Run(150)
    T.ok(c.n.ns.Security.MyCertificate())
    T.no(c.n.ns.IsMember(), "каталога ещё нет")
    local function Probes()
        local n = 0
        for _, e in ipairs(w.log) do
            -- Первая ошибка после KP отменяет и оставшиеся куски, и следующий RP.
            -- Считаем все шёпоты, чтобы лишние пакеты тоже нарушали ограничение.
            if e.from == c.n:Name() and e.target == c.k:Name() then n = n + 1 end
        end
        return n
    end
    T.eq(Probes(), 1, "главному корню отправлен только первый пакет")
    w:Run(25 * 60)
    T.eq(Probes(), 1, "после «нет такого игрока» не чаще раза в полчаса")
    w:Run(10 * 60)
    T.eq(Probes(), 2, "через полчаса — снова")
    T.eq(shown.n, 0, "строки «нет такого игрока» скрыты")
    Errors(c)
end)

T.test("migration: старый офицер и каталог не отменяют исключение главы после перезапуска", function()
    local w, c = Build()
    local gk = c.k.ns.Util.GuildKey(c.v.guild)
    local old = c.k.ns.store.security.policies[gk].wire
    c.b, c.v, c.k = Upgrade(w, c.b), Upgrade(w, c.v), Upgrade(w, c.k)
    w:Run(90)
    T.ok(c.k.ns.Security.RemoveGuild(c.v.guild))
    w:Run(55)
    c.b = Upgrade(w, c.b)
    for _, target in ipairs({ c.k, c.v, c.b }) do
        c.o.ns.Comm.Send("WHISPER", old, { target = target:Name() })
    end
    -- Офицер прежней версии продолжает раздавать прежние KT по GUILD.
    w:Run(120)
    for _, target in ipairs({ c.k, c.v, c.b }) do
        T.ok(target.ns.store.security.governed)
        T.no(target.ns.Util.IsMemberGuild(c.v.guild), "старое доверие не отменяет исключение")
    end
    Errors(c)
end)

local function Pack(tag, values)
    local parts = { tag .. ":" }
    for _, value in ipairs(values) do
        value = tostring(value)
        parts[#parts + 1] = #value .. ":" .. value
    end
    return table.concat(parts)
end

T.test("migration: изменённый аддон участника не выдаёт себя за главу", function()
    local w, c = Build()
    c.b, c.k = Upgrade(w, c.b), Upgrade(w, c.k)
    c.e = w:Client({ first = "Мнимый", surname = "Король", guild = "Чиллзон", rank = 3 })
    c.k.ns.Roster.Scan(); c.o.ns.Roster.Scan()
    w:Run(90)
    local evil, Ed = c.e.ns, c.e.ns.Ed25519
    local mine = evil.Security.MyCertificate()
    T.ok(mine and mine.role == "member")
    local saved = evil.db.securityKeys[evil.group .. ":" .. evil.faction .. ":" .. evil.myKey]
    local seed, now = Ed.FromB64(saved.seed), evil.ServerTime()
    local body = Pack("GUILDROOT", { evil.group, evil.faction, "Чиллзон Подделка",
        c.e:Name(), mine.public, now, now + 600, "1", 1 })
    -- Локальный интерфейс можно разблокировать. Подписанный сертификат от этого не меняется.
    evil.Security.CanManageUnion = function() return true end
    local root = evil.Security.Roots()[evil.Util.GuildKey("Чиллзон")]
    local fakeBody = Pack("CREDENTIAL", { evil.group, evil.faction, "Чиллзон", c.e:Name(),
        mine.public, "leader", 0, now, now + 600, root.name, root.public, "0", "1" })
    local fakeCert = Pack("CERT", { fakeBody, Ed.ToB64(Ed.Sign(seed, fakeBody)), "" })
    for _, certificate in ipairs({ mine.raw, fakeCert }) do
        local wire = "KA~" .. Ed.ToB64(certificate) .. "~" .. Ed.ToB64(body) .. "~" .. Ed.ToB64(Ed.Sign(seed, body))
        for _, target in ipairs({ c.k, c.b }) do
            evil.Comm.Send("WHISPER", wire, { target = target:Name() })
        end
    end
    evil.Comm.Send("GUILD", "KT~Чиллзон Подделка~" .. c.e:Name() .. "~" .. mine.public)
    w:Run(50)
    for _, target in ipairs({ c.k, c.b }) do
        T.no(target.ns.Util.IsMemberGuild("Чиллзон Подделка"), "самоподписанные права отвергнуты получателем")
    end
    Errors(c)
end)

T.test("migration: решение главы принимается только на новом префиксе", function()
    local w, c = Build()
    c.b, c.k = Upgrade(w, c.b), Upgrade(w, c.k)
    w:Run(90)
    local ns, guild = c.k.ns, "Чиллзон Запад"
    local Ed, mine = ns.Ed25519, ns.Security.MyCertificate()
    local saved = ns.db.securityKeys[ns.group .. ":" .. ns.faction .. ":" .. ns.myKey]
    local root, now = ns.Security.Roots()[ns.Util.GuildKey(c.v.guild)], ns.ServerTime()
    local body = Pack("GUILDROOT", { ns.group, ns.faction, guild,
        root.name, root.public, now, now + 600, "1", 1 })
    local wire = "KA~" .. Ed.ToB64(mine.raw) .. "~" .. Ed.ToB64(body)
        .. "~" .. Ed.ToB64(Ed.Sign(Ed.FromB64(saved.seed), body))
    ns.Comm.Send("WHISPER", wire, { target = c.b:Name(), prefix = ns.Config.PREFIX })
    w:Run(20)
    T.no(c.b.ns.Util.IsMemberGuild(guild), "девять полей не принимаются на прежнем префиксе")
    ns.Comm.Send("WHISPER", wire, { target = c.b:Name() })
    w:Run(20)
    T.ok(c.b.ns.Util.IsMemberGuild(guild), "та же подпись принимается на префиксе решений главы")
    Errors(c)
end)
