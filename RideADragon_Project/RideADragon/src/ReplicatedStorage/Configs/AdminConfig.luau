--[[
    AdminConfig
    Live-server admin permissions for chat commands.

    The experience shown in Studio is group-owned, so CreatorId may be a group id.
    "Bendzaminoo" is included explicitly so the owner can use the commands immediately.
    Add additional Roblox usernames or numeric UserIds here when needed.
]]

return {
    -- Exact Roblox usernames (case-insensitive). Display names are NOT used for permissions.
    AdminUsernames = {
        "Bendzaminoo",
    },

    -- Prefer UserIds for any additional admins because usernames can change.
    AdminUserIds = {
        -- 123456789,
    },

    -- If the experience is personally owned (not group-owned), its creator is also an admin.
    AllowUserCreator = true,

    -- Anyone is allowed to use the commands while testing inside Roblox Studio.
    AllowEveryoneInStudio = true,

    -- Safety limits for one command.
    MaxItemCount = 100,
    MaxSpins = 1000000,
    MaxCash = 1000000000000000,
}
