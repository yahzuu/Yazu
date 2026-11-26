-- ================================================================
--  Yazu | features/blair.lua
--  VERSION: 3.0  (rebuilt on the real game objects)
--  Source of every path below: Yazu universal dump of PlaceId 6348640020,
--  PlaceVersion 3616 (map Camp Sapple). Paths that were not seen in that
--  dump are marked UNCONFIRMED.
-- ================================================================

-- >>> PURE  (no Roblox globals; unit tested in tests/blair_test.luau)
local Pure = {}

-- The journal shows "Freezing Temp." but the server's evidence table uses
-- "Freezing Temperatures" (JournalHandler L49-L62). One name everywhere.
Pure.EVIDENCE = { 'EMF Level 5', 'Freezing Temperatures', 'Ghost Orb', 'Ghost Writing',
    'Spirit Box', 'Ultraviolet', 'SLS Anomaly' }
Pure.SHORT = { ['EMF Level 5'] = 'EMF5', ['Freezing Temperatures'] = 'Freeze', ['Ghost Orb'] = 'Orb',
    ['Ghost Writing'] = 'Writing', ['Spirit Box'] = 'SpiritBox', ['Ultraviolet'] = 'UV',
    ['SLS Anomaly'] = 'SLS' }

function Pure.normEvidence(name)
    if name == 'Freezing Temp.' then return 'Freezing Temperatures' end
    return name
end

