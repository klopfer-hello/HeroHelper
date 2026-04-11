--[[
    HeroHelper - Database Module

    Static database of every TBC raid boss for which HeroHelper knows when to
    remind the player to cast Heroism / Bloodlust. Each entry is keyed by an
    addon-internal ID (stable across versions) and provides:

        name     -- English boss name (used for name-based detection)
        aliases  -- optional list of extra name strings that can match (e.g.
                    localized variants, combined encounters like "Twin Emperors")
        raid     -- human-readable raid name (for grouping in the config UI)
        raidKey  -- stable key identifying the raid (used by the UI tabs)
        default  -- default trigger config for this boss:
                      { type = "pull"  }                   -> cast on the pull
                      { type = "hp",  hp = 35 }            -> cast at <= 35% HP
                      { type = "phase", phase = 2, yell = "..." }
                                                            -> cast when a boss
                                                               yell matches
        yells    -- optional table mapping phase index -> yell pattern or
                    spellID used to advance phase detection. The Triggers module
                    uses these to decide when "phase N" has been entered.

    The per-character saved variables store *overrides* (HH.chardb.bosses[id]).
    Any missing key falls back to this table's defaults.
]]

local ADDON_NAME, HH = ...

HH.Database = {}
local DB = HH.Database

-- ============================================================================
-- Raid groupings (used by the config panel tabs / dropdowns)
-- ============================================================================

DB.RAIDS = {
    { key = "kara",    name = "Karazhan",          order = 1 },
    { key = "gruul",   name = "Gruul's Lair",      order = 2 },
    { key = "mag",     name = "Magtheridon's Lair",order = 3 },
    { key = "ssc",     name = "Serpentshrine Cavern", order = 4 },
    { key = "tk",      name = "Tempest Keep",      order = 5 },
    { key = "za",      name = "Zul'Aman",          order = 6 },
    { key = "hyjal",   name = "Hyjal Summit",      order = 7 },
    { key = "bt",      name = "Black Temple",      order = 8 },
    { key = "swp",     name = "Sunwell Plateau",   order = 9 },
}

-- ============================================================================
-- Boss table
-- ============================================================================
-- Default triggers are picked from common Shaman raid practice:
--   * trash-adjacent DPS checks / short execute fights -> "pull"
--   * long progression bosses                          -> "hp" at a value where
--                                                         burn phase starts
--   * phased fights with a clear burn phase entry      -> "phase" with yell

