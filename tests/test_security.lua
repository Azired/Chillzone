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
    T.eq(c.G.ns.Security.KnownRank("Чиллзон Север", c.B:Name()), nil, "signed census grants no leader authority")
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
    local forged = "RR~Чиллзон Север~" .. c.X.ns.Ed25519.ToB64(c.V.ns.Security.MyCertificate().raw)
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
    T.eq(c.V.ns.Data.KnownRank(guild, c.X:Name()), nil, "self-report grants no rank")
    Whisper(w, c.X, c.A, codec.EncodeRL("P", codec.EncodeChat("L", guild, 9002, "MAGE", "forged-leader-probe")))
    T.eq(c.V:Saw("forged-leader-probe"), 0, "outsider cannot write to leaders")
    c.A.ns.Config.TRUST_ANY_MEMBER = false
    Whisper(w, c.X, c.A, codec.EncodeRL("L", raw))
    Whisper(w, c.X, c.A, codec.EncodeRL("P", codec.EncodeChat("L", guild, 9012, "MAGE", "strict-forged-leader-probe")))
    T.eq(c.V.ns.Data.KnownRank(guild, c.X:Name()), nil, "strict transport setting grants no rank from a report")
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
    Whisper(w, c.B, c.A, "RR~Чиллзон Север~" .. c.B.ns.Ed25519.ToB64(cert.raw))
    T.eq(c.A.ns.Relay.Reporters()[guild].key, before, "ordinary member cannot preempt the live officer")
end)

T.test("security: resetting one's own root automatically creates a different key", function()
    local w, c = Build()
    local before = c.V.ns.Security.MyCertificate().public
    T.ok(c.V.ns.Security.Reset("Чиллзон Север"), "native authority can retire its own compromised key")
    w:Run(50)
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
