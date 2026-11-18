local T = require("testlib")
require("lib.utils")
local codec = require("ha.codec")
local prefix = string.rep("ordinary ASCII span ", 1000)
local utf8 = "é漢😀"
T.section("bounded spans retain strict UTF-8, escapes and container identities")
for _, value in ipairs({ "", "short", prefix, prefix .. utf8 .. prefix, 'quote"slash\\newline\n', utf8 }) do
  T.eq("strict string round trip", codec.decode(codec.encode(value)), value)
end
T.eq("Unicode surrogate pair remains valid", codec.decode('"\\uD83D\\uDE00"'), "😀")
T.eq("escaped controls remain valid", codec.decode('"\\b\\f\\n\\r\\t"'), "\b\f\n\r\t")
local shape = codec.decode('{"null":null,"array":[],"object":{}}')
T.eq("null sentinel retained", shape.null, codec.null)
T.truthy("empty array retained", codec.isArray(shape.array))
T.truthy("empty object retained", codec.isObject(shape.object))
T.section("malformed tails after large spans remain rejected")
for _, raw in ipairs({
  '"' .. prefix,
  '"' .. prefix .. '\\x"',
  '"' .. prefix .. '\\u12"',
  '"' .. prefix .. string.char(0) .. '"',
  '"' .. prefix .. string.char(31) .. '"',
  '"' .. prefix .. string.char(0xC3) .. '"',
  '"' .. prefix .. string.char(0xE6, 0xBC) .. '"',
  '"' .. prefix .. string.char(0xF0, 0x9F, 0x98) .. '"',
  '"' .. prefix .. '" trailing',
}) do
  local ok = pcall(codec.decode, raw)
  T.eq("invalid strict input rejected", ok, false)
end
T.section("template's permissive mode recovers four-byte escaped Unicode")
local permissive = require("JSON"):new({ strictParsing = false })
T.eq("four-byte unknown escape follows permissive contract", permissive:decode('"\\😀"'), "😀")
T.eq("strict mode still rejects same escape", pcall(codec.decode, '"\\😀"'), false)
T.finish()
