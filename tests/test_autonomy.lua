-- Автономная связь: долго живут допуски издателей и решения, но не членство игроков.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build(officerRoot)
    local w = Wow.World()
    w:Guild("Чиллзон"); w:Guild("Северный союз")
    local k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0 })
    local o = w:Client({ first = "Офицер", surname = "Главный", guild = k.guild, rank = 1 })
    local v = w:Client({ first = "Вера", surname = "Верная", guild = "Северный союз", rank = 0 })
    local q = w:Client({ first = "Олег", surname = "Северный", guild = v.guild, rank = 1 })
    w:Run(30); w:Init(officerRoot and o or k, v); w:Run(45)
    w:Pair(v, k); w:Run(120)
    T.ok(q.ns.IsMember(), "решение дошло до запасного издателя")
    return w, k, o, v, q
end

local function Skip(w, days)
    for _, c in ipairs(w.clients) do
        c.clockSkew = (c.clockSkew or 0) + days * 86400
        c.ns.Roster.Scan()
    end
    w:Run(240)
end

local function Errors(w)
    for _, c in ipairs(w.clients) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end

T.test("autonomy: полгода без обоих корней, новые клиенты и перезаход офицера", function()
    local w, k, o, v, q = Build()
    k:Logout(); v:Logout()
    for _, c in ipairs({ k, v }) do w:AddOffline(c.guild, c:Name() .. "-" .. c.realm, c.rank) end
    Skip(w, 183)
    for _, c in ipairs({ o, q }) do
        local cert = c.ns.Security.MyCertificate()
        T.ok(cert, "офицер продлевает свой сертификат без корня")
        T.ok(cert.expires - cert.issued <= c.ns.Config.AUTH_TTL, "членство по-прежнему короткое")
        T.no(c.ns.Security.CanManageUnion(), "допуск издателя не даёт управления")
    end
    local a = w:Client({ first = "Новый", surname = "Главный", guild = o.guild, rank = 3, clockSkew = o.clockSkew })
    local b = w:Client({ first = "Новый", surname = "Северный", guild = q.guild, rank = 3, clockSkew = q.clockSkew })
    o.ns.Roster.Scan(); q.ns.Roster.Scan(); w:Run(180)
    T.ok(a.ns.Util.IsMemberGuild(q.guild), "новая установка получила долговременное решение главы")
    T.ok(b.ns.IsMember(), "новая установка подключённой гильдии получила состав")
    T.ok(a.ns.Security.MyCertificate(), "новичок главной гильдии получил короткое членство")
    T.ok(b.ns.Security.MyCertificate(), "новичок другой гильдии получил короткое членство")
    a:Slash("/cz1", "полгода без главы"); w:Run(60)
    T.eq(b:Saw("полгода без главы"), 1, "чат между новыми установками")
    local db, skew = o.ns.db, o.clockSkew
    o:Logout()
    o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, db = db, clockSkew = skew })
    w:Run(240)
    T.ok(o.ns.Security.MyCertificate(), "допуск восстановился с диска")
    b:Slash("/cz1", "после перезахода издателя"); w:Run(60)
    T.eq(a:Saw("после перезахода издателя"), 1, "связь после перезахода")
    Errors(w)
end)

T.test("autonomy: отзыв допуска не обходится старым KD или коротким делегированием", function()
    local w, k, o, v = Build()
    local grant = o.ns.Issuers.For(o.guild, o.ns.myKey)
    T.ok(grant, "долгосрочный допуск выдан")
    local saved = grant.raw
    T.ok(k.ns.Issuers.Revoke(o:Name()), "корень явно отзывает допуск")
    w:Run(30)
    T.eq(o.ns.Issuers.For(o.guild, o.ns.myKey), nil, "отзыв дошёл до издателя")
    o.ns.Comm.Dispatch("KD~" .. o.ns.Ed25519.ToB64(saved), k:Name(), "WHISPER")
    w:Run(10)
    T.eq(o.ns.Issuers.For(o.guild, o.ns.myKey), nil, "старый допуск не возвращается")
    k:Logout(); v:Logout(); Skip(w, 8)
    T.eq(o.ns.Security.MyCertificate(), nil, "запасной не обходит отзыв прежним недельным сертификатом")
    Errors(w)
end)

