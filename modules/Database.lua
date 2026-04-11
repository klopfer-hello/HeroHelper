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
    -- Curator Evocates at 20% HP for ~20s, during which the raid freecasts.
    -- Popping BL just as Evocation starts lines the 30s haste window up with
    -- the biggest uninterrupted DPS window of the fight and kills him before
    -- his post-Evocate enrage matters.
    ["kara_curator"]    = { raidKey = "kara", name = "The Curator",                                     default = { type = "hp", hp = 20 } },
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
    -- Morogrim spawns murloc adds at 50% and 25%. Popping BL at 25% after
    -- the second wave is handled lets the raid burn him down before another
    -- add set spawns.
    ["ssc_morogrim"]    = { raidKey = "ssc", name = "Morogrim Tidewalker",                              default = { type = "hp", hp = 25 } },
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
    -- Hex Lord's abilities (Spirit Bolts, Drain Power) only get nastier as
    -- the fight drags on. Pulling with BL skips an entire Spirit Bolts cycle
    -- and is the standard community call for the timed-chest run.
    ["za_hexlord"]      = { raidKey = "za", name = "Hex Lord Malacrass",                                default = { type = "pull" } },
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
    -- The Shade is unattackable for most of the fight while channeling.
    -- Once freed by Akama it becomes active and drops fast — hp 35 lines
    -- up with the burn window after it first takes damage so the reminder
    -- fires during the actual DPS phase rather than the channeling setup.
    ["bt_akama"]        = { raidKey = "bt", name = "Shade of Akama",                                    default = { type = "hp", hp = 35 } },
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
-- Import / Export  (hash format)
-- ============================================================================
--
-- Wire format:
--
--     HH!<base64 payload>
--
-- The base64 payload decodes to plaintext:
--
--     HH2|<bossID>=<spec>|<bossID>=<spec>|...
--
-- Differences from the legacy HH1 plaintext format:
--   * HH2 emits **every boss in the database**, not just the user's
--     overrides. This makes the hash a complete snapshot: importing it
--     reproduces the sender's effective config exactly, regardless of how
--     the receiver's addon defaults happen to be tuned.
--   * The plaintext is wrapped in base64 and prefixed with `HH!` so the
--     final string is a short opaque "hash" that's safe to paste anywhere
--     and visually distinct from ordinary chat text.
--
-- <spec> is one of:
--     pull         -> trigger on pull
--     hp:<N>       -> trigger at HP% <= N
--     phase:<N>    -> trigger on phase >= N
--     off          -> disabled for this boss
--
-- Backward compatibility: ImportHash also accepts a bare `HH1|...` or
-- `HH2|...` plaintext string (no HH!/base64 wrapper), so strings produced
-- by earlier builds keep working.

local EXPORT_VERSION = "HH2"
local HASH_PREFIX    = "HH!"

-- -- Base64 ------------------------------------------------------------------
--
-- Tiny pure-Lua base64 so we don't drag in LibCompress. The payload is a
-- few hundred bytes at most, so math-based bit slicing is perfectly fast.

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64_CHARS do B64_INDEX[B64_CHARS:sub(i, i)] = i - 1 end

