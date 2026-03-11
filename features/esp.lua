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

end -- return function
