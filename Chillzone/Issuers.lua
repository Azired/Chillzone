-- Долгосрочный корневой допуск издателя. Он не даёт членства или управления объединением.
local ADDON, ns = ...
local S, U, C, Ed = ns.Security, ns.Util, ns.Config, ns.Ed25519
local Pack, Unpack = S.Control.Pack, S.Control.Unpack
local I, pending = {}, {}
local shared = {}
ns.Issuers = I

local function Store()
    local s = ns.store.security
    if type(s.issuers) ~= "table" then s.issuers = {} end
    return s.issuers
end
local function Root(guild) return S.Roots()[U.GuildKey(guild)] end
local function Blocks()
    local s = ns.store.security
    s.issuerBlocks = s.issuerBlocks or {}
    return s.issuerBlocks
end
local function Compact(d)
    return { raw = d.raw, guild = d.guild, name = d.name, key = d.key, public = d.public,
        issued = d.issued, expires = d.expires, active = d.active, revision = d.revision, root = d.root, scope = d.scope }
end
function I.IsGrant(raw) return type(raw) == "string" and raw:sub(1, 6) == "GRANT:" end
function I.Read(raw)
    if not I.IsGrant(raw) then return end
    local f = Unpack(raw, "GRANT", 2, 1200)
    local p = f and (Unpack(f[1], "ISSUER", 11, 700) or Unpack(f[1], "ISSUER", 10, 700))
    local issued, expires, revision = p and tonumber(p[6]), p and tonumber(p[7]), p and tonumber(p[9])
    local pk, sig = p and Ed.FromB64(p[5]), f and Ed.FromB64(f[2])
    if not p or p[1] ~= ns.group or p[2] ~= ns.faction or not pk or #pk ~= 32
        or not sig or #sig ~= 64 or not U.Key(p[4]) or p[4] ~= U.Display(p[4])
        or #p[4] > 64 or p[4]:find("[~|%c]") or #p[3] > 96 or p[3] ~= U.Trim(p[3]) or p[3]:find("[~|%c]")
        or p[3] == "" or not issued or issued % 1 ~= 0 or issued < 1 or issued > 4102444800
        or not expires or expires % 1 ~= 0 or expires <= issued or expires - issued > C.AUTH_ISSUER_TTL
        or not revision or revision % 1 ~= 0 or revision < 1 or revision > 9007199254740991
        or (p[8] ~= "0" and p[8] ~= "1") or not Ed.FromB64(p[10])
        or (p[11] and p[11] ~= "issuer" and p[11] ~= "leader") then return end
    return { raw = raw, body = f[1], sig = sig, guild = p[3], name = p[4], key = U.Key(p[4]),
        public = p[5], issued = issued, expires = expires, active = p[8] == "1", revision = revision, root = p[10],
        scope = p[11] or "issuer" }
end
local function Latest(d)
    local list = Store()[U.GuildKey(d.guild)]
    return list and list[d.key]
end
local function Admissible(d)
    local root = d and Root(d.guild)
    if not root or root.public ~= d.root or d.issued > ns.ServerTime() + 30
        or (d.active and d.expires or d.issued + C.AUTH_ISSUER_TTL) <= ns.ServerTime() then return false end
    local old = Latest(d)
    return not old or old.root ~= d.root or (d.revision >= old.revision and d.issued >= old.issued
        and (d.revision ~= old.revision or d.raw == old.raw))
end
function I.Current(raw)
    local d = I.Read(raw)
    if not d or not d.active or d.expires <= ns.ServerTime() or not Admissible(d)
        or (ns.IssuerRevocations and ns.IssuerRevocations.Blocks(d)) then return end
    local list = ns.store.security.certs[U.GuildKey(d.guild)]
    local c = list and list[d.key] and S.Control.Certificate(list[d.key])
    if c and c.issued >= d.issued and (c.public ~= d.public or (c.role ~= "leader" and c.role ~= "officer")) then return end
    if U.GuildKey(d.guild) == U.GuildKey(ns.MyGuild()) and ns.Roster.Fresh()
        and not ns.Roster.IsOfficerRank(ns.Roster.RankOf(d.name)) then return end
    return d
