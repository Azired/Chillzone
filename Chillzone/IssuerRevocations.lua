-- Подписанный отзыв допуска главой своей гильдии. Корневой персонаж может быть офлайн.
local ADDON, ns = ...
local S, I, U, C, Ed = ns.Security, ns.Issuers, ns.Util, ns.Config, ns.Ed25519
local Pack, Unpack = S.Control.Pack, S.Control.Unpack
local R, pending, checking, shared = {}, {}, {}, {}
local waitingRoots = {}
ns.IssuerRevocations = R

local function Store()
    local s = ns.store.security
    if type(s.issuerRevocations) ~= "table" then s.issuerRevocations = {} end
    return s.issuerRevocations
end
local function Root(guild) return S.Roots()[U.GuildKey(guild)] end
local function Integer(value, max)
    local n = type(value) == "string" and value:match("^%d+$") and tonumber(value)
    return n and n >= 1 and n <= max and n % 1 == 0 and n or nil
end
local function Read(raw)
    local f = type(raw) == "string" and Unpack(raw, "REVOKE", 5, 4500)
    local p = f and Unpack(f[1], "ISSUERREVOKE", 9, 650)
    local d, leader, c = f and I.Read(f[2]), f and I.Read(f[3]), f and S.Control.Certificate(f[4])
    local issued, revision = p and Integer(p[8], 4102444800), p and Integer(p[6], 9007199254740991)
    local sig = f and Ed.FromB64(f[5])
    if not p or not d or not d.active or not leader or leader.scope ~= "leader" or not c or not sig or #sig ~= 64
        or p[1] ~= ns.group or p[2] ~= ns.faction or p[3] ~= d.guild or p[4] ~= d.name or p[5] ~= d.public
        or revision ~= d.revision or tonumber(p[7]) ~= d.issued or not issued or issued < d.issued
        or d.issued + C.AUTH_ISSUER_TTL <= ns.ServerTime()
        or issued > ns.ServerTime() + 30 or p[9] ~= "0" or U.GuildKey(c.guild) ~= U.GuildKey(d.guild)
        or c.role ~= "leader" or c.rank ~= 0 or c.issued > issued or c.expires <= issued
        or issued - c.issued > C.AUTH_ROLE_TTL then return end
    if leader.root ~= d.root or U.GuildKey(leader.guild) ~= U.GuildKey(d.guild) or leader.public ~= c.public
        or leader.key ~= c.key then return end
    return { raw = raw, wire = "KV~" .. Ed.ToB64(raw), body = f[1], sig = sig, grant = d, certificate = c,
        leader = leader, guild = d.guild, key = d.key, root = d.root, revision = revision, issued = issued,
        expires = d.issued + C.AUTH_ISSUER_TTL }
end
local function Latest(guild, key)
    local list = Store()[U.GuildKey(guild)]
    return list and list[key]
end
function R.Blocks(d)
    local r = Latest(d.guild, d.key)
    return r and r.root == d.root and r.revision >= d.revision or false
end
function R.LegacyBlocked(guild, key)
    local r, root = Latest(guild, key), Root(guild)
    if not r or not root or r.root ~= root.public then return false end
    local list = (ns.store.security.issuers or {})[U.GuildKey(guild)]
    local d = list and list[key]
    return not d or d.root ~= r.root or d.revision <= r.revision
end
local function Newer(r)
    local root, old = Root(r.guild), Latest(r.guild, r.key)
    if not root or root.public ~= r.root then return false end
    return not old or old.root ~= r.root or r.revision > old.revision
        or (r.revision == old.revision and r.issued > old.issued)
end
local function GrantAt(d, at)
    local root = d and Root(d.guild)
    if not root or d.root ~= root.public or not d.active or d.issued > at or d.expires <= at then return false end
    local old = Latest(d.guild, d.key)
    if old and old.root == d.root and old.revision >= d.revision and old.issued < at then return false end
    local list = ns.store.security.issuers[U.GuildKey(d.guild)]
    local newer = list and list[d.key]
    if newer and newer.root == d.root and not newer.active and newer.revision >= d.revision and newer.issued < at then return false end
    if newer and newer.root == d.root and newer.revision > d.revision and newer.issued < at
        and (newer.public ~= d.public or (d.scope == "leader" and newer.scope ~= "leader")) then return false end
    return Ed.ValidPublicKey(Ed.FromB64(d.public)) and Ed.Verify(Ed.FromB64(root.public), d.body, d.sig)
end
-- Дата в отзыве выбирается самим подписантом. Уже известная потеря полномочий
-- запрещает любой ещё не принятый отзыв, даже с прежней датой и старой подписью.
local function CurrentAuthority(r)
    local d, root = r.leader, Root(r.guild)
    if not root or root.public ~= r.root then return false end
    local list = ns.store.security.issuers[U.GuildKey(r.guild)]
    local latest = list and list[d.key]
    if latest and latest.root == d.root and latest.revision >= d.revision then d = latest end
    if not d.active or d.scope ~= "leader" or d.public ~= r.leader.public
        or d.expires <= ns.ServerTime() or R.Blocks(d) then return false end
    if U.GuildKey(r.guild) == U.GuildKey(ns.MyGuild()) and ns.Roster.Fresh()
        and ns.Roster.rankKnown[d.key] and ns.Roster.RankOf(d.name) ~= 0 then return false end
    return true
