-- OpenLayer. Session layer list, one silent hop shout, shard-move line.
-- Layer id is server-zoneUID from Creature-0-server-instance-zoneUID-npc-spawn.

local ADDON = ...
local PREFIX = "OpenLayer"
local LT_PREFIX = "LYRTRK1"
local CHANNEL = "layer"
local HOST_TTL, FRESH, DROP = 120, 600, 3600
local PRESENCE = 60
local REQUEST = 90

local issecretvalue = issecretvalue
local function isSecret(v)
	return issecretvalue and issecretvalue(v) and true or false
end

local function say(text)
	print("|cffffcc00OpenLayer|r " .. text)
end

local function bare(name)
	if isSecret(name) or type(name) ~= "string" or name == "" then return end
	return (strsplit("-", name))
end

local function myName()
	local first, sur = UnitName("player")
	if isSecret(first) or type(first) ~= "string" or first == "" then return end
	if not isSecret(sur) and type(sur) == "string" and sur ~= "" and not string.find(first, sur, 1, true) then
		return first .. " " .. sur
	end
	return first
end

local function mapHere()
	local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if isSecret(id) or type(id) ~= "number" or id <= 0 then return end
	return id
end

local function clock(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local db
local layers = {}
local current
local vote
local used, lastHost = {}, nil
local request
local evictAt, fromNum, pendingLand
local lastPresence = 0
local toldBlock
local shardText, noteUntil

local square, menu, note
local buttons = {}

local COLOR = {
	green = { 0.15, 0.55, 0.2 },
	orange = { 0.85, 0.45, 0.05 },
	red = { 0.45, 0.12, 0.12 },
}

local function status(row)
	if not row then return end
	local now = GetServerTime()
	local age = now - (row.seen or 0)
	if age > DROP then return end
	if age > FRESH then return "red" end
	for _, rec in pairs(row.who) do
		if rec.host and now - rec.t < HOST_TTL then return "green" end
	end
	return "orange"
end

local function zoneList(map)
	local ids, zs = {}, layers[map]
	if not zs then return ids end
	local now = GetServerTime()
	for zone, row in pairs(zs) do
		if now - (row.seen or 0) <= DROP then ids[#ids + 1] = zone end
	end
	table.sort(ids)
	return ids
end

local function layerNum(map, zone)
	for i, id in ipairs(zoneList(map)) do
		if id == zone then return i end
	end
end

local function rowFor(map, zone, server)
	map, zone = tonumber(map), tonumber(zone)
	if not map or not zone or zone <= 0 then return end
	local zs = layers[map]
	if not zs then
		zs = {}
		layers[map] = zs
	end
	local row = zs[zone]
	if not row then
		row = { seen = 0, who = {} }
		zs[zone] = row
	end
	if type(server) == "string" and server ~= "" and server ~= "0" then row.server = server end
	return row
end

local function expire()
	local now = GetServerTime()
	for map, zs in pairs(layers) do
		for zone, row in pairs(zs) do
			if now - (row.seen or 0) > DROP then zs[zone] = nil end
		end
		if not next(zs) then layers[map] = nil end
	end
end

local function refresh()
	if square then
		local n = current and layerNum(current.map, current.zone)
		square.text:SetText(n and tostring(n) or "")
	end
	if menu and menu:IsShown() and menu.paint then menu.paint() end
end

local function noteSeen(map, zone, server, time)
	local row = rowFor(map, zone, server)
	if row and time and time > (row.seen or 0) then
		row.seen = time
		refresh()
	end
end

local function noteWho(map, zone, server, name, host, time)
	name = bare(name)
	local row = rowFor(map, zone, server)
	if not row or not name or not time then return end
	local now = GetServerTime()
	if time > now + 30 then time = now end
	local prev = row.who[name]
	if prev and time <= prev.t then return end
	row.who[name] = { t = time, host = host and true or false }
	if time > (row.seen or 0) then row.seen = time end
	refresh()
end

local function notice(text)
	say(text)
	if note then
		note:SetText(text)
		noteUntil = GetTime() + 20
	end
end

local function sendAddon(msg)
	local fn = C_ChatInfo and C_ChatInfo.SendAddonMessage
	if not fn then return end
	local id = GetChannelName(CHANNEL)
	if id and id ~= 0 then pcall(fn, PREFIX, msg, "CHANNEL", id) end
	if IsInGuild() then pcall(fn, PREFIX, msg, "GUILD") end
end

local function publish(force)
	if not current then return end
	local now = GetServerTime()
	if not force and now - lastPresence < PRESENCE then return end
	lastPresence = now
	noteWho(current.map, current.zone, current.server, myName(), db.hosting, now)
	sendAddon(string.format("P:%d:%d:%s:%d:%d", current.map, current.zone, current.server or "0", db.hosting and 1 or 0, now))
end

local function setCurrent(map, zone, server)
	local prev = current
	current = { map = map, zone = zone, server = server or "0" }
	vote = nil
	if not prev or prev.zone ~= zone or prev.server ~= current.server or prev.map ~= map then
		publish(true)
	end
	if pendingLand and GetTime() - pendingLand.at < 120 then
		local n = layerNum(map, zone)
		local text = "Layer " .. (pendingLand.from or "?") .. " -> " .. (n or "?")
		if pendingLand.wantZone and pendingLand.wantZone ~= zone then
			text = text .. " (asked for " .. (pendingLand.wantNum or "?") .. ")"
		end
		pendingLand = nil
		request = nil
		notice(text)
	end
	refresh()
end

local function clearCurrent()
	current = nil
	vote = nil
	refresh()
end

local function readUnit(unit)
	if not UnitExists(unit) or (UnitPlayerControlled and UnitPlayerControlled(unit)) then return end
	local guid = UnitGUID(unit)
	if isSecret(guid) or type(guid) ~= "string" then return end
	local kind, _, server, _, zoneUID, npc = strsplit("-", guid)
	if kind ~= "Creature" and kind ~= "Vehicle" then return end
	zoneUID = tonumber(zoneUID)
	if not server or server == "" or not zoneUID or zoneUID == 0 then return end
	return server, zoneUID, npc, guid
end

local function observe(unit)
	if IsInInstance() or (UnitOnTaxi and UnitOnTaxi("player")) then return end
	local server, zone, _, guid = readUnit(unit)
	if not server then return end
	local map = mapHere()
	if not map then return end
	noteSeen(map, zone, server, GetServerTime())
	if current and current.map == map and current.zone == zone and current.server == server then
		publish(false)
		return
	end
	if not vote or vote.id ~= server .. "-" .. zone then
		vote = { id = server .. "-" .. zone, guid = guid, n = 1, map = map, zone = zone, server = server }
		return
	end
	if vote.guid == guid then return end
	vote.n = 2
	setCurrent(map, zone, server)
end

local function scanPlates()
	if not C_NamePlate or not C_NamePlate.GetNamePlates then return end
	local ok, plates = pcall(C_NamePlate.GetNamePlates)
	if not ok or type(plates) ~= "table" then return end
	for _, plate in ipairs(plates) do
		local unit = plate.namePlateUnitToken or plate.unitToken
		if unit and not isSecret(unit) then observe(unit) end
	end
end

local function hostToken(kind, zone, server)
	local now, best, bestT = GetServerTime()
	local me = bare(myName())
	for _, zs in pairs(layers) do
		for z, row in pairs(zs) do
			local hit
			if kind == "W" then
				hit = z == zone and (server == "0" or not row.server or row.server == server)
			else
				hit = not (current and z == current.zone and row.server == current.server)
			end
			if hit then
				for name, rec in pairs(row.who) do
					if rec.host and now - rec.t < HOST_TTL and not used[name] and name ~= me then
						if not bestT or rec.t > bestT then best, bestT = name, rec.t end
					end
				end
			end
		end
	end
	if best then
		used[best] = true
		lastHost = best
		return best
	end
	if lastHost then return "!" .. lastHost end
end

local function channelReady()
	local id = GetChannelName(CHANNEL)
	if id and id ~= 0 then return true end
	pcall(JoinChannelByName, CHANNEL)
	say("Joined the layer channel. Try again.")
	return false
end

local function ask(kind, zone, server, num)
	if IsInGroup() then say("You are in a group."); return end
	if not current then say("Layer unknown. Target an NPC."); return end
	if not channelReady() then return end
	server = server or current.server or "0"
	local token = hostToken(kind, zone, server)
	local msg = string.format("%s:%d:%d:%s", kind, current.map, zone, server)
	if token then msg = msg .. ":" .. token end
	sendAddon(msg)
	request = { at = GetTime(), zone = zone, num = num, kind = kind }
	notice(num and ("Asked for layer " .. num) or "Asked for another layer")
end

local function askNumber(num)
	if not current then say("Layer unknown. Target an NPC."); return end
	local ids = zoneList(current.map)
	local zone = ids[num]
	if not zone then say("No layer " .. num); return end
	local row = layers[current.map][zone]
	if zone == current.zone and (not row.server or row.server == current.server) then
		say("Already on layer " .. num)
		return
	end
	ask("W", zone, row.server or "0", num)
end

local function askAny()
	if not current then say("Layer unknown. Target an NPC."); return end
	ask("A", current.zone, current.server or "0", nil)
end

local function onAsk(kind, map, zone, server, token, sender)
	if not db.hosting or IsInGroup() or IsInInstance() or not current then return end
	local me = bare(myName())
	local them = bare(sender)
	if not them or them == me then return end
	if type(token) == "string" and token ~= "" then
		if string.sub(token, 1, 1) == "!" then
			if bare(string.sub(token, 2)) == me then return end
		elseif bare(token) ~= me then
			return
		end
	end
	zone = tonumber(zone)
	if kind == "W" then
		if current.zone ~= zone then return end
		if server ~= "0" and current.server ~= server then return end
	elseif kind == "A" then
		if current.zone == zone and current.server == server then return end
	else
		return
	end
	local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
	if fn then pcall(fn, sender) end
end

local function onSync(prefix, msg, sender)
	if isSecret(prefix) or isSecret(msg) or type(msg) ~= "string" then return end
	if prefix == LT_PREFIX then
		local cmd, map, zone = strsplit(":", msg)
		if cmd == "S" then noteSeen(map, zone, nil, GetServerTime()) end
		return
	end
	if prefix ~= PREFIX or bare(sender) == bare(myName()) then return end
	local kind, map, zone, server, extra, time = strsplit(":", msg)
	if kind == "P" then
		noteWho(map, zone, server, sender, extra == "1", tonumber(time) or GetServerTime())
	elseif kind == "W" or kind == "A" then
		onAsk(kind, map, zone, server, extra, sender)
	end
end

local function setShard(text)
	if shardText then shardText:SetText(text or "") end
end

local function hookShard()
	if shardText or not ShardTransferImminentFrame then return end
	shardText = ShardTransferImminentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	shardText:SetPoint("BOTTOM", ShardTransferImminentFrame, "BOTTOM", 0, 14)
end

local function paintSquare()
	local n = current and layerNum(current.map, current.zone)
	square.text:SetText(n and tostring(n) or "")
end

local function showTip()
	GameTooltip:SetOwner(square, "ANCHOR_RIGHT")
	GameTooltip:SetText("OpenLayer", 1, 1, 1)
	if current then
		local n = layerNum(current.map, current.zone)
		GameTooltip:AddLine("Layer " .. (n or "?"), 1, 0.82, 0)
		GameTooltip:AddLine((current.server or "?") .. "-" .. current.zone, 0.8, 0.8, 0.8)
		GameTooltip:AddLine(GetRealZoneText() or "", 0.8, 0.8, 0.8)
	else
		GameTooltip:AddLine("No layer yet", 0.8, 0.8, 0.8)
	end
	GameTooltip:AddLine(db.hosting and "Hosting on" or "Hosting off", 0.8, 0.8, 0.8)
	if evictAt and evictAt > GetTime() then
		GameTooltip:AddLine("Moving in " .. clock(evictAt - GetTime()), 1, 0.8, 0.2)
	end
	local lt = _G.LayerTracker_CurrentLayer
	if type(lt) == "number" and lt > 0 then
		GameTooltip:AddLine("LayerTracker " .. lt, 0.7, 0.7, 0.7)
	end
	GameTooltip:AddLine("Click for layers", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function button(i)
	local b = buttons[i]
	if b then return b end
	b = CreateFrame("Button", nil, menu)
	b:SetHeight(18)
	b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 18)
	b:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 18)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0.1, 0.1, 0.1, 0.95)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.18)
	b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.label:SetPoint("LEFT", 4, 0)
	b.label:SetPoint("RIGHT", -4, 0)
	b.label:SetJustifyH("LEFT")
	b:SetScript("OnClick", function(self) if self.fn then self.fn() end end)
	buttons[i] = b
	return b
