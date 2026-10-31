describe("Social.ChatMatcher", function()
  local ns, ChatMatcher, cfg
  local L1 = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r"

  before_each(function()
    ns = boot_phase4({ "Modules/Social/ChatMatcher.lua" })
    ChatMatcher = ns.Social.ChatMatcher
    cfg = { include = ChatMatcher.DEFAULT_INCLUDE, exclude = ChatMatcher.DEFAULT_EXCLUDE }
  end)

  it("detects a request with an item link and keeps the full link", function()
    local r = ChatMatcher.Parse("LF crafter for " .. L1 .. " pls", cfg)
    assert.is_true(r.isRequest)
    assert.are.equal(212345, r.itemLinks[1].itemID)
    assert.are.equal(L1, r.itemLinks[1].link)
    assert.are.equal("lf crafter for [everforged gloves ] pls", r.plain)
  end)

  it("treats WTB as a request only with an item link", function()
    assert.is_true(ChatMatcher.Parse("WTB " .. L1, cfg).isRequest)
    assert.is_false(ChatMatcher.Parse("WTB gold", cfg).isRequest)
  end)

  it("lets exclusions win and ignores crafter adverts", function()
    assert.is_false(ChatMatcher.Parse("WTS crafting all recipes, can craft " .. L1, cfg).isRequest)
    assert.is_false(ChatMatcher.Parse("LF crafter? lol I'm selling", cfg).isRequest)
    assert.is_true(ChatMatcher.Parse("WTS crafting all recipes, can craft " .. L1, cfg).excluded)
  end)

  it("does not let an exclusion fire inside an include phrase", function()
    local r = ChatMatcher.Parse("who can craft " .. L1, cfg)
    assert.is_true(r.isRequest)
    assert.is_false(r.excluded)
    assert.is_false(ChatMatcher.Parse("can craft " .. L1, cfg).isRequest)
    assert.is_true(ChatMatcher.Parse("can craft " .. L1, cfg).excluded)
    assert.is_false(ChatMatcher.Parse("who can craft " .. L1 .. " wts", cfg).isRequest)
  end)

  it("matches case-insensitively on word boundaries", function()
    assert.is_true(ChatMatcher.Parse("Looking For A Crafter!!", cfg).isRequest)
    assert.is_false(ChatMatcher.Parse("twts", { include = {}, exclude = { "wts" } }).excluded)
    assert.is_false(ChatMatcher.Parse("lf crafters", { include = { "lf craft" }, exclude = {} }).isRequest)
  end)

  it("extracts recipe links of both link types", function()
    local r = ChatMatcher.Parse("can anyone craft |cffffd000|Henchant:447379|h[Tailoring: Robe]|h|r", cfg)
    assert.is_true(r.isRequest)
    assert.are.equal(447379, r.recipeLinks[1].recipeID)
    assert.are.equal("|cffffd000|Henchant:447379|h[Tailoring: Robe]|h|r", r.recipeLinks[1].link)
    local s = ChatMatcher.Parse("|cffffd000|Hspell:12345|h[Robe]|h|r", cfg)
    assert.are.equal(12345, s.recipeLinks[1].recipeID)
    assert.are.equal(0, #s.itemLinks)
  end)

  it("collects several links in order", function()
    local a = "|cff0070dd|Hitem:1001::::|h[Alpha]|h|r"
    local b = "|cff0070dd|Hitem:1002::::|h[Beta]|h|r"
    local r = ChatMatcher.Parse("LF crafter " .. a .. " " .. b, cfg)
    assert.are.equal(2, #r.itemLinks)
    assert.are.equal(1001, r.itemLinks[1].itemID)
    assert.are.equal(1002, r.itemLinks[2].itemID)
  end)

  it("honours user keywords with magic characters", function()
    assert.is_true(ChatMatcher.Parse("lf b.s. pls", { include = { "lf b.s." }, exclude = {} }).isRequest)
    assert.is_false(ChatMatcher.Parse("lf bxsx pls", { include = { "lf b.s." }, exclude = {} }).isRequest)
    assert.is_true(ChatMatcher.Parse("need (tailor) now", { include = { "(tailor)" }, exclude = {} }).isRequest)
  end)

  it("builds keyword patterns with frontiers only at alphanumeric ends", function()
    assert.are.equal("%f[%w]lf crafter%f[%W]", ChatMatcher.KeywordPattern("LF Crafter"))
    assert.are.equal("%f[%w]lf b%.s%.", ChatMatcher.KeywordPattern("lf b.s."))
    assert.are.equal("%(tailor%)", ChatMatcher.KeywordPattern("(tailor)"))
  end)

  it("finds recipe names longest-first without overlapping hits", function()
    local idx = { { name = "everforged mace", recipeID = 1 }, { name = "forged mace", recipeID = 2 } }
    assert.are.same({ 1 }, ChatMatcher.FindRecipeNames("need someone to craft everforged mace", idx, 3))
    assert.are.same({ 2 }, ChatMatcher.FindRecipeNames("need a forged mace", idx, 3))
    assert.are.same({ 1, 2 }, ChatMatcher.FindRecipeNames("everforged mace and forged mace", idx, 3))
    assert.are.same({ 1 }, ChatMatcher.FindRecipeNames("everforged mace and forged mace", idx, 1))
  end)

  it("never raises on odd input", function()
    for _, v in ipairs({ 42, true, {}, function() end }) do
      local r = ChatMatcher.Parse(v, cfg)
      assert.is_false(r.isRequest)
      assert.is_false(r.excluded)
      assert.are.equal("", r.plain)
    end
    assert.is_false(ChatMatcher.Parse(nil, cfg).isRequest)
    assert.is_false(ChatMatcher.Parse("", cfg).isRequest)
    assert.is_true(ChatMatcher.Parse("lf crafter", nil).isRequest)
    assert.is_true(ChatMatcher.Parse("lf crafter", { include = { 5, "", "lf crafter" }, exclude = "x" }).isRequest)
    assert.is_false(ChatMatcher.Parse("|Hitem:123|h[unterminated", cfg).isRequest)
    assert.are.equal(0, #ChatMatcher.Parse("lf crafter |cffffffff|Hitem:123|h[unterminated", cfg).itemLinks)
    assert.are.same({}, ChatMatcher.FindRecipeNames(nil, nil, 3))
    assert.are.same({}, ChatMatcher.FindRecipeNames("abc", { { name = 5 } }, 3))
  end)

  it("bounds the work on long or hostile lines", function()
    local t0 = os.clock()
    ChatMatcher.Parse(("|Hitem:1|h"):rep(5000), cfg)
    ChatMatcher.Parse(("|A"):rep(20000), cfg)
    ChatMatcher.Parse(("lf crafter "):rep(5000), cfg)
    ChatMatcher.Parse(("x"):rep(1000000), cfg)
    ChatMatcher.Parse(("|cffffffff|Hitem:1::|h[a]|h|r"):rep(5000), cfg)
    assert.is_true(os.clock() - t0 < 2)
    local r = ChatMatcher.Parse(("|cffffffff|Hitem:1::|h[a]|h|r"):rep(5000), cfg)
    assert.is_true(#r.itemLinks <= ChatMatcher.MAX_LINKS)
    assert.is_true(#r.plain <= ChatMatcher.MAX_LENGTH)
  end)
end)