end
-- Архивное доказательство проверяется на момент выдачи отзыва. Истечение короткого
-- сертификата позже не возвращает уже отозванный годовой допуск новым установкам.
local function CertificateAt(c, at)
    local root = c and Root(c.guild)
    if not root or c.issued > at or c.expires <= at then return false end
    if c.issuer == root.public and U.Key(c.issuerName) == U.Key(root.name) then
        if c.delegation ~= "" then return false end
    elseif I.IsGrant(c.delegation) then
        local d = I.Read(c.delegation)
        if not d or U.GuildKey(d.guild) ~= U.GuildKey(c.guild) or d.public ~= c.issuer or d.key ~= U.Key(c.issuerName)
            or c.canIssue or c.expires > d.expires or not GrantAt(d, c.issued) then return false end
    else
        local d = S.Control.Certificate(c.delegation)
        if not d or d.delegation ~= "" or not d.canIssue or (d.role ~= "leader" and d.role ~= "officer")
            or d.issuer ~= root.public or U.Key(d.issuerName) ~= U.Key(root.name)
            or d.public ~= c.issuer or d.key ~= U.Key(c.issuerName) or U.GuildKey(d.guild) ~= U.GuildKey(c.guild)
            or c.canIssue or c.expires > d.expires or not CertificateAt(d, c.issued) then return false end
    end
    return Ed.ValidPublicKey(c.pk) and Ed.Verify(c.issuerPK, c.body, c.sig)
end
function R.Share(target, priority)
    for _, list in pairs(Store()) do
        for _, r in pairs(list) do
            local root, key = Root(r.guild), target .. ":" .. U.GuildKey(r.guild) .. ":" .. r.key
            local old = shared[key]
            local proof = Read(r.raw)
            if root and root.public == r.root and proof and CurrentAuthority(proof) and (target == "GUILD" or not old or old.raw ~= r.raw
                or ns.Now() - old.at >= C.AUTH_INTRODUCE) then
                if ns.Comm.Send(target == "GUILD" and "GUILD" or "WHISPER", proof.wire,
                    { target = target ~= "GUILD" and target or nil, prio = priority, key = "issuer-revoke:" .. key }) then
                    shared[key] = { raw = r.raw, at = ns.Now() }
                end
            end
        end
    end
end
local function Keep(r, dist)
    if not Newer(r) then return end
    local gk = U.GuildKey(r.guild)
    Store()[gk] = Store()[gk] or {}
    Store()[gk][r.key] = { raw = r.raw, guild = r.guild, key = r.key, root = r.root,
        revision = r.revision, issued = r.issued, expires = r.expires }
    ns.Fire("ISSUER_REVOCATION", r.wire, gk .. ":" .. r.key)
    if dist ~= "GUILD" then R.Share("GUILD", ns.Comm.PRIO_CONTROL) end
    if dist ~= "GUILD" and ns.Relay then
        for _, e in ipairs(ns.Relay.Candidates()) do
            if ns.Relay.TrustOf(e.name) then R.Share(e.name, true) end
        end
    end
end
local function LeaderCertificate()
    if not S.CanAdmin() or ns.Roster.MyRank() ~= 0 or ns.Roster.RankOf(ns.me) ~= 0 then return end
    local c = S.MyCertificate()
    return c and c.role == "leader" and c.rank == 0 and S.Level(c) == 3 and c or nil
end
function R.Revoke(name, archive)
    local cert, key, root = LeaderCertificate(), U.Key(name), S.MyRoot()
    local list = ns.store.security.issuers[U.GuildKey(ns.MyGuild())] or {}
    local previous = archive and Read(archive.raw)
    local d = previous and previous.grant or key and list[key]
    local leader = I.For(ns.MyGuild(), ns.myKey)
    if not cert or not root or not d or not d.active or (archive and not previous)
        or (archive and archive.expires or d.expires) <= ns.ServerTime() or d.root ~= root.public or pending[key]
        or not leader or leader.scope ~= "leader" or leader.public ~= cert.public
        or (archive and Latest(d.guild, key) ~= archive)
        or (not archive and (R.Blocks(d) or not ns.Roster.OfficerDemoted(name))) then return false end
    local body = Pack("ISSUERREVOKE", { ns.group, ns.faction, d.guild, d.name, d.public,
        d.revision, d.issued, math.max(ns.ServerTime(), archive and archive.issued + 1 or 0), "0" })
    local function Guard()
        local current = LeaderCertificate()
        return current and current.raw == cert.raw and S.MyRoot() == root and ns.MyGuild() == d.guild
            and I.For(ns.MyGuild(), ns.myKey) and I.For(ns.MyGuild(), ns.myKey).raw == leader.raw
            and (archive and Latest(d.guild, key) == archive
                or not archive and ns.Roster.OfficerDemoted(name) and not R.Blocks(d))
    end
    pending[key] = true
    local queued = S.SignControl(body, Guard, function(sig)
        pending[key] = nil
        if not sig then return end
        local r = Read(Pack("REVOKE", { body, d.raw, leader.raw, cert.raw, Ed.ToB64(sig) }))
        if r then Keep(r) end
    end)
    if not queued then pending[key] = nil end
    return queued
