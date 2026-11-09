-- Chillzone: ключи игроков, сертификаты от их гильдий и подпись пакетов от автора до получателя.
-- Реле только переносят байты; ключи и права заверяют только глава и офицеры гильдии.
-- Корень доверия своей гильдии офицер задаёт вручную, один раз на гильдию: /chillzone trust init.
-- Состав объединения и его изменения подписывает только текущий глава главной гильдии.
-- Подписанный пакет S1 несёт отпечаток сертификата автора, а сам сертификат приходит
-- отдельно (KP, по запросу — KQ) и проверяется один раз. Отметка «проверен против корня»
-- хранится в SavedVariables, поэтому после входа сертификаты не проверяются заново.
local ADDON, ns = ...
local U, C, Ed = ns.Util, ns.Config, ns.Ed25519
Ed.SLICE_MS = 2
local S = { stats = { rejected = 0, verified = 0, limited = 0 } }
ns.Security = S
local identity, keys, issuing, pending, outgoing = nil, {}, {}, {}, {}
local acceptedLinks = {} -- подтверждённые запросы: повтор ответа при потере пакета, без второго accept
local certCache, verifyPending, replay, cachedOpens, limits = {}, {}, {}, {}, {}
-- byFp: отпечаток → проверенный сертификат; waiting: кто ждёт сертификат по отпечатку;
-- checking: сертификаты в проверке; hints: имя корня своей гильдии со слов участника (KH),
-- пока свой корень не задан.
local byFp, waiting, checking, inflight, hints = {}, {}, {}, {}, {}
local initAsking, heardHint = nil, -1e9
local asked, introduced, served, resent = {}, {}, {}, {}
local openedHere = {}
local sealed = {} -- [пакет S1] = { inner, cert, at }: подписанное мной недавно (S.Own)
local serial, lastHello, lastPolicy = 0, -1e9, -1e9
local lastSaid
local policySigning = {}
local policySent = {}
local pendingPolicies = {}
local lastLegacyProbe = -1e9
local lastNativeHello = -1e9
local nativeTrustPending = false
local nativeUnionPending = false
local nativeUnionBootstrap = false
local unionQueries = {}
local unionQueryAt, unionQueryDelay = -1e9, 0
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
-- Общие канонические поля и очередь криптографии для отдельных допусков и ключа управления.
S.Control = { Pack = Pack, Unpack = Unpack, Job = Job, Budget = Budget }
function S.PublicKey() return identity and identity.public end
function S.SignControl(body, guard, done)
    local saved = identity
    if not saved or not guard() then return false end
    return Job(function() return Ed.Sign(saved.seed, body, saved.pk) end, function(sig)
        done(sig and saved == identity and guard() and sig or nil)
    end)
end
function S.CanAdmin()
    -- Свой корень нужен и гильдии, которая только просит подключить её к объединению.
    return ns.MyGuild() ~= nil and ns.Roster.Fresh() and ns.Roster.IsOfficerRank(ns.Roster.MyRank())
end
function S.CanManageUnion()
    return U.IsMainGuild(ns.MyGuild()) and ns.Roster.Fresh() and ns.Roster.MyRank() == 0
        and ns.Roster.RankOf(ns.me) == 0
end
function S.CanSignUnion()
    local owner = ns.UnionAuthority and ns.UnionAuthority.Current()
    return S.CanManageUnion() and owner ~= nil and owner.public == S.PublicKey()
end
function S.UnionDenied()
    return S.CanManageUnion() and ns.L.UNION_KEY_REQUIRED or ns.L.UNION_ONLY_LEADER
end
-- Офицеру гильдии вне объединения доступен только запрос связи. Главная гильдия всегда в объединении.
function S.CanRequestUnion()
    return S.CanAdmin() and not ns.IsMember()
end
local function LocalOrMember(guild)
    return U.IsMemberGuild(guild) or U.GuildKey(guild) == GuildKey()
end
local function GuildName(guild)
    return type(guild) == "string" and guild ~= "" and #guild <= 96 and guild == U.Trim(guild)
        and not guild:find("[~|%c]") and not ns.Codec.LongGuild(guild)
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
    if p[1] ~= ns.group or p[2] ~= ns.faction or not LocalOrMember(p[3]) or not Name(p[4])
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
S.Control.Certificate = Certificate
local function Approve(c, rootPublic)
    c.approvedRoot = rootPublic
    certCache[c.raw] = c
    byFp[c.fp] = c.raw
    return c
end
local function Current(c)
    local root = c and Root(c.guild)
    local now = ns.ServerTime()
    if not root or not LocalOrMember(c.guild) or c.expires <= now or c.issued > now + 30 then return false end
    if c.approvedRoot and c.approvedRoot ~= root.public then return false end
    local s = Store()
    local list = s.certs[U.GuildKey(c.guild)]
    local newer = list and list[c.key] and Certificate(list[c.key])
    if newer and newer.issued > c.issued and (newer.public ~= c.public or newer.role ~= c.role or newer.rank ~= c.rank) then return false end
    if c.delegation ~= "" then
        if ns.Issuers and ns.Issuers.IsGrant(c.delegation) then
            if not ns.Issuers.Current(c.delegation) then return false end
        else
            local d = Certificate(c.delegation)
            if not d or d.delegation ~= "" or d.issuer ~= root.public or not Current(d)
                or (ns.Issuers and not ns.Issuers.LegacyAllowed(d)) then return false end
        end
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
        if ns.Issuers and ns.Issuers.IsGrant(c.delegation) then
            local d = ns.Issuers.Verify(c.delegation)
            if not d or U.GuildKey(d.guild) ~= U.GuildKey(c.guild) or d.public ~= c.issuer
                or d.key ~= U.Key(c.issuerName) or c.canIssue or c.expires > d.expires then return end
        else
            -- Прежнее недельное делегирование принимается при постепенном обновлении.
            local d = Certificate(c.delegation)
            if not Current(d) or not d.canIssue or (d.role ~= "leader" and d.role ~= "officer") or d.delegation ~= ""
                or U.GuildKey(d.guild) ~= U.GuildKey(c.guild) or d.public ~= c.issuer or d.key ~= U.Key(c.issuerName)
                or d.issuer ~= root.public or U.Key(d.issuerName) ~= U.Key(root.name) or c.canIssue
                or c.expires > d.expires or not Ed.Verify(d.issuerPK, d.body, d.sig) then return end
        end
    end
    if not Ed.ValidPublicKey(c.pk) or not Ed.Verify(c.issuerPK, c.body, c.sig) then return end
    -- Проверка подписи растянута на кадры: корень и делегирование должны быть в силе и при
    -- записи результата, а не только в начале проверки.
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
function S.MyCertificate()
    local g = ns.MyGuild()
    local c = g and S.Member(g, ns.me)
    return c and identity and c.public == identity.public and c or nil
end
-- Отсутствие сертификата не означает отсутствие корня: повторный init здесь не поможет.
local function CertificateWait(root)
    if identity and U.Key(root.name) == ns.myKey then
        if root.public ~= identity.public then return ns.L.AUTH_ROOT_KEY_CHANGED end
        if S.CanAdmin() then return ns.L.AUTH_CERT_PENDING end
    end
    return ns.L.AUTH_CERT_WAIT:format(U.Display(root.name))
end
function S.NotReadyReason()
    local guild = ns.MyGuild()
    local root = guild and Root(guild)
    return root and CertificateWait(root) or ns.L.AUTH_NOT_READY
