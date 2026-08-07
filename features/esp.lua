-- ================================================================
--  features/esp.lua
--  Contains: ESP drawing logic and all ESP tab UI.
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService       = Services.RunService
local UserInputService = Services.UserInputService
local Players          = Services.Players
local LocalPlayer      = Services.LocalPlayer

-- ── Helpers ────────────────────────────────────────────────────
local MathHandler = {}
function MathHandler:Abbreviate(n)
    if type(n) ~= 'number' then return tostring(n) end
    local abbr = { K=1e3, M=1e6, B=1e9, T=1e12 }
    local sel, res = 0, tostring(math.round(n))
    for k, v in next, abbr do
        if math.abs(n) >= v and v > sel then
            sel = v; res = tostring(math.round(n/v)) .. k
        end
    end
    return res
end

-- ================================================================
--  ESP LOGIC
-- ================================================================
local espData          = {}
local EspConn          = nil
local RainbowEnemyConn = nil
local RainbowAllyConn  = nil

local function newDraw(kind, props)
    local d = Drawing.new(kind)
    for k, v in next, props do d[k] = v end
    return d
end

local function createEsp(player)
    if player == LocalPlayer then return end
    espData[player] = {
        box    = newDraw('Square', { Visible=false, Thickness=1, Filled=false, Color=Color3.fromRGB(255,0,0) }),
        name   = newDraw('Text',   { Visible=false, Size=14, Outline=true, OutlineColor=Color3.new(0,0,0), Color=Color3.fromRGB(255,255,255), Center=true }),
        health = newDraw('Text',   { Visible=false, Size=12, Outline=true, OutlineColor=Color3.new(0,0,0), Color=Color3.fromRGB(0,255,0),     Center=true }),
        dist   = newDraw('Text',   { Visible=false, Size=11, Outline=true, OutlineColor=Color3.new(0,0,0), Color=Color3.fromRGB(200,200,200), Center=true }),
        tracer = newDraw('Line',   { Visible=false, Thickness=1, Color=Color3.fromRGB(255,0,0) }),
    }
end

local function removeEsp(player)
    if not espData[player] then return end
    for _, d in next, espData[player] do d:Remove() end
    espData[player] = nil
end

for _, p in next, Players:GetPlayers() do task.spawn(createEsp, p) end
Players.PlayerAdded:Connect(createEsp)
Players.PlayerRemoving:Connect(removeEsp)

local function setAllEspHidden()
    for _, d in next, espData do for _, dr in next, d do dr.Visible = false end end
end

local function startEsp(toggle)
    if EspConn then EspConn:Disconnect(); EspConn = nil end
    if not toggle then setAllEspHidden(); return end
    local frame = 0
    EspConn = RunService.RenderStepped:Connect(function()
        frame = frame + 1
        if frame % 2 ~= 0 then return end

        local cam      = workspace.CurrentCamera; if not cam then return end
        local vsize    = cam.ViewportSize
        local maxDist  = Options.MaxEspDist   and Options.MaxEspDist.Value   or 1000
        local thick    = Options.EspThickness and Options.EspThickness.Value or 1
        local opacity  = Options.EspOpacity   and Options.EspOpacity.Value   or 1
        local filled   = Toggles.EspBoxFilled and Toggles.EspBoxFilled.Value or false
        local useTeam  = Toggles.EspUseTeamColor and Toggles.EspUseTeamColor.Value
        local smartESP = Toggles.SmartESP     and Toggles.SmartESP.Value
        local nameOutlineCol = Options.EspNameOutline and Options.EspNameOutline.Value or Color3.new(0,0,0)
        local espColour      = Options.EspColour and Options.EspColour.Value or nil
        local lpHRP = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild('HumanoidRootPart')

        for player, d in next, espData do
            local char = player.Character
            local root = char and char:FindFirstChild('HumanoidRootPart')
            local head = char and char:FindFirstChild('Head')
            local hum  = char and char:FindFirstChildWhichIsA('Humanoid')

            if not (root and head and hum) then
                for _, dr in next, d do dr.Visible = false end; continue
            end

            if smartESP and table.find(State.whitelistedIds, player.UserId) then
                for _, dr in next, d do dr.Visible = false end; continue
            end

            local rootSP, rootVis = cam:WorldToViewportPoint(root.Position)
            local headSP          = cam:WorldToViewportPoint(head.Position)
            local dist3D          = lpHRP and (lpHRP.Position - root.Position).Magnitude or 0

            if not rootVis or dist3D > maxDist then
                for _, dr in next, d do dr.Visible = false end; continue
            end

            local sRoot = Vector2.new(rootSP.X, rootSP.Y)
            local sHead = Vector2.new(headSP.X, headSP.Y)
            local boxH  = math.abs(sRoot.Y - sHead.Y) * 2
            local boxW  = boxH * 0.55

            local col
            if useTeam and player.TeamColor then
                col = player.TeamColor.Color
            elseif espColour and Toggles.UseEspColourOverride and Toggles.UseEspColourOverride.Value then
                col = espColour
            else
                local isAlly = player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team
                col = isAlly
                    and (Options.AllyColor  and Options.AllyColor.Value  or Color3.fromRGB(0,255,0))
                    or  (Options.EnemyColor and Options.EnemyColor.Value or Color3.fromRGB(255,0,0))
            end

            d.box.Visible      = Toggles.EspBoxes and Toggles.EspBoxes.Value or false
            d.box.Color        = col
            d.box.Filled       = filled
            d.box.Thickness    = thick
            d.box.Transparency = opacity
            d.box.Size         = Vector2.new(boxW, boxH)
            d.box.Position     = Vector2.new(sHead.X - boxW/2, sHead.Y)

            d.name.Visible      = Toggles.EspNames and Toggles.EspNames.Value or false
            d.name.Text         = player.DisplayName
            d.name.Color        = col
            d.name.OutlineColor = nameOutlineCol
            d.name.Transparency = opacity
            d.name.Position     = Vector2.new(sHead.X, sHead.Y - 18)

            local showHealth = Toggles.EspHealth and Toggles.EspHealth.Value
            d.health.Visible  = showHealth or false
            if showHealth then
                local hp = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                d.health.Text         = '[' .. MathHandler:Abbreviate(math.floor(hum.Health)) .. ' hp]'
                d.health.Color        = Color3.new(1 - hp, hp, 0)
                d.health.Transparency = opacity
                d.health.Position     = Vector2.new(sHead.X, sHead.Y - 30)
            end

            local showDist = Toggles.EspDist and Toggles.EspDist.Value
            d.dist.Visible = showDist or false
            if showDist then
                d.dist.Text         = '[' .. MathHandler:Abbreviate(math.floor(dist3D)) .. 'm]'
                d.dist.Color        = col
                d.dist.Transparency = opacity
                d.dist.Position     = Vector2.new(sHead.X, sRoot.Y + 4)
            end

            local showTracer = Toggles.EspTracers and Toggles.EspTracers.Value
            d.tracer.Visible = showTracer or false
            if showTracer then
                local from = (Toggles.EspTracerMouse and Toggles.EspTracerMouse.Value)
                    and UserInputService:GetMouseLocation()
                    or  Vector2.new(vsize.X/2, vsize.Y)
                d.tracer.Color        = col
                d.tracer.Thickness    = thick
                d.tracer.Transparency = opacity
                d.tracer.From         = from
                d.tracer.To           = sRoot
            end
        end
    end)
