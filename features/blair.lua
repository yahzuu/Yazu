return function(State, Tabs, Services, Library)
    -- 1. Setup local variables for easy access
    local LocalPlayer = Services.LocalPlayer
    local RunService  = Services.RunService
    local Toggles     = State.Toggles -- This is where Linoria stores toggle states
    local Options     = State.Options -- This is where sliders/keybinds are

    -- 2. Create the UI Group
    local BlairTab = Tabs.Blair or Tabs.Misc -- Fallback if tab doesn't exist
    local MyGroup  = BlairTab:AddLeftGroupbox('Custom Logic')

    -- 3. Add a Toggle
    -- 'MyCustomFeature' is the internal ID used to check the state
    MyGroup:AddToggle('MyCustomFeature', { 
        Text = 'Enable Custom Logic', 
        Default = false,
        Tooltip = 'This runs the code in the loop below'
    })

    -- 4. The Logic Processor (The "Brain")
    -- We use a loop so the code is always ready to react when you click the toggle
    task.spawn(function()
        while true do
            task.wait() -- Small wait to prevent crashing
            
            -- CHECK: Is the toggle on?
            if Toggles.MyCustomFeature and Toggles.MyCustomFeature.Value then
                
                -- INSERT YOUR LOGIC HERE
                -- Example: print("Logic is running!")
                
            else
                -- OPTIONAL: Logic to run when the toggle is OFF
            end
        end
    end)
end
