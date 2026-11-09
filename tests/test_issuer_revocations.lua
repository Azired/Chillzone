-- Глава своей гильдии отзывает делегирование без входа корневого персонажа.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
    math.randomseed(73)
    local w = Wow.World()
    for _, guild in ipairs({ "Чиллзон", "Северный союз", "Южный союз" }) do w:Guild(guild) end
    local k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0 })
    local p = w:Client({ first = "Корень", surname = "Северный", guild = "Северный союз", rank = 1 })
    local v = w:Client({ first = "Вера", surname = "Верная", guild = p.guild, rank = 0 })
    local o = w:Client({ first = "Олег", surname = "Северный", guild = p.guild, rank = 1 })
    local b = w:Client({ first = "Борис", surname = "Северный", guild = p.guild, rank = 3 })
    local q = w:Client({ first = "Юлия", surname = "Южная", guild = "Южный союз", rank = 0 })
    w:Run(30); w:Init(k, p, q); w:Run(60)
    w:Pair(v, k); w:Pair(q, k); w:Run(240)
    T.ok(o.ns.Issuers.For(o.guild, o.ns.myKey), "допуск запасного выдан")
    p:Logout(); w:AddOffline(p.guild, p:Name() .. "-" .. p.realm, p.rank)
    return w, k, p, v, o, b, q
end

local function Demote(w, o)
    o.rank = 3
    for _, c in ipairs(w.clients) do c.ns.Roster.Scan() end
end

local function Errors(w)
    for _, c in ipairs(w.clients) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end

T.test("issuer-revoke: глава автоматически отзывает допуск, отзыв доходит до третьей гильдии", function()
    local w, k, _, v, o, _, q = Build()
    local raw = o.ns.Issuers.For(o.guild, o.ns.myKey).raw
    Demote(w, o); w:Run(120)
    for _, c in ipairs({ k, v, q }) do
        T.eq(c.ns.Issuers.Current(raw), nil, c:Name() .. ": старый допуск отозван")
        local list = c.ns.store.security.issuerRevocations
        T.ok(list and list[c.ns.Util.GuildKey(o.guild)] and list[c.ns.Util.GuildKey(o.guild)][o.ns.myKey],
            "подписанный отзыв сохранён")
        c.ns.Comm.Dispatch("KD~" .. c.ns.Ed25519.ToB64(raw), o:Name(), "WHISPER")
    end
    w:Run(10)
    T.eq(k.ns.Issuers.Current(raw), nil, "повтор KD не возвращает право выдачи")
    T.ok(v.ns.Security.MyCertificate(), "глава сохраняет своё членство и выдачу")
    T.no(v.ns.Security.CanManageUnion(), "отзыв своей гильдии не даёт управления объединением")
    T.ok(k.ns.Util.IsMemberGuild(v.guild), "состав объединения сохранён")
    Errors(w)
end)

