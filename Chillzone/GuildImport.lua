-- Обычный /ги сразу виден в A. Его выбранный репортёр подписывает наблюдение G1
-- своим сертификатом и передаёт существующему Relay, без отдельных соединений.
local ADDON, ns = ...
local U, C, Codec = ns.Util, ns.Config, ns.Codec
local Import = { stats = { localLines = 0, received = 0, queued = 0, limited = 0, dropped = 0 } }
ns.GuildImport = Import
local observed, remembered, authors = {}, {}, {}
local minute, count, sequence, epoch = 0, 0, 0, 0
local pending, nonce

local function IsSecret(value)
	return type(issecretvalue) == "function" and issecretvalue(value)
end

local function Once(cache, key)
	if cache[key] then return false end
	local slot = (cache.slot or 0) % 256 + 1
	local old = cache[slot]
	if old then cache[old] = nil end
	cache.slot, cache[slot], cache[key] = slot, key, true
	return true
end

local function Remember(guild, author, class, text, at)
	local key = U.Key(author)
	if not ns.char or not ns.char.chatOn or not key or (ns.store and ns.store.ignore[key]) then return end
	-- При получении импорт не выводится в игровые вкладки через Chat.Show.
	ns.Chat.Remember("A", guild, author, class, text, at, true)
end

function Import.Ready()
	return ns.Relay.CanSendImport()
end

local function Permit(author)
	local now = ns.Now()
	if now - minute >= 60 then minute, count, authors = now, 0, {} end
	local key = U.Key(author)
	if count >= C.IMPORT_GUILD_PER_MIN or (authors[key] or 0) >= C.IMPORT_AUTHOR_PER_MIN then return false end
	count, authors[key] = count + 1, (authors[key] or 0) + 1
	return true
end

ns.RegisterEvent("CHAT_MSG_GUILD", function(raw, sender, ...)
	if IsSecret(raw) or IsSecret(sender) or type(raw) ~= "string" or type(sender) ~= "string" then return end
	if not ns.IsMember() or ns.GuildChat.IsMirror(raw) then return end
	local line, guid = select(9, ...), select(10, ...)
	local guild, author, at = ns.MyGuild(), U.Display(sender), ns.ServerTime()
	local class = ns.GuildChat.ClassOf(sender, guid)
	local text = Codec.SanitizeChat(raw)
	-- Проверяем те же поля и предел текста, что принимают удалённые читатели.
	if not Codec.EncodeGuildImport(guild, "local", at, author, class, text) then return end
	if not IsSecret(line) and type(line) == "number" and line > 0
		and not Once(observed, U.GuildKey(guild) .. "~" .. line) then return end
	Remember(guild, author, class, text, at)
	Import.stats.localLines = Import.stats.localLines + 1
	if not Import.Ready() then return end
	-- Не заполняем общую очередь подписей и оставляем транспорт другим сообщениям.
	if pending or ns.Comm.ImportQueued() >= C.IMPORT_QUEUE_MAX or not Permit(author) then
		Import.stats.limited = Import.stats.limited + 1
		return
	end
	nonce = nonce or (at .. "-" .. U.Hash(tostring({}) .. ns.Now()))
	sequence = sequence + 1
	local inner = Codec.EncodeGuildImport(guild, nonce .. "-" .. sequence, at, author, class, text)
	local token, generation = {}, epoch
	pending = token
	local accepted = ns.Security.Seal(inner, function(wire)
		if pending == token then pending = nil end
		if not wire or generation ~= epoch or not Import.Ready() or ns.ServerTime() - at > C.IMPORT_TTL then
			Import.stats.dropped = Import.stats.dropped + 1
			return
		end
		if ns.Relay.Out("P", wire) then Import.stats.queued = Import.stats.queued + 1
		else Import.stats.dropped = Import.stats.dropped + 1 end
	end)
	if not accepted then
		if pending == token then pending = nil end
		Import.stats.dropped = Import.stats.dropped + 1
	end
end)

ns.Comm.On("G1", function(msg, sender, dist, ctx)
	if dist ~= "RELAY" or not ctx or not ctx.authenticated or not ns.IsMember() then return end
	local d, cert = Codec.DecodeGuildImport(msg), ctx.certificate
	if not d or not cert or cert.key ~= U.Key(sender) or U.GuildKey(cert.guild) ~= U.GuildKey(d.guild)
		or not U.IsMemberGuild(d.guild) or U.GuildKey(d.guild) == U.GuildKey(ns.MyGuild())
		or d.at > ns.ServerTime() + 3 or ns.ServerTime() - d.at > C.IMPORT_TTL then return end
	if not Once(remembered, U.GuildKey(d.guild) .. "~" .. cert.key .. "~" .. d.id) then return end
	Remember(d.guild, d.author, d.class, d.text, d.at)
	Import.stats.received = Import.stats.received + 1
end)

local function Cancel()
	epoch, pending = epoch + 1, nil
end
ns.On("REPORTER", Cancel)
ns.On("GUILD_CHANGED", function()
	Cancel()
	minute, count, authors = ns.Now(), 0, {}
end)

ns.Command("bridge", function(arg)
	local L = ns.L
	if U.Trim(arg) ~= "" then ns.Print(L.GUILD_IMPORT_USAGE); return end
	if not ns.IsMember() then ns.Print(L.GUILD_IMPORT_OFF); return end
	ns.Print(L.GUILD_IMPORT_LOCAL)
	if not ns.Census.IsReporter() then ns.Print(L.GUILD_IMPORT_OPERATOR, ns.Census.ReporterName() or "-"); return end
	ns.Print(Import.Ready() and L.GUILD_IMPORT_READY or L.GUILD_IMPORT_WAIT)
	ns.Print(L.GUILD_IMPORT_LIMITS, C.IMPORT_AUTHOR_PER_MIN, C.IMPORT_GUILD_PER_MIN,
		Import.stats.limited + Import.stats.dropped)
end, ns.L.HELP_BRIDGE)
