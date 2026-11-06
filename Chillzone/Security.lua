-- Signed identities, guild-approved credentials and end-to-end payload integrity.
-- Relays carry bytes; only guild authorities certify identities and permissions.
local ADDON, ns = ...
local U, C, Ed = ns.Util, ns.Config, ns.Ed25519
Ed.SLICE_MS = 2
local S = { stats = { rejected = 0, verified = 0, limited = 0 } }
ns.Security = S
local identity, keys, issuing, pending, outgoing = nil, {}, {}, {}, {}
local certCache, verifyPending, replay, cachedOpens, limits = {}, {}, {}, {}, {}
local openedHere = {}
local serial, lastHello, lastPolicy = 0, -1e9, -1e9
local policySigning = {}
local policySent, credentialSent = {}, {}
local lastNativeHello = -1e9
local MAX_CERT, MAX_WIRE, MAX_PENDING = 1800, 7000, 32

local function Store()
    return ns.store and ns.store.security
end
local function GuildKey() local g = ns.MyGuild(); return g and U.GuildKey(g) end
local function Root(guild) local s = Store(); return s and s.roots[U.GuildKey(guild)] end
local function Pack(tag, values)
    local out = { tag .. ":" }
    for _, value in ipairs(values) do
        value = tostring(value)
        out[#out + 1] = #value .. ":" .. value
    end
    return table.concat(out)
end
local function Unpack(raw, tag, count, cap)
    if type(raw) ~= "string" or #raw > cap or raw:sub(1, #tag + 1) ~= tag .. ":" then return end
    local out, pos = {}, #tag + 2
    for i = 1, count do
        local len, first = raw:match("^(%d+):()", pos)
        if not len or #len > 4 or (#len > 1 and len:sub(1, 1) == "0") then return end
        len = tonumber(len)
        if len > cap or first + len - 1 > #raw then return end
        out[i], pos = raw:sub(first, first + len - 1), first + len
    end
    if pos == #raw + 1 then return out end
end
local function Int(s, lo, hi)
    if type(s) ~= "string" or not s:match("^%d+$") or (#s > 1 and s:sub(1, 1) == "0") then return end
    local n = tonumber(s)
    if n and n >= lo and n <= hi then return n end
end
local function Name(s)
    return type(s) == "string" and #s > 0 and #s <= 64 and not s:find("[~|%c]") and s == U.Display(s)
end
local function Budget(name)
    local now = ns.Now()
    local key = U.Key(name) or "?"
    local b = limits[key]
    if not b or now - b.t >= 60 then b = { t = now, n = 0 }; limits[key] = b end
    b.n = b.n + 1
    if b.n > 30 then S.stats.limited = S.stats.limited + 1; return false end
    return true
end
local function Job(fn, done)
    local accepted = Ed.Run(fn, function(ok, value)
        if not ok then ns.CaptureError("signature", value) end
        done(ok and value or nil)
    end)
    if not accepted then S.stats.limited = S.stats.limited + 1 end
    return accepted
end
function S.CanAdmin()
    return ns.IsMember() and ns.Roster.Fresh() and ns.Roster.IsOfficerRank(ns.Roster.MyRank())
end
local function NativeRole(name)
    if not ns.Roster.Fresh() then return end
    local rank = ns.Roster.RankOf(name)
    if rank == nil then return end
    return rank == 0 and "leader" or (ns.Roster.IsOfficerRank(rank) and "officer"
        or (U.IsRelayRankName(ns.Roster.rankNames[U.Key(name)]) and "rank" or "member")), rank
end
local function Certificate(raw)
    local cached = certCache[raw]
    if cached then return cached end
    local f = Unpack(raw, "CERT", 3, MAX_CERT)
    local p = f and Unpack(f[1], "CREDENTIAL", 13, 600)
    if not p then return end
    local issued, expires = Int(p[8], 1, 4102444800), Int(p[9], 1, 4102444800)
    local rank, pk = Int(p[7], 0, 30), Ed.FromB64(p[5])
    if p[1] ~= ns.group or p[2] ~= ns.faction or not U.IsMemberGuild(p[3]) or not Name(p[4])
        or not Name(p[10]) or not pk or #pk ~= 32 or not issued or not expires
        or expires <= issued or expires - issued > C.AUTH_TTL or not rank
        or (p[6] ~= "leader" and p[6] ~= "officer" and p[6] ~= "rank" and p[6] ~= "member")
        or (p[12] ~= "0" and p[12] ~= "1") or p[13] ~= "1" then return end
    local sig, issuer = Ed.FromB64(f[2]), Ed.FromB64(p[11])
    if not sig or #sig ~= 64 or not issuer or #issuer ~= 32 then return end
    return { raw = raw, body = f[1], sig = sig, delegation = f[3], group = p[1], faction = p[2],
        guild = p[3], name = p[4], key = U.Key(p[4]), public = p[5], pk = pk, role = p[6], rank = rank,
        issued = issued, expires = expires, issuerName = p[10], issuer = p[11], issuerPK = issuer, canIssue = p[12] == "1" }
end
local function Current(c)
    local root = c and Root(c.guild)
    local now = ns.ServerTime()
    if not root or c.expires <= now or c.issued > now + 30 then return false end
    if c.approvedRoot and c.approvedRoot ~= root.public then return false end
    local s = Store()
    local list = s.certs[U.GuildKey(c.guild)]
    local newer = list and list[c.key] and Certificate(list[c.key])
    if newer and newer.issued > c.issued and (newer.public ~= c.public or newer.role ~= c.role or newer.rank ~= c.rank) then return false end
    if c.delegation ~= "" then
        local d = Certificate(c.delegation)
        if not d or d.delegation ~= "" or d.issuer ~= root.public or not Current(d) then return false end
    end
    if U.GuildKey(c.guild) == GuildKey() and ns.Roster.Fresh() then
        local role, rank = NativeRole(c.name)
        if role ~= c.role or rank ~= c.rank then return false end
    end
    return true
end
local function VerifyCertificate(raw)
    local c = Certificate(raw)
    if not Current(c) then return end
    local root = Root(c.guild)
    if c.approvedRoot == root.public then return c end
    if c.issuer == root.public and U.Key(c.issuerName) == U.Key(root.name) then
        if c.delegation ~= "" then return end
    else
        -- Only a root-signed officer credential may delegate issuance, one level.
        local d = Certificate(c.delegation)
        if not Current(d) or not d.canIssue or (d.role ~= "leader" and d.role ~= "officer") or d.delegation ~= ""
            or U.GuildKey(d.guild) ~= U.GuildKey(c.guild) or d.public ~= c.issuer or d.key ~= U.Key(c.issuerName)
            or d.issuer ~= root.public or U.Key(d.issuerName) ~= U.Key(root.name) or c.canIssue
            or c.expires > d.expires or not Ed.Verify(d.issuerPK, d.body, d.sig) then return end
    end
    if not Ed.ValidPublicKey(c.pk) or not Ed.Verify(c.issuerPK, c.body, c.sig) then return end
    -- Signature work yields frames. Its trust root and delegation must still be
    -- current when the result is committed, not merely when the job started.
    local liveRoot = Root(c.guild)
    if not liveRoot or liveRoot.public ~= root.public or not Current(c) then return end
    c.approvedRoot = root.public
    certCache[raw] = c
    return c
end
local function Keep(c)
    if not Current(c) then return end
    local s, gk = Store(), U.GuildKey(c.guild)
    s.certs[gk] = s.certs[gk] or {}
    local old = s.certs[gk][c.key]
    local previous = old and Certificate(old)
    if previous and previous.issued > c.issued then return end
    s.certs[gk][c.key] = c.raw
    if c.canIssue and c.delegation == "" and (c.role == "leader" or c.role == "officer") then
        s.delegations[gk] = s.delegations[gk] or {}
        s.delegations[gk][c.key] = c.raw
    end
    ns.Fire("CREDENTIAL", c)
end
function S.CheckCertificate(raw, sender, done)
    local c = Certificate(raw)
    if not c or not Current(c) or (sender and c.key ~= U.Key(sender)) then return false end
    if c.approvedRoot == Root(c.guild).public then Keep(c); done(c); return true end
    if not Budget(sender or c.name) then return false end
    return Job(function() return VerifyCertificate(raw) end, function(valid)
        if valid and Current(valid) then Keep(valid); done(valid) else S.stats.rejected = S.stats.rejected + 1 end
    end)
end
function S.Member(guild, name)
    local s = Store()
    local list = s and s.certs[U.GuildKey(guild)]
    local raw = list and list[U.Key(name)]
    local c = raw and Certificate(raw)
    local root = c and Root(c.guild)
    return root and c.approvedRoot == root.public and Current(c) and c or nil
end
function S.Certificates(guild)
    local out, s = {}, Store()
    for _, raw in pairs(s and s.certs[U.GuildKey(guild)] or {}) do
        local c = Certificate(raw)
        if c and S.Member(guild, c.name) then out[#out + 1] = c end
    end
    return out
end
function S.Level(c)
    if not Current(c) then return 0 end
    if ns.ServerTime() - c.issued > C.AUTH_ROLE_TTL then return 1 end
    if c.role == "leader" then return 3 end
    if c.role == "officer" then return U.IsMainGuild(c.guild) and 3 or 2 end
    return 1
end
function S.KnownRank(guild, name)
    local c = S.Member(guild, name)
    if c and S.Level(c) > 1 then return c.role == "leader" and 0 or c.rank end
end
function S.MyCertificate()
    local g = ns.MyGuild()
    local c = g and S.Member(g, ns.me)
    return c and identity and c.public == identity.public and c or nil
end
local function ShareRoot(guild, root)
    if S.CanAdmin() then
        ns.Comm.Send("GUILD", "KT~" .. guild .. "~" .. root.name .. "~" .. root.public,
            { key = "root:" .. U.GuildKey(guild), guard = S.CanAdmin })
    end
end
local function Pin(guild, name, public)
    if not U.IsMemberGuild(guild) or not Name(name) then return false end
    local pk = Ed.FromB64(public)
    if not pk or #pk ~= 32 then return false end
    local s, gk = Store(), U.GuildKey(guild)
    if s.retired[gk] and s.retired[gk][public] then return false end
    local old = s.roots[gk]
    if old and (old.public ~= public or U.Key(old.name) ~= U.Key(name)) then return false end
    if old then return true end
    s.roots[gk] = { name = name, public = public, guild = guild }
    if not old and gk == GuildKey() then ShareRoot(guild, s.roots[gk]) end
    ns.Fire("AUTH_ROOT", guild)
    return true
end
local function Authority()
    if not identity or not S.CanAdmin() then return end
    local root = Root(ns.MyGuild())
    if not root then return end
    -- Exactly one online native officer issues credentials. A backup retains its
    -- root-signed delegation separately from its frequently renewed role proof.
    local delegations = Store().delegations[GuildKey()] or {}
    local best, bestIsRoot
    for _, row in ipairs(ns.Roster.members) do
        if row.online and ns.Roster.IsOfficerRank(row.rank) then
            local isRoot = row.key == U.Key(root.name)
            local d = delegations[row.key] and Certificate(delegations[row.key])
            if isRoot or (d and Current(d) and d.approvedRoot == root.public) then
                if not best or (isRoot and not bestIsRoot) or (isRoot == bestIsRoot and row.key < best) then
                    best, bestIsRoot = row.key, isRoot
                end
            end
        end
    end
    if best ~= ns.myKey then return end
    if root and root.public == identity.public and U.Key(root.name) == ns.myKey then return root, "" end
    local mine = delegations[ns.myKey] and Certificate(delegations[ns.myKey])
    if mine and Current(mine) and mine.public == identity.public and mine.issuer == root.public then return root, mine.raw end
end
local function Issue(name, public)
    local root, delegation = Authority()
    local signingIdentity = identity
    local role, rank = NativeRole(name)
    local key, now = U.Key(name), ns.ServerTime()
    if not root or not role or issuing[key] then return end
    local old = S.Member(ns.MyGuild(), name)
    local renew = role == "member" and C.AUTH_TTL / 2 or C.AUTH_RENEW
    if old and old.public == public and old.role == role and old.rank == rank and now - old.issued < renew then return end
    if old then now = math.max(now, old.issued + 1) end
    local expires = now + C.AUTH_TTL
    if delegation ~= "" then expires = math.min(expires, Certificate(delegation).expires) end
    local body = Pack("CREDENTIAL", { ns.group, ns.faction, ns.MyGuild(), U.Display(name), public, role, rank,
        now, expires, U.Display(ns.me), identity.public, delegation == "" and (role == "leader" or role == "officer") and "1" or "0", 1 })
    issuing[key] = true
    local started = Job(function()
        local pk = Ed.FromB64(public)
        if pk and Ed.ValidPublicKey(pk) then return Ed.Sign(signingIdentity.seed, body, signingIdentity.pk) end
    end, function(sig)
        issuing[key] = nil
        local currentRole, currentRank = NativeRole(name)
        if not sig or identity ~= signingIdentity or not Authority() or role ~= currentRole or rank ~= currentRank or Root(ns.MyGuild()) ~= root then return end
        local raw = Pack("CERT", { body, Ed.ToB64(sig), delegation })
        local c = Certificate(raw)
        if not c then return end
        c.approvedRoot = root.public
        certCache[raw] = c
        Keep(c)
        ns.Comm.Send("GUILD", "KP~" .. Ed.ToB64(raw), { key = "credential:" .. key, guard = S.CanAdmin })
    end)
    if not started then issuing[key] = nil end
    return started
end
local function Entropy()
    -- Same compromise as Olympus: mixed local samples, NOT an OS CSPRNG.
    local parts = { "Chillzone identity v1", ns.me, ns.group, ns.faction }
    local function Sample(fn, ...)
        if type(fn) ~= "function" then return end
        local ok, a, b = pcall(fn, ...)
        if ok and not (type(issecretvalue) == "function" and (issecretvalue(a) or issecretvalue(b))) then
            parts[#parts + 1] = tostring(a) .. "," .. tostring(b)
        end
    end
    for _ = 1, 8 do
        Sample(debugprofilestop); Sample(GetTimePreciseSec); Sample(GetTime); Sample(GetServerTime)
        Sample(UnitGUID, "player"); Sample(GetCursorPosition)
        parts[#parts + 1] = tostring(math.random()) .. tostring(math.random()) .. tostring({}) .. tostring({})
    end
    return Ed.SHA512(table.concat(parts, "|")):sub(1, 32)
end
local function StartIdentity(rotate)
    ns.db.securityKeys = ns.db.securityKeys or {}
    local scope = ns.group .. ":" .. ns.faction .. ":" .. ns.myKey
    local saved = not rotate and ns.db.securityKeys[scope] or nil
    local seed = saved and Ed.FromB64(saved.seed)
    if not seed or #seed ~= 32 then saved = { seed = Ed.ToB64(Entropy()), sequence = 0 }; ns.db.securityKeys[scope] = saved end
    seed = Ed.FromB64(saved.seed)
    saved.sequence = math.max(tonumber(saved.sequence) or 0, ns.ServerTime() * 10000)
    identity = nil
    Job(function() return Ed.PublicKey(seed) end, function(pk)
        if not pk or ns.db.securityKeys[scope] ~= saved then return end
        saved.pk, saved.public = pk, Ed.ToB64(pk)
        identity = setmetatable({ seed = seed, pk = pk, public = saved.public }, {
            __index = function(_, k) return saved[k] end,
            __newindex = function(_, k, v) saved[k] = v end,
        })
        S.Say()
    end)
end
function S.Say()
    if not identity or not ns.IsMember() or not ns.Roster.Fresh() then return end
    lastHello = ns.Now()
    keys[ns.myKey] = { name = ns.me, public = identity.public }
    ns.Comm.Send("GUILD", "K1~" .. identity.public, { key = "identity" })
    local mine = S.MyCertificate()
    if mine then ns.Comm.Send("GUILD", "KP~" .. Ed.ToB64(mine.raw), { key = "my-credential" }) end
end
function S.SendCredential(target)
    local c = S.MyCertificate()
    local key, now = U.Key(target), ns.Now()
    local old = credentialSent[key]
    if c and (not old or old.raw ~= c.raw or now - old.at >= 120) then
        credentialSent[key] = { raw = c.raw, at = now }
        ns.Comm.Send("WHISPER", "KP~" .. Ed.ToB64(c.raw), { target = target, prio = true })
    end
end
function S.Roots() return Store() and Store().roots or {} end
function S.ShareTrust()
    if not S.CanAdmin() then return false end
    if ns.Census then ns.Census.SendHello() end
    for _, root in pairs(S.Roots()) do ShareRoot(root.guild, root) end
    return true
end
local function Forget(guild, public)
    local s, gk = Store(), U.GuildKey(guild)
    local old = s.roots[gk]
    if not old or old.public ~= public then return false end
    s.retired[gk] = s.retired[gk] or {}
    s.retired[gk][public] = true
    s.roots[gk], s.certs[gk], s.delegations[gk], s.policies[gk] = nil, nil, nil, nil
    if gk == GuildKey() and keys[U.Key(old.name)] and keys[U.Key(old.name)].public == public then keys[U.Key(old.name)] = nil end
    ns.Fire("AUTH_ROOT", guild)
    return true
end
function S.Reset(guild)
    local root = Root(guild)
    if not S.CanAdmin() or not root then return false end
    local public = root.public
    if not Forget(guild, public) then return false end
    ns.Comm.Send("GUILD", "KF~" .. guild .. "~" .. public, { prio = true, guard = S.CanAdmin })
    if U.GuildKey(guild) == GuildKey() and identity and identity.public == public then StartIdentity(true) end
    S.Say()
    return true
end
ns.Comm.On("KF", function(msg, sender, dist)
    if dist ~= "GUILD" or not ns.Roster.Fresh() or not ns.Roster.IsOfficerRank(ns.Roster.RankOf(sender)) then return end
    local guild, public = msg:match("^KF~([^~]+)~([%w_-]+)$")
    if guild then Forget(guild, public) end
end)
function S.SendPolicies(target)
    local key, now = U.Key(target), ns.Now()
    policySent[key] = policySent[key] or {}
    for _, p in pairs(Store() and Store().policies or {}) do
        local old = policySent[key][p.guild]
        if p.expires > ns.ServerTime() and (not old or old.wire ~= p.wire or now - old.at >= 120) then
            policySent[key][p.guild] = { wire = p.wire, at = now }
            ns.Comm.Send("WHISPER", p.wire, { target = target, prio = true, key = "policy:" .. U.Key(target) .. ":" .. p.guild })
        end
    end
end
local function BuildPolicies()
    local c, root = S.MyCertificate(), Authority()
    local signingIdentity = identity
    if not c or not root or not U.IsMainGuild(c.guild) then return end
    local now, s = ns.ServerTime(), Store()
    for gk, entry in pairs(S.Roots()) do
        local previous = s.policies[gk]
        if not policySigning[gk] and (not previous or now - previous.issued >= C.AUTH_RENEW) then
            local body = Pack("GUILDROOT", { ns.group, ns.faction, entry.guild, entry.name, entry.public, now,
                math.min(now + C.AUTH_TTL, c.expires) })
            policySigning[gk] = true
            local queued = Job(function() return Ed.Sign(signingIdentity.seed, body, signingIdentity.pk) end, function(sig)
                policySigning[gk] = nil
                if not sig or identity ~= signingIdentity or not Authority() or Root(entry.guild) ~= entry then return end
                local wire = "KA~" .. Ed.ToB64(c.raw) .. "~" .. Ed.ToB64(body) .. "~" .. Ed.ToB64(sig)
                s.policies[gk] = { wire = wire, issued = now, expires = math.min(now + C.AUTH_TTL, c.expires), guild = entry.guild }
                ns.Comm.Send("GUILD", wire, { key = "root-policy:" .. gk, guard = S.CanAdmin })
            end)
            if not queued then policySigning[gk] = nil end
        end
    end
end
ns.Comm.On("KA", function(msg, sender, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if #msg > 3000 or not Budget(sender) then return end
    local encodedCert, encodedBody, encodedSig = msg:match("^KA~([%w_-]+)~([%w_-]+)~([%w_-]+)$")
    local raw, body, sig = encodedCert and Ed.FromB64(encodedCert), encodedBody and Ed.FromB64(encodedBody), encodedSig and Ed.FromB64(encodedSig)
    local p = body and Unpack(body, "GUILDROOT", 7, 500)
    local issued, expires = p and Int(p[6], 1, 4102444800), p and Int(p[7], 1, 4102444800)
    local pk = p and Ed.FromB64(p[5])
    if not raw or not p or not sig or #sig ~= 64 or p[1] ~= ns.group or p[2] ~= ns.faction
        or not U.IsMemberGuild(p[3]) or not Name(p[4]) or not pk or #pk ~= 32
        or not issued or not expires or expires <= ns.ServerTime() or issued > ns.ServerTime() + 30
        or expires - issued > C.AUTH_TTL then return end
    Job(function()
        local c = VerifyCertificate(raw)
        if not c or not U.IsMainGuild(c.guild) or not c.canIssue or (c.role ~= "leader" and c.role ~= "officer") or expires > c.expires then return end
        if Ed.Verify(c.pk, body, sig) then return c end
    end, function(issuer)
        if not issuer or not Current(issuer) or expires <= ns.ServerTime() then return end
        local s, gk = Store(), U.GuildKey(p[3])
        local old = s.policies[gk]
        if old and old.issued > issued then return end
        if not Pin(p[3], p[4], p[5]) then return end
        s.policies[gk] = { wire = msg, issued = issued, expires = expires, guild = p[3] }
    end)
end)
function S.Link(name)
    local root = ns.MyGuild() and Root(ns.MyGuild())
    local key = U.Key(name)
    if not S.CanAdmin() or not identity or not root or not key or ns.Roster.RankOf(name) ~= nil then return false end
    serial = serial + 1
    local nonce = tostring(ns.ServerTime()) .. "." .. serial
    outgoing[key] = { nonce = nonce, untilAt = ns.Now() + 180 }
    ns.Comm.Send("WHISPER", "KL~H~" .. nonce .. "~" .. ns.MyGuild() .. "~" .. root.name .. "~" .. root.public,
        { target = name, prio = true, guard = S.CanAdmin })
    ns.Print(ns.L.AUTH_SENT, U.Display(name))
    return true
end
function S.Accept(name)
    local key = U.Key(name)
    local p, root = pending[key], ns.MyGuild() and Root(ns.MyGuild())
    if not S.CanAdmin() or not p or not root or ns.Now() > p.untilAt then return false end
    if not Pin(p.guild, p.name, p.public) then return false end
    pending[key] = nil
    ShareRoot(p.guild, Root(p.guild))
    ns.Comm.Send("WHISPER", "KL~R~" .. p.nonce .. "~" .. ns.MyGuild() .. "~" .. root.name .. "~" .. root.public,
        { target = name, prio = true, guard = S.CanAdmin })
    S.SendCredential(name)
    ns.Print(ns.L.AUTH_PAIRED, U.Display(name), p.guild)
    return true
end
ns.Comm.On("KL", function(msg, sender, dist)
    if dist ~= "WHISPER" or not S.CanAdmin() or not Budget(sender) then return end
    local mode, nonce, guild, name, public = msg:match("^KL~([HR])~([%d%.]+)~([^~]+)~([^~]+)~([%w_-]+)$")
    if not mode or #msg > 250 or #nonce > 40 or not U.IsMemberGuild(guild) or U.GuildKey(guild) == GuildKey()
        or not Name(name) or #public ~= 43 or not Ed.FromB64(public) then return end
    local key = U.Key(sender)
    if mode == "H" then
        local total = 0; for _ in pairs(pending) do total = total + 1 end
        if total >= 16 and not pending[key] then return end
        pending[key] = { nonce = nonce, guild = guild, name = name, public = public, untilAt = ns.Now() + 180 }
        ns.Print(ns.L.AUTH_REQUEST, U.Display(sender), guild)
    else
        local p = outgoing[key]
        if not p or p.nonce ~= nonce or ns.Now() > p.untilAt then return end
        if Pin(guild, name, public) then
            outgoing[key] = nil
            ShareRoot(guild, Root(guild))
            S.SendCredential(sender)
            ns.Print(ns.L.AUTH_PAIRED, U.Display(sender), guild)
        end
    end
end)
ns.Comm.On("KT", function(msg, sender, dist)
    if dist ~= "GUILD" or not ns.Roster.Fresh() or not ns.Roster.IsOfficerRank(ns.Roster.RankOf(sender)) then return end
    local guild, name, public = msg:match("^KT~([^~]+)~([^~]+)~([%w_-]+)$")
    if guild then Pin(guild, name, public) end
end)
ns.Comm.On("K1", function(msg, sender, dist)
    if dist ~= "GUILD" or not NativeRole(sender) then return end
    local public = msg:match("^K1~([%w_-]+)$")
    local raw = public and Ed.FromB64(public)
    if not raw or #raw ~= 32 then return end
    keys[U.Key(sender)] = { name = sender, public = public }
    -- A reload has the same native name as the old peer. Answer its identity
    -- announcement so it learns the officer reporter before accepting RG.
    if S.CanAdmin() and ns.Census and ns.Now() - lastNativeHello >= 5 then
        lastNativeHello = ns.Now()
        ns.Census.SendHello()
    end
end)
ns.Comm.On("KP", function(msg, sender, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if dist == "GUILD" and not NativeRole(sender) then return end
    local raw = msg:match("^KP~([%w_-]+)$")
    raw = raw and Ed.FromB64(raw)
    if raw then S.CheckCertificate(raw, nil, function(c)
        if c.key == U.Key(sender) then ns.Fire("AUTH_PEER", c, sender) end
    end) end
end)
function S.Seal(inner, done)
    local c, saved = S.MyCertificate(), identity
    if not c or not saved or not ns.IsMember() then return false end
    local kind = inner:sub(1, 2)
    if kind ~= "M1" and kind ~= "R1" then return false end
    saved.sequence = saved.sequence + 1
    local at, sequence = tostring(ns.ServerTime()), tostring(saved.sequence)
    local body = Pack("MESSAGE", { ns.group, ns.faction, c.raw, at, sequence, inner })
    return Job(function() return Ed.Sign(saved.seed, body, saved.pk) end, function(sig)
        if not sig or identity ~= saved or not ns.IsMember() or not Current(c) or not S.MyCertificate() then return end
        local wire = "S1~" .. Ed.ToB64(c.raw) .. "~" .. at .. "~" .. sequence .. "~" .. Ed.ToB64(sig) .. "~" .. inner
        if #wire <= MAX_WIRE then done(wire) end
    end)
end
function S.Open(wire, sender, done)
    if type(wire) ~= "string" or #wire > MAX_WIRE then return false end
    local cert, at, seq, signature, inner = wire:match("^S1~([%w_-]+)~(%d+)~(%d+)~([%w_-]+)~(.+)$")
    local raw = cert and Ed.FromB64(cert)
    local c = raw and Certificate(raw)
    local stamp, sequence = Int(at, 1, 4102444800), Int(seq, 1, 9007199254740991)
    local sig = signature and Ed.FromB64(signature)
    if not c or not Current(c) or not stamp or not sequence or not sig or #sig ~= 64 then return false end
    local kind, now = inner:sub(1, 2), ns.ServerTime()
    local guild = inner:match("^M1~[ACL]~([^~]+)~") or inner:match("^R1~([^~]+)~")
    if not guild or U.GuildKey(guild) ~= U.GuildKey(c.guild) or stamp > now + 30
        or now - stamp > (kind == "M1" and C.CHAT_DEDUPE or C.TOTAL_KEEP) then return false end
    local tier = inner:match("^M1~([ACL])~")
    if kind ~= "M1" and kind ~= "R1" then return false end
    if tier and S.Level(c) < ({ A = 1, C = 2, L = 3 })[tier] then return false end
    local cached = cachedOpens[wire]
    if cached and cached.root == Root(c.guild).public then done(cached.inner, cached.cert, wire); return true end
    local waiting = verifyPending[wire]
    if waiting then
        if #waiting < 4 then waiting[#waiting + 1] = done end
        return true
    end
    local count = 0; for _ in pairs(verifyPending) do count = count + 1 end
    if count >= MAX_PENDING or not Budget(sender) then return false end
    verifyPending[wire] = { done }
    local accepted = Job(function()
        local valid = VerifyCertificate(raw)
        if valid and Ed.Verify(valid.pk, Pack("MESSAGE", { ns.group, ns.faction, raw, at, seq, inner }), sig) then return valid end
    end, function(valid)
        local callbacks = verifyPending[wire] or {}
        verifyPending[wire] = nil
        if not valid or not Current(valid) then S.stats.rejected = S.stats.rejected + 1; return end
        local id = valid.public .. ":" .. valid.key .. ":" .. seq
        if kind == "M1" then
            if replay[id] and (replay[id].signature ~= signature or not openedHere[id]) then return end
            local used = 0
            for _, entry in pairs(replay) do if now - entry.at <= C.CHAT_DEDUPE then used = used + 1 end end
            if not replay[id] and used >= 2048 then S.stats.limited = S.stats.limited + 1; return end
            replay[id] = { signature = signature, at = stamp }
            openedHere[id] = true
        end
        Keep(valid)
        local retained = 0; for _ in pairs(cachedOpens) do retained = retained + 1 end
        if retained >= 256 then
            local oldest, time
            for key, entry in pairs(cachedOpens) do if not time or entry.at < time then oldest, time = key, entry.at end end
            cachedOpens[oldest] = nil
        end
        cachedOpens[wire] = { cert = valid, inner = inner, at = now, root = Root(c.guild).public }
        S.stats.verified = S.stats.verified + 1
        for _, callback in ipairs(callbacks) do callback(inner, valid, wire) end
    end)
    if not accepted then verifyPending[wire] = nil end
    return accepted
end
ns.Comm.On("S1", function(wire, sender, dist)
    if dist ~= "GUILD" or not NativeRole(sender) then return end
    S.Open(wire, sender, function(inner, c)
        if c.key ~= U.Key(sender) or U.GuildKey(c.guild) ~= GuildKey() then return end
        ns.Comm.Dispatch(inner, c.name, "GUILD", { authenticated = true, certificate = c, wire = wire })
    end)
end)
local function Tick()
    if not identity or not ns.IsMember() or not ns.Roster.Fresh() then return end
    local guild, now = ns.MyGuild(), ns.Now()
    if S.CanAdmin() and not Root(guild) and now - ns.loginAt >= 20 then
        local best
        for key, row in pairs(keys) do
            if ns.Roster.IsOfficerRank(ns.Roster.RankOf(row.name)) and (not best or key < best) then best = key end
        end
        if best then Pin(guild, U.Display(keys[best].name), keys[best].public) end
    end
    if S.CanAdmin() and now - lastPolicy >= 30 then
        lastPolicy = now
        for _, root in pairs(S.Roots()) do ShareRoot(root.guild, root) end
    end
    if now - lastHello >= 60 then S.Say() end
    if Authority() then
        Issue(ns.me, identity.public)
        local count = 0
        for _, row in pairs(keys) do
            if count >= 8 then break end
            if Issue(row.name, row.public) then count = count + 1 end
        end
    end
    BuildPolicies()
end
ns.On("LOGIN", function()
    local s = ns.store.security
    if type(s) ~= "table" or s.version ~= 1 then
        ns.store.security = { version = 1, roots = {}, certs = {}, policies = {} }
        ns.store.guilds, ns.store.relays, ns.store.manual = {}, {}, {}
    end
    s = Store()
    s.roots, s.certs, s.policies, s.delegations, s.retired = s.roots or {}, s.certs or {}, s.policies or {}, s.delegations or {}, s.retired or {}
    s.replay = type(s.replay) == "table" and s.replay or {}
    replay = s.replay
    for id, entry in pairs(replay) do
        if type(entry) ~= "table" or type(entry.at) ~= "number" or ns.ServerTime() - entry.at > C.CHAT_DEDUPE then replay[id] = nil end
    end
    StartIdentity(false)
    -- Restored credentials regain authority only after actual signature checks.
    for _, list in pairs(s.certs) do
        for _, raw in pairs(list) do S.CheckCertificate(raw, nil, function() end) end
    end
    ns.Every(5, "security maintenance", Tick)
    ns.Every(60, "security gc", function()
        local now = ns.ServerTime()
        for wire, entry in pairs(cachedOpens) do if now - entry.at > 120 then cachedOpens[wire] = nil end end
        for id, entry in pairs(replay) do if now - entry.at > C.CHAT_DEDUPE then replay[id], openedHere[id] = nil, nil end end
        for key, p in pairs(pending) do if ns.Now() > p.untilAt then pending[key] = nil end end
        for key, p in pairs(outgoing) do if ns.Now() > p.untilAt then outgoing[key] = nil end end
        for raw, c in pairs(certCache) do if c.expires <= now then certCache[raw] = nil end end
    end)
end)
ns.On("GUILD_CHANGED", function()
    keys, issuing, pending, outgoing = {}, {}, {}, {}
    lastHello, lastPolicy = -1e9, -1e9
    S.Say()
end)
ns.Command("link", function(name)
    if not S.Link(U.Trim(name)) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
end, "соединить гильдии: /cz link Имя Фамилия (глава или офицер)")
ns.Command("accept", function(name)
    if not S.Accept(U.Trim(name)) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
end, "подтвердить проверенное имя: /cz accept Имя Фамилия")
ns.Command("trust", function(arg)
    local guild = arg:match("^reset%s+(.+)$")
    if not guild or not S.Reset(U.Trim(guild)) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
end, "сбросить доверие после утраты ключа: /cz trust reset Название гильдии")
ns.Status(function()
    return ns.L.AUTH_STATUS:format(S.MyCertificate() and ns.L.YES or ns.L.NO, S.stats.verified, S.stats.rejected)
end)
