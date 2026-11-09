-- Соединение через настоящий транспорт: потеря пакетов, задержки и повторное подтверждение.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Запомни Навсегда")
    local root = w:Client({ first = "Корень", surname = "Чиллзон", guild = "Чиллзон", rank = 1, realm = "CAMWOWEU4Realm4PvP" })
    local king = w:Client({ first = "Criogen", surname = "Magovich", guild = "Чиллзон", rank = 0, realm = "CAMWOWEU4Realm4PvP" })
    local leader = w:Client({ first = "Апдог", surname = "Ватс", guild = "Запомни Навсегда", rank = 0, realm = "CAMWOWEU4Realm6PvP" })
    w:Run(30)
    w:Init(root, leader)
    w:Run(100)
    T.ok(king.ns.Security.MyCertificate(), "у главы Чиллзон есть сертификат")
    T.ok(leader.ns.Security.MyCertificate(), "у главы ЗН есть сертификат")
    return w, king, leader, root
end

local function LoseFirst(w, from, mode)
    local deliver, lost = w.Deliver, false
    w.Deliver = function(self, sender, dist, prefix, msg, ...)
        if sender == from and dist == "WHISPER" and msg:sub(1, 5) == "KL~" .. mode .. "~" and not lost then
            lost = true
            return 0 -- API принял пакет, но получателю он не достался.
        end
        return deliver(self, sender, dist, prefix, msg, ...)
    end
    return function() return lost end
end

T.test("link: потерянный запрос повторяется без команды игрока", function()
    local w, king, leader = Build()
    local lost = LoseFirst(w, king, "H")
    T.ok(king.ns.Security.Link(leader:Name()))
    w:Run(40)
    T.ok(lost(), "первый запрос потерялся")
    T.eq(leader:Saw("Запрос связи от"), 1, "повтор доставлен один раз в интерфейс")
    T.ok(leader.ns.Security.Accept(king:Name()))
    w:Run(40)
    T.ok(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], "Апдог знает корень Чиллзон")
end)

T.test("link: потерянный ответ восстанавливает связь и перепись ЗН", function()
    local w, king, leader = Build()
    local lost = LoseFirst(w, king, "R")
    T.ok(leader.ns.Security.Link(king:Name()))
    w:Run(5)
    T.ok(king.ns.Security.Accept(leader:Name()))
    w:Run(45)
    T.ok(lost(), "первый ответ потерялся")
    T.ok(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], "ответ повторён без второго accept")
    T.eq(king:Saw("Запрос связи от"), 1, "повтор не требует нового ручного подтверждения")
    T.ok(#leader.ns.Relay.Candidates() > 0, "у Апдога появились кандидаты в реле")
    w:Run(220)
    local row = king.ns.Data.Row("Запомни Навсегда")
    T.ok(row and row.r, "перепись ЗН дошла до Чиллзон")
    for _, c in ipairs({ king, leader }) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end)

T.test("link: временно несвежий ростер не теряет входящий запрос", function()
    local w, king, leader = Build()
    local fresh, untilAt = leader.ns.Roster.Fresh, w.now + 20
    leader.ns.Roster.Fresh = function() return w.now >= untilAt and fresh() end
    T.ok(king.ns.Security.Link(leader:Name()))
    w:Run(40)
    T.eq(leader:Saw("Запрос связи от"), 1, "после обновления ростера запрос пришёл повторно")
end)

T.test("link: три минуты подтверждения начинаются после отправки", function()
    local w, king, leader = Build()
    local untilAt = w.now + 190
    king.ns.Comm.InLockdown = function() return w.now < untilAt end
    T.ok(king.ns.Security.Link(leader:Name()))
    w:Run(190)
    w:Run(5)
    T.eq(leader:Saw("Запрос связи от"), 1, "запрос дошёл после долгого ожидания очереди")
    T.ok(leader.ns.Security.Accept(king:Name()))
    w:Run(30)
    T.ok(king.ns.Security.Roots()[king.ns.Util.GuildKey(leader.guild)], "поздно отправленный запрос ещё действителен")
end)

