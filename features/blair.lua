-- ================================================================
--  Yazu Feature Template
--  Use this to add new logic while staying compatible with the UI
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService    = Services.RunService
local LocalPlayer   = Services.LocalPlayer
local RepStorage    = Services.ReplicatedStorage
local Toggles       = State.Toggles -- Access to all UI toggle states
local Options       = State.Options -- Access to all UI slider/keybind states

-- ── 1. TAB & GROUPBOX SETUP ───────────────────────────────────
-- Replace 'Misc' with the specific tab name if needed
local MyTab = Tabs.Blair or Tabs.Misc 
local MyGroup = MyTab:AddLeftGroupbox('New Feature Group')

-- ── 2. INTERNAL CACHE ─────────────────────────────────────────
local Internal = {
    LastExecution = 0,
    ActiveObjects = {}
}

-- Helper for Blair-specific modules
local function GetMod(name)
    local s = RepStorage:FindFirstChild("SharedData")
    local m = s and s:FindFirstChild(name)
    if m then
        local ok, res = pcall(require, m)
        return ok and res or nil
    end
    return nil
end

-- ── 3. UI ELEMENTS ────────────────────────────────────────────
-- Toggle ID must be unique (e.g., 'Template_MyFeature')
MyGroup:AddToggle('Template_Feature1', { Text = 'Enable Logic A', Default = false })
MyGroup:AddToggle('Template_Feature2', { Text = 'Enable Logic B', Default = false })

-- ── 4. INSTANT LOGIC (HEARTBEAT) ──────────────────────────────
-- Best for: Movement, constant value freezing, UI overlays
RunService.Heartbeat:Connect(function()
    
    -- [FEATURE A]
    if Toggles.Template_Feature1 and Toggles.Template_Feature1.Value then
        -- Insert logic that needs to run every frame here
        -- Example: LocalPlayer.Character.Humanoid.WalkSpeed = 25
    end

end)

-- ── 5. LOOPED LOGIC (THREADED) ────────────────────────────────
-- Best for: ESP, Remote spamming, searching workspace, notifications
task.spawn(function()
    while true do
        task.wait(1) -- Adjust delay to save performance
        
        -- [FEATURE B]
        if Toggles.Template_Feature2 and Toggles.Template_Feature2.Value then
            -- Insert logic that only needs to check occasionally
            -- Example: Notify player of ghost location
            print("Logic B is looping...")
        end
    end
end)

-- ── 6. INITIALIZATION ─────────────────────────────────────────
Library:Notify("Template Module Loaded", 2)

end
