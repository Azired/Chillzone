-- Published RFC 8032 and cross-implementation vectors against the vendored code.
local T = ...
local env = setmetatable({ bit = require("bit") }, { __index = _G })
env._G = env
local ns = T.load({ "libs/Ed25519.lua" }, env)
local Ed = ns.Ed25519

T.test("signatures: public keys and signatures match all external vectors", function()
    local n = 0
    for line in T.read(T.ROOT .. "/tests/fixtures/ed25519-vectors.txt"):gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local name, seed, pk, text, signature = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+)$")
            T.ok(name, "well-formed external vector")
            seed, pk, signature = Ed.FromHex(seed), Ed.FromHex(pk), Ed.FromHex(signature)
            text = text == "-" and "" or Ed.FromHex(text)
            T.eq(Ed.PublicKey(seed), pk, name .. ": public key")
            T.eq(Ed.Sign(seed, text, pk), signature, name .. ": exact signature")
            T.ok(Ed.Verify(pk, text, signature), name .. ": authentic signature")
            T.no(Ed.Verify(pk, text .. "!", signature), name .. ": changed text")
            n = n + 1
        end
    end
    T.eq(n, 14, "complete external vector corpus")
end)

T.test("signatures: malformed signatures and small-order public keys fail closed", function()
    local identity = "\1" .. string.rep("\0", 31)
    local forged = Ed.FromHex("58" .. string.rep("66", 31) .. "01" .. string.rep("00", 31))
    T.no(Ed.ValidPublicKey(identity), "identity point cannot be a signing identity")
    T.no(Ed.ValidPublicKey(string.rep("\0", 32)), "small-order point rejected")
    T.no(Ed.Verify(identity, "any message", forged), "small-order forgery rejected")
    T.no(Ed.Verify(identity, nil, forged), "wrong types rejected")
    T.eq(#Ed.ToB64(string.rep("\0", 64)), 86, "wire signature overhead")
end)
