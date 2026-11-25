extends "res://tests/test_base.gd"
## The score game's show: visuals, the result, the ranking, the portrait layout, audio.

## #141: the new look only shows the game; it changes nothing of it.
func _test_game_mode_visuals(rs: Node) -> void:
	var words := ["SUMMON THE UFO", "SCORE", "TIME", "JACKPOT", "1000", "100", "DIAL 1", "2:30", "0123456789", "+-:!.x"]
	_ok(words.all(func(w): return PixelText.supports(w)) and not PixelText.supports("あ") and PixelText.width("100", 3.0) == 51.0
		and PixelText.height(3.0) == 21.0 and PixelText.width("", 2.0) == 0.0,
		"game mode art: the pixel font has every arcade word (Japanese stays on the labels)")
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	ctl.tick(1.0 / 60.0)
	var b := ctl.backdrop
	var title: bool = ctl.hud.title_showing() and not ctl.fx.ufo_visible and ctl.hud._start.text.contains("Enter") \
		and ctl.hud._logo_tex != null and ctl.hud._logo_tex == load(TitleScreen.LOGO_PNG)  # #310: the title screen's logo picture
	var high := b.star_count()
	b.quality = "low"
	var low := b.star_count()
	b.quality = "high"
	_ok(title and high == 126 and low == 40 and b.side_colors["left"] == ctl.lanes["left"].color
		and ctl.field.wall_colors[0] == ctl.lanes["left"].color and b.side_colors.keys() == ["left"] and ctl.visual_quality == "high",
		"game mode art: the score game's own title (logo, big UFO, START) while it waits; the left wall and the conduit take the Dial's colour; low quality has fewer stars",
		"%s %d %d" % [title, high, low])
	game._unhandled_input(_key(KEY_ENTER))
	ctl.tick(1.0 / 60.0)
	var playing_clean: bool = not ctl.hud.title_showing() and ctl.fx.ufo_visible
	_gm_step(ctl, ctl.countdown_s + 0.2)
	ctl.mock_hub.mock_ball(GM_L)
	var lit: float = b.side_level("left")
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(ctl.lanes["left"].capsule.capsule_id)
	var pin: StaticBody2D = ctl.field.get_children().filter(func(n): return n.has_meta("target") and n.get_meta("target") == "pin_3")[0]
	ctl.field._on_capsule_body(pin, id)
	var pin_glow: bool = ctl.field._pin_flash.has("pin_3") and ctl.score.score == 10
	ctl.field.advance(0.5)
	b.pulse(Color.WHITE, 1.0)
	var flash := b.flash_level()
	b.advance(1.0)
	_ok(playing_clean and lit == 1.0 and pin_glow and not ctl.field._pin_flash.has("pin_3")
		and flash == 1.0 and b.flash_level() == 0.0 and b.side_level("left") == 0.0 and not ctl.hud.title_showing(),
		"game mode art: no title during play; a hit pin glows and fades; the background's glow and the Dial side's light fade by themselves",
		"%s %s %s %s" % [playing_clean, lit, pin_glow, flash])
	# (portrait, #157: the three "how to play" cards stand one under another, inside the screen)
	_ok(ctl.hud.clock_color() == Color.WHITE and GameModeHud.title_card(0).end.y <= GameModeHud.title_card(1).position.y
		and GameModeHud.title_card(1).end.y <= GameModeHud.title_card(2).position.y
		and Rect2(Vector2.ZERO, GameModeLayout.SCREEN).encloses(GameModeHud.title_card(2)) and GameModeHud.START_RECT.end.y < GameModeHud.title_card(0).position.y,
		"game mode art: the clock is white until the last 30 seconds; the title's cards go down the screen")
	_gm_free(game, rs)