end
local function Keep(d, dist)
    local gk = U.GuildKey(d.guild)
    Store()[gk] = Store()[gk] or {}
    local old = Store()[gk][d.key]
    if not old or old.raw ~= d.raw then
        Store()[gk][d.key] = Compact(d)
        if d.blocked then
            Blocks()[gk] = Blocks()[gk] or {}
            Blocks()[gk][d.key] = d.root
        end
        if not d.active then
            local wire = "KD~" .. Ed.ToB64(d.raw)
            ns.Fire("ISSUER_REVOCATION", wire, gk .. ":" .. d.key)
            if dist == "WHISPER" then
                ns.Comm.Send("GUILD", wire, { prio = ns.Comm.PRIO_CONTROL, key = "issuer-revoke:" .. gk .. ":" .. d.key })
            end
        end
    end
end
function I.Verify(raw)
    local d = I.Current(raw)
    if not d then return end
    if not Ed.ValidPublicKey(Ed.FromB64(d.public)) or not Ed.Verify(Ed.FromB64(d.root), d.body, d.sig) then return end
    if not I.Current(raw) then return end
    Keep(d)
    return d
end
function I.For(guild, key)
    local list = Store()[U.GuildKey(guild)]
    local d = list and list[key]
    return d and I.Current(d.raw)
