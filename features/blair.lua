-- ================================================================
--  features/blair.lua
--  Advanced Blair Integration for Yazu Framework
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService    = Services.RunService
local LocalPlayer   = Services.LocalPlayer
local RepStorage    = Services.ReplicatedStorage

-- ── 1. TAB RECOVERY ───────────────────────────────────────────
-- If you didn't add the tab in main.lua, this logic finds the window 
-- and creates it so the script doesn't crash.
local BlairTab = Tabs.Blair
if not BlairTab then
    -- Try to find the Window object to add the tab dynamically
    for _, v in next, getgc(true) do
        if type(v) == 'table' and rawget(v, 'AddTab') and rawget(v, 'CreateWindow') == nil then
            BlairTab = v:AddTab('Blair')
            Tabs.Blair = BlairTab
            break
        end
    end
end

-- Fallback to Misc if window recovery fails
if not BlairTab then BlairTab = Tabs.Misc end

-- ── 2. UI GROUPS ──────────────────────────────────────────────
local MainGrp  = BlairTab:AddLeftGroupbox('Character Perks')
local VisGrp   = BlairTab:AddLeftGroupbox('Visuals')
local EvidGrp  = BlairTab:AddRightGroupbox('Ghost & Evidence')
local MiscGrp  = BlairTab:AddRightGroupbox('Miscellaneous')

-- ── 3. INTERNAL STATE ─────────────────────────────────────────
local BlairState = {
    OriginalSanityFunc = nil,
    CrosshairLines    = {},
    LastAlert         = 0
}

-- ── 4. HELPER: Safe Module Access ─────────────────────────────
local function GetModule(name)
    local shared = RepStorage:FindFirstChild("SharedData")
    local module = shared and shared:FindFirstChild(name)
    if module then
        local success, result = pcall(require, module)
        return success and result or nil
    end
    return nil
end

-- ── 5. FEATURE IMPLEMENTATION ─────────────────────────────────

-- [Sanity Freeze Hook]
local function ToggleSanity(val)
    local sanityMod = GetModule("SanityMonitor")
    if not sanityMod then return end
    
    if val then
        BlairState.OriginalSanityFunc = sanityMod.setSanity
        sanityMod.setSanity = function(newVal)
            -- Force it to 100 regardless of game logic
            return BlairState.OriginalSanityFunc(100)
        end
    else
        if BlairState.OriginalSanityFunc then
            sanityMod.setSanity = BlairState.OriginalSanityFunc
        end
    end
end

-- [Crosshair Drawing]
local function UpdateCrosshair()
    local enabled = Toggles.Blair_Crosshair and Toggles.Blair_Crosshair.Value
    if not BlairState.CrosshairLines[1] then
        BlairState.CrosshairLines[1] = Drawing.new("Line")
        BlairState.CrosshairLines[2] = Drawing.new("Line")
    end
    
    local h, v = BlairState.CrosshairLines[1], BlairState.CrosshairLines[2]
    h.Visible = enabled
    v.Visible = enabled
    
    if enabled then
        local center = workspace.CurrentCamera.ViewportSize / 2
        h.Color = Color3.fromRGB(255, 0, 0); h.Thickness = 2
        h.From = center - Vector2.new(15, 0); h.To = center + Vector2.new(15, 0)
        
        v.Color = Color3.fromRGB(255, 0, 0); v.Thickness = 2
        v.From = center - Vector2.new(0, 15); v.To = center + Vector2.new(0, 15)
    end
end

-- ── 6. UI ELEMENTS ────────────────────────────────────────────

MainGrp:AddToggle('Blair_InfStamina', { Text = 'Infinite Stamina', Default = false })
MainGrp:AddToggle('Blair_SanityFreeze', { Text = 'Sanity Freeze (100%)', Default = false, Callback = ToggleSanity })

VisGrp:AddToggle('Blair_FullBright', { Text = 'Full Bright', Default = false })
VisGrp:AddToggle('Blair_NoFlashDrain', { Text = 'No Flashlight Drain', Default = false })
VisGrp:AddToggle('Blair_Crosshair', { Text = 'Crosshair Overlay', Default = false })

EvidGrp:AddToggle('Blair_AutoLog', { Text = 'Auto Evidence Logger', Default = false })
EvidGrp:AddToggle('Blair_WritingInd', { Text = 'Ghost Writing Indicator', Default = false })
EvidGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = false })

MiscGrp:AddToggle('Blair_FastInteract', { Text = 'Fast Interaction', Default = false })
MiscGrp:AddToggle('Blair_RadioSpam', { Text = 'Radio Spammer', Default = false })

-- ── 7. MAIN HEARTBEAT LOOP ─────────────────────────────────────

RunService.Heartbeat:Connect(function()
    -- 1. Infinite Stamina
    if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        local ctrlMod = pGui and pGui:FindFirstChild("Game") and pGui.Game:FindFirstChild("PlayerController")
        if ctrlMod then
            local ctrl = require(ctrlMod)
            if ctrl then ctrl.Sprint = 0.5 end
        end
    end

    -- 2. Full Bright
    if Toggles.Blair_FullBright and Toggles.Blair_FullBright.Value then
        local light = GetModule("LightPartRemote")
        if light then light.OverrideAmbient = true end
    end

    -- 3. Flashlight
    if Toggles.Blair_NoFlashDrain and Toggles.Blair_NoFlashDrain.Value then
        local fl = GetModule("Flashlight")
        if fl then fl.Intensity = 1 end
    end

    -- 4. Fast Interaction
    if Toggles.Blair_FastInteract and Toggles.Blair_FastInteract.Value then
        for _, prompt in next, workspace:GetDescendants() do
            if prompt:IsA("ProximityPrompt") then
                prompt.HoldDuration = 0
            end
        end
    end

    -- 5. Crosshair
    UpdateCrosshair()

    -- 6. Evidence Monitoring
    if Toggles.Blair_AutoLog and Toggles.Blair_AutoLog.Value then
        local emf = GetModule("EMFLocalCore")
        local thermo = GetModule("ThermometerLocalCore")
        if (emf and emf.EvidenceFound) or (thermo and thermo.TemperatureDrop) then
            if os.clock() - BlairState.LastAlert > 5 then
                Library:Notify("Evidence Detected! Check your logs.", 4)
                BlairState.LastAlert = os.clock()
            end
        end
    end
end)

-- ── 8. GHOST ESP (Dedicated Thread) ───────────────────────────
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_GhostESP and Toggles.Blair_GhostESP.Value then
            for _, obj in next, workspace:GetChildren() do
                if obj.Name:find("Ghost") and obj:IsA("Model") then
                    if not obj:FindFirstChild("YazuGhostESP") then
                        local h = Instance.new("Highlight", obj)
                        h.Name = "YazuGhostESP"
                        h.FillColor = Color3.fromRGB(255, 0, 0)
                        h.OutlineColor = Color3.fromRGB(255, 255, 255)
                    end
                end
            end
        else
            for _, obj in next, workspace:GetChildren() do
                local h = obj:FindFirstChild("YazuGhostESP")
                if h then h:Destroy() end
            end
        end
    end
end)

-- ── 9. RADIO SPAM (Dedicated Thread) ──────────────────────────
task.spawn(function()
    while true do
        task.wait(0.5)
        if Toggles.Blair_RadioSpam and Toggles.Blair_RadioSpam.Value then
            local radio = GetModule("RadioRemote")
            if radio and radio.SendSignal then
                pcall(function() radio.SendSignal("Signal Interference") end)
            end
        end
    end
end)

end
