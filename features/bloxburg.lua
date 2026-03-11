-- ================================================================
--  features/bloxburg.lua
--  Contains: All Bloxburg auto-farm, auto-build, and misc logic.
--  This is the largest file — ~600 lines but entirely self-contained.
-- ================================================================

return function(State, Tabs, Services, Library)

local TweenService    = Services.TweenService
local Players         = Services.Players
local LocalPlayer     = Services.LocalPlayer
local _PathSvc        = Services.PathfindingService
local _HttpSvc        = Services.HttpService
local _RepStore       = Services.ReplicatedStorage
local _CollSvc        = Services.CollectionService
local _Heartbt        = Services.RunService.Heartbeat

-- ── Forward-declare job function handles ──────────────────────
local _bxFW, _bxNet, _bxJobs
local _bxReady = false

local _fnDelivery, _fnBensIceCream, _fnStylezHair, _fnBloxyBurgers
local _fnPizzaBaker, _fnFisherman, _fnMechanic, _fnLumber
local _fnMiner, _fnJanitor, _fnSuperCashier, _fnStocker
local _fnSaveHouse, _fnLoadHouse, _fnTeleportPlot

local function _notReady() Library:Notify('Still loading Bloxburg framework…') end
local function _call(fnRef, v)
    if not _bxReady then _notReady(); return end
    if fnRef then task.spawn(fnRef, v) end
end

-- ================================================================
--  UI — BXBRG TAB  (always built immediately, no waiting)
-- ================================================================
local BX_FarmGrp  = Tabs.BXBRG:AddLeftGroupbox('Auto Farm')
local BX_BuildGrp = Tabs.BXBRG:AddRightGroupbox('Auto Build')
local BX_MiscGrp  = Tabs.BXBRG:AddLeftGroupbox('Misc')

BX_FarmGrp:AddToggle('BX_PizzaDelivery',      { Text = 'Pizza Delivery',      Default = false, Callback = function(v) if _fnDelivery then task.spawn(_fnDelivery, v) else Library:Notify('Still loading…') end end })
BX_FarmGrp:AddToggle('BX_BensIceCream',       { Text = 'Bens Ice Cream',      Default = false, Callback = function(v) _call(_fnBensIceCream, v)  end })
BX_FarmGrp:AddToggle('BX_StylezHairDresser',  { Text = 'Stylez Hair Dresser', Default = false, Callback = function(v) _call(_fnStylezHair, v)    end })
BX_FarmGrp:AddToggle('BX_BloxyBurgers',       { Text = 'Bloxy Burgers',       Default = false, Callback = function(v) _call(_fnBloxyBurgers, v)  end })
BX_FarmGrp:AddToggle('BX_PizzaBaker',         { Text = 'Pizza Baker',         Default = false, Callback = function(v) _call(_fnPizzaBaker, v)    end })
BX_FarmGrp:AddToggle('BX_Fisherman',          { Text = 'Fisherman',           Default = false, Callback = function(v) _call(_fnFisherman, v)     end })
BX_FarmGrp:AddToggle('BX_Mechanic',           { Text = 'Mechanic',            Default = false, Callback = function(v) _call(_fnMechanic, v)      end })
BX_FarmGrp:AddToggle('BX_Lumber',             { Text = 'Lumber',              Default = false, Callback = function(v) _call(_fnLumber, v)        end })
BX_FarmGrp:AddToggle('BX_Miner',              { Text = 'Miner',               Default = false, Callback = function(v) _call(_fnMiner, v)         end })
BX_FarmGrp:AddToggle('BX_Janitor',            { Text = 'Janitor',             Default = false, Callback = function(v) _call(_fnJanitor, v)       end })
BX_FarmGrp:AddToggle('BX_SupermarketCashier', { Text = 'Supermarket Cashier', Default = false, Callback = function(v) _call(_fnSuperCashier, v)  end })
BX_FarmGrp:AddToggle('BX_SupermarketStocker', { Text = 'Supermarket Stocker', Default = false, Callback = function(v) _call(_fnStocker, v)       end })

-- Auto Build
BX_BuildGrp:AddLabel('Copy House')
BX_BuildGrp:AddDropdown('BX_CopyHousePlayer', {
    Text = 'Select Player', Default = 1,
    Values = (function()
        local names = {}
        for _, p in next, Players:GetPlayers() do if p ~= LocalPlayer then table.insert(names, p.Name) end end
        return #names > 0 and names or {''}
    end)(),
})
BX_BuildGrp:AddButton({ Text = 'Copy House', Func = function()
    if not _bxReady then _notReady() return end
    local name = Options.BX_CopyHousePlayer and Options.BX_CopyHousePlayer.Value or ''
    if name == '' then Library:Notify('No player selected!') return end
    local target = Players:FindFirstChild(name)
    if not target then Library:Notify('Player not found!') return end
    if _fnSaveHouse then task.spawn(_fnSaveHouse, target) end
end })

BX_BuildGrp:AddDivider()
BX_BuildGrp:AddLabel('Load Saved House')

local function _bxRefreshHouseList()
    if not isfolder('Yazu') then makefolder('Yazu') end
    if not isfolder('Yazu/Bloxburg Houses') then makefolder('Yazu/Bloxburg Houses') end
    local ok, files = pcall(listfiles, 'Yazu/Bloxburg Houses')
    if not ok then files = {} end
    local names = {}
    for _, f in next, files do
        local n = f:match('Yazu[/\\]Bloxburg Houses[/\\](.+)') or f:match('([^/\\]+)$')
        if n and n ~= '' then table.insert(names, n) end
    end
    if #names == 0 then names = {''} end
    if Options.BX_LoadHouseFile then Options.BX_LoadHouseFile:SetValues(names) end
    return names
end

BX_BuildGrp:AddDropdown('BX_LoadHouseFile', { Text = 'Select House File', Default = 1, Values = _bxRefreshHouseList() })
BX_BuildGrp:AddButton({ Text = 'Refresh File List', Func = _bxRefreshHouseList })
BX_BuildGrp:AddButton({ Text = 'Load House', Func = function()
    if not _bxReady then _notReady() return end
    local file = Options.BX_LoadHouseFile and Options.BX_LoadHouseFile.Value or ''
    if file == '' then Library:Notify('No file selected!') return end
    local ok, data = pcall(readfile, 'Yazu/Bloxburg Houses/' .. file)
    if not ok then Library:Notify('Error reading file!') return end
    local houseData = _HttpSvc:JSONDecode(data)
    local bsVal    = houseData.bsValue    or 0
    local totalVal = (houseData.totalValue or 0) - (bsVal * 20)
    Library:Notify(string.format('Loading… Cost: $%s | %s BloxBux', totalVal, bsVal))
    if _fnLoadHouse then task.spawn(_fnLoadHouse, houseData) end
end })