end

-- ================================================================
--  UI — ESP TAB
-- ================================================================
local EspGrp      = Tabs.ESP:AddLeftGroupbox('ESP')
local EspColorGrp = Tabs.ESP:AddRightGroupbox('Colors')

EspGrp:AddToggle('ToggleEsp',   { Text = 'Enable ESP', Default = false, Callback = startEsp })
EspGrp:AddToggle('SmartESP',    { Text = 'Smart ESP (skip whitelisted)', Default = false })
EspGrp:AddSlider('MaxEspDist',  { Text = 'Max Distance (studs)', Default = 1000, Min = 50, Max = 10000, Rounding = 0 })
EspGrp:AddDropdown('EspFont', {
    Text = 'Font', Default = 1, Values = { 'UI', 'System', 'Plex', 'Monospace' },
    Callback = function(font)
        local id = Drawing.Fonts and Drawing.Fonts[font] or 0
        for _, d in next, espData do
            if d.name   then d.name.Font   = id end
            if d.health then d.health.Font = id end
            if d.dist   then d.dist.Font   = id end
        end
    end,
})
EspGrp:AddSlider('EspTextSize', {
    Text = 'Text Size', Default = 14, Min = 8, Max = 40, Rounding = 0,
    Callback = function(s) for _, d in next, espData do if d.name then d.name.Size = s end end end,
})
EspGrp:AddSlider('EspThickness',   { Text = 'Thickness',      Default = 1, Min = 1, Max = 10, Rounding = 0 })
EspGrp:AddSlider('EspOpacity',     { Text = 'Opacity (0-1)',   Default = 1, Min = 0, Max = 1,  Rounding = 1 })
EspGrp:AddToggle('EspBoxes',       { Text = 'Boxes',           Default = false })
EspGrp:AddToggle('EspBoxFilled',   { Text = 'Filled Boxes',    Default = false })
EspGrp:AddToggle('EspNames',       { Text = 'Names',           Default = true  })
EspGrp:AddToggle('EspHealth',      { Text = 'Health',          Default = true  })
EspGrp:AddToggle('EspDist',        { Text = 'Distance',        Default = false })
EspGrp:AddToggle('EspTracers',     { Text = 'Tracers',         Default = false })
EspGrp:AddToggle('EspTracerMouse', { Text = 'Tracers from Mouse', Default = false })
EspGrp:AddToggle('EspUseTeamColor',{ Text = 'Use Team Color',  Default = false })

