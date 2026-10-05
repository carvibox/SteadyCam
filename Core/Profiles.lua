---------------------------------------------------------------------------------------
--  Core/Profiles.lua — which calibration applies to a mount
---------------------------------------------------------------------------------------
--  Size factor (on-foot / mounted gain) for a mount (KNOWLEDGE.md §6):
--    1. that mount's own calibration for this race + sex
--    2. a calibrated mount with the same model and scale ("family", MountFamilies.lua)
--    3. SteadyCam's shipped measurement for this race + sex and mount or its family
--       ("builtin", Core/KnownCalibrations.lua)
--    4. otherwise every calibrated mount of this race + sex pooled together ("average";
--       the shipped ones when you have none)
--    5. otherwise the built-in reference (Core/ReferenceData.lua)
--  Dip gain h: how much of the mounted gain is left while the game already shows you on
--  foot but still uses the mounted camera (a dismount made the usual way, before the
--  server confirms it). Own value → family → shipped (measured or scaled) → estimated
--  from the size factor (h ≈ 0.099 × ratio, Core/KnownCalibrations.lua).
---------------------------------------------------------------------------------------
local _, PC = ...

local P = {}
PC.Profiles = P

local DIP_KEEP = 12 -- measurements kept per mount

local function Median(list)
  local copy = {}
  for i, v in ipairs(list) do
    copy[i] = v
  end
  table.sort(copy)
  local n = #copy
  if n == 0 then
    return nil
  end
  if n % 2 == 1 then
    return copy[(n + 1) / 2]
  end
  return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

local function MeanRatio(m)
  return m.ratio or PC.Analysis.MeanRatio(m.captures)
end

local function Calibrated(m)
  return m and not m.unmeasurable and m.captures and #m.captures > 0
end

