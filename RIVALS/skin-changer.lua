repeat task.wait() until game:IsLoaded()
print("[skchan] Game loaded")
assert(hookmetamethod, "[ascida]: Your executor doesn't support this.")
print("[skchan] hookmetamethod available")

-- FIX: debug.info returns nil for C functions; string.find(nil,...) would crash
for _, v in getgc() do
    if typeof(v) == "function" then
        local src = debug.info(v, "s")
        if src and string.find(src, "AnalyticsPipelineController") then
            local orig = hookfunction(v, newcclosure(function(...)
                if checkcaller() then return orig(...) end
                return nil
            end))
            print("[skchan] AnalyticsPipelineController hooked")
        end
    end
end

local players           = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local httpService       = game:GetService("HttpService")
local localPlayer       = players.LocalPlayer

-- OPT: cache lowercased name once — used in _PlayFinisher on every kill
local localPlayerNameLower = localPlayer.Name:lower()

print("[skchan] Services acquired")

local function waitForCharacter()
    if not localPlayer.Character then
        print("[skchan] Waiting for character...")
        localPlayer.CharacterAdded:Wait()
    end
    task.wait(1)
end
waitForCharacter()
print("[skchan] Character ready")

local function awaitChild(parent, name, limit)
    local attempts = 0
    local child
    repeat
        task.wait(1)
        child    = parent:FindFirstChild(name)
        attempts = attempts + 1
        if attempts > (limit or 20) then
            -- FIX: parent.Name guarded — parent could theoretically be destroyed
            local pname = pcall(function() return parent.Name end) and parent.Name or "?"
            print("[skchan] ERROR: '" .. name .. "' not found under " .. pname)
            return nil
        end
    until child
    return child
end

local playerScripts = awaitChild(localPlayer, "PlayerScripts")
if not playerScripts then return end
print("[skchan] PlayerScripts found")

local controllers = awaitChild(playerScripts, "Controllers")
if not controllers then return end
print("[skchan] Controllers found")

local modules = awaitChild(replicatedStorage, "Modules")
if not modules then return end
print("[skchan] Modules found")

local function waitForModule(parent, name, timeout)
    local elapsed = 0
    while not parent:FindFirstChild(name) and elapsed < timeout do
        task.wait(0.5)
        elapsed = elapsed + 0.5
    end
    return parent:FindFirstChild(name)
end

print("[skchan] Waiting for module instances...")
local cosmeticLib = waitForModule(modules,     "CosmeticLibrary",     10)
local itemLib     = waitForModule(modules,     "ItemLibrary",         10)
local dataCtrl    = waitForModule(controllers, "PlayerDataController", 10)
local dataUtility = waitForModule(modules,     "PlayerDataUtility",   10)

print("[skchan] CosmeticLibrary:",      cosmeticLib and "found" or "MISSING")
print("[skchan] ItemLibrary:",          itemLib     and "found" or "MISSING")
print("[skchan] PlayerDataController:", dataCtrl    and "found" or "MISSING")

if not cosmeticLib or not itemLib or not dataCtrl then
    print("[skchan] ERROR: Required modules missing, aborting")
    return
end

-- ── Module references ─────────────────────────────────────────────────────────
local EnumLibrary, CosmeticLibrary, ItemLibrary, DataController, DataUtility

local loadSuccess, loadErr = pcall(function()
    print("[skchan] Requiring CosmeticLibrary...")
    CosmeticLibrary = require(cosmeticLib)
    print("[skchan] CosmeticLibrary OK")

    print("[skchan] Requiring ItemLibrary...")
    ItemLibrary = require(itemLib)
    print("[skchan] ItemLibrary OK")

    print("[skchan] Requiring DataController...")
    DataController = require(dataCtrl)
    print("[skchan] DataController OK")

    if dataUtility then
        DataUtility = require(dataUtility)
        print("[skchan] DataUtility OK")
    end

    local enumLib = modules:FindFirstChild("EnumLibrary")
    if enumLib then
        print("[skchan] Requiring EnumLibrary...")
        EnumLibrary = require(enumLib)
        print("[skchan] EnumLibrary OK")
        if EnumLibrary and EnumLibrary.WaitForEnumBuilder then
            task.spawn(function()
                pcall(function() EnumLibrary:WaitForEnumBuilder() end)
                print("[skchan] EnumBuilder ready")
            end)
        end
    else
        print("[skchan] EnumLibrary not found, skipping")
    end
end)

