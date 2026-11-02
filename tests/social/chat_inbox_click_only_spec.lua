-- Structural rule (design rule 3, no automation): ChatInbox:Reply, the one function that fills the chat box with a
-- whisper to a requester, is called only as a `:Reply(` call directly inside a SetScript("OnClick", function ... end)
-- handler (the Requests tab's Reply button), or as a `:Reply(` call directly inside `run`, the key binding's one entry
-- point in UI/Bindings.lua (Task 19; a key press is the player's act), never from an event, timer, message or a
-- closure nested in either, and never passed on as a value. ChatFrameUtil.SendTellWithMessage stays out of
-- ChatInbox's capture path; nothing in ChatInbox sends chat (SendChatMessage). The scan and its rules are
-- tests/helpers/click_only.lua's. That scan matches a string containing the name as well, so the locale lookups of the
-- button's label and the binding's name (L["Reply"], L["Reply to the latest chat request"]) are the strings it is told
-- to leave alone here.
local click_only = require("tests.helpers.click_only")

local INBOX = "Modules/Social/ChatInbox.lua"
-- file -> where a :Reply( call may sit, directly (never in a closure nested in it): true = a SetScript("OnClick", ...)
-- handler; a string = the header of the one function that may hold it.
local ALLOWED = { ["UI/Tabs/Requests.lua"] = true, ["UI/Bindings.lua"] = "function run(" }

-- A reference to Reply, judged as click_only.referenced_only_from_onclick judges it, except that a locale lookup
-- L["Reply"] or L["Reply to the latest chat request"] (a string starting with Reply, the tokens before it `L` and `[`,
-- `]` after it) is not a reference: the string is looked up, never called. A bracketed key anywhere else
-- (box["Reply"](box, 1), local f = box["Reply"]) stays a reference and fails the rule. A key built at run time
-- (box[name]) cannot be detected by any token scan.
local function is_locale_label(text, r)
  if r.call or r.definition then return false end
  local quote = text:sub(r.pos, r.pos)
  if quote ~= '"' and quote ~= "'" then return false end
  local before = text:sub(1, r.pos - 1)
  if before:match("L%[%s*$") == nil or before:match("[%w_]L%[%s*$") ~= nil then return false end
  local close = r.pos + 1
  while close <= #text and text:sub(close, close) ~= quote do
    close = close + (text:sub(close, close) == "\\" and 2 or 1)
  end
  local after = text:sub(close + 1)
  return after:match("^%s*%]") ~= nil and after:match("^%s*%]%s*%(") == nil
end

-- text -> calls ("line"), bad (messages), for one file's source.
local function judge(file, text, calls, bad)
  local refs, depth = click_only.references_in(text, "Reply")
  if depth ~= 0 then bad[#bad + 1] = file .. ": unbalanced blocks (scanner out of step)" end
  for _, r in ipairs(refs) do
    if not is_locale_label(text, r) then
      if r.call then calls[#calls + 1] = file .. ":" .. r.line end
      local fine
      if r.definition then
        fine = file == INBOX
      else
        local rule = ALLOWED[file]
        fine = rule and r.call and r.fn
        if fine then
          if rule == true then fine = r.fn.onClick else fine = click_only.header_matches(r.fn, rule) end
        end
      end
      if not fine then
        bad[#bad + 1] = file .. ":" .. r.line .. " references Reply other than as a :Reply( call directly in an"
          .. " OnClick handler (or in the binding's run)"
      end
    end
  end
end

local function check()
  local calls, bad = {}, {}
  for _, file in ipairs(click_only.lua_files()) do judge(file, click_only.read(file), calls, bad) end
  if #calls == 0 then bad[#bad + 1] = "no :Reply( call found" end
  return #bad == 0, table.concat(bad, "\n"), calls
end

describe("click-only chat inbox reply", function()
  it("references ChatInbox:Reply only from an OnClick handler and the binding's run", function()
    local ok, message, calls = check()
    assert.is_true(ok, message)
    assert.equal(2, #calls, "expected exactly two :Reply( calls, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/Bindings%.lua:"))
    assert.truthy(calls[2]:find("^UI/Tabs/Requests%.lua:"))
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

  it("flags a bracketed \"Reply\" key, but not the locale lookup", function()
    local function bad_count(source)
      local calls, bad = {}, {}
      judge("UI/Tabs/Requests.lua", source, calls, bad)
      return #bad
    end
    assert.equal(1, bad_count('C_Timer.After(1, function() box["Reply"](box, 1) end)'))
    assert.equal(1, bad_count('local f = box["Reply"]'))
    assert.equal(1, bad_count('local f = self.box["Reply"]; f(self.box, 1)'))
    assert.equal(1, bad_count('local f = boxL["Reply"]'))
    assert.equal(1, bad_count('C_Timer.After(1, function() box:Reply(1) end)'))
    assert.equal(0, bad_count('button:SetText(L["Reply"])'))
    assert.equal(0, bad_count('button:SetText(L[ "Reply" ])'))
    assert.equal(0, bad_count('button:SetScript("OnClick", function(self) box:Reply(self.id) end)'))
  end)

  it("accepts the locale lookup of a longer key starting with Reply, only as a lookup", function()
    local function bad_count(source)
      local calls, bad = {}, {}
      judge("UI/Bindings.lua", source, calls, bad)
      return #bad
    end
    assert.equal(0, bad_count('BINDING_NAME_X = L["Reply to the latest chat request"]'))
    assert.equal(0, bad_count("local t = L['Reply to the latest chat request']"))
    assert.equal(0, bad_count('local t = L["Reply to \\"x\\" now"]:format(1)'))
    assert.equal(1, bad_count('local t = L["Reply to the latest chat request"](1)'))
    assert.equal(1, bad_count('local t = box["Reply to the latest chat request"]'))
    assert.equal(1, bad_count('local t = boxL["Reply to"]'))
    assert.equal(1, bad_count('local t = "Reply to the latest chat request"'))
    assert.equal(1, bad_count('local t = f("Reply to the latest chat request")'))
  end)

  it("lets UI/Bindings.lua call Reply only directly in run", function()
    local function bad_count(file, source)
      local calls, bad = {}, {}
      judge(file, source, calls, bad)
      return #bad, #calls
    end
    assert.same({ 0, 1 }, { bad_count("UI/Bindings.lua", "local function run(id)\n  if x then inbox:Reply(1) end\nend") })
    assert.same({ 1, 1 }, { bad_count("UI/Bindings.lua",
      "local function run(id)\n  C_Timer.After(1, function() inbox:Reply(1) end)\nend") })
    assert.same({ 1, 1 }, { bad_count("UI/Bindings.lua", "local function later() inbox:Reply(1) end") })
    assert.same({ 1, 1 }, { bad_count("UI/Bindings.lua",
      'button:SetScript("OnClick", function() inbox:Reply(1) end)') })
    assert.same({ 1, 0 }, { bad_count("UI/Bindings.lua", "local function run(id) pcall(inbox.Reply, inbox, 1) end") })
    assert.same({ 1, 1 }, { bad_count("UI/Bindings.lua", "local function run_later(id) inbox:Reply(1) end") })
    assert.same({ 1, 1 }, { bad_count("UI/Tabs/Requests.lua", "local function run(id) inbox:Reply(1) end") })
    assert.same({ 1, 1 }, { bad_count("UI/Other.lua", "local function run(id) inbox:Reply(1) end") })
  end)
end)
