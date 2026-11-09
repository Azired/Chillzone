-- Отдельный ключ управления. Издатель сертификатов не может заменить закреплённого главу.
local ADDON, ns = ...
local S, U, Ed = ns.Security, ns.Util, ns.Ed25519
local Pack, Unpack = S.Control.Pack, S.Control.Unpack
local A, allowed = {}, {}
local signing, checking = false, {}
ns.UnionAuthority = A

local function Store() return ns.store.security end
local function Read(raw)
    local f = type(raw) == "string" and Unpack(raw, "OWNER", 3, 5000)
    local p = f and Unpack(f[1], "UNIONOWNER", 6, 400)
    local generation, issued = p and tonumber(p[5]), p and tonumber(p[6])
    local pk, sig = p and Ed.FromB64(p[4]), f and Ed.FromB64(f[2])
    if not p or p[1] ~= ns.group or p[2] ~= ns.faction or not U.Key(p[3]) or p[3] ~= U.Display(p[3])
        or #p[3] > 64 or p[3]:find("[~|%c]")
        or not pk or #pk ~= 32 or not sig or #sig ~= 64 or not generation or generation % 1 ~= 0
        or generation < 1 or generation > 9007199254740991 or not issued or issued % 1 ~= 0
        or issued < 1 or issued > ns.ServerTime() + 30 then return end
    return { raw = raw, body = f[1], sig = sig, previous = f[3], name = p[3], public = p[4],
        generation = generation, issued = issued }
end
function A.Current() return Store().owner end
function A.Allow(sender) allowed[U.Key(sender)] = ns.Now() + 180 end
local function NativeOfficer(sender)
    return ns.Roster.Fresh() and ns.Roster.IsOfficerRank(ns.Roster.RankOf(sender))
end
local function Bootstrap(owner, sender, dist)
    if dist == "WHISPER" then
        local untilAt = allowed[U.Key(sender)]
        return untilAt and untilAt >= ns.Now() or false
    end
    if dist ~= "GUILD" or not NativeOfficer(sender) then return false end
    if U.IsMainGuild(ns.MyGuild()) then
        return ns.Roster.RankOf(owner.name) == 0
            and (not Store().ownerReset or U.Key(sender) == U.Key(owner.name))
    end
    return not Store().ownerReset
end
local function Verify(raw, known, depth)
    if depth > 32 then return end
    local owner = Read(raw)
    if not owner then return end
    if known and owner.raw == known.raw then return owner end
    local public
    if owner.previous == "" then
        if known or owner.generation ~= 1 then return end
        public = owner.public
    else
        local previous = Verify(owner.previous, known, depth + 1)
        if not previous or owner.generation ~= previous.generation + 1 or owner.issued < previous.issued then return end
        public = previous.public
    end
    if not Ed.ValidPublicKey(Ed.FromB64(owner.public)) or not Ed.Verify(Ed.FromB64(public), owner.body, owner.sig) then return end
    return owner
end
function A.Share(target, priority)
    local owner = A.Current()
    if not owner then return end
    local cert = S.MyCertificate()
    local proof = cert and cert.public == owner.public and cert.role == "leader" and U.IsMainGuild(cert.guild)
        and ("~" .. Ed.ToB64(cert.raw)) or ""
    local wire = "UO~" .. Ed.ToB64(owner.raw)
    if #wire + #proof <= ns.Codec.CHUNK * ns.Codec.MAX_CHUNKS then wire = wire .. proof end
    ns.Comm.Send(target == "GUILD" and "GUILD" or "WHISPER", wire,
        { target = target ~= "GUILD" and target or nil, prio = priority,
          key = "union-owner:" .. target, guard = function() return A.Current() == owner end })
end
local function Keep(owner)
    Store().owner, Store().ownerReset = owner, nil
    ns.Fire("UNION_OWNER")
end
function A.Reset()
    if not S.CanAdmin() then return false end
    Store().owner, Store().ownerReset = nil, true
    ns.Comm.Send("GUILD", "UQ~1", { prio = ns.Comm.PRIO_CONTROL, key = "union-query" })
    return true
end
function A.Tick(keys)
    if signing or not S.PublicKey() or not S.MyRoot() or not U.IsMainGuild(ns.MyGuild()) or not ns.Roster.Fresh() then return end
    local old, name, public = A.Current()
    if not old then
        if not S.CanManageUnion() then return end
        name, public = U.Display(ns.me), S.PublicKey()
    elseif old.public == S.PublicKey() and U.Key(old.name) == ns.myKey and not S.CanManageUnion() then
        for _, row in ipairs(ns.Roster.members) do
            local peer = keys[row.key]
            if row.rank == 0 and peer and ns.Now() - peer.at <= ns.Config.PEER_WINDOW then name, public = U.Display(row.name), peer.public end
        end
        if not public then return end
    else return end
    local body = Pack("UNIONOWNER", { ns.group, ns.faction, name, public,
        old and old.generation + 1 or 1, math.max(ns.ServerTime(), old and old.issued or 0) })
    local function Guard()
        return A.Current() == old and U.IsMainGuild(ns.MyGuild()) and ns.Roster.Fresh()
            and ns.Roster.RankOf(name) == 0
            and (not old or keys[U.Key(name)] and keys[U.Key(name)].public == public)
            and (old and S.PublicKey() == old.public or not old and S.CanManageUnion())
    end
    signing = true
    local queued = S.SignControl(body, Guard, function(sig)
        signing = false
        if not sig then return end
        local owner = Read(Pack("OWNER", { body, Ed.ToB64(sig), old and old.raw or "" }))
        if not owner then return end
        Keep(owner)
        A.Share("GUILD", ns.Comm.PRIO_BOOTSTRAP)
    end)
    if not queued then signing = false end
end
ns.Comm.On("UO", function(msg, sender, dist, ctx)
    if ctx and not ctx.unionControl then return end
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if #msg > 8100 or not S.Control.Budget("owner:" .. (U.Key(sender) or "?"), ns.Config.AUTH_NEW_PER_MIN) then return end
    local encoded, proof = msg:match("^UO~([%w_-]+)~([%w_-]+)$")
    encoded = encoded or msg:match("^UO~([%w_-]+)$")
    local raw = encoded and Ed.FromB64(encoded)
    local proposed, old = raw and Read(raw), A.Current()
    if not proposed or (old and (old.raw == raw or proposed.generation <= old.generation)) or checking[raw] then return end
    local count = 0; for _ in pairs(checking) do count = count + 1 end
    if count >= 8 then return end
    local function Use(verifiedProof)
        local function Trusted()
            if old or Bootstrap(proposed, sender, dist) then return true end
            local cert = verifiedProof and S.Member(ns.Config.MAIN_GUILD, proposed.name)
            return cert and cert.public == proposed.public and cert.role == "leader" and S.Level(cert) == 3
        end
        if not Trusted() or A.Current() ~= old then return end
        checking[raw] = true
        local queued = S.Control.Job(function() return Verify(raw, old, 1) end, function(owner)
            checking[raw] = nil
            if not owner or A.Current() ~= old or not Trusted() then return end
            Keep(owner)
            if S.CanAdmin() then A.Share("GUILD", ns.Comm.PRIO_BOOTSTRAP) end
        end)
        if not queued then checking[raw] = nil end
    end
    if not old and not Bootstrap(proposed, sender, dist) and proof and not Store().ownerReset then
        S.CheckCertificate(Ed.FromB64(proof), proposed.name, function(c)
            if c.public == proposed.public and U.IsMainGuild(c.guild) and c.role == "leader" and S.Level(c) == 3 then Use(true) end
        end, sender)
    else Use() end
end)
