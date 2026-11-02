local ADDON_NAME, ns = ...

-- Gate: is addon chat restricted right now? Midnight locks addon (and secret-value) chat inside instances and other
-- restricted states. Comm asks IsLocked() before every flush and listens for FS_COMM_GATE_CHANGED(locked, reason).
-- Plain singleton on ns.Social.Gate (not an Ace module): Init() creates one hidden frame for
-- ADDON_RESTRICTION_STATE_CHANGED.
ns.Social = ns.Social or {}
local Gate = {}
ns.Social.Gate = Gate

-- Seconds of silence after the client refused a send with AddOnMessageLockdown.
Gate.SEND_FAILED_BACKOFF = 60

-- C_ChatInfo.AreOutgoingAddonChatMessagesRestricted() is unverified (docs/in-game-checklist.md P4-2): it may be true
-- in cities while addon messages still arrive. Off until a client confirms it is safe to honour.
Gate.USE_REALM_FLAG = false

local frame
local armed = false             -- Init() ran and Stop() has not since
local lastLocked, lastReason = false, nil
local chatState = 0              -- last Enum.AddOnRestrictionState seen for the Chat type (0 = Inactive)
local sendFailedAt               -- Now() of the last AddOnMessageLockdown, nil when none

local BACKOFF_KEY = "Gate:Backoff"   -- ns.FS:Debounce key of the back-off timer

local function enum_value(group, key, fallback)
  local e = Enum and Enum[group]
  return e and e[key] or fallback
end

local function chat_type() return enum_value("AddOnRestrictionType", "Chat", 5) end

-- The first applicable reason, in this order: the event state, IsAddOnRestrictionActive (always false while the
-- event is being dispatched, hence the event state first), the messaging lockdown, the realm flag, a recent failed
-- send. A missing API restricts nothing.
function Gate:IsLocked()
  if chatState ~= enum_value("AddOnRestrictionState", "Inactive", 0) then return true, "restriction" end
  local restricted = C_RestrictedActions
  if restricted and restricted.IsAddOnRestrictionActive and restricted.IsAddOnRestrictionActive(chat_type()) then
    return true, "restriction"
  end
  local chat = C_ChatInfo
  if chat and chat.InChatMessagingLockdown and chat.InChatMessagingLockdown() then return true, "lockdown" end
  if Gate.USE_REALM_FLAG and chat and chat.AreOutgoingAddonChatMessagesRestricted
    and chat.AreOutgoingAddonChatMessagesRestricted() then
    return true, "realm"
  end
  if sendFailedAt and ns.FS:Now() - sendFailedAt < Gate.SEND_FAILED_BACKOFF then return true, "sendFailed" end
  return false, nil
end

-- Recomputes the gate and sends FS_COMM_GATE_CHANGED(locked, reason) when it changed (locked flipped, or the reason
-- of a locked gate changed). Also called by Comm before a flush.
function Gate:Recheck()
  local locked, reason = self:IsLocked()
  if locked == lastLocked and reason == lastReason then return end
  lastLocked, lastReason = locked, reason
  ns.FS:SendMessage(ns.Msg.COMM_GATE_CHANGED, locked, reason)
end

function Gate:OnRestrictionStateChanged(restrictionType, state)
  if restrictionType ~= chat_type() then return end
  chatState = state or enum_value("AddOnRestrictionState", "Inactive", 0)
  self:Recheck()
end

-- Only AddOnMessageLockdown (the client refusing addon chat) locks; throttling and the rest are Comm's business.
-- A timer (ns.FS:Debounce, so a second failure replaces it and Stop cancels it) announces the end of the back-off,
-- since nothing else would call Recheck then.
function Gate:ReportSendResult(result)
  if result ~= enum_value("SendAddonMessageResult", "AddOnMessageLockdown", 11) then return end
  sendFailedAt = ns.FS:Now()
  ns.FS:Debounce(BACKOFF_KEY, Gate.SEND_FAILED_BACKOFF, ns.FS:Wrap("Gate:Backoff", function() Gate:Recheck() end))
  self:Recheck()
end

-- Idempotent. Seeds the cached state with a Recheck, so a client that is already restricted at login announces it.
function Gate:Init()
  if armed then return end
  armed = true
  if not frame then
    frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", ns.FS:Wrap("Gate:Event", function(_, _, restrictionType, state)
      Gate:OnRestrictionStateChanged(restrictionType, state)
    end))
  end
  frame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
  self:Recheck()
end

-- Tears the gate down: stops listening, cancels the back-off timer and forgets the event state, the failed send and
-- the cached transition state, so a later Init starts clean. Sends nothing. Called by Comm (Task 5) from its
-- OnDisable (it is the gate's only user that outlives a single call; Guild goes through Comm).
function Gate:Stop()
  armed = false
  if frame then frame:UnregisterAllEvents() end
  ns.FS:CancelDebounce(BACKOFF_KEY)
  sendFailedAt = nil
  chatState = enum_value("AddOnRestrictionState", "Inactive", 0)
  lastLocked, lastReason = false, nil
end
