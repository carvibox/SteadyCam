---------------------------------------------------------------------------------------
--  Core/Analysis.lua — pure calibration math (no WoW API; tested offline, see Tests/)
---------------------------------------------------------------------------------------
--  Model (KNOWLEDGE.md §4): after a dismount the character's on-screen X is
--      X(t) = -G_mounted * g(t) * shoulder(t)
--  with g(t) the game's normalized gain curve (1 while mounted, a dip to ~0.45, then a
--  ramp to `ratio` ~4.2 around t_ramp ≈ 0.255 - 0.0037·zoom s, ±25 ms at random).
--  Some mounts (Golden Gryphon) dip and switch at a random moment; others (a gnome's
--  ground mounts) ease straight to the on-foot camera from the swap. A dismount plan is
--  the shoulder offset every 10 ms: either hold + smoothstep (robust to random timing)
--  or curve-following (offset = desired / expected g). The optimizer scores both
--  families against every measured curve and keeps the lowest back-and-forth.
--
--  Capture = { zoom, ratio, ramp, dt, g = { g(0), g(dt), ... } }
---------------------------------------------------------------------------------------
local _, PC = ...

local A = {}
PC.Analysis = A

local abs, floor = math.abs, math.floor

local SAMPLE_DT = 0.01 -- evaluation step (s)
local HORIZON = 0.8 -- seconds evaluated after the swap
-- Extra timing noise per scenario (s). With few captures the game's ±25 ms randomness
-- is not in the data yet, so it is simulated wider.
local JITTER_FEW = { -0.03, -0.015, 0, 0.015, 0.03 }
local JITTER_MANY = { -0.01, 0, 0.01 }
local MANY_CAPTURES = 6

local function Smoothstep(u)
  if u <= 0 then
    return 0
  elseif u >= 1 then
    return 1
  end
  return u * u * (3 - 2 * u)
end
A.Smoothstep = Smoothstep