## #141 (the feedback round): the pixel canvas, the new things to hit, the bounce, the combo
## and the sky that follow the round, the gesture panel beside the field.
func _test_game_mode_juice(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = _gm_playing(game)
	# one dot = two screen pixels, like the UFO's 64 x 64 sprite at 2x; the picture is in the canvas
	_ok(ctl.pixel_view.size == Vector2i(360, 640) and GameModeController.DOT_PX == GameModeVFX.UFO_SCALE
		and ctl.screen.size == Vector2(720, 1280) and ctl.field_art.get_parent() == ctl.pixel_view
		and ctl.fx.get_parent() == ctl.pixel_view and ctl.backdrop.get_parent() == ctl.pixel_view
		and ctl.field.get_parent() == ctl.layer and ctl.pixel_view.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"game mode pixels: the background, the field's picture and the effects are drawn in a 360 x 640 portrait canvas shown at 2x (the UFO's dot size); the physics stays in the game's world")
	# the new kinds score, light up and kick
	ctl.mock_hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(ctl.lanes["left"].capsule.capsule_id)
	var f := ctl.field
	var body := func(target: String) -> Node:
		return f.get_children().filter(func(n): return n.has_meta("target") and n.get_meta("target") == target)[0]
	var before := ctl.score.score
	f._on_capsule_body(body.call("pop_0"), id)
	f._on_capsule_body(body.call("target_2"), id)
	f._on_capsule_body(body.call("sling_1"), id)
	var t := ctl.score.table
	_ok(ctl.score.score - before == int(round(t["pop"] + t["target"] * 1.5 + t["sling"] * 1.5)) and f._pop_flash[0] > 0.0
		and f._target_lit[2] == PinballField.TARGET_LIT_S and f._sling_flash[1] > 0.0 and ctl.score.chain == 2
		and PinballField.slope_normal(0).x > 0.0 and PinballField.slope_normal(1).x < 0.0 and PinballField.slope_normal(0).y < 0.0
		and PinballField.CAPSULE_R == 18.0,
		"game mode field: pop bumpers, wall targets and the slingshot slopes score (the pop and the target build the combo), light up, and the slopes kick up and inward; the capsule is bigger",
		"%d %s" % [ctl.score.score - before, f._target_lit])
	# the picture bounces on a score and comes to rest by itself; nothing else waits for it
	var jolted := ctl.bounce_offset()
	var clock_before := ctl.time_left
	ctl._process(0.5)
	_gm_step(ctl, 0.5)
	var rested: bool = ctl.bounce_offset() == 0.0 and ctl.screen.position == Vector2.ZERO
	ctl.effects = false
	ctl.bounce(1.0)
	var off: bool = ctl.bounce_offset() == 0.0
	ctl.effects = true
	_ok(jolted > 0.0 and jolted <= GameModeController.BOUNCE_MAX_PX and rested and off and ctl.time_left < clock_before,
		"game mode juice: a score makes the picture bounce (whole dots, bounded) and it settles by itself while the clock runs; effects off = no bounce",
		"%s %s %s" % [jolted, rested, off])
	# the combo: a banner when it climbs, bigger pop-ups, the sky's energy; all gone when it runs out
	var lvl := ctl.combo_level()
	var banner := ctl.fx.banner_text()
	var energy: float = ctl.backdrop.energy
	for i in 40:
		f.advance(0.04)
	var trail := f.capsule_trail(id).size()
	_gm_step(ctl, ctl.score.combo_window_s + 1.2)
	_ok(lvl == 1 and banner == "COMBO x1.5" and energy > 0.0 and ctl.combo_level() == 0 and ctl.backdrop.energy == 0.0
		and ctl.fx.banner_text() == "" and ctl.fx.popups() == 0 and trail > 0 and trail <= PinballField.TRAIL_POINTS
		and GameModeVFX.popup_scale(false, 0) == 2.0 and GameModeVFX.popup_scale(false, 3) == 4.0 and GameModeVFX.popup_scale(true, 3) == 6.0
		and ctl.score.chain_left_k(ctl.clock) == 0.0,
		"game mode juice: the combo shows a banner, makes the pop-ups bigger and the sky livelier, and it all goes when the chain runs out; the capsule leaves a bounded trail",
		"%d '%s' %s %d" % [lvl, banner, energy, trail])
	# the attractions: gems and the alien are taken once and come back; a warp hole holds a capsule and shoots it up, once
	var area := func(target: String) -> Area2D:
		return f.get_children().filter(func(n): return n is Area2D and n.get_meta("target") == target)[0]
	var cap: RigidBody2D = f._capsules[id].body
	before = ctl.score.score
	var mult := ctl.score.multiplier(ctl.clock)
	f._on_area(cap, area.call("gem_1"))
	f._on_area(cap, area.call("gem_1"))
	f._on_area(cap, area.call("alien"))
	f._on_area(cap, area.call("alien"))
	var taken: bool = f.gem_left[1] == PinballField.GEM_RESPAWN_S and f.gem_left[0] == 0.0 and f.alien_left == PinballField.ALIEN_RESPAWN_S
	var gained := ctl.score.score - before
	f._on_area(cap, area.call("warp_0"))
	var held: bool = f.capsule_held(id) and f.warp_holding[0] == 1
	for i in 60:
		f.advance(1.0 / 60.0)
	var out: bool = not f.capsule_held(id) and f.warp_holding[0] == 0 and cap.linear_velocity.y < -400.0 and cap.linear_velocity.x > 0.0
	f._on_area(cap, area.call("warp_1"))
	var once: bool = not f.capsule_held(id)
	f.gem_left[1] = 0.01
	f.alien_left = 0.01
	f._alien_t = 0.0
	var a0 := f.alien_position()
	f._alien_t = PinballField.ALIEN_PERIOD_S * 0.5 - 0.02
	f.advance(0.02)
	_ok(taken and gained >= t["gem"] + t["alien"] and gained <= int((t["gem"] + t["alien"]) * 3.0) and mult >= 1.0 and held and out and once
		and f.gem_left[1] == 0.0 and f.alien_left == 0.0 and absf(f.alien_position().x - a0.x) > 300.0
		and f.alien_position().x >= PinballField.ALIEN_X0 and f.alien_position().x <= PinballField.ALIEN_X1
		and int(ctl.score.counts.get("warp", 0)) == 1,
		"game mode field: a gem and the alien score once and come back later, the alien drifts across; a warp hole holds a capsule, shoots it up towards the middle, and takes each capsule only once",
		"%s %d %s %s %s" % [taken, gained, held, out, once])
	_ok(ctl.hud.size == Vector2(720, 1280) and ctl.hud.art.size == Vector2(720, 1280),
		"game mode layout: the HUD's drawing has the screen's size (with none, the score and clock panels dropped out for a frame when the picture shook)")
	# the sky follows the clock: calm, the last 30 s, the last 10 s
	var calm: int = ctl.backdrop.urgency
	var calm_sky := ctl.backdrop.sky_bottom()
	ctl.time_left = ctl.hurry_s - 1.0
	ctl.tick(1.0 / 60.0)
	var hurry: int = ctl.backdrop.urgency
	ctl.time_left = ctl.warning_s - 1.0
	ctl.tick(1.0 / 60.0)
	var last: int = ctl.backdrop.urgency
	ctl.backdrop.advance(2.0)
	_ok(calm == 0 and hurry == 1 and last == 2 and ctl.backdrop.sky_bottom() != calm_sky and ctl.backdrop.time_k < 0.2
		and ctl.backdrop.light_color().r > ctl.backdrop.light_color().b,
		"game mode juice: the sky and its light change with the time left (calm, the last 30 s, the last 10 s)",
		"%d %d %d" % [calm, hurry, last])
	# #258: the hand window bottom right: the camera big on top (GestureHud), the easy mode's guide
	# right under it (EasyModeHud), one rounded window over the field's corner, clear of the
	# Dial's port, the score and the UFO's rail; the practice's words beside the port stay clear of it
	var screen_rect := Rect2(Vector2.ZERO, GameModeLayout.SCREEN)
	game.gesture_hud.column = true
	game.gesture_hud.place(720.0, 1280.0)
	var card := Rect2(game.gesture_hud.position, game.gesture_hud.size)
	var win := GameModeLayout.GUIDE_RECT
	var lower := EasyModeHud.PANEL
	var cam: Rect2 = game.gesture_hud.cam_rect()
	var field_rect := Rect2(PinballField.LEFT - 12.0, PinballField.TOP - 30.0, PinballField.RIGHT - PinballField.LEFT + 24.0,
		PinballField.FLOOR_Y - PinballField.TOP + 98.0)
	var port := Rect2(GameModeVFX.PORTS["left"] - Vector2(40, 40), Vector2(80, 100))
	var rail := Rect2(ctl.ufo.x_min - 64.0, ctl.ufo.y - 52.0, ctl.ufo.x_max - ctl.ufo.x_min + 128.0, 116)  # (the sprite's own top rows are empty)
	var practice_sub: Rect2 = GestureTutorialHud.LINES["sub"][1]
	_ok(screen_rect.encloses(win) and win.encloses(card) and card.position == win.position and win.position.x > GameModeLayout.CX
		and win.end.y > GameModeLayout.FIELD_FLOOR and is_equal_approx(lower.position.y, card.end.y) and is_equal_approx(lower.end.y, win.end.y)
		and lower.position.x == win.position.x and lower.size.x == win.size.x
		and not win.intersects(port) and not win.intersects(rail) and not win.intersects(GameModeHud.SCORE_RECT)
		and not win.intersects(practice_sub) and not win.intersects(GameModeLayout.MESSAGE_RECT)
		and cam.size.x >= 280.0 and is_equal_approx(cam.size.x / cam.size.y, 4.0 / 3.0) and Rect2(Vector2.ZERO, card.size).encloses(cam)
		and game.gesture_hud._cam.size == cam.size
		and game.gesture_hud.ring()[0].x + game.gesture_hud.ring()[1] < card.size.x and game.gesture_hud.ring()[0].y + game.gesture_hud.ring()[1] < card.size.y
		and game.gesture_hud.ring()[0].y - game.gesture_hud.ring()[1] > cam.end.y,
		"game mode layout #258: the hand window is bottom right (a big camera on top, the stick and the state under it, the easy guide under that), clear of the Dial's port, the score, the rail and the practice's words",
		"%s %s %s" % [card, lower, cam])
	# the field is tall, the Dial's port is under it, on the left (#200: the only one)
	var pl: Vector2 = GameModeVFX.PORTS["left"]
	_ok(PinballField.FLOOR_Y - PinballField.TOP > PinballField.RIGHT - PinballField.LEFT and screen_rect.encloses(field_rect)
		and pl.x < GameModeLayout.CX and pl.y > PinballField.FLOOR_Y + 68.0 and GameModeVFX.PORTS.size() == 1
		and ctl.lanes["left"].device == GM_L and not ctl.lanes.has("right")
		and GameModeLayout.dial_edge("left").x < 0.0
		and ctl.ufo.x_min >= PinballField.LEFT + 30.0 and ctl.ufo.x_max <= PinballField.RIGHT - 30.0,
		"game mode layout: portrait: the field is taller than wide and inside the screen; the one port (Dial 1) is bottom left, its light runs off the left side")
	game.gesture_hud.column = false
	game.gesture_hud.place(720.0, 1280.0)
	_ok(game.gesture_hud.size == GestureHud.SIZE and game.gesture_hud._cam.size == GestureHud.CAM_RECT.size, "game mode layout: outside the score game the hand panel is the wide one as before (its small camera)")
	ctl.close()
	_ok(ctl.pixel_view.render_target_update_mode == SubViewport.UPDATE_DISABLED and ctl.screen.position == Vector2.ZERO,
		"game mode pixels: the canvas stops drawing when the score game is closed")
	_gm_free(game, rs)

## #141: the arm camera's scope in the right column; it shows the hub's picture (the
## backend's stabilized one when that streams) and says which.
func _test_game_mode_scope(rs: Node) -> void:
	var on := {"stabilized": true, "tracking": true, "w": 1280, "dx": 25.6, "dy": 0.0}
	_ok(ArmScope.state_of("", {}) == "NO SIGNAL" and ArmScope.state_of("demo", {}) == "DEMO" and ArmScope.state_of("focus", {}) == "STAB OFF"
		and ArmScope.state_of("overview", {}) == "STAB OFF" and ArmScope.state_of("focus", {"stabilized": false, "tracking": true}) == "STAB OFF"
		and ArmScope.state_of("focus", on) == "STAB ON" and ArmScope.state_of("focus", {"stabilized": true, "tracking": false}) == "STAB WAIT"
		and is_equal_approx(ArmScope.shake_of(on), 0.5) and ArmScope.shake_of({}) == 0.0 and ArmScope.shake_of({"w": 1280, "dx": 900.0}) == 1.0,
		"game mode scope: it says which picture it shows (the backend's stabilized one: STAB ON / STAB WAIT; the camera as it is: STAB OFF) and how much shake is being cancelled")
	var game := _gm_game()
	var ctl: GameModeController = _gm_playing(game)
	var sc := ctl.scope
	ctl._process(0.016)
	# #271: no arm camera: NO SIGNAL on the scope (never the overview camera in its place)
	var hidden: bool = sc.visible and not sc._cam.visible and sc.source_role() == "" and sc.state() == "NO SIGNAL"
	ctl.demo = true  # the rehearsal's made-up picture stands in for the camera
	ctl._process(0.016)
	var shown: bool = sc.visible and sc.source_role() == "demo" and sc.state() == "DEMO"
	var card := ArmScope.RECT
	var field_rect := Rect2(PinballField.LEFT - 12.0, PinballField.TOP - 30.0, PinballField.RIGHT - PinballField.LEFT + 24.0,
		PinballField.FLOOR_Y - PinballField.TOP + 98.0)
	var port := Rect2(GameModeVFX.PORTS["left"] - Vector2(40, 40), Vector2(80, 100))
	var rail := Rect2(ctl.ufo.x_min - 64.0, ctl.ufo.y - 52.0, ctl.ufo.x_max - ctl.ufo.x_min + 128.0, 116)  # (the sprite's own top rows are empty)
	_ok(hidden and shown and sc.stream_header().is_empty()
		and not card.intersects(field_rect) and not card.intersects(GameModeHud.TIME_RECT) and not card.intersects(port)
		and not card.intersects(rail) and not card.intersects(GameModeLayout.COMBO_RECT)
		and Rect2(Vector2.ZERO, GameModeLayout.SCREEN).encloses(card) and sc.centre().x + ArmScope.RADIUS <= card.size.x
		and sc.centre().y + ArmScope.RADIUS <= card.size.y and sc.demo_pan() == sc.demo_pan(),
		"game mode scope: the arm camera is a round scope on the right of the status row (hidden with no camera; the demo has its own picture); it covers neither the field, the UFO's rail, the clock nor the Dial's port",
		"%s %s" % [hidden, shown])
	ctl.close()
	_ok(not sc.visible and sc._demo_view.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"game mode scope: closed with the score game (nothing drawn)")
	_gm_free(game, rs)

## #143: the score game's sound files (Kenney, CC0), the buses, the pan, the priority, the
## fallback to the synthesised sounds, the music's two takes.
func _test_game_mode_audio(rs: Node) -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GameModeSounds.MANIFEST))
	var entries: Dictionary = manifest.sounds
	var files_ok := true
	for key in entries.keys():
		var m: Dictionary = entries[key]
		var path := GameModeSounds.AUDIO_DIR + str(m.file)
		if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != str(m.sha256) or not str(m.page).begins_with("https://kenney.nl/assets/") \
				or str(m.pack) == "" or str(m.purpose) == "" or float(m.seconds) <= 0.0:
			files_ok = false
			print("  manifest: ", key, " ", path)
	_ok(files_ok and entries.size() >= 27 and manifest.licence == "CC0-1.0" and str(manifest.mirror.commit).length() == 40
		and FileAccess.file_exists("res://assets/audio/licenses/kenney_cc0.md"),
		"audio: every sound in the manifest is here unchanged (sha256), with its pack, its page at the source and the CC0 licence recorded")
	var snd := GameModeSounds.new()
	add_child(snd)
	snd.enabled = true
	# every sound the controller asks for exists, as a file, and as a synthesised fallback
	var src := FileAccess.get_file_as_string("res://scripts/game_mode/game_mode_controller.gd")
	var re := RegEx.new()
	re.compile("sounds\\.play\\(\"([a-z_]+)\"\\)")
	var asked: Array = []
	for hit in re.search_all(src):
		if not asked.has(hit.get_string(1)):
			asked.append(hit.get_string(1))
	for kind in ScoreManager.DEFAULT_TABLE.keys():  # the hits play their kind's name ("goal" for the goals)
		var k: String = "goal" if str(kind).begins_with("goal") else ("bonus" if kind == "switch_bonus" else str(kind))
		if not asked.has(k):
			asked.append(k)
	# the practice's two sounds (#149) are synthesised only: no file was added for them
	var with_files: bool = asked.all(func(k): return snd.source_of(k) == ("synth" if k in GameModeSounds.SYNTH_ONLY else "file"))
	snd.use_files = false
	var synth: bool = asked.all(func(k): return snd.source_of(k) == "synth")
	snd.use_files = true
	snd.load_manifest("res://assets/audio/no_such_manifest.json")
	var no_manifest: bool = asked.all(func(k): return snd.source_of(k) == "synth") and snd.source_of("nothing") == ""
	snd.play("bumper")  # still sounds, synthesised
	var fallback_plays: bool = snd.sounding() == 1 and snd.log.has("bumper")
	snd.load_manifest()
	snd.silence()
	_ok(asked.size() >= 26 and with_files and synth and no_manifest and fallback_plays,
		"audio: every sound the score game asks for has a file and a synthesised fallback; with files off or the manifest missing it still plays",
		"%d %s %s %s %s" % [asked.size(), with_files, synth, no_manifest, fallback_plays])
	# the buses, the Dial's side, the gap, the priority
	var buses: bool = [AudioBuses.SFX, AudioBuses.SFX_LEFT, AudioBuses.BGM, AudioBuses.VOICE].all(
		func(b): return AudioServer.get_bus_index(b) >= 0) and AudioServer.get_bus_index("SFX Right") < 0
	var pan_l: float = (AudioServer.get_bus_effect(AudioServer.get_bus_index(AudioBuses.SFX_LEFT), 0) as AudioEffectPanner).pan
	snd.on_lane("left", "ABSORBING")
	snd.on_lane("left", "RETURNING")
	snd.on_lane("", "RELEASING")  # the lane state does not say: the event's own side decides
	snd.play("absorb")
	snd.play("return")
	snd.play("go")
	snd.play("release", "left")
	var sides: Array = snd.voices.filter(func(v): return not v.is_empty()).map(func(v): return "%s:%s" % [v.key, v.side])
	var bus_mid: bool = snd._players.any(func(pl): return pl.playing and pl.bus == AudioBuses.SFX)
	var bus_l: bool = snd._players.any(func(pl): return pl.playing and pl.bus == AudioBuses.SFX_LEFT)
	_ok(buses and pan_l < 0.0 and AudioBuses.sfx_bus("right") == AudioBuses.SFX and sides.has("absorb:left") and sides.has("return:left") and sides.has("go:") and sides.has("release:left") and bus_mid and bus_l,
		"audio: effects, music and voice have their own buses; the Dial's sounds go to its side (the left; there is no right bus, #200), the others stay in the middle",
		str(sides))
	snd.silence()
	snd.log.clear()
	# the sounds play out in real time and the pin is 23 ms long: a runner that stalls that
	# long would end it before the count (7 sounding, not 8). The audio is slowed while this
	# part counts the players, so nothing ends under the test; it is set back after.
	AudioServer.playback_speed_scale = 0.001
	snd.play("pin")
	snd.play("pin")  # inside the gap: not again
	var gap_ok: bool = snd.log.count("pin") == 1 and snd.min_gap_ms("pin") > 0
	for k in ["bumper", "pop", "spinner", "switch", "target", "gem", "goal", "warp"]:
		snd.play(k)
	var full := snd.sounding()
	var before_drop := snd.dropped
	snd.play("sling")  # priority 0 with every player busy: dropped
	var was_dropped: bool = snd.dropped == before_drop + 1 and snd.sounding() == GameModeSounds.PLAYERS
	snd.play("jackpot")  # priority 2: takes a lesser sound's player
	var stole: bool = snd.voices.any(func(v): return v.get("key", "") == "jackpot") and snd.sounding() == GameModeSounds.PLAYERS \
		and not snd.voices.any(func(v): return v.get("key", "") == "pin")
	snd.play("stop")
	var cut: bool = snd.sounding() == 1 and snd.voices.filter(func(v): return not v.is_empty()).size() == 1
	_ok(gap_ok and full == GameModeSounds.PLAYERS and was_dropped and stole and cut and snd.priority_of("pin") == 0 and snd.priority_of("jackpot") == 2,
		"audio: one pin sound per gap; with every player busy a pin-level sound is dropped and a jackpot takes the least important one's player; stop cuts the rest",
		"%s %d %s %s %s" % [gap_ok, full, was_dropped, stole, cut])
	AudioServer.playback_speed_scale = 1.0
	# volumes and mutes; the music's two takes fade and are not the same take pitched up
	AudioBuses.apply({"enabled": true, "bgm_enabled": false, "sfx_volume_db": -6.0})
	var muted: bool = AudioBuses.muted(AudioBuses.BGM) and not AudioBuses.muted(AudioBuses.SFX) and AudioBuses.volume_db(AudioBuses.SFX) == -6.0
	AudioBuses.apply({"enabled": false})
	var all_off: bool = AudioBuses.muted(AudioBuses.BGM) and AudioBuses.muted(AudioBuses.SFX)
	AudioBuses.apply({})
	AudioBuses.ensure(0.0)  # the configured pan survives the settings being applied again
	AudioBuses.apply({})
	var pan_kept: bool = AudioBuses.pan() == 0.0
	AudioBuses.ensure(AudioBuses.DEFAULT_PAN)
	snd.set_bgm(true)
	var normal: bool = snd._bgm.playing and snd._bgm_gain == 1.0 and snd._fast_gain == 0.0 and not snd._bgm_fast.playing
	snd.set_bgm(true, true)
	var crossing: bool = snd.hurry  # no fade (#181): the faster take is on at once
	var fast: bool = snd._bgm_fast.playing and not snd._bgm.playing and snd._bgm_fast.pitch_scale == 1.0
	snd.set_bgm(false)
	var faded: bool = not snd._bgm.playing and not snd._bgm_fast.playing and not snd.bgm_on
	var takes: bool = (snd._bgm_fast.stream as AudioStreamWAV).data.size() < (snd._bgm.stream as AudioStreamWAV).data.size()
	_ok(muted and all_off and pan_kept and is_equal_approx(AudioBuses.pan(), AudioBuses.DEFAULT_PAN) and not AudioBuses.muted(AudioBuses.BGM) and normal and crossing and fast and faded and takes and snd.duck_db() == 0.0,
		"audio: effects and music are turned down and muted separately; the music starts at once, switches to its own faster take for the last 30 s (not the same take pitched up) and stops at once",
		"%s %s %s %s %s %s %s" % [muted, all_off, normal, crossing, fast, faded, takes])
	remove_child(snd)
	snd.free()
	# in a round: the combo's step has its sound, the voices go to the Voice bus
	var game := _gm_game()
	var ctl: GameModeController = _gm_playing(game)
	ctl.mock_hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(ctl.lanes["left"].capsule.capsule_id)
	var f := ctl.field
	for target in ["bumper_0", "pop_1"]:
		f._on_capsule_body(f.get_children().filter(func(n): return n.has_meta("target") and n.get_meta("target") == target)[0], id)
	ctl.tick(1.0 / 60.0)
	_ok(ctl.sounds.log.has("combo") and ctl.sounds.combo_step == 1 and ctl.sounds.side_of("absorb") == "left" and ctl.sounds.side_of("drop") == "left"
		and ctl.sounds.log.has("absorb") and ctl.sounds.log.has("drop") and ctl.sounds.log.has("bumper") and ctl.sounds.log.has("pop")
		and game.study_mode.speech._player.bus == AudioBuses.VOICE,
		"audio: in a round the combo's step has its sound, the Dial's transfer sounds are on its side (the left), and UFOくん's voice is on the Voice bus",
		"%s %d %s" % [ctl.sounds.log, ctl.sounds.combo_step, ctl.sounds.side_of("absorb")])
	_gm_free(game, rs)

