-- Signed identities, guild-approved credentials and end-to-end payload integrity.
-- Relays carry bytes; only guild authorities certify identities and permissions.
-- Корень доверия своей гильдии офицер задаёт вручную, один раз на гильдию: /cz trust init.
-- Подписанный пакет S1 несёт отпечаток сертификата автора, а сам сертификат приходит
-- отдельно (KP, по запросу — KQ) и проверяется один раз. Отметка «проверен против корня»
-- хранится в SavedVariables, поэтому после входа сертификаты не проверяются заново.
local ADDON, ns = ...
local U, C, Ed = ns.Util, ns.Config, ns.Ed25519
Ed.SLICE_MS = 2
local S = { stats = { rejected = 0, verified = 0, limited = 0 } }
ns.Security = S
local identity, keys, issuing, pending, outgoing = nil, {}, {}, {}, {}
local certCache, verifyPending, replay, cachedOpens, limits = {}, {}, {}, {}, {}
-- byFp: отпечаток → проверенный сертификат; waiting: кто ждёт сертификат по отпечатку;
-- checking: сертификаты в проверке; hints: имя корня своей гильдии со слов участника (KH),
-- пока свой корень не задан.
local byFp, waiting, checking, inflight, hints = {}, {}, {}, {}, {}
local initAsking, heardHint = nil, -1e9
local asked, introduced, served, resent = {}, {}, {}, {}
local openedHere = {}
local serial, lastHello, lastPolicy = 0, -1e9, -1e9
local lastSaid
local policySigning = {}
local policySent = {}
local lastNativeHello = -1e9
local MAX_CERT, MAX_WIRE, MAX_PENDING, FP_LEN = 1800, 7000, 32, 16

local function Store()
    return ns.store and ns.store.security
end
local function GuildKey() local g = ns.MyGuild(); return g and U.GuildKey(g) end
local function Root(guild) local s = Store(); return s and s.roots[U.GuildKey(guild)] end
local function Peer(name) return U.Key(name) or "?" end
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
-- Проверки подписей дорогие, поэтому у каждого источника своя минута: key — вид и источник
-- ("a:" автор, "h:" пересылающий, "n:" присланный сертификат), limit — сколько в минуту.
local function Budget(key, limit)
    local now = ns.Now()
    local b = limits[key]
    if not b or now - b.t >= 60 then b = { t = now, n = 0 }; limits[key] = b end
    b.n = b.n + 1
    if b.n > limit then S.stats.limited = S.stats.limited + 1; return false end
    return true
end
-- Лимит уже исчерпан? Ничего не списывает: для тех, чья принадлежность ещё не доказана.
local function Spent(key, limit)
    local b = limits[key]
    if b and ns.Now() - b.t < 60 and b.n >= limit then S.stats.limited = S.stats.limited + 1; return true end
    return false
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
    -- Отпечаток — начало подписи выдавшего: она своя у каждого тела сертификата, а
    -- поддельное тело с той же подписью не пройдёт проверку и в индекс не попадёт.
    return { raw = raw, body = f[1], sig = sig, delegation = f[3], group = p[1], faction = p[2],
        guild = p[3], name = p[4], key = U.Key(p[4]), public = p[5], pk = pk, role = p[6], rank = rank,
        issued = issued, expires = expires, issuerName = p[10], issuer = p[11], issuerPK = issuer,
        canIssue = p[12] == "1", fp = Ed.ToB64(sig:sub(1, 12)) }
end
local function Approve(c, rootPublic)
    c.approvedRoot = rootPublic
    certCache[c.raw] = c
    byFp[c.fp] = c.raw
    return c
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
    return Approve(c, root.public)
end
-- Кто ждал этот сертификат (пакет S1, RP, RR), продолжает.
local function Wake(c)
    local list = waiting[c.fp]
    if not list then return end
    waiting[c.fp] = nil
    for _, fn in ipairs(list) do ns.SafeCall("certificate wait", fn, c) end
