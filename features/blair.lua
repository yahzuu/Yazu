-- ================================================================
--  features/blair.lua
--  Complete Blair Integration for Yazu Framework
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService      = Services.RunService
local Players         = Services.Players
local LocalPlayer     = Services.LocalPlayer
local RepStorage      = Services.ReplicatedStorage
local UserInput       = Services.UserInputService

-- ── 1. UI SETUP ───────────────────────────────────────────────
local BlairTab = Tabs.Blair
local MainGrp  = BlairTab:AddLeftGroupbox('Player Hacks')
local GhostGrp = BlairTab:AddRightGroupbox('Ghost & Evidence')
local VisGrp   = BlairTab:AddLeftGroupbox('Visuals')
local MiscGrp  = BlairTab:AddRightGroupbox('Miscellaneous')

-- ── 2. INTERNAL STATE ─────────────────────────────────────────
local BlairState = {
    OriginalSanitySet = nil,
    CrosshairLines    = {},
    GhostHighlights   = {},
}

-- ── 3. HELPER FUNCTIONS ───────────────────────────────────────
local function GetModule(path)
    local success, result = pcall(function()
        return require(path)
    end)
    return success and result or nil
end

-- ── 4. FEATURE IMPLEMENTATIONS ────────────────────────────────

-- [CROSSHAIR LOGIC]
local function CreateCrosshair()
    local line1 = Drawing.new("Line")
    local line2 = Drawing.new("Line")
    
    line1.Thickness = 2
    line1.Color = Color3.fromRGB(255, 0, 0)
    line2.Thickness = 2
    line2.Color = Color3.fromRGB(255, 0, 0)
    
    BlairState.CrosshairLines = {line1, line2}
end
CreateCrosshair()

local function UpdateCrosshair()
    local enabled = Toggles.Blair_Crosshair and Toggles.Blair_Crosshair.Value
    local l1, l2 = BlairState.CrosshairLines[1], BlairState.CrosshairLines[2]
    
    l1.Visible = enabled
    l2.Visible = enabled
    
    if enabled then
        local cam = workspace.CurrentCamera
        local center = cam.ViewportSize / 2
        
        l1.From = center - Vector2.new(15, 0)
        l1.To   = center + Vector2.new(15, 0)
        
        l2.From = center - Vector2.new(0, 15)
        l2.To   = center + Vector2.new(0, 15)
    end
end

-- [SANITY HOOK]
local function ToggleSanityFreeze(val)
    local module = GetModule(RepStorage:WaitForChild("SharedData"):WaitForChild("SanityMonitor"))
    if not module then return end

    if val then
        BlairState.OriginalSanitySet = module.setSanity
        module.setSanity = function(value)
            -- If the game tries to set sanity lower than 100, force it to 100
            return BlairState.OriginalSanitySet(100)
        end
    else
        if BlairState.OriginalSanitySet then
            module.setSanity = BlairState.OriginalSanitySet
        end
    end
end

-- ── 5. UI CONTROLS ─────────────────────────────────────────────

-- Player Group
MainGrp:AddToggle('Blair_InfStamina', { Text = 'Infinite Stamina', Default = false })
MainGrp:AddToggle('Blair_SanityFreeze', { Text = 'Sanity Freeze (100%)', Default = false, Callback = ToggleSanityFreeze })

-- Ghost & Evidence Group
GhostGrp:AddToggle('Blair_AutoEvidence', { Text = 'Auto Evidence Logger', Default = false })
GhostGrp:AddToggle('Blair_WritingInd', { Text = 'Ghost Writing Indicator', Default = false })
GhostGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = false })

-- Visuals Group
VisGrp:AddToggle('Blair_FullBright', { Text = 'Full Bright', Default = false })
VisGrp:AddToggle('Blair_NoFlashDrain', { Text = 'No Flashlight Drain', Default = false })
VisGrp:AddToggle('Blair_Crosshair', { Text = 'Crosshair Overlay', Default = false })