EspColorGrp:AddLabel('Enemy Color'):AddColorPicker('EnemyColor', { Default = Color3.fromRGB(255,0,0), Title = 'Enemy Color' })
EspColorGrp:AddToggle('RainbowEnemy', {
    Text = 'Rainbow Enemy', Default = false,
    Callback = function(t)
        if RainbowEnemyConn then RainbowEnemyConn:Disconnect(); RainbowEnemyConn = nil end
        if not t then return end
        RainbowEnemyConn = RunService.RenderStepped:Connect(function()
            Options.EnemyColor:SetValueRGB(Color3.fromHSV(tick() % 5 / 5, 1, 1))
        end)
    end,
})
EspColorGrp:AddLabel('Ally Color'):AddColorPicker('AllyColor', { Default = Color3.fromRGB(0,255,0), Title = 'Ally Color' })
EspColorGrp:AddToggle('RainbowAlly', {
    Text = 'Rainbow Ally', Default = false,
    Callback = function(t)
        if RainbowAllyConn then RainbowAllyConn:Disconnect(); RainbowAllyConn = nil end
        if not t then return end
        RainbowAllyConn = RunService.RenderStepped:Connect(function()
            Options.AllyColor:SetValueRGB(Color3.fromHSV((tick() + 2.5) % 5 / 5, 1, 1))
        end)
    end,
})
EspColorGrp:AddLabel('Override ESP Color (optional)'):AddColorPicker('EspColour', { Default = Color3.fromRGB(255,255,255), Title = 'ESP Color Override' })
EspColorGrp:AddToggle('UseEspColourOverride', { Text = 'Use Color Override', Default = false })
EspColorGrp:AddLabel('Name Outline Color'):AddColorPicker('EspNameOutline', { Default = Color3.new(0,0,0), Title = 'Name Outline' })

-- ================================================================
--  SPECTATE
-- ================================================================
--  Locks the camera to a selected player's HumanoidRootPart using
--  Enum.CameraType.Attach.  Camera restores to Follow on disable.
--  Spectated player is tracked in the upvalue SpectateTarget so the
--  radar can reference it without any extra State wiring.
-- ================================================================

local SpectateConn        = nil
local SpectateTarget      = nil  -- Player currently being spectated (upvalue shared with Radar)
local SpectateRenderConn  = nil  -- RenderStepped loop that drives camera + streaming focus
local SpectateCharConn    = nil  -- CharacterAdded watcher (reconnects on respawn)

-- ── Streaming-aware spectate helpers ───────────────────────────
--
--  workspace.StreamingEnabled means far-away characters simply do not
--  exist on the client.  To force Roblox to load them we do two things:
--
--  1. Set workspace.CurrentCamera.CFrame / .Focus to the target's last
--     known server position every frame — this shifts the streaming
--     focal point so the engine starts sending us those chunks.
--
--  2. Write LocalPlayer.ReplicationFocus to the target's root (if that
--     property is writable by the executor).  This is the proper API for
--     redirecting which area the server replicates to this client.
--
--  While the character is loading we stay in scriptable mode and manually
--  position the camera at the target's last network-replicated position
--  (readable from the humanoid state / character even before all parts
--  exist).  The moment the full character arrives we switch to Attach.
-- ───────────────────────────────────────────────────────────────

local function getTargetPosition()
    -- Returns the best available world position for SpectateTarget, or nil.
    if not SpectateTarget then return nil end
    local char = SpectateTarget.Character
    if not char then return nil end
    local root = char:FindFirstChild('HumanoidRootPart')
    if root then return root.Position end
    -- Fallback: any BasePart in the character (e.g. during streaming-in)
    for _, v in next, char:GetChildren() do
        if v:IsA('BasePart') then return v.Position end
    end
    return nil
end

local function setReplicationFocus(root)
    -- Try to redirect server replication to the target's position.
    -- This forces Roblox to stream the area around the target to our client.
    pcall(function()
        LocalPlayer.ReplicationFocus = root
    end)
    -- Also force the camera's Focus CFrame so the streaming system
    -- uses the target location as the LOD origin even before Attach works.
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam and root then
            cam.Focus = CFrame.new(root.Position)
        end
    end)
end

local function clearReplicationFocus()
    pcall(function()
        local lc = LocalPlayer.Character
        local root = lc and lc:FindFirstChild('HumanoidRootPart')
        LocalPlayer.ReplicationFocus = root or workspace
    end)
end

local function tryAttachCam()
    -- Returns true and attaches camera if the full character is loaded.
    local cam  = workspace.CurrentCamera; if not cam then return false end
    local char = SpectateTarget and SpectateTarget.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if not root then return false end
    cam.CameraType    = Enum.CameraType.Attach
    cam.CameraSubject = root
    setReplicationFocus(root)
    return true
end

local function stopSpectate()
    if SpectateRenderConn then SpectateRenderConn:Disconnect(); SpectateRenderConn = nil end
    if SpectateCharConn   then SpectateCharConn:Disconnect();   SpectateCharConn   = nil end
    if SpectateConn       then SpectateConn:Disconnect();       SpectateConn       = nil end
    SpectateTarget = nil
    clearReplicationFocus()
    local cam = workspace.CurrentCamera
    if cam then
        cam.CameraType    = Enum.CameraType.Follow
        cam.CameraSubject = LocalPlayer.Character
            and LocalPlayer.Character:FindFirstChildWhichIsA('Humanoid') or nil
    end
