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
