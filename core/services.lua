-- ================================================================
--  core/services.lua
--  All Roblox services in one place.
--  To add a new service: just add it here and use Services.X everywhere.
-- ================================================================

local Services = {
    RunService       = game:GetService('RunService'),
    TweenService     = game:GetService('TweenService'),
    UserInputService = game:GetService('UserInputService'),
    Players          = game:GetService('Players'),
    PathfindingService = game:GetService('PathfindingService'),
    HttpService      = game:GetService('HttpService'),
    ReplicatedStorage = game:GetService('ReplicatedStorage'),
    CollectionService = game:GetService('CollectionService'),
}

Services.LocalPlayer = Services.Players.LocalPlayer

return Services
