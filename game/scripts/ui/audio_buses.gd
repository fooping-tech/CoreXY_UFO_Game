class_name AudioBuses
## The game's audio buses (#143), made at run time so there is no layout file to keep in
## step: effects, music and voice each have their own, all into Master.
##
##   SFX        every sound effect
##   SFX Left   effects of the left Dial's side (panned left, into SFX)
##   SFX Right  effects of the right Dial's side (panned right, into SFX)
##   BGM        music
##   Voice      UFOくん's and the helper's spoken lines
##
## Volumes and mutes come from config `audio` (sfx_volume_db, sfx_enabled, bgm_volume_db,
## bgm_enabled); `audio.enabled` off mutes effects and music as before. Sound only: nothing
## here knows about the robot, the score or the devices.

const SFX := "SFX"
const SFX_LEFT := "SFX Left"
const SFX_RIGHT := "SFX Right"
const BGM := "BGM"
const VOICE := "Voice"
## how far the side buses are panned (0 = centre, 1 = hard)
const DEFAULT_PAN := 0.6
## the voice bus counts as speaking above this peak
const VOICE_PEAK_DB := -45.0

## Makes the buses that are missing (safe to call again). `pan` 0..1 sets how far the side
## buses are panned; left out (negative), a pan already set stays as it is.
static func ensure(pan := -1.0) -> void:
	for name in [SFX, BGM, VOICE]:
		_bus(name, "Master")
	for side in [[SFX_LEFT, -1.0], [SFX_RIGHT, 1.0]]:
		var idx := _bus(side[0], SFX)
		var fresh := AudioServer.get_bus_effect_count(idx) == 0
		if fresh:
			AudioServer.add_bus_effect(idx, AudioEffectPanner.new())
		if fresh or pan >= 0.0:
			(AudioServer.get_bus_effect(idx, 0) as AudioEffectPanner).pan = clampf(float(side[1]) * (pan if pan >= 0.0 else DEFAULT_PAN), -1.0, 1.0)

## How far the side buses are panned now (0..1).
static func pan() -> float:
	var idx := AudioServer.get_bus_index(SFX_RIGHT)
	if idx < 0 or AudioServer.get_bus_effect_count(idx) == 0:
		return 0.0
	return (AudioServer.get_bus_effect(idx, 0) as AudioEffectPanner).pan

static func _bus(name: String, send: String) -> int:
	var idx := AudioServer.get_bus_index(name)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(idx, send)
	return idx

## The bus for an effect of `side` ("left" / "right"; anything else = the middle).
static func sfx_bus(side: String) -> String:
	return SFX_LEFT if side == "left" else (SFX_RIGHT if side == "right" else SFX)

## Volumes and mutes from the config's `audio` section (the settings screen changes them live).
static func apply(audio: Dictionary) -> void:
	ensure()
	var on := bool(audio.get("enabled", true))
	_level(SFX, float(audio.get("sfx_volume_db", 0.0)), not (on and bool(audio.get("sfx_enabled", true))))
	_level(BGM, float(audio.get("bgm_volume_db", 0.0)), not (on and bool(audio.get("bgm_enabled", true))))

static func _level(name: String, db: float, mute: bool) -> void:
	var idx := AudioServer.get_bus_index(name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, clampf(db, -60.0, 6.0))
		AudioServer.set_bus_mute(idx, mute)

static func muted(name: String) -> bool:
	var idx := AudioServer.get_bus_index(name)
	return idx >= 0 and AudioServer.is_bus_mute(idx)

static func volume_db(name: String) -> float:
	var idx := AudioServer.get_bus_index(name)
	return AudioServer.get_bus_volume_db(idx) if idx >= 0 else 0.0

## A spoken line is sounding now (the music steps back while it does).
static func voice_active() -> bool:
	var idx := AudioServer.get_bus_index(VOICE)
	if idx < 0:
		return false
	return maxf(AudioServer.get_bus_peak_volume_left_db(idx, 0), AudioServer.get_bus_peak_volume_right_db(idx, 0)) > VOICE_PEAK_DB