end

local function paintMenu()
	local rows = {}
	if current then
		for i, zone in ipairs(zoneList(current.map)) do
			local row = layers[current.map][zone]
			rows[#rows + 1] = { zone = zone, num = i, row = row, st = status(row) or "red" }
		end
	end
	local n = #rows + 1
	for i = 1, n do
		local b = button(i)
		b:Show()
		if i <= #rows then
			local item = rows[i]
			local c = COLOR[item.st]
			b.bg:SetColorTexture(c[1], c[2], c[3], 0.95)
			local here = current and item.zone == current.zone and (not item.row.server or item.row.server == current.server)
			b.label:SetText(here and (item.num .. "  you") or tostring(item.num))
			b.fn = (item.st == "red" or here) and nil or function()
				menu:Hide()
				ask("W", item.zone, item.row.server or "0", item.num)
			end
		else
			b.bg:SetColorTexture(0.12, 0.12, 0.12, 0.95)
			b.label:SetText(db.hosting and "Hosting: on" or "Hosting: off")
			b.fn = function()
				db.hosting = not db.hosting
				publish(true)
				paintMenu()
			end
		end
	end
	for i = n + 1, #buttons do buttons[i]:Hide() end
	menu:SetSize(120, 8 + n * 18)
end

local function toggleMenu()
	if menu:IsShown() then menu:Hide(); return end
	paintMenu()
	menu:Show()
end

local function buildUI()
	square = CreateFrame("Button", "OpenLayerSquare", UIParent)
	square:SetSize(28, 28)
	square:SetFrameStrata("MEDIUM")
	square:SetClampedToScreen(true)
	square:SetMovable(true)
	square:RegisterForDrag("LeftButton")
	square:RegisterForClicks("LeftButtonUp")
	local edge = square:CreateTexture(nil, "BACKGROUND")
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)
	edge:SetColorTexture(1, 1, 1, 0.45)
	local bg = square:CreateTexture(nil, "BORDER")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.88)
	square.text = square:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	square.text:SetPoint("CENTER")
	note = square:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	note:SetPoint("TOP", square, "BOTTOM", 0, -4)
	note:SetJustifyH("CENTER")
	local point = db.point
	if type(point) == "table" and type(point[1]) == "string" and type(point[3]) == "number" and type(point[4]) == "number" then
		square:SetPoint(point[1], UIParent, point[2] or point[1], point[3], point[4])
	else
		square:SetPoint("TOP", UIParent, "TOP", 0, -80)
	end
	square:SetScript("OnDragStart", function(self) self.moved = true; self:StartMoving() end)
	square:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rel, x, y = self:GetPoint()
		db.point = { p, rel, x, y }
	end)
	square:SetScript("OnClick", function(self)
		if self.moved then self.moved = nil; return end
		toggleMenu()
	end)
	square:SetScript("OnEnter", showTip)
	square:SetScript("OnLeave", function() GameTooltip:Hide() end)

	menu = CreateFrame("Frame", "OpenLayerMenu", UIParent)
	menu:SetFrameStrata("DIALOG")
	menu:SetClampedToScreen(true)
	menu:SetPoint("TOPLEFT", square, "TOPRIGHT", 6, 0)
	menu.bg = menu:CreateTexture(nil, "BACKGROUND")
	menu.bg:SetAllPoints()
	menu.bg:SetColorTexture(0, 0, 0, 0.92)
	menu.paint = paintMenu
	menu:Hide()
	paintSquare()