print("[skchan] Module load:", tostring(loadSuccess), loadErr and tostring(loadErr) or "")

if not loadSuccess or not CosmeticLibrary or not ItemLibrary or not DataController then
    print("[skchan] ERROR: Failed to require core modules, aborting")
    return
end

-- ── OPT: pre-built caches set up after modules are confirmed loaded ───────────

-- Cache for DataController.GetUnlockedWeapons — built once, never changes at runtime
-- OPT: was rebuilt on every call by iterating all ItemLibrary.Items each time
local unlockedWeaponsCache = nil
local function getUnlockedWeapons()
    if unlockedWeaponsCache then return unlockedWeaponsCache end
    unlockedWeaponsCache = {}
    if ItemLibrary and ItemLibrary.Items then
        for name in pairs(ItemLibrary.Items) do
            if not name:find("MISSING_") then
                unlockedWeaponsCache[name] = true
            end
        end
    end
    return unlockedWeaponsCache
end

-- OPT: single reusable proxy for CosmeticInventory ownership — was a new table
-- allocation on every DataController:Get("CosmeticInventory") call.
-- Only claim ownership of cosmetics that actually exist in CosmeticLibrary.Cosmetics
-- to prevent the game from trying to validate non-existent/bogus cosmetic names.
local cosmeticInventoryProxy = setmetatable({}, {
    __index = function(_, key)
        if type(key) ~= "string" then return nil end
        local cosmetic = CosmeticLibrary.Cosmetics[key]
        if cosmetic then return true end
        -- handle enum-based keys
        if EnumLibrary then
            local ok, name = pcall(function() return EnumLibrary:FromEnum(key) end)
            if ok and name and CosmeticLibrary.Cosmetics[tostring(name)] then
                return true
            end
        end
        return nil
    end,
    __newindex = function() end,
})

-- OPT: ReplicatedClass enum keys cached after first lookup — was requiring the
-- module and calling ToEnum("Data/Skin/Wrap/Charm") on every ClientViewModel.new
local rcEnumsCache = nil
local function getRCEnums()
    if rcEnumsCache then return rcEnumsCache end
    local ok, rc = pcall(require, replicatedStorage.Modules.ReplicatedClass)
    if ok and rc then
        rcEnumsCache = {
            Data  = rc:ToEnum("Data"),
            Skin  = rc:ToEnum("Skin"),
            Wrap  = rc:ToEnum("Wrap"),
            Charm = rc:ToEnum("Charm"),
        }
    end
    return rcEnumsCache
end

-- OPT: Finishers folder cached once — was FindFirstChild on every kill
local finishersFolder = replicatedStorage.Modules:FindFirstChild("Finishers")

-- ── State ─────────────────────────────────────────────────────────────────────
local equipped  = {}   -- equipped[weaponName][cosmeticType] = clonedData
local favorites = {}   -- favorites[weaponName][cosmeticName] = bool
local constructingWeapon, viewingProfile, lastUsedWeapon
local hooksReady = false

-- OPT: debounce replicate+save so rapid equips don't pile up waiting threads
-- (previously every single equip spawned its own thread that could wait 10s)
local replicatePending = false
local function scheduleReplicate()
    if replicatePending then return end
    replicatePending = true
    task.spawn(function()
        local waited = 0
        while not hooksReady and waited < 10 do
            task.wait(0.1)
            waited = waited + 0.1
        end
        replicatePending = false
        print("[skchan] Replicating WeaponInventory...")
        local ok, err = pcall(function()
            DataController.CurrentData:Replicate("WeaponInventory")
        end)
        print("[skchan] Replicate:", tostring(ok), err and tostring(err) or "")
        -- saveConfig deferred so file I/O doesn't block the replicate
        task.defer(saveConfig)
    end)
