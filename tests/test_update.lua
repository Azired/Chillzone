-- Предупреждение об устаревшем аддоне: версии из приветов H1 и отчётов R1, порог в два игрока.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local WARN = "вышла версия 0.9.0"

local function Member(w, first, version, opts)
	opts = opts or {}
	return w:Client({
		first = first, surname = opts.surname or "Тестовый", guild = opts.guild or "Чиллзон", rank = opts.rank or 3,
		db = opts.db, config = version and { VERSION = version } or nil,
	})
end

T.test("update: одного игрока с новой версией мало, двух достаточно, строка одна за сессию", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local old = Member(w, "Старый", "0.8.0")
	local first = Member(w, "Первый", "0.9.0")
	w:Run(120)
	T.eq(old.ns.Update.Available(), nil, "один игрок — ещё не выход версии")
	T.eq(old:Saw(WARN), 0, "строки в чате нет")
	T.eq(old.ns.Views.Title(), "Chillzone", "заголовок без предупреждения")
	local newest, n = old.ns.Update.Newest()
	T.eq(newest, "0.9.0", "новая версия услышана")
	T.eq(n, 1, "от одного игрока")

	Member(w, "Второй", "0.9.0")
	w:Run(60)
	T.eq(old.ns.Update.Available(), "0.9.0", "два игрока — версия вышла")
	T.eq(old:Saw(WARN), 1, "строка в чате")
	T.eq(old:Saw("у вас 0.8.0"), 1, "в строке своя версия")
	T.ok(old.ns.Views.Title():find(WARN, 1, true), "заголовок окна просит обновиться")
	w:Run(600)
	T.eq(old:Saw(WARN), 1, "за сессию строка одна")
	T.eq(first:Saw("вышла версия"), 0, "у обновлённых предупреждения нет")
end)

T.test("update: сборка с хвостом и откат не в счёт", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local old = Member(w, "Старый", "0.8.0")
	Member(w, "Тестер", "0.9.0-dev")
	local back = Member(w, "Откат", "0.9.0")
	w:Run(120)
	T.eq(old.ns.Update.Available(), nil, "тестовая сборка не второй игрок")
	local _, n = old.ns.Update.Newest()
	T.eq(n, 1, "в счёте только 0.9.0")
	back.ns.VERSION = "0.8.0"
	w:Run(120)
	T.eq(old.ns.Update.Newest(), nil, "вернулся на 0.8.0 — его 0.9.0 больше не в счёте")
	T.eq(old:Saw("вышла версия"), 0, "строки нет")
end)

T.test("update: 0.9.1 у одного и 0.9.0 у другого — вышла 0.9.0", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local old = Member(w, "Старый", "0.8.0")
	Member(w, "Новейший", "0.9.1")
	Member(w, "Новый", "0.9.0")
	w:Run(120)
	T.eq(old.ns.Update.Available(), "0.9.0", "вышедшая — та, что назвали оба")
	T.eq(old:Saw(WARN), 1, "строка про 0.9.0")
end)

T.test("update: услышанное помнится между входами и уходит после обновления", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local db = {}
	local old = Member(w, "Старый", "0.8.0", { db = db })
	local b = Member(w, "Первый", "0.9.0")
	local c = Member(w, "Второй", "0.9.0")
	w:Run(120)
	T.eq(old:Saw(WARN), 1, "предупреждение в первой сессии")
	old:Logout(); b:Logout(); c:Logout()

	local again = Member(w, "Старый", "0.8.0", { db = db })
	T.eq(again.ns.Update.Available(), "0.9.0", "сохранено на аккаунт")
	w:Run(5)
	T.eq(again:Saw(WARN), 0, "сразу после входа строки нет")
	w:Run(again.ns.Config.UPDATE_TELL_AFTER)
	T.eq(again:Saw(WARN), 1, "строка после входа без новых приветов")
	again:Logout()

	local updated = Member(w, "Старый", "0.9.0", { db = db })
	T.eq(updated.ns.Update.Available(), nil, "обновился — предупреждения нет")
	T.eq(next(db.versions), nil, "услышанное очищено")
	w:Run(60)
	T.eq(updated:Saw("вышла версия"), 0, "строки нет")
end)

T.test("update: услышанное старше UPDATE_KEEP забывается", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local db = {}
	local old = Member(w, "Старый", "0.8.0", { db = db })
	local b = Member(w, "Первый", "0.9.0")
	local c = Member(w, "Второй", "0.9.0")
	w:Run(120)
	T.eq(old.ns.Update.Available(), "0.9.0", "версия вышла")
	old:Logout(); b:Logout(); c:Logout()
	w.timers = {} -- все вышли; часы двигаем сразу, без двух недель таймеров
	w.now = w.now + old.ns.Config.UPDATE_KEEP + 60
	local again = Member(w, "Старый", "0.8.0", { db = db })
	T.eq(again.ns.Update.Available(), nil, "через UPDATE_KEEP забыто")
end)

T.test("update: версии репортёров других гильдий приходят в отчётах", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local a = Member(w, "Арагорн", "0.8.0", { surname = "Светлый", rank = 1 })
	local k = Member(w, "Карл", "0.8.0", { surname = "Великий", rank = 0 })
	local v = Member(w, "Вера", "0.9.0", { surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local g = Member(w, "Глеб", "0.9.0", { surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
	w:Run(30)
	w:Init(a, v, g)
	w:Pair(v, a)
	w:Pair(g, a)
	w:Run(400)
	T.ok(a.ns.Data.Row("Чиллзон Север"), "отчёт Севера дошёл")
	T.ok(a.ns.Data.Row("Орден Чиллзона"), "отчёт Ордена дошёл")
	T.eq(a.ns.Data.Row("Орден Чиллзона").r.version, "0.9.0", "в отчёте версия репортёра")
	for _, c in ipairs({ a, k }) do
		T.eq(c.ns.Update.Available(), "0.9.0", c:Name() .. ": версия вышла по отчётам")
		T.eq(c:Saw(WARN), 1, c:Name() .. ": строка в чате")
	end
	T.eq(v:Saw("вышла версия"), 0, "у обновлённых строки нет")
end)
