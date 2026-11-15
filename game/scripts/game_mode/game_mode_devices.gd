class_name GameModeDevices
extends Node
## What the game mode (#138) needs from the peripherals' hub (UFO-DeviceHub: M5Dial x2 and
## the Illumination ATOM). Two implementations: MockDialHub (inside the game, no backend)
## and BackendDialHub (the backend's DeviceHubService over the WebSocket: the real hub or
## its Python mock). The game never talks to a device any other way, and none of this
## touches the crane (no RobotState, no robot command).
##
## An ACK (command_done ok) means the device accepted the command, not that it finished:
## RELEASE_BALL is finished by the RELEASE_DONE event, which itself only says the servo
## sequence ended (there is no sensor that sees the capsule leave).

const DIAL_1 := 0x20  # left of the screen
const DIAL_2 := 0x21  # right of the screen
const ILLUMINATION := 0x10

## {name, source (int or null), data: Dictionary, event_id (int or null), session_id (int or null)}
signal device_event(ev: Dictionary)
## result: the device's answer ("ACCEPTED", "BUSY", "REJECTED_STATE", "OFFLINE", "TIMEOUT"...);
## data: {command_id} for a command, {status: Dictionary} for a status request
signal command_done(rid: String, ok: bool, result: String, data: Dictionary)

## "mock" (inside the game) / "backend"
func kind() -> String:
	return ""

## The hub answers now (a command may still be refused).
func available() -> bool:
	return false

## The hub session the game is in (0 = none / unknown yet).
func session_id() -> int:
	return 0

## Sends a device command; the answer comes as command_done(rid, ...).
func command(_device: int, _name: String, _params: Dictionary = {}) -> String:
	return ""

## Asks a device for its STATUS: command_done(rid, ok, result, {status}).
func status(_device: int) -> String:
	return ""

## Stops every device (STOP_ALL): always tried, whatever the game's state.
func stop_all() -> void:
	pass

## Mock only: a capsule lands in the Dial (false = not a mock, or the Dial is not armed).
func mock_ball(_device: int) -> bool:
	return false

func can_mock_ball() -> bool:
	return false

## Called every game tick (the in-game mock runs its servo timers on it).
func tick(_dt: float) -> void:
	pass