## #144: sparks and rings from a bounded pool, the hit flash, the picture-only hit-stop,
## and UFOくん's reactions.
## #304: every effect is played at its own level (the manifest's gain_db, the own files' and
## the synthesised sounds' tables), the study mode's and the motion's effects go through the
## effects' bus, and the music is not far under the effects.
func _test_audio_levels() -> void:
	var snd := GameModeSounds.new()
	add_child(snd)
	snd.enabled = true
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GameModeSounds.MANIFEST))
	var at := {}
	for key in ["go", "pin", "final_hit", "reveal"]:
		snd.silence()
		snd.play(key)
		for i in snd.voices.size():
			if str(snd.voices[i].get("key", "")) == key:
				at[key] = snd._players[i].volume_db - snd.volume_db
	var levels: bool = is_equal_approx(float(at.get("go", 99.0)), float(manifest.sounds.go.gain_db)) \
		and is_equal_approx(float(at.get("pin", 99.0)), float(manifest.sounds.pin.gain_db)) \
		and is_equal_approx(float(at.get("final_hit", 99.0)), float(GameModeSounds.SYNTH_META.final_hit.gain_db)) \
		and is_equal_approx(float(at.get("reveal", 99.0)), snd.gain_db_of("reveal"))
	var own: bool = snd.source_of("reveal") != "file" or is_equal_approx(snd.gain_db_of("reveal"), float(GameModeSounds.OWN_GAIN_DB.reveal))
	snd.silence()
	snd.free()
	var study := StudySounds.new()
	add_child(study)
	study.play("go")  # a manifest file: its gain_db
	var sp: AudioStreamPlayer = study._players[0]
	var study_ok: bool = sp.bus == AudioBuses.SFX and is_equal_approx(sp.volume_db - study.volume_db, float(manifest.sounds.go.gain_db))
	study.play("boom")  # synthesised: its own table
	var sp2: AudioStreamPlayer = study._players[1]
	study_ok = study_ok and is_equal_approx(sp2.volume_db - study.volume_db, float(StudySounds.GAIN_DB.boom))
	for p in study._players:
		p.stop()
	study.free()
	var fx := Sfx.new()
	add_child(fx)
	var motion: bool = fx._players.values().all(func(p): return p.bus == AudioBuses.SFX) and fx._cue_player.bus == AudioBuses.SFX \
		and float(Sfx.VOICE_GAIN_DB.up) < float(Sfx.VOICE_GAIN_DB.move)
	fx.free()
	_ok(levels and own and study_ok and motion and GameModeSounds.BGM_DB > -6.0,
		"audio levels #304: each effect at its own gain (manifest / own file / synthesised), the study's and the motion's on the effects' bus, the music near the effects",
		"%s %s %s %s %s" % [at, own, study_ok, motion, GameModeSounds.BGM_DB])

func _test_game_mode_reactions(rs: Node) -> void:
	var ps := GameModeParticles.new()
	add_child(ps)
	ps.burst(Vector2(100, 100), Color.RED, 20)
	var some := ps.sparks()
	for i in 30:
		ps.burst(Vector2(100, 100), Color.RED, 50)
		ps.ring(Vector2(100, 100), Color.RED)
	var full := ps.sparks()
	var rings := ps.rings()
	ps.advance(2.0)
	var gone: bool = ps.sparks() == 0 and ps.rings() == 0
	ps.quality = "low"
	var low := ps.granted(20)
	ps.effects = false
	ps.burst(Vector2.ZERO, Color.RED, 20)
	ps.ring(Vector2.ZERO, Color.RED)
	_ok(some == 20 and full == GameModeParticles.MAX_SPARKS and rings == GameModeParticles.MAX_RINGS and gone and low == 10
		and ps.sparks() == 0 and ps.rings() == 0 and ps.get_child_count() == 0,
		"game mode particles: sparks and rings come from a fixed pool (never more than its size, no nodes made), die by themselves, are halved at low quality and off with effects",
		"%d %d %d %s %d" % [some, full, rings, gone, low])
	remove_child(ps)
	ps.free()
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.1)
	var fx := ctl.fx
	var started: bool = fx.reactions.has("start") and fx.ufo_face() == "excited" and fx.ufo_offset().y <= 0.0 and ctl.particles.sparks() > 0
	_gm_step(ctl, 1.2)
	var idle: bool = fx.reaction() == "" and fx.ufo_face() == "" and fx.ufo_offset() == Vector2.ZERO
	ctl.mock_hub.mock_ball(GM_L)
	ctl.tick(1.0 / 60.0)
	var called: bool = fx.reaction() == "call" and fx.ufo_face() == "surprised"
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var dropped: bool = fx.reactions.has("drop")
	var id := str(ctl.lanes["left"].capsule.capsule_id)
	var f := ctl.field
	var body := func(target: String) -> Node:
		return f.get_children().filter(func(n): return n.has_meta("target") and n.get_meta("target") == target)[0]
	_gm_step(ctl, 0.6)
	ctl.particles.clear()
	f._on_capsule_body(body.call("bumper_0"), id)
	var pleased: bool = (fx.reaction() == "score" and fx.ufo_face() == "happy" and f.capsule_flash(id) > 0.0
		and ctl.particles.sparks() >= 10 and ctl.particles.rings() == 1 and ctl.hitstop_left() == 0.0)
	_ok(started and idle and called and dropped and pleased,
		"game mode UFO: excited and jumping at GO, idle again after, surprised when a capsule is on its way, winks as it drops it, happy at a score (the capsule flashes, sparks and a ring fly)",
		"%s %s %s %s %s" % [started, idle, called, dropped, pleased])
	# a big score: the picture alone holds still; the clock and the physics state go on
	var star: Area2D = f.get_children().filter(func(n): return n is Area2D and n.get_meta("target") == "star")[0]
	var cap: RigidBody2D = f._capsules[id].body
	f._on_area(cap, star)
	var stopped := ctl.hitstop_left()
	var t0 := ctl.time_left
	ctl._process(0.016)
	var held: bool = ctl.pixel_view.render_target_update_mode == SubViewport.UPDATE_DISABLED
	ctl.tick(1.0 / 60.0)
	var clock_ran: bool = ctl.time_left < t0
	ctl._process(0.2)
	var released: bool = ctl.pixel_view.render_target_update_mode == SubViewport.UPDATE_ALWAYS and ctl.hitstop_left() == 0.0
	var big_face := fx.ufo_face()
	fx.react("score")  # a weaker reaction does not cut the big one short
	var kept: bool = fx.reaction() == "big"
	fx.react("stop")
	var cut: bool = fx.reaction() == "stop"
	ctl.effects = false
	ctl.hitstop(0.08)
	var no_stop: bool = ctl.hitstop_left() == 0.0 and fx.ufo_offset() == Vector2.ZERO
	ctl.effects = true
	_ok(stopped > 0.0 and stopped <= GameModeController.HITSTOP_MAX_S and held and clock_ran and released and big_face == "excited" and kept and cut and no_stop,
		"game mode juice: a big score holds the picture still for a moment (bounded) while the clock runs on; a stronger reaction is not cut short by a weaker one; effects off = no hit-stop",
		"%s %s %s %s %s %s %s" % [stopped, held, clock_ran, released, big_face, kept, cut])
	# the moods: worried for the last 30 s, sad at a miss, sleepy when the time is up, happy at the result
	_gm_step(ctl, 1.2)
	ctl.time_left = ctl.hurry_s + 0.01
	ctl.tick(1.0 / 60.0)
	ctl.tick(1.0 / 60.0)
	var hurried: bool = fx.reactions.has("hurry") and fx.ufo_mood == "hurry"
	_gm_step(ctl, 1.0)
	var worried := fx.ufo_face()
	f._exit(id, "timeout", Vector2(600, 400))
	var missed: bool = fx.reaction() == "miss" and fx.ufo_face() == "sad"
	ctl.time_left = 0.01
	_gm_step(ctl, 0.1)
	var over := fx.ufo_mood
	_gm_step(ctl, 12.0)
	_ok(hurried and worried == "worried" and missed and over == "over" and ctl.phase == "RESULT" and fx.ufo_mood == "happy"
		and fx.reactions.has("big") and GameModeVFX.REACTIONS.values().all(func(r): return GameModeVFX.UFO_FACES.has(r[0]))
		and GameModeVFX.MOODS.values().all(func(m): return m == "" or GameModeVFX.UFO_FACES.has(m)),
		"game mode UFO: worried for the last 30 seconds, sad when a capsule runs out of time, sleepy at time up, happy at the result; every face is on the expression sheet",
		"%s %s %s %s %s %s" % [hurried, worried, missed, over, ctl.phase, fx.ufo_mood])
	_gm_free(game, rs)