end

local function tick()
	expire()
	if evictAt then
		local left = evictAt - GetTime()
		if left > -30 then
			local n = fromNum or (current and layerNum(current.map, current.zone))
			local label = n and ("Leaving layer " .. n) or "Leaving layer"
			setShard(left > 0 and (label .. "  " .. clock(left)) or label)
		else
			evictAt = nil
			setShard("")
		end
	end
	if noteUntil and GetTime() > noteUntil then
		note:SetText("")
		noteUntil = nil
	end
	if current then publish(false) end
	if menu and menu:IsShown() then paintMenu() end
	if square and GameTooltip:IsOwned(square) then showTip() end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PARTY_INVITE_REQUEST")
pcall(f.RegisterEvent, f, "SHARD_TRANSFER_IMMINENT")
pcall(f.RegisterEvent, f, "SHARD_TRANSFER")
f:RegisterEvent("ADDON_ACTION_BLOCKED")
f:RegisterEvent("ADDON_ACTION_FORBIDDEN")

f:SetScript("OnEvent", function(_, event, ...)
	local a1, a2 = ...
	if event == "ADDON_LOADED" then
		if a1 ~= ADDON then
			hookShard()
			return
		end
		OpenLayerDB = OpenLayerDB or {}
		if OpenLayerDB.hosting == nil then OpenLayerDB.hosting = true end
		db = OpenLayerDB
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
			pcall(C_ChatInfo.RegisterAddonMessagePrefix, LT_PREFIX)
		end
		buildUI()
		hookShard()
	elseif event == "PLAYER_LOGIN" then
		hookShard()
		C_Timer.NewTicker(1, tick)
	elseif not db then
		return
	elseif event == "PLAYER_TARGET_CHANGED" then
		observe("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		observe("mouseover")
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		if not isSecret(a1) then observe(a1) end
	elseif event == "ZONE_CHANGED_NEW_AREA" or event == "SHARD_TRANSFER" then
		if event == "SHARD_TRANSFER" then
			local n = current and layerNum(current.map, current.zone)
			local hop = request and (GetTime() - request.at) <= REQUEST and request.kind == "W" and request or nil
			pendingLand = {
				at = GetTime(),
				from = fromNum or n,
				wantZone = hop and hop.zone or nil,
				wantNum = hop and hop.num or nil,
			}
			evictAt = nil
			fromNum = nil
			setShard("")
		end
		clearCurrent()
		C_Timer.After(1, scanPlates)
	elseif event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(1, scanPlates)
	elseif event == "SHARD_TRANSFER_IMMINENT" then
		hookShard()
		fromNum = current and layerNum(current.map, current.zone)
		local left = type(GetEvictionTimeRemaining) == "function" and GetEvictionTimeRemaining() or nil
		if not isSecret(left) and type(left) == "number" then evictAt = GetTime() + left end
		tick()
	elseif event == "CHAT_MSG_ADDON" then
		onSync(a1, a2, select(4, ...))
	elseif event == "PARTY_INVITE_REQUEST" then
		if request and GetTime() - request.at <= REQUEST and not isSecret(a1) then
			local who = bare(a1)
			if who then used[who] = true; lastHost = who end
			pcall(AcceptGroup)
			pcall(StaticPopup_Hide, "PARTY_INVITE")
		end
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if a1 == ADDON and not toldBlock then
			toldBlock = true
			say("The game blocked " .. tostring(a2))
		end
	end
end)

SLASH_OPENLAYER1 = "/ol"
SLASH_OPENLAYER2 = "/openlayer"
SlashCmdList.OPENLAYER = function(msg)
	if not db then return end
	msg = string.lower(strtrim(msg or ""))
	if msg == "host" then
		db.hosting = not db.hosting
		publish(true)
		say(db.hosting and "Hosting on." or "Hosting off.")
		if menu and menu:IsShown() then paintMenu() end
	else
		toggleMenu()
	end
end

SLASH_LAYERME1 = "/layerme"
SlashCmdList.LAYERME = function(msg)
	if not db then return end
	msg = strtrim(msg or "")
	if msg == "" then askAny(); return end
	local num = tonumber(msg)
	if num and num >= 1 then askNumber(math.floor(num)) else say("Usage: /layerme [number]") end
end
