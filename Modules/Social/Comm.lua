local ADDON_NAME, ns = ...

-- Comm: the gated AceComm transport behind Guild sync. Plain object (ns.Social.Comm.New), not an Ace module: Guild
-- builds one in OnEnable, hands it the AceComm-embedded module as `ace`, forwards AceComm's received-callback to
-- comm:OnCommReceived and calls comm:Stop() from OnDisable.
--
-- Outbound: Send() puts the message on the wire at once while the gate is open and the queue is empty; otherwise it
-- queues it (50 entries, oldest dropped; a repeated `key` replaces the queued entry in place). Flush() rechecks the
-- gate and sends the queue FIFO while it stays open. A 15 s ticker runs only while the queue is non-empty. AceComm
-- reports a result per 255-byte chunk; the first chunk answered with AddOnMessageLockdown (11) tells the gate, and
-- the WHOLE message goes back to the front of the queue (receivers never see a partial message; the later chunks
-- of that send are ignored). A message that hits lockdown 3 times, or a permanent failure, is dropped. Throttling
-- is ChatThrottleLib's business, not ours.
--
-- Inbound: only this addon's prefix, GUILD and WHISPER, never ourselves. The per-sender rate limit (20 messages per
-- 60 s, sliding) runs BEFORE anything is unwired or decoded, so a spammer cannot make us decompress repeatedly;
-- text over Codec.MAX_WIRE is dropped before the rate limit costs it anything. Dispatch runs under a log-only error
-- source, so a hostile or buggy message can never turn a module off; such errors count in stats.invalid.
ns.Social = ns.Social or {}
local Comm = {}
ns.Social.Comm = Comm

Comm.MAX_QUEUE = 50
Comm.MAX_ATTEMPTS = 3          -- sends of one message that may hit lockdown before it is dropped
Comm.RATE_LIMIT = 20           -- inbound messages per sender ...
Comm.RATE_WINDOW = 60          -- ... per this many seconds
Comm.FLUSH_INTERVAL = 15       -- seconds between flush attempts while the queue is non-empty
Comm.ERROR_SOURCE = "Guild:Comm"

local SWEEP_AT = 256           -- sender records before idle ones are purged
local SWEEP_EVERY = 10         -- ... at most this often (seconds)
local KINDS = { H = true, Q = true, D = true, version = true }
local DISTRIBUTIONS = { GUILD = true, WHISPER = true }

local function send_result(name, fallback)
  local e = Enum and Enum.SendAddonMessageResult
  return e and e[name] or fallback
end

-- NotInGuild, TargetOffline, InvalidChannel, InvalidPrefix, InvalidMessage, InvalidChatType: resending cannot help.
local PERMANENT = { { "NotInGuild", 10 }, { "TargetOffline", 12 }, { "InvalidChannel", 7 }, { "InvalidPrefix", 1 },
  { "InvalidMessage", 2 }, { "InvalidChatType", 4 } }

local function is_permanent(result)
  for _, pair in ipairs(PERMANENT) do
    if result == send_result(pair[1], pair[2]) then return true end
  end
  return false
end

local Methods = {}
local Meta = { __index = Methods }

---------------------------------------------------------------------------
-- Queue
---------------------------------------------------------------------------

local function stop_ticker(self)
  if self.ticker then self.ticker:Cancel(); self.ticker = nil end
end

local function ensure_ticker(self)
  if self.ticker or self.stopped or #self.queue == 0 then return end
  self.ticker = C_Timer.NewTicker(Comm.FLUSH_INTERVAL, ns.FS:Wrap("Comm:Ticker", function() self:Flush() end))
end

local function drop(self, entry)
  entry.state = "dropped"
  self.stats.dropped = self.stats.dropped + 1
end

