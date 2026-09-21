-- HealOnRaid: floating healing numbers on raid/party frames.

local ADDON = ...

-- The public API is a plain table, deliberately kept separate from any frame:
-- a global frame sharing the addon's name is what the client was flagging as a
-- protected action.
local HOR = {}
_G.HealOnRaid = HOR

-- Unnamed, so it can never collide with a protected global.
local eventFrame = CreateFrame("Frame")

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local defaults = {
	enabled = true,
	-- showOverheal/showPeriodic/showCrit needed the combat log, which this
	-- client forbids; they are kept so the code still reads cleanly if a
	-- future client re-opens it.
	showOverheal = false,
	showPeriodic = false,
	showCrit = false,
	minAmount = 0,          -- hide heals smaller than this
	mergeWindow = 0.25,     -- seconds; heals on the same unit inside this window combine
	duration = 1.5,         -- seconds the text stays up
	rise = 26,              -- pixels the text floats upward
	fontSize = 16,
	xOffset = 0,
	yOffset = 0,
	color = { 0.3, 1.0, 0.3 },
	overhealColor = { 0.6, 0.6, 0.6 },
}

local db

--------------------------------------------------------------------
-- Unit frame discovery
--------------------------------------------------------------------

-- Frames registered by other addons / user config via HealOnRaid:RegisterFrame().
local extraFrames = {}

function HOR:RegisterFrame(frame)
	if type(frame) == "table" and frame.GetObjectType then
		extraFrames[frame] = true
	end
end

local candidates = {}
local candidatesDirty = true

