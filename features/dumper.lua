-- ================================================================
--  features/dumper.lua
--  Script Dump | Instance Tree | Network Meta | Env Globals | Remote Spy
--  Compatible with LinoriaLib
-- ================================================================

return function(State, Tabs, Services, Library)

-- ================================================================
--  SERVICES
-- ================================================================

local RunService     = game:GetService("RunService")
local PlayersService = game:GetService("Players")
local HttpService    = game:GetService("HttpService")
local LocalPlayer    = PlayersService.LocalPlayer

-- ================================================================
--  FILESYSTEM
--  Nothing filesystem-related runs at load time.
--  The folder is created lazily on the first button press.
--  This was the original crash — makefolder() was called at load
--  time with no pcall, killing the whole feature before any UI built.
-- ================================================================

local FOLDER_ROOT    = "YazuDumper"
local FOLDER_SESSION = FOLDER_ROOT .. "/" .. tostring(os.time())
local filesystemReady = false

local function initFilesystem()
    if filesystemReady then
        return true
    end
    if type(makefolder) ~= "function" then
        Library:Notify("makefolder() not supported on this executor")
        return false
    end
    local ok, err = pcall(function()
        makefolder(FOLDER_ROOT)
        makefolder(FOLDER_SESSION)
    end)
    if not ok then
        Library:Notify("Folder creation failed: " .. tostring(err))
        return false
    end
    filesystemReady = true
    return true
end

local function safeWrite(filename, content)
    if not initFilesystem() then
        return false
    end
    if type(writefile) ~= "function" then
        Library:Notify("writefile() not supported on this executor")
        return false
    end
    local path = FOLDER_SESSION .. "/" .. filename
    local ok, err = pcall(writefile, path, content)
    if not ok then
        Library:Notify("Write error: " .. tostring(err))
        return false
    end
    return true
end

local function safeRead(filename)
    if not filesystemReady then
        return ""
    end
    if type(readfile) ~= "function" then
        return ""
    end
    local path = FOLDER_SESSION .. "/" .. filename
    local ok, data = pcall(readfile, path)
    if ok and type(data) == "string" then
        return data
    end
    return ""
end

-- ================================================================
--  GENERAL ERROR WRAPPER
-- ================================================================

local function guarded(fn)
    local ok, err = pcall(fn)
    if not ok then
        Library:Notify("Error: " .. tostring(err))
    end
    return ok
end

-- ================================================================
--  INSTANCE PATH BUILDER
-- ================================================================

local function buildInstancePath(inst)
    if not inst then
        return "nil"
    end
    if inst == game then
        return "game"
    end

    local parts = {}
    local current = inst
    while current and current ~= game do
        table.insert(parts, 1, current.Name)
        current = current.Parent
    end

    if #parts == 0 then
        return "game"
    end

    local firstIsService = false
    pcall(function()
        game:GetService(parts[1])
        firstIsService = true
    end)

    local result
    if firstIsService then
        result = 'game:GetService("' .. parts[1] .. '")'
    else
        result = 'game["' .. parts[1] .. '"]'
    end

    for i = 2, #parts do
        local segment = parts[i]
        if segment:match("[^%w_]") or segment:match("^%d") then
            result = result .. '["' .. segment .. '"]'
        else
            result = result .. "." .. segment
        end
    end

    return result
end

-- ================================================================
--  SOURCE EXTRACTION
-- ================================================================

local function extractSource(inst)
    if inst:IsA("Script") then
        return "-- [ServerScript] not readable from the client"
    end

    local ok, result = pcall(function()
        if type(decompile) == "function" then
            local d = decompile(inst)
            if type(d) == "string" and #d > 0 then
                return d
            end
        end
        local s = inst.Source
        if type(s) == "string" and #s > 0 then
            return s
        end
        return nil
    end)

    if ok and result then
        return result
    end
    if ok then
        return "-- source was empty"
    end
    return "-- decompile failed: " .. tostring(result)
end

-- ================================================================
--  SCRIPT DUMP ENGINE
-- ================================================================

