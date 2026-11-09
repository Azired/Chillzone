-- Подписанный импорт: права репортёра, сроки, повторы и независимые лимиты.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local head = w:Client({ first = "Глава", surname = "Гильдии", guild = "Чиллзон", rank = 0 })
	local reader = w:Client({ first = "Читатель", surname = "Гильдии", guild = "Чиллзон", rank = 3 })
	w:Run(30); w:Init(head); w:Run(80)
	T.ok(head.ns.Census.IsReporter(), "глава выбран репортёром")
	T.ok(reader.ns.Security.Member(head.guild, head:Name()), "сертификат репортёра уже проверен")
	return w, head, reader
end

local function Inner(head, id, at)
	return assert(head.ns.Codec.EncodeGuildImport(head.guild, id, at or head.ns.ServerTime(),
		"Автор Безаддона", "MAGE", "текст-" .. id))
end

local function Seal(w, head, inner)
	local wire
	T.ok(head.ns.Security.Seal(inner, function(value) wire = value end), "подпись поставлена в очередь")
	w:Run(0.1)
	T.ok(wire, "настоящая подпись готова")
	return wire
end

local function Pack(tag, fields)
	local out = { tag .. ":" }
	for _, value in ipairs(fields) do
		value = tostring(value)
		out[#out + 1] = #value .. ":" .. value
	end
	return table.concat(out)
end

-- Настоящая подпись с заданным временем конверта, в обход ограничений отправки.
local function Signed(head, inner, at, seq)
	local ns, seed = head.ns
	local cert, Ed = ns.Security.MyCertificate(), ns.Ed25519
	for _, key in pairs(ns.db.securityKeys) do seed = Ed.FromB64(key.seed) end
	local body = Pack("MESSAGE", { ns.group, ns.faction, cert.raw, at, seq, inner })
	local signature = Ed.ToB64(Ed.Sign(seed, body, cert.pk))
	return table.concat({ "S1", cert.fp, at, seq, signature, inner }, "~")
end

local function Hold(ns)
	local steps, Ed, after = {}, ns.Ed25519, ns.Ed25519.after
	Ed.after = function(fn) steps[#steps + 1] = fn end
	return function()
		local count = 0
		while steps[1] do
			count = count + 1
			T.ok(count < 100000, "очередь криптографии завершается")
			table.remove(steps, 1)()
		end
		Ed.after = after
	end
end

T.test("guild import security: подписывает только текущий репортёр своей гильдии", function()
	local w, head, reader = Build()
	T.no(reader.ns.Security.Seal(Inner(head, "member"), function() end), "сертификата участника недостаточно")
	local foreign = head.ns.Codec.EncodeGuildImport("Другая гильдия", "foreign", head.ns.ServerTime(), "Автор", nil, "строка")
	T.no(head.ns.Security.Seal(foreign, function() end), "репортёр не подписывает чужую гильдию")
	T.no(head.ns.Security.Seal(Inner(head, "old", head.ns.ServerTime() - head.ns.Config.IMPORT_TTL - 1), function() end))
	local drain, elected = Hold(head.ns), head.ns.Census.IsReporter
	local completed, result = false, true
	T.ok(head.ns.Security.Seal(Inner(head, "handover"), function(value) completed, result = true, value end))
	head.ns.Census.IsReporter = function() return false end
	drain()
	head.ns.Census.IsReporter = elected
	T.ok(completed)
	T.no(result, "смена репортёра во время подписи отменяет импорт")
	w:Run(0.1)
	T.eq(#head.ns.db.errors, 0)
end)

T.test("guild import security: оба времени проверяются до подписи, после неё и в кэше", function()
	local w, head, reader = Build()
	local S, opened, now = reader.ns.Security, 0, head.ns.ServerTime()
	local old = now - head.ns.Config.IMPORT_TTL - 1
	for _, wire in ipairs({ Signed(head, Inner(head, "native-old", old), now, 10001),
		Signed(head, Inner(head, "envelope-old", now), old, 10002) }) do
		T.no(S.Open(wire, head:Name(), function() opened = opened + 1 end), "просроченное время отклонено")
	end
	local wire = Seal(w, head, Inner(head, "cache"))
	T.ok(S.Open(wire, head:Name(), function() opened = opened + 1 end))
	w:Run(0.1)
	T.eq(opened, 1)
	T.ok(S.Open(wire, head:Name(), function() opened = opened + 1 end), "свежий кэш доступен другому обработчику")
	T.eq(opened, 2)
	T.ok(head.ns.Security.Own(wire))
	reader.clockSkew, head.clockSkew = 31, 31
	T.no(S.Open(wire, head:Name(), function() opened = opened + 1 end), "кэш не продлевает срок")
	T.no(head.ns.Security.Own(wire), "свой кэш тоже не продлевает срок")
	reader.clockSkew, head.clockSkew = 0, 0
	local delayed = Seal(w, head, Inner(head, "delayed"))
	local drain = Hold(reader.ns)
	T.ok(S.Open(delayed, head:Name(), function() opened = opened + 1 end))
	reader.clockSkew = 31
	drain()
	T.eq(opened, 2, "импорт истёк во время асинхронной проверки")
	T.eq(#reader.ns.db.errors, 0)
end)

T.test("guild import security: изменение текста и повтор после reload отклоняются", function()
	local w, head, reader = Build()
	local wire = Seal(w, head, Inner(head, "replay"))
	local opened = 0
	reader.ns.Security.Open((wire:gsub("текст%-replay", "подменённый текст")), head:Name(), function() opened = opened + 1 end)
	w:Run(0.1)
	T.eq(opened, 0, "изменение вложенного G1 ломает подпись")
	reader.ns.Security.Open(wire, head:Name(), function() opened = opened + 1 end)
	w:Run(0.1)
	T.eq(opened, 1)
	local db = reader.ns.db
	reader:Logout()
	local back = w:Client({ first = "Читатель", surname = "Гильдии", guild = "Чиллзон", rank = 3, db = db })
	w:Run(0.1)
	back.ns.Security.Open(wire, head:Name(), function() opened = opened + 1 end)
	w:Run(0.1)
	T.eq(opened, 1, "защита G1 от повторов сохранена в SavedVariables")
	T.eq(#back.ns.db.errors, 0)
end)

T.test("guild import security: лимит гильдии G1 не расходует личный бюджет M1", function()
	local w, head, reader = Build()
	local imported, regular = 0, 0
	for i = 1, head.ns.Config.IMPORT_GUILD_PER_MIN do
		local wire = Seal(w, head, Inner(head, "budget-" .. i))
		T.ok(reader.ns.Security.Open(wire, head:Name(), function() imported = imported + 1 end))
		w:Run(0.1)
	end
	T.eq(imported, head.ns.Config.IMPORT_GUILD_PER_MIN)
	local extra = Seal(w, head, Inner(head, "budget-extra"))
	T.no(reader.ns.Security.Open(extra, head:Name(), function() imported = imported + 1 end))
	local ordinary = Seal(w, head, head.ns.Codec.EncodeChat("A", head.guild, 1234, "MAGE", "обычный чат"))
	T.ok(reader.ns.Security.Open(ordinary, head:Name(), function() regular = regular + 1 end))
	w:Run(0.1)
	T.eq(regular, 1, "M1 сохраняет собственный бюджет автора")
	T.eq(imported, head.ns.Config.IMPORT_GUILD_PER_MIN)
end)

T.test("guild import security: лимит пересылающего G1 отделён от обычного реле", function()
	local w, head, reader = Build()
	local base = Seal(w, head, Inner(head, "hop-original"))
	local opened = 0
	for i = 1, head.ns.Config.IMPORT_HOP_PER_MIN do
		local forged = base:gsub("текст%-hop%-original", "подмена " .. i)
		T.ok(reader.ns.Security.Open(forged, head:Name(), function() opened = opened + 1 end))
		w:Run(0.1)
	end
	T.eq(opened, 0)
	T.no(reader.ns.Security.Open(base, head:Name(), function() opened = opened + 1 end), "бюджет G1 пересылающего исчерпан")
	local ordinary = Seal(w, head, head.ns.Codec.EncodeChat("A", head.guild, 1235, "MAGE", "живой личный чат"))
	T.ok(reader.ns.Security.Open(ordinary, head:Name(), function() opened = opened + 1 end))
	w:Run(0.1)
	T.eq(opened, 1, "подделки G1 не блокируют проверку M1 того же пересылающего")
end)

T.test("guild import security: четыре проверки G1 оставляют место обычным сообщениям", function()
	local w, head, reader = Build()
	local imported = Seal(w, head, Inner(head, "pending"))
	local ordinary = Seal(w, head, head.ns.Codec.EncodeChat("A", head.guild, 1236, "MAGE", "ожидающий чат"))
	local drain = Hold(reader.ns)
	for i = 1, reader.ns.Config.IMPORT_VERIFY_PENDING do
		T.ok(reader.ns.Security.Open(imported .. i, head:Name(), function() end))
	end
	T.no(reader.ns.Security.Open(imported .. "extra", head:Name(), function() end), "пятый импорт не занимает очередь")
	for i = 1, 32 - reader.ns.Config.IMPORT_VERIFY_PENDING do
		T.ok(reader.ns.Security.Open(ordinary .. i, head:Name(), function() end), "обычный пакет имеет свободный слот")
	end
	T.no(reader.ns.Security.Open(ordinary .. "extra", head:Name(), function() end), "общий предел остался 32")
	drain()
	T.eq(#reader.ns.db.errors, 0)
end)
