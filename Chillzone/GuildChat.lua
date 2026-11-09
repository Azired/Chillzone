-- Chillzone: чат своей гильдии и офицерский чат гильдии в окне Chillzone. Строки берутся из
-- обычных событий игры (CHAT_MSG_GUILD / CHAT_MSG_OFFICER), хранятся по 100 на персонажа и
-- уходят событием CHAT в окно. Копии прежних версий с меткой [Чиллзон] скрываются:
-- общий канал больше не отправляет читаемые копии в /g.
local ADDON, ns = ...

local U = ns.Util
local L = ns.L

local GuildChat = {}
ns.GuildChat = GuildChat

-- Может ли персонаж писать в офицерский чат гильдии.
function GuildChat.CanOfficer()
	local g, rank = ns.MyGuild()
	if not g then return false end
	local info = rawget(_G, "C_GuildInfo")
	local can = type(info) == "table" and info.CanSpeakInOfficerChat
	if type(can) == "function" then
		local ok, yes = pcall(can)
		if ok and yes ~= nil then return yes and true or false end
	end
	return rank ~= nil and ns.Roster.IsOfficerRank(rank)
end

-- Forever может закрыть текст, автора и GUID даже у обычного чата гильдии.
-- Проверяем до строковых операций; старые клиенты могут не иметь этого API.
local function IsSecret(value)
	return type(issecretvalue) == "function" and issecretvalue(value)
end

-- Класс автора: по доступному GUID из события, иначе по ростеру.
function GuildChat.ClassOf(sender, guid)
	local byGuid = rawget(_G, "GetPlayerInfoByGUID")
	if not IsSecret(guid) and guid and guid ~= "" and type(byGuid) == "function" then
		local ok, _, class = pcall(byGuid, guid)
		if ok and not IsSecret(class) and type(class) == "string" then return class end
	end
	local key = U.Key(sender)
	for _, m in ipairs(ns.Roster.members or {}) do
		if m.key == key then return m.class end
	end
	return nil
end

function GuildChat.Receive(channel, text, sender, guid)
	if IsSecret(text) or IsSecret(sender) then return end
	if not ns.char or type(text) ~= "string" or type(sender) ~= "string" then return end
	if channel == "G" and GuildChat.IsMirror(text) then return end
	ns.Chat.Remember(channel, ns.MyGuild(), sender, GuildChat.ClassOf(sender, guid), text)
end

-- Совместимость с прежними версиями: копию убираем сразу, даже если обычный /g
-- пришёл раньше подписанного сообщения M1. Сами такие строки больше не создаём.
function GuildChat.IsMirror(text)
	if IsSecret(text) then return false end
	return ns.IsMember() and type(text) == "string" and text:sub(1, #L.GUILD_MIRROR_PREFIX) == L.GUILD_MIRROR_PREFIX
end

ns.AddChatFilter("CHAT_MSG_GUILD", function(_, _, text)
	return GuildChat.IsMirror(text)
end)

-- Строка в чат гильдии (G) или офицеров гильдии (O). true — ушла.
function GuildChat.Send(channel, text)
	if not ns.MyGuild() then
		ns.Print(L.GUILD_NONE)
		return false
	end
	if channel == "O" and not GuildChat.CanOfficer() then
		ns.Print(L.GUILD_NO_OFFICER)
		return false
	end
	text = U.Cut(U.Trim(text), 255)
	if text == "" then return false end
	SendChatMessage(text, channel == "O" and "OFFICER" or "GUILD")
	return true
end

-- История принадлежит гильдии: сменил гильдию — старые строки не показываем.
local function CheckGuild()
	local g = ns.MyGuild()
	if not g or not ns.char then return end
	if ns.char.historyGuild ~= g then
		ns.char.history.G, ns.char.history.O = {}, {}
		ns.char.historyGuild = g
	end
end

ns.RegisterEvent("CHAT_MSG_GUILD", function(text, sender, ...)
	local guid = select(10, ...)
	GuildChat.Receive("G", text, sender, guid)
end)
ns.RegisterEvent("CHAT_MSG_OFFICER", function(text, sender, ...)
	local guid = select(10, ...)
	GuildChat.Receive("O", text, sender, guid)
end)
ns.On("ROSTER", CheckGuild)
ns.On("GUILD_CHANGED", CheckGuild)