end

local function startSpectateLoop()
    -- Kill any existing loop first
    if SpectateRenderConn then SpectateRenderConn:Disconnect(); SpectateRenderConn = nil end

    local attached = false

    SpectateRenderConn = RunService.RenderStepped:Connect(function()
        if not SpectateTarget then return end
        local cam = workspace.CurrentCamera; if not cam then return end

        local char = SpectateTarget.Character
        local root = char and char:FindFirstChild('HumanoidRootPart')

        if root then
            -- Force streaming to load the area around the target every frame
            setReplicationFocus(root)

            if not attached then
                -- Switch from Scriptable → Attach now that the root exists
                cam.CameraType    = Enum.CameraType.Attach
                cam.CameraSubject = root
                attached = true
            end
        else
            -- Character not streamed yet: manually position camera at last known pos
            -- and keep hammering ReplicationFocus so Roblox sends us the data
            attached = false
            cam.CameraType = Enum.CameraType.Scriptable

            local pos = getTargetPosition()
            if pos then
                cam.CFrame = CFrame.new(pos + Vector3.new(0, 5, 12), pos)
                pcall(function() cam.Focus = CFrame.new(pos) end)
                -- Drive replication toward that position directly
                pcall(function()
                    LocalPlayer.ReplicationFocus = workspace.Terrain
                    -- Terrain is a writable fallback; actual position is set via cam.Focus
                end)
            end

            -- Also directly request character load via RequestStreamAroundAsync if available
            pcall(function()
                if pos and workspace.RequestStreamAroundAsync then
                    workspace:RequestStreamAroundAsync(pos, 0)
                end
            end)
        end
    end)
end

local function spectatePlayer(targetName)
    stopSpectate()
    if not targetName or targetName == '' then return end
    local target = Players:FindFirstChild(targetName)
    if not target or target == LocalPlayer then return end
    SpectateTarget = target

    -- Start the per-frame loop immediately (handles both loaded and unloaded chars)
    startSpectateLoop()

    -- Re-start the loop on respawn so we re-attach cleanly after death
    SpectateCharConn = SpectateTarget.CharacterAdded:Connect(function()
        task.wait(0.1)
        startSpectateLoop()
    end)
end

local SpectateGrp = Tabs.ESP:AddLeftGroupbox('Spectate')

SpectateGrp:AddToggle('SpectateEnabled', {
    Text    = 'Enable Spectate',
    Default = false,
    Callback = function(on)
        if not on then
            stopSpectate()
        else
            local sel = Options.SpectateTarget and Options.SpectateTarget.Value
            if sel and sel ~= '' then spectatePlayer(sel) end
        end
    end,
})

