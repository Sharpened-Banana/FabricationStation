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
local lastLocked, lastReason = false, nil
local chatState = 0              -- last Enum.AddOnRestrictionState seen for the Chat type (0 = Inactive)
local sendFailedAt               -- Now() of the last AddOnMessageLockdown, nil when none
local backoffTimer

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
  chatState = state
  self:Recheck()
end

-- Only AddOnMessageLockdown (the client refusing addon chat) locks; throttling and the rest are Comm's business.
-- A timer announces the end of the back-off, since nothing else would call Recheck then.
function Gate:ReportSendResult(result)
  if result ~= enum_value("SendAddonMessageResult", "AddOnMessageLockdown", 11) then return end
  sendFailedAt = ns.FS:Now()
  if backoffTimer then backoffTimer:Cancel() end
  local timer
  timer = C_Timer.NewTimer(Gate.SEND_FAILED_BACKOFF, ns.FS:Wrap("Gate:Backoff", function()
    if backoffTimer == timer then backoffTimer = nil end
    Gate:Recheck()
  end))
  backoffTimer = timer
  self:Recheck()
end

-- Idempotent.
function Gate:Init()
  if frame then return end
  frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
  frame:SetScript("OnEvent", ns.FS:Wrap("Gate:Event", function(_, _, restrictionType, state)
    Gate:OnRestrictionStateChanged(restrictionType, state)
  end))
end
