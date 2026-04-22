-- ================================================================
--  features/blair.lua
--  Comprehensive script for Blair (Phasmophobia clone)
--  Integrated with Yazu Framework & LinoriaLib
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService    = Services.RunService
local Players       = Services.Players
local LocalPlayer   = Services.LocalPlayer
local RepStorage    = Services.ReplicatedStorage
local UserInput     = Services.UserInputService

-- ── 1. Variables & State ──────────────────────────────────────
local BlairState = {
    OriginalSanityHook = nil,
    GhostList          = {},
    ItemList           = {},
    DrawingObjects     = {},
}

-- ── 2. UI Setup ───────────────────────────────────────────────
local BlairTab = Tabs.Blair
local CharGrp  = BlairTab:AddLeftGroupbox('Character')
local GhostGrp = BlairTab:AddRightGroupbox('Ghost & Evidence')
local WorldGrp = BlairTab:AddLeftGroupbox('World & Visuals')
local MiscGrp  = BlairTab:AddRightGroupbox('Misc')

-- ── 3. Feature Functions ──────────────────────────────────────

-- Crosshair Setup
local CrosshairX = Drawing.new("Line")
local CrosshairY = Drawing.new("Line")

local function UpdateCrosshair()
    local visible = Toggles.Blair_Crosshair and Toggles.Blair_Crosshair.Value or false
    CrosshairX.Visible = visible
    CrosshairY.Visible = visible
    
    if visible then
        local center = UserInput:GetMouseLocation()
        CrosshairX.From      = center - Vector2.new(10, 0)
        CrosshairX.To        = center + Vector2.new(10, 0)
        CrosshairX.Color     = Color3.fromRGB(255, 0, 0)
        CrosshairX.Thickness = 2
        
        CrosshairY.From      = center - Vector2.new(0, 10)
        CrosshairY.To        = center + Vector2.new(0, 10)
        CrosshairY.Color     = Color3.fromRGB(255, 0, 0)
        CrosshairY.Thickness = 2
    end
end

-- Infinite Stamina
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
            pcall(function()
                local playerGui = LocalPlayer:WaitForChild("PlayerGui")
                local controller = require(playerGui:WaitForChild("Game"):WaitForChild("PlayerController"))
                if controller then
                    controller.Sprint = 0.5 -- Prevent depletion
                end
            end)
        end
    end
end)

-- Sanity Freeze
local function ToggleSanity(val)
    pcall(function()
        local sanityModule = require(RepStorage:WaitForChild("SharedData"):WaitForChild("SanityMonitor"))
        if val then
            BlairState.OriginalSanityHook = sanityModule.setSanity
            sanityModule.setSanity = function(value)
                if value < 100 then return BlairState.OriginalSanityHook(100) end
                return BlairState.OriginalSanityHook(value)
            end
        else
            if BlairState.OriginalSanityHook then
                sanityModule.setSanity = BlairState.OriginalSanityHook
            end
        end
    end)
end

-- ── 4. UI Controls ─────────────────────────────────────────────

-- Character Group
CharGrp:AddToggle('Blair_InfStamina', { Text = 'Infinite Stamina', Default = false })
CharGrp:AddToggle('Blair_SanityFreeze', { 
    Text = 'Sanity Freeze (100%)', 
    Default = false,
    Callback = ToggleSanity
})

-- Ghost & Evidence Group
GhostGrp:AddToggle('Blair_AutoEvidence', { Text = 'Auto Evidence Logger', Default = false })
GhostGrp:AddToggle('Blair_WritingIndicator', { Text = 'Ghost Writing Indicator', Default = false })
GhostGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = false })

-- World & Visuals Group
WorldGrp:AddToggle('Blair_FullBright', { Text = 'Full Bright (Ambient)', Default = false })
WorldGrp:AddToggle('Blair_NoFlashlightDrain', { Text = 'No Flashlight Drain', Default = false })
WorldGrp:AddToggle('Blair_Crosshair', { Text = 'Crosshair Overlay', Default = false })

-- Misc Group
MiscGrp:AddToggle('Blair_FastInteract', { Text = 'Fast Interaction', Default = false })
MiscGrp:AddToggle('Blair_RadioSpam', { Text = 'Radio Spammer', Default = false })

-- ── 5. Main Loops ──────────────────────────────────────────────

RunService.Heartbeat:Connect(function()
    -- Crosshair Update
    UpdateCrosshair()

    -- Fast Interaction
    if Toggles.Blair_FastInteract and Toggles.Blair_FastInteract.Value then
        for _, prompt in next, workspace:GetDescendants() do
            if prompt:IsA("ProximityPrompt") then
                prompt.HoldDuration = 0
            end
        end
    end

    -- Full Bright Logic
    if Toggles.Blair_FullBright and Toggles.Blair_FullBright.Value then
        pcall(function()
            local lightRemote = require(RepStorage.SharedData:FindFirstChild("LightPartRemote"))
            if lightRemote then lightRemote.OverrideAmbient = true end
        end)
    end

    -- No Flashlight Drain
    if Toggles.Blair_NoFlashlightDrain and Toggles.Blair_NoFlashlightDrain.Value then
        pcall(function()
            local fl = require(RepStorage.SharedData:FindFirstChild("Flashlight"))
            if fl then fl.Intensity = 1 end
        end)
    end

    -- Evidence & Indicators
    pcall(function()
        if Toggles.Blair_AutoEvidence and Toggles.Blair_AutoEvidence.Value then
            local emf = require(RepStorage.SharedData.EMFLocalCore)
            local thermo = require(RepStorage.SharedData.ThermometerLocalCore)
            if emf.EvidenceFound then Library:Notify("[Evidence] EMF Level 5 Detected!") end
            if thermo.TemperatureDrop then Library:Notify("[Evidence] Freezing Temps Detected!") end
        end

        if Toggles.Blair_WritingIndicator and Toggles.Blair_WritingIndicator.Value then
            local book = require(RepStorage.SharedData.GhostWritingBook)
            if book.EvidenceFound then Library:Notify("[Evidence] Ghost has written in book!") end
        end
    end)
end)

-- Radio Spammer Loop
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_RadioSpam and Toggles.Blair_RadioSpam.Value then
            pcall(function()
                local radio = require(RepStorage.SharedData.RadioRemote)
                radio.SendSignal("Yazu Framework Active")
            end)
        end
    end
end)

-- Ghost ESP Logic
task.spawn(function()
    while true do
        task.wait(0.5)
        if Toggles.Blair_GhostESP and Toggles.Blair_GhostESP.Value then
            for _, v in next, workspace:GetChildren() do
                if v.Name:find("Ghost") and v:FindFirstChild("HumanoidRootPart") then
                    -- Simple Notification or logic here (Full Box ESP would link to features/esp.lua)
                    -- For now, highlights are common in Blair:
                    local highlight = v:FindFirstChild("YazuHighlight") or Instance.new("Highlight", v)
                    highlight.Name = "YazuHighlight"
                    highlight.FillColor = Color3.fromRGB(255, 0, 0)
                    highlight.Enabled = true
                end
            end
        else
            for _, v in next, workspace:GetChildren() do
                local h = v:FindFirstChild("YazuHighlight")
                if h then h.Enabled = false end
            end
        end
    end
end)

end -- End Function