--- g at time t (seconds after the swap). Before the swap the mounted gain (1) applies;
--- after the curve ends its last value holds.
function A.SampleCurve(capture, t)
  local g = capture.g
  if t <= 0 then
    return g[1]
  end
  local pos = t / capture.dt + 1
  local i = floor(pos)
  if i >= #g then
    return g[#g]
  end
  return g[i] + (g[i + 1] - g[i]) * (pos - i)
end

--- Shoulder offset commanded by a hold + smoothstep schedule at time t.
function A.DismountShoulder(t, delay, time, from, to)
  if t <= delay then
    return from
  end
  if time <= 0 then
    return to
  end
  return from + (to - from) * Smoothstep((t - delay) / time)
end

---------------------------------------------------------------------------------------
-- Paths: a dismount plan is the shoulder offset every SAMPLE_DT from the swap
-- (STEPS + 1 values covering HORIZON); after the path ends the on-foot offset holds.
---------------------------------------------------------------------------------------
local STEPS = floor(HORIZON / SAMPLE_DT + 0.5)
A.SAMPLE_DT = SAMPLE_DT
local SHOULDER_LIMIT = 10
-- Search grids. Inverse paths glide over at least 0.1 s so a net move never snaps.
local INVERSE_SHIFTS = { -0.02, -0.01, 0, 0.01, 0.02, 0.03, 0.04 }
local INVERSE_TIMES = { 0.1, 0.15, 0.2, 0.3, 0.4 }

--- Hold `from` for `delay`, then smoothstep to `to` over `time`.
function A.ClassicPath(delay, time, from, to)
  local path = {}
  for i = 0, STEPS do
    path[i + 1] = A.DismountShoulder(i * SAMPLE_DT, delay, time, from, to)
  end
  return path
end

--- Value of a path at time t (linear between samples; `final` after the end).
function A.PathValue(path, t, final)
  if t <= 0 then
    return path[1]
  end
  local pos = t / SAMPLE_DT + 1
  local i = floor(pos)
  if i >= #path then
    return final or path[#path]
  end
  return path[i] + (path[i + 1] - path[i]) * (pos - i)
end

--- Has the camera's early "dip" (g drops below 0.9 in the first 0.15 s)? Mounts with a
--- dip switch cameras at a random moment ~0.15-0.25 s later; mounts without one ease
--- straight to the on-foot camera from the swap (KNOWLEDGE.md §4).
function A.HasDip(capture)
  for t = 0.02, 0.15 + 1e-9, SAMPLE_DT do
    if A.SampleCurve(capture, t) < 0.9 then
      return true
    end
  end
  return false
end

--- Back-and-forth beyond the net move for one scenario following `path`, in
--- mounted-gain units (multiply by G_mounted for screen px). 0 = one clean move.
function A.PathExtra(capture, shift, path, from)
  local first = -from -- steady mounted position just before the swap (g = 1)
  local prev, x = first, first
  local total = 0
  for i = 1, #path do
    x = -A.SampleCurve(capture, (i - 1) * SAMPLE_DT - shift) * path[i]
    total = total + abs(x - prev)
    prev = x
  end
  return total - abs(x - first)
end

--- Worst and mean extra motion of a path over a scenario set.
function A.ScorePath(scenarios, path, from)
  local worst, sum = 0, 0
  for i = 1, #scenarios do
    local s = scenarios[i]
    local e = A.PathExtra(s.capture, s.shift, path, from)
    if e > worst then
      worst = e
    end
    sum = sum + e
  end
  return worst, sum / #scenarios
end

--- Classic schedule score (kept for comparisons and tests).
function A.ScoreSchedule(scenarios, delay, time, from, to)
  return A.ScorePath(scenarios, A.ClassicPath(delay, time, from, to), from)
end

--- Least-squares ramp(zoom) = a + b·zoom over the captures; b = 0 with a single zoom.
function A.FitRampTrend(captures)
  local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
  for i = 1, #captures do
    local c = captures[i]
    n = n + 1
    sx, sy = sx + c.zoom, sy + c.ramp
    sxx, sxy = sxx + c.zoom * c.zoom, sxy + c.zoom * c.ramp
  end
  if n == 0 then
    return 0.2, 0
  end
  local d = n * sxx - sx * sx
  if n < 2 or abs(d) < 1e-9 then
    return sy / n, 0
  end
  local b = (n * sxy - sx * sy) / d
  return (sy - b * sx) / n, b
end

local function AnyDip(captures)
  for i = 1, #captures do
    if A.HasDip(captures[i]) then
      return true
    end
  end
  return false
end

--- Time shift that moves a capture to the target zoom along the ramp trend. Only dip
--- mounts follow the zoom trend; dip-free curves start at the swap at every zoom.
local function TrendShifter(captures, zoom)
  if not AnyDip(captures) then
    return function()
      return 0
    end
  end
  local a, b = A.FitRampTrend(captures)
  return function(c)
    return (a + b * zoom) - (a + b * c.zoom)
  end
end

--- Scenarios for a target zoom: every capture (from any zoom) moved along the ramp
--- trend to that zoom — keeping its own random deviation — plus timing jitter: ±1 frame
--- for dip-free mounts (their switch starts at the swap), wider for dip mounts with few
--- captures (their ±25 ms randomness is not in the data yet).
function A.BuildScenarios(captures, zoom)
  local trend = TrendShifter(captures, zoom)
  local jitter = JITTER_MANY
  if AnyDip(captures) and #captures < MANY_CAPTURES then
    jitter = JITTER_FEW
  end
  local list = {}
  for i = 1, #captures do
    local c = captures[i]
    local trendShift = trend(c)
    for j = 1, #jitter do
      list[#list + 1] = { capture = c, shift = trendShift + jitter[j] }
    end
  end
  return list
end

--- Mean normalized curve at `zoom` (captures moved along the ramp trend), on the path grid.
function A.Template(captures, zoom)
  local trend = TrendShifter(captures, zoom)
  local tpl = {}
  for i = 0, STEPS do
    local sum = 0
    for j = 1, #captures do
      local c = captures[j]
      sum = sum + A.SampleCurve(c, i * SAMPLE_DT - trend(c))
    end
    tpl[i + 1] = sum / #captures
  end
  return tpl
end

--- Curve-following path: shoulder = desired (g · shoulder) / expected g, so the character
--- glides from its mounted spot to its on-foot spot over `time` while the game changes
--- cameras underneath. `shift` delays the expected curve; the last 0.1 s settles on `to`.
function A.InversePath(template, ratio, shift, time, from, to)
  local tplCurve = { g = template, dt = SAMPLE_DT }
  local path = {}
  for i = 0, STEPS do
    local t = i * SAMPLE_DT
    local e = time > 0 and Smoothstep(t / time) or 1
    local want = (1 - e) * from + e * to * ratio
    local g = A.SampleCurve(tplCurve, t - shift)
    local v = want / math.max(g, 0.05)
    if v > SHOULDER_LIMIT then
      v = SHOULDER_LIMIT
    elseif v < -SHOULDER_LIMIT then
      v = -SHOULDER_LIMIT
    end
    path[i + 1] = v
  end
  local blendStart = #path - 10
  for i = blendStart, #path do
    path[i] = path[i] + (to - path[i]) * Smoothstep((i - blendStart) / 10)
  end
  return path
end

--- Best plan for dismounting from shoulder `from` (mounted) to `to` (on foot) at `zoom`.
--- Tries both families — hold + smoothstep (robust to a randomly timed camera switch)
--- and curve-following (exact when the switch starts at the swap) — and keeps the one
--- with the lowest worst + mean extra motion. Returns
---   { kind = "classic"|"inverse", path, worst, mean, delay, time, shift }
--- `yield` (optional) is called every few candidates (coroutine-friendly).
function A.OptimizeDismount(captures, zoom, from, to, yield)
  if #captures == 0 or abs(from) + abs(to) < 1e-6 then
    return { kind = "classic", path = A.ClassicPath(0, 0, from, to), worst = 0, mean = 0, delay = 0, time = 0 }
  end
  local scenarios = A.BuildScenarios(captures, zoom)
  local best = { cost = math.huge }
  local evaluated = 0

  local function Consider(plan)
    local worst, mean = A.ScorePath(scenarios, plan.path, from)
    local cost = worst + mean
    if cost < best.cost - 1e-9 then
      plan.cost, plan.worst, plan.mean = cost, worst, mean
      best = plan
    end
    evaluated = evaluated + 1
    if yield and evaluated % 8 == 0 then
      yield()
    end
  end

  local function TryClassic(delay, time)
    if delay < 0 or time < 0 or delay > 0.4 or time > 0.4 then
      return
    end
    Consider({ kind = "classic", delay = delay, time = time, path = A.ClassicPath(delay, time, from, to) })
  end

  for d = 0, 30, 2 do
    for t = 0, 30, 2 do
      TryClassic(d / 100, t / 100)
    end
  end
  if best.kind == "classic" then
    local d0, t0 = floor(best.delay * 100 + 0.5), floor(best.time * 100 + 0.5)
    for d = d0 - 2, d0 + 2 do
      for t = t0 - 2, t0 + 2 do
        TryClassic(d / 100, t / 100)
      end
    end
  end

  local template = A.Template(captures, zoom)
  local ratio = A.MeanRatio(captures)
  for _, shift in ipairs(INVERSE_SHIFTS) do
    for _, time in ipairs(INVERSE_TIMES) do
      Consider({
        kind = "inverse",
        shift = shift,
        time = time,
        path = A.InversePath(template, ratio, shift, time, from, to),
      })
    end
  end
  best.cost = nil
  return best
end

--- Distinct capture zooms, sorted (the rows the runtime interpolates between).
function A.CaptureZooms(captures)
  local seen, list = {}, {}
  for i = 1, #captures do
    local z = floor(captures[i].zoom + 0.5)
    if not seen[z] then
      seen[z] = true
      list[#list + 1] = z
    end
  end
  table.sort(list)
  return list
end

--- Interpolate { {zoom, delay, time}, ... } (sorted by zoom) at `zoom`; clamped.
function A.TimingForZoom(rows, zoom)
  if not rows or #rows == 0 then
    return nil
  end
  if zoom <= rows[1].zoom then
    return rows[1].delay, rows[1].time
  end
  for i = 2, #rows do
    local lo, hi = rows[i - 1], rows[i]
    if zoom <= hi.zoom then
      local u = (zoom - lo.zoom) / (hi.zoom - lo.zoom)
      return lo.delay + (hi.delay - lo.delay) * u, lo.time + (hi.time - lo.time) * u
    end
  end
  return rows[#rows].delay, rows[#rows].time
end

--- Interpolate { {zoom, path}, ... } (sorted by zoom) at `zoom`, element by element;
--- clamped outside. Returns the path and the nearest row (for its description).
function A.PathForZoom(rows, zoom)
  if not rows or #rows == 0 then
    return nil
  end
  if zoom <= rows[1].zoom then
    return rows[1].path, rows[1]
  end
  for i = 2, #rows do
    local lo, hi = rows[i - 1], rows[i]
    if zoom <= hi.zoom then
      local u = (zoom - lo.zoom) / (hi.zoom - lo.zoom)
      local path = {}
      for k = 1, math.min(#lo.path, #hi.path) do
        path[k] = lo.path[k] + (hi.path[k] - lo.path[k]) * u
      end
      return path, (u < 0.5) and lo or hi
    end
  end
  return rows[#rows].path, rows[#rows]
end

--- Mean on-foot / mounted gain ratio over the captures.
function A.MeanRatio(captures)
  if #captures == 0 then
    return nil
  end
  local sum = 0
  for i = 1, #captures do
    sum = sum + captures[i].ratio
  end
  return sum / #captures
end

---------------------------------------------------------------------------------------
-- Raw capture → normalized capture (used by the calibration recorder)
---------------------------------------------------------------------------------------
--- `samples` = { {t = s, x = screenX, sh = shoulderCVar}, ... } relative to the swap
--- (t < 0 = still mounted). `gMounted` = mounted px per shoulder unit (measured while
--- mounted before the swap; estimated from the pre-swap samples when omitted).
--- Returns a capture, or nil + reason.
function A.NormalizeDismount(samples, zoom, gMounted)
  if not gMounted then
    local sum, n = 0, 0
    for i = 1, #samples do
      local s = samples[i]
      if s.t < -0.02 and s.x and s.sh and abs(s.sh) > 0.2 then
        sum, n = sum + (-s.x / s.sh), n + 1
      end
    end
    if n == 0 then
      return nil, "no mounted samples before the swap"
    end
    gMounted = sum / n
  end
  if abs(gMounted) < 1e-6 then
    return nil, "mounted gain is zero"
  end

  local function At(t)
    local prev
    for i = 1, #samples do
      local s = samples[i]
      if s.x and s.sh and abs(s.sh) > 0.2 then
        if s.t >= t then
          if not prev then
            return nil
          end
          local u = (s.t > prev.t) and (t - prev.t) / (s.t - prev.t) or 0
          return -(prev.x + (s.x - prev.x) * u) / ((prev.sh + (s.sh - prev.sh) * u) * gMounted)
        end
        prev = s
      end
    end
    return prev and (-prev.x / (prev.sh * gMounted)) or nil
  end

  local raw = {}
  for i = 0, floor(HORIZON / SAMPLE_DT + 0.5) do
    raw[i + 1] = At(i * SAMPLE_DT)
  end
  -- Leading gap (the /say bubble shows up after a server round trip, up to ~0.15 s):
  -- ease from the mounted gain; the dip starts smoothly so this is a close fit.
  local firstIdx
  for i = 1, #raw do
    if raw[i] then
      firstIdx = i
      break
    end
  end
  if not firstIdx or firstIdx > 16 then
    return nil, "too few samples right after the swap"
  end
  for i = 1, firstIdx - 1 do
    raw[i] = 1 + (raw[firstIdx] - 1) * ((i - 1) / (firstIdx - 1))
  end
  for i = 2, #raw do
    if not raw[i] then
      raw[i] = raw[i - 1]
    end
  end
  -- 3-tap smoothing against pixel quantization.
  local g = { raw[1] }
  for i = 2, #raw - 1 do
    g[i] = (raw[i - 1] + raw[i] + raw[i + 1]) / 3
  end
  g[#raw] = raw[#raw]

  local capture = { zoom = zoom, dt = SAMPLE_DT, g = g }
  local tail = 0
  for i = #g - 9, #g do
    tail = tail + g[i]
  end
  capture.ratio = tail / 10
  capture.ramp = A.FindRamp(capture)
  if not capture.ramp then
    return nil, "no camera switch found"
  end
  return capture
end

--- Ramp time: first t ≥ 0.05 s where g crosses halfway between its dip and `ratio`.
function A.FindRamp(capture)
  local g, dt = capture.g, capture.dt
  local startIdx = floor(0.05 / dt) + 1
  local dip = math.huge
  for i = startIdx, math.min(#g, floor(0.3 / dt) + 1) do
    if g[i] < dip then
      dip = g[i]
    end
  end
  local mid = (dip + capture.ratio) / 2
  for i = startIdx, #g do
    if g[i] >= mid then
      return (i - 1) * dt
    end
  end
  return nil
end

---------------------------------------------------------------------------------------
-- Dip gain (KNOWLEDGE.md §4, "two clocks")
---------------------------------------------------------------------------------------
-- Dismounting the usual way, the game shows you on foot at once but keeps the mounted
-- camera until the server confirms; meanwhile the screen eases (first order, DIP_TAU,
-- after a frame or two) from the mounted gain to h × the mounted gain.
A.DIP_TAU = 0.065

--- Fit h from a constant-offset dismount: samples { t, x, sh } relative to the swap,
--- tSwitch = when the server confirmed (COMPANION_UPDATE). nil if it can't be measured.
function A.FitDipGain(samples, tSwitch)
  if not tSwitch or tSwitch < 0.08 then
    return nil
  end
  local sum, n, sh0 = 0, 0, nil
  for _, s in ipairs(samples) do
    if s.t and s.x and s.sh and abs(s.sh) > 0.2 and s.t >= -0.4 and s.t <= -0.02 then
      sum, n = sum + s.x / s.sh, n + 1
      sh0 = sh0 or s.sh
    end
  end
  if n < 4 then
    return nil
  end
  local k0 = sum / n -- screen px per offset unit on the mounted camera
  local points = {}
  for _, s in ipairs(samples) do
    if s.t and s.t >= -0.4 and s.t <= tSwitch and s.sh and abs(s.sh - sh0) > 0.01 * abs(sh0) then
      return nil -- the offset moved: only constant-offset dismounts measure the game alone
    end
    if s.t and s.x and s.sh and s.t >= 0.02 and s.t <= tSwitch - 0.01 then
      points[#points + 1] = { s.t, (s.x / s.sh) / k0 }
    end
  end
  if #points < 6 then
    return nil
  end
  -- Least squares for h; the start delay (a frame or two) is searched over 0-30 ms.
  local best, bestErr
  for lat = 0, 0.03, 0.003 do
    local num, den = 0, 0
    for _, pt in ipairs(points) do
      local e = math.exp(-math.max(0, pt[1] - lat) / A.DIP_TAU)
      num = num + (pt[2] - e) * (1 - e)
      den = den + (1 - e) * (1 - e)
    end
    if den > 0 then
      local h = num / den
      local err = 0
      for _, pt in ipairs(points) do
        local e = math.exp(-math.max(0, pt[1] - lat) / A.DIP_TAU)
        local d = pt[2] - (h + (1 - h) * e)
        err = err + d * d
      end
      if not bestErr or err < bestErr then
        best, bestErr = h, err
      end
    end
  end
  if not best or best < 0.15 or best > 1.3 then
    return nil
  end
  return best
end

--- Captures whose size factors agree: the ones within `tolerance` (default 15 %) of the
--- median. Returns the kept list and whether enough agree (at least half) to trust them.
--- (A Thundering Jade Cloud Serpent read 10.8 at zoom 12 and 1.5 at zoom 22: neither.)
function A.ConsistentCaptures(captures, tolerance)
  tolerance = tolerance or 0.15
  local ratios = {}
  for i, c in ipairs(captures) do
    ratios[i] = c.ratio
  end
  table.sort(ratios)
  local n = #ratios
  if n == 0 then
    return {}, false
  end
  local median = n % 2 == 1 and ratios[(n + 1) / 2] or (ratios[n / 2] + ratios[n / 2 + 1]) / 2
  local kept = {}
  for _, c in ipairs(captures) do
    if abs(c.ratio / median - 1) <= tolerance then
      kept[#kept + 1] = c
    end
  end
  return kept, #kept * 2 >= n and #kept > 0
end

--- Dip gain from a dismount played with the two-step plan (offset from / used until the
--- server confirms): the screen heads to h_true / h_used of where it started, through
--- the game's lag (DIP_TAU), so each sample just before the confirmation is projected to
--- where it was going. samples = { t, x } relative to the swap. preX = the screen X
--- before the swap when the bubble wasn't up yet (calibration: the line is said in the
--- same click, so it appears after the swap). nil if it can't tell.
function A.StepDipGain(samples, used, confirmAt, preX)
  if not (used and confirmAt and confirmAt >= 0.06) then
    return nil
  end
  local pre, n = 0, 0
  for _, s in ipairs(samples) do
    if s.x and s.t >= -0.3 and s.t <= -0.02 then
      pre, n = pre + s.x, n + 1
    end
  end
  if n >= 4 then
    pre = pre / n
  elseif preX then
    pre = preX
  else
    return nil
  end
  if abs(pre) < 10 then
    return nil
  end
  local sum, m = 0, 0
  for _, s in ipairs(samples) do
    if s.x and s.t >= confirmAt - 0.03 and s.t <= confirmAt - 0.002 then
      local reached = 1 - math.exp(-math.max(0, s.t - 0.012) / A.DIP_TAU)
      if reached > 0.3 then
        sum, m = sum + (pre + (s.x - pre) / reached), m + 1
      end
    end
  end
  if m < 2 then
    return nil
  end
  local h = used * (sum / m) / pre
  if h < 0.15 or h > 1.3 then
    return nil
  end
  return h
end

--- Size factor from any dismount with a visible bubble: screen px per offset unit on foot
--- (the settled tail, 0.6–1.2 s) over the same while mounted (before the swap). samples =
--- { t, x, sh }. nil if either part is missing or too small to measure.
function A.TestRatio(samples)
  local function Gain(t0, t1)
    local sum, n = 0, 0
    for _, s in ipairs(samples) do
      if s.t and s.x and s.sh and abs(s.sh) > 0.2 and abs(s.x) >= 10 and s.t >= t0 and s.t <= t1 then
        sum, n = sum + s.x / s.sh, n + 1
      end
    end
    return n >= 4 and sum / n or nil
  end
  local mounted, foot = Gain(-0.3, -0.02), Gain(0.6, 1.2)
  if not mounted or not foot or mounted == 0 then
    return nil
  end
  local ratio = foot / mounted
  if ratio < 1.05 or ratio > 40 then
    return nil
  end
  return ratio
end
