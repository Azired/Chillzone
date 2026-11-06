-- Security regressions exercise server-stamped senders through the real transport.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local Build, Whisper

T.test("security: raw outsider whispers never enter alliance chat", function()
    local w = Wow.World()
    w:Guild("Чиллзон")
    local leader = w:Client({ first = "Глава", surname = "Гильдии", guild = "Чиллзон", rank = 0 })
    local outsider = w:Client({ first = "Посторонний", surname = "Игрок" })
    w:Run(80)
    local payload = outsider.ns.Codec.EncodeChat("A", "Чиллзон Подделка", 9001, "MAGE", "outsider-direct-chat")
    outsider.ns.Comm.Send("WHISPER", payload, { target = leader:Name(), logged = true })
    w:Run(10)
    T.eq(leader:Saw("outsider-direct-chat"), 0, "unknown sender cannot bypass relay admission")
    T.eq(#leader.ns.Chat.History("A"), 0, "rejected message is not persisted")
    T.eq(#leader.ns.db.errors, 0, "no swallowed transport error")
end)

T.test("security: real signed packets reject relay mutations and forged credentials", function()
    local w, c = Build()
    local payload = c.V.ns.Codec.EncodeChat("L", "Чиллзон Север", 9010, "DRUID", "original-signed-body")
    local wire
    T.ok(c.V.ns.Security.Seal(payload, function(signed) wire = signed end), "real signature queued")
    w:Run(3)
    T.ok(wire, "signature produced automatically in-game")
    local delivered = 0
    local function Open(value)
        c.G.ns.Security.Open(value, c.M:Name(), function() delivered = delivered + 1 end)
        w:Run(2)
    end
    Open(wire:gsub("original%-signed%-body", "modified-signed-body"))
    Open(wire:gsub("~M1~L~", "~M1~A~"))
    T.eq(delivered, 0, "relay cannot alter signed text or channel")
    Open(wire)
    T.eq(delivered, 1, "unaltered message verifies after failed forgeries")
    local credential = c.V.ns.Security.MyCertificate()
    local other
    for _, saved in pairs(c.X.ns.db.securityKeys) do other = saved.public end
    T.ok(other and other ~= credential.public, "attacker has its own independent key")
    local substituted, changes = credential.raw:gsub(credential.public:gsub("(%W)", "%%%1"), other, 1)
    T.eq(changes, 1, "test must actually replace the public key")
    local accepted = false
    c.G.ns.Security.CheckCertificate(substituted, c.V:Name(), function() accepted = true end)
    w:Run(2)
    T.no(accepted, "public-key substitution requires a real authority signature")
end)

T.test("security: expired and retired authority credentials fail closed", function()
    local w, c = Build()
    local credential = c.V.ns.Security.MyCertificate()
    local clock = c.G.ns.ServerTime
    c.G.ns.ServerTime = function() return credential.expires + 1 end
    T.eq(c.G.ns.Security.Member("Чиллзон Север", c.V:Name()), nil, "expired membership rejected")
    c.G.ns.ServerTime = clock
    T.no(c.M.ns.Security.Reset("Чиллзон Север"), "ordinary relay cannot revoke trust")
    T.ok(c.G.ns.Security.Reset("Чиллзон Север"), "native officer can retire a lost authority key")
    local accepted = false
    c.G.ns.Security.CheckCertificate(credential.raw, c.V:Name(), function() accepted = true end)
    w:Run(2)
    T.no(accepted, "retired root cannot regain authority through a cached certificate")
end)

T.test("security: после /cz trust reset чужой гильдии офицер снова подтверждает её корень", function()
    local w, c = Build()
    -- Второй участник Ордена: отзыв (KF) и повторное подтверждение (KU, KT) доходят и до него.
    local D = w:Client({ first = "Дина", surname = "Дальняя", guild = "Орден Чиллзона", rank = 3 })
    c.G.ns.Roster.Scan()
    w:Run(60)
    local gk = c.G.ns.Util.GuildKey("Чиллзон Север")
    local public = c.V.ns.Security.MyCertificate().public
    T.eq(D.ns.Security.Roots()[gk] and D.ns.Security.Roots()[gk].public, public, "Дина знает корень Севера")
    T.ok(c.G.ns.Security.Reset("Чиллзон Север"), "Глеб сбрасывает корень Севера")
    w:Run(5)
    for _, cl in ipairs({ c.G, D }) do
        T.eq(cl.ns.Security.Roots()[gk], nil, cl:Name() .. ": корня Севера нет")
        T.ok(cl.ns.store.security.retired[gk][public], cl:Name() .. ": ключ помечен отозванным")
    end
    -- Без явного подтверждения отозванный ключ не возвращается: KT от Веры (в чужую гильдию
    -- не доходит) или повторное объявление офицером Ордена.
    c.G.ns.Comm.Dispatch("KT~Чиллзон Север~" .. c.V:Name() .. "~" .. public, c.G:Name(), "GUILD")
    T.eq(c.G.ns.Security.Roots()[gk], nil, "KT не возвращает отозванный корень")
    -- Офицер Севера снова просит соединения, Глеб подтверждает.
    T.ok(c.V.ns.Security.Link(c.G:Name()), "Вера просит соединения")
    w:Run(5)
    T.ok(c.G.ns.Security.Accept(c.V:Name()), "Глеб подтверждает отозванный прежде корень")
    w:Run(20)
    for _, cl in ipairs({ c.G, D }) do
        local root = cl.ns.Security.Roots()[gk]
        T.eq(root and root.public, public, cl:Name() .. ": корень Севера снова принят")
        T.eq(cl.ns.store.security.retired[gk], nil, cl:Name() .. ": отметки об отзыве нет")
    end
    -- Снова в обратную сторону: сброс, затем просит Глеб, а подтверждает Вера (ответ KL~R).
    T.ok(c.G.ns.Security.Reset("Чиллзон Север"), "второй сброс")
    w:Run(5)
    T.ok(c.G.ns.Security.Link(c.V:Name()), "Глеб просит соединения")
    w:Run(5)
    T.ok(c.V.ns.Security.Accept(c.G:Name()), "Вера подтверждает")
    w:Run(20)
    for _, cl in ipairs({ c.G, D }) do
        local root = cl.ns.Security.Roots()[gk]
        T.eq(root and root.public, public, cl:Name() .. ": корень Севера принят по ответу на /cz link")
    end
    -- Связь работает: строка Веры снова доходит до Ордена.
    c.V:Slash("/cz1", "снова на связи")
    w:Run(60)
    T.eq(c.G:Saw("снова на связи"), 1, "Глеб видит строку Севера")
    -- Рядовой Ордена не может снять отметку об отзыве своим KU.
    T.ok(c.G.ns.Security.Reset("Чиллзон Север"), "третий сброс")
    w:Run(5)
    D.ns.Comm.Send("GUILD", "KU~Чиллзон Север~" .. public, { prio = true })
    w:Run(5)
    T.ok(c.G.ns.store.security.retired[gk][public], "KU рядового не снимает отметку")
    for _, cl in ipairs({ c.G, c.V, D }) do T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": без ошибок") end
end)

T.test("security: a genuinely signed member census cannot grant authority", function()
    local w, c = Build()
    local old = c.B.ns.Security.MyCertificate()
    T.ok(old and c.B.ns.Security.Level(old) == 1, "ordinary credential ready")
    -- The member cannot become a leader through its own census, even when that
    -- census has a genuine signature belonging to the member.
    local raw = c.B.ns.Codec.EncodeReport({ guild = "Чиллзон Север", total = 2, online = 2,
        leader = c.B:Name(), faction = "Alliance", st = c.B.ns.ServerTime() })
    local wire
    c.B.ns.Security.Seal(raw, function(value) wire = value end)
    w:Run(2)
    T.ok(wire, "member can sign census data with its own key")
    Whisper(w, c.B, c.A, c.B.ns.Codec.EncodeRL("L", wire))
    T.eq(Wow.CertRank(c.G.ns, "Чиллзон Север", c.B:Name()), nil, "signed census grants no leader authority")
    local payload = c.B.ns.Codec.EncodeChat("L", "Чиллзон Север", 9011, "MAGE", "self-promoted-member")
    c.B.ns.Security.Seal(payload, function(value) wire = value end)
    w:Run(2)
    Whisper(w, c.B, c.A, c.B.ns.Codec.EncodeRL("P", wire))
    T.eq(c.G:Saw("self-promoted-member"), 0, "genuine member signature does not grant leadership")
end)

Build = function()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Чиллзон Север")
    w:Guild("Орден Чиллзона")
    local c = {}
    c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
    c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3 })
    c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
    c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3 })
    c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
    c.X = w:Client({ first = "Посторонний", surname = "Игрок" })
    w:Run(30)
    w:Init(c.A, c.V, c.G)
    for _, source in ipairs({ c.V, c.G }) do
        T.ok(source.ns.Security.Link(c.A:Name()), "officer initiates pairing")
        w:Run(5)
        T.ok(c.A.ns.Security.Accept(source:Name()), "receiving officer approves exact requester")
        w:Run(10)
    end
    w:Run(400)
    for name, cl in pairs(c) do
        T.eq(#cl.ns.db.errors, 0, name .. ": " .. table.concat(cl.ns.db.errors, " | "))
    end
    return w, c
end

Whisper = function(w, from, to, raw)
    from.ns.Comm.Send("WHISPER", raw, { target = to:Name(), prio = true })
    w:Run(20)
end

local function Fields(tag, values)
    local out = { tag .. ":" }
    for _, value in ipairs(values) do value = tostring(value); out[#out + 1] = #value .. ":" .. value end
    return table.concat(out)
end
local function Seed(cl)
    local _, saved = next(cl.ns.db.securityKeys)
    return saved and cl.ns.Ed25519.FromB64(saved.seed)
end
T.test("security: a previously verified credential is retained when its peer announces it", function()
    local w, c = Build()
    local certificate = assert(c.B.ns.Security.MyCertificate())
    local S, U = c.G.ns.Security, c.G.ns.Util
    T.ok(S.CheckCertificate(certificate.raw, certificate.name, function() end))
    w:Run(2)
    local known = c.G.ns.store.security.certs[U.GuildKey(certificate.guild)]
    -- KA verifies and caches its embedded issuer before a following KP announces
    -- the same identity. Signature caching must not bypass identity retention.
    known[certificate.key] = nil
    T.eq(S.Member(certificate.guild, certificate.name), nil, "identity has not been retained")
    local announced
    T.ok(S.CheckCertificate(certificate.raw, certificate.name, function(valid) announced = valid end))
    T.ok(announced, "cached real signature is accepted")
    T.ok(S.Member(certificate.guild, certificate.name), "peer announcement retains the verified identity")
end)
local function ReplaceDuringRealVerification(receiver, oldGuild, newPublic, body)
    local Ed, real = receiver.ns.Ed25519, receiver.ns.Ed25519.Verify
    local changed = false
    Ed.Verify = function(pk, message, signature)
        local valid = real(pk, message, signature)
        if valid and message == body and not changed then
            changed = true
            local old = receiver.ns.Security.Roots()[receiver.ns.Util.GuildKey(oldGuild)]
            T.ok(receiver.ns.Security.Reset(oldGuild), "trusted native officer retires old root")
            -- Simulate a subsequent, explicitly confirmed replacement while the
            -- frame-sliced verifier still holds the result for the old root.
            receiver.ns.Security.Roots()[receiver.ns.Util.GuildKey(oldGuild)] = {
                guild = oldGuild, name = old.name, public = newPublic,
            }
        end
        return valid
    end
    return function() Ed.Verify = real; return changed end
end

T.test("security: a root replacement during real certificate verification cancels admission", function()
    local w, c = Build()
    local cred = c.V.ns.Security.MyCertificate()
    local body, replacements = cred.body:gsub(tostring(cred.issued), tostring(cred.issued + 1), 1)
    T.eq(replacements, 1, "new certificate body is distinct and uncached")
    local Ed = c.V.ns.Ed25519
    local raw = Fields("CERT", { body, Ed.ToB64(Ed.Sign(Seed(c.V), body)), "" })
    local newPublic
    for _, item in pairs(c.X.ns.db.securityKeys) do newPublic = item.public end
    local finish = ReplaceDuringRealVerification(c.G, "Чиллзон Север", newPublic, body)
    local accepted = false
    c.G.ns.Security.CheckCertificate(raw, c.V:Name(), function() accepted = true end)
    w:Run(1)
    T.ok(finish(), "root changed after actual Ed25519 verification")
    T.no(accepted, "old-root result cannot register a reporter after replacement")
end)

T.test("security: a root replacement during real catalog verification cancels new trust", function()
    local w, c = Build()
    local Ed, cred = c.A.ns.Ed25519, c.A.ns.Security.MyCertificate()
    local now, guild = c.A.ns.ServerTime(), "Чиллзон Восток"
    local body = Fields("GUILDROOT", { c.A.ns.group, c.A.ns.faction, guild,
        c.V:Name(), c.V.ns.Security.MyCertificate().public, now, now + 600 })
    local wire = "KA~" .. Ed.ToB64(cred.raw) .. "~" .. Ed.ToB64(body) .. "~" .. Ed.ToB64(Ed.Sign(Seed(c.A), body))
    local newPublic
    for _, item in pairs(c.X.ns.db.securityKeys) do newPublic = item.public end
    local finish = ReplaceDuringRealVerification(c.G, "Чиллзон", newPublic, body)
    c.G.ns.Comm.Dispatch(wire, c.A:Name(), "WHISPER")
    w:Run(1)
    T.ok(finish(), "catalog issuer retired after actual signature check")
    T.eq(c.G.ns.Security.Roots()[c.G.ns.Util.GuildKey(guild)], nil, "retired catalog issuer cannot add trust")
end)

T.test("security: cached credentials cannot outlive an observed issuer demotion", function()
    local w, c = Build()
    c.B.rank = 1
    c.V:Fire("GUILD_RANKS_UPDATE")
    c.B:Fire("GUILD_RANKS_UPDATE")
    w:Run(65)
    local delegate, subject = c.B.ns.Security.MyCertificate(), c.V.ns.Security.MyCertificate()
    T.ok(delegate and delegate.canIssue and delegate.role == "officer", "native promotion grants a root-signed delegation")
    local Ed, now = c.B.ns.Ed25519, c.B.ns.ServerTime()
    local body = Fields("CREDENTIAL", { c.B.ns.group, c.B.ns.faction, "Чиллзон Север", c.V:Name(),
        subject.public, "leader", 0, now, now + 600, c.B:Name(), delegate.public, "0", "1" })
    local leaf = Fields("CERT", { body, Ed.ToB64(Ed.Sign(Seed(c.B), body)), delegate.raw })
    local accepted = false
    c.G.ns.Security.CheckCertificate(leaf, c.V:Name(), function() accepted = true end)
    w:Run(2)
    T.ok(accepted, "legitimate delegated certificate is initially cached")
    c.B.rank = 3
    c.V:Fire("GUILD_RANKS_UPDATE")
    c.B:Fire("GUILD_RANKS_UPDATE")
    w:Run(65)
    local revoked = c.B.ns.Security.MyCertificate()
    T.ok(revoked and revoked.role == "member" and revoked.issued > delegate.issued, "native demotion has a newer signed credential")
    accepted = false
    c.G.ns.Security.CheckCertificate(revoked.raw, c.B:Name(), function() accepted = true end)
    w:Run(2)
    T.ok(accepted, "receiver observes the real signed demotion")
    accepted = false
    c.G.ns.Security.CheckCertificate(leaf, c.V:Name(), function() accepted = true end)
    w:Run(2)
    T.no(accepted, "cached delegated leaf is invalid after issuer demotion")
end)

T.test("security: RR cannot replace a reporter using only a guild claim", function()
    local w, c = Build()
    local gk = c.A.ns.Util.GuildKey("Чиллзон Север")
    local before = c.A.ns.Relay.Reporters()[gk]
    T.ok(before, "legitimate reporter registered")
    -- A certificate is public: stealing the legitimate reporter's certificate
    -- must not let another native WHISPER sender register under its identity.
    local forged = "RR~Чиллзон Север~" .. c.V.ns.Security.MyCertificate().fp
    Whisper(w, c.X, c.A, forged)
    T.eq(c.A.ns.Relay.Reporters()[gk].key, before.key, "outsider did not replace the reporter")
    c.A.ns.Config.TRUST_ANY_MEMBER = false
    Whisper(w, c.X, c.A, forged)
    T.eq(c.A.ns.Relay.Reporters()[gk].key, before.key, "strict transport setting also rejects the outsider")
    c.A.ns.Config.TRUST_ANY_MEMBER = true
    local start = #w.log
    c.G:Slash("/cz3", "private-registration-probe")
    w:Run(35)
    T.eq(c.V:Saw("private-registration-probe"), 1, "legitimate guild still receives delivery")
    for i = start + 1, #w.log do
        local entry = w.log[i]
        T.no(entry.target == c.X:Name() and entry.msg:find("private-registration-probe", 1, true), "no outsider delivery")
    end
end)

T.test("security: a forged census report never grants a leader role", function()
    local w, c = Build()
    local codec = c.X.ns.Codec
    local guild = "Чиллзон Подделка"
    local raw = codec.EncodeReport({ guild = guild, total = 1, online = 1,
        leader = c.X:Name(), faction = "Alliance", st = c.X.ns.ServerTime() })
    Whisper(w, c.X, c.A, codec.EncodeRL("L", raw))
    T.eq(Wow.CertRank(c.V.ns, guild, c.X:Name()), nil, "self-report grants no rank")
    Whisper(w, c.X, c.A, codec.EncodeRL("P", codec.EncodeChat("L", guild, 9002, "MAGE", "forged-leader-probe")))
    T.eq(c.V:Saw("forged-leader-probe"), 0, "outsider cannot write to leaders")
    c.A.ns.Config.TRUST_ANY_MEMBER = false
    Whisper(w, c.X, c.A, codec.EncodeRL("L", raw))
    Whisper(w, c.X, c.A, codec.EncodeRL("P", codec.EncodeChat("L", guild, 9012, "MAGE", "strict-forged-leader-probe")))
    T.eq(Wow.CertRank(c.V.ns, guild, c.X:Name()), nil, "strict transport setting grants no rank from a report")
    T.eq(c.V:Saw("strict-forged-leader-probe"), 0, "strict transport setting also rejects self-promotion")
end)

T.test("security: even a selected ordinary relay cannot forge another author's text", function()
    local w, c = Build()
    c.A:Logout()
    w:Run(240)
    T.ok(c.M.ns.Relay.IAmRelay(), "ordinary member remains an available relay")
    T.eq(c.V.ns.Relay.Pick().key, c.M.ns.myKey, "officer outage selects ordinary member")
    local codec = c.M.ns.Codec
    local fake = codec.EncodeRM("RG", "P", c.V:Name(),
        codec.EncodeChat("L", "Чиллзон Север", 9003, "DRUID", "forged-origin-probe"))
    w:Deliver(c.M, "GUILD", c.M.ns.PREFIX, fake, nil, true)
    w:Run(10)
    T.eq(c.M:Saw("forged-origin-probe"), 0, "forged envelope not displayed")
    T.eq(c.G:Saw("forged-origin-probe"), 0, "forged envelope not forwarded")
    c.V:Slash("/cz1", "honest-member-fallback")
    w:Run(45)
    T.eq(c.G:Saw("honest-member-fallback"), 1, "signed chat survives officer outage")
end)

T.test("security: unsigned guild envelopes cannot impersonate a real foreign leader", function()
    local w, c = Build()
    local codec = c.M.ns.Codec
    w:Deliver(c.M, "GUILD", c.M.ns.PREFIX, codec.EncodeRM("RG", "P", c.V:Name(),
        codec.EncodeChat("L", "Чиллзон Север", 9004, "DRUID", "unsigned-origin-probe")), nil, true)
    w:Run(10)
    T.eq(c.A:Saw("unsigned-origin-probe"), 0, "real leader name cannot authenticate an envelope")
end)

T.test("security: chat replay is rejected after a saved-state reload", function()
    local w, c = Build()
    local wire
    c.V.ns.Security.Seal(c.V.ns.Codec.EncodeChat("A", "Чиллзон Север", 9020, "DRUID", "replay-window-probe"),
        function(value) wire = value end)
    w:Run(2)
    local accepted = 0
    c.G.ns.Security.Open(wire, c.M:Name(), function() accepted = accepted + 1 end)
    w:Run(2)
    T.eq(accepted, 1, "first genuine message accepted")
    local db = c.G.ns.db
    c.G:Logout()
    local restored = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, db = db })
    w:Run(5)
    restored.ns.Security.Open(wire, c.M:Name(), function() accepted = accepted + 1 end)
    w:Run(2)
    T.eq(accepted, 1, "persisted replay window rejects the old message")
    T.eq(#restored.ns.db.errors, 0, "reload has no hidden errors")
end)

T.test("security: certificates do not permit taking an officer reporter's healthy lease", function()
    local w, c = Build()
    local cert = c.B.ns.Security.MyCertificate()
    local guild = c.B.ns.Util.GuildKey("Чиллзон Север")
    local before = c.A.ns.Relay.Reporters()[guild].key
    Whisper(w, c.B, c.A, "RR~Чиллзон Север~" .. cert.fp)
    T.eq(c.A.ns.Relay.Reporters()[guild].key, before, "ordinary member cannot preempt the live officer")
end)

T.test("security: resetting one's own root automatically creates a different key", function()
    local w, c = Build()
    local before = c.V.ns.Security.MyCertificate().public
    T.ok(c.V.ns.Security.Reset("Чиллзон Север"), "native authority can retire its own compromised key")
    w:Run(10)
    T.ok(c.V.ns.Security.Init(), "the officer sets the new root by hand")
    w:Run(40)
    local current = c.V.ns.Security.MyCertificate()
    T.ok(current and current.public ~= before, "new automatic identity replaces the retired key")
    T.eq(#c.V.ns.db.errors, 0, "key recovery has no hidden errors")
end)

T.test("security: key reset safely cancels queued issuance using the old identity", function()
    local w, c = Build()
    local steps = {}
    local Ed, after = c.V.ns.Ed25519, c.V.ns.Ed25519.after
    Ed.after = function(fn) steps[#steps + 1] = fn end
    local first = w:Client({ first = "Новый", surname = "Участник", guild = "Чиллзон Север", rank = 3 })
    local second = w:Client({ first = "Другой", surname = "Участник", guild = "Чиллзон Север", rank = 3 })
    w:Run(10)
    c.V.ns.Roster.Scan()
    first.ns.Security.Say(); second.ns.Security.Say()
    w:Run(10)
    T.ok(Ed.Busy() >= 2, "multiple real issuance jobs wait for a frame")
    T.ok(c.V.ns.Security.Reset("Чиллзон Север"), "native root reset queued behind issuance")
    local limit = 0
    while steps[1] do
        limit = limit + 1
        T.ok(limit < 10000, "queued crypto work terminates")
        table.remove(steps, 1)()
    end
    Ed.after = after
    w:Run(50)
    T.eq(#c.V.ns.db.errors, 0, "old issuance does not dereference the replaced identity")
end)

T.test("security: priority queue and peer discovery have hard bounds", function()
    local w, c = Build()
    local Comm = c.B.ns.Comm
    for i = 1, 300 do Comm.Send("GUILD", "test-queued-" .. i, { prio = true }) end
    T.ok(Comm.QueueSize() <= Comm.MAX_QUEUE, "priority traffic cannot bypass queue cap")
    local start = #w.log
    c.V.ns.Relay.PingAll()
    w:Run(10)
    local peers = {}
    for i = start + 1, #w.log do
        local e = w.log[i]
        if e.from == c.V:Name() and e.dist == "WHISPER" then peers[e.target] = true end
    end
    local count = 0; for _ in pairs(peers) do count = count + 1 end
    T.ok(count <= 3, "discovery is bounded independently of alliance reader count")
end)

T.test("security: additional readers cause no author-to-reader confirmation traffic", function()
    local w, c = Build()
    local readers = {}
    for i = 1, 12 do readers[i] = w:Client({ first = "Читатель" .. i, surname = "Севера", guild = "Чиллзон Север", rank = 3 }) end
    w:Run(180)
    local start = #w.log
    c.V:Slash("/cz1", "one-signature-many-readers")
    w:Run(40)
    for _, reader in ipairs(readers) do T.eq(reader:Saw("one-signature-many-readers"), 1, "real reader verifies and displays once") end
    w:Run(180) -- include the old non-reporter periodic discovery interval
    for i = start + 1, #w.log do
        local e = w.log[i]
        if e.from == c.V:Name() and e.dist == "WHISPER" then
            for _, reader in ipairs(readers) do T.no(e.target == reader:Name(), "author sends no private confirmation to readers") end
        end
        if e.dist == "WHISPER" then
            for _, reader in ipairs(readers) do T.no(e.from == reader:Name(), "passive readers do not poll remote relays") end
        end
    end
end)

T.test("security: the guild root is set by hand once, a late officer cannot split it", function()
    local w = Wow.World()
    w:Guild("Чиллзон Север")
    local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
    local B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3 })
    w:Run(200)
    local gk = V.ns.Util.GuildKey("Чиллзон Север")
    T.eq(V.ns.Security.Roots()[gk], nil, "officers online for minutes create no root by themselves")
    T.no(B.ns.Security.Init(), "an ordinary member cannot set the root")
    w:Init(V)
    w:Run(60)
    T.ok(B.ns.Security.MyCertificate(), "the member is certified under the new root")
    T.no(V.ns.Security.Init(), "a second init is refused at once")
    -- An officer logging in later learns the root from the online officer: in answer to his K1
    -- or from the periodic KT (every 30 s, accepted once his own roster is read).
    local O = w:Client({ first = "Олег", surname = "Опытный", guild = "Чиллзон Север", rank = 1 })
    V.ns.Roster.Scan(); B.ns.Roster.Scan() -- he is an old member: already in their rosters
    w:Run(45)
    local root = O.ns.Security.Roots()[gk]
    T.ok(root and root.name == V:Name(), "late officer received the existing root")
    T.no(O.ns.Security.Init(), "late officer cannot start a second root")
    -- With only a member online, a new officer is told the guild already has a root.
    V:Logout(); O:Logout()
    local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 1 })
    B.ns.Roster.Scan()
    w:Run(30)
    local said = {}
    T.ok(N.ns.Security.Init(false, function(text) said[#said + 1] = text end), "the query starts")
    w:Run(12)
    T.eq(N.ns.Security.Roots()[gk], nil, "the member's answer stops a second root")
    T.ok(said[#said] and said[#said]:find(V:Name(), 1, true), "and names the existing root")
    T.ok(N.ns.Security.Init(true), "force is the explicit way past that answer")
    w:Run(12)
    T.eq(N.ns.Security.Roots()[gk] and N.ns.Security.Roots()[gk].name, N:Name(), "forced root is set")
    for _, cl in ipairs({ V, B, O, N }) do T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": no errors") end
end)

T.test("security: verified credentials return after a reload without signature checks", function()
    local w, c = Build()
    local db = c.G.ns.db
    c.G:Logout()
    local restored = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, db = db })
    local S = restored.ns.Security
    T.ok(S.Member("Чиллзон Север", c.V:Name()), "foreign credential is usable at once")
    T.ok(S.Member("Чиллзон", c.A:Name()), "main guild credential too")
    T.ok(restored.ns.Ed25519.Busy() <= 1, "login queues only the own key, no credential checks")
    w:Run(5)
    T.eq(S.stats.limited, 0, "login does not exhaust any verification budget")
    T.eq(S.stats.rejected, 0, "nothing restored is rejected")
    -- A credential without its verification mark is not trusted from disk.
    restored:Logout()
    local security = db.realms[restored.ns.group][restored.ns.faction].security
    security.verified[restored.ns.Util.GuildKey("Чиллзон Север")] = nil
    local again = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, db = db })
    T.eq(again.ns.Security.Member("Чиллзон Север", c.V:Name()), nil, "unmarked credential is dropped")
    T.ok(again.ns.Security.Member("Чиллзон", c.A:Name()), "marked ones stay")
    T.eq(#again.ns.db.errors, 0, "no hidden errors")
end)

T.test("security: signed packets carry a fingerprint, the credential comes once or on request", function()
    local w, c = Build()
    local S = c.V.ns.Security
    local wire
    S.Seal(c.V.ns.Codec.EncodeChat("A", "Чиллзон Север", 9030, "DRUID", "короткая строка"), function(v) wire = v end)
    w:Run(2)
    T.ok(wire and #wire < 250, "a short chat line stays small: " .. tostring(wire and #wire))
    T.no(wire:find(c.V.ns.Ed25519.ToB64(S.MyCertificate().raw), 1, true), "the credential itself is not inside")
    -- A new member's credential is unknown to Gleb: he asks whoever passed the packet on.
    local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
    c.V.ns.Roster.Scan() -- otherwise Vera drops her first K1 and waits for the next one
    w:Run(60)
    T.ok(N.ns.Security.MyCertificate(), "new member certified")
    T.eq(c.G.ns.Security.Member("Чиллзон Север", N:Name()), nil, "Gleb does not know her credential yet")
    local signed
    N.ns.Security.Seal(N.ns.Codec.EncodeChat("A", "Чиллзон Север", 9031, "MAGE", "по запросу"), function(v) signed = v end)
    w:Run(2)
    local opened = 0
    c.G.ns.Security.Open(signed, c.V:Name(), function() opened = opened + 1 end)
    w:Run(10)
    T.eq(opened, 1, "KQ to the forwarder brings the credential and the packet opens")
    T.ok(c.G.ns.Security.Member("Чиллзон Север", N:Name()), "and the credential is kept")
end)

T.test("security: verification limits count authors and forwarders separately", function()
    local w, c = Build()
    local S = c.G.ns.Security
    local authors = { c.A, c.M, c.V, c.B }
    for _, author in ipairs(authors) do
        S.CheckCertificate(author.ns.Security.MyCertificate().raw, nil, function() end)
    end
    w:Run(65)
    local opened = 0
    for _, author in ipairs(authors) do
        local guild, wires = author.ns.MyGuild(), {}
        for i = 1, 10 do
            author.ns.Security.Seal(author.ns.Codec.EncodeChat("A", guild, 9100 + i, "MAGE", "budget-" .. i),
                function(v) wires[#wires + 1] = v end)
        end
        w:Run(3)
        for _, wire in ipairs(wires) do S.Open(wire, c.A:Name(), function() opened = opened + 1 end) end
        w:Run(3)
    end
    T.eq(opened, 40, "one forwarder carries more than one author's worth of packets a minute")
    w:Run(65)
    local burst, accepted, before = {}, 0, S.stats.limited
    for i = 1, 32 do
        c.B.ns.Security.Seal(c.B.ns.Codec.EncodeChat("A", "Чиллзон Север", 9200 + i, "MAGE", "burst-" .. i),
            function(v) burst[#burst + 1] = v end)
    end
    w:Run(5)
    for _, wire in ipairs(burst) do S.Open(wire, c.M:Name(), function() accepted = accepted + 1 end) end
    w:Run(10)
    T.eq(accepted, c.G.ns.Config.AUTH_AUTHOR_PER_MIN, "a single author is still cut at the author limit")
    T.ok(S.stats.limited > before, "and the cut is counted")
    -- New credentials are limited by the sender, not by the name each one claims.
    local mine, Ed = c.V.ns.Security.MyCertificate(), c.X.ns.Ed25519
    local letters = { "а", "б", "в", "г", "д" }
    before = S.stats.limited
    for i = 1, 25 do
        local name = "Подложный Ж" .. letters[(i - 1) % 5 + 1] .. letters[math.floor((i - 1) / 5) + 1]
        local body = Fields("CREDENTIAL", { mine.group, mine.faction, mine.guild, name, mine.public, "member", 3,
            mine.issued, mine.expires, mine.issuerName, mine.issuer, "0", 1 })
        c.G.ns.Comm.Dispatch("KP~" .. Ed.ToB64(Fields("CERT", { body, Ed.ToB64(mine.sig), "" })), c.X:Name(), "WHISPER")
    end
    w:Run(30)
    T.eq(S.stats.limited - before, 25 - c.G.ns.Config.AUTH_NEW_PER_MIN, "one sender's forged credentials share one budget")
    T.eq(#c.G.ns.db.errors, 0, "no hidden errors")
end)

T.test("security: other officers keep the guild certified for days while the root is away", function()
    local w = Wow.World()
    w:Guild("Чиллзон Север")
    local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
    local O = w:Client({ first = "Олег", surname = "Опытный", guild = "Чиллзон Север", rank = 1 })
    local B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3 })
    w:Run(30)
    w:Init(V)
    w:Run(60)
    T.ok(O.ns.Security.MyCertificate(), "officer certified by the root")
    T.ok(B.ns.Security.MyCertificate(), "member certified by the root")
    V:Logout()
    local online = { O, B }
    local function Skip(days) -- server time jumps; timers are not replayed
        for _, cl in ipairs(online) do cl.clockSkew = (cl.clockSkew or 0) + days * 86400 end
    end
    Skip(3)
    O.ns.Roster.Scan()
    w:Run(30)
    T.ok(B.ns.Security.MyCertificate(), "three days later the member still has a credential")
    -- A newcomer is certified by the remaining officer under his delegation from the root.
    local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
    N.clockSkew = O.clockSkew
    online[#online + 1] = N
    O.ns.Roster.Scan(); B.ns.Roster.Scan()
    w:Run(60)
    local U, cert = O.ns.Util, N.ns.Security.MyCertificate()
    T.ok(cert and U.Key(cert.issuerName) == U.Key(O:Name()), "newcomer certified by the officer, not the absent root")
    T.ok(B.ns.Security.Member("Чиллзон Север", N:Name()), "and the guild accepts that credential")
    -- More than AUTH_TTL after the root was last online nobody can issue any more.
    Skip(5)
    w:Run(30)
    T.eq(B.ns.Security.MyCertificate(), nil, "the member's credential expired")
    T.eq(N.ns.Security.MyCertificate(), nil, "the newcomer's too: it never outlives the delegation")
    for _, cl in ipairs({ V, O, B, N }) do T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": no errors") end
end)

T.test("security: forged packets with someone's fingerprint do not spend that author's limit", function()
    local w, c = Build()
    local S = c.G.ns.Security
    S.CheckCertificate(c.B.ns.Security.MyCertificate().raw, nil, function() end)
    w:Run(5)
    local genuine
    c.B.ns.Security.Seal(c.B.ns.Codec.EncodeChat("A", "Чиллзон Север", 9300, "MAGE", "настоящая строка"),
        function(v) genuine = v end)
    w:Run(3)
    -- The fingerprint is public: an outsider stamps it on packets with signatures that do not match.
    local limit, rejected = c.G.ns.Config.AUTH_AUTHOR_PER_MIN, S.stats.rejected
    for i = 1, limit do
        local forged = genuine:gsub("^(S1~[%w_-]+~)(%d+)", function(head, at) return head .. (tonumber(at) - i) end)
        S.Open(forged, c.X:Name(), function() end)
    end
    w:Run(10)
    T.eq(S.stats.rejected - rejected, limit, "every forgery fails its signature check")
    local opened = 0
    S.Open(genuine, c.A:Name(), function() opened = opened + 1 end)
    w:Run(5)
    T.eq(opened, 1, "the real author's packet still opens")
    T.eq(#c.G.ns.db.errors, 0, "no hidden errors")
end)

T.test("security: an officer's other credentials do not crowd out a member's own", function()
    local w, c = Build()
    local B, V = c.B, c.V
    T.eq(B.ns.Security.MyCertificate().rank, 3, "an ordinary member to begin with")
    -- KPs from Vera with other members' credentials keep Boris's limit for new credentials from
    -- her used up, as on a guild's first day. Own-guild names must be in the roster, or such a
    -- KP is dropped before the limit. Once the limit is used up, extras cost no signature checks.
    local mine, Ed = V.ns.Security.MyCertificate(), B.ns.Ed25519
    local letters = { "а", "б", "в", "г", "д" }
    local others = {}
    for i = 1, B.ns.Config.AUTH_NEW_PER_MIN + 1 do
        local name = "Запасной Ж" .. letters[(i - 1) % 5 + 1] .. letters[math.floor((i - 1) / 5) + 1]
        w:AddOffline("Чиллзон Север", name .. "-CAMWOWUS2Realm7PvE", 3)
        local body = Fields("CREDENTIAL", { mine.group, mine.faction, mine.guild, name, mine.public, "member", 3,
            mine.issued, mine.expires, mine.issuerName, mine.issuer, "0", 1 })
        others[i] = "KP~" .. Ed.ToB64(Fields("CERT", { body, Ed.ToB64(mine.sig), "" }))
    end
    -- Boris becomes a veteran: Vera issues a new credential, and it must still get through.
    B.rank = 2
    B.ns.Roster.Scan(); V.ns.Roster.Scan()
    for _ = 1, 100 do
        for _, msg in ipairs(others) do B.ns.Comm.Dispatch(msg, V:Name(), "GUILD") end
        w:Run(0.25)
    end
    local cert = B.ns.Security.MyCertificate()
    T.eq(cert and cert.rank, 2, "the new credential arrived despite the exhausted limit")
    T.eq(#B.ns.db.errors, 0, "no hidden errors")
end)

T.test("security: a member who missed their own credential gets it again after K1", function()
    local w, c = Build()
    local B, U = c.B, c.B.ns.Util
    T.ok(B.ns.Security.MyCertificate(), "certified")
    -- The KP never reached Boris; Vera holds a fresh credential and will not issue it again.
    B.ns.store.security.certs[U.GuildKey("Чиллзон Север")][U.Key(B:Name())] = nil
    T.eq(B.ns.Security.MyCertificate(), nil, "no credential")
    w:Run(75)
    T.ok(B.ns.Security.MyCertificate(), "the issuer whispered it back after K1 ~0")
    T.eq(#B.ns.db.errors, 0, "no hidden errors")
end)

T.test("security: early certificate waits for its root despite forged wait metadata", function()
    local w, c = Build()
    local guild = "Орден Чиллзона"
    local root = c.G.ns.Security.Roots()[c.G.ns.Util.GuildKey(guild)]
    local certificate = c.G.ns.Security.MyCertificate()
    local wire
    c.G.ns.Security.Seal(c.G.ns.Codec.EncodeChat("A", guild, 9341, "HUNTER", "ранняя строка"),
        function(value) wire = value end)
    w:Run(3)
    T.ok(wire, "real signed message is ready")

    local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
    -- Контролируем порядок KP/KT: фоновые объявления не должны подменить этот сценарий.
    local fire = N.Fire
    N.Fire = function(self, event, ...)
        if event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_ADDON_LOGGED" then return end
        return fire(self, event, ...)
    end
    N.ns.Roster.Scan()
    local opened, forged = 0, 0
    T.ok(N.ns.Security.Open(wire, c.V:Name(), function() opened = opened + 1 end, true),
        "message waits for the author certificate")
    local fake, replacements = wire:gsub("~M1~A~Орден Чиллзона~", "~M1~A~Чиллзон~", 1)
    T.eq(replacements, 1, "forgery changes the claimed guild with the same fingerprint")
    N.ns.Security.Open(fake, c.X:Name(), function() forged = forged + 1 end)
    N.ns.Comm.Dispatch("KP~" .. N.ns.Ed25519.ToB64(certificate.raw), c.V:Name(), "GUILD")
    w:Run(65)
    T.eq(opened, 0, "unverified certificate grants no trust before KT")
    T.eq(N.ns.Security.Member(guild, c.G:Name()), nil, "certificate is not admitted yet")
    N.ns.Comm.Dispatch("KT~" .. guild .. "~" .. root.name .. "~" .. root.public, c.V:Name(), "GUILD")
    w:Run(10)
    T.eq(opened, 1, "retained certificate releases the original message after its root")
    T.eq(forged, 0, "forged guild never authorizes the modified message")
    T.eq(#N.ns.db.errors, 0, "no hidden errors")
end)
