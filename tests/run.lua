-- Запуск: luajit tests/run.lua (из корня репозитория или откуда угодно).
-- Ненулевой код выхода, если хоть один тест упал.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = here .. "/?.lua;" .. package.path

local T = require("lib")
T.ROOT = here .. "/.."

local SUITES = {
	"test_static",
	"test_util",
	"test_codec",
	"test_comm",
	"test_data",
	"test_relay",
	"test_chat",
	"test_chat_tab",
	"test_guildmirror",
	"test_security",
	"test_link",
	"test_union",
	"test_migration",
	"test_signatures",
	"test_recruit",
	"test_recruit_sync",
	"test_update",
	"test_map",
}

for _, name in ipairs(SUITES) do
	local path = here .. "/" .. name .. ".lua"
	local f = io.open(path, "rb")
	if f then
		f:close()
		local chunk = assert(loadfile(path))
		chunk(T)
	end
end

os.exit(T.run() and 0 or 1)