## #171: the debug panel is not beside the score game; the spell waits a moment for its voice.
func _test_score_game_panel_and_spell_voice(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	game._set_debug_visible(true)
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	var closed = not game.debug_ui.visible and ctl.active()
	game._unhandled_input(_key(KEY_F1))
	var f1_opens = game.debug_ui.visible
	game._unhandled_input(_key(KEY_F1))
	game.show_title()
	game._unhandled_input(_key(KEY_G))  # another mode: the panel is as it was before the score game
	var back = game.debug_ui.visible
	game.show_title()
	ctl.debug_panel = true  # config game_mode.debug_panel
	game._unhandled_input(_key(KEY_3))
	var kept = game.debug_ui.visible
	_ok(closed and f1_opens and back and kept,
		"score game: the debug panel is closed when the score game opens (F1 opens it; it is back for the other modes; game_mode.debug_panel keeps it)",
		"%s %s %s %s" % [closed, f1_opens, back, kept])
	# the spell: its voice comes over a link that is only just opening
	ctl.tutorial_auto = true
	var hw = ctl.tutorial_voice.client()
	game._unhandled_input(_key(KEY_ENTER))
	var waits = hw == null or (not ctl.tutorial_voice.pending.is_empty() and ctl.tutorial_speech.current == "")
	_gm_step(ctl, 1.0)
	var still = hw == null or (not ctl.tutorial_voice.pending.is_empty() and ctl.tutorial.kind() == "summon")
	if hw != null:
		hw.link.enabled = false  # (no link to wait for any more: as when it is up and the hello came)
	_gm_step(ctl, 0.1)
	if hw != null:
		hw.link.enabled = true
	var said_after_hello = ctl.tutorial_voice.pending.is_empty() and ctl.tutorial_speech.current.contains("ベントラ")
	# no link ever: the words come anyway, after the wait, and the practice goes on
	ctl.close()
	ctl.open()
	ctl.start_tutorial()
	_gm_step(ctl, ctl.tutorial_voice.link_wait_s + 0.2)
	var words_anyway = ctl.tutorial_voice.pending.is_empty() and ctl.tutorial_speech.current.contains("ベントラ")
	_ok(waits and still and said_after_hello and words_anyway and is_equal_approx(ctl.tutorial_speech.voice_wait_s, 6.0),
		"tutorial voice: the spell waits for the voice's link (at most a moment) instead of being shown without its voice",
		"%s %s %s %s hw=%s" % [waits, still, said_after_hello, words_anyway, hw != null])

## #173: the music from the files of assets/audio/bgm (each machine's own): menu, round, result.
func _test_game_mode_music_files(rs: Node) -> void:
	# two made-up files (the real ones are never in Git); the third track has none
	var dir := "user://test_bgm/"
	DirAccess.make_dir_recursive_absolute(dir)
	var tone = StudySounds._tones([[440.0, 0.3]], 0.2)
	tone.save_to_wav(dir + "menu.wav")
	tone.save_to_wav(dir + "round.wav")
	for more in ["top.wav", "practice.wav", "jingle.wav"]:
		tone.save_to_wav(dir + more)
	var f := FileAccess.open(dir + "broken.mp3", FileAccess.WRITE)
	f.store_string("not music")
	f.close()
	var loaded = GameModeSounds.load_music_stream(dir + "menu.wav")
	var loops = loaded is AudioStreamWAV and loaded.loop_mode == AudioStreamWAV.LOOP_FORWARD and loaded.loop_end > 1000
	var missing = GameModeSounds.load_music_stream(dir + "nothing.ogg") == null and GameModeSounds.load_music_stream(dir + "x.txt") == null
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	var snd: GameModeSounds = ctl.sounds
	snd.enabled = true
	var none_by_default = not snd.has_music("menu") and not snd.has_music("game")  # the tests read no file of this machine
	GameModeSounds.load_music = true
	snd.music_names = {"top": "top.wav", "menu": "menu.wav", "tutorial": "practice.wav", "game": "round.wav", "ending": "ending.mp3"}  # (no ending.mp3 there)
	snd.jingle_name = "jingle.wav"
	snd.load_music_files(dir)
	GameModeSounds.load_music = false
	var found = snd.has_music("menu") and snd.has_music("game") and not snd.has_music("ending")
	var tick := func(secs: float) -> void:
		for i in int(secs * 60.0):
			game._process(1.0 / 60.0)
			snd._process(1.0 / 60.0)
	# the title screen, then the score game's own title: the menu's music
	game.show_title()
	tick.call(2.0 / 60.0)
	# #181: the title screen has its own music, at once and at its full level (no fade)
	var on_title = snd.track_wanted() == "top" and snd._music["top"].playing and snd._music_gain["top"] == 1.0 and not snd._music["menu"].playing \
		and is_equal_approx(snd._music["top"].volume_db, snd.volume_db + GameModeSounds.BGM_DB + float(snd.music_gain_db["top"]))
	# the 校正 tab: no music at all; back from it the music is there again
	snd.silent = true
	snd._process(1.0 / 60.0)
	var calib_quiet = snd.track_wanted() == "" and not snd._music["top"].playing
	snd.silent = false
	tick.call(2.0 / 60.0)
	var calib_back = not game.calibrating() and snd._music["top"].playing
	# a mode is chosen: the jingle once (not a loop), alone; then the score game's title music
	var j0 = snd.jingles
	game._unhandled_input(_key(KEY_3))
	var jingle = snd.jingles == j0 + 1 and snd.jingle_playing() and not (snd._jingle.stream as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_FORWARD
	tick.call(2.0 / 60.0)
	var jingle_alone = snd.track_wanted() == "" and not snd._music["top"].playing and not snd._music["menu"].playing
	# a jingle still sounding when the round's music starts is cut (the synthesised tune too)
	snd.set_bgm(true)
	var jingle_cut = not snd.jingle_playing()
	snd.set_bgm(false)
	snd.play_jingle()
	snd._jingle.stop()
	tick.call(0.2)
	var on_game_title = snd.track_wanted() == "menu" and snd._music["menu"].playing and not snd._music["top"].playing
	_ok(calib_quiet and calib_back and jingle and jingle_alone and jingle_cut,
		"music (#181): none in the calibration tab; choosing a mode on the title plays the jingle once, alone, then the next music",
		"%s %s %s %s" % [calib_quiet, calib_back, jingle, jingle_alone])
	# the practice has its own music, the countdown after it none
	game._unhandled_input(_key(KEY_T))
	tick.call(2.0 / 60.0)
	var practice_music = ctl.phase == "TUTORIAL" and snd.track_wanted() == "tutorial" and snd._music["tutorial"].playing and not snd._music["menu"].playing
	ctl._halt("test")
	tick.call(2.0 / 60.0)
	_ok(practice_music and not snd._music["tutorial"].playing, "music (#181): the practice has its own music, stopped at once when it ends", "%s %s" % [practice_music, ctl.phase])
	# the round: its file, not the synthesised tune, also in the last stretch
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, 0.5)
	tick.call(1.0)
	var countdown_quiet = ctl.phase == "COUNTDOWN" and snd.track_wanted() == "" and not snd._music["menu"].playing
	_gm_step(ctl, ctl.countdown_s)
	tick.call(1.0)
	var in_round = ctl.phase == "PLAYING" and snd.track_wanted() == "game" and snd._music["game"].playing \
		and not snd._bgm.playing and not snd._bgm_fast.playing
	ctl.time_left = ctl.hurry_s - 0.1
	_gm_step(ctl, 0.2)
	tick.call(1.0)
	var hurry_same = snd.hurry and snd._music["game"].playing and not snd._bgm_fast.playing
	# the result: no file for it here -> silence, and the round's music has faded out
	ctl.time_left = 0.05
	_gm_step(ctl, ctl.closing_wait_s + 1.0)
	tick.call(1.0)
	var result_wanted = ctl.phase == "RESULT" and snd.ending_on and snd.track_wanted() == "ending" and not snd._music["game"].playing
	# with a file for the result it plays; a new round ends it; music off = nothing
	snd.music_names["ending"] = "menu.wav"
	GameModeSounds.load_music = true
	snd.load_music_files(dir)
	GameModeSounds.load_music = false
	tick.call(0.5)
	var ending_plays = snd._music["ending"].playing
	snd.enabled = false
	tick.call(1.0)
	var off_silent = snd.track_wanted() == "" and not snd._music["ending"].playing
	snd.enabled = true
	game._unhandled_input(_key(KEY_ENTER))
	game._unhandled_input(_key(KEY_ENTER))
	game._unhandled_input(_key(KEY_ENTER))
	var next_round = not snd.ending_on
	game.show_title()
	tick.call(0.2)
	var back_to_menu = snd.track_wanted() == "top"
	game._unhandled_input(_key(KEY_G))  # another mode: no music
	tick.call(0.2)
	var other_mode = snd.track_wanted() == ""
	# a file that is not music is as no file: the round keeps the synthesised tune
	snd.music_names = {"top": "", "menu": "", "tutorial": "", "game": "broken.mp3", "ending": ""}
	GameModeSounds.load_music = true
	snd.load_music_files(dir)
	GameModeSounds.load_music = false
	snd.set_bgm(true)
	tick.call(0.5)
	var synth_kept = not snd.has_music("game") and snd._bgm.playing
	snd.set_bgm(false)
	_ok(loops and missing and none_by_default and found and on_title and on_game_title and countdown_quiet and in_round and hurry_same,
		"music files: the menu's on the title screens, the round's while the clock runs (one track to the end, no synthesised tune over it), nothing in the countdown; files loop",
		"%s %s %s %s %s %s %s %s %s" % [loops, missing, none_by_default, found, on_title, on_game_title, countdown_quiet, in_round, hurry_same])
	_ok(result_wanted and ending_plays and off_silent and next_round and back_to_menu and other_mode and synth_kept,
		"music files: the result's after the round until the next one; sound off = none; other modes = none; a missing or unreadable file leaves things as they were (the synthesised tune for the round)",
		"%s %s %s %s %s %s %s" % [result_wanted, ending_plays, off_silent, next_round, back_to_menu, other_mode, synth_kept])
	for name in ["menu.wav", "round.wav", "broken.mp3", "top.wav", "practice.wav", "jingle.wav"]:
		DirAccess.remove_absolute(dir + name)
	_gm_free(game, rs)

## The real field: capsules dropped from several X reach a goal by themselves (Godot's
## physics, run faster than real time), touching scoring targets on the way.
## The round's end bonuses and the result's timeline (#153), with no game: the sums, no
## double count, the order of the cues, the number shown against the truth.
func _test_game_mode_result_logic() -> void:
	var b := ResultBonus.compute(12340, 7, 5, 2)
	var ids: Array = b.items.map(func(it): return it.id)
	_ok(b.base_score == 12340 and b.capsule_bonus == 700 and b.combo_bonus == 250 and b.jackpot_bonus == 1000
		and b.total_bonus == 1950 and b.final_score == 14290 and ids == ["capsule", "combo", "jackpot"],
		"result bonus: capsules x100 + the longest chain x50 + jackpots x500, added to the score in that order", str(b))
	var tuned := ResultBonus.compute(500, 3, 4, 1, {"capsule_each": 10, "combo_each": 0, "jackpot_each": 7})
	var zero := ResultBonus.compute(0, 0, 0, 0)
	_ok(tuned.capsule_bonus == 30 and tuned.combo_bonus == 0 and tuned.jackpot_bonus == 7 and tuned.final_score == 537
		and tuned.items.size() == 2 and zero.final_score == 0 and zero.total_bonus == 0 and zero.items.is_empty()
		and ResultBonus.valid_capsules([{"late": false}, {"late": true}, {}]) == 2,
		"result bonus: the rates are config values, a bonus of 0 is left out, a late capsule does not count, nothing scored is a result too")
	# what ScoreManager already paid (the switch bonus, the jackpot's own points) is in the base score only
	var s := ScoreManager.new()
	for i in 3:
		s.hit("c1", "switch", "switch_%d" % i, 1.0 + 0.1 * i)
	s.goal("c1", "center", 2.0)
	var played := s.score
	var b2 := ResultBonus.compute(s.score, 1, s.best_chain, s.jackpots)
	_ok(s.jackpots == 1 and int(s.counts.get("switch_bonus", 0)) == 1 and played >= 1500 + 3000 and s.score == played
		and b2.base_score == played and b2.total_bonus == 100 + 50 * s.best_chain + 500 and b2.final_score == played + b2.total_bonus,
		"result bonus: the switch bonus and the jackpot scored while playing are not added again; ScoreManager.score is not changed",
		"%d %s" % [played, str(b2)])
	# the timeline
	var show := ResultShow.new()
	var ks: Array = []
	var at_lock := {}
	show.cue.connect(func(name, d):
		if name == "count":
			ks.append(float(d.k))
		if name in ["score_lock", "bonus_lock"]:
			at_lock[show.log.size()] = [show.shown, show.banked])
	show.time_up()
	var flashed: bool = show.flash == 1.0 and show.log == ["time_up"] and not show.active()
	show.begin(b)
	var mono := true
	var over := false
	var last := 0.0
	var secs := 0.0
	var titles: Array = []
	while not show.settled() and secs < 60.0:
		show.advance(1.0 / 60.0)
		secs += 1.0 / 60.0
		mono = mono and show.shown >= last - 0.001
		over = over or show.shown > float(b.final_score) + 0.001
		last = show.shown
		if titles.is_empty() or titles[-1] != show.title():
			titles.append(show.title())
	var order: Array = show.log.filter(func(n): return n != "count" and n != "confetti")
	var locks_ok := at_lock.values().all(func(v): return int(round(v[0])) == int(v[1]))
	_ok(flashed and order == ["reveal", "score_lock", "bonus_show", "bonus_hit", "bonus_lock", "bonus_show", "bonus_hit", "bonus_lock",
		"bonus_show", "bonus_hit", "bonus_lock", "wind_up", "final", "settled"] and titles == ["YOUR SCORE", "BONUS!", "FINAL SCORE!"]
		and secs > 8.0 and secs < 20.0, "result show: TIME UP, the score, each bonus announced then added, FINAL SCORE, in one timeline",
		"%s %.1f s %s" % [str(order), secs, str(titles)])
	_ok(mono and not over and locks_ok and at_lock.size() == 4 and int(round(show.shown)) == 14290 and show.banked == 14290
		and b.final_score == 14290 and b.base_score == 12340,
		"result show: the number shown only climbs, stops on the truth at every lock and never passes the final score; the breakdown is not touched",
		"%s %s %s %s" % [mono, over, locks_ok, str(at_lock)])
	var rising := ks.size() > 20
	for i in range(1, ks.size()):
		if ks[i] < ks[i - 1] - 0.001 and ks[i] > 0.3:
			rising = false  # (a drop is only ever a new count starting low again)
	_ok(rising and ks.max() > 0.9 and ks.min() < 0.3, "result show: the counting blips climb with the number (their pitch follows)", str(ks.size()))
	# after the end nothing more happens: no bonus is ever added a second time
	var cues := show.log.size()
	for i in 600:
		show.advance(1.0 / 60.0)
	_ok(show.log.size() == cues and show.banked == 14290 and int(round(show.shown)) == 14290 and show.log.count("bonus_hit") == 3,
		"result show: each bonus lands once; after the final score nothing is added, however long it stays")
	# Enter in the middle: the last picture at once
	show.begin(b)
	for i in 150:
		show.advance(1.0 / 60.0)
	var mid: bool = not show.settled() and show.shown < 14290.0
	show.skip()
	var skipped: bool = show.settled() and int(round(show.shown)) == 14290 and show.log[-1] == "settled" and show.title() == "FINAL SCORE!"
	cues = show.log.size()
	show.skip()
	show.advance(1.0)
	_ok(mid and skipped and show.log.size() == cues, "result show: a skip goes straight to the final score, once")
	# no animation (effects off), and a round with nothing scored
	show.begin(b, false)
	var plain: bool = show.settled() and int(round(show.shown)) == 14290 and show.log == ["settled"]
	show.begin(zero)
	secs = 0.0
	while not show.settled() and secs < 60.0:
		show.advance(1.0 / 60.0)
		secs += 1.0 / 60.0
	_ok(plain and show.settled() and show.shown == 0.0 and not show.log.has("bonus_show") and show.log.has("final") and secs < 7.0,
		"result show: with effects off the final score stands at once; 0 points and no capsule still ends in FINAL SCORE", "%.1f" % secs)
	for c in show.cue.get_connections():
		show.cue.disconnect(c.callable)  # (the test's own listener holds the show: let go of it)
	show.reset()
	_ok(not show.active() and show.data.is_empty() and show.shown == 0.0 and show.log.is_empty() and show.title() == "",
		"result show: reset() leaves nothing behind (no timer, no tween to carry into the next round)")
	# the number always fits the screen, on the dot grid
	var fits := true
	for digits in range(1, 15):
		for k in [1.0, 1.15, 1.37, 1.72]:
			var sc := GameModeResultScreen.number_scale(digits, k)
			fits = fits and GameModeResultScreen.number_width(digits, k) <= GameModeResultScreen.SCREEN.x and sc >= 2.0 and fmod(sc, 2.0) == 0.0
	_ok(fits and GameModeResultScreen.number_scale(2) == GameModeResultScreen.NUMBER_SCALE
		and GameModeResultScreen.number_scale(5) >= 16.0 and GameModeResultScreen.number_scale(12) < GameModeResultScreen.number_scale(6)
		and PixelText.height(GameModeResultScreen.number_scale(1, 1.72)) <= 300.0,
		"result screen: the number is huge and never wider than the screen, however many digits (its dots are whole canvas dots)")

## The round's end in the game (#153): 0 s -> SETTLING -> RESULT, the breakdown fixed once,
## the show and its keys, a new round clean, no command to a device because of the show.
func _test_game_mode_result_show(rs: Node) -> void:
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var show := ctl.result_show
	var screen := ctl.result_screen
	var l: GameModeController.Lane = ctl.lanes["left"]
	# one capsule played and given back in the round
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(l.capsule.capsule_id)
	ctl.field.target_hit.emit(id, "bumper", "bumper_1", Vector2(500, 400))
	ctl.field.target_hit.emit(id, "bumper", "bumper_2", Vector2(700, 400))
	ctl.field.capsule_exited.emit(id, "center", Vector2(640, 660))
	_gm_step(ctl, 5.0)
	var mid := ctl.score.score
	# 0 s with a capsule in play (it still scores)
	ctl.time_left = 0.5
	hub.mock_ball(GM_L)
	_gm_step(ctl, 0.6)
	_process_frame(screen)
	_ok(ctl.phase == "SETTLING" and show.log == ["time_up"] and screen.mode() == "time_up" and ctl.result.is_empty()
		and ctl.sounds.log.has("timeup") and ctl.sounds.log.has("timeup_hit") and game.shake.trauma > 0.0 and screen.art.visible
		and not show.active() and l.state == "ABSORBING",
		"game mode result: at 0 s TIME UP! (the thud, the flash and the shake at once) while the round settles as before",
		"%s %s %s" % [ctl.phase, str(show.log), screen.mode()])
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s - 0.5)
	var id2 := str(l.capsule.capsule_id)
	ctl.field.target_hit.emit(id2, "star", "star", Vector2(640, 505))
	ctl.field.capsule_exited.emit(id2, "left", Vector2(300, 660))
	var sent := {}
	_gm_step(ctl, 5.0)
	var base := ctl.score.score
	var res: Dictionary = ctl.result
	var row: Dictionary = ctl.trace.named("result")[-1]
	_ok(ctl.phase == "RESULT" and base > mid and res.base_score == base and res.capsules == 2 and ctl.capsules.finished.size() == 2
		and res.capsule_bonus == 200 and res.combo_bonus == 50 * ctl.score.best_chain and res.jackpot_bonus == 0
		and res.final_score == base + res.total_bonus and ctl.final_score() == res.final_score,
		"game mode result: what scored while settling is in the result", "%d %s" % [base, str(res)])
	_ok(int(row.score_delta) == base and row.breakdown is Dictionary and int(row.breakdown.final_score) == res.final_score
		and int(row.breakdown.base_score) == base and int(row.breakdown.total_bonus) == res.total_bonus
		and ctl.hud.result_lines().contains(str(res.final_score)) and ctl.hud.result_lines().contains(str(base)),
		"game mode result: the trace's result row carries the same breakdown as the screen", str(row.get("breakdown")))
	# the show runs; the truth does not move, and no device hears of it
	for dev in [GM_L, GM_R]:
		for cmd in ["SET_MODE", "ARM_RECEIVER", "DISARM_RECEIVER", "RELEASE_BALL", "STOP_ALL", "SET_DIAL_EFFECT"]:
			sent["%d %s" % [dev, cmd]] = hub.count(dev, cmd)
	var started: bool = show.active() and not show.settled() and screen.mode() == "result" and show.log[0] == "reveal" \
		and ctl.display_score() == show.shown and show.shown < float(res.final_score)
	# the small score panel shows the very number of the big one, from the first frame of the show
	ctl.hud._shown_score = float(base)  # (where the panel stood when the round ended)
	ctl.hud._process(1.0 / 60.0)
	var panel_same: bool = ctl.hud.shown_score() == show.shown
	_gm_step(ctl, 0.3)
	ctl.hud._process(1.0 / 60.0)
	panel_same = panel_same and ctl.hud.shown_score() == show.shown
	var counted := false
	var secs := 0.0
	var top := 0.0
	while not show.settled() and secs < 60.0:
		_gm_step(ctl, 0.1)
		secs += 0.1
		top = maxf(top, show.shown)
		counted = counted or ctl.sounds.log.has("result_count")
	_process_frame(screen)
	var same_commands := true
	for dev in [GM_L, GM_R]:
		for cmd in ["SET_MODE", "ARM_RECEIVER", "DISARM_RECEIVER", "RELEASE_BALL", "STOP_ALL", "SET_DIAL_EFFECT"]:
			same_commands = same_commands and sent["%d %s" % [dev, cmd]] == hub.count(dev, cmd)
	_ok(panel_same, "game mode result: the HUD's score panel shows the same number as the big one all through the show (no easing of its own)",
		"%s %s" % [ctl.hud.shown_score(), show.shown])
	_ok(started and counted and show.log.count("bonus_hit") == 2 and show.log.has("final") and ctl.sounds.log.has("final_hit")
		and ctl.sounds.log.has("result") and ctl.sounds.log.has("bonus_hit") and int(round(show.shown)) == res.final_score
		and top <= float(res.final_score) + 0.001 and ctl.score.score == base and ctl.result == res
		and screen.number_text() == str(res.final_score) and ctl.fx.reactions.has("big"),
		"game mode result: the score counts up, each bonus lands with its sound, FINAL SCORE; the score and the breakdown stay as they were",
		"%s %s %s %d" % [started, counted, str(show.log.filter(func(n): return n != "count" and n != "confetti")), int(round(show.shown))])
	_ok(same_commands and ctl.phase == "RESULT" and l.state == "CLOSED" and hub.dials[GM_L].op_mode == "STANDBY",
		"game mode result: the show sends nothing to the Dials (STANDBY after the round as before)")
	_ok(screen.keys_text().contains("もう一回") and screen.keys_text().contains("練習") and screen.keys_text().contains("タイトル")
		and screen.stats_text().contains("カプセル  2") and screen.faults_text() == "" and ctl.display_score() == float(res.final_score),
		"game mode result: after the show the final score stays, with the capsules, the best combo, the jackpots and the keys",
		screen.keys_text())
	# Enter after the show: a new round with nothing of the show left
	game._unhandled_input(_key(KEY_ENTER))
	_ok(ctl.phase == "COUNTDOWN" and ctl.score.score == 0 and ctl.result.is_empty() and not show.active() and show.shown == 0.0
		and show.log.is_empty() and screen.particles.sparks() == 0 and screen.particles.rings() == 0 and screen.sheets() == 0
		and screen.mode() == "" and ctl.final_score() == 0,
		"game mode result: the next round starts from nothing (score, breakdown, timeline, sparks and sheets all cleared)")
	# a round with nothing: Enter in the middle of the show only ends the show; the next Enter plays
	_gm_step(ctl, ctl.countdown_s + 0.2)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	var empty: bool = ctl.phase == "RESULT" and ctl.result.final_score == 0 and ctl.result.items.is_empty() and not show.settled()
	game._unhandled_input(_key(KEY_ENTER))
	var skipped: bool = ctl.phase == "RESULT" and show.settled() and show.shown == 0.0 and screen.keys_text().contains("もう一回")
	game._unhandled_input(_key(KEY_ENTER))
	_ok(empty and skipped and ctl.phase == "COUNTDOWN", "game mode result: no capsule and 0 points is a result too; Enter skips the show, Enter again plays",
		"%s %s %s" % [empty, skipped, ctl.phase])
	# Space in the middle of the show: STOP_ALL goes out whatever the show does, the score stands
	_gm_step(ctl, ctl.countdown_s + 0.2)
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	ctl.field.capsule_exited.emit(str(l.capsule.capsule_id), "center", Vector2(640, 660))
	_gm_step(ctl, 5.0)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	_gm_step(ctl, 1.5)
	var stops := hub.count(GM_L, "STOP_ALL")
	var final := ctl.final_score()
	var running_show: bool = ctl.phase == "RESULT" and not show.settled() and final == 1000 + 100 + 0
	game._unhandled_input(_key(KEY_SPACE))
	_ok(running_show and hub.count(GM_L, "STOP_ALL") == stops + 1 and ctl.phase == "RESULT" and show.settled()
		and int(round(show.shown)) == final and ctl.final_score() == final and show.log[-1] == "settled",
		"game mode result: Space during the show sends STOP_ALL at once; the show ends and the final score stands", "%s %d" % [running_show, final])
	# T: the practice from the result; Esc in the middle of a show: the title, nothing left
	game._unhandled_input(_key(KEY_T))
	var practice: bool = ctl.phase == "TUTORIAL" and not show.active() and ctl.result.is_empty()
	game._unhandled_input(_key(KEY_ESCAPE))
	_gm_free(game, rs)
	game = _gm_game()
	ctl = _gm_playing(game)
	show = ctl.result_show
	ctl.time_left = 0.05
	_gm_step(ctl, 3.5)
	var mid_show: bool = ctl.phase == "RESULT" and show.active() and not show.settled()
	game._unhandled_input(_key(KEY_ESCAPE))
	_gm_step(ctl, 0.2)
	_ok(practice and mid_show and not ctl.active() and not show.active() and ctl.result.is_empty() and ctl.result_screen.mode() == "",
		"game mode result: T goes to the practice, Esc in the middle of the show goes to the title; neither leaves the show running",
		"%s %s %s" % [practice, mid_show, ctl.active()])
	_gm_free(game, rs)
	# effects off, no shake, no sound: the result is there at once and the keys work
	game = _gm_game()
	ctl = _gm_playing(game)
	show = ctl.result_show
	ctl.effects = false
	VFXManager.enabled = false
	game.shake.trauma = 0.0
	hub = ctl.mock_hub
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	ctl.field.capsule_exited.emit(str(ctl.lanes["left"].capsule.capsule_id), "left", Vector2(300, 660))
	_gm_step(ctl, 5.0)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	_process_frame(ctl.result_screen)
	var plain: bool = ctl.phase == "RESULT" and show.settled() and int(round(show.shown)) == ctl.final_score() \
		and ctl.final_score() == 100 + 100 and game.shake.trauma == 0.0 and ctl.hitstop_left() == 0.0 \
		and ctl.result_screen.particles.sparks() == 0 and ctl.result_screen.sheets() == 0 and ctl.result_screen.mode() == "result"
	game._unhandled_input(_key(KEY_ENTER))
	VFXManager.enabled = true
	_ok(plain and ctl.phase == "COUNTDOWN", "game mode result: with effects off the final score is shown at once, with no shake, no spark, no sheet; Enter plays again",
		"%s %s %d" % [plain, ctl.phase, ctl.final_score()])
	# the screen shake can be switched off by its own setting; the show goes on without it
	ctl.effects = true
	game.shake.enabled = false
	_gm_step(ctl, ctl.countdown_s + 0.2)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	_ok(ctl.phase == "RESULT" and show.active() and game.shake.trauma == 0.0 and show.log.has("reveal"),
		"game mode result: render.screen_shake off keeps the picture still through TIME UP and the result")
	_gm_free(game, rs)