T.test("autonomy: обе гильдии восстанавливают связь после полугода полного офлайна", function()
    local w, k, o, v, q = Build()
    local odb, qdb = o.ns.db, q.ns.db
    for _, c in ipairs({ k, o, v, q }) do c:Logout() end
    for _, c in ipairs({ k, v }) do w:AddOffline(c.guild, c:Name() .. "-" .. c.realm, c.rank) end
    w:Run(183 * 86400)
    o = w:Client({ first = o.first, surname = o.surname, guild = o.guild, rank = 1, db = odb })
    q = w:Client({ first = q.first, surname = q.surname, guild = q.guild, rank = 1, db = qdb })
    w:Run(300)
    T.ok(o.ns.Security.MyCertificate(), "издатель восстановился без сохранённого короткого сертификата")
    T.ok(q.ns.Security.MyCertificate(), "издатель второй гильдии тоже восстановился")
    q:Slash("/cz1", "после полугода полного офлайна"); w:Run(60)
    T.eq(o:Saw("после полугода полного офлайна"), 1, "сохранённого доверия и адресов достаточно для связи")
    Errors(w)
end)

T.test("autonomy: допуск истекает, возвращение корня восстанавливает выдачу", function()
    local w, k, o, v = Build()
    local db = k.ns.db
    k:Logout(); v:Logout()
    w:AddOffline(k.guild, k:Name() .. "-" .. k.realm, k.rank)
    Skip(w, 367)
    T.eq(o.ns.Security.MyCertificate(), nil, "срок допуска ограничен")
    local returned = w:Client({ first = k.first, surname = k.surname, guild = k.guild, rank = 0,
        db = db, clockSkew = o.clockSkew })
    -- Вошедший персонаж заменяет офлайн-строку своего ростера, как в игре.
    for i, row in ipairs(w.guilds[k.guild].members) do
        if row.full then table.remove(w.guilds[k.guild].members, i); break end
    end
    w:Run(120)
    T.ok(o.ns.Security.MyCertificate(), "вернувшийся корень снова выдаёт короткие сертификаты")
    T.ok(returned.ns.Security.CanManageUnion(), "свой ключ управления сохранился")
    Errors(w)
end)

T.test("autonomy: смена личного ключа не обходит явный отзыв издателя", function()
    local w, k, o = Build()
    T.ok(k.ns.Issuers.Revoke(o:Name())); w:Run(20)
    local db = o.ns.db
    o:Logout(); db.securityKeys = nil
    local changed = w:Client({ first = o.first, surname = o.surname, guild = o.guild, rank = 1, db = db })
    k.ns.Roster.Scan(); w:Run(120)
    T.eq(changed.ns.Issuers.For(changed.guild, changed.ns.myKey), nil, "другой ключ не отменяет ручной отзыв")
    k:Slash("/chillzone", "trust issuer-grant " .. changed:Name()); w:Run(30)
    T.ok(changed.ns.Issuers.For(changed.guild, changed.ns.myKey), "только явное разрешение корня возвращает выдачу")
    Errors(w)
end)

T.test("autonomy: исключение сохраняется через полгода и передаётся новичку", function()
    local w, k, o, v, q = Build()
    local old = k.ns.store.security.policies[k.ns.Util.GuildKey(v.guild)].wire
    T.ok(k.ns.Security.RemoveGuild(v.guild)); w:Run(60)
    k:Logout(); v:Logout()
    w:AddOffline(k.guild, k:Name() .. "-" .. k.realm, k.rank)
    Skip(w, 183)
    local newcomer = w:Client({ first = "Новый", surname = "Читатель", guild = o.guild, rank = 3, clockSkew = o.clockSkew })
    o.ns.Roster.Scan(); w:Run(90)
    local entry = newcomer.ns.store.security.union[newcomer.ns.Util.GuildKey(q.guild)]
    T.ok(entry and not entry.active, "новичок получил подписанное исключение")
    newcomer.ns.Comm.Dispatch(old, o:Name(), "WHISPER"); w:Run(10)
    T.no(newcomer.ns.Util.IsMemberGuild(q.guild), "старое добавление не отменяет отзыв")
    Errors(w)
end)

