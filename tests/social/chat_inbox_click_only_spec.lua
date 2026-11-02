-- Structural rule (design rule 3, no automation): ChatInbox:Reply, the one function that fills the chat box with a
-- whisper to a requester, is called only as a `:Reply(` call directly inside a SetScript("OnClick", function ... end)
-- handler (the Requests tab's Reply button; Task 19 adds the key binding's handler to ALLOWED), never from an event,
-- timer, message or a closure nested in the handler, and never passed on as a value. ChatFrameUtil.SendTellWithMessage
-- stays out of ChatInbox's capture path; nothing in ChatInbox sends chat (SendChatMessage). The scan and its rules are
-- tests/helpers/click_only.lua's. That scan matches a string containing the name as well, so the button's own label
-- (the exact string "Reply", a locale key) is the one string it is told to leave alone here.
local click_only = require("tests.helpers.click_only")

local INBOX = "Modules/Social/ChatInbox.lua"
local ALLOWED = { "UI/Tabs/Requests.lua" }
local LABEL = '"Reply"'

-- click_only.referenced_only_from_onclick, minus the references that are exactly the quoted label.
local function check()
  local allowed = {}
  for _, p in ipairs(ALLOWED) do allowed[p] = true end
  local calls, bad = {}, {}
  for _, file in ipairs(click_only.lua_files()) do
    local text = click_only.read(file)
    local refs, depth = click_only.references_in(text, "Reply")
    if depth ~= 0 then bad[#bad + 1] = file .. ": unbalanced blocks (scanner out of step)" end
    for _, r in ipairs(refs) do
      local isLabel = text:sub(r.pos, r.pos + #LABEL - 1) == LABEL and not r.call and not r.definition
      if not isLabel then   -- (the exact string "Reply" is the locale key of the button's label)
        if r.call then calls[#calls + 1] = file .. ":" .. r.line end
        local fine
        if r.definition then
          fine = file == INBOX
        else
          fine = allowed[file] and r.fn and r.fn.onClick and r.call
        end
        if not fine then
          bad[#bad + 1] = file .. ":" .. r.line .. " references Reply other than as a :Reply( call directly in an"
            .. " OnClick handler"
        end
      end
    end
  end
  if #calls == 0 then bad[#bad + 1] = "no :Reply( call found" end
  return #bad == 0, table.concat(bad, "\n"), calls
end

describe("click-only chat inbox reply", function()
  it("references ChatInbox:Reply only from an OnClick handler", function()
    local ok, message, calls = check()
    assert.is_true(ok, message)
    assert.equal(1, #calls, "expected exactly one :Reply( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/Tabs/Requests%.lua:"))
  end)

  it("defines ChatInbox:Reply in Modules/Social/ChatInbox.lua", function()
    assert.truthy(click_only.body_of(INBOX, "function ChatInbox:Reply("))
  end)

  it("calls SendTellWithMessage and SendTell only inside ChatInbox:Reply", function()
    for _, token in ipairs({ "SendTellWithMessage", "SendTell" }) do
      local ok, message, hits = click_only.only_inside(token, INBOX, "function ChatInbox:Reply(",
        { files = { INBOX } })
      assert.is_true(ok, message)
      assert.is_true(#hits >= 1, token)
    end
  end)

  it("never sends chat", function()
    local text = click_only.read(INBOX)
    for _, token in ipairs({ "SendChatMessage", "SendAddonMessage", "BNSendWhisper" }) do
      assert.equal(0, #click_only.references_in(text, token), token)
    end
    for _, file in ipairs({ INBOX, "UI/Tabs/Requests.lua" }) do
      assert.equal(0, #click_only.references(file, "SendChatMessage"), file)
    end
  end)

  it("sees a stray reference (the rule is not vacuous)", function()
    local refs = click_only.references_in('local function later() inbox:Reply(1) end\nC_Timer.After(1, later)', "Reply")
    assert.equal(1, #refs)
    assert.is_falsy(refs[1].fn.onClick)
  end)
end)
