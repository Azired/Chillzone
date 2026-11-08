-- Соединение через настоящий транспорт: потеря пакетов, задержки и повторное подтверждение.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
    local w = Wow.World()
    w:Guild("Чиллзон")
    w:Guild("Запомни Навсегда")
    local root = w:Client({ first = "Глава", surname = "Чиллзон", guild = "Чиллзон", rank = 1, realm = "CAMWOWEU4Realm4PvP" })
    local officer = w:Client({ first = "Criogen", surname = "Magovich", guild = "Чиллзон", rank = 0, realm = "CAMWOWEU4Realm4PvP" })
    local leader = w:Client({ first = "Апдог", surname = "Ватс", guild = "Запомни Навсегда", rank = 0, realm = "CAMWOWEU4Realm6PvP" })
    w:Run(30)
    w:Init(root, leader)
    w:Run(100)
    T.ok(officer.ns.Security.MyCertificate(), "у офицера есть сертификат")
    T.ok(leader.ns.Security.MyCertificate(), "у главы ЗН есть сертификат")
    return w, officer, leader, root
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
    local w, officer, leader = Build()
    local lost = LoseFirst(w, officer, "H")
    T.ok(officer.ns.Security.Link(leader:Name()))
    w:Run(40)
    T.ok(lost(), "первый запрос потерялся")
    T.eq(leader:Saw("Запрос связи от"), 1, "повтор доставлен один раз в интерфейс")
    T.ok(leader.ns.Security.Accept(officer:Name()))
    w:Run(40)
    T.ok(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], "Апдог знает корень Чиллзон")
end)

T.test("link: потерянный ответ восстанавливает связь и перепись ЗН", function()
    local w, officer, leader = Build()
    local lost = LoseFirst(w, officer, "R")
    T.ok(leader.ns.Security.Link(officer:Name()))
    w:Run(5)
    T.ok(officer.ns.Security.Accept(leader:Name()))
    w:Run(45)
    T.ok(lost(), "первый ответ потерялся")
    T.ok(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], "ответ повторён без второго accept")
    T.eq(officer:Saw("Запрос связи от"), 1, "повтор не требует нового ручного подтверждения")
    T.ok(#leader.ns.Relay.Candidates() > 0, "у Апдога появились кандидаты в реле")
    w:Run(220)
    local row = officer.ns.Data.Row("Запомни Навсегда")
    T.ok(row and row.r, "перепись ЗН дошла до Чиллзон")
    for _, c in ipairs({ officer, leader }) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end)

T.test("link: временно несвежий ростер не теряет входящий запрос", function()
    local w, officer, leader = Build()
    local fresh, untilAt = leader.ns.Roster.Fresh, w.now + 20
    leader.ns.Roster.Fresh = function() return w.now >= untilAt and fresh() end
    T.ok(officer.ns.Security.Link(leader:Name()))
    w:Run(40)
    T.eq(leader:Saw("Запрос связи от"), 1, "после обновления ростера запрос пришёл повторно")
end)

T.test("link: три минуты подтверждения начинаются после отправки", function()
    local w, officer, leader = Build()
    local untilAt = w.now + 190
    officer.ns.Comm.InLockdown = function() return w.now < untilAt end
    T.ok(officer.ns.Security.Link(leader:Name()))
    w:Run(190)
    w:Run(5)
    T.eq(leader:Saw("Запрос связи от"), 1, "запрос дошёл после долгого ожидания очереди")
    T.ok(leader.ns.Security.Accept(officer:Name()))
    w:Run(30)
    T.ok(officer.ns.Security.Roots()[officer.ns.Util.GuildKey(leader.guild)], "поздно отправленный запрос ещё действителен")
end)

T.test("link: запрос обгоняет повторяемые отправки GUILD после общей паузы", function()
    local w, officer, leader = Build()
    local send = officer.env.C_ChatInfo.SendAddonMessage
    officer.env.C_ChatInfo.SendAddonMessage = function(prefix, msg, dist, ...)
        if dist == "GUILD" then return 3 end
        return send(prefix, msg, dist, ...)
    end
    officer.ns.Comm.Send("GUILD", "Q1~", { prio = officer.ns.Comm.PRIO_CONTROL })
    officer.ns.Comm.Flush(1)
    T.ok(officer.ns.Security.Link(leader:Name()))
    w:Run(6)
    T.eq(leader:Saw("Запрос связи от"), 1, "после общей паузы сначала отправлен ручной запрос")
end)

T.test("link: неотправленный запрос не выдаётся за отправленный", function()
    local w, officer, leader = Build()
    local send = officer.env.C_ChatInfo.SendAddonMessage
    officer.env.C_ChatInfo.SendAddonMessage = function(prefix, msg, dist, ...)
        if dist == "WHISPER" then return 12 end
        return send(prefix, msg, dist, ...)
    end
    T.ok(officer.ns.Security.Link(leader:Name()))
    w:Run(10)
    T.eq(officer:Saw("Запрос связи отправлен"), 0, "ошибка API не считается отправкой")
    T.ok(officer:Saw("Передать запрос связи") > 0, "игрок видит отказ отправки")
end)

