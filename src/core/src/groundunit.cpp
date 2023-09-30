#include "groundunit.h"
#include "utils.h"
#include "logger.h"
#include "commands.h"
#include "scheduler.h"
#include "defines.h"
#include "unitsmanager.h"

#include <GeographicLib/Geodesic.hpp>
using namespace GeographicLib;

extern Scheduler* scheduler;
extern UnitsManager* unitsManager;
json::value GroundUnit::database = json::value();

void GroundUnit::loadDatabase(string path) {
	char* buf = nullptr;
	size_t sz = 0;
	if (_dupenv_s(&buf, &sz, "DCSOLYMPUS_PATH") == 0 && buf != nullptr)
	{
		std::ifstream ifstream(string(buf) + path);
		std::stringstream ss;
		ss << ifstream.rdbuf();
		std::error_code errorCode;
		database = json::value::parse(ss.str(), errorCode);
		if (database.is_object())
			log("Ground Units database loaded correctly");
		else
			log("Error reading Ground Units database file");

		free(buf);
	}
}

/* Ground unit */
GroundUnit::GroundUnit(json::value json, unsigned int ID) : Unit(json, ID)
{
	log("New Ground Unit created with ID: " + to_string(ID));

	setCategory("GroundUnit");
	setDesiredSpeed(10);
};

void GroundUnit::setDefaults(bool force)
{
	if (!getAlive() || !getControlled() || getHuman() || !getIsLeader()) return;

	/* Set the default IDLE state */
	setState(State::IDLE);

	/* Set the default options */
	setROE(ROE::OPEN_FIRE_WEAPON_FREE, force);
	setOnOff(onOff, force);
	setFollowRoads(followRoads, force);
}

void GroundUnit::setState(unsigned char newState)
{
	/************ Perform any action required when LEAVING a state ************/
	if (newState != state) {
		switch (state) {
		case State::IDLE: {
			break;
		}
		case State::REACH_DESTINATION: {
			break;
		}
		case State::FIRE_AT_AREA: {
			setTargetPosition(Coords(NULL));
			break;
		}
		case State::SIMULATE_FIRE_FIGHT: {
			setTargetPosition(Coords(NULL));
			break;
		}
		default:
			break;
		}
	}

	/************ Perform any action required when ENTERING a state ************/
	switch (newState) {
	case State::IDLE: {
		clearActivePath();
		resetActiveDestination();
		break;
	}
	case State::REACH_DESTINATION: {
		resetActiveDestination();
		break;
	}
	case State::FIRE_AT_AREA: {
		clearActivePath();
		resetActiveDestination();
		break;
	}
	case State::SIMULATE_FIRE_FIGHT: {
		clearActivePath();
		resetActiveDestination();
		break;
	}
	default:
		break;
	}

	resetTask();

	log(unitName + " setting state from " + to_string(state) + " to " + to_string(newState));
	state = newState;

	triggerUpdate(DataIndex::state);
}

void GroundUnit::AIloop()
{
	switch (state) {
	case State::IDLE: {
		setTask("Idle");
		if (getHasTask())
			resetTask();
		break;
	}
	case State::REACH_DESTINATION: {
		string enrouteTask = "";
		bool looping = false;

		std::ostringstream taskSS;
		taskSS << "{ id = 'FollowRoads', value = " << (getFollowRoads() ? "true" : "false") << " }";
		enrouteTask = taskSS.str();

		if (activeDestination == NULL || !getHasTask())
		{
			if (!setActiveDestination())
				setState(State::IDLE);
			else
				goToDestination(enrouteTask);
		}
		else {
			if (isDestinationReached(GROUND_DEST_DIST_THR)) {
				if (updateActivePath(looping) && setActiveDestination())
					goToDestination(enrouteTask);
				else
					setState(State::IDLE);
			}
		}
		break;
	}
	case State::FIRE_AT_AREA: {
		setTask("Firing at area");

		if (!getHasTask()) {
			std::ostringstream taskSS;
			taskSS.precision(10);
			taskSS << "{id = 'FireAtPoint', lat = " << targetPosition.lat << ", lng = " << targetPosition.lng << ", radius = 1000}";
			Command* command = dynamic_cast<Command*>(new SetTask(groupName, taskSS.str(), [this]() { this->setHasTaskAssigned(true); }));
			scheduler->appendCommand(command);
			setHasTask(true);
		}
	}
	case State::SIMULATE_FIRE_FIGHT: {
		setTask("Simulating fire fight");

		if (!getHasTask() || 0 * (((double)(rand()) / (double)(RAND_MAX)) < 0.01)) {
			double dist;
			double bearing1;
			double bearing2;
			Geodesic::WGS84().Inverse(position.lat, position.lng, targetPosition.lat, targetPosition.lng, dist, bearing1, bearing2);

			double r = 15; /* m */
			/* Default gun values */
			double barrelHeight = 1.0; /* m */
			double muzzleVelocity = 860; /* m/s */
			if (database.has_object_field(to_wstring(name))) { 
				json::value databaseEntry = database[to_wstring(name)];
				if (databaseEntry.has_number_field(L"barrelHeight") && databaseEntry.has_number_field(L"muzzleVelocity")) {
					barrelHeight = databaseEntry[L"barrelHeight"].as_number().to_double();
					muzzleVelocity = databaseEntry[L"muzzleVelocity"].as_number().to_double();
					log(to_string(barrelHeight) + " " + to_string(muzzleVelocity));
				}
			}

			double barrelElevation = r * (9.81 * dist / (2 * muzzleVelocity * muzzleVelocity) + (targetPosition.alt - (position.alt + barrelHeight)) / dist);	/* m */
			
			double lat = 0;
			double lng = 0;
			double randomBearing = bearing1 + 0 * (((double)(rand()) / (double)(RAND_MAX) - 0.5) * 2) * 15;
			Geodesic::WGS84().Direct(position.lat, position.lng, randomBearing, r, lat, lng);

			std::ostringstream taskSS;
			taskSS.precision(10);
			taskSS << "{id = 'FireAtPoint', lat = " << lat << ", lng = " << lng << ", alt = " << position.alt + barrelElevation + barrelHeight << ", radius = 0.001}";
			Command* command = dynamic_cast<Command*>(new SetTask(groupName, taskSS.str(), [this]() { this->setHasTaskAssigned(true); }));
			scheduler->appendCommand(command);
			setHasTask(true);
		}
	}
	default:
		break;
	}
}

void GroundUnit::changeSpeed(string change)
{
	if (change.compare("stop") == 0)
		setState(State::IDLE);
	else if (change.compare("slow") == 0)
		setDesiredSpeed(getDesiredSpeed() - knotsToMs(5));
	else if (change.compare("fast") == 0)
		setDesiredSpeed(getDesiredSpeed() + knotsToMs(5));

	if (getDesiredSpeed() < 0)
		setDesiredSpeed(0);
}

void GroundUnit::setOnOff(bool newOnOff, bool force) 
{
	if (newOnOff != onOff || force) {
		Unit::setOnOff(newOnOff, force);
		Command* command = dynamic_cast<Command*>(new SetOnOff(groupName, onOff));
		scheduler->appendCommand(command);
	}
}

void GroundUnit::setFollowRoads(bool newFollowRoads, bool force)
{
	if (newFollowRoads != followRoads || force) {
		Unit::setFollowRoads(newFollowRoads, force);
		resetActiveDestination(); /* Reset active destination to apply option*/
	}
}
