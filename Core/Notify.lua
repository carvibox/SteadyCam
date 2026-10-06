---------------------------------------------------------------------------------------
--  Core/Notify.lua — mount usage and the "not calibrated yet" chat link
---------------------------------------------------------------------------------------
--  Counts how often you ride each mount (the calibration picker lists the ones you use
--  most first). The first time per session you ride a mount with no calibration — its
--  own or one of the same model (Core/MountFamilies.lua) — a chat line offers a link;
--  clicking it starts that mount's calibration right away (UI/Wizard.lua).
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local LINK = "|Haddon:steadycam:calibrate:%d|h|cff69ccf0[%s]|r|h"

local notified = {} -- [mountID] = true once announced this session
local waitingForID = false

local function OnRide(mountID)
  if type(mountID) ~= "number" or PC.Calibration.IsRunning() then
    return
  end
  local use = PC.db.mountUse
  use[mountID] = (use[mountID] or 0) + 1
  if not PC.FramingActive() then
    return
  end
  local settings = PC.db.settings
  local name = PC.GetMountName(mountID) or "?"
  local link = string.format(LINK, mountID, PC.L.NOTIFY_LINK)
  -- A mount SteadyCam knows nothing about (new, or far bigger / smaller than any measured):
  -- said every time it is ridden, until it is calibrated (on by default).
  if settings.notifyBlind and PC.Profiles.Confidence(mountID) == "blind" then
    PC.Print(string.format(PC.L.NOTIFY_BLIND, name, link))
    return
  end
  -- Any mount without a calibration: once per session, opt-in.
  if not settings.notifyUncalibrated or notified[mountID] or PC.Profiles.IsCalibrated(mountID) then
    return
  end
  notified[mountID] = true
  PC.Print(string.format(PC.L.NOTIFY_UNCALIBRATED, name, link))
end

PC.On("MOUNT_SWAP", function(mounted, mountID)
  if not mounted then
    waitingForID = false
    return
  end
  if mountID then
    OnRide(mountID)
  else
    waitingForID = true -- the journal names the mount a few frames later
  end
end)

PC.On("MOUNT_IDENTIFIED", function(mountID)
  if waitingForID then
    waitingForID = false
    OnRide(mountID)
  end
end)

--- Chat link handler: "addon:steadycam:calibrate:<mountID>" (research: a quick one),
--- "addon:steadycam:disabledc" (turn DynamicCam off and reload).
function PC.HandleLink(link)
  if type(link) ~= "string" then
    return false
  end
  if link == "addon:steadycam:disabledc" and PC.DisableDynamicCam then
    PC.DisableDynamicCam()
    return true
  end
  if not PC.StartCalibrationFromLink then
    return false
  end
  local kind, id = link:match("^addon:steadycam:(%a+):(%d+)")
  if kind == "calibrate" or kind == "research" then
    PC.StartCalibrationFromLink(tonumber(id), kind == "research")
    return true
  end
  return false
end

if _G.EventRegistry and _G.EventRegistry.RegisterCallback then
  _G.EventRegistry:RegisterCallback("SetItemRef", function(_, link)
    PC.HandleLink(link)
  end)
end