end
function I.Candidates(guild)
    local out = {}
    for _, d in pairs(Store()[U.GuildKey(guild)] or {}) do
        local current = I.Current(d.raw)
        if current then out[#out + 1] = current end
    end
    return out
end
function I.LegacyAllowed(c)
    if ns.IssuerRevocations and ns.IssuerRevocations.LegacyBlocked(c.guild, c.key) then return false end
    local list = Store()[U.GuildKey(c.guild)]
    local d = list and list[c.key]
    return not d or d.root ~= (Root(c.guild) or {}).public or (d.active and d.public == c.public and d.expires > ns.ServerTime()
        and not (ns.IssuerRevocations and ns.IssuerRevocations.Blocks(d)))
end
local function IsRoot()
    local root = S.MyRoot()
    return S.CanAdmin() and root and root.public == S.PublicKey() and U.Key(root.name) == ns.myKey
end
local function Issue(name, public, active, manual)
    if not IsRoot() then return false end
    local guild, key, root = ns.MyGuild(), U.Key(name), S.MyRoot()
    if not key or pending[key] then return false end
    local list = Store()[U.GuildKey(guild)] or {}
    local old, now = list[key], ns.ServerTime()
    local revision = (old and old.root == root.public and old.revision or 0) + 1
    local scope = ns.Roster.RankOf(name) == 0 and "leader" or "issuer"
    local body = Pack("ISSUER", { ns.group, ns.faction, guild, U.Display(name), public,
        now, now + C.AUTH_ISSUER_TTL, active and "1" or "0", revision, root.public, scope })
    local function Guard()
        return IsRoot() and ns.MyGuild() == guild and S.MyRoot() == root
            and (active or manual or ns.Roster.OfficerDemoted(name))
            and (not active or (ns.Roster.IsOfficerRank(ns.Roster.RankOf(name))
                and scope == (ns.Roster.RankOf(name) == 0 and "leader" or "issuer")))
    end
    pending[key] = true
    local queued = S.SignControl(body, Guard, function(sig)
        pending[key] = nil
        if not sig then return end
        local d = I.Read(Pack("GRANT", { body, Ed.ToB64(sig) }))
        if not d or not Admissible(d) then return end
        d.blocked = manual and not active or nil
        if manual and active and Blocks()[U.GuildKey(guild)] then Blocks()[U.GuildKey(guild)][key] = nil end
        Keep(d)
        ns.Comm.Send("GUILD", "KD~" .. Ed.ToB64(d.raw), { key = "issuer:" .. key, guard = Guard })
    end)
    if not queued then pending[key] = nil end
    return queued
end
function I.Revoke(name)
    local d = I.For(ns.MyGuild(), U.Key(name))
    return d and Issue(d.name, d.public, false, true) or false
end
function I.Grant(name, public) return Issue(name, public, true, true) end
function I.Tick(keys)
    if not IsRoot() then return end
    local list = Store()[U.GuildKey(ns.MyGuild())] or {}
    for _, d in pairs(list) do
        if d.active and d.root == S.MyRoot().public and ns.Roster.OfficerDemoted(d.name) then
            if Issue(d.name, d.public, false) then return end
        end
    end
    for key, peer in pairs(keys) do
        local blocked = Blocks()[U.GuildKey(ns.MyGuild())]
        blocked = blocked and blocked[key] == S.MyRoot().public
        if key ~= ns.myKey and not blocked and ns.Now() - peer.at <= C.PEER_WINDOW
            and ns.Roster.IsOfficerRank(ns.Roster.RankOf(peer.name)) then
            local d = list[key]
            if not d or d.root ~= S.MyRoot().public or d.public ~= peer.public or not d.active
                or d.scope ~= (ns.Roster.RankOf(peer.name) == 0 and "leader" or "issuer")
                or ns.ServerTime() - d.issued >= C.AUTH_ISSUER_TTL / 2
                or (ns.IssuerRevocations and ns.IssuerRevocations.Blocks(d)) then
                if Issue(peer.name, peer.public, true) then return end
            end
        end
    end
end
function I.Share(target, priority)
    for _, list in pairs(Store()) do
        for _, d in pairs(list) do
            if Admissible(d) and (not d.active or (target == "GUILD" and d.expires > ns.ServerTime()
                and U.GuildKey(d.guild) == U.GuildKey(ns.MyGuild()))
                or (target ~= "GUILD" and d.active and d.expires > ns.ServerTime() and U.IsMainGuild(d.guild))) then
                local key = target .. ":" .. U.GuildKey(d.guild) .. ":" .. d.key
                local old = shared[key]
                if target == "GUILD" or not old or old.raw ~= d.raw or ns.Now() - old.at >= C.AUTH_INTRODUCE then
                    shared[key] = { raw = d.raw, at = ns.Now() }
                    ns.Comm.Send(target == "GUILD" and "GUILD" or "WHISPER", "KD~" .. Ed.ToB64(d.raw),
                        { target = target ~= "GUILD" and target or nil, prio = priority,
                          key = "issuer-share:" .. key })
                end
            end
        end
    end
    if ns.IssuerRevocations then ns.IssuerRevocations.Share(target, priority) end
end
function I.ShareRevocations(target, priority)
    for _, list in pairs(Store()) do
        for _, d in pairs(list) do
            if not d.active and Admissible(d) then
                local key = target .. ":" .. U.GuildKey(d.guild) .. ":" .. d.key
                local old = shared[key]
                if not old or old.raw ~= d.raw or ns.Now() - old.at >= C.AUTH_INTRODUCE then
                    if ns.Comm.Send("WHISPER", "KD~" .. Ed.ToB64(d.raw),
                        { target = target, prio = priority, key = "issuer-share:" .. key }) then
                        shared[key] = { raw = d.raw, at = ns.Now() }
                    end
                end
            end
        end
    end
    ns.IssuerRevocations.Share(target, priority)
end
ns.Comm.On("KD", function(msg, sender, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if #msg > 1700 or not S.Control.Budget("issuer:" .. (U.Key(sender) or "?"), C.AUTH_NEW_PER_MIN) then return end
    local encoded = msg:match("^KD~([%w_-]+)$")
    local d = encoded and I.Read(Ed.FromB64(encoded))
    if not d or not Admissible(d) or (d.active and d.expires <= ns.ServerTime()) then return end
    if Latest(d) and Latest(d).raw == d.raw then return end
    S.Control.Job(function() return Ed.Verify(Ed.FromB64(d.root), d.body, d.sig) end, function(valid)
        if valid and Admissible(d) then Keep(d, dist) end
    end)
end)
function I.Sweep(restore)
    local now = ns.ServerTime()
    for gk, list in pairs(Store()) do
        for key, d in pairs(list) do
            if d.blocked then
                Blocks()[gk] = Blocks()[gk] or {}
                Blocks()[gk][key] = d.root
            end
            -- KD должен перекрывать и прежний допуск с максимальным сроком.
            if (d.active and d.expires or d.issued + C.AUTH_ISSUER_TTL) <= now then list[key] = nil
            elseif restore then list[key] = Compact(d) end
        end
        if not next(list) then Store()[gk] = nil end
    end
    for key, entry in pairs(shared) do if ns.Now() - entry.at >= C.AUTH_INTRODUCE then shared[key] = nil end end
    for gk, list in pairs(Blocks()) do
        local root = S.Roots()[gk]
        for key, public in pairs(list) do if not root or root.public ~= public then list[key] = nil end end
        if not next(list) then Blocks()[gk] = nil end
    end
end
