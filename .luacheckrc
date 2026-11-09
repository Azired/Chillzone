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
	"C_FriendList",
	"C_InputInterfaceStyle",
	"C_Map",
	"C_PartyInfo",
	"C_Timer",
	"Enum",

	-- функции
	"ChatFrame_AddMessageEventFilter",
	"ChatFrame_OpenChat",
	"CreateFrame",
	"FCFDock_GetSelectedWindow",
	"FCFDock_SelectWindow",
	"FCF_CanOpenNewWindow",
	"FCF_GetChatWindowInfo",
	"FCF_GetNumActiveChatFrames",
	"FCF_OpenNewWindow",
	"FCF_SelectDockFrame",
	"GetChannelName",
	"GetChatWindowInfo",
	"GetCursorPosition",
	"GetGuildInfo",
	"GetGuildRosterInfo",
	"GetGuildRosterLastOnline",
	"GetNormalizedRealmName",
	"GetNumGuildMembers",
	"GetNumWhoResults",
	"GetWhoInfo",
	"GetMaxPlayerLevel",
	"SendWho",
	"SetWhoToUI",
	"CanGuildInvite",
	"GuildInvite",
	"InviteUnit",
	"IsMouseButtonDown",
	"hooksecurefunc",
	"GetRealmName",
	"GetServerTime",
	"GetTime",
	"GetTimePreciseSec",
	"debugprofilestop",
	"debugstack",
	"GuildRoster",
	"IsInGuild",
	"IsBuiltinChatWindow",
	"InCombatLockdown",
	"IsShiftKeyDown",
	"LeaveChannelByName",
	"LoadAddOn",
	"SendChatMessage",
	"UnitClass",
	"UnitFactionGroup",
	"UnitFullName",
	"UnitGUID",
	"UnitLevel",

	-- фреймы, шрифты и константы
	"ACTIVE_CHAT_EDIT_BOX",
	"ChatFontNormal",
	"Constants",
	"DEFAULT_CHAT_FRAME",
	"ERR_CHAT_PLAYER_NOT_FOUND_S",
	"GameTooltip",
	"GENERAL_CHAT_DOCK",
	"LAST_ACTIVE_CHAT_EDIT_BOX",
	"Minimap",
	"NUM_CHAT_WINDOWS",
	"RAID_CLASS_COLORS",
	"SELECTED_CHAT_FRAME",
	"SELECTED_DOCK_FRAME",
	"UIParent",
	"UISpecialFrames",
	"WorldMapFrame",

	-- библиотеки и их глобалы
	"LibStub",
	"OpenMapAPI",
	"HBD_PINS_WORLDMAP_SHOW_CONTINENT",
}

-- Тесты: LuaJIT (setfenv, bit, jit), игра в них симулируется (tests/wow.lua).
files["tests/"] = { std = "luajit" }
