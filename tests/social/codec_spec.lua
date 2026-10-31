describe("Social.Codec", function()
  local ns, p4, Codec
  before_each(function()
    ns, _, p4 = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua" })
    Codec = ns.Social.Codec
  end)

  it("is available with the fake codec and exposes the limits", function()
    assert.is_true(Codec.IsAvailable())
    assert.are.equal(16384, Codec.MAX_WIRE)
    assert.are.equal(262144, Codec.MAX_DECODED)
  end)

  it("round-trips a table", function()
    local v = { t = "H", c = { ["A-R"] = "0000abcd" } }
    assert.are.same(v, Codec.Decode(assert(Codec.Encode(v))))
  end)

  it("returns errors instead of throwing", function()
    assert.are.same({ nil, "decode" }, { Codec.Decode("garbage") })
    assert.are.same({ nil, "size" }, { Codec.Decode(string.rep("A", Codec.MAX_WIRE + 1)) })
    assert.are.same({ nil, "type" }, { Codec.Decode(p4.encodeRaw("x")) })
    _G.C_EncodingUtil = nil
    assert.is_false(Codec.IsAvailable())
    assert.are.same({ nil, "unavailable" }, { Codec.Encode({}) })
    assert.are.same({ nil, "unavailable" }, { Codec.Decode("anything") })
  end)

  it("is unavailable unless all six functions exist", function()
    for _, name in ipairs({ "SerializeCBOR", "DeserializeCBOR", "CompressString", "DecompressString",
      "EncodeBase64", "DecodeBase64" }) do
      local saved = C_EncodingUtil[name]
      C_EncodingUtil[name] = nil
      assert.is_false(Codec.IsAvailable(), name)
      C_EncodingUtil[name] = saved
    end
    assert.is_true(Codec.IsAvailable())
  end)

  it("treats non-strings and empty strings as undecodable", function()
    for _, bad in ipairs({ 42, true, {}, "" }) do
      assert.are.same({ nil, "decode" }, { Codec.Decode(bad) })
    end
    assert.are.same({ nil, "decode" }, { Codec.Decode(nil) })
  end)

  it("accepts a wire string of exactly MAX_WIRE bytes and rejects one byte more", function()
    -- the fake base64 wrapper is "b64(" .. inner .. ")", so a well-formed string can be padded to an exact length
    local at = "b64(" .. string.rep("x", Codec.MAX_WIRE - 5) .. ")"
    assert.are.equal(Codec.MAX_WIRE, #at)
    assert.are.same({ nil, "decode" }, { Codec.Decode(at) })  -- past the size gate, then not valid compressed data
    assert.are.same({ nil, "size" }, { Codec.Decode(at .. "x") })
  end)

  it("rejects a decompression bomb before CBOR parsing", function()
    local parsed = false
    C_EncodingUtil.DeserializeCBOR = function() parsed = true; return {} end
    C_EncodingUtil.DecodeBase64 = function() return "x" end
    C_EncodingUtil.DecompressString = function() return string.rep("y", Codec.MAX_DECODED + 1) end
    assert.are.same({ nil, "size" }, { Codec.Decode("short") })
    assert.is_false(parsed)
  end)

  it("accepts a decompressed payload of exactly MAX_DECODED bytes", function()
    C_EncodingUtil.DecodeBase64 = function() return "x" end
    C_EncodingUtil.DecompressString = function() return string.rep("y", Codec.MAX_DECODED) end
    -- passes the size gate; the unknown token then raises inside DeserializeCBOR and is reported as "decode"
    assert.are.same({ nil, "decode" }, { Codec.Decode("short") })
  end)

  it("maps every kind of API failure to a code without raising", function()
    local E = C_EncodingUtil
    E.DecodeBase64 = function() error("boom") end
    assert.are.same({ nil, "decode" }, { Codec.Decode("short") })
    E.DecodeBase64 = function() return nil end
    assert.are.same({ nil, "decode" }, { Codec.Decode("short") })
    E.DecodeBase64 = function() return "ok" end
    E.DecompressString = function() error("boom") end
    assert.are.same({ nil, "decode" }, { Codec.Decode("short") })
    E.DecompressString = function() return nil end
    assert.are.same({ nil, "decode" }, { Codec.Decode("short") })
    E.DecompressString = function() return "tok" end
    E.DeserializeCBOR = function() error("boom") end
    assert.are.same({ nil, "decode" }, { Codec.Decode("short") })
    E.DeserializeCBOR = function() return nil end
    assert.are.same({ nil, "type" }, { Codec.Decode("short") })
  end)

  it("reports encode failures", function()
    local orig = C_EncodingUtil.SerializeCBOR
    C_EncodingUtil.SerializeCBOR = function() error("unsupported") end
    assert.are.same({ nil, "encode" }, { Codec.Encode({ a = 1 }) })
    C_EncodingUtil.SerializeCBOR = orig
    local cyclic = {}; cyclic.self = cyclic
    assert.are.same({ nil, "encode" }, { Codec.Encode(cyclic) })
    C_EncodingUtil.CompressString = function() return nil end
    assert.are.same({ nil, "encode" }, { Codec.Encode({ a = 1 }) })
  end)

  it("encodes with Deflate", function()
    local seen
    local orig = C_EncodingUtil.CompressString
    C_EncodingUtil.CompressString = function(s, method) seen = method; return orig(s, method) end
    assert.is_truthy(Codec.Encode({ a = 1 }))
    assert.are.equal(Enum.CompressionMethod.Deflate, seen)
  end)

  it("never returns a non-table value from Decode", function()
    for _, v in ipairs({ "s", 5, true }) do
      assert.are.same({ nil, "type" }, { Codec.Decode(p4.encodeRaw(v)) })
    end
  end)
end)
