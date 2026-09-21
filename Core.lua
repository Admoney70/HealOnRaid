-- HealOnRaid: floating healing numbers on raid/party frames.

local ADDON = ...

local HOR = CreateFrame("Frame", "HealOnRaid")
_G.HealOnRaid = HOR

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local defaults = {
	enabled = true,
	showOverheal = false,   -- flip on once the basic display is confirmed working
	showPeriodic = true,    -- HoT ticks
	showCrit = true,        -- scale up crits
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
-- Combat log
--------------------------------------------------------------------

local playerGUID

local healEvents = {
	SPELL_HEAL = false,
	SPELL_PERIODIC_HEAL = true,
}

local function onCombatLog()
	local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _,
		_, _, _, amount, overheal, _, crit = CombatLogGetCurrentEventInfo()

	local periodic = healEvents[subevent]
	if periodic == nil then
		return
	end
	if sourceGUID ~= playerGUID then
		return
	end
	if periodic and not db.showPeriodic then
		return
	end

	amount = amount or 0
	overheal = overheal or 0

	local effective = amount - overheal
	if effective < 0 then
		effective = 0
	end

	-- With overheal display off, a fully-overhealed tick is just noise.
	if effective == 0 and not db.showOverheal then
		return
	end
	if effective < db.minAmount then
		return
	end

	showHeal(destGUID, effective, overheal, crit and true or false)
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

HOR:RegisterEvent("ADDON_LOADED")
HOR:RegisterEvent("PLAYER_LOGIN")
HOR:RegisterEvent("GROUP_ROSTER_UPDATE")
HOR:RegisterEvent("PLAYER_ENTERING_WORLD")

HOR:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			applyDefaults()
		end
	elseif event == "PLAYER_LOGIN" then
		playerGUID = UnitGUID("player")
		candidatesDirty = true
		if db.enabled then
			self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		end
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		onCombatLog()
	else
		candidatesDirty = true
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
		if db.enabled then
			HOR:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		else
			HOR:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		end
		say("display " .. onOff(db.enabled))

	elseif cmd == "overheal" then
		db.showOverheal = not db.showOverheal
		say("overheal display " .. onOff(db.showOverheal))

	elseif cmd == "hots" then
		db.showPeriodic = not db.showPeriodic
		say("HoT ticks " .. onOff(db.showPeriodic))

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
		say("  /hor overheal     - toggle overheal numbers (" .. onOff(db.showOverheal) .. ")")
		say("  /hor hots         - toggle HoT ticks (" .. onOff(db.showPeriodic) .. ")")
		say("  /hor size <n>     - font size (" .. db.fontSize .. ")")
		say("  /hor min <n>      - hide heals below n (" .. db.minAmount .. ")")
		say("  /hor test         - show a test heal on your own frame")
	end
end
