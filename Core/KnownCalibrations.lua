---------------------------------------------------------------------------------------
--  Core/KnownCalibrations.lua — measurements shipped with SteadyCam
---------------------------------------------------------------------------------------
--  Results depend only on the game (race + sex model × mount model), never on how a
--  player frames the camera (horizontal or vertical) and not on the zoom (KNOWLEDGE.md
--  §4, §7b). Measured 2026-10-02/03 on every playable race and sex (worgen and dracthyr
--  in both forms; Earthen missing) with the Kor'kron War Saber, dip gains measured with
--  the plan itself:
--    * the size factor changes with the race (mechagnome F 0.90 … dracthyr 1.56 × the
--      gnome's) by about the same factor on every mount → RaceFactor(key);
--    * the dip gain is DIP_PER_RATIO × size factor: 0.092–0.103, median 0.099 over 52
--      race/sex/form calibrations — except mounts that hide your character (Obsidian
--      Nightwing: 1.0, "fixedDip").
--  Your own calibration always wins over these.
--    [modelKey] = { [mountID] = { ratio = size factor, dipGain = h (optional),
--                                 fixedDip = h doesn't scale with the race (optional) } }
---------------------------------------------------------------------------------------
local _, PC = ...

PC.KnownCalibrations = {
  ["BloodElf-F"] = {
    [2198] = { ratio = 3.180, dipGain = 0.318 }, -- Sable de guerra Kor'kron
  },
  ["BloodElf-M"] = {
    [2198] = { ratio = 3.318, dipGain = 0.318 }, -- Sable de guerra Kor'kron
  },
  ["DarkIronDwarf-F"] = {
    [2198] = { ratio = 3.081, dipGain = 0.299 }, -- Sable de guerra Kor'kron
  },
  ["DarkIronDwarf-M"] = {
    [2198] = { ratio = 3.869, dipGain = 0.384 }, -- Sable de guerra Kor'kron
  },
  ["Dracthyr-F"] = {
    [2198] = { ratio = 5.235, dipGain = 0.522 }, -- Sable de guerra Kor'kron
  },
  ["Dracthyr-F-Alt"] = {
    [2198] = { ratio = 3.115, dipGain = 0.300 }, -- Sable de guerra Kor'kron
  },
  ["Dracthyr-M"] = {
    [2198] = { ratio = 5.212, dipGain = 0.530 }, -- Sable de guerra Kor'kron
  },
  ["Dracthyr-M-Alt"] = {
    [18] = { ratio = 5.800 }, -- Yegua zaina
    [2198] = { ratio = 3.316, dipGain = 0.330 }, -- Sable de guerra Kor'kron
    [2238] = { ratio = 2.593 }, -- Crocolisco dorado de Adalid del Botín
  },
  ["Draenei-F"] = {
    [2198] = { ratio = 3.526, dipGain = 0.351 }, -- Sable de guerra Kor'kron
  },
  ["Draenei-M"] = {
    [2198] = { ratio = 4.645, dipGain = 0.463 }, -- Sable de guerra Kor'kron
  },
  ["Dwarf-F"] = {
    [2198] = { ratio = 3.123, dipGain = 0.302 }, -- Sable de guerra Kor'kron
  },
  ["Dwarf-M"] = {
    [2198] = { ratio = 3.819, dipGain = 0.379 }, -- Sable de guerra Kor'kron
  },
  ["Gnome-F"] = {
    [2198] = { ratio = 3.168, dipGain = 0.293 }, -- Sable de guerra Kor'kron
  },
  ["Gnome-M"] = {
    [18] = { ratio = 5.740 }, -- Yegua zaina
    [26] = { ratio = 3.992 }, -- Sable de hielo rayado
    [34] = { ratio = 4.001 }, -- Sable de la noche rayado
    [129] = { ratio = 4.235 }, -- Grifo dorado
    [403] = { ratio = 3.863 }, -- Rey dorado
    [1773] = { ratio = 3.600 }, -- Grifo del puerto
    [2198] = { ratio = 3.355, dipGain = 0.323 }, -- Sable de guerra Kor'kron
  },
  ["Goblin-F"] = {
    [2198] = { ratio = 3.464, dipGain = 0.335 }, -- Sable de guerra Kor'kron
  },
  ["Goblin-M"] = {
    [2198] = { ratio = 3.473, dipGain = 0.344 }, -- Sable de guerra Kor'kron
  },
  ["Harronir-F"] = {
    [2198] = { ratio = 3.562, dipGain = 0.348 }, -- Sable de guerra Kor'kron
  },
  ["Harronir-M"] = {
    [2198] = { ratio = 3.989, dipGain = 0.396 }, -- Sable de guerra Kor'kron
  },
  ["HighmountainTauren-F"] = {
    [2198] = { ratio = 4.036, dipGain = 0.401 }, -- Sable de guerra Kor'kron
  },
  ["HighmountainTauren-M"] = {
    [455] = { ratio = 6.919, dipGain = 1.032, fixedDip = true }, -- Alanoche obsidiana
    [466] = { ratio = 1.568 }, -- Dragón nimbo de jade tronador
    [762] = { ratio = 3.974, dipGain = 0.356 }, -- Gronnito puñocarbón
    [1360] = { ratio = 6.628 }, -- Corredor Nieblabrillante
    [2198] = { ratio = 4.800, dipGain = 0.485 }, -- Sable de guerra Kor'kron
    [2754] = { ratio = 2.061 }, -- Dracohalcón peridoto
  },
  ["Human-F"] = {
    [2198] = { ratio = 3.083, dipGain = 0.308 }, -- Sable de guerra Kor'kron
  },
  ["Human-M"] = {
    [2198] = { ratio = 3.581, dipGain = 0.354 }, -- Sable de guerra Kor'kron
  },
  ["KulTiran-F"] = {
    [2198] = { ratio = 3.731, dipGain = 0.370 }, -- Sable de guerra Kor'kron
  },
  ["KulTiran-M"] = {
    [2198] = { ratio = 3.931, dipGain = 0.397 }, -- Sable de guerra Kor'kron
  },
  ["LightforgedDraenei-F"] = {
    [2198] = { ratio = 3.494, dipGain = 0.344 }, -- Sable de guerra Kor'kron
  },
  ["LightforgedDraenei-M"] = {
    [2198] = { ratio = 4.682, dipGain = 0.464 }, -- Sable de guerra Kor'kron
  },
  ["Mechagnome-F"] = {
    [2198] = { ratio = 3.033, dipGain = 0.292 }, -- Sable de guerra Kor'kron
  },
  ["Mechagnome-M"] = {
    [2198] = { ratio = 3.120, dipGain = 0.300 }, -- Sable de guerra Kor'kron
  },
  ["NightElf-F"] = {
    [2198] = { ratio = 3.274, dipGain = 0.320 }, -- Sable de guerra Kor'kron
  },
  ["NightElf-M"] = {
    [2198] = { ratio = 3.746, dipGain = 0.372 }, -- Sable de guerra Kor'kron
  },
  ["Nightborne-F"] = {
    [2198] = { ratio = 3.567, dipGain = 0.351 }, -- Sable de guerra Kor'kron
  },
  ["Nightborne-M"] = {
    [2198] = { ratio = 3.749, dipGain = 0.370 }, -- Sable de guerra Kor'kron
  },
  ["Orc-F"] = {
    [2198] = { ratio = 3.602, dipGain = 0.360 }, -- Sable de guerra Kor'kron
  },
  ["Orc-M"] = {
    [2198] = { ratio = 4.619, dipGain = 0.459 }, -- Sable de guerra Kor'kron
  },
  ["Pandaren-F"] = {
    [2198] = { ratio = 4.182, dipGain = 0.406 }, -- Sable de guerra Kor'kron
  },
  ["Pandaren-M"] = {
    [403] = { ratio = 4.360 }, -- Rey dorado
    [1283] = { ratio = 6.965 }, -- Mecazancudo de Mecandria
    [2198] = { ratio = 3.992, dipGain = 0.398 }, -- Sable de guerra Kor'kron
  },
  ["Scourge-F"] = {
    [2198] = { ratio = 3.355, dipGain = 0.330 }, -- Sable de guerra Kor'kron
  },
  ["Scourge-M"] = {
    [2198] = { ratio = 3.669, dipGain = 0.366 }, -- Sable de guerra Kor'kron
  },
  ["Tauren-F"] = {
    [2198] = { ratio = 4.031, dipGain = 0.413 }, -- Sable de guerra Kor'kron
  },
  ["Tauren-M"] = {
    [2198] = { ratio = 4.703, dipGain = 0.458 }, -- Sable de guerra Kor'kron
  },
  ["Troll-F"] = {
    [2198] = { ratio = 3.615, dipGain = 0.360 }, -- Sable de guerra Kor'kron
  },
  ["Troll-M"] = {
    [2198] = { ratio = 4.618, dipGain = 0.463 }, -- Sable de guerra Kor'kron
  },
  ["VoidElf-F"] = {
    [2198] = { ratio = 3.176, dipGain = 0.311 }, -- Sable de guerra Kor'kron
  },
  ["VoidElf-M"] = {
    [2198] = { ratio = 3.299, dipGain = 0.321 }, -- Sable de guerra Kor'kron
  },
  ["Vulpera-F"] = {
    [2198] = { ratio = 3.662, dipGain = 0.343 }, -- Sable de guerra Kor'kron
  },
  ["Vulpera-M"] = {
    [2198] = { ratio = 3.682, dipGain = 0.359 }, -- Sable de guerra Kor'kron
  },
  ["Worgen-F"] = {
    [2198] = { ratio = 3.805, dipGain = 0.380 }, -- Sable de guerra Kor'kron
  },
  ["Worgen-F-Alt"] = {
    [2198] = { ratio = 3.093, dipGain = 0.309 }, -- Sable de guerra Kor'kron
  },
  ["Worgen-M"] = {
    [2198] = { ratio = 4.870, dipGain = 0.485 }, -- Sable de guerra Kor'kron
  },
  ["Worgen-M-Alt"] = {
    [2198] = { ratio = 3.624, dipGain = 0.356 }, -- Sable de guerra Kor'kron
  },
  ["ZandalariTroll-F"] = {
    [2198] = { ratio = 4.164, dipGain = 0.413 }, -- Sable de guerra Kor'kron
  },
  ["ZandalariTroll-M"] = {
    [2198] = { ratio = 3.739, dipGain = 0.370 }, -- Sable de guerra Kor'kron
    [2329] = { ratio = 4.786 }, -- Barredor de Lunargenta
  },
}

PC.DIP_PER_RATIO = 0.099

-- Races that use another race's character models (same files, other textures).
PC.RaceAliases = {
  ["MagharOrc-M"] = "Orc-M",
  ["MagharOrc-F"] = "Orc-F",
}

local BASE, REFERENCE = "Gnome-M", 2198 -- the race every factor is relative to, and the mount

--- Shipped values for a race + sex and a mount (or one with the same model), or nil.
function PC.KnownFor(key, mountID)
  local known = PC.KnownCalibrations[key] or PC.KnownCalibrations[PC.RaceAliases[key] or ""]
  if not known or type(mountID) ~= "number" then
    return nil
  end
  if known[mountID] then
    return known[mountID]
  end
  for _, other in ipairs(PC.MountFamily(mountID)) do
    if known[other] then
      return known[other]
    end
  end
  return nil
end

local factors -- [key] = size factor relative to the gnome, built on first use

local function BuildFactors()
  factors = {}
  local base = PC.KnownFor(BASE, REFERENCE)
  local list = {}
  for key in pairs(PC.KnownCalibrations) do
    local own = PC.KnownFor(key, REFERENCE)
    if base and own then
      factors[key] = own.ratio / base.ratio
      list[#list + 1] = factors[key]
    end
  end
  table.sort(list)
  factors.median = list[math.floor((#list + 1) / 2)] or 1
end

--- How much bigger this race + sex's size factors are than the gnome's; second value
--- false when the race wasn't measured (the median of the measured races is returned).
function PC.RaceFactor(key)
  if not factors then
    BuildFactors()
  end
  if factors[key] then
    return factors[key], true
  end
  local alias = PC.RaceAliases[key]
  if alias and factors[alias] then
    return factors[alias], true
  end
  return factors.median, false
end

--- Shipped values for this race + sex and a mount: measured on it ("builtin"), or
--- measured on another race (the gnome first) and scaled by the two races' factors
--- ("scaled"). nil if no race measured that mount or its family.
function PC.KnownScaled(key, mountID)
  local exact = PC.KnownFor(key, mountID)
  if exact then
    return exact, "builtin"
  end
  local fromKey, from = BASE, PC.KnownFor(BASE, mountID)
  if not from then
    local keys = {}
    for k in pairs(PC.KnownCalibrations) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      from = PC.KnownFor(k, mountID)
      if from then
        fromKey = k
        break
      end
    end
  end
  if not from then
    return nil
  end
  local scale = PC.RaceFactor(key) / PC.RaceFactor(fromKey)
  local dip = from.dipGain and (from.fixedDip and from.dipGain or from.dipGain * scale)
  return { ratio = from.ratio * scale, dipGain = dip, fixedDip = from.fixedDip }, "scaled"
end

PC.KNOWN_BASE = BASE

--- Rebuild the race factors (tests swap the table).
function PC.ResetKnownFactors()
  factors = nil
end
