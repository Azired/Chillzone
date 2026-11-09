-- Chillzone: общий чат гильдий «Чиллзон». /cz1 — все, /cz2 — офицеры, /cz3 — главы
-- гильдий и офицеры главной гильдии. Строка уходит двумя путями (M1 по GUILD — своей
-- гильдии, через реле — остальным), на приёме оба сходятся в Chat.Receive с дедупликацией.
-- Скрытого канала нет: его мог открыть /join любой, кто знает название, и писать от имени
-- любой гильдии. Из каналов прежних версий аддон выходит при входе.
-- Строки хранятся в истории и уходят событием CHAT в окно Chillzone (ChatPane.lua); копия —
-- в чат игры, с меткой канала-ссылкой: клик по ней открывает окно на этом канале.
-- Формат вывода и окно вывода — по образцу Olympus Channels.lua.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Chat = {}
ns.Chat = Chat

Chat.TIER_LEVEL = { A = 1, C = 2, L = 3 }
Chat.TIER_COLOR = { A = "ff7fd4c1", C = "ff6fa8ff", L = "ffffb347" }
Chat.TAG_LINK = "addon:Chillzone:chan:"
-- Каналы окна по порядку: чат гильдии, офицеры гильдии, затем три уровня «Чиллзон».
Chat.ORDER = { "G", "O", "A", "C", "L" }
Chat.GUILD_CHANNELS = { G = true, O = true }
local RGB = { G = { 0.25, 1, 0.25 }, O = { 0.25, 0.75, 0.25 } }
-- Цвета текста общего чата на выбор в настройках. Первый — по умолчанию, как у метки [Чиллзон].
Chat.COLORS = { "7fd4c1", "ffffff", "ffe066", "ffb347", "ff8080", "ff8fd0", "c79bff", "6fa8ff", "6fe0ff", "8fe36f" }
Chat.stats = { sent = 0, shown = 0, dupes = 0, refused = 0, limited = 0 }
-- Почему своя строка не подписана (Security.Seal): что сказать игроку.
local SEAL_FAILED = {
	busy = L.CHAT_SEAL_BUSY, failed = L.CHAT_SEAL_FAILED, long = L.CHAT_SEAL_LONG,
}