## The high scores (#155), with no game: the order, ties, the ten places, the file.
func _test_ranking_logic() -> void:
	var path := _rank_file("logic.tsv")
	var rk := RankingManager.new()
	rk.path = path
	rk.load_file()
	_ok(rk.entries.is_empty() and rk.load_error == "" and rk.rows().size() == 10 and int(rk.rows()[0].score) == 0
		and rk.rank_for(100) == 1 and rk.rank_for(0) == 0 and not FileAccess.file_exists(path),
		"ranking: with no file it starts empty (ten empty places), and nothing is written until there is a record")
	var given := [500, 900, 100, 900, 300, 700, 200, 800, 600, 400, 1000, 50]
	var ranks: Array = []
	for i in given.size():
		ranks.append(rk.submit(given[i], "id%d" % i, "2026-11-17T10:00:%02d" % i))
	var scores: Array = rk.entries.map(func(e): return int(e.score))
	var ids: Array = rk.entries.map(func(e): return str(e.id))
	_ok(scores == [1000, 900, 900, 800, 700, 600, 500, 400, 300, 200] and ranks == [1, 1, 3, 2, 4, 3, 6, 3, 5, 7, 1, 0],
		"ranking: the ten best, highest first; each record is told its place as it is made", "%s %s" % [str(scores), str(ranks)])
	_ok(ids[1] == "id1" and ids[2] == "id3" and rk.rank_of("id1") == 2 and rk.rank_of("id3") == 3,
		"ranking: with the same score the record made first stays above")
	_ok(rk.entries.size() == 10 and rk.rank_of("id2") == 0 and rk.rank_of("id11") == 0 and rk.rank_for(200) == 0 and rk.rank_for(201) == 10,
		"ranking: an 11th is not kept (the 100 that was pushed out, the 50 that never got in); a tie with the 10th does not get in")
	var before := rk.to_text()
	_ok(rk.submit(0, "zero") == 0 and rk.submit(-30, "neg") == 0 and rk.submit(5000, "") == 0 and rk.to_text() == before,
		"ranking: 0 points (or less, or no id) is not a record")
	_ok(rk.submit(5000, "id1") == 0 and rk.submit(5000, "id11") == 0 and rk.to_text() == before and rk.entries.size() == 10,
		"ranking: one round is recorded once: an id already on the board, or already turned away, changes nothing")
	# the file, and a restart
	var text := FileAccess.get_file_as_string(path)
	var lines := text.strip_edges().split("\n")
	var again := RankingManager.new()
	again.path = path
	again.load_file()
	_ok(lines.size() == 11 and lines[0] == "rank\tscore\ttimestamp\tid" and lines[1] == "1\t1000\t2026-11-17T10:00:10\tid10"
		and lines[10].begins_with("10\t200\t") and not FileAccess.file_exists(path + ".tmp"),
		"ranking: the file is tab separated text: rank, score, timestamp, id (no name)", lines[1])
	_ok(again.to_text() == before and again.load_error == "" and again.rank_of("id3") == 3 and again.submit(900, "late") == 4
		and again.submit(900, "id3") == 0,
		"ranking: after a restart the same ten are there, ties in the same order, and a record of before is not made again")
	# a damaged file: what can be read is kept, the rest skipped, nothing stops
	var bad := _rank_file("bad.tsv")
	DirAccess.make_dir_recursive_absolute(bad.get_base_dir())
	var f := FileAccess.open(bad, FileAccess.WRITE)
	f.store_string("rank\tscore\ttimestamp\tid\n1\tabc\tt\tx1\n\u0001\u0002garbage without tabs\n9\t700\tt\tgood\n2\t700\tt\tgood\n3\t-5\tt\tneg\n4\t600\tt\n5\t900\tt\tbest\n6\t99999999999999999\tt\thuge\n")
	f.close()
	var hurt := RankingManager.new()
	hurt.path = bad
	hurt.load_file()
	var kept: Array = hurt.entries.map(func(e): return "%s %d" % [e.id, int(e.score)])
	var junk := _rank_file("junk.tsv")
	f = FileAccess.open(junk, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0, 255, 254, 9, 9, 10, 13, 0, 200, 9]))
	f.close()
	var none := RankingManager.new()
	none.path = junk
	none.load_file()
	_ok(kept == ["best 900", "good 700"] and hurt.load_error != "" and FileAccess.file_exists(bad + ".bad") and hurt.submit(800, "new") == 2
		and none.entries.is_empty() and none.submit(10, "first") == 1,
		"ranking: a damaged file never stops the game: the lines that can be read are used (the rank column is not trusted), the old file is kept as .bad",
		"%s / %s" % [str(kept), hurt.load_error])
	# a file that cannot be written: the ranking goes on in memory and says why
	var stuck := RankingManager.new()
	stuck.path = "/dev/null/no_such_dir/rankings.tsv"
	var r := stuck.submit(100, "a")
	var mem := RankingManager.new()
	mem.path = ""
	_ok(r == 1 and stuck.save_error != "" and stuck.entries.size() == 1 and stuck.submit(200, "b") == 1 and stuck.entries.size() == 2
		and mem.submit(5, "m") == 1 and mem.save_error == "",
		"ranking: when the file cannot be written the record still stands until the game closes, and save_error says so", stuck.save_error)
	# review on #156: records the file does not have yet survive a reload (the title, R), and are written when the file can be
	stuck.load_file()
	var held: bool = stuck.entries.size() == 2 and stuck.save_error != ""
	stuck.path = _rank_file("later.tsv")
	stuck.load_file()
	var late := RankingManager.new()
	late.path = stuck.path
	late.load_file()
	_ok(held and stuck.entries.size() == 2 and stuck.save_error == "" and late.to_text() == stuck.to_text() and late.entries.size() == 2,
		"ranking: a reload never throws away records that could not be saved; they are written as soon as the file can be", stuck.save_error)
	# review on #156: a write cut short does not replace the file that was there
	var cut := CutShortRanking.new()
	cut.path = path
	cut.load_file()
	var on_disk := FileAccess.get_file_as_string(path)
	var got := cut.submit(99999, "cut")
	_ok(got == 1 and cut.save_error != "" and FileAccess.get_file_as_string(path) == on_disk and not FileAccess.file_exists(path + ".tmp")
		and on_disk.count("\n") == 11 and cut.entries.size() == 10,
		"ranking: a file cut short as it is written (a full disk) is not put in place of the saved one; the failure is reported", cut.save_error)
	_ok(GameModeRankingHud.rank_color(1) == GameModeRankingHud.GOLD and GameModeRankingHud.rank_color(2) == GameModeRankingHud.SILVER
		and GameModeRankingHud.rank_color(3) == GameModeRankingHud.BRONZE and GameModeRankingHud.rank_color(7) == GameModeRankingHud.REST
		and GameModeRankingHud.row_y(10) + PixelText.height(GameModeRankingHud.row_scale(10)) < GameModeRankingHud.PLATE.end.y
		and GameModeRankingHud.row_y(1) > GameModeRankingHud.PLATE.position.y and Rect2(Vector2.ZERO, GameModeLayout.SCREEN).encloses(GameModeRankingHud.PLATE)
		and GameModeRankingHud.PLATE.size.y > GameModeRankingHud.PLATE.size.x
		and GameModeRankingHud.row_y(4) - GameModeRankingHud.row_y(3) >= PixelText.height(GameModeRankingHud.TOP_SCALE) + 8.0
		and RankingManager.new_id() != RankingManager.new_id(),
		"ranking board: gold, silver, bronze, then the rest; ten rows fit the plate without touching; every round has its own id")