end

local SKIP_COSMETIC_NAMES = {
    RANDOM_COSMETIC = true,
    NONE            = true,
    [""]            = true,
}

-- ── cloneCosmetic ─────────────────────────────────────────────────────────────
local function cloneCosmetic(name, cosmeticType, options)
    if not name or SKIP_COSMETIC_NAMES[name] then
        return nil
    end
    if not CosmeticLibrary or not CosmeticLibrary.Cosmetics then
        print("[skchan] cloneCosmetic: CosmeticLibrary not ready")
        return nil
    end

    -- 1. Apply game's own rename map (12 entries: "Bone Crossbow" -> "Crossbone" etc.)
    local resolvedName = (CosmeticLibrary.RENAMED_COSMETICS
        and CosmeticLibrary.RENAMED_COSMETICS[name])
        or name

    -- 2. Direct string lookup (covers all 1057 normal cases per diagnostic)
    local base = CosmeticLibrary.Cosmetics[resolvedName]

    -- 3. Case-insensitive fallback (safety net only)
    if not base then
        local lower = resolvedName:lower()
        for k, v in pairs(CosmeticLibrary.Cosmetics) do
            if tostring(k):lower() == lower then
                base         = v
                resolvedName = k
                print("[skchan] cloneCosmetic: case-insensitive match:", name, "->", k)
                break
            end
        end
    end

    -- 4. Enum-based lookup (last resort)
    if not base and EnumLibrary then
        pcall(function()
            local enumId = EnumLibrary:ToEnum(resolvedName)
            if enumId then
                local candidate = CosmeticLibrary.Cosmetics[enumId]
                if candidate then
                    base = candidate
                    print("[skchan] cloneCosmetic: enum match:", name, "->", tostring(enumId))
                end
            end
        end)
    end

    if not base then
        print("[skchan] cloneCosmetic: FAILED for:", name, "-> resolved:", resolvedName)
        return nil
    end

    local data = {}
    for k, v in pairs(base) do data[k] = v end
    data.Name = resolvedName
    data.Type = data.Type or cosmeticType
    data.Seed = math.random(1, 1000000)

    if EnumLibrary then
        pcall(function()
            local enumId = EnumLibrary:ToEnum(resolvedName)
            if enumId then
                data.Enum     = enumId
                data.ObjectID = enumId
            end
        end)
    end

    if options then
        if options.inverted      then data.Inverted         = true end
        if options.favoritesOnly then data.OnlyUseFavorites = true end
    end

    return data
end

-- ── Config persistence ────────────────────────────────────────────────────────
local saveFile = "skchan/config.json"

function saveConfig()
    if not writefile then return end
    task.spawn(function()
        pcall(function()
            local config = { equipped = {}, favorites = favorites }
            for weapon, cosmetics in pairs(equipped) do
                config.equipped[weapon] = {}
                for cosmeticType, cosmeticData in pairs(cosmetics) do
                    if cosmeticData and cosmeticData.Name then
                        config.equipped[weapon][cosmeticType] = {
                            name     = cosmeticData.Name,
                            seed     = cosmeticData.Seed,
                            inverted = cosmeticData.Inverted,
                        }
                    end
                end
            end
            if not isfolder("skchan") then makefolder("skchan") end
            writefile(saveFile, httpService:JSONEncode(config))
            print("[skchan] Config saved")
        end)
    end)
end