-- Misc
BX_MiscGrp:AddLabel('Teleport to Player Plot')
BX_MiscGrp:AddDropdown('BX_TpPlotPlayer', {
    Text = 'Select Player', Default = 1,
    Values = (function()
        local names = {}
        for _, p in next, Players:GetPlayers() do if p ~= LocalPlayer then table.insert(names, p.Name) end end
        return #names > 0 and names or {''}
    end)(),
})
BX_MiscGrp:AddButton({ Text = 'Teleport to Plot', Func = function()
    if not _bxReady then _notReady() return end
    local name = Options.BX_TpPlotPlayer and Options.BX_TpPlotPlayer.Value or ''
    if name == '' then Library:Notify('No player selected!') return end
    if _fnTeleportPlot then _fnTeleportPlot(name) end
end })

-- Player dropdown refresh
local function _bxUpdatePlayerDropdowns()
    local vals = {}
    for _, p in next, Players:GetPlayers() do if p ~= LocalPlayer then table.insert(vals, p.Name) end end
    if #vals == 0 then vals = {''} end
    if Options.BX_CopyHousePlayer then Options.BX_CopyHousePlayer:SetValues(vals) end
    if Options.BX_TpPlotPlayer     then Options.BX_TpPlotPlayer:SetValues(vals)     end
end
Players.PlayerAdded:Connect(_bxUpdatePlayerDropdowns)
Players.PlayerRemoving:Connect(function() task.defer(_bxUpdatePlayerDropdowns) end)

-- ================================================================
--  PIZZA DELIVERY  (standalone, no framework needed)
-- ================================================================
local BOX_TAG    = 'PizzaPlanetDeliveryCustomer'
local TWEEN_SPEED = 28

local function _getDeliveryRemote()
    local ds = _RepStore:WaitForChild('Modules', 10):WaitForChild('DataService', 10)
    local child = ds:GetChildren()[1]
    if not child then Library:Notify('[Pizza] DataService remote not found!'); return nil end
    local remote = child:FindFirstChild(child.Name)
    if not remote then Library:Notify('[Pizza] Remote not found!'); return nil end
    return remote
end

