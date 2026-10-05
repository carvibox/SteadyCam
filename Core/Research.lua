---------------------------------------------------------------------------------------
--  Core/Research.lua — data collection across races (research mode, off by default)
---------------------------------------------------------------------------------------
--  Hypothesis (KNOWLEDGE.md §7b): the size factor and dip gain depend on the mount model,
--  not on the race — except races the game gives bigger mounts (tauren, pandaren, kul
--  tiran, dracthyr...). To check it and fill Core/KnownCalibrations.lua, every race on
--  TARGETS calibrates the same reference mount: one usable by both factions. With
--  research mode on, each login says in chat whether this character's race still needs
--  it, with a link that starts a quick calibration (6 steps).
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_MountJournal = _G.C_MountJournal

local R = {}
PC.Research = R

-- Every playable race and sex (game tables, 12.1); worgen and dracthyr in both forms
-- ("-Alt"). Mag'har orcs use the orc models, so they count as measured with the orc
-- (PC.RaceAliases). A death knight can ride from level 1, so any race can be measured.
R.TARGETS = {
  "Human-M", "Human-F",
  "Orc-M", "Orc-F",
  "Dwarf-M", "Dwarf-F",
  "NightElf-M", "NightElf-F",
  "Scourge-M", "Scourge-F",
  "Tauren-M", "Tauren-F",
  "Gnome-M", "Gnome-F",
  "Troll-M", "Troll-F",
  "Goblin-M", "Goblin-F",
  "BloodElf-M", "BloodElf-F",
  "Draenei-M", "Draenei-F",
  "Worgen-M", "Worgen-F", "Worgen-M-Alt", "Worgen-F-Alt",
  "Pandaren-M", "Pandaren-F",
  "Nightborne-M", "Nightborne-F",
  "HighmountainTauren-M", "HighmountainTauren-F",
  "VoidElf-M", "VoidElf-F",
  "LightforgedDraenei-M", "LightforgedDraenei-F",
  "ZandalariTroll-M", "ZandalariTroll-F",
  "KulTiran-M", "KulTiran-F",
  "DarkIronDwarf-M", "DarkIronDwarf-F",
  "Vulpera-M", "Vulpera-F",
  "Mechagnome-M", "Mechagnome-F",
  "Dracthyr-M", "Dracthyr-F", "Dracthyr-M-Alt", "Dracthyr-F-Alt",
  "EarthenDwarf-M", "EarthenDwarf-F",
  "Harronir-M", "Harronir-F",
}

local LINK = "|Haddon:steadycam:research:%d|h|cff69ccf0[%s]|r|h"

local raceNames -- [race file] = name in the client's language

local function RaceName(file)
  if not raceNames then
    raceNames = {}
    local get = _G.C_CreatureInfo and _G.C_CreatureInfo.GetRaceInfo
    for id = 1, 120 do
      local ok, info = pcall(get or error, id)
      if ok and type(info) == "table" and info.clientFileString and not raceNames[info.clientFileString] then
        raceNames[info.clientFileString] = info.raceName
      end
    end
  end
  return raceNames[file] or file
end

local function Label(key)
  local race, sex, alt = key:match("^(.-)%-(%a)(%-?A?l?t?)$")
  return string.format("%s (%s%s)", RaceName(race or key), sex == "F" and PC.L.SEX_F or PC.L.SEX_M,
    alt == "-Alt" and (", " .. PC.L.FORM_ALT) or "")
end

local function Usable(mountID)
  local _, _, _, _, isUsable, _, _, isFactionSpecific, _, hideOnChar, isCollected =
    C_MountJournal.GetMountInfoByID(mountID)
  return isCollected and not hideOnChar and not isFactionSpecific, isUsable
end

--- The reference mount: chosen once (both factions, collected), then kept.
function R.ReferenceMount()
  local store = PC.db.research
  if store.mountID and Usable(store.mountID) then
    return store.mountID
  end
  local best, bestScore
  for _, id in ipairs(C_MountJournal.GetMountIDs()) do
    local ok, usableHere = Usable(id)
    if ok then
      local score = (PC.db.mountUse[id] or 0) * 10 + (usableHere and 5 or 0)
      if not bestScore or score > bestScore then
        best, bestScore = id, score
      end
    end
  end
  store.mountID = best
  return best
end

--- true if `key` (or the race it shares models with) has measured the reference mount
--- (or one with the same model) with the plan itself (v0.8.5+: `stepGains`). Older
--- calibrations and the shipped table don't count: their dip gains came from curve fits.
function R.IsMeasured(key, mountID)
  local alias = PC.RaceAliases[key]
  if alias and alias ~= key and R.IsMeasured(alias, mountID) then
    return true
  end
  local model = PC.db.models[key]
  local mounts = model and model.mounts
  if not mounts or not mountID then
    return false
  end
  local function Measured(id)
    local m = mounts[id]
    return m and m.captures and #m.captures > 0 and m.stepGains and #m.stepGains > 0
  end
  if Measured(mountID) then
    return true
  end
  for _, id in ipairs(PC.MountFamily(mountID)) do
    if Measured(id) then
      return true
    end
  end
  return false