T.test("link: истечение запроса видно игроку и останавливает повторы", function()
    local w, officer, leader = Build()
    T.ok(officer.ns.Security.Link(leader:Name()))
    w:Run(210)
    T.eq(officer:Saw("Время ожидания подтверждения"), 1, "выведено понятное окончание ожидания")
    local sent = #w.log
    w:Run(60)
    for i = sent + 1, #w.log do
        local e = w.log[i]
        T.no(e.from == officer:Name() and e.msg:sub(1, 5) == "KL~H~", "просроченный запрос не повторяется")
    end
    T.eq(leader:Saw("Запрос связи от"), 1, "повторы не засоряют чат")
end)

T.test("link: временно несвежий ростер отправителя не отменяет соединение", function()
    local w, officer, leader = Build()
    T.ok(officer.ns.Security.Link(leader:Name()))
    local fresh, untilAt = officer.ns.Roster.Fresh, w.now + 20
    officer.ns.Roster.Fresh = function() return w.now >= untilAt and fresh() end
    w:Run(40)
    T.eq(leader:Saw("Запрос связи от"), 1, "после обновления ростера отправка возобновилась")
    T.eq(officer:Saw("Передать запрос связи"), 0, "временное ожидание ростера не выдаётся за окончательный отказ")
end)

T.test("link: новый запрос того же офицера требует отдельного подтверждения", function()
    local w, officer, leader = Build()
    w:Pair(leader, officer)
    T.ok(leader.ns.Security.Link(officer:Name()))
    w:Run(35)
    T.eq(officer:Saw("Запрос связи от"), 2, "новый nonce показан как новый запрос")
    local replies = 0
    for _, e in ipairs(w.log) do
        if e.from == officer:Name() and e.msg:sub(1, 5) == "KL~R~" then replies = replies + 1 end
    end
    T.eq(replies, 1, "новый запрос не подтверждён автоматически")
end)

T.test("link: повтор с изменённым корнем не получает автоматического ответа", function()
    local w, officer, leader = Build()
    w:Pair(leader, officer)
    local request
    for _, e in ipairs(w.log) do
        if e.from == leader:Name() and e.msg:sub(1, 5) == "KL~H~" then request = e.msg end
    end
    T.ok(request, "сохранён первоначальный запрос")
    local main = officer.ns.Security.Roots()[officer.ns.Util.GuildKey("Чиллзон")]
    local changed = request:gsub("~[%w_-]+$", "~" .. main.public)
    T.no(changed == request, "корень действительно подменён")
    leader.ns.Comm.Send("WHISPER", changed, { target = officer:Name(), prio = true })
    w:Run(20)
    local replies = 0
    for _, e in ipairs(w.log) do
        if e.from == officer:Name() and e.msg:sub(1, 5) == "KL~R~" then replies = replies + 1 end
    end
    T.eq(replies, 1, "одобрен только первоначальный корень")
    local root = officer.ns.Security.Roots()[officer.ns.Util.GuildKey(leader.guild)]
    T.no(root.public == main.public, "подмена не изменила доверие")
end)

T.test("link: отзыв корня прекращает автоматические ответы", function()
    local w, officer, leader = Build()
    LoseFirst(w, officer, "R")
    T.ok(leader.ns.Security.Link(officer:Name()))
    w:Run(5)
    T.ok(officer.ns.Security.Accept(leader:Name()))
    w:Run(5)
    T.ok(officer.ns.Security.Reset(leader.guild))
    w:Run(45)
    T.eq(officer.ns.Security.Roots()[officer.ns.Util.GuildKey(leader.guild)], nil, "повтор не возвращает отозванный корень")
    T.eq(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], nil, "после отзыва ответ не отправляется")
end)

T.test("link: потеря офицерских прав прекращает автоматические ответы", function()
    local w, officer, leader = Build()
    LoseFirst(w, officer, "R")
    T.ok(leader.ns.Security.Link(officer:Name()))
    w:Run(5)
    T.ok(officer.ns.Security.Accept(leader:Name()))
    w:Run(5)
    officer.rank = 3
    officer.ns.Roster.Scan()
    w:Run(45)
    T.eq(leader.ns.Security.Roots()[leader.ns.Util.GuildKey("Чиллзон")], nil, "бывший офицер больше не отвечает на запрос")
end)

T.test("link: офицер соединяет гильдии и передаёт перепись при корне вне игры", function()
    local w, officer, leader, root = Build()
    root.online = false
    officer.ns.Roster.Scan()
    LoseFirst(w, officer, "R")
    T.ok(leader.ns.Security.Link(officer:Name()))
    w:Run(5)
    T.ok(officer.ns.Security.Accept(leader:Name()))
    w:Run(240)
    T.ok(leader.ns.Security.Member("Чиллзон", officer:Name()), "Апдог получил сертификат самого офицера")
    T.ok(leader.ns.Relay.TrustOf(officer:Name()), "офицер известен как реле при корне вне игры")
    local row = officer.ns.Data.Row(leader.guild)
    T.ok(row and row.r, "перепись дошла через офицера без корневого персонажа")
end)