DB.BOSSES = {
    -- ==================== KARAZHAN ====================
    ["kara_attumen"]    = { raidKey = "kara", name = "Attumen the Huntsman",                           default = { type = "pull" } },
    ["kara_moroes"]     = { raidKey = "kara", name = "Moroes",                                          default = { type = "pull" } },
    ["kara_maiden"]     = { raidKey = "kara", name = "Maiden of Virtue",                                default = { type = "pull" } },
    ["kara_opera"]      = { raidKey = "kara", name = "Opera Event",                                     aliases = { "Romulo", "Julianne", "Dorothee", "Strawman", "Tinhead", "Roar", "The Crone", "The Big Bad Wolf" }, default = { type = "pull" } },
    ["kara_curator"]    = { raidKey = "kara", name = "The Curator",                                     default = { type = "pull" } },
    ["kara_terestian"]  = { raidKey = "kara", name = "Terestian Illhoof",                               default = { type = "pull" } },
    ["kara_shade"]      = { raidKey = "kara", name = "Shade of Aran",                                   default = { type = "hp", hp = 35 } },
    ["kara_netherspite"]= { raidKey = "kara", name = "Netherspite",                                     default = { type = "pull" } },
    ["kara_chess"]      = { raidKey = "kara", name = "Chess Event",                                     default = { type = "pull" } },
    ["kara_prince"]     = { raidKey = "kara", name = "Prince Malchezaar",
        default = { type = "phase", phase = 2 },
        yells = {
            [2] = "All will be laid to waste",         -- infernal phase begins
            [3] = "Not enough!",                       -- phase 3
        },
    },
    ["kara_nightbane"]  = { raidKey = "kara", name = "Nightbane",
        default = { type = "phase", phase = 2 },
        yells = {
            [2] = "Fleshlings, your time has come",    -- ground phase
        },
    },

    -- ==================== GRUUL'S LAIR ====================
    ["gruul_maulgar"]   = { raidKey = "gruul", name = "High King Maulgar",                              default = { type = "pull" } },
    ["gruul_gruul"]     = { raidKey = "gruul", name = "Gruul the Dragonkiller",                         default = { type = "hp", hp = 30 } },

    -- ==================== MAGTHERIDON'S LAIR ====================
    ["mag_magtheridon"] = { raidKey = "mag",  name = "Magtheridon",
        default = { type = "phase", phase = 3 },
        yells = {
            [3] = "I am... unleashed!",                 -- phase 3 / breakout burn
        },
    },

    -- ==================== SERPENTSHRINE CAVERN ====================
    ["ssc_hydross"]     = { raidKey = "ssc", name = "Hydross the Unstable",                             default = { type = "pull" } },
    ["ssc_lurker"]      = { raidKey = "ssc", name = "The Lurker Below",                                 default = { type = "pull" } },
    ["ssc_leotheras"]   = { raidKey = "ssc", name = "Leotheras the Blind",                              default = { type = "phase", phase = 2 }, yells = { [2] = "Now you will feel true pain" } },
    ["ssc_flk"]         = { raidKey = "ssc", name = "Fathom-Lord Karathress",                           default = { type = "hp", hp = 35 } },
    ["ssc_morogrim"]    = { raidKey = "ssc", name = "Morogrim Tidewalker",                              default = { type = "pull" } },
    ["ssc_vashj"]       = { raidKey = "ssc", name = "Lady Vashj",
        default = { type = "phase", phase = 3 },
        yells = {
            [3] = "I have waited long enough",          -- phase 3 adds
        },
    },

    -- ==================== TEMPEST KEEP (THE EYE) ====================
    ["tk_alar"]         = { raidKey = "tk", name = "Al'ar",
        default = { type = "phase", phase = 2 },
        yells = { [2] = "Burn" },                        -- phase 2 trigger
    },
    ["tk_vr"]           = { raidKey = "tk", name = "Void Reaver",                                       default = { type = "pull" } },
    ["tk_solarian"]     = { raidKey = "tk", name = "High Astromancer Solarian",                         default = { type = "hp", hp = 20 } },
    ["tk_kaelthas"]     = { raidKey = "tk", name = "Kael'thas Sunstrider",
        default = { type = "phase", phase = 5 },
        yells = {
            [5] = "Forgive me my friends",              -- phase 5 burn
        },
    },

    -- ==================== ZUL'AMAN ====================
    ["za_nalorakk"]     = { raidKey = "za", name = "Nalorakk",                                          default = { type = "pull" } },
    ["za_akilzon"]      = { raidKey = "za", name = "Akil'zon",                                          default = { type = "pull" } },
    ["za_jan"]          = { raidKey = "za", name = "Jan'alai",                                          default = { type = "hp", hp = 35 } },
    ["za_halazzi"]      = { raidKey = "za", name = "Halazzi",                                           default = { type = "phase", phase = 2 }, yells = { [2] = "Totem will crush you!" } },
    ["za_hexlord"]      = { raidKey = "za", name = "Hex Lord Malacrass",                                default = { type = "hp", hp = 40 } },
    ["za_zuljin"]       = { raidKey = "za", name = "Zul'jin",
        default = { type = "phase", phase = 5 },
        yells = {
            [2] = "Bear spirit, hear me!",
            [3] = "Eagle spirit, lend me your wings!",
            [4] = "Lynx spirit, come to me!",
            [5] = "Dragonhawk, guide my hand!",
        },
    },

    -- ==================== HYJAL SUMMIT ====================
    ["hyjal_rage"]      = { raidKey = "hyjal", name = "Rage Winterchill",                               default = { type = "pull" } },
    ["hyjal_anetheron"] = { raidKey = "hyjal", name = "Anetheron",                                      default = { type = "pull" } },
    ["hyjal_kazrogal"]  = { raidKey = "hyjal", name = "Kaz'rogal",                                      default = { type = "pull" } },
    ["hyjal_azgalor"]   = { raidKey = "hyjal", name = "Azgalor",                                        default = { type = "pull" } },
    ["hyjal_archimonde"]= { raidKey = "hyjal", name = "Archimonde",                                     default = { type = "hp", hp = 20 } },

    -- ==================== BLACK TEMPLE ====================
    ["bt_njentus"]      = { raidKey = "bt", name = "High Warlord Naj'entus",                            default = { type = "pull" } },
    ["bt_supremus"]     = { raidKey = "bt", name = "Supremus",                                          default = { type = "pull" } },
    ["bt_akama"]        = { raidKey = "bt", name = "Shade of Akama",                                    default = { type = "pull" } },
    ["bt_teron"]        = { raidKey = "bt", name = "Teron Gorefiend",                                   default = { type = "pull" } },
    ["bt_bloodboil"]    = { raidKey = "bt", name = "Gurtogg Bloodboil",                                 default = { type = "hp", hp = 25 } },
    ["bt_ros"]          = { raidKey = "bt", name = "Reliquary of Souls",                                default = { type = "phase", phase = 3 }, yells = { [3] = "I will not be denied" } },
    ["bt_mother"]       = { raidKey = "bt", name = "Mother Shahraz",                                    default = { type = "pull" } },
    ["bt_council"]      = { raidKey = "bt", name = "Illidari Council",                                  default = { type = "pull" } },
    ["bt_illidan"]      = { raidKey = "bt", name = "Illidan Stormrage",
        default = { type = "phase", phase = 5 },
        yells = {
            [2] = "Behold the flames of Azzinoth",      -- phase 2
            [3] = "I will not be touched by rabble",    -- phase 3 demon
            [4] = "You have come a long way",           -- phase 4
            [5] = "You are not prepared",               -- final phase
        },
    },

    -- ==================== SUNWELL PLATEAU ====================
    ["swp_kalecgos"]    = { raidKey = "swp", name = "Kalecgos",                                         default = { type = "pull" } },
    ["swp_brutallus"]   = { raidKey = "swp", name = "Brutallus",                                        default = { type = "pull" } },
    ["swp_felmyst"]     = { raidKey = "swp", name = "Felmyst",                                          default = { type = "phase", phase = 2 }, yells = { [2] = "Choke on your final breath" } },
    ["swp_eredar"]      = { raidKey = "swp", name = "Eredar Twins",                                     aliases = { "Grand Warlock Alythess", "Lady Sacrolash" }, default = { type = "hp", hp = 25 } },
    ["swp_muru"]        = { raidKey = "swp", name = "M'uru",                                            default = { type = "phase", phase = 2 } },
    ["swp_kiljaeden"]   = { raidKey = "swp", name = "Kil'jaeden",
        default = { type = "phase", phase = 4 },
        yells = {
            [2] = "I am the hand of Sargeras",
            [3] = "Do not hold back",
            [4] = "Unleash the fury",                    -- final burn phase
        },
    },
}