local function Pack(tag, values)
    local parts = { tag .. ":" }
    for _, value in ipairs(values) do value = tostring(value); parts[#parts + 1] = #value .. ":" .. value end
    return table.concat(parts)
end

local function Seed(c)
    local _, key = next(c.ns.db.securityKeys)
    return c.ns.Ed25519.FromB64(key.seed)
end

T.test("autonomy: корневой офицер не подменяет ключ управления сертификатом главы", function()
    local w, k, o, v = Build(true)
    local Ed, cert, now = o.ns.Ed25519, o.ns.Security.MyCertificate(), o.ns.ServerTime()
    local body = Pack("CREDENTIAL", { o.ns.group, o.ns.faction, o.guild, o:Name(), cert.public,
        "leader", 0, now, now + 600, o:Name(), cert.public, "1", 1 })
    local fake = Pack("CERT", { body, Ed.ToB64(Ed.Sign(Seed(o), body)), "" })
    local decision = Pack("GUILDROOT", { o.ns.group, o.ns.faction, "Чиллзон Подделка", v:Name(),
        v.ns.Security.MyCertificate().public, now, now + 600, "1", 1 })
    v.ns.Comm.Dispatch("KA~" .. Ed.ToB64(fake) .. "~" .. Ed.ToB64(decision) .. "~" .. Ed.ToB64(Ed.Sign(Seed(o), decision)), o:Name(), "WHISPER")
    w:Run(5)
    T.no(v.ns.Util.IsMemberGuild("Чиллзон Подделка"), "доверенный издатель не меняет состав")
    T.ok(k.ns.Security.RemoveGuild(v.guild), "настоящий глава по-прежнему управляет")
    w:Run(60)
    T.no(v.ns.IsMember(), "отзыв настоящего главы принят")
    Errors(w)
end)

T.test("autonomy: ложная передача ключа от корневого офицера отклоняется", function()
    local w, _, o, v = Build(true)
    local A, Ed = v.ns.UnionAuthority, o.ns.Ed25519
    local owner = A.Current()
    T.ok(owner, "ключ главы уже закреплён")
    local body = Pack("UNIONOWNER", { o.ns.group, o.ns.faction, o:Name(), o.ns.Security.PublicKey(),
        owner.generation + 1, o.ns.ServerTime() })
    local raw = Pack("OWNER", { body, Ed.ToB64(Ed.Sign(Seed(o), body)), owner.raw })
    v.ns.Comm.Dispatch("UO~" .. Ed.ToB64(raw), o:Name(), "WHISPER")
    w:Run(10)
    T.eq(A.Current().public, owner.public, "право выдачи сертификатов не заменяет подпись прежнего главы")
    Errors(w)
end)

T.test("autonomy: смена доверия во время проверки решения отменяет результат", function()
    local w, k, _, v = Build()
    local Ed, real = v.ns.Ed25519, v.ns.Ed25519.Verify
    local owner, guild = v.ns.UnionAuthority.Current(), "Восточный союз"
    local body = Pack("UNIONDECISION", { k.ns.group, k.ns.faction, guild, v:Name(), v.ns.Security.PublicKey(),
        k.ns.ServerTime(), "1", 1, owner.generation })
    local wire = "KA~" .. owner.public .. "~" .. Ed.ToB64(body) .. "~" .. Ed.ToB64(Ed.Sign(Seed(k), body))
    local changed = false
    Ed.Verify = function(pk, message, signature)
        local valid = real(pk, message, signature)
        if valid and message == body then changed = v.ns.UnionAuthority.Reset() end
        return valid
    end
    v.ns.Comm.Dispatch(wire, k:Name(), "WHISPER"); w:Run(1)
    Ed.Verify = real
    T.ok(changed, "доверие сброшено после настоящей проверки Ed25519")
    T.no(v.ns.Util.IsMemberGuild(guild), "устаревший результат не меняет состав")
    Errors(w)
end)

T.test("autonomy: закрепление ключа отменяет уже запущенную проверку старого каталога", function()
    local w, k, _, v = Build()
    local Ed, real = v.ns.Ed25519, v.ns.Ed25519.Verify
    local owner, guild, now = v.ns.UnionAuthority.Current(), "Старый каталог", k.ns.ServerTime()
    v.ns.store.security.owner = nil -- состояние миграционного клиента до UO
    local body = Pack("GUILDROOT", { k.ns.group, k.ns.faction, guild, v:Name(), v.ns.Security.PublicKey(), now, now + 600, "1", 1 })
    local wire = "KA~" .. Ed.ToB64(k.ns.Security.MyCertificate().raw) .. "~" .. Ed.ToB64(body)
        .. "~" .. Ed.ToB64(Ed.Sign(Seed(k), body))
    local changed = false
    Ed.Verify = function(pk, message, signature)
        local valid = real(pk, message, signature)
        if valid and message == body then v.ns.store.security.owner = owner; changed = true end
        return valid
    end
    v.ns.Comm.Dispatch(wire, k:Name(), "WHISPER"); w:Run(1)
    Ed.Verify = real
    T.ok(changed, "ключ закреплён после криптографической проверки прежнего KA")
    T.no(v.ns.Util.IsMemberGuild(guild), "старый путь доверия уже закрыт")
    Errors(w)
end)
