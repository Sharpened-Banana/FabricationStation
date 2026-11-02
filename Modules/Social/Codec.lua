local ADDON_NAME, ns = ...

-- Table <-> wire-safe string through the client's C_EncodingUtil: CBOR -> Deflate -> Base64. A plain helper on
-- ns.Social.Codec (no module, no events, no state). Every call into the client API runs inside pcall and every failure
-- comes back as a code, never as an error: Decode is fed untrusted peer data.
--
-- Size limits: the wire string is rejected above MAX_WIRE before any decoding, and the decompressed bytes above
-- MAX_DECODED before CBOR parsing. DecompressString has no output limit parameter, so MAX_WIRE is also what bounds
-- the transient expansion (about 12 KB of Deflate expands to at most ~12 MB, and is dropped straight away).
ns.Social = ns.Social or {}
local Codec = {}
ns.Social.Codec = Codec

Codec.MAX_WIRE = 16384
Codec.MAX_DECODED = 262144

local FUNCTIONS = { "SerializeCBOR", "DeserializeCBOR", "CompressString", "DecompressString", "EncodeBase64",
  "DecodeBase64" }

-- True when C_EncodingUtil exists with all six functions (and the Deflate method id they are called with).
function Codec.IsAvailable()
  local api = C_EncodingUtil
  if type(api) ~= "table" then return false end
  for _, name in ipairs(FUNCTIONS) do
    if type(api[name]) ~= "function" then return false end
  end
  local methods = Enum and Enum.CompressionMethod
  return type(methods) == "table" and methods.Deflate ~= nil
end

-- value -> base64 string | nil, "unavailable" | "encode". Does not enforce MAX_WIRE (the in-game selftest measures real
-- sizes); a sender that produces more than MAX_WIRE just gets dropped by every receiver's Decode.
function Codec.Encode(value)
  if not Codec.IsAvailable() then return nil, "unavailable" end
  local api, deflate = C_EncodingUtil, Enum.CompressionMethod.Deflate
  local ok, serialized = pcall(api.SerializeCBOR, value)
  if not ok or type(serialized) ~= "string" then return nil, "encode" end
  local compressed
  ok, compressed = pcall(api.CompressString, serialized, deflate)
  if not ok or type(compressed) ~= "string" then return nil, "encode" end
  local encoded
  ok, encoded = pcall(api.EncodeBase64, compressed)
  if not ok or type(encoded) ~= "string" or encoded == "" then return nil, "encode" end
  return encoded
end

-- string -> table | nil, "unavailable" | "size" | "decode" | "type". The two decoding APIs that return nothing on bad
-- input (DecodeBase64, DecompressString) and any that raise are both "decode".
function Codec.Decode(s)
  if not Codec.IsAvailable() then return nil, "unavailable" end
  if type(s) ~= "string" or s == "" then return nil, "decode" end
  if #s > Codec.MAX_WIRE then return nil, "size" end
  local api, deflate = C_EncodingUtil, Enum.CompressionMethod.Deflate
  local ok, compressed = pcall(api.DecodeBase64, s)
  if not ok or type(compressed) ~= "string" then return nil, "decode" end
  local raw
  ok, raw = pcall(api.DecompressString, compressed, deflate)
  if not ok or type(raw) ~= "string" then return nil, "decode" end
  if #raw > Codec.MAX_DECODED then return nil, "size" end
  local value
  ok, value = pcall(api.DeserializeCBOR, raw)
  if not ok then return nil, "decode" end
  if type(value) ~= "table" then return nil, "type" end
  return value
end
