-- Basalt 2.5.0-dev, single-file build made by tools/bundle.lua
-- Source: https://github.com/mindbound/Basalt2
-- Commit: d436223dd1fd74ab7bdb64694a680d972cc86357
-- Elements: Canvas, Collection, Frame, Input, Label, List
-- Added as dependencies: Collection (List, require)
-- Modules: none
--
-- MIT License
--
-- Copyright (c) 2025 Pyroxenium
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
local sources = {}
sources["main"] = [=[
local require = ...
if type(require) ~= "function" then
    local name, path = ...
    local initPath = fs.combine(fs.getDir(path or "basalt/main.lua"), "init.lua")
    return assert(loadfile(initPath, nil, _ENV))(name, initPath)
end
local errors = require("core/errors")
local palette = require("core/palette")
local reactive = require("core/reactive")
local state = require("core/state")
local layout = require("core/layout")
local Container = require("core/container")
local BaseFrame = require("core/baseframe")
Container.register("Label", require("elements/Label"))
Container.register("Canvas", require("elements/Canvas"))
Container.register("Frame", require("elements/Frame"))
Container.register("Input", require("elements/Input"))
Container.register("Collection", require("elements/Collection"))
Container.register("List", require("elements/List"))
local basalt = {}
basalt.VERSION = "2.5.0-dev"
basalt.traceback = true
basalt.errors = errors
basalt.text = require("core/text")
basalt.rgb = palette.rgb
basalt.state = state.create
basalt.signal = state.create
basalt.computed = state.computed
basalt.isState = state.is
basalt.auto = layout.auto
basalt.fill = layout.fill
basalt.percent = layout.percent
function basalt.setReactiveStrings(enabled)
    if type(enabled) ~= "boolean" then
        error("Basalt: setReactiveStrings expects a boolean", 2)
    end
    reactive.setEnabled(enabled)
end
function basalt.getReactiveStrings()
    return reactive.isEnabled()
end
function basalt.literal(value)
    return reactive.literal(value)
end
function basalt.use(moduleName)
    return require("modules/" .. moduleName)
end
local frames = {}
local mainFrame = nil
local running = false
local inRun = false
local schedules = {}
local onTerminate = nil
function basalt.createFrame(t, monitorName)
    t = t or term.current()
    local f = BaseFrame.new()
    f:setTerm(t)
    if monitorName == nil and t.setTextScale and peripheral then
        local ok, name = pcall(peripheral.getName, t)
        if ok then monitorName = name end
    end
    rawset(f, "monitor", monitorName)
    frames[#frames + 1] = f
    if not mainFrame then mainFrame = f end
    return f
end
function basalt.getMainFrame()
    return mainFrame or basalt.createFrame()
end
local function raiseFrom(co, err)
    if type(err) == "table" and err.__basaltError then error(err, 0) end
    error(errors.wrap(err, debug.traceback(co)), 0)
end
local scheduledCos = setmetatable({}, { __mode = "k" })
function basalt.schedule(fn, options)
    if options ~= nil and type(options) ~= "table" then
        error("Basalt: schedule options must be a table", 2)
    end
    local co = coroutine.create(fn)
    scheduledCos[co] = true
    local ok, filter = coroutine.resume(co)
    if not ok then raiseFrom(co, filter) end
    schedules[#schedules + 1] = {
        co = co,
        filter = filter,
        ignoreTerminate = options ~= nil and options.ignoreTerminate == true,
    }
    return co
end
local function isTerminationError(err)
    local message = tostring(err)
    return message == "Terminated" or message:match(": Terminated$") ~= nil
end
local function resumeSchedules(event, ...)
    local terminate = event == "terminate"
    local cancel = terminate and onTerminate ~= nil
    for i = #schedules, 1, -1 do
        local s = schedules[i]
        if coroutine.status(s.co) == "suspended"
            and not (terminate and s.ignoreTerminate)
            and (s.filter == nil or s.filter == event or cancel) then
            local ok, filter = coroutine.resume(s.co, event, ...)
            if ok then
                s.filter = filter
            elseif not (cancel and isTerminationError(filter)) then
                raiseFrom(s.co, filter)
            end
        end
        if coroutine.status(s.co) == "dead" then
            table.remove(schedules, i)
        end
    end
end
local MOUSE = {
    mouse_click = true,
    mouse_up = true,
    mouse_drag = true,
    mouse_scroll = true,
    mouse_move = true,
}
local KEY = { key = true, key_up = true, char = true, paste = true }
local function focusedTakesTerminate()
    local focused = mainFrame and mainFrame:getFocused()
    if focused and focused ~= mainFrame then
        return focused:handleTerminate() == true
    end
    return false
end
local function dispatch(event, a, b, c, ...)
    if event == "terminate" then
        for i = 1, #frames do
            frames[i]:handleEvent(event, a, b, c, ...)
        end
        if focusedTakesTerminate() then return end
        resumeSchedules(event, a, b, c, ...)
        if onTerminate then onTerminate() end
        return
    elseif event == "mouse_move" and type(a) == "string" then
        for i = 1, #frames do
            local f = frames[i]
            if rawget(f, "monitor") == a then
                f:handleEvent(event, b, c)
            end
        end
    elseif MOUSE[event] or KEY[event] then
        if mainFrame then mainFrame:handleEvent(event, a, b, c, ...) end
    elseif event == "monitor_touch" or event == "monitor_resize" then
        for i = 1, #frames do
            local f = frames[i]
            if rawget(f, "monitor") == a then
                if event == "monitor_touch" then
                    f:handleEvent("mouse_click", 1, b, c)
                    f:handleEvent("mouse_up", 1, b, c)
                else
                    f:handleEvent("term_resize")
                end
            end
        end
    else
        for i = 1, #frames do
            frames[i]:handleEvent(event, a, b, c, ...)
        end
    end
    resumeSchedules(event, a, b, c, ...)
end
local function syncFrameSizes()
    for i = 1, #frames do
        local f = frames[i]
        local r = rawget(f, "_render")
        local w, h = rawget(f, "term").getSize()
        if w ~= r.width or h ~= r.height then
            f:handleEvent("term_resize")
        end
    end
end
local drawing = false
local repaintPending = false
local function drawFrames(onScreenOnly)
    for i = 1, #frames do
        local f = frames[i]
        local r = rawget(f, "_render")
        if not (onScreenOnly and r.released) then
            r:resetClip()
            f:draw()
        end
    end
end
local function onDrawError(e)
    local scheduled = scheduledCos[coroutine.running() or false]
    if (inRun or scheduled) and not (type(e) == "table" and e.__basaltError) then
        return errors.wrap(e, debug.traceback(nil, 2))
    end
    return e
end
local function draw(onScreenOnly)
    drawing = true
    local ok, err = xpcall(function()
        drawFrames(onScreenOnly)
        if repaintPending then
            repaintPending = false
            syncFrameSizes()
            drawFrames(true)
        end
    end, onDrawError)
    drawing = false
    repaintPending = false
    if not ok then error(err, 0) end
end
function basalt.update(event, ...)
    if event then dispatch(event, ...) end
    draw()
end
function basalt.stop()
    running = false
end
local function cleanup()
    for i = 1, #frames do
        local f = frames[i]
        local r = rawget(f, "_render")
        if not (r and r.released) then
            f:cleanup()
            r = rawget(f, "_render")
            if r then r.released = true end
        end
    end
    palette.resume(true)
end
local function repaint()
    if not drawing then syncFrameSizes() end
    for i = 1, #frames do
        local f = frames[i]
        rawget(f, "_render"):invalidate()
        f:markRenderDirty()
    end
    if drawing then
        repaintPending = true
    else
        draw(true)
    end
end
function basalt.cleanup()
    cleanup()
end
function basalt.repaint()
    repaint()
end
function basalt.suspendPalette()
    if palette.suspend() then repaint() end
end
function basalt.resumePalette()
    if palette.resume() then repaint() end
end
function basalt.isPaletteSuspended()
    return palette.isSuspended()
end
function basalt.run(options)
    if running then error("Basalt is already running", 2) end
    if options ~= nil and type(options) ~= "table" then
        error("Basalt: run options must be a table", 2)
    end
    local handler = options and options.onTerminate
    if handler ~= nil and type(handler) ~= "function" then
        error("Basalt: run option onTerminate must be a function", 2)
    end
    running = true
    inRun = true
    onTerminate = handler
    local ok, err = xpcall(function()
        syncFrameSizes()
        draw()
        while running do
            local ev = table.pack(os.pullEventRaw())
            if ev[1] == "terminate" and not onTerminate then
                running = false
            else
                dispatch(table.unpack(ev, 1, ev.n))
                draw()
            end
        end
    end, function(e)
        if type(e) == "table" and e.__basaltError then return e end
        return errors.wrap(e, debug.traceback(nil, 2))
    end)
    running = false
    inRun = false
    onTerminate = nil
    cleanup()
    if not ok then
        errors.show(err.err, err.trace, basalt.traceback)
    end
end
return basalt
]=]
sources["core/baseframe"] = [=[

local require = ...
local class = require("core/class")
local Container = require("core/container")
local Render = require("core/render")
local state = require("core/state")
local BaseFrame = class.create("BaseFrame", Container)
class.property(BaseFrame, "background", colors.black)
function BaseFrame:setup()
    Container.setup(self)
    rawset(self, "_keysDown", {})
end
function BaseFrame:isKeyDown(keyCode)
    return rawget(self, "_keysDown")[keyCode] == true
end
function BaseFrame:setTerm(t)
    local old = rawget(self, "_render")
    local render = Render.new(t)
    if old then
        if rawget(self, "term") == t then
            render.mapper = old.mapper
        else
            old.mapper:restore()
        end
    end
    rawset(self, "term", t)
    rawset(self, "_render", render)
    local w, h = t.getSize()
    self._p.width, self._p.height = w, h
    self:markDirty()
    return self
end
function BaseFrame:draw()
    if not rawget(self, "_dirty") then return end
    self._render:setCursor(1, 1, false)
    for _ = 1, 2 do
        rawset(self, "_dirty", false)
        state.clearWatcher(self)
        self:render(self._render)
        if not rawget(self, "_dirty") then break end
    end
    self._render:flush()
end
function BaseFrame:setFocused(el)
    local old = rawget(self, "_focused")
    if old == el then return end
    rawset(self, "_focused", el)
    local r = rawget(self, "_render")
    if r then r:setCursor(1, 1, false) end
    if old and old ~= self then old:fire("blur") end
    if el and el ~= self and rawget(self, "_focused") == el then
        el:fire("focus")
    end
    self:markDirty()
end
function BaseFrame:setCursor(x, y, blink, color)
    local r = rawget(self, "_render")
    if r then r:setCursor(x, y, blink, color) end
    return self
end
function BaseFrame:getFocused()
    return rawget(self, "_focused")
end
function BaseFrame:_updateHovered(x, y)
    local hit = self:findAt(x, y)
    local hovered = hit ~= self and hit or nil
    local old = rawget(self, "_hovered")
    if old == hovered then return end
    rawset(self, "_hovered", hovered)
    if old then
        old:setState("hover", false)
        old:fire("mouseLeave")
    end
    if hovered then
        hovered:setState("hover", true)
        hovered:fire("mouseEnter")
    end
end
local function isInside(el, ancestor)
    while el do
        if el == ancestor then return true end
        el = rawget(el, "parent")
    end
    return false
end
function BaseFrame:_releaseSubtree(el, keepHover)
    local focused = rawget(self, "_focused")
    if focused and isInside(focused, el) then self:setFocused(nil) end
    local clicked = rawget(self, "_clicked")
    if clicked and isInside(clicked, el) then
        clicked:setState("pressed", false)
        rawset(self, "_clicked", false)
    end
    local hovered = rawget(self, "_hovered")
    if not keepHover and hovered and isInside(hovered, el) then
        hovered:setState("hover", false)
        hovered:fire("mouseLeave")
        rawset(self, "_hovered", nil)
    end
end
function BaseFrame:handleEvent(event, a, b, c)
    if event == "key" then
        rawget(self, "_keysDown")[a] = true
    elseif event == "key_up" then
        rawget(self, "_keysDown")[a] = nil
    end
    if event == "mouse_click" then
        self:_updateHovered(b, c)
        rawset(self, "_clicked", self:handleMouse(event, a, b, c))
    elseif event == "mouse_move" then
        local x, y = a, b
        if c ~= nil then x, y = b, c end
        if type(x) == "number" and type(y) == "number" then
            self:_updateHovered(x, y)
        end
    elseif event == "mouse_up" or event == "mouse_drag" then
        self:_updateHovered(b, c)
        local el = rawget(self, "_clicked")
        if el then
            local ax, ay = el:getAbsolutePosition()
            if event == "mouse_up" then
                el:setState("pressed", false)
                el:fire("clickUp", a, b - ax + 1, c - ay + 1)
                rawset(self, "_clicked", false)
            else
                el:fire("drag", a, b - ax + 1, c - ay + 1)
            end
        end
    elseif event == "mouse_scroll" then
        self:handleMouse(event, a, b, c)
        self:_updateHovered(b, c)
    elseif event == "key" or event == "key_up" or event == "char"
        or event == "paste" then
        local f = rawget(self, "_focused")
        if f and f ~= self then f:handleKey(event, a, b) end
    elseif event == "term_resize" then
        local w, h = self.term.getSize()
        self._p.width, self._p.height = w, h
        self._render:resize(w, h)
        self:markDirty()
    end
end
function BaseFrame:cleanup()
    local r = rawget(self, "_render")
    if r then r.mapper:restore() end
    local t = rawget(self, "term")
    if t then
        t.setBackgroundColor(colors.black)
        t.setTextColor(colors.white)
        t.clear()
        t.setCursorPos(1, 1)
        t.setCursorBlink(false)
    end
    if r then
        r:resize(r.width, r.height)
        self:markRenderDirty()
    end
end
return BaseFrame
]=]
sources["core/class"] = [=[

local require = ...
local reactive = require("core/reactive")
local state = require("core/state")
local layout = require("core/layout")
local class = {}
local unpack = table.unpack or unpack
local function syncMirroredState(t, prop, value)
    if prop.state and t.setState then
        local active = prop.stateWhen and prop.stateWhen(value, t) or not not value
        t:setState(prop.state, active)
    end
end
local function resolveSpecValue(t, prop, value)
    if state.is(value) then
        value = state.read(value, t)
    elseif type(value) == "function" and not prop.rawFunction then
        value = state.withWatcher(t, value, t)
    end
    if type(value) == "table" then value = reactive.unwrap(value) end
    syncMirroredState(t, prop, value)
    return value
end
local function capitalize(s)
    return s:sub(1, 1):upper() .. s:sub(2)
end
function class.create(name, parent)
    local c = {}
    c.__name = name
    c.__parent = parent
    c.__props = setmetatable({}, parent and { __index = parent.__props } or nil)
    c.__defaults = setmetatable({}, parent and { __index = parent.__defaults } or nil)
    c.__stateStyles = {}
    c.__pmeta = { __index = c.__defaults }
    if parent then setmetatable(c, { __index = parent }) end
    c.__getPropertySpec = function(t, k)
        local prop = c.__props[k]
        if not prop then return false end
        local resolver = c.__stateResolver
        if prop.styleable and resolver then
            local found, stateValue = resolver(t, k, c)
            if found then
                return true, resolveSpecValue(t, prop, stateValue), prop
            end
        end
        local value = rawget(t, "_p")[k]
        if value ~= nil then
            return true, resolveSpecValue(t, prop, value), prop
        end
        return false
    end
    c.__meta = {
        __index = function(t, k)
            local box = rawget(t, "_layoutBox")
            if box and box[k] ~= nil then return box[k] end
            local found, value = c.__getPropertySpec(t, k)
            if found then
                if layout.is(value) then
                    return layout.resolveToken(value, t, k)
                end
                return value
            end
            return c[k]
        end,
        __newindex = function(t, k, v)
            local prop = c.__props[k]
            if prop then
                if type(v) == "string" then
                    if not prop.rawString and reactive.isEnabled()
                        and reactive.isExpression(v) then
                        v = reactive.compile(v, t)
                    end
                elseif type(v) == "table" then
                    v = reactive.unwrap(v)
                end
                local p = rawget(t, "_p")
                local old = p[k]
                if old ~= v then
                    p[k] = v
                    if (type(v) == "function" and not prop.rawFunction)
                        or state.is(v) then
                        if prop.visual then
                            if t.invalidateLayout then t:invalidateLayout(k) end
                            if t.markRenderDirty then
                                t:markRenderDirty()
                            else
                                t:markDirty()
                            end
                        end
                    else
                        if prop.onChange then prop.onChange(t, v, old) end
                        syncMirroredState(t, prop, v)
                        if prop.visual then
                            if t.invalidateLayout then t:invalidateLayout(k) end
                            if t.markRenderDirty then
                                t:markRenderDirty()
                            else
                                t:markDirty()
                            end
                        end
                    end
                end
            else
                rawset(t, k, v)
            end
        end,
        __tostring = function(t)
            return name
        end,
    }
    c.new = function(props)
        local self = setmetatable({
            _p = setmetatable({}, c.__pmeta),
            _handlers = {},
            _class = c,
        }, c.__meta)
        self:setup()
        if props then self:apply(props) end
        return self
    end
    return c
end
function class.property(c, propName, default, opts)
    opts = opts or {}
    c.__props[propName] = {
        visual = opts.visual ~= false,
        onChange = opts.onChange,
        rawFunction = opts.rawFunction,
        rawString = opts.rawString,
        state = opts.state,
        stateWhen = opts.stateWhen,
        styleable = opts.styleable ~= false,
    }
    c.__defaults[propName] = reactive.unwrap(default)
    local cap = capitalize(propName)
    c["set" .. cap] = function(self, v)
        self[propName] = v
        return self
    end
    c["get" .. cap] = function(self)
        return self[propName]
    end
end
function class.combinedProperty(c, combinedName, propertyNames)
    if type(combinedName) ~= "string" or combinedName == "" then
        error("Basalt class: combined property name must be a non-empty string", 2)
    end
    if type(propertyNames) ~= "table" or #propertyNames == 0 then
        error("Basalt class: combined property list must not be empty", 2)
    end
    local names = {}
    for i = 1, #propertyNames do
        local propName = propertyNames[i]
        if type(propName) ~= "string" or c.__props[propName] == nil then
            error("Basalt class: unknown property '" .. tostring(propName)
                .. "' in combined property " .. combinedName, 2)
        end
        names[i] = propName
    end
    local setterName = "set" .. combinedName
    local getterName = "get" .. combinedName
    local rawGetterName = "getRaw" .. combinedName
    c[setterName] = function(self, ...)
        local values = table.pack(...)
        if values.n ~= #names then
            error("Basalt: " .. setterName .. " expects " .. #names
                .. " values, got " .. values.n, 2)
        end
        for i = 1, #names do self[names[i]] = values[i] end
        return self
    end
    c[getterName] = function(self)
        local values = { n = #names }
        for i = 1, #names do values[i] = self[names[i]] end
        return unpack(values, 1, values.n)
    end
    c[rawGetterName] = function(self)
        local values = { n = #names }
        for i = 1, #names do values[i] = self:raw(names[i]) end
        return unpack(values, 1, values.n)
    end
end
function class.event(c, eventName)
    c["on" .. capitalize(eventName)] = function(self, fn)
        return self:on(eventName, fn)
    end
end
return class
]=]
sources["core/collection"] = [=[
local require = ...
local class = require("core/class")
local CollectionEntry = require("core/collectionentry")
local reactive = require("core/reactive")
local methods = {}
local collection = { methods = methods }
local function indexOf(self, value)
    if type(value) == "number" then
        local index = math.floor(value)
        return self.items[index] and index or nil
    end
    for i, entry in ipairs(self.items) do
        if entry == value then return i end
    end
end
local function eligible(entry)
    return entry and entry.selectable ~= false and entry.disabled ~= true
        and entry.separator ~= true
end
local function selectedSnapshot(self)
    local index = self:getSelectedIndex()
    return index, index and self.items[index] or nil
end
local function syncSelected(self)
    local index = self:getSelectedIndex() or false
    rawget(self, "_p").selected = index
    self:setState("selected", index ~= false)
end
local function fireChange(self, oldIndex, oldItem)
    syncSelected(self)
    local index, item = selectedSnapshot(self)
    local eventName = rawget(self, "_collectionChangeEvent")
    if eventName then self:fire(eventName, index or false, item, oldIndex or false, oldItem) end
    self:markDirty()
end
local function normalize(self, item)
    item = reactive.unwrap(item)
    if CollectionEntry.is(item) then
        if rawget(item, "_parent") == self then return item end
        item = item:getData()
    end
    return CollectionEntry.new(self, item)
end
local function replaceItems(self, values, oldItems)
    if type(values) ~= "table" then
        error("Basalt Collection: items must be a table", 3)
    end
    local oldIndex, oldItem
    local selected = rawget(self, "_collectionSelection")
    if type(oldItems) == "table" then
        for i, entry in ipairs(oldItems) do
            if selected[entry] then oldIndex, oldItem = i, entry break end
        end
    end
    if type(oldItems) == "table" then
        for _, entry in ipairs(oldItems) do
            if CollectionEntry.is(entry) then rawset(entry, "_parent", nil) end
        end
    end
    local items = {}
    local newSelection = {}
    for i, item in ipairs(values) do
        local wantsSelection = type(item) == "table" and not CollectionEntry.is(item)
            and item.selected == true
        items[i] = normalize(self, item)
        local data = items[i]:getData()
        data.selected = nil
        if wantsSelection and (self.multiSelection or next(newSelection) == nil) then
            newSelection[items[i]] = true
        end
    end
    rawget(self, "_p").items = items
    rawset(self, "_collectionSelection", newSelection)
    if oldItem or next(newSelection) then
        fireChange(self, oldIndex, oldItem)
    else
        syncSelected(self)
        self:markDirty()
    end
    if self.setOffset and self.offset ~= nil then self:setOffset(self.offset) end
end
local function ensureProperty(c, name, default, options)
    if c.__props[name] == nil then class.property(c, name, default, options) end
end
function collection.install(c, options)
    options = options or {}
    ensureProperty(c, "items", false, {
        onChange = function(self, value, old)
            if rawget(self, "_collectionSelection") then replaceItems(self, value, old) end
        end,
    })
    ensureProperty(c, "selectable", true)
    ensureProperty(c, "multiSelection", false, {
        onChange = function(self, enabled)
            if enabled or not rawget(self, "_collectionSelection") then return end
            local first = self:getSelectedItem()
            local selected = rawget(self, "_collectionSelection")
            for entry in pairs(selected) do selected[entry] = entry == first or nil end
            syncSelected(self)
        end,
    })
    ensureProperty(c, "selected", false, {
        styleable = false,
        onChange = function(self, value)
            if not rawget(self, "_collectionSelection") then return end
            if value == false or value == nil then
                self:clearItemSelection()
            else
                self:selectItem(value)
            end
        end,
    })
    ensureProperty(c, "selectionBackground", colors.blue)
    ensureProperty(c, "selectionForeground", colors.white)
    class.event(c, "select")
    local changeEvent
    if options.changeEvent ~= false then
        changeEvent = options.changeEvent or "change"
    end
    if changeEvent then class.event(c, changeEvent) end
    c.setSelectedBackground = function(self, value)
        self.selectionBackground = value
        return self
    end
    c.getSelectedBackground = function(self) return self.selectionBackground end
    c.setSelectedForeground = function(self, value)
        self.selectionForeground = value
        return self
    end
    c.getSelectedForeground = function(self) return self.selectionForeground end
    c.setSelectionColor = function(self, foreground, background)
        self.selectionForeground = foreground
        self.selectionBackground = background
        return self
    end
    c.getSelectionColor = function(self)
        return self.selectionForeground, self.selectionBackground
    end
    c._collectionChangeEventName = changeEvent
    for name, method in pairs(collection.methods) do c[name] = method end
end
function collection.setup(self)
    rawset(self, "_collectionSelection", {})
    rawset(self, "_collectionChangeEvent", self._class._collectionChangeEventName)
    local initial = rawget(self, "_p").items
    local items = {}
    if type(initial) == "table" then
        for i, item in ipairs(initial) do items[i] = normalize(self, item) end
    end
    rawget(self, "_p").items = items
    syncSelected(self)
end
function methods:indexOfItem(value)
    return indexOf(self, value)
end
function methods:getItem(index)
    return self.items[index]
end
function methods:getItemCount()
    return #self.items
end
function methods:addItem(item)
    local wantsSelection = type(item) == "table" and not CollectionEntry.is(item)
        and item.selected == true
    local entry = normalize(self, item)
    entry:getData().selected = nil
    self.items[#self.items + 1] = entry
    if wantsSelection then self:selectItem(entry) end
    self:markDirty()
    return entry
end
function methods:insertItem(index, item)
    index = math.max(1, math.min(#self.items + 1, math.floor(index)))
    local entry = normalize(self, item)
    local wantsSelection = entry:getData().selected == true
    entry:getData().selected = nil
    table.insert(self.items, index, entry)
    if wantsSelection then self:selectItem(entry) end
    syncSelected(self)
    self:markDirty()
    return entry
end
function methods:removeItem(value)
    local index = indexOf(self, value)
    if not index then return self end
    local oldIndex, oldItem = selectedSnapshot(self)
    local entry = table.remove(self.items, index)
    local selected = rawget(self, "_collectionSelection")
    local changed = selected[entry] == true
    selected[entry] = nil
    rawset(entry, "_parent", nil)
    if changed then fireChange(self, oldIndex, oldItem) else syncSelected(self) end
    self:markDirty()
    return self
end
function methods:clear()
    local oldIndex, oldItem = selectedSnapshot(self)
    for _, entry in ipairs(self.items) do rawset(entry, "_parent", nil) end
    rawget(self, "_p").items = {}
    rawset(self, "_collectionSelection", {})
    if oldItem then fireChange(self, oldIndex, oldItem) else syncSelected(self) end
    self:markDirty()
    return self
end
function methods:clearItems()
    return self:clear()
end
function methods:isItemSelected(value)
    local index = indexOf(self, value)
    return index ~= nil
        and rawget(self, "_collectionSelection")[self.items[index]] == true
end
function methods:isSelected(value)
    return self:isItemSelected(value)
end
function methods:getSelectedItems()
    local result = {}
    local selected = rawget(self, "_collectionSelection")
    for _, entry in ipairs(self.items) do
        if selected[entry] then result[#result + 1] = entry end
    end
    return result
end
function methods:getSelectedItem()
    local selected = rawget(self, "_collectionSelection")
    for _, entry in ipairs(self.items) do
        if selected[entry] then return entry end
    end
end
function methods:getSelectedIndex()
    local selected = rawget(self, "_collectionSelection")
    for i, entry in ipairs(self.items) do
        if selected[entry] then return i end
    end
end
function methods:getSelection()
    local result = {}
    local selected = rawget(self, "_collectionSelection")
    for i, entry in ipairs(self.items) do
        if selected[entry] then result[#result + 1] = i end
    end
    return result
end
function methods:selectItem(value, emit)
    if not self.selectable then return self end
    local index = indexOf(self, value)
    local entry = index and self.items[index]
    if not eligible(entry) then return self end
    local selected = rawget(self, "_collectionSelection")
    local oldIndex, oldItem = selectedSnapshot(self)
    local changed = not selected[entry]
    if not self.multiSelection then
        for current in pairs(selected) do
            if current ~= entry then selected[current], changed = nil, true end
        end
    end
    selected[entry] = true
    if changed then
        if emit == false then syncSelected(self) else fireChange(self, oldIndex, oldItem) end
    end
    return self
end
function methods:unselectItem(value, emit)
    local index = indexOf(self, value)
    local entry = index and self.items[index]
    local selected = rawget(self, "_collectionSelection")
    if not entry or not selected[entry] then return self end
    local oldIndex, oldItem = selectedSnapshot(self)
    selected[entry] = nil
    if emit == false then syncSelected(self) else fireChange(self, oldIndex, oldItem) end
    return self
end
function methods:toggleItem(value, emit)
    if self:isItemSelected(value) then
        return self:unselectItem(value, emit)
    end
    return self:selectItem(value, emit)
end
function methods:clearItemSelection(emit)
    local oldIndex, oldItem = selectedSnapshot(self)
    if not oldItem then return self end
    rawset(self, "_collectionSelection", {})
    if emit == false then syncSelected(self) else fireChange(self, oldIndex, oldItem) end
    return self
end
function methods:clearSelection(emit)
    return self:clearItemSelection(emit)
end
function methods:selectNext(emit)
    local start = self:getSelectedIndex() or 0
    for index = start + 1, #self.items do
        if eligible(self.items[index]) then return self:selectItem(index, emit) end
    end
    return self
end
function methods:selectPrevious(emit)
    local start = self:getSelectedIndex() or (#self.items + 1)
    for index = start - 1, 1, -1 do
        if eligible(self.items[index]) then return self:selectItem(index, emit) end
    end
    return self
end
function methods:scrollToTop()
    if self.setOffset then self:setOffset(0) end
    return self
end
function methods:scrollToBottom()
    if self.setOffset then self:setOffset(math.huge) end
    return self
end
function methods:activateItem(value, emit, toggle)
    local index = indexOf(self, value)
    local entry = index and self.items[index]
    if not self.selectable or not eligible(entry) then return self end
    if toggle then self:toggleItem(entry) else self:selectItem(entry) end
    index = indexOf(self, entry)
    if emit ~= false then
        if type(entry.callback) == "function" then entry.callback(self, entry) end
        self:fire("select", index, entry)
    end
    return self
end
function methods:select(value, emit)
    return self:activateItem(value, emit, self.multiSelection)
end
function methods:_moveCollectionEntry(entry, delta)
    local index = indexOf(self, entry)
    if index then self:_moveCollectionEntryTo(entry, index + delta) end
    return self
end
function methods:_moveCollectionEntryTo(entry, target)
    local index = indexOf(self, entry)
    if not index then return self end
    target = math.max(1, math.min(#self.items, math.floor(target)))
    if target ~= index then
        table.remove(self.items, index)
        table.insert(self.items, target, entry)
        syncSelected(self)
        self:markDirty()
    end
    return self
end
function methods:_swapCollectionEntries(a, b)
    local ai, bi = indexOf(self, a), indexOf(self, b)
    if ai and bi and ai ~= bi then
        self.items[ai], self.items[bi] = self.items[bi], self.items[ai]
        syncSelected(self)
        self:markDirty()
    end
    return self
end
return collection
]=]
sources["core/collectionentry"] = [=[

local methods = {}
local CollectionEntry = {}
CollectionEntry.__index = function(entry, key)
    local method = methods[key]
    if method then return method end
    if key == "selected" then
        local parent = rawget(entry, "_parent")
        return parent and parent:isItemSelected(entry) or false
    end
    local data = rawget(entry, "_data")
    if data and data[key] ~= nil then return data[key] end
    local parent = rawget(entry, "_parent")
    local parentMethod = parent and parent[key]
    if type(parentMethod) == "function" then
        return function(_, ...)
            return parentMethod(parent, ...)
        end
    end
end
CollectionEntry.__newindex = function(entry, key, value)
    if type(key) == "string" and key:sub(1, 1) == "_" then
        rawset(entry, key, value)
        return
    end
    if key == "selected" then
        local parent = rawget(entry, "_parent")
        if parent then
            if value then parent:selectItem(entry) else parent:unselectItem(entry) end
        end
        return
    end
    local data = rawget(entry, "_data")
    if data[key] ~= value then
        data[key] = value
        local parent = rawget(entry, "_parent")
        if parent then parent:markDirty() end
    end
end
CollectionEntry.__tostring = function(entry)
    local data = rawget(entry, "_data")
    if data.text ~= nil then return tostring(data.text) end
    if data.label ~= nil then return tostring(data.label) end
    if data.value ~= nil then return tostring(data.value) end
    return "Entry"
end
function CollectionEntry.new(parent, item)
    local data
    if type(item) == "table" then
        data = item
    else
        data = { text = tostring(item), value = item }
    end
    if data.text == nil and data.label == nil and data.value == nil then
        data.text = "Entry"
    end
    return setmetatable({ _parent = parent, _data = data }, CollectionEntry)
end
function CollectionEntry.is(value)
    return getmetatable(value) == CollectionEntry
end
function methods:getData()
    return rawget(self, "_data")
end
function methods:getParent()
    return rawget(self, "_parent")
end
function methods:setText(text)
    self.text = text
    return self
end
function methods:getText()
    return self.text
end
function methods:getIndex()
    local parent = rawget(self, "_parent")
    return parent and parent:indexOfItem(self) or nil
end
function methods:moveUp(amount)
    local parent = rawget(self, "_parent")
    if parent then parent:_moveCollectionEntry(self, -(amount or 1)) end
    return self
end
function methods:moveDown(amount)
    local parent = rawget(self, "_parent")
    if parent then parent:_moveCollectionEntry(self, amount or 1) end
    return self
end
function methods:moveToTop()
    local parent = rawget(self, "_parent")
    if parent then parent:_moveCollectionEntryTo(self, 1) end
    return self
end
function methods:moveToBottom()
    local parent = rawget(self, "_parent")
    if parent then parent:_moveCollectionEntryTo(self, #parent.items) end
    return self
end
function methods:swapWith(other)
    local parent = rawget(self, "_parent")
    if parent and rawget(other, "_parent") == parent then
        parent:_swapCollectionEntries(self, other)
    end
    return self
end
function methods:remove()
    local parent = rawget(self, "_parent")
    if not parent then return false end
    parent:removeItem(self)
    return true
end
function methods:select()
    local parent = rawget(self, "_parent")
    if parent then parent:selectItem(self) end
    return self
end
function methods:unselect()
    local parent = rawget(self, "_parent")
    if parent then parent:unselectItem(self) end
    return self
end
function methods:isSelected()
    local parent = rawget(self, "_parent")
    return parent and parent:isItemSelected(self) or false
end
return CollectionEntry
]=]
sources["core/container"] = [=[

local require = ...
local class = require("core/class")
local Element = require("core/element")
local state = require("core/state")
local layout = require("core/layout")
local scroll = require("core/scroll")
local Container = class.create("Container", Element)
class.property(Container, "scrollable", false, {
    onChange = function(self, enabled)
        if not enabled then scroll.disable(self) end
    end,
})
class.property(Container, "scrollbar", "auto")
class.property(Container, "scrollXEnabled", true)
class.property(Container, "scrollYEnabled", true)
class.property(Container, "scrollStep", 3)
class.property(Container, "scrollbarColor", colors.gray)
class.property(Container, "scrollbarThumbColor", colors.lightGray)
class.event(Container, "scrollChange")
function Container:setup()
    Element.setup(self)
    rawset(self, "_children", {})
    rawset(self, "_addIndex", 0)
    rawset(self, "_sortDirty", false)
    rawset(self, "_layoutDirty", true)
    rawset(self, "_viewportDirty", true)
    rawset(self, "_visibleChildren", {})
    scroll.setup(self)
end
function Container:getScroll()
    return rawget(self, "_scrollX") or 0, rawget(self, "_scrollY") or 0
end
function Container:getContentSize()
    return rawget(self, "_contentWidth") or 0,
        rawget(self, "_contentHeight") or 0
end
function Container:getScrollInfo()
    local info = scroll.geometry(self)
    info.x, info.y = self:getScroll()
    info.contentWidth, info.contentHeight = self:getContentSize()
    return info
end
function Container:scrollTo(x, y)
    scroll.set(self, x or 0, y or 0)
    return self
end
function Container:scrollBy(dx, dy)
    local x, y = self:getScroll()
    scroll.set(self, x + (dx or 0), y + (dy or 0))
    return self
end
local function descendantBox(container, el)
    local x, y = el.x, el.y
    local p = rawget(el, "parent")
    while p and p ~= container do
        x = x + p.x - 1 - (rawget(p, "_scrollX") or 0)
        y = y + p.y - 1 - (rawget(p, "_scrollY") or 0)
        p = rawget(p, "parent")
    end
    if p ~= container then
        error("Basalt scroll: element is not a descendant of this container", 3)
    end
    return x, y, el.width, el.height
end
function Container:scrollToElement(el)
    local x, y = descendantBox(self, el)
    return self:scrollTo(x - 1, y - 1)
end
function Container:ensureVisible(el)
    local x, y, w, h = descendantBox(self, el)
    local sx, sy = self:getScroll()
    if x < sx + 1 then sx = x - 1 end
    if y < sy + 1 then sy = y - 1 end
    if x + w - 1 > sx + self.width then sx = x + w - 1 - self.width end
    if y + h - 1 > sy + self.height then sy = y + h - 1 - self.height end
    return self:scrollTo(sx, sy)
end
function Container:addChild(child)
    local oldParent = rawget(child, "parent")
    if oldParent then oldParent:removeChild(child) end
    rawset(child, "parent", self)
    self._addIndex = self._addIndex + 1
    rawset(child, "_order", self._addIndex)
    local ch = self._children
    ch[#ch + 1] = child
    self._sortDirty = true
    self:markLayoutDirty()
    return child
end
function Container:removeChild(child)
    local ch = self._children
    for i = 1, #ch do
        if ch[i] == child then
            local root = self:getRoot()
            if root._releaseSubtree then root:_releaseSubtree(child) end
            table.remove(ch, i)
            rawset(child, "parent", nil)
            self:markLayoutDirty()
            return true
        end
    end
    return false
end
function Container:destroy()
    local children = rawget(self, "_children")
    while children and #children > 0 do
        local child = children[#children]
        if child.destroy then child:destroy() end
        if children[#children] == child then self:removeChild(child) end
    end
    Element.destroy(self)
    return self
end
function Container:getChildren()
    return self._children
end
function Container:find(childName)
    local ch = self._children
    for i = 1, #ch do
        if ch[i].name == childName then return ch[i] end
    end
    for i = 1, #ch do
        local c = ch[i]
        if c.find then
            local found = c:find(childName)
            if found then return found end
        end
    end
    return nil
end
local function zLess(a, b)
    local az, bz = a.z, b.z
    if az == bz then return a._order < b._order end
    return az < bz
end
function Container:_sorted()
    if self._sortDirty then
        table.sort(self._children, zLess)
        self._sortDirty = false
        self._viewportDirty = true
    end
    return self._children
end
local function intersectsViewport(child, scrollX, scrollY, width, height)
    local box = rawget(child, "_layoutBox")
    local x = box and box.x or child.x
    local y = box and box.y or child.y
    local w = box and box.width or child.width
    local h = box and box.height or child.height
    if w <= 0 or h <= 0 then return false end
    return x <= scrollX + width and y <= scrollY + height
        and x + w - 1 > scrollX and y + h - 1 > scrollY
end
function Container:_visibleSorted()
    local cached = rawget(self, "_visibleChildren")
    if not rawget(self, "_viewportDirty") and cached then return cached end
    cached = {}
    local scrollX, scrollY = self:getScroll()
    local children = self:_sorted()
    for i = 1, #children do
        local child = children[i]
        if child.visible and intersectsViewport(child, scrollX, scrollY,
            self.width, self.height) then
            cached[#cached + 1] = child
        end
    end
    rawset(self, "_visibleChildren", cached)
    rawset(self, "_viewportDirty", false)
    return cached
end
function Container:render(buf)
    Element.render(self, buf)
    local children = self._children
    if rawget(self, "_layoutDirty") then
        for i = 1, #children do
            local c = children[i]
            state.clearWatcher(c)
            local z = c:raw("z")
            if state.is(z) or type(z) == "function" then
                self._sortDirty = true
            end
        end
        self:fire("layout", self.width, self.height)
        if self.layoutChildren then
            self:layoutChildren()
        else
            layout.resolveFreeChildren(self)
        end
        scroll.update(self)
        rawset(self, "_layoutDirty", false)
        rawset(self, "_viewportDirty", true)
    end
    local scrollX, scrollY = self:getScroll()
    local ch = self:_visibleSorted()
    for i = 1, #ch do
        local c = ch[i]
        if c.visible then
            buf:push(c.x - scrollX, c.y - scrollY, c.width, c.height)
            c:render(buf)
            buf:pop()
        end
    end
    scroll.draw(self, buf)
end
function Container:handleMouse(event, btn, x, y)
    if event == "mouse_click" and scroll.pointerDown(self, x, y) then
        return self
    end
    local scrollX, scrollY = self:getScroll()
    local contentX, contentY = x + scrollX, y + scrollY
    local ch = self:_visibleSorted()
    for i = #ch, 1, -1 do
        local c = ch[i]
        if c.visible and c:contains(contentX, contentY) then
            local hit = c:handleMouse(event, btn,
                contentX - c.x + 1, contentY - c.y + 1)
            if hit then return hit end
        end
    end
    if event == "mouse_scroll" and scroll.wheel(self, btn) then return self end
    return Element.handleMouse(self, event, btn, x, y)
end
function Container:findAt(x, y)
    if scroll.isBarPoint(self, x, y) then return self end
    local scrollX, scrollY = self:getScroll()
    local contentX, contentY = x + scrollX, y + scrollY
    local ch = self:_visibleSorted()
    for i = #ch, 1, -1 do
        local c = ch[i]
        if c.visible and c:contains(contentX, contentY) then
            local lx, ly = contentX - c.x + 1, contentY - c.y + 1
            if c.findAt then
                local hit = c:findAt(lx, ly)
                if hit then return hit end
            end
            return c
        end
    end
    return self
end
function Container.register(elementName, elementClass)
    Container["add" .. elementName] = function(self, props)
        local el = elementClass.new(props)
        self:addChild(el)
        return el
    end
end
return Container
]=]
sources["core/element"] = [=[

local require = ...
local class = require("core/class")
local reactive = require("core/reactive")
local state = require("core/state")
local layout = require("core/layout")
local Element = class.create("Element")
class.property(Element, "x", 1)
class.property(Element, "y", 1)
class.property(Element, "z", 0, {
    onChange = function(self)
        local p = rawget(self, "parent")
        if p then p._sortDirty = true end
    end,
})
class.property(Element, "width", 1)
class.property(Element, "height", 1)
class.property(Element, "minWidth", false)
class.property(Element, "maxWidth", false)
class.property(Element, "minHeight", false)
class.property(Element, "maxHeight", false)
class.property(Element, "position", "flow")
class.property(Element, "alignSelf", false)
class.property(Element, "shrink", false)
class.property(Element, "visible", true, {
    onChange = function(self, visible)
        if not visible then
            local root = self:getRoot()
            if root._releaseSubtree then root:_releaseSubtree(self) end
        end
    end,
})
class.property(Element, "background", false)
class.property(Element, "foreground", colors.white)
class.property(Element, "name", "", { visual = false })
class.property(Element, "disabled", false, {
    state = "disabled",
    styleable = false,
    onChange = function(self, disabled)
        if disabled then
            local root = self:getRoot()
            if root._releaseSubtree then root:_releaseSubtree(self, true) end
        end
    end,
})
class.property(Element, "focusOnClick", true, { visual = false, styleable = false })
class.combinedProperty(Element, "Position", { "x", "y" })
class.combinedProperty(Element, "Size", { "width", "height" })
class.combinedProperty(Element, "Bounds", { "x", "y", "width", "height" })
class.combinedProperty(Element, "Colors", { "foreground", "background" })
class.combinedProperty(Element, "MinSize", { "minWidth", "minHeight" })
class.combinedProperty(Element, "MaxSize", { "maxWidth", "maxHeight" })
class.event(Element, "click")
class.event(Element, "clickUp")
class.event(Element, "drag")
class.event(Element, "scroll")
class.event(Element, "focus")
class.event(Element, "blur")
class.event(Element, "key")
class.event(Element, "keyUp")
class.event(Element, "char")
class.event(Element, "paste")
class.event(Element, "stateChange")
class.event(Element, "mouseEnter")
class.event(Element, "mouseLeave")
class.event(Element, "layout")
local statePriorities = {
    hover = 10,
    focused = 20,
    checked = 30,
    selected = 30,
    pressed = 40,
    disabled = 100,
}
local paintOnlyProperties = {
    disabled = true,
    checked = true,
    selected = true,
    active = true,
    progress = true,
    value = true,
    offset = true,
    horizontalOffset = true,
    replaceChar = true,
    sortable = true,
    sortColumn = true,
    sortDirection = true,
}
local function propertyAffectsLayout(propName)
    if not propName then return true end
    if paintOnlyProperties[propName] then return false end
    local lower = propName:lower()
    if lower:find("color", 1, true)
        or lower:find("background", 1, true)
        or lower:find("foreground", 1, true)
        or lower:find("symbol", 1, true) then
        return false
    end
    return true
end
local function styleAffectsLayout(style)
    if not style then return false end
    for propName in pairs(style) do
        if propertyAffectsLayout(propName) then return true end
    end
    return false
end
local function stateStyleAffectsLayout(self, stateName)
    local localStyle = rawget(self, "_stateStyles")[stateName]
    if styleAffectsLayout(localStyle) then return true end
    local c = rawget(self, "_class")
    while c do
        local styles = rawget(c, "__stateStyles")
        if styles and styleAffectsLayout(styles[stateName]) then return true end
        c = rawget(c, "__parent")
    end
    return false
end
local function statePriority(self, stateName)
    local custom = rawget(self, "_statePriorities")
    return (custom and custom[stateName]) or statePriorities[stateName] or 50
end
local function activeStates(self)
    local cached = rawget(self, "_activeStates")
    if cached then return cached end
    local states, seq = rawget(self, "_states"), rawget(self, "_stateSequence")
    cached = {}
    for stateName, active in pairs(states) do
        if active then cached[#cached + 1] = stateName end
    end
    table.sort(cached, function(a, b)
        local ap, bp = statePriority(self, a), statePriority(self, b)
        if ap ~= bp then return ap > bp end
        return (seq[a] or 0) > (seq[b] or 0)
    end)
    rawset(self, "_activeStates", cached)
    return cached
end
local function classStateValue(c, stateName, propName)
    while c do
        local styles = rawget(c, "__stateStyles")
        local stateStyle = styles and styles[stateName]
        if stateStyle and stateStyle[propName] ~= nil then
            return true, stateStyle[propName]
        end
        c = rawget(c, "__parent")
    end
    return false
end
Element.__stateResolver = function(self, propName, c)
    local styles = rawget(self, "_stateStyles")
    local active = activeStates(self)
    for i = 1, #active do
        local stateName = active[i]
        local localStyle = styles[stateName]
        if localStyle and localStyle[propName] ~= nil then
            return true, localStyle[propName]
        end
        local found, value = classStateValue(c, stateName, propName)
        if found then return true, value end
    end
    return false
end
local function syncFocusedState(self, fromEvent)
    local root = self:getRoot()
    local focused = fromEvent
    if root.getFocused then focused = root:getFocused() == self end
    if self:hasState("focused") ~= focused then
        self:setState("focused", focused)
    end
end
function Element:setup()
    rawset(self, "_states", {})
    rawset(self, "_stateStyles", {})
    rawset(self, "_statePriorities", {})
    rawset(self, "_stateSequence", {})
    rawset(self, "_stateSequenceN", 0)
    rawset(self, "_bindings", {})
    self:on("focus", function(s) syncFocusedState(s, true) end)
    self:on("blur", function(s) syncFocusedState(s, false) end)
end
function Element:setState(stateName, active)
    if type(stateName) ~= "string" or stateName == "" then
        error("Basalt: state name must be a non-empty string", 2)
    end
    active = active ~= false and active ~= nil
    local states = rawget(self, "_states")
    if states[stateName] == active then return self end
    states[stateName] = active
    if active then
        local n = rawget(self, "_stateSequenceN") + 1
        rawset(self, "_stateSequenceN", n)
        rawget(self, "_stateSequence")[stateName] = n
    end
    rawset(self, "_activeStates", nil)
    if stateStyleAffectsLayout(self, stateName) then
        self:markLayoutDirty()
    else
        self:markRenderDirty()
    end
    self:fire("stateChange", stateName, active)
    return self
end
function Element:hasState(stateName)
    return rawget(self, "_states")[stateName] == true
end
function Element:toggleState(stateName)
    return self:setState(stateName, not self:hasState(stateName))
end
function Element:getStates()
    local result = {}
    for stateName, active in pairs(rawget(self, "_states")) do
        if active then result[#result + 1] = stateName end
    end
    table.sort(result)
    return result
end
function Element:setStateStyle(stateName, props, priority)
    if type(props) ~= "table" then
        error("Basalt: state style must be a table", 2)
    end
    local c = rawget(self, "_class")
    local style = {}
    for propName, value in pairs(props) do
        local prop = c.__props[propName]
        if not prop then
            error("Basalt: unknown state style property '" .. tostring(propName) .. "'", 2)
        end
        if not prop.styleable then
            error("Basalt: property '" .. propName .. "' cannot be state-styled", 2)
        end
        style[propName] = value
    end
    rawget(self, "_stateStyles")[stateName] = style
    if priority ~= nil then self:setStatePriority(stateName, priority) end
    if self:hasState(stateName) and styleAffectsLayout(style) then
        self:markLayoutDirty()
    else
        self:markRenderDirty()
    end
    return self
end
function Element:setStatePriority(stateName, priority)
    if type(priority) ~= "number" then
        error("Basalt: state priority must be a number", 2)
    end
    rawget(self, "_statePriorities")[stateName] = priority
    rawset(self, "_activeStates", nil)
    self:markLayoutDirty()
    return self
end
function Element:apply(props)
    for k, v in pairs(props) do
        if type(v) == "function" and k:find("^on%u") and self[k] then
            self[k](self, v)
        else
            self[k] = v
        end
    end
    return self
end
function Element:raw(propName)
    return rawget(self, "_p")[propName]
end
function Element:on(eventName, fn)
    local handlers = rawget(self, "_handlers")
    local hs = handlers[eventName]
    if not hs then
        hs = {}
        handlers[eventName] = hs
    end
    hs[#hs + 1] = fn
    return self
end
function Element:off(eventName, fn)
    local hs = rawget(self, "_handlers")[eventName]
    if not hs then return self end
    for i = #hs, 1, -1 do
        if hs[i] == fn then
            table.remove(hs, i)
            break
        end
    end
    return self
end
local defaultBindingEvents = {
    text = "change",
    checked = "change",
    value = "change",
    selected = "select",
}
function Element:bind(propName, source, options)
    local c = rawget(self, "_class")
    if not c.__props[propName] then
        error("Basalt: cannot bind unknown property '" .. tostring(propName) .. "'", 2)
    end
    if not state.is(source) then
        error("Basalt: bind expects a state or computed value", 2)
    end
    if type(options) == "function" then
        options = { fromState = options }
    else
        options = options or {}
    end
    if type(options) ~= "table" then
        error("Basalt: bind options must be a function or table", 2)
    end
    self:unbind(propName)
    local boundValue = source
    if options.fromState then
        local transform = options.fromState
        if type(transform) ~= "function" then
            error("Basalt: fromState must be a function", 2)
        end
        local el = self
        boundValue = state.computed(function()
            return transform(source:get(), el)
        end)
    end
    local binding = { source = source, value = boundValue }
    local eventName = options.event or defaultBindingEvents[propName]
    local twoWay = options.twoWay ~= false and state.isWritable(source)
        and eventName ~= nil
    if twoWay then
        local toState = options.toState
        if toState ~= nil and type(toState) ~= "function" then
            error("Basalt: toState must be a function", 2)
        end
        local writableSource = source
        binding.event = eventName
        binding.handler = function(_, value, ...)
            if toState then value = toState(value, self, ...) end
            writableSource:set(value)
            self[propName] = boundValue
        end
        self:on(eventName, binding.handler)
    end
    rawget(self, "_bindings")[propName] = binding
    self[propName] = boundValue
    local _ = self[propName]
    return self
end
function Element:unbind(propName, keepCurrent)
    local bindings = rawget(self, "_bindings")
    local binding = bindings and bindings[propName]
    if not binding then return self end
    local current = self[propName]
    if binding.handler then self:off(binding.event, binding.handler) end
    bindings[propName] = nil
    if keepCurrent == false then
        rawget(self, "_p")[propName] = nil
        self:markDirty()
    else
        if type(current) == "string" then
            current = reactive.literal(current)
        end
        self[propName] = current
    end
    return self
end
function Element:fire(eventName, ...)
    local hs = self._handlers[eventName]
    if not hs then return false end
    for i = 1, #hs do
        hs[i](self, ...)
    end
    return true
end
function Element:markDirty()
    return self:markLayoutDirty()
end
function Element:markRenderDirty()
    local n = self
    local p = rawget(n, "parent")
    while p do
        n = p
        p = rawget(n, "parent")
    end
    rawset(n, "_dirty", true)
    return self
end
function Element:invalidateLayout(propName)
    if propName and not propertyAffectsLayout(propName) then return self end
    local n = self
    while n do
        if rawget(n, "_children") then
            rawset(n, "_layoutDirty", true)
            rawset(n, "_viewportDirty", true)
        end
        n = rawget(n, "parent")
    end
    return self
end
function Element:markLayoutDirty()
    self:invalidateLayout()
    return self:markRenderDirty()
end
function Element:contains(px, py)
    local x, y = self.x, self.y
    return px >= x and py >= y and px < x + self.width and py < y + self.height
end
function Element:getRoot()
    local n = self
    while rawget(n, "parent") do
        n = rawget(n, "parent")
    end
    return n
end
function Element:getAbsolutePosition()
    local x, y = self.x, self.y
    local p = rawget(self, "parent")
    while p do
        x = x + p.x - 1 - (rawget(p, "_scrollX") or 0)
        y = y + p.y - 1 - (rawget(p, "_scrollY") or 0)
        p = rawget(p, "parent")
    end
    return x, y
end
function Element:measure(_availableWidth, _availableHeight)
    local w, h = layout.spec(self, "width"), layout.spec(self, "height")
    return type(w) == "number" and w or 1, type(h) == "number" and h or 1
end
function Element:focus()
    if self.disabled then return self end
    local root = self:getRoot()
    if root.setFocused then root:setFocused(self) end
    return self
end
function Element:setCursor(x, y, blink, color)
    local root = self:getRoot()
    if root ~= self and root.setCursor and root.getFocused
        and root:getFocused() == self then
        local ax, ay = self:getAbsolutePosition()
        local cursorX, cursorY = ax + x - 1, ay + y - 1
        local visible = x >= 1 and y >= 1 and x <= self.width and y <= self.height
        local p = rawget(self, "parent")
        while visible and p do
            local px, py = p:getAbsolutePosition()
            if cursorX < px or cursorY < py
                or cursorX >= px + p.width or cursorY >= py + p.height then
                visible = false
            end
            p = rawget(p, "parent")
        end
        if visible then
            root:setCursor(cursorX, cursorY, blink, color)
        else
            root:setCursor(1, 1, false, color)
        end
    end
    return self
end
function Element:destroy()
    local p = rawget(self, "parent")
    if p then p:removeChild(self) end
    return self
end
function Element:render(buf)
    local bg = self.background
    if bg then
        buf:fill(1, 1, self.width, self.height, " ", self.foreground, bg)
    end
end
function Element:handleMouse(event, btn, x, y)
    if self.disabled then return nil end
    if event == "mouse_click" then
        if self.background or self._handlers.click then
            self:setState("pressed", true)
            if self.focusOnClick then self:focus() end
            self:fire("click", btn, x, y)
            return self
        end
    elseif event == "mouse_scroll" then
        if self._handlers.scroll then
            self:fire("scroll", btn, x, y)
            return self
        end
    end
    return nil
end
function Element:handleKey(event, a, b)
    if self.disabled then return end
    if event == "key" then
        self:fire("key", a, b)
    elseif event == "key_up" then
        self:fire("keyUp", a)
    elseif event == "char" then
        self:fire("char", a)
    elseif event == "paste" then
        self:fire("paste", a)
    end
end
function Element:handleTerminate()
    return false
end
return Element
]=]
sources["core/errors"] = [=[

local require, basaltDir = ...
local errors = {}
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end
local function isInternal(file)
    return file == "[C]"
        or file:sub(1, 1) == "("
        or file:find("^reactive{")
        or (basaltDir ~= "" and file:find(basaltDir, 1, true) == 1)
end
function errors.parse(err, trace)
    local msg = tostring(err)
    local file, line, rest = msg:match("^(.-):(%d+): (.*)$")
    local lines = {}
    if trace then
        for tl in trace:gmatch("[^\n]+") do
            tl = trim(tl)
            if tl ~= "" and tl ~= "stack traceback:"
                and not tl:find("in function 'xpcall'", 1, true) then
                lines[#lines + 1] = tl
            end
        end
    end
    local userFile, userLine
    for _, tl in ipairs(lines) do
        local f, l = tl:match("^(.-):(%d+):")
        if f and not isInternal(f) then
            userFile, userLine = f, tonumber(l)
            break
        end
    end
    return {
        message = rest or msg,
        file = file,
        line = line and tonumber(line),
        userFile = userFile,
        userLine = userLine,
        trace = lines,
    }
end
local function cprint(text, color)
    term.setTextColor(color)
    print(text)
end
local function readSourceLine(file, lineNo)
    if not fs.exists(file) or fs.isDir(file) then return nil end
    local h = fs.open(file, "r")
    if not h then return nil end
    local content, n = nil, 0
    repeat
        content = h.readLine()
        n = n + 1
    until n == lineNo or content == nil
    h.close()
    return content
end
function errors.show(err, trace, showTrace)
    local info = errors.parse(err, trace)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    cprint("Basalt Error", colors.red)
    print()
    cprint(info.message, colors.white)
    print()
    local exFile = info.userFile or info.file
    local exLine = info.userLine or info.line
    if exFile and exLine then
        local src = readSourceLine(exFile, exLine)
        cprint("\26 " .. exFile .. ":" .. exLine, colors.cyan)
        if src then cprint("  " .. trim(src), colors.lightGray) end
        print()
    end
    if showTrace ~= false and #info.trace > 0 then
        cprint("Traceback:", colors.gray)
        for i = 1, math.min(#info.trace, 6) do
            local tl = info.trace[i]
            local f = tl:match("^(.-):%d+:")
            cprint("  " .. tl, (f and not isInternal(f))
                and colors.lightGray or colors.gray)
        end
        if #info.trace > 6 then
            cprint("  ... (" .. (#info.trace - 6) .. " more)", colors.gray)
        end
        print()
    end
    cprint("Press any key to exit", colors.orange)
        while true do
            local e = os.pullEventRaw()
        if e == "key" or e == "mouse_click"
            or e == "monitor_touch" or e == "terminate" then
            break
        end
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end
function errors.wrap(err, trace)
    return setmetatable({ __basaltError = true, err = err, trace = trace }, {
        __tostring = function(t) return tostring(t.err) end,
    })
end
return errors
]=]
sources["core/itemview"] = [=[

local itemview = {}
function itemview.maxOffset(count, rows)
    return math.max(0, count - math.max(0, rows))
end
function itemview.clampOffset(offset, count, rows)
    return math.max(0, math.min(math.floor(offset or 0),
        itemview.maxOffset(count, rows)))
end
function itemview.ensureVisible(offset, index, count, rows)
    offset = itemview.clampOffset(offset, count, rows)
    if not index or index < 1 then return offset end
    if index <= offset then offset = index - 1 end
    if index > offset + rows then offset = index - rows end
    return itemview.clampOffset(offset, count, rows)
end
function itemview.geometry(count, rows, offset, mode)
    if mode ~= "auto" and mode ~= "always" and mode ~= "hidden" then
        error("Basalt item scrollbar: expected 'auto', 'always' or 'hidden'", 3)
    end
    rows = math.max(0, math.floor(rows or 0))
    local maximum = itemview.maxOffset(count, rows)
    offset = itemview.clampOffset(offset, count, rows)
    local show = mode ~= "hidden" and rows > 0
        and (mode == "always" or maximum > 0)
    local thumbSize = rows
    local thumbPos = 0
    if show and rows > 0 then
        thumbSize = math.max(1, math.floor(rows * rows / math.max(count, rows)))
        thumbSize = math.min(rows, thumbSize)
        local travel = rows - thumbSize
        thumbPos = maximum > 0
            and math.floor(travel * offset / maximum + 0.5) or 0
    end
    return {
        show = show,
        rows = rows,
        maximum = maximum,
        offset = offset,
        thumbSize = thumbSize,
        thumbPos = thumbPos,
    }
end
function itemview.draw(buf, x, y, geometry, foreground, track, thumb)
    if not geometry.show or geometry.rows <= 0 then return end
    buf:fill(x, y, 1, geometry.rows, " ", foreground, track)
    buf:fill(x, y + geometry.thumbPos, 1, geometry.thumbSize,
        " ", foreground, thumb)
end
function itemview.pointerDown(coordinate, geometry)
    if not geometry.show then return nil, nil end
    local thumbStart = geometry.thumbPos + 1
    if coordinate >= thumbStart
        and coordinate < thumbStart + geometry.thumbSize then
        return geometry.offset, coordinate - thumbStart
    end
    local travel = math.max(1, geometry.rows - geometry.thumbSize)
    local target = math.floor((coordinate - 1 - geometry.thumbSize / 2)
        / travel * geometry.maximum + 0.5)
    return itemview.clampOffset(target,
        geometry.maximum + geometry.rows, geometry.rows), nil
end
function itemview.drag(coordinate, grab, geometry)
    local travel = math.max(1, geometry.rows - geometry.thumbSize)
    local pos = math.max(0, math.min(travel, coordinate - 1 - grab))
    local target = math.floor(pos / travel * geometry.maximum + 0.5)
    return itemview.clampOffset(target,
        geometry.maximum + geometry.rows, geometry.rows)
end
return itemview
]=]
sources["core/layout"] = [=[

local require = ...
local state = require("core/state")
local layout = {}
local Token = {}
Token.__index = Token
Token.__basaltLayoutValue = true
local function token(kind, value)
    return setmetatable({ kind = kind, value = value }, Token)
end
function layout.auto()
    return token("auto")
end
function layout.fill(weight)
    weight = weight or 1
    if type(weight) ~= "number" or weight <= 0 then
        error("Basalt layout: fill weight must be greater than zero", 2)
    end
    return token("fill", weight)
end
function layout.percent(amount)
    if type(amount) ~= "number" or amount < 0 then
        error("Basalt layout: percent must be a non-negative number", 2)
    end
    return token("percent", amount)
end
function layout.is(value)
    local mt = type(value) == "table" and getmetatable(value)
    return mt and mt.__basaltLayoutValue == true or false
end
function layout.spec(el, propName)
    local c = rawget(el, "_class")
    if c and c.__getPropertySpec then
        local found, value = c.__getPropertySpec(el, propName)
        if found then return value end
    end
    return el:raw(propName)
end
local function round(value)
    return math.floor(value + 0.5)
end
local function clamp(value, minimum, maximum)
    if minimum and value < minimum then value = minimum end
    if maximum and value > maximum then value = maximum end
    return math.max(0, round(value))
end
function layout.constrain(el, axis, value)
    local minName = axis == "width" and "minWidth" or "minHeight"
    local maxName = axis == "width" and "maxWidth" or "maxHeight"
    local minimum, maximum = el[minName], el[maxName]
    if minimum == false then minimum = nil end
    if maximum == false then maximum = nil end
    return clamp(value, minimum, maximum)
end
function layout.measure(el, availableWidth, availableHeight)
    if el.measure then return el:measure(availableWidth, availableHeight) end
    return 1, 1
end
function layout.resolveSize(el, axis, spec, availableWidth, availableHeight)
    local available = axis == "width" and availableWidth or availableHeight
    local measuredW, measuredH
    local value
    if layout.is(spec) then
        if spec.kind == "percent" then
            value = available * spec.value
        elseif spec.kind == "fill" then
            value = available
        else
            measuredW, measuredH = layout.measure(el, availableWidth, availableHeight)
            value = axis == "width" and measuredW or measuredH
        end
    else
        value = tonumber(spec) or 1
    end
    return layout.constrain(el, axis, value)
end
function layout.resolveToken(value, el, propName)
    local parent = rawget(el, "parent")
    local availableWidth = parent and parent.width or 1
    local availableHeight = parent and parent.height or 1
    if value.kind == "fill" and parent then
        if propName == "width" then
            availableWidth = math.max(0, availableWidth - (tonumber(layout.spec(el, "x")) or 1) + 1)
        elseif propName == "height" then
            availableHeight = math.max(0, availableHeight - (tonumber(layout.spec(el, "y")) or 1) + 1)
        end
    end
    return layout.resolveSize(el, propName, value, availableWidth, availableHeight)
end
function layout.resolveFreeChild(parent, child)
    local xSpec, ySpec = layout.spec(child, "x"), layout.spec(child, "y")
    local wSpec, hSpec = layout.spec(child, "width"), layout.spec(child, "height")
    local hasToken = layout.is(xSpec) or layout.is(ySpec)
        or layout.is(wSpec) or layout.is(hSpec)
    if not hasToken then
        local old = rawget(child, "_layoutBox")
        rawset(child, "_layoutBox", nil)
        if old and rawget(child, "_children") then
            rawset(child, "_layoutDirty", true)
            rawset(child, "_viewportDirty", true)
        end
        return
    end
    local pw, ph = parent.width, parent.height
    local x = tonumber(xSpec) or 1
    local y = tonumber(ySpec) or 1
    local aw, ah = math.max(0, pw - x + 1), math.max(0, ph - y + 1)
    local w = layout.resolveSize(child, "width", wSpec, aw, ah)
    local h = layout.resolveSize(child, "height", hSpec, aw, ah)
    local old = rawget(child, "_layoutBox")
    rawset(child, "_layoutBox", { x = round(x), y = round(y), width = w, height = h })
    if rawget(child, "_children") and (not old
        or old.width ~= w or old.height ~= h) then
        rawset(child, "_layoutDirty", true)
        rawset(child, "_viewportDirty", true)
    end
end
function layout.resolveFreeChildren(parent)
    local children = parent:getChildren()
    for i = 1, #children do layout.resolveFreeChild(parent, children[i]) end
end
function layout.setBox(el, x, y, width, height)
    local box = {
        x = round(x), y = round(y),
        width = math.max(0, round(width)),
        height = math.max(0, round(height)),
    }
    local old = rawget(el, "_layoutBox")
    rawset(el, "_layoutBox", box)
    if rawget(el, "_children") and (not old
        or old.width ~= box.width or old.height ~= box.height) then
        rawset(el, "_layoutDirty", true)
        rawset(el, "_viewportDirty", true)
    end
end
return layout
]=]
sources["core/palette"] = [=[

local palette = {}
local floor = math.floor
local char = string.char
local NATIVE_HEX = {
    [0] = 0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2,
    0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
    0x999999, 0x4C99B2, 0xB266E5, 0x3366CC,
    0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
}
local reg = {}
local regCount = 16
local charOf = {}
local dedupe = {}
local function hexToRGB(n)
    return floor(n / 65536) / 255, floor(n / 256) % 256 / 255, (n % 256) / 255
end
for i = 0, 15 do
    reg[i] = { hexToRGB(NATIVE_HEX[i]) }
    charOf[2 ^ i] = char(i)
    dedupe[NATIVE_HEX[i]] = 2 ^ i
end
palette.charOf = charOf
function palette.getRGB(value)
    local index
    if type(value) == "string" then
        index = value:byte()
    elseif charOf[value] then
        index = charOf[value]:byte()
    else
        index = value
    end
    local rgb = reg[index]
    if not rgb then error("Basalt: unknown registry color " .. tostring(value), 2) end
    return rgb[1], rgb[2], rgb[3]
end
local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end
local function parse(r, g, b)
    if type(r) == "string" then
        local hex = r:gsub("#", "")
        if hex:match("^%x%x%x$") then
            hex = hex:gsub("%x", "%0%0")
        elseif hex:match("^%x%x%x%x%x%x%x%x$") then
            hex = hex:sub(3)
        elseif not hex:match("^%x%x%x%x%x%x$") then
            error("Basalt: invalid color string '" .. r
                .. "' (expected #RGB, #RRGGBB or #AARRGGBB)", 3)
        end
        return hexToRGB(tonumber(hex, 16))
    end
    if g == nil then
        if r < 0 or r > 0xFFFFFF or r % 1 ~= 0 then
            error("Basalt: invalid color number "
                .. tostring(r) .. " (expected 0x000000-0xFFFFFF)", 3)
        end
        return hexToRGB(r)
    end
    if b == nil then
        error("Basalt: blue component is required when green is provided", 3)
    end
    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end
    return clamp01(r), clamp01(g), clamp01(b)
end
function palette.rgb(r, g, b)
    local rr, gg, bb = parse(r, g, b)
    local key = floor(rr * 255 + 0.5) * 65536 + floor(gg * 255 + 0.5) * 256 + floor(bb * 255 + 0.5)
    local known = dedupe[key]
    if known then return known end
    if regCount > 255 then
        local best, bestDistance = 0, math.huge
        for index = 0, 255 do
            local rgb = reg[index]
            local distance = (rr - rgb[1]) ^ 2 + (gg - rgb[2]) ^ 2 + (bb - rgb[3]) ^ 2
            if distance < bestDistance then best, bestDistance = index, distance end
        end
        local fallback = best < 16 and 2 ^ best or 0x10000 + best
        dedupe[key] = fallback
        return fallback
    end
    local idx = regCount
    regCount = regCount + 1
    reg[idx] = { rr, gg, bb }
    local handle = 0x10000 + idx
    charOf[handle] = char(idx)
    dedupe[key] = handle
    return handle
end
function palette.hasVirtual()
    return regCount > 16
end
local HEXC = {}
for i = 0, 15 do HEXC[i] = ("%x"):format(i) end
local identity = {}
for i = 0, 15 do identity[char(i)] = HEXC[i] end
palette.identityMap = identity
local HEX2BYTE = {}
for i = 0, 15 do
    HEX2BYTE[HEXC[i]] = char(i)
    HEX2BYTE[HEXC[i]:upper()] = char(i)
end
palette.hexToByte = HEX2BYTE
function palette.windowTranslation(win)
    local getPal = win.getPaletteColour or win.getPaletteColor
    if not getPal then return nil end
    local translate
    for i = 0, 15 do
        local ok, r, g, b = pcall(getPal, 2 ^ i)
        if ok and type(r) == "number" and type(g) == "number"
            and type(b) == "number" then
            local nr, ng, nb = palette.getRGB(2 ^ i)
            if math.abs(r - nr) + math.abs(g - ng) + math.abs(b - nb) > 0.004 then
                if not translate then
                    translate = {}
                    for k, v in pairs(HEX2BYTE) do translate[k] = v end
                end
                local byte = charOf[palette.rgb(r, g, b)]
                translate[HEXC[i]] = byte
                translate[HEXC[i]:upper()] = byte
            end
        end
    end
    return translate
end
local Mapper = {}
Mapper.__index = Mapper
local mappers = setmetatable({}, { __mode = "k" })
local suspendDepth = 0
local savedSlots = setmetatable({}, { __mode = "k" })
local behind = {}
for i = 0, 15 do behind[i] = {} end
local function terminalKey(t)
    if t.setTextScale and peripheral and peripheral.getName then
        local ok, name = pcall(peripheral.getName, t)
        if ok and type(name) == "string" then return "peripheral:" .. name end
    end
    return t
end
local function readSlot(t, slot)
    local getPal = t.getPaletteColour or t.getPaletteColor
    if getPal then
        local ok, r, g, b = pcall(getPal, 2 ^ slot)
        if ok and type(r) == "number" and type(g) == "number"
            and type(b) == "number" then
            return { r, g, b }
        end
    end
    local n = reg[slot]
    return { n[1], n[2], n[3] }
end
local function ownColor(t, slot)
    local shown = readSlot(t, slot)
    local found, bestD = nil, 3 * 0.003 * 0.003
    for i, rgb in pairs(behind[slot]) do
        local c = reg[i]
        local dr, dg, db = c[1] - shown[1], c[2] - shown[2], c[3] - shown[3]
        local d = dr * dr + dg * dg + db * db
        if d < bestD then found, bestD = rgb, d end
    end
    if found then return { found[1], found[2], found[3] } end
    return shown
end
local function override(self, setPal, slot, idx)
    local first = self.overridden[slot] == nil
    local rec = savedSlots[self.key]
    local original = first and not (rec and rec.rgb[slot])
        and ownColor(self.term, slot)
    local c = reg[idx]
    setPal(2 ^ slot, c[1], c[2], c[3])
    if first then
        if not rec then
            rec = { rgb = {}, holders = {} }
            savedSlots[self.key] = rec
        end
        if original then rec.rgb[slot] = original end
        rec.holders[slot] = (rec.holders[slot] or 0) + 1
    end
    behind[slot][idx] = rec and rec.rgb[slot] or behind[slot][idx]
    self.overridden[slot] = idx
end
local function release(self, setPal, slot, always)
    local key = self.key
    local rec = savedSlots[key]
    local holders = rec and rec.holders[slot] or 1
    local rgb = rec and rec.rgb[slot] or reg[slot]
    if setPal and (always or holders <= 1) then
        setPal(2 ^ slot, rgb[1], rgb[2], rgb[3])
    end
    self.overridden[slot] = nil
    if not rec then return end
    if holders > 1 then
        rec.holders[slot] = holders - 1
    else
        rec.holders[slot], rec.rgb[slot] = nil, nil
        if next(rec.holders) == nil then savedSlots[key] = nil end
    end
end
function palette.newMapper(t)
    local mapper = setmetatable({
        term = t,
        key = terminalKey(t),
        overridden = {},
        prevSlot = {},
        prevMap = {},
    }, Mapper)
    mappers[mapper] = true
    return mapper
end
local function dist(a, b)
    local dr, dg, db = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return dr * dr + dg * dg + db * db
end
local function remember(self, map)
    local changed = false
    local prev = self.prevMap
    for k, v in pairs(map) do
        if prev[k] ~= nil and prev[k] ~= v then
            changed = true
            break
        end
    end
    self.prevMap = map
    return changed
end
local function buildSuspended(self, used)
    local map = {}
    for i = 0, 15 do map[char(i)] = HEXC[i] end
    local own
    for idx in pairs(used) do
        if idx > 15 then
            if not own then
                own = {}
                for s = 0, 15 do own[s] = ownColor(self.term, s) end
            end
            local c = reg[idx]
            local best, bestD = 15, math.huge
            for s = 0, 15 do
                local d = dist(c, own[s])
                if d < bestD then best, bestD = s, d end
            end
            map[char(idx)] = HEXC[best]
        end
    end
    return map
end
function Mapper:build(used)
    if suspendDepth > 0 then
        local map = buildSuspended(self, used)
        return map, remember(self, map)
    end
    local t = self.term
    local setPal = t.setPaletteColour or t.setPaletteColor
    local map = {}
    local occupant = {}
    for i = 0, 15 do
        map[char(i)] = HEXC[i]
        if used[i] then
            occupant[i] = i
            if setPal and self.overridden[i] then
                release(self, setPal, i, true)
            end
        end
    end
    local virt = {}
    for idx in pairs(used) do
        if idx > 15 then virt[#virt + 1] = idx end
    end
    if #virt > 0 then
        table.sort(virt)
        local leftovers = {}
        if setPal then
            local rewrite = self.rewrite
            local function assign(idx, slot)
                occupant[slot] = idx
                self.prevSlot[idx] = slot
                if rewrite or self.overridden[slot] ~= idx then
                    override(self, setPal, slot, idx)
                end
                map[char(idx)] = HEXC[slot]
            end
            local pending = {}
            for _, idx in ipairs(virt) do
                local s = self.prevSlot[idx]
                if s and occupant[s] == nil then
                    assign(idx, s)
                else
                    pending[#pending + 1] = idx
                end
            end
            local nextSlot = 0
            for _, idx in ipairs(pending) do
                local slot
                while nextSlot <= 15 do
                    if occupant[nextSlot] == nil then
                        slot = nextSlot
                        break
                    end
                    nextSlot = nextSlot + 1
                end
                if slot then
                    assign(idx, slot)
                else
                    leftovers[#leftovers + 1] = idx
                end
            end
        else
            leftovers = virt
        end
        for _, idx in ipairs(leftovers) do
            local c = reg[idx]
            local best, bestD = 15, math.huge
            for s = 0, 15 do
                local occ = occupant[s]
                local shown = occ and reg[occ] or (not setPal and reg[s] or nil)
                if shown then
                    local d = dist(c, shown)
                    if d < bestD then best, bestD = s, d end
                end
            end
            map[char(idx)] = HEXC[best]
        end
    end
    self.rewrite = nil
    return map, remember(self, map)
end
local function releaseAll(self)
    local t = self.term
    local setPal = t.setPaletteColour or t.setPaletteColor
    for slot in pairs(self.overridden) do
        release(self, setPal, slot, false)
    end
end
function Mapper:restore()
    releaseAll(self)
    self.overridden, self.prevSlot, self.prevMap = {}, {}, {}
end
function Mapper:invalidate()
    self.rewrite = true
end
function palette.suspend()
    suspendDepth = suspendDepth + 1
    if suspendDepth > 1 then return false end
    for mapper in pairs(mappers) do
        releaseAll(mapper)
    end
    return true
end
function palette.resume(all)
    if suspendDepth == 0 then return false end
    suspendDepth = all and 0 or suspendDepth - 1
    return suspendDepth == 0
end
function palette.isSuspended()
    return suspendDepth > 0
end
return palette
]=]
sources["core/reactive"] = [=[

local require = ...
local palette = require("core/palette")
local reactive = {}
local enabled = true
local LiteralMeta = {
    __basaltLiteral = true,
    __tostring = function(marker) return marker.value end,
}
local helpers = {
    colors = colors,
    math = math,
    rgb = palette.rgb,
    tostring = tostring,
    tonumber = tonumber,
    clamp = function(v, lo, hi) return math.min(math.max(v, lo), hi) end,
    round = function(v) return math.floor(v + 0.5) end,
    floor = math.floor,
    ceil = math.ceil,
    abs = math.abs,
    min = math.min,
    max = math.max,
}
function reactive.setEnabled(on)
    enabled = on and true or false
end
function reactive.isEnabled()
    return enabled
end
function reactive.isExpression(value)
    return type(value) == "string" and value:sub(1, 1) == "{"
        and value:sub(-1) == "}"
end
function reactive.literal(value)
    if type(value) ~= "string" then return value end
    return setmetatable({ value = value }, LiteralMeta)
end
function reactive.isLiteral(value)
    local mt = type(value) == "table" and getmetatable(value)
    return mt and mt.__basaltLiteral == true or false
end
function reactive.unwrap(value)
    local mt = type(value) == "table" and getmetatable(value)
    if mt and mt.__basaltLiteral == true then return value.value end
    return value
end
function reactive.compile(str, element)
    local expr = str:sub(2, -2)
    local env = setmetatable({}, {
        __index = function(_, key)
            if key == "self" then return element end
            if key == "parent" then return rawget(element, "parent") end
            local h = helpers[key]
            if h ~= nil then return h end
            local root = element:getRoot()
            if root.find then return root:find(key) end
            return nil
        end,
    })
    local fn, err = load("return " .. expr, "reactive" .. str, "t", env)
    if not fn then
        error("Basalt: invalid reactive expression " .. str
            .. ": " .. tostring(err), 3)
    end
    return fn
end
return reactive
]=]
sources["core/render"] = [=[

local require = ...
local palette = require("core/palette")
local textutil = require("core/text")
local rep, sub, byte = string.rep, string.sub, string.byte
local floor = math.floor
local charOf = palette.charOf
local width, cellSub, normalize = textutil.width, textutil.sub, textutil.normalize
local byteLen, byteCells, cellsOf = textutil.byteLen, textutil.isByteCells, textutil.cells
local isUtf8 = textutil.isUtf8
local function textArg(s)
    local t = type(s)
    if t == "string" then return s end
    if t == "number" then return tostring(s) end
    error("Basalt: text must be a string, got " .. t, 3)
end
local function fitPlane(plane, n)
    if plane and byteLen(plane) > n then
        return sub(plane, 1, n)
    end
    return plane
end
local mosaicChars = {}
local mosaicCache = {}
for mask = 0, 31 do mosaicChars[mask] = string.char(128 + mask) end
local Render = {}
Render.__index = Render
function Render.new(t)
    local self = setmetatable({}, Render)
    self.term = t
    self.mapper = palette.newMapper(t)
    self:resize(t.getSize())
    return self
end
function Render:resize(w, h)
    self.width, self.height = w, h
    self.text, self.fg, self.bg = {}, {}, {}
    self.prevText, self.prevFg, self.prevBg = {}, {}, {}
    local blankT = rep(" ", w)
    local blankF = rep("\0", w)
    local blankB = rep(string.char(15), w)
    for y = 1, h do
        self.text[y], self.fg[y], self.bg[y] = blankT, blankF, blankB
    end
    self.dirty = true
    self.stack = {}
    return self:resetClip()
end
function Render:resetClip()
    self.ox, self.oy = 0, 0
    self.cx1, self.cy1, self.cx2, self.cy2 = 1, 1, self.width, self.height
    self.stackN = 0
    return self
end
function Render:invalidate()
    self.prevText, self.prevFg, self.prevBg = {}, {}, {}
    self.mapper:invalidate()
    self.dirty = true
    return self
end
function Render:push(x, y, w, h)
    local n, s = self.stackN, self.stack
    s[n + 1], s[n + 2], s[n + 3] = self.ox, self.oy, self.cx1
    s[n + 4], s[n + 5], s[n + 6] = self.cy1, self.cx2, self.cy2
    self.stackN = n + 6
    local ox, oy = self.ox + x - 1, self.oy + y - 1
    self.ox, self.oy = ox, oy
    if ox + 1 > self.cx1 then self.cx1 = ox + 1 end
    if oy + 1 > self.cy1 then self.cy1 = oy + 1 end
    if ox + w < self.cx2 then self.cx2 = ox + w end
    if oy + h < self.cy2 then self.cy2 = oy + h end
    return self
end
function Render:pop()
    local n, s = self.stackN, self.stack
    self.ox, self.oy, self.cx1 = s[n - 5], s[n - 4], s[n - 3]
    self.cy1, self.cx2, self.cy2 = s[n - 2], s[n - 1], s[n]
    self.stackN = n - 6
    return self
end
local function splicePlane(line, x, str, n)
    return sub(line, 1, x - 1) .. str .. sub(line, x + n)
end
local function spliceText(line, x, str, n)
    if not isUtf8() or (byteCells(line) and byteCells(str)) then
        return sub(line, 1, x - 1) .. str .. sub(line, x + n)
    end
    local first, last = textutil.span(line, x, x + n - 1)
    return sub(line, 1, first - 1) .. str .. sub(line, last + 1)
end
local function mergeTransparent(source, underneath, mask)
    local out = {}
    for i = 1, byteLen(source) do
        local marker = mask and byte(mask, i) or byte(source, i)
        out[i] = marker == 0 and sub(underneath, i, i) or sub(source, i, i)
    end
    return table.concat(out)
end
local function mergeTransparentText(source, underneath, mask)
    if not isUtf8() or (byteCells(source) and byteCells(underneath)) then
        return mergeTransparent(source, underneath, mask)
    end
    local src, under, out = cellsOf(source), cellsOf(underneath), {}
    for i = 1, #src do
        local marker = mask and byte(mask, i) or byte(src[i], 1)
        out[i] = marker == 0 and (under[i] or " ") or src[i]
    end
    return table.concat(out)
end
local function nearestOf(value, a, b)
    local vr, vg, vb = palette.getRGB(value)
    local ar, ag, ab = palette.getRGB(a)
    local br, bg, bb = palette.getRGB(b)
    local da = (vr - ar) ^ 2 + (vg - ag) ^ 2 + (vb - ab) ^ 2
    local db = (vr - br) ^ 2 + (vg - bg) ^ 2 + (vb - bb) ^ 2
    return da <= db and 0 or 1
end
local function compileMosaic(c1, c2, c3, c4, c5, c6)
    local key = c1 .. c2 .. c3 .. c4 .. c5 .. c6
    local cached = mosaicCache[key]
    if cached then return cached[1], cached[2], cached[3] end
    local values, counts, order = { c1, c2, c3, c4, c5, c6 }, {}, {}
    for i = 1, 6 do
        local value = values[i]
        if counts[value] then counts[value] = counts[value] + 1
        else counts[value], order[#order + 1] = 1, value end
    end
    local a, b
    for _, value in ipairs(order) do
        if not a or counts[value] > counts[a] then b, a = a, value
        elseif not b or counts[value] > counts[b] then b = value end
    end
    if not b then
        cached = { " ", a, a }
        mosaicCache[key] = cached
        return cached[1], cached[2], cached[3]
    end
    local bits = {}
    for i = 1, 6 do
        bits[i] = values[i] == a and 0
            or (values[i] == b and 1 or nearestOf(values[i], a, b))
    end
    local pivot, mask = bits[6], 0
    if bits[1] ~= pivot then mask = mask + 1 end
    if bits[2] ~= pivot then mask = mask + 2 end
    if bits[3] ~= pivot then mask = mask + 4 end
    if bits[4] ~= pivot then mask = mask + 8 end
    if bits[5] ~= pivot then mask = mask + 16 end
    local fg, bg
    if pivot == 0 then fg, bg = b, a else fg, bg = a, b end
    cached = { mosaicChars[mask], fg, bg }
    mosaicCache[key] = cached
    return cached[1], cached[2], cached[3]
end
function Render:write(x, y, str, fgChar, bgChar)
    local ay = y + self.oy
    if ay < self.cy1 or ay > self.cy2 then return self end
    str = textArg(str)
    local utf8 = isUtf8()
    if utf8 then str = normalize(str) end
    local cut = utf8 and cellSub or sub
    local ax = x + self.ox
    local s, e = ax, ax + (utf8 and width(str) or byteLen(str)) - 1
    local x1, x2 = self.cx1, self.cx2
    if s < x1 then
        str = cut(str, x1 - s + 1)
        s = x1
    end
    if e > x2 then
        str = cut(str, 1, x2 - s + 1)
        e = x2
    end
    if s > e then return self end
    if utf8 then
        self.text[ay] = spliceText(self.text[ay], s, str, width(str))
    else
        self.text[ay] = splicePlane(self.text[ay], s, str, byteLen(str))
    end
    if fgChar then
        local span = rep(fgChar, e - s + 1)
        self.fg[ay] = splicePlane(self.fg[ay], s, span, byteLen(span))
    end
    if bgChar then
        local span = rep(bgChar, e - s + 1)
        self.bg[ay] = splicePlane(self.bg[ay], s, span, byteLen(span))
    end
    self.dirty = true
    return self
end
local function colorChar(color)
    if not color then return nil end
    local c = charOf[color]
    if not c then
        error("Basalt: unknown color value " .. tostring(color)
            .. " (use colors.* or basalt.rgb)", 3)
    end
    return c
end
function Render:blit(x, y, str, fg, bg)
    return self:write(x, y, str, colorChar(fg), colorChar(bg))
end
function Render:colorBlit(x, y, str, foregrounds, backgrounds)
    str = textArg(str)
    local fg, bg = {}, {}
    for i = 1, width(str) do
        fg[i] = colorChar(foregrounds[i])
        bg[i] = colorChar(backgrounds[i])
    end
    return self:rawBlit(x, y, str, table.concat(fg), table.concat(bg))
end
function Render:drawText(x, y, str)
    return self:write(x, y, str)
end
function Render:rawBlit(x, y, str, fgStr, bgStr)
    local ay = y + self.oy
    if ay < self.cy1 or ay > self.cy2 then return self end
    str = textArg(str)
    local utf8 = isUtf8()
    local w
    if utf8 then
        str = normalize(str)
        w = width(str)
        fgStr, bgStr = fitPlane(fgStr, w), fitPlane(bgStr, w)
    else
        w = byteLen(str)
    end
    local ax = x + self.ox
    local s, e = ax, ax + w - 1
    local x1, x2 = self.cx1, self.cx2
    local cutFront = s < x1 and (x1 - s) or 0
    local cutBack = e > x2 and (e - x2) or 0
    if cutFront > 0 or cutBack > 0 then
        s = s + cutFront
        e = e - cutBack
        if s > e then return self end
        str = (utf8 and cellSub or sub)(str, 1 + cutFront, w - cutBack)
        if fgStr then fgStr = sub(fgStr, 1 + cutFront, byteLen(fgStr) - cutBack) end
        if bgStr then bgStr = sub(bgStr, 1 + cutFront, byteLen(bgStr) - cutBack) end
    end
    if utf8 then
        self.text[ay] = spliceText(self.text[ay], s, str, width(str))
    else
        self.text[ay] = splicePlane(self.text[ay], s, str, byteLen(str))
    end
    if fgStr then self.fg[ay] = splicePlane(self.fg[ay], s, fgStr, byteLen(fgStr)) end
    if bgStr then self.bg[ay] = splicePlane(self.bg[ay], s, bgStr, byteLen(bgStr)) end
    self.dirty = true
    return self
end
function Render:maskedBlit(x, y, str, fgStr, bgStr, textMask, fgMask, bgMask)
    local ay, ax = y + self.oy, x + self.ox
    if ay < self.cy1 or ay > self.cy2 then return self end
    str = textArg(str)
    local utf8 = isUtf8()
    local w
    if utf8 then
        str = normalize(str)
        w = width(str)
        fgStr, bgStr = fitPlane(fgStr, w), fitPlane(bgStr, w)
        textMask, fgMask, bgMask = fitPlane(textMask, w), fitPlane(fgMask, w), fitPlane(bgMask, w)
    else
        w = byteLen(str)
    end
    local s, e = ax, ax + w - 1
    local cutFront = s < self.cx1 and self.cx1 - s or 0
    local cutBack = e > self.cx2 and e - self.cx2 or 0
    local function cut(plane)
        return plane and sub(plane, 1 + cutFront, byteLen(plane) - cutBack)
    end
    if cutFront > 0 or cutBack > 0 then
        s, e = s + cutFront, e - cutBack
        if s > e then return self end
        str = (utf8 and cellSub or sub)(str, 1 + cutFront, w - cutBack)
        fgStr, bgStr = cut(fgStr), cut(bgStr)
        textMask, fgMask, bgMask = cut(textMask), cut(fgMask), cut(bgMask)
    end
    if utf8 then
        local oldText = cellSub(self.text[ay], s, e)
        local merged = mergeTransparentText(str, oldText, textMask)
        self.text[ay] = spliceText(self.text[ay], s, merged, width(str))
    else
        local merged = mergeTransparent(str, sub(self.text[ay], s, e), textMask)
        self.text[ay] = splicePlane(self.text[ay], s, merged, byteLen(merged))
    end
    if fgStr then
        local merged = mergeTransparent(fgStr, sub(self.fg[ay], s, e), fgMask)
        self.fg[ay] = splicePlane(self.fg[ay], s, merged, byteLen(merged))
    end
    if bgStr then
        local merged = mergeTransparent(bgStr, sub(self.bg[ay], s, e), bgMask)
        self.bg[ay] = splicePlane(self.bg[ay], s, merged, byteLen(merged))
    end
    self.dirty = true
    return self
end
function Render:drawPixels(x, y, pixelWidth, pixelHeight, rows, paletteBytes)
    local cellWidth, cellHeight = math.ceil(pixelWidth / 2), math.ceil(pixelHeight / 3)
    for cellY = 1, cellHeight do
        local text, fg, bg, mask, rowHasPixels = {}, {}, {}, {}, false
        local underRow
        for cellX = 1, cellWidth do
            local absoluteX, absoluteY = x + cellX - 1 + self.ox, y + cellY - 1 + self.oy
            local visible = absoluteX >= self.cx1 and absoluteX <= self.cx2
                and absoluteY >= self.cy1 and absoluteY <= self.cy2
            local values, any = {}, false
            if visible then
                local underneath, underBg = {}, sub(self.bg[absoluteY], absoluteX, absoluteX)
                local underCode
                if isUtf8() then
                    underRow = underRow or cellsOf(self.text[absoluteY])
                    local underCell = underRow[absoluteX] or " "
                    underCode = byteLen(underCell) == 1 and byte(underCell) or nil
                else
                    underCode = byte(self.text[absoluteY], absoluteX)
                end
                if underCode and underCode >= 128 and underCode <= 159 then
                    local underFg, underMask = sub(self.fg[absoluteY], absoluteX, absoluteX), underCode - 128
                    local weights = { 1, 2, 4, 8, 16 }
                    for slot = 1, 5 do
                        underneath[slot] = floor(underMask / weights[slot]) % 2 == 1 and underFg or underBg
                    end
                    underneath[6] = underBg
                else
                    for slot = 1, 6 do underneath[slot] = underBg end
                end
                for py = 1, 3 do
                    local sourceY = (cellY - 1) * 3 + py
                    for px = 1, 2 do
                        local sourceX = (cellX - 1) * 2 + px
                        local slot = (py - 1) * 2 + px
                        local index = sourceY <= pixelHeight and sourceX <= pixelWidth
                            and rows[sourceY]:byte(sourceX) or 0
                        if index ~= 0 then
                            values[slot], any = paletteBytes[index], true
                            if not values[slot] then error("Basalt: FLIMG palette index " .. index .. " is missing", 2) end
                        else values[slot] = underneath[slot] end
                    end
                end
            end
            if any then
                text[cellX], fg[cellX], bg[cellX] = compileMosaic(
                    values[1], values[2], values[3], values[4], values[5], values[6])
                mask[cellX], rowHasPixels = "\1", true
            else
                text[cellX], fg[cellX], bg[cellX] = "\0", "\0", "\0"
                mask[cellX] = "\0"
            end
        end
        if rowHasPixels then
            local visibleMask = table.concat(mask)
            self:maskedBlit(x, y + cellY - 1,
                table.concat(text), table.concat(fg), table.concat(bg),
                visibleMask, visibleMask, visibleMask)
        end
    end
    return self
end
local HEXBYTE = {}
for i = 0, 15 do
    HEXBYTE[("%x"):format(i)] = string.char(i)
    HEXBYTE[("%X"):format(i)] = string.char(i)
end
function Render:drawBlit(x, y, str, fgHex, bgHex)
    return self:rawBlit(x, y, str,
        fgHex and (fgHex:gsub(".", HEXBYTE)),
        bgHex and (bgHex:gsub(".", HEXBYTE)))
end
function Render:fill(x, y, w, h, ch, fg, bg)
    local row = rep(ch, w)
    local f, b = colorChar(fg), colorChar(bg)
    for dy = 0, h - 1 do
        self:write(x, y + dy, row, f, b)
    end
    return self
end
function Render:setCursor(x, y, blink, color)
    self.cursorX, self.cursorY, self.cursorBlink = x, y, blink
    self.cursorColor = color
    self.dirty = true
    return self
end
local function scanLine(line, used)
    for i = 1, byteLen(line) do
        used[line:byte(i)] = true
    end
end
function Render:flush()
    if not self.dirty then return self end
    local t = self.term
    self.released = nil
    local map, force
    if palette.hasVirtual() then
        local used = {}
        for y = 1, self.height do
            scanLine(self.fg[y], used)
            scanLine(self.bg[y], used)
        end
        map, force = self.mapper:build(used)
    else
        map, force = palette.identityMap, false
    end
    local prevT, prevF, prevB = self.prevText, self.prevFg, self.prevBg
    for y = 1, self.height do
        local tx, f, b = self.text[y], self.fg[y], self.bg[y]
        if force or tx ~= prevT[y] or f ~= prevF[y] or b ~= prevB[y] then
            t.setCursorPos(1, y)
            t.blit(tx, (f:gsub(".", map)), (b:gsub(".", map)))
            prevT[y], prevF[y], prevB[y] = tx, f, b
        end
    end
    if self.cursorBlink then
        local ch = self.cursorColor and charOf[self.cursorColor]
        local hex = ch and map[ch]
        if hex then t.setTextColor(2 ^ tonumber(hex, 16)) end
        t.setCursorPos(self.cursorX, self.cursorY)
        t.setCursorBlink(true)
    else
        t.setCursorBlink(false)
    end
    self.dirty = false
    return self
end
return Render
]=]
sources["core/scroll"] = [=[

local scroll = {}
local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end
local function offsets(self)
    return rawget(self, "_scrollX") or 0, rawget(self, "_scrollY") or 0
end
local function maxOffsets(self)
    return math.max(0, (rawget(self, "_contentWidth") or 0) - self.width),
        math.max(0, (rawget(self, "_contentHeight") or 0) - self.height)
end
local function barMode(self)
    local mode = self.scrollbar
    if mode ~= "auto" and mode ~= "always" and mode ~= "hidden" then
        error("Basalt scroll: scrollbar must be 'auto', 'always' or 'hidden'", 3)
    end
    return mode
end
function scroll.disable(self)
    rawset(self, "_scrollX", 0)
    rawset(self, "_scrollY", 0)
    rawset(self, "_showScrollX", false)
    rawset(self, "_showScrollY", false)
    rawset(self, "_scrollDrag", nil)
    rawset(self, "_viewportDirty", true)
end
function scroll.setup(self)
    rawset(self, "_scrollX", 0)
    rawset(self, "_scrollY", 0)
    rawset(self, "_contentWidth", 0)
    rawset(self, "_contentHeight", 0)
    self:on("drag", function(s, _, x, y)
        scroll.drag(s, x, y)
    end)
    self:on("clickUp", function(s)
        rawset(s, "_scrollDrag", nil)
    end)
end
function scroll.update(self)
    local children = self:getChildren()
    local contentWidth, contentHeight = 0, 0
    for i = 1, #children do
        local child = children[i]
        if child.visible then
            contentWidth = math.max(contentWidth, child.x + child.width - 1)
            contentHeight = math.max(contentHeight, child.y + child.height - 1)
        end
    end
    rawset(self, "_contentWidth", contentWidth)
    rawset(self, "_contentHeight", contentHeight)
    if not self.scrollable then
        scroll.disable(self)
        return
    end
    local mode = barMode(self)
    local overflowX = self.scrollXEnabled and contentWidth > self.width
    local overflowY = self.scrollYEnabled and contentHeight > self.height
    rawset(self, "_showScrollX", mode ~= "hidden"
        and self.scrollXEnabled and (mode == "always" or overflowX))
    rawset(self, "_showScrollY", mode ~= "hidden"
        and self.scrollYEnabled and (mode == "always" or overflowY))
    local maxX, maxY = maxOffsets(self)
    local x, y = offsets(self)
    rawset(self, "_scrollX", self.scrollXEnabled and clamp(x, 0, maxX) or 0)
    rawset(self, "_scrollY", self.scrollYEnabled and clamp(y, 0, maxY) or 0)
    rawset(self, "_viewportDirty", true)
end
local function thumb(trackLength, viewport, content, offset, maximum)
    if trackLength <= 0 then return 1, 0 end
    local size = math.max(1, math.floor(trackLength * viewport
        / math.max(content, viewport)))
    size = math.min(trackLength, size)
    local travel = trackLength - size
    local pos = maximum > 0 and math.floor(travel * offset / maximum + 0.5) or 0
    return size, pos
end
function scroll.geometry(self)
    local showX = rawget(self, "_showScrollX") == true
    local showY = rawget(self, "_showScrollY") == true
    local x, y = offsets(self)
    local maxX, maxY = maxOffsets(self)
    local horizontalLength = math.max(0, self.width - (showY and 1 or 0))
    local verticalLength = math.max(0, self.height - (showX and 1 or 0))
    local hSize, hPos = thumb(horizontalLength, self.width,
        rawget(self, "_contentWidth") or 0, x, maxX)
    local vSize, vPos = thumb(verticalLength, self.height,
        rawget(self, "_contentHeight") or 0, y, maxY)
    return {
        showX = showX, showY = showY,
        horizontalLength = horizontalLength,
        verticalLength = verticalLength,
        horizontalThumbSize = hSize,
        horizontalThumbPos = hPos,
        verticalThumbSize = vSize,
        verticalThumbPos = vPos,
        maxX = maxX, maxY = maxY,
    }
end
function scroll.draw(self, buf)
    if not self.scrollable then return end
    local g = scroll.geometry(self)
    local track, thumbColor = self.scrollbarColor, self.scrollbarThumbColor
    if g.showY and g.verticalLength > 0 then
        buf:fill(self.width, 1, 1, g.verticalLength, " ", self.foreground, track)
        buf:fill(self.width, g.verticalThumbPos + 1, 1, g.verticalThumbSize,
            " ", self.foreground, thumbColor)
    end
    if g.showX and g.horizontalLength > 0 then
        buf:fill(1, self.height, g.horizontalLength, 1, " ", self.foreground, track)
        buf:fill(g.horizontalThumbPos + 1, self.height,
            g.horizontalThumbSize, 1, " ", self.foreground, thumbColor)
    end
    if g.showX and g.showY then
        buf:fill(self.width, self.height, 1, 1, " ", self.foreground, track)
    end
end
function scroll.set(self, x, y, emit)
    if not self.scrollable then return false end
    local oldX, oldY = offsets(self)
    local maxX, maxY = maxOffsets(self)
    x = self.scrollXEnabled and clamp(math.floor(x or oldX), 0, maxX) or 0
    y = self.scrollYEnabled and clamp(math.floor(y or oldY), 0, maxY) or 0
    if x == oldX and y == oldY then return false end
    rawset(self, "_scrollX", x)
    rawset(self, "_scrollY", y)
    rawset(self, "_viewportDirty", true)
    self:markRenderDirty()
    if emit ~= false then self:fire("scrollChange", x, y) end
    return true
end
function scroll.wheel(self, direction)
    if not self.scrollable then return false end
    local x, y = offsets(self)
    local amount = direction * math.max(1, math.floor(self.scrollStep))
    if self.scrollYEnabled and (rawget(self, "_contentHeight") or 0) > self.height then
        return scroll.set(self, x, y + amount)
    elseif self.scrollXEnabled then
        return scroll.set(self, x + amount, y)
    end
    return false
end
function scroll.isBarPoint(self, x, y)
    if not self.scrollable then return false end
    local g = scroll.geometry(self)
    if g.showY and x == self.width and y <= g.verticalLength then return "y", g end
    if g.showX and y == self.height and x <= g.horizontalLength then return "x", g end
    if g.showX and g.showY and x == self.width and y == self.height then return "corner", g end
    return false, g
end
function scroll.pointerDown(self, x, y)
    local axis, g = scroll.isBarPoint(self, x, y)
    if axis == "corner" or not axis then return axis == "corner" end
    local isY = axis == "y"
    local coordinate = isY and y or x
    local thumbPos = isY and g.verticalThumbPos or g.horizontalThumbPos
    local thumbSize = isY and g.verticalThumbSize or g.horizontalThumbSize
    local trackLength = isY and g.verticalLength or g.horizontalLength
    local maximum = isY and g.maxY or g.maxX
    local thumbStart = thumbPos + 1
    if coordinate >= thumbStart and coordinate < thumbStart + thumbSize then
        rawset(self, "_scrollDrag", {
            axis = axis,
            grab = coordinate - thumbStart,
        })
    else
        local travel = math.max(1, trackLength - thumbSize)
        local target = math.floor((coordinate - 1 - thumbSize / 2)
            / travel * maximum + 0.5)
        local sx, sy = offsets(self)
        scroll.set(self, isY and sx or target, isY and target or sy)
    end
    return true
end
function scroll.drag(self, x, y)
    local dragState = rawget(self, "_scrollDrag")
    if not dragState then return false end
    local g = scroll.geometry(self)
    local isY = dragState.axis == "y"
    local coordinate = isY and y or x
    local size = isY and g.verticalThumbSize or g.horizontalThumbSize
    local length = isY and g.verticalLength or g.horizontalLength
    local maximum = isY and g.maxY or g.maxX
    local travel = math.max(1, length - size)
    local pos = clamp(coordinate - 1 - dragState.grab, 0, travel)
    local target = math.floor(pos / travel * maximum + 0.5)
    local sx, sy = offsets(self)
    return scroll.set(self, isY and sx or target, isY and target or sy)
end
return scroll
]=]
sources["core/state"] = [=[

local state = {}
local unpack = table.unpack or unpack
local currentWatcher = nil
local Signal = {}
Signal.__index = Signal
Signal.__basaltStateValue = true
local Computed = {}
Computed.__index = Computed
Computed.__basaltStateValue = true
local function registerWatcher(signal, watcher)
    watcher = watcher or currentWatcher
    if watcher and watcher.markDirty then
        signal._watchers[watcher] = true
        local dependencies = rawget(watcher, "_stateDependencies")
        if not dependencies then
            dependencies = setmetatable({}, { __mode = "k" })
            rawset(watcher, "_stateDependencies", dependencies)
        end
        dependencies[signal] = true
    end
end
function state.clearWatcher(watcher)
    local dependencies = rawget(watcher, "_stateDependencies")
    if not dependencies then return end
    for signal in pairs(dependencies) do
        signal._watchers[watcher] = nil
        dependencies[signal] = nil
    end
end
function state.withWatcher(watcher, fn, ...)
    local previous = currentWatcher
    currentWatcher = watcher or previous
    local result = table.pack(pcall(fn, ...))
    currentWatcher = previous
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end
function state.is(value)
    local mt = type(value) == "table" and getmetatable(value)
    return mt and mt.__basaltStateValue == true or false
end
function state.read(value, watcher)
    return value:get(watcher)
end
function state.isWritable(value)
    return getmetatable(value) == Signal
end
function Signal:get(watcher)
    registerWatcher(self, watcher)
    return self._value
end
function Signal:set(value)
    local old = self._value
    if old == value then return self end
    self._value = value
    for watcher in pairs(self._watchers) do
        if watcher.markLayoutDirty then
            watcher:markLayoutDirty()
        else
            watcher:markDirty()
        end
    end
    for listener in pairs(self._listeners) do
        listener(value, old)
    end
    return self
end
function Signal:update(fn)
    if type(fn) ~= "function" then
        error("Basalt state: update expects a function", 2)
    end
    return self:set(fn(self._value))
end
function Signal:touch()
    for watcher in pairs(self._watchers) do
        if watcher.markLayoutDirty then
            watcher:markLayoutDirty()
        else
            watcher:markDirty()
        end
    end
    for listener in pairs(self._listeners) do
        listener(self._value, self._value)
    end
    return self
end
function Signal:subscribe(fn, immediate)
    if type(fn) ~= "function" then
        error("Basalt state: subscribe expects a function", 2)
    end
    self._listeners[fn] = true
    if immediate then fn(self._value, nil) end
    local active = true
    return function()
        if active then
            self._listeners[fn] = nil
            active = false
        end
    end
end
function Signal:map(fn)
    if type(fn) ~= "function" then
        error("Basalt state: map expects a function", 2)
    end
    local source = self
    return state.computed(function()
        return fn(source:get())
    end)
end
function Signal:__tostring()
    return tostring(self._value)
end
function Computed:get(watcher)
    return state.withWatcher(watcher, self._compute)
end
function Computed:map(fn)
    if type(fn) ~= "function" then
        error("Basalt state: map expects a function", 2)
    end
    local source = self
    return state.computed(function()
        return fn(source:get())
    end)
end
function Computed:__tostring()
    return tostring(self:get())
end
function state.create(initialValue)
    return setmetatable({
        _value = initialValue,
        _watchers = setmetatable({}, { __mode = "k" }),
        _listeners = {},
    }, Signal)
end
function state.computed(fn)
    if type(fn) ~= "function" then
        error("Basalt computed: expected a function", 2)
    end
    return setmetatable({ _compute = fn }, Computed)
end
return state
]=]
sources["core/text"] = [=[

local textutil = {}
local find, sub, byte, char, rep = string.find, string.sub, string.byte, string.char, string.rep
local floor, concat = math.floor, table.concat
local utf8Mode = type(unicode) == "table" and type(unicode.len) == "function"
function textutil.isUtf8()
    return utf8Mode
end
function textutil.setUtf8(enabled)
    utf8Mode = enabled and true or false
end
local function byteLen(s)
    local _, last = find(s, "$")
    return last
end
textutil.byteLen = byteLen
local function isPlain(s)
    return not find(s, "[\128-\255]")
end
textutil.isPlain = isPlain
local function isByteCells(s)
    return not find(s, "[\194-\244]")
end
textutil.isByteCells = isByteCells
local function cellLen(s, i, n)
    local b = byte(s, i)
    local len
    if b < 0xC2 then return 1
    elseif b <= 0xDF then len = 2
    elseif b <= 0xEF then len = 3
    elseif b <= 0xF4 then len = 4
    else return 1 end
    if i + len - 1 > n then return 1 end
    local second = byte(s, i + 1)
    if second < 0x80 or second > 0xBF
        or (b == 0xE0 and second < 0xA0) or (b == 0xED and second > 0x9F)
        or (b == 0xF0 and second < 0x90) or (b == 0xF4 and second > 0x8F) then
        return 1
    end
    for j = i + 2, i + len - 1 do
        local c = byte(s, j)
        if c < 0x80 or c > 0xBF then return 1 end
    end
    return len
end
local function cellStarts(s)
    local starts, count, i, n = {}, 0, 1, byteLen(s)
    while i <= n do
        count = count + 1
        starts[count] = i
        i = i + cellLen(s, i, n)
    end
    return starts, n
end
local function str(s)
    if type(s) == "string" then return s end
    return tostring(s)
end
function textutil.width(s)
    s = str(s)
    if not utf8Mode or isByteCells(s) then
        return byteLen(s)
    end
    local count, i, n = 0, 1, byteLen(s)
    while i <= n do
        count = count + 1
        i = i + cellLen(s, i, n)
    end
    return count
end
function textutil.span(s, i, j)
    i, j = i or 1, j or -1
    i = i >= 0 and floor(i) or -floor(-i)
    j = j >= 0 and floor(j) or -floor(-j)
    local starts, n, count
    if not utf8Mode or isByteCells(s) then
        n = byteLen(s)
        count = n
    elseif i >= 0 and j >= 0 then
        if i < 1 then i = 1 end
        local b = j + 1 > i and j + 1 or i
        n = byteLen(s)
        local pos, c, fa = 1, 1, nil
        while true do
            local lead = find(s, "[\194-\244]", pos)
            local stop = lead and (c + lead - pos)
            if not fa and (not lead or i <= stop) then
                fa = pos + (i - c)
                if fa > n + 1 then fa = n + 1 end
            end
            if fa and (not lead or b <= stop) then
                local fb = pos + (b - c)
                if fb > n + 1 then fb = n + 1 end
                if j < i then return fa, fa - 1 end
                return fa, fb - 1
            end
            pos, c = lead + cellLen(s, lead, n), stop + 1
        end
    else
        starts, n = cellStarts(s)
        count = #starts
    end
    if i < 0 then i = count + i + 1 end
    if j < 0 then j = count + j + 1 end
    if i < 1 then i = 1 end
    if j > count then j = count end
    if i > j then
        local at = starts and (starts[i] or n + 1) or math.min(i, n + 1)
        return at, at - 1
    end
    if not starts then return i, j end
    return starts[i], (starts[j + 1] or (n + 1)) - 1
end
function textutil.sub(s, i, j)
    s = str(s)
    if not utf8Mode or isByteCells(s) then
        return sub(s, i or 1, j or -1)
    end
    local first, last = textutil.span(s, i, j)
    return sub(s, first, last)
end
function textutil.offset(s, cell)
    cell = floor(cell)
    if cell < 1 or not utf8Mode or isByteCells(s) then
        return cell
    end
    local starts, n = cellStarts(s)
    if cell <= #starts then
        return starts[cell]
    end
    return n + 1 + (cell - #starts - 1)
end
function textutil.cells(s)
    s = str(s)
    local out = {}
    if not utf8Mode or isByteCells(s) then
        for i = 1, byteLen(s) do out[i] = sub(s, i, i) end
        return out
    end
    local i, n = 1, byteLen(s)
    while i <= n do
        local len = cellLen(s, i, n)
        out[#out + 1] = sub(s, i, i + len - 1)
        i = i + len
    end
    return out
end
local function latin1(b)
    return char(0xC0 + floor(b / 64), 0x80 + b % 64)
end
function textutil.normalize(s)
    s = str(s)
    if not utf8Mode or isByteCells(s) then
        return s
    end
    local out, i, n, runStart = nil, 1, byteLen(s), 1
    while i <= n do
        local b = byte(s, i)
        local len = cellLen(s, i, n)
        if len == 1 and b >= 0xC2 and b <= 0xF4 then
            out = out or {}
            out[#out + 1] = sub(s, runStart, i - 1)
            out[#out + 1] = latin1(b)
            runStart = i + 1
        end
        i = i + len
    end
    if not out then return s end
    out[#out + 1] = sub(s, runStart)
    return concat(out)
end
function textutil.splice(s, i, j, piece)
    piece = textutil.normalize(piece)
    if not utf8Mode or (isByteCells(s) and isByteCells(piece)) then
        return sub(s, 1, i - 1) .. piece .. sub(s, j + 1)
    end
    s = textutil.normalize(s)
    local before = i > 1 and textutil.sub(s, 1, i - 1) or ""
    return before .. piece .. textutil.sub(s, j + 1)
end
function textutil.pad(s, n, align)
    s = str(s)
    local w = textutil.width(s)
    if w > n then
        return textutil.sub(s, 1, n)
    end
    local space = n - w
    if align == "right" then
        return rep(" ", space) .. s
    elseif align == "center" then
        local left = floor(space / 2)
        return rep(" ", left) .. s .. rep(" ", space - left)
    end
    return s .. rep(" ", space)
end
function textutil.fromInput(s)
    s = str(s)
    if not utf8Mode or isPlain(s) then
        return s
    end
    local out, i, n = {}, 1, byteLen(s)
    while i <= n do
        local b = byte(s, i)
        local len = cellLen(s, i, n)
        if len > 2 or (len == 2 and b > 0xC3) then
            out[#out + 1] = sub(s, i, i + len - 1)
            i = i + len
        else
            out[#out + 1] = b >= 0xA0 and latin1(b) or char(b)
            i = i + 1
        end
    end
    return concat(out)
end
function textutil.fromLegacy(s)
    s = str(s)
    if not utf8Mode or isPlain(s) then
        return s
    end
    return (s:gsub("[\160-\255]", function(c) return latin1(byte(c)) end))
end
function textutil.toLegacy(s)
    s = str(s)
    if not utf8Mode or isByteCells(s) then
        return s
    end
    local out, i, n = {}, 1, byteLen(s)
    while i <= n do
        local len = cellLen(s, i, n)
        if len == 1 then
            out[#out + 1] = sub(s, i, i)
        elseif len == 2 and byte(s, i) <= 0xC3 then
            out[#out + 1] = char((byte(s, i) - 0xC0) * 64 + byte(s, i + 1) - 0x80)
        else
            out[#out + 1] = "?"
        end
        i = i + len
    end
    return concat(out)
end
function textutil.char(code)
    code = floor(code)
    if code >= 0 and code <= 255 then
        return textutil.fromLegacy(char(code))
    end
    if not utf8Mode or code < 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
        return "?"
    end
    if code < 0x800 then
        return char(0xC0 + floor(code / 64), 0x80 + code % 64)
    elseif code < 0x10000 then
        return char(0xE0 + floor(code / 4096), 0x80 + floor(code / 64) % 64, 0x80 + code % 64)
    end
    return char(0xF0 + floor(code / 262144), 0x80 + floor(code / 4096) % 64,
        0x80 + floor(code / 64) % 64, 0x80 + code % 64)
end
function textutil.lower(s)
    s = str(s)
    if isPlain(s) then
        return (s:lower())
    end
    s = s:gsub("[A-Z]", function(c) return char(byte(c) + 32) end)
    if utf8Mode then
        s = s:gsub("\195([\128-\158])", function(c)
            if c == "\151" then return nil end
            return "\195" .. char(byte(c) + 32)
        end)
    end
    return s
end
function textutil.wrap(s, width)
    width = math.max(1, width)
    local measure, cut = textutil.width, textutil.sub
    local lines = {}
    for paragraph in (str(s) .. "\n"):gmatch("(.-)\n") do
        local line, lineWidth = "", 0
        for word in paragraph:gmatch("%S+") do
            local wordWidth = measure(word)
            if lineWidth == 0 then
                line, lineWidth = word, wordWidth
            elseif lineWidth + 1 + wordWidth <= width then
                line, lineWidth = line .. " " .. word, lineWidth + 1 + wordWidth
            else
                lines[#lines + 1] = line
                line, lineWidth = word, wordWidth
            end
            while lineWidth > width do
                lines[#lines + 1] = cut(line, 1, width)
                line = cut(line, width + 1)
                lineWidth = lineWidth - width
            end
        end
        lines[#lines + 1] = line
    end
    if #lines > 1 and lines[#lines] == "" then
        table.remove(lines)
    end
    if #lines == 0 then lines = { "" } end
    return lines
end
return textutil
]=]
sources["elements/Canvas"] = [=[

local require = ...
local class = require("core/class")
local Element = require("core/element")
local Canvas = class.create("Canvas", Element)
class.property(Canvas, "draw", false, { rawFunction = true })
function Canvas:render(buf)
    Element.render(self, buf)
    local draw = self.draw
    if draw then draw(self, buf) end
end
return Canvas
]=]
sources["elements/Collection"] = [=[

local require = ...
local class = require("core/class")
local Element = require("core/element")
local collection = require("core/collection")
local Collection = class.create("Collection", Element)
collection.install(Collection)
function Collection:setup()
    Element.setup(self)
    collection.setup(self)
end
return Collection
]=]
sources["elements/Frame"] = [=[

local require = ...
local class = require("core/class")
local Container = require("core/container")
local Frame = class.create("Frame", Container)
class.property(Frame, "background", colors.gray)
class.property(Frame, "width", 20)
class.property(Frame, "height", 8)
class.property(Frame, "draggable", false)
class.property(Frame, "draggingMap", false, { visual = false })
local function inDragZone(self, x, y)
    local zones = self.draggingMap
    if not zones then
        zones = { { x = 1, y = 1, width = "full", height = 1 } }
    end
    for i = 1, #zones do
        local zone = zones[i]
        local zw = zone.width == "full" and self.width or (zone.width or 1)
        local zh = zone.height == "full" and self.height or (zone.height or 1)
        if x >= zone.x and x < zone.x + zw
            and y >= zone.y and y < zone.y + zh then
            return true
        end
    end
    return false
end
function Frame:setup()
    Container.setup(self)
    self:on("click", function(s, _, x, y)
        if s.draggable and inDragZone(s, x, y) then
            rawset(s, "_dragFrom", { x = x, y = y })
        end
    end)
    self:on("drag", function(s, _, x, y)
        local from = rawget(s, "_dragFrom")
        if from then
            s.x = s.x + x - from.x
            s.y = s.y + y - from.y
        end
    end)
    self:on("clickUp", function(s)
        rawset(s, "_dragFrom", nil)
    end)
end
function Frame:toFront()
    local parent = rawget(self, "parent")
    if not parent then return self end
    local top = self.z
    for _, sibling in ipairs(parent:getChildren()) do
        if sibling.z > top then top = sibling.z end
    end
    if top >= self.z then self.z = top + 1 end
    return self
end
return Frame
]=]
sources["elements/Input"] = [=[

local require = ...
local class = require("core/class")
local Element = require("core/element")
local textutil = require("core/text")
local cellWidth, cellSub = textutil.width, textutil.sub
local normalize, splice = textutil.normalize, textutil.splice
local function clampCursor(self, n)
    local cur = rawget(self, "_cursor")
    if cur and cur > n + 1 then
        rawset(self, "_cursor", n + 1)
        rawset(self, "_scroll", math.max(0, n + 1 - self.width))
    end
end
local function scrollToCursor(self, n)
    local pos, scroll, w = rawget(self, "_cursor"), rawget(self, "_scroll"), self.width
    local lastW = rawget(self, "_scrollWidth")
    if lastW and w > lastW then
        scroll = math.min(scroll, math.max(0, n + 1 - w))
    end
    if pos - scroll > w then scroll = pos - w end
    if pos - scroll < 1 then scroll = pos - 1 end
    rawset(self, "_scroll", scroll)
    rawset(self, "_scrollWidth", w)
end
local Input = class.create("Input", Element)
class.property(Input, "text", "", {
    rawString = true,
    onChange = function(self, v)
        if type(v) == "string" then
            local stored = normalize(v)
            if stored ~= v then rawget(self, "_p").text = stored end
        end
        clampCursor(self, v == nil and 0 or cellWidth(v))
    end,
})
class.property(Input, "placeholder", "")
class.property(Input, "placeholderColor", colors.gray)
class.property(Input, "maxLength", false)
class.property(Input, "replaceChar", false)
class.property(Input, "pattern", false)
class.property(Input, "width", 12)
class.property(Input, "height", 1)
class.property(Input, "background", colors.lightGray)
class.property(Input, "foreground", colors.black)
class.event(Input, "change")
class.event(Input, "enter")
local function currentText(self)
    return normalize(self.text)
end
function Input:setup()
    Element.setup(self)
    rawset(self, "_cursor", 1)
    rawset(self, "_scroll", 0)
    self:on("click", function(s, _, x, y)
        if y ~= 1 then return end
        s:_moveCursor(s._scroll + x)
    end)
    self:on("focus", function(s) s:markDirty() end)
    self:on("blur", function(s) s:markDirty() end)
end
function Input:_moveCursor(pos)
    local n = cellWidth(self.text)
    if pos < 1 then pos = 1 end
    if pos > n + 1 then pos = n + 1 end
    rawset(self, "_cursor", pos)
    scrollToCursor(self, n)
    self:markDirty()
end
function Input:setCursorPos(pos)
    if type(pos) ~= "number" or pos ~= pos then
        error("Basalt: cursor position must be a number", 2)
    end
    self:_moveCursor(math.floor(pos))
    return self
end
function Input:getCursorPos()
    clampCursor(self, cellWidth(self.text))
    return rawget(self, "_cursor")
end
function Input:_insert(str)
    str = normalize(str)
    local pattern = self.pattern
    if pattern then
        local kept = {}
        for _, ch in ipairs(textutil.cells(str)) do
            if ch:match(pattern) then kept[#kept + 1] = ch end
        end
        str = table.concat(kept)
        if str == "" then return end
    end
    local value = currentText(self)
    local max = self.maxLength
    local added = cellWidth(str)
    if max and cellWidth(value) + added > max then return end
    local c = self._cursor
    self.text = splice(value, c, c - 1, str)
    self:_moveCursor(c + added)
    self:fire("change", self.text)
end
function Input:handleKey(event, a, b)
    if event == "char" or event == "paste" then
        if type(a) == "string" then self:_insert(textutil.fromInput(a)) end
    elseif event == "key" then
        local c = self._cursor
        if a == keys.backspace then
            if c > 1 then
                self.text = splice(currentText(self), c - 1, c - 1, "")
                self:_moveCursor(c - 1)
                self:fire("change", self.text)
            end
        elseif a == keys.delete then
            local value = currentText(self)
            if c <= cellWidth(value) then
                self.text = splice(value, c, c, "")
                self:fire("change", self.text)
            end
        elseif a == keys.left then
            self:_moveCursor(c - 1)
        elseif a == keys.right then
            self:_moveCursor(c + 1)
        elseif a == keys.home then
            self:_moveCursor(1)
        elseif a == keys["end"] then
            self:_moveCursor(cellWidth(self.text) + 1)
        elseif a == keys.enter then
            self:fire("enter", self.text)
        end
    end
    Element.handleKey(self, event, a, b)
end
function Input:render(buf)
    Element.render(self, buf)
    local root = self:getRoot()
    local focused = root.getFocused and root:getFocused() == self
    local value = currentText(self)
    local w = self.width
    local n = cellWidth(value)
    clampCursor(self, n)
    scrollToCursor(self, n)
    if value == "" and not focused then
        buf:blit(1, 1, cellSub(self.placeholder, 1, w), self.placeholderColor, nil)
    else
        local visible = cellSub(value, self._scroll + 1, self._scroll + w)
        local rc = self.replaceChar
        if rc then
            visible = cellSub(normalize(rc), 1, 1):rep(cellWidth(visible))
        end
        buf:blit(1, 1, visible, self.foreground, nil)
    end
    if focused then
        self:setCursor(self._cursor - self._scroll, 1, true, self.foreground)
    end
end
function Input:measure()
    return math.max(1, cellWidth(self.text), cellWidth(self.placeholder)), 1
end
return Input
]=]
sources["elements/Label"] = [=[

local require = ...
local class = require("core/class")
local Element = require("core/element")
local textutil = require("core/text")
local Label = class.create("Label", Element)
local function reflow(self)
    local p = rawget(self, "_p")
    if rawget(self, "_autoSize") then
        if type(p.width) ~= "function" then
            p.width = math.max(textutil.width(tostring(self.text)), 1)
        end
        return
    end
    if rawget(self, "_autoHeight") and type(p.height) ~= "function"
        and type(p.width) ~= "function" then
        p.height = #textutil.wrap(self.text, self.width)
    end
end
class.property(Label, "text", "", {
    onChange = function(self) reflow(self) end,
})
class.property(Label, "width", 1, {
    onChange = function(self)
        rawset(self, "_autoSize", false)
        reflow(self)
    end,
})
class.property(Label, "height", 1, {
    onChange = function(self)
        rawset(self, "_autoHeight", false)
    end,
})
function Label:setup()
    Element.setup(self)
    rawset(self, "_autoSize", true)
    rawset(self, "_autoHeight", true)
end
function Label:render(buf)
    Element.render(self, buf)
    local str = tostring(self.text)
    if rawget(self, "_autoSize") or self.height == 1 then
        buf:blit(1, 1, str, self.foreground, nil)
    else
        local lines = textutil.wrap(str, self.width)
        for i = 1, math.min(#lines, self.height) do
            buf:blit(1, i, lines[i], self.foreground, nil)
        end
    end
end
function Label:measure()
    return math.max(1, textutil.width(tostring(self.text))), 1
end
return Label
]=]
sources["elements/List"] = [=[

local require = ...
local class = require("core/class")
local Collection = require("elements/Collection")
local itemview = require("core/itemview")
local textutil = require("core/text")
local List = class.create("List", Collection)
class.property(List, "offset", 0)
class.property(List, "emptyText", "")
class.property(List, "emptyTextColor", colors.gray)
class.property(List, "background", colors.black)
class.property(List, "width", 16)
class.property(List, "height", 8)
class.property(List, "scrollbar", "auto")
class.property(List, "scrollbarColor", colors.gray)
class.property(List, "scrollbarThumbColor", colors.lightGray)
local function maxOffset(self)
    return itemview.maxOffset(#self.items, self.height)
end
function List:getScrollInfo()
    return itemview.geometry(#self.items, self.height, self.offset, self.scrollbar)
end
function List:setOffset(offset)
    self.offset = itemview.clampOffset(offset, #self.items, self.height)
    return self
end
function List:scrollToItem(index)
    self.offset = itemview.ensureVisible(self.offset, index,
        #self.items, self.height)
    return self
end
function List:selectItem(value, emit)
    Collection.selectItem(self, value, emit)
    local index = self:indexOfItem(value) or self:getSelectedIndex()
    if index then self:scrollToItem(index) end
    return self
end
function List:setup()
    Collection.setup(self)
    self:on("click", function(s, _, x, y)
        local geometry = s:getScrollInfo()
        if geometry.show and x == s.width then
            local target, grab = itemview.pointerDown(y, geometry)
            if target ~= nil then s:setOffset(target) end
            if grab ~= nil then rawset(s, "_itemScrollDrag", grab) end
            return
        end
        local idx = s.offset + y
        if s.items[idx] ~= nil then
            s:select(idx)
        end
    end)
    self:on("drag", function(s, _, _, y)
        local grab = rawget(s, "_itemScrollDrag")
        if grab ~= nil then
            s:setOffset(itemview.drag(y, grab, s:getScrollInfo()))
        end
    end)
    self:on("clickUp", function(s)
        rawset(s, "_itemScrollDrag", nil)
    end)
end
function List:handleMouse(event, btn, x, y)
    if event == "mouse_scroll" then
        if self.disabled then return nil end
        local old = self.offset
        self:setOffset(old + btn)
        local userHandled = self:fire("scroll", btn, x, y)
        if self.offset ~= old or userHandled then return self end
        return nil
    end
    return Collection.handleMouse(self, event, btn, x, y)
end
function List:removeItem(index)
    Collection.removeItem(self, index)
    if self.offset > maxOffset(self) then self.offset = maxOffset(self) end
    self:markDirty()
    return self
end
local function canSelect(entry)
    return entry ~= nil and entry.selectable ~= false
        and entry.disabled ~= true and entry.separator ~= true
end
local function nearestSelectable(self, index, dir)
    local items = self.items
    index = math.max(1, math.min(#items, index))
    local last = dir > 0 and #items or 1
    for i = index, last, dir do
        if canSelect(items[i]) then return i end
    end
    for i = index - dir, dir > 0 and 1 or #items, -dir do
        if canSelect(items[i]) then return i end
    end
    return nil
end
local function scrollByKey(self, key)
    local offset, page = self.offset, math.max(1, self.height)
    if key == keys.up then
        self:setOffset(offset - 1)
    elseif key == keys.down then
        self:setOffset(offset + 1)
    elseif key == keys.pageUp then
        self:setOffset(offset - page)
    elseif key == keys.pageDown then
        self:setOffset(offset + page)
    elseif key == keys.home then
        self:setOffset(0)
    elseif key == keys["end"] then
        self:setOffset(maxOffset(self))
    end
end
function List:handleKey(event, a, b)
    if event == "key" and #self.items > 0 then
        if not self.selectable then
            scrollByKey(self, a)
        else
            local selected = self.selected or 0
            local target, dir
            if a == keys.up then
                target, dir = selected > 1 and selected - 1 or 1, selected > 0 and -1 or 1
            elseif a == keys.down then
                target, dir = selected > 0 and math.min(#self.items, selected + 1) or 1, 1
            elseif a == keys.home then
                target, dir = 1, 1
            elseif a == keys["end"] then
                target, dir = #self.items, -1
            elseif a == keys.pageUp then
                target, dir = math.max(1, (selected > 0 and selected or 1) - self.height), -1
            elseif a == keys.pageDown then
                target, dir = math.min(#self.items,
                    (selected > 0 and selected or 1) + self.height), 1
            elseif a == keys.enter and selected > 0 then
                self:activateItem(selected)
            end
            if target then
                local index = nearestSelectable(self, target, dir)
                if index then
                    self:scrollToItem(target)
                    self:selectItem(index)
                else
                    scrollByKey(self, a)
                end
            end
        end
    end
    Collection.handleKey(self, event, a, b)
end
function List:clear()
    Collection.clear(self)
    self.offset = 0
    return self
end
function List:render(buf)
    Collection.render(self, buf)
    local items = self.items
    local w, h = self.width, self.height
    if #items == 0 and tostring(self.emptyText) ~= "" then
        local label = textutil.sub(tostring(self.emptyText), 1, w)
        buf:blit(math.floor((w - textutil.width(label)) / 2) + 1,
            math.floor((h - 1) / 2) + 1, label, self.emptyTextColor, nil)
        return
    end
    local off = itemview.clampOffset(self.offset, #items, h)
    rawget(self, "_p").offset = off
    local geometry = self:getScrollInfo()
    local textWidth = math.max(0, w - (geometry.show and 1 or 0))
    local function drawIcon(item, row, selected, rowBackground)
        local icon = item.iconChar
        if type(icon) == "number" then icon = textutil.char(icon) end
        if type(icon) ~= "string" or icon == "" then return end
        local x = math.floor(tonumber(item.iconX) or 1)
        if x < 1 or x > textWidth then return end
        local foreground = selected and item.selectedIconForeground
            or item.iconForeground or rowBackground
        local background = selected and item.selectedIconBackground
            or item.iconBackground
        buf:blit(x, row, textutil.sub(icon, 1, 1), foreground, background)
    end
    for row = 1, h do
        local idx = off + row
        local item = items[idx]
        if item == nil then break end
        local label = tostring(item)
        if item.separator then
            local symbol = label ~= "" and textutil.sub(label, 1, 1) or "-"
            buf:blit(1, row, symbol:rep(textWidth),
                item.fg or self.foreground, item.bg)
        elseif self:isSelected(idx) then
            local foreground = item.selectedFg or self.selectionForeground
            local background = item.selectedBg or self.selectionBackground
            buf:fill(1, row, textWidth, 1, " ", foreground, background)
            buf:blit(1, row, textutil.sub(label, 1, textWidth), foreground, background)
            drawIcon(item, row, true, background)
        else
            local foreground = item.fg or self.foreground
            local background = item.bg
            if background then
                buf:fill(1, row, textWidth, 1, " ", foreground, background)
            end
            buf:blit(1, row, textutil.sub(label, 1, textWidth), foreground, background)
            drawIcon(item, row, false, background or self.background)
        end
    end
    itemview.draw(buf, w, 1, geometry, self.foreground,
        self.scrollbarColor, self.scrollbarThumbColor)
end
return List
]=]
local loaded = {}
local function loader(name)
    local cached = loaded[name]
    if cached ~= nil then return cached end

    local source = sources[name]
        or error("Basalt: module not bundled: " .. tostring(name), 0)
    local chunk = assert(load(source, "@basalt/" .. name .. ".lua", nil, _ENV))
    local result = chunk(loader, "basalt")
    loaded[name] = result == nil and true or result
    return loaded[name]
end
return loader("main")