end
-- Сертификата с этим отпечатком нет: подождать и, если он ещё не проверяется, попросить
-- его у того, кто прислал пакет (KQ). Тот только что сам проверял пакет — сертификат у него есть.
-- Пакет пришёл по GUILD — и просьба по GUILD: так всей гильдии хватает одного ответа.
local function Await(fp, sender, fn, viaGuild)
    local list = waiting[fp]
    if not list then
        local total = 0; for _ in pairs(waiting) do total = total + 1 end
        if total >= MAX_PENDING then S.stats.limited = S.stats.limited + 1; return false end
        list = { at = ns.Now() }
        waiting[fp] = list
    end
    if #list >= 8 then return false end
    list[#list + 1] = fn
    local key, now = (viaGuild and "GUILD" or Peer(sender)) .. "|" .. fp, ns.Now()
    if sender and not inflight[fp] and not ns.IsMe(sender) and (not asked[key] or now - asked[key] >= 10) then
        asked[key] = now
        if viaGuild then
            ns.Comm.Send("GUILD", "KQ~" .. fp, { prio = true, key = "kq:" .. key })
        else
            ns.Comm.Send("WHISPER", "KQ~" .. fp, { target = sender, prio = true, key = "kq:" .. key })
        end
    end
    return true
end
local function Keep(c)
    if not c.approvedRoot or not Current(c) then return end
    Wake(c)
    local s, gk = Store(), U.GuildKey(c.guild)
    s.certs[gk] = s.certs[gk] or {}
    s.verified[gk] = s.verified[gk] or {}
    local old = s.certs[gk][c.key]
    local previous = old and Certificate(old)
    if previous and previous.issued > c.issued then return end
    s.certs[gk][c.key], s.verified[gk][c.key] = c.raw, c.approvedRoot
    if c.canIssue and c.delegation == "" and (c.role == "leader" or c.role == "officer") then
        s.delegations[gk] = s.delegations[gk] or {}
        s.delegations[gk][c.key], s.verified[gk]["@" .. c.key] = c.raw, c.approvedRoot
    end
    ns.Fire("CREDENTIAL", c)
end
-- owner — чей это должен быть сертификат; from — кто его прислал (с него и лимит проверок).
function S.CheckCertificate(raw, owner, done, from)
    local c = Certificate(raw)
    if not c or not Current(c) or (owner and c.key ~= U.Key(owner)) then return false end
    if c.approvedRoot == Root(c.guild).public then Keep(c); done(c); return true end
    local waiters = checking[raw]
    if waiters then
        if #waiters < 4 then waiters[#waiters + 1] = done end
        return true
    end
    local count = 0; for _ in pairs(checking) do count = count + 1 end
    if count >= MAX_PENDING then S.stats.limited = S.stats.limited + 1; return false end
    -- Свой сертификат — отдельно: при первой выдаче все KP идут от одного офицера, и чужие
    -- сертификаты не должны вытеснять мой (повторно его не выдадут до продления).
    local own = c.key == ns.myKey and identity ~= nil and c.public == identity.public
    if not Budget(own and "own" or "n:" .. Peer(from or owner or c.name), C.AUTH_NEW_PER_MIN) then return false end
    checking[raw], inflight[c.fp] = { done }, true
    local accepted = Job(function() return VerifyCertificate(raw) end, function(valid)
        local callbacks = checking[raw] or {}
        checking[raw], inflight[c.fp] = nil, nil
        if not valid or not Current(valid) then S.stats.rejected = S.stats.rejected + 1; return end
        Keep(valid)
        for _, fn in ipairs(callbacks) do fn(valid) end
    end)
    if not accepted then checking[raw], inflight[c.fp] = nil, nil end
    return accepted
end
-- fn(c) — когда известен проверенный действующий сертификат с этим отпечатком: сразу или
-- после того, как sender ответит на KQ. owner — чей это должен быть сертификат.
function S.Resolve(fp, owner, sender, fn)
    if type(fp) ~= "string" or #fp ~= FP_LEN then return false end
    local function Use(c)
        if c and c.approvedRoot and Current(c) and (not owner or c.key == U.Key(owner)) then fn(c) end
    end
    local raw = byFp[fp]
    if raw then Use(Certificate(raw)); return true end
    return Await(fp, sender, Use)
end
function S.Fingerprint(raw)
    local c = raw and Certificate(raw)
    return c and c.fp
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
    hints[gk] = nil
    if gk == GuildKey() then ShareRoot(guild, s.roots[gk]) end
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
        Keep(Approve(c, root.public))
        -- Корень — раньше сертификата: без корня новичок отбросит KP, а повторно его не выдадут.
        ShareRoot(root.guild, root)
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
-- Свой сертификат гильдии — при смене и раз в AUTH_ANNOUNCE; в промежутке его по запросу
-- (KQ) отдаёт автор, а новые сертификаты рассылает выдавший их офицер.
function S.Say()
    if not identity or not ns.IsMember() or not ns.Roster.Fresh() then return end
    lastHello = ns.Now()
    keys[ns.myKey] = { name = ns.me, public = identity.public }
    local mine = S.MyCertificate()
    -- "~0": сертификата у меня нет. Издатель, у которого он уже есть, пришлёт его шёпотом.
    ns.Comm.Send("GUILD", "K1~" .. identity.public .. (mine and "" or "~0"), { key = "identity" })
    if mine and (not lastSaid or lastSaid.raw ~= mine.raw or lastHello - lastSaid.at >= C.AUTH_ANNOUNCE) then
        lastSaid = { raw = mine.raw, at = lastHello }
        ns.Comm.Send("GUILD", "KP~" .. Ed.ToB64(mine.raw), { key = "my-credential" })
    end
end
-- Сертификат (по умолчанию свой) уходит получателю раньше подписанного пакета: в самом
-- пакете только отпечаток. Одному получателю — раз в AUTH_INTRODUCE. target "GUILD" — своя гильдия.
-- force — без этого предела: получатель сам попросил всё заново (Q1), прежний KP он мог
-- отбросить, пока не знал корня гильдии автора.
function S.Introduce(target, raw, force)
    if not raw then
        local mine = S.MyCertificate()
        raw = mine and mine.raw
    end
    local c = raw and Certificate(raw)
    if not c or not c.approvedRoot or not target then return end
    local key, now = (target == "GUILD" and "GUILD" or Peer(target)) .. "|" .. c.fp, ns.Now()
    if not force and introduced[key] and now - introduced[key] < C.AUTH_INTRODUCE then return end
    introduced[key] = now
    local wire = "KP~" .. Ed.ToB64(raw)
    if target == "GUILD" then
        ns.Comm.Send("GUILD", wire, { prio = true, key = "kp:" .. key })
    else
        ns.Comm.Send("WHISPER", wire, { target = target, prio = true, key = "kp:" .. key })
    end
end
-- То же для готового пакета S1: сертификат его автора, если он у меня есть.
function S.IntroduceWire(target, wire, force)
    local fp = type(wire) == "string" and wire:match("^S1~([%w_-]+)~")
    local raw = fp and byFp[fp]
    if raw then S.Introduce(target, raw, force) end
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
    s.roots[gk], s.certs[gk], s.delegations[gk], s.policies[gk], s.verified[gk] = nil, nil, nil, nil, nil
    for raw, c in pairs(certCache) do
        if U.GuildKey(c.guild) == gk then certCache[raw], byFp[c.fp] = nil, nil end
    end
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
-- Корень доверия своей гильдии: ключ этого офицера. Задаётся вручную один раз на гильдию;
-- остальные офицеры и участники получают его через KT. Сначала гильдия спрашивается (KR):
-- офицер с корнем отвечает KT, участник с корнем — именем корня (KH). Через INIT_WAIT секунд
-- корень задаётся, если никто не ответил. force — не смотреть на ответы участников (корень
-- мог быть подделан или его ключ утерян). report(text) — что сказать игроку. Возвращает,
-- начат ли опрос.
local INIT_WAIT = 10
function S.Init(force, report)
    report = report or function() end
    local L, guild = ns.L, ns.MyGuild()
    if not S.CanAdmin() or not guild then report(L.AUTH_NEED_OFFICER); return false end
    local gk, root = U.GuildKey(guild), Root(guild)
    if root then report(L.AUTH_INIT_DONE:format(U.Display(root.name))); return false end
    if not identity or ns.Now() - ns.loginAt < 20 or initAsking then report(L.AUTH_INIT_WAIT); return false end
    local retired = Store().retired[gk]
    if retired and retired[identity.public] then
        -- Мой ключ уже был корнем и сброшен: нужен новый ключ.
        StartIdentity(true)
        report(L.AUTH_INIT_WAIT)
        return false
    end
    initAsking, hints[gk] = true, nil
    ns.Comm.Send("GUILD", "KR~", { prio = true, key = "root-query" })
    report(L.AUTH_INIT_ASK)
    ns.After(INIT_WAIT, "trust init", function()
        initAsking = nil
        local now = Root(guild)
        if now then report(L.AUTH_INIT_DONE:format(U.Display(now.name))); return end
        if GuildKey() ~= gk or not S.CanAdmin() or not identity then report(L.AUTH_NEED_OFFICER); return end
        if hints[gk] and not force then report(L.AUTH_INIT_HINT:format(U.Display(hints[gk]))); return end
        if Pin(guild, U.Display(ns.me), identity.public) then report(L.AUTH_INIT_OK) else report(L.AUTH_NEED_OFFICER) end
    end)
    return true
end
ns.Comm.On("KR", function(_, sender, dist)
    if dist ~= "GUILD" or not NativeRole(sender) or ns.IsMe(sender) then return end
    local root = Root(ns.MyGuild())
    if not root then return end
    if S.CanAdmin() then ShareRoot(root.guild, root); return end
    -- Участников много, ответа хватит одного: случайная пауза, и кто услышал чужой — молчит.
    ns.After(math.random() * 3, "root hint", function()
        if ns.Now() - heardHint < INIT_WAIT or Root(ns.MyGuild()) ~= root then return end
        heardHint = ns.Now()
        ns.Comm.Send("GUILD", "KH~" .. root.name, { key = "root-hint" })
    end)
end)
ns.Comm.On("KH", function(msg, sender, dist)
    if dist ~= "GUILD" or not NativeRole(sender) then return end
    heardHint = ns.Now()
    local name, gk = msg:match("^KH~(.+)$"), GuildKey()
    if name and Name(name) and gk and not Root(ns.MyGuild()) then hints[gk] = name end
end)
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
    if #msg > 3000 or not Budget("n:" .. Peer(sender), C.AUTH_NEW_PER_MIN) then return end
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
    S.Introduce(name)
    ns.Print(ns.L.AUTH_PAIRED, U.Display(name), p.guild)
    return true
end
ns.Comm.On("KL", function(msg, sender, dist)
    if dist ~= "WHISPER" or not S.CanAdmin() or not Budget("l:" .. Peer(sender), 30) then return end
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
            S.Introduce(sender)
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
    local public, flag = msg:match("^K1~([%w_-]+)(.*)$")
    if flag ~= "" and flag ~= "~0" then return end
    local raw = Ed.FromB64(public)
    if not raw or #raw ~= 32 then return end
    local k = U.Key(sender)
    keys[k] = { name = sender, public = public }
    -- У участника нет сертификата, а у меня, активного издателя, он есть: первый KP до него
    -- не дошёл (лимит, ещё не было корня). Issue свежий сертификат заново не выдаёт.
    if flag == "~0" and Authority() and (not resent[k] or ns.Now() - resent[k] >= 60) then
        local held = S.Member(ns.MyGuild(), sender)
        if held and held.public == public then
            resent[k] = ns.Now()
            ns.Comm.Send("WHISPER", "KP~" .. Ed.ToB64(held.raw), { target = sender, prio = true, key = "kp-own:" .. k })
        end
    end
    -- A reload has the same native name as the old peer. Answer its identity
    -- announcement so it learns the officer reporter before accepting RG, and
    -- the guild root before an officer would think of /cz trust init.
    if S.CanAdmin() and ns.Now() - lastNativeHello >= 5 then
        lastNativeHello = ns.Now()
        local root = Root(ns.MyGuild())
        if root then ShareRoot(root.guild, root) end
        if ns.Census then ns.Census.SendHello() end
    end
end)
ns.Comm.On("KP", function(msg, sender, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if dist == "GUILD" and not NativeRole(sender) then return end
    local raw = msg:match("^KP~([%w_-]+)$")
    raw = raw and Ed.FromB64(raw)
    if not raw then return end
    S.CheckCertificate(raw, nil, function(c)
        if c.key == U.Key(sender) then ns.Fire("AUTH_PEER", c, sender) end
    end, sender)
end)
-- Запрос сертификата по отпечатку. Шёпотом отвечает любой, у кого он проверен. В гильдии —
-- только владелец или репортёр (они и шлют в гильдию подписанные пакеты), один KP на всех.
ns.Comm.On("KQ", function(msg, sender, dist)
    if dist ~= "WHISPER" and dist ~= "GUILD" then return end
    local fp = msg:match("^KQ~([%w_-]+)$")
    if not fp or #fp ~= FP_LEN then return end
    local now = ns.Now()
    if dist == "GUILD" then asked["GUILD|" .. fp] = now end -- уже спросили и за меня
    local raw = byFp[fp]
    local c = raw and Certificate(raw)
    if not c then return end
    local key = (dist == "GUILD" and "GUILD" or Peer(sender)) .. "|" .. fp
    if served[key] and now - served[key] < 30 then return end
    if dist == "GUILD" then
        if c.key ~= ns.myKey and not (ns.Census and ns.Census.IsReporter()) then return end
        served[key] = now
        ns.Comm.Send("GUILD", "KP~" .. Ed.ToB64(raw), { prio = true, key = "kp:" .. key })
        return
    end
    if not Budget("q:" .. Peer(sender), 20) then return end
    served[key] = now
    ns.Comm.Send("WHISPER", "KP~" .. Ed.ToB64(raw), { target = sender, prio = true, key = "kp:" .. key })
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
        local wire = "S1~" .. c.fp .. "~" .. at .. "~" .. sequence .. "~" .. Ed.ToB64(sig) .. "~" .. inner
        if #wire <= MAX_WIRE then done(wire) end
    end)
end
-- sender — от кого пришёл пакет (автор или пересылающий): с него лимит и у него KQ.
-- viaGuild — пакет пришёл по GUILD.
function S.Open(wire, sender, done, viaGuild)
    if type(wire) ~= "string" or #wire > MAX_WIRE then return false end
    local fp, at, seq, signature, inner = wire:match("^S1~([%w_-]+)~(%d+)~(%d+)~([%w_-]+)~(.+)$")
    local stamp, sequence = Int(at, 1, 4102444800), Int(seq, 1, 9007199254740991)
    local sig = signature and Ed.FromB64(signature)
    if not fp or #fp ~= FP_LEN or not stamp or not sequence or not sig or #sig ~= 64 then return false end
    local kind = inner:sub(1, 2)
    local guild = inner:match("^M1~[ACL]~([^~]+)~") or inner:match("^R1~([^~]+)~")
    if (kind ~= "M1" and kind ~= "R1") or not guild then return false end
    local function Check(c)
        local now = ns.ServerTime()
        if not c or not c.approvedRoot or not Current(c) or U.GuildKey(guild) ~= U.GuildKey(c.guild) or stamp > now + 30
            or now - stamp > (kind == "M1" and C.CHAT_DEDUPE or C.TOTAL_KEEP) then return false end
        local tier = inner:match("^M1~([ACL])~")
        if tier and S.Level(c) < ({ A = 1, C = 2, L = 3 })[tier] then return false end
        local cached = cachedOpens[wire]
        if cached and cached.root == c.approvedRoot then done(cached.inner, cached.cert, wire); return true end
        local waiters = verifyPending[wire]
        if waiters then
            if #waiters < 4 then waiters[#waiters + 1] = done end
            return true
        end
        local count = 0; for _ in pairs(verifyPending) do count = count + 1 end
        if count >= MAX_PENDING then S.stats.limited = S.stats.limited + 1; return false end
        -- Сертификат уже проверен, осталась одна подпись. Лимит — на автора и отдельно,
        -- выше, на пересылающего: через реле и репортёра идут сообщения многих авторов.
        -- Пересылающий платит сразу. Автор — только за верную подпись: отпечаток публичен,
        -- и подделки с чужим отпечатком не должны выбирать лимит настоящего автора.
        if Spent("a:" .. c.key, C.AUTH_AUTHOR_PER_MIN) or not Budget("h:" .. Peer(sender), C.AUTH_HOP_PER_MIN) then return false end
        verifyPending[wire] = { done }
        local body = Pack("MESSAGE", { ns.group, ns.faction, c.raw, at, seq, inner })
        local accepted = Job(function() return Ed.Verify(c.pk, body, sig) end, function(valid)
            local callbacks = verifyPending[wire] or {}
            verifyPending[wire] = nil
            if not valid or not Current(c) then S.stats.rejected = S.stats.rejected + 1; return end
            if not Budget("a:" .. c.key, C.AUTH_AUTHOR_PER_MIN) then return end
            local id = c.public .. ":" .. c.key .. ":" .. seq
            local later = ns.ServerTime()
            if kind == "M1" then
                if replay[id] and (replay[id].signature ~= signature or not openedHere[id]) then return end
                local used = 0
                for _, entry in pairs(replay) do if later - entry.at <= C.CHAT_DEDUPE then used = used + 1 end end
                if not replay[id] and used >= 2048 then S.stats.limited = S.stats.limited + 1; return end
                replay[id] = { signature = signature, at = stamp }
                openedHere[id] = true
            end
            local retained = 0; for _ in pairs(cachedOpens) do retained = retained + 1 end
            if retained >= 256 then
                local oldest, time
                for key, entry in pairs(cachedOpens) do if not time or entry.at < time then oldest, time = key, entry.at end end
                cachedOpens[oldest] = nil
            end
            Keep(c)
            cachedOpens[wire] = { cert = c, inner = inner, at = later, root = c.approvedRoot }
            S.stats.verified = S.stats.verified + 1
            for _, callback in ipairs(callbacks) do callback(inner, c, wire) end
        end)
        if not accepted then verifyPending[wire] = nil end
        return accepted
    end
    local raw = byFp[fp]
    if raw then return Check(Certificate(raw)) end
    return Await(fp, sender, Check, viaGuild)
end
ns.Comm.On("S1", function(wire, sender, dist)
    if dist ~= "GUILD" or not NativeRole(sender) then return end
    S.Open(wire, sender, function(inner, c)
        if c.key ~= U.Key(sender) or U.GuildKey(c.guild) ~= GuildKey() then return end
        ns.Comm.Dispatch(inner, c.name, "GUILD", { authenticated = true, certificate = c, wire = wire })
    end, true)
end)
-- Сертификаты и делегирования на диске: при входе (restore) отметки проверки снимаются
-- без криптографии; в остальное время — уборка истёкшего. Сертификат без отметки или
-- с отметкой другого корня выбрасывается: заново он придёт от выдавшего или по KQ.
local function Sweep(restore)
    local s, now = Store(), ns.ServerTime()
    for _, part in ipairs({ { s.certs, "" }, { s.delegations, "@" } }) do
        local lists, prefix = part[1], part[2]
        for gk, list in pairs(lists) do
            local root, marks = s.roots[gk], s.verified[gk] or {}
            for key, raw in pairs(list) do
                local c = Certificate(raw)
                if not c or not root or marks[prefix .. key] ~= root.public or c.expires <= now then
                    list[key], marks[prefix .. key] = nil, nil
                elseif restore then
                    Approve(c, root.public)
                end
            end
            if next(list) == nil then lists[gk] = nil end
        end
    end
    for gk, marks in pairs(s.verified) do
        for key in pairs(marks) do
            local plain = key:gsub("^@", "")
            local list = (plain ~= key and s.delegations or s.certs)[gk]
            if not list or not list[plain] then marks[key] = nil end
        end
        if next(marks) == nil then s.verified[gk] = nil end
    end
    for gk, p in pairs(s.policies) do
        if type(p) ~= "table" or type(p.expires) ~= "number" or p.expires <= now then s.policies[gk] = nil end
    end
end
local function Tick()
    if not identity or not ns.IsMember() or not ns.Roster.Fresh() then return end
    local now = ns.Now()
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
    s.verified = type(s.verified) == "table" and s.verified or {}
    s.replay = type(s.replay) == "table" and s.replay or {}
    replay = s.replay
    for id, entry in pairs(replay) do
        if type(entry) ~= "table" or type(entry.at) ~= "number" or ns.ServerTime() - entry.at > C.CHAT_DEDUPE then replay[id] = nil end
    end
    StartIdentity(false)
    Sweep(true)
    ns.Every(5, "security maintenance", Tick)
    ns.Every(60, "security gc", function()
        local now, clock = ns.ServerTime(), ns.Now()
        Sweep(false)
        for wire, entry in pairs(cachedOpens) do if now - entry.at > 120 then cachedOpens[wire] = nil end end
        for id, entry in pairs(replay) do if now - entry.at > C.CHAT_DEDUPE then replay[id], openedHere[id] = nil, nil end end
        for key, p in pairs(pending) do if clock > p.untilAt then pending[key] = nil end end
        for key, p in pairs(outgoing) do if clock > p.untilAt then outgoing[key] = nil end end
        for raw, c in pairs(certCache) do if c.expires <= now then certCache[raw] = nil end end
        for fp, raw in pairs(byFp) do if not certCache[raw] then byFp[fp] = nil end end
        for fp, list in pairs(waiting) do if clock - list.at > 30 then waiting[fp] = nil end end
        for key, b in pairs(limits) do if clock - b.t >= 60 then limits[key] = nil end end
        for key, t in pairs(asked) do if clock - t >= 60 then asked[key] = nil end end
        for key, t in pairs(served) do if clock - t >= 60 then served[key] = nil end end
        for key, t in pairs(resent) do if clock - t >= 60 then resent[key] = nil end end
        for key, t in pairs(introduced) do if clock - t >= C.AUTH_INTRODUCE then introduced[key] = nil end end
    end)
end)
ns.On("GUILD_CHANGED", function()
    keys, issuing, pending, outgoing, hints = {}, {}, {}, {}, {}
    lastHello, lastPolicy, lastSaid = -1e9, -1e9, nil
    S.Say()
end)
ns.Command("link", function(name)
    if not S.Link(U.Trim(name)) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
end, "соединить гильдии: /cz link Имя Фамилия (глава или офицер)")
ns.Command("accept", function(name)
    if not S.Accept(U.Trim(name)) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
end, "подтвердить проверенное имя: /cz accept Имя Фамилия")
ns.Command("trust", function(arg)
    local cmd, rest = U.Trim(arg or ""):match("^(%S*)%s*(.-)$")
    cmd, rest = U.Fold(cmd or ""), U.Trim(rest or "")
    if cmd == "init" then
        S.Init(U.Fold(rest) == "force", function(text) ns.Print("%s", text) end)
    elseif cmd == "reset" and rest ~= "" then
        if not S.Reset(rest) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
    else
        local list = {}
        for _, root in pairs(S.Roots()) do list[#list + 1] = root end
        table.sort(list, function(a, b) return U.GuildKey(a.guild) < U.GuildKey(b.guild) end)
        if #list == 0 then ns.Print(ns.L.AUTH_NO_ROOTS) end
        for _, root in ipairs(list) do ns.Print(ns.L.AUTH_ROOT_LINE, root.guild, U.Display(root.name)) end
    end
end, "доверие: /cz trust — корни; /cz trust init — задать корень своей гильдии (один раз); /cz trust reset Гильдия — после утраты ключа")
ns.Status(function()
    return ns.L.AUTH_STATUS:format(S.MyCertificate() and ns.L.YES or ns.L.NO, S.stats.verified, S.stats.rejected)
end)