end

local function Pending(mountID)
  local list = {}
  for _, key in ipairs(R.TARGETS) do
    if not R.IsMeasured(key, mountID) then
      list[#list + 1] = Label(key)
    end
  end
  return list
end

---------------------------------------------------------------------------------------
-- Mount research: once this race is measured, offer your mounts whose model no race has
-- measured yet (shipped data or anyone's calibration), favorites and most ridden first.
-- Any race works: values are scaled to every other race (Core/KnownCalibrations.lua).
---------------------------------------------------------------------------------------
local function Members(mountID)
  local family = PC.MountFamily(mountID)
  return #family > 0 and family or { mountID }
end

--- true if any race has a calibration of this mount's model, or SteadyCam ships one.
function R.MountCovered(mountID)
  for _, model in pairs(PC.db.models) do
    for _, id in ipairs(Members(mountID)) do
      local m = model.mounts and model.mounts[id]
      if m and (m.unmeasurable or (m.captures and #m.captures > 0)) then
        return true
      end
    end
  end
  for key in pairs(PC.KnownCalibrations) do
    if PC.KnownFor(key, mountID) then
      return true
    end
  end
  return false
end

--- Your mount models: how many are covered, and the next one to measure here (usable).
function R.MountProgress()
  local seen, total, covered, candidates = {}, 0, 0, {}
  for _, id in ipairs(C_MountJournal.GetMountIDs()) do
    local name, _, _, _, isUsable, _, isFavorite, _, _, hideOnChar, isCollected =
      C_MountJournal.GetMountInfoByID(id)
    if isCollected and not hideOnChar then
      local family = Members(id)[1]
      if not seen[family] then
        seen[family] = true
        total = total + 1
        if R.MountCovered(id) then
          covered = covered + 1
        elseif isUsable then
          candidates[#candidates + 1] = {
            id = id,
            name = name,
            favorite = isFavorite and true or false,
            uses = PC.db.mountUse[id] or 0,
          }
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.favorite ~= b.favorite then
      return a.favorite
    end
    if a.uses ~= b.uses then
      return a.uses > b.uses
    end
    return (a.name or "") < (b.name or "")
  end)
  return covered, total, candidates[1]
end

local function AnnounceMounts()
  local L = PC.L
  local covered, total, nextMount = R.MountProgress()
  if nextMount then
    PC.Print(string.format(L.RESEARCH_MOUNTS_NEXT, covered, total, tostring(nextMount.name),
      string.format(LINK, nextMount.id, L.RESEARCH_LINK)))
  elseif covered < total then
    PC.Print(string.format(L.RESEARCH_MOUNTS_ELSEWHERE, covered, total))
  else
    PC.Print(string.format(L.RESEARCH_MOUNTS_DONE, total))
  end
end

--- Chat status for this character (login, after a calibration).
function R.Announce()
  if not PC.db.settings.research then
    return
  end
  local L = PC.L
  local mountID = R.ReferenceMount()
  if not mountID then
    PC.Print(L.RESEARCH_NOMOUNT)
    return
  end
  local key = PC.GetModelKey()
  local onList = false
  for _, k in ipairs(R.TARGETS) do
    onList = onList or k == key
  end
  local mountName = PC.GetMountName(mountID) or "?"
  if onList and not R.IsMeasured(key, mountID) then
    PC.Print(string.format(L.RESEARCH_TODO, Label(key), mountName, string.format(LINK, mountID, L.RESEARCH_LINK)))
  elseif onList then
    PC.Print(string.format(L.RESEARCH_DONE_HERE, Label(key)))
  else
    PC.Print(string.format(L.RESEARCH_OFFLIST, Label(key)))
  end
  if onList and R.IsMeasured(key, mountID) or not onList then
    AnnounceMounts()
  end
  local pending = Pending(mountID)
  if #pending == 0 then
    PC.Print(L.RESEARCH_ALL_DONE)
  else
    local shown = {}
    for i = 1, math.min(#pending, 6) do
      shown[i] = pending[i]
    end
    local list = table.concat(shown, ", ") .. (#pending > #shown and ", ..." or "")
    PC.Print(string.format(L.RESEARCH_PROGRESS, #R.TARGETS - #pending, #R.TARGETS, mountName, list))
  end
end

PC.On("CALIBRATION_UPDATED", function()
  R.Announce()
end)

-- Once per login or /reload, after the chat has settled.
local login = _G.CreateFrame("Frame")
login:RegisterEvent("PLAYER_ENTERING_WORLD")
login:SetScript("OnEvent", function(_, _, isLogin, isReload)
  if isLogin or isReload then
    _G.C_Timer.After(6, R.Announce)
  end
end)
