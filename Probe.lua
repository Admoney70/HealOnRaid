-- HealOnRaid probe: answers, from inside the running client, which sources of
-- healing data this build will actually hand an addon.
--
-- Everything here is defensive on purpose. Each event registration is pcall'd
-- so a protected one cannot stop the rest, every value is checked with
-- issecretvalue before it is touched, and nothing does arithmetic on anything.
-- Run "/hor probe", cast a few heals, then read the report.

local function say(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66HealOnRaid probe:|r " .. msg)
end

local function isSecret(value)
	if issecretvalue then
		local ok, secret = pcall(issecretvalue, value)
		return ok and secret
	end
	return false
end

local yes, no = "|cff66ff66yes|r", "|cffff6666no|r"

--------------------------------------------------------------------
-- 1. Old-style combat chat events
--------------------------------------------------------------------

-- In vanilla these carried the combat log line as a plain string in arg1.
local chatEvents = {
	"CHAT_MSG_SPELL_SELF_BUFF",
	"CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
	"CHAT_MSG_SPELL_PARTY_BUFF",
	"CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
	"CHAT_MSG_COMBAT_SELF_HITS",
}

local probe = CreateFrame("Frame")
local registered, seen = {}, {}
local running = false

probe:SetScript("OnEvent", function(_, event, arg1)
	if not running or seen[event] then
		return
	end
	seen[event] = true

	if arg1 == nil then
		say(event .. ": fired, but arg1 was nil")
	elseif isSecret(arg1) then
		say(event .. ": fired, but arg1 is |cffff6666secret|r")
	else
		local ok, text = pcall(tostring, arg1)
		if ok then
			say(event .. ": |cff66ff66readable|r ->")
			say("  \"" .. text .. "\"")
			if text:find("%d") then
				say("  |cff66ff66contains digits - real amounts are reachable.|r")
			else
				say("  |cffff9900no digits in the line.|r")
			end
		else
			say(event .. ": fired, but could not be converted to text")
		end
	end
end)

local function startChatProbe()
	for _, event in ipairs(chatEvents) do
		if not registered[event] then
			-- A protected registration must not take the others down with it.
			local ok = pcall(probe.RegisterEvent, probe, event)
			registered[event] = ok
			if not ok then
				say(event .. ": registration |cffff6666forbidden|r")
			end
		end
	end

	local any = false
	for _, ok in pairs(registered) do
		any = any or ok
	end
	if any then
		say("listening. Cast a few direct heals, then read the lines above.")
		say("Silence means these events no longer fire on this client.")
	else
		say("no combat chat event could be registered at all.")
	end
end

--------------------------------------------------------------------
-- 2. C_DamageMeter, Blizzard's own server-side meter
--------------------------------------------------------------------

local function probeDamageMeter()
	if type(C_DamageMeter) ~= "table" then
		say("C_DamageMeter: " .. no .. " (not present on this client)")
		return
	end

	say("C_DamageMeter: " .. yes .. " - functions it exposes:")
	local names = {}
	for key, value in pairs(C_DamageMeter) do
		if type(value) == "function" then
			names[#names + 1] = key
		end
	end
	table.sort(names)
	if #names == 0 then
		say("  (none readable)")
	end
	for i = 1, #names do
		say("  " .. names[i])
	end
	say("report these back - they decide whether real amounts are possible.")
end

--------------------------------------------------------------------
-- 3. Can a secret number be drawn as text at all?
--------------------------------------------------------------------

local function probeDisplay()
	if not UnitHealth then
		return
	end
	local value = UnitHealth("player")
	if not isSecret(value) then
		say("UnitHealth: |cff66ff66not secret here|r - amounts may be computable.")
		return
	end

	say("UnitHealth: secret, as expected. Can a secret still be drawn?")

	local fs = UIParent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")

	local ok = pcall(fs.SetText, fs, value)
	say("  FontString:SetText(secret): " .. (ok and yes or no))

	local okFmt = pcall(fs.SetFormattedText, fs, "%s", value)
	say("  FontString:SetFormattedText(secret): " .. (okFmt and yes or no))

	fs:Hide()

	if ok or okFmt then
		say("  |cff66ff66a secret number CAN be drawn - amounts are displayable|r")
		say("  even though the addon may never read or sum them.")
	else
		say("  |cffff9900secrets cannot be drawn as text; numbers are out.|r")
	end
end

function HealOnRaid_RunProbe()
	running = true
	say("--- checking what this client allows ---")
	probeDamageMeter()
	probeDisplay()
	startChatProbe()
end