T.test("link: запрос обгоняет повторяемые отправки GUILD после общей паузы", function()
    local w, king, leader = Build()
    local send = king.env.C_ChatInfo.SendAddonMessage
    king.env.C_ChatInfo.SendAddonMessage = function(prefix, msg, dist, ...)
        if dist == "GUILD" then return 3 end
        return send(prefix, msg, dist, ...)
    end
    king.ns.Comm.Send("GUILD", "Q1~", { prio = king.ns.Comm.PRIO_CONTROL })
    king.ns.Comm.Flush(1)
    T.ok(king.ns.Security.Link(leader:Name()))
    w:Run(6)
    T.eq(leader:Saw("Запрос связи от"), 1, "после общей паузы сначала отправлен ручной запрос")
end)

T.test("link: неотправленный запрос не выдаётся за отправленный", function()
    local w, king, leader = Build()
    local send = king.env.C_ChatInfo.SendAddonMessage
    king.env.C_ChatInfo.SendAddonMessage = function(prefix, msg, dist, ...)
        if dist == "WHISPER" then return 12 end
        return send(prefix, msg, dist, ...)
    end
    T.ok(king.ns.Security.Link(leader:Name()))
    w:Run(10)
    T.eq(king:Saw("Запрос связи отправлен"), 0, "ошибка API не считается отправкой")
    T.ok(king:Saw("Передать запрос связи") > 0, "игрок видит отказ отправки")
end)

T.test("link: истечение запроса видно игроку и останавливает повторы", function()
    local w, king, leader = Build()
    T.ok(king.ns.Security.Link(leader:Name()))
    w:Run(210)
    T.eq(king:Saw("Время ожидания подтверждения"), 1, "выведено понятное окончание ожидания")
    local sent = #w.log
    w:Run(60)
    for i = sent + 1, #w.log do
        local e = w.log[i]
        T.no(e.from == king:Name() and e.msg:sub(1, 5) == "KL~H~", "просроченный запрос не повторяется")
    end
    T.eq(leader:Saw("Запрос связи от"), 1, "повторы не засоряют чат")
end)

T.test("link: временно несвежий ростер отправителя не отменяет соединение", function()
    local w, king, leader = Build()
    T.ok(king.ns.Security.Link(leader:Name()))
    local fresh, untilAt = king.ns.Roster.Fresh, w.now + 20
    king.ns.Roster.Fresh = function() return w.now >= untilAt and fresh() end
    w:Run(40)
    T.eq(leader:Saw("Запрос связи от"), 1, "после обновления ростера отправка возобновилась")
    T.eq(king:Saw("Передать запрос связи"), 0, "временное ожидание ростера не выдаётся за окончательный отказ")
end)

T.test("link: новый запрос того же главы требует отдельного подтверждения", function()
    local w, king, leader = Build()
    w:Pair(leader, king)
    T.ok(leader.ns.Security.Link(king:Name()))
    w:Run(35)
    T.eq(king:Saw("Запрос связи от"), 2, "новый nonce показан как новый запрос")
    local replies = 0
    for _, e in ipairs(w.log) do
        if e.from == king:Name() and e.msg:sub(1, 5) == "KL~R~" then replies = replies + 1 end
    end
    T.eq(replies, 1, "новый запрос не подтверждён автоматически")
end)