local function loadConfig()
    if not readfile or not isfile or not isfile(saveFile) then
        print("[skchan] No config file, starting fresh")
        return
    end
    print("[skchan] Loading config...")
    pcall(function()
        local config = httpService:JSONDecode(readfile(saveFile))
        if config.equipped then
            for weapon, cosmetics in pairs(config.equipped) do
                equipped[weapon] = {}
                for cosmeticType, cosmeticData in pairs(cosmetics) do
                    local cloned = cloneCosmetic(
                        cosmeticData.name, cosmeticType, { inverted = cosmeticData.inverted }
                    )
                    if cloned then
                        cloned.Seed                    = cosmeticData.seed
                        equipped[weapon][cosmeticType] = cloned
                        print("[skchan] Loaded:", weapon, cosmeticType, cosmeticData.name)
                    else
                        print("[skchan] FAILED to clone:", weapon, cosmeticType, cosmeticData.name)
                    end
                end
            end
        end
        favorites = config.favorites or {}
        print("[skchan] Config load complete")
    end)
end

-- ── Patch DataController ownership ───────────────────────────────────────────
print("[skchan] Patching DataController...")
DataController.OwnsAllWeapons     = function() return true end
DataController.GetUnlockedWeapons = getUnlockedWeapons  -- OPT: uses cached table
print("[skchan] DataController ownership patched")

-- ── Patch CosmeticLibrary ─────────────────────────────────────────────────────
print("[skchan] Patching CosmeticLibrary...")
CosmeticLibrary.OwnsCosmeticNormally     = function() return true end
CosmeticLibrary.OwnsCosmeticUniversally  = function() return true end
CosmeticLibrary.OwnsCosmeticForSomething = function() return true end
CosmeticLibrary.OwnsCosmeticForWeapon    = function() return true end
local originalOwnsCosmetic = CosmeticLibrary.OwnsCosmetic
CosmeticLibrary.OwnsCosmetic = function(self, inventory, name, weapon)
    if name and name:find("MISSING_") then
        return originalOwnsCosmetic(self, inventory, name, weapon)
    end
    return true
end
print("[skchan] CosmeticLibrary patched")

-- ── Patch DataController.Get ──────────────────────────────────────────────────
local originalGet = DataController.Get
DataController.Get = function(self, key)
    -- OPT: return the single cached proxy instead of allocating a new table each call
    if key == "CosmeticInventory" then
        return cosmeticInventoryProxy
    end
    local data = originalGet(self, key)
    if key == "FavoritedCosmetics" then
        local result = {}
        if data then for k, v in pairs(data) do result[k] = v end end
        for weapon, favs in pairs(favorites) do
            result[weapon] = result[weapon] or {}
            for name, isFav in pairs(favs) do result[weapon][name] = isFav end
        end
        return result
    end
    return data
end
print("[skchan] DataController.Get patched")

-- ── Patch DataController.GetWeaponData ───────────────────────────────────────
local originalGetWeaponData = DataController.GetWeaponData
DataController.GetWeaponData = function(self, weaponName)
    local data         = { Unlocked = true, Level = 100, XP = 99999 }
    local originalData = originalGetWeaponData(self, weaponName)
    if originalData then
        for k, v in pairs(originalData) do data[k] = v end
    end
    if equipped[weaponName] then
        for cosmeticType, cosmeticData in pairs(equipped[weaponName]) do
            data[cosmeticType] = cosmeticData
        end
    end
    return data
end
print("[skchan] DataController.GetWeaponData patched")

-- ── FighterController ─────────────────────────────────────────────────────────
local FighterController
task.spawn(function()
    local fc = controllers:FindFirstChild("FighterController")
    if fc then
        print("[skchan] Requiring FighterController...")
        pcall(function() FighterController = require(fc) end)
        print("[skchan] FighterController:", FighterController and "OK" or "FAILED")
    else
        print("[skchan] FighterController not found")
    end
end)

