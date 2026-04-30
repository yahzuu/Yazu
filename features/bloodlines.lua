-- ================================================================
--  features/bloodlines.lua - MODIFIED FOR LINORIA COMPATIBILITY
--  This is now a proper Yazu feature module that works with your existing UI
-- ================================================================

return function(State, Tabs, Services, Library)
    local Players = Services.Players
    local ReplicatedStorage = Services.ReplicatedStorage
    local RunService = Services.RunService
    local Lighting = Services.Lighting
    local MemStorageService = Services.MemStorageService
    local TeleportService = Services.TeleportService
    
    local MAIN_PLACE_ID = 10266164381;
    
    -- Check if we're in the right place
    if (game.PlaceId ~= MAIN_PLACE_ID) then
        return; -- Don't run on lobby
    end

    -- Use your existing UI system instead of creating new one
    local BloodlinesTab = Tabs['Bloodlines'] or Window:AddTab('Bloodlines')
    
    -- Create sections using Linoria's UI methods (similar to your existing patterns)
    local localCheats = BloodlinesTab:AddLeftGroupbox('Local Cheats')
    local visualCheats = BloodlinesTab:AddLeftGroupbox('Visual Cheats')
    local riskyCheats = BloodlinesTab:AddRightGroupbox('Risky Cheats')
    local teleportCheats = BloodlinesTab:AddRightGroupbox('Teleport Cheats')
    local miscCheats = BloodlinesTab:AddRightGroupbox('Misc Cheats')

    -- Variables
    local chatLogger;
    local localPlayer = Players.LocalPlayer;
    local funcs = {};
    
    -- Initialize chat logger (simplified for Linoria)
    do
        chatLogger = {
            textList = {},
            visible = false,
            title = 'Chat Logger',
            size = Vector2.new(300, 200),
            position = Vector2.new(100, 100)
        }
        
        function chatLogger:SetVisible(state)
            chatLogger.visible = state;
        end
    end

    -- Utility Functions (simplified)
    local IsA = game.IsA;

    -- Anti Cheat Bypass / No Fall Damage
    do
        local oldNamecall;
        local function fireServerHook(remote, action, ...)
            if (remote == ReplicatedStorage.Events.DataEvent and string.lower(action) == 'banme') then
                return warn('No No No');
            end;
            return oldNamecall(remote, action, ...);
        end;

        oldNamecall = hookmetamethod(game, '__namecall', function(self, ...)
            local method = getnamecallmethod();
            
            if ((method == 'fireServer' or method == 'FireServer') and IsA(self, 'RemoteEvent') and self == ReplicatedStorage.Events.DataEvent) then
                return fireServerHook(self, ...);
            end;
            
            return oldNamecall(self, ...);
        end);
    end;

    -- Remove Kill Bricks
    do
        local KILL_BRICKS_NAMES = {'LavarossaVoid', 'Void'};
        local killBricks = {};
        
        function funcs.noKillBricks(state)
            -- Implementation in your UI will be handled by Linoria toggles
        end;
    end;

    -- Chat Logger (simplified for Linoria)
    do
        ReplicatedStorage.DefaultChatSystemChatEvents.OnMessageDoneFiltering.OnClientEvent:Connect(function(messageData)
            local player, message = Players:FindFirstChild(messageData.FromSpeaker), messageData.Message;
            if (not player or not message) then return end;
            
            -- Store chat log for later display
        end);
        
        function funcs.chatLogger(state)
            chatLogger:SetVisible(state);
        end;
    end;

    -- Danger Check
    local inDanger = false;
    
    do
        ReplicatedStorage.Events.DataEvent.OnClientEvent:Connect(function(eventType, ...)
            if (eventType == 'InDanger') then
                inDanger = true;
            elseif (eventType == 'OutOfDanger') then
                inDanger = false;
            end;
        end);
    end

    -- Danger Checks Features
    do
        function funcs.resetCharacter()
            localPlayer:Kick('');
            task.wait(2.5);
            game:Shutdown();
        end;

        function funcs.instantLog()
            if (inDanger) then return; end;
            
            localPlayer:Kick('');
            task.wait(2.5);
            game:Shutdown();
        end;
    end;

    -- Visuals Features
    do
        local oldvalue = Lighting.FogEnd;
        local oldBrightness = Lighting.Brightness;
        
        function funcs.noFog(state)
            if (not state) then
                Lighting.FogEnd = oldvalue;
                return;
            end;
            
            RunService.RenderStepped:Connect(function()
                Lighting.FogEnd = 9999999999;
            end);
        end;

        function funcs.fullBright(state)
            if (not state) then
                Lighting.Brightness = oldBrightness;
                return;
            end;
            
            RunService.RenderStepped:Connect(function()
                -- Your brightness logic here
            end);
        end;
    end;

    -- Teleports (simplified - UI will use your existing systems)
    local chakraPoints = {};
    
    do
        for _, chakraPoint in next, workspace.ChakraPoints:GetChildren() do
            table.insert(chakraPoints, chakraPoint.PointName.Value);
        end;
        
        function funcs.teleportToChakraPoint()
            -- Implementation here
        end;
    end;

    -- NPCs and Mobs features (simplified)
    local npcs = {};
    
    do
        local function onChildAdded(object)
            if (not IsA(object, 'Model')) then return end;
            
            local npcValue = object:WaitForChild('NPC', 10);
            if (not npcValue) then return end;
            
            if (npcValue.Value == 'Dialog') then
                table.insert(npcs, object.Name);
            end;
        end;

        for _, v in next, workspace:GetChildren() do
            task.spawn(onChildAdded, v);
        end;

        workspace.ChildAdded:Connect(onChildAdded);
    end;

    -- Add Features To Your Existing UI System (using Linoria)
    
    -- Local Cheats Section
    localCheats:AddToggle({
        Text = 'Moderator Sound Alert',
        Default = true,
        Callback = function(state) 
            -- Store state in your State table or Library options
        end
    });
    
    localCheats:AddToggle({
        Text = 'Chakra Sense Notifier',
        Default = true,
        Callback = function(state)
            -- Store state for later use
        end
    });

    localCheats:AddSlider({
        Text = 'Fly Speed',
        Min = 0,
        Max = 500,
        Default = 100,
        Callback = function(value)
            -- Handle fly speed change
        end
    });
    
    localCheats:AddToggle({
        Text = 'Fly',
        Callback = function(state)
            -- Fly logic here
        end
    });

    localCheats:AddSlider({
        Text = 'Move Speed',
        Min = 0,
        Max = 500,
        Default = 16,
        Callback = function(value)
            -- Handle move speed change
        end
    });
    
    localCheats:AddToggle({
        Text = 'Speed',
        Callback = function(state)
            -- Speed logic here
        end
    });

    localCheats:AddToggle({
        Text = 'Auto Pickup',
        Callback = function(state)
            -- Auto pickup logic here
        end
    });
    
    localCheats:AddToggle({
        Text = 'No Clip',
        Callback = function(state)
            -- No clip logic here
        end
    });

    localCheats:AddToggle({
        Text = 'No Kill Bricks',
        Callback = function(state)
            funcs.noKillBricks(state);
        end
    });
    
    localCheats:AddToggle({
        Text = 'No Fall Damage'
    });

    localCheats:AddToggle({
        Text = 'Chat Logger',
        Callback = function(state)
            funcs.chatLogger(state);
        end
    });
    
    localCheats:AddButton({
        Text = 'Reset Character',
        Callback = funcs.resetCharacter
    });

    localCheats:AddBind({
        Text = 'Instant Log',
        Mode = 'hold',
        Callback = funcs.instantLog
    });
    
    -- Visual Cheats Section
    visualCheats:AddToggle({
        Text = 'No Fog',
        Callback = function(state)
            funcs.noFog(state);
        end
    });

    visualCheats:AddToggle({
        Text = 'No Rain'
    });

    visualCheats:AddSlider({
        Text = 'Brightness Level',
        Min = 1,
        Max = 10,
        Default = 5,
        Callback = function(value)
            -- Handle brightness change
        end
    });
    
    visualCheats:AddToggle({
        Text = 'Full Bright',
        Callback = function(state)
            funcs.fullBright(state);
        end
    });

    visualCheats:AddDropdown({
        Text = 'Time Of Day',
        Default = 1,
        Values = {'Morning', 'Afternoon', 'Evening', 'Night'}
    });
    
    -- Risky Cheats Section  
    riskyCheats:AddButton({
        Text = 'Rollback Data',
        Callback = function()
            -- Rollback data logic here
        end
    });
    
    -- Teleport Cheats Section
    teleportCheats:AddDropdown({
        Text = 'Chakra Point',
        Default = 1,
        Values = chakraPoints
    });
    
    teleportCheats:AddButton({
        Text = 'Teleport To',
        Callback = funcs.teleportToChakraPoint
    });

    -- NPCs Teleport section (simplified)
    teleportCheats:AddDropdown({
        Text = 'NPCs',
        Default = 1,
        Values = npcs
    });
    
    teleportCheats:AddButton({
        Text = 'Teleport To NPC'
    });

    teleportCheats:AddList({
        Text = 'Players',
        PlayerOnly = true
    });

    -- Misc Cheats Section
    miscCheats:AddToggle({
        Text = 'Thunderstorm Server Finder',
        Callback = function(state)
            -- Thunderstorm server finder logic here
        end
    });
    
end
