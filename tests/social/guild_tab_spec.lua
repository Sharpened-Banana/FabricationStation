-- Guild tab, guild settings group and /fs guild (phase 4 Task 9): the user-facing surface of the guild crafter
-- directory. Boots 1a's real MainWindow (last = "UI/MainWindow.lua") so the tab registers with it and the options land in
-- the real GetOptionsTable(); Scanner and Recipes are p4.fake_module overrides (the real modules exist, only the methods
-- the specs need are replaced), the roster, the native query, AceComm and the encoding are the phase-4 harness fakes.
local FILES = { "Modules/Social/GuildOptions.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/Guild.lua" }

local NAMES = { [100] = "Everforged Mace", [101] = "Everforged Axe", [200] = "Silk Bandage", [300] = "Midnight Flask" }
local DIM = "|cff9d9d9d"
local EM_DASH = "\226\128\148"

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function point(region, i) return { region:GetPoint(i or 1) } end
local function map(list, key)
  local out = {}
  for i, v in ipairs(list) do out[i] = v[key] end
  return out
end
local function contains(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end
local function uniq(list)
  local out, seen = {}, {}
  for _, v in ipairs(list) do
    if not seen[v] then seen[v] = true; out[#out + 1] = v end
  end
  return out
end

-- Edit boxes, check buttons and buttons that keep their text, and buttons that keep their enabled state (the shared
-- stubs make them no-ops).
local function wrap_frames()
  local real = _G.CreateFrame
  _G.CreateFrame = function(frameType, name, parent, template)
    local f = real(frameType, name, parent, template)
    if frameType == "EditBox" or frameType == "CheckButton" or frameType == "Button" then
      local text, checked, enabled = "", false, true
      function f:SetText(t) text = t end
      function f:GetText() return text end
      function f:Type(t) text = t; local s = self:GetScript("OnTextChanged"); if s then s(self, true) end end
      function f:SetChecked(v) checked = v and true or false end
      function f:GetChecked() return checked end
      function f:SetEnabled(v) enabled = v and true or false end
      function f:Enable() enabled = true end
      function f:Disable() enabled = false end
      function f:IsEnabled() return enabled end
      if template == "SearchBoxTemplate" then f.Instructions = f:CreateFontString() end
    end
    return f
  end
end

describe("Guild tab, settings and diagnostics", function()
  local ns, W, p4, Guild, Protocol, settings, chars, tooltip
  local MW

  local function fixture_chars()
    return {
      ["Me-Realm"] = { professions = {
        [2907] = { name = "Blacksmithing", skill = 50, maxSkill = 100, recipes = { [101] = true, [100] = true },
          concentration = { value = 1, max = 1000 } },
      } },
      ["Alt-Realm"] = { professions = {
        [2906] = { name = "Alchemy", skill = 10, maxSkill = 100, recipes = { [300] = true }, concentration = {} },
      } },
    }
  end

  local function dir() return Guild:GetDirectory() end
  local function now() return ns.FS:Now() end

  -- A stored peer profile in the Task 6 shape: one skill line with the given recipes (id -> { q, qc }).
  local function store(charKey, owner, opts)
    opts = opts or {}
    local lv = opts.lv or "q"
    local line = { k = opts.k or 50, m = 100, recipes = {} }
    if lv == "q" then line.q, line.qc = {}, {} end
    for id, quality in pairs(opts.recipes or { [100] = { 3, 5 } }) do
      line.recipes[id] = true
      if lv == "q" then line.q[id], line.qc[id] = quality[1], quality[2] end
    end
    dir().profiles[charKey] = { c = charKey, ts = 1, lv = lv, h = "00000001", owner = owner,
      verified = opts.verified ~= false, rt = opts.rt or now(), lines = { [opts.line or 2907] = line } }
  end
  local function native_members(recipeID, members, skillLineID)
    dir().native[recipeID] = { time = now(), skillLineID = skillLineID or 2907, members = members }
  end
  local NATIVE_B = { name = "B-Realm", classFile = "MAGE", online = false }
  local NATIVE_D = { name = "D-Realm", classFile = "ROGUE", online = true }

  -- B: Axe (q2/qc4) and Mace (q3/qc5); C: Mace, recipes only; E: Flask (Alchemy); D and B: Silk Bandage (native).
  local function seed()
    store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 }, [101] = { 2, 4 } }, k = 80 })
    store("C-Realm", "Peer2-Realm", { lv = "r", recipes = { [100] = true } })
    store("E-Realm", "Peer3-Realm", { recipes = { [300] = { 1, 2 } }, line = 2906 })
    native_members(200, { NATIVE_D, NATIVE_B })
    dir().members["Peer-Realm"] = { addonVersion = "1.0.0", proto = 1, lastSeen = now(), chars = {} }
    dir().members["Peer2-Realm"] = { addonVersion = "1.0.0", proto = 1, lastSeen = now(), chars = {} }
  end

  local function sent_msgs()
    local out = {}
    for _, s in ipairs(p4.comm.sent) do out[#out + 1] = (Protocol.Unwire(s.text)) end
    return out
  end
  local function last_sent_msg() local l = sent_msgs(); return l[#l] end
  local function clear_sent() for i = #p4.comm.sent, 1, -1 do p4.comm.sent[i] = nil end end

  local function registered_options(key) return ns.FS:GetOptionsTable().args[key] end
  local function registered_tab(id)
    for _, t in ipairs(MW:GetTabs()) do if t.id == id then return t.def end end
  end
  local function printed() return W.printed[#W.printed] end

  local function boot(opts)
    opts = opts or {}
    ns, W, p4 = boot_phase4(FILES, { last = "UI/MainWindow.lua", stubs = {
      C_Spell = { GetSpellName = function(id) return NAMES[id] end },
      GameTooltip = {
        SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() tooltip.shown = true end,
        Hide = function() tooltip.shown = false end,
      },
    } })
    wrap_frames()
    Protocol = ns.Social.Protocol
    chars = fixture_chars()
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function() return { "Alt-Realm", "Me-Realm" } end,
      GetCharacter = function(_, key) return chars[key] end,
      GetProfession = function(_, key, sl) return chars[key] and chars[key].professions[sl] end,
      GetCachedSchematic = function() return nil end,
    })
    p4.fake_module(ns, "Recipes", {
      Evaluate = function(_, _, _, o) return { expectedQuality = o.useConcentration and 5 or 3 } end,
    })
    Guild = ns.FS:GetModule("Guild")
    MW = ns.FS:GetModule("MainWindow")
    settings = Guild:Settings()
    if opts.guild ~= false then
      p4.guild.key = { "G", "Realm" }
      p4.guild.members = { { name = "Peer-Realm", online = true } }      -- a loaded (non-empty) roster
      Guild:OnEnteringWorld()
      p4.advance(21)                                                     -- the login refresh and HELLO
      clear_sent()
      seed()
    end
  end

  before_each(function()
    tooltip = { lines = {} }
    boot()
  end)

  ---------------------------------------------------------------------------
  -- Tab rows
  ---------------------------------------------------------------------------

  describe("BuildTabRows", function()
    it("lists one row per recipe and crafter, sorted by recipe name then crafter order", function()
      local rows = Guild:BuildTabRows({})
      local seen = {}
      for i, r in ipairs(rows) do seen[i] = r.recipeName .. "/" .. r.crafter.name end
      assert.are.same({ "Everforged Axe/B-Realm", "Everforged Mace/B-Realm", "Everforged Mace/C-Realm",
        "Midnight Flask/E-Realm", "Silk Bandage/D-Realm", "Silk Bandage/B-Realm" }, seen)
      assert.are.same({ 101, 100, 100, 300, 200, 200 }, map(rows, "recipeID"))
      assert.are.same({ 2907, 2907, 2907, 2906, 2907, 2907 }, map(rows, "skillLineID"))
      assert.are.equal("addon", rows[1].crafter.source)
      assert.are.equal("native", rows[5].crafter.source)
    end)

    it("takes the crafters from GetCrafters unchanged", function()
      for _, r in ipairs(Guild:BuildTabRows({})) do
        if r.recipeID == 100 then
          local ids = {}
          for _, c in ipairs(Guild:GetCrafters(100)) do ids[#ids + 1] = c.name end
          assert.are.same({ "B-Realm", "C-Realm" }, ids)
          break
        end
      end
    end)

    it("filters by text on the recipe name or the crafter name, case-insensitively, as a plain substring", function()
      assert.are.same({ "Everforged Mace" }, uniq(map(Guild:BuildTabRows({ text = "mace" }), "recipeName")))
      assert.are.equal(2, #Guild:BuildTabRows({ text = "MACE" }))            -- both crafters of a matching recipe
      assert.are.same({ "B-Realm" }, uniq(map(map(Guild:BuildTabRows({ text = "b-real" }), "crafter"), "name")))
      assert.are.equal(3, #Guild:BuildTabRows({ text = "b-real" }))          -- B's three recipes, not their other crafters
      assert.are.equal(0, #Guild:BuildTabRows({ text = "%" }))
      assert.are.equal(0, #Guild:BuildTabRows({ text = "." }))
      assert.are.equal(6, #Guild:BuildTabRows({ text = "" }))
      assert.are.equal(6, #Guild:BuildTabRows({ text = nil }))
    end)

    it("filters by profession", function()
      assert.are.same({ "Midnight Flask" }, map(Guild:BuildTabRows({ skillLineID = 2906 }), "recipeName"))
      assert.are.equal(5, #Guild:BuildTabRows({ skillLineID = 2907 }))
      assert.are.equal(0, #Guild:BuildTabRows({ skillLineID = 999 }))
      assert.are.equal(1, #Guild:BuildTabRows({ skillLineID = 2907, text = "axe" }))
    end)

    it("names a recipe the client has no name for", function()
      store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 }, [555] = { 1, 1 } } })
      local names = uniq(map(Guild:BuildTabRows({}), "recipeName"))
      assert.is_true(contains(names, "Recipe 555"))
    end)

    it("leaves out the account's own characters and contested ones, and answers empty with Guild off", function()
      store("Me-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 } } })
      dir().contested["C-Realm"] = now()
      local rows = Guild:BuildTabRows({ text = "mace" })
      assert.are.same({ "B-Realm" }, map(map(rows, "crafter"), "name"))
      Guild:Disable()
      assert.are.same({}, Guild:BuildTabRows({}))
    end)

    it("reads only: no directory is created and nothing is written", function()
      local before = ns.Util.DeepCopy(ns.FS.db.global.guildDirectory)
      Guild:BuildTabRows({ text = "mace" })
      assert.are.same(before, ns.FS.db.global.guildDirectory)
      p4.guild.key = nil
      Guild:OnGuildUpdate()
      assert.are.same({}, Guild:BuildTabRows({}))
    end)

    it("lists the profession lines of the stored profiles and the native cache", function()
      assert.are.same({ 2906, 2907 }, Guild:TabSkillLines())
      native_members(777, { NATIVE_D }, 2910)
      assert.are.same({ 2906, 2907, 2910 }, Guild:TabSkillLines())
    end)
  end)

  ---------------------------------------------------------------------------
  -- Status and self-test
  ---------------------------------------------------------------------------

  describe("Status", function()
    it("summarises the directory, the gate and the queue", function()
      local s = Guild:Status()
      assert.are.equal("G-Realm", s.guildKey)
      assert.are.equal(2, s.addonMembers)
      assert.are.equal(3, s.profiles)
      assert.are.equal(1, s.nativeCached)
      assert.is_false(s.gateLocked)
      assert.is_nil(s.gateReason)
      assert.are.equal(0, s.queue)
      assert.are.equal("ok", s.sync)
    end)

    it("reports the chat gate and what waits behind it", function()
      p4.restriction.lockdown = true
      Guild.comm:Send(Protocol.Hello("1.0.0", {}), "GUILD", nil, { key = "hello" })
      local s = Guild:Status()
      assert.is_true(s.gateLocked)
      assert.are.equal("lockdown", s.gateReason)
      assert.are.equal(1, s.queue)
      assert.are.equal("paused", s.sync)
    end)

    it("is empty outside a guild and says read-only on a newer saved format", function()
      ns.FS.dbIsNewer = true
      assert.are.equal("readOnly", Guild:Status().sync)
      ns.FS.dbIsNewer = false
      p4.guild.key = nil
      Guild:OnGuildUpdate()
      local s = Guild:Status()
      assert.is_nil(s.guildKey)
      assert.are.same({ 0, 0, 0, 0 }, { s.addonMembers, s.profiles, s.nativeCached, s.queue })
    end)
  end)

  describe("SelfTest", function()
    it("round-trips the largest own profile", function()
      local r = Guild:SelfTest()
      assert.is_true(r.ok); assert.is_nil(r.err)
      assert.is_true(r.wireBytes > 0)
      assert.are.equal(math.ceil(r.wireBytes / 254), r.chunks)
    end)

    it("picks the largest profile of the account", function()
      local small = Guild:SelfTest().wireBytes
      chars["Alt-Realm"].professions[2906].recipes = {}
      for id = 1, 40 do chars["Alt-Realm"].professions[2906].recipes[5000 + id] = true end
      Guild:OnPrivacyChanged(); p4.advance(1)
      settings.shareAlts = "all"
      Guild:OnPrivacyChanged(); p4.advance(1)
      assert.is_true(Guild:SelfTest().wireBytes > small)
    end)

    it("builds the profile when sharing is off", function()
      settings.share = false
      Guild:OnPrivacyChanged()
      local r = Guild:SelfTest()
      assert.is_true(r.ok)
      assert.is_true(r.wireBytes > 0)
    end)

    it("sends one chunk up to 255 bytes and ceil(bytes / 254) above", function()
      local Codec = ns.Social.Codec
      for _, case in ipairs({ { 253, 255, 1 }, { 254, 256, 2 }, { 507, 509, 3 } }) do
        local encoded, bytes, chunks = case[1], case[2], case[3]
        Codec.Encode = function() return string.rep("x", encoded) end
        local r = Guild:SelfTest()
        assert.are.equal(bytes, r.wireBytes)
        assert.are.equal(chunks, r.chunks)
        assert.is_false(r.ok)                                 -- the filler does not decode
      end
    end)

    it("fails clearly without a profile or without the codec", function()
      chars["Me-Realm"].professions = {}
      chars["Alt-Realm"].professions = {}
      settings.share = false
      Guild:OnPrivacyChanged()                                -- forgets the profiles built at login
      local r = Guild:SelfTest()
      assert.is_false(r.ok); assert.are.equal("no profile", r.err)
      assert.are.equal(0, r.wireBytes); assert.are.equal(0, r.chunks)
      chars = fixture_chars()
      _G.C_EncodingUtil = nil
      r = Guild:SelfTest()
      assert.is_false(r.ok); assert.are.equal("no codec", r.err)
    end)

    it("reports a mismatch after the round trip", function()
      ns.Social.Protocol.Unwire = function()
        return ns.Social.Protocol.Data({ c = "X-Realm", ts = 1, lv = "r", pr = {} })
      end
      local r = Guild:SelfTest()
      assert.is_false(r.ok)
      assert.are.equal("mismatch", r.err)
    end)
  end)

  ---------------------------------------------------------------------------
  -- /fs guild
  ---------------------------------------------------------------------------

  describe("/fs guild", function()
    it("is a registered subcommand with a help line", function()
      assert.is_truthy(ns.FS.slashCommands.guild)
      assert.are.equal("guild sync status; 'selftest' checks the wire format", ns.FS.slashCommands.guild.help)
    end)

    it("prints the status without arguments", function()
      ns.FS:HandleSlash("guild")
      local text = table.concat(W.printed, "\n")
      assert.truthy(text:find("G-Realm", 1, true))
      assert.truthy(text:find("3 profiles", 1, true))
    end)

    it("prints the self-test result", function()
      ns.FS:HandleSlash("guild selftest")
      local line = printed()
      assert.truthy(line:find("ok", 1, true))
      assert.truthy(line:find("bytes", 1, true))
      assert.truthy(line:find("chunk", 1, true))
    end)

    it("says FAILED with the reason, and warns above 12000 bytes", function()
      chars["Me-Realm"].professions = {}
      chars["Alt-Realm"].professions = {}
      settings.share = false
      Guild:OnPrivacyChanged()
      ns.FS:HandleSlash("guild selftest")
      assert.truthy(printed():find("FAILED", 1, true))
      assert.truthy(printed():find("no profile", 1, true))
      chars = fixture_chars()
      settings.share = true
      Guild:OnPrivacyChanged(); p4.advance(1)
      local Codec = ns.Social.Codec
      local real = Codec.Encode
      Codec.Encode = function(msg) local e = real(msg); return e .. string.rep("x", 12100) end
      ns.FS:HandleSlash("guild selftest")
      assert.truthy(printed():find("12000", 1, true))
    end)

    it("answers an unknown argument with the usage", function()
      ns.FS:HandleSlash("guild nonsense")
      assert.truthy(printed():find("selftest", 1, true))
    end)

    it("works while Guild is off", function()
      Guild:Disable()
      ns.FS:HandleSlash("guild")
      assert.truthy(table.concat(W.printed, "\n"):find("turned off", 1, true))
      assert.same({}, ns.FS.db.global.diagnostics.errors)
    end)
  end)

  ---------------------------------------------------------------------------
  -- Options group
  ---------------------------------------------------------------------------

  describe("options group", function()
    local OPTION_KEYS = { "share", "shareLevel", "shareAlts", "tooltipLine", "panelLine", "useNative", "purge" }

    it("registers the guild group at order 70 with every setting", function()
      local opts = registered_options("guild")
      assert.are.equal("group", opts.type)
      assert.are.equal(70, opts.order)
      for _, key in ipairs(OPTION_KEYS) do assert.is_table(opts.args[key], key) end
      assert.are.equal("toggle", opts.args.share.type)
      assert.are.equal("select", opts.args.shareLevel.type)
      assert.are.equal("Recipes and expected quality", opts.args.shareLevel.values.quality)
      assert.are.equal("Recipes only", opts.args.shareLevel.values.recipes)
      assert.is_string(opts.args.shareAlts.values.current)
      assert.is_string(opts.args.shareAlts.values.guild)
      assert.is_string(opts.args.shareAlts.values.all)
      assert.are.equal("execute", opts.args.purge.type)
    end)

    it("reads the settings", function()
      local opts = registered_options("guild")
      assert.is_true(opts.args.share.get())
      assert.are.equal("quality", opts.args.shareLevel.get())
      assert.are.equal("guild", opts.args.shareAlts.get())
      settings.tooltipLine = false
      assert.is_false(opts.args.tooltipLine.get())
    end)

    it("re-announces after a privacy change", function()
      local opts = registered_options("guild")
      opts.args.shareLevel.set(nil, "recipes")
      assert.are.equal("recipes", settings.shareLevel)
      p4.advance(1)
      assert.are.equal("r", Guild:GetOwnProfile("Me-Realm").lv)
      assert.are.equal("H", last_sent_msg().t)
    end)

    it("sends the empty HELLO at once when sharing is switched off", function()
      local opts = registered_options("guild")
      opts.args.share.set(nil, false)
      assert.is_false(settings.share)
      local msg = last_sent_msg()
      assert.are.equal("H", msg.t)
      assert.are.same({}, msg.c)
      assert.are.same({}, Guild:GetOwnHashes())
    end)

    it("rebuilds and announces when the characters shared change", function()
      local opts = registered_options("guild")
      opts.args.shareAlts.set(nil, "current")
      assert.are.equal("current", settings.shareAlts)
      p4.advance(1)
      assert.are.equal("H", last_sent_msg().t)
    end)

    it("ignores a value that is not one of the choices", function()
      local opts = registered_options("guild")
      opts.args.shareLevel.set(nil, "everything")
      opts.args.shareAlts.set(nil, "nobody")
      assert.are.equal("quality", settings.shareLevel)
      assert.are.equal("guild", settings.shareAlts)
    end)

    it("changes the line toggles without announcing anything", function()
      local opts = registered_options("guild")
      opts.args.tooltipLine.set(nil, false)
      opts.args.panelLine.set(nil, false)
      opts.args.useNative.set(nil, false)
      assert.is_false(settings.tooltipLine); assert.is_false(settings.panelLine); assert.is_false(settings.useNative)
      p4.advance(2)
      assert.are.equal(0, #p4.comm.sent)
    end)

    it("forgets the current guild's directory behind a confirmation", function()
      local opts = registered_options("guild")
      assert.is_function(opts.args.purge.confirm)
      assert.is_string(opts.args.purge.confirm())
      assert.is_not_nil(ns.FS.db.global.guildDirectory["G-Realm"])
      opts.args.purge.func()
      assert.is_nil(ns.FS.db.global.guildDirectory["G-Realm"])
    end)

    it("is disabled and writes nothing while the saved data is from a newer version", function()
      local opts = registered_options("guild")
      local before = ns.Util.DeepCopy(ns.FS.db.global)
      local sentBefore = #p4.comm.sent
      ns.FS.dbIsNewer = true
      for _, key in ipairs(OPTION_KEYS) do
        assert.is_true(opts.args[key].disabled(), key)
      end
      assert.has_no.errors(function()
        opts.args.share.set(nil, false)
        opts.args.shareLevel.set(nil, "recipes")
        opts.args.shareAlts.set(nil, "all")
        opts.args.tooltipLine.set(nil, false)
        opts.args.panelLine.set(nil, false)
        opts.args.useNative.set(nil, false)
        opts.args.purge.func()
      end)
      p4.advance(5)
      assert.are.same(before, ns.FS.db.global)
      assert.are.equal(sentBefore, #p4.comm.sent)
      ns.FS.dbIsNewer = false
      assert.is_false(opts.args.share.disabled())
    end)
  end)

  ---------------------------------------------------------------------------
  -- Tab
  ---------------------------------------------------------------------------

  describe("tab", function()
    local container, refreshed

    local function view() return ns.FS:GetModule("GuildTab"):GetView() end
    local function open(width)
      container = CreateFrame("Frame")
      container:SetSize(width or 716, 500)
      local def = registered_tab("guild")
      def.build(container)
      def.refresh(container)
      return view()
    end
    local function resize(width)
      container:SetSize(width, 500)
      container:GetScript("OnSizeChanged")(container, width, 500)
    end
    local function row_frame(grid, i) return grid.rowPool[i] end
    local function click(frame) frame:GetScript("OnClick")(frame) end
    local function hover(frame) frame:GetScript("OnEnter")(frame) end
    local function refresh_now() registered_tab("guild").refresh(container) end

    before_each(function()
      refreshed = {}
      container = nil
      MW.RefreshTab = function(_, id)
        refreshed[#refreshed + 1] = id
        if container then registered_tab(id).refresh(container) end
      end
    end)

    it("registers at order 90 in phase 4 through a core registrar", function()
      local def = registered_tab("guild")
      assert.are.equal(90, def.order)
      assert.are.equal(4, def.phase)
      assert.are.equal("Guild", def.label)
      assert.are.equal("Interface\\Icons\\INV_Misc_Tabard_01", def.icon)
      assert.is_function(def.build); assert.is_function(def.refresh)
      assert.is_true(ns.FS:GetModule("GuildTab").coreModule)
      assert.is_true(ns.FS:GetModule("GuildTab"):IsEnabled())
    end)

    describe("Layout", function()
      local Tab
      before_each(function() Tab = ns.UI.GuildTab end)

      it("gives the Recipe column at least 120 px at 516 px and all columns room", function()
        local l = Tab.Layout(516)
        assert.same({}, l.hidden)
        assert.are.equal(516 - 12 - 306 - 20, l.flex)
        assert.is_true(l.flex >= 120)
        assert.are.equal(716 - 12 - 306 - 20, Tab.Layout(716).flex)
      end)

      it("hides Source, then Conc Q, then Age when the width is short", function()
        assert.same({ source = true }, Tab.Layout(400).hidden)
        assert.same({ source = true, qc = true }, Tab.Layout(380).hidden)
        assert.same({ source = true, qc = true, age = true }, Tab.Layout(330).hidden)
        for _, w in ipairs({ 400, 380, 330 }) do assert.is_true(Tab.Layout(w).flex >= 120, w) end
      end)

      it("hides nothing for an unknown width", function()
        assert.same({}, Tab.Layout(nil).hidden)
        assert.is_nil(Tab.Layout(0).flex)
      end)
    end)

    it("builds the bar and lays it out at 516 and 716 px", function()
      local v = open(516)
      assert.are.equal("TOPLEFT", point(v.search)[1])
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -4 }, point(v.search))
      assert.are.equal(170, v.search:GetWidth())
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 174, -4 }, point(v.profButton))
      assert.are.equal(150, v.profButton:GetWidth())
      assert.same({ "TOPRIGHT", v.bar, "TOPRIGHT", 0, -4 }, point(v.askButton))
      assert.are.equal(100, v.askButton:GetWidth())
      assert.is_true(170 + 4 + 150 < 516 - 12 - 100)            -- the three controls never overlap
      assert.are.equal(516 - 12, v.status:GetWidth())
      assert.are.equal(178, v.grid.layout.flex)
      resize(716)
      assert.same({ "TOPRIGHT", v.bar, "TOPRIGHT", 0, -4 }, point(v.askButton))
      assert.are.equal(716 - 12, v.status:GetWidth())
      assert.are.equal(378, v.grid.layout.flex)
      resize(380)
      assert.same({ source = true, qc = true }, v.grid.layout.hidden)
    end)

    it("shows one grid row per crafter with the six columns", function()
      local v = open()
      assert.are.equal(6, v.grid.shownRows)
      local axe = row_frame(v.grid, 1)
      assert.are.same({ "Everforged Axe", "B-Realm", "2", "4", "Addon", "<1m" },
        { plain(axe.cells.recipe:GetText()), plain(axe.cells.crafter:GetText()), axe.cells.q:GetText(),
          axe.cells.qc:GetText(), axe.cells.source:GetText(), axe.cells.age:GetText() })
      local mace_c = row_frame(v.grid, 3)
      assert.are.same({ "C-Realm", EM_DASH, EM_DASH }, { plain(mace_c.cells.crafter:GetText()), mace_c.cells.q:GetText(),
        mace_c.cells.qc:GetText() })                                    -- recipes-only profile: quality unknown, never 0
      local bandage = row_frame(v.grid, 5)
      assert.are.same({ "D-Realm", EM_DASH, EM_DASH, "Guild query" }, { plain(bandage.cells.crafter:GetText()),
        bandage.cells.q:GetText(), bandage.cells.qc:GetText(), bandage.cells.source:GetText() })
      assert.is_false(v.empty:IsShown())
    end)

    it("dims crafters known to be offline", function()
      local v = open()
      local offline = row_frame(v.grid, 6)                              -- B-Realm, native, online = false
      assert.are.equal(DIM .. "B-Realm|r", offline.cells.crafter:GetText())
      local online = row_frame(v.grid, 5)
      assert.are.equal("D-Realm", online.cells.crafter:GetText())
    end)

    it("escapes pipes in peer names and writes a copy reported by someone else as 'via owner'", function()
      store("Ev|cffff0000il-Realm", "Peer|TBad-Realm", { verified = false, recipes = { [101] = { 5, 5 } } })
      local v = open()
      local text
      for i = 1, v.grid.shownRows do
        local t = row_frame(v.grid, i).cells.crafter:GetText()
        if t:find("Ev", 1, true) then text = t end
      end
      assert.truthy(text)
      assert.truthy(text:find("Ev||cffff0000il-Realm (via Peer||TBad-Realm)", 1, true))
      assert.is_nil(text:find("[^|]|c"))
    end)

    it("shows every value, hidden columns included, in the row tooltip", function()
      local v = open(380)                                              -- source and conc Q hidden
      local row = row_frame(v.grid, 2)                                 -- Everforged Mace / B-Realm
      hover(row)
      local text = plain(table.concat(tooltip.lines, "\n"))
      assert.truthy(text:find("Everforged Mace", 1, true))
      assert.truthy(text:find("B-Realm", 1, true))
      assert.truthy(text:find("Blacksmithing", 1, true) or text:find("2907", 1, true))
      assert.truthy(text:find("Q3", 1, true))
      assert.truthy(text:find("Q5", 1, true))
      assert.truthy(text:find("Addon", 1, true))
      assert.truthy(text:find("synced", 1, true))
    end)

    it("filters by the search box after 0.3 s and by the profession button", function()
      local v = open()
      v.search:Type("mace")
      assert.are.equal(6, v.grid.shownRows)                            -- nothing yet
      p4.advance(0.3)
      assert.same({ "Everforged Mace", "Everforged Mace" }, (function()
        local out = {}
        for i = 1, v.grid.shownRows do out[i] = plain(row_frame(v.grid, i).cells.recipe:GetText()) end
        return out
      end)())
      v.search:Type("")
      assert.are.equal(6, v.grid.shownRows)                            -- clearing is immediate
      assert.are.equal("All professions", v.profButton:GetText())
      click(v.profButton)
      assert.truthy(v.profButton:GetText():find("Alchemy", 1, true))
      assert.are.equal(1, v.grid.shownRows)
      click(v.profButton)
      assert.truthy(v.profButton:GetText():find("Blacksmithing", 1, true))
      assert.are.equal(5, v.grid.shownRows)
      click(v.profButton)
      assert.are.equal("All professions", v.profButton:GetText())
      assert.are.equal(6, v.grid.shownRows)
    end)

    it("whispers the crafter of a clicked row and selects its recipe", function()
      local v = open()
      click(row_frame(v.grid, 2))
      assert.are.same({ { "B-Realm" } }, W.tells)
      assert.are.equal(100, v.selected.recipeID)
      assert.truthy(v.status:GetText():find("Everforged Mace", 1, true))
      click(row_frame(v.grid, 5))
      assert.are.same({ "B-Realm", "D-Realm" }, { W.tells[1][1], W.tells[2][1] })
      assert.are.equal(200, v.selected.recipeID)
    end)

    it("never sends a chat message itself", function()
      local v = open()
      _G.SendChatMessage = function() error("SendChatMessage must not be called") end
      assert.has_no.errors(function() click(row_frame(v.grid, 1)) end)
    end)

    describe("Ask guild", function()
      it("is disabled until a row is selected", function()
        local v = open()
        assert.is_false(v.askButton:IsEnabled())
        hover(v.askButton)
        assert.truthy(table.concat(tooltip.lines, "\n"):find("row", 1, true))
        click(row_frame(v.grid, 5))
        assert.is_true(v.askButton:IsEnabled())
      end)

      it("is disabled while the chat gate is locked, with 'Sync paused' in the footer", function()
        local v = open()
        click(row_frame(v.grid, 5))
        p4.restriction.lockdown = true
        ns.FS:SendMessage(ns.Msg.COMM_GATE_CHANGED, true, "lockdown")
        p4.advance(0.5)
        assert.is_false(v.askButton:IsEnabled())
        assert.truthy(v.footer:GetText():find("^Sync paused %(instance%)"))
        p4.restriction.lockdown = false
        ns.FS:SendMessage(ns.Msg.COMM_GATE_CHANGED, false)
        p4.advance(0.5)
        assert.is_true(v.askButton:IsEnabled())
        assert.is_nil(v.footer:GetText():find("paused", 1, true))
      end)

      it("is disabled when the guild recipe list is switched off in the settings", function()
        local v = open()
        click(row_frame(v.grid, 5))
        settings.useNative = false
        refresh_now()
        assert.is_false(v.askButton:IsEnabled())
        assert.are.equal(0, p4.guild.queryCount)
        v.askButton:GetScript("OnClick")(v.askButton)                  -- a click anyway asks nothing
        assert.are.equal(0, p4.guild.queryCount)
      end)

      it("queries the selected recipe and shows the answer", function()
        local v = open()
        click(row_frame(v.grid, 2))                                   -- Everforged Mace, skill line 2907
        v.askButton:GetScript("OnClick")(v.askButton)
        assert.are.equal(1, p4.guild.queryCount)
        assert.same({ skillLineID = 2907, recipeID = 100 }, { skillLineID = p4.guild.lastQuery.skillLineID,
          recipeID = p4.guild.lastQuery.recipeID })
        assert.truthy(v.status:GetText():find("Asking", 1, true))
        p4.guild.postQuery = { skillLineID = 2907, recipeID = 100,
          list = { { "Zed", "Zed-Realm", "MAGE", true }, { "Yan", "Yan-Realm", "ROGUE", false } } }
        W.fire("GUILD_RECIPE_KNOWN_BY_MEMBERS")
        assert.truthy(v.status:GetText():find("2 can craft", 1, true))
        p4.advance(2)                                                  -- FS_GUILD_CHANGED, then the debounced refresh
        assert.truthy(refreshed[1] == "guild")
        local names = {}
        for i = 1, v.grid.shownRows do names[#names + 1] = plain(row_frame(v.grid, i).cells.crafter:GetText()) end
        assert.truthy((table.concat(names, ","):find("Zed-Realm", 1, true)))
      end)

      it("says why a query failed", function()
        local v = open()
        click(row_frame(v.grid, 2))
        v.askButton:GetScript("OnClick")(v.askButton)
        p4.advance(6)
        assert.truthy(v.status:GetText():find("did not answer", 1, true))
      end)
    end)

    it("shows the sync summary in the footer, leading with its key word", function()
      local v = open()
      local text = v.footer:GetText()
      assert.truthy(text:find("^Sync: on"))
      assert.truthy(text:find("2 with addon", 1, true))
      assert.truthy(text:find("3 profiles", 1, true))
      settings.share = false
      refresh_now()
      assert.truthy(v.footer:GetText():find("^Sync: sharing off"))
      hover(v.footerHit)
      assert.truthy(#tooltip.lines > 1)
    end)

    it("says when Guild is turned off, there is no guild, or nobody crafts anything", function()
      local v = open()
      Guild:Disable()
      refresh_now()
      assert.is_true(v.empty:IsShown())
      assert.truthy(v.empty:GetText():find("Guild sync is turned off", 1, true))
      assert.is_false(v.grid.frame:IsShown())
      Guild:Enable()
      refresh_now()
      assert.is_true(v.grid.frame:IsShown())
      assert.is_false(v.empty:IsShown())
      p4.guild.key = nil
      Guild:OnGuildUpdate()
      refresh_now()
      assert.truthy(v.empty:GetText():find("Not in a guild", 1, true))
      p4.guild.key = { "G", "Realm" }
      Guild:OnGuildUpdate()
      ns.FS.db.global.guildDirectory["G-Realm"] = nil
      refresh_now()
      assert.truthy(v.empty:GetText():find("No guild crafters", 1, true))
      v.search:Type("zzz")
      p4.advance(0.3)
      assert.truthy(v.empty:GetText():find("match", 1, true))
    end)

    it("refreshes after FS_GUILD_CHANGED and FS_COMM_GATE_CHANGED, once per burst", function()
      open()
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      ns.FS:SendMessage(ns.Msg.COMM_GATE_CHANGED, true, "lockdown")
      p4.advance(0.4)
      assert.are.same({}, refreshed)
      p4.advance(0.2)
      assert.are.same({ "guild" }, refreshed)
      p4.advance(0.5)
      assert.are.same({ "guild" }, refreshed)
    end)

    it("keeps ages moving once a minute while shown, and stops when hidden", function()
      open()
      p4.advance(61)
      assert.is_true(#refreshed >= 1)
      refreshed = {}
      container:GetScript("OnHide")(container)
      p4.advance(130)
      assert.are.same({}, refreshed)
    end)

    it("cancels everything pending and listens to nothing while disabled", function()
      open()
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      ns.FS:GetModule("GuildTab"):Disable()
      p4.advance(5)
      assert.are.same({}, refreshed)
      assert.are.same({}, W.registrations(ns.FS:GetModule("GuildTab")).messages)
      assert.are.same({}, W.registrations(ns.FS:GetModule("GuildTab")).events)
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      p4.advance(5)
      assert.are.same({}, refreshed)
    end)

    it("logs no errors through a refresh", function()
      local v = open()
      click(row_frame(v.grid, 1))
      refresh_now()
      assert.same({}, ns.FS.db.global.diagnostics.errors)
    end)
  end)
end)

describe("Guild tab in a full load", function()
  it("is a core registrar before the Settings tab, and the guild group is registered", function()
    local W = install_wow_stubs()
    local ns = load_addon({})
    W.boot()
    local ids = {}
    for _, t in ipairs(ns.FS:GetModule("MainWindow"):GetTabs()) do ids[#ids + 1] = t.id end
    assert.same({ "dashboard", "recipes", "queue", "orders", "customers", "ledger", "characters", "planner", "guild",
      "settings" }, ids)
    assert.is_true(ns.FS:GetModule("GuildTab"):IsEnabled())
    assert.is_nil(ns.FS:GetOptionsTable().args.modules.args.GuildTab)
    assert.is_table(ns.FS:GetOptionsTable().args.guild)
    ns.FS:HandleSlash("tab guild")
    assert.equal("guild", ns.FS:GetModule("MainWindow"):GetSelectedTab())
    ns.FS:HandleSlash("guild selftest")
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