-- ── __namecall hook ───────────────────────────────────────────────────────────
task.spawn(function()
    print("[skchan] Waiting for Remotes...")
    local remotes            = replicatedStorage:WaitForChild("Remotes", 15)
    local dataRemotes        = remotes and remotes:WaitForChild("Data", 10)
    local equipRemote        = dataRemotes and dataRemotes:WaitForChild("EquipCosmetic", 10)
    local favoriteRemote     = dataRemotes and dataRemotes:FindFirstChild("FavoriteCosmetic")
    local replicationRemotes = remotes and remotes:FindFirstChild("Replication")
    local fighterRemotes     = replicationRemotes and replicationRemotes:FindFirstChild("Fighter")
    local useItemRemote      = fighterRemotes and fighterRemotes:FindFirstChild("UseItem")

    print("[skchan] equipRemote:",    equipRemote    and equipRemote:GetFullName()    or "MISSING")
    print("[skchan] favoriteRemote:", favoriteRemote and favoriteRemote:GetFullName() or "MISSING")
    print("[skchan] useItemRemote:",  useItemRemote  and useItemRemote:GetFullName()  or "MISSING")

    if not equipRemote then
        print("[skchan] ERROR: EquipCosmetic not found, hook NOT installed")
        return
    end

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if getnamecallmethod() ~= "FireServer" then return oldNamecall(self, ...) end

        -- OPT: previously `local args = { ... }` ran here for EVERY FireServer call
        -- in the entire game. Now we only unpack ... when self actually matches one
        -- of our remotes, eliminating table allocation on all unrelated calls.

        if self == equipRemote then
            local weaponName, cosmeticType, cosmeticName, options = ...
            options = options or {}

            if SKIP_COSMETIC_NAMES[cosmeticName] then
                return oldNamecall(self, ...)
            end

            equipped[weaponName] = equipped[weaponName] or {}

            if not cosmeticName or cosmeticName == "None" or cosmeticName == "" then
                equipped[weaponName][cosmeticType] = nil
                if not next(equipped[weaponName]) then equipped[weaponName] = nil end
            else
                local cloned = cloneCosmetic(cosmeticName, cosmeticType, {
                    inverted      = options.IsInverted,
                    favoritesOnly = options.OnlyUseFavorites,
                })
                if cloned then
                    equipped[weaponName][cosmeticType] = cloned
                else
                    return oldNamecall(self, ...)
                end
            end

            scheduleReplicate()
            return
        end

        if favoriteRemote and self == favoriteRemote then
            local a1, a2, a3 = ...
            favorites[a1]     = favorites[a1] or {}
            favorites[a1][a2] = a3 or nil
            saveConfig()
            return
        end

        if useItemRemote and self == useItemRemote and FighterController then
            local itemObjectID = ...
            task.spawn(function()
                pcall(function()
                    local fighter = FighterController:GetFighter(localPlayer)
                    if fighter and fighter.Items then
                        for _, item in pairs(fighter.Items) do
                            if item:Get("ObjectID") == itemObjectID then
                                lastUsedWeapon = item.Name
                                break
                            end
                        end
                    end
                end)
            end)
        end

        return oldNamecall(self, ...)
    end))
    print("[skchan] __namecall hook installed")
end)

-- ── ItemLibrary image patch ───────────────────────────────────────────────────
print("[skchan] Patching ItemLibrary.GetViewModelImageFromWeaponData...")
local originalGetViewModelImage = ItemLibrary.GetViewModelImageFromWeaponData
ItemLibrary.GetViewModelImageFromWeaponData = function(self, weaponData, highRes)
    if not weaponData then
        return originalGetViewModelImage(self, weaponData, highRes)
    end
    local weaponName    = weaponData.Name
    local equippedSkins = equipped[weaponName]
    local shouldShowSkin = equippedSkins and equippedSkins.Skin and (
        (weaponData.Skin and weaponData.Skin == equippedSkins.Skin)
        or viewingProfile == localPlayer
    )
    if shouldShowSkin then
        local skinInfo = self.ViewModels[equippedSkins.Skin.Name]
        if skinInfo then
            return skinInfo[highRes and "ImageHighResolution" or "Image"] or skinInfo.Image
        end
    end
    return originalGetViewModelImage(self, weaponData, highRes)
end
print("[skchan] GetViewModelImageFromWeaponData patched")

