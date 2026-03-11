-- ================================================================
--  core/state.lua
--  All shared variables that multiple features need to read/write.
--  Every feature gets this same table — changes in one file are
--  instantly visible in all others because tables are references.
-- ================================================================

local State = {
    -- Aimbot
    whitelistedIds    = {},
    currentTarget     = nil,
    aimOnePressActive = false,
    aimKeyLastState   = false,
    savedMouseSens    = nil,
    activeTween       = nil,
    stickyTarget      = nil,

    -- SpinBot / TriggerBot
    Spinning         = false,
    Triggering       = false,
    spinKeyLastState = false,
    trigKeyLastState = false,
    lastRandAimTime  = 0,
    lastRandSpinTime = 0,

    -- Player lists
    ignoredPlayers = {},   -- { [name] = true }
    targetPlayers  = {},   -- { [name] = true }

    -- Desync  (DO NOT CHANGE these defaults)
    desyncActive    = false,
    desyncHbConn    = nil,
    frozenServerPos = nil,

    -- Aimbot part list (shared so misc loop can randomise it)
    aimPartValues  = { 'Head', 'HumanoidRootPart', 'UpperTorso', 'Torso', 'LowerTorso' },
    spinPartValues = { 'Head', 'HumanoidRootPart' },
}

return State
