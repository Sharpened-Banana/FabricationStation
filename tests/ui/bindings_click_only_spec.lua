-- Structural rule (design rule 3, no automation; phase 7 Task 19): the key bindings reach the craft, the claim and the
-- chat box through programmatic clicks, so who can trigger them is pinned here, over every shipped Lua file:
--   * FabricationStation_Binding is referenced only by its definition in UI/Bindings.lua (the calls are the bodies of
--     Bindings.xml, which are not Lua files);
--   * `run`, the one function behind it, is referenced only by its definition and by the SafeCall inside
--     FabricationStation_Binding; the module is not exported (no `Run`) and no other file looks "Bindings" up by name;
--   * UI/Bindings.lua has exactly one `function run(`;
--   * ClickClaim is defined only in UI/OrdersPanel.lua and referenced elsewhere only inside `run`;
--   * a `:Click(` call exists only directly inside `run` (the proxy) and directly inside ClickClaim (the claim button),
--     one each, never in a closure nested in either (a timer, OnUpdate, event handler) and never passed on as a value.
-- The craft, claim and Reply rules (tests/queue/craft_spec.lua, tests/orders/claim_click_only_spec.lua,
-- tests/social/chat_inbox_click_only_spec.lua) guard the protected calls themselves. The scan is click_only's.
local click_only = require("tests.helpers.click_only")

local BIND, ORDERS = "UI/Bindings.lua", "UI/OrdersPanel.lua"
local RUN, CLAIM, ENTRY = "function run(", "function M.ClickClaim(", "function FabricationStation_Binding("

local function in_fn(r, header) return r.fn ~= nil and click_only.header_matches(r.fn, header) end