-- ── Viewmodel / replication hooks (3 s delay) ─────────────────────────────────
task.spawn(function()
    print("[skchan] Viewmodel hooks: waiting 3s...")
    task.wait(3)

    -- ClientItem._CreateViewModel
    pcall(function()
        print("[skchan] Hooking ClientItem._CreateViewModel...")
        local ClientItem = require(
            playerScripts.Modules.ClientReplicatedClasses.ClientFighter.ClientItem
        )
        if not ClientItem._CreateViewModel then
            print("[skchan] ClientItem._CreateViewModel not found")
            return
        end
        local orig = ClientItem._CreateViewModel
        ClientItem._CreateViewModel = function(self, viewmodelRef)
            local ok, result = pcall(function()
                local weaponName   = self.Name
                local weaponPlayer = self.ClientFighter and self.ClientFighter.Player
                constructingWeapon = (weaponPlayer == localPlayer) and weaponName or nil
                if weaponPlayer == localPlayer
                        and equipped[weaponName] and equipped[weaponName].Skin
                        and viewmodelRef then
                    pcall(function()
                        local dataKey = self:ToEnum("Data")
                        local skinKey = self:ToEnum("Skin")
                        local nameKey = self:ToEnum("Name")
                        if viewmodelRef[dataKey] then
                            viewmodelRef[dataKey][skinKey] = equipped[weaponName].Skin
                            viewmodelRef[dataKey][nameKey] = equipped[weaponName].Skin.Name
                        elseif viewmodelRef.Data then
                            viewmodelRef.Data.Skin = equipped[weaponName].Skin
                            viewmodelRef.Data.Name = equipped[weaponName].Skin.Name
                        end
                    end)
                end
                return orig(self, viewmodelRef)
            end)
            constructingWeapon = nil
            if ok then return result end
            return orig(self, viewmodelRef)
        end
        print("[skchan] ClientItem._CreateViewModel hooked")
    end)

    -- ClientViewModel.GetWrap / ClientViewModel.new
    pcall(function()
        print("[skchan] Hooking ClientViewModel...")
        local vmMod = playerScripts
            .Modules.ClientReplicatedClasses.ClientFighter.ClientItem
            :FindFirstChild("ClientViewModel")
        if not vmMod then
            print("[skchan] ClientViewModel not found")
            return
        end
        local ClientViewModel = require(vmMod)

        if ClientViewModel.GetWrap then
            local orig = ClientViewModel.GetWrap
            ClientViewModel.GetWrap = function(self)
                local weaponName   = self.ClientItem and self.ClientItem.Name
                local weaponPlayer = self.ClientItem
                    and self.ClientItem.ClientFighter
                    and self.ClientItem.ClientFighter.Player
                if weaponName and weaponPlayer == localPlayer
                        and equipped[weaponName] and equipped[weaponName].Wrap then
                    return equipped[weaponName].Wrap
                end
                return orig(self)
            end
            print("[skchan] ClientViewModel.GetWrap hooked")
        else
            print("[skchan] ClientViewModel.GetWrap not found")
        end

        local origNew = ClientViewModel.new
        ClientViewModel.new = function(replicatedData, clientItem)
            local ok, result = pcall(function()
                local weaponPlayer = clientItem.ClientFighter and clientItem.ClientFighter.Player
                local weaponName   = constructingWeapon or clientItem.Name
                if weaponPlayer == localPlayer and equipped[weaponName] then
                    local enums = getRCEnums()
                    if enums then
                        replicatedData[enums.Data] = replicatedData[enums.Data] or {}
                        local cosmetics = equipped[weaponName]
                        if cosmetics.Skin  then replicatedData[enums.Data][enums.Skin]  = cosmetics.Skin end
                        if cosmetics.Wrap  then replicatedData[enums.Data][enums.Wrap]  = cosmetics.Wrap end
                        if cosmetics.Charm then replicatedData[enums.Data][enums.Charm] = cosmetics.Charm end
                    end
                end
                return origNew(replicatedData, clientItem)
            end)
            if ok and result and result._UpdateWrap then
                local weaponName = constructingWeapon or clientItem.Name
                if clientItem.ClientFighter and clientItem.ClientFighter.Player == localPlayer
                        and equipped[weaponName] and equipped[weaponName].Wrap then
                    pcall(function() result:_UpdateWrap() end)
                end
            end
            return result
        end
        print("[skchan] ClientViewModel.new hooked")
    end)

    -- ViewProfile.Fetch
    pcall(function()
        print("[skchan] Hooking ViewProfile.Fetch...")
        local ViewProfile = require(playerScripts.Modules.Pages.ViewProfile)
        if not (ViewProfile and ViewProfile.Fetch) then
            print("[skchan] ViewProfile.Fetch not found")
            return
        end
        local orig = ViewProfile.Fetch
        ViewProfile.Fetch = function(self, targetPlayer)
            viewingProfile = targetPlayer
            return orig(self, targetPlayer)
        end
        print("[skchan] ViewProfile.Fetch hooked")
    end)

    -- ── Finisher injection (DISABLED by default) ─────────────────────────────
    -- This hook is optional and can cause freezes/crashes in the current RIVALS
    -- build. If you want finishers, enable it after confirming the rest works.
    --[[
    pcall(function()
        print("[skchan] Hooking ClientEntity._PlayFinisher...")
        local ClientEntity = require(
            playerScripts.Modules.ClientReplicatedClasses.ClientEntity
        )
        if not ClientEntity._PlayFinisher then
            print("[skchan] ClientEntity._PlayFinisher not found")
            return
        end

        local orig = ClientEntity._PlayFinisher
        ClientEntity._PlayFinisher = function(self, finisherName, isFinal, eliminator, serial)
            local isOurKill = false
            if eliminator == localPlayer then
                isOurKill = true
            elseif type(eliminator) == "string" then
                isOurKill = eliminator == localPlayer.Name or eliminator:lower() == localPlayerNameLower
            elseif typeof(eliminator) == "userdata" and EnumLibrary then
                pcall(function()
                    local decoded = EnumLibrary:FromEnum(eliminator)
                    if decoded then
                        local ds = tostring(decoded)
                        isOurKill = ds == localPlayer.Name or ds:lower() == localPlayerNameLower
                    end
                end)
            end

            if isOurKill then
                local weaponToUse = lastUsedWeapon
                if not (weaponToUse and equipped[weaponToUse] and equipped[weaponToUse].Finisher) then
                    for wName, cosmetics in pairs(equipped) do
                        if cosmetics.Finisher then
                            weaponToUse = wName
                            break
                        end
                    end
                end

                if weaponToUse and equipped[weaponToUse] and equipped[weaponToUse].Finisher then
                    local override = equipped[weaponToUse].Finisher.Name
                    if finishersFolder and finishersFolder:FindFirstChild(override) then
                        finisherName = override
                    end
                end
            end

            return orig(self, finisherName, isFinal, eliminator, serial)
        end
        print("[skchan] ClientEntity._PlayFinisher hooked")
    end)
    --]]

    hooksReady = true
    print("[skchan] hooksReady = true.")
    -- Only flush if the user actually has saved/selected cosmetics; otherwise skip
    -- the expensive inventory replication to avoid startup freeze.
    local hasEquipped = false
    for _ in pairs(equipped) do hasEquipped = true; break end
    if hasEquipped then
        print("[skchan] Replicating WeaponInventory in background...")
        task.spawn(function()
            task.wait(2)
            local ok, err = pcall(function()
                if DataController.CurrentData and DataController.CurrentData.Replicate then
                    DataController.CurrentData:Replicate("WeaponInventory")
                end
            end)
            print("[skchan] Flush:", tostring(ok), err and tostring(err) or "")
        end)
    else
        print("[skchan] Nothing equipped, skipping startup flush.")
    end
end)

-- ── Load saved config ─────────────────────────────────────────────────────────
print("[skchan] Loading config...")
loadConfig()
print("[skchan] Script fully initialised")
