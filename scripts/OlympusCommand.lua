local version = "v0.4.4-alpha"

local debug = true

Olympus.OlympusDLL = nil
Olympus.DLLsloaded = false
Olympus.OlympusModPath = os.getenv('DCSOLYMPUS_PATH')..'\\bin\\' 
Olympus.log = mist.Logger:new("Olympus", 'info')

Olympus.unitCounter = 1
Olympus.payloadRegistry = {}

Olympus.missionData = {}
Olympus.unitsData = {}
Olympus.weaponsData = {}

Olympus.unitIndex = 0
Olympus.unitStep = 50
Olympus.units = {}

Olympus.weaponIndex = 0
Olympus.weaponStep = 50
Olympus.weapons = {}

Olympus.missionStartTime = DCS.getRealTime()

function Olympus.debug(message, displayFor)
	if debug == true then
    	trigger.action.outText(message, displayFor)
	end
end

function Olympus.notify(message, displayFor)
    trigger.action.outText(message, displayFor)
end

function Olympus.loadDLLs()
	-- Add the .dll paths
	package.cpath = package.cpath..';'..Olympus.OlympusModPath..'?.dll;'
	
	local status
	status, Olympus.OlympusDLL = pcall(require, 'olympus')
	if status then
		return true
	else
		return false
	end	
end

-- Gets a unit class reference from a given ObjectID (the ID used by Olympus for unit referencing)
function Olympus.getUnitByID(ID)
	return Olympus.units[ID];
end

function Olympus.getCountryIDByCoalition(coalitionString)
	for countryName, countryId in pairs(country.id) do
		if coalition.getCountryCoalition(countryId) == Olympus.getCoalitionIDByCoalition(coalitionString) then
			return countryId
		end
	end
	return 0
end

function Olympus.getCoalitionIDByCoalition(coalitionString)
	local coalitionID = 0
	if coalitionString == "red" then 
		coalitionID = 1
	elseif coalitionString == "blue" then
		coalitionID = 2
	end
	return coalitionID
end

function Olympus.getCoalitionByCoalitionID(coalitionID)
	local coalitionString = "neutral"
	if coalitionID == 1 then 
		coalitionString = "red"
	elseif coalitionID == 2 then
		coalitionString = "blue"
	end
	return coalitionString
end

-- Builds a valid task depending on the provided options
function Olympus.buildEnrouteTask(options)
	local task = nil
	-- Engage specific target by ID. Checks if target exists.
	if options['id'] == 'EngageUnit' and options['targetID'] then
		local target = Olympus.getUnitByID(options['targetID'])
		if target and target:isExist() then
			task = { 
				id = 'EngageUnit', 
				params = { 
					unitId = options['targetID'],
				} 
			}
		end
	-- Start being an active tanker
	elseif options['id'] == 'Tanker' then
		task = { 
			id = 'Tanker', 
			params = {},
		}
	-- Start being an active AWACS
	elseif options['id'] == 'AWACS' then
		task = { 
			id = 'AWACS', 
			params = {},
		}
	end
	return task
end

