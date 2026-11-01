-- Comm: the gated AceComm transport (send queue, send results, inbound dispatch, per-sender rate limit).
-- The fake ace here is asynchronous like the real one: SendCommMessage only records, and the spec fires the per-chunk
-- callbacks itself. One block at the end drives the shared synchronous AceComm fake of the phase-4 harness (p4.comm).
describe("Comm", function()
  local ns, p4, Comm, Protocol, Codec, gate, comm, ace, got

  local function fake_ace()
    local a = { sent = {} }
    function a:SendCommMessage(prefix, text, dist, target, prio, cb, arg)
      a.sent[#a.sent + 1] = { prefix = prefix, text = text, dist = dist, target = target, prio = prio, cb = cb, arg = arg }
    end
    -- Fires the callback of the n-th SendCommMessage call the way AceComm does for one chunk.
    function a:callback(n, result, bytesSent)
      local s = self.sent[n]
      s.cb(s.arg, bytesSent or 255, #s.text, result)
    end
    return a
  end

  local function hello(v) return Protocol.Hello(v or "1.0.0", {}) end

  -- A DATA message long enough to need several 255-byte chunks.
  local function big_data_msg()
    local r = {}
    for i = 1, 600 do r[i] = 1000 + i end
    return Protocol.Data({ c = "Me-Realm", ts = 1, lv = "r", pr = { { s = 1, k = 1, m = 100, r = r } } })
  end

  local function new_comm(overrides)
    local deps = { ace = ace, gate = gate, selfName = function() return "Me-Realm" end, now = function() return ns.FS:Now() end }
    for k, v in pairs(overrides or {}) do deps[k] = v end
    return Comm.New(deps)
  end

  before_each(function()
    ns, _, p4 = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
      "Modules/Social/Protocol.lua", "Modules/Social/Comm.lua" })
    Comm, Protocol, Codec, gate = ns.Social.Comm, ns.Social.Protocol, ns.Social.Codec, ns.Social.Gate
    ace = fake_ace()
    comm = new_comm()
    got = {}
    comm:RegisterHandler("H", function(m, s, d) got[#got + 1] = { m, s, d } end)
  end)

  describe("Send", function()
    it("sends immediately when unlocked", function()
      assert.are.equal("sent", comm:Send(hello(), "GUILD"))
      assert.are.equal(1, #ace.sent)
      assert.are.equal("FabStn", ace.sent[1].prefix)
      assert.are.equal("GUILD", ace.sent[1].dist)
      assert.is_nil(ace.sent[1].target)
      assert.truthy(ace.sent[1].text:match("^1:"))
      assert.are.equal("NORMAL", ace.sent[1].prio)
      assert.are.equal(0, comm:QueueSize())
      assert.are.equal(1, comm.stats.sent)
    end)

    it("passes the whisper target and an explicit BULK priority through", function()
      comm:Send(Protocol.Request({ "A-R" }), "WHISPER", "A-R", { prio = "BULK" })
      assert.are.equal("WHISPER", ace.sent[1].dist)
      assert.are.equal("A-R", ace.sent[1].target)
      assert.are.equal("BULK", ace.sent[1].prio)
    end)

    it("falls back to NORMAL for an unknown priority", function()
      comm:Send(hello(), "GUILD", nil, { prio = "WHATEVER" })
      assert.are.equal("NORMAL", ace.sent[1].prio)
    end)

    it("queues while locked, coalesces by key, flushes FIFO on unlock", function()
      p4.restriction.chatActive = true
      assert.are.equal("queued", comm:Send(hello("1.0.0"), "GUILD", nil, { key = "hello" }))
      comm:Send(Protocol.Request({ "A-R" }), "WHISPER", "A-R")
      comm:Send(hello("1.0.1"), "GUILD", nil, { key = "hello" })
      assert.are.equal(2, comm:QueueSize())
      assert.are.equal(0, #ace.sent)
      p4.restriction.chatActive = false
      comm:Flush()
      assert.are.equal(2, #ace.sent)
      assert.are.equal("1.0.1", Protocol.Unwire(ace.sent[1].text).v) -- the replaced entry keeps its queue slot
      assert.are.equal("Q", Protocol.Unwire(ace.sent[2].text).t)
      assert.are.equal(0, comm:QueueSize())
    end)

    it("does not coalesce entries without a key", function()
      p4.restriction.chatActive = true
      comm:Send(hello(), "GUILD"); comm:Send(hello(), "GUILD")
      assert.are.equal(2, comm:QueueSize())
    end)

    it("caps the queue at 50 and drops the oldest", function()
      p4.restriction.chatActive = true
      for i = 1, 51 do comm:Send(hello("v" .. i), "GUILD", nil, { key = "k" .. i }) end
      assert.are.equal(50, comm:QueueSize())
      assert.are.equal(1, comm.stats.dropped)
      p4.restriction.chatActive = false; comm:Flush()
      assert.are.equal(50, #ace.sent)
      assert.are.equal("v2", Protocol.Unwire(ace.sent[1].text).v)   -- v1 is gone
      assert.are.equal("v51", Protocol.Unwire(ace.sent[50].text).v)
    end)

    it("keeps arrival order when a message arrives behind a queue while the gate is open", function()
      p4.restriction.chatActive = true
      comm:Send(hello("first"), "GUILD")
      p4.restriction.chatActive = false      -- open again, but nothing flushed yet
      assert.are.equal("sent", comm:Send(hello("second"), "GUILD"))
      assert.are.equal("first", Protocol.Unwire(ace.sent[1].text).v)
      assert.are.equal("second", Protocol.Unwire(ace.sent[2].text).v)
    end)

    it("drops what cannot be sent", function()
      assert.are.equal("dropped", comm:Send(hello(), "PARTY"))
      assert.are.equal("dropped", comm:Send(hello(), "WHISPER"))
      assert.are.equal("dropped", comm:Send(hello(), "WHISPER", ""))
      assert.are.equal("dropped", comm:Send(nil, "GUILD"))
      local cyclic = {}; cyclic.self = cyclic
      assert.are.equal("dropped", comm:Send(cyclic, "GUILD"))
      assert.are.equal(5, comm.stats.dropped)
      assert.are.equal(0, #ace.sent)
    end)

    it("drops everything when the codec is unavailable", function()
      _G.C_EncodingUtil = nil
      assert.are.equal("dropped", comm:Send(hello(), "GUILD"))
      assert.are.equal(0, comm:QueueSize())
    end)

    it("drops a message no peer would accept (over MAX_WIRE)", function()
      local huge = Protocol.Hello("1.0.0", {})
      huge.v = string.rep("x", Codec.MAX_WIRE + 10)
      assert.are.equal("dropped", comm:Send(huge, "GUILD"))
      assert.are.equal(0, #ace.sent)
    end)
  end)

  describe("send results", function()
    it("requeues the whole message when a later chunk hits lockdown, exactly once", function()
      assert.are.equal("sent", comm:Send(big_data_msg(), "GUILD", nil, { prio = "BULK" }))
      local text = ace.sent[1].text
      assert.is_true(#text > 510)
      ace:callback(1, 0)     -- first chunk Success
      ace:callback(1, 11)    -- second chunk AddOnMessageLockdown
      ace:callback(1, 11)    -- third chunk: must not requeue a second time
      assert.are.equal(1, comm:QueueSize())
      assert.are.same({ true, "sendFailed" }, { gate:IsLocked() })
      p4.advance(60)
      comm:Flush()
      assert.are.equal(2, #ace.sent)
      assert.are.equal(text, ace.sent[2].text)
      assert.are.equal("BULK", ace.sent[2].prio)
      assert.are.equal(0, comm:QueueSize())
    end)

    it("does not resend while the back-off lasts", function()
      comm:Send(hello(), "GUILD")
      ace:callback(1, 11)
      p4.advance(59); comm:Flush()
      assert.are.equal(1, #ace.sent)
      assert.are.equal(1, comm:QueueSize())
    end)

    it("ignores a late callback of an earlier attempt", function()
      comm:Send(big_data_msg(), "GUILD")
      ace:callback(1, 11)                  -- attempt 1 fails, requeued
      p4.advance(60); comm:Flush()         -- attempt 2 is out
      assert.are.equal(2, #ace.sent)
      ace:callback(1, 11)                  -- a straggling chunk of attempt 1
      assert.are.equal(0, comm:QueueSize())
      assert.are.equal(2, comm.stats.sent)
    end)

    it("drops after 3 lockdown attempts", function()
      comm:Send(hello(), "GUILD")
      ace:callback(1, 11)
      for attempt = 2, 3 do
        p4.advance(60); comm:Flush()
        assert.are.equal(attempt, #ace.sent)
        ace:callback(attempt, 11)
      end
      assert.are.equal(0, comm:QueueSize())
      assert.are.equal(1, comm.stats.dropped)
      p4.advance(60); comm:Flush()
      assert.are.equal(3, #ace.sent)
    end)

    it("drops on every permanent failure result and ignores the transient ones", function()
      for _, result in ipairs({ 10, 12, 7, 1, 2, 4 }) do
        comm:Send(hello(), "GUILD")
        ace:callback(#ace.sent, result)
      end
      assert.are.equal(0, comm:QueueSize())
      assert.are.equal(6, comm.stats.dropped)
      assert.is_false((gate:IsLocked()))
      for _, result in ipairs({ 0, 3, 8, 5 }) do
        local before = comm.stats.dropped
        comm:Send(hello(), "GUILD")
        ace:callback(#ace.sent, result)
        assert.are.equal(before, comm.stats.dropped)
        assert.are.equal(0, comm:QueueSize())
      end
    end)

    it("does not let a requeued message jump over a newer one with the same key", function()
      comm:Send(hello("old"), "GUILD", nil, { key = "hello" })
      p4.restriction.chatActive = true
      comm:Send(hello("new"), "GUILD", nil, { key = "hello" })
      ace:callback(1, 11)                       -- "old" fails after "new" was queued: superseded
      assert.are.equal(1, comm:QueueSize())
      p4.restriction.chatActive = false; p4.advance(60); comm:Flush()
      assert.are.equal("new", Protocol.Unwire(ace.sent[2].text).v)
      assert.are.equal(2, #ace.sent)
    end)

    it("puts a requeued message ahead of what was queued behind it", function()
      comm:Send(hello("first"), "GUILD")        -- out, still waiting for its callback
      p4.restriction.lockdown = true
      comm:Send(hello("second"), "GUILD")       -- queued
      ace:callback(1, 11)
      p4.restriction.lockdown = false; p4.advance(60); comm:Flush()
      assert.are.equal("first", Protocol.Unwire(ace.sent[2].text).v)
      assert.are.equal("second", Protocol.Unwire(ace.sent[3].text).v)
    end)

    it("survives an error raised by ace and keeps flushing", function()
      p4.restriction.chatActive = true
      comm:Send(hello("a"), "GUILD"); comm:Send(hello("b"), "GUILD")
      p4.restriction.chatActive = false
      local calls = 0
      function ace:SendCommMessage(...)
        calls = calls + 1
        if calls == 1 then error("boom") end
        self.sent[#self.sent + 1] = { text = select(2, ...) }
      end
      comm:Flush()
      assert.are.equal(2, calls)
      assert.are.equal(1, #ace.sent)
      assert.are.equal("b", Protocol.Unwire(ace.sent[1].text).v)
      assert.are.equal(0, comm:QueueSize())
      assert.are.equal(1, comm.stats.dropped)
    end)

    it("works with the synchronous AceComm fake of the harness", function()
      local sync = p4.comm.embed({})
      local c = new_comm({ ace = sync })
      p4.comm.sendResult = function(chunk) return chunk == 2 and 11 or 0 end
      assert.are.equal("queued", c:Send(big_data_msg(), "GUILD"))
      assert.are.equal(1, c:QueueSize())
      assert.are.equal(1, #p4.comm.sent)
      p4.comm.sendResult = 0
      p4.advance(60); c:Flush()
      assert.are.equal(0, c:QueueSize())
      assert.are.equal(p4.comm.sent[1].text, p4.comm.sent[2].text)
    end)
  end)

  describe("Flush and the ticker", function()
    it("rechecks the gate before sending, so the unlock is announced", function()
      p4.restriction.chatActive = true
      comm:Send(hello(), "GUILD")
      gate:Recheck()
      p4.restriction.chatActive = false
      comm:Flush()
      assert.are.same({ { true, "restriction" }, { false } }, p4.messages("FS_COMM_GATE_CHANGED"))
    end)

    it("flushes every 15 s while the queue is not empty and then stops", function()
      p4.restriction.chatActive = true
      comm:Send(hello(), "GUILD")
      p4.advance(15)
      assert.are.equal(0, #ace.sent)           -- still locked
      p4.restriction.chatActive = false
      p4.advance(15)
      assert.are.equal(1, #ace.sent)
      p4.advance(60)
      assert.are.equal(1, #ace.sent)
      assert.is_false(comm:IsTickerRunning())
    end)

    it("runs one ticker for any number of queued messages", function()
      p4.restriction.chatActive = true
      for _ = 1, 5 do comm:Send(hello(), "GUILD") end
      p4.restriction.chatActive = false
      p4.advance(15)
      assert.are.equal(5, #ace.sent)
    end)

    it("Stop cancels the ticker, clears the queue and stops the gate", function()
      p4.restriction.chatActive = true
      comm:Send(hello(), "GUILD")
      comm:Stop()
      assert.are.equal(0, comm:QueueSize())
      assert.is_false(comm:IsTickerRunning())
      p4.restriction.chatActive = false
      p4.advance(60)
      assert.are.equal(0, #ace.sent)
      assert.are.equal("dropped", comm:Send(hello(), "GUILD"))
    end)

    it("Stop leaves no gate back-off behind and sends no unlock message", function()
      comm:Send(hello(), "GUILD")
      ace:callback(1, 11)
      comm:Stop()
      local before = #p4.messages("FS_COMM_GATE_CHANGED")
      p4.advance(120)
      assert.are.equal(before, #p4.messages("FS_COMM_GATE_CHANGED"))
    end)

    it("ignores callbacks and inbound messages after Stop, and Start re-arms", function()
      comm:Send(hello(), "GUILD")
      comm:Stop()
      ace:callback(1, 11)
      assert.are.equal(0, comm:QueueSize())
      comm:OnCommReceived("FabStn", Protocol.Wire(hello()), "GUILD", "X-R")
      assert.are.equal(0, #got)
      comm:Start()
      assert.are.equal("sent", comm:Send(hello(), "GUILD"))
      comm:OnCommReceived("FabStn", Protocol.Wire(hello()), "GUILD", "X-R")
      assert.are.equal(1, #got)
    end)

    it("starts the gate on creation, so a client restricted at login announces it", function()
      comm:Stop()
      p4.restriction.chatActive = true
      new_comm()
      local last = p4.messages("FS_COMM_GATE_CHANGED")
      assert.are.same({ true, "restriction" }, last[#last])
    end)
  end)

  describe("OnCommReceived", function()
    local function wire(v) return Protocol.Wire(hello(v)) end

    it("drops oversized text and rate-limits floods", function()
      comm:OnCommReceived("FabStn", "1:" .. string.rep("A", 20000), "GUILD", "X-R")
      for _ = 1, Comm.RATE_LIMIT + 1 do comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-R") end
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "Y-R")
      assert.are.equal(Comm.RATE_LIMIT + 1, #got)   -- RATE_LIMIT from X, 1 from Y
      assert.are.equal(1, comm.stats.rateLimited)
    end)

    it("lets a whole sync burst through: one DATA per shared character plus a HELLO and headroom", function()
      assert.is_true(Comm.RATE_LIMIT >= Protocol.LIMITS.MAX_CHARS + 10)
      for _ = 1, Protocol.LIMITS.MAX_CHARS + 2 do comm:OnCommReceived("FabStn", wire("1"), "WHISPER", "X-R") end
      assert.are.equal(Protocol.LIMITS.MAX_CHARS + 2, #got)
      assert.are.equal(0, comm.stats.rateLimited)
    end)

    it("budgets each sender's wire bytes per window, before anything is decoded", function()
      local decodes = 0
      C_EncodingUtil.DecodeBase64 = function() decodes = decodes + 1 end
      local text = "1:" .. string.rep("A", Codec.MAX_WIRE - 2)          -- MAX_WIRE bytes on the wire
      local fit = math.floor(Comm.BYTE_BUDGET / #text)
      assert.is_true(fit < Comm.RATE_LIMIT)                           -- the byte budget binds before the count
      for _ = 1, fit + 5 do comm:OnCommReceived("FabStn", text, "GUILD", "X-R") end
      assert.are.equal(fit, decodes)
      assert.are.equal(5, comm.stats.rateLimited)
      comm:OnCommReceived("FabStn", text, "GUILD", "Y-R")             -- another sender has its own budget
      assert.are.equal(fit + 1, decodes)
      p4.advance(Comm.RATE_WINDOW)
      comm:OnCommReceived("FabStn", text, "GUILD", "X-R")             -- the window slid
      assert.are.equal(fit + 2, decodes)
    end)

    it("asks acceptSender before anything is unwired, rate-counted or recorded", function()
      local decodes, asked = 0, {}
      local base = C_EncodingUtil.DecodeBase64
      C_EncodingUtil.DecodeBase64 = function(...) decodes = decodes + 1; return base(...) end
      comm = new_comm({ acceptSender = function(sender, distribution)
        asked[#asked + 1] = { sender, distribution }
        return distribution ~= "WHISPER"
      end })
      comm:RegisterHandler("H", function(m, s, d) got[#got + 1] = { m, s, d } end)
      comm:OnCommReceived("FabStn", wire("1"), "WHISPER", "Stranger")
      assert.are.equal(0, decodes)
      assert.are.equal(0, #got)
      assert.are.equal(0, comm:SenderCount())
      assert.are.equal(1, comm.stats.refused)
      assert.are.same({ "Stranger-Realm", "WHISPER" }, asked[1])
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "Stranger")
      assert.are.equal(1, decodes)
      assert.are.equal(1, #got)
    end)

    it("rate-limits before it unwires or decodes anything", function()
      local decodes = 0
      local base = C_EncodingUtil.DecodeBase64
      C_EncodingUtil.DecodeBase64 = function(...) decodes = decodes + 1; return base(...) end
      local text = wire("1")
      for _ = 1, Comm.RATE_LIMIT + 80 do comm:OnCommReceived("FabStn", text, "GUILD", "X-R") end
      assert.are.equal(Comm.RATE_LIMIT, decodes)
      assert.are.equal(80, comm.stats.rateLimited)
    end)

    it("does not decode oversized text at all", function()
      local decodes = 0
      C_EncodingUtil.DecodeBase64 = function() decodes = decodes + 1 end
      comm:OnCommReceived("FabStn", string.rep("A", Codec.MAX_WIRE + 1), "GUILD", "X-R")
      assert.are.equal(0, decodes)
      assert.are.equal(1, comm.stats.invalid)
    end)

    it("accepts text of exactly MAX_WIRE bytes through to the decoder", function()
      local decodes = 0
      C_EncodingUtil.DecodeBase64 = function() decodes = decodes + 1 end
      comm:OnCommReceived("FabStn", "1:" .. string.rep("A", Codec.MAX_WIRE - 2), "GUILD", "X-R")
      assert.are.equal(1, decodes)
    end)

    it("lets the window slide: a sender can talk again after 60 s", function()
      local n = Comm.RATE_LIMIT
      for _ = 1, n do comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-R") end
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-R")
      assert.are.equal(n, #got)
      p4.advance(30)
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-R")
      assert.are.equal(n, #got)
      p4.advance(30)
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-R")
      assert.are.equal(n + 1, #got)
    end)

    it("counts a sender by its normalized name", function()
      for _ = 1, Comm.RATE_LIMIT do comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-Some Realm") end
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-SomeRealm")
      assert.are.equal(Comm.RATE_LIMIT, #got)
      assert.are.equal(1, comm.stats.rateLimited)
      assert.are.equal("X-SomeRealm", got[1][2])
    end)

    it("forgets idle senders so the table cannot grow without bound", function()
      for i = 1, 300 do comm:OnCommReceived("FabStn", wire("1"), "GUILD", "S" .. i .. "-R") end
      p4.advance(61)
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "Late-R")
      assert.is_true(comm:SenderCount() <= 2)
    end)

    it("ignores self, other prefixes, other channels and invalid payloads; routes version mismatch", function()
      local ver
      comm:RegisterHandler("version", function(s, v) ver = { s, v } end)
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "Me-Realm")
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "Me")
      comm:OnCommReceived("Other", wire("1"), "GUILD", "X-R")
      comm:OnCommReceived("FabStn", wire("1"), "PARTY", "X-R")
      comm:OnCommReceived("FabStn", "1:" .. Codec.Encode({ t = "H" }), "GUILD", "X-R")
      comm:OnCommReceived("FabStn", "2:zzz", "GUILD", "X")
      assert.are.equal(0, #got)
      assert.are.same({ "X-Realm", 2 }, ver)
      assert.are.equal(1, comm.stats.invalid)
    end)

    it("counts undecodable and header-less text as invalid", function()
      comm:OnCommReceived("FabStn", "garbage", "GUILD", "X-R")
      comm:OnCommReceived("FabStn", "1:not-base64", "GUILD", "X-R")
      comm:OnCommReceived("FabStn", 12, "GUILD", "X-R")
      assert.are.equal(3, comm.stats.invalid)
      assert.are.equal(0, #got)
    end)

    it("passes the validated message, the normalized sender and the distribution to the handler", function()
      local q
      comm:RegisterHandler("Q", function(m, s, d) q = { m, s, d } end)
      comm:OnCommReceived("FabStn", Protocol.Wire(Protocol.Request({ "A-R" })), "WHISPER", "Pal")
      assert.are.same({ "A-R" }, q[1].c)
      assert.are.equal("Pal-Realm", q[2])
      assert.are.equal("WHISPER", q[3])
    end)

    it("ignores a valid message of a kind nobody handles", function()
      comm:OnCommReceived("FabStn", Protocol.Wire(Protocol.Request({ "A-R" })), "GUILD", "X-R")
      assert.are.equal(0, comm.stats.invalid)
    end)

    it("isolates a failing handler under a log-only source and counts it as invalid", function()
      comm:RegisterHandler("Q", function() error("handler bug") end)
      comm:OnCommReceived("FabStn", Protocol.Wire(Protocol.Request({ "A-R" })), "GUILD", "X-R")
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", "X-R")
      assert.are.equal(1, #got)
      assert.are.equal(1, comm.stats.invalid)
      local errors = ns.FS.db.global.diagnostics.errors
      assert.are.equal(1, #errors)
      assert.are.equal("Guild:Comm", errors[1].source)
      assert.is_nil(next(ns.FS.failedModules))
    end)

    it("ignores secret values", function()
      comm:OnCommReceived("FabStn", p4.secret("1:abc"), "GUILD", "X-R")
      comm:OnCommReceived("FabStn", wire("1"), "GUILD", p4.secret("X-R"))
      assert.are.equal(0, #got)
      assert.are.equal(0, #(ns.FS.db.global.diagnostics and ns.FS.db.global.diagnostics.errors or {}))
    end)
  end)

  describe("RegisterHandler", function()
    it("rejects unknown kinds and non-functions", function()
      assert.has_error(function() comm:RegisterHandler("X", function() end) end)
      assert.has_error(function() comm:RegisterHandler("H", "nope") end)
    end)
  end)
end)