-- A new message: replaces a queued one with the same key (keeping its slot), otherwise goes last; the oldest entry
-- falls off a full queue.
local function enqueue(self, entry)
  local queue = self.queue
  entry.state = "queued"
  self.stats.queued = self.stats.queued + 1
  if entry.key ~= nil then
    for i, queued in ipairs(queue) do
      if queued.key == entry.key then
        queue[i] = entry
        queued.state = "replaced"
        return
      end
    end
  end
  queue[#queue + 1] = entry
  while #queue > Comm.MAX_QUEUE do
    drop(self, table.remove(queue, 1))
  end
  ensure_ticker(self)
end

-- A message whose send hit lockdown goes back to the FRONT (it is the oldest), unless it is out of attempts, a newer
-- message with its key is already queued, or the queue is full.
local function requeue(self, entry)
  local queue = self.queue
  if entry.attempt >= Comm.MAX_ATTEMPTS or #queue >= Comm.MAX_QUEUE then return drop(self, entry) end
  if entry.key ~= nil then
    for _, queued in ipairs(queue) do
      if queued.key == entry.key then return drop(self, entry) end
    end
  end
  entry.attempt = entry.attempt + 1
  entry.state = "queued"
  self.stats.queued = self.stats.queued + 1
  table.insert(queue, 1, entry)
  ensure_ticker(self)
end

---------------------------------------------------------------------------
-- Transmit
---------------------------------------------------------------------------

-- AceComm calls this once per chunk: callbackFn(callbackArg, bytesSent, bytesTotal, result). The arg is a ticket made
-- per transmit, so a straggling chunk of an earlier attempt cannot touch the current one.
local function handle_result(ticket, result)
  local self, entry = ticket.comm, ticket.entry
  if ticket.failed or self.stopped or entry.ticket ~= ticket or type(result) ~= "number" then return end
  if result == send_result("AddOnMessageLockdown", 11) then
    ticket.failed = true
    requeue(self, entry)
    self.gate:ReportSendResult(result)
  elseif is_permanent(result) then
    ticket.failed = true
    drop(self, entry)
  end
end

local function on_chunk(ticket, _, _, result)
  ns.FS:SafeCall("Comm:Result", handle_result, ticket, result)
end

local function transmit(self, entry)
  local ticket = { comm = self, entry = entry }
  entry.ticket = ticket
  entry.state = "sent"
  self.stats.sent = self.stats.sent + 1
  self.ace:SendCommMessage(ns.Social.Protocol.PREFIX, entry.text, entry.dist, entry.target, entry.prio, on_chunk, ticket)
end

local function flush_queue(self)
  self.gate:Recheck()
  local queue = self.queue
  while #queue > 0 and not self.stopped do
    if self.gate:IsLocked() then break end
    local entry = table.remove(queue, 1)
    local ok = ns.FS:SafeCall("Comm:Flush", transmit, self, entry)
    if not ok then drop(self, entry) end
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- deps = { ace, gate, selfName = fun(): string, now = fun(): number }. `ace` needs SendCommMessage(self, prefix, text,
-- distribution, target, prio, callbackFn, callbackArg). Creating a Comm starts it (and the gate).
function Comm.New(deps)
  assert(type(deps) == "table" and deps.ace and deps.gate, "Comm.New: ace and gate are required")
  local self = setmetatable({
    ace = deps.ace,
    gate = deps.gate,
    selfName = deps.selfName or function() return nil end,
    now = deps.now or function() return ns.FS:Now() end,
    errorSource = deps.errorSource or Comm.ERROR_SOURCE,
    queue = {},
    handlers = {},
    senders = {},          -- [normalized sender] = { receive times, oldest first }
    senderCount = 0,
    lastSweep = 0,
    stats = { sent = 0, queued = 0, dropped = 0, invalid = 0, rateLimited = 0 },
    stopped = true,
  }, Meta)
  self:Start()
  return self
end

-- Arms the gate (idempotent). New() calls it; call it again only after Stop().
function Methods:Start()
  if not self.stopped then return end
  self.stopped = false
  self.gate:Init()
end

-- Cancels the ticker, forgets the queue and the rate-limit records and stops the gate. Later sends are dropped and
-- late results and inbound messages are ignored until Start().
function Methods:Stop()
  self.stopped = true
  stop_ticker(self)
  self.queue = {}
  self.senders, self.senderCount = {}, 0
  self.gate:Stop()
end

function Methods:QueueSize() return #self.queue end
function Methods:IsTickerRunning() return self.ticker ~= nil end
function Methods:SenderCount() return self.senderCount end

function Methods:RegisterHandler(kind, fn)
  if not KINDS[kind] then error("Comm:RegisterHandler: unknown kind " .. tostring(kind), 2) end
  if type(fn) ~= "function" then error("Comm:RegisterHandler: handler must be a function", 2) end
  self.handlers[kind] = fn
end

-- msg: a Protocol message. opts = { prio = "NORMAL"|"BULK", key = any }. Returns "sent" (handed to AceComm and not
-- refused so far), "queued" or "dropped".
function Methods:Send(msg, distribution, target, opts)
  local entry = { dist = distribution, target = target, attempt = 1, state = "new" }
  if self.stopped or type(msg) ~= "table" or not DISTRIBUTIONS[distribution]
    or (distribution == "WHISPER" and (type(target) ~= "string" or target == "")) then
    drop(self, entry)
    return entry.state
  end
  local text = ns.Social.Protocol.Wire(msg)
  if not text or #text > ns.Social.Codec.MAX_WIRE then    -- no peer would accept more than MAX_WIRE
    drop(self, entry)
    return entry.state
  end
  entry.text = text
  entry.prio = type(opts) == "table" and opts.prio == "BULK" and "BULK" or "NORMAL"
  entry.key = type(opts) == "table" and opts.key or nil
  local locked = self.gate:IsLocked()
  if not locked and #self.queue == 0 then
    local ok = ns.FS:SafeCall("Comm:Send", transmit, self, entry)
    if not ok then drop(self, entry) end
    return entry.state
  end
  enqueue(self, entry)
  if not locked then self:Flush() end    -- keeps arrival order behind older queued messages
  return entry.state
end

-- Rechecks the gate, then sends the queue FIFO while it stays open. Called by Guild on FS_COMM_GATE_CHANGED(false)
-- and by the ticker.
function Methods:Flush()
  if self.stopped or self.flushing then return end
  self.flushing = true
  ns.FS:SafeCall("Comm:Flush", flush_queue, self)
  self.flushing = false
  if #self.queue == 0 then stop_ticker(self) else ensure_ticker(self) end
end

---------------------------------------------------------------------------
-- Inbound
---------------------------------------------------------------------------

local function sweep(self, now)
  self.lastSweep = now
  local cutoff = now - Comm.RATE_WINDOW
  for name, times in pairs(self.senders) do
    if times[#times] <= cutoff then
      self.senders[name] = nil
      self.senderCount = self.senderCount - 1
    end
  end
end

-- Sliding window: at most RATE_LIMIT receive times within the last RATE_WINDOW seconds per sender.
local function allow(self, sender)
  local now = self.now()
  local times = self.senders[sender]
  if not times then
    if self.senderCount >= SWEEP_AT and now - self.lastSweep >= SWEEP_EVERY then sweep(self, now) end
    times = {}
    self.senders[sender] = times
    self.senderCount = self.senderCount + 1
  end
  if #times >= Comm.RATE_LIMIT then
    if now - times[1] < Comm.RATE_WINDOW then return false end
    table.remove(times, 1)
  end
  times[#times + 1] = now
  return true
end

local function receive(self, prefix, text, distribution, sender)
  local Protocol = ns.Social.Protocol
  if self.stopped then return end
  if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(sender)) then return end
  if prefix ~= Protocol.PREFIX or not DISTRIBUTIONS[distribution] then return end
  if type(sender) ~= "string" or sender == "" then return end
  if type(text) ~= "string" then
    self.stats.invalid = self.stats.invalid + 1
    return
  end
  local senderName = ns.Social.Util.NormalizeName(sender)
  if senderName == ns.Social.Util.NormalizeName(self.selfName()) then return end
  if #text > ns.Social.Codec.MAX_WIRE then
    self.stats.invalid = self.stats.invalid + 1
    return
  end
  if not allow(self, senderName) then
    self.stats.rateLimited = self.stats.rateLimited + 1
    return
  end
  local msg, protoVersion, err = Protocol.Unwire(text)
  if not msg then
    if err == "version" then
      if self.handlers.version then self.handlers.version(senderName, protoVersion) end
    else
      self.stats.invalid = self.stats.invalid + 1
    end
    return
  end
  if not Protocol.Validate(msg) then
    self.stats.invalid = self.stats.invalid + 1
    return
  end
  local handler = self.handlers[msg.t]
  if handler then handler(msg, senderName, distribution) end
end

-- AceComm's received-callback (prefix, text, distribution, sender). Never raises.
function Methods:OnCommReceived(prefix, text, distribution, sender)
  local ok = ns.FS:SafeCall(self.errorSource, receive, self, prefix, text, distribution, sender)
  if not ok then self.stats.invalid = self.stats.invalid + 1 end
end
