-- Крошечный тестовый каркас: T.test, проверки, загрузка файлов аддона в отдельное окружение.
local T = { tests = {}, failed = 0, passed = 0 }

T.ROOT = "."

function T.test(name, fn)
	T.tests[#T.tests + 1] = { name = name, fn = fn }
end

local function show(v)
	if type(v) == "string" then return ("%q"):format(v) end
	return tostring(v)
end

function T.eq(a, b, msg)
	if a ~= b then error(("%s: ожидалось %s, получено %s"):format(msg or "eq", show(b), show(a)), 2) end
end

function T.ok(v, msg)
	if not v then error((msg or "ok") .. ": условие не выполнено", 2) end
end

function T.no(v, msg)
	if v then error((msg or "no") .. ": ожидалось ложное значение, получено " .. show(v), 2) end
end

-- Глубокое сравнение таблиц (для round-trip кодека).
function T.same(a, b, msg, path)
	path = path or "$"
	if type(a) ~= type(b) then error(("%s: %s тип %s против %s"):format(msg or "same", path, type(a), type(b)), 2) end
	if type(a) ~= "table" then
		if a ~= b then error(("%s: %s = %s, ожидалось %s"):format(msg or "same", path, show(a), show(b)), 2) end
		return
	end
	for k, v in pairs(a) do
		local ok, err = pcall(T.same, v, b[k], msg, path .. "." .. tostring(k))
		if not ok then error(err, 2) end
	end
	for k in pairs(b) do
		if a[k] == nil then error(("%s: %s.%s отсутствует"):format(msg or "same", path, tostring(k)), 2) end
	end
end

function T.read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

-- Файлы аддона по порядку из Chillzone.toc (libs включительно).
function T.tocFiles()
	local out = {}
	for line in T.read(T.ROOT .. "/Chillzone/Chillzone.toc"):gmatch("[^\r\n]+") do
		if not line:find("^##") and line:find("%S") then out[#out + 1] = (line:gsub("\\", "/"):gsub("%s+$", "")) end
	end
	return out
end

-- Загружает перечисленные файлы аддона в окружение env (по умолчанию — пустое поверх _G)
-- с общей таблицей ns, как это делает игра: chunk("Chillzone", ns).
function T.load(files, env, ns)
	ns = ns or {}
	env = env or setmetatable({}, { __index = _G })
	for _, f in ipairs(files) do
		local chunk, err = loadfile(T.ROOT .. "/Chillzone/" .. f)
		if not chunk then error(err, 2) end
		setfenv(chunk, env)
		chunk("Chillzone", ns)
	end
	return ns, env
end

function T.run()
	for _, t in ipairs(T.tests) do
		local filter = os.getenv("CZ_TEST_FILTER")
		if not filter or t.name:find(filter, 1, true) then
		local ok, err = xpcall(t.fn, debug.traceback)
		if ok then
			T.passed = T.passed + 1
			if os.getenv("CZ_TEST_PROGRESS") then io.write("PASS ", t.name, "\n"); io.flush() end
		else
			T.failed = T.failed + 1
			io.write("FAIL ", t.name, "\n  ", tostring(err):gsub("\n", "\n  "), "\n")
		end
		end
	end
	io.write(("%d прошло, %d упало\n"):format(T.passed, T.failed))
	return T.failed == 0
end

return T