-- Builds a valid task depending on the provided options
function Olympus.buildTask(groupName, options)
	local task = nil

	local group = Group.getByName(groupName)
	if (Olympus.isArray(options)) then
		local tasks = {}
		for idx, subOptions in pairs(options) do
			tasks[idx] = Olympus.buildTask(groupName, subOptions) or Olympus.buildEnrouteTask(subOptions)
		end
		task = { 
			id = 'ComboTask', 
			params = { 
				tasks = tasks
			} 
		} 
		Olympus.debug(Olympus.serializeTable(task), 30)
	else 
		if options['id'] == 'FollowUnit' and options['leaderID'] and options['offset'] then
			local leader = Olympus.getUnitByID(options['leaderID'])
			if leader and leader:isExist() then
				task = {
					id = 'Follow',
					params = {
						groupId = leader:getGroup():getID(),
						pos = options['offset'],
						lastWptIndexFlag = false,
						lastWptIndex = 1
					}    
				}
			end
		elseif options['id'] == 'Refuel' then
			task = {
				id = 'Refueling', 
				params = {}   
			}
		elseif options['id'] == 'Orbit' then
			task = { 
				id = 'Orbit', 
				params = { 
					pattern = options['pattern'] or "Circle"
				} 
			}
			if options['altitude'] then
				if options ['altitudeType'] then
					if options ['altitudeType'] == "AGL" then
						local groundHeight = 0
						if group then
							local groupPos = mist.getLeadPos(group)
							groundHeight = land.getHeight({x = groupPos.x, y = groupPos.z})
						end
						task['params']['altitude'] = groundHeight + options['altitude']
					else
						task['params']['altitude'] = options['altitude']
					end
				else
					task['params']['altitude'] = options['altitude']
				end
			end
			if options['speed'] then
				task['params']['speed'] = options['speed']
			end
		elseif options['id'] == 'Bombing' and options['lat'] and options['lng'] then
			local point = coord.LLtoLO(options['lat'], options['lng'], 0)
			task = {
				id = 'Bombing', 
				params = {
					point = {x = point.x, y = point.z},
					attackQty = 1
				}   
			}
		elseif options['id'] == 'CarpetBombing' and options['lat'] and options['lng'] then
			local point = coord.LLtoLO(options['lat'], options['lng'], 0)
			task = {
				id = 'CarpetBombing', 
				params = {
					x = point.x,
					y = point.z,
					carpetLength = 1000,
					attackType = 'Carpet',
					expend = "All",
					attackQty = 1,
					attackQtyLimit = true 
				}   
			}
		elseif options['id'] == 'AttackMapObject' and options['lat'] and options['lng'] then
			local point = coord.LLtoLO(options['lat'], options['lng'], 0)
			task = {
				id = 'AttackMapObject', 
				params = {
					point = {x = point.x, y = point.z}
				}   
			}
		elseif options['id'] == 'FireAtPoint' and options['lat'] and options['lng'] and options['radius'] then
			local point = coord.LLtoLO(options['lat'], options['lng'], 0)
			task = {
				id = 'FireAtPoint', 
				params = {
					point = {x = point.x, y = point.z},
					radius = options['radius']
				}   
			}
		end
	end
	return task
end

-- Move a unit. Since many tasks in DCS are Enroute tasks, this function is an important way to control the unit AI
function Olympus.move(groupName, lat, lng, altitude, altitudeType, speed, speedType, category, taskOptions)
    Olympus.debug("Olympus.move " .. groupName .. " (" .. lat .. ", " .. lng ..") " .. altitude .. "m " .. altitudeType .. " ".. speed .. "m/s " .. category .. " " .. Olympus.serializeTable(taskOptions), 2)
    local group = Group.getByName(groupName)
	if group then
		if category == "Aircraft" then
			local startPoint = mist.getLeadPos(group)
			local endPoint = coord.LLtoLO(lat, lng, 0) 
			if altitudeType == "AGL" then
				altitude = land.getHeight({x = endPoint.x, y = endPoint.z}) + altitude
			end

			local path = {}
			if taskOptions and taskOptions['id'] == 'Land' then
				path = {
					[1] = mist.fixedWing.buildWP(startPoint, turningPoint, speed, altitude, 'BARO'),
					[2] = mist.fixedWing.buildWP(endPoint, landing, speed, 0, 'AGL')
				} 
			else
				path = {
					[1] = mist.fixedWing.buildWP(startPoint, turningPoint, speed, altitude, 'BARO'),
					[2] = mist.fixedWing.buildWP(endPoint, turningPoint, speed, altitude, 'BARO')
				}
			end

			-- If a task exists assign it to the controller
			if taskOptions then
				local task = Olympus.buildEnrouteTask(taskOptions)
				if task then 
					path[1].task = task
					path[2].task = task
				end
			end
			
			-- Assign the mission task to the controller
			local missionTask = {
				id = 'Mission',
				params = {
					route = {
						points = mist.utils.deepCopy(path),
					},
				},
			}
			local groupCon = group:getController()
			if groupCon then
				groupCon:setTask(missionTask)
			end
			Olympus.debug("Olympus.move executed successfully on Aircraft", 2)
		elseif category == "Helicopter" then
			local startPoint = mist.getLeadPos(group)
			local endPoint = coord.LLtoLO(lat, lng, 0) 

			if altitudeType == "AGL" then
				altitude = land.getHeight({x = endPoint.x, y = endPoint.z}) + altitude
			end

			local path = {}
			if taskOptions and taskOptions['id'] == 'Land' then
				path = {
					[1] = mist.heli.buildWP(startPoint, turningPoint, speed, altitude, 'BARO'),
					[2] = mist.heli.buildWP(endPoint, landing, speed, 0, 'AGL')
				} 
			else
				path = {
					[1] = mist.heli.buildWP(startPoint, turningPoint, speed, altitude, 'BARO'),
					[2] = mist.heli.buildWP(endPoint, turningPoint, speed, altitude, 'BARO')
				}
			end

			-- If a task exists assign it to the controller
			if taskOptions then
				local task = Olympus.buildEnrouteTask(taskOptions)
				if task then 
					path[1].task = task
					path[2].task = task
				end
			end
			
			-- Assign the mission task to the controller
			local missionTask = {
				id = 'Mission',
				params = {
					route = {
						points = mist.utils.deepCopy(path),
					},
				},
			}
			local groupCon = group:getController()
			if groupCon then
				groupCon:setTask(missionTask)
			end
			Olympus.debug("Olympus.move executed successfully on Helicopter", 2)
		elseif category == "GroundUnit" then
			local startPoint = mist.getLeadPos(group)
			local endPoint = coord.LLtoLO(lat, lng, 0) 
			local bearing = math.atan2(endPoint.z - startPoint.z, endPoint.x - startPoint.x)

			vars = 
				{
					group = group, 
					point = endPoint,
					heading = bearing,
					speed = speed
				}

			if taskOptions and taskOptions['id'] == 'FollowRoads' and taskOptions['value'] == true then
				vars["disableRoads"] = false
			else
				vars["form"] = "Off Road"
				vars["disableRoads"] = true
			end

			mist.groupToRandomPoint(vars)
			Olympus.debug("Olympus.move executed succesfully on GroundUnit", 2)
		elseif category == "NavyUnit" then
			local startPoint = mist.getLeadPos(group)
			local endPoint = coord.LLtoLO(lat, lng, 0) 
			local bearing = math.atan2(endPoint.z - startPoint.z, endPoint.x - startPoint.x)
			
			vars = 
				{
					group = group, 
					point = endPoint,
					heading = bearing,
					speed = speed
				}
			mist.groupToRandomPoint(vars)
			Olympus.debug("Olympus.move executed succesfully on NavyUnit", 2)
		else
			Olympus.debug("Olympus.move not implemented yet for " .. category, 2)
		end
	else
        Olympus.debug("Error in Olympus.move " .. groupName, 2)
	end