-- Misc Group
MiscGrp:AddToggle('Blair_FastInteract', { Text = 'Fast Interaction', Default = false })
MiscGrp:AddToggle('Blair_RadioSpam', { Text = 'Radio Spammer', Default = false })

-- ── 6. MAIN LOOPS ──────────────────────────────────────────────

-- Heartbeat Loop for continuous features
RunService.Heartbeat:Connect(function()
    -- 1. Infinite Stamina
    if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        local controller = playerGui and GetModule(playerGui:WaitForChild("Game"):WaitForChild("PlayerController"))
        if controller then
            controller.Sprint = 0.5
        end
    end

    -- 2. Fast Interaction
    if Toggles.Blair_FastInteract and Toggles.Blair_FastInteract.Value then
        for _, prompt in next, workspace:GetDescendants() do
            if prompt:IsA("ProximityPrompt") then
                prompt.HoldDuration = 0
            end
        end
    end

    -- 3. Full Bright
    if Toggles.Blair_FullBright and Toggles.Blair_FullBright.Value then
        local lightRemote = GetModule(RepStorage.SharedData:FindFirstChild("LightPartRemote"))
        if lightRemote then 
            lightRemote.OverrideAmbient = true 
        end
    end

    -- 4. No Flashlight Drain
    if Toggles.Blair_NoFlashDrain and Toggles.Blair_NoFlashDrain.Value then
        local flashMod = GetModule(RepStorage.SharedData:FindFirstChild("Flashlight"))
        if flashMod then 
            flashMod.Intensity = 1 
        end
    end

    -- 5. Crosshair
    UpdateCrosshair()

    -- 6. Evidence Monitoring (Notifications)
    if Toggles.Blair_AutoEvidence and Toggles.Blair_AutoEvidence.Value then
        local emf = GetModule(RepStorage.SharedData:FindFirstChild("EMFLocalCore"))
        local thermo = GetModule(RepStorage.SharedData:FindFirstChild("ThermometerLocalCore"))
        
        if emf and emf.EvidenceFound then 
            Library:Notify("[BLAIR] EMF Evidence Detected!", 3) 
        end
        if thermo and thermo.TemperatureDrop then 
            Library:Notify("[BLAIR] Freezing Temps Detected!", 3) 
        end
    end

    if Toggles.Blair_WritingInd and Toggles.Blair_WritingInd.Value then
        local book = GetModule(RepStorage.SharedData:FindFirstChild("GhostWritingBook"))
        if book and book.EvidenceFound then 
            Library:Notify("[BLAIR] Ghost Writing Found!", 3)
        end
    end
end)

-- Dedicated Thread for Radio Spammer
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_RadioSpam and Toggles.Blair_RadioSpam.Value then
            local radio = GetModule(RepStorage.SharedData:FindFirstChild("RadioRemote"))
            if radio then
                pcall(function() radio.SendSignal("Yazu Framework Active") end)
            end
        end
    end
end)

-- Ghost ESP Loop
task.spawn(function()
    while true do
        task.wait(0.5)
        if Toggles.Blair_GhostESP and Toggles.Blair_GhostESP.Value then
            for _, obj in next, workspace:GetChildren() do
                -- Blair ghosts usually have "Ghost" in their name
                if obj.Name:find("Ghost") and obj:IsA("Model") then
                    if not obj:FindFirstChild("YazuHighlight") then
                        local highlight = Instance.new("Highlight")
                        highlight.Name = "YazuHighlight"
                        highlight.FillColor = Color3.fromRGB(255, 0, 0)
                        highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
                        highlight.Parent = obj
                    end
                end
            end
        else
            -- Clean up highlights when toggled off
            for _, obj in next, workspace:GetChildren() do
                local h = obj:FindFirstChild("YazuHighlight")
                if h then h:Destroy() end
            end
        end
    end
end)

end -- End Function
