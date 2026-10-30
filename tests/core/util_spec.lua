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
end)