local function runScriptDump(containers, outputFilename)
    local scriptCount = 0

    local chunks = {
        "-- ===========================================================",
        "-- Yazu Universal Script Dump",
        "-- Generated : " .. os.date("%Y-%m-%d %H:%M:%S"),
        "-- PlaceId   : " .. tostring(game.PlaceId),
        "-- GameId    : " .. tostring(game.GameId),
        "-- ===========================================================",
        "",
    }

    for i = 1, #containers do
        local label     = containers[i][1]
        local container = containers[i][2]

        if container then
            table.insert(chunks, string.rep("=", 60))
            table.insert(chunks, "-- CONTAINER: " .. label)
            table.insert(chunks, string.rep("=", 60))
            table.insert(chunks, "")

            local ok, descendants = pcall(function()
                return container:GetDescendants()
            end)

            if ok and descendants then
                for _, inst in ipairs(descendants) do
                    local isScript = inst:IsA("LocalScript")
                        or inst:IsA("ModuleScript")
                        or inst:IsA("Script")

                    if isScript then
                        scriptCount = scriptCount + 1

                        local header = string.format(
                            "-- [%s]  %s  (%s)",
                            label,
                            inst:GetFullName(),
                            inst.ClassName
                        )

                        local source = extractSource(inst)

                        table.insert(chunks, header)
                        table.insert(chunks, source)
                        table.insert(chunks, "")
                        table.insert(chunks, string.rep("-", 60))
                        table.insert(chunks, "")

                        RunService.RenderStepped:Wait()
                    end
                end
            end
        end
    end

    safeWrite(outputFilename, table.concat(chunks, "\n"))
    return scriptCount
end

-- ================================================================
--  FULL DUMP  (all services + LocalPlayer containers)
-- ================================================================

local function dumpAllScripts()
    local lp = LocalPlayer

    local containers = {
        { "Workspace",         workspace                             },
        { "ReplicatedStorage", game:GetService("ReplicatedStorage") },
        { "ReplicatedFirst",   game:GetService("ReplicatedFirst")   },
        { "StarterGui",        game:GetService("StarterGui")        },
        { "StarterPack",       game:GetService("StarterPack")       },
        { "Players",           PlayersService                        },
    }

    pcall(function()
        if lp.Backpack then
            table.insert(containers, { "LP/Backpack", lp.Backpack })
        end
    end)
    pcall(function()
        if lp.PlayerGui then
            table.insert(containers, { "LP/PlayerGui", lp.PlayerGui })
        end
    end)
    pcall(function()
        if lp.Character then
            table.insert(containers, { "LP/Character", lp.Character })
        end
    end)

    return runScriptDump(containers, "ALL_Scripts.lua")
end

-- ================================================================
--  SINGLE SERVICE DUMP
-- ================================================================

local function dumpSingleService(serviceName)
    local serviceInstance
    local ok, err = pcall(function()
        if serviceName == "Workspace" then
            serviceInstance = workspace
        else
            serviceInstance = game:GetService(serviceName)
        end
    end)

    if not ok or not serviceInstance then
        Library:Notify("Could not get service " .. serviceName .. ": " .. tostring(err))
        return 0
    end

    local containers = {
        { serviceName, serviceInstance },
    }

    return runScriptDump(containers, "Service_" .. serviceName .. ".lua")
end

-- ================================================================
--  LOCALPLAYER CONTAINER DUMP
-- ================================================================

local function dumpLocalPlayerContainer(label, containerGetter)
    local container
    local ok, err = pcall(function()
        container = containerGetter()
    end)

    if not ok or not container then
        Library:Notify("Could not get LP/" .. label .. ": " .. tostring(err))
        return 0
    end

    local containers = {
        { "LP/" .. label, container },
    }

    return runScriptDump(containers, "LP_" .. label .. ".lua")
end

-- ================================================================
--  INSTANCE TREE DUMP
-- ================================================================

local function buildTreeNode(inst, depth)
    local node = {
        Name      = inst.Name,
        ClassName = inst.ClassName,
        Children  = {},
    }

    if inst:IsA("BasePart") then
        table.insert(node.Children, {
            Name  = "_Position",
            Value = tostring(inst.Position),
        })
    end

    if depth < 8 then
        local ok, children = pcall(function()
            return inst:GetChildren()
        end)
        if ok and children then
            for _, child in ipairs(children) do
                table.insert(node.Children, buildTreeNode(child, depth + 1))
            end
        end
    end

    return node
