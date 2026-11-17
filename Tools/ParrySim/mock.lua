-- Minimal Roblox API stand-ins for running BladeBallRewrite.lua's core offline (LuaJIT).
local M = {}

M.now = 0
M.errors = {}
M.err_count = 0

local function pack(...) return { n = select("#", ...), ... } end
M.pack = pack

---------------------------------------------------------------- Vector3
local V3, V3m = {}, {}
local sqrt = math.sqrt
local function v3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V3) end
M.v3 = v3
V3.__index = function(v, k)
    if k == "Magnitude" then local x, y, z = v.x, v.y, v.z; return sqrt(x * x + y * y + z * z) end
    if k == "Unit" then
        local x, y, z = v.x, v.y, v.z
        local m = sqrt(x * x + y * y + z * z)
        return v3(x / m, y / m, z / m)
    end
    if k == "X" then return v.x elseif k == "Y" then return v.y elseif k == "Z" then return v.z end
    return V3m[k]
end
V3.__add = function(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
V3.__sub = function(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
V3.__mul = function(a, b)
    if type(a) == "number" then return v3(a * b.x, a * b.y, a * b.z) end
    if type(b) == "number" then return v3(a.x * b, a.y * b, a.z * b) end
    return v3(a.x * b.x, a.y * b.y, a.z * b.z)
end
V3.__div = function(a, b)
    if type(b) == "number" then return v3(a.x / b, a.y / b, a.z / b) end
    return v3(a.x / b.x, a.y / b.y, a.z / b.z)
end
V3.__unm = function(a) return v3(-a.x, -a.y, -a.z) end
V3.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
V3.__tostring = function(a) return ("%.3f, %.3f, %.3f"):format(a.x, a.y, a.z) end
function V3m.Dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function V3m.Cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
function V3m.Lerp(a, b, t) return v3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t) end
M.Vector3 = { new = v3, yAxis = v3(0, 1, 0), xAxis = v3(1, 0, 0), zAxis = v3(0, 0, 1), zero = v3(0, 0, 0), one = v3(1, 1, 1) }

---------------------------------------------------------------- Vector2
local V2, V2m = {}, {}
local function v2(x, y) return setmetatable({ x = x or 0, y = y or 0 }, V2) end
V2.__index = function(v, k)
    if k == "X" then return v.x elseif k == "Y" then return v.y end
    if k == "Magnitude" then return sqrt(v.x * v.x + v.y * v.y) end
    if k == "Unit" then local m = sqrt(v.x * v.x + v.y * v.y); return v2(v.x / m, v.y / m) end
    return V2m[k]
end
V2.__add = function(a, b) return v2(a.x + b.x, a.y + b.y) end
V2.__sub = function(a, b) return v2(a.x - b.x, a.y - b.y) end
V2.__mul = function(a, b)
    if type(a) == "number" then return v2(a * b.x, a * b.y) end
    if type(b) == "number" then return v2(a.x * b, a.y * b) end
    return v2(a.x * b.x, a.y * b.y)
end
V2.__div = function(a, b) return v2(a.x / b, a.y / b) end
M.Vector2 = { new = v2, zero = v2(0, 0) }

---------------------------------------------------------------- CFrame
local CF = {}
local function cf(pos, look)
    look = look or v3(0, 0, -1)
    local right = look:Cross(M.Vector3.yAxis)
    if right.Magnitude < 1e-6 then right = v3(1, 0, 0) else right = right.Unit end
    local up = right:Cross(look)
    return setmetatable({ Position = pos, p = pos, LookVector = look, RightVector = right, UpVector = up }, CF)
end
CF.__index = function(c, k) return nil end
M.CFrame = {
    new = function(x, y, z)
        if type(x) == "table" then return cf(x) end
        return cf(v3(x or 0, y or 0, z or 0))
    end,
    lookAt = function(at, target)
        local d = target - at
        local m = d.Magnitude
        return cf(at, m > 1e-9 and d / m or v3(0, 0, -1))
    end,
}

---------------------------------------------------------------- typeof
local InstMT, SigMT = {}, {}
function M.typeof(v)
    local mt = getmetatable(v)
    if mt == V3 then return "Vector3" end
    if mt == InstMT then return "Instance" end
    if mt == CF then return "CFrame" end
    if mt == V2 then return "Vector2" end
    if mt == SigMT then return "RBXScriptSignal" end
    if type(v) == "table" and rawget(v, "__enum") then return "EnumItem" end
    return type(v)
end

---------------------------------------------------------------- scheduler
local heap = {}
local seq = 0
local function hpush(t, item)
    seq = seq + 1
    item.t, item.s = t, seq
    heap[#heap + 1] = item
    local i = #heap
    while i > 1 do
        local p = math.floor(i / 2)
        local a, b = heap[p], heap[i]
        if a.t < b.t or (a.t == b.t and a.s < b.s) then break end
        heap[p], heap[i] = b, a
        i = p
    end
end
local function hpop()
    local top = heap[1]
    local last = heap[#heap]
    heap[#heap] = nil
    if #heap > 0 then
        heap[1] = last
        local i, n = 1, #heap
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            local function lt(x, y) return x.t < y.t or (x.t == y.t and x.s < y.s) end
            if l <= n and lt(heap[l], heap[s]) then s = l end
            if r <= n and lt(heap[r], heap[s]) then s = r end
            if s == i then break end
            heap[s], heap[i] = heap[i], heap[s]
            i = s
        end
    end
    return top
end
local deferq = {}

function M.reset_scheduler()
    heap, deferq, seq = {}, {}, 0
    M.errors, M.err_count = {}, 0
end

function M.report(err, co)
    M.err_count = M.err_count + 1
    local msg = tostring(err)
    if co then msg = debug.traceback(co, msg) end
    if not M.errors[tostring(err)] then
        M.errors[tostring(err)] = msg
        if M.verbose_errors then io.stderr:write("[sim error] " .. msg .. "\n") end
    end
end

function M.resume(co, ...)
    if coroutine.status(co) ~= "suspended" then return co end
    local ok, err = coroutine.resume(co, ...)
    if not ok then M.report(err, co) end
    return co
end

M.task = {}
function M.task.spawn(f, ...)
    local co = type(f) == "thread" and f or coroutine.create(f)
    return M.resume(co, ...)
end
function M.task.defer(f, ...)
    local co = type(f) == "thread" and f or coroutine.create(f)
    deferq[#deferq + 1] = { co = co, args = pack(...) }
    return co
end
function M.task.delay(t, f, ...)
    local co = type(f) == "thread" and f or coroutine.create(f)
    hpush(M.now + math.max(tonumber(t) or 0, 0), { co = co, args = pack(...) })
    return co
end
function M.task.wait(t)
    local co, main = coroutine.running()
    if not co or main then error("task.wait outside a coroutine") end
    local t0 = M.now
    hpush(M.now + math.max(tonumber(t) or 0, 1e-6), { co = co, wait_t0 = t0 })
    return coroutine.yield()
end
function M.task.cancel(co) end

function M.run_deferred()
    local guard = 0
    while #deferq > 0 and guard < 10000 do
        guard = guard + 1
        local d = table.remove(deferq, 1)
        M.resume(d.co, unpack(d.args, 1, d.args.n))
    end
end

function M.run_timers()
    while heap[1] and heap[1].t <= M.now do
        local it = hpop()
        if it.wait_t0 then M.resume(it.co, M.now - it.wait_t0) else M.resume(it.co, unpack(it.args, 1, it.args.n)) end
        M.run_deferred()
    end
    M.run_deferred()
end

---------------------------------------------------------------- signals
SigMT.__index = SigMT
function M.signal() return setmetatable({ h = {}, dirty = false }, SigMT) end
local function disconnect(c) c.Connected = false; c.sig.dirty = true end
function SigMT:Connect(fn)
    local c = { fn = fn, Connected = true, sig = self, Disconnect = disconnect }
    self.h[#self.h + 1] = c
    return c
end
SigMT.connect = SigMT.Connect
function SigMT:Once(fn)
    local c
    c = self:Connect(function(...) c:Disconnect(); fn(...) end)
    return c
end
function SigMT:Wait()
    local co = coroutine.running()
    self:Once(function(...) M.resume(co, ...) end)
    return coroutine.yield()
end
M.defer_signals = false
function SigMT:Fire(...)
    if M.defer_signals then
        local args = pack(...)
        for _, c in ipairs(self.h) do
            if c.Connected then
                local fn = c.fn
                deferq[#deferq + 1] = { co = coroutine.create(function() if c.Connected then fn(unpack(args, 1, args.n)) end end), args = pack() }
            end
        end
        return
    end
    if self.dirty then
        local keep = {}
        for _, c in ipairs(self.h) do if c.Connected then keep[#keep + 1] = c end end
        self.h, self.dirty = keep, false
    end
    local list, n = self.h, #self.h
    for i = 1, n do
        local c = list[i]
        if c.Connected then
            local co = coroutine.create(c.fn)
            M.resume(co, ...)
        end
    end
end

---------------------------------------------------------------- instances
local ISA = {
    Part = { BasePart = true, PVInstance = true }, MeshPart = { BasePart = true, PVInstance = true },
    Model = { PVInstance = true }, RemoteEvent = { BaseRemoteEvent = true }, UnreliableRemoteEvent = { BaseRemoteEvent = true },
    Frame = { GuiObject = true }, TextButton = { GuiObject = true, GuiButton = true }, ImageButton = { GuiObject = true, GuiButton = true },
    LinearVelocity = { Constraint = true },
}
local IM = {}
local function d_of(o) return rawget(o, "__d") end

function M.inst(class, name, props)
    local o = setmetatable({}, InstMT)
    rawset(o, "__d", {
        class = class, name = name or class, children = {}, attrs = {}, asig = {}, psig = {}, props = props or {},
        get = {}, parent = nil,
        ev = { ChildAdded = M.signal(), ChildRemoved = M.signal(), Destroying = M.signal(), AttributeChanged = M.signal(),
            DescendantAdded = M.signal(), AncestryChanged = M.signal() },
    })
    return o
end
InstMT.__index = function(o, k)
    local d = rawget(o, "__d")
    if k == "Name" then return d.name end
    if k == "ClassName" then return d.class end
    if k == "Parent" then return d.parent end
    local g = d.get[k]
    if g then return g(o) end
    local p = d.props[k]
    if p ~= nil then return p end
    local m = IM[k]
    if m then return m end
    local e = d.ev[k]
    if e then return e end
    for _, c in ipairs(d.children) do if rawget(c, "__d").name == k then return c end end
    error(tostring(k) .. " is not a valid member of " .. d.class .. " \"" .. d.name .. "\"", 2)
end
InstMT.__newindex = function(o, k, v)
    local d = rawget(o, "__d")
    if k == "Parent" then
        local old = d.parent
        if old == v then return end
        if old then
            local od = d_of(old)
            for i, c in ipairs(od.children) do if c == o then table.remove(od.children, i); break end end
            od.ev.ChildRemoved:Fire(o)
        end
        d.parent = v
        if v then
            local nd = d_of(v)
            nd.children[#nd.children + 1] = o
            nd.ev.ChildAdded:Fire(o)
        end
        return
    end
    if k == "Name" then d.name = v; return end
    local old = d.props[k]
    d.props[k] = v
    if old ~= v then
        local s = d.psig[k]
        if s then s:Fire() end
    end
end
InstMT.__tostring = function(o) return rawget(o, "__d").name end

function M.set_getter(o, prop, fn) d_of(o).get[prop] = fn end
function M.raw_children(o) return d_of(o).children end

function IM.FindFirstChild(o, name, recursive)
    local d = d_of(o)
    for _, c in ipairs(d.children) do if d_of(c).name == name then return c end end
    if recursive then
        for _, c in ipairs(d.children) do
            local f = IM.FindFirstChild(c, name, true)
            if f then return f end
        end
    end
    return nil
end
function IM.WaitForChild(o, name, timeout) return IM.FindFirstChild(o, name) end
function IM.GetChildren(o)
    local out = {}
    for i, c in ipairs(d_of(o).children) do out[i] = c end
    return out
end
function IM.GetDescendants(o)
    local out = {}
    local function walk(x) for _, c in ipairs(d_of(x).children) do out[#out + 1] = c; walk(c) end end
    walk(o)
    return out
end
function IM.IsA(o, cls)
    local c = d_of(o).class
    if c == cls or cls == "Instance" then return true end
    local s = ISA[c]
    return s ~= nil and s[cls] == true
end
function IM.FindFirstChildOfClass(o, cls)
    for _, c in ipairs(d_of(o).children) do if d_of(c).class == cls then return c end end
    return nil
end
function IM.FindFirstChildWhichIsA(o, cls)
    for _, c in ipairs(d_of(o).children) do if IM.IsA(c, cls) then return c end end
    return nil
end
function IM.FindFirstAncestorOfClass(o, cls)
    local p = d_of(o).parent
    while p do
        if d_of(p).class == cls then return p end
        p = d_of(p).parent
    end
    return nil
end
IM.FindFirstAncestorWhichIsA = function(o, cls)
    local p = d_of(o).parent
    while p do
        if IM.IsA(p, cls) then return p end
        p = d_of(p).parent
    end
    return nil
end
function IM.IsDescendantOf(o, anc)
    local p = d_of(o).parent
    while p do
        if p == anc then return true end
        p = d_of(p).parent
    end
    return false
end
function IM.GetAttribute(o, name) return d_of(o).attrs[name] end
function IM.SetAttribute(o, name, v)
    local d = d_of(o)
    local old = d.attrs[name]
    d.attrs[name] = v
    if old ~= v then
        local s = d.asig[name]
        if s then s:Fire() end
        d.ev.AttributeChanged:Fire(name)
    end
end
function IM.GetAttributes(o)
    local out = {}
    for k, v in pairs(d_of(o).attrs) do out[k] = v end
    return out
end
function IM.GetAttributeChangedSignal(o, name)
    local d = d_of(o)
    local s = d.asig[name]
    if not s then s = M.signal(); d.asig[name] = s end
    return s
end
function IM.GetPropertyChangedSignal(o, prop)
    local d = d_of(o)
    local s = d.psig[prop]
    if not s then s = M.signal(); d.psig[prop] = s end
    return s
end
function IM.Destroy(o)
    d_of(o).ev.Destroying:Fire()
    o.Parent = nil
end
function IM.GetFullName(o)
    local parts, x = {}, o
    while x do table.insert(parts, 1, d_of(x).name); x = d_of(x).parent end
    return table.concat(parts, ".")
end
function IM.ClearAllChildren(o) for _, c in ipairs(IM.GetChildren(o)) do c.Parent = nil end end
function IM.GetPivot(o) return M.CFrame.new(o.Position) end

function M.remote(name, parent, kind)
    local r = M.inst(kind or "RemoteEvent", name)
    local d = d_of(r)
    d.props.OnClientEvent = M.signal()
    d.props.FireServer = function(self, ...) if d.on_fire then d.on_fire(...) end end
    d.props.FireAllClients = function() end
    if parent then r.Parent = parent end
    return r
end
function M.on_fire(r, fn) d_of(r).on_fire = fn end
function M.bindable(name, parent)
    local b = M.inst("BindableEvent", name)
    local sig = M.signal()
    d_of(b).props.Event = sig
    d_of(b).props.Fire = function(self, ...) sig:Fire(...) end
    if parent then b.Parent = parent end
    return b
end
function M.folder(name, parent)
    local f = M.inst("Folder", name)
    if parent then f.Parent = parent end
    return f
end

---------------------------------------------------------------- Enum
local function enum_item(cat, item) return { __enum = true, Name = item, EnumType = cat, Value = 0 } end
M.Enum = setmetatable({}, { __index = function(t, cat)
    local c = setmetatable({}, { __index = function(ct, item)
        local e = enum_item(cat, item)
        rawset(ct, item, e)
        return e
    end })
    rawset(t, cat, c)
    return c
end })

---------------------------------------------------------------- libs
function M.make_table_lib()
    local t = {}
    for k, v in pairs(table) do t[k] = v end
    t.unpack = t.unpack or unpack
    t.pack = pack
    t.clone = function(src) local o = {}; for k, v in pairs(src) do o[k] = v end; return setmetatable(o, getmetatable(src)) end
    t.create = function(n, v) local o = {}; if v ~= nil then for i = 1, n do o[i] = v end end; return o end
    t.clear = function(x) for k in pairs(x) do x[k] = nil end end
    t.find = function(x, v) for i, y in ipairs(x) do if y == v then return i end end; return nil end
    t.freeze = function(x) return x end
    t.isfrozen = function() return false end
    return t
end
function M.make_math_lib(rng)
    local m = {}
    for k, v in pairs(math) do m[k] = v end
    m.clamp = function(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end; return x end
    m.sign = function(x) if x > 0 then return 1 elseif x < 0 then return -1 end; return 0 end
    m.round = function(x) return math.floor(x + 0.5) end
    if rng then
        m.random = function(a, b)
            if a == nil then return rng() end
            if b == nil then return math.floor(rng() * a) + 1 end
            return a + math.floor(rng() * (b - a + 1))
        end
        m.randomseed = function() end
    end
    return m
end
local bit = require("bit")
M.bit32 = {
    bxor = function(...) local r = bit.bxor(...); if r < 0 then r = r + 4294967296 end; return r end,
    band = function(...) local r = bit.band(...); if r < 0 then r = r + 4294967296 end; return r end,
    bor = function(...) local r = bit.bor(...); if r < 0 then r = r + 4294967296 end; return r end,
    lshift = bit.lshift, rshift = bit.rshift,
}

return M
