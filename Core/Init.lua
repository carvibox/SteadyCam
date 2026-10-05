---------------------------------------------------------------------------------------
--  Core/Init.lua — namespace, chat helpers, callbacks
---------------------------------------------------------------------------------------
--  What it does: Creates the SteadyCam namespace (PC) shared by every file through
--  the addon vararg, plus a tiny callback bus so modules stay decoupled:
--    PC.On(event, fn)      subscribe
--    PC.Fire(event, ...)   publish (MOUNT_SWAP, SETTINGS_CHANGED, PROFILE_READY, ...)
--  Related: every other file (loaded after this one, see SteadyCam.toc).
---------------------------------------------------------------------------------------
local addonName, PC = ...
local _G = _G

_G.SteadyCam = PC -- exposed for debugging and for other addons (e.g. Combat Mode)

PC.name = addonName
PC.version = (_G.C_AddOns and _G.C_AddOns.GetAddOnMetadata(addonName, "Version")) or "dev"

local PREFIX = "|cfff0bd30SteadyCam|r" -- the accent gold (UI/Theme.lua)

function PC.Print(msg)
  print(PREFIX .. "|cff909090: " .. tostring(msg) .. "|r")
end

function PC.Debug(msg)
  if PC.db and PC.db.settings.debug then
    PC.Print("|cff69ccf0[debug]|r " .. tostring(msg))
  end
end

local listeners = {}

function PC.On(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

function PC.Fire(event, ...)
  local list = listeners[event]
  if not list then
    return
  end
  for i = 1, #list do
    list[i](...)
  end
end

--- Smoothstep: eases in and out so camera moves never start or stop abruptly.
function PC.Smoothstep(u)
  if u <= 0 then
    return 0
  elseif u >= 1 then
    return 1
  end
  return u * u * (3 - 2 * u)
end

function PC.Clamp(v, lo, hi)
  if v < lo then
    return lo
  elseif v > hi then
    return hi
  end
  return v
end