end
-- priority: корень перед сертификатом уходит с приоритетом сертификата и прямо перед ним
-- (ещё не отправленное объявление того же корня поднимается в очереди). Без priority —
-- фоновое повторное объявление, которое не обгоняет чат.
-- before — ключ сертификата: KT должен обогнать и уже ожидающий или отправляемый KP.
local function ShareRoot(guild, root, priority, before)
    if root and S.CanAdmin() then
        ns.Comm.Send("GUILD", "KT~" .. guild .. "~" .. root.name .. "~" .. root.public,
            { prio = priority, key = "root:" .. U.GuildKey(guild), before = before, guard = S.CanAdmin })
    end
end
-- Снять с ключа public отметку об отзыве (см. Forget).
local function Unretire(gk, public)
    local list = Store().retired[gk]
    if not list or not list[public] then return end
    list[public] = nil
    if next(list) == nil then Store().retired[gk] = nil end
end
-- Задать корень гильдии guild. Отозванный ключ (/chillzone trust reset) из каталога, от офицеров
-- (KT) и т. п. не принимается; confirmed — его явно подтвердил офицер здесь же
-- (/chillzone accept или ответ на свой /chillzone link): тогда отметка об отзыве снимается.
local function Pin(guild, name, public, confirmed, trustedRoot)
    if not GuildName(guild) or not Name(name) then return false end
    if not LocalOrMember(guild) and not trustedRoot and not (confirmed and S.CanManageUnion()) then return false end
    local pk = Ed.FromB64(public)
    if not pk or #pk ~= 32 then return false end
    local s, gk = Store(), U.GuildKey(guild)
    local old = s.roots[gk]
    if old and (old.public ~= public or U.Key(old.name) ~= U.Key(name)) then return false end
    if s.retired[gk] and s.retired[gk][public] then
        if not confirmed then return false end
        Unretire(gk, public)
    end
    if old then return true end
    s.roots[gk] = { name = name, public = public, guild = guild }
    hints[gk] = nil
    if gk == GuildKey() then ShareRoot(guild, s.roots[gk], ns.Comm.PRIO_BOOTSTRAP) end
    ns.Fire("AUTH_ROOT", guild)
    return true
end
local function Authority()
    if not identity or not S.CanAdmin() then return end
    local root = Root(ns.MyGuild())
    if not root then return end
    -- Онлайн в ростере не означает работающий аддон. Издатель должен недавно объявить
    -- именно подтверждённый ключ; иначе запасные навсегда уступят молчащему персонажу.
    -- Делегирование хранится отдельно от часто продлеваемого подтверждения звания.
    local delegations = Store().delegations[GuildKey()] or {}
    local best, bestIsRoot
    for _, row in ipairs(ns.Roster.members) do
        local peer = keys[row.key]
        if row.online and ns.Roster.IsOfficerRank(row.rank) and peer
            and ns.Now() - peer.at <= C.PEER_WINDOW then
            local isRoot = row.key == U.Key(root.name) and peer.public == root.public
            local grant = ns.Issuers and ns.Issuers.For(ns.MyGuild(), row.key)
            local d = delegations[row.key] and Certificate(delegations[row.key])
            if isRoot or (grant and grant.public == peer.public)
                or (d and ns.Issuers.LegacyAllowed(d) and d.canIssue and d.public == peer.public and Current(d) and d.approvedRoot == root.public) then
                if not best or (isRoot and not bestIsRoot) or (isRoot == bestIsRoot and row.key < best) then
                    best, bestIsRoot = row.key, isRoot
                end
            end
        end
    end
    if best ~= ns.myKey then return end
    if root and root.public == identity.public and U.Key(root.name) == ns.myKey then return root, "" end
    local grant = ns.Issuers and ns.Issuers.For(ns.MyGuild(), ns.myKey)
    if grant and grant.public == identity.public then return root, grant.raw end
    local mine = delegations[ns.myKey] and Certificate(delegations[ns.myKey])
    if mine and ns.Issuers.LegacyAllowed(mine) and Current(mine) and mine.public == identity.public and mine.issuer == root.public then return root, mine.raw end
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
    if delegation ~= "" then
        local d = (ns.Issuers and ns.Issuers.Read(delegation)) or Certificate(delegation)
        expires = math.min(expires, d.expires)
    end
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
        local queuedKey = "credential:" .. key
        ShareRoot(root.guild, root, true, queuedKey)
        ns.Comm.Send("GUILD", "KP~" .. Ed.ToB64(raw), { prio = true, key = queuedKey, guard = S.CanAdmin })
    end)
    if not started then issuing[key] = nil end
    return started
end
-- Сколько ещё сертификатов издатель может поставить в очередь (C.AUTH_ISSUE_QUEUE): и
-- подписываемые сейчас, и ждущие отправки, в том числе повторные шёпотом.
local function IssueRoom()
    local busy = ns.Comm.Queued("credential:") + ns.Comm.Queued("kp-own:")
    for _ in pairs(issuing) do busy = busy + 1 end
    return C.AUTH_ISSUE_QUEUE - busy
