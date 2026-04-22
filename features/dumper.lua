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
--  Backend ported directly from Remote2Script v2 by Luckyxero.
--
--  Architecture mirrors R2Sv2 exactly:
--    1. Hook captures args at TOP LEVEL of vararg function (Lua 5.1 rule)
--    2. args[#args] = nil  strips the trailing nil Roblox appends to varargs
--    3. method:match("Server")  broad match catches FireServer/InvokeServer
--    4. Entries queued into namecallDump table, NOT processed inline
--    5. RunService.Stepped drains the queue every frame (same as R2Sv2)
--    6. getfenv(2).script  retrieves the caller script instance
--    7. RemoteFunction return values captured via InvokeServer pcall
--    8. GetPath / GetType / Table_TS  ported verbatim for correct serialisation
--    9. Original namecall called with ORIGINAL ... not the stripped args
-- ================================================================

-- HasSpecial: true if string contains any control char, whitespace, or punctuation.
-- Used by GetPath to decide whether a path segment needs bracket notation.
local HasSpecial = function(str)
    return (str:match("%c") or str:match("%s") or str:match("%p")) ~= nil
end

-- GetPath: builds a valid Lua path expression pointing to any Instance.
-- Ported verbatim from R2Sv2's GetPath function.
local GetPath = function(Inst)
    local Obj   = Inst
    local parts = {}
    local temp  = {}
    local hasError = false

    while Obj ~= game do
        if Obj == nil then
            hasError = true
            break
        end
        -- Use ClassName when the parent is game (service root), else use Name
        table.insert(temp, Obj.Parent == game and Obj.ClassName or tostring(Obj))
        Obj = Obj.Parent
    end

    -- First segment is always game:GetService("ClassName")
    table.insert(parts, 'game:GetService("' .. temp[#temp] .. '")')

    -- Remaining segments use dot or bracket notation depending on the name
    for i = #temp - 1, 1, -1 do
        table.insert(parts,
            HasSpecial(temp[i])
            and '["' .. temp[i] .. '"]'
            or  "."  .. temp[i]
        )
    end

    return hasError
        and "nil -- Path contained invalid instance"
        or  table.concat(parts, "")
end

-- GetType: serialises any Roblox value to its Lua constructor string.
-- Ported verbatim from R2Sv2's GetType function.
local GetType = function(value)
    local Types = {
        EnumItem = function()
            return "Enum." .. tostring(value.EnumType) .. "." .. tostring(value.Name)
        end,
        Instance = function()
            return GetPath(value)
        end,
        CFrame = function()
            return "CFrame.new(" .. tostring(value) .. ")"
        end,
        Vector3 = function()
            return "Vector3.new(" .. tostring(value) .. ")"
        end,
        BrickColor = function()
            return 'BrickColor.new("' .. tostring(value) .. '")'
        end,
        Color3 = function()
            return "Color3.new(" .. tostring(value) .. ")"
        end,
        string = function()
            local S = tostring(value)
            return '"' .. S .. '"'
        end,
        Ray = function()
            return "Ray.new(Vector3.new("
                .. tostring(value.Origin)
                .. "), Vector3.new("
                .. tostring(value.Direction)
                .. "))"
        end,
    }
    local t = typeof(value)
    if Types[t] ~= nil then
        return Types[t]()
    end
    return tostring(value)
end

-- Table_TS: recursively serialises a Lua/Roblox table to a table literal string.
-- Ported verbatim from R2Sv2's Table_TS function.
-- Forward-declared so GetType can call it and it can call itself recursively.
local Table_TS
Table_TS = function(T)
    local M = {}
    for i, v in pairs(T) do
        local I = "\n\t" .. (type(i) == "number"
            and "["  .. i  .. "] = "
            or  '["' .. i  .. '"] = ')
        table.insert(M, I .. (type(v) == "table" and Table_TS(v) or GetType(v)))
    end
    return "\n{" .. table.concat(M, ", ") .. "\n}"
end

-- namecall_script: builds the complete Lua script string for one captured call.
-- Ported verbatim from R2Sv2's namecall_script function.
-- Uses `...` directly — valid here because this IS the vararg function level.
local namecall_script = function(object, method, ...)
    local scriptStr = "-- Script generated by Yazu RemoteSpy\n"
                   .. "-- yazu dumper\n"
                   .. " \n"
    local argNames = {}
    for i, v in pairs({...}) do
        scriptStr = scriptStr
            .. "local A_" .. i .. " = "
            .. (type(v) == "table" and Table_TS(v) or GetType(v))
            .. "\n"
        table.insert(argNames, "A_" .. i)
    end
    scriptStr = scriptStr .. "local Event = " .. GetPath(object) .. "\n\n"
    scriptStr = scriptStr .. "Event:" .. method .. "(" .. table.concat(argNames, ", ") .. ")"
    return scriptStr
end

-- ----------------------------------------------------------------
--  Spy state variables
-- ----------------------------------------------------------------
local spyIsActive      = false   -- whether the spy is currently logging
local spyLogBuffer     = {}      -- list of {script, caller, object, method, freturn} entries
local namecallDump     = {}      -- queue filled by the hook, drained by Stepped
local spyTotalFired    = 0       -- running count of all intercepted calls
local spyHookInstalled = false   -- whether __namecall has been patched
local spyOriginalCall  = nil     -- saved reference to the original __namecall

-- ----------------------------------------------------------------
--  flushSpyLog: writes the current in-memory buffer to Remote_Log.lua.
--  Called automatically every 25 calls and when spy is disabled.
-- ----------------------------------------------------------------
local function flushSpyLog()
    if #spyLogBuffer == 0 then
        return
    end

    local lines = {
        "-- ===========================================================",
        "-- Yazu Remote Spy Log",
        "-- Flushed  : " .. os.date("%Y-%m-%d %H:%M:%S"),
        "-- Total    : " .. tostring(spyTotalFired) .. " calls this session",
        "-- ===========================================================",
        "",
    }

    for _, entry in ipairs(spyLogBuffer) do
        -- Write the generated call script
        table.insert(lines, entry.script)
        -- If we captured a return value (RemoteFunction), append it
        if entry.freturn then
            table.insert(lines, "-- Return value: " .. tostring(entry.freturn))
        end
        -- If we have the caller script instance, note its full name
        if entry.caller then
            local ok, name = pcall(function()
                return entry.caller:GetFullName()
            end)
            if ok and name then
                table.insert(lines, "-- Caller: " .. name)
            end
        end
        table.insert(lines, string.rep("-", 40))
        table.insert(lines, "")
    end

    safeWrite("Remote_Log.lua", table.concat(lines, "\n"))
end

-- ----------------------------------------------------------------
--  installSpyHook: patches game.__namecall once.
--  Safe to call multiple times — exits immediately if already hooked.
-- ----------------------------------------------------------------
local function installSpyHook()
    if spyHookInstalled then
        return true
    end

    -- Verify required executor functions exist before touching the metatable
    if type(getrawmetatable) ~= "function" then
        Library:Notify("RemoteSpy: getrawmetatable() not available on this executor")
        return false
    end

    if type(getnamecallmethod) ~= "function" then
        Library:Notify("RemoteSpy: getnamecallmethod() not available on this executor")
        return false
    end

    -- Get the game object's metatable
    local gameMeta
    local metaOk, metaErr = pcall(function()
        gameMeta = getrawmetatable(game)
    end)

    if not metaOk or not gameMeta then
        Library:Notify("RemoteSpy: getrawmetatable(game) failed — " .. tostring(metaErr))
        return false
    end

    -- Unlock the metatable so we can overwrite __namecall
    if type(setreadonly) == "function" then
        pcall(setreadonly, gameMeta, false)
    elseif type(make_writeable) == "function" then
        pcall(make_writeable, gameMeta)
    end

    -- Save original __namecall before overwriting
    spyOriginalCall = gameMeta.__namecall

    if not spyOriginalCall then
        Library:Notify("RemoteSpy: __namecall is nil — cannot hook on this executor")
        return false
    end

    -- ============================================================
    --  THE HOOK — ported directly from R2Sv2's on_namecall
    --
    --  CRITICAL RULES FOLLOWED:
    --  [1] local args = {...}   — varargs captured at the OUTERMOST
    --      level of this function, before ANY nested function call.
    --      Lua 5.1 forbids reading `...` from inside a nested closure.
    --
    --  [2] args[#args] = nil    — strips the trailing nil Roblox
    --      appends to the vararg list on every namecall invocation.
    --
    --  [3] method:match("Server") — broad pattern matches both
    --      "FireServer" and "InvokeServer" (and their variants).
    --
    --  [4] "CharacterSoundEvent" is skipped — same as R2Sv2.
    --
    --  [5] The entry is QUEUED into namecallDump, not processed
    --      inline. Heavy work (file I/O, notifications) happens on
    --      the Stepped drain loop below, not inside the hook.
    --
    --  [6] The original is called with the ORIGINAL `...`, NOT with
    --      unpack(args). We stripped the trailing nil from args only
    --      for our own use; the game must receive the original call
    --      untouched so no functionality is broken.
    -- ============================================================
    gameMeta.__namecall = function(object, ...)
        local method = getnamecallmethod()

        -- [1] Capture varargs into a plain table at the top level of this function
        local args = {...}

        -- [2] Strip trailing nil that Roblox appends
        args[#args] = nil

        -- Only intercept when spy is active, method contains "Server",
        -- and the object is not the noisy CharacterSoundEvent remote
        if spyIsActive
            and method ~= nil
            and method:match("Server")
            and object.Name ~= "CharacterSoundEvent"
        then
            -- [3] Attempt to get the script that made this call (pcall: getfenv may be absent)
            local callerScript = nil
            pcall(function()
                callerScript = getfenv(2).script
            end)

            -- [4] For RemoteFunction, capture the return value via InvokeServer
            --     Wrapped in pcall so a network error never breaks the hook
            local freturnStr = nil
            if object.ClassName == "RemoteFunction" then
                pcall(function()
                    local freturn = {pcall(object.InvokeServer, object, unpack(args))}
                    -- select(2, ...) drops the pcall success boolean, keeping only the values
                    freturn = {select(2, unpack(freturn))}
                    if #freturn == 0 then
                        freturnStr = object.Name .. " is a void type RemoteFunction"
                    else
                        freturnStr = Table_TS(freturn)
                    end
                end)
            end

            -- [5] Build the script string now (uses unpack(args) — safe, args is a plain table)
            --     Then queue the complete entry for the Stepped drain loop
            local builtScript = namecall_script(
                object,
                object.ClassName == "RemoteEvent" and "FireServer" or "InvokeServer",
                unpack(args)
            )

            namecallDump[#namecallDump + 1] = {
                script  = builtScript,
                caller  = callerScript,
                object  = object,
                method  = method,
                freturn = freturnStr,
            }
        end

        -- [6] Always forward the ORIGINAL varargs to the real namecall
        return spyOriginalCall(object, ...)
    end

    spyHookInstalled = true
    return true
end

-- ----------------------------------------------------------------
--  Stepped drain loop — mirrors R2Sv2's Step:Connect pattern.
--  Empties namecallDump every frame, updating the buffer and firing
--  notifications. Doing this outside the hook keeps the hook fast.
-- ----------------------------------------------------------------
RunService.Stepped:Connect(function()
    while #namecallDump > 0 do
        local entry = table.remove(namecallDump, 1)

        spyTotalFired = spyTotalFired + 1

        -- Add to in-memory buffer
        table.insert(spyLogBuffer, entry)

        -- Cap buffer at 300 entries to prevent unbounded memory growth
        if #spyLogBuffer > 300 then
            table.remove(spyLogBuffer, 1)
        end

        -- Auto-flush to file every 25 calls
        if spyTotalFired % 25 == 0 then
            flushSpyLog()
        end

        -- Notify with remote name and method
        Library:Notify(
            string.format(
                "[Spy] #%d  %s : %s",
                spyTotalFired,
                entry.object.Name,
                entry.method
            ),
            3
        )
    end
end)

-- ----------------------------------------------------------------
--  Public controls
-- ----------------------------------------------------------------
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
            "Remote Spy: DISABLED — %d calls logged to Remote_Log.lua",
            spyTotalFired
        )
    )
end

local function clearRemoteLog()
    spyLogBuffer  = {}
    namecallDump  = {}
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
    Text = 'Force ReplicatedStorage Dump',
    Func = function()
        guarded(function()
            local count = dumpSingleService('ReplicatedStorage')
            Library:Notify('ReplicatedStorage — ' .. count .. ' scripts saved')
        end)
    end,
})

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
