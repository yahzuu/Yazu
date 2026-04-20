-- features/dumper.lua
-- Universal Environment Dumper v2.0 — Linoria UI Integration
-- Preserves ALL original logic. Wraps into Yazu's module pattern.
-- Usage: load('features/dumper.lua')(State, Tabs, Services, Library)

return function(State, Tabs, Services, Library)
    -- ================================================================
    -- SERVICES
    -- ================================================================
    local runService     = game:GetService("RunService")
    local playersService = game:GetService("Players")
    local httpService    = game:GetService("HttpService")
    
    -- ================================================================
    -- FOLDER SETUP
    -- ================================================================
    local logFolder    = "UniversalDumperLogs"
    local timestamp    = os.time()
    local outputFolder = string.format("%s/%d", logFolder, timestamp)
    makefolder(logFolder)
    makefolder(outputFolder)

    -- ================================================================
    -- UTILITY FUNCTIONS
    -- ================================================================
    local function safeCall(func)
        local success, err = pcall(func)
        if not success then
            Library:Notify("Error in dump: " .. tostring(err))
        end
    end

    local function crawlInstance(instance, depth)
        local result = {
            Name = instance.Name,
            ClassName = instance.ClassName,
            Children = {}
        }
        
        -- Add properties that are relevant for debugging
        if instance:IsA("BasePart") then
            table.insert(result.Children, {Name = "Position", Value = tostring(instance.Position)})
            table.insert(result.Children, {Name = "Rotation", Value = tostring(instance.Rotation)})
        end
        
        local children = instance:GetChildren()
        for _, child in ipairs(children) do
            table.insert(result.Children, crawlInstance(child, depth + 1))
        end
        
        return result
    end

    -- ================================================================
    -- SCRIPT SOURCE DUMP (Enhanced version)
    -- ================================================================
    local function dumpScriptSources()
        local scriptCount = 0
        local existing = ""
        
        pcall(function()
            existing = readfile(string.format("%s/Script_Source_Dump.lua", outputFolder))
        end)
        
        for _, player in ipairs(playersService:GetPlayers()) do
            -- This is a simplified approach - you may want to modify this 
            -- based on your specific requirements or executor capabilities
            local character = player.Character
            if character then
                local humanoid = character:FindFirstChild("Humanoid")
                if humanoid then
                    for _, child in ipairs(character:GetDescendants()) do
                        if child:IsA("Script") or child:IsA("LocalScript") then
                            scriptCount += 1
                            
                            -- Try to get source code (if available)
                            local source = ""
                            local byteHash = "unknown"
                            
                            -- Attempt to extract script content (simplified approach)
                            pcall(function()
                                if child:IsA("Script") then
                                    -- For server scripts, try to get their source
                                    if typeof(child.Source) == "string" then
                                        source = child.Source
                                    end
                                elseif child:IsA("LocalScript") then
                                    -- For local scripts, attempt to get source
                                    if typeof(child.Source) == "string" then
                                        source = child.Source
                                    end
                                end
                                
                                byteHash = tostring(child:FindFirstChild("Bytecode")) or "unknown"
                            end)
                            
                            if source ~= "" then
                                existing = existing .. string.format(
                                    "-- Script: %s\n-- Source:\n%s\n\n",
                                    child:GetFullName(),
                                    source
                                )
                            else
                                -- If we can't get source, at least log it as a failed decompile
                                existing = existing .. string.format(
                                    "-- Script: %s (Decompile failed)\n-- Bytecode Hash: %s\n\n",
                                    child:GetFullName(),
                                    byteHash or "unknown"
                                )
                            end
                        end
                    end
                end
            end
        end
        
        writefile(
            string.format("%s/Script_Source_Dump.lua", outputFolder),
            existing
        )
        
        return scriptCount
    end

    -- ================================================================
    -- INSTANCE TREE DUMP (original, untouched)
    -- ================================================================
    local function dumpInstanceTree()
        local root         = game
        local instanceData = crawlInstance(root, 0)

        local existing = ""
        pcall(function() existing = readfile(outputFolder .. "/Instance_Tree.json") end)
        
        writefile(
            outputFolder .. "/Instance_Tree.json",
            existing .. httpService:JSONEncode(instanceData) .. "\n"
        )
    end

    -- ================================================================
    -- NETWORK METADATA DUMP (Added functionality)
    -- ================================================================
    local function dumpNetworkMetadata()
        local metadata = {
            PlayersCount = #playersService:GetPlayers(),
            ServerTime = os.time(),
            GameId = game.GameId,
            PlaceId = game.PlaceId
        }
        
        -- Add some basic network metrics if available
        local performance = {}
        performance.networkStats = {
            scriptCount = 0,
            playerCount = #playersService:GetPlayers()
        }
        
        local existing = ""
        pcall(function() 
            existing = readfile(outputFolder .. "/Network_Metadata.txt") 
        end)
        
        writefile(
            outputFolder .. "/Network_Metadata.txt",
            existing ..
            "=== Network Metadata ===\n" ..
            string.format("Timestamp: %s\n", os.date("%Y-%m-%d %H:%M:%S")) ..
            string.format("Players: %d\n", performance.networkStats.playerCount) ..
            string.format("Game ID: %s\n", game.GameId) ..
            string.format("Place ID: %s\n", game.PlaceId) ..
            "\n"
        )
    end

    -- ================================================================
    -- ENVIRONMENT GLOBALS DUMP (Added functionality)
    -- ================================================================
    local function dumpEnvironmentGlobals()
        local globals = {}
        
        -- Collect global environment variables
        for k, v in pairs(getgenv()) do
            table.insert(globals, {
                Key = tostring(k),
                Value = tostring(v),
                Type = typeof(v)
            })
        end
        
        local existing = ""
        pcall(function() 
            existing = readfile(outputFolder .. "/Environment_Globals.txt") 
        end)
        
        writefile(
            outputFolder .. "/Environment_Globals.txt",
            existing ..
            "=== Environment Globals ===\n" ..
            string.format("Timestamp: %s\n", os.date("%Y-%m-%d %H:%M:%S")) ..
            "\n"
        )
        
        -- Append to the file with formatted globals
        local outputFile = outputFolder .. "/Environment_Globals.txt"
        for _, item in ipairs(globals) do
            writefile(
                outputFile,
                existing .. 
                string.format("%s: %s (%s)\n", 
                    item.Key, 
                    item.Value, 
                    item.Type
                ),
                true -- Append mode
            )
        end
    end

    -- ================================================================
    -- UI SETUP (Integration with your existing tab system)
    -- ================================================================
    
    local leftBox = Tabs:AddTab("Dumper")
    local rightBox = Tabs:AddTab("Advanced Dumper")

    leftBox:AddDivider()
    
    -- Initial full dump button (replicates original initializeDumper() one-shot dumps)
    leftBox:AddButton({
        Text = "Run Initial Full Dump",
        Func = function()
            safeCall(dumpScriptSources)
            safeCall(dumpInstanceTree)
            safeCall(dumpNetworkMetadata)
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Initial full dump complete → " .. outputFolder)
        end,
    })

    leftBox:AddButton({
        Text = "Open Log Folder Path",
        Func = function()
            Library:Notify("Logs saved to: " .. outputFolder)
        end,
    })
    
    -- Manual one-shot dump buttons (right side)
    rightBox:AddDivider()

    rightBox:AddButton({
        Text = "Dump Script Sources",
        Func = function()
            local count = safeCall(function() return dumpScriptSources() end)
            Library:Notify(string.format("Scripts dumped (%d) → Script_Source_Dump.lua", 
                count or 0))
        end,
    })

    rightBox:AddButton({
        Text = "Dump Instance Tree",
        Func = function()
            safeCall(dumpInstanceTree)
            Library:Notify("Instance tree → Instance_Tree.json")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Network Metadata",
        Func = function()
            safeCall(dumpNetworkMetadata)
            Library:Notify("Network metadata → Network_Metadata.txt")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Env Globals",
        Func = function()
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Env globals → Environment_Globals.txt")
        end,
    })
    
    -- Add a utility to open the log folder
    local function openLogFolder()
        local success, err = pcall(function()
            if not isfolder(outputFolder) then
                makefolder(logFolder)
                makefolder(outputFolder)
            end
            
            Library:Notify("Opening folder: " .. outputFolder)
        end)
        
        if not success then
            Library:Notify("Error opening log folder: " .. tostring(err))
        end
    end
    
    leftBox:AddButton({
        Text = "Open Log Folder",
        Func = function()
            openLogFolder()
        end,
    })
    
    -- Return the functions so they can be used elsewhere if needed
    return {
        dumpScriptSources = dumpScriptSources,
        dumpInstanceTree = dumpInstanceTree,
        dumpNetworkMetadata = dumpNetworkMetadata,
        dumpEnvironmentGlobals = dumpEnvironmentGlobals
    }
end
