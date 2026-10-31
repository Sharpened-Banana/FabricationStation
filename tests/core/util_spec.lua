describe("Util", function()
  local ns
  before_each(function()
    install_wow_stubs()
    ns = load_addon({}, "Core/Util.lua")
  end)

  it("PushCapped keeps the newest entries up to cap", function()
    local list = {}
    for i = 1, 5 do ns.Util.PushCapped(list, i, 3) end
    assert.same({ 3, 4, 5 }, list)
  end)
  it("DeepCopy drops functions and returns a distinct table", function()
    local src = { a = { b = 1 }, f = print }
    local copy = ns.Util.DeepCopy(src)
    assert.same({ a = { b = 1 } }, copy); assert.is_not.equals(src, copy); assert.is_not.equals(src.a, copy.a)
  end)
  it("DeepCopy drops userdata and threads and passes scalars through", function()
    local src = { io = io.stdout, co = coroutine.create(print), n = 1, s = "x", b = false }
    assert.same({ n = 1, s = "x", b = false }, ns.Util.DeepCopy(src))
    assert.equals(5, ns.Util.DeepCopy(5)); assert.is_nil(ns.Util.DeepCopy(print))
  end)
  it("DeepCopy terminates on self-reference with maxDepth", function()
    local t = { v = 1 }; t.self = t
    local copy = ns.Util.DeepCopy(t, 2)
    assert.equals(1, copy.v); assert.is_table(copy.self); assert.is_nil(copy.self.self)
  end)
  it("DeepCopy defaults to depth 10", function()
    local t = {}; local cur = t
    for _ = 1, 15 do cur.n = {}; cur = cur.n end
    local copy, depth = ns.Util.DeepCopy(t), 1
    while copy.n do copy = copy.n; depth = depth + 1 end
    assert.equals(10, depth)
  end)

  describe("SettingsAccessor", function()
    local DEFAULTS = { a = 1, nested = { b = true } }
    local function fill(target, defaults)
      for k, v in pairs(defaults) do
        if type(target[k]) ~= type(v) then target[k] = ns.Util.DeepCopy(v) end
      end
      return target
    end
    local function fs(global, newer)
      ns.FS = { db = global and { global = global } or nil, dbIsNewer = newer }
    end
    after_each(function() ns.FS = nil end)

    it("returns db.global.settings[key], created and filled on first use", function()
      local g = {}
      fs(g)
      local get = ns.Util.SettingsAccessor("orders")
      local s = get(DEFAULTS, fill)
      assert.equals(g.settings.orders, s)
      assert.same({ a = 1, nested = { b = true } }, s)
      s.a = 5
      assert.equals(5, get(DEFAULTS, fill).a)
      assert.is_not.equals(DEFAULTS.nested, s.nested)
    end)
    it("repairs a settings or settings[key] that is not a table, keeping stored values", function()
      local g = { settings = "junk" }
      fs(g)
      assert.equals(1, ns.Util.SettingsAccessor("x")(DEFAULTS, fill).a)
      assert.is_table(g.settings.x)
      local g2 = { settings = { x = { a = 7 } } }
      fs(g2)
      assert.equals(7, ns.Util.SettingsAccessor("x")(DEFAULTS, fill).a)
    end)
    it("is a session-only copy while the saved data is from a newer version, never writing db.global", function()
      local g = { settings = { x = { a = 7 } } }
      fs(g, true)
      local get = ns.Util.SettingsAccessor("x")
      local s = get(DEFAULTS, fill)
      assert.equals(7, s.a)
      s.a = 9
      assert.equals(9, get(DEFAULTS, fill).a)
      assert.same({ a = 7 }, g.settings.x)
      local empty = {}
      fs(empty, true)
      ns.Util.SettingsAccessor("y")(DEFAULTS, fill)
      assert.same({}, empty)
    end)
    it("is a session-only copy before InitDB, and each accessor keeps its own", function()
      fs(nil)
      local one, two = ns.Util.SettingsAccessor("x"), ns.Util.SettingsAccessor("x")
      one(DEFAULTS, fill).a = 3
      assert.equals(3, one(DEFAULTS, fill).a)
      assert.equals(1, two(DEFAULTS, fill).a)
    end)
  end)
end)