end  

-- Creates a simple smoke on the ground
function Olympus.smoke(color, lat, lng)
    Olympus.debug("Olympus.smoke " .. color .. " (" .. lat .. ", " .. lng ..")", 2)
	local colorEnum = nil
	if color == "green" then
		colorEnum = trigger.smokeColor.Green
	elseif color == "red" then
		colorEnum = trigger.smokeColor.Red
	elseif color == "white" then 
		colorEnum = trigger.smokeColor.White
	elseif color == "orange" then 
		colorEnum = trigger.smokeColor.Orange
	elseif color == "blue" then
		colorEnum = trigger.smokeColor.Blue
	end
    trigger.action.smoke(mist.utils.makeVec3GL(coord.LLtoLO(lat, lng, 0)), colorEnum)
end  

-- Creates an explosion on the ground
function Olympus.explosion(intensity, lat, lng)
    Olympus.debug("Olympus.explosion " .. intensity .. " (" .. lat .. ", " .. lng ..")", 2)
	trigger.action.explosion(mist.utils.makeVec3GL(coord.LLtoLO(lat, lng, 0)), intensity)
end  

-- Spawns a new unit or group
function Olympus.spawnUnits(spawnTable) 
	Olympus.debug("Olympus.spawnUnits " .. Olympus.serializeTable(spawnTable), 2)

	local unitTable = nil
	local route = nil
	local category = nil

	if spawnTable.category == 'Aircraft' then
		unitTable = Olympus.generateAirUnitsTable(spawnTable.units)
		route = Olympus.generateAirUnitsRoute(spawnTable)
		category = 'plane'
	elseif spawnTable.category == 'Helicopter' then
		unitTable = Olympus.generateAirUnitsTable(spawnTable.units)
		route = Olympus.generateAirUnitsRoute(spawnTable)
		category = 'helicopter'
	elseif spawnTable.category == 'GroundUnit' then
		unitTable = Olympus.generateGroundUnitsTable(spawnTable.units)
		category = 'vehicle'
	elseif spawnTable.category == 'NavyUnit' then
		unitTable = Olympus.generateNavyUnitsTable(spawnTable.units)
		category = 'ship'
	end

	Olympus.debug(Olympus.serializeTable(unitTable), 5)

	local countryID = 0
	if spawnTable.country == nil or spawnTable.country == "" then
		countryID = Olympus.getCountryIDByCoalition(spawnTable.coalition)
	else
		countryID = country.id[spawnTable.country]
	end

	local vars = 
	{
		units = unitTable, 
		country = countryID, 
		category = category,
		route = route,
		name = "Olympus-" .. Olympus.unitCounter,
		task = 'CAP'
	}
	mist.dynAdd(vars)

	Olympus.unitCounter = Olympus.unitCounter + 1
	Olympus.debug("Olympus.spawnUnits completed succesfully", 2)