local function Pack(tag, values)
    local out = { tag .. ":" }
    for _, value in ipairs(values) do value = tostring(value); out[#out + 1] = #value .. ":" .. value end
    return table.concat(out)
end
local function Seed(c)
    local _, key = next(c.ns.db.securityKeys)
    return c.ns.Ed25519.FromB64(key.seed)
end
local function Forge(signer, grant, credential, issued)
    local body = Pack("ISSUERREVOKE", { signer.ns.group, signer.ns.faction, grant.guild,
        grant.name, grant.public, grant.revision, grant.issued, issued or signer.ns.ServerTime(), "0" })
    local Ed = signer.ns.Ed25519
    local leader = signer.ns.Issuers.For(signer.guild, signer.ns.myKey) or grant
    return "KV~" .. Ed.ToB64(Pack("REVOKE", { body, grant.raw, leader.raw, credential.raw, Ed.ToB64(Ed.Sign(Seed(signer), body)) }))
end

T.test("issuer-revoke: офицер и глава чужой гильдии не подписывают отзыв", function()
    local w, k, _, v, o, _, q = Build()
    local grant = o.ns.Issuers.For(o.guild, o.ns.myKey)
    for _, signer in ipairs({ o, k, q }) do
        local wire = Forge(signer, grant, signer.ns.Security.MyCertificate())
        k.ns.Comm.Dispatch(wire, signer:Name(), "WHISPER")
        v.ns.Comm.Dispatch(wire, signer:Name(), "WHISPER")
    end
    w:Run(15)
    T.ok(k.ns.Issuers.Current(grant.raw), "чужое или офицерское решение отклонено")
    T.ok(v.ns.Issuers.Current(grant.raw), "настоящий офицер остался издателем")
    Errors(w)
end)

T.test("issuer-revoke: офицер не получает право отзыва через поддельный сертификат главы", function()
    local w, k, _, v, o = Build()
    local grant, now, Ed = o.ns.Issuers.For(o.guild, o.ns.myKey), o.ns.ServerTime(), o.ns.Ed25519
    local body = Pack("CREDENTIAL", { o.ns.group, o.ns.faction, o.guild, o:Name(), o.ns.Security.PublicKey(),
        "leader", 0, now, now + 600, o:Name(), o.ns.Security.PublicKey(), "0", 1 })
    local fake = { raw = Pack("CERT", { body, Ed.ToB64(Ed.Sign(Seed(o), body)), grant.raw }) }
    local target = v.ns.Issuers.For(v.guild, v.ns.myKey)
    k.ns.Comm.Dispatch(Forge(o, target, fake), o:Name(), "WHISPER"); w:Run(10)
    T.ok(k.ns.Issuers.Current(target.raw), "обычный корневой допуск не содержит права отзыва главы")
    Errors(w)
end)

T.test("issuer-revoke: сохранённый дочерний сертификат перестаёт работать после отзыва", function()
    local w, k, _, _, o, b = Build()
    local grant, Ed, now = o.ns.Issuers.For(o.guild, o.ns.myKey), o.ns.Ed25519, o.ns.ServerTime()
    local body = Pack("CREDENTIAL", { o.ns.group, o.ns.faction, o.guild, b:Name(), b.ns.Security.PublicKey(),
        "member", 3, now, now + 600, o:Name(), o.ns.Security.PublicKey(), "0", 1 })
    local raw = Pack("CERT", { body, Ed.ToB64(Ed.Sign(Seed(o), body)), grant.raw })
    local accepted = false
    k.ns.Security.CheckCertificate(raw, b:Name(), function() accepted = true end); w:Run(2)
    T.ok(accepted, "настоящий допуск действительно разрешал выдачу")
    Demote(w, o); w:Run(90)
    accepted = false
    k.ns.Security.CheckCertificate(raw, b:Name(), function() accepted = true end); w:Run(2)
    T.no(accepted, "отзыв отменяет и ранее проверенный дочерний сертификат")
    Errors(w)
end)

T.test("issuer-revoke: возвращение корня и новое назначение не отменяются старым отзывом", function()
    local w, k, p, v, o = Build()
    Demote(w, o); w:Run(90)
    local rev = v.ns.store.security.issuerRevocations[v.ns.Util.GuildKey(o.guild)][o.ns.myKey]
    T.ok(rev, "первоначальное разжалование подписано")
    o.rank = 1
    for i, row in ipairs(w.guilds[p.guild].members) do
        if row.full then table.remove(w.guilds[p.guild].members, i); break end
    end
    p = w:Client({ first = p.first, surname = p.surname, guild = p.guild, rank = p.rank, db = p.ns.db })
    for _, c in ipairs(w.clients) do c.ns.Roster.Scan() end
    w:Run(120)
    local grant = o.ns.Issuers.For(o.guild, o.ns.myKey)
    T.ok(grant and grant.revision > rev.revision, "корень выдал новый допуск после реального повышения")
    k.ns.Comm.Dispatch("KD~" .. k.ns.Ed25519.ToB64(grant.raw), p:Name(), "WHISPER"); w:Run(5)
    k.ns.Comm.Dispatch(rev.wire, o:Name(), "WHISPER"); w:Run(5)
    T.ok(k.ns.Issuers.Current(grant.raw), "архивный отзыв касается прежней ревизии")
    Errors(w)
end)

T.test("issuer-revoke: потеря звания главы во время подписи отменяет отзыв", function()
    local w, k, _, v, o, b = Build()
    local Ed, sign = v.ns.Ed25519, v.ns.Ed25519.Sign
    local changed = false
    Ed.Sign = function(seed, body, pk)
        local sig = sign(seed, body, pk)
        if body:sub(1, 13) == "ISSUERREVOKE:" then
            v.rank, b.rank, changed = 1, 0, true
            v.ns.Roster.Scan()
        end
        return sig
    end
    Demote(w, o); w:Run(12)
    Ed.Sign = sign
    T.ok(changed, "игровое право изменилось после настоящей подписи")
    local list = k.ns.store.security.issuerRevocations[k.ns.Util.GuildKey(o.guild)]
    T.no(list and list[o.ns.myKey], "результат от прежнего главы не отправлен")
    Errors(w)
end)

T.test("issuer-revoke: отзыв переживает истечение сертификата главы и новую установку", function()
    local w, k, _, v, o = Build()
    local raw = o.ns.Issuers.For(o.guild, o.ns.myKey).raw
    Demote(w, o); w:Run(90)
    v:Logout()
    for _, c in ipairs(w.clients) do c.clockSkew = 8 * 86400 end
    w:Run(120)
    local n = w:Client({ first = "Новый", surname = "Главный", guild = k.guild, rank = 3, clockSkew = k.clockSkew })
    k.ns.Roster.Scan(); w:Run(120)
    T.ok(n.ns.Security.MyCertificate(), "новичок получил членство")
    T.eq(n.ns.Issuers.Current(raw), nil, "архивный отзыв проверен без действующего сертификата старого подписанта")
    local revocations = n.ns.store.security.issuerRevocations
    T.ok(revocations and revocations[n.ns.Util.GuildKey(o.guild)] and revocations[n.ns.Util.GuildKey(o.guild)][o.ns.myKey],
        "проверена именно подпись отзыва, а не отсутствие исходного допуска")
    Errors(w)
end)

T.test("issuer-revoke: просроченное подтверждение роли главы не разрешает новый отзыв", function()
    local w, k, _, v, o = Build()
    local grant, cert = o.ns.Issuers.For(o.guild, o.ns.myKey), v.ns.Security.MyCertificate()
    local issued = cert.issued + v.ns.Config.AUTH_ROLE_TTL + 1
    k.clockSkew = issued - k.ns.ServerTime()
    k.ns.Comm.Dispatch(Forge(v, grant, cert, issued), v:Name(), "WHISPER")
    w:Run(2)
    T.ok(k.ns.Issuers.Current(grant.raw), "старую роль нельзя использовать для нового решения")
    Errors(w)
end)

T.test("issuer-revoke: старое хранилище без таблицы отзывов не ломает проверку допуска", function()
    local w, _, _, v, o = Build()
    local grant = o.ns.Issuers.For(o.guild, o.ns.myKey)
    v.ns.store.security.issuerRevocations = nil
    T.ok(v.ns.Issuers.Current(grant.raw), "первый доступ инициализирует новое хранилище")
    Errors(w)
end)

T.test("issuer-revoke: корень не выдаёт право главы после смены звания во время подписи", function()
    local w, _, p, v, o = Build()
    for i, row in ipairs(w.guilds[p.guild].members) do
        if row.full then table.remove(w.guilds[p.guild].members, i); break end
    end
    p = w:Client({ first = p.first, surname = p.surname, guild = p.guild, rank = p.rank, db = p.ns.db })
    w:Run(30)
    local Ed, sign, send = p.ns.Ed25519, p.ns.Ed25519.Sign, p.ns.Comm.Send
    local changed, published = false, false
    Ed.Sign = function(seed, body, pk)
        local sig = sign(seed, body, pk)
        local fields = p.ns.Security.Control.Unpack(body, "ISSUER", 11, 700)
        if fields and fields[4] == o:Name() and fields[11] == "leader" then
            o.rank, v.rank, changed = 1, 0, true
            p.ns.Roster.Scan()
        end
        return sig
    end
    p.ns.Comm.Send = function(dist, msg, opts)
        local encoded = msg:match("^KD~([%w_-]+)$")
        local d = encoded and p.ns.Issuers.Read(Ed.FromB64(encoded))
        if d and d.name == o:Name() and d.scope == "leader" then published = true end
        return send(dist, msg, opts)
    end
    o.rank, v.rank = 0, 1
    p.ns.Roster.Scan()
    T.ok(p.ns.Issuers.Grant(o:Name(), o.ns.Security.PublicKey()), "начата выдача по свежему званию главы")
    w:Run(2)
    Ed.Sign, p.ns.Comm.Send = sign, send
    T.ok(changed, "звание изменилось после настоящей подписи корня")
    T.no(published, "отменённый допуск главы не поставлен в сеть")
    Errors(w)
end)

T.test("issuer-revoke: отзыв, пришедший до состава объединения, применяется после проверки корня", function()
    local w, k, _, v, o = Build()
    Demote(w, o); w:Run(90)
    local gk, main = k.ns.Util.GuildKey(o.guild), k.ns.Util.GuildKey(k.guild)
    local rev = k.ns.store.security.issuerRevocations[gk]
    T.ok(rev and rev[o.ns.myKey], "главная гильдия получила настоящий отзыв")
    local n = w:Client({ first = "Новый", surname = "Читатель", guild = k.guild, rank = 3 })
    -- Первый корень и UO уже получены, KA ещё собирается или проверяется.
    n.ns.store.security.roots[main] = k.ns.Security.Roots()[main]
    n.ns.store.security.owner = k.ns.UnionAuthority.Current()
    n.ns.Comm.Dispatch(rev[o.ns.myKey].wire, k:Name(), "WHISPER")
    n.ns.Comm.Dispatch(k.ns.store.security.policies[gk].wire, k:Name(), "WHISPER")
    w:Run(2)
    T.ok(n.ns.Util.IsMemberGuild(v.guild), "подписанное решение главы проверено")
    local seen = n.ns.store.security.issuerRevocations[gk]
    T.ok(seen and seen[o.ns.myKey], "предшествующий KV дождался корня и проверен")
    Errors(w)
end)
