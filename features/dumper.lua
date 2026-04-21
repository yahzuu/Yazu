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
        return success
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
    -- SCRIPT SOURCE DUMP (FIXED - Single File Implementation)
    -- ================================================================
    local function dumpScriptSources()
        local scriptCount = 0
        local outputFileContent = ""
        
        -- Add header information
        outputFileContent = "-- Script Source Dump\n-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n"
        
        for _, player in ipairs(playersService:GetPlayers()) do
            local character = player.Character
            if character then
                -- Process all scripts from the character's descendants
                for _, descendant in ipairs(character:GetDescendants()) do
                    if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
                        scriptCount += 1
                        
                        local source = ""
                        local byteHash = "unknown"
                        
                        -- Try to extract source code (if available)
                        pcall(function()
                            if descendant:IsA("Script") and typeof(descendant.Source) == "string" then
                                source = descendant.Source
                            elseif descendant:IsA("LocalScript") and typeof(descendant.Source) == "string" then
                                source = descendant.Source
                            elseif descendant:IsA("ModuleScript") and typeof(descendant.Source) == "string" then
                                source = descendant.Source
                            end
                            
                            -- Get bytecode hash if available
                            local bytecode = descendant:FindFirstChild("Bytecode")
                            if bytecode then
                                byteHash = string.format("%x", table.sum(bytecode:GetBytecode()))
                            end
                        end)
                        
                        -- Add to output file
                        if source ~= "" and source ~= nil then
                            outputFileContent = outputFileContent .. 
                                "-- Script: " .. descendant:GetFullName() .. "\n" ..
                                source .. "\n\n"
                        else
                            -- If we can't get source, at least log it as a failed decompile
                            outputFileContent = outputFileContent .. 
                                "-- Script: " .. descendant:GetFullName() .. " (Decompile failed)\n" ..
                                "-- Bytecode Hash: " .. (byteHash or "unknown") .. "\n\n"
                        end
                        
                        -- Also process the main script if it's a ModuleScript
                        if descendant:IsA("ModuleScript") then
                            local moduleSource = ""
                            pcall(function()
                                if typeof(descendant.Source) == "string" then
                                    moduleSource = descendant.Source
                                end
                            end)
                            
                            outputFileContent = outputFileContent .. 
                                "-- Module: " .. descendant:GetFullName() .. "\n" ..
                                (moduleSource ~= "" and moduleSource or "-- No source available") .. "\n\n"
                        end
                    end
                end
                
                -- Process player's backpack scripts
                local backpack = character:FindFirstChild("Backpack")
                if backpack then
                    for _, descendant in ipairs(backpack:GetDescendants()) do
                        if descendant:IsA("Script") or descendant:IsA("LocalScript") then
                            scriptCount += 1
                            
                            local source = ""
                            pcall(function()
                                if typeof(descendant.Source) == "string" then
                                    source = descendant.Source
                                end
                            end)
                            
                            outputFileContent = outputFileContent .. 
                                "-- Backpack Script: " .. descendant:GetFullName() .. "\n" ..
                                (source ~= "" and source or "-- No source available") .. "\n\n"
                        end
                    end
                end
                
                -- Process player's PlayerGui scripts
                local playerGui = player:FindFirstChild("PlayerGui")
                if playerGui then
                    for _, descendant in ipairs(playerGui:GetDescendants()) do
                        if descendant:IsA("Script") or descendant:IsA("LocalScript") then
                            scriptCount += 1
                            
                            local source = ""
                            pcall(function()
                                if typeof(descendant.Source) == "string" then
                                    source = descendant.Source
                                end
                            end)
                            
                            outputFileContent = outputFileContent .. 
                                "-- PlayerGui Script: " .. descendant:GetFullName() .. "\n" ..
                                (source ~= "" and source or "-- No source available") .. "\n\n"
                        end
                    end
                end
            end
            
            -- Process player's character scripts
            for _, child in ipairs(player:GetDescendants()) do
                if child:IsA("Script") or child:IsA("LocalScript") then
                    scriptCount += 1
                    
                    local source = ""
                    pcall(function()
                        if typeof(child.Source) == "string" then
                            source = child.Source
                        end
                    end)
                    
                    outputFileContent = outputFileContent .. 
                        "-- Player Script: " .. child:GetFullName() .. "\n" ..
                        (source ~= "" and source or "-- No source available") .. "\n\n"
                end
            end
        end
        
        -- Process server scripts from various locations
        for _, descendant in ipairs(game:GetDescendants()) do
            if descendant:IsA("Script") then
                scriptCount += 1
                
                local source = ""
                pcall(function()
                    if typeof(descendant.Source) == "string" then
                        source = descendant.Source
                    end
                end)
                
                outputFileContent = outputFileContent .. 
                    "-- Server Script: " .. descendant:GetFullName() .. "\n" ..
                    (source ~= "" and source or "-- No source available") .. "\n\n"
            end
        end
        
        -- Write the single file with all script sources
        writefile(
            string.format("%s/Script_Source_Dump.lua", outputFolder),
            outputFileContent
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
    -- NETWORK METADATA DUMP (Enhanced version)
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
    -- ENVIRONMENT GLOBALS DUMP (Enhanced version)
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
            -- FIX 6: read-then-write instead of unsupported 3-arg writefile append
            local current = ""
            pcall(function() current = readfile(outputFile) end)
            writefile(
                outputFile,
                current .. 
                string.format("%s: %s (%s)\n", 
                    item.Key, 
                    item.Value, 
                    item.Type
                )
            )
        end
    end

    -- ================================================================
    -- REMOTE SPY FUNCTIONALITY (Integrated)
    -- ================================================================
    local remoteSpyActive = false
    local remotesLog = {}
    
    local function startRemoteSpy()
        if remoteSpyActive then return end
        
        remoteSpyActive = true
        Library:Notify("Remote Spy Enabled")
        
        -- Add a simple logging mechanism for remote events/functions
        table.insert(remotesLog, {
            time = os.time(),
            message = "Remote spy started",
            type = "status"
        })
        
        -- Example of how you could log remotes in a single file
        local function logRemoteCall(remoteName, callType, args)
            if #remotesLog > 100 then table.remove(remotesLog, 1) end
            
            table.insert(remotesLog, {
                time = os.time(),
                message = string.format("Remote %s called: %s", remoteName, callType),
                type = "remote_call",
                args = args or {}
            })
            
            -- Write to file if needed
            local logFileContent = ""
            for _, entry in ipairs(remotesLog) do
                logFileContent = logFileContent .. 
                    string.format("[%s] %s\n", os.date("%H:%M:%S", entry.time), entry.message)
            end
            
            writefile(outputFolder .. "/Remote_Log.txt", logFileContent)
        end
        
        -- For demonstration, add a dummy remote handler
        local testRemote = Instance.new("RemoteEvent")
        testRemote.Name = "TestRemote"
        testRemote.Parent = game.Workspace
        
        testRemote.OnServerEvent:Connect(function(player, ...)
            logRemoteCall("TestRemote", "OnServerEvent", {...})
        end)

        testRemote.OnClientEvent:Connect(function(...)
            logRemoteCall("TestRemote", "OnClientEvent", {...})
        end)
    end
    
    local function stopRemoteSpy()
        remoteSpyActive = false
        Library:Notify("Remote Spy Disabled")
        
        table.insert(remotesLog, {
            time = os.time(),
            message = "Remote spy stopped",
            type = "status"
        })
    end

    -- ================================================================
    -- UI SETUP (Integration with your existing tab system)
    -- ================================================================
    
    -- FIX 1 & 2: Tabs is a plain table, use groupboxes on Tabs.Dumper
    local leftBox  = Tabs.Dumper:AddLeftGroupbox("Dumper")
    local rightBox = Tabs.Dumper:AddRightGroupbox("Advanced Dumper")

    -- FIX 3: Removed leftBox:AddDivider() — does not exist in Linoria
    
    -- Initial full dump button
    leftBox:AddButton({
        Text = "Run Initial Full Dump",
        Func = function()
            safeCall(function() 
                dumpScriptSources()
                dumpInstanceTree()
                dumpNetworkMetadata()
                dumpEnvironmentGlobals()
                Library:Notify("Initial full dump complete → " .. outputFolder)
            end)
        end,
    })

    leftBox:AddButton({
        Text = "Open Log Folder Path",
        Func = function()
            Library:Notify("Logs saved to: " .. outputFolder)
        end,
    })
    
    -- FIX 4: Removed rightBox:AddDivider() — does not exist in Linoria

    rightBox:AddButton({
        Text = "Dump Script Sources",
        Func = function()
            local count = safeCall(function() 
                return dumpScriptSources() 
            end)
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
    
    -- Remote Spy functionality
    -- FIX 5: Removed rightBox:AddDivider() — does not exist in Linoria
    rightBox:AddLabel("RemoteSpy Integration:")
    
    rightBox:AddButton({
        Text = "Enable Remote Logging",
        Func = function()
            startRemoteSpy()
        end,
    })

    rightBox:AddButton({
        Text = "Disable Remote Logging",
        Func = function()
            stopRemoteSpy()
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
        dumpEnvironmentGlobals = dumpEnvironmentGlobals,
        startRemoteSpy = startRemoteSpy,
        stopRemoteSpy = stopRemoteSpy
    }
end