end

-- Generates unit table for a air unit. 
function Olympus.generateAirUnitsTable(units)
	local unitTable = {}
	for idx, unit in pairs(units) do
		local loadout = unit.loadout			-- loadout: a string, one of the names defined in unitPayloads.lua. Must be compatible with the unitType
		local payload = unit.payload			-- payload: a table, if present the unit will receive this specific payload. Overrides loadout

		if unit.heading == nil then
			unit.heading = 0
		end

		if payload == nil then
			if loadout and loadout ~= "" and Olympus.unitPayloads[unit.unitType][loadout] then
				payload = Olympus.unitPayloads[unit.unitType][loadout]
			else
				payload = {}
			end
		end
		
		local spawnLocation = mist.utils.makeVec3GL(coord.LLtoLO(unit.lat, unit.lng, 0))
		unitTable[#unitTable + 1] = 
		{
			["type"] = unit.unitType,
			["x"] = spawnLocation.x,
			["y"] = spawnLocation.z,
			["alt"] = unit.alt,
			["alt_type"] = "BARO",
			["skill"] = "Excellent",
			["payload"] = { ["pylons"] = payload, ["fuel"] = 999999, ["flare"] = 60, ["ammo_type"] = 1, ["chaff"] = 60, ["gun"] = 100, }, 
			["heading"] = unit.heading,
			["callsign"] = { [1] = 1, [2] = 1, [3] = 1, ["name"] = "Olympus" .. Olympus.unitCounter.. "-" .. #unitTable + 1 },
			["name"] = "Olympus-" .. Olympus.unitCounter .. "-" .. #unitTable + 1,
			["livery_id"] = unit.liveryID
		}

		-- Add the payload to the registry, used for unit cloning
		Olympus.payloadRegistry[unitTable[#unitTable].name] = payload
	end
	return unitTable
end

function Olympus.generateAirUnitsRoute(spawnTable)
	local airbaseName = spawnTable.airbaseName	-- airbaseName: a string, if present the aircraft will spawn on the ground of the selected airbase
	local spawnLocation = mist.utils.makeVec3GL(coord.LLtoLO(spawnTable.units[1].lat, spawnTable.units[1].lng, 0))

	-- If a airbase is provided the first waypoint is set as a From runway takeoff.
	local route = {}
	if airbaseName and airbaseName ~= "" then
		local airbase = Airbase.getByName(airbaseName)
		if airbase then
			local airbaseID = airbase:getID()
			route = 
			{
				["points"] = 
				{
					[1] = 
					{
						["action"] = "From Parking Area Hot",
						["tasks"] = {
							[1] = {["number"] = 1, ["auto"] = true, ["id"] = "WrappedAction", ["enabled"] = true, ["params"] = {["action"] = {["id"] = "EPLRS", ["params"] = {["value"] = true}, }, }, },
							[2] = {["number"] = 2, ["auto"] = false, ["id"] = "Orbit", ["enabled"] = true, ["params"] = {["pattern"] = "Circle"}, },
						},
						["type"] = "TakeOffParkingHot",
						["ETA"] = 0,
						["ETA_locked"] = true,
						["x"] = spawnLocation.x,
						["y"] = spawnLocation.z,
                        ["alt_type"] = "BARO",
						["formation_template"] = "",
						["airdromeId"] = airbaseID,
						["speed_locked"] = true,
					}, 
				}, 
			} 			
		end
	else
		route = {
				["points"] = 
				{
					[1] = 
					{
						["alt"] = alt,
						["alt_type"] = "BARO",
						["tasks"] = {
							[1] = {["number"] = 1, ["auto"] = true, ["id"] = "WrappedAction", ["enabled"] = true, ["params"] = {["action"] = {["id"] = "EPLRS", ["params"] = {["value"] = true}, }, }, },
							[2] = {["number"] = 2, ["auto"] = false, ["id"] = "Orbit", ["enabled"] = true, ["params"] = {["pattern"] = "Circle"}, },
						},
						["type"] = "Turning Point",
						["x"] = spawnLocation.x,
						["y"] = spawnLocation.z,
					},
				}, 
			} 
	end
	return route
end

-- Generates ground units table, either single or from template
function Olympus.generateGroundUnitsTable(units)
	local unitTable = {}
	for idx, unit in pairs(units) do
		local spawnLocation = mist.utils.makeVec3GL(coord.LLtoLO(unit.lat, unit.lng, 0))
		if Olympus.hasKey(templates, unit.unitType) then
			for idx, value in pairs(templates[unit.unitType].units) do
				unitTable[#unitTable + 1] = 
				{
					["type"] = value.name,
					["x"] = spawnLocation.x + value.dx,
					["y"] = spawnLocation.z + value.dy,
					["heading"] = 0,
					["skill"] = "High",
					["name"] = "Olympus-" .. Olympus.unitCounter .. "-" .. #unitTable + 1
				}
			end 
		else
			unitTable[#unitTable + 1] = 
			{
				["type"] = unit.unitType,
				["x"] = spawnLocation.x,
				["y"] = spawnLocation.z,
				["heading"] = unit.heading,
				["skill"] = "High",
				["name"] = "Olympus-" .. Olympus.unitCounter .. "-" .. #unitTable + 1,
				["livery_id"] = unit.liveryID
			}
		end
	end

	return unitTable
end  

-- Generates navy units table, either single or from template
function Olympus.generateNavyUnitsTable(units)
	local unitTable = {}
	for idx, unit in pairs(units) do
		local spawnLocation = mist.utils.makeVec3GL(coord.LLtoLO(unit.lat, unit.lng, 0))
		if Olympus.hasKey(templates, unit.unitType) then
			for idx, value in pairs(templates[unit.unitType].units) do
				unitTable[#unitTable + 1] = 
				{
					["type"] = value.name,
					["x"] = spawnLocation.x + value.dx,
					["y"] = spawnLocation.z + value.dy,
					["heading"] = 0,
					["skill"] = "High",
					["name"] = "Olympus-" .. Olympus.unitCounter .. "-" .. #unitTable + 1,
					["transportable"] = { ["randomTransportable"] = false }
				}
			end 
		else
			unitTable[#unitTable + 1] = 
			{
				["type"] = unit.unitType,
				["x"] = spawnLocation.x,
				["y"] = spawnLocation.z,
				["heading"] = unit.heading,
				["skill"] = "High",
				["name"] = "Olympus-" .. Olympus.unitCounter .. "-" .. #unitTable + 1,
				["transportable"] = { ["randomTransportable"] = false },
				["livery_id"] = unit.liveryID
			}
		end
	end

	return unitTable
end  

-- Clones a unit by ID. Will clone the unit with the same original payload as the source unit. TODO: only works on Olympus unit not ME units.
function Olympus.clone(ID, lat, lng, category)
	Olympus.debug("Olympus.clone " .. ID .. ", " .. category, 2)
	local unit = Olympus.getUnitByID(ID)
	if unit then
		local position = unit:getPosition()
		local heading = math.atan2( position.x.z, position.x.x )
		
		-- TODO: understand category in this script
		local spawnTable = {
			coalition = Olympus.getCoalitionByCoalitionID(unit:getCoalition()),
			category = category,
			units = {
				[1] = {
					lat = lat,
					lng = lng,
					alt = unit:getPoint().y,
					heading = heading,
					unitType = unit:getTypeName(),
					payload = Olympus.payloadRegistry[unit:getName()]
				}
			}
		}
		Olympus.spawnUnits(spawnTable)
	end
	Olympus.debug("Olympus.clone completed successfully", 2)
end

function Olympus.delete(ID, explosion)
	Olympus.debug("Olympus.delete " .. ID .. " " .. tostring(explosion), 2)
	local unit = Olympus.getUnitByID(ID)
	if unit then
		if unit:getPlayerName() or explosion then
			trigger.action.explosion(unit:getPoint() , 250 ) --consider replacing with forcibly deslotting the player, however this will work for now
			Olympus.debug("Olympus.delete completed successfully", 2)
		else
			unit:destroy(); --works for AI units not players
			Olympus.debug("Olympus.delete completed successfully", 2)
		end
	end
end

function Olympus.setTask(groupName, taskOptions)
	Olympus.debug("Olympus.setTask " .. groupName .. " " .. Olympus.serializeTable(taskOptions), 2)
	local group = Group.getByName(groupName)
	if group then
		local task = Olympus.buildTask(groupName, taskOptions);
		Olympus.debug("Olympus.setTask " .. Olympus.serializeTable(task), 20)
		if task then
			group:getController():setTask(task)
			Olympus.debug("Olympus.setTask completed successfully", 2)
		end
	end
end

function Olympus.resetTask(groupName)
	Olympus.debug("Olympus.resetTask " .. groupName, 2)
	local group = Group.getByName(groupName)
	if group then
		group:getController():resetTask()
		Olympus.debug("Olympus.resetTask completed successfully", 2)
	end
end

function Olympus.setCommand(groupName, command)
	Olympus.debug("Olympus.setCommand " .. groupName .. " " .. Olympus.serializeTable(command), 2)
	local group = Group.getByName(groupName)
	if group then
		group:getController():setCommand(command)
		Olympus.debug("Olympus.setCommand completed successfully", 2)
	end
end

function Olympus.setOption(groupName, optionID, optionValue)
	Olympus.debug("Olympus.setOption " .. groupName .. " " .. optionID .. " " .. tostring(optionValue), 2)
	local group = Group.getByName(groupName)
	if group then
		group:getController():setOption(optionID, optionValue)
		Olympus.debug("Olympus.setOption completed successfully", 2)
	end
end

function Olympus.setOnOff(groupName, onOff)
	Olympus.debug("Olympus.setOnOff " .. groupName .. " " .. tostring(onOff), 2)
	local group = Group.getByName(groupName)
	if group then
		group:getController():setOnOff(onOff)
		Olympus.debug("Olympus.setOnOff completed successfully", 2)
	end
end

function Olympus.setUnitsData(arg, time)
	-- Units data
	local units = {}
	
	local startIndex = Olympus.unitIndex
	local endIndex = startIndex + Olympus.unitStep
	local index = 0
	for ID, unit in pairs(Olympus.units) do
		index = index + 1
		if index > startIndex then
			if unit ~= nil then
				local table = {}		
				-- Get the object category in Olympus name
				local objectCategory = unit:getCategory()
				if objectCategory == Object.Category.UNIT then
					if unit:getDesc().category == Unit.Category.AIRPLANE then
						table["category"] = "Aircraft"
					elseif unit:getDesc().category == Unit.Category.HELICOPTER then
						table["category"] = "Helicopter"
					elseif unit:getDesc().category == Unit.Category.GROUND_UNIT then
						table["category"] = "GroundUnit"
					elseif unit:getDesc().category == Unit.Category.SHIP then
						table["category"] = "NavyUnit"
					end
				else
					units[ID] = {isAlive = false}
					Olympus.units[ID] = nil
				end

				-- If the category is handled by Olympus, get the data
				if table["category"] ~= nil then
					-- Compute unit position and heading
					local lat, lng, alt = coord.LOtoLL(unit:getPoint())
					local position = unit:getPosition()
					local heading = math.atan2( position.x.z, position.x.x )

					-- Fill the data table
					table["name"] = unit:getTypeName()
					table["coalitionID"] = unit:getCoalition()
					table["position"] = {}
					table["position"]["lat"] = lat 
					table["position"]["lng"] = lng 
					table["position"]["alt"] = alt
					table["speed"] = mist.vec.mag(unit:getVelocity())
					table["heading"] = heading 
					table["isAlive"] = unit:isExist() and unit:isActive() and unit:getLife() >= 1
					
					local group = unit:getGroup()
					if group ~= nil then
						local controller = group:getController()
						if controller ~= nil then
							-- Get the targets detected by the unit controller
							local contacts = {}
							local unitController = unit:getController()
							if unitController ~= nil then
								for det, enum in pairs(Controller.Detection) do
									local controllerTargets = unitController:getDetectedTargets(enum)
									for i, target in ipairs(controllerTargets) do
										if target ~= nil and target.object ~= nil and target.visible then
											target["detectionMethod"] = det
											contacts[#contacts + 1] = target
										end
									end
								end
							end
							
							table["country"] = unit:getCountry()
							table["unitName"] = unit:getName()
							table["groupName"] = group:getName()
							table["isHuman"] = (unit:getPlayerName() ~= nil)
							table["hasTask"] = controller:hasTask()
							table["ammo"] = unit:getAmmo() --TODO remove a lot of stuff we don't really need
							table["fuel"] = unit:getFuel()
							table["life"] = unit:getLife() / unit:getLife0()
							table["contacts"] = contacts

							units[ID] = table
						end
					end
				end
			else
				units[ID] = {isAlive = false}
				Olympus.units[ID] = nil
			end
		end
		if index >= endIndex then
			break
		end
	end
	if index ~= endIndex then 
		Olympus.unitIndex = 0
	else
		Olympus.unitIndex = endIndex
	end
	
	-- Assemble unitsData table
	Olympus.unitsData["units"] = units

	Olympus.OlympusDLL.setUnitsData()
	return time + 0.05
end

function Olympus.setWeaponsData(arg, time)
	-- Weapons data
	local weapons = {}
	
	local startIndex = Olympus.weaponIndex
	local endIndex = startIndex + Olympus.weaponStep
	local index = 0
	for ID, weapon in pairs(Olympus.weapons) do
		index = index + 1
		if index > startIndex then
			if weapon ~= nil then
				local table = {}

				-- Get the object category in Olympus name
				local objectCategory = weapon:getCategory()
				if objectCategory == Object.Category.WEAPON then
					if weapon:getDesc().category == Weapon.Category.MISSILE then
						table["category"] = "Missile"
					elseif weapon:getDesc().category == Weapon.Category.ROCKET then
						table["category"] = "Missile"
					elseif weapon:getDesc().category == Weapon.Category.BOMB then
						table["category"] = "Bomb"
					end
				else
					weapons[ID] = {isAlive = false}
					Olympus.weapons[ID] = nil
				end

				-- If the category is handled by Olympus, get the data
				if table["category"] ~= nil then
					-- Compute weapon position and heading
					local lat, lng, alt = coord.LOtoLL(weapon:getPoint())
					local position = weapon:getPosition()
					local heading = math.atan2( position.x.z, position.x.x )

					-- Fill the data table
					table["name"] = weapon:getTypeName()
					table["coalitionID"] = weapon:getCoalition()
					table["position"] = {}
					table["position"]["lat"] = lat 
					table["position"]["lng"] = lng 
					table["position"]["alt"] = alt
					table["speed"] = mist.vec.mag(weapon:getVelocity())
					table["heading"] = heading 
					table["isAlive"] = weapon:isExist()
					
					weapons[ID] = table
				end
			else
				weapons[ID] = {isAlive = false}
				Olympus.weapons[ID] = nil
			end
		end
		if index >= endIndex then
			break
		end
	end
	if index ~= endIndex then 
		Olympus.weaponIndex = 0
	else
		Olympus.weaponIndex = endIndex
	end
	
	-- Assemble weaponsData table
	Olympus.weaponsData["weapons"] = weapons

	Olympus.OlympusDLL.setWeaponsData()
	return time + 0.25
end

function Olympus.setMissionData(arg, time)
	-- Bullseye data
	local bullseyes = {}
	for i = 0, 2 do
		local bullseyeVec3 = coalition.getMainRefPoint(i)
		local bullseyeLatitude, bullseyeLongitude, bullseyeAltitude = coord.LOtoLL(bullseyeVec3)
		bullseyes[i] = {}
		bullseyes[i]["latitude"] = bullseyeLatitude
		bullseyes[i]["longitude"] = bullseyeLongitude
		bullseyes[i]["coalition"] = Olympus.getCoalitionByCoalitionID(i) 
	end

	-- Airbases data
	local base = world.getAirbases()
	local airbases = {}
	for i = 1, #base do
		local info = {}
		local latitude, longitude, altitude = coord.LOtoLL(Airbase.getPoint(base[i]))
		info["callsign"] = Airbase.getCallsign(base[i])
		info["coalition"] = Olympus.getCoalitionByCoalitionID(Airbase.getCoalition(base[i])) 
		info["latitude"] =  latitude
		info["longitude"] =  longitude
		if Airbase.getUnit(base[i]) then
			info["unitId"] = Airbase.getUnit(base[i]):getID()
		end
		airbases[i] = info
	end

	-- Mission
	local mission = {}
	mission.theatre = env.mission.theatre
	mission.dateAndTime = {
		["elapsedTime"] = DCS.getRealTime() - Olympus.missionStartTime,
		["time"] = mist.time.getDHMS(timer.getAbsTime()),
		["startTime"] = env.mission.start_time,
		["date"] = env.mission.date
	}

	mission.coalitions = {
		["red"] = {},
		["blue"] = {},
		["neutral"] = {}
	}
	for countryName, countryId in pairs(country["id"]) do
		local coalitionName = Olympus.getCoalitionByCoalitionID(coalition.getCountryCoalition(countryId))
		mission.coalitions[coalitionName][#mission.coalitions[coalitionName] + 1] = countryName 
	end

	-- Assemble table
	Olympus.missionData["bullseyes"] = bullseyes
	Olympus.missionData["airbases"] = airbases
	Olympus.missionData["mission"] = mission

	Olympus.OlympusDLL.setMissionData()
	return time + 1
end

function Olympus.initializeUnits() 
	if mist and mist.DBs and mist.DBs.MEunitsById then
		for id, unitTable in pairs(mist.DBs.MEunitsById) do
			local unit = Unit.getByName(unitTable["unitName"])
			if unit then
				Olympus.units[unit["id_"]] = unit
			end
		end
		Olympus.notify("Olympus units table initialized", 2)
	else
		Olympus.debug("MIST DBs not ready", 2)
		timer.scheduleFunction(Olympus.initializeUnits, {}, timer.getTime() + 1)
	end
end

function Olympus.serializeTable(val, name, skipnewlines, depth)
    skipnewlines = skipnewlines or false
    depth = depth or 0

    local tmp = string.rep(" ", depth)
    if name then 
		if type(name) == "number" then
			tmp = tmp .. "[" .. name .. "]" .. " = " 
		else
			tmp = tmp .. name  .. " = " 
		end
	end

    if type(val) == "table" then
        tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")
        for k, v in pairs(val) do
            tmp =  tmp .. Olympus.serializeTable(v, k, skipnewlines, depth + 1) .. "," .. (not skipnewlines and "\n" or "")
        end
        tmp = tmp .. string.rep(" ", depth) .. "}"
    elseif type(val) == "number" then
        tmp = tmp .. tostring(val)
    elseif type(val) == "string" then
        tmp = tmp .. string.format("%q", val)
    elseif type(val) == "boolean" then
        tmp = tmp .. (val and "true" or "false")
    else
        tmp = tmp .. "\"[inserializeable datatype:" .. type(val) .. "]\""
    end

    return tmp
end

function Olympus.isArray(t)
	local i = 0
	for _ in pairs(t) do
		i = i + 1
		if t[i] == nil then return false end
	end
	return true
end

function Olympus.hasValue(tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

function Olympus.hasKey(tab, key)
    for k, value in pairs(tab) do
        if k == key then
            return true
        end
    end

    return false
end

------------------------------------------------------------------------------------------------------
-- Olympus startup script
------------------------------------------------------------------------------------------------------
local OlympusName = 'Olympus ' .. version .. ' C++ module';
Olympus.DLLsloaded = Olympus.loadDLLs()
if Olympus.DLLsloaded then
	Olympus.notify(OlympusName..' successfully loaded.', 20)
else
	Olympus.notify('Failed to load '..OlympusName, 20)
end

-- Create the handler to detect new units
if handler ~= nil then
	world.removeEventHandler(handler)
	Olympus.debug("Olympus handler removed" , 2)
end
handler = {}
function handler:onEvent(event)
	if event.id == 1 then
		local weapon = event.weapon
		if Olympus ~= nil and Olympus.weapons ~= nil then
			Olympus.weapons[weapon["id_"]] = weapon
			Olympus.debug("New weapon created " .. weapon["id_"], 2)
		end
	elseif event.id == 15 then
		local unit = event.initiator
		if Olympus ~= nil and Olympus.units ~= nil then
			Olympus.units[unit["id_"]] = unit
			Olympus.debug("New unit created " .. unit["id_"], 2)
		end
	end
end
world.addEventHandler(handler)

-- Start the periodic functions
timer.scheduleFunction(Olympus.setUnitsData, {}, timer.getTime() + 0.05)
timer.scheduleFunction(Olympus.setWeaponsData, {}, timer.getTime() + 0.25)
timer.scheduleFunction(Olympus.setMissionData, {}, timer.getTime() + 1)

-- Initialize the ME units
Olympus.initializeUnits()

Olympus.notify("OlympusCommand script " .. version .. " loaded successfully", 2, true)

