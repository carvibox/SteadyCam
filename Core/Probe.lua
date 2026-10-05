---------------------------------------------------------------------------------------
--  Core/Probe.lua — where your character is on screen (chat bubble probe)
---------------------------------------------------------------------------------------
--  WoW gives addons no camera position, and blocks measuring nameplates, but chat bubbles
--  (open world) can be measured: the calibration /say bubble sits above your head, so
--  its center tracks your character on screen (KNOWLEDGE.md §2).
--  Picks your bubble among others: when the game lets us read bubble text, only a bubble
--  containing "SteadyCam" or the last line *you* said (CHAT_MSG_SAY / YELL from your own
--  GUID) counts — an NPC's bubble must never stand in for yours. If no text is readable:
--  the bubble tracked last frame, else the one nearest the center.
--  Probe.lastMatch tells how the last read was matched ("text" / "track" / "center").
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_ChatBubbles = _G.C_ChatBubbles
local CreateFrame = _G.CreateFrame
local UIParent = _G.UIParent
local UnitGUID = _G.UnitGUID
local UnitName = _G.UnitName
local issecretvalue = _G.issecretvalue

local abs = math.abs

local Probe = {}
PC.Probe = Probe

local MARK = "SteadyCam"
local lastBubble
local ownText -- the last line your character said (its bubble shows this text)

local function IsSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

local function BubbleText(bubble)
  local ok, text = pcall(function()
    for _, child in ipairs({ bubble:GetChildren() }) do
      local fs = child.String
      if fs and fs.GetText then
        return fs:GetText()
      end
    end
  end)
  if ok and type(text) == "string" and not IsSecret(text) then
    return text
  end
end

--- Center relative to the screen center, in UIParent units; nil when unreadable.
local function Center(region)
  local ok, x, y, scale = pcall(function()
    local cx, cy = region:GetCenter()
    return cx, cy, region:GetEffectiveScale()
  end)
  if not ok or not x or not y or IsSecret(x) or IsSecret(y) or IsSecret(scale) then
    return nil
  end
  local s = scale / UIParent:GetEffectiveScale()
  return x * s - UIParent:GetWidth() / 2, y * s - UIParent:GetHeight() / 2
end

--- x, y of your bubble (screen-center relative) or nil + reason.
function Probe.Read()
  if not (C_ChatBubbles and C_ChatBubbles.GetAllChatBubbles) then
    return nil, "no chat bubble API"
  end
  local ok, bubbles = pcall(C_ChatBubbles.GetAllChatBubbles, false)
  if not ok or type(bubbles) ~= "table" then
    return nil, "chat bubbles unavailable here"
  end
  local best, bestX, bestY, bestScore
  for _, bubble in ipairs(bubbles) do
    local visible = bubble.IsVisible and bubble:IsVisible()
    local forbidden = bubble.IsForbidden and bubble:IsForbidden()
    if visible and not forbidden then
      local x, y = Center(bubble)
      if x then
        local score
        local text = BubbleText(bubble)
        if text then
          local mine = text:find(MARK, 1, true) or (ownText and text:find(ownText, 1, true))
          score = mine and -2 or nil -- someone else's bubble: skip
        elseif bubble == lastBubble then
          score = -1
        else
          score = abs(x) / 1000
        end
        if score and (not bestScore or score < bestScore) then
          best, bestX, bestY, bestScore = bubble, x, y, score
        end
      end
    end
  end
  if not best then
    lastBubble = nil
    return nil, "no chat bubble"
  end
  lastBubble = best
  Probe.lastMatch = bestScore == -2 and "text" or (bestScore == -1 and "track" or "center")
  return bestX, bestY
end

function Probe.Reset()
  lastBubble = nil
end

-- Remember what you say so your bubble can be recognized by its text.
local chat = CreateFrame("Frame")
chat:RegisterEvent("CHAT_MSG_SAY")
chat:RegisterEvent("CHAT_MSG_YELL")
chat:SetScript("OnEvent", function(_, _, text, sender, ...)
  local guid = select(10, ...) -- 12th payload argument
  pcall(function()
    if type(text) ~= "string" or IsSecret(text) or text == "" then
      return
    end
    local mine
    if type(guid) == "string" and not IsSecret(guid) and UnitGUID then
      mine = guid == UnitGUID("player")
    elseif type(sender) == "string" and not IsSecret(sender) and UnitName then
      mine = sender:match("^[^%-]+") == UnitName("player")
    end
    if mine then
      ownText = text
    end
  end)
end)