T.test("link: повтор с изменённым корнем не получает автоматического ответа", function()
    local w, king, leader = Build()
    w:Pair(leader, king)
    local request
    for _, e in ipairs(w.log) do
        if e.from == leader:Name() and e.msg:sub(1, 5) == "KL~H~" then request = e.msg end
    end
    T.ok(request, "сохранён первоначальный запрос")
    local main = king.ns.Security.Roots()[king.ns.Util.GuildKey("Чиллзон")]
    local changed = request:gsub("~[%w_-]+$", "~" .. main.public)
    T.no(changed == request, "корень действительно подменён")
    leader.ns.Comm.Send("WHISPER", changed, { target = king:Name(), prio = true })
    w:Run(20)
    local replies = 0
    for _, e in ipairs(w.log) do
        if e.from == king:Name() and e.msg:sub(1, 5) == "KL~R~" then replies = replies + 1 end
    end
    T.eq(replies, 1, "одобрен только первоначальный корень")
    local root = king.ns.Security.Roots()[king.ns.Util.GuildKey(leader.guild)]
    T.no(root.public == main.public, "подмена не изменила доверие")
end)

T.test("link: отзыв корня прекращает автоматические ответы", function()
    local w, king, leader = Build()
    LoseFirst(w, king, "R")
    T.ok(leader.ns.Security.Link(king:Name()))
    w:Run(5)
    T.ok(king.ns.Security.Accept(leader:Name()))
    w:Run(5)
    T.ok(king.ns.Security.Reset(leader.guild))
    w:Run(45)
    T.eq(king.ns.Security.Roots()[king.ns.Util.GuildKey(leader.guild)], nil, "повтор не возвращает отозванный корень")
    T.eq(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], nil, "после отзыва ответ не отправляется")
end)

T.test("link: потеря звания главы прекращает автоматические ответы", function()
    local w, king, leader = Build()
    LoseFirst(w, king, "R")
    T.ok(leader.ns.Security.Link(king:Name()))
    w:Run(5)
    T.ok(king.ns.Security.Accept(leader:Name()))
    w:Run(5)
    king.rank = 3
    king.ns.Roster.Scan()
    w:Run(45)
    T.eq(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], nil, "бывший глава больше не отвечает на запрос")
end)

T.test("link: глава соединяет гильдии и передаёт перепись при корне вне игры", function()
    local w, king, leader, root = Build()
    root.online = false
    king.ns.Roster.Scan()
    LoseFirst(w, king, "R")
    T.ok(leader.ns.Security.Link(king:Name()))
    w:Run(5)
    T.ok(king.ns.Security.Accept(leader:Name()))
    w:Run(240)
    T.ok(leader.ns.Security.Member("Чиллзон", king:Name()), "Апдог получил сертификат самого главы")
    T.ok(leader.ns.Relay.TrustOf(king:Name()), "глава известен как реле при корне вне игры")
    local row = king.ns.Data.Row(leader.guild)
    T.ok(row and row.r, "перепись дошла через главу без корневого персонажа")
end)

T.test("link: решение главы приходит вместе с повторным ответом", function()
    local w, king, leader, root = Build()
    root.online = false
    king.ns.Roster.Scan()
    LoseFirst(w, king, "R")
    T.ok(leader.ns.Security.Link(king:Name()))
    w:Run(5)
    T.ok(king.ns.Security.Accept(leader:Name()))
    T.no(leader.ns.IsMember(), "до ответа гильдия вне объединения")
    w:Run(40)
    T.ok(leader.ns.IsMember(), "решение принято до следующей подписи главы")
end)

T.test("link: офицер гильдии объединения не подтверждает постороннюю гильдию", function()
    local w, king, leader = Build()
    w:Pair(leader, king)
    w:Run(60)
    T.ok(leader.ns.IsMember(), "гильдия в объединении")
    w:Guild("Посторонние")
    local stranger = w:Client({ first = "Чужой", surname = "Глава", guild = "Посторонние", rank = 0, realm = "CAMWOWEU4Realm6PvP" })
    w:Run(30)
    w:Init(stranger)
    T.ok(stranger.ns.Security.Link(leader:Name()))
    w:Run(5)
    local ok, why = leader.ns.Security.Accept(stranger:Name())
    T.no(ok, "добавляет только глава Чиллзон")
    T.eq(why, leader.ns.L.UNION_ONLY_LEADER, "причина отказа понятна")
end)
