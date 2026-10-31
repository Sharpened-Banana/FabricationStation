### Task 2: Customer tags, notes, alt linking, search, export

**Files:**
- Modify: `Modules/Customers.lua`
- Test: `tests/customers/tags_links_spec.lua`

**Interfaces:**
- Consumes: Task 1 `Customers` store.
- Produces: `Customers:SetNote(nameRealm, text)`, `Customers:SetTag(nameRealm, tag, on)` (tags `"VIP"` and `"blocked"` are canonical; a custom tag is trimmed and cut to 24 characters, and an empty one is ignored), `Customers:Link(alt, main) -> ok, err` (`err = "cycle"|"self"`), `Customers:Unlink(alt)`, `Customers:Root(nameRealm) -> nameRealm`, `Customers:GetGroup(nameRealm) -> {nameRealm,...}` (root first, then alts sorted), `Customers:IsBlocked(nameRealm) -> bool` (true if anyone in the group has `blocked`), `Customers:Search(text) -> {CustomerRecord}` (case-insensitive plain substring over nameRealm, notes and tag names; sorted by `lastSeen` descending with nil as 0, then by nameRealm; empty text returns all), `Customers:Export(nameRealms|nil) -> string`. Every change creates a missing record and sends `FS_CUSTOMERS_CHANGED`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Customers tags/links/search/export", function()
  local ns, C
  before_each(function()
    ns = P2.boot(); P2.load(ns, {"Modules/Customers.lua"}); C = ns.FS:GetModule("Customers")
    C:RecordOrder("Bob-Silvermoon", {time=1000, orderID=1, itemID=1, recipeID=1, quality=3, tip=500000, commission=450000, orderType="personal"})
  end)
  it("blocks a whole linked group", function()
    C:Link("Alt-Silvermoon", "Bob-Silvermoon"); C:SetTag("Bob-Silvermoon", "blocked", true)
    assert.is_true(C:IsBlocked("Alt-Silvermoon")); assert.is_false(C:IsBlocked("Nobody-Silvermoon"))
    assert.same({"Bob-Silvermoon", "Alt-Silvermoon"}, C:GetGroup("Alt-Silvermoon"))
  end)
  it("refuses cycles and self links", function()
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    assert.same({false, "cycle"}, {C:Link("Bob-Silvermoon", "Alt-Silvermoon")})
    assert.same({false, "self"}, {C:Link("Bob-Silvermoon", "Bob-Silvermoon")})
  end)
  it("searches names, notes and tags", function()
    C:SetTag("Bob-Silvermoon", "VIP", true); C:SetNote("Ann-Silvermoon", "slow payer")
    assert.equal("Bob-Silvermoon", C:Search("vip")[1].nameRealm)
    assert.equal("Ann-Silvermoon", C:Search("SLOW")[1].nameRealm)
    assert.equal(2, #C:Search(""))
  end)
  it("exports CSV with quoting", function()
    C:SetTag("Bob-Silvermoon", "VIP", true); C:SetTag("Bob-Silvermoon", "blocked", true)
    C:SetNote("Bob-Silvermoon", 'pays well, "fast"\nalways')
    assert.equal('nameRealm,orders,tipsTotal,lastSeen,tags,linkedTo,notes\n'
      .. 'Bob-Silvermoon,1,500000,1970-01-01,VIP;blocked,,"pays well, ""fast"" always"',
      C:Export({"Bob-Silvermoon"}))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/customers/tags_links_spec.lua`
Expected: FAIL (`attempt to call method 'Link' (a nil value)`)

- [ ] **Step 3: Implement the functions listed under Interfaces in `Modules/Customers.lua`**

`Link` stores `alt.linkedTo = Root(main)`. A link is a cycle when `Root(main) == alt`. Export: dates use `date("!%Y-%m-%d", lastSeen)`, tags are sorted by byte order and joined with `;`, newlines become a space, and a field containing `,`, `"` or a newline is quoted with `"` doubled.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/customers && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Modules/Customers.lua tests/customers/tags_links_spec.lua
git commit -m "feat: add customer tags, notes, alt linking, search and export"
```

