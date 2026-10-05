---------------------------------------------------------------------------------------
--  Core/Mounts.lua — mount / vehicle state and mount identity
---------------------------------------------------------------------------------------
--  Polls IsMounted() / UnitInVehicle("player") every frame (events arrive before the
--  flag flips) and fires:
--    MOUNT_SWAP(mounted, mountID, confirmed)   mountID = journal ID, "vehicle", or nil;
--        confirmed (dismounts) = the server already confirmed it this frame
--    MOUNT_CONFIRMED()              COMPANION_UPDATE: the server confirmed a mount change
--    MOUNT_IDENTIFIED(mountID)      when the journal reports the mount a few frames late
--  A dismount made the usual way (key, spell) is shown at once but confirmed about one
--  round trip later — the game keeps the mounted camera until then. /dismount waits for
--  the server, so both happen together (KNOWLEDGE.md §4).
--  On dismount, mountID is the mount you just left (its calibration drives the timing).
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_MountJournal = _G.C_MountJournal
local CreateFrame = _G.CreateFrame
local GetTime = _G.GetTime
local IsMounted = _G.IsMounted
local UnitInVehicle = _G.UnitInVehicle

local IDENTIFY_WINDOW = 1.0 -- seconds to keep looking for the active mount
local CONFIRM_WINDOW = 0.05 -- a COMPANION_UPDATE this recent counts as "same frame"

local mounted = nil -- cached state; nil until the first poll
local currentMountID = nil
local lastFoundID = nil
local identifyUntil = nil
local confirmedAt = -1
-- The mount you just left, until its dismount is confirmed: a COMPANION_UPDATE only
-- counts once the journal no longer lists that mount as active (a mount summon right
-- after dismounting fires one too — seen at 0.076 s with a blood elf, while the camera
-- switched at ~0.22 s).
local leftMountID, leftUntil = nil, 0
local confirmWaiting = false

local function LiveMounted()
  if IsMounted and IsMounted() then
    return true
  end
  return UnitInVehicle and UnitInVehicle("player") == true or false
end

--- Journal ID of the mount you are riding, "vehicle", "taxi", or nil if not found (yet).
function PC.FindActiveMountID()
  if UnitInVehicle and UnitInVehicle("player") then
    return "vehicle"
  end
  if _G.UnitOnTaxi and _G.UnitOnTaxi("player") then
    return "taxi" -- flight paths count as mounted, with their own camera
  end
  if not (C_MountJournal and C_MountJournal.GetMountIDs) then
    return nil
  end
  if lastFoundID then
    local _, _, _, isActive = C_MountJournal.GetMountInfoByID(lastFoundID)
    if isActive then
      return lastFoundID
    end
  end
  for _, id in ipairs(C_MountJournal.GetMountIDs()) do
    local _, _, _, isActive = C_MountJournal.GetMountInfoByID(id)
    if isActive then
      lastFoundID = id
      return id
    end
  end
  return nil
end

function PC.IsMountedOrInVehicle()
  if mounted == nil then
    mounted = LiveMounted()
  end
  return mounted
end

function PC.GetCurrentMountID()
  return currentMountID
end

function PC.GetMountName(mountID)
  if mountID == "vehicle" then
    return _G.VEHICLE or "Vehicle"
  end
  if type(mountID) ~= "number" or not C_MountJournal then
    return nil
  end
  local name = C_MountJournal.GetMountInfoByID(mountID)
  return name
end

local flyingBefore = false -- IsFlying() on the previous frame (tells an air dismount)

local function Poll()
  local live = LiveMounted()
  PC.dismountedInAir = nil
  if mounted == nil then
    mounted = live
    if live then
      currentMountID = PC.FindActiveMountID()
    end
    return
  end
  if live ~= mounted then
    mounted = live
    if live then
      currentMountID = PC.FindActiveMountID()
      identifyUntil = currentMountID == nil and (GetTime() + IDENTIFY_WINDOW) or nil
      PC.Fire("MOUNT_SWAP", true, currentMountID)
    else
      local leftMount = currentMountID
      currentMountID, identifyUntil = nil, nil
      PC.dismountedInAir = flyingBefore
      local confirmed = GetTime() - confirmedAt <= CONFIRM_WINDOW
      leftMountID, leftUntil, confirmWaiting = (not confirmed) and leftMount or nil, GetTime() + 1, false
      PC.Fire("MOUNT_SWAP", false, leftMount, confirmed)
    end
  elseif identifyUntil then
    local id = PC.FindActiveMountID()
    if id then
      currentMountID, identifyUntil = id, nil
      PC.Fire("MOUNT_IDENTIFIED", id)
    elseif GetTime() > identifyUntil then
      identifyUntil = nil
    end
  end
  flyingBefore = live and _G.IsFlying and _G.IsFlying() or false
end

local function StillActive(mountID)
  if type(mountID) ~= "number" or not C_MountJournal then
    return false
  end
  local _, _, _, isActive = C_MountJournal.GetMountInfoByID(mountID)
  return isActive and true or false
end

-- Fire MOUNT_CONFIRMED once a COMPANION_UPDATE has come and the left mount is gone.
local function CheckConfirmation()
  if leftMountID and GetTime() > leftUntil then
    leftMountID, confirmWaiting = nil, false
  end
  if not confirmWaiting then
    return
  end
  if leftMountID and StillActive(leftMountID) then
    return -- not the dismount's confirmation (yet)
  end
  leftMountID, confirmWaiting = nil, false
  PC.Fire("MOUNT_CONFIRMED")
end

function PC.StartMountWatcher()
  local frame = CreateFrame("Frame", "SteadyCamMountWatcher")
  frame:SetScript("OnUpdate", function()
    Poll()
    CheckConfirmation()
  end)
  frame:RegisterEvent("COMPANION_UPDATE")
  frame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
  frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
      -- The model swaps in this frame: react now, not in OnUpdate (a frame later the
      -- dismount hold arrives after the game's own change: ~10 px on a big rider).
      Poll()
      return
    end
    confirmedAt = GetTime()
    confirmWaiting = true
    CheckConfirmation()
  end)
end
