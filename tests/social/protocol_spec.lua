local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepcopy(x) end
  return out
end

local NIL = {}   -- merge(base, { key = NIL }) removes the key (a nil value cannot be stored in the override table)

local function merge(base, over)
  local out = deepcopy(base)
  for k, v in pairs(over) do
    if v == NIL then out[k] = nil else out[k] = v end
  end
  return out
end

-- a copy of profile P whose pr[line].r is replaced by r
local function with_recipe(profile, line, r)
  local out = deepcopy(profile)
  out.pr[line].r = r
  return out
end

local function rep_list(item, n)
  local out = {}
  for i = 1, n do out[i] = deepcopy(item) end
  return out
end

local function fifty_one_chars()
  local c = {}
  for i = 1, 51 do c[("N%d-Realm"):format(i)] = "0000abcd" end
  return c
end

describe("Social.Protocol", function()
  local ns, p4, Protocol, Codec
  local P
  before_each(function()
    ns, _, p4 = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
      "Modules/Social/Protocol.lua" })
    Protocol, Codec = ns.Social.Protocol, ns.Social.Codec
    P = { c = "Alt-Realm", ts = 100, lv = "q",
      pr = { { s = 2, k = 90, m = 100, r = { 20, 3, 5, 10, 2, 4 } }, { s = 1, k = 50, m = 100, r = { 7, 1, 1 } } } }
  end)

  local function valid(m) return (Protocol.Validate(m)) end

  describe("constants and constructors", function()
    it("exposes the version and prefix", function()
      assert.are.equal(1, Protocol.VERSION)
      assert.are.equal("FabStn", Protocol.PREFIX)
    end)

    it("builds H, Q and D with string keys and dense arrays", function()
      assert.are.same({ t = "H", p = 1, v = "1.0.0", c = { ["A-R"] = "0000abcd" } },
        Protocol.Hello("1.0.0", { ["A-R"] = "0000abcd" }))
      assert.are.same({ t = "Q", p = 1, c = { "A-R", "B-R" } }, Protocol.Request({ "A-R", "B-R" }))
      local d = Protocol.Data(P)
      assert.are.equal("D", d.t)
      assert.are.equal(1, d.p)
      assert.are.equal(Protocol.HashProfile(P), d.h)
      assert.are.equal("Alt-Realm", d.c)
      assert.are.equal(100, d.ts)
      assert.are.equal("q", d.lv)
      assert.are.same(P.pr, d.pr)
    end)

    it("copies caller tables so later mutation cannot change a built message", function()
      local hashes, keys = { ["A-R"] = "0000abcd" }, { "A-R" }
      local h, q = Protocol.Hello("1.0.0", hashes), Protocol.Request(keys)
      hashes["B-R"] = "11111111"; keys[2] = "B-R"
      assert.is_nil(h.c["B-R"])
      assert.are.equal(1, #q.c)
    end)

    it("keeps the version a string even when the caller has none", function()
      assert.is_true(valid(Protocol.Hello(nil, {})))
    end)
  end)

  describe("HashProfile", function()
    it("hashes order-independently and content-sensitively", function()
      local Q = deepcopy(P); Q.pr = { Q.pr[2], Q.pr[1] }; Q.pr[2].r = { 10, 2, 4, 20, 3, 5 }; Q.ts = 999
      assert.are.equal(Protocol.HashProfile(P), Protocol.HashProfile(Q))
      Q.pr[2].r[3] = 5
      assert.are_not.equal(Protocol.HashProfile(P), Protocol.HashProfile(Q))
    end)

    it("hashes the documented canonical string", function()
      -- lv|  then lines by s: s:k:m|  then recipes by id: id,q,qc;
      local expect = ns.Social.Util.Hash32("q|1:50:100|7,1,1;2:90:100|10,2,4;20,3,5;")
      assert.are.equal(expect, Protocol.HashProfile(P))
      local r = { c = "A-R", ts = 1, lv = "r", pr = { { s = 3, k = 1, m = 5, r = { 9, 4, 6 } } } }
      assert.are.equal(ns.Social.Util.Hash32("r|3:1:5|4;6;9;"), Protocol.HashProfile(r))
    end)

    it("excludes c and ts so an unchanged resync keeps the hash", function()
      local Q = deepcopy(P); Q.c = "Other-Realm"; Q.ts = 5
      assert.are.equal(Protocol.HashProfile(P), Protocol.HashProfile(Q))
    end)

    it("reacts to lv, skill, max skill, quality and line changes", function()
      local base = Protocol.HashProfile(P)
      local function changed(fn) local Q = deepcopy(P); fn(Q); return Protocol.HashProfile(Q) ~= base end
      assert.is_true(changed(function(Q) Q.lv = "r" end))
      assert.is_true(changed(function(Q) Q.pr[1].k = 91 end))
      assert.is_true(changed(function(Q) Q.pr[1].m = 101 end))
      assert.is_true(changed(function(Q) Q.pr[1].s = 3 end))
      assert.is_true(changed(function(Q) Q.pr[1].r[2] = 4 end))
      assert.is_true(changed(function(Q) table.remove(Q.pr) end))
    end)

    it("does not mutate its input", function()
      local before = deepcopy(P)
      Protocol.HashProfile(P)
      assert.are.same(before, P)
    end)

    it("is always 8 lowercase hex digits, also for an empty profile", function()
      assert.is_truthy(Protocol.HashProfile({ lv = "r", pr = {} }):match("^%x%x%x%x%x%x%x%x$"))
    end)
  end)

  describe("Wire / Unwire", function()
    it("wires and unwires; reports version mismatch without decoding", function()
      local m = Protocol.Data(P)
      assert.are.same(m, (Protocol.Unwire(Protocol.Wire(m))))
      assert.are.same({ nil, 2, "version" }, { Protocol.Unwire("2:anything") })
      assert.are.same({ nil, nil, "header" }, { Protocol.Unwire("nocolon") })
    end)

    it("prefixes the protocol version and returns it", function()
      local text = assert(Protocol.Wire(Protocol.Request({ "A-R" })))
      assert.are.equal("1:", text:sub(1, 2))
      local m, v = Protocol.Unwire(text)
      assert.are.equal("Q", m.t)
      assert.are.equal(1, v)
    end)

    it("does not touch the codec on a version mismatch", function()
      local calls = 0
      for _, name in ipairs({ "DeserializeCBOR", "DecodeBase64", "DecompressString" }) do
        local orig = C_EncodingUtil[name]
        C_EncodingUtil[name] = function(...) calls = calls + 1; return orig(...) end
      end
      assert.are.same({ nil, 9, "version" }, { Protocol.Unwire("9:" .. assert(Codec.Encode({ t = "Q" }))) })
      assert.are.equal(0, calls)
    end)

    it("reports header errors for malformed text", function()
      for _, bad in ipairs({ "", ":", "1:", ":abc", "x:abc", "1abc", "-1:abc", "1.5:abc", " 1:abc" }) do
        assert.are.same({ nil, nil, "header" }, { Protocol.Unwire(bad) }, ("%q"):format(bad))
      end
      assert.are.same({ nil, nil, "header" }, { Protocol.Unwire(nil) })
      assert.are.same({ nil, nil, "header" }, { Protocol.Unwire(42) })
      assert.are.same({ nil, nil, "header" }, { Protocol.Unwire(("9"):rep(500) .. ":x") })
    end)

    it("passes codec errors through with the version", function()
      assert.are.same({ nil, 1, "decode" }, { Protocol.Unwire("1:garbage") })
      assert.are.same({ nil, 1, "size" }, { Protocol.Unwire("1:" .. ("A"):rep(Codec.MAX_WIRE + 1)) })
      assert.are.same({ nil, 1, "type" }, { Protocol.Unwire("1:" .. p4.encodeRaw("x")) })
    end)

    it("returns the codec error from Wire when the codec is unavailable", function()
      _G.C_EncodingUtil = nil
      assert.are.same({ nil, "unavailable" }, { Protocol.Wire(Protocol.Request({})) })
      assert.are.same({ nil, 1, "unavailable" }, { Protocol.Unwire("1:abc") })
    end)
  end)

  describe("Validate", function()
    it("accepts valid shapes", function()
      assert.is_true((Protocol.Validate(Protocol.Hello("1.0.0", { ["A-R"] = "0000abcd" }))))
      assert.is_true((Protocol.Validate(Protocol.Request({ "A-R" }))))
      assert.is_true((Protocol.Validate(Protocol.Data(P))))
    end)

    it("returns nil as the second value on success and a code on failure", function()
      assert.are.same({ true, nil }, { Protocol.Validate(Protocol.Request({})) })
      local ok, err = Protocol.Validate("string")
      assert.is_false(ok)
      assert.are.equal("string", type(err))
    end)

    it("rejects out-of-bound shapes", function()
      local bad = {
        "string", {}, { t = "Z", p = 1 },
        merge(Protocol.Data(P), { lv = "x" }),
        merge(Protocol.Data(P), { c = "NoRealm" }),
        with_recipe(P, 1, { 20, 9, 5 }),               -- q out of range
        with_recipe(P, 1, { "20", 3, 5 }),             -- non-number id
        with_recipe(P, 1, { 20, 3 }),                  -- not a multiple of 3
        merge(Protocol.Data(P), { pr = rep_list(P.pr[1], 7) }),
        Protocol.Hello("1.0.0", fifty_one_chars()),
      }
      -- the profile-shaped cases above need the D wrapper: with_recipe returns a bare profile
      bad[6], bad[7], bad[8] = Protocol.Data(bad[6]), Protocol.Data(bad[7]), Protocol.Data(bad[8])
      for i, m in ipairs(bad) do assert.is_false((Protocol.Validate(m)), "case " .. i) end
    end)

    it("rejects non-tables, wrong types and bad p", function()
      for i, m in ipairs({ 1, true, function() end, "H" }) do assert.is_false(valid(m), "case " .. i) end
      assert.is_false(valid(nil))
      local h = Protocol.Hello("1.0.0", {})
      for i, p in ipairs({ "1", 1.5, 0 / 0, 1 / 0, true, {} }) do
        assert.is_false(valid(merge(h, { p = p })), "p case " .. i)
      end
      assert.is_false(valid(merge(h, { p = NIL })))
      assert.is_false(valid(merge(h, { t = NIL })))
      assert.is_false(valid(merge(h, { t = 1 })))
      assert.is_false(valid(merge(h, { t = "h" })))
    end)

    describe("charKeys", function()
      local function req(key) return Protocol.Request({ key }) end
      it("accepts Name-Realm and rejects everything else", function()
        assert.is_true(valid(req("Thrall-Area52")))
        assert.is_true(valid(req("Thrall-Mal'Ganis")))
        assert.is_true(valid(req("Zoë-Ravenholdt")))
        for _, k in ipairs({ "NoRealm", "-Realm", "Name-", "A-B-C", "Na me-Realm", "Name-Re alm", "Name-Realm\n",
          "", "A-\tR", ("x"):rep(33) .. "-" .. ("y"):rep(32) }) do
          assert.is_false(valid(req(k)), ("%q"):format(k))
        end
        assert.is_true(valid(req(("x"):rep(31) .. "-" .. ("y"):rep(32))))   -- exactly 64
        assert.is_false(valid(Protocol.Request({ 5 })))
        assert.is_false(valid(Protocol.Request({ true })))
      end)
    end)

    describe("HELLO", function()
      local function hello(c, v) return { t = "H", p = 1, v = v or "1.0.0", c = c } end
      it("accepts the empty withdraw map and up to 50 entries", function()
        assert.is_true(valid(hello({})))
        local c = {}
        for i = 1, 50 do c[("N%d-R"):format(i)] = "0000abcd" end
        assert.is_true(valid(hello(c)))
        c["N51-R"] = "0000abcd"
        assert.is_false(valid(hello(c)))
      end)
      it("bounds the version string", function()
        assert.is_true(valid(hello({}, ("v"):rep(32))))
        assert.is_false(valid(hello({}, ("v"):rep(33))))
        assert.is_false(valid(hello({}, 1)))
        assert.is_false(valid({ t = "H", p = 1, c = {} }))
      end)
      it("requires 8 lowercase hex hash values", function()
        for _, h in ipairs({ "0000abc", "0000abcde", "0000ABCD", "0000abcg", "", 12345678, true, {} }) do
          assert.is_false(valid(hello({ ["A-R"] = h })), tostring(h))
        end
        assert.is_true(valid(hello({ ["A-R"] = "deadbeef" })))
      end)
      it("rejects a non-map c and array keys", function()
        assert.is_false(valid(hello(nil)))
        assert.is_false(valid(hello("x")))
        assert.is_false(valid(hello({ "0000abcd" })))
        assert.is_false(valid(hello({ [1.5] = "0000abcd" })))
        assert.is_false(valid(hello({ ["bad key-R"] = "0000abcd" })))
      end)
    end)

    describe("REQUEST", function()
      it("accepts up to 50 keys and rejects 51", function()
        local c = {}
        for i = 1, 50 do c[i] = ("N%d-R"):format(i) end
        assert.is_true(valid({ t = "Q", p = 1, c = c }))
        c[51] = "N51-R"
        assert.is_false(valid({ t = "Q", p = 1, c = c }))
      end)
      it("requires a dense array", function()
        assert.is_false(valid({ t = "Q", p = 1, c = { [1] = "A-R", [3] = "B-R" } }))
        assert.is_false(valid({ t = "Q", p = 1, c = { [2] = "A-R" } }))
        assert.is_false(valid({ t = "Q", p = 1, c = { x = "A-R" } }))
        assert.is_false(valid({ t = "Q", p = 1, c = "A-R" }))
        assert.is_false(valid({ t = "Q", p = 1 }))
        assert.is_false(valid({ t = "Q", p = 1, c = { [1.5] = "A-R" } }))
      end)
    end)

    describe("DATA", function()
      local function data(over) return merge(Protocol.Data(P), over or {}) end
      local function line(r, over) return merge({ s = 1, k = 1, m = 1, r = r }, over or {}) end
      local function rdata(lv, r, over) return data({ lv = lv, pr = { line(r, over) } }) end

      it("checks the header fields", function()
        assert.is_true(valid(data()))
        for _, h in ipairs({ "0000ABCD", "123", 5, true }) do assert.is_false(valid(data({ h = h })), tostring(h)) end
        assert.is_false(valid(data({ h = NIL })))
        assert.is_false(valid(data({ ts = "100" })))
        assert.is_false(valid(data({ ts = 0 / 0 })))
        assert.is_false(valid(data({ ts = 1 / 0 })))
        assert.is_false(valid(data({ ts = NIL })))
        assert.is_true(valid(data({ ts = 1767225600.5 })))
        assert.is_false(valid(data({ lv = NIL })))
        assert.is_false(valid(data({ c = NIL })))
        assert.is_false(valid(data({ pr = NIL })))
        assert.is_false(valid(data({ pr = "x" })))
      end)

      it("caps the profile at 6 lines and requires a dense array", function()
        assert.is_true(valid(data({ pr = rep_list(P.pr[1], 6) })))
        local err = select(2, Protocol.Validate(data({ pr = rep_list(P.pr[1], 7) })))
        assert.are.equal("pr.count", err)
        assert.is_true(valid(data({ pr = {} })))
        assert.is_false(valid(data({ pr = { [2] = P.pr[1] } })))
        assert.is_false(valid(data({ pr = { P.pr[1], "x" } })))
      end)

      it("checks skill line, skill and max skill", function()
        for _, s in ipairs({ 0, -1, 1.5, "2", 0 / 0, 1 / 0 }) do
          assert.is_false(valid(rdata("r", { 1 }, { s = s })), "s " .. tostring(s))
        end
        assert.is_true(valid(rdata("r", { 1 }, { s = 2823 })))
        assert.is_false(valid(rdata("r", { 1 }, { s = NIL })))
        assert.is_true(valid(rdata("r", { 1 }, { k = 0, m = 0 })))
        assert.is_true(valid(rdata("r", { 1 }, { k = 1000, m = 1000 })))
        assert.is_false(valid(rdata("r", { 1 }, { k = -1 })))
        assert.is_false(valid(rdata("r", { 1 }, { m = 1001, k = 5 })))
        assert.is_false(valid(rdata("r", { 1 }, { k = 6, m = 5 })))
        assert.is_false(valid(rdata("r", { 1 }, { k = 1.5, m = 5 })))
        assert.is_false(valid(rdata("r", { 1 }, { k = "1", m = 5 })))
        assert.is_false(valid(rdata("r", { 1 }, { k = NIL })))
        assert.is_false(valid(rdata("r", { 1 }, { m = NIL })))
      end)

      it("checks lv=r recipe lists", function()
        assert.is_true(valid(rdata("r", {})))
        assert.is_true(valid(rdata("r", { 1, 2, 10000000 })))
        assert.is_true(valid(rdata("r", { 1, 2 })))   -- no multiple-of-3 rule for lv=r
        for _, id in ipairs({ 0, -5, 10000001, 1.5, "7", true, 0 / 0, 1 / 0 }) do
          assert.is_false(valid(rdata("r", { 4, id })), "id " .. tostring(id))
        end
        assert.is_false(valid(rdata("r", { [1] = 1, [3] = 3 })))
        assert.is_false(valid(rdata("r", { x = 1 })))
        assert.is_false(valid(rdata("r", nil)))
        assert.is_false(valid(rdata("r", "str")))
      end)

      it("checks lv=q triples", function()
        assert.is_true(valid(rdata("q", {})))
        assert.is_true(valid(rdata("q", { 1, 0, 0, 2, 5, 5 })))
        assert.is_false(valid(rdata("q", { 1, 6, 0 })))
        assert.is_false(valid(rdata("q", { 1, 0, 6 })))
        assert.is_false(valid(rdata("q", { 1, -1, 0 })))
        assert.is_false(valid(rdata("q", { 1, 0, 1.5 })))
        assert.is_false(valid(rdata("q", { 1, "0", 0 })))
        assert.is_false(valid(rdata("q", { 1, 2, 3, 4 })))
        assert.is_false(valid(rdata("q", { 1 })))
        assert.is_false(valid(rdata("q", { 0, 1, 1 })))
        assert.is_false(valid(rdata("q", { 10000001, 1, 1 })))
      end)

      it("bounds the recipe list at 12000 entries", function()
        local function list(n, v) local t = {} for i = 1, n do t[i] = v or (i % 3 == 1 and 5 or 1) end return t end
        assert.is_true(valid(rdata("r", list(12000, 5))))
        local err = select(2, Protocol.Validate(rdata("r", list(12001, 5))))
        assert.are.equal("r.count", err)
        assert.is_true(valid(rdata("q", list(12000))))
        assert.is_false(valid(rdata("q", list(12003))))
      end)

      it("stops counting an oversized list early", function()
        -- 10^6 entries: a validator that walked the whole list would be visibly slow, one that stops at the cap is not
        local t = {}
        for i = 1, 1000000 do t[i] = 1 end
        -- Collect first and keep the collector off while timing: the clock is CPU time, and a GC step walking a big heap
        -- is not the validator's cost (on CI it made this call overrun the budget).
        collectgarbage()
        collectgarbage("stop")
        local started = os.clock()
        local ok = valid(rdata("r", t))
        local elapsed = os.clock() - started
        collectgarbage("restart")
        assert.is_false(ok)
        assert.is_true(elapsed < 0.5, "took " .. elapsed .. " s")
      end)
    end)

    it("reports distinct, stable error codes for the limits Guild builds against", function()
      local function err(m) return select(2, Protocol.Validate(m)) end
      assert.are.equal("pr.count", err(Protocol.Data(merge(P, { pr = rep_list(P.pr[1], 7) }))))
      assert.are.equal("r.count", err(Protocol.Data(with_recipe(P, 1, (function()
        local t = {} for i = 1, 12003 do t[i] = i % 3 == 1 and 5 or 1 end return t end)()))))
      assert.are.equal("lv", err(Protocol.Data(merge(P, { lv = "x" }))))
      assert.are.equal("t", err({ t = "Z", p = 1 }))
      assert.are.equal("p", err({ t = "Q", p = 1.5, c = {} }))
    end)

    it("exposes the limits as data", function()
      local L = Protocol.LIMITS
      assert.are.equal(6, L.MAX_LINES)
      assert.are.equal(12000, L.MAX_RECIPE_ENTRIES)
      assert.are.equal(50, L.MAX_CHARS)
      assert.are.equal(64, L.MAX_CHARKEY)
      assert.are.equal(32, L.MAX_VERSION)
      assert.are.equal(10000000, L.MAX_RECIPE_ID)
      assert.are.equal(1000, L.MAX_SKILL)
      assert.are.equal(5, L.MAX_QUALITY)
    end)

    it("never raises on hostile input", function()
      local cyc = {}; cyc.self = cyc
      local hostile = {
        { t = "D", p = 1, c = cyc, h = cyc, ts = cyc, lv = cyc, pr = cyc },
        { t = "D", p = 1, c = "A-R", h = "0000abcd", ts = 1, lv = "q", pr = { cyc } },
        { t = "D", p = 1, c = "A-R", h = "0000abcd", ts = 1, lv = "q", pr = { { s = 1, k = 1, m = 1, r = cyc } } },
        { t = "H", p = 1, v = "x", c = { [cyc] = "0000abcd" } },
        { t = "H", p = 1, v = "x", c = { [{}] = {} } },
        { t = "Q", p = 1, c = { cyc } },
        setmetatable({}, { __index = function() error("trap") end }),
        setmetatable({ t = "Q", p = 1 }, { __index = function() error("trap") end }),
      }
      for i, m in ipairs(hostile) do
        local ok, res = pcall(Protocol.Validate, m)
        assert.is_true(ok, "raised on case " .. i)
        assert.is_false(res, "accepted case " .. i)
      end
    end)

    it("validates a message that went through the whole wire path", function()
      local m = assert(Protocol.Unwire(assert(Protocol.Wire(Protocol.Data(P)))))
      assert.is_true(valid(m))
    end)
  end)
end)