end

local function dumpInstanceTree()
    local tree = buildTreeNode(game, 0)
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(tree)
    end)
    if not ok then
        Library:Notify("JSON encode failed: " .. tostring(encoded))
        return
    end
    safeWrite("Instance_Tree.json", encoded)
end

-- ================================================================
--  NETWORK METADATA DUMP
-- ================================================================

local function dumpNetworkMetadata()
    local players     = PlayersService:GetPlayers()
    local playerNames = {}

    for _, player in ipairs(players) do
        table.insert(playerNames, player.Name)
    end

    local lines = {
        "=== Yazu Network Metadata Snapshot ===",
        "Timestamp    : " .. os.date("%Y-%m-%d %H:%M:%S"),
        "GameId       : " .. tostring(game.GameId),
        "PlaceId      : " .. tostring(game.PlaceId),
        "JobId        : " .. tostring(game.JobId),
        "PlaceVersion : " .. tostring(game.PlaceVersion),
        "PlayerCount  : " .. tostring(#players),
        "PlayerNames  : " .. table.concat(playerNames, ", "),
        "",
    }

    local newContent = table.concat(lines, "\n")
    local existing   = safeRead("Network_Meta.txt")
    safeWrite("Network_Meta.txt", existing .. newContent)
end

-- ================================================================
--  ENVIRONMENT GLOBALS DUMP
-- ================================================================

local function dumpEnvGlobals()
    if type(getgenv) ~= "function" then
        Library:Notify("getgenv() not available on this executor")
        return
    end

    local env = getgenv()
    if type(env) ~= "table" then
        Library:Notify("getgenv() did not return a table")
        return
    end

    local lines = {
        "=== Yazu Environment Globals ===",
        "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "",
    }

    local keys = {}
    for k in pairs(env) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    for _, k in ipairs(keys) do
        local v    = env[k]
        local line = string.format(
            "%-40s = %-35s [%s]",
            tostring(k),
            tostring(v),
            type(v)
        )
        table.insert(lines, line)
    end

    safeWrite("Env_Globals.txt", table.concat(lines, "\n"))
end

-- ================================================================
--  REMOTE SPY
--  Hooks __namecall on the game metatable.
--
--  KEY FIX: varargs `...` cannot be accessed inside a nested
--  closure in Lua 5.1 (which Roblox uses). The args MUST be
--  captured into a local table BEFORE any inner function.
-- ================================================================

local spyIsActive      = false
local spyLogBuffer     = {}
local spyTotalFired    = 0
local spyHookInstalled = false
local spyOriginalCall  = nil

local function buildRemoteScript(remoteObject, methodName, callArgs)
    local lines = {
        "-- ==============================",
        "-- [RemoteSpy] Captured Call",
        "-- Time   : " .. os.date("%H:%M:%S"),
        "-- Remote : " .. tostring(remoteObject.ClassName) .. " @ " .. buildInstancePath(remoteObject),
        "-- Method : " .. tostring(methodName),
        "-- ==============================",
        "",
    }

    for i = 1, #callArgs do
        local arg     = callArgs[i]
        local argType = type(arg)
        local argRepr

        if argType == "userdata" then
            local typeOk, typeName = pcall(typeof, arg)
            if not typeOk then
                typeName = "userdata"
            end

            if typeName == "Instance" then
                argRepr = buildInstancePath(arg)
            elseif typeName == "Vector3" then
                argRepr = string.format(
                    "Vector3.new(%g, %g, %g)",
                    arg.X, arg.Y, arg.Z
                )
            elseif typeName == "CFrame" then
                local cx, cy, cz = arg.X, arg.Y, arg.Z
                local rx, ry, rz = arg:ToEulerAnglesXYZ()
                argRepr = string.format(
                    "CFrame.new(%g, %g, %g) * CFrame.fromEulerAnglesXYZ(%g, %g, %g)",
                    cx, cy, cz, rx, ry, rz
                )
            elseif typeName == "Color3" then
                argRepr = string.format(
                    "Color3.new(%g, %g, %g)",
                    arg.R, arg.G, arg.B
                )
            elseif typeName == "EnumItem" then
                argRepr = "Enum." .. tostring(arg.EnumType) .. "." .. tostring(arg.Name)
            elseif typeName == "BrickColor" then
                argRepr = 'BrickColor.new("' .. tostring(arg.Name) .. '")'
            elseif typeName == "UDim2" then
                argRepr = string.format(
                    "UDim2.new(%g, %g, %g, %g)",
                    arg.X.Scale, arg.X.Offset,
                    arg.Y.Scale, arg.Y.Offset
                )
            elseif typeName == "UDim" then
                argRepr = string.format("UDim.new(%g, %g)", arg.Scale, arg.Offset)
            elseif typeName == "Vector2" then
                argRepr = string.format("Vector2.new(%g, %g)", arg.X, arg.Y)
            elseif typeName == "Rect" then
                argRepr = string.format(
                    "Rect.new(%g, %g, %g, %g)",
                    arg.Min.X, arg.Min.Y, arg.Max.X, arg.Max.Y
                )
            else
                argRepr = "--[[ " .. typeName .. " ]] " .. tostring(arg)
            end

        elseif argType == "string" then
            argRepr = string.format("%q", arg)

        elseif argType == "number" then
            argRepr = tostring(arg)

        elseif argType == "boolean" then
            argRepr = tostring(arg)

        elseif argType == "table" then
            argRepr = "{--[[ table: inspect manually ]]}"

        elseif argType == "function" then
            argRepr = "--[[ function ]]"

        else
            argRepr = "--[[ " .. argType .. ": " .. tostring(arg) .. " ]]"
        end

        table.insert(lines, string.format("local Arg%d = %s", i, argRepr))
    end

    local argList = {}
    for i = 1, #callArgs do
        table.insert(argList, "Arg" .. i)
    end

    table.insert(lines, "")
    table.insert(lines, "local Remote = " .. buildInstancePath(remoteObject))
    table.insert(lines, "Remote:" .. methodName .. "(" .. table.concat(argList, ", ") .. ")")
    table.insert(lines, "")

    return table.concat(lines, "\n")
end

local function flushSpyLog()
    if #spyLogBuffer == 0 then
        return
    end

    local header = {
        "-- ===========================================================",
        "-- Yazu Remote Spy Log",
        "-- Flushed  : " .. os.date("%Y-%m-%d %H:%M:%S"),
        "-- Total    : " .. tostring(spyTotalFired) .. " calls this session",
        "-- ===========================================================",
        "",
    }

    local allLines = {}
    for _, v in ipairs(header) do
        table.insert(allLines, v)
    end
    for _, entry in ipairs(spyLogBuffer) do
        table.insert(allLines, entry)
        table.insert(allLines, string.rep("-", 40))
        table.insert(allLines, "")
    end

    safeWrite("Remote_Log.lua", table.concat(allLines, "\n"))
end

local function installSpyHook()
    if spyHookInstalled then
        return true
    end

    if type(getrawmetatable) ~= "function" then
        Library:Notify("RemoteSpy: getrawmetatable() not available on this executor")
        return false
    end

    if type(getnamecallmethod) ~= "function" then
        Library:Notify("RemoteSpy: getnamecallmethod() not available on this executor")
        return false
    end

    local gameMeta
    local metaOk, metaErr = pcall(function()
        gameMeta = getrawmetatable(game)
    end)

    if not metaOk or not gameMeta then
        Library:Notify("RemoteSpy: getrawmetatable(game) failed: " .. tostring(metaErr))
        return false
    end

    if type(setreadonly) == "function" then
        pcall(setreadonly, gameMeta, false)
    elseif type(make_writeable) == "function" then
        pcall(make_writeable, gameMeta)
    end

    spyOriginalCall = rawget(gameMeta, "__namecall")

    if not spyOriginalCall then
        Library:Notify("RemoteSpy: __namecall is nil — cannot hook")
        return false
    end

    local wrapFunction
    if type(newcclosure) == "function" then
        wrapFunction = newcclosure
    else
        wrapFunction = function(f) return f end
    end

    -- IMPORTANT: `...` is captured into `callArgs` immediately inside the
    -- outer vararg function, BEFORE any nested closure.
    -- In Lua 5.1 you cannot reference `...` from inside a nested function.
    rawset(gameMeta, "__namecall", wrapFunction(function(self, ...)
        local method    = getnamecallmethod()
        local callArgs  = { ... }  -- capture varargs HERE, at the top level of this function

        if spyIsActive and method then
            local methodLower = string.lower(method)
            local isRemoteMethod = (methodLower == "fireserver")
                or (methodLower == "invokeserver")

            if isRemoteMethod then
                local isRemote = false
                pcall(function()
                    isRemote = self:IsA("RemoteEvent") or self:IsA("RemoteFunction")
                end)

                if isRemote then
                    -- callArgs is already a plain table here, safe to use in nested pcall
                    pcall(function()
                        spyTotalFired = spyTotalFired + 1

                        local script = buildRemoteScript(self, method, callArgs)
                        table.insert(spyLogBuffer, script)

                        if #spyLogBuffer > 300 then
                            table.remove(spyLogBuffer, 1)
                        end

                        if spyTotalFired % 25 == 0 then
                            flushSpyLog()
                        end

                        Library:Notify(
                            string.format(
                                "[Spy] #%d  %s : %s",
                                spyTotalFired, self.Name, method
                            ),
                            3
                        )
                    end)
                end
            end
        end

        return spyOriginalCall(self, table.unpack(callArgs))
    end))

    spyHookInstalled = true
    return true
end

local function enableRemoteSpy()
    if spyIsActive then
        Library:Notify("Remote Spy is already running")
        return
    end
    local hookOk = installSpyHook()
    if hookOk then
        spyIsActive = true
        Library:Notify("Remote Spy: ENABLED")
    end
end

local function disableRemoteSpy()
    if not spyIsActive then
        Library:Notify("Remote Spy is not running")
        return
    end
    spyIsActive = false
    flushSpyLog()
    Library:Notify(
        string.format(
            "Remote Spy: DISABLED — %d calls logged",
            spyTotalFired
        )
    )
end

local function clearRemoteLog()
    spyLogBuffer  = {}
    spyTotalFired = 0
    Library:Notify("Remote log buffer cleared")
end

-- ================================================================
--  UI — LEFT GROUPBOX 1: Main Dump Actions
-- ================================================================

local DumperGroupbox = Tabs.Dumper:AddLeftGroupbox('Dumper')

DumperGroupbox:AddButton({
    Text = 'Full Dump (All Services)',
    Func = function()
        guarded(function()
            local count = dumpAllScripts()
            dumpInstanceTree()
            dumpNetworkMetadata()
            dumpEnvGlobals()
            Library:Notify(
                string.format('Full dump done — %d scripts saved', count)
            )
        end)
    end,
})

DumperGroupbox:AddButton({
    Text = 'Dump All Scripts Only',
    Func = function()
        guarded(function()
            local count = dumpAllScripts()
            Library:Notify(
                string.format('Script dump done — %d scripts saved', count)
            )
        end)
    end,
})

DumperGroupbox:AddButton({
    Text = 'Dump Instance Tree',
    Func = function()
        guarded(function()
            dumpInstanceTree()
            Library:Notify('Instance tree saved to Instance_Tree.json')
        end)
    end,
})

DumperGroupbox:AddButton({
    Text = 'Dump Network Metadata',
    Func = function()
        guarded(function()
            dumpNetworkMetadata()
            Library:Notify('Network metadata saved to Network_Meta.txt')
        end)
    end,
})

DumperGroupbox:AddButton({
    Text = 'Dump Env Globals',
    Func = function()
        guarded(function()
            dumpEnvGlobals()
            Library:Notify('Env globals saved to Env_Globals.txt')
        end)
    end,
})

DumperGroupbox:AddButton({
    Text = 'Show Output Folder',
    Func = function()
        Library:Notify('Output: ' .. FOLDER_SESSION)
    end,
})

-- ================================================================
--  UI — LEFT GROUPBOX 2: Per-Service Script Dumps
-- ================================================================

local ServiceGroupbox = Tabs.Dumper:AddLeftGroupbox('Dump by Service')

ServiceGroupbox:AddButton({
    Text = 'Workspace',
    Func = function()
        guarded(function()
            local count = dumpSingleService('Workspace')
            Library:Notify('Workspace — ' .. count .. ' scripts saved')
        end)
    end,
})

ServiceGroupbox:AddButton({
    Text = 'ReplicatedStorage',
    Func = function()
        guarded(function()
            local count = dumpSingleService('ReplicatedStorage')
            Library:Notify('ReplicatedStorage — ' .. count .. ' scripts saved')
        end)
    end,
})

ServiceGroupbox:AddButton({
    Text = 'ReplicatedFirst',
    Func = function()
        guarded(function()
            local count = dumpSingleService('ReplicatedFirst')
            Library:Notify('ReplicatedFirst — ' .. count .. ' scripts saved')
        end)
    end,
})

ServiceGroupbox:AddButton({
    Text = 'StarterGui',
    Func = function()
        guarded(function()
            local count = dumpSingleService('StarterGui')
            Library:Notify('StarterGui — ' .. count .. ' scripts saved')
        end)
    end,
})

ServiceGroupbox:AddButton({
    Text = 'StarterPack',
    Func = function()
        guarded(function()
            local count = dumpSingleService('StarterPack')
            Library:Notify('StarterPack — ' .. count .. ' scripts saved')
        end)
    end,
})

ServiceGroupbox:AddButton({
    Text = 'Players',
    Func = function()
        guarded(function()
            local count = dumpSingleService('Players')
            Library:Notify('Players — ' .. count .. ' scripts saved')
        end)
    end,
})

-- ================================================================
--  UI — LEFT GROUPBOX 3: LocalPlayer Container Dumps
-- ================================================================

local LocalPlayerGroupbox = Tabs.Dumper:AddLeftGroupbox('LocalPlayer Dumps')

LocalPlayerGroupbox:AddButton({
    Text = 'LP / Backpack',
    Func = function()
        guarded(function()
            local count = dumpLocalPlayerContainer('Backpack', function()
                return LocalPlayer.Backpack
            end)
            Library:Notify('LP/Backpack — ' .. count .. ' scripts saved')
        end)
    end,
})

LocalPlayerGroupbox:AddButton({
    Text = 'LP / PlayerGui',
    Func = function()
        guarded(function()
            local count = dumpLocalPlayerContainer('PlayerGui', function()
                return LocalPlayer.PlayerGui
            end)
            Library:Notify('LP/PlayerGui — ' .. count .. ' scripts saved')
        end)
    end,
})

LocalPlayerGroupbox:AddButton({
    Text = 'LP / Character',
    Func = function()
        guarded(function()
            local count = dumpLocalPlayerContainer('Character', function()
                return LocalPlayer.Character
            end)
            Library:Notify('LP/Character — ' .. count .. ' scripts saved')
        end)
    end,
})

-- ================================================================
--  UI — RIGHT GROUPBOX: Remote Spy
-- ================================================================

local SpyGroupbox = Tabs.Dumper:AddRightGroupbox('Remote Spy')

SpyGroupbox:AddLabel('Hooks FireServer / InvokeServer')
SpyGroupbox:AddLabel('via __namecall metatable hook.')

SpyGroupbox:AddButton({
    Text = 'Enable Remote Spy',
    Func = function()
        enableRemoteSpy()
    end,
})

SpyGroupbox:AddButton({
    Text = 'Disable + Save Log',
    Func = function()
        disableRemoteSpy()
    end,
})

SpyGroupbox:AddButton({
    Text = 'Flush Log Now',
    Func = function()
        guarded(function()
            flushSpyLog()
            Library:Notify(
                string.format('Flushed %d entries to Remote_Log.lua', #spyLogBuffer)
            )
        end)
    end,
})

SpyGroupbox:AddButton({
    Text = 'Clear Log Buffer',
    Func = function()
        clearRemoteLog()
    end,
})

SpyGroupbox:AddButton({
    Text = 'Show Call Count',
    Func = function()
        Library:Notify(
            string.format(
                'Total fired: %d   Buffered: %d',
                spyTotalFired, #spyLogBuffer
            )
        )
    end,
})

end -- return function
