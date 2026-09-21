-- HealOnRaid: shows where your healing is landing, on the raid/party frames.
--
-- NOTE ON WHY THERE ARE NO NUMBERS. This client (1.60.x) has two restrictions
-- that together make healing amounts unobtainable by an addon:
--   1. Registering COMBAT_LOG_EVENT_UNFILTERED is a protected call. It throws
--      ADDON_ACTION_FORBIDDEN and taints the addon for the session.
--   2. UnitHealth() and friends return "secret values". Addon code may store
--      and pass them, but may not do arithmetic on them, compare them, or even
--      run tostring()/format() on them.
-- So neither the amounts themselves nor a health delta standing in for them
-- can be read, and a secret number cannot be turned into text to display.
-- What is still allowed is knowing WHICH spell you cast and WHO it landed on,
-- which is what this addon shows.

local ADDON = ...

-- The public API is a plain table, deliberately kept separate from any frame:
-- a global frame sharing the addon's name is what the client was flagging as a
-- protected action.
local HOR = {}
_G.HealOnRaid = HOR

-- Unnamed, so it can never collide with a protected global.
local eventFrame = CreateFrame("Frame")

local floor = math.floor

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local defaults = {
	enabled = true,
	showSelfHeals = true,   -- include heals you cast on yourself
	showEstimate = true,    -- prefix the spell's tooltip heal figure, if readable
	dbVersion = 3,          -- bumped when defaults change meaningfully
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

local function entryString(entry)
	return entry.label
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

-- label is an ordinary string (a spell name); never a secret value.
local function showHeal(guid, label)
	local frame = findFrameForGUID(guid)
	if not frame then
		return
	end

	local now = GetTime()
	local entry = byGUID[guid]

	if entry and entry.frame == frame and (now - entry.start) <= db.mergeWindow then
		-- Same target again in quick succession: just refresh the label.
		entry.label = label
		entry.start = now
	else
		entry = {
			text = acquireText(),
			frame = frame,
			guid = guid,
			label = label,
			start = now,
		}
		active[#active + 1] = entry
		byGUID[guid] = entry
	end

	entry.text:SetTextColor(unpack(db.color))
	entry.text:SetFont(FONT, db.fontSize, "OUTLINE")
	entry.text:SetText(entryString(entry))
	layout(entry, now - entry.start)

	updater:Show()
end

--------------------------------------------------------------------
-- Heal detection
--
-- Cast events are ordinary, non-secret data, so this is the one avenue left:
-- UNIT_SPELLCAST_SENT tells us who a cast was aimed at, UNIT_SPELLCAST_SUCCEEDED
-- tells us it landed. No health is ever read, because health is secret.
--
-- The API cannot tell us whether a spell heals, so we match against a list of
-- known healing spells. These are English names; use "/hor add <name>" on a
-- non-English client or for anything missing.
--------------------------------------------------------------------

local playerGUID

-- Direct, hard-cast heals only. HoTs, channels and totems are deliberately
-- absent: they have no per-tick cast event, so nothing could be shown for them
-- anyway, and their tooltip figure describes the whole duration rather than the
-- cast, which would make the estimate below misleading.
local healSpells = {
	-- Priest
	["Lesser Heal"] = true, ["Heal"] = true, ["Greater Heal"] = true,
	["Flash Heal"] = true, ["Holy Nova"] = true,
	-- Druid
	["Healing Touch"] = true, ["Regrowth"] = true,
	-- Paladin
	["Holy Light"] = true, ["Flash of Light"] = true, ["Lay on Hands"] = true,
	-- Shaman
	["Healing Wave"] = true, ["Lesser Healing Wave"] = true, ["Chain Heal"] = true,
}

local function isHealSpell(name)
	if not name then
		return false
	end
	return healSpells[name] or (db.customSpells and db.customSpells[name]) or false
end

--------------------------------------------------------------------
-- Tooltip estimate
--
-- A spell's tooltip states what it heals for, already adjusted for your
-- +healing gear, and it is static spell data rather than unit state, so it is
-- not expected to be secret. "Not expected" is doing real work in that
-- sentence, though: if this client does make it secret, or the wording does
-- not parse, every step below fails soft and we fall back to the spell name
-- alone. Nothing here is ever allowed to raise.
--
-- This is an ESTIMATE of the cast, not healing done: it cannot know crits,
-- and it cannot know how much was wasted as overheal.
--------------------------------------------------------------------

local scanner
local estimateCache = {}

local function isSecret(value)
	if issecretvalue then
		local ok, secret = pcall(issecretvalue, value)
		return ok and secret
	end
	return false
end

-- Returns the midpoint of the healing range in a spell's tooltip, or nil.
local function readEstimate(spellID)
	if estimateCache[spellID] ~= nil then
		return estimateCache[spellID] or nil
	end

	local result
	local ok = pcall(function()
		if not scanner then
			scanner = CreateFrame("GameTooltip", "HealOnRaidScanner", nil, "GameTooltipTemplate")
		end
		scanner:SetOwner(UIParent, "ANCHOR_NONE")
		scanner:ClearLines()
		scanner:SetSpellByID(spellID)

		for i = 1, scanner:NumLines() do
			local line = _G["HealOnRaidScannerTextLeft" .. i]
			local text = line and line:GetText()
			if text and not isSecret(text) then
				-- "Heals a friendly target for 624 to 724." -> 624, 724
				local low, high = text:match("(%d+)%s+%D+%s+(%d+)")
				if low and high then
					result = floor((tonumber(low) + tonumber(high)) / 2)
					break
				end
				-- Single-figure wordings, e.g. "Heals the target for 1500."
				local single = text:match("[Hh]eal%D+(%d+)")
				if single then
					result = tonumber(single)
					break
				end
			end
		end
	end)

	estimateCache[spellID] = (ok and result) or false
	return estimateCache[spellID] or nil
end

-- castGUID -> target name, filled in by UNIT_SPELLCAST_SENT.
local castTargets = {}

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
		return "player"   -- a cast with no target is a self-cast
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

local function onCastSent(unit, target, castGUID)
	if unit ~= "player" then
		return
	end
	castTargets[castGUID or 0] = target
end

local function onCastSucceeded(unit, castGUID, spellID)
	if unit ~= "player" then
		return
	end

	local name = castTargets[castGUID or 0]
	castTargets[castGUID or 0] = nil

	local spellName = GetSpellInfo(spellID)
	if not isHealSpell(spellName) then
		return
	end

	local target = unitForName(name)
	if not target or not UnitExists(target) or not UnitIsFriend("player", target) then
		return
	end
	if UnitIsUnit(target, "player") and not db.showSelfHeals then
		return
	end

	local guid = UnitGUID(target)
	if not guid then
		return
	end

	local label = spellName
	if db.showEstimate then
		local estimate = readEstimate(spellID)
		if estimate then
			label = "~" .. estimate .. "  |cff88cc88" .. spellName .. "|r"
		end
	end
	showHeal(guid, label)
end

--------------------------------------------------------------------
-- Events
--------------------------------------------------------------------

local function applyDefaults()
	HealOnRaidDB = HealOnRaidDB or {}
	-- Settings from before the client's restrictions were understood refer to
	-- features that cannot exist; start those profiles over.
	if HealOnRaidDB.dbVersion ~= defaults.dbVersion then
		wipe(HealOnRaidDB)
	end
	db = HealOnRaidDB
	db.customSpells = db.customSpells or {}
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
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
	if event == "UNIT_SPELLCAST_SENT" then
		if db and db.enabled then
			onCastSent(arg1, arg2, arg3)
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if db and db.enabled then
			onCastSucceeded(arg1, arg2, arg3)
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "SPELLS_CHANGED" then
		wipe(estimateCache)
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

	elseif cmd == "overheal" or cmd == "hots" or cmd == "min" or cmd == "amounts" then
		say("|cffff9900Healing amounts are not obtainable on this client.|r")
		say("The combat log is a protected registration, and UnitHealth returns")
		say("a secret value that addons may not do arithmetic on or convert to")
		say("text. What is shown is the spell you cast, plus the figure from its")
		say("own tooltip where readable - an estimate of the cast, not healing")
		say("done: it cannot know crits or how much was wasted as overheal.")

	elseif cmd == "add" and value ~= "" then
		-- Rest of the line, so multi-word spell names work.
		local spell = input:match("^%s*%S+%s+(.-)%s*$")
		db.customSpells[spell] = true
		say("'" .. spell .. "' will now be shown as a heal.")

	elseif cmd == "probe" then
		if HealOnRaid_RunProbe then
			HealOnRaid_RunProbe()
		else
			say("probe module not loaded")
		end

	elseif cmd == "estimate" then
		db.showEstimate = not db.showEstimate
		wipe(estimateCache)
		say("tooltip estimate " .. onOff(db.showEstimate))

	elseif cmd == "diag" then
		say("client readability check:")
		local spellID = tonumber(value)
		if not spellID then
			say("  usage: /hor diag <spellID of a heal you know>")
			say("  a rank's ID is in its tooltip on wowhead, e.g. 2061 Flash Heal")
		else
			wipe(estimateCache)   -- a diagnostic must never report a cached miss
			local name = GetSpellInfo(spellID)
			say("  spell: " .. (name or "|cffff6666unknown id|r"))
			local estimate = readEstimate(spellID)
			if estimate then
				say("  tooltip figure: |cff66ff66" .. estimate .. "|r - estimates work here")
			else
				say("  tooltip figure: |cffff6666unreadable|r - either secret on this")
				say("  client or an unrecognised wording; spell names only.")
			end
		end

	elseif cmd == "self" then
		db.showSelfHeals = not db.showSelfHeals
		say("self-heals " .. onOff(db.showSelfHeals))

	elseif cmd == "size" and tonumber(value) then
		db.fontSize = tonumber(value)
		say("font size set to " .. db.fontSize)

	elseif cmd == "test" then
		if not playerGUID then
			return
		end
		showHeal(playerGUID, "Flash Heal")
		say("test heal sent to your own frame")

	else
		say("commands:")
		say("  /hor on|off       - toggle the display (" .. onOff(db.enabled) .. ")")
		say("  /hor amounts      - why no numbers are shown on this client")
		say("  /hor estimate     - toggle the tooltip figure (" .. onOff(db.showEstimate) .. ")")
		say("  /hor diag <id>    - test whether tooltip figures are readable")
		say("  /hor probe        - report what heal data this client allows")
		say("  /hor self         - toggle self-heals (" .. onOff(db.showSelfHeals) .. ")")
		say("  /hor add <spell>  - treat another spell as a heal")
		say("  /hor size <n>     - font size (" .. db.fontSize .. ")")
		say("  /hor test         - show a test heal on your own frame")
	end
end
