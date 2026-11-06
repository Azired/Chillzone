-- Chillzone: настройки, которые меняет автор аддона (не игрок).
local ADDON, ns = ...

local C = {}
ns.Config = C

C.VERSION = "0.3.0"
C.PREFIX = "CHZSIGNED1" -- incompatible trust boundary: unsigned older clients cannot join

-- «Своя» гильдия: в названии есть эта подстрока (без учёта регистра, кириллица).
C.GUILD_TOKEN = "Чиллзон"
-- Главная гильдия: её глава — Король, главы остальных — Лорды, офицеры — Капитаны.
C.MAIN_GUILD = "Чиллзон"
-- Офицеры — звания с игровым флагом «офицер» (галочка в настройках гильдии), как в
-- ChillZoneUnion 0.6.
-- Live authorization fails closed when the native permission flag is unknown.
-- OFFICER_RANK is retained only as a default for pure data builders.
C.OFFICER_RANK = 1
-- Связные: игровое звание, которому глава гильдии доверяет связь между гильдиями
-- (как «Ветеран» в ChillZoneUnion). Сравнивается название звания целиком, без учёта
-- регистра и пробелов по краям: «Ветераны» и «Почётный ветеран» не подходят.
-- Глава, офицеры и связные гильдии могут быть её репортёром; в главной гильдии они же — реле.
-- Остальные участники не пересылают чужие сообщения. Пустая строка — только глава и офицеры.
-- Действует, только когда TRUST_ANY_MEMBER = false.
C.RELAY_RANK = "Ветеран"
-- Certified members are fallback transports. Native/certified officers have priority.
-- Forwarded data always requires an end-to-end signature; relay status grants no issuer rights.
-- false retains the optional officer/veteran transport restriction.
C.TRUST_ANY_MEMBER = true

-- Legacy configuration retained for compatibility; it grants no trust in 0.3.
C.RELAYS = {}

-- Необязательный белый список гильдий. Пустой — подходит любая гильдия с GUILD_TOKEN.
C.GUILDS = {
	-- "Чиллзон",
	-- "Чиллзон Север",
}

-- Скрытые каналы прежних версий. Аддон в них больше не пишет: при входе выходит из них
-- и прячет их строки, чтобы сырой текст старых клиентов не попадал в чат.
C.OLD_CHANNELS = { "ChillzoneA", "ChillzoneH" }

---------------------------------------------------------------------------
-- Тайминги (секунды)
---------------------------------------------------------------------------
C.HELLO_EVERY = 60 -- H1 в гильдию
C.PEER_WINDOW = 180 -- кто считается «на связи» для выборов
C.SCAN_EVERY = 60 -- чтение ростера
C.REPORT_EVERY = 170 -- отчёт переписи репортёра
C.REPORT_IDLE = 600 -- без изменений — не чаще
C.LOGIN_QUIET = 70 -- первые секунды после входа репортёр молчит (слушает выборы)
C.Q1_GAP = 120 -- ответ на Q1 не чаще

C.FRESH = 15 * 60 -- онлайн и зоны свежие
C.TOTAL_KEEP = 24 * 3600 -- численность показывается
C.KEEP = 7 * 86400 -- хранение отчёта
C.CLAIM_TTL = 15 * 60 -- отправитель отчитывается за одну гильдию

C.RELAY_VERIFIED = 15 * 60 -- реле отвечало — годится для выбора
C.RELAY_WINDOW = 600 -- окно смены реле для гильдии
C.RELAY_TIMEOUT = 30 -- нет ответа на RP — реле офлайн
C.RELAY_DOWN = 600 -- офлайн-реле исключается
C.RELAY_LEARNED_TTL = 14 * 86400
C.RELAY_LEARNED_MAX = 12
C.RELAY_HOLD = 20 -- очередь, пока ни одно реле не ответило
C.RELAY_DEDUPE = 300
C.RELAY_PER_MIN = 10 -- сообщений в минуту от одного автора через реле
C.RELAY_GOSSIP = 8 -- имён реле в RY
C.REG_EVERY = 170 -- RR

C.CHAT_DEDUPE = 120
C.CHAT_GAP = 1.5 -- у отправителя между строками
C.CHAT_PARTS = 3
C.CHAT_PART = 200 -- байт текста в части
C.CHAT_BURST = 6 -- у получателя: строк сразу от одного автора
C.CHAT_REFILL = 1.2 -- и по одной раз в столько секунд
C.CHAT_TIER_MIN = 60 -- строк в минуту на уровень
C.CHAT_HISTORY = 100

-- Credentials permit transport for a day; privileged roles require a recent renewal.
C.AUTH_TTL = 24 * 3600
C.AUTH_ROLE_TTL = 15 * 60
C.AUTH_RENEW = 10 * 60
C.AUTH_ROSTER_TTL = 120