local function addCandidate(frame)
	if frame and frame.GetObjectType then
		candidates[#candidates + 1] = frame
	end
end

local function rebuildCandidates()
	wipe(candidates)

	-- Blizzard compact raid frames (both the flat and the grouped layouts).
	for i = 1, 40 do
		addCandidate(_G["CompactRaidFrame" .. i])
	end
	for group = 1, 8 do
		for member = 1, 5 do
			addCandidate(_G["CompactRaidGroup" .. group .. "Member" .. member])
		end
	end
	for i = 1, 5 do
		addCandidate(_G["CompactPartyFrameMember" .. i])
	end

	-- Classic party/player/target frames.
	for i = 1, 4 do
		addCandidate(_G["PartyMemberFrame" .. i])
	end
	addCandidate(_G.PlayerFrame)
	addCandidate(_G.TargetFrame)
	addCandidate(_G.FocusFrame)

	for frame in pairs(extraFrames) do
		addCandidate(frame)
	end

	candidatesDirty = false
end

local function frameUnit(frame)
	return frame.displayedUnit or frame.unit
end

local function findFrameForGUID(guid)
	if candidatesDirty then
		rebuildCandidates()
	end

	for i = 1, #candidates do
		local frame = candidates[i]
		local unit = frameUnit(frame)
		if unit and frame:IsVisible() and UnitGUID(unit) == guid then
			return frame
		end
	end
end

--------------------------------------------------------------------
-- Floating text pool
--------------------------------------------------------------------

local pool = {}       -- inactive FontStrings
local active = {}     -- active entries: { text, frame, guid, amount, overheal, start, crit }
local byGUID = {}     -- guid -> active entry, for merging

local function acquireText()
	local text = tremove(pool)
	if not text then
		text = UIParent:CreateFontString(nil, "OVERLAY")
	end
	text:SetFont(FONT, db.fontSize, "OUTLINE")
	text:Show()
	return text
end

local function releaseEntry(entry)
	entry.text:Hide()
	entry.text:ClearAllPoints()
	pool[#pool + 1] = entry.text
	if byGUID[entry.guid] == entry then
		byGUID[entry.guid] = nil
	end
end

local function formatAmount(amount)
	if amount >= 1000000 then
		return format("%.1fm", amount / 1000000)
	elseif amount >= 10000 then
		return format("%.1fk", amount / 1000)
	end
	return tostring(amount)
end

local function entryString(entry)
	local s = "+" .. formatAmount(entry.amount)
	if db.showOverheal and entry.overheal > 0 then
		s = s .. " |cff999999(" .. formatAmount(entry.overheal) .. ")|r"
	end
	return s
end

local function layout(entry, elapsed)
	local frame = entry.frame
	if not frame:IsVisible() then
		return false
	end

	local progress = elapsed / db.duration
	local alpha = progress < 0.6 and 1 or (1 - (progress - 0.6) / 0.4)

	entry.text:ClearAllPoints()
	entry.text:SetPoint("CENTER", frame, "CENTER",
		db.xOffset, db.yOffset + db.rise * progress)
	entry.text:SetAlpha(alpha)
	return true
end

local updater = CreateFrame("Frame")
updater:Hide()
updater:SetScript("OnUpdate", function()
	local now = GetTime()
	for i = #active, 1, -1 do
		local entry = active[i]
		local elapsed = now - entry.start
		if elapsed >= db.duration or not layout(entry, elapsed) then
			releaseEntry(entry)
			tremove(active, i)
		end
	end
	if #active == 0 then
		updater:Hide()
	end
end)

local function showHeal(guid, amount, overheal, crit)
	local frame = findFrameForGUID(guid)
	if not frame then
		return
	end

	local now = GetTime()
	local entry = byGUID[guid]

	if entry and entry.frame == frame and (now - entry.start) <= db.mergeWindow then
		entry.amount = entry.amount + amount
		entry.overheal = entry.overheal + overheal
		entry.crit = entry.crit or crit
	else
		entry = {
			text = acquireText(),
			frame = frame,
			guid = guid,
			amount = amount,
			overheal = overheal,
			crit = crit,
			start = now,
		}
		active[#active + 1] = entry
		byGUID[guid] = entry
	end

	local r, g, b = unpack(amount > 0 and db.color or db.overhealColor)
	entry.text:SetTextColor(r, g, b)
	entry.text:SetFont(FONT,
		(db.showCrit and entry.crit) and (db.fontSize * 1.4) or db.fontSize, "OUTLINE")
	entry.text:SetText(entryString(entry))
	layout(entry, now - entry.start)

	updater:Show()
end

--------------------------------------------------------------------
-- Heal detection
--
-- This client (1.60.x) makes registering COMBAT_LOG_EVENT_UNFILTERED a
-- PROTECTED call: it throws ADDON_ACTION_FORBIDDEN and taints the addon for
-- the rest of the session, so the combat log is simply not available to us.
--
-- Instead we infer heals from the player's own cast events and then measure
-- the target's health change. UNIT_SPELLCAST_SENT tells us who a cast was
-- aimed at, UNIT_SPELLCAST_SUCCEEDED tells us it landed, and the health delta
-- over the following moments is the effective healing.
--------------------------------------------------------------------

local playerGUID

-- castGUID -> target name, filled in by UNIT_SPELLCAST_SENT.
local castTargets = {}

-- Heals we are currently measuring the health delta for.
local watching = {}

local WATCH_TIME = 0.7  -- seconds to keep sampling a target's health

local groupUnits = {}

local function rebuildGroupUnits()
	wipe(groupUnits)
	groupUnits[#groupUnits + 1] = "player"
	local raid = IsInRaid() and GetNumGroupMembers() or 0
	if raid > 0 then
		for i = 1, raid do
			groupUnits[#groupUnits + 1] = "raid" .. i
		end
	else
		for i = 1, 4 do
			groupUnits[#groupUnits + 1] = "party" .. i
		end
	end
	groupUnits[#groupUnits + 1] = "target"
end

local function unitForName(name)
	if not name then
		return "player"
	end
	if #groupUnits == 0 then
		rebuildGroupUnits()
	end
	for i = 1, #groupUnits do
		local unit = groupUnits[i]
		if UnitExists(unit) and UnitName(unit) == name then
			return unit
		end
	end
end

-- Sampling loop: for each pending heal, watch the unit's health climb.
local watcher = CreateFrame("Frame")
watcher:Hide()
watcher:SetScript("OnUpdate", function()
	local now = GetTime()
	for i = #watching, 1, -1 do
		local w = watching[i]
		local current = UnitHealth(w.unit)
		local delta = current - w.before
		if delta > w.best then
			w.best = delta
		end

		-- Stop early once the unit is capped: nothing more can be measured.
		if now - w.start >= WATCH_TIME or current >= UnitHealthMax(w.unit) then
			if w.best >= db.minAmount and w.best > 0 then
				showHeal(w.guid, w.best, 0, false)
			end
			tremove(watching, i)
		end
	end
	if #watching == 0 then
		watcher:Hide()
	end
end)

local function onCastSent(unit, target, castGUID)
	if unit ~= "player" then
		return
	end
	castTargets[castGUID or 0] = target
end

local function onCastSucceeded(unit, castGUID)
	if unit ~= "player" then
		return
	end

	local name = castTargets[castGUID or 0]
	castTargets[castGUID or 0] = nil

	local target = unitForName(name)
	if not target or not UnitExists(target) then
		return
	end
	-- Only friendly targets can be healed; this filters out damage casts.
	if not UnitIsFriend("player", target) then
		return
	end

	local guid = UnitGUID(target)
	if not guid then
		return
	end

	watching[#watching + 1] = {
		unit = target,
		guid = guid,
		before = UnitHealth(target),
		best = 0,
		start = GetTime(),
	}
	watcher:Show()
end

--------------------------------------------------------------------
-- Events
--------------------------------------------------------------------

local function applyDefaults()
	HealOnRaidDB = HealOnRaidDB or {}
	db = HealOnRaidDB
	for key, value in pairs(defaults) do
		if db[key] == nil then
			if type(value) == "table" then
				db[key] = { unpack(value) }
			else
				db[key] = value
			end
		end
	end
	HOR.db = db
end

-- Every event this addon will ever want is registered once, here at load time.
-- Nothing is registered or unregistered from inside a handler, and enabling or
-- disabling the display is a flag check rather than a RegisterEvent call.
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- COMBAT_LOG_EVENT_UNFILTERED is deliberately NOT registered: on this client
-- that call is forbidden and taints the addon for the session.
eventFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
	if event == "UNIT_SPELLCAST_SENT" then
		if db and db.enabled then
			onCastSent(arg1, arg2, arg3)
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if db and db.enabled then
			onCastSucceeded(arg1, arg2)
		end
	elseif event == "ADDON_LOADED" then
		if arg1 == ADDON then
			applyDefaults()
		end
	elseif event == "PLAYER_LOGIN" then
		playerGUID = UnitGUID("player")
		candidatesDirty = true
		rebuildGroupUnits()
	else
		candidatesDirty = true
		rebuildGroupUnits()
	end
end)

--------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------

local function say(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66HealOnRaid:|r " .. msg)
end

local function onOff(value)
	return value and "|cff66ff66on|r" or "|cffff6666off|r"
end

SLASH_HEALONRAID1 = "/hor"
SLASH_HEALONRAID2 = "/healonraid"
SlashCmdList.HEALONRAID = function(input)
	local cmd, value = input:lower():match("^%s*(%S*)%s*(%S*)%s*$")

	if cmd == "on" or cmd == "off" then
		db.enabled = (cmd == "on")
		say("display " .. onOff(db.enabled))

	elseif cmd == "overheal" or cmd == "hots" then
		-- Both of these needed the combat log, which this client forbids.
		say("|cffff9900not available on this client.|r Overheal amounts and HoT")
		say("ticks are only in the combat log, and registering for it is a")
		say("protected call here. Numbers shown are effective healing only.")

	elseif cmd == "size" and tonumber(value) then
		db.fontSize = tonumber(value)
		say("font size set to " .. db.fontSize)

	elseif cmd == "min" and tonumber(value) then
		db.minAmount = tonumber(value)
		say("minimum heal set to " .. db.minAmount)

	elseif cmd == "test" then
		if not playerGUID then
			return
		end
		showHeal(playerGUID, 742, 158, false)
		say("test heal sent to your own frame")

	else
		say("commands:")
		say("  /hor on|off       - toggle the display (" .. onOff(db.enabled) .. ")")
		say("  /hor overheal     - why overheal is unavailable here")
		say("  /hor size <n>     - font size (" .. db.fontSize .. ")")
		say("  /hor min <n>      - hide heals below n (" .. db.minAmount .. ")")
		say("  /hor test         - show a test heal on your own frame")
	end
end