-- evidenceTable: { [ghostName] = { evidence, ... } } from
-- Remotes.GetGhostInformation.GetGhostEvidences (the journal's own call).
-- found / ruledOut: sets { [evidence] = true }.
-- Returns sorted ghost names that have every found evidence and none of the
-- ruled-out ones.
function Pure.possibleGhosts(evidenceTable, found, ruledOut)
    local out = {}
    for ghost, list in pairs(evidenceTable or {}) do
        local has = {}
        for _, e in ipairs(list) do has[Pure.normEvidence(e)] = true end
        local ok = true
        for e in pairs(found or {}) do if not has[e] then ok = false break end end
        if ok then
            for e in pairs(ruledOut or {}) do if has[e] then ok = false break end end
        end
        if ok then out[#out + 1] = ghost end
    end
    table.sort(out)
    return out
end

-- Evidence that every remaining ghost would still be able to show and that is
-- not found yet: what is worth testing next. Returns { {name, count}, ... }
-- sorted by how many remaining ghosts have it.
function Pure.nextEvidence(evidenceTable, possible, found)
    local count = {}
    for _, g in ipairs(possible) do
        for _, e in ipairs(evidenceTable[g] or {}) do
            local n = Pure.normEvidence(e)
            if not (found and found[n]) then count[n] = (count[n] or 0) + 1 end
        end
    end
    local out = {}
    for e, n in pairs(count) do out[#out + 1] = { e, n } end
    table.sort(out, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    return out
end

-- zones: { {name=, temp=, base=} }. The ghost's room cools down from its base
-- temperature, so the biggest drop wins (not just the lowest number, because
-- rooms start at different base temperatures).
function Pure.coldestZone(zones)
    local best, bestDrop
    for _, z in ipairs(zones) do
        if type(z.temp) == 'number' then
            local drop = (z.base or 20) - z.temp
            if not bestDrop or drop > bestDrop then best, bestDrop = z, drop end
        end
    end
    return best, bestDrop
end

-- Is a point inside an axis box given in the box's local frame?
-- (lx, ly, lz) = point in the part's object space, (sx, sy, sz) = part size.
function Pure.insideLocal(lx, ly, lz, sx, sy, sz)
    return math.abs(lx) <= sx / 2 and math.abs(ly) <= sy / 2 and math.abs(lz) <= sz / 2
end

function Pure.fmtTemp(c, unit)
    if type(c) ~= 'number' then return '?' end
    if unit == 'F' then return string.format('%.1fF', c * 9 / 5 + 32) end
    return string.format('%.1fC', c)
end

function Pure.fmtTime(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    return string.format('%d:%02d', sec // 60, sec % 60)
end
-- <<< PURE

return function(State, Tabs, Services, Library)

local Tab = Tabs.blair or Tabs.Blair
if not Tab then return end

local RunService   = Services.RunService
local Players      = Services.Players
local LocalPlayer  = Services.LocalPlayer
local RepStorage   = game:GetService('ReplicatedStorage')
local CollectionService = game:GetService('CollectionService')

-- ================================================================
--  CLEANUP
-- ================================================================
local cleanups = {}
local function onCleanup(fn) cleanups[#cleanups + 1] = fn end
local function runCleanups()
    for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
    cleanups = {}
end
if type(Library.OnUnload) == 'function' then Library:OnUnload(runCleanups) end
local function connect(signal, fn)
    local c = signal:Connect(fn)
    onCleanup(function() c:Disconnect() end)
    return c
end

local function on(name) return Toggles and Toggles[name] and Toggles[name].Value == true end
local function opt(name, fallback)
    local o = Options and Options[name]
    if o and o.Value ~= nil then return o.Value end
    return fallback
end
local function notify(text, t) pcall(function() Library:Notify(text, t or 4) end) end

-- ================================================================
--  GAME OBJECTS  (dump of PlaceVersion 3616)
-- ================================================================
--  workspace.Ghost                Model, tag GhostModel (GhostVisibility L44, highlight.Ghost L66)
--    .Hunting                     BoolValue (ReplicatedStorage.GhostModel.Ghost template)
--    .OriginalGhostName           StringValue
--    .HumanoidRootPart
--  workspace.Map.Zones.<Room>     Part with IsZone, _____Temperature (NumberValue,
--                                 child _____LocalBaseTemp); "Exclude" child = not a ghost room
--                                 (TemperatureCore also accepts a child named "Temperature")
--  workspace.Map.Orbs.OrbPart     .Zone ObjectValue -> the orb's room (VideoCameraHandler L870)
--  workspace.Map.Prints           UV prints: BaseParts with attributes IsUVPart + StartTime
--                                 (UVLightClient L71)
--  Tools (Map.Items, characters, backpacks):
--    EMF Reader.RecentlyLevelFive BoolValue
--    Thermometer.IsFreezing       BoolValue (ThermometerClient L205)
--    Ghost Writing Book.Written   BoolValue
--  Player values: Zone (ObjectValue -> room), Dead (BoolValue)
--  Player attribute StaminaImmune: PlayerController skips stamina drain (L451, L579)
--  ReplicatedStorage.Activity     IntValue (ghost activity; scale UNCONFIRMED)
--  ReplicatedStorage.ReplicatedValues: MapName, Weather (StringValue)
--  Remotes.GetGhostInformation.GetGhostEvidences  RemoteFunction, the journal calls it
--                                 at load (JournalHandler L53)
--  CollectionService tag CursedObject (e.g. Music Box)
local function map() return workspace:FindFirstChild('Map') end
local function ghost()
    local g = workspace:FindFirstChild('Ghost')
    if g and g:IsA('Model') then return g end
    return nil
end
local function ghostRoot(g)
    return g and (g:FindFirstChild('HumanoidRootPart') or g.PrimaryPart)
end
local function isHunting(g)
    local h = g and g:FindFirstChild('Hunting')
    return h ~= nil and h:IsA('BoolValue') and h.Value == true
end
local function myRoot()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild('HumanoidRootPart')
end
local function dist(part)
    local r = myRoot()
    if not (r and part) then return nil end
    return (r.Position - part.Position).Magnitude
end
local function valueOf(inst, name)
    local v = inst and inst:FindFirstChild(name)
    if v and v:IsA('ValueBase') then return v.Value end
    return nil
end

-- ── zones ─────────────────────────────────────────────────────
local function zoneTemp(z)
    local t = z:FindFirstChild('_____Temperature') or z:FindFirstChild('Temperature')
    if not t then return nil, nil end
    local temp = tonumber(t.Value)
    local base = t:FindFirstChild('_____LocalBaseTemp') or t:FindFirstChild('LocalBaseTemp')
    return temp, base and tonumber(base.Value) or nil
end

local function zoneList(includeExcluded)
    local out = {}
    local m = map()
    local zf = m and m:FindFirstChild('Zones')
    if not zf then return out end
    for _, z in ipairs(zf:GetChildren()) do
        if z:IsA('BasePart') and z:FindFirstChild('IsZone') then
            local temp, base = zoneTemp(z)
            local excluded = z:FindFirstChild('Exclude') ~= nil
            if temp and (includeExcluded or not excluded) then
                out[#out + 1] = { name = z.Name, temp = temp, base = base, part = z, excluded = excluded }
            end
        end
    end
    return out
end

local function zoneAt(pos)
    local m = map()
    local zf = m and m:FindFirstChild('Zones')
    if not zf then return nil end
    for _, z in ipairs(zf:GetChildren()) do
        if z:IsA('BasePart') and z:FindFirstChild('IsZone') then
            local l = z.CFrame:PointToObjectSpace(pos)
            if Pure.insideLocal(l.X, l.Y, l.Z, z.Size.X, z.Size.Y, z.Size.Z) then return z end
        end
    end
    return nil
end

local function orbZone()
    local m = map()
    local orbs = m and m:FindFirstChild('Orbs')
    if not orbs then return nil, nil end
    for _, o in ipairs(orbs:GetChildren()) do
        local z = o:FindFirstChild('Zone')
        if z and z:IsA('ObjectValue') and z.Value then return z.Value, o end
    end
    return nil, nil
end

-- ── tools (tracked as they appear, instead of scanning the whole map) ──
local tools = setmetatable({}, { __mode = 'k' })
local function trackTool(inst)
    if inst:IsA('Tool') then tools[inst] = true end
end
task.spawn(function()
    for _, d in ipairs(workspace:GetDescendants()) do if d:IsA('Tool') then tools[d] = true end end
    for _, p in ipairs(Players:GetPlayers()) do
        local bp = p:FindFirstChildOfClass('Backpack')
        if bp then for _, t in ipairs(bp:GetChildren()) do trackTool(t) end end
    end
end)
connect(workspace.DescendantAdded, trackTool)
local function hookBackpack(p)
    local function hb(bp)
        if bp and bp:IsA('Backpack') then
            for _, t in ipairs(bp:GetChildren()) do trackTool(t) end
            connect(bp.ChildAdded, trackTool)
        end
    end
    hb(p:FindFirstChildOfClass('Backpack'))
    connect(p.ChildAdded, hb)
end
for _, p in ipairs(Players:GetPlayers()) do hookBackpack(p) end
connect(Players.PlayerAdded, hookBackpack)

local function eachTool(name, fn)
    for t in pairs(tools) do
        if t.Parent and t.Name == name then fn(t) end
    end
end

-- ================================================================
--  EVIDENCE
-- ================================================================
local evidence = {
    table = nil,        -- ghost -> evidence list (from the server, like the journal)
    auto = {},          -- evidence seen by the script
    seenAt = {},
    lastPossibleCount = nil,
}

task.spawn(function()
    local remotes = RepStorage:WaitForChild('Remotes', 20)
    local info = remotes and remotes:WaitForChild('GetGhostInformation', 20)
    local rf = info and info:WaitForChild('GetGhostEvidences', 20)
    if not rf then return end
    local ok, res = pcall(rf.InvokeServer, rf)
    if ok and type(res) == 'table' then evidence.table = res end
end)

local function markAuto(name, why)
    if evidence.auto[name] then return end
    evidence.auto[name] = true
    evidence.seenAt[name] = os.clock()
    if on('Blair_EvidenceNotify') then notify('Evidence found: ' .. name .. ' (' .. why .. ')', 6) end
end

local function scanEvidence()
    eachTool('EMF Reader', function(t)
        if valueOf(t, 'RecentlyLevelFive') == true then markAuto('EMF Level 5', 'EMF reader hit 5') end
    end)
    eachTool('Thermometer', function(t)
        if valueOf(t, 'IsFreezing') == true then markAuto('Freezing Temperatures', 'thermometer') end
    end)
    eachTool('Ghost Writing Book', function(t)
        if valueOf(t, 'Written') == true then markAuto('Ghost Writing', 'book was written in') end
    end)
    for _, z in ipairs(zoneList(true)) do
        if z.temp < 0 then markAuto('Freezing Temperatures', z.name .. ' below 0') break end
    end
    local m = map()
    local prints = m and m:FindFirstChild('Prints')
    if prints then
        for _, p in ipairs(prints:GetDescendants()) do
            if p:IsA('BasePart') and p:GetAttribute('IsUVPart') then markAuto('Ultraviolet', 'UV print on the map') break end
        end
    end
    -- Orbs: the orb part is placed in a room; whether it exists for ghosts
    -- WITHOUT orb evidence is UNCONFIRMED, so this one is opt-in.
    if on('Blair_OrbCounts') and orbZone() then markAuto('Ghost Orb', 'orb part on the map') end
end

local function manualSet(prefix)
    local s = {}
    for _, e in ipairs(Pure.EVIDENCE) do
        if on(prefix .. Pure.SHORT[e]) then s[e] = true end
    end
    return s
end

local function foundSet()
    local s = manualSet('Blair_Have_')
    if on('Blair_AutoEvidence') then for e in pairs(evidence.auto) do s[e] = true end end
    return s
end

local function possible()
    if not evidence.table then return nil end
    return Pure.possibleGhosts(evidence.table, foundSet(), manualSet('Blair_No_'))
end

-- ================================================================
--  ESP  (BillboardGui labels; Highlights only for ghost + players,
--  Roblox draws at most 31 Highlights at once)
-- ================================================================
local guiParent
do
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then guiParent = h else
        local ok2, cg = pcall(function() return game:GetService('CoreGui') end)
        guiParent = ok2 and cg or LocalPlayer:WaitForChild('PlayerGui')
    end
end
local root = Instance.new('ScreenGui')
root.Name = 'YazuBlair'
root.ResetOnSpawn = false
root.IgnoreGuiInset = true
root.DisplayOrder = 50
root.Parent = guiParent
onCleanup(function() root:Destroy() end)
local espFolder = Instance.new('Folder')
espFolder.Name = 'ESP'
espFolder.Parent = root

local esp = {} -- key -> { bb, label, hl, box }
local function makeLabel(part, color)
    local bb = Instance.new('BillboardGui')
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(160, 34)
    bb.StudsOffset = Vector3.new(0, 2.2, 0)
    bb.LightInfluence = 0
    bb.Adornee = part
    local l = Instance.new('TextLabel')
    l.BackgroundTransparency = 1
    l.Size = UDim2.fromScale(1, 1)
    l.Font = Enum.Font.GothamBold
    l.TextSize = 13
    l.TextColor3 = color
    l.TextStrokeTransparency = 0.3
    l.TextWrapped = true
    l.Parent = bb
    bb.Parent = espFolder
    return bb, l
end

local function setEsp(key, part, color, text, withHighlight, model)
    local e = esp[key]
    if not part or not part.Parent then
        if e then
            pcall(function() e.bb:Destroy() end)
            if e.hl then pcall(function() e.hl:Destroy() end) end
            esp[key] = nil
        end
        return
    end
    if not e then
        local bb, l = makeLabel(part, color)
        e = { bb = bb, label = l }
        esp[key] = e
    end
    e.bb.Adornee = part
    e.label.TextColor3 = color
    e.label.Text = text
    if withHighlight then
        if not e.hl then
            local hl = Instance.new('Highlight')
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.FillTransparency = 0.7
            hl.OutlineTransparency = 0
            hl.Parent = espFolder
            e.hl = hl
        end
        e.hl.Adornee = model or part
        e.hl.FillColor = color
        e.hl.OutlineColor = color
    elseif e.hl then
        e.hl:Destroy()
        e.hl = nil
    end
    e.touched = true
end

local function sweepEsp()
    for key, e in pairs(esp) do
        if not e.touched then
            pcall(function() e.bb:Destroy() end)
            if e.hl then pcall(function() e.hl:Destroy() end) end
            esp[key] = nil
        else
            e.touched = false
        end
    end
end

local function partOf(inst)
    if inst:IsA('BasePart') then return inst end
    if inst:IsA('Model') then return inst.PrimaryPart or inst:FindFirstChildWhichIsA('BasePart', true) end
    if inst:IsA('Tool') then return inst:FindFirstChild('Handle') or inst:FindFirstChildWhichIsA('BasePart', true) end
    return inst:FindFirstChildWhichIsA('BasePart', true)
end

local function distText(part)
    local d = dist(part)
    return d and string.format(' [%dm]', math.floor(d + 0.5)) or ''
end

-- ================================================================
--  HUNT TRACKING
-- ================================================================
local hunt = { active = false, startedAt = 0, count = 0 }

local function nearestHidingSpot()
    local m = map()
    local r = myRoot()
    if not (m and r) then return nil end
    local best, bestD
    for _, folderName in ipairs({ 'Lockers', 'HidingSpots' }) do
        local f = m:FindFirstChild(folderName)
        if f then
            for _, d in ipairs(f:GetDescendants()) do
                if d:IsA('BasePart') and (d.Name == 'Hitbox' or d.Parent and d.Parent.Name == 'Available') then
                    local dd = (d.Position - r.Position).Magnitude
                    if not bestD or dd < bestD then best, bestD = d, dd end
                end
            end
        end
    end
    return best, bestD
end

local pingSound
local function playAlert()
    if not on('Blair_HuntSound') then return end
    if not pingSound then
        pingSound = Instance.new('Sound')
        pingSound.SoundId = 'rbxasset://sounds/electronicpingshort.wav'
        pingSound.Volume = 1
        pingSound.Parent = root
    end
    pcall(function() pingSound:Play() end)
end

local function updateHunt()
    local h = isHunting(ghost())
    if h and not hunt.active then
        hunt.active, hunt.startedAt, hunt.count = true, os.clock(), hunt.count + 1
        if on('Blair_HuntAlert') then
            notify('HUNT STARTED, hide!', 6)
            playAlert()
        end
    elseif not h and hunt.active then
        hunt.active = false
        if on('Blair_HuntAlert') then notify(string.format('Hunt over (%s)', Pure.fmtTime(os.clock() - hunt.startedAt)), 4) end
    end
end

-- ================================================================
--  HUD
-- ================================================================
local hud = Instance.new('Frame')
hud.Name = 'Info'
hud.Position = UDim2.fromOffset(16, 200)
hud.Size = UDim2.fromOffset(300, 10)
hud.AutomaticSize = Enum.AutomaticSize.Y
hud.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
hud.BackgroundTransparency = 0.25
hud.BorderSizePixel = 0
hud.Active = true
hud.Draggable = true
hud.Visible = false
hud.Parent = root
do
    local c = Instance.new('UICorner'); c.CornerRadius = UDim.new(0, 8); c.Parent = hud
    local s = Instance.new('UIStroke'); s.Color = Color3.fromRGB(170, 130, 255); s.Transparency = 0.4; s.Parent = hud
    local p = Instance.new('UIPadding')
    p.PaddingLeft, p.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
    p.PaddingTop, p.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
    p.Parent = hud
end
local hudText = Instance.new('TextLabel')
hudText.BackgroundTransparency = 1
hudText.Size = UDim2.new(1, 0, 0, 10)
hudText.AutomaticSize = Enum.AutomaticSize.Y
hudText.Font = Enum.Font.Code
hudText.TextSize = 14
hudText.TextColor3 = Color3.fromRGB(235, 235, 245)
hudText.TextXAlignment = Enum.TextXAlignment.Left
hudText.TextYAlignment = Enum.TextYAlignment.Top
hudText.TextWrapped = true
hudText.RichText = true
hudText.Parent = hud

local banner = Instance.new('TextLabel')
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.new(0.5, 0, 0, 70)
banner.Size = UDim2.fromOffset(420, 46)
banner.BackgroundColor3 = Color3.fromRGB(150, 0, 0)
banner.BackgroundTransparency = 0.15
banner.Font = Enum.Font.GothamBlack
banner.TextSize = 22
banner.TextColor3 = Color3.new(1, 1, 1)
banner.Visible = false
banner.Parent = root
do local c = Instance.new('UICorner'); c.CornerRadius = UDim.new(0, 10); c.Parent = banner end

local function col(hex, s) return string.format('<font color="#%s">%s</font>', hex, s) end
local function unit() return opt('Blair_TempUnit', 'C') == 'Fahrenheit' and 'F' or 'C' end

local function hudLines()
    local L = {}
    local rv = RepStorage:FindFirstChild('ReplicatedValues')
    local mapName = valueOf(rv, 'MapName') or '?'
    local weather = valueOf(rv, 'Weather') or '?'
    local act = RepStorage:FindFirstChild('Activity')
    L[#L + 1] = col('b48cff', 'Yazu Blair') .. string.format('  %s, %s', mapName, weather)
    if act and act:IsA('ValueBase') then L[#L + 1] = 'Activity: ' .. tostring(act.Value) end

    local zv = LocalPlayer:FindFirstChild('Zone')
    local myZone = zv and zv.Value
    if myZone then
        local t = zoneTemp(myZone)
        L[#L + 1] = string.format('You: %s  %s', myZone.Name, Pure.fmtTemp(t, unit()))
    end

    local zones = zoneList(false)
    local cold, drop = Pure.coldestZone(zones)
    if cold then
        L[#L + 1] = string.format('Coldest room: %s  %s (%.1f below normal)', col('7fd4ff', cold.name), Pure.fmtTemp(cold.temp, unit()), drop or 0)
    end
    local oz = orbZone()
    if oz then L[#L + 1] = 'Orb room: ' .. col('ffe680', oz.Name) end

    local g = ghost()
    local gr = ghostRoot(g)
    if gr then
        local gz = zoneAt(gr.Position)
        L[#L + 1] = string.format('Ghost: %s%s%s', gz and gz.Name or 'outside rooms', distText(gr),
            isHunting(g) and col('ff4040', '  HUNTING') or '')
    end
    if hunt.count > 0 then L[#L + 1] = string.format('Hunts so far: %d', hunt.count) end

    local found = foundSet()
    local parts = {}
    for _, e in ipairs(Pure.EVIDENCE) do
        local s = Pure.SHORT[e]
        if found[e] then parts[#parts + 1] = col('6dff8a', s)
        elseif on('Blair_No_' .. s) then parts[#parts + 1] = col('ff6060', '-' .. s)
        else parts[#parts + 1] = col('808090', s) end
    end
    L[#L + 1] = 'Evidence: ' .. table.concat(parts, ' ')

    local poss = possible()
    if poss then
        if #poss == 0 then
            L[#L + 1] = col('ff6060', 'No ghost matches. Check your marks.')
        elseif #poss <= 8 then
            L[#L + 1] = string.format('Possible (%d): %s', #poss, col('ffd070', table.concat(poss, ', ')))
        else
            L[#L + 1] = string.format('Possible: %d ghosts', #poss)
        end
        if #poss > 1 then
            local nxt = Pure.nextEvidence(evidence.table, poss, found)
            local tips = {}
            for i = 1, math.min(3, #nxt) do
                if nxt[i][2] < #poss then tips[#tips + 1] = Pure.SHORT[nxt[i][1]] or nxt[i][1] end
            end
            if #tips > 0 then L[#L + 1] = 'Test next: ' .. table.concat(tips, ', ') end
        end
        if evidence.lastPossibleCount ~= #poss then
            if #poss == 1 and evidence.lastPossibleCount and on('Blair_EvidenceNotify') then
                notify('It has to be: ' .. poss[1], 8)
            end
            evidence.lastPossibleCount = #poss
        end
    else
        L[#L + 1] = col('808090', 'Ghost list: waiting for the journal data')
    end
    return L
end

-- ================================================================
--  UI
-- ================================================================
local GhostGrp    = Tab:AddLeftGroupbox('Ghost')
local EvidenceGrp = Tab:AddLeftGroupbox('Evidence')
local EspGrp      = Tab:AddRightGroupbox('ESP')
local PlayerGrp   = Tab:AddRightGroupbox('Player')
local HudGrp      = Tab:AddRightGroupbox('Info panel')

GhostGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = true,
    Tooltip = 'Outline + label on workspace.Ghost: room, distance, hunting. The outline may not show while the ghost is fully invisible; the label always does.' })
GhostGrp:AddLabel('Ghost color'):AddColorPicker('Blair_GhostCol', { Default = Color3.fromRGB(255, 60, 60), Title = 'Ghost ESP' })
GhostGrp:AddToggle('Blair_HuntAlert', { Text = 'Hunt alert (banner + notify)', Default = true })
GhostGrp:AddToggle('Blair_HuntSound', { Text = 'Hunt alert sound', Default = true })
GhostGrp:AddToggle('Blair_HideSpot', { Text = 'Show nearest hiding spot in a hunt', Default = true })
GhostGrp:AddToggle('Blair_RoomESP', { Text = 'Mark coldest room', Default = true,
    Tooltip = 'Label on the room that has cooled the most from its normal temperature: usually the ghost room.' })
GhostGrp:AddToggle('Blair_AllTemps', { Text = 'Label every room with its temperature', Default = false })
GhostGrp:AddDropdown('Blair_TempUnit', { Text = 'Temperature unit', Values = { 'Celsius', 'Fahrenheit' }, Default = 1 })

EvidenceGrp:AddToggle('Blair_AutoEvidence', { Text = 'Auto-detect evidence', Default = true,
    Tooltip = 'EMF 5, freezing, ghost writing and UV prints are read from the game. Spirit Box and SLS need a manual mark.' })
EvidenceGrp:AddToggle('Blair_OrbCounts', { Text = 'Count orb part as Ghost Orb', Default = false,
    Tooltip = 'UNCONFIRMED: the orb part may exist even when the ghost has no orbs. Leave off until you see it match a few times.' })
EvidenceGrp:AddToggle('Blair_EvidenceNotify', { Text = 'Notify on new evidence / final ghost', Default = true })
EvidenceGrp:AddLabel('Found (manual):')
for _, e in ipairs(Pure.EVIDENCE) do
    EvidenceGrp:AddToggle('Blair_Have_' .. Pure.SHORT[e], { Text = 'Have: ' .. e, Default = false })
end
EvidenceGrp:AddLabel('Ruled out (manual):')
for _, e in ipairs(Pure.EVIDENCE) do
    EvidenceGrp:AddToggle('Blair_No_' .. Pure.SHORT[e], { Text = 'Not: ' .. e, Default = false })
end
EvidenceGrp:AddButton({ Text = 'Reset evidence (new match)', Func = function()
    evidence.auto, evidence.seenAt, evidence.lastPossibleCount = {}, {}, nil
    for _, e in ipairs(Pure.EVIDENCE) do
        for _, pre in ipairs({ 'Blair_Have_', 'Blair_No_' }) do
            local t = Toggles[pre .. Pure.SHORT[e]]
            if t and t.Value then pcall(t.SetValue, t, false) end
        end
    end
    hunt.count = 0
    notify('Evidence cleared', 3)
end })
EvidenceGrp:AddButton({ Text = 'Print possible ghosts', Func = function()
    local p = possible()
    if not p then notify('Journal data not loaded yet', 4) return end
    notify(#p > 0 and ('Possible: ' .. table.concat(p, ', ')) or 'No ghost matches', 10)
end })

EspGrp:AddToggle('Blair_ItemESP', { Text = 'Item ESP', Default = false })
EspGrp:AddToggle('Blair_VanItemsOnly', { Text = 'Only van equipment', Default = false })
EspGrp:AddToggle('Blair_CursedESP', { Text = 'Cursed object ESP', Default = true })
EspGrp:AddToggle('Blair_UVESP', { Text = 'UV print ESP', Default = true })
EspGrp:AddToggle('Blair_OrbESP', { Text = 'Orb ESP', Default = false })
EspGrp:AddToggle('Blair_PlayerESP', { Text = 'Teammate ESP', Default = false })
EspGrp:AddToggle('Blair_HidingESP', { Text = 'Hiding spot ESP', Default = false })
EspGrp:AddToggle('Blair_GeneratorESP', { Text = 'Generator / fuse ESP', Default = false })
EspGrp:AddSlider('Blair_ESPRange', { Text = 'Item ESP range (studs)', Default = 250, Min = 25, Max = 1000, Rounding = 0 })

PlayerGrp:AddToggle('Blair_Speed', { Text = 'Walk speed override', Default = false })
PlayerGrp:AddSlider('Blair_SpeedValue', { Text = 'Walk speed', Default = 14, Min = 6, Max = 40, Rounding = 0,
    Tooltip = 'The game walks at about 6.5. Big jumps here are easy for the server to notice.' })
PlayerGrp:AddToggle('Blair_Stamina', { Text = 'Infinite stamina', Default = false,
    Tooltip = "Sets the game's own StaminaImmune flag on your client. The server can ask for your stamina (AskClientStamina); whether it reacts is UNCONFIRMED." })
PlayerGrp:AddToggle('Blair_Jump', { Text = 'Allow jumping', Default = false })
PlayerGrp:AddSlider('Blair_JumpValue', { Text = 'Jump power', Default = 40, Min = 20, Max = 120, Rounding = 0 })

HudGrp:AddToggle('Blair_HUD', { Text = 'Show info panel (drag to move)', Default = true })
HudGrp:AddToggle('Blair_Crosshair', { Text = 'Crosshair', Default = false })

-- ================================================================
--  LOOPS
-- ================================================================
local itemColorVan = Color3.fromRGB(120, 200, 255)
local itemColorMap = Color3.fromRGB(200, 200, 200)
local cursedColor  = Color3.fromRGB(200, 90, 255)

local function drawEsp()
    local m = map()
    local ghostCol = opt('Blair_GhostCol', Color3.fromRGB(255, 60, 60))

    -- ghost
    local g = ghost()
    local gr = ghostRoot(g)
    if on('Blair_GhostESP') and gr then
        local gz = zoneAt(gr.Position)
        local name = valueOf(g, 'OriginalGhostName')
        local txt = (isHunting(g) and 'HUNTING\n' or '') .. (name and name ~= '' and name or 'Ghost')
            .. distText(gr) .. (gz and ('\n' .. gz.Name) or '')
        setEsp('ghost', gr, isHunting(g) and Color3.fromRGB(255, 0, 0) or ghostCol, txt, true, g)
    end

    -- rooms
    local zones = zoneList(true)
    local cold = Pure.coldestZone((function()
        local t = {}
        for _, z in ipairs(zones) do if not z.excluded then t[#t + 1] = z end end
        return t
    end)())
    for _, z in ipairs(zones) do
        local isCold = cold and z.part == cold.part
        if (on('Blair_RoomESP') and isCold) or on('Blair_AllTemps') then
            setEsp('zone:' .. z.name, z.part, isCold and Color3.fromRGB(120, 210, 255) or Color3.fromRGB(180, 180, 190),
                (isCold and 'COLDEST  ' or '') .. z.name .. '  ' .. Pure.fmtTemp(z.temp, unit()), false)
        end
    end

    if not m then return end
    local range = opt('Blair_ESPRange', 250)

    -- items
    if on('Blair_ItemESP') then
        local items = m:FindFirstChild('Items')
        if items then
            for _, it in ipairs(items:GetChildren()) do
                local van = it:GetAttribute('VanItem') == true
                if van or not on('Blair_VanItemsOnly') then
                    local p = partOf(it)
                    local d = p and dist(p)
                    if p and (not d or d <= range) then
                        setEsp(it, p, van and itemColorVan or itemColorMap, it.Name .. distText(p), false)
                    end
                end
            end
        end
    end

    -- cursed objects (tag CursedObject; Map.CursedSpawns holds the spawn spots)
    if on('Blair_CursedESP') then
        for _, c in ipairs(CollectionService:GetTagged('CursedObject')) do
            local p = c:IsDescendantOf(workspace) and partOf(c)
            if p then setEsp(c, p, cursedColor, 'CURSED: ' .. c.Name .. distText(p), false) end
        end
    end

    -- UV prints
    if on('Blair_UVESP') then
        local prints = m:FindFirstChild('Prints')
        if prints then
            for _, p in ipairs(prints:GetDescendants()) do
                if p:IsA('BasePart') and p:GetAttribute('IsUVPart') then
                    setEsp(p, p, Color3.fromRGB(120, 255, 140), 'UV' .. distText(p), false)
                end
            end
        end
    end

    -- orbs
    if on('Blair_OrbESP') then
        local orbs = m:FindFirstChild('Orbs')
        if orbs then
            for _, o in ipairs(orbs:GetChildren()) do
                local p = partOf(o)
                local z = o:FindFirstChild('Zone')
                if p then setEsp(o, p, Color3.fromRGB(255, 230, 120),
                    'Orb' .. (z and z.Value and (' (' .. z.Value.Name .. ')') or '') .. distText(p), false) end
            end
        end
    end

    -- hiding spots
    if on('Blair_HidingESP') then
        local lockers = m:FindFirstChild('Lockers')
        if lockers then
            for _, l in ipairs(lockers:GetChildren()) do
                local p = l:FindFirstChild('Hitbox') or partOf(l)
                if p then setEsp(l, p, Color3.fromRGB(150, 255, 200),
                    'Hide: ' .. l.Name .. ' (' .. tostring(valueOf(l, 'State') or '?') .. ')' .. distText(p), false) end
            end
        end
    end

    -- generator
    if on('Blair_GeneratorESP') then
        local gens = m:FindFirstChild('Generators')
        if gens then
            for _, gm in ipairs(gens:GetChildren()) do
                local p = partOf(gm)
                if p then setEsp(gm, p, Color3.fromRGB(255, 180, 60), 'Generator' .. distText(p), false) end
            end
        end
    end

    -- teammates
    if on('Blair_PlayerESP') then
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LocalPlayer and pl.Character then
                local hrp = pl.Character:FindFirstChild('HumanoidRootPart')
                if hrp then
                    local dead = valueOf(pl, 'Dead') == true
                    local zv = pl:FindFirstChild('Zone')
                    local zn = zv and zv.Value and zv.Value.Name
                    setEsp('player:' .. pl.UserId, hrp, dead and Color3.fromRGB(130, 130, 130) or Color3.fromRGB(120, 255, 160),
                        pl.DisplayName .. (dead and ' (dead)' or '') .. distText(hrp) .. (zn and ('\n' .. zn) or ''), true, pl.Character)
                end
            end
        end
    end
end

-- crosshair (Drawing API is optional)
local cross = {}
if type(Drawing) == 'table' or type(Drawing) == 'userdata' then
    pcall(function()
        cross.a, cross.b = Drawing.new('Line'), Drawing.new('Line')
        for _, l in pairs(cross) do l.Thickness = 2; l.Color = Color3.fromRGB(180, 140, 255); l.Visible = false end
    end)
    onCleanup(function() for _, l in pairs(cross) do pcall(function() l:Remove() end) end end)
end

local slow = 0
connect(RunService.Heartbeat, function(dt)
    -- movement / stamina every frame (the game resets WalkSpeed itself)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass('Humanoid')
    if hum then
        if on('Blair_Speed') then hum.WalkSpeed = opt('Blair_SpeedValue', 14) end
        if on('Blair_Jump') then hum.UseJumpPower = true; hum.JumpPower = opt('Blair_JumpValue', 40) end
    end

    slow = slow + dt
    if slow < 0.25 then return end
    slow = 0

    pcall(updateHunt)
    if on('Blair_AutoEvidence') then pcall(scanEvidence) end
    local ok, err = pcall(drawEsp)
    if not ok then warn('[Yazu Blair] esp: ' .. tostring(err)) end
    sweepEsp()

    -- banner
    if hunt.active and on('Blair_HuntAlert') then
        local txt = 'HUNT  ' .. Pure.fmtTime(os.clock() - hunt.startedAt)
        if on('Blair_HideSpot') then
            local spot, d = nearestHidingSpot()
            if spot and d then txt = txt .. string.format('   hide: %s %dm', spot.Parent and spot.Parent.Name or 'spot', math.floor(d + 0.5)) end
        end
        banner.Text = txt
        banner.Visible = true
    else
        banner.Visible = false
    end

    hud.Visible = on('Blair_HUD')
    if hud.Visible then
        local okH, lines = pcall(hudLines)
        hudText.Text = okH and table.concat(lines, '\n') or ('info error: ' .. tostring(lines))
    end
end)

connect(RunService.RenderStepped, function()
    if not cross.a then return end
    local show = on('Blair_Crosshair')
    cross.a.Visible, cross.b.Visible = show, show
    if show then
        local c = workspace.CurrentCamera.ViewportSize / 2
        cross.a.From, cross.a.To = c - Vector2.new(9, 0), c + Vector2.new(9, 0)
        cross.b.From, cross.b.To = c - Vector2.new(0, 9), c + Vector2.new(0, 9)
    end
end)

-- infinite stamina: only touch the attribute when we set it
local staminaSet = false
local function applyStamina()
    if on('Blair_Stamina') then
        pcall(function() LocalPlayer:SetAttribute('StaminaImmune', true) end)
        staminaSet = true
    elseif staminaSet then
        pcall(function() LocalPlayer:SetAttribute('StaminaImmune', nil) end)
        staminaSet = false
    end
end
if Toggles.Blair_Stamina then Toggles.Blair_Stamina:OnChanged(applyStamina) end
connect(LocalPlayer:GetAttributeChangedSignal('StaminaImmune'), function()
    if on('Blair_Stamina') and LocalPlayer:GetAttribute('StaminaImmune') ~= true then applyStamina() end
end)
onCleanup(function() if staminaSet then pcall(function() LocalPlayer:SetAttribute('StaminaImmune', nil) end) end end)

notify('Yazu Blair v3 loaded', 4)

end