--- The calibration that covers a mount: its own ("mount") or a same-model one
--- ("family", plus that mount's entry). nil if neither.
local function OwnOrFamily(mountID)
  if type(mountID) ~= "number" then
    return nil
  end
  local mounts = PC.GetModelStore().mounts
  if Calibrated(mounts[mountID]) then
    return mounts[mountID], "mount"
  end
  for _, other in ipairs(PC.MountFamily(mountID)) do
    if other ~= mountID and Calibrated(mounts[other]) then
      return mounts[other], "family"
    end
  end
  return nil
end

--- Shipped values for this race + sex: measured on it ("builtin"), or the gnome's
--- measurement of the mount (or its family) scaled by this race's factor ("scaled").
local function Builtin(mountID)
  return PC.KnownScaled(PC.GetModelKey(), mountID)
end

--- true if the mount (or one with the same model) has your calibration or shipped
--- values for this race + sex — or was tried and can't be measured (no more chat links).
function P.IsCalibrated(mountID)
  local m = type(mountID) == "number" and PC.GetModelStore().mounts[mountID]
  return OwnOrFamily(mountID) ~= nil or Builtin(mountID) ~= nil or (m and m.unmeasurable) or false
end

--- Size factors measured by tests on a mount that was never calibrated (or its family).
local function TestRatio(mountID)
  if type(mountID) ~= "number" then
    return nil
  end
  local mounts = PC.GetModelStore().mounts
  local own = mounts[mountID]
  if own and own.testRatios and #own.testRatios > 0 then
    return Median(own.testRatios), own
  end
  for _, other in ipairs(PC.MountFamily(mountID)) do
    local m = mounts[other]
    if m and m.testRatios and #m.testRatios > 0 then
      return Median(m.testRatios), m
    end
  end
  return nil
end

local sizeK -- cached size constant (see SizeK below); cleared when new data arrives

--- Add a size factor measured by a test (dismount with a visible bubble).
function P.LearnTestRatio(mountID, ratio, store)
  if type(mountID) ~= "number" or not ratio then
    return
  end
  sizeK = nil
  local mounts = (store or PC.GetModelStore()).mounts
  local m = mounts[mountID]
  if not m then
    m = { name = PC.GetMountName(mountID) }
    mounts[mountID] = m
  end
  m.testRatios = m.testRatios or {}
  m.testRatios[#m.testRatios + 1] = ratio
  while #m.testRatios > DIP_KEEP do
    table.remove(m.testRatios, 1)
  end
  PC.Debug(string.format("mount %s: size factor %.2f from tests (median of %d)", tostring(mountID),
    Median(m.testRatios), #m.testRatios))
end

-- Size factor ≈ K / model size (Core/MountSizes.lua): K from every measurement we have
-- (shipped and yours, all races brought to the gnome's scale), median, rebuilt when a
-- calibration or test adds data. (sizeK is declared above, with LearnTestRatio.)
local function SizeK()
  if sizeK then
    return sizeK
  end
  local list = {}
  local function Add(key, mountID, ratio)
    local size = PC.MountSize[mountID]
    local factor, measured = PC.RaceFactor(key)
    if size and ratio and measured then
      list[#list + 1] = ratio / factor * size
    end
  end
  for key, mounts in pairs(PC.KnownCalibrations) do
    for id, k in pairs(mounts) do
      Add(key, id, k.ratio)
    end
  end
  for key, model in pairs(PC.db.models) do
    for id, m in pairs(model.mounts or {}) do
      if type(id) == "number" and not m.unmeasurable then
        if m.captures and #m.captures > 0 then
          Add(key, id, MeanRatio(m))
        elseif m.testRatios and #m.testRatios > 0 then
          Add(key, id, Median(m.testRatios))
        end
      end
    end
  end
  sizeK = Median(list) or 24.2
  return sizeK
end

PC.On("CALIBRATION_UPDATED", function()
  sizeK = nil
end)

--- Your own measurements of this mount (or its family) made with another race or form,
--- scaled to this one by the races' factors. nil if none.
function P.FromOtherRaces(mountID)
  if type(mountID) ~= "number" then
    return nil
  end
  local myKey = PC.GetModelKey()
  local myFactor = PC.RaceFactor(myKey)
  local ids = PC.MountFamily(mountID)
  if #ids == 0 then
    ids = { mountID }
  end
  local keys = {}
  for key in pairs(PC.db.models) do
    if key ~= myKey then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local factor, measured = PC.RaceFactor(key)
    local mounts = PC.db.models[key].mounts or {}
    for _, id in ipairs(ids) do
      local m = mounts[id]
      if measured and m and not m.unmeasurable then
        local ratio = (m.captures and #m.captures > 0 and MeanRatio(m))
          or (m.testRatios and #m.testRatios > 0 and Median(m.testRatios))
        if ratio then
          return ratio * myFactor / factor
        end
      end
    end
  end
  return nil
end

--- Size factor estimated from the mount model's size, or nil without a size.
function P.EstimateFromSize(mountID)
  local size = type(mountID) == "number" and PC.MountSize[mountID]
  if not size or size <= 0 then
    return nil
  end
  return SizeK() * PC.RaceFactor(PC.GetModelKey()) / size
end

function P.GetSource(mountID)
  local mounts = PC.GetModelStore().mounts
  local entry, kind = OwnOrFamily(mountID)
  if entry then
    return { kind = kind, from = entry.name, ratio = MeanRatio(entry) }
  end
  local tested, testedEntry = TestRatio(mountID)
  if tested then
    return { kind = "mount", from = testedEntry.name, ratio = tested }
  end
  local known, knownKind = Builtin(mountID)
  if known and knownKind == "builtin" then
    return { kind = knownKind, ratio = known.ratio }
  end
  local other = P.FromOtherRaces(mountID)
  if other then
    return { kind = "scaled", ratio = other }
  end
  if known then
    return { kind = knownKind, ratio = known.ratio }
  end
  local estimate = P.EstimateFromSize(mountID)
  if estimate then
    return { kind = "estimated", ratio = estimate }
  end
  -- Unknown mount: the average of your calibrated mounts, else of the gnome's shipped
  -- ones scaled to your race.
  local count, ratioSum = 0, 0
  for _, m in pairs(mounts) do
    if m.captures and #m.captures > 0 then
      count = count + 1
      ratioSum = ratioSum + MeanRatio(m)
    end
  end
  if count == 0 then
    local factor = PC.RaceFactor(PC.GetModelKey())
    for _, k in pairs(PC.KnownCalibrations[PC.KNOWN_BASE] or {}) do
      count, ratioSum = count + 1, ratioSum + k.ratio * factor
    end
  end
  if count > 0 then
    return { kind = "average", count = count, ratio = ratioSum / count }
  end
  return { kind = "reference", ratio = PC.ReferenceData.ratio }
end

--- On-foot / mounted gain ratio for a mount (used by the "Same as on foot" mode).
function P.GetRatio(mountID)
  return P.GetSource(mountID).ratio or PC.ReferenceData.ratio
end

--- Dip gain for a mount, plus where it comes from ("mount" | "family" | "builtin" |
--- "scaled" | "estimated"). Without a measurement it follows from the size factor:
--- h ≈ DIP_PER_RATIO × ratio for every race and mount measured so far.

-- A dip-gain measurement can be noisy (two captures of one mount gave 0.34 and 0.22)
-- while h ≈ DIP_PER_RATIO × size factor holds within ±12 % on ordinary mounts. Three or
-- more measurements (their median), or two that agree, win outright — the Obsidian
-- Nightwing, which hides your character, measured 1.0 five times: its camera doesn't dip
-- at all. Otherwise they refine the estimate (worth PRIOR_WEIGHT measurements), at most
-- ±15 % away from it.
local PRIOR_WEIGHT, MAX_SHIFT, AGREE = 3, 0.15, 0.12

local function Blend(m, ratio)
  if m.stepGains and #m.stepGains > 0 then
    return Median(m.stepGains) -- clean: measured with the plan itself
  end
  local prior = PC.DIP_PER_RATIO * ratio
  local list = m.dipGains or (m.dipGain and { m.dipGain }) or {}
  if #list >= 2 then
    local sorted = {}
    for i, h in ipairs(list) do
      sorted[i] = h
    end
    table.sort(sorted)
    local median = Median(sorted)
    -- Three or more: the median shrugs off a bad one. Two: only if they agree.
    if median and median > 0 and (#list >= 3 or (sorted[#sorted] - sorted[1]) / median <= AGREE) then
      return median
    end
  end
  local sum = prior * PRIOR_WEIGHT
  for _, h in ipairs(list) do
    sum = sum + h
  end
  local h = sum / (PRIOR_WEIGHT + #list)
  return PC.Clamp(h, prior * (1 - MAX_SHIFT), prior * (1 + MAX_SHIFT))
end

function P.GetDipGain(mountID)
  local mounts = PC.GetModelStore().mounts
  local own = mountID and mounts[mountID]
  if own and own.stepGains and #own.stepGains > 0 then
    return Median(own.stepGains), "mount"
  end
  if own and (own.dipGain or own.dipGains) and Calibrated(own) then
    return Blend(own, MeanRatio(own)), "mount"
  end
  if type(mountID) == "number" then
    for _, other in ipairs(PC.MountFamily(mountID)) do
      local m = mounts[other]
      if m and m.stepGains and #m.stepGains > 0 then
        return Median(m.stepGains), "family"
      end
      if m and (m.dipGain or m.dipGains) and Calibrated(m) then
        return Blend(m, MeanRatio(m)), "family"
      end
    end
  end
  local known, knownKind = Builtin(mountID)
  if known and known.dipGain then
    return known.dipGain, knownKind
  end
  return PC.Clamp(PC.DIP_PER_RATIO * P.GetRatio(mountID), 0.15, 1), "estimated"
end


--- Add a dip-gain measurement for a mount (store = a model's store, default yours).
--- step = measured while playing the two-step plan (calibration since 0.8.5, or a test):
--- the screen's plateau gives h directly and those values win over curve fits.
function P.LearnDipGain(mountID, h, store, step)
  if type(mountID) ~= "number" or not h then
    return
  end
  local mounts = (store or PC.GetModelStore()).mounts
  local m = mounts[mountID]
  if not m then
    m = { name = PC.GetMountName(mountID) }
    mounts[mountID] = m
  end
  local field = step and "stepGains" or "dipGains"
  m[field] = m[field] or {}
  local list = m[field]
  list[#list + 1] = h
  while #list > DIP_KEEP do
    table.remove(list, 1)
  end
  m.dipGain = Median(m.stepGains or m.dipGains)
  PC.Debug(string.format("mount %s: dip gain %.2f (median of %d %s)", tostring(mountID), m.dipGain,
    #(m.stepGains or m.dipGains), m.stepGains and "plan measurements" or "curve fits"))
end

-- Raw dismount tests saved before dip gains existed (rows "t,x,y,sh", events
-- "t,name,arg"): learn from each of them once.
local function LearnFromTestLog()
  local log = PC.db.testLog
  if type(log) ~= "table" then
    return
  end
  for _, e in ipairs(log) do
    if not e.learned and e.kind == "dismount" and e.plan == "raw" and e.events and e.rows then
      e.learned = true
      local tSwitch
      for _, line in ipairs(e.events) do
        local t, name = line:match("^([^,]+),([^,]+)")
        t = tonumber(t)
        if name == "COMPANION_UPDATE" and t and t > 0.03 then
          tSwitch = t
          break
        end
      end
      if tSwitch and type(e.mountID) == "number" and e.model then
        local samples = {}
        for _, line in ipairs(e.rows) do
          local t, x, _, sh = line:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
          if t then
            samples[#samples + 1] = { t = tonumber(t), x = tonumber(x), sh = tonumber(sh) }
          end
        end
        local models = PC.db.models
        models[e.model] = models[e.model] or {}
        models[e.model].mounts = models[e.model].mounts or {}
        P.LearnDipGain(e.mountID, PC.Analysis.FitDipGain(samples, tSwitch), models[e.model])
      end
    end
  end
end

-- Two-step dismount tests saved by 0.3.0 (before they measured the dip gain themselves):
-- until the server confirms, the screen settles at h_true / h_used of where it started.
local function LearnFromStepTests()
  local log = PC.db.testLog
  if type(log) ~= "table" then
    return
  end
  for _, e in ipairs(log) do
    if e.kind == "dismount" and e.plan == "step" and not e.stepChecked3
      and e.dipGain and e.confirmAt and e.rows and e.model then
      e.stepChecked3 = true
      local samples = {}
      for _, line in ipairs(e.rows) do
        local t, x = line:match("^([^,]*),([^,]*)")
        t, x = tonumber(t), tonumber(x)
        if t then
          samples[#samples + 1] = { t = t, x = x }
        end
      end
      local h = PC.Analysis.StepDipGain(samples, e.dipGain, e.confirmAt)
      if h then
        e.dipGainMeasured = h
        local models = PC.db.models
        models[e.model] = models[e.model] or {}
        models[e.model].mounts = models[e.model].mounts or {}
        P.LearnDipGain(e.mountID, h, models[e.model], true)
      end
    end
  end
end

--- Status for the UI: "reference" | "mount" | "family" | "average", plus the pooled
--- mount count (average) or the calibrated mount's name (family).
function P.Describe(mountID)
  local source = P.GetSource(mountID)
  return source.kind, source.count or source.from
end

-- Calibrations saved before the consistency check: drop captures that disagree, and
-- mark mounts whose results can't be trusted at all.
local function CheckStoredCalibrations()
  for _, model in pairs(PC.db.models) do
    for id, m in pairs(model.mounts or {}) do
      if m.captures and #m.captures > 0 and not m.checked then
        m.checked = true
        local kept, trusted = PC.Analysis.ConsistentCaptures(m.captures)
        if not trusted then
          m.captures, m.ratio, m.unmeasurable = nil, nil, true
          PC.Debug(string.format("mount %s: stored calibration disagrees with itself, dropped", tostring(id)))
        elseif #kept < #m.captures then
          local ratios = {}
          for i, c in ipairs(kept) do
            ratios[i] = c.ratio
          end
          m.captures, m.ratio = kept, Median(ratios)
        end
      end
    end
  end
end

-- Saved dismount tests also measured the size factor (mounted before, on foot after).
local function LearnRatiosFromTests()
  local log = PC.db.testLog
  if type(log) ~= "table" then
    return
  end
  for _, e in ipairs(log) do
    if e.kind == "dismount" and not e.ratioChecked and e.rows and e.model and type(e.mountID) == "number"
      and e.plan ~= "raw" then
      e.ratioChecked = true
      local samples = {}
      for _, line in ipairs(e.rows) do
        local t, x, _, sh = line:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
        if t then
          samples[#samples + 1] = { t = tonumber(t), x = tonumber(x), sh = tonumber(sh) }
        end
      end
      local ratio = PC.Analysis.TestRatio(samples)
      if ratio then
        local models = PC.db.models
        models[e.model] = models[e.model] or {}
        models[e.model].mounts = models[e.model].mounts or {}
        P.LearnTestRatio(e.mountID, ratio, models[e.model])
      end
    end
  end
end

function P.Init()
  CheckStoredCalibrations()
  LearnRatiosFromTests()
  LearnFromTestLog()
  LearnFromStepTests()
end
