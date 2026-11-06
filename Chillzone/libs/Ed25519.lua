local ADDON, ns = ...

-- Ed25519 signatures (RFC 8032) and SHA-512 (FIPS 180-4) in plain Lua 5.1. Written for Olympus Link
-- (0.9.10; 1.4.0 its own addon, Olympus_Link, which uses this file): the Olympus Discord bot's codes
-- carry a signature this checks, and a confirmer's addon signs what it confirms with a key of its
-- own. The Arena's ledgers, the records' seals and the other signed parts of Olympus use it too
-- (ns.Ed25519). Nothing here needs integers
-- wider than the game's Lua numbers (doubles, exact for every integer below 2^53).
--
-- SHA-512 works on 64-bit words kept as two 32-bit halves (hi, lo), with the game's bit
-- library for the logic (as Sign.lua's SHA-256) and plain additions for the sums: a half is
-- always 0 .. 2^32 - 1, a sum of five halves stays below 2^35, and its carry is
-- math.floor(sum / 2^32).
--
-- The curve is a port of TweetNaCl's arithmetic (Bernstein, van Gastel, Janssen, Lange,
-- Schwabe, Smetsers; public domain): a number mod p = 2^255 - 19 is 16 limbs of 16 bits, each
-- a Lua number. Why every intermediate value stays below 2^53, so every step is exact:
--   * a multiplication (M, S) ends with two carry passes: each limb is then in [0, 2^16), the
--     first within 38 of that range;
--   * the point formulas below add or subtract such limbs at most twice before the next
--     multiplication (A, Z, never carried), so what a multiplication reads is below 2^19;
--   * a product of two limbs is then below 2^38; a column of the product adds 16 of them,
--     the upper columns folded in times 38 (2^256 = 38 mod p): 16 + 38 * 15 = 586 products
--     at most, below 2^38 * 2^9.2 = 2^47.2;
--   * a carry is math.floor(t / 2^16) (dividing by a power of two is exact), below 2^32, and
--     the one out of the top limb comes back into the first times 38 (below 2^38).
-- Scalars mod L (the group's order) are bytes, as in TweetNaCl's modL: a product of two bytes
-- is below 2^16, a column of 32 below 2^21, and the reduction's steps stay below 2^34.
--
-- Unlike TweetNaCl nothing here takes constant time (a Lua interpreter can't promise it, and the
-- only secret, a confirmer's key, signs on its own computer): scalars are multiplied four bits
-- at a time, and a check adds two scalar multiplications in one pass. Verification follows RFC
-- 8032: S must be below L, the public key a canonical point of more than small order, and R
-- the canonical encoding the check computes.
--
-- A signature costs tens of milliseconds in the game's Lua: Ed.Run runs the work in a coroutine
-- that yields every Ed.SLICE_MS, resumed on the next frame (C_Timer.After(0)), so the game
-- never stops for it.

local Ed = {}
ns.Ed25519 = Ed

local B = _G.bit
local band, bor, bxor, bnot, rshift, lshift = B.band, B.bor, B.bxor, B.bnot, B.rshift, B.lshift
local floor = math.floor
local byte, char, concat = string.byte, string.char, table.concat
local M32 = 4294967296

---------------------------------------------------------------------------
-- Slices: heavy loops call Pause(), which yields only inside a job Ed.Run started, once the
-- job has had its time this frame.
---------------------------------------------------------------------------

Ed.SLICE_MS = 4       -- a job's time per frame
Ed.MAX_JOBS = 40      -- jobs waiting at most (a confirmer's signatures, a code's check)
Ed.after = function(fn) C_Timer.After(0, fn) end -- tests run the frames themselves

local jobs = {}
local current           -- the job's coroutine while it runs
local sliceEnd = 0
local pauses = 0        -- without a clock: a slice is this many pauses
local scheduled = false

local function Clock()
	if type(debugprofilestop) == "function" then return debugprofilestop() end
	return nil
end

local function Pause()
	if current == nil or coroutine.running() ~= current then return end
	pauses = pauses + 1
	local now = Clock()
	if (now and now >= sliceEnd) or (not now and pauses >= 16) then coroutine.yield() end
end

local function Step()
	scheduled = false
	local job = jobs[1]
	if not job then return end
	local now = Clock()
	current, sliceEnd, pauses = job.co, (now or 0) + Ed.SLICE_MS, 0
	local ok, res = coroutine.resume(job.co)
	current = nil
	job.slices = job.slices + 1
	if not ok or coroutine.status(job.co) == "dead" then
		table.remove(jobs, 1)
		if job.done then
			local okDone, err = pcall(job.done, ok, res, job.slices)
			if not okDone and ns.CaptureError then ns.CaptureError("ed25519 done", err) end
		end
	end
	if jobs[1] and not scheduled then
		scheduled = true
		Ed.after(Step)
	end
end

-- fn() runs a slice per frame; done(ok, result, slices) once it returns (ok false: it failed,
-- result is the error). False when too many jobs wait already.
function Ed.Run(fn, done)
	if #jobs >= Ed.MAX_JOBS then return false end
	jobs[#jobs + 1] = { co = coroutine.create(fn), done = done, slices = 0 }
	if not scheduled then
		scheduled = true
		Ed.after(Step)
	end
	return true
end

-- Yields here when a job has had its time (other files' heavy loops inside a job: the QR code).
Ed.Pause = Pause

function Ed.Busy() return #jobs end
function Ed.Reset() wipe(jobs); current, scheduled = nil, false end -- tests

---------------------------------------------------------------------------
-- Encodings
---------------------------------------------------------------------------

function Ed.ToHex(s)
	return (s:gsub(".", function(c) return ("%02x"):format(byte(c)) end))
end

-- Bytes from hex (either case), nil unless it is whole bytes of hex.
function Ed.FromHex(h)
	if type(h) ~= "string" or #h % 2 ~= 0 or h:find("[^%x]") then return nil end
	return (h:gsub("%x%x", function(x) return char(tonumber(x, 16)) end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_VALUE = {}
for i = 1, 64 do B64_VALUE[byte(B64, i)] = i - 1 end

-- base64url without padding (RFC 4648 section 5).
function Ed.ToB64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local k = c and 4 or (b and 3 or 2)
		for j = 1, k do
			local v = floor(n / 2 ^ (18 - 6 * (j - 1))) % 64
			out[#out + 1] = B64:sub(v + 1, v + 1)
		end
	end
	return concat(out)
end

-- Bytes from base64url without padding; nil for anything else, and for a spelling that is not
-- the one Ed.ToB64 writes (unused bits set): one text per value.
function Ed.FromB64(s)
	if type(s) ~= "string" or #s % 4 == 1 then return nil end
	local out, n, bits = {}, 0, 0
	for i = 1, #s do
		local v = B64_VALUE[byte(s, i)]
		if not v then return nil end
		n, bits = n * 64 + v, bits + 6
		if bits >= 8 then
			bits = bits - 8
			local d = 2 ^ bits
			out[#out + 1] = char(floor(n / d))
			n = n % d
		end
	end
	if n ~= 0 then return nil end
	return concat(out)
end

---------------------------------------------------------------------------
-- SHA-512
---------------------------------------------------------------------------

local K512 = {
	0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
	0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019, 0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
	0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
	0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
	0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3, 0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
	0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
	0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
	0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725, 0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
	0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
	0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
	0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001, 0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
	0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
	0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
	0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb, 0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
	0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
	0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
	0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207, 0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
	0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
	0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
	0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a, 0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}
local H512 = {
	0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
	0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
}

local wh, wl = {}, {} -- the message schedule, reused

-- SHA-512 of a string, as 64 bytes.
local function SHA512(msg)
	local len = #msg
	-- 0x80, zeros up to 112 mod 128, then the length in bits on 128 bits (big endian).
	local bits = len * 8
	local tail = {}
	for i = 7, 0, -1 do tail[#tail + 1] = char(floor(bits / 2 ^ (8 * i)) % 256) end
	msg = msg .. "\128" .. string.rep("\0", (111 - len) % 128 + 8) .. concat(tail)
	local h = {}
	for i = 1, 16 do h[i] = H512[i] end
	for chunk = 1, #msg, 128 do
		for i = 1, 16 do
			local at = chunk + (i - 1) * 8
			local a, b, c, d, e, f, g, k = byte(msg, at, at + 7)
			wh[i] = ((a * 256 + b) * 256 + c) * 256 + d
			wl[i] = ((e * 256 + f) * 256 + g) * 256 + k
		end
		for i = 17, 80 do
			-- sigma0 = ROTR 1 ^ ROTR 8 ^ SHR 7, sigma1 = ROTR 19 ^ ROTR 61 ^ SHR 6
			local xh, xl = wh[i - 15], wl[i - 15]
			local s0h = bxor(bor(rshift(xh, 1), lshift(xl, 31)), bor(rshift(xh, 8), lshift(xl, 24)), rshift(xh, 7))
			local s0l = bxor(bor(rshift(xl, 1), lshift(xh, 31)), bor(rshift(xl, 8), lshift(xh, 24)), bor(rshift(xl, 7), lshift(xh, 25)))
			local yh, yl = wh[i - 2], wl[i - 2]
			local s1h = bxor(bor(rshift(yh, 19), lshift(yl, 13)), bor(rshift(yl, 29), lshift(yh, 3)), rshift(yh, 6))
			local s1l = bxor(bor(rshift(yl, 19), lshift(yh, 13)), bor(rshift(yh, 29), lshift(yl, 3)), bor(rshift(yl, 6), lshift(yh, 26)))
			local lo = s1l % M32 + wl[i - 7] + s0l % M32 + wl[i - 16]
			local carry = floor(lo / M32)
			wl[i] = lo - carry * M32
			wh[i] = (s1h % M32 + wh[i - 7] + s0h % M32 + wh[i - 16] + carry) % M32
		end
		local ah, al, bh, bl, ch, cl, dh, dl = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
		local eh, el, fh, fl, gh, gl, hh, hl = h[9], h[10], h[11], h[12], h[13], h[14], h[15], h[16]
		for i = 1, 80 do
			-- Sigma1(e) = ROTR 14 ^ ROTR 18 ^ ROTR 41; Ch(e, f, g) = (e & f) ^ (~e & g)
			local S1h = bxor(bor(rshift(eh, 14), lshift(el, 18)), bor(rshift(eh, 18), lshift(el, 14)), bor(rshift(el, 9), lshift(eh, 23)))
			local S1l = bxor(bor(rshift(el, 14), lshift(eh, 18)), bor(rshift(el, 18), lshift(eh, 14)), bor(rshift(eh, 9), lshift(el, 23)))
			local chh = bxor(band(eh, fh), band(bnot(eh), gh))
			local chl = bxor(band(el, fl), band(bnot(el), gl))
			local lo = hl + S1l % M32 + chl % M32 + K512[2 * i] + wl[i]
			local carry = floor(lo / M32)
			local t1l = lo - carry * M32
			local t1h = (hh + S1h % M32 + chh % M32 + K512[2 * i - 1] + wh[i] + carry) % M32
			-- Sigma0(a) = ROTR 28 ^ ROTR 34 ^ ROTR 39; Maj(a, b, c)
			local S0h = bxor(bor(rshift(ah, 28), lshift(al, 4)), bor(rshift(al, 2), lshift(ah, 30)), bor(rshift(al, 7), lshift(ah, 25)))
			local S0l = bxor(bor(rshift(al, 28), lshift(ah, 4)), bor(rshift(ah, 2), lshift(al, 30)), bor(rshift(ah, 7), lshift(al, 25)))
			local mjh = bxor(band(ah, bh), band(ah, ch), band(bh, ch))
			local mjl = bxor(band(al, bl), band(al, cl), band(bl, cl))
			lo = S0l % M32 + mjl % M32
			carry = floor(lo / M32)
			local t2l = lo - carry * M32
			local t2h = (S0h % M32 + mjh % M32 + carry) % M32
			hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
			lo = dl + t1l
			carry = floor(lo / M32)
			eh, el = (dh + t1h + carry) % M32, lo - carry * M32
			dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
			lo = t1l + t2l
			carry = floor(lo / M32)
			ah, al = (t1h + t2h + carry) % M32, lo - carry * M32
		end
		local v = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
		for i = 1, 16, 2 do
			local lo = h[i + 1] + v[i + 1]
			local carry = floor(lo / M32)
			h[i + 1] = lo - carry * M32
			h[i] = (h[i] + v[i] + carry) % M32
		end
		Pause()
	end
	local out = {}
	for i = 1, 16 do
		local x = h[i]
		out[i] = char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
	end
	return concat(out)
end
Ed.SHA512 = SHA512

---------------------------------------------------------------------------
-- The field: numbers mod p = 2^255 - 19, 16 limbs of 16 bits (least significant first,
-- indexes 1 to 16), each limb a Lua number (see the top of the file for their bounds).
---------------------------------------------------------------------------

local function gf(init)
	local o = {}
	for i = 1, 16 do o[i] = init and init[i] or 0 end
	return o
end

local ZERO, ONE = gf(), gf({ 1 })
local D = gf({ 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 })
local D2 = gf({ 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 })
local BX = gf({ 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 })
local BY = gf({ 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 })
local SQRTM1 = gf({ 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 })

local function Set(o, a) for i = 1, 16 do o[i] = a[i] end end
local function A(o, a, b) for i = 1, 16 do o[i] = a[i] + b[i] end end
local function Z(o, a, b) for i = 1, 16 do o[i] = a[i] - b[i] end end

-- One carry pass (TweetNaCl's car25519): every limb into [0, 2^16), the top one's carry back
-- into the first times 38.
local function Carry(o)
	for i = 1, 16 do
		local c = floor(o[i] / 65536)
		o[i] = o[i] - c * 65536
		if i < 16 then o[i + 1] = o[i + 1] + c else o[1] = o[1] + 38 * c end
	end
end

-- o = a * b and o = a * a, written out (as loops they made a signature three times slower
-- under luajit -joff, the stand-in for the game's interpreter): the 256 products column by
-- column, the columns above 2^256 folded in times 38, two carry passes. o may be a or b.
local function M(o, a, b)
	local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
	local b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16]
	local t0 = a0 * b0 + 38 * (a1 * b15 + a2 * b14 + a3 * b13 + a4 * b12 + a5 * b11 + a6 * b10 + a7 * b9 + a8 * b8 + a9 * b7 + a10 * b6 + a11 * b5 + a12 * b4 + a13 * b3 + a14 * b2 + a15 * b1)
	local t1 = a0 * b1 + a1 * b0 + 38 * (a2 * b15 + a3 * b14 + a4 * b13 + a5 * b12 + a6 * b11 + a7 * b10 + a8 * b9 + a9 * b8 + a10 * b7 + a11 * b6 + a12 * b5 + a13 * b4 + a14 * b3 + a15 * b2)
	local t2 = a0 * b2 + a1 * b1 + a2 * b0 + 38 * (a3 * b15 + a4 * b14 + a5 * b13 + a6 * b12 + a7 * b11 + a8 * b10 + a9 * b9 + a10 * b8 + a11 * b7 + a12 * b6 + a13 * b5 + a14 * b4 + a15 * b3)
	local t3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + 38 * (a4 * b15 + a5 * b14 + a6 * b13 + a7 * b12 + a8 * b11 + a9 * b10 + a10 * b9 + a11 * b8 + a12 * b7 + a13 * b6 + a14 * b5 + a15 * b4)
	local t4 = a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0 + 38 * (a5 * b15 + a6 * b14 + a7 * b13 + a8 * b12 + a9 * b11 + a10 * b10 + a11 * b9 + a12 * b8 + a13 * b7 + a14 * b6 + a15 * b5)
	local t5 = a0 * b5 + a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1 + a5 * b0 + 38 * (a6 * b15 + a7 * b14 + a8 * b13 + a9 * b12 + a10 * b11 + a11 * b10 + a12 * b9 + a13 * b8 + a14 * b7 + a15 * b6)
	local t6 = a0 * b6 + a1 * b5 + a2 * b4 + a3 * b3 + a4 * b2 + a5 * b1 + a6 * b0 + 38 * (a7 * b15 + a8 * b14 + a9 * b13 + a10 * b12 + a11 * b11 + a12 * b10 + a13 * b9 + a14 * b8 + a15 * b7)
	local t7 = a0 * b7 + a1 * b6 + a2 * b5 + a3 * b4 + a4 * b3 + a5 * b2 + a6 * b1 + a7 * b0 + 38 * (a8 * b15 + a9 * b14 + a10 * b13 + a11 * b12 + a12 * b11 + a13 * b10 + a14 * b9 + a15 * b8)
	local t8 = a0 * b8 + a1 * b7 + a2 * b6 + a3 * b5 + a4 * b4 + a5 * b3 + a6 * b2 + a7 * b1 + a8 * b0 + 38 * (a9 * b15 + a10 * b14 + a11 * b13 + a12 * b12 + a13 * b11 + a14 * b10 + a15 * b9)
	local t9 = a0 * b9 + a1 * b8 + a2 * b7 + a3 * b6 + a4 * b5 + a5 * b4 + a6 * b3 + a7 * b2 + a8 * b1 + a9 * b0 + 38 * (a10 * b15 + a11 * b14 + a12 * b13 + a13 * b12 + a14 * b11 + a15 * b10)
	local t10 = a0 * b10 + a1 * b9 + a2 * b8 + a3 * b7 + a4 * b6 + a5 * b5 + a6 * b4 + a7 * b3 + a8 * b2 + a9 * b1 + a10 * b0 + 38 * (a11 * b15 + a12 * b14 + a13 * b13 + a14 * b12 + a15 * b11)
	local t11 = a0 * b11 + a1 * b10 + a2 * b9 + a3 * b8 + a4 * b7 + a5 * b6 + a6 * b5 + a7 * b4 + a8 * b3 + a9 * b2 + a10 * b1 + a11 * b0 + 38 * (a12 * b15 + a13 * b14 + a14 * b13 + a15 * b12)
	local t12 = a0 * b12 + a1 * b11 + a2 * b10 + a3 * b9 + a4 * b8 + a5 * b7 + a6 * b6 + a7 * b5 + a8 * b4 + a9 * b3 + a10 * b2 + a11 * b1 + a12 * b0 + 38 * (a13 * b15 + a14 * b14 + a15 * b13)
	local t13 = a0 * b13 + a1 * b12 + a2 * b11 + a3 * b10 + a4 * b9 + a5 * b8 + a6 * b7 + a7 * b6 + a8 * b5 + a9 * b4 + a10 * b3 + a11 * b2 + a12 * b1 + a13 * b0 + 38 * (a14 * b15 + a15 * b14)
	local t14 = a0 * b14 + a1 * b13 + a2 * b12 + a3 * b11 + a4 * b10 + a5 * b9 + a6 * b8 + a7 * b7 + a8 * b6 + a9 * b5 + a10 * b4 + a11 * b3 + a12 * b2 + a13 * b1 + a14 * b0 + 38 * (a15 * b15)
	local t15 = a0 * b15 + a1 * b14 + a2 * b13 + a3 * b12 + a4 * b11 + a5 * b10 + a6 * b9 + a7 * b8 + a8 * b7 + a9 * b6 + a10 * b5 + a11 * b4 + a12 * b3 + a13 * b2 + a14 * b1 + a15 * b0
	local c
	c = floor(t0 / 65536); t0 = t0 - c * 65536; t1 = t1 + c
	c = floor(t1 / 65536); t1 = t1 - c * 65536; t2 = t2 + c
	c = floor(t2 / 65536); t2 = t2 - c * 65536; t3 = t3 + c
	c = floor(t3 / 65536); t3 = t3 - c * 65536; t4 = t4 + c
	c = floor(t4 / 65536); t4 = t4 - c * 65536; t5 = t5 + c
	c = floor(t5 / 65536); t5 = t5 - c * 65536; t6 = t6 + c
	c = floor(t6 / 65536); t6 = t6 - c * 65536; t7 = t7 + c
	c = floor(t7 / 65536); t7 = t7 - c * 65536; t8 = t8 + c
	c = floor(t8 / 65536); t8 = t8 - c * 65536; t9 = t9 + c
	c = floor(t9 / 65536); t9 = t9 - c * 65536; t10 = t10 + c
	c = floor(t10 / 65536); t10 = t10 - c * 65536; t11 = t11 + c
	c = floor(t11 / 65536); t11 = t11 - c * 65536; t12 = t12 + c
	c = floor(t12 / 65536); t12 = t12 - c * 65536; t13 = t13 + c
	c = floor(t13 / 65536); t13 = t13 - c * 65536; t14 = t14 + c
	c = floor(t14 / 65536); t14 = t14 - c * 65536; t15 = t15 + c
	c = floor(t15 / 65536); t15 = t15 - c * 65536; t0 = t0 + 38 * c
	c = floor(t0 / 65536); t0 = t0 - c * 65536; t1 = t1 + c
	c = floor(t1 / 65536); t1 = t1 - c * 65536; t2 = t2 + c
	c = floor(t2 / 65536); t2 = t2 - c * 65536; t3 = t3 + c
	c = floor(t3 / 65536); t3 = t3 - c * 65536; t4 = t4 + c
	c = floor(t4 / 65536); t4 = t4 - c * 65536; t5 = t5 + c
	c = floor(t5 / 65536); t5 = t5 - c * 65536; t6 = t6 + c
	c = floor(t6 / 65536); t6 = t6 - c * 65536; t7 = t7 + c
	c = floor(t7 / 65536); t7 = t7 - c * 65536; t8 = t8 + c
	c = floor(t8 / 65536); t8 = t8 - c * 65536; t9 = t9 + c
	c = floor(t9 / 65536); t9 = t9 - c * 65536; t10 = t10 + c
	c = floor(t10 / 65536); t10 = t10 - c * 65536; t11 = t11 + c
	c = floor(t11 / 65536); t11 = t11 - c * 65536; t12 = t12 + c
	c = floor(t12 / 65536); t12 = t12 - c * 65536; t13 = t13 + c
	c = floor(t13 / 65536); t13 = t13 - c * 65536; t14 = t14 + c
	c = floor(t14 / 65536); t14 = t14 - c * 65536; t15 = t15 + c
	c = floor(t15 / 65536); t15 = t15 - c * 65536; t0 = t0 + 38 * c
	o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11], o[12], o[13], o[14], o[15], o[16] = t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15
end

local function S(o, a)
	local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
	local t0 = a0 * a0 + 38 * (2 * (a1 * a15 + a2 * a14 + a3 * a13 + a4 * a12 + a5 * a11 + a6 * a10 + a7 * a9) + a8 * a8)
	local t1 = 2 * a0 * a1 + 38 * (2 * (a2 * a15 + a3 * a14 + a4 * a13 + a5 * a12 + a6 * a11 + a7 * a10 + a8 * a9))
	local t2 = 2 * a0 * a2 + a1 * a1 + 38 * (2 * (a3 * a15 + a4 * a14 + a5 * a13 + a6 * a12 + a7 * a11 + a8 * a10) + a9 * a9)
	local t3 = 2 * (a0 * a3 + a1 * a2) + 38 * (2 * (a4 * a15 + a5 * a14 + a6 * a13 + a7 * a12 + a8 * a11 + a9 * a10))
	local t4 = 2 * (a0 * a4 + a1 * a3) + a2 * a2 + 38 * (2 * (a5 * a15 + a6 * a14 + a7 * a13 + a8 * a12 + a9 * a11) + a10 * a10)
	local t5 = 2 * (a0 * a5 + a1 * a4 + a2 * a3) + 38 * (2 * (a6 * a15 + a7 * a14 + a8 * a13 + a9 * a12 + a10 * a11))
	local t6 = 2 * (a0 * a6 + a1 * a5 + a2 * a4) + a3 * a3 + 38 * (2 * (a7 * a15 + a8 * a14 + a9 * a13 + a10 * a12) + a11 * a11)
	local t7 = 2 * (a0 * a7 + a1 * a6 + a2 * a5 + a3 * a4) + 38 * (2 * (a8 * a15 + a9 * a14 + a10 * a13 + a11 * a12))
	local t8 = 2 * (a0 * a8 + a1 * a7 + a2 * a6 + a3 * a5) + a4 * a4 + 38 * (2 * (a9 * a15 + a10 * a14 + a11 * a13) + a12 * a12)
	local t9 = 2 * (a0 * a9 + a1 * a8 + a2 * a7 + a3 * a6 + a4 * a5) + 38 * (2 * (a10 * a15 + a11 * a14 + a12 * a13))
	local t10 = 2 * (a0 * a10 + a1 * a9 + a2 * a8 + a3 * a7 + a4 * a6) + a5 * a5 + 38 * (2 * (a11 * a15 + a12 * a14) + a13 * a13)
	local t11 = 2 * (a0 * a11 + a1 * a10 + a2 * a9 + a3 * a8 + a4 * a7 + a5 * a6) + 38 * (2 * (a12 * a15 + a13 * a14))
	local t12 = 2 * (a0 * a12 + a1 * a11 + a2 * a10 + a3 * a9 + a4 * a8 + a5 * a7) + a6 * a6 + 38 * (2 * a13 * a15 + a14 * a14)
	local t13 = 2 * (a0 * a13 + a1 * a12 + a2 * a11 + a3 * a10 + a4 * a9 + a5 * a8 + a6 * a7) + 38 * (2 * a14 * a15)
	local t14 = 2 * (a0 * a14 + a1 * a13 + a2 * a12 + a3 * a11 + a4 * a10 + a5 * a9 + a6 * a8) + a7 * a7 + 38 * (a15 * a15)
	local t15 = 2 * (a0 * a15 + a1 * a14 + a2 * a13 + a3 * a12 + a4 * a11 + a5 * a10 + a6 * a9 + a7 * a8)
	local c
	c = floor(t0 / 65536); t0 = t0 - c * 65536; t1 = t1 + c
	c = floor(t1 / 65536); t1 = t1 - c * 65536; t2 = t2 + c
	c = floor(t2 / 65536); t2 = t2 - c * 65536; t3 = t3 + c
	c = floor(t3 / 65536); t3 = t3 - c * 65536; t4 = t4 + c
	c = floor(t4 / 65536); t4 = t4 - c * 65536; t5 = t5 + c
	c = floor(t5 / 65536); t5 = t5 - c * 65536; t6 = t6 + c
	c = floor(t6 / 65536); t6 = t6 - c * 65536; t7 = t7 + c
	c = floor(t7 / 65536); t7 = t7 - c * 65536; t8 = t8 + c
	c = floor(t8 / 65536); t8 = t8 - c * 65536; t9 = t9 + c
	c = floor(t9 / 65536); t9 = t9 - c * 65536; t10 = t10 + c
	c = floor(t10 / 65536); t10 = t10 - c * 65536; t11 = t11 + c
	c = floor(t11 / 65536); t11 = t11 - c * 65536; t12 = t12 + c
	c = floor(t12 / 65536); t12 = t12 - c * 65536; t13 = t13 + c
	c = floor(t13 / 65536); t13 = t13 - c * 65536; t14 = t14 + c
	c = floor(t14 / 65536); t14 = t14 - c * 65536; t15 = t15 + c
	c = floor(t15 / 65536); t15 = t15 - c * 65536; t0 = t0 + 38 * c
	c = floor(t0 / 65536); t0 = t0 - c * 65536; t1 = t1 + c
	c = floor(t1 / 65536); t1 = t1 - c * 65536; t2 = t2 + c
	c = floor(t2 / 65536); t2 = t2 - c * 65536; t3 = t3 + c
	c = floor(t3 / 65536); t3 = t3 - c * 65536; t4 = t4 + c
	c = floor(t4 / 65536); t4 = t4 - c * 65536; t5 = t5 + c
	c = floor(t5 / 65536); t5 = t5 - c * 65536; t6 = t6 + c
	c = floor(t6 / 65536); t6 = t6 - c * 65536; t7 = t7 + c
	c = floor(t7 / 65536); t7 = t7 - c * 65536; t8 = t8 + c
	c = floor(t8 / 65536); t8 = t8 - c * 65536; t9 = t9 + c
	c = floor(t9 / 65536); t9 = t9 - c * 65536; t10 = t10 + c
	c = floor(t10 / 65536); t10 = t10 - c * 65536; t11 = t11 + c
	c = floor(t11 / 65536); t11 = t11 - c * 65536; t12 = t12 + c
	c = floor(t12 / 65536); t12 = t12 - c * 65536; t13 = t13 + c
	c = floor(t13 / 65536); t13 = t13 - c * 65536; t14 = t14 + c
	c = floor(t14 / 65536); t14 = t14 - c * 65536; t15 = t15 + c
	c = floor(t15 / 65536); t15 = t15 - c * 65536; t0 = t0 + 38 * c
	o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11], o[12], o[13], o[14], o[15], o[16] = t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15
end

-- o = a^(2^n) (n squarings).
local function Sq(o, a, n)
	S(o, a)
	for i = 2, n do
		S(o, o)
		if i % 25 == 0 then Pause() end
	end
end

-- Powers by the usual addition chain (ref10's): 250 squarings and 11 multiplications.
-- t = z^(2^250 - 1); returns z^11 too. (Its own temporaries: a job may pause in the middle.)
local function Pow250(t, z)
	local c1, c2, c9, c11, c31, c10, c20, c50, c100 = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
	S(c2, z)            -- 2
	Sq(c1, c2, 2)       -- 8
	M(c9, c1, z)        -- 9
	M(c11, c9, c2)      -- 11
	S(c1, c11)          -- 22
	M(c31, c1, c9)      -- 2^5 - 1
	Sq(c1, c31, 5)
	M(c10, c1, c31)     -- 2^10 - 1
	Sq(c1, c10, 10)
	M(c20, c1, c10)     -- 2^20 - 1
	Sq(c1, c20, 20)
	M(c1, c1, c20)      -- 2^40 - 1
	Sq(c1, c1, 10)
	M(c50, c1, c10)     -- 2^50 - 1
	Sq(c1, c50, 50)
	M(c100, c1, c50)    -- 2^100 - 1
	Sq(c1, c100, 100)
	M(c1, c1, c100)     -- 2^200 - 1
	Sq(c1, c1, 50)
	M(t, c1, c50)       -- 2^250 - 1
	return c11
end
-- o = 1 / z = z^(p - 2) = z^(2^255 - 21).
local function Invert(o, z)
	local t = gf()
	local z11 = Pow250(t, z)
	Sq(t, t, 5)
	M(o, t, z11)
end
-- o = z^((p - 5) / 8) = z^(2^252 - 3), for square roots.
local function Pow2523(o, z)
	local t = gf()
	Pow250(t, z)
	Sq(t, t, 2)
	M(o, t, z)
end

-- The 32 bytes of n mod p (fully reduced), as numbers (TweetNaCl's pack25519).
local function Pack25519(n)
	local t, m = gf(n), gf()
	Carry(t); Carry(t); Carry(t)
	for _ = 1, 2 do
		m[1] = t[1] - 0xffed
		for i = 2, 15 do
			m[i] = t[i] - 0xffff - floor(m[i - 1] / 65536) % 2
			m[i - 1] = m[i - 1] % 65536
		end
		m[16] = t[16] - 0x7fff - floor(m[15] / 65536) % 2
		local borrow = floor(m[16] / 65536) % 2
		m[15] = m[15] % 65536
		if borrow == 0 then Set(t, m) end -- t - p did not go below zero: it is the answer
	end
	local out = {}
	for i = 1, 16 do
		out[2 * i - 1] = t[i] % 256
		out[2 * i] = floor(t[i] / 256)
	end
	return out
end
local function Equal(a, b)
	local x, y = Pack25519(a), Pack25519(b)
	for i = 1, 32 do if x[i] ~= y[i] then return false end end
	return true
end
local function Parity(a) return Pack25519(a)[1] % 2 end
-- 32 bytes (numbers) into a field number, the top bit left out.
local function Unpack25519(o, n)
	for i = 1, 16 do o[i] = n[2 * i - 1] + n[2 * i] * 256 end
	o[16] = o[16] % 32768
end

---------------------------------------------------------------------------
-- Points of the curve -x^2 + y^2 = 1 + d x^2 y^2, in extended coordinates { X, Y, Z, T }
-- (x = X/Z, y = Y/Z, T = XY/Z).
---------------------------------------------------------------------------

local function Point() return { gf(), gf(), gf(), gf() } end
local function SetPoint(p, q) for i = 1, 4 do Set(p[i], q[i]) end end
local function Identity(p) Set(p[1], ZERO); Set(p[2], ONE); Set(p[3], ONE); Set(p[4], ZERO) end

local ta, tb, tc, td, te, tf, tg, th, tt = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()

-- p = p + q (TweetNaCl's add: add-2008-hwcd-3, a = -1).
local function Add(p, q)
	Z(ta, p[2], p[1])
	Z(tt, q[2], q[1])
	M(ta, ta, tt)
	A(tb, p[1], p[2])
	A(tt, q[1], q[2])
	M(tb, tb, tt)
	M(tc, p[4], q[4])
	M(tc, tc, D2)
	M(td, p[3], q[3])
	A(td, td, td)
	Z(te, tb, ta)
	Z(tf, td, tc)
	A(tg, td, tc)
	A(th, tb, ta)
	M(p[1], te, tf)
	M(p[2], th, tg)
	M(p[3], tg, tf)
	M(p[4], te, th)
end

-- p = 2p (dbl-2008-hwcd, a = -1): 4 squarings and 4 multiplications instead of Add's 9.
local function Double(p)
	S(ta, p[1])          -- X^2
	S(tb, p[2])          -- Y^2
	S(tc, p[3])
	A(tc, tc, tc)        -- 2 Z^2
	A(th, ta, tb)        -- H = X^2 + Y^2
	A(tt, p[1], p[2])
	S(tt, tt)
	Z(te, th, tt)        -- E = H - (X + Y)^2
	Z(tg, ta, tb)        -- G = X^2 - Y^2
	A(tf, tc, tg)        -- F = 2 Z^2 + G
	M(p[1], te, tf)
	M(p[2], tg, th)
	M(p[4], te, th)
	M(p[3], tf, tg)
end

-- The 32 bytes of a point (y, and the sign of x in the top bit), as a string.
local function PackPoint(p)
	local zi, tx, ty = gf(), gf(), gf()
	Invert(zi, p[3])
	M(tx, p[1], zi)
	M(ty, p[2], zi)
	local out = Pack25519(ty)
	out[32] = out[32] + Parity(tx) * 128
	return char(unpack(out))
end

-- p = 0*q .. 15*q, for four bits at a time.
local function Table(q)
	local t = { [0] = Point() }
	Identity(t[0])
	for i = 1, 15 do
		t[i] = Point()
		if i == 1 then
			SetPoint(t[i], q)
		elseif i % 2 == 0 then
			SetPoint(t[i], t[i / 2])
			Double(t[i])
		else
			SetPoint(t[i], t[i - 1])
			Add(t[i], q)
		end
	end
	return t
end

-- Four bits of a scalar (32 bytes as numbers, little endian): the k-th from the bottom, 0-based.
local function Nibble(s, k)
	local b = s[floor(k / 2) + 1]
	if k % 2 == 1 then return floor(b / 16) end
	return b % 16
end

-- p = s1 * t1 (+ s2 * t2): tables from Table, scalars of 32 bytes. Four doublings and at most
-- two additions per four bits, from the top.
local function MultiMult(p, s1, t1, s2, t2)
	Identity(p)
	for k = 63, 0, -1 do
		if k < 63 then Double(p); Double(p); Double(p); Double(p) end
		local n = Nibble(s1, k)
		if n > 0 then Add(p, t1[n]) end
		if s2 then
			n = Nibble(s2, k)
			if n > 0 then Add(p, t2[n]) end
		end
		Pause()
	end
end

local baseTable -- 0..15 times the base point, made the first time it is needed
local function BaseTable()
	if not baseTable then
		local b = Point()
		Set(b[1], BX); Set(b[2], BY); Set(b[3], ONE); M(b[4], BX, BY)
		baseTable = Table(b)
	end
	return baseTable
end

-- -A from its 32 bytes (a string), or nil when they are not the canonical encoding of a point
-- (TweetNaCl's unpackneg, with RFC 8032's checks: y below p, and no x = 0 with the sign set).
local P_BYTES = { 0xed }
for i = 2, 31 do P_BYTES[i] = 0xff end
P_BYTES[32] = 0x7f
local function UnpackNeg(s)
	local n = { byte(s, 1, 32) }
	local top = n[32]
	n[32] = top % 128
	-- y < p: compared from the top byte down.
	local below = false
	for i = 32, 1, -1 do
		if n[i] ~= P_BYTES[i] then below = n[i] < P_BYTES[i] break end
	end
	if not below then return nil end
	n[32] = top
	local r = Point()
	local num, den, den2, den4, den6, t, chk = gf(), gf(), gf(), gf(), gf(), gf(), gf()
	Set(r[3], ONE)
	Unpack25519(r[2], n)
	S(num, r[2])
	M(den, num, D)
	Z(num, num, r[3])
	A(den, r[3], den)
	S(den2, den)
	S(den4, den2)
	M(den6, den4, den2)
	M(t, den6, num)
	M(t, t, den)
	Pow2523(t, t)
	M(t, t, num)
	M(t, t, den)
	M(t, t, den)
	M(r[1], t, den)
	S(chk, r[1])
	M(chk, chk, den)
	if not Equal(chk, num) then M(r[1], r[1], SQRTM1) end
	S(chk, r[1])
	M(chk, chk, den)
	if not Equal(chk, num) then return nil end
	local sign = floor(top / 128)
	if sign == 1 and Equal(r[1], ZERO) then return nil end
	if Parity(r[1]) == sign then Z(r[1], ZERO, r[1]) end
	M(r[4], r[1], r[2])
	return r
end

-- Is p of small order (8p is the identity)?
local function SmallOrder(p)
	local q = Point()
	SetPoint(q, p)
	Double(q); Double(q); Double(q)
	return Equal(q[1], ZERO) and Equal(q[2], q[3])
end

---------------------------------------------------------------------------
-- Scalars mod L = 2^252 + 27742317777372353535851937790883648493, as bytes (TweetNaCl's modL).
---------------------------------------------------------------------------

local LB = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

-- x (64 numbers, little endian, each below 2^21 or so) mod L, as 32 bytes (numbers).
local function ModL(x)
	for i = 64, 33, -1 do
		local carry, j = 0, i - 32
		while j < i - 12 do
			x[j] = x[j] + carry - 16 * x[i] * LB[j - (i - 32) + 1]
			carry = floor((x[j] + 128) / 256)
			x[j] = x[j] - carry * 256
			j = j + 1
		end
		x[j] = x[j] + carry
		x[i] = 0
	end
	local carry = 0
	for j = 1, 32 do
		x[j] = x[j] + carry - floor(x[32] / 16) * LB[j]
		carry = floor(x[j] / 256)
		x[j] = x[j] % 256
	end
	for j = 1, 32 do x[j] = x[j] - carry * LB[j] end
	local r = {}
	for i = 1, 32 do
		x[i + 1] = (x[i + 1] or 0) + floor(x[i] / 256)
		r[i] = x[i] % 256
	end
	return r
end

-- A 64-byte string (a SHA-512) mod L.
local function Reduce(h)
	return ModL({ byte(h, 1, 64) })
end

-- Is s (32 bytes as numbers) below L, the only spelling RFC 8032 accepts?
local function BelowL(s)
	for i = 32, 1, -1 do
		if s[i] ~= LB[i] then return s[i] < LB[i] end
	end
	return false
end

---------------------------------------------------------------------------
-- Keys, signatures and checks. Keys and signatures are binary strings: a seed and a public
-- key 32 bytes, a signature 64. Called directly they run at once; inside Ed.Run, in slices.
---------------------------------------------------------------------------

-- The secret scalar (clamped) and the prefix of a seed.
local function Expand(seed)
	local d = { byte(SHA512(seed), 1, 64) }
	d[1] = d[1] - d[1] % 8
	d[32] = d[32] % 64 + 64
	return d
end

local function BaseMult(s)
	local p = Point()
	MultiMult(p, s, BaseTable())
	return PackPoint(p)
end

function Ed.PublicKey(seed)
	assert(type(seed) == "string" and #seed == 32, "a seed is 32 bytes")
	return BaseMult(Expand(seed))
end

function Ed.Sign(seed, msg, pk)
	assert(type(seed) == "string" and #seed == 32, "a seed is 32 bytes")
	assert(type(msg) == "string", "a message is a string")
	local d = Expand(seed)
	pk = pk or BaseMult(d)
	local r = Reduce(SHA512(char(unpack(d, 33, 64)) .. msg))
	local R = BaseMult(r)
	local h = Reduce(SHA512(R .. pk .. msg))
	local x = {}
	for i = 1, 64 do x[i] = 0 end
	for i = 1, 32 do x[i] = r[i] end
	for i = 1, 32 do
		local hi = h[i]
		for j = 1, 32 do x[i + j - 1] = x[i + j - 1] + hi * d[j] end
	end
	return R .. char(unpack(ModL(x), 1, 32))
end

-- Is pk (32 bytes) a public key a signature can be checked with: the canonical encoding of a
-- point of more than small order?
function Ed.ValidPublicKey(pk)
	if type(pk) ~= "string" or #pk ~= 32 then return false end
	local negA = UnpackNeg(pk)
	return negA ~= nil and not SmallOrder(negA)
end

-- Is sig a valid signature of msg by the key pk? False for anything malformed.
function Ed.Verify(pk, msg, sig)
	if type(pk) ~= "string" or #pk ~= 32 or type(msg) ~= "string" or type(sig) ~= "string" or #sig ~= 64 then return false end
	local s = { byte(sig, 33, 64) }
	if not BelowL(s) then return false end
	local negA = UnpackNeg(pk)
	if not negA or SmallOrder(negA) then return false end
	local R = sig:sub(1, 32)
	local h = Reduce(SHA512(R .. pk .. msg))
	local p = Point()
	MultiMult(p, s, BaseTable(), h, Table(negA))
	return PackPoint(p) == R
end