## The high scores in the game (#155): made by itself after the result's show, NEW RECORD!,
## the board, what makes no record, the keys, a restart.
func _test_game_mode_ranking(rs: Node) -> void:
	var path := _rank_file("game.tsv")
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	ctl.ranking.path = path
	ctl.ranking_enabled = true
	var rk := ctl.ranking
	var board := ctl.ranking_hud
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	# R on the score game's title: the board (empty), and back
	game._unhandled_input(_key(KEY_R))
	_process_frame(board)
	_process_frame(ctl.hud)
	var lines := board.board_lines()
	var seen: bool = ctl.phase == "IDLE" and ctl.ranking_view == "board" and board.mode() == "board" and board.art.visible \
		and not ctl.hud.title_showing() and lines.size() == 10 and lines[0] == "1  ---" and lines[9] == "10  ---" \
		and board.keys_text().contains("スタート")
	game._unhandled_input(_key(KEY_R))
	var back: bool = ctl.ranking_view == "" and ctl.hud.title_showing()
	game._unhandled_input(_key(KEY_R))
	game._unhandled_input(_key(KEY_ENTER))
	_ok(seen and back and ctl.phase == "COUNTDOWN" and ctl.ranking_view == "" and ctl.round_id != "",
		"game mode ranking: R on the title shows the high scores (empty places as ---), R goes back, Enter starts from the board",
		"%s %s %s %s" % [seen, back, ctl.phase, str(lines)])
	_gm_step(ctl, ctl.countdown_s + 0.2)
	# a round: nothing is recorded before the result's show is over, then it is, by itself
	var first_id := ctl.round_id
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, 5.0)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	var waiting: bool = ctl.phase == "RESULT" and not ctl.result_show.settled() and rk.entries.is_empty() and ctl.ranking_view == "" \
		and ctl.result_screen.keys_text().contains("スキップ")
	_gm_finish_round(ctl, false)
	var final := ctl.final_score()
	var row: Dictionary = ctl.trace.named("ranking")[-1]
	_ok(waiting and final == 1100 and rk.entries.size() == 1 and int(rk.entries[0].score) == 1100 and str(rk.entries[0].id) == first_id
		and ctl.ranking_rank == 1 and ctl.ranking_view == "" and FileAccess.file_exists(path) and str(row.result) == "rank 1"
		and int(row.score_delta) == 1100 and ctl.score.score == 1000,
		"game mode ranking: when the result's show ends the final score (with its bonuses) is recorded by itself, once; no one types anything",
		"%s %d %s" % [waiting, final, str(rk.entries)])
	game.shake.trauma = 0.0
	_gm_step(ctl, ctl.rank_hold_s + 0.1)
	_process_frame(board)
	_process_frame(ctl.result_screen)
	_ok(ctl.ranking_view == "record" and board.place_text() == "第 1 位！" and ctl.sounds.log.has("new_record") and game.shake.trauma > 0.0
		and board.particles.sparks() > 0 and board.particles.rings() > 0 and board.sheets() > 0 and ctl.result_screen.mode() == ""
		and ctl.phase == "RESULT" and board.keys_text().contains("ランキング"),
		"game mode ranking: a new place in the top ten: NEW RECORD! and the place, with the sound, the shake, the sparks and the confetti at once",
		"%s %s" % [ctl.ranking_view, board.place_text()])
	_gm_step(ctl, ctl.rank_record_s + 0.1)
	_process_frame(board)
	lines = board.board_lines()
	var only_numbers := lines.all(func(l): return l.replace("-", "").replace(" ", "").is_valid_int() or l.ends_with("---"))
	_ok(ctl.ranking_view == "board" and lines[0] == "1  1100" and lines[1] == "2  ---" and only_numbers and board.note_text() == ""
		and board.keys_text().contains("もう一回") and board.keys_text().contains("練習") and board.keys_text().contains("タイトル"),
		"game mode ranking: then the board, HIGH SCORES: places and scores only, this round's place marked", str(lines))
	_gm_step(ctl, 20.0)
	ctl.ranking_flow.register_score()
	_ok(rk.entries.size() == 1 and ctl.ranking_view == "board" and ctl.phase == "RESULT",
		"game mode ranking: staying on the board, or asking again, never records the round a second time")
	# Enter on the board plays again; the new round is a new record of its own
	game._unhandled_input(_key(KEY_ENTER))
	_ok(ctl.phase == "COUNTDOWN" and ctl.ranking_view == "" and ctl.ranking_rank == 0 and ctl.round_id != first_id and board.mode() == ""
		and board.particles.sparks() == 0 and board.sheets() == 0, "game mode ranking: Enter on the board plays again, with nothing of the board left")
	# 0 points: no record. Enter skips the show, Enter again goes to the board, Enter again plays
	_gm_step(ctl, ctl.countdown_s + 0.2)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	game._unhandled_input(_key(KEY_ENTER))
	var skipped: bool = ctl.result_show.settled() and ctl.ranking_view == ""
	game._unhandled_input(_key(KEY_ENTER))
	var zero: bool = ctl.ranking_view == "board" and ctl.ranking_note == "zero" and ctl.ranking_rank == 0 and rk.entries.size() == 1
	game._unhandled_input(_key(KEY_ENTER))
	_ok(skipped and zero and ctl.phase == "COUNTDOWN", "game mode ranking: 0 points is not recorded (the board is still shown); Enter: skip, board, play",
		"%s %s %s" % [skipped, zero, ctl.phase])
	# a stopped round, the demo and a shortened round make no record
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_play_capsule(ctl, "center")
	var asked := ctl.trace.named("ranking").size()
	game._unhandled_input(_key(KEY_SPACE))
	_gm_step(ctl, 20.0)
	var stopped: bool = ctl.phase == "STOPPED" and rk.entries.size() == 1 and ctl.ranking_view == "" and ctl.trace.named("ranking").size() == asked
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, 5.0)
	ctl.demo = true
	_gm_finish_round(ctl, false)
	_gm_step(ctl, ctl.rank_hold_s + 0.1)
	_process_frame(board)
	var demo: bool = ctl.ranking_note == "demo" and ctl.ranking_view == "board" and rk.entries.size() == 1 and ctl.final_score() > 0 \
		and board.note_text().contains("デモ")
	ctl.demo = false
	game._unhandled_input(_key(KEY_ENTER))
	ctl.duration_s = 20.0
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_finish_round(ctl)
	var short: bool = ctl.ranking_note == "short" and rk.entries.size() == 1
	ctl.duration_s = 150.0
	# T from the result: the practice (it has no result, so no record)
	game._unhandled_input(_key(KEY_T))
	_ok(stopped and demo and short and ctl.phase == "TUTORIAL" and ctl.ranking_view == "" and rk.entries.size() == 1,
		"game mode ranking: a stopped round, the demo, a shortened round and the practice make no record",
		"%s %s %s %s" % [stopped, demo, short, ctl.phase])
	game._unhandled_input(_key(KEY_ESCAPE))
	_gm_free(game, rs)
	# a restart: the record is still there; a round that does not reach the ten is not kept
	var fill := RankingManager.new()
	fill.path = path
	fill.load_file()
	var kept: bool = fill.entries.size() == 1 and int(fill.entries[0].score) == 1100
	for i in 9:
		fill.submit(5000 + 100 * i, "fill%d" % i)
	game = _gm_game()
	ctl = game.game_mode
	ctl.ranking.path = path
	ctl.ranking_enabled = true
	board = ctl.ranking_hud
	ctl = _gm_playing(game)
	var loaded: bool = ctl.ranking.entries.size() == 10 and int(ctl.ranking.rows()[9].score) == 1100
	_gm_finish_round(ctl)
	_gm_step(ctl, ctl.rank_hold_s + 0.1)
	_process_frame(board)
	_ok(kept and loaded and ctl.final_score() == 1100 and ctl.ranking_rank == 0 and ctl.ranking_note == "out" and ctl.ranking_view == "board"
		and not ctl.sounds.log.has("new_record") and board.note_text().contains("1100") and ctl.ranking.entries.size() == 10
		and ctl.ranking.rank_of(ctl.round_id) == 0 and FileAccess.get_file_as_string(path).count("\t1100\t") == 1,
		"game mode ranking: the records survive a restart; a round below the ten goes straight to the board and is not kept (a tie with the 10th stays out)",
		"%s %s %d %s" % [kept, loaded, ctl.final_score(), ctl.ranking_note])
	# a higher score lands in the middle of the board, with its place
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	var l: GameModeController.Lane = ctl.lanes["left"]
	ctl.mock_hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	for i in 3:
		ctl.field.target_hit.emit(str(l.capsule.capsule_id), "switch", "switch_%d" % i, Vector2(600, 300))
	ctl.field.capsule_exited.emit(str(l.capsule.capsule_id), "center", Vector2(640, 660))
	_gm_step(ctl, 5.0)
	_gm_finish_round(ctl, false)
	_gm_step(ctl, ctl.rank_hold_s + 0.1)
	var want := ctl.ranking.rank_of(ctl.round_id)
	_ok(ctl.final_score() > 5000 and ctl.ranking_rank == want and want >= 1 and want <= 9 and ctl.ranking_view == "record"
		and board.place_text() == "第 %d 位！" % want and ctl.ranking.entries.size() == 10 and ctl.ranking.rank_of("id-none") == 0
		and int(ctl.ranking.rows()[want - 1].score) == ctl.final_score(),
		"game mode ranking: a score among the ten takes its place there (the old 10th drops off)", "%d -> %d" % [ctl.final_score(), want])
	# Enter on NEW RECORD!: the board at once
	game._unhandled_input(_key(KEY_ENTER))
	var to_board: bool = ctl.ranking_view == "board" and ctl.phase == "RESULT"
	# the file cannot be written: the round still ends, the board says so
	game._unhandled_input(_key(KEY_ENTER))
	ctl.ranking.path = "/dev/null/no_such_dir/rankings.tsv"
	ctl.ranking.clear()
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_finish_round(ctl)
	_gm_step(ctl, ctl.rank_hold_s + ctl.rank_record_s + 0.2)
	_process_frame(board)
	_ok(to_board and ctl.phase == "RESULT" and ctl.ranking_rank == 1 and ctl.ranking_view == "board" and ctl.ranking.save_error != ""
		and board.note_text().contains("保存できなかった"),
		"game mode ranking: Enter on NEW RECORD! goes to the board; a file that cannot be written does not stop the round (the board says so)",
		"%s %s" % [to_board, ctl.ranking.save_error])
	# effects off: no NEW RECORD! show, the board with the place marked; ranking off: the result ends as before
	game._unhandled_input(_key(KEY_ENTER))
	ctl.ranking.path = ""
	ctl.ranking.clear()
	ctl.effects = false
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_finish_round(ctl)
	_gm_step(ctl, ctl.rank_hold_s + 0.1)
	var plain: bool = ctl.ranking_rank == 1 and ctl.ranking_view == "board" and ctl.sounds.last_played == "goal" and board.particles.sparks() == 0 \
		and board.sheets() == 0
	game._unhandled_input(_key(KEY_ENTER))
	ctl.effects = true
	ctl.ranking_enabled = false
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_finish_round(ctl)
	_gm_step(ctl, 10.0)
	var off: bool = ctl.ranking_note == "off" and ctl.ranking_view == "" and ctl.ranking.entries.size() == 1 and ctl.result_screen.mode() == "result"
	game._unhandled_input(_key(KEY_R))
	game._unhandled_input(_key(KEY_ENTER))
	_ok(plain and off and ctl.phase == "COUNTDOWN", "game mode ranking: with effects off the board comes without the show; with the ranking off the result ends as before",
		"%s %s %s" % [plain, off, ctl.phase])
	# leaving the result before its show is over (T, Esc): the round was played, so it is still recorded
	ctl.ranking_enabled = true
	ctl.ranking.clear()
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, 5.0)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	var early: bool = ctl.phase == "RESULT" and not ctl.result_show.settled() and ctl.ranking.entries.is_empty()
	game._unhandled_input(_key(KEY_T))
	var by_t: bool = ctl.phase == "TUTORIAL" and ctl.ranking.entries.size() == 1 and int(ctl.ranking.entries[0].score) == 1100
	game._unhandled_input(_key(KEY_ESCAPE))
	game._unhandled_input(_key(KEY_3))
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_play_capsule(ctl, "left")
	_gm_step(ctl, 5.0)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(early and by_t and not ctl.active() and ctl.ranking.entries.size() == 2 and int(ctl.ranking.entries[1].score) == 200,
		"game mode ranking: T or Esc in the middle of the result's show still records the round that was played (once)",
		"%s %s %s" % [early, by_t, str(ctl.ranking.entries)])
	_gm_free(game, rs)
	for name in ["game.tsv", "logic.tsv", "bad.tsv", "junk.tsv", "later.tsv"]:
		_rank_file(name)  # (the tests' own files are not left behind)