-- ============================================================================
-- Name lookup cache
-- ============================================================================

-- name_lower -> bossID (built lazily)
DB._nameIndex = nil

local function BuildNameIndex()
    local index = {}
    for id, boss in pairs(DB.BOSSES) do
        index[boss.name:lower()] = id
        if boss.aliases then
            for _, alias in ipairs(boss.aliases) do
                index[alias:lower()] = id
            end
        end
    end
    DB._nameIndex = index
end

-- Returns the bossID for a given unit name string, or nil.
function DB:LookupByName(unitName)
    if not unitName then return nil end
    if not DB._nameIndex then BuildNameIndex() end
    return DB._nameIndex[unitName:lower()]
end

-- Returns the boss entry table for an ID.
function DB:Get(id)
    return DB.BOSSES[id]
end

-- Returns the effective trigger config for a boss (user override merged on top
-- of the database default).
function DB:GetTriggerConfig(id)
    local boss = DB.BOSSES[id]
    if not boss then return nil end

    local override = HH.chardb and HH.chardb.bosses and HH.chardb.bosses[id]
    if override and override.enabled == false then
        return nil -- explicitly disabled
    end

    local cfg = {}
    for k, v in pairs(boss.default) do cfg[k] = v end
    if override then
        if override.type  then cfg.type  = override.type  end
        if override.hp    then cfg.hp    = override.hp    end
        if override.phase then cfg.phase = override.phase end
    end
    return cfg