end
function R.Tick()
    local cert = LeaderCertificate()
    if not cert then return end
    -- Сохранённый отзыв остаётся действующим. Его новое доказательство нужно клиентам,
    -- которые уже знают о смене главы и больше не принимают старую подпись впервые.
    for _, archive in pairs(Store()[U.GuildKey(ns.MyGuild())] or {}) do
        local proof = Read(archive.raw)
        if proof and (proof.certificate.public ~= cert.public or not CurrentAuthority(proof)) then
            if R.Revoke(proof.grant.name, archive) then return end
        end
    end
    local root = S.MyRoot()
    -- Корень уже выпускает обычный подписанный KD; второго документа не требуется.
    if root and root.public == S.PublicKey() and U.Key(root.name) == ns.myKey then return end
    for _, d in pairs(ns.store.security.issuers[U.GuildKey(ns.MyGuild())] or {}) do
        if d.active and not R.Blocks(d) and ns.Roster.OfficerDemoted(d.name) then
            if R.Revoke(d.name) then return end
        end
    end
end
ns.Comm.On("KV", function(msg, sender, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if #msg > 6100 or not S.Control.Budget("issuer-revoke:" .. (U.Key(sender) or "?"), C.AUTH_NEW_PER_MIN) then return end
    local encoded = msg:match("^KV~([%w_-]+)$")
    local raw = encoded and Ed.FromB64(encoded)
    local f = raw and Unpack(raw, "REVOKE", 5, 4500)
    local target = f and I.Read(f[2])
    if target and (not Root(target.guild) or (not U.IsMemberGuild(target.guild)
        and U.GuildKey(target.guild) ~= U.GuildKey(ns.MyGuild()))) then
        -- Начальная рассылка KV может обогнать KA и установку чужого корня.
        -- Очередь лишь сохраняет байты: право отзыва проверяется после получения корня.
        for i = #waitingRoots, 1, -1 do
            if ns.Now() - waitingRoots[i].at > 30 then table.remove(waitingRoots, i)
            elseif waitingRoots[i].msg == msg then return end
        end
        if #waitingRoots >= 8 then table.remove(waitingRoots, 1) end
        waitingRoots[#waitingRoots + 1] = { msg = msg, sender = sender, dist = dist, at = ns.Now(), guild = target.guild }
        return
    end
    local r = raw and Read(raw)
    if not r or not Newer(r) or not CurrentAuthority(r) or checking[r.raw] then return end
    local count = 0; for _ in pairs(checking) do count = count + 1 end
    if count >= 16 then return end
    checking[r.raw] = true
    local queued = S.Control.Job(function()
        local d = r.grant
        if not Ed.Verify(Ed.FromB64(r.root), d.body, d.sig) or not GrantAt(r.leader, r.issued)
            or not CertificateAt(r.certificate, r.issued) then return false end
        return Ed.Verify(r.certificate.pk, r.body, r.sig)
    end, function(valid)
        checking[r.raw] = nil
        if valid and Newer(r) and CurrentAuthority(r) then Keep(r, dist) end
    end)
    if not queued then checking[r.raw] = nil end
end)
ns.On("AUTH_ROOT", function(guild)
    local previous = waitingRoots
    waitingRoots = {}
    for _, p in ipairs(previous) do
        if ns.Now() - p.at <= 30 then
            if U.GuildKey(p.guild) == U.GuildKey(guild) then ns.Comm.Dispatch(p.msg, p.sender, p.dist)
            else waitingRoots[#waitingRoots + 1] = p end
        end
    end
end)
function R.Sweep(restore)
    for gk, list in pairs(Store()) do
        for key, r in pairs(list) do
            local proof = (restore or not r.expires) and Read(r.raw)
            local expires = r.expires or proof and proof.expires
            if not expires or expires <= ns.ServerTime() then list[key] = nil
            elseif restore then
                list[key] = { raw = r.raw, guild = r.guild, key = r.key, root = r.root,
                    revision = r.revision, issued = r.issued, expires = expires }
            end
        end
        if not next(list) then Store()[gk] = nil end
    end
    for key, entry in pairs(shared) do if ns.Now() - entry.at >= C.AUTH_INTRODUCE then shared[key] = nil end end
end