## Portrait (#157): the 9:16 screen, its regions, the tall field, and what must not have
## changed with it (the Dials' sides, the robot's coordinates).
func _test_portrait_layout(rs: Node) -> void:
	var L := GameModeLayout
	var screen := Rect2(Vector2.ZERO, L.SCREEN)
	_ok(int(ProjectSettings.get_setting("display/window/size/viewport_width")) == 720
		and int(ProjectSettings.get_setting("display/window/size/viewport_height")) == 1280
		and str(ProjectSettings.get_setting("display/window/stretch/mode")) == "canvas_items"
		and str(ProjectSettings.get_setting("display/window/stretch/aspect")) == "keep"
		and int(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter")) == 0
		and L.SCREEN == Vector2(720, 1280) and Vector2(L.PIXEL_SIZE) * L.DOT_PX == L.SCREEN
		and is_equal_approx(1080.0 / L.SCREEN.x * L.DOT_PX, 3.0) and is_equal_approx(2160.0 / L.SCREEN.x * L.DOT_PX, 6.0)
		and is_equal_approx(L.SCREEN.x / L.SCREEN.y, 9.0 / 16.0),
		"portrait: the design screen is 720 x 1280 (9:16), stretched whole with its aspect kept (bars, never a cut or a squeeze); one dot is 3 px at 1080 x 1920 and 6 px at 2160 x 3840, nearest neighbour")
	# the regions, top to bottom, none over another, all inside the screen
	var rail := Rect2(L.FIELD_LEFT, L.UFO_Y - 52.0, L.FIELD_RIGHT - L.FIELD_LEFT, 104.0)
	var field := Rect2(L.FIELD_LEFT, L.FIELD_TOP, L.FIELD_RIGHT - L.FIELD_LEFT, L.FIELD_FLOOR - L.FIELD_TOP)
	var regions := [L.SCORE_RECT, L.TIME_RECT, L.MESSAGE_RECT, L.COMBO_RECT, L.SCOPE_RECT, rail]
	var clear := true
	for i in regions.size():
		clear = clear and screen.encloses(regions[i])
		for j in range(i + 1, regions.size()):
			clear = clear and not (regions[i] as Rect2).intersects(regions[j])
	_ok(clear and L.SCORE_RECT.end.y <= L.STATUS_Y and L.MESSAGE_RECT.end.y <= rail.position.y and rail.end.y <= L.FIELD_TOP + 2.0
		and L.FIELD_FLOOR < L.DIALS_Y and screen.encloses(field) and field.size.y > field.size.x * 1.05
		and L.SCORE_RECT.size.x >= 320.0 and L.TIME_RECT.size.x >= 320.0 and L.SCORE_RECT.end.x < L.CX and L.TIME_RECT.position.x > L.CX,
		"portrait layout: score and clock on top (half the width each), the hand, the combo and the arm camera under them, the UFO's rail, the tall field, the Dials at the foot; nothing over anything else")
	_ok(L.fit_scale("12345", 316.0, 8.0) == 8.0 and L.fit_scale("123456789", 316.0, 8.0) == 4.0 and L.fit_scale("1", 10.0, 8.0) == 2.0
		and PixelText.width("123456789", L.fit_scale("123456789", 316.0, 8.0)) <= 316.0
		and PixelText.width("2:30", 8.0) <= L.TIME_RECT.size.x - 28.0,
		"portrait layout: the score's digits are as big as its panel allows (8 dots for six digits) and shrink, in whole even dots, before they would leave it")
	# the tall field: everything inside it, and room for a capsule everywhere
	var F := PinballField
	var cap := F.CAPSULE_R * 2.0
	var inside := true
	var pins: Array[Vector2] = []
	for row in F.PIN_ROWS:
		for i in int(row[2]):
			pins.append(Vector2(float(row[1]) + F.PIN_STEP * i, float(row[0])))
	var things: Array = pins.duplicate()
	things.append_array(F.BUMPERS)
	things.append_array(F.SPINNERS)
	things.append_array(F.POPS)
	things.append_array(F.WARPS)
	things.append_array(F.GEMS)
	things.append(F.STAR)
	for p in things:
		inside = inside and p.x > F.LEFT and p.x < F.RIGHT and p.y > F.SPAWN_Y and p.y < F.FLOOR_Y
	var gaps := true
	for i in pins.size():
		gaps = gaps and pins[i].x - F.PIN_R - F.LEFT >= cap and F.RIGHT - pins[i].x - F.PIN_R >= cap  # past the walls
		for j in range(i + 1, pins.size()):
			gaps = gaps and pins[i].distance_to(pins[j]) - 2.0 * F.PIN_R >= cap + 4.0  # between any two pins
	for b in F.BUMPERS:
		for p in pins:
			gaps = gaps and (b as Vector2).distance_to(p) - F.BUMPER_R - F.PIN_R >= cap
	var centre_w: float = F.POSTS_X[1] - F.POSTS_X[0]
	var side_w: float = F.POSTS_X[0] - F.LEFT - F.SLOPE_W
	_ok(inside and gaps and F.PIN_ROWS.size() >= 4 and F.SWITCH_X.size() == 3 and F.BUMPERS.size() == 3 and F.SPINNERS.size() == 2
		and F.POPS.size() == 2 and F.TARGETS.size() == 4 and F.WARPS.size() == 2 and F.GEMS.size() == 4
		and centre_w >= cap * 2.0 and side_w >= cap * 3.0 and centre_w < side_w
		and is_equal_approx(F.POSTS_X[0] + F.POSTS_X[1], F.LEFT + F.RIGHT) and is_equal_approx(F.SWITCH_X[1], F.CENTRE_X)
		and F.goal_at(F.LEFT + 40.0) == "left" and F.goal_at(F.CENTRE_X) == "center" and F.goal_at(F.RIGHT - 40.0) == "right"
		and F.ALIEN_X0 > F.LEFT and F.ALIEN_X1 < F.RIGHT and F.SLOPE_BOTTOM_Y < F.FLOOR_Y and F.SPAWN_Y < F.SWITCH_Y,
		"portrait field: every kind of thing is there (pins, 3 switches, 3 bumpers, 2 spinners, the star, 4 gems, the alien, 2 warp holes, 2 slingshots, 3 goals), inside the walls, with room for a capsule between any two pins and into every goal",
		"%s %s %.0f %.0f" % [inside, gaps, centre_w, side_w])
	# in the game: the picture is the layout's, the HUD stays readable in a shake, Dial 1 is left
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hud_inside := true
	for l in [ctl.hud._centre, ctl.hud._message, ctl.hud._hint, ctl.hud._problem, ctl.hud._lane["left"], ctl.hud._start]:
		hud_inside = hud_inside and screen.encloses(Rect2((l as Label).position, (l as Label).size))
	for l in [ctl.result_screen._sub, ctl.result_screen._stats, ctl.result_screen._keys, ctl.result_screen._faults,
			ctl.ranking_hud._place, ctl.ranking_hud._note, ctl.ranking_hud._keys, ctl.tutorial_hud._title, ctl.tutorial_hud._guide]:
		hud_inside = hud_inside and screen.encloses(Rect2((l as Label).position, (l as Label).size))
	for line in GestureTutorialHud.LINES.values():
		for r in line:
			hud_inside = hud_inside and screen.encloses(r)
	game.shake.enabled = true
	for i in 30:  # (the shake's noise has a random seed: now and then one step of it is next to nothing)
		game.shake.trauma = 1.0
		game.shake.step(1.0 / 60.0)
		if game.shake.offset.length() > 1.0:
			break
	ctl._process(1.0 / 60.0)
	var moved: Vector2 = ctl.layer.offset
	var held: Vector2 = ctl.hud.position + moved  # where the HUD really is on the screen
	_ok(hud_inside and moved.length() > 0.5 and held.length() <= moved.length() * 0.3 and held.length() <= 4.0
		and screen.encloses(Rect2(L.SCORE_RECT.position + held, L.SCORE_RECT.size)) and screen.encloses(Rect2(L.TIME_RECT.position + held, L.TIME_RECT.size))
		and screen.encloses(GestureTutorialHud.PANEL) and screen.encloses(GameModeHud.START_RECT)
		and GameModeResultScreen.CENTRE.y > L.FIELD_TOP and GameModeResultScreen.CENTRE.y < L.FIELD_FLOOR
		and GameModeResultScreen.CONFETTI_Y < L.SCREEN.y and GameModeRankingHud.TITLE_Y > L.MESSAGE_RECT.end.y,
		"portrait game: every line of the HUD, the practice, the result and the ranking is inside the screen; in the biggest shake the score and the clock move only a quarter as far and never leave it",
		"%s %s %s" % [hud_inside, str(moved), str(held)])
	game.shake.trauma = 0.0
	_ok(ctl.lanes["left"].device == GameModeDevices.DIAL_1 and ctl.lanes.size() == 1 and ctl.hud._lane.keys() == ["left"]
		and ctl.fx.port("left").x < L.CX and ctl.fx.dial_edge("left").x < ctl.fx.port("left").x
		and ctl.backdrop.ports == {"left": ctl.fx.port("left")}
		and ctl.ufo.x_min < ctl.ufo.x_max and is_equal_approx(ctl.ufo.y, L.UFO_Y) and ctl.ufo.y < F.TOP,
		"portrait game: Dial 1 is the left of the screen and the only portal (port, light and device agree); the UFO runs above the field")
	_gm_free(game, rs)
	# the staff's screens fit the narrow screen
	game = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var dbg: float = game.debug_ui._panel.get_combined_minimum_size().x
	game.show_title()
	game.open_settings()
	var set_w := 0.0
	for tab in 3:
		game.settings.show_tab(tab)
		for c in game.settings.find_children("*", "PanelContainer", true, false):
			if c.get_parent() is CenterContainer:
				set_w = maxf(set_w, (c as Control).get_combined_minimum_size().x)
	var cards: Array = game.title._cards
	var stacked := cards.size() >= 2
	for c in cards:
		stacked = stacked and (c as Control).get_parent() is VBoxContainer and (c as Control).get_combined_minimum_size().x <= L.SCREEN.x - 40.0
	var panel_w: float = game.debug_ui.PANEL_W
	_ok(dbg <= panel_w and set_w > 0.0 and set_w <= L.SCREEN.x and stacked and panel_w <= L.SCREEN.x * 0.5,
		"portrait staff screens: the debug panel keeps its 360 px (a wide row scrolls, it no longer runs off the screen), the settings panel fits the 720 px screen, the title's mode cards stand one under another",
		"%.0f %.0f %s" % [dbg, set_w, stacked])
	# full screen: the config decides, the command line and F11 win
	var at_start: int = game.window_mode_applied  # (decided once while the game came up)
	var full_cfg: bool = game.fullscreen_wanted()
	game.fullscreen_override = "on"
	var on: bool = game.fullscreen_wanted()
	game.fullscreen_override = "off"
	var off: bool = not game.fullscreen_wanted()
	game.fullscreen_override = ""
	game.apply_window_mode()  # (headless: nothing to do, and nothing breaks)
	_ok(full_cfg == bool(GameConfig.value("render.fullscreen", false)) and on and off and at_start >= 1 and game.window_mode_applied == at_start + 1,
		"portrait display: full screen follows render.fullscreen, already at start (no argument needed); --fullscreen / --windowed and F11 override it",
		"%d" % at_start)
	# the screen's shape is the picture's only: the robot's own coordinates mean what they did
	var ax0: Vector3 = RobotState.anchor_for_xy(10.0, 10.0)
	var ax1: Vector3 = RobotState.anchor_for_xy(60.0, 10.0)
	var ay1: Vector3 = RobotState.anchor_for_xy(10.0, 60.0)
	_ok(RobotState.rope_length_for_z(100.0) > RobotState.rope_length_for_z(0.0) and ax1.x > ax0.x and is_equal_approx(ax1.z, ax0.z)
		and ay1.z < ax0.z and is_equal_approx(ay1.x, ax0.x) and is_equal_approx(ax0.y, 0.0),
		"portrait and the robot: the robot's coordinates are untouched: the arm going up still lengthens the rope (the inverse mapping: the UFO goes down), +X is still right and +Y still away on the picture",
		"%s %s %s rope %.1f %.1f" % [str(ax0), str(ax1), str(ay1), RobotState.rope_length_for_z(0.0), RobotState.rope_length_for_z(100.0)])
	remove_child(game)
	game.free()
	rs.clear_samples()