local seen = {} -- [Key#id#text] = время
local buckets = {} -- [Key] = { n, t }
local tierMinute = {} -- [tier] = { n, t0 }
local lastSend = -1e9
local nextId = math.random(0, 9999)

---------------------------------------------------------------------------
-- Уровни
---------------------------------------------------------------------------

-- Уровень по рангу в гильдии: 3 — глава или офицер главной гильдии, 2 — офицер, 1 — участник.
-- officer — офицерское ли звание (Roster.IsOfficerRank или список офицеров в отчёте); nil —
-- по Config.OFFICER_RANK.
function Chat.LevelOf(guild, rank, officer)
	if rank == nil then return 1 end
	if rank == 0 then return 3 end
	if officer == nil then officer = rank <= C.OFFICER_RANK end
	if officer then return U.IsMainGuild(guild) and 3 or 2 end
	return 1
end

function Chat.MyLevel()
	local g, rank = ns.MyGuild()
	if not g or not U.IsMemberGuild(g) then return 0 end
	return Chat.LevelOf(g, rank, ns.Roster.IsOfficerRank(rank))
end

-- Уровень отправителя, насколько я могу его проверить. 0 — подделка.
function Chat.VerifiedLevel(guild, sender)
	local mine = ns.MyGuild()
	local myRank = ns.Roster.RankOf(sender)
	if mine and U.GuildKey(guild) == U.GuildKey(mine) then
		if myRank == nil then return 0 end -- назвался моей гильдией, но его нет в ростере
		return Chat.LevelOf(guild, myRank, ns.Roster.IsOfficerRank(myRank))
	end
	if myRank ~= nil then return 0 end -- согильдиец назвался другой гильдией
	-- В отчёте чужой гильдии есть только глава и офицеры: ранг известен — значит, офицер.
	local c = ns.Security.Member(guild, sender)
	return c and ns.Security.Level(c) or 0
end

---------------------------------------------------------------------------
-- Вывод
---------------------------------------------------------------------------
-- Вкладки чата игры, которые сейчас открыты: { { name, frame } } по номеру окна. Закрытое окно
-- (не показано и не пристыковано) пропускаем: строки в нём никто не увидит. Журнал боя — тоже:
-- это особое окно игры. Окна только читаем, ничего в них не меняем (taint).
function Chat.Windows()
	local out = {}
	local info = GetChatWindowInfo or FCF_GetChatWindowInfo
	if type(info) ~= "function" then return out end
	local combat = rawget(_G, "COMBATLOG") or rawget(_G, "ChatFrame2")
	for i = 1, (tonumber(NUM_CHAT_WINDOWS) or 10) do
		local f = rawget(_G, "ChatFrame" .. i)
		if type(f) == "table" and type(f.AddMessage) == "function" and f ~= combat then
			local ok, name, _, _, _, _, _, shown, _, docked = pcall(info, i)
			if ok and type(name) == "string" and name ~= "" and (shown or docked or rawget(f, "isDocked")) then
				out[#out + 1] = { name = name, frame = f }
			end
		end
	end
	return out
end

local function WindowByName(name)
	if type(name) ~= "string" or name == "" then return nil end
	for _, w in ipairs(Chat.Windows()) do
		if U.Fold(w.name) == U.Fold(name) then return w end
	end
	return nil
end

-- Список выбранных названий; пустая строка — основное окно независимо от его названия.
-- Прежний одиночный выбор переносим даже для закрытой вкладки.
function Chat.SelectedWindows()
	if not ns.char then return { "" } end
	if type(ns.char.chatWindows) ~= "table" or #ns.char.chatWindows == 0 then
		local name = ns.char.chatWindow or ""
		local w = WindowByName(name)
		ns.char.chatWindows = { w and w.frame == DEFAULT_CHAT_FRAME and "" or name }
	end
	return ns.char.chatWindows
end

ns.On("LOGIN", Chat.SelectedWindows)

function Chat.WindowSelected(name)
	for _, chosen in ipairs(Chat.SelectedWindows()) do
		if U.Fold(chosen) == U.Fold(name) then return true end
	end
	return false
end

local windowWarned = {} -- о каких пропавших вкладках уже предупредили

-- Куда писать копии строк: name — название вкладки, nil или "" — основное окно. Вкладку
-- ищем без учёта регистра, запоминаем её название как в игре. false — такой вкладки нет.
function Chat.SetWindow(name)
	if not name or name == "" then
		ns.char.chatWindows = { "" }
		windowWarned = {}
		return true
	end
	local w = WindowByName(name)
	if not w then return false end
	ns.char.chatWindows = { w.frame == DEFAULT_CHAT_FRAME and "" or w.name }
	windowWarned = {}
	return true
end

-- Галочка в настройках добавляет или убирает вкладку, оставляя хотя бы одну.
-- Выключение всех копий — отдельная настройка chatMirror.
function Chat.ToggleWindow(name)
	local w = name ~= "" and WindowByName(name)
	if w and w.frame == DEFAULT_CHAT_FRAME then name = "" end
	local chosen = Chat.SelectedWindows()
	for i, value in ipairs(chosen) do
		if U.Fold(value) == U.Fold(name) then
			if #chosen == 1 then return false end
			table.remove(chosen, i)
			windowWarned[value] = nil
			return true
		end
	end
	if name ~= "" and not w then return false end
	chosen[#chosen + 1] = name == "" and "" or w.name
	return true
end

function Chat.Frames()
	local out, used, missing = {}, {}, {}
	for _, name in ipairs(Chat.SelectedWindows()) do
		local w = name ~= "" and WindowByName(name)
		local f = name == "" and DEFAULT_CHAT_FRAME or (w and w.frame)
		if f then
			windowWarned[name] = nil
			if not used[f] then out[#out + 1], used[f] = f, true end
		else
			missing[#missing + 1] = name
		end
	end
	-- Пока открыта хоть одна выбранная вкладка, пишем только в выбранные.
	-- Если пропали все, одна резервная копия идёт в основное окно.
	if #out == 0 then
		out[1] = DEFAULT_CHAT_FRAME
		for _, name in ipairs(missing) do
			if not windowWarned[name] then
				windowWarned[name] = true
				ns.Print(L.CHAT_WINDOW_GONE, name)
			end
		end
	end
	return out
end

-- Метка канала в чате игры: ссылка addon:Chillzone:chan:<tier>, цветом канала.
function Chat.Tag(tier)
	return "|c" .. Chat.TIER_COLOR[tier] .. "|H" .. Chat.TAG_LINK .. tier .. "|h[" .. L["TIER_" .. tier] .. "]|h|r"
end

-- Короткая метка гильдии только в строках чата; полное имя хранится в истории.
function Chat.GuildTag(guild)
	local name = Codec.Plain(guild or "?")
	return L.CHAT_GUILD_TAGS[U.Fold(name)] or name
end

function Chat.Format(tier, guild, sender, class, text)
	local name = U.Display(sender)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.colorStr then name = "|c" .. color.colorStr .. name .. "|r" end
	local g = Chat.GuildTag(guild)
	return Chat.Tag(tier) .. " |cff999999<" .. g .. ">|r |Hplayer:" .. (U.TellName(sender) or "?") .. "|h[" .. name .. "]|h: " .. Codec.SanitizeChat(text)
end

-- Цвет текста общего чата, rrggbb: выбранный в настройках или первый из Chat.COLORS.
function Chat.TextColor()
	local hex = ns.db and ns.db.settings and ns.db.settings.chatColor
	if type(hex) == "string" and hex:match("^%x%x%x%x%x%x$") then return hex end
	return Chat.COLORS[1]
end

function Chat.HexToRGB(hex)
	return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- Цвет строк канала: чат гильдии и офицеров — как в игре, уровни «Чиллзон» — общий, из настроек.
-- Окно и копия в чате игры берут его здесь, поэтому совпадают.
function Chat.Color(channel)
	if not Chat.GUILD_CHANNELS[channel] then return Chat.HexToRGB(Chat.TextColor()) end
	local info = rawget(_G, "ChatTypeInfo")
	local t = type(info) == "table" and info[channel == "O" and "OFFICER" or "GUILD"]
	if type(t) == "table" and t.r then return t.r, t.g, t.b end
	local c = RGB[channel]
	return c[1], c[2], c[3]
end

function Chat.Label(channel)
	if channel == "G" then return ns.MyGuild() or L.CHAN_GUILD end
	if channel == "O" then return L.CHAN_OFFICER end
	return L["TIER_" .. channel]
end

-- Подпись в поле ввода: чат гильдии — «Гильдия», как в чате игры; остальные — по названию.
function Chat.Prompt(channel)
	if channel == "G" then return L.CHAN_GUILD end
	return Chat.Label(channel)
end

-- Чей канал: своей гильдии или всех гильдий «Чиллзон»; long — для шапки, с командой /cz1–3.
-- Без этого чат гильдии «Чиллзон» и общий канал «Чиллзон» в списке не различить.
function Chat.Scope(channel, long)
	if Chat.GUILD_CHANNELS[channel] then return L.SCOPE_GUILD end
	if long then return L.SCOPE_ALL_CMD:format(Chat.TIER_LEVEL[channel] or 1) end
	return L.SCOPE_ALL
end

-- Строки канала, старые первыми: { t, s (имя), g (гильдия), c (класс), x (текст) }.
function Chat.History(channel)
	if Chat.GUILD_CHANNELS[channel] then
		local h = ns.char and ns.char.history
		return h and h[channel] or {}
	end
	return ns.store and ns.store.chat[channel] or {}
end

-- Добавить строку в историю канала (не больше CHAT_HISTORY) и сообщить окну.
function Chat.Remember(channel, guild, sender, class, text)
	local list = Chat.History(channel)
	local e = { t = ns.ServerTime(), s = U.Display(sender), g = guild, c = class, x = text }
	list[#list + 1] = e
	while #list > C.CHAT_HISTORY do table.remove(list, 1) end
	ns.Fire("CHAT", channel, e)
	return e
end

function Chat.Show(tier, guild, sender, class, text)
	Chat.stats.shown = Chat.stats.shown + 1
	if not ns.char or ns.char.chatMirror ~= false then
		local stamp = (ns.char and ns.char.chatTime and date) and ("|cff999999" .. date("%H:%M", ns.ServerTime()) .. "|r ") or ""
		local line = stamp .. Chat.Format(tier, guild, sender, class, text)
		for _, f in ipairs(Chat.Frames()) do f:AddMessage(line, Chat.Color(tier)) end
	end
	Chat.Remember(tier, guild, sender, class, text)
end

-- Каналы, доступные мне сейчас, в порядке окна.
function Chat.Channels()
	local out = {}
	if ns.MyGuild() then
		out[#out + 1] = "G"
		if ns.GuildChat and ns.GuildChat.CanOfficer() then out[#out + 1] = "O" end
	end
	local level = Chat.MyLevel()
	for _, tier in ipairs({ "A", "C", "L" }) do
		if level >= Chat.TIER_LEVEL[tier] then out[#out + 1] = tier end
	end
	return out
end

---------------------------------------------------------------------------
-- Приём
---------------------------------------------------------------------------
local function Bucket(key, now)
	local b = buckets[key]
	if not b then
		b = { n = C.CHAT_BURST, t = now }
		buckets[key] = b
	end
	b.n = math.min(C.CHAT_BURST, b.n + (now - b.t) / C.CHAT_REFILL)
	b.t = now
	if b.n < 1 then return false end
	b.n = b.n - 1
	return true
end

local function TierOk(tier, now)
	local m = tierMinute[tier]
	if not m or now - m.t0 >= 60 then
		tierMinute[tier] = { n = 1, t0 = now }
		return true
	end
	m.n = m.n + 1
	return m.n <= C.CHAT_TIER_MIN
end

function Chat.Receive(msg, sender, dist, ctx)
	if dist ~= "GUILD" and dist ~= "RELAY" then return end
	if not ctx or not ctx.authenticated then return end
	local d = Codec.DecodeChat(msg)
	if not d or ns.IsMe(sender) or not ns.IsMember() then return end
	if not U.IsMemberGuild(d.guild) then return end
	local key = U.Key(sender)
	if not key or (ns.store and ns.store.ignore[key]) then return end
	local mine = U.GuildKey(ns.MyGuild())
	local theirs = U.GuildKey(d.guild)
	if dist == "GUILD" and theirs ~= mine then return end -- по GUILD пишут только согильдийцы
	if dist == "RELAY" and theirs == mine then return end -- своя гильдия приходит напрямую
	local now = ns.Now()
	local dk = key .. "#" .. d.id .. "#" .. d.text
	if seen[dk] and now - seen[dk] <= C.CHAT_DEDUPE then
		Chat.stats.dupes = Chat.stats.dupes + 1
		return
	end
	seen[dk] = now
	local need = Chat.TIER_LEVEL[d.tier]
	if Chat.MyLevel() < need then return end -- не мой уровень
	if Chat.VerifiedLevel(d.guild, sender) < need then
		Chat.stats.refused = Chat.stats.refused + 1
		ns.Log("строка %s от %s <%s> отклонена: уровень не подтверждён", d.tier, U.Display(sender), d.guild)
		return
	end
	if not ns.char.chatOn then return end
	if not Bucket(key, now) or not TierOk(d.tier, now) then
		Chat.stats.limited = Chat.stats.limited + 1
		return
	end
	Chat.Show(d.tier, d.guild, sender, d.class, d.text)
end

ns.Comm.On("M1", Chat.Receive)

---------------------------------------------------------------------------
-- Отправка (из слэш-команды или Enter в окне). true — строка ушла.
---------------------------------------------------------------------------
function Chat.Send(tier, text)
	if not ns.me then return false end
	local guild = ns.MyGuild()
	if not guild or not U.IsMemberGuild(guild) then
		ns.Print(L.CHAT_NOT_MEMBER)
		return false
	end
	local need = Chat.TIER_LEVEL[tier]
	if Chat.MyLevel() < need then
		ns.Print(L.CHAT_NO_RIGHTS, L["TIER_" .. tier])
		return false
	end
	local mine = ns.Security.MyCertificate()
	if not mine then ns.Print("%s", ns.Security.NotReadyReason()); return false end
	-- Получатели проверяют уровень по сертификату (Security.Level), а не по званию в ростере:
	-- роль в сертификате подтверждена лишь AUTH_ROLE_TTL после выдачи. Строку с устаревшей
	-- ролью они отклонили бы молча — лучше сказать об этом здесь.
	if ns.Security.Level(mine) < need then
		ns.Print(L.CHAT_ROLE_STALE, L["TIER_" .. tier])
		return false
	end
	text = Codec.SanitizeChat(text)
	if text == "" then
		ns.Print(L.CHAT_USAGE)
		return false
	end
	local now = ns.Now()
	if now - lastSend < C.CHAT_GAP then
		ns.Print(L.CHAT_TOO_FAST)
		return false
	end
	lastSend = now
	if not ns.char.warned then
		ns.char.warned = true
		ns.Print(L.CHAT_WARNING)
	end
	local _, class = UnitClass("player")
	local budget = math.min(C.CHAT_PART, Codec.ChatBudget(guild, Codec.CLASS_CODE[class or ""] or ""))
	local parts, cut = Codec.SplitChat(text, budget, C.CHAT_PARTS)
	-- Подпись идёт асинхронно и может не получиться и в очереди, и позже. Причину игрок
	-- видит один раз на строку.
	local told = false
	local function Failed(why)
		if told then return end
		told = true
		ns.Print("%s", why == "nocert" and ns.Security.NotReadyReason() or SEAL_FAILED[why] or L.CHAT_SEAL_FAILED)
	end
	local queued = 0
	for _, part in ipairs(parts) do
		nextId = (nextId + 1) % 10000
		local msg = Codec.EncodeChat(tier, guild, nextId, class, part)
		if msg then
			local id, textPart = nextId, part
			local ok, why = ns.Security.Seal(msg, function(wire, failed)
				if not wire then Failed(failed); return end
				ns.Comm.Send("GUILD", wire, { prio = true, logged = true })
				ns.Relay.Out("P", wire)
				seen[ns.myKey .. "#" .. id .. "#" .. textPart] = now
				Chat.Show(tier, guild, ns.me, class, textPart)
				Chat.stats.sent = Chat.stats.sent + 1
				ns.SafeCall("guild mirror", ns.GuildChat.Mirror, tier, textPart)
			end)
			if not ok then
				Failed(why)
				break
			end
			queued = queued + 1
		end
	end
	if queued == 0 then
		if not told then Failed("failed") end
		lastSend = -1e9 -- ничего не ушло: повтор не считается частым
		return false
	end
	ns.Comm.Flush(2)
	if cut then ns.Print(L.CHAT_CUT) end
	return true
end

-- Кому шепчем: «Имя-Фамилия текст», «Имя Фамилия текст» (на Forever имена из двух слов)
-- или «Имя текст». Возвращает имя для шёпота и текст.
function Chat.ParseWhisper(rest)
	rest = U.Trim(rest)
	local first, after = rest:match("^(%S+)%s*(.-)$")
	if not first then return nil end
	if first:find("-", 1, true) or not ns.splitNames then return U.TellName(first), after end
	local second, text = after:match("^(%S+)%s*(.-)$")
	if not second then return nil end
	return U.TellName(first .. " " .. second), text
end

local WHISPER = { w = true, whisper = true, t = true, tell = true, ["ш"] = true }

-- Строка из поля ввода окна в канал channel. ok — ушла (поле можно очистить).
function Chat.Submit(channel, text)
	text = U.Trim(text)
	if text == "" then return false end
	local cmd, rest = text:match("^/(%S+)%s*(.-)$")
	if cmd then
		if not WHISPER[U.Fold(cmd)] then
			ns.Print(L.CHAT_BOX_COMMANDS)
			return false
		end
		local target, said = Chat.ParseWhisper(rest)
		said = U.Trim(said)
		if not target or said == "" then
			ns.Print(L.CHAT_WHISPER_USAGE)
			return false
		end
		SendChatMessage(U.Cut(said, 255), "WHISPER", nil, target)
		return true
	end
	if Chat.GUILD_CHANNELS[channel] then return ns.GuildChat.Send(channel, text) end
	if not Chat.TIER_LEVEL[channel] then return false end
	return Chat.Send(channel, text)
end

-- Нумерованные алиасы отправляют любой текст в выбранный канал.
-- Ввод остаётся в игровом поле; разбор выполняется только после Enter.
for i, tier in ipairs({ "A", "C", "L" }) do
	_G["SLASH_CHILLZONE" .. tier .. "1"] = "/cz" .. i
	_G["SLASH_CHILLZONE" .. tier .. "2"] = "/чз" .. i
	SlashCmdList["CHILLZONE" .. tier] = function(msg)
		if U.Trim(msg) == "" then
			if Chat.MyLevel() < Chat.TIER_LEVEL[tier] then
				ns.Print(L.CHAT_NO_RIGHTS, L["TIER_" .. tier])
				return
			end
			ns.SafeCall("/cz" .. i, ns.UI.OpenChat, tier, true)
			return
		end
		ns.SafeCall("/cz" .. i, Chat.Send, tier, msg or "")
	end
end
-- Короткие алиасы: известная команда выполняется, остальной текст уходит всем.
_G.SLASH_CHILLZONECHAT1 = "/cz"
_G.SLASH_CHILLZONECHAT2 = "/чз"
_G.SLASH_CHILLZONECHAT3 = "/чиллзон"
SlashCmdList.CHILLZONECHAT = function(msg)
	if not ns.me then return end
	if not ns.RunCommand(msg) then SlashCmdList.CHILLZONEA(msg) end
end

---------------------------------------------------------------------------
-- Клик по метке канала в чате игры. Ссылки addon: игра на Forever отдаёт своему
-- обработчику, который ничего не делает (проверено Olympus, Channels.lua 1.2.1); мы
-- ловим клик пост-хуком SetItemRef и открываем своё окно — поле ввода игры не трогаем.
---------------------------------------------------------------------------
function Chat.TagClick(link, _, button)
	if type(link) ~= "string" or link:sub(1, #Chat.TAG_LINK) ~= Chat.TAG_LINK then return false end
	if button and button ~= "LeftButton" then return false end
	local tier = link:sub(#Chat.TAG_LINK + 1)
	if not Chat.TIER_LEVEL[tier] or not (ns.UI and ns.UI.OpenChat) then return false end
	ns.UI.OpenChat(tier, true)
	return true
end

ns.On("LOGIN", function()
	local hook = rawget(_G, "hooksecurefunc")
	if type(hook) ~= "function" then return end
	pcall(hook, "SetItemRef", function(link, text, button)
		ns.SafeCall("tag click", Chat.TagClick, link, text, button)
	end)
end)

---------------------------------------------------------------------------
-- Скрытые каналы прежних версий. Игра сама возвращает персонажа в пользовательские
-- каналы при входе: выходим из них, а их строки и уведомления (сырой «M1~...» старых
-- клиентов) прячем, пока выход не прошёл.
---------------------------------------------------------------------------
local function OldChannel(baseName)
	if type(baseName) ~= "string" then return false end
	local f = U.Fold(baseName)
	for _, name in ipairs(C.OLD_CHANNELS or {}) do
		if U.Fold(name) == f then return true end
	end
	return false
end
Chat.IsOldChannel = OldChannel

function Chat.LeaveOldChannels()
	if not GetChannelName or not LeaveChannelByName then return 0 end
	local n = 0
	for _, name in ipairs(C.OLD_CHANNELS or {}) do
		local id = GetChannelName(name)
		if (tonumber(id) or 0) > 0 then
			LeaveChannelByName(name)
			n = n + 1
			ns.Log("вышел из старого канала %s", name)
		end
	end
	return n
end

local function HideOld(_, _, _, _, _, _, _, _, _, _, baseName)
	return OldChannel(baseName)
end
for _, event in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
	ns.AddChatFilter(event, HideOld)
end

ns.On("LOGIN", function()
	ns.After(5, "leave old channels", Chat.LeaveOldChannels)
	ns.After(30, "leave old channels again", Chat.LeaveOldChannels)
end)

---------------------------------------------------------------------------
-- Команды
---------------------------------------------------------------------------
ns.Command("chat", function(arg)
	arg = U.Fold(U.Trim(arg))
	if arg == "on" or arg == "вкл" then
		ns.char.chatOn = true
	elseif arg == "off" or arg == "выкл" then
		ns.char.chatOn = false
	end
	ns.Print(ns.char.chatOn and L.CHAT_ON or L.CHAT_OFF)
end, L.HELP_CHAT_TOGGLE)

-- То же выбирают в настройках окна (UI.lua).
ns.Command("window", function(arg)
	arg = U.Trim(arg)
	if not Chat.SetWindow(arg) then
		local names = {}
		for _, w in ipairs(Chat.Windows()) do names[#names + 1] = "«" .. w.name .. "»" end
		ns.Print(L.CHAT_WINDOW_MISSING, arg, table.concat(names, ", "))
		return
	end
	local name = Chat.SelectedWindows()[1]
	if name ~= "" then ns.Print(L.CHAT_WINDOW_SET, name) else ns.Print(L.CHAT_WINDOW_MAIN) end
end, L.HELP_WINDOW)

ns.Command("ignore", function(arg)
	arg = U.Trim(arg)
	if arg == "" then
		local names = {}
		for _, n in pairs(ns.store.ignore) do names[#names + 1] = n end
		table.sort(names)
		ns.Print(L.IGNORE_LIST, #names > 0 and table.concat(names, ", ") or "—")
		return
	end
	local k = U.Key(arg)
	if ns.store.ignore[k] then
		ns.store.ignore[k] = nil
		ns.Print(L.IGNORE_OFF, arg)
	else
		ns.store.ignore[k] = U.Display(arg)
		ns.Print(L.IGNORE_ON, arg)
	end
end, L.HELP_IGNORE)

ns.Command("history", function(arg)
	local tier = ({ ["1"] = "A", ["2"] = "C", ["3"] = "L" })[U.Trim(arg)] or "A"
	if Chat.MyLevel() < Chat.TIER_LEVEL[tier] then
		ns.Print(L.CHAT_NO_RIGHTS, L["TIER_" .. tier])
		return
	end
	local list = ns.store.chat[tier]
	local frames = Chat.Frames()
	for i = math.max(1, #list - 19), #list do
		local e = list[i]
		local line = "|cff999999" .. (date and date("%H:%M", e.t) or "") .. "|r " .. Chat.Format(tier, e.g, e.s, e.c, e.x)
		for _, f in ipairs(frames) do f:AddMessage(line, Chat.Color(tier)) end
	end
end, L.HELP_HISTORY)

ns.Every(60, "chat gc", function()
	local now = ns.Now()
	for k, t in pairs(seen) do
		if now - t > C.CHAT_DEDUPE then seen[k] = nil end
	end
	for k, b in pairs(buckets) do
		if now - b.t > 60 then buckets[k] = nil end
	end
end)

ns.Status(function()
	local s = Chat.stats
	return L.STATUS_CHAT:format(Chat.MyLevel(), s.sent, s.shown, s.dupes, s.refused, s.limited)
end)