local function getPlayerNames()
    local names = {}
    for _, p in next, Players:GetPlayers() do
        if p ~= LocalPlayer then names[#names+1] = p.Name end
    end
    table.sort(names)
    if #names == 0 then names = { '(no players)' } end
    return names
end

SpectateGrp:AddDropdown('SpectateTarget', {
    Text    = 'Target Player',
    Default = 1,
    Values  = getPlayerNames(),
    Callback = function(name)
        if Toggles.SpectateEnabled and Toggles.SpectateEnabled.Value then
            spectatePlayer(name)
        end
    end,
})

SpectateGrp:AddButton('Refresh Player List', function()
    local names = getPlayerNames()
    if Options.SpectateTarget then
        if Options.SpectateTarget.SetValues then
            Options.SpectateTarget:SetValues(names)
        end
    end
end)

-- Stop spectating if the target leaves
Players.PlayerRemoving:Connect(function(p)
    if p == SpectateTarget then
        stopSpectate()
        if Toggles.SpectateEnabled then Toggles.SpectateEnabled:SetValue(false) end
    end
end)

-- ================================================================
--  RADAR / MAP
-- ================================================================
--  Pure Drawing-based top-down minimap drawn in the lower-right
--  corner.  Size and world range are controlled by sliders so the
--  user can scale it freely at runtime.
--
--  Center origin:
--    • Spectate ON  → spectated player's HRP
--    • Spectate OFF → LocalPlayer's HRP
--
--  The spectated player's blip is drawn in cyan so it's easy to spot.
-- ================================================================

local radarDrawings  = {}  -- static BG drawing objects (border, bg, crosshair, label)
local radarBlips     = {}  -- [player] = { dot=Drawing, name=Drawing }
local RadarConn      = nil
local RadarDragConn1 = nil
local RadarDragConn2 = nil
local RadarDragConn3 = nil

local RADAR_DEFAULT_SIZE  = 300   -- px
local RADAR_DEFAULT_RANGE = 300   -- studs

-- Persisted radar center so it survives size-slider changes without resetting position
local radarCenter     = nil   -- Vector2, nil until first startRadar call
local radarDragging   = false
local radarDragOffset = Vector2.new(0, 0)  -- mouse pos relative to center when drag began

local function clearRadarStatic()
    for _, d in next, radarDrawings do pcall(function() d:Remove() end) end
    radarDrawings = {}
end

local function clearAllRadarBlips()
    for player, blip in next, radarBlips do
        pcall(function() blip.glow:Remove()    end)
        pcall(function() blip.dot:Remove()     end)
        pcall(function() blip.outline:Remove() end)
        pcall(function() blip.name:Remove()    end)
        pcall(function() blip.dist:Remove()    end)
    end
    radarBlips = {}
end

-- Top-down world → screen-space radar conversion
local function worldToRadarPos(origin, targetPos, radarCenter, halfSize, worldRange)
    local diff  = targetPos - origin
    local scale = halfSize / worldRange
    return Vector2.new(radarCenter.X + diff.X * scale,
                       radarCenter.Y + diff.Z * scale)
end

-- Build (or rebuild) the static background drawing objects
local function buildRadarBG(center, size)
    clearRadarStatic()
    local half = size / 2

    -- Outer glow border (bright accent ring)
    local glow = newDraw('Square', {
        Visible      = true, Filled = true,
        Color        = Color3.fromRGB(255, 40, 40),
        Transparency = 0.7,                          -- subtle red glow ring
        Size         = Vector2.new(size + 10, size + 10),
        Position     = center - Vector2.new(half + 5, half + 5),
    })
    -- Hard border
    local border = newDraw('Square', {
        Visible      = true, Filled = false,
        Color        = Color3.fromRGB(255, 60, 60),
        Transparency = 0,                            -- fully visible border line
        Thickness    = 2,
        Size         = Vector2.new(size + 4, size + 4),
        Position     = center - Vector2.new(half + 2, half + 2),
    })
    -- Background fill — nearly transparent so it barely darkens the game
    local bg = newDraw('Square', {
        Visible      = true, Filled = true,
        Color        = Color3.fromRGB(5, 5, 15),
        Transparency = 0.82,                         -- very see-through; blips pop above it
        Size         = Vector2.new(size, size),
        Position     = center - Vector2.new(half, half),
    })
    -- Crosshair horizontal
    local ch_h = newDraw('Line', {
        Visible      = true,
        Color        = Color3.fromRGB(255, 80, 80),
        Transparency = 0.45,
        Thickness    = 1,
        From         = Vector2.new(center.X - half, center.Y),
        To           = Vector2.new(center.X + half, center.Y),
    })
    -- Crosshair vertical
    local ch_v = newDraw('Line', {
        Visible      = true,
        Color        = Color3.fromRGB(255, 80, 80),
        Transparency = 0.45,
        Thickness    = 1,
        From         = Vector2.new(center.X, center.Y - half),
        To           = Vector2.new(center.X, center.Y + half),
    })
    -- Label
    local lbl = newDraw('Text', {
        Visible      = true,
        Text         = '── RADAR ──',
        Size         = 12,
        Color        = Color3.fromRGB(255, 100, 100),
        Outline      = true,
        OutlineColor = Color3.new(0, 0, 0),
        Center       = true,
        Position     = Vector2.new(center.X, center.Y - half - 16),
    })
    -- Self-dot (you): bright white square at center
    local selfDot = newDraw('Square', {
        Visible  = true,
        Filled   = true,
        Color    = Color3.fromRGB(255, 255, 255),
        Size     = Vector2.new(10, 10),
        Position = center - Vector2.new(5, 5),
    })
    -- Self-dot outline for contrast
    local selfOutline = newDraw('Square', {
        Visible   = true,
        Filled    = false,
        Color     = Color3.fromRGB(0, 0, 0),
        Thickness = 1,
        Size      = Vector2.new(10, 10),
        Position  = center - Vector2.new(5, 5),
    })

    -- Insert order = draw order; BG first so blips render on top
    table.insert(radarDrawings, glow)
    table.insert(radarDrawings, border)
    table.insert(radarDrawings, bg)
    table.insert(radarDrawings, ch_h)
    table.insert(radarDrawings, ch_v)
    table.insert(radarDrawings, lbl)
    table.insert(radarDrawings, selfDot)
    table.insert(radarDrawings, selfOutline)

    return {
        glow=glow, border=border, bg=bg,
        ch_h=ch_h, ch_v=ch_v, lbl=lbl,
        selfDot=selfDot, selfOutline=selfOutline
    }
end

-- Ensure a blip exists for a player (called lazily during radar loop)
local function ensureBlip(player)
    if player == LocalPlayer then return end
    if radarBlips[player] then return end
    radarBlips[player] = {
        -- Glow halo behind the dot (slightly larger, semi-transparent)
        glow = newDraw('Square', { Visible=false, Filled=true,  Size=Vector2.new(18,18), Transparency=0.5 }),
        -- Main dot
        dot  = newDraw('Square', { Visible=false, Filled=true,  Size=Vector2.new(10,10) }),
        -- Black outline so dot pops on any background
        outline = newDraw('Square', { Visible=false, Filled=false, Thickness=1, Color=Color3.new(0,0,0), Size=Vector2.new(10,10) }),
        -- Player name
        name = newDraw('Text', { Visible=false, Size=11, Outline=true, OutlineColor=Color3.new(0,0,0), Center=true }),
        -- Distance in studs
        dist = newDraw('Text', { Visible=false, Size=10, Outline=true, OutlineColor=Color3.new(0,0,0), Center=true, Color=Color3.fromRGB(220,220,220) }),
    }
end

local radarBG = nil   -- holds refs returned by buildRadarBG
local lastRadarSize = nil

local function stopRadar()
    if RadarConn      then RadarConn:Disconnect();      RadarConn      = nil end
    if RadarDragConn1 then RadarDragConn1:Disconnect(); RadarDragConn1 = nil end
    if RadarDragConn2 then RadarDragConn2:Disconnect(); RadarDragConn2 = nil end
    if RadarDragConn3 then RadarDragConn3:Disconnect(); RadarDragConn3 = nil end
    radarDragging = false
    clearRadarStatic()
    clearAllRadarBlips()
    radarBG       = nil
    lastRadarSize = nil
end

local function startRadar(on)
    stopRadar()
    if not on then return end

    for _, p in next, Players:GetPlayers() do ensureBlip(p) end

    local function getSize()  return Options.RadarSize  and Options.RadarSize.Value  or RADAR_DEFAULT_SIZE  end
    local function getRange() return Options.RadarRange and Options.RadarRange.Value or RADAR_DEFAULT_RANGE end

    -- Initialise center only on first launch; preserve it across size changes / re-enables
    if not radarCenter then
        local cam = workspace.CurrentCamera
        local vs  = cam and cam.ViewportSize or Vector2.new(1920, 1080)
        local sz  = getSize()
        radarCenter = Vector2.new(vs.X - sz/2 - 20, vs.Y - sz/2 - 20)
    end

    local sz = getSize()
    radarBG       = buildRadarBG(radarCenter, sz)
    lastRadarSize = sz

    -- ── Drag handling ──────────────────────────────────────────────
    -- InputBegan: start drag when left-clicking inside the radar square
    RadarDragConn1 = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local mp    = UserInputService:GetMouseLocation()
        local half  = (Options.RadarSize and Options.RadarSize.Value or RADAR_DEFAULT_SIZE) / 2
        local ctr   = radarCenter
        if math.abs(mp.X - ctr.X) <= half and math.abs(mp.Y - ctr.Y) <= half then
            radarDragging   = true
            radarDragOffset = mp - ctr
        end
    end)

    -- InputChanged: move radar with the mouse while dragging
    RadarDragConn2 = UserInputService.InputChanged:Connect(function(input)
        if not radarDragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local mp = UserInputService:GetMouseLocation()
        radarCenter = mp - radarDragOffset
    end)

    -- InputEnded: release drag
    RadarDragConn3 = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            radarDragging = false
        end
    end)
    -- ──────────────────────────────────────────────────────────────

    RadarConn = RunService.RenderStepped:Connect(function()
        local cam2 = workspace.CurrentCamera; if not cam2 then return end
        local sz2  = getSize()
        local rng  = getRange()
        -- Use the draggable radarCenter upvalue; clamp to viewport so it can't go off-screen
        local vs2  = cam2.ViewportSize
        local half = sz2 / 2
        radarCenter = Vector2.new(
            math.clamp(radarCenter.X, half + 4, vs2.X - half - 4),
            math.clamp(radarCenter.Y, half + 4, vs2.Y - half - 4)
        )
        local ctr2 = radarCenter

        -- Rebuild BG only if size changed (avoids per-frame allocation)
        if sz2 ~= lastRadarSize then
            radarBG       = buildRadarBG(ctr2, sz2)
            lastRadarSize = sz2
        else
            -- Reposition existing BG elements to current (possibly dragged) center
            radarBG.glow.Size         = Vector2.new(sz2+10, sz2+10)
            radarBG.glow.Position     = ctr2 - Vector2.new(half+5, half+5)
            radarBG.border.Size       = Vector2.new(sz2+4, sz2+4)
            radarBG.border.Position   = ctr2 - Vector2.new(half+2, half+2)
            radarBG.bg.Size           = Vector2.new(sz2, sz2)
            radarBG.bg.Position       = ctr2 - Vector2.new(half, half)
            radarBG.ch_h.From         = Vector2.new(ctr2.X - half, ctr2.Y)
            radarBG.ch_h.To           = Vector2.new(ctr2.X + half, ctr2.Y)
            radarBG.ch_v.From         = Vector2.new(ctr2.X, ctr2.Y - half)
            radarBG.ch_v.To           = Vector2.new(ctr2.X, ctr2.Y + half)
            radarBG.lbl.Position      = Vector2.new(ctr2.X, ctr2.Y - half - 16)
            radarBG.selfDot.Position    = ctr2 - Vector2.new(5, 5)
            radarBG.selfOutline.Position = ctr2 - Vector2.new(5, 5)
        end

        -- Resolve origin
        local useSpec   = Toggles.SpectateEnabled and Toggles.SpectateEnabled.Value and SpectateTarget
        local origChar  = useSpec and SpectateTarget.Character or LocalPlayer.Character
        local origRoot  = origChar and origChar:FindFirstChild('HumanoidRootPart')

        if not origRoot then
            for _, blip in next, radarBlips do
                blip.dot.Visible = false; blip.name.Visible = false
            end
            return
        end
        local origin = origRoot.Position
        local showNames = Toggles.RadarNames and Toggles.RadarNames.Value
        local showDist  = Toggles.RadarDist  and Toggles.RadarDist.Value

        for player, blip in next, radarBlips do
            local char = player.Character
            local root = char and char:FindFirstChild('HumanoidRootPart')
            if not root then
                blip.glow.Visible    = false
                blip.dot.Visible     = false
                blip.outline.Visible = false
                blip.name.Visible    = false
                blip.dist.Visible    = false
                continue
            end

            local pos2D   = worldToRadarPos(origin, root.Position, ctr2, half, rng)
            local inBounds = math.abs(pos2D.X - ctr2.X) <= half
                          and math.abs(pos2D.Y - ctr2.Y) <= half

            blip.glow.Visible    = inBounds
            blip.dot.Visible     = inBounds
            blip.outline.Visible = inBounds
            blip.name.Visible    = inBounds and showNames
            blip.dist.Visible    = inBounds and showDist

            if inBounds then
                -- Colour logic: spectated = cyan, otherwise match ESP colours
                local col
                if player == SpectateTarget then
                    col = Color3.fromRGB(0, 255, 255)
                elseif Toggles.EspUseTeamColor and Toggles.EspUseTeamColor.Value and player.TeamColor then
                    col = player.TeamColor.Color
                else
                    local isAlly = player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team
                    col = isAlly
                        and (Options.AllyColor  and Options.AllyColor.Value  or Color3.fromRGB(0, 255, 80))
                        or  (Options.EnemyColor and Options.EnemyColor.Value or Color3.fromRGB(255, 40, 40))
                end

                local DOT_SIZE = 10
                local GLOW_SIZE = 18

                -- Glow halo (behind dot, same color but transparent)
                blip.glow.Color    = col
                blip.glow.Size     = Vector2.new(GLOW_SIZE, GLOW_SIZE)
                blip.glow.Position = pos2D - Vector2.new(GLOW_SIZE/2, GLOW_SIZE/2)

                -- Main dot
                blip.dot.Color    = col
                blip.dot.Size     = Vector2.new(DOT_SIZE, DOT_SIZE)
                blip.dot.Position = pos2D - Vector2.new(DOT_SIZE/2, DOT_SIZE/2)

                -- Black outline
                blip.outline.Size     = Vector2.new(DOT_SIZE, DOT_SIZE)
                blip.outline.Position = pos2D - Vector2.new(DOT_SIZE/2, DOT_SIZE/2)

                -- Label stack: name above, dist below
                local labelOffset = DOT_SIZE/2 + 2
                if showNames then
                    blip.name.Text     = player.Name
                    blip.name.Color    = col
                    blip.name.Position = pos2D - Vector2.new(0, labelOffset + 11)
                end
                if showDist then
                    local studs = math.floor((root.Position - origin).Magnitude)
                    blip.dist.Text     = studs .. 'm'
                    blip.dist.Color    = Color3.fromRGB(220, 220, 220)
                    blip.dist.Position = pos2D + Vector2.new(0, labelOffset)
                end
            end
        end
    end)