end

-- Iterator over all bosses in a raid, sorted by declaration order.
function DB:IterRaid(raidKey)
    local list = {}
    for id, boss in pairs(DB.BOSSES) do
        if boss.raidKey == raidKey then
            table.insert(list, { id = id, boss = boss })
        end
    end
    table.sort(list, function(a, b) return a.boss.name < b.boss.name end)
    local i = 0
    return function()
        i = i + 1
        if list[i] then return list[i].id, list[i].boss end
    end
end

-- Debug: total boss count
function DB:Count()
    local n = 0
    for _ in pairs(DB.BOSSES) do n = n + 1 end
    return n
end

function DB:Initialize()
    BuildNameIndex()
    HH:Debug("Database loaded: " .. DB:Count() .. " bosses across " .. #DB.RAIDS .. " raids")
    return true
end

-- ============================================================================
-- Import / Export
-- ============================================================================
--
-- Serialization format v1:
--
--     HH1|<bossID>=<spec>|<bossID>=<spec>|...
--
-- <spec> is one of:
--     pull         -> trigger on pull
--     hp:<N>       -> trigger at HP% <= N
--     phase:<N>    -> trigger on phase >= N
--     off          -> disabled for this boss
--
-- The format is intentionally plain text, no base64, no Lua code — so it is
-- safe to `loadstring`-free parse, safe to paste into chat, and easy to read
-- by a human. Missing boss IDs fall back to the database default on import.
-- Unknown boss IDs are ignored (forward/backward compatibility).

local EXPORT_VERSION = "HH1"

function DB:ExportOverrides()
    local parts = { EXPORT_VERSION }
    -- Emit in a stable alphabetical order so two exports of the same config
    -- produce identical strings.
    local ids = {}
    for id in pairs(HH.chardb.bosses or {}) do table.insert(ids, id) end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local o = HH.chardb.bosses[id]
        if o and DB.BOSSES[id] then
            local spec
            if o.enabled == false then
                spec = "off"
            elseif o.type == "hp" and o.hp then
                spec = "hp:" .. tostring(o.hp)
            elseif o.type == "phase" and o.phase then
                spec = "phase:" .. tostring(o.phase)
            elseif o.type == "pull" then
                spec = "pull"
            end
            if spec then
                table.insert(parts, id .. "=" .. spec)
            end
        end
    end

    return table.concat(parts, "|")
end

-- Parses a HH1|... string. Returns (ok, applied, skipped, err). On success,
-- overrides are written into HH.chardb.bosses (existing entries for unknown
-- IDs are preserved; entries for known IDs are replaced).
function DB:ImportOverrides(str)
    if type(str) ~= "string" then return false, 0, 0, "not a string" end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")

    local version, rest = str:match("^(HH%d+)|(.*)$")
    if not version then
        -- Also accept a bare version string with no entries (valid empty import)
        if str == EXPORT_VERSION then return true, 0, 0, nil end
        return false, 0, 0, "missing or invalid version prefix (expected HH1|...)"
    end
    if version ~= EXPORT_VERSION then
        return false, 0, 0, "unsupported format version: " .. version
    end

    HH.chardb.bosses = HH.chardb.bosses or {}

    local applied, skipped = 0, 0
    for entry in (rest .. "|"):gmatch("([^|]+)|") do
        local id, spec = entry:match("^([^=]+)=(.*)$")
        if id and spec and DB.BOSSES[id] then
            local o = { enabled = true }
            if spec == "pull" then
                o.type = "pull"
            elseif spec == "off" then
                o.enabled = false
            else
                local kind, val = spec:match("^(%a+):(%d+)$")
                if kind == "hp" then
                    o.type = "hp"
                    o.hp   = math.max(1, math.min(99, tonumber(val) or 35))
                elseif kind == "phase" then
                    o.type = "phase"
                    o.phase = math.max(1, math.min(10, tonumber(val) or 2))
                else
                    o = nil
                end
            end
            if o then
                HH.chardb.bosses[id] = o
                applied = applied + 1
            else
                skipped = skipped + 1
            end
        elseif id then
            skipped = skipped + 1
        end
    end

    return true, applied, skipped, nil
end
