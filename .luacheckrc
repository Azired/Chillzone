-- luacheck: проверка Chillzone и тестов. Запуск из корня: luacheck .
-- Игра — Lua 5.1; тесты гоняются в LuaJIT.
std = "lua51"
max_line_length = false
-- Аргументы обработчиков (self, event, sender…) часто не нужны — это нормально.
unused_args = false

-- Сторонние библиотеки не наши — их не проверяем.
exclude_files = {
	"Chillzone/libs/**",
	"reference/**",
}

-- Каждый файл аддона начинается с local ADDON, ns = ... — ADDON обычно не нужен.
ignore = { "211/ADDON" }

-- Что аддон пишет в глобальное окружение.
globals = {
	"ChillzoneDB",
	"SLASH_CHILLZONE1",
	"SlashCmdList",
}

-- API игры, которым аддон пользуется. Новый вызов игры — добавить сюда.
read_globals = {
	-- Lua-расширения игры
	"date",
	"time",
	"tinsert",
	"wipe",
	"issecretvalue",
	"issecurevariable",

	-- C_* и перечисления
	"C_AddOns",
	"C_ChatInfo",
	"C_GuildInfo",
	"C_InputInterfaceStyle",
	"C_Map",
	"C_Timer",
	"Enum",

	-- функции
	"ChatFrame_AddMessageEventFilter",
	"CreateFrame",
	"FCF_GetChatWindowInfo",
	"GetChannelName",
	"GetChatWindowInfo",
	"GetCursorPosition",
	"GetGuildInfo",
	"GetGuildRosterInfo",
	"GetGuildRosterLastOnline",
	"GetNormalizedRealmName",
	"GetNumGuildMembers",
	"GetRealmName",
	"GetServerTime",
	"GetTime",
	"GetTimePreciseSec",
	"debugprofilestop",
	"GuildRoster",
	"IsInGuild",
	"IsShiftKeyDown",
	"LeaveChannelByName",
	"LoadAddOn",
	"SendChatMessage",
	"UnitClass",
	"UnitFactionGroup",
	"UnitFullName",
	"UnitGUID",

	-- фреймы, шрифты и константы
	"ChatFontNormal",
	"DEFAULT_CHAT_FRAME",
	"ERR_CHAT_PLAYER_NOT_FOUND_S",
	"GameTooltip",
	"Minimap",
	"NUM_CHAT_WINDOWS",
	"RAID_CLASS_COLORS",
	"UIParent",
	"UISpecialFrames",
	"WorldMapFrame",

	-- библиотеки и их глобалы
	"LibStub",
	"HBD_PINS_WORLDMAP_SHOW_CONTINENT",
}

-- Тесты: LuaJIT (setfenv, bit, jit), игра в них симулируется (tests/wow.lua).
files["tests/"] = { std = "luajit" }