end

-- Keep blip table in sync with player join/leave
Players.PlayerAdded:Connect(function(p)
    if Toggles.RadarEnabled and Toggles.RadarEnabled.Value then ensureBlip(p) end
end)
Players.PlayerRemoving:Connect(function(p)
    if radarBlips[p] then
        pcall(function() radarBlips[p].glow:Remove()    end)
        pcall(function() radarBlips[p].dot:Remove()     end)
        pcall(function() radarBlips[p].outline:Remove() end)
        pcall(function() radarBlips[p].name:Remove()    end)
        pcall(function() radarBlips[p].dist:Remove()    end)
        radarBlips[p] = nil
    end
end)

-- ── Radar UI ───────────────────────────────────────────────────
local RadarGrp = Tabs.ESP:AddRightGroupbox('Radar')
RadarGrp:AddToggle('RadarEnabled', {
    Text    = 'Enable Radar',
    Default = false,
    Callback = startRadar,
})
RadarGrp:AddToggle('RadarNames', { Text = 'Show Names on Radar', Default = false })
RadarGrp:AddToggle('RadarDist',  { Text = 'Show Distance on Radar', Default = true })
RadarGrp:AddSlider('RadarSize', {
    Text     = 'Radar Size (px)',
    Default  = RADAR_DEFAULT_SIZE,
    Min      = 100,
    Max      = 1200,
    Rounding = 0,
})
RadarGrp:AddSlider('RadarRange', {
    Text     = 'World Range (studs)',
    Default  = RADAR_DEFAULT_RANGE,
    Min      = 50,
    Max      = 2000,
    Rounding = 0,
})
RadarGrp:AddButton('Reset Radar Position', function()
    -- Snap back to default bottom-right corner
    local cam = workspace.CurrentCamera
    local vs  = cam and cam.ViewportSize or Vector2.new(1920, 1080)
    local sz  = Options.RadarSize and Options.RadarSize.Value or RADAR_DEFAULT_SIZE
    radarCenter   = Vector2.new(vs.X - sz/2 - 20, vs.Y - sz/2 - 20)
    radarDragging = false
end)

