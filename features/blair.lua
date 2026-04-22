-- ================================================================
--  features/blair.lua
--  Blair-specific features for Yazu
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService      = Services.RunService
local Players         = Services.Players
local LocalPlayer     = Services.LocalPlayer
local RepStorage      = Services.ReplicatedStorage
local UserInput       = Services.UserInputService

-- ── Variables ─────────────────────────────────────────────────
local BlairTab = Tabs.Blair
local MainGrp  = BlairTab:AddLeftGroupbox('Player Hacks')
local EvidGrp  = BlairTab:AddRightGroupbox('Ghost & Evidence')
local VisGrp   = BlairTab:AddLeftGroupbox('Visuals')
local MiscGrp  = BlairTab:AddRightGroupbox('Miscellaneous')

local OriginalSanityFunc = nil
local GhostHighlights   = {}

-- ── Helpers ───────────────────────────────────────────────────
local function GetSharedModule(name)
    local sharedData = RepStorage:FindFirstChild("SharedData")
    if sharedData then
        local module = sharedData:FindFirstChild(name)
        if module then return require(module) end
    end
    return nil
end

local function GetPlayerController()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local gameFolder = playerGui and playerGui:FindFirstChild("Game")
    local controllerModule = gameFolder and gameFolder:FindFirstChild("PlayerController")
    if controllerModule then return require(controllerModule) end
    return nil
end

-- ── Crosshair Logic ───────────────────────────────────────────
local CrosshairL1 = Drawing.new("Line")
local CrosshairL2 = Drawing.new("Line")

local function UpdateCrosshair()
    local enabled = Toggles.Blair_Crosshair and Toggles.Blair_Crosshair.Value
    CrosshairL1.Visible = enabled
    CrosshairL2.Visible = enabled

    if enabled then
        local cam = workspace.CurrentCamera
        local center = cam.ViewportSize / 2
        
        CrosshairL1.From = center - Vector2.new(15, 0)
        CrosshairL1.To   = center + Vector2.new(15, 0)
        CrosshairL1.Color = Color3.fromRGB(255, 0, 0)
        CrosshairL1.Thickness = 2

        CrosshairL2.From = center - Vector2.new(0, 15)
        CrosshairL2.To   = center + Vector2.new(0, 15)
        CrosshairL2.Color = Color3.fromRGB(255, 0, 0)
        CrosshairL2.Thickness = 2
    end
end

-- ── UI Elements & Logic ───────────────────────────────────────

-- [Character Section]
MainGrp:AddToggle('Blair_InfStamina', { Text = 'Infinite Stamina', Default = false })
MainGrp:AddToggle('Blair_SanityFreeze', { 
    Text = 'Sanity Freeze (100%)', 
    Default = false,
    Callback = function(val)
        local sanityMod = GetSharedModule("SanityMonitor")
        if sanityMod then
            if val then
                OriginalSanityFunc = sanityMod.setSanity
                sanityMod.setSanity = function(newVal)
                    if newVal < 100 then return OriginalSanityFunc(100) end
                    return OriginalSanityFunc(newVal)
                end
            elseif OriginalSanityFunc then
                sanityMod.setSanity = OriginalSanityFunc
            end
        end
    end
})

-- [Ghost & Evidence Section]
EvidGrp:AddToggle('Blair_AutoLog', { Text = 'Auto Evidence Logger', Default = false })
EvidGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = false })
EvidGrp:AddToggle('Blair_WritingInd', { Text = 'Ghost Writing Indicator', Default = false })

-- [Visuals Section]
VisGrp:AddToggle('Blair_FullBright', { Text = 'Full Bright', Default = false })
VisGrp:AddToggle('Blair_NoFlashDrain', { Text = 'No Flashlight Drain', Default = false })
VisGrp:AddToggle('Blair_Crosshair', { Text = 'Crosshair', Default = false })

-- [Misc Section]
MiscGrp:AddToggle('Blair_FastInteract', { Text = 'Fast Interaction', Default = false })
MiscGrp:AddToggle('Blair_RadioSpam', { Text = 'Radio Spammer', Default = false })

-- ── Main Loop (Heartbeat) ─────────────────────────────────────
RunService.Heartbeat:Connect(function()
    -- 1. Infinite Stamina
    if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
        local controller = GetPlayerController()
        if controller then controller.Sprint = 0.5 end
    end

    -- 2. Full Bright
    if Toggles.Blair_FullBright and Toggles.Blair_FullBright.Value then
        local lightMod = GetSharedModule("LightPartRemote")
        if lightMod then lightMod.OverrideAmbient = true end
    end

    -- 3. Flashlight
    if Toggles.Blair_NoFlashDrain and Toggles.Blair_NoFlashDrain.Value then
        local flashMod = GetSharedModule("Flashlight")
        if flashMod then flashMod.Intensity = 1 end
    end

    -- 4. Fast Interaction
    if Toggles.Blair_FastInteract and Toggles.Blair_FastInteract.Value then
        for _, obj in next, workspace:GetDescendants() do
            if obj:IsA("ProximityPrompt") then
                obj.HoldDuration = 0
            end
        end
    end

    -- 5. Auto Evidence / Indicators
    if Toggles.Blair_AutoLog and Toggles.Blair_AutoLog.Value then
        local emf = GetSharedModule("EMFLocalCore")
        local thermo = GetSharedModule("ThermometerLocalCore")
        if emf and emf.EvidenceFound then Library:Notify("EMF Evidence Detected!") end
        if thermo and thermo.TemperatureDrop then Library:Notify("Freezing Temps Detected!") end
    end

    if Toggles.Blair_WritingInd and Toggles.Blair_WritingInd.Value then
        local book = GetSharedModule("GhostWritingBook")
        if book and book.EvidenceFound then Library:Notify("Ghost Writing Found!") end
    end

    -- 6. Ghost ESP
    if Toggles.Blair_GhostESP and Toggles.Blair_GhostESP.Value then
        for _, obj in next, workspace:GetChildren() do
            if obj.Name:find("Ghost") and obj:IsA("Model") then
                if not obj:FindFirstChild("YazuESP") then
                    local h = Instance.new("Highlight")
                    h.Name = "YazuESP"
                    h.FillColor = Color3.fromRGB(255, 0, 0)
                    h.OutlineColor = Color3.fromRGB(255, 255, 255)
                    h.Parent = obj
                end
            end
        end
    else
        for _, obj in next, workspace:GetChildren() do
            local h = obj:FindFirstChild("YazuESP")
            if h then h:Destroy() end
        end
    end

    -- 7. Crosshair
    UpdateCrosshair()
end)

-- ── Secondary Loop (Radio Spam) ───────────────────────────────
task.spawn(function()
    while task.wait(1) do
        if Toggles.Blair_RadioSpam and Toggles.Blair_RadioSpam.Value then
            local radio = GetSharedModule("RadioRemote")
            if radio then radio.SendSignal("Signal Interference Detected") end
        end
    end
end)

end