local function _safeMove(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart'); if not root then return end
    local dist = (root.Position - targetPos).Magnitude; if dist < 4 then return end
    local cfVal = Instance.new('CFrameValue'); cfVal.Value = root.CFrame
    local conn = cfVal:GetPropertyChangedSignal('Value'):Connect(function()
        if LocalPlayer.Character then LocalPlayer.Character:SetPrimaryPartCFrame(cfVal.Value) end
    end)
    local tw = TweenService:Create(cfVal, TweenInfo.new(dist / TWEEN_SPEED, Enum.EasingStyle.Linear), { Value = CFrame.new(targetPos) })
    tw:Play()
    local done = false; tw.Completed:Connect(function() done = true end)
    repeat task.wait(0.05) until done or not (Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value)
    tw:Cancel(); conn:Disconnect(); cfVal:Destroy()
end

local function _getConveyorBox()
    local conveyor = workspace:FindFirstChild('Environment')
        and workspace.Environment:FindFirstChild('Locations')
        and workspace.Environment.Locations:FindFirstChild('City')
        and workspace.Environment.Locations.City:FindFirstChild('PizzaPlanet')
        and workspace.Environment.Locations.City.PizzaPlanet:FindFirstChild('Interior')
        and workspace.Environment.Locations.City.PizzaPlanet.Interior:FindFirstChild('Conveyor')
        and workspace.Environment.Locations.City.PizzaPlanet.Interior.Conveyor:FindFirstChild('MovingBoxes')
    if not conveyor then return nil end
    return conveyor:FindFirstChildWhichIsA('UnionOperation')
end

_fnDelivery = function(toggle)
    if not toggle then return end
    local remote = _getDeliveryRemote(); if not remote then return end
    Library:Notify('[Pizza Delivery] Starting loop…')
    while Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value do
        task.wait(0.1)
        local char = LocalPlayer.Character; if not char then task.wait(1); continue end
        local box = _getConveyorBox(); if not box then task.wait(0.5); continue end
        local result, attempts = nil, 0
        repeat
            attempts = attempts + 1; box = _getConveyorBox(); if not box then break end
            char = LocalPlayer.Character
            if char then char:SetPrimaryPartCFrame(CFrame.new(box.Position + Vector3.new(0, 3, 0))) end
            task.wait(0.05); keypress(0x45); task.wait(0.05); keyrelease(0x45); task.wait(0.1)
            char = LocalPlayer.Character
            if char and char:FindFirstChild('Pizza Box') then result = true end
        until result or attempts >= 40 or not (Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value)
        if not (Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value) then break end
        if not result then task.wait(1); continue end
        Library:Notify('[Pizza] Got box! Finding customer…')
        local customer, waitAttempts = nil, 0
        repeat
            task.wait(0.2); waitAttempts = waitAttempts + 1
            local tagged = _CollSvc:GetTagged(BOX_TAG)
            if #tagged > 0 then customer = tagged[1] end
        until customer or waitAttempts >= 25
        if not customer then Library:Notify('[Pizza] No customer, retrying…'); task.wait(1); continue end
        local customerHRP = customer:FindFirstChild('HumanoidRootPart') or customer.PrimaryPart
        if not customerHRP then task.wait(0.5); continue end
        Library:Notify('[Pizza] Walking to customer…')
        _safeMove(customerHRP.Position + Vector3.new(0, 3, 0))
        if not (Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value) then break end
        char = LocalPlayer.Character
        if char then char:SetPrimaryPartCFrame(CFrame.new(customerHRP.Position + Vector3.new(0, 3, 2))) end
        task.wait(0.2); keypress(0x45); task.wait(0.1); keyrelease(0x45)
        Library:Notify('[Pizza] Delivered! Waiting for next box…')
        local timeout = 0
        repeat task.wait(0.2); timeout = timeout + 0.2
        until not (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild('Pizza Box')) or timeout >= 10
        task.wait(0.5)
    end
    Library:Notify('[Pizza Delivery] Stopped.')
end

-- ================================================================
--  FRAMEWORK BOOTSTRAP + ALL JOB FUNCTIONS  (async)
-- ================================================================
task.spawn(function()
    local ok, fw = pcall(function()
        local m = require(_RepStore:WaitForChild('Framework', 10))
        return m and getupvalue(m, 3) or nil
    end)
    if not ok or not fw then
        Library:Notify('[BXBRG] Framework not found — run inside Bloxburg!'); return
    end
    _bxFW = fw
    local _bxMods, _bxGui
    repeat task.wait()
        _bxMods = _bxFW.Modules; _bxNet = _bxFW.net
        _bxJobs = _bxMods and _bxMods.JobHandler; _bxGui = _bxMods and _bxMods.GUIHandler
    until _bxMods and _bxNet and _bxJobs and _bxGui

    if not isfolder('Yazu/Bloxburg Houses') then makefolder('Yazu/Bloxburg Houses') end
    pcall(function() hookfunction(getfenv(_bxNet.FireServer).i, function() print('Ban attempt blocked') end) end)

    -- Helpers
    local function _tweenTP(position)
        local root = LocalPlayer.Character and LocalPlayer.Character.PrimaryPart; if not root then return end
        local path = _PathSvc:CreatePath(); path:ComputeAsync(root.Position, position)
        local waypoints = path:GetWaypoints()
        local cfVal = Instance.new('CFrameValue'); cfVal.Value = root.CFrame
        local conn = cfVal:GetPropertyChangedSignal('Value'):Connect(function()
            LocalPlayer.Character:SetPrimaryPartCFrame(cfVal.Value)
        end)
        for _, wp in next, waypoints do
            local ti = TweenInfo.new((root.Position - wp.Position).Magnitude / 20, Enum.EasingStyle.Linear)
            local tw = TweenService:Create(cfVal, ti, { Value = CFrame.new(wp.Position + Vector3.new(0,4,0)) })
            tw:Play(); tw.Completed:Wait()
        end
        conn:Disconnect(); cfVal:Destroy()
    end

    local function _findWS(stations)
        local best, bd = nil, math.huge
        local root = LocalPlayer.Character and LocalPlayer.Character.PrimaryPart; if not root then return end
        for _, v in next, stations:GetChildren() do
            local d = (root.Position - v.PrimaryPart.Position).Magnitude
            if d < bd and (v.InUse.Value == nil or v.InUse.Value == LocalPlayer) then bd, best = d, v end
        end
        return best
    end

    local function _findWSBens(stations)
        for _, v in next, stations:GetChildren() do
            local c = v.Occupied.Value
            if c and c.Order.Value == '' then return v end
        end
    end

    -- NameCall hook (auto-complete orders)
    local _bxOldNC
    _bxOldNC = hookmetamethod(game, '__namecall', function(...)
        SX_VM_CNONE()
        local args = {...}; local self = args[1]
        if typeof(self) ~= 'Instance' then return _bxOldNC(...) end
        if checkcaller() and getnamecallmethod() == 'FireServer' and args[2] and args[2].Order and args[2].Workstation then
            local ws = args[2].Workstation
            if ws.Parent.Name == 'HairdresserWorkstations' and Toggles.BX_StylezHairDresser and Toggles.BX_StylezHairDresser.Value then
                args[2].Order = { ws.Occupied.Value.Order.Style.Value, ws.Occupied.Value.Order.Color.Value }
            elseif ws.Parent.Name == 'CashierWorkstations' and Toggles.BX_BloxyBurgers and Toggles.BX_BloxyBurgers.Value then
                args[2].Order = { ws.Occupied.Value.Order.Burger.Value, ws.Occupied.Value.Order.Fries.Value, ws.Occupied.Value.Order.Cola.Value }
            elseif ws.Parent.Name == 'BakerWorkstations' and Toggles.BX_PizzaBaker and Toggles.BX_PizzaBaker.Value then
                args[2].Order = { true, true, true, ws.Order.Value }
            end
        end
        return _bxOldNC(unpack(args))
    end)

    -- Suppress EndShift during delivery
    local oldFS = _bxNet.FireServer
    oldFS = hookfunction(_bxNet.FireServer, function(self, data, ...)
        if data.Type == 'EndShift' and Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value then return end
        return pcall(oldFS, self, data, ...)
    end)

    -- ── Save House ────────────────────────────────────────────
    _fnSaveHouse = function(player)
        local plot   = workspace.Plots[string.format('Plot_%s', player.Name)]
        local ground = plot.Ground
        local save   = { Walls={}, Paths={}, Floors={}, Roofs={}, Pools={}, Fences={}, Ground={ Counters={}, Objects={} }, Basements={} }
        local function getRot(obj) return tostring(plot.PrimaryPart.CFrame:ToObjectSpace(obj)) end
        local function getFloor(pos)
            local cf, cd = nil, math.huge
            for _, v in next, plot.House.Floor:GetChildren() do
                local d = (v.Part.Position - pos).Magnitude
                if d <= cd then cf, cd = v, d end
            end
            return cf
        end
        local function getPolePos(pole)
            pole = pole.Value
            return pole.Parent:IsA('BasePart') and pole.Parent.Position or pole.Parent.Value
        end
        local objs, cnts = {}, {}
        for _, obj in next, plot.House.Objects:GetChildren() do
            local floor = getFloor(obj.Position) or plot
            local od = { Name=obj.Name, AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(obj), Rot=getRot(obj.CFrame), Position=tostring(ground.CFrame:PointToObjectSpace(obj.Position)) }
            if not objs[floor] then objs[floor] = {} end
            if obj:FindFirstChild('ItemHolder') then
                for _, item in next, obj.ItemHolder:GetChildren() do
                    if item:FindFirstChild('RailingSegment') then
                        od.Fences = od.Fences or {}
                        local _, from = _bxFW.Shared.FenceService:GetEdgePositions(item)
                        table.insert(od.Fences, { Name=item.Name, From=tostring(ground.CFrame:PointToObjectSpace(from)), AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(item), Segment=item.RailingSegment.Value.Name })
                    else
                        od.Items = od.Items or {}
                        table.insert(od.Items, { Name=item.Name, AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(item), Rot=getRot(item.CFrame), Position=tostring(ground.CFrame:PointToObjectSpace(item.Position)) })
                    end
                end
            end
            table.insert(objs[floor], od)
        end
        for _, cnt in next, plot.House.Counters:GetChildren() do
            local floor = getFloor(cnt.Position) or plot
            local cd = { Name=cnt.Name, AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(cnt), Rot=getRot(cnt.CFrame), Position=tostring(ground.CFrame:PointToObjectSpace(cnt.Position)) }
            if not cnts[floor] then cnts[floor] = {} end
            if cnt:FindFirstChild('ItemHolder') then
                for _, item in next, cnt.ItemHolder:GetChildren() do
                    cd.Items = cd.Items or {}
                    table.insert(cd.Items, { Name=item.Name, AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(item), Rot=getRot(item.CFrame), Position=tostring(ground.CFrame:PointToObjectSpace(item.Position)) })
                end
            end
            table.insert(cnts[floor], cd)
        end
        for _, wall in next, plot.House.Walls:GetChildren() do
            if wall.Name == 'Poles' then continue end
            local from, to = ground.CFrame:PointToObjectSpace(getPolePos(wall.BPole)), ground.CFrame:PointToObjectSpace(getPolePos(wall.FPole))
            local wd = { From=tostring(from), To=tostring(to), AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(wall), Items={} }
            if wall:FindFirstChild('ItemHolder') then
                for _, item in next, wall.ItemHolder:GetChildren() do
                    local id = { Name=item.Name, Position=tostring(ground.CFrame:PointToObjectSpace(item.Position)), Side=item:FindFirstChild('SideValue') and item.SideValue.Value == -1 or nil, AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(item) }
                    local cfg = _bxFW.Items:GetItem(item.Name)
                    if cfg.Type ~= 'Windows' and cfg.Type ~= 'Doors' then id.Rot = getRot(item.CFrame) end
                    if item:FindFirstChild('ItemHolder') then
                        id.Items = {}
                        for _, i2 in next, item.ItemHolder:GetChildren() do
                            table.insert(id.Items, { Name=i2.Name, Rot=getRot(i2.CFrame), Position=tostring(ground.CFrame:PointToObjectSpace(i2.Position)), AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(i2) })
                        end
                    end
                    table.insert(wd.Items, id)
                end
            end
            table.insert(save.Walls, wd)
        end
        for _, floor in next, plot.House.Floor:GetChildren() do
            local fd = { AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(floor), Points={}, Objects=objs[floor] or {}, Counters=cnts[floor] or {} }
            for _, v in next, floor.PointData:GetChildren() do table.insert(fd.Points, tostring(v.Value)) end
            table.insert(save.Floors, fd)
        end
        for _, roof in next, plot.House.Roof:GetChildren() do
            local rd = { AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(roof), Name=roof.Name, Points={}, Items={} }
            for _, v in next, roof.PointData:GetChildren() do table.insert(rd.Points, tostring(v.Value)) end
            if roof:FindFirstChild('ItemHolder') then
                for _, item in next, roof.ItemHolder:GetChildren() do
                    table.insert(rd.Items, { Name=item.Name, Position=tostring(ground.CFrame:PointToObjectSpace(item.Position)), Rot=getRot(item.CFrame), AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(item) })
                end
            end
            table.insert(save.Roofs, rd)
        end
        for _, path in next, plot.House.Paths:GetChildren() do
            if path.Name == 'Poles' then continue end
            local f2, t2 = ground.CFrame:PointToObjectSpace(getPolePos(path.BPole)), ground.CFrame:PointToObjectSpace(getPolePos(path.FPole))
            table.insert(save.Paths, { AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(path), From=tostring(f2), To=tostring(t2) })
        end
        for _, pool in next, plot.House.Pools:GetChildren() do
            table.insert(save.Pools, { Position=tostring(ground.CFrame:ToObjectSpace(pool.HitBox.CFrame)), Size=tostring(Vector2.new(pool.HitBox.Size.X, pool.HitBox.Size.Z)), Type=pool.Name })
        end
        for _, bsmt in next, plot.House.Basements:GetChildren() do
            table.insert(save.Basements, { Position=tostring(ground.CFrame:ToObjectSpace(bsmt.HitBox.CFrame)), Size=tostring(Vector2.new(bsmt.HitBox.Size.X, bsmt.HitBox.Size.Z)), Type=bsmt.Name })
        end
        for _, fence in next, plot.House.Fences:GetChildren() do
            if fence.Name == 'Poles' then continue end
            local ft, ff = _bxFW.Shared.FenceService:GetEdgePositions(fence)
            local fd2 = { To=tostring(ground.CFrame:PointToObjectSpace(ft)), From=tostring(ground.CFrame:PointToObjectSpace(ff)), AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(fence), Name=fence.Name, Items={} }
            if fence:FindFirstChild('ItemHolder') then
                for _, item in next, fence.ItemHolder:GetChildren() do
                    table.insert(fd2.Items, { AppearanceData=_bxFW.Shared.ObjectService:GetAppearanceData(item), Name=item.Name, Rot=getRot(item.CFrame), Position=tostring(ground.CFrame:PointToObjectSpace(item.Position)) })
                end
            end
            table.insert(save.Fences, fd2)
        end
        if objs[plot] then save.Ground.Objects  = objs[plot] end
        if cnts[plot] then save.Ground.Counters = cnts[plot] end
        local houses = _RepStore.Stats[player.Name].Houses
        local house
        for _, v in next, houses:GetChildren() do if v.Value == houses.Value then house = v end end
        save.totalValue = house and house.TotalValue.Value or 'Unknown'
        save.bsValue    = house and house.BSValue.Value    or 'Unknown'
        writefile(string.format('Yazu/Bloxburg Houses/%s.json', player.Name), _HttpSvc:JSONEncode(save))
        Library:Notify(string.format('House of %s saved!', player.Name))
        _bxRefreshHouseList()
    end

    -- ── Load House ────────────────────────────────────────────
    _fnLoadHouse = function(houseData)
        local myPlot   = workspace.Plots['Plot_' .. LocalPlayer.Name]
        local myGround = myPlot.Ground
        local placements = 0
        local oldFW = _bxFW
        local streamRefTypes = {'PlaceObject','PlaceWall','PlaceFloor','PlacePath','PlaceRoof'}
        local fw = {
            net = setmetatable({
                InvokeServer = function(self, data, ...)
                    placements = placements + 1
                    if placements >= 4 then placements = 0; task.wait(3) end
                    local dt  = data.Type
                    local ret = { oldFW.net:InvokeServer(data) }
                    if table.find(streamRefTypes, dt) then
                        ret[1] = typeof(ret[1]) == 'Instance' and ret[1].Value
                    end
                    return unpack(ret)
                end
            }, { __index = oldFW.net })
        }
        local pos = fw.net:InvokeServer({ Type='ToPlot', Player=LocalPlayer })
        LocalPlayer.Character:SetPrimaryPartCFrame(pos)
        fw.net:InvokeServer({ Type='EnterBuild', Plot=myPlot })
        local function cvt3(s)  return myGround.CFrame:PointToWorldSpace(Vector3.new(unpack(s:split(',')))) end
        local function cvtPts(pts) local r={} for _, v in next, pts do table.insert(r, cvt3(v)) end return r end
        local function cvtRot(cf)
            if not cf then return end
            local c = myGround.CFrame:ToWorldSpace(CFrame.new(unpack(cf:split(','))))
            local r = -math.atan2(c.lookVector.z, c.lookVector.x) - math.pi * 0.5
            if r < 0 then r = 2*math.pi + r end
            return r
        end
        for _, wd in next, houseData.Walls do
            local wall = fw.net:InvokeServer({ Type='PlaceWall', From=cvt3(wd.From), To=cvt3(wd.To) })
            for _, id in next, wd.Items do
                local item = fw.net:InvokeServer({ Type='PlaceObject', Name=id.Name, TargetModel=wall, Rot=cvtRot(id.Rot), Pos=cvt3(id.Position) })
                if id.Items then for _, id2 in next, id.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
                fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=id.AppearanceData })
            end
            fw.net:InvokeServer({ Type='ColorObject', Object=wall, UseMaterials=true, Data={wd.AppearanceData[1],{},{},{}}, Side='R' })
            fw.net:InvokeServer({ Type='ColorObject', Object=wall, UseMaterials=true, Data={wd.AppearanceData[2],{},{},{}}, Side='L' })
        end
        for _, fd in next, houseData.Floors do
            local floor = fw.net:InvokeServer({ Type='PlaceFloor', Points=cvtPts(fd.Points) })
            for _, od in next, fd.Objects or {} do
                local item = fw.net:InvokeServer({ Type='PlaceObject', Name=od.Name, TargetModel=floor, Rot=cvtRot(od.Rot), Pos=cvt3(od.Position) })
                fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=od.AppearanceData })
                if od.Fences and item then for _, fcd in next, od.Fences do local fe=fw.net:InvokeServer({Type='PlaceObject',Name=fcd.Name,Pos=cvt3(fcd.From),RailingSegment=item.ObjectModel.Railings[fcd.Segment]}); fw.net:InvokeServer({Type='ColorObject',Object=fe,UseMaterials=true,Data=fcd.AppearanceData}) end end
                if od.Items then for _, id2 in next, od.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
            end
            for _, cd in next, fd.Counters or {} do
                local item = fw.net:InvokeServer({ Type='PlaceObject', Name=cd.Name, TargetModel=floor, Rot=cvtRot(cd.Rot), Pos=cvt3(cd.Position) })
                if cd.Items then for _, id2 in next, cd.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
                fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=cd.AppearanceData })
            end
            fw.net:InvokeServer({ Type='ColorObject', Object=floor, UseMaterials=true, Data=fd.AppearanceData })
        end
        for _, pd in next, houseData.Paths do
            local path = fw.net:InvokeServer({ Type='PlacePath', To=cvt3(pd.To), From=cvt3(pd.From) })
            fw.net:InvokeServer({ Type='ColorObject', Object=path, UseMaterials=true, Data=pd.AppearanceData })
        end
        for _, rd in next, houseData.Roofs do
            local roof = fw.net:InvokeServer({ Type='PlaceRoof', Points=cvtPts(rd.Points), Start=cvt3(rd.Points[1]), Settings={IsPreview=true,Type=rd.Name,RotateNum=0} })
            for _, id in next, rd.Items or {} do local item=fw.net:InvokeServer({Type='PlaceObject',Name=id.Name,TargetModel=roof,Rot=cvtRot(id.Rot),Pos=cvt3(id.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=item,UseMaterials=true,Data=id.AppearanceData}) end
            fw.net:InvokeServer({ Type='ColorObject', Object=roof, UseMaterials=true, Data=rd.AppearanceData })
        end
        for _, poolD in next, houseData.Pools do fw.net:InvokeServer({ Type='PlacePool', Size=Vector2.new(unpack(poolD.Size:split(','))), Center=CFrame.new(unpack(poolD.Position:split(','))), ItemType=poolD.Type }) end
        for _, bsD  in next, houseData.Basements do fw.net:InvokeServer({ Type='PlaceBasement', ItemType='Basements', Size=Vector2.new(unpack(bsD.Size:split(','))), Center=CFrame.new(unpack(bsD.Position:split(','))) - Vector3.new(0,-12.49,0) }) end
        for _, fcd in next, houseData.Fences do
            local fence = fw.net:InvokeServer({ Type='PlaceObject', Name=fcd.Name, StartPos=cvt3(fcd.From), Pos=cvt3(fcd.To), ItemType=fcd.Name })
            for _, id in next, fcd.Items do local item=fw.net:InvokeServer({Type='PlaceObject',Name=id.Name,TargetModel=fence,Rot=cvtRot(id.Rot),Pos=cvt3(id.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=item,UseMaterials=true,Data=id.AppearanceData}) end
            fw.net:InvokeServer({ Type='ColorObject', Object=fence, UseMaterials=true, Data=fcd.AppearanceData })
        end
        for _, gi in next, houseData.Ground.Objects do
            local item = fw.net:InvokeServer({ Type='PlaceObject', Name=gi.Name, TargetModel=myPlot.GroundParts.Ground, Rot=cvtRot(gi.Rot), Pos=cvt3(gi.Position) })
            if gi.Fences and item then for _, fcd in next, gi.Fences do local fe=fw.net:InvokeServer({Type='PlaceObject',Name=fcd.Name,Pos=cvt3(fcd.From),RailingSegment=item.ObjectModel.Railings[fcd.Segment]}); fw.net:InvokeServer({Type='ColorObject',Object=fe,UseMaterials=true,Data=fcd.AppearanceData}) end end
            if gi.Items then for _, id2 in next, gi.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
            fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=gi.AppearanceData })
        end
        for _, ci in next, houseData.Ground.Counters do
            local item = fw.net:InvokeServer({ Type='PlaceObject', Name=ci.Name, Pos=cvt3(ci.Position), Rot=cvtRot(ci.Rot), TargetModel=myPlot.GroundParts.Ground })
            if ci.Items then for _, id in next, ci.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id.Name,TargetModel=item,Rot=cvtRot(id.Rot),Pos=cvt3(id.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id.AppearanceData}) end end
            fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=ci.AppearanceData })
        end
        fw.net:FireServer({ Type='ExitBuild' })
        Library:Notify('House loaded!')
    end

    -- ── Job Functions ─────────────────────────────────────────
    _fnBensIceCream = function(toggle)
        if not toggle then return end
        repeat
            local ws = _findWSBens(workspace.Environment.Locations.BensIceCream.CustomerTargets)
            if _bxJobs:GetJob() == 'BensIceCreamSeller' and ws then
                local customer = ws.Occupied.Value
                local iceCup
                repeat _bxFW.net:FireServer({ Type='TakeIceCreamCup' }); iceCup = _bxFW.Shared.EquipmentService:GetEquipped(LocalPlayer); task.wait()
                until iceCup or not (Toggles.BX_BensIceCream and Toggles.BX_BensIceCream.Value)
                if not (Toggles.BX_BensIceCream and Toggles.BX_BensIceCream.Value) then return end
                for x = 1, 2 do
                    _bxFW.net:FireServer({ Type='AddIceCreamScoop', Taste=customer.Order['Flavor'..tostring(x)].Value, Ball=iceCup:WaitForChild('Ball'..tostring(x)) }); task.wait(0.1)
                end
                if customer.Order.Topping.Value ~= '' then _bxFW.net:FireServer({ Type='AddIceCreamTopping', Taste=customer.Order.Topping.Value }) end
                task.wait(0.1); _bxFW.net:FireServer({ Type='JobCompleted', Workstation=ws }); task.wait(1)
            end
            task.wait()
        until not (Toggles.BX_BensIceCream and Toggles.BX_BensIceCream.Value)
    end

    _fnStylezHair = function(toggle)
        if not toggle then return end
        repeat
            if _bxJobs:GetJob() == 'StylezHairdresser' then
                local ws = _findWS(workspace.Environment.Locations.StylezHairStudio.HairdresserWorkstations)
                if ws and ws.Mirror:FindFirstChild('HairdresserGUI') then
                    ws.Mirror.HairdresserGUI.Overlay:FindFirstChild('false').ImageRectOffset = Vector2.new(0,0)
                    ws.Mirror.HairdresserGUI.Overlay:FindFirstChild('false').ImageColor3    = Color3.new(0,255,0)
                    for _, v in next, getconnections(ws.Mirror.HairdresserGUI.Frame.Done.Activated) do v.Function() end
                    task.wait(1)
                end
            end
            _Heartbt:Wait()
        until not (Toggles.BX_StylezHairDresser and Toggles.BX_StylezHairDresser.Value)
    end

    _fnBloxyBurgers = function(toggle)
        if not toggle then return end
        local function getStations()
            local res = {}
            if not workspace.Environment.Locations:FindFirstChild('BloxyBurgers') then return res end
            for _, v in next, workspace.Environment.Locations.BloxyBurgers.CashierWorkstations:GetChildren() do
                if (v.InUse.Value == LocalPlayer or v.InUse.Value == nil) and v.Occupied.Value ~= nil then table.insert(res, v) end
            end
            return res
        end
        repeat
            if _bxJobs:GetJob() == 'BloxyBurgersCashier' then
                for _, ws in next, getStations() do
                    if ws and ws.OrderDisplay.DisplayMain:FindFirstChild('CashierGUI') then
                        ws.OrderDisplay.DisplayMain.CashierGUI.Overlay:FindFirstChild('false').ImageRectOffset = Vector2.new(0,0)
                        ws.OrderDisplay.DisplayMain.CashierGUI.Overlay:FindFirstChild('false').ImageColor3    = Color3.new(0,255,0)
                        for _, v in next, getconnections(ws.OrderDisplay.DisplayMain.CashierGUI.Frame.Done.Activated) do v.Function() end
                        task.wait(1)
                    end
                end
            end
            _Heartbt:Wait()
        until not (Toggles.BX_BloxyBurgers and Toggles.BX_BloxyBurgers.Value)
    end

    _fnPizzaBaker = function(toggle)
        if not toggle then return end
        repeat
            if _bxJobs:GetJob() == 'PizzaPlanetBaker' then
                local ws = _findWS(workspace.Environment.Locations.PizzaPlanet.BakerWorkstations)
                if ws then
                    local order = ws.Order; local oldPos = LocalPlayer.Character.PrimaryPart.Position
                    if order.IngredientsLeft.Value == 0 then
                        LocalPlayer.Character.PrimaryPart.CFrame = CFrame.new(1167.14685,13.6576815,255.879852); task.wait(0.5)
                        _bxNet:FireServer({ Type='TakeIngredientCrate', Object=workspace.Environment.Locations.PizzaPlanet.IngredientCrates.Crate }); task.wait(0.5)
                        _bxNet:FireServer({ Type='TakeIngredientCrate', Object=workspace.Environment.Locations.PizzaPlanet.IngredientCrates.Crate })
                        LocalPlayer.Character.PrimaryPart.CFrame = CFrame.new(oldPos); task.wait(0.5)
                        _bxNet:FireServer({ Type='RestockIngredients', Workstation=ws })
                    elseif order.Value ~= 'true' then
                        if ws:FindFirstChild('OrderDisplay') and ws.OrderDisplay:FindFirstChild('DisplayMain') and ws.OrderDisplay.DisplayMain:FindFirstChild('BakerGUI') then
                            ws.OrderDisplay.DisplayMain.BakerGUI.Overlay:FindFirstChild('false').ImageRectOffset = Vector2.new(0,0)
                            ws.OrderDisplay.DisplayMain.BakerGUI.Overlay:FindFirstChild('false').ImageColor3    = Color3.new(0,255,0)
                            for _, v in next, getconnections(ws.OrderDisplay.DisplayMain.BakerGUI.Frame.Done.Activated) do v.Function() end
                        end
                    end
                    task.wait(1)
                end
            end
            _Heartbt:Wait()
        until not (Toggles.BX_PizzaBaker and Toggles.BX_PizzaBaker.Value)
    end

    local function _bxFishLoop()
        repeat task.wait() until LocalPlayer.Character:FindFirstChild('Fishing Rod') and _bxJobs:GetJob() == 'HutFisherman'
        local t0 = tick()
        _bxNet:FireServer({ Type='UseFishingRod', State=true, Pos=LocalPlayer.Character['Fishing Rod'].Line.Position }); task.wait(2)
        if LocalPlayer.Character:FindFirstChild('Fishing Rod') then
            local origY = LocalPlayer.Character['Fishing Rod'].Bobber.Position.Y; local con
            con = LocalPlayer.Character['Fishing Rod'].Bobber:GetPropertyChangedSignal('Position'):Connect(function()
                if not LocalPlayer.Character:FindFirstChild('Fishing Rod') then return end
                if origY - LocalPlayer.Character['Fishing Rod'].Bobber.Position.Y < 3 then
                    _bxNet:FireServer({ Type='UseFishingRod', State=false, Time=tick()-t0 }); con:Disconnect()
                    if Toggles.BX_Fisherman and Toggles.BX_Fisherman.Value then _bxFishLoop() end
                end
            end)
        end
    end
    _fnFisherman = function(toggle) if not toggle then return end; _bxFishLoop() end

    local WheelPos = { Bloxster=Vector3.new(1155.36475,13.3524084,411.294983), Classic=Vector3.new(1156,13.3524084,396.650177), Moped=Vector3.new(1154,13,402) }
    local function _getMotorWS()
        if not workspace.Environment.Locations:FindFirstChild('MikesMotors') then return end
        local s
        for _, v in next, workspace.Environment.Locations.MikesMotors.MechanicWorkstations:GetChildren() do
            if v:FindFirstChild('InUse') and v.InUse.Value == LocalPlayer then s = v end
        end
        for _, v in next, workspace.Environment.Locations.MikesMotors.MechanicWorkstations:GetChildren() do
            if v:FindFirstChild('InUse') and v:FindFirstChild('Occupied') and v.InUse.Value == nil and v.Occupied.Value ~= nil then s = v end
        end
        if not s then task.wait(); return _getMotorWS() end
        return s
    end
    _fnMechanic = function(toggle)
        if not toggle then return end
        repeat
            if _bxJobs:GetJob() == 'MikesMechanic' then
                local v = _getMotorWS()
                if v and v.Occupied.Value then
                    local Order = v.Occupied.Value:WaitForChild('Order')
                    if Order:FindFirstChild('Oil') and Order.Oil.Value ~= nil then
                        repeat _tweenTP(Vector3.new(1194,13,389)); _bxNet:FireServer({Type='TakeOil';Object=workspace.Environment.Locations.MikesMotors.OilCans:FindFirstChildWhichIsA('Model')}); task.wait() until LocalPlayer.Character:FindFirstChild('Oil Can') or not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
                        _tweenTP(v.Display.Screen.Position + Vector3.new(0,0,5)); _bxNet:FireServer({Type='FixBike';Workstation=v})
                        repeat task.wait() until not LocalPlayer.Character:FindFirstChild('Oil Can') or not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
                        _bxNet:FireServer({Type='JobCompleted';Workstation=v}); task.wait(2)
                    elseif Order:FindFirstChild('Wheels') then
                        local wt = Order.Wheels.Value
                        for i = 1, 2 do
                            repeat _tweenTP(WheelPos[wt]); _bxNet:FireServer({Type='TakeWheel';Object=workspace.Environment.Locations.MikesMotors.TireRacks:FindFirstChild(wt)}); task.wait() until LocalPlayer.Character:FindFirstChild(wt..' Wheel') or not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
                            _tweenTP(v.Display.Screen.Position + Vector3.new(0,0,5)); _bxNet:FireServer({Type='FixBike';Workstation=v;Front=(i==1) or nil})
                            repeat task.wait() until not LocalPlayer.Character:FindFirstChild(wt..' Wheel') or not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
                            if i==2 then _bxNet:FireServer({Type='JobCompleted';Workstation=v}) end; task.wait(2)
                        end
                    elseif Order:FindFirstChild('Color') and Order.Color.Value ~= nil then
                        local col = Order.Color.Value
                        repeat _tweenTP(Vector3.new(1173,13,388)); _bxNet:FireServer({Type='TakePainter';Object=workspace.Environment.Locations.MikesMotors.PaintingEquipment:FindFirstChild(col)}); task.wait() until LocalPlayer.Character:FindFirstChild('Spray Painter') or not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
                        _tweenTP(v.Display.Screen.Position + Vector3.new(0,0,5)); _bxNet:FireServer({Type='FixBike';Workstation=v})
                        repeat task.wait() until not LocalPlayer.Character:FindFirstChild('Spray Painter') or not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
                        _bxNet:FireServer({Type='JobCompleted';Workstation=v}); task.wait(2)
                    end
                end
            end
            _Heartbt:Wait()
        until not (Toggles.BX_Mechanic and Toggles.BX_Mechanic.Value)
    end

    local function _getTree()
        local bd, bb = math.huge, nil
        for _, v in next, workspace.Environment.Trees:GetChildren() do
            local d = LocalPlayer:DistanceFromCharacter(v.PrimaryPart.Position)
            if d < bd and v.PrimaryPart.Position.Y > 5 then bd, bb = d, v end
        end
        return bb
    end
    _fnLumber = function(toggle)
        if not toggle then return end
        task.spawn(function()
            repeat
                if Toggles.BX_Lumber and Toggles.BX_Lumber.Value and _bxJobs:GetJob() == 'LumberWoodcutter' then LocalPlayer.Character.Humanoid:ChangeState(11) end
                _Heartbt:Wait()
            until not (Toggles.BX_Lumber and Toggles.BX_Lumber.Value)
        end)
        repeat
            if _bxJobs:GetJob() == 'LumberWoodcutter' then
                local tree = _getTree()
                if tree then
                    local ti = TweenInfo.new((LocalPlayer.Character.HumanoidRootPart.Position - tree.PrimaryPart.Position).Magnitude/45, Enum.EasingStyle.Linear)
                    local tw = TweenService:Create(LocalPlayer.Character.HumanoidRootPart, ti, { CFrame=tree.PrimaryPart.CFrame })
                    tw:Play(); tw.Completed:Wait()
                    repeat _bxNet:FireServer({Type='UseHatchet',Tree=tree}); task.wait() until tree.PrimaryPart.Position.Y < 0 or _bxJobs:GetJob() ~= 'LumberWoodcutter' or not (Toggles.BX_Lumber and Toggles.BX_Lumber.Value)
                end
            end
            _Heartbt:Wait()
        until not (Toggles.BX_Lumber and Toggles.BX_Lumber.Value)
    end

    local _oreColors = {'Dark stone grey','Dark orange','Deep orange','Lime green','Royal purple'}
    local function _getOre()
        local bd, bb, best = math.huge, nil, 'Dark stone grey'
        for _, v in next, workspace.Environment.Locations.Static_MinerCave.Folder:GetChildren() do
            if v:FindFirstChild('M') then
                local vc = v:FindFirstChild('M').BrickColor.Name
                if table.find(_oreColors, best) < table.find(_oreColors, vc) then bb=v; best=vc
                elseif table.find(_oreColors, best) == table.find(_oreColors, vc) then
                    local d = LocalPlayer:DistanceFromCharacter(v.PrimaryPart.Position)
                    if d < bd then bd, bb = d, v end
                end
            end
        end
        if not bb then
            for _, v in next, workspace.Environment.Locations.Static_MinerCave.Folder:GetChildren() do
                local d = LocalPlayer:DistanceFromCharacter(v.PrimaryPart.Position)
                if d < bd and (not v:FindFirstChild('B') or v:FindFirstChild('B').BrickColor.Name ~= 'Bright red') then bd, bb = d, v end
            end
        end
        return bb
    end
    _fnMiner = function(toggle)
        if not toggle then
            local bv = LocalPlayer.Character and LocalPlayer.Character.HumanoidRootPart:FindFirstChildOfClass('BodyVelocity')
            if bv then bv:Destroy() end; return
        end
        local bv = Instance.new('BodyVelocity', LocalPlayer.Character.HumanoidRootPart); bv.Velocity = Vector3.new(0,0,0)
        task.spawn(function()
            repeat
                if Toggles.BX_Miner and Toggles.BX_Miner.Value then LocalPlayer.Character.Humanoid:ChangeState(11) end
                _Heartbt:Wait()
            until not (Toggles.BX_Miner and Toggles.BX_Miner.Value)
        end)
        repeat
            if (Toggles.BX_Miner and Toggles.BX_Miner.Value) and _bxJobs:GetJob() == 'CaveMiner' and workspace.Environment.Locations:FindFirstChild('Static_MinerCave') then
                local blk = _getOre()
                if blk then
                    blk.PrimaryPart.CanCollide = false; _tweenTP(blk.PrimaryPart.Position)
                    local x,y,z = string.match(blk.Name, '(.+):(.+):(.+)')
                    _bxNet:InvokeServer({ Type='MineBlock', P=Vector3.new(x,y,z) })
                end
            end
        until not (Toggles.BX_Miner and Toggles.BX_Miner.Value)
    end

    local function _getTrash()
        local bd, bb = math.huge, nil
        for _, v in next, workspace.Environment.Locations.GreenClean.Spawns:GetChildren() do
            local d = LocalPlayer:DistanceFromCharacter(v.Position)
            if d < bd and v:FindFirstChildWhichIsA('Decal', true) then bd, bb = d, v end
        end
        if not bb then task.wait(); return _getTrash() end
        return bb
    end
    _fnJanitor = function(toggle)
        if not toggle then return end
        task.spawn(function()
            repeat
                if Toggles.BX_Janitor and Toggles.BX_Janitor.Value then LocalPlayer.Character.Humanoid:ChangeState(11) end
                _Heartbt:Wait()
            until not (Toggles.BX_Janitor and Toggles.BX_Janitor.Value)
        end)
        repeat
            if (Toggles.BX_Janitor and Toggles.BX_Janitor.Value) and _bxJobs:GetJob() == 'CleanJanitor' then
                local trash = _getTrash()
                if trash then
                    if trash:FindFirstChild('Object') and trash.Object:IsA('Part') then _tweenTP(trash.Object.Position)
                    else _tweenTP(trash.Position) end
                    _bxNet:InvokeServer({ Type='CleanJanitorObject', Spawn=trash })
                end
            end
            _Heartbt:Wait()
        until not (Toggles.BX_Janitor and Toggles.BX_Janitor.Value)
    end

    local _grocFn = {
        RestockBags = function(stn)
            local crate = workspace.Environment.Locations.Supermarket.Crates:FindFirstChild('BagCrate')
            _tweenTP(crate.Position + Vector3.new(5,0,-5)); _bxNet:FireServer({ Type='TakeNewBags', Object=crate })
            repeat task.wait() until LocalPlayer.Character:FindFirstChild('BFF Bags')
            _tweenTP(stn.Scanner.Position - Vector3.new(3,0,0)); _bxNet:FireServer({ Type='RestockBags', Workstation=stn })
            repeat task.wait() until stn.BagsLeft.Value > 0
        end,
        GetFreeStation = function()
            if not workspace.Environment.Locations:FindFirstChild('Supermarket') then return end
            local stn
            for _, v in next, workspace.Environment.Locations.Supermarket.CashierWorkstations:GetChildren() do
                if v:FindFirstChild('InUse') and v.InUse.Value == LocalPlayer then stn = v end
            end
            if not stn then
                local bd = math.huge
                for _, v in next, workspace.Environment.Locations.Supermarket.CashierWorkstations:GetChildren() do
                    if v:FindFirstChild('InUse') and v.InUse.Value == nil then
                        local d = LocalPlayer:DistanceFromCharacter(v.Scanner.Position)
                        if d < bd then bd, stn = d, v end
                    end
                end
            end
            if not stn then task.wait() end; return stn
        end
    }
    local _bxCurBags, _bxCurCount = 1, 0
    local function _bxNextCustomer()
        if not (_bxJobs:GetJob()=='SupermarketCashier' and Toggles.BX_SupermarketCashier and Toggles.BX_SupermarketCashier.Value) then return end
        local stn = _grocFn.GetFreeStation(); _bxCurCount, _bxCurBags = 0, 1
        if stn.BagsLeft.Value == 0 then _grocFn.RestockBags(stn) end
        repeat
            for _, v in next, stn.DroppedFood:GetChildren() do
                _bxCurCount = _bxCurCount + 1
                if _bxCurCount / _bxCurBags == 3 then
                    _bxNet:FireServer({Type='TakeNewBag',Workstation=stn}); _bxCurBags = _bxCurBags + 1
                    if stn.BagsLeft.Value == 0 then _grocFn.RestockBags(stn); task.wait() end
                end
                _bxNet:FireServer({Type='ScanDroppedItem',Item=v}); task.wait(0.1)
            end
            task.wait()
        until _bxJobs:GetJob() ~= 'SupermarketCashier' or (stn.Occupied.Value ~= nil and (stn.Occupied.Value.Head.Position - stn.CustomerTarget_2.Position).magnitude < 3)
        _bxNet:FireServer({Type='JobCompleted',Workstation=stn}); _bxNextCustomer()
    end
    _fnSuperCashier = function(toggle)
        if not toggle then return end
        repeat task.wait() until _bxJobs:GetJob() == 'SupermarketCashier'
        if Toggles.BX_SupermarketCashier and Toggles.BX_SupermarketCashier.Value then _bxNextCustomer() end
    end

    local function _getCrate()
        local bd, bb = math.huge, nil
        for _, v in next, workspace.Environment.Locations.Supermarket.Crates:GetChildren() do
            local d = LocalPlayer:DistanceFromCharacter(v.Position)
            if d < bd and v.Name == 'Crate' then bd, bb = d, v end
        end
        if not bb then task.wait(0.5) end; return bb
    end
    local function _getEmptyShelf()
        local bd, bb = math.huge, nil
        for _, v in next, workspace.Environment.Locations.Supermarket.Shelves:GetChildren() do
            local d = LocalPlayer:DistanceFromCharacter(v.PrimaryPart.Position)
            if d < bd and v.IsEmpty.Value == true then bd, bb = d, v end
        end
        if not bb then task.wait(0.5) end; return bb
    end
    local _goShelf, _takeCrate
    _goShelf = function()
        if _bxJobs:GetJob()=='SupermarketStocker' and Toggles.BX_SupermarketStocker and Toggles.BX_SupermarketStocker.Value then
            local shelf = _getEmptyShelf(); _tweenTP(shelf:FindFirstChild('Part').Position)
            _bxNet:FireServer({Type='RestockShelf',Shelf=shelf}); _takeCrate()
        end
    end
    _takeCrate = function()
        if _bxJobs:GetJob()=='SupermarketStocker' and Toggles.BX_SupermarketStocker and Toggles.BX_SupermarketStocker.Value then
            local crate = _getCrate(); _tweenTP(crate.Position)
            _bxNet:FireServer({Type='TakeFoodCrate',Object=crate}); _goShelf()
        end
    end
    _fnStocker = function(toggle)
        if not toggle then return end
        task.spawn(function()
            repeat
                if (Toggles.BX_SupermarketStocker and Toggles.BX_SupermarketStocker.Value) and _bxJobs:GetJob()=='SupermarketStocker' then LocalPlayer.Character.Humanoid:ChangeState(11) end
                _Heartbt:Wait()
            until not (Toggles.BX_SupermarketStocker and Toggles.BX_SupermarketStocker.Value)
        end)
        if _bxJobs:GetJob() == 'SupermarketStocker' then _takeCrate() end
    end

    _fnTeleportPlot = function(name)
        local target = Players:FindFirstChild(name)
        if not target then Library:Notify('Player not found!'); return end
        local pos = _bxFW.net:InvokeServer({ Type='ToPlot', Player=target })
        LocalPlayer.Character:SetPrimaryPartCFrame(pos)
        Library:Notify('Teleported to ' .. name .. "'s plot")
    end

    _bxReady = true
    Library:Notify('[BXBRG] Bloxburg framework loaded!')
end) -- end task.spawn

end -- return function