local function Base64Encode(str)
    local out = {}
    local len = #str
    local i   = 1
    while i <= len do
        local a = str:byte(i)     or 0
        local b = str:byte(i + 1) or 0
        local c = str:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        local c1 = math.floor(n / 262144)
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64)   % 64
        local c4 = n % 64
        out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
        if i + 1 <= len then
            out[#out + 1] = B64_CHARS:sub(c3 + 1, c3 + 1)
        else
            out[#out + 1] = "="
        end
        if i + 2 <= len then
            out[#out + 1] = B64_CHARS:sub(c4 + 1, c4 + 1)
        else
            out[#out + 1] = "="
        end
        i = i + 3
    end
    return table.concat(out)
end

local function Base64Decode(str)
    str = str:gsub("%s+", "")
    str = str:gsub("=+$", "")
    local out = {}
    local len = #str
    local i   = 1
    while i <= len do
        local a = B64_INDEX[str:sub(i,     i)]
        local b = B64_INDEX[str:sub(i + 1, i + 1)]
        local c = B64_INDEX[str:sub(i + 2, i + 2)]
        local d = B64_INDEX[str:sub(i + 3, i + 3)]
        if not a or not b then return nil, "invalid base64 character" end
        local n = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        out[#out + 1] = string.char(math.floor(n / 65536))
        if c then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if d then out[#out + 1] = string.char(n % 256) end
        i = i + 4
    end
    return table.concat(out)
end

-- -- Spec encoding -----------------------------------------------------------

local function EncodeSpec(cfg, enabled)
    if enabled == false then return "off" end
    if cfg.type == "pull"  then return "pull" end
    if cfg.type == "hp"    and cfg.hp    then return "hp:"    .. tostring(cfg.hp)    end
    if cfg.type == "phase" and cfg.phase then return "phase:" .. tostring(cfg.phase) end
    return nil
end

-- Parses the payload after the `HHn|` header and writes entries into
-- HH.chardb.bosses. Returns (applied, skipped). Used by both HH1 and HH2.
local function ParseEntries(rest)
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
                    o.type  = "phase"
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
    return applied, skipped
end

-- -- Public API --------------------------------------------------------------

-- Builds a full snapshot of the player's effective per-boss configuration
-- and returns it wrapped as an opaque hash string.
function DB:ExportHash()
    local ids = {}
    for id in pairs(DB.BOSSES) do table.insert(ids, id) end
    table.sort(ids)

    local parts = { EXPORT_VERSION }
    for _, id in ipairs(ids) do
        local boss     = DB.BOSSES[id]
        local override = HH.chardb and HH.chardb.bosses and HH.chardb.bosses[id]

        -- Merge override on top of the database default, exactly the same
        -- way GetTriggerConfig does it.
        local cfg = {}
        for k, v in pairs(boss.default) do cfg[k] = v end
        if override then
            if override.type  then cfg.type  = override.type  end
            if override.hp    then cfg.hp    = override.hp    end
            if override.phase then cfg.phase = override.phase end
        end
        local enabled = not (override and override.enabled == false)

        local spec = EncodeSpec(cfg, enabled)
        if spec then
            parts[#parts + 1] = id .. "=" .. spec
        end
    end

    local plain = table.concat(parts, "|")
    return HASH_PREFIX .. Base64Encode(plain)
end

-- Parses an export hash. Returns (ok, applied, skipped, err). On success,
-- entries are written into HH.chardb.bosses — existing entries for boss IDs
-- not present in the hash are left untouched; entries for IDs in the hash
-- are replaced.
--
-- Accepts:
--   * HH!<base64> (new format)
--   * HH2|... plaintext (same payload, unwrapped)
--   * HH1|... plaintext (legacy overrides-only format)
function DB:ImportHash(str)
    if type(str) ~= "string" then return false, 0, 0, "not a string" end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str == "" then return false, 0, 0, "empty input" end

    -- Unwrap the HH!<base64> envelope if present.
    local plain = str
    if str:sub(1, #HASH_PREFIX) == HASH_PREFIX then
        local decoded, err = Base64Decode(str:sub(#HASH_PREFIX + 1))
        if not decoded then
            return false, 0, 0, "invalid hash: " .. tostring(err)
        end
        plain = decoded
    end

    local version, rest = plain:match("^(HH%d+)|(.*)$")
    if not version then
        -- Allow a bare version marker (empty but valid).
        if plain == "HH1" or plain == "HH2" then
            return true, 0, 0, nil
        end
        return false, 0, 0, "missing or invalid version (expected HH!<hash>)"
    end
    if version ~= "HH1" and version ~= "HH2" then
        return false, 0, 0, "unsupported format version: " .. version
    end

    local applied, skipped = ParseEntries(rest)
    return true, applied, skipped, nil
end

-- Legacy aliases — kept so any external caller still using the pre-hash
-- names continues to work.
DB.ExportOverrides = DB.ExportHash
DB.ImportOverrides = DB.ImportHash