end
local function Entropy()
    -- Тот же компромисс, что в Olympus: смесь местных замеров, а НЕ криптостойкий генератор ОС.
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
    for _, key in pairs(ns.db.securityKeys) do key.pk = nil end
    identity = nil
    Job(function() return Ed.PublicKey(seed) end, function(pk)
        if not pk or ns.db.securityKeys[scope] ~= saved then return end
        saved.public = Ed.ToB64(pk)
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
    if not identity or not ns.MyGuild() or not ns.Roster.Fresh() then return end
    local needUnion = lastHello < 0 or not ns.IsMember() or not Store().owner
    lastHello = ns.Now()
    keys[ns.myKey] = { name = ns.me, public = identity.public, at = lastHello }
    local mine = S.MyCertificate()
    -- K1 понимает и 0.8; новый запрос состава идёт отдельно, чтобы старый издатель не потерял ключ.
    -- UQ раньше K1: приоритетный каталог не должен прерывать уже начатую выдачу KP.
    if needUnion and lastHello >= unionQueryAt then
        ns.Comm.Send("GUILD", "UQ~1", { prio = unionQueryDelay == 0 and ns.Comm.PRIO_BOOTSTRAP or true, key = "union-query" })
        unionQueryDelay = math.min(3600, math.max(60, unionQueryDelay * 2))
        unionQueryAt = lastHello + unionQueryDelay
    elseif not needUnion then unionQueryAt, unionQueryDelay = -1e9, 0 end
    ns.Comm.Send("GUILD", "K1~" .. identity.public .. (mine and "" or "~0"),
        { prio = ns.Comm.PRIO_BOOTSTRAP, key = "identity" })
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
    local queuedKey = "kp:" .. key
    if target == "GUILD" then
        ShareRoot(c.guild, Root(c.guild), true, queuedKey)
        ns.Comm.Send("GUILD", wire, { prio = true, key = queuedKey })
    else
        ns.Comm.Send("WHISPER", wire, { target = target, prio = true, key = queuedKey })
    end
end
-- То же для готового пакета S1: сертификат его автора, если он у меня есть.
function S.IntroduceWire(target, wire, force)
    local fp = type(wire) == "string" and wire:match("^S1~([%w_-]+)~")
    local raw = fp and byFp[fp]
    if raw then S.Introduce(target, raw, force) end
end
function S.Roots() return Store() and Store().roots or {} end
local function PolicyPrefix(p)
    return p.legacy and C.PREFIX or C.UNION_PREFIX
end
local function PolicyCurrent(p)
    if p.durable then
        local owner = ns.UnionAuthority.Current()
        return owner and p.owner == owner.public and p.generation == owner.generation
    end
    return p.expires > ns.ServerTime() and not Store().owner and not (p.legacy and Store().governed)
end
function S.ShareTrust(bootstrap)
    if not S.CanAdmin() then return false end
    if ns.Census then ns.Census.SendHello() end
    -- При первом входе корни и состав обгоняют чат; обычная догоняющая рассылка
    -- остаётся наравне с ним, как и сертификаты.
    local priority = bootstrap and ns.Comm.PRIO_BOOTSTRAP or true
    for _, root in pairs(S.Roots()) do
        if LocalOrMember(root.guild) then ShareRoot(root.guild, root, priority) end
    end
    ns.UnionAuthority.Share("GUILD", priority)
    ns.Issuers.Share("GUILD", priority)
    for _, p in pairs(Store().policies) do
        if PolicyCurrent(p) then ns.Comm.Send("GUILD", p.wire,
            { prio = priority, key = "union:" .. U.GuildKey(p.guild), prefix = PolicyPrefix(p) }) end
    end
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
    ns.Comm.Send("GUILD", "KF~" .. guild .. "~" .. public, { prio = ns.Comm.PRIO_CONTROL, guard = S.CanAdmin })
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
    if root then
        report(S.MyCertificate() and L.AUTH_INIT_DONE:format(U.Display(root.name)) or CertificateWait(root))
        return false
    end
    if not identity or ns.Now() - ns.loginAt < 20 or initAsking then report(L.AUTH_INIT_WAIT); return false end
    local retired = Store().retired[gk]
    if retired and retired[identity.public] then
        -- Мой ключ уже был корнем и сброшен: нужен новый ключ.
        StartIdentity(true)
        report(L.AUTH_INIT_WAIT)
        return false
    end
    initAsking, hints[gk] = true, nil
    ns.Comm.Send("GUILD", "KR~", { prio = ns.Comm.PRIO_CONTROL, key = "root-query" })
    report(L.AUTH_INIT_ASK)
    ns.After(INIT_WAIT, "trust init", function()
        initAsking = nil
        local now = Root(guild)
        if now then
            report(S.MyCertificate() and L.AUTH_INIT_DONE:format(U.Display(now.name)) or CertificateWait(now))
            return
        end
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
    if S.CanAdmin() then ShareRoot(root.guild, root, ns.Comm.PRIO_CONTROL); return end
    -- Участников много, ответа хватит одного: случайная пауза, и кто услышал чужой — молчит.
    ns.After(math.random() * 3, "root hint", function()
        if ns.Now() - heardHint < INIT_WAIT or Root(ns.MyGuild()) ~= root then return end
        heardHint = ns.Now()
        ns.Comm.Send("GUILD", "KH~" .. root.name, { prio = ns.Comm.PRIO_CONTROL, key = "root-hint" })
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
-- KU~гильдия~ключ: офицер своей гильдии явно подтвердил отозванный корень чужой гильдии
-- (/chillzone accept, /chillzone link). Принимается от тех же, от кого KF; сам корень приходит следом (KT).
ns.Comm.On("KU", function(msg, sender, dist)
    if dist ~= "GUILD" or not ns.Roster.Fresh() or not ns.Roster.IsOfficerRank(ns.Roster.RankOf(sender)) then return end
    local guild, public = msg:match("^KU~([^~]+)~([%w_-]+)$")
    if guild and U.IsMemberGuild(guild) and U.GuildKey(guild) ~= GuildKey() then Unretire(U.GuildKey(guild), public) end
end)
function S.SendPolicies(target)
    local key, now = U.Key(target), ns.Now()
    ns.UnionAuthority.Share(target, true)
    ns.Issuers.Share(target, true)
    policySent[key] = policySent[key] or {}
    for _, p in pairs(Store() and Store().policies or {}) do
        local old = policySent[key][p.guild]
        if PolicyCurrent(p)
            and (not old or old.wire ~= p.wire or now - old.at >= 120) then
            policySent[key][p.guild] = { wire = p.wire, at = now }
            ns.Comm.Send("WHISPER", p.wire, { target = target, prio = true,
                key = "policy:" .. U.Key(target) .. ":" .. p.guild, prefix = PolicyPrefix(p) })
        end
    end
end
-- Контакт гильдии получает решение шёпотом при каждой подписи. Другой персонаж этого же
-- аккаунта со мной в игре не бывает: решение он найдёт в общих SavedVariables. Контакт,
-- о котором сервер ответил «нет такого игрока», пропускается на C.UNION_CONTACT_RETRY.
-- То же для главного корня, у которого новая установка просит каталог 0.8 (см. Tick).
local contactAway = {}
local probeKey
local function Reachable(name)
    local k = U.Key(name)
    if not k or k == ns.myKey or (ns.db and ns.db.chars and ns.db.chars[k]) then return false end
    return not contactAway[k] or ns.Now() - contactAway[k] >= C.UNION_CONTACT_RETRY
end
function S.UnionContact(key)
    if probeKey and key == probeKey then return true end
    for _, entry in pairs(Store() and Store().union or {}) do
        if entry.contact and U.Key(entry.contact) == key then return true end
    end
    return false
end
function S.ContactAway(key)
    if S.UnionContact(key) then contactAway[key] = ns.Now() end
end
local function BuildPolicies()
    local owner = ns.UnionAuthority.Current()
    if not owner or not identity or not S.CanManageUnion() or owner.public ~= identity.public then return end
    local now, s = ns.ServerTime(), Store()
    for gk, entry in pairs(s.union) do
        local previous = s.policies[gk]
        if not policySigning[gk] and (not previous or not previous.durable or previous.owner ~= owner.public) then
            local revision = (entry.revision or 0) + 1
            local body = Pack("UNIONDECISION", { ns.group, ns.faction, entry.guild, entry.name, entry.public, now,
                entry.active and "1" or "0", revision, owner.generation })
            policySigning[gk] = true
            local function Guard()
                return S.CanManageUnion() and ns.UnionAuthority.Current() == owner and s.union[gk] == entry
            end
            local queued = S.SignControl(body, Guard, function(sig)
                policySigning[gk] = nil
                if not sig then return end
                local wire = "KA~" .. owner.public .. "~" .. Ed.ToB64(body) .. "~" .. Ed.ToB64(sig)
                entry.revision, entry.issued = revision, now
                entry.legacy, s.governed = nil, true
                s.policies[gk] = { wire = wire, issued = now, revision = revision,
                    expires = 0, durable = true, owner = owner.public, generation = owner.generation, guild = entry.guild }
                entry.generation = owner.generation
                ns.UnionAuthority.Share("GUILD", ns.Comm.PRIO_BOOTSTRAP)
                ns.Fire("UNION_POLICY", entry.guild, wire)
                ns.Comm.Send("GUILD", wire, { key = "root-policy:" .. gk, guard = S.CanManageUnion })
                -- Подключаемая гильдия пока не зарегистрирована у реле. Её представитель
                -- получает решение напрямую; удалённая получает отзыв тем же путём.
                if entry.contact and Reachable(entry.contact) then
                    ns.UnionAuthority.Share(entry.contact, true)
                    ns.Comm.Send("WHISPER", wire, { target = entry.contact, prio = true,
                        key = "union-contact:" .. gk, guard = S.CanManageUnion })
                end
            end)
            if not queued then policySigning[gk] = nil end
        end
    end
end
-- До первого решения главы принимаем проверенные каталоги 0.8. Они сохраняют уже
-- действующее доверие, но никогда не отменяют новое решение или исключение гильдии.
local function LegacyPolicy(msg, sender, dist)
    if Store().governed or Store().owner or Store().ownerReset then return end
    local ec, eb, es = msg:match("^KA~([%w_-]+)~([%w_-]+)~([%w_-]+)$")
    local raw, body, sig = ec and Ed.FromB64(ec), eb and Ed.FromB64(eb), es and Ed.FromB64(es)
    local p = body and Unpack(body, "GUILDROOT", 7, 500)
    local issued, expires = p and Int(p[6], 1, 4102444800), p and Int(p[7], 1, 4102444800)
    local pk = p and Ed.FromB64(p[5])
    if not raw or not p or not sig or #sig ~= 64 or p[1] ~= ns.group or p[2] ~= ns.faction
        or not GuildName(p[3]) or not Name(p[4]) or not pk or #pk ~= 32
        or not issued or not expires or expires <= ns.ServerTime() or issued > ns.ServerTime() + 30
        or expires <= issued or expires - issued > C.AUTH_TTL then return end
    Job(function()
        local c = VerifyCertificate(raw)
        if not c or not U.IsMainGuild(c.guild) or not c.canIssue
            or (c.role ~= "leader" and c.role ~= "officer") or expires > c.expires then return end
        if Ed.Verify(c.pk, body, sig) then return c end
    end, function(issuer)
        local s, gk = Store(), U.GuildKey(p[3])
        if not issuer or not Current(issuer) or expires <= ns.ServerTime() or s.governed or s.owner or s.ownerReset then return end
        local old, known = s.union[gk], s.policies[gk]
        if old and (not old.legacy or old.issued > issued) then return end
        -- Реле присылают один и тот же каталог раз за разом. Он ничего не меняет: без этой
        -- проверки каждый повтор уходил бы всей гильдии и будил приветы H1.
        if known and known.legacy and known.issued and known.issued >= issued then return end
        if not Pin(p[3], p[4], p[5], false, true) then return end
        if not U.IsMainGuild(p[3]) then
            s.union[gk] = { guild = p[3], name = p[4], public = p[5], active = true,
                issued = issued, revision = 0, legacy = true, contact = p[4] }
        end
        s.policies[gk] = { wire = msg, guild = p[3], issued = issued, expires = expires, legacy = true }
        ns.Fire("UNION")
        ns.Fire("AUTH_ROOT", p[3])
        if dist == "WHISPER" then ns.Comm.Send("GUILD", msg, { key = "union:" .. gk, prefix = C.PREFIX }) end
    end)
end
ns.Comm.On("KA", function(msg, sender, dist, ctx)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if #msg > 3000 or not Budget("n:" .. Peer(sender), C.AUTH_NEW_PER_MIN) then return end
    -- Куски KA могут обогнать растянутую на кадры проверку UO. Ограниченная очередь
    -- ничего не подтверждает: после закрепления ключа документ проходит обычную проверку.
    local queuedPublic, queuedEncoded = msg:match("^KA~([%w_-]+)~([%w_-]+)~[%w_-]+$")
    local queuedOwner = ns.UnionAuthority.Current()
    local queuedBody = queuedEncoded and Ed.FromB64(queuedEncoded)
    if (not ctx or ctx.unionControl) and queuedBody and queuedBody:sub(1, 14) == "UNIONDECISION:"
        and (not queuedOwner or queuedPublic ~= queuedOwner.public) then
        for _, p in ipairs(pendingPolicies) do if p.msg == msg then return end end
        if #pendingPolicies >= 8 then table.remove(pendingPolicies, 1) end
        pendingPolicies[#pendingPolicies + 1] = { msg = msg, sender = sender, dist = dist, ctx = ctx, at = ns.Now() }
        return
    end
    if Store().ownerReset then return end
    if Store().owner then
        if ctx and not ctx.unionControl then return end
        local public, encoded, signature = msg:match("^KA~([%w_-]+)~([%w_-]+)~([%w_-]+)$")
        local body, sig = encoded and Ed.FromB64(encoded), signature and Ed.FromB64(signature)
        local p = body and Unpack(body, "UNIONDECISION", 9, 650)
        local issued, revision, generation = p and Int(p[6], 1, 4102444800), p and Int(p[8], 1, 9007199254740991),
            p and Int(p[9], 1, 9007199254740991)
        local owner = ns.UnionAuthority.Current()
        local pk = p and Ed.FromB64(p[5])
        if public ~= owner.public or not p or not sig or #sig ~= 64 or p[1] ~= ns.group or p[2] ~= ns.faction
            or not GuildName(p[3]) or U.IsMainGuild(p[3]) or not Name(p[4]) or not pk or #pk ~= 32
            or not issued or issued > ns.ServerTime() + 30 or not revision or generation ~= owner.generation
            or (p[7] ~= "0" and p[7] ~= "1") then return end
        local s, gk = Store(), U.GuildKey(p[3])
        local function Newer()
            local old = s.union[gk]
            return not old or (old.generation or 0) < generation
                or ((old.generation or 0) == generation and (old.revision or 0) < revision)
        end
        if not Newer() then return end
        Job(function() return Ed.Verify(Ed.FromB64(public), body, sig) end, function(valid)
            if not valid or ns.UnionAuthority.Current() ~= owner or not Newer() then return end
            local old = s.union[gk]
            s.union[gk] = { guild = p[3], name = p[4], public = p[5], active = p[7] == "1",
                issued = issued, revision = revision, generation = generation }
            if p[7] == "1" and not Pin(p[3], p[4], p[5]) then s.union[gk] = old; return end
            s.policies[gk] = { wire = msg, issued = issued, revision = revision, expires = 0,
                durable = true, owner = public, generation = generation, guild = p[3] }
            s.governed = true
            ns.Fire("UNION_POLICY", p[3], msg); ns.Fire("UNION"); ns.Fire("AUTH_ROOT", p[3])
            if dist == "WHISPER" then ns.Comm.Send("GUILD", msg, { key = "union:" .. gk }) end
        end)
        return
    end
    if ctx and not ctx.unionControl then LegacyPolicy(msg, sender, dist); return end
    local encodedCert, encodedBody, encodedSig = msg:match("^KA~([%w_-]+)~([%w_-]+)~([%w_-]+)$")
    local raw, body, sig = encodedCert and Ed.FromB64(encodedCert), encodedBody and Ed.FromB64(encodedBody), encodedSig and Ed.FromB64(encodedSig)
    local p = body and Unpack(body, "GUILDROOT", 9, 600)
    local issued, expires = p and Int(p[6], 1, 4102444800), p and Int(p[7], 1, 4102444800)
    local pk = p and Ed.FromB64(p[5])
    if not raw or not p or not sig or #sig ~= 64 or p[1] ~= ns.group or p[2] ~= ns.faction
        or not GuildName(p[3]) or U.IsMainGuild(p[3]) or not Name(p[4]) or not pk or #pk ~= 32
        or not issued or not expires or expires <= ns.ServerTime() or issued > ns.ServerTime() + 30
        or expires <= issued or expires - issued > C.AUTH_TTL or (p[8] ~= "0" and p[8] ~= "1")
        or not Int(p[9], 1, 9007199254740991) then return end
    Job(function()
        local c = VerifyCertificate(raw)
        if not c or not U.IsMainGuild(c.guild) or c.role ~= "leader" or c.rank ~= 0
            or issued < c.issued or issued - c.issued > C.AUTH_ROLE_TTL or expires > c.expires then return end
        if Ed.Verify(c.pk, body, sig) then return c end
    end, function(issuer)
        if not issuer or not Current(issuer) or expires <= ns.ServerTime() or Store().owner or Store().ownerReset then return end
        local s, gk = Store(), U.GuildKey(p[3])
        local old, revision = s.union[gk], tonumber(p[9])
        if old and (old.issued > issued or (old.issued == issued and (old.revision or 0) >= revision)) then return end
        local entry = { guild = p[3], name = p[4], public = p[5], active = p[8] == "1", issued = issued, revision = revision }
        s.union[gk] = entry
        if entry.active and not Pin(p[3], p[4], p[5]) then s.union[gk] = old; return end
        s.policies[gk] = { wire = msg, issued = issued, revision = revision, expires = expires, guild = p[3] }
        s.governed = true
        ns.Fire("UNION_POLICY", p[3], msg)
        ns.Fire("UNION")
        ns.Fire("AUTH_ROOT", p[3])
        -- Репортёры разносят решения по своей гильдии, включая её исключение.
        if dist == "WHISPER" then ns.Comm.Send("GUILD", msg, { key = "union:" .. gk }) end
    end)
end)
ns.On("UNION_OWNER", function()
    local waitingPolicies = pendingPolicies
    pendingPolicies = {}
    for _, p in ipairs(waitingPolicies) do
        if ns.Now() - p.at <= 30 then ns.Comm.Dispatch(p.msg, p.sender, p.dist, p.ctx) end
    end
end)
ns.On("UNION_RESET", function()
    pendingPolicies = {}
    unionQueryAt, unionQueryDelay = ns.Now() + 60, 60
end)
local LINK_TTL, LINK_RETRY = 180, 15
local function LinkPermission()
    if not ns.MyGuild() then return ns.L.AUTH_LINK_NOT_MEMBER end
    if not ns.Roster.Fresh() then
        ns.Roster.RequestScan()
        return ns.L.AUTH_LINK_ROSTER
    end
    if not ns.Roster.IsOfficerRank(ns.Roster.MyRank()) then return ns.L.AUTH_LINK_OFFICER end
end
local function CanLinkHere()
    return not U.IsMainGuild(ns.MyGuild()) or S.CanSignUnion()
end
local function LinkCurrent(p)
    return S.CanAdmin() and CanLinkHere() and ns.MyGuild() == p.localGuild and Root(p.localGuild) == p.localRoot
end
local function SameLink(p, nonce, guild, name, public)
    return p.nonce == nonce and p.guild == guild and p.name == name and p.public == public
end
-- Ход запроса связи: в чат и на вкладку «Объединение».
local function LinkNotice(text, ...)
    if select("#", ...) > 0 then text = text:format(...) end
    ns.Print("%s", text)
    ns.Fire("UNION_LINK", text)
end
local function SendLink(key, p)
    p.queued = true
    local function Done(ok, why)
        p.queued = nil
        if outgoing[key] ~= p then return end
        if not ok then
            if why == "authority changed" and ns.MyGuild() == p.localGuild and Root(p.localGuild) == p.localRoot
                and not ns.Roster.Fresh() then
                ns.Roster.RequestScan()
                p.retryAt = ns.Now() + LINK_RETRY
                return
            end
            outgoing[key] = nil
            ns.Log("запрос связи %s не отправлен: %s", p.target, tostring(why))
            LinkNotice(ns.L.AUTH_LINK_FAILED, p.target)
            return
        end
        if not p.sentAt then
            p.sentAt, p.untilAt = ns.Now(), ns.Now() + LINK_TTL
            LinkNotice(ns.L.AUTH_SENT, p.target)
        end
        p.retryAt = ns.Now() + LINK_RETRY
    end
    local root = p.localRoot
    local queued = ns.Comm.Send("WHISPER", "KL~H~" .. p.nonce .. "~" .. p.localGuild .. "~" .. root.name .. "~" .. root.public,
        { target = p.target, prio = ns.Comm.PRIO_LINK, key = "link:" .. key,
          guard = function() return outgoing[key] == p and LinkCurrent(p) and ns.Now() <= p.untilAt end,
          done = Done })
    if not queued and outgoing[key] == p then Done(false, "queue") end
end
local function ReplyLink(key, p)
    if p.queued or (p.repliedAt and ns.Now() - p.repliedAt < 5) then return end
    p.queued = true
    local function Done(ok, why)
        p.queued = nil
        if ok then
            p.repliedAt = ns.Now()
        else
            ns.Log("ответ на запрос связи %s не отправлен: %s", p.target, tostring(why))
        end
    end
    local root = p.localRoot
    local queued = ns.Comm.Send("WHISPER", "KL~R~" .. p.nonce .. "~" .. p.localGuild .. "~" .. root.name .. "~" .. root.public,
        { target = p.target, prio = ns.Comm.PRIO_LINK, key = "link-reply:" .. key,
          guard = function()
              local pinned = Root(p.guild)
              return acceptedLinks[key] == p and LinkCurrent(p) and ns.Now() <= p.untilAt
                  and pinned and pinned.public == p.public and pinned.name == p.name
          end, done = Done })
    if not queued and p.queued then Done(false, "queue") end
    -- Решение главы могло прийти раньше потерянного ответа: без корня инициатор его отбросил.
    local decision = S.CanManageUnion() and Store().policies[U.GuildKey(p.guild)]
    if decision and not decision.legacy and PolicyCurrent(decision) then
        ns.UnionAuthority.Share(p.target, ns.Comm.PRIO_LINK)
        ns.Comm.Send("WHISPER", decision.wire, { target = p.target, prio = ns.Comm.PRIO_LINK,
            key = "union-contact:" .. U.GuildKey(p.guild), guard = S.CanManageUnion })
    end
    ns.Security.Introduce(p.target, nil, true)
end
local function TickLinks()
    local now = ns.Now()
    for key, p in pairs(outgoing) do
        if now > p.untilAt then
            outgoing[key] = nil
            LinkNotice(p.sentAt and ns.L.AUTH_LINK_EXPIRED or ns.L.AUTH_LINK_FAILED, p.target)
        elseif p.retryAt and not p.queued and now >= p.retryAt and LinkCurrent(p) then
            SendLink(key, p)
        end
    end
    for key, p in pairs(acceptedLinks) do if now > p.untilAt then acceptedLinks[key] = nil end end
end
local function Admit(guild, name, public, contact)
    if not S.CanSignUnion() or U.IsMainGuild(guild) then return end
    local s, gk = Store(), U.GuildKey(guild)
    local old = s.union[gk]
    s.union[gk] = { guild = guild, name = name, public = public, active = true,
        issued = old and old.issued or 0, revision = old and old.revision or 0, contact = contact }
    s.policies[gk] = nil
    BuildPolicies()
    ns.Fire("UNION")
end
function S.UnionGuilds()
    local list = { { guild = C.MAIN_GUILD, main = true } }
    for _, entry in pairs(Store() and Store().union or {}) do
        if entry.active then list[#list + 1] = { guild = entry.guild } end
    end
    table.sort(list, function(a, b) return U.GuildKey(a.guild) < U.GuildKey(b.guild) end)
    return list
end
function S.UnionRequests()
    local list = {}
    if not S.CanManageUnion() then return list end
    for _, p in pairs(pending) do
        if ns.Now() <= p.untilAt then list[#list + 1] = { guild = p.guild, contact = p.sender } end
    end
    table.sort(list, function(a, b) return U.GuildKey(a.guild) < U.GuildKey(b.guild) end)
    return list
end
-- Гильдии, чей корень уже лежит в хранилище, но которых нет в составе: подключённые до
-- CHZUNION1 и гильдии других персонажей аккаунта (SavedVariables общие для персонажей одной
-- группы реалмов и фракции). Чужой корень сюда со стороны не попадёт: Pin принимает его
-- только от своей гильдии, из подписанного состава или по запросу связи, принятому главой.
function S.KnownGuilds()
    local list, s = {}, Store()
    if not s or not S.CanManageUnion() then return list end
    local requested = {}
    for _, p in pairs(pending) do
        if ns.Now() <= p.untilAt then requested[U.GuildKey(p.guild)] = true end
    end
    for gk, root in pairs(s.roots) do
        local entry = s.union[gk]
        if not (entry and entry.active) and not requested[gk] and GuildName(root.guild)
            and not U.IsMainGuild(root.guild) and Name(root.name) then
            list[#list + 1] = { guild = root.guild, root = root.name }
        end
    end
    table.sort(list, function(a, b) return U.GuildKey(a.guild) < U.GuildKey(b.guild) end)
    return list
end
-- Добавить известную гильдию без запроса связи. Решение получает её корневой офицер, когда
-- он в игре вместе с главой, или персонаж этого аккаунта из неё — через SavedVariables.
function S.AddKnown(guild)
    if not S.CanSignUnion() then return false, S.UnionDenied() end
    if type(guild) ~= "string" or U.IsMainGuild(guild) then return false end
    local s, gk = Store(), U.GuildKey(guild)
    local root, entry = s and s.roots[gk], s and s.union[gk]
    if not root or (entry and entry.active) or not GuildName(root.guild) or not Name(root.name) then return false end
    Admit(root.guild, root.name, root.public, root.name)
    return true
end
function S.RemoveGuild(guild)
    if not S.CanSignUnion() then return false, S.UnionDenied() end
    if U.IsMainGuild(guild) then return false end
    local s, gk = Store(), U.GuildKey(guild)
    local old = s and s.union[gk]
    if not old or not old.active then return false end
    s.union[gk] = { guild = old.guild, name = old.name, public = old.public, active = false,
        issued = old.issued, revision = old.revision, contact = old.contact }
    s.policies[gk] = nil
    BuildPolicies()
    ns.Fire("UNION")
    ns.Fire("AUTH_ROOT", guild)
    return true
end
function S.MyRoot()
    local guild = ns.MyGuild()
    return guild and Root(guild) or nil
end
-- Запрос связи к name ещё ждёт ответа: "queued", "sent" или nil. Для вкладки офицера.
function S.LinkState(name)
    local p = outgoing[U.Key(U.TellName(name))]
    return p and (p.sentAt and "sent" or "queued") or nil
end
function S.Link(name)
    local why = LinkPermission()
    if why then return false, why end
    if not identity then return false, ns.L.AUTH_LINK_KEY end
    local guild = ns.MyGuild()
    local root = Root(guild)
    if not root then return false, ns.L.AUTH_LINK_ROOT end
    name = U.TellName(name)
    local key = U.Key(name)
    if not CanLinkHere() then return false, S.UnionDenied() end
    if not key or key == "" or ns.Roster.RankOf(name) ~= nil then return false, ns.L.AUTH_LINK_NAME end
    serial = serial + 1
    local p = { nonce = tostring(ns.ServerTime()) .. "." .. serial, target = name,
        localGuild = guild, localRoot = root, untilAt = ns.Now() + ns.Comm.HOLD_MAX }
    outgoing[key] = p
    LinkNotice(ns.L.AUTH_LINK_QUEUED, name)
    SendLink(key, p)
    return outgoing[key] == p
end
-- Офицер явно подтвердил корень чужой гильдии: гильдии — сначала что он больше не отозван
-- (KU: прежний /chillzone trust reset ушёл всем по KF), затем сам корень (KT).
local function Confirmed(guild, public)
    ns.Comm.Send("GUILD", "KU~" .. guild .. "~" .. public, { prio = ns.Comm.PRIO_CONTROL, key = "unretire:" .. U.GuildKey(guild), guard = S.CanAdmin })
    ShareRoot(guild, Root(guild), ns.Comm.PRIO_BOOTSTRAP)
end
function S.Accept(name)
    local why = LinkPermission()
    if why then return false, why end
    local key = U.Key(name)
    local p, root = pending[key], ns.MyGuild() and Root(ns.MyGuild())
    if not CanLinkHere() then return false, S.UnionDenied() end
    if not root then return false, ns.L.AUTH_LINK_ROOT end
    if not p or ns.Now() > p.untilAt then return false, ns.L.AUTH_LINK_NO_REQUEST:format(U.Display(name)) end
    if not U.IsMemberGuild(p.guild) and not S.CanManageUnion() then return false, ns.L.UNION_ONLY_LEADER end
    if not Pin(p.guild, p.name, p.public, true) then return false, ns.L.AUTH_LINK_CONFLICT end
    pending[key] = nil
    if U.IsMainGuild(p.guild) then ns.UnionAuthority.Allow(p.target) end
    p.localGuild, p.localRoot, p.untilAt = ns.MyGuild(), root, ns.Now() + LINK_TTL
    acceptedLinks[key] = p
    Confirmed(p.guild, p.public)
    Admit(p.guild, p.name, p.public, p.target)
    ReplyLink(key, p)
    ns.Fire("UNION")
    ns.Print(ns.L.AUTH_ACCEPTED, p.guild, p.target)
    return true
end
ns.Comm.On("KL", function(msg, sender, dist)
    if dist ~= "WHISPER" or not Budget("l:" .. Peer(sender), 30) then return end
    local mode, nonce, guild, name, public = msg:match("^KL~([HR])~([%d%.]+)~([^~]+)~([^~]+)~([%w_-]+)$")
    if not mode or #msg > 250 or #nonce > 40 or not GuildName(guild) or U.GuildKey(guild) == GuildKey()
        or not Name(name) or #public ~= 43 or not Ed.FromB64(public) then return end
    local why = LinkPermission()
    if why then ns.Log("соединение с %s пропущено: %s", U.Display(sender), why); return end
    local key = U.Key(sender)
    if mode == "H" then
        local accepted = acceptedLinks[key]
        if accepted and accepted.nonce == nonce then
            if ns.Now() <= accepted.untilAt and SameLink(accepted, nonce, guild, name, public) then ReplyLink(key, accepted) end
            return
        end
        local previous = pending[key]
        if previous and ns.Now() <= previous.untilAt and SameLink(previous, nonce, guild, name, public) then return end
        local total = 0; for _ in pairs(pending) do total = total + 1 end
        if total >= 16 and not pending[key] then return end
        pending[key] = { nonce = nonce, guild = guild, name = name, public = public, sender = sender,
            target = U.TellName(sender), untilAt = ns.Now() + LINK_TTL }
        ns.Print(ns.L.AUTH_REQUEST, U.Display(sender), guild)
        ns.Fire("UNION")
    else
        local p = outgoing[key]
        if not p or not p.sentAt or p.nonce ~= nonce or ns.Now() > p.untilAt or not LinkCurrent(p) then return end
        if Pin(guild, name, public, true) then
            if U.IsMainGuild(guild) then ns.UnionAuthority.Allow(sender) end
            outgoing[key] = nil
            Confirmed(guild, public)
            S.Introduce(sender, nil, true)
            Admit(guild, name, public, sender)
            LinkNotice(ns.L.AUTH_PAIRED, U.Display(sender), guild)
        else
            outgoing[key] = nil
            LinkNotice(ns.L.AUTH_LINK_CONFLICT)
        end
    end
end)
ns.Comm.On("KT", function(msg, sender, dist)
    if dist ~= "GUILD" or not ns.Roster.Fresh() or not ns.Roster.IsOfficerRank(ns.Roster.RankOf(sender)) then return end
    local guild, name, public = msg:match("^KT~([^~]+)~([^~]+)~([%w_-]+)$")
    -- Только корни гильдий объединения и своей. Корень посторонней гильдии, записанный заранее,
    -- Pin потом не заменяет: настоящий корень при её подключении был бы отвергнут.
    if guild then Pin(guild, name, public) end
end)
local function NativeTrustReply(union, bootstrap)
    if not S.CanAdmin() then return end
    if union then
        nativeUnionPending = true
        nativeUnionBootstrap = nativeUnionBootstrap or bootstrap ~= false
    end
    if nativeTrustPending then return end
    nativeTrustPending = true
    ns.After(math.max(0, 5 - (ns.Now() - lastNativeHello)), "доверие новым участникам", function()
        nativeTrustPending = false
        if not S.CanAdmin() then return end
        lastNativeHello = ns.Now()
        if nativeUnionPending then
            nativeUnionPending = false
            local priority = nativeUnionBootstrap
            nativeUnionBootstrap = false
            S.ShareTrust(priority)
        else
            local root = Root(ns.MyGuild())
            if root then ShareRoot(root.guild, root) end
            if ns.Census then ns.Census.SendHello() end
        end
    end)
end
ns.Comm.On("UQ", function(msg, sender, dist, ctx)
    if msg == "UQ~1" and dist == "GUILD" and ctx and ctx.unionControl and NativeRole(sender) then
        local key = U.Key(sender)
        local first = not unionQueries[key]
        unionQueries[key] = ns.Now()
        NativeTrustReply(true, first)
    end
end)
ns.Comm.On("K1", function(msg, sender, dist)
    if dist ~= "GUILD" or not NativeRole(sender) then return end
    local public, flag = msg:match("^K1~([%w_-]+)(.*)$")
    if flag ~= "" and flag ~= "~0" and flag ~= "~u" and flag ~= "~0~u" then return end
    local raw = Ed.FromB64(public)
    if not raw or #raw ~= 32 then return end
    local k = U.Key(sender)
    local firstPeer = not keys[k] or keys[k].public ~= public
    keys[k] = { name = sender, public = public, at = ns.Now() }
    -- У участника нет сертификата, а у меня, активного издателя, он есть: первый KP до него
    -- не дошёл (лимит, ещё не было корня). Issue свежий сертификат заново не выдаёт.
    -- Пока выданный сертификат ещё ждёт в очереди или очередь выдачи полна — не дублировать.
    local issuerRoot = flag:find("~0", 1, true) and Authority()
    if issuerRoot and (not resent[k] or ns.Now() - resent[k] >= 60)
        and ns.Comm.Queued("credential:" .. k, true) == 0 and IssueRoom() > 0 then
        local held = S.Member(ns.MyGuild(), sender)
        if held and held.public == public then
            resent[k] = ns.Now()
            local queuedKey = "kp-own:" .. k
            ShareRoot(issuerRoot.guild, issuerRoot, true, queuedKey)
            ns.Comm.Send("WHISPER", "KP~" .. Ed.ToB64(held.raw), { target = sender, prio = true, key = queuedKey })
        end
    end
    -- После перезагрузки имя то же. Ответить на объявление ключа, чтобы вошедший узнал
    -- репортёра-офицера раньше, чем примет RG, и корень гильдии раньше, чем офицер возьмётся
    -- за /chillzone trust init.
    local requested = flag:find("~u", 1, true) ~= nil
    -- Вошедший офицер мог принести каталог с другого персонажа своего аккаунта.
    -- Первый K1 соседа запускает доставку, даже если его UQ уже ждёт длинного повтора.
    NativeTrustReply(requested or (firstPeer and Store().owner ~= nil), requested)
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
-- только владелец или репортёр (и прежний, пока передаёт дела): они и шлют в гильдию
-- подписанные пакеты. Один KP на всех.
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
        if c.key ~= ns.myKey and not (ns.Census and ns.Census.Forwarding()) then return end
        served[key] = now
        local queuedKey = "kp:" .. key
        ShareRoot(c.guild, Root(c.guild), true, queuedKey)
        ns.Comm.Send("GUILD", "KP~" .. Ed.ToB64(raw), { prio = true, key = queuedKey })
        return
    end
    if not Budget("q:" .. Peer(sender), 20) then return end
    served[key] = now
    ns.Comm.Send("WHISPER", "KP~" .. Ed.ToB64(raw), { target = sender, prio = true, key = "kp:" .. key })
end)
-- Подписать своё M1 или R1. done(wire) — подписано; done(nil, why) — не вышло уже после
-- постановки в очередь. Возвращает true (подпись в очереди) или false, why.
-- why: "nocert" — нет действующего сертификата, "busy" — очередь подписей полна,
-- "failed" — подпись не удалась или сертификат сменился, пока она шла, "long" — пакет велик.
function S.Seal(inner, done)
    local c, saved = S.MyCertificate(), identity
    if not c or not saved or not ns.IsMember() then return false, "nocert" end
    local kind = inner:sub(1, 2)
    if kind ~= "M1" and kind ~= "R1" then return false, "failed" end
    saved.sequence = saved.sequence + 1
    local at, sequence = tostring(ns.ServerTime()), tostring(saved.sequence)
    local body = Pack("MESSAGE", { ns.group, ns.faction, c.raw, at, sequence, inner })
    local queued = Job(function() return Ed.Sign(saved.seed, body, saved.pk) end, function(sig)
        if not sig or identity ~= saved or not ns.IsMember() or not Current(c) or not S.MyCertificate() then
            done(nil, "failed")
            return
        end
        local wire = "S1~" .. c.fp .. "~" .. at .. "~" .. sequence .. "~" .. Ed.ToB64(sig) .. "~" .. inner
        if #wire > MAX_WIRE then done(nil, "long"); return end
        sealed[wire] = { inner = inner, cert = c, at = ns.Now() }
        done(wire)
    end)
    if not queued then return false, "busy" end
    return true
end
-- Пакет, который я сам подписал недавно: вложенное и мой сертификат, без проверки подписи.
function S.Own(wire)
    local mine = sealed[wire]
    if mine and Current(mine.cert) then return mine.inner, mine.cert end
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
    if (kind ~= "M1" and kind ~= "R1") or not guild or not U.IsMemberGuild(guild) then return false end
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
            if not valid or not Current(c) or not U.IsMemberGuild(guild) then S.stats.rejected = S.stats.rejected + 1; return end
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
-- Каталог KA без ревизии остался от 0.8: в нём 7 полей, новые клиенты его не примут,
-- а рассылать его по GUILD и шёпотом пришлось бы до конца срока, неделю.
local function Sweep(restore)
    local s, now = Store(), ns.ServerTime()
    ns.Issuers.Sweep(restore)
    ns.IssuerRevocations.Sweep(restore)
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
        if type(p) ~= "table" or type(p.expires) ~= "number" or (not p.durable and p.expires <= now)
            or (type(p.revision) ~= "number" and (not p.legacy or s.governed)) then s.policies[gk] = nil end
    end
end
local function Tick()
    TickLinks()
    if not identity or not ns.MyGuild() or not ns.Roster.Fresh() then return end
    local now = ns.Now()
    if S.CanAdmin() and now - lastPolicy >= 30 then
        lastPolicy = now
        for _, root in pairs(S.Roots()) do
            if LocalOrMember(root.guild) then ShareRoot(root.guild, root) end
        end
    end
    if now - lastHello >= 60 then S.Say() end
    ns.UnionAuthority.Tick(keys)
    -- У новой установки среди 0.8 ещё нет состава, поэтому обычный выбор реле закрыт.
    -- Старое RP с настоящим своим сертификатом запрашивает подписанный каталог у
    -- уже доверенного главного корня. Нативный KT сам по себе членства не даёт.
    -- Персонажу своего аккаунта не шепчем, корню не в игре — не чаще C.UNION_CONTACT_RETRY.
    local mainRoot, mine = Root(C.MAIN_GUILD), S.MyCertificate()
    local probing = not Store().governed and not ns.IsMember() and mainRoot and mine
    probeKey = probing and U.Key(mainRoot.name) or nil
    if probing and Reachable(mainRoot.name) and now - lastLegacyProbe >= 120 then
        lastLegacyProbe = now
        S.Introduce(mainRoot.name)
        ns.Comm.Send("WHISPER", "RP~" .. mine.fp, { target = mainRoot.name,
            prio = true, key = "legacy-union-probe" })
    end
    if Authority() then
        local room = IssueRoom()
        if room > 0 and Issue(ns.me, identity.public) then room = room - 1 end
        for _, row in pairs(keys) do
            if room <= 0 then break end
            if Issue(row.name, row.public) then room = room - 1 end
        end
    end
    BuildPolicies()
    if IssueRoom() == C.AUTH_ISSUE_QUEUE then ns.Issuers.Tick(keys) end
    ns.IssuerRevocations.Tick()
    -- Доставка отделена от подписи: недоступному контакту повторяем тот же документ,
    -- не создавая новую ревизию и не требуя продления решения главы.
    if S.CanSignUnion() then
        for gk, entry in pairs(Store().union) do
            local p = Store().policies[gk]
            if p and p.durable and PolicyCurrent(p) and entry.contact and Reachable(entry.contact)
                and ns.ServerTime() - (p.contactAt or p.issued) >= C.UNION_CONTACT_RETRY then
                p.contactAt = ns.ServerTime()
                ns.UnionAuthority.Share(entry.contact, true)
                ns.Comm.Send("WHISPER", p.wire, { target = entry.contact, prio = true,
                    key = "union-contact:" .. gk, guard = S.CanSignUnion })
            end
        end
    end
end
ns.On("LOGIN", function()
    local s = ns.store.security
    local legacy = type(s) == "table" and s.version == 1 and s.union == nil
    if type(s) ~= "table" or s.version ~= 1 then
        ns.store.security = { version = 1, roots = {}, certs = {}, policies = {} }
        ns.store.guilds, ns.store.relays, ns.store.manual = {}, {}, {}
    end
    s = Store()
    s.union = type(s.union) == "table" and s.union or {}
    s.roots, s.certs, s.policies, s.delegations, s.retired = s.roots or {}, s.certs or {}, s.policies or {}, s.delegations or {}, s.retired or {}
    s.verified = type(s.verified) == "table" and s.verified or {}
    -- Однократный перенос уже подтверждённых корней 0.8, без нового списка в Config.
    -- Выполняется до восстановления сертификатов: членство не пропадает даже на кадр.
    if legacy then
        for gk, root in pairs(s.roots) do
            local pk = type(root) == "table" and Ed.FromB64(root.public)
            if pk and #pk == 32 and GuildName(root.guild) and Name(root.name)
                and gk == U.GuildKey(root.guild) and not U.IsMainGuild(root.guild)
                and not (s.retired[gk] and s.retired[gk][root.public]) then
                s.union[gk] = { guild = root.guild, name = root.name, public = root.public,
                    active = true, issued = 0, revision = 0, legacy = true, contact = root.name }
            end
        end
        for _, p in pairs(s.policies) do
            if type(p) == "table" and type(p.wire) == "string" then
                local encoded = p.wire:match("^KA~[%w_-]+~([%w_-]+)~[%w_-]+$")
                local body = encoded and Ed.FromB64(encoded)
                p.legacy = body and Unpack(body, "GUILDROOT", 7, 500) ~= nil or nil
            end
        end
    end
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
        for wire, entry in pairs(sealed) do if clock - entry.at > 120 then sealed[wire] = nil end end
        for id, entry in pairs(replay) do if now - entry.at > C.CHAT_DEDUPE then replay[id], openedHere[id] = nil, nil end end
        for key, p in pairs(pending) do if clock > p.untilAt then pending[key] = nil end end
        for raw, c in pairs(certCache) do if c.expires <= now then certCache[raw] = nil end end
        for fp, raw in pairs(byFp) do if not certCache[raw] then byFp[fp] = nil end end
        for fp, list in pairs(waiting) do if clock - list.at > 30 then waiting[fp] = nil end end
        for key, b in pairs(limits) do if clock - b.t >= 60 then limits[key] = nil end end
        for key, t in pairs(asked) do if clock - t >= 60 then asked[key] = nil end end
        for key, t in pairs(served) do if clock - t >= 60 then served[key] = nil end end
        for key, t in pairs(resent) do if clock - t >= 60 then resent[key] = nil end end
        for key, t in pairs(introduced) do if clock - t >= C.AUTH_INTRODUCE then introduced[key] = nil end end
        for key, t in pairs(unionQueries) do if clock - t >= 3600 then unionQueries[key] = nil end end
    end)
end)
ns.On("GUILD_CHANGED", function()
    keys, issuing, pending, outgoing, hints = {}, {}, {}, {}, {}
    acceptedLinks = {}
    unionQueries, unionQueryAt, unionQueryDelay = {}, -1e9, 0
    lastHello, lastPolicy, lastSaid = -1e9, -1e9, nil
    S.Say()
end)
ns.Command("link", function(name)
    local ok, why = S.Link(U.Trim(name))
    if not ok and why then ns.Print(why) end
end, "соединить гильдии: /chillzone link Имя Фамилия (глава или офицер)")
ns.Command("accept", function(name)
    local ok, why = S.Accept(U.Trim(name))
    if not ok and why then ns.Print(why) end
end, "подтвердить проверенное имя: /chillzone accept Имя Фамилия")
ns.Command("trust", function(arg)
    local cmd, rest = U.Trim(arg or ""):match("^(%S*)%s*(.-)$")
    cmd, rest = U.Fold(cmd or ""), U.Trim(rest or "")
    if cmd == "init" then
        S.Init(U.Fold(rest) == "force", function(text) ns.Print("%s", text) end)
    elseif cmd == "issuer-revoke" and rest ~= "" then
        ns.Print(ns.Issuers.Revoke(rest) and ns.L.AUTH_ISSUER_REVOKE or ns.L.AUTH_ISSUER_FAILED, rest)
    elseif cmd == "issuer-grant" and rest ~= "" then
        local peer = keys[U.Key(rest)]
        ns.Print(peer and ns.Issuers.Grant(peer.name, peer.public) and ns.L.AUTH_ISSUER_GRANT or ns.L.AUTH_ISSUER_FAILED, rest)
    elseif cmd == "owner-reset" then
        ns.Print(ns.UnionAuthority.Reset() and ns.L.AUTH_OWNER_RESET or ns.L.AUTH_NEED_OFFICER)
    elseif cmd == "reset" and rest ~= "" then
        if not S.Reset(rest) then ns.Print(ns.L.AUTH_NEED_OFFICER) end
    else
        local list = {}
        for _, root in pairs(S.Roots()) do list[#list + 1] = root end
        table.sort(list, function(a, b) return U.GuildKey(a.guild) < U.GuildKey(b.guild) end)
        if #list == 0 then ns.Print(ns.L.AUTH_NO_ROOTS) end
        for _, root in ipairs(list) do ns.Print(ns.L.AUTH_ROOT_LINE, root.guild, U.Display(root.name)) end
    end
end, "доверие: /chillzone trust — корни; init — задать свой корень; reset Гильдия — сброс корня; issuer-revoke/issuer-grant Имя Фамилия — допуск издателя; owner-reset — восстановление ключа управления")
ns.Status(function()
    return ns.L.AUTH_STATUS:format(S.MyCertificate() and ns.L.YES or ns.L.NO, S.stats.verified, S.stats.rejected)
end)