-- The references to `name` that are the name token itself or a string that is exactly the name (box["Click"]); a
-- string that only contains it ("OnClick", "ChatToast:Click") is not one.
local function name_refs(text, name)
  local refs, depth = click_only.references_in(text, name)
  local out = {}
  for _, r in ipairs(refs) do
    local quote = text:sub(r.pos, r.pos)
    local token = text:sub(r.pos, r.pos + #name - 1) == name
    local exact = (quote == '"' or quote == "'") and text:sub(r.pos + 1, r.pos + #name) == name
      and text:sub(r.pos + #name + 1, r.pos + #name + 1) == quote
    if token or exact then out[#out + 1] = r end
  end
  return out, depth
end

-- Each judge adds messages to `bad` for one file's source (and counts to `calls`).
local function judge_click(file, text, calls, bad)
  local refs, depth = name_refs(text, "Click")
  if depth ~= 0 then bad[#bad + 1] = file .. ": unbalanced blocks (scanner out of step)" end
  for _, r in ipairs(refs) do
    local fine = r.call and ((file == BIND and in_fn(r, RUN)) or (file == ORDERS and in_fn(r, CLAIM)))
    if fine then calls[file] = (calls[file] or 0) + 1 else
      bad[#bad + 1] = file .. ":" .. r.line .. " references Click other than as a :Click( call directly in run"
        .. " (UI/Bindings.lua) or in ClickClaim (UI/OrdersPanel.lua)"
    end
  end
end

local function judge_claim(file, text, bad)
  for _, r in ipairs((click_only.references_in(text, "ClickClaim"))) do
    local fine = (file == ORDERS and r.definition) or (file == BIND and not r.definition and in_fn(r, RUN))
    if not fine then
      bad[#bad + 1] = file .. ":" .. r.line .. " references ClickClaim outside its definition in " .. ORDERS
        .. " and run in " .. BIND
    end
  end
end

local function judge_entry(file, text, bad)
  for _, r in ipairs((click_only.references_in(text, "FabricationStation_Binding"))) do
    if not (file == BIND and r.definition) then
      bad[#bad + 1] = file .. ":" .. r.line .. " references FabricationStation_Binding other than its definition in "
        .. BIND
    end
  end
end

-- `run` (UI/Bindings.lua only): its definition and the SafeCall argument inside the entry point; no `Run`. Elsewhere:
-- no string that is exactly "Bindings" (GetModule("Bindings") is the only way to reach the module).
local function judge_run(file, text, bad)
  if file ~= BIND then
    for _, r in ipairs((click_only.references_in(text, "Bindings"))) do
      if text:sub(r.pos + 1, r.pos + 8) == "Bindings" and text:sub(r.pos + 9, r.pos + 9) == text:sub(r.pos, r.pos) then
        bad[#bad + 1] = file .. ":" .. r.line .. " looks up the Bindings module"
      end
    end
    return
  end
  for _, r in ipairs(name_refs(text, "run")) do
    if not (r.definition or in_fn(r, ENTRY)) then
      bad[#bad + 1] = file .. ":" .. r.line .. " references run outside its definition and the entry point's SafeCall"
    end
  end
  for _, r in ipairs(name_refs(text, "Run")) do
    bad[#bad + 1] = file .. ":" .. r.line .. " names Run (run is not exported)"
  end
  local _, _, funcs = click_only.references_in(text, "\0")
  local defined = 0
  for _, fn in ipairs(funcs) do
    if click_only.header_matches(fn, RUN) then defined = defined + 1 end
  end
  if defined ~= 1 then bad[#bad + 1] = file .. ": expected exactly one " .. RUN .. ", found " .. defined end
end

local function judge_all(file, text, calls, bad)
  judge_click(file, text, calls, bad)
  judge_claim(file, text, bad)
  judge_entry(file, text, bad)
  judge_run(file, text, bad)
end

-- A probe: `source` placed in `file` is flagged (exactly `count` messages when given).
local function flagged(file, source, count)
  local calls, bad = {}, {}
  judge_all(file, source, calls, bad)
  if count then return #bad == count end
  return #bad >= 1
end

-- What UI/Bindings.lua looks like, in miniature, for the probes (accepted as it stands).
local MINI = [==[
local proxy = CreateFrame("Button", "FabricationStationQueueCraftProxy", UIParent)
local function run(id)
  if id == "craftNext" then proxy:Click()
  elseif id == "claimBest" then
    local orders = ns.UI.OrdersPanel
    if not (orders and orders.ClickClaim and orders.ClickClaim()) then say("x") end
  end
end
function FabricationStation_Binding(id)
  return ns.FS:SafeCall("Bindings:Run", run, id)
end
]==]

describe("click-only key bindings", function()
  it("pins the real files", function()
    local calls, bad, ordersDefines = {}, {}, 0
    for _, file in ipairs(click_only.lua_files()) do
      local text = click_only.read(file)
      judge_all(file, text, calls, bad)
      if file == ORDERS and click_only.body_of(file, CLAIM) then ordersDefines = 1 end
    end
    assert.same({}, bad)
    assert.same({ [BIND] = 1, [ORDERS] = 1 }, calls)
    assert.equal(1, ordersDefines)
    assert.truthy(click_only.body_of(BIND, RUN))
    assert.truthy(click_only.body_of(BIND, ENTRY))
  end)

  it("calls FabricationStation_Binding only from the bodies of Bindings.xml", function()
    local f = assert(io.open("Bindings.xml", "r"))
    local xml = f:read("*a")
    f:close()
    local _, bodies = xml:gsub('>FabricationStation_Binding%("%a+"%)</Binding>', "")
    local _, mentions = xml:gsub("FabricationStation_Binding", "")
    assert.equal(4, bodies)
    assert.equal(4, mentions)
    -- (the Lua side: no reference but the definition, in judge_entry above)
    local bad = {}
    for _, file in ipairs(click_only.lua_files()) do judge_entry(file, click_only.read(file), bad) end
    assert.same({}, bad)
  end)

  it("passes the miniature as it stands and the probes' base", function()
    assert.is_false(flagged(BIND, MINI))
  end)

  describe("probes: the rules are not vacuous", function()
    it("flags a Click on a timer, ticker, OnUpdate or event", function()
      assert.is_true(flagged(BIND, MINI .. "C_Timer.After(1, function() proxy:Click() end)\n"))
      assert.is_true(flagged(BIND, MINI .. "C_Timer.NewTicker(60, function() proxy:Click() end)\n"))
      assert.is_true(flagged(BIND, MINI .. 'frame:SetScript("OnUpdate", function() proxy:Click() end)\n'))
      assert.is_true(flagged(BIND, MINI .. 'self:RegisterEvent("BAG_UPDATE", function() proxy:Click() end)\n'))
      assert.is_true(flagged(BIND, (MINI:gsub("proxy:Click%(%)", "C_Timer.After(1, function() proxy:Click() end)"))))
    end)
    it("flags a Click at the top level, in another function, on a value or by key", function()
      assert.is_true(flagged(BIND, MINI .. "proxy:Click()\n"))
      assert.is_true(flagged(BIND, MINI .. "local function other() proxy:Click() end\n"))
      assert.is_true(flagged(BIND, MINI .. "local c = proxy.Click\n"))
      assert.is_true(flagged(BIND, MINI .. 'proxy["Click"](proxy)\n'))
      assert.is_true(flagged(BIND, MINI .. "pcall(proxy.Click, proxy)\n"))
    end)
    it("flags a Click in another file, including on the proxy or the claim button by name", function()
      assert.is_true(flagged("UI/Tabs/Queue.lua", "button:Click()\n"))
      assert.is_true(flagged("UI/Tabs/Queue.lua", 'C_Timer.After(1, function() _G["FabricationStationQueueCraftProxy"]:Click() end)'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", "local function run(id) proxy:Click() end"))
      assert.is_true(flagged(ORDERS, "function M.ClickClaim()\n  C_Timer.After(1, function() side.claim:Click() end)\nend"))
      assert.is_true(flagged(ORDERS, "local function later() side.claim:Click() end"))
      assert.is_true(flagged(BIND, "function M.ClickClaim()\n  side.claim:Click()\nend"))   -- wrong file for it
    end)
    it("accepts the one Click directly in ClickClaim and ignores strings that only contain the name", function()
      assert.is_false(flagged(ORDERS, "function M.ClickClaim()\n  side.claim:Click()\nend"))
      assert.is_false(flagged("UI/ChatToast.lua", 'button:SetScript("OnClick", function() end); local s = "ChatToast:Click"'))
      assert.is_false(flagged("UI/Tabs/Guild.lua", 'local s = L["Click to whisper"]'))
    end)

    it("flags ClickClaim called from a timer, another file or defined elsewhere", function()
      assert.is_true(flagged(BIND, MINI .. "C_Timer.NewTicker(60, function() local o = ns.UI.OrdersPanel; o.ClickClaim() end)\n"))
      assert.is_true(flagged(BIND, MINI .. "local function other() return ns.UI.OrdersPanel.ClickClaim() end\n"))
      assert.is_true(flagged("UI/Tabs/Queue.lua", "ns.UI.OrdersPanel.ClickClaim()"))
      assert.is_true(flagged("UI/Tabs/Queue.lua", 'C_Timer.After(1, function() ns.UI.OrdersPanel["ClickClaim"]() end)'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", "function M.ClickClaim() return true end"))
      assert.is_true(flagged(BIND, MINI .. "function M.ClickClaim() return true end\n"))
      assert.is_true(flagged(ORDERS, "local function later() M.ClickClaim() end"))
    end)

    it("flags FabricationStation_Binding called by anything but a binding body", function()
      assert.is_true(flagged(BIND, MINI .. 'C_Timer.NewTicker(60, function() FabricationStation_Binding("craftNext") end)\n'))
      assert.is_true(flagged(BIND, MINI .. 'FabricationStation_Binding("craftNext")\n'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", 'C_Timer.After(1, function() FabricationStation_Binding("craftNext") end)'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", 'C_Timer.After(1, function() _G["FabricationStation_Binding"]("toggle") end)'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", "function FabricationStation_Binding(id) end"))
      assert.is_true(flagged("UI/Tabs/Queue.lua", "local entry = FabricationStation_Binding"))
    end)

    it("flags run reached from anywhere but the entry point", function()
      assert.is_true(flagged(BIND, MINI .. 'C_Timer.NewTicker(60, function() run("craftNext") end)\n'))
      assert.is_true(flagged(BIND, MINI .. 'run("craftNext")\n'))
      assert.is_true(flagged(BIND, MINI .. "Bindings.Run = run\n"))
      assert.is_true(flagged(BIND, MINI .. 'pcall(run, "toggle")\n'))
      assert.is_true(flagged(BIND, MINI .. "function Bindings:Run(id) end\n"))
      assert.is_true(flagged(BIND, MINI .. 'local function again() return ns.FS:SafeCall("x", run, "toggle") end\n'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", 'ns.FS:GetModule("Bindings"):Run("craftNext")'))
      assert.is_true(flagged("UI/Tabs/Queue.lua", "local b = ns.FS:GetModule('Bindings')"))
    end)
    it("flags a second function run( and accepts other strings that contain Bindings", function()
      assert.is_true(flagged(BIND, MINI .. "local function run(id) end\n"))
      assert.is_true(flagged(BIND, MINI .. "function run(id) end\n"))
      assert.is_false(flagged("UI/Tabs/Settings.lua", 'local s = L["Key Bindings"]; local t = "Bindings:Run"'))
    end)
  end)
end)