-- ================================================================
--  ANTI-AFK
-- ================================================================
--  Hooks LocalPlayer.Idled (fires after ~5 min of no input) and
--  sends a harmless VirtualUser button press to reset the timer.
--  Falls back to a periodic humanoid jump if VirtualUser is blocked.
-- ================================================================

local AntiAfkConn = nil

local function setAntiAfk(on)
    if AntiAfkConn then AntiAfkConn:Disconnect(); AntiAfkConn = nil end
    if not on then return end

    local ok, VU = pcall(function() return game:GetService('VirtualUser') end)
    if ok and VU then
        -- Primary: respond to the Idled event Roblox fires before kicking
        AntiAfkConn = LocalPlayer.Idled:Connect(function()
            VU:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            task.wait(0.1)
            VU:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
        end)
    else
        -- Fallback: jump every 4 minutes
        local lastFire = tick()
        AntiAfkConn = RunService.Heartbeat:Connect(function()
            if tick() - lastFire < 240 then return end
            lastFire = tick()
            local char = LocalPlayer.Character
            local hum  = char and char:FindFirstChildWhichIsA('Humanoid')
            if hum then hum.Jump = true end
        end)
    end
end

-- ================================================================
--  POTATO GRAPHICS
-- ================================================================
--  Saves current settings, then hammers everything to minimum.
--  Toggling OFF fully restores the saved state.
--
--  What gets nuked:
--    • Rendering quality level → Level01
--    • GlobalShadows → false
--    • All PostEffect objects in Lighting → Disabled
--    • Atmosphere / Sky → removed from Lighting
--    • ParticleEmitter, Beam, Trail, Fire, Smoke, Sparkles → Rate=0
-- ================================================================

local savedGfx = nil   -- holds pre-potato state for restoration
local removedLightingChildren = {}  -- Atmosphere / Sky refs

local function applyPotatoGraphics()
    local ls = game:GetService('Lighting')
    savedGfx = {
        quality       = settings().Rendering.QualityLevel,
        globalShadows = ls.GlobalShadows,
        brightness    = ls.Brightness,
        shadowSoft    = ls.ShadowSoftness,
        postEffects   = {},
    }

    -- Rendering quality
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)

    -- Lighting
    ls.GlobalShadows  = false
    ls.Brightness     = 1
    ls.ShadowSoftness = 0

    -- Post effects
    for _, v in next, ls:GetChildren() do
        if v:IsA('PostEffect') then
            savedGfx.postEffects[v] = v.Enabled
            v.Enabled = false
        end
    end

    -- Atmosphere & Sky: detach so they stop rendering
    removedLightingChildren = {}
    for _, v in next, ls:GetChildren() do
        if v:IsA('Atmosphere') or v:IsA('Sky') then
            v.Parent = nil
            table.insert(removedLightingChildren, v)
        end
    end

    -- Kill VFX across the entire workspace
    for _, v in next, workspace:GetDescendants() do
        if v:IsA('ParticleEmitter') or v:IsA('Beam') or v:IsA('Trail') then
            pcall(function() v.Enabled = false end)
        elseif v:IsA('Fire') or v:IsA('Smoke') or v:IsA('Sparkles') then
            pcall(function() v.Enabled = false end)
        end
    end
end

local function restoreGraphics()
    if not savedGfx then return end
    local ls = game:GetService('Lighting')

    pcall(function() settings().Rendering.QualityLevel = savedGfx.quality end)
    ls.GlobalShadows  = savedGfx.globalShadows
    ls.Brightness     = savedGfx.brightness
    ls.ShadowSoftness = savedGfx.shadowSoft

    for v, wasEnabled in next, savedGfx.postEffects do
        pcall(function() v.Enabled = wasEnabled end)
    end

    -- Restore detached Lighting children
    for _, v in next, removedLightingChildren do
        pcall(function() v.Parent = ls end)
    end
    removedLightingChildren = {}

    -- Re-enable VFX
    for _, v in next, workspace:GetDescendants() do
        if v:IsA('ParticleEmitter') or v:IsA('Beam') or v:IsA('Trail')
        or v:IsA('Fire') or v:IsA('Smoke') or v:IsA('Sparkles') then
            pcall(function() v.Enabled = true end)
        end
    end

    savedGfx = nil
end

-- ── Misc UI groupbox ───────────────────────────────────────────
local MiscGrp = Tabs.ESP:AddLeftGroupbox('Misc')

MiscGrp:AddToggle('AntiAfk', {
    Text     = 'Anti-AFK',
    Default  = false,
    Callback = setAntiAfk,
})

MiscGrp:AddToggle('PotatoGraphics', {
    Text     = 'Potato Graphics',
    Default  = false,
    Callback = function(on)
        if on then applyPotatoGraphics() else restoreGraphics() end
    end,
})

end -- return function
