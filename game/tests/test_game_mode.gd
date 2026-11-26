extends "res://tests/test_base.gd"
## The score game's rules and devices: score, power-ups, the Dial lanes, faults, the clock, the field's physics.

## #188: independent timers, field pickups, triple virtual balls and scoring multiplier.
func _test_game_mode_powerups() -> void:
	var p := PowerUpManager.new()
	p.configure({"duration_s": {"speed": 0.5, "double": 1.0}})
	_ok(p.collect("speed") and p.active("speed"), "power-up speed activates")
	_ok(p.collect("double") and p.active("double"), "power-up x2 activates")
	_ok(p.collect("multiball") and not p.active("multiball"), "multi-ball lifetime belongs to physical ball")
	var ended := p.advance(0.6)
	_ok("speed" in ended and not p.active("speed") and p.active("double"), "power-ups expire independently")
	p.collect("double")
	_ok(p.seconds("double") == 1, "re-pickup refreshes instead of stacking")
	p.reset()
	_ok(not p.active("speed") and not p.active("double"), "power-up reset clears all timers")
	var sc := ScoreManager.new()
	sc.power_multiplier = 2.0
	var r := sc.hit("a", "bumper", "bumper_0", 0.0)
	_ok(int(r.points) == 200 and sc.score == 200, "x2 multiplies a base hit")
	sc.reset()
	_ok(sc.power_multiplier == 1.0, "x2 resets with the round")
	var field := PinballField.new()
	add_child(field)
	field.configure_powerups({"first_spawn_s": 0.1, "spawn_interval_s": 0.1, "weights": {"speed": 1, "multiball": 0, "double": 0}})
	field.set_powerups_enabled(true)
	field.advance(0.2)
	_ok(field.powerup_kind == "speed", "field presents one collectible at a time")
	var seen: Array[String] = []
	field.powerup_collected.connect(func(_id: String, kind: String, _pos: Vector2): seen.append(kind))
	field.spawn_capsule("test", 300.0, Color.CYAN)
	field._on_area(field._capsules["test"].body, field._powerup_area)
	field._on_area(field._capsules["test"].body, field._powerup_area)
	_ok(seen.size() == 1 and seen[0] == "speed" and field.powerup_kind == "", "one item can be collected only once")
	var made := field.split_capsule("test", ["test-mb1", "test-mb2"])
	_ok(field.capsule_count() == 3 and made == ["test-mb1", "test-mb2"], "one virtual capsule can split into three")
	_ok(field.split_capsule("gone", ["x1", "x2"]).is_empty() and field.split_capsule("test", ["test-mb1"]).is_empty()
		and field.capsule_count() == 3, "a split reports only the balls it really made")
	# which item comes: by weight, and not at all when its chance or every weight is 0
	field.configure_powerups({"weights": {"speed": 3, "multiball": 0, "double": 1}})
	var picked := {"speed": 0, "multiball": 0, "double": 0}
	for i in 800:
		picked[field.pick_powerup()] += 1
	_ok(picked.multiball == 0 and picked.speed > 520 and picked.speed < 680 and picked.double > 120,
		"the items come by their weights (3 : 0 : 1)", str(picked))
	field.configure_powerups({"weights": {"speed": 0, "multiball": 0, "double": 0}})
	_ok(field.pick_powerup() == "", "every weight 0: no item")
	field.clear()
	field.configure_powerups({"first_spawn_s": 0.1, "spawn_interval_s": 2.0, "spawn_chance": 0.0, "weights": {"speed": 1}})
	field.set_powerups_enabled(true)
	field.advance(0.2)
	field.advance(2.1)
	_ok(field.powerup_kind == "", "spawn_chance 0: the time comes and nothing appears")
	field.configure_powerups({"first_spawn_s": 0.1, "spawn_chance": 1.0})
	field.advance(0.2)
	_ok(field.powerup_kind != "" and field.powerup_pos in PinballField.POWERUP_SPOTS, "spawn_chance 1: an item at one of the spots")
	field.clear()
	_ok(field.capsule_count() == 0 and field.powerup_kind == "", "field clears extra balls and pickups")
	field.queue_free()
	var fx := GameModeVFX.new()
	add_child(fx)
	fx.powerup_notice("multiball")
	fx.powerup_notice("double")
	_ok(fx._power_notice.text == "MULTI BALL!" and fx._power_queue.size() == 1, "pickup notices queue rather than overwrite")
	fx.advance(1.4)
	_ok(fx._power_notice.text == "DOUBLE SCORE!", "next pickup notice appears")
	fx.set_power_portal("left", true)
	_ok(fx.power_portals.left and fx.power_portals.keys() == ["left"], "multi-ball portal effect is on the portal's side (the left, the only one)")
	fx.reset()
	_ok(not fx.power_portals.left, "portal effect clears on reset")
	fx.queue_free()

func _test_game_mode_score() -> void:
	var s := ScoreManager.new()
	var a := s.hit("c1", "pin", "pin_3", 0.0)
	var again := s.hit("c1", "pin", "pin_3", 0.1)  # resting on the pin
	var later := s.hit("c1", "pin", "pin_3", 0.6)
	var other := s.hit("c2", "pin", "pin_3", 0.6)  # another capsule on the same pin
	_ok(a.points == 10 and again.points == 0 and later.points == 10 and other.points == 10 and s.score == 30,
		"game mode score: a pin is 10, the same capsule on the same target only once per cooldown", str(s.score))
	s.reset()
	var b1 := s.hit("c1", "bumper", "bumper_0", 1.0)
	var b2 := s.hit("c1", "bumper", "bumper_1", 1.5)
	var p := s.hit("c1", "pin", "pin_1", 1.6)  # multiplied, but a pin never builds the chain
	var b3 := s.hit("c1", "spinner", "spinner_0", 2.0)
	var b4 := s.hit("c1", "bumper", "bumper_2", 2.5)
	var b6 := [s.hit("c1", "bumper", "bumper_0", 3.0), s.hit("c1", "bumper", "bumper_1", 3.5)]
	var cold := s.hit("c1", "bumper", "bumper_0", 9.0)  # the window ran out
	_ok(b1.points == 100 and b2.points == 150 and p.points == 15 and b3.points == 300 and b4.points == 200
		and b6[1].points == 300 and s.best_chain == 6 and cold.points == 100 and s.chain_now(9.0) == 1,
		"game mode score: combo x1.5 / x2 / x3 by chain, lost after the window",
		"%s %s %s %s %s %s %s" % [b1.points, b2.points, p.points, b3.points, b4.points, b6[1].points, cold.points])
	s.reset()
	var s0 := s.hit("c1", "switch", "switch_0", 0.0)
	var s0b := s.hit("c2", "switch", "switch_0", 5.0)
	var s1 := s.hit("c2", "switch", "switch_1", 20.0)
	var lit := s.switch_lit.duplicate()
	var s2 := s.hit("c3", "switch", "switch_2", 40.0)
	_ok(s0.points == 50 and s0b.points == 50 and lit == [true, true, false] and s2.points == 1550 and s2.bonus == "switch_bonus"
		and s.switch_lit == [false, false, false] and s.jackpot_armed(41.0) and not s.jackpot_armed(61.0),
		"game mode score: the three switches are shared by the capsules; all lit = 1500 and the jackpot is armed", "%s %s" % [lit, s2])
	var before := s.score
	var j := s.goal("c3", "center", 45.0)
	var j2 := s.goal("c3", "center", 45.1)  # the same capsule reported again
	var plain := s.goal("c4", "center", 46.0)  # the jackpot is spent
	var left := s.goal("c5", "left", 46.0)
	var none := s.goal("c6", "timeout", 46.0)
	_ok(j.points == 3000 and j.kind == "jackpot" and j2.points == 0 and plain.points == 1000 and left.points == 100
		and none.points == 0 and s.score == before + 4100 and s.jackpots == 1 and s.capsule_finished("c3"),
		"game mode score: goals 100 / 1000, the jackpot 3000 once, a capsule's goal never twice, no goal on a timeout",
		"%s %s %s %s" % [j.points, j2.points, plain.points, left.points])
	var t := ScoreManager.new()
	t.configure({"table": {"pin": 20, "nonsense": 9}, "cooldown_s": 1.0})
	_ok(t.table.pin == 20 and not t.table.has("nonsense") and t.table.bumper == 100 and t.cooldown_s == 1.0,
		"game mode score: the table comes from the config (known kinds only)")

func _test_game_mode_ufo_and_mock_dials() -> void:
	var u := UfoDropController.new()
	u.configure(PinballField.LEFT, PinballField.RIGHT, {"min": 0.1, "max": 0.9, "one_way_s": 6.0})
	u.u = 0.0
	var x0 := u.x()
	var lo := x0
	var hi := x0
	for i in 360:
		u.advance(1.0 / 60.0)
	var x6 := u.x()
	for i in 720:
		u.advance(1.0 / 60.0)
		lo = minf(lo, u.x())
		hi = maxf(hi, u.x())
	var w := PinballField.RIGHT - PinballField.LEFT
	_ok(is_equal_approx(x0, PinballField.LEFT + 0.1 * w) and absf(x6 - (PinballField.LEFT + 0.9 * w)) < 1.0
		and lo >= x0 - 0.01 and hi <= PinballField.LEFT + 0.9 * w + 0.01,
		"game mode UFO: 10 % .. 90 % of the field, 6 s one way, turning at the ends", "%.1f %.1f %.1f %.1f" % [x0, x6, lo, hi])
	var hub := MockDialHub.new()
	var events: Array = []
	var answers := {}
	hub.device_event.connect(func(ev): events.append(ev))
	hub.command_done.connect(func(rid, _ok2, result, _d): answers[rid] = result)
	var early := hub.command(GM_L, "ARM_RECEIVER")  # not in GAME mode yet
	var no_ball := hub.mock_ball(GM_L)
	var m := hub.command(GM_L, "SET_MODE", {"mode": "GAME"})
	var arm := hub.command(GM_L, "ARM_RECEIVER")
	var rel_early := hub.command(GM_L, "RELEASE_BALL")  # nothing in it
	hub.tick(0.1)
	var ball := hub.mock_ball(GM_L)
	var ball2 := hub.mock_ball(GM_L)
	var rel := hub.command(GM_L, "RELEASE_BALL")
	var rel2 := hub.command(GM_L, "RELEASE_BALL")
	hub.tick(0.1)
	var started := events.filter(func(e): return e.name == "RELEASE_STARTED").size()
	hub.tick(MockDialHub.SERVO_HOLD_S)
	var mid: String = hub.dials[GM_L].state
	hub.tick(MockDialHub.SERVO_SETTLE_S)
	var done := events.filter(func(e): return e.name == "RELEASE_DONE")
	_ok(answers[early] == "REJECTED_STATE" and not no_ball and answers[m] == "ACCEPTED" and answers[arm] == "ACCEPTED"
		and answers[rel_early] == "REJECTED_STATE" and ball and not ball2 and answers[rel] == "ACCEPTED" and answers[rel2] == "BUSY"
		and started == 1 and mid == "RETURNING" and done.size() == 1 and hub.dials[GM_L].state == "COMPLETE"
		and hub.dials[GM_R].state == "DISABLED" and hub.count(GM_L, "RELEASE_BALL") == 1,
		"game mode mock Dial: as UFO-DeviceHub's (GAME, armed, one capsule, one release, DONE after the servo times)",
		"%s %s %s" % [answers, mid, done])
	hub.free()

## An actual round with a mock Dial: three virtual balls must never cause three
## RELEASE_BALL commands. Pickup SFX/LED/lighting are observable in the hub trace.
func _test_game_mode_powerup_integration(rs: Node) -> void:
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var lane: GameModeController.Lane = ctl.lanes["left"]
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(lane.capsule.capsule_id)
	var pos := Vector2(350, 600)
	var hand_top: float = game.gesture.joystick.max_speed
	_ok(game.hand_boost_scale() == 1.0 and game.powerup_xy_speed(true) == game.jog_speed_real_mm
		and game.powerup_xy_speed(false) == game.jog_speed_mm,
		"no power: the hand and the keys are as fast as outside the game")
	var told: Array[float] = []
	game.jog_boost_sender = func(s: float) -> void: told.append(s)
	ctl._on_powerup_collected(id, "speed", pos)
	game._sync_jog_boost(true)
	game._sync_jog_boost(true)
	_ok(ctl.powerups.active("speed") and is_equal_approx(game.powerup_xy_speed(true), 100.0)
		and is_equal_approx(game.hand_boost_scale() * hand_top, 100.0) and ctl.sounds.log.has("power_speed"),
		"pickup speed: the hand and the keys go up to 100 mm/s in XY, audible",
		"keys=%s hand=%s" % [str(game.powerup_xy_speed(true)), str(game.hand_boost_scale() * hand_top)])
	_ok(told.size() == 1 and is_equal_approx(told[0], 10.0), "speed: the backend is told once, for the power's seconds", str(told))
	_gm_step(ctl, 3.0)
	game._sync_jog_boost(true)
	ctl._on_powerup_collected(id, "speed", pos)  # taken again: the time starts again, and the backend hears it
	game._sync_jog_boost(true)
	_ok(told.size() == 2 and is_equal_approx(told[1], 10.0), "speed taken again: the backend's time is renewed", str(told))
	ctl._on_powerup_collected(id, "double", pos)
	ctl.field.target_hit.emit(id, "bumper", "bumper_0", pos)
	var light_changed := hub.executed.any(func(e): return e[0] == GameModeDevices.ILLUMINATION and e[1] == "SET_LIGHT_MODE" and e[2].get("mode", "") == "CUSTOM")
	_ok(ctl.score.score == 200 and ctl.powerups.active("double") and light_changed
		and ctl.sounds.log.has("power_double"), "pickup x2: doubled scoring, gold illumination and cue")
	ctl._on_powerup_collected(id, "multiball", pos)
	ctl.tick(1.0 / 60.0)
	var children := [id + "-mb1", id + "-mb2"]
	var multi_led := hub.executed.any(func(e): return e[0] == GM_L and e[1] == "SET_DIAL_EFFECT" and e[2].get("target", "") == "FRONT" and e[2].get("effect", "") == "COMET")
	_ok(ctl.field.capsule_count() == 3 and (ctl._multi_balls[id] as Array).size() == 3
		and ctl.fx.power_portals.left and multi_led and _gm_sent(hub, GM_R) == 0
		and ctl.sounds.log.has("power_multi"),
		"pickup multi: three physics balls, same-side portal LED, distinct audio",
		"balls=%d left=%s LED=%s audio=%s" % [ctl.field.capsule_count(), str(ctl.fx.power_portals.left),
			str(multi_led), str(ctl.sounds.log.has("power_multi"))])
	ctl.field.capsule_exited.emit(children[0], "left", pos)
	ctl.field.capsule_exited.emit(id, "left", pos)
	_ok(lane.state == "SIMULATING" and hub.count(GM_L, "RELEASE_BALL") == 0
		and (ctl._multi_balls[id] as Array) == [children[1]],
		"multiball: no physical release until last virtual ball")
	ctl.field.capsule_exited.emit(children[1], "left", pos)
	_ok(lane.state == "RETURNING" and not ctl.fx.power_portals.left and ctl._multi_balls.is_empty()
		and ctl._virtual_root.is_empty(),
		"multiball: last ball starts one return and restores portal")
	_gm_step(ctl, 4.0)
	_ok(hub.count(GM_L, "RELEASE_BALL") == 1 and lane.released == 1
		and lane.state == "READY", "multiball: original Dial releases exactly once")
	ctl._halt("test stop")
	game._sync_jog_boost(true)
	_ok(not ctl.powerups.active("speed") and game.powerup_xy_speed(true) == game.jog_speed_real_mm
		and game.hand_boost_scale() == 1.0 and told[-1] == 0.0,
		"speed upgrade cannot persist when the round stops (and the backend is told to end it)", str(told))
	_gm_free(game, rs)

func _test_game_mode_round(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	var robot_before: Vector3 = game.mock.target
	game.show_title()
	game._unhandled_input(_key(KEY_RIGHT))
	game._unhandled_input(_key(KEY_RIGHT))
	var third: bool = game.title.selected_mode() == "score" and game.title._cards.size() == 2
	game._unhandled_input(_key(KEY_ENTER))
	_ok(third and not game.title_active() and ctl.active() and ctl.phase == "IDLE" and ctl.layer.visible
		and ctl.devices == ctl.mock_hub and game.debug_ui.layer > GameModeController.LAYER,
		"game mode: the title's second card (the game mode) opens it (waiting for Enter), on the Dials simulated in the game")
	_ok(ctl.guide_hidden(), "game mode #258: no hand window on the score game's title (its corner would cover the cards)")
	game._unhandled_input(_key(KEY_Z))  # no capsule is taken before the start
	var hub := ctl.mock_hub
	game._unhandled_input(_key(KEY_ENTER))
	var counting: bool = ctl.phase == "COUNTDOWN" and hub.dials[GM_L].state != "ARMED"
	_gm_step(ctl, ctl.countdown_s + 0.2)
	var l: GameModeController.Lane = ctl.lanes["left"]
	_ok(counting and ctl.phase == "PLAYING" and l.state == "READY" and hub.dials[GM_L].state == "ARMED"
		and hub.dials[GM_L].op_mode == "GAME" and absf(ctl.time_left - (ctl.duration_s - 0.2)) < 0.05
		and ctl.duration_s == 150.0 and hub.count(GameModeDevices.ILLUMINATION, "SET_LIGHT_MODE") == 2,
		"game mode: Enter, 3 s countdown, then 150 s; the Dial in GAME mode and armed only at GO",
		"%s %s %.2f" % [ctl.phase, l.state, ctl.time_left])
	_ok(GameModeController.SIDES == ["left"] and ctl.lanes.keys() == ["left"] and l.device == GM_L and GameModeLayout.PORTS.keys() == ["left"]
		and ctl.fx.colors.keys() == ["left"] and ctl.backdrop.ports.keys() == ["left"] and _gm_sent(hub, GM_R) == 0
		and hub.dials[GM_R].state != "ARMED" and hub.dials[GM_R].op_mode == "STANDBY",
		"game mode (#200): the portal is on the left only: one lane (Dial 1), one port; nothing is sent to Dial 2",
		"%s %d %s" % [ctl.lanes.keys(), _gm_sent(hub, GM_R), hub.dials[GM_R].state])
	# Dial 1 (left): the drop point is where the UFO is when the switch closes
	var x_at_switch := ctl.ufo.x()
	game._unhandled_input(_key(KEY_Z))
	var absorbing: bool = l.state == "ABSORBING" and ctl.capsules.active.size() == 1
	var c: Dictionary = l.capsule
	var left_fx: bool = ctl.fx.played.has("capsule_portal_open:left") and ctl.fx.played.has("capsule_collect:left") \
		and ctl.fx.streaming("left", true) and ctl.fx.collects().size() == 1
	var sheets_in: bool = ctl.fx.port_sheet_running("left") \
		and ["capsule_portal_open", "capsule_absorb"].all(func(id): return VFXManager.spawned_log.has(id))
	# #258: the collection show: up from the port, big in the middle with カプセル回収！, up
	# into UFOくん (which waits meanwhile), its light
	var parts := []
	var mid_big := false
	for i in 40:
		_gm_step(ctl, ctl.absorb_s / 40.0)
		if ctl.fx.collects().is_empty():
			break
		var at: Dictionary = ctl.fx.collect_at(ctl.fx.collects()[0])
		if parts.is_empty() or parts[-1] != at.part:
			parts.append(at.part)
		mid_big = mid_big or (at.part == "show" and at.scale > 3.0 and at.text > 0.9 and at.pos == GameModeVFX.COLLECT_MID)
	var show_ok: bool = parts == ["rise", "show", "up", "light"] and mid_big and is_equal_approx(ctl.ufo.x(), x_at_switch)
	_ok(show_ok and is_equal_approx(ctl.guide_alpha(), GameModeLayout.GUIDE_FAINT) and is_equal_approx(ctl.guide_scale(), GameModeLayout.GUIDE_SMALL),
		"game mode #258: a capsule taken in rises from the port, is shown big in the middle (カプセル回収！), goes up into UFOくん and its light; UFOくん waits; the hand window steps aside (small in the corner, faint)",
		"%s big=%s ufo=%.1f/%.1f guide=%.2f" % [parts, mid_big, ctl.ufo.x(), x_at_switch, ctl.guide_alpha()])
	_gm_step(ctl, 0.05)
	var dropping: bool = l.state == "DROPPING" and not ctl.field.has_capsule(c.capsule_id)
	_gm_step(ctl, ctl.drop_s + 0.02)
	var sheets_drop: bool = not ctl.fx.port_sheet_running("left") and VFXManager.spawned_log.has("capsule_materialize") \
		and VFXManager.spawned_log.has("capsule_portal_close")
	var baked := true
	for id in GameModeVFX.MOMENTS:
		baked = baked and VFXManager.has_fx(id) and str(VFXManager.catalog[id].opts.palette[0]) == "#101014" \
			and GameModeVFX.SHEETS[id][0] == id
	_ok(sheets_in and sheets_drop and baked,
		"game mode vfx: the six capsule sheets (baked grey, tinted per Dial) play; the port's loop runs only while that port is open",
		"%s %s %s" % [sheets_in, sheets_drop, baked])
	var cap_x := ctl.field.capsule_position(c.capsule_id).x
	_ok(absorbing and left_fx and dropping and l.state == "SIMULATING" and is_equal_approx(c.drop_x, x_at_switch)
		and is_equal_approx(cap_x, x_at_switch) and absf(ctl.ufo.x() - x_at_switch) < 8.0
		and c.source_dial == GM_L and c.cycle == 1 and c.session == hub.session and is_equal_approx(ctl.absorb_s + ctl.drop_s, 2.2),
		"game mode: BALL_RECEIVED fixes the drop X under UFOくん, which waits there (#258); port -> UFO -> drop in 2.2 s; the capsule knows its Dial, cycle, session",
		"%s x=%.1f/%.1f ufo=%.1f %s" % [l.state, cap_x, x_at_switch, ctl.ufo.x(), c])
	# #200: there is no right portal: its old key does nothing, and a capsule a Dial 2 still
	# plugged in reports is not the game's (nothing appears, nothing is released there)
	game._unhandled_input(_key(KEY_Z))  # the Dial holds one: nothing more
	game._unhandled_input(_key(KEY_M))
	hub.dials[GM_R].state = "ARMED"
	hub.mock_ball(GM_R)
	_gm_step(ctl, 0.2)
	var one: bool = ctl.capsules.active.size() == 1 and ctl.field.capsule_count() == 1 and _gm_sent(hub, GM_R) == 0 \
		and not ctl.fx.played.has("capsule_portal_open:right") \
		and ctl.trace.rows.any(func(row): return row.event == "event_ignored" and row.result == "not_a_game_dial" and row.source_dial == GM_R)
	ctl.field.target_hit.emit(c.capsule_id, "bumper", "bumper_0", Vector2(395, 430))
	ctl.field.target_hit.emit(c.capsule_id, "pin", "pin_2", Vector2(395, 230))
	ctl.field.target_hit.emit("nobody", "star", "star", Vector2(640, 505))  # not a capsule of this round
	var scored: bool = ctl.score.score == 110 and c.score == 110
	# the capsule leaves through the centre
	ctl.field.capsule_exited.emit(c.capsule_id, "center", Vector2(640, 660))
	ctl.field.capsule_exited.emit(c.capsule_id, "center", Vector2(640, 660))  # reported twice
	var returning: bool = l.state == "RETURNING" and ctl.score.score == 1110 \
		and not ctl.field.has_capsule(c.capsule_id) and hub.count(GM_L, "RELEASE_BALL") == 0 and ctl.fx.streaming("left", false)
	_ok(one and scored and returning,
		"game mode: one capsule at a time (the one Dial's); Dial 2 and its old key are not part of the game; a goal counts once, RELEASE_BALL only at the sync point",
		"%s %s %s %s %d" % [one, scored, returning, l.state, ctl.score.score])
	_gm_step(ctl, ctl.release_sync_s + 0.05)
	var releasing: bool = l.state == "RELEASING" and hub.dials[GM_L].state == "RELEASING" and ctl.fx.played.has("capsule_release_burst:left") \
		and VFXManager.spawned_log.has("capsule_release_burst") and ctl.fx.port_sheet_running("left")
	_gm_step(ctl, 0.3)
	_gm_step(ctl, MockDialHub.SERVO_HOLD_S + MockDialHub.SERVO_SETTLE_S)
	var back: bool = l.state == "READY" and l.released == 1 and hub.dials[GM_L].state == "ARMED" and hub.dials[GM_L].cycle == 2 \
		and hub.count(GM_L, "RELEASE_BALL") == 1
	_ok(is_equal_approx(ctl.guide_scale(), 1.0) and is_equal_approx(ctl.guide_alpha(), 1.0) and not ctl.guide_hidden(),
		"game mode #258: the hand window is back to full size once the capsule has left the field")
	game._unhandled_input(_key(KEY_Z))  # the next capsule comes in through the same port
	var again: bool = l.state == "ABSORBING" and ctl.fx.streaming("left", true)
	_gm_step(ctl, 3.0)
	_ok(releasing and back and again and l.capsule.cycle == 2 and _gm_sent(hub, GM_R) == 0
		and ctl.capsules.finished.size() == 1 and ctl.score.score == 1110,
		"game mode: the capsule leaves by the Dial it came in by (RELEASE_BALL once, DONE, status, armed again); then the next one comes in",
		"%s %s %s %s" % [releasing, back, again, l.state])
	# the lights are decoration: refused or not, the game goes on; the crane is never touched
	var names: Array = ctl.trace.rows.map(func(row): return row.event)
	var row: Dictionary = ctl.trace.named("score")[0]
	_ok(game.mock.target == robot_before and names.has("capsule_created") and names.has("led") and names.has("release")
		and row.source_dial == GM_L and row.capsule_id == c.capsule_id and row.score_delta == 100 and row.session_id == hub.session
		and GameModeTrace.FIELDS.all(func(k): return row.has(k)),
		"game mode: the crane is not touched; the trace has the session, Dial, cycle, capsule, score and LED rows", str(row))
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(game.title_active() and not ctl.active() and not ctl.layer.visible and hub.count(GM_L, "STOP_ALL") == 1
		and ctl.field.capsule_count() == 0, "game mode: Esc goes back to the title; a running round is stopped (STOP_ALL)")
	game._unhandled_input(_key(KEY_G))
	_ok(not ctl.active() and not game.title_active(), "game mode: the crane game (2) is as before, without the score game")
	_gm_free(game, rs)

func _test_game_mode_duplicates_and_sessions(rs: Node) -> void:
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var l: GameModeController.Lane = ctl.lanes["left"]
	# every event twice (a re-sent event) and a bouncing switch: still one capsule
	hub.duplicate_events = true
	hub.mock_ball(GM_L)
	hub.chatter(GM_L, 3)
	hub.stale_event(GM_L, "BALL_RECEIVED", {"cycle": 9})  # an old session's event arrives late
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var one: bool = ctl.capsules.active.size() == 1 and ctl.field.capsule_count() == 1
	var id := str(l.capsule.capsule_id)
	ctl.field.capsule_exited.emit(id, "left", Vector2(300, 660))
	_gm_step(ctl, 4.0)
	hub.stale_event(GM_L, "RELEASE_DONE", {"command_id": 1})
	var ignored: Array = ctl.trace.rows.filter(func(row): return row.event in ["event_ignored", "ball_ignored"]).map(func(row): return row.result)
	_ok(one and l.state == "READY" and hub.count(GM_L, "RELEASE_BALL") == 1 and ctl.score.score == 100 and l.released == 1
		and ignored.has("duplicate") and ignored.has("old_cycle") and ignored.has("stale_session"),
		"game mode: re-sent events, a bouncing switch and an old session's event give one capsule, one score, one release", str(ignored))
	hub.duplicate_events = false
	# the hub's link drops and comes back (a new session) while a capsule is in play
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	id = str(l.capsule.capsule_id)
	var old_session := hub.session
	hub.restart_session()
	var kept: bool = l.state == "SIMULATING" and bool(l.capsule.orphaned) and ctl.session == old_session + 1
	ctl.field.target_hit.emit(id, "bumper", "bumper_1", Vector2(640, 415))
	ctl.field.capsule_exited.emit(id, "center", Vector2(640, 660))
	_gm_step(ctl, ctl.arm_retry_s + 1.0)
	_ok(kept and ctl.score.score == 1200 and l.state == "FAULT" and hub.count(GM_L, "RELEASE_BALL") == 1
		and ctl.lane_text("left").contains("係の人"),
		"game mode: after a reconnection the capsule in play still scores but is NOT released by itself (FAULT)",
		"%s %d" % [l.state, hub.count(GM_L, "RELEASE_BALL")])
	_gm_free(game, rs)
	game = _gm_game()
	ctl = _gm_playing(game)
	hub = ctl.mock_hub
	l = ctl.lanes["left"]
	# the link drops and comes back while the Dial was only waiting: it is armed again
	hub.restart_session()
	var idle_off: bool = l.state == "OFFLINE"
	_gm_step(ctl, ctl.arm_retry_s + 1.0)
	_ok(idle_off and l.state == "READY" and hub.dials[GM_L].state == "ARMED",
		"game mode: after a reconnection a Dial that was only waiting arms again", "%s %s" % [idle_off, l.state])
	# review on #139: a capsule lands before the ARM_RECEIVER's answer is back
	hub.latency_s = 1.0
	hub.command(GM_L, "DISARM_RECEIVER")
	l.state = "ARMING"
	ctl._arm(l)
	var arming: bool = l.state == "ARMING" and hub.dials[GM_L].state == "ARMED"
	hub.mock_ball(GM_L)
	var taken_early: bool = l.state == "ABSORBING" and not l.capsule.is_empty()
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.1)  # the late ACK changes nothing
	var rid := str(l.capsule.capsule_id)
	var in_play: bool = l.state == "SIMULATING" and ctl.field.has_capsule(rid)
	hub.latency_s = 0.03
	ctl.field.capsule_exited.emit(rid, "left", Vector2(300, 660))
	_gm_step(ctl, 4.0)
	_ok(arming and taken_early and in_play and l.state == "READY" and hub.count(GM_L, "RELEASE_BALL") == 1,
		"game mode: a capsule reported before the arm's ACK is still played and released (not left in the Dial)",
		"%s %s %s %s" % [arming, taken_early, in_play, l.state])
	# the Dial offline for a moment: its lane waits and arms again
	hub.set_online(GM_L, false)
	var off: bool = l.state == "OFFLINE"
	hub.set_online(GM_L, true)
	_gm_step(ctl, 0.3)
	_ok(off and l.state == "READY", "game mode: a Dial that went offline is armed again when it is back", l.state)
	_gm_free(game, rs)

func _test_game_mode_release_faults(rs: Node) -> void:
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var l: GameModeController.Lane = ctl.lanes["left"]
	# the release command is refused: no second try
	hub.refuse_next["%d|RELEASE_BALL" % GM_L] = "OFFLINE"
	_gm_play_capsule(ctl, "left")
	_gm_step(ctl, 6.0)
	var refused: bool = l.state == "FAULT" and hub.count(GM_L, "RELEASE_BALL") == 0 and l.fault.contains("OFFLINE") \
		and ctl.score.score == 100 and ctl.fx.played.has("capsule_fault:left") and ctl.phase == "PLAYING"
	var refused_note := "%s %s" % [l.state, l.fault]
	_gm_free(game, rs)
	game = _gm_game()
	ctl = _gm_playing(game)
	hub = ctl.mock_hub
	l = ctl.lanes["left"]
	# the servo sequence fails
	hub.fail_release[GM_L] = true
	_gm_play_capsule(ctl, "left")
	_gm_step(ctl, 4.0)
	_ok(refused and l.state == "FAULT" and hub.count(GM_L, "RELEASE_BALL") == 1 and ctl.score.score == 100
		and ctl.fx.played.has("capsule_fault:left") and ctl.phase == "PLAYING",
		"game mode: a refused release and RELEASE_FAILED stop the lane (FAULT), never a second RELEASE_BALL; the score stays",
		"%s / %s %s" % [refused_note, l.state, l.fault])
	_gm_free(game, rs)
	game = _gm_game()
	ctl = _gm_playing(game)
	hub = ctl.mock_hub
	l = ctl.lanes["left"]
	# RELEASE_DONE never comes
	hub.lose_release_done[GM_L] = true
	_gm_play_capsule(ctl, "left")
	_gm_step(ctl, ctl.release_sync_s + ctl.release_timeout_s - 0.5)
	var waiting: bool = l.state == "RELEASING"
	_gm_step(ctl, 5.0)
	var settled: bool = l.state == "READY" and l.released == 1 and hub.count(GM_L, "RELEASE_BALL") == 1 \
		and ctl.trace.rows.any(func(row): return row.release_status == "timeout")
	# every Illumination command is refused: the next capsule does not care
	for n in ["SET_LIGHT_MODE", "TRIGGER_EFFECT"]:
		hub.refuse_next["%d|%s" % [GameModeDevices.ILLUMINATION, n]] = "OFFLINE"
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, 4.0)
	_ok(waiting and settled and l.state == "READY" and l.released == 2 and hub.count(GM_L, "RELEASE_BALL") == 2,
		"game mode: a lost RELEASE_DONE is settled by the Dial's status (done and empty = go on, no re-release); refused lights never hold a release",
		"%s %s %s %d" % [waiting, settled, l.state, l.released])
	# ... and when the status does not say so either: FAULT
	hub.lose_release_done[GM_L] = true
	hub.stuck_ball[GM_L] = true
	_gm_play_capsule(ctl, "left")
	_gm_step(ctl, ctl.release_sync_s + ctl.release_timeout_s + ctl.verify_retry_s * ctl.verify_tries + 1.0)
	_ok(l.state == "FAULT" and l.fault.contains("RELEASE_DONE") and hub.count(GM_L, "RELEASE_BALL") == 3
		and hub.led_effect(GM_L) == "FLASH",
		"game mode: no RELEASE_DONE and a Dial that is not done = FAULT (red flash on the Dial), still one RELEASE_BALL per capsule",
		"%s %s" % [l.state, l.fault])
	_gm_free(game, rs)
	game = _gm_game()
	ctl = _gm_playing(game)
	hub = ctl.mock_hub
	l = ctl.lanes["left"]
	# after the release the Dial still reports a capsule: not armed again blindly
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	hub.stuck_ball[GM_L] = true  # the capsule does not leave: the switch stays on
	ctl.field.capsule_exited.emit(str(l.capsule.capsule_id), "left", Vector2(300, 660))
	_gm_step(ctl, ctl.release_sync_s + MockDialHub.SERVO_HOLD_S + MockDialHub.SERVO_SETTLE_S + 0.1)
	var verifying: bool = l.state == "VERIFYING"
	var per_try: float = MockDialHub.SERVO_HOLD_S + MockDialHub.SERVO_SETTLE_S + ctl.verify_retry_s * ctl.verify_tries + 1.0
	_gm_step(ctl, per_try * (ctl.release_retries + 1))
	# #185: the release is tried again, twice; a capsule that still does not leave is a FAULT
	_ok(verifying and l.state == "FAULT" and l.fault.contains("出ていない") and hub.count(GM_L, "RELEASE_BALL") == 1 + ctl.release_retries
		and ctl.release_retries == 2 and hub.dials[GM_L].state == "COMPLETE" and l.released == 0,
		"game mode: RELEASE_DONE is not proof: a capsule still in the Dial gets the release twice more, then the Dial is not armed again (FAULT)", "%s %s %d" % [l.state, l.fault, hub.count(GM_L, "RELEASE_BALL")])
	# ... one that leaves at the second try: the round goes on
	hub.stuck_ball.clear()
	ctl._halt("test")
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 1.0)
	var n_rel := hub.count(GM_L, "RELEASE_BALL")
	hub.stuck_ball[GM_L] = 1
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, per_try * 2.0 + 2.0)
	var second_try: bool = ctl.phase == "PLAYING" and l.state == "READY" and l.released == 1 and hub.count(GM_L, "RELEASE_BALL") == n_rel + 2 \
		and l.re_releases == 0 and ctl.trace.rows.any(func(row): return str(row.get("release_status", "")).begins_with("again 1/"))
	# ... and a Dial that does not know the second release (older firmware): FAULT, said so
	hub.no_second_release = true
	hub.stuck_ball[GM_L] = true
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, per_try * 2.0 + 2.0)
	_ok(second_try and l.state == "FAULT" and l.fault.contains("ファームウェア"),
		"game mode (#185): a capsule that leaves at the second release lets the round go on; a Dial that refuses the second release is a FAULT that says so",
		"%s %s %s" % [second_try, l.state, l.fault])
	_gm_free(game, rs)

## The Dials' transfer LEDs (UFO-DeviceHub docs/game-mode-interface.md): decoration that
## follows the game, never something the game waits for.
func _test_game_mode_dial_leds(rs: Node) -> void:
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var l: GameModeController.Lane = ctl.lanes["left"]
	var fx_of := func(dev: int) -> Array:
		return hub.executed.filter(func(e): return e[0] == dev and e[1] == "SET_DIAL_EFFECT").map(func(e): return e[2])
	var colours: bool = hub.dials[GM_L].color == [0, 255, 255] and hub.count(GM_L, "SET_DIAL_COLOR") == 1 \
		and hub.count(GM_R, "SET_DIAL_COLOR") == 0 and ctl.fx.colors["left"] == Color8(0, 255, 255)
	hub.mock_ball(GM_L)
	var intake: Dictionary = fx_of.call(GM_L)[-1]
	var intake_ok: bool = intake.effect == "CHASE" and intake.direction == "TO_SCREEN" and intake.duration_ms == 1500 \
		and intake.priority == "NORMAL" and intake.target == "BOTH" and not intake.has("color") and hub.led_effect(GM_L) == "CHASE"
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	ctl.field.capsule_exited.emit(str(l.capsule.capsule_id), "left", Vector2(300, 660))
	var opposite: bool = hub.dials[GM_L].led.effect == "COMET" and hub.dials[GM_L].led.direction == "TO_DIAL"
	var sent_before_release: bool = hub.count(GM_L, "RELEASE_BALL") == 0
	_gm_step(ctl, ctl.release_sync_s + 0.1)
	var releasing: bool = hub.led_effect(GM_L) == "CHASE" and hub.dials[GM_L].led.direction == "TO_DIAL" and l.state == "RELEASING"
	_gm_step(ctl, 3.0)
	_ok(colours and intake_ok and opposite and sent_before_release and releasing and l.state == "READY" and hub.led_effect(GM_L) == "NONE"
		and fx_of.call(GM_L).map(func(p): return p.effect) == ["CHASE", "COMET", "CHASE"],
		"game mode LEDs: the unit colour per session, INTAKE (to the screen), RETURN_FLOW then RELEASING (to the Dial); the Dial ends it at RELEASE_DONE; no LED command for Dial 2",
		"%s %s %s %s %s" % [colours, intake_ok, opposite, releasing, fx_of.call(GM_L)])
	# a refused effect (a higher priority is running) holds nothing
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	hub.dials[GM_L].led = {"effect": "FLASH", "direction": "NONE", "color": [255, 0, 0], "priority": "HIGH", "left": 0.0}
	ctl.field.capsule_exited.emit(str(l.capsule.capsule_id), "left", Vector2(300, 660))
	_gm_step(ctl, 4.0)
	var refused: bool = ctl.trace.rows.any(func(row): return row.event == "ack" and row.result == "IGNORED_PRIORITY")
	_ok(refused and l.state == "READY" and l.released == 2 and l.led_ok and fx_of.call(GM_R).is_empty(),
		"game mode LEDs: IGNORED_PRIORITY changes nothing: the capsule is released as usual", l.state)
	_gm_free(game, rs)
	# firmware 0.2: the Dials do not know the LED commands
	game = _gm_game()
	game.game_mode.mock_hub.old_firmware = true
	ctl = _gm_playing(game)
	hub = ctl.mock_hub
	l = ctl.lanes["left"]
	var asked: int = ctl.trace.rows.filter(func(row): return row.event == "command" and row.effect_id in ["SET_DIAL_EFFECT", "SET_DIAL_COLOR"]).size()
	_gm_play_capsule(ctl, "center")
	_gm_step(ctl, 4.0)
	var asked_after: int = ctl.trace.rows.filter(func(row): return row.event == "command" and row.effect_id in ["SET_DIAL_EFFECT", "SET_DIAL_COLOR"]).size()
	_ok(asked == 1 and asked_after == 1 and not l.led_ok and l.state == "READY" and l.released == 1 and ctl.score.score == 1000
		and ctl.trace.rows.any(func(row): return row.event == "led" and str(row.led_command).contains("not sent")),
		"game mode LEDs: older firmware (UNSUPPORTED) = no more LED commands this round, the game is the same", "%d %d" % [asked, asked_after])
	ctl.dial_leds = false
	game._unhandled_input(_key(KEY_SPACE))
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	var asked_off: int = ctl.trace.rows.filter(func(row): return row.event == "command" and str(row.effect_id).begins_with("SET_DIAL_")).size()
	_ok(ctl.phase == "PLAYING" and l.state == "READY" and asked_off == asked_after,
		"game mode LEDs: game_mode.dial_leds off sends none", "%d %d" % [asked_off, asked_after])
	_gm_free(game, rs)

func _test_game_mode_clock_and_stop(rs: Node) -> void:
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var l: GameModeController.Lane = ctl.lanes["left"]
	_ok(GameModeHud.clock_text(150.0) == "2:30" and GameModeHud.clock_text(29.2) == "0:30" and GameModeHud.clock_text(0.0) == "0:00",
		"game mode HUD: the clock counts down from 2:30")
	ctl.time_left = 30.5
	_gm_step(ctl, 1.0)
	var hurry: bool = ctl.sounds.hurry and ctl.sounds.log.has("hurry") and ctl.sounds.bgm_on
	ctl.time_left = 10.4
	_gm_step(ctl, 1.0)
	var warned: bool = ctl.sounds.log.has("warning")
	# a capsule taken just before 0 s plays on; nothing new after 0 s
	ctl.time_left = 0.5
	hub.mock_ball(GM_L)
	_gm_step(ctl, 0.6)
	var settling: bool = ctl.phase == "SETTLING" and l.state == "ABSORBING" \
		and not ctl.sounds.bgm_on and ctl.sounds.log.has("timeup") \
		and ctl.tutorial_speech.current == GameModeController.TIME_UP_LINE  # #271: UFOくん says the end
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s - 0.5)
	_ok(hurry and warned and settling and l.state == "SIMULATING" and ctl.time_left == 0.0,
		"game mode: the last 30 s hurry, the last 10 s warn; at 0 s the capsule in play goes on",
		"%s %s %s %s" % [hurry, warned, settling, l.state])
	# review on #139: time runs out while an ARM_RECEIVER is on its way: that Dial is disarmed too
	var g2 := _gm_game()
	var c2 := _gm_playing(g2)
	c2.mock_hub.latency_s = 1.0
	var l2: GameModeController.Lane = c2.lanes["left"]
	c2.mock_hub.command(GM_L, "DISARM_RECEIVER")
	l2.state = "ARMING"
	c2._arm(l2)
	var armed_now: bool = c2.mock_hub.dials[GM_L].state == "ARMED"
	c2.time_left = 0.01
	_gm_step(c2, 0.05)
	var closing: bool = c2.phase == "SETTLING" and l2.state == "CLOSING" and c2.mock_hub.dials[GM_L].state == "READY"
	_gm_step(c2, 2.5)
	_ok(armed_now and closing and c2.phase == "RESULT" and l2.state == "CLOSED" and not c2.mock_hub.mock_ball(GM_L),
		"game mode: at 0 s a Dial whose arming was still on its way is disarmed too", "%s %s %s" % [armed_now, closing, l2.state])
	_gm_free(g2, rs)
	# the Dial was free at 0 s: it is disarmed; a capsule that landed just as the time ran
	# out (its report comes after 0 s): back out, no score
	var g3 := _gm_game()
	var c3 := _gm_playing(g3)
	var h3 := c3.mock_hub
	var l3: GameModeController.Lane = c3.lanes["left"]
	h3.latency_s = 1.0  # the Dial's answers are slow: the lane is still closing when the report comes
	c3.time_left = 0.01
	_gm_step(c3, 0.05)
	var disarmed: bool = c3.phase == "SETTLING" and l3.state == "CLOSING" and h3.dials[GM_L].state == "READY" and not h3.mock_ball(GM_L)
	h3._emit(GM_L, "BALL_RECEIVED", {"cycle": 2})
	h3.dials[GM_L].state = "BALL_DETECTED"
	h3.latency_s = 0.03
	var late: bool = l3.state == "RETURNING" and bool(l3.capsule.late) and c3.field.capsule_count() == 0
	_gm_step(c3, 6.0)
	_ok(disarmed and late and c3.phase == "RESULT" and c3.score.score == 0 and l3.state == "CLOSED" and h3.count(GM_L, "RELEASE_BALL") == 1
		and h3.dials[GM_L].op_mode == "STANDBY" and c3.capsules.finished.size() == 1
		and int(c3.result.get("capsules", -1)) == 0 and int(c3.result.get("capsule_bonus", -1)) == 0,
		"game mode: at 0 s a free Dial is disarmed; a capsule reported after 0 s goes straight back (never on the field, no score, no bonus), then RESULT",
		"%s %s %s %s %d" % [disarmed, late, c3.phase, l3.state, c3.score.score])
	_gm_free(g3, rs)
	# the capsule in play at 0 s is scored and released
	var id := str(l.capsule.capsule_id)
	ctl.field.target_hit.emit(id, "star", "star", Vector2(640, 505))
	ctl.field.capsule_exited.emit(id, "center", Vector2(640, 660))
	_gm_step(ctl, 5.0)
	_ok(ctl.phase == "RESULT" and ctl.guide_hidden(), "game mode #258: no hand window on the result (its corner would cover the lines)")
	var mist_of := func(): return hub.executed.filter(func(e): return e[0] == GameModeDevices.ILLUMINATION and e[1] == "SET_MIST").map(func(e): return e[2])
	var m0: Array = mist_of.call()
	var capsule_mists := m0.filter(func(m): return int(m.duration_s) == ctl.mist_capsule_s)
	var result_before := m0.filter(func(m): return int(m.duration_s) == ctl.mist_result_s).size()
	_gm_step(ctl, 20.0)  # the result's show runs to its FINAL SCORE
	var m1: Array = mist_of.call()
	_ok(not capsule_mists.is_empty() and capsule_mists[0].pattern == "CONTINUOUS" and result_before == 0
		and ctl.result_show.log.has("final") and m1.size() == m0.size() + 1
		and m1[-1].pattern == "CONTINUOUS" and int(m1[-1].duration_s) == ctl.mist_result_s,
		"game mode: mist for mist_capsule_s when a capsule is taken in; the result's mist only when its score settles (FINAL SCORE), once",
		"%s -> %s" % [str(m0), str(m1)])
	ctl.mist_enabled = false
	_ok(not ctl.mist_burst(5), "mist off by config: nothing is sent")
	ctl.mist_enabled = true
	_ok(not ctl.mist_burst(0), "0 s: no mist")
	# #316: no mist while a servo moves (it floods their reply line): it waits, then goes out
	var em0: Dictionary = RobotState.easy_mode
	var ms0: String = RobotState.machine_state
	var n0: int = mist_of.call().size()
	RobotState.easy_mode = {"state": "DELIVER_DIAL_1", "step": "RELEASE"}
	var queued := ctl.mist_burst(ctl.mist_capsule_s)
	ctl.lights_tick(0.5)
	_gm_step(ctl, 0.3)
	var held: bool = mist_of.call().size() == n0 and ctl.mist_pending_s == ctl.mist_capsule_s
	RobotState.easy_mode = {"state": "DELIVER_DIAL_1", "step": "RAISE_EMPTY"}  # the drum: the same line
	ctl.lights_tick(0.5)
	_gm_step(ctl, 0.3)
	var held_z: bool = mist_of.call().size() == n0
	RobotState.easy_mode = {"state": "MANUAL_XY", "step": "IDLE"}
	ctl.lights_tick(0.1)
	_gm_step(ctl, 0.3)
	var m2: Array = mist_of.call()
	_ok(queued and held and held_z and m2.size() == n0 + 1 and int(m2[-1].duration_s) == ctl.mist_capsule_s
		and ctl.mist_pending_s == 0,
		"game mode #316: a mist asked for while the claw or the drum moves is sent once they stopped, once",
		"%s %s %s %s" % [queued, held, held_z, str(m2.slice(n0))])
	RobotState.machine_state = "Z_RAISING"  # a manual move; it never stops: the mist is dropped
	ctl.mist_burst(5)
	ctl.lights_tick(ctl.mist_defer_max_s + 1.0)
	RobotState.machine_state = "IDLE"
	ctl.lights_tick(0.1)
	_gm_step(ctl, 0.3)
	_ok(mist_of.call().size() == n0 + 1 and ctl.mist_pending_s == 0,
		"game mode #316: a mist that waited longer than mist_defer_max_s for the servos is dropped")
	RobotState.easy_mode = em0
	RobotState.machine_state = ms0
	_ok(ctl.phase == "RESULT" and ctl.score.score == 1500 and l.state == "CLOSED"
		and hub.count(GM_L, "RELEASE_BALL") == 1 and _gm_sent(hub, GM_R) == 0 and hub.dials[GM_L].op_mode == "STANDBY"
		and hub.dials[GM_L].cycle == 1 and ctl.hud.result_lines().contains("1500") and ctl.capsules.finished.size() == 1,
		"game mode: after 0 s the capsule in play is scored and released, then RESULT",
		"%s %d %s" % [ctl.phase, ctl.score.score, l.state])
	game._unhandled_input(_key(KEY_Z))  # RESULT: nothing is taken
	game._unhandled_input(_key(KEY_ENTER))  # the result's show ends (#153)...
	game._unhandled_input(_key(KEY_ENTER))  # ...and the next Enter plays
	_ok(ctl.phase == "COUNTDOWN" and ctl.score.score == 0 and ctl.capsules.finished.is_empty(), "game mode: Enter on the result starts a new round")
	_gm_step(ctl, ctl.countdown_s + 0.2)
	# a capsule that never leaves the field: taken out at 15 s, no goal score, released
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	ctl.field.advance(ctl.field.max_stay_s - 0.1)
	var still: bool = l.state == "SIMULATING"
	ctl.field.advance(0.2)
	_gm_step(ctl, 4.0)
	_ok(still and l.state == "READY" and l.released == 1 and ctl.score.score == 0 and ctl.field.capsule_count() == 0
		and ctl.field.max_stay_s == 15.0 and ctl.trace.named("stay_timeout").size() == 1,
		"game mode: a capsule is taken out after 15 s in the field (no goal score) and released as usual", l.state)
	# the settle time runs out with a lane still busy: it ends in FAULT, the result still comes
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var released_before := hub.count(GM_L, "RELEASE_BALL")
	ctl.time_left = 0.01
	_gm_step(ctl, 0.1)
	_gm_step(ctl, ctl.settle_max_s + 0.5)
	_ok(ctl.phase == "RESULT" and l.state == "FAULT" and hub.count(GM_L, "RELEASE_BALL") == released_before
		and ctl.hud.result_lines().contains("Dial: ") and hub.dials[GM_L].state == "BALL_DETECTED",
		"game mode: settling is bounded (30 s): what is still in play ends as a FAULT and the result is shown", "%s %s" % [ctl.phase, l.state])
	# the next round with that capsule still in the Dial: the lane cannot arm and says why
	game._unhandled_input(_key(KEY_ENTER))  # (the result's show ends, then the round starts)
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	var stuck: bool = l.state in ["OFFLINE", "ARMING"] and ctl.lane_text("left").contains("残っている")
	hub.dials[GM_L].state = "READY"  # a person took it out
	_gm_step(ctl, ctl.arm_retry_s + 0.3)
	_ok(stuck and l.state == "READY" and hub.count(GM_L, "RELEASE_BALL") == released_before,
		"game mode: a capsule left in a Dial keeps that lane from arming (the HUD says so) until a person takes it out", l.state)
	# Space
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	id = str(l.capsule.capsule_id)
	var stops := hub.count(GM_L, "STOP_ALL")
	var releases := hub.count(GM_L, "RELEASE_BALL")
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))
	game._unhandled_input(_key(KEY_SPACE))
	var crane_stopped: bool = game.mock.target.is_equal_approx(game.mock.pos)
	ctl.field.capsule_exited.emit(id, "center", Vector2(640, 660))
	hub.mock_ball(GM_L)
	_gm_step(ctl, 5.0)
	_ok(crane_stopped and ctl.phase == "STOPPED" and ctl.field.frozen and hub.count(GM_L, "STOP_ALL") == stops + 1
		and hub.count(GM_R, "STOP_ALL") >= 1 and hub.count(GM_L, "RELEASE_BALL") == releases and ctl.score.score == 0
		and l.state == "FAULT" and hub.dials[GM_L].op_mode == "STANDBY" and ctl.message.contains("係の人"),
		"game mode: Space stops the crane and the round, STOP_ALL goes to every device, nothing is scored or released afterwards",
		"%s %s" % [ctl.phase, l.state])
	game._unhandled_input(_key(KEY_ENTER))
	_ok(ctl.phase == "COUNTDOWN" and not ctl.field.frozen, "game mode: Enter after a stop starts over")
	_gm_free(game, rs)

func _test_game_mode_backend_hub(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	var hub := ctl.backend_hub
	ctl.devices_wanted = "backend"
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	var events: Array = []
	var answers: Array = []
	hub.device_event.connect(func(ev): events.append(ev))
	hub.command_done.connect(func(rid, ok, result, data): answers.append([rid, ok, result, data]))
	_ok(ctl.devices == hub and not hub.available() and not hub.can_mock_ball() and ctl.hud != null,
		"game mode backend: picked by game_mode.devices; without a backend it is not available")
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, 0.2)
	_ok(ctl.phase == "COUNTDOWN" and ctl.lanes["left"].state == "OFFLINE",
		"game mode backend: no hub = the lane waits offline (the round still runs)")
	# why there is no hub is said on the screen
	var no_backend: String = ctl.hud.problem_text()
	hub._problem = ""
	hub._meta_rid = "why1"
	game.ws.ack.emit("why1", true, {"command": "devicehub_meta", "connected": false, "port": "/dev/cu.usbmodem101",
		"session_id": 0, "problem": "ポート /dev/cu.usbmodem101 のハブは別のシステムのもの（this hub is system 2）。設定のシステム番号は 1"})
	var wrong_system: String = hub._problem
	hub._meta_rid = "why2"
	game.ws.ack.emit("why2", false, {"command": "devicehub_meta", "reason": "周辺機器のハブを使っていない（設定の devicehub.enabled をオンにして ./start.sh）"})
	var no_hub: String = hub._problem
	_ok(no_backend.contains("つながっていない") and no_backend.contains("./start.sh") and wrong_system.contains("別のシステム")
		and wrong_system.contains("システム番号は 1") and no_hub.contains("devicehub.enabled") and not hub.available(),
		"game mode backend: why the hub is away is shown (no backend, another system's hub, no hub in the backend)",
		"%s | %s | %s" % [no_backend, wrong_system, no_hub])
	# the backend's answers and events, as the server sends them
	hub._meta_rid = "meta1"
	game.ws.ack.emit("meta1", true, {"command": "devicehub_meta", "connected": true, "port": "mock", "session_id": 7})
	hub._pending["c1"] = "command"
	game.ws.ack.emit("c1", true, {"command": "devicehub_command", "result": {"ok": true, "result": "ACCEPTED", "command_id": 41.0}})
	hub._pending["c2"] = "command"
	game.ws.ack.emit("c2", true, {"command": "devicehub_command", "result": {"ok": false, "result": "REJECTED_STATE", "command_id": 42.0}})
	hub._pending["c3"] = "command"
	game.ws.ack.emit("c3", false, {"reason": "timeout"})
	hub._pending["s1"] = "status"
	game.ws.ack.emit("s1", true, {"command": "devicehub_status", "device": 32.0, "status": {"dial_state": "COMPLETE", "cycle": 3.0}})
	game.ws.message_received.emit({"type": "devicehub_event", "data": {"name": "BALL_RECEIVED", "source": 33.0,
		"data": {"cycle": 4.0}, "event_id": 9.0, "session_id": 7.0, "received_at": 12.5}})
	game.ws.message_received.emit({"type": "robot_state", "data": {}})
	var connected: Array = events.filter(func(e): return e.name == "GATEWAY_CONNECTED")
	var ball: Array = events.filter(func(e): return e.name == "BALL_RECEIVED")
	_ok(hub._hub_connected and hub._mock and hub._session == 7 and connected.size() == 1 and connected[0].data.session_id == 7
		and answers.size() == 4 and answers[0] == ["c1", true, "ACCEPTED", {"command_id": 41}]
		and answers[1][1] == false and answers[1][2] == "REJECTED_STATE" and answers[2] == ["c3", false, "TIMEOUT", {}]
		and answers[3][3].status.dial_state == "COMPLETE" and ball.size() == 1 and ball[0].source == 33
		and typeof(ball[0].source) == TYPE_INT and ball[0].event_id == 9 and ball[0].session_id == 7 and ball[0].data.cycle == 4.0
		and ctl.session == 7,
		"game mode backend: the backend's ACK / NACK / timeout / status and devicehub_event become the game's answers and events",
		"%s | %s" % [answers, events])
	_gm_free(game, rs)

func _test_game_mode_physics() -> void:
	var holder := CanvasLayer.new()
	add_child(holder)
	var f := PinballField.new()
	holder.add_child(f)
	var exits := {}
	var hits := {}
	f.capsule_exited.connect(func(id, goal, _pos): exits[id] = goal)
	f.target_hit.connect(func(id, kind, _t, _pos): hits[kind] = int(hits.get(kind, 0)) + 1)
	var ticks := Engine.physics_ticks_per_second
	var max_steps := Engine.max_physics_steps_per_frame
	Engine.physics_ticks_per_second = 60 * 8
	Engine.time_scale = 8.0
	Engine.max_physics_steps_per_frame = 32
	# many X, not a lucky few (#147): the field is chaotic, a handful proves nothing
	var xs := []
	for k in 24:
		xs.append(lerpf(PinballField.LEFT + 50.0, PinballField.RIGHT - 50.0, k / 23.0))
	var worst := 0.0
	for i in xs.size():
		var id := "p%d" % i
		f.spawn_capsule(id, xs[i], Color.WHITE)
		var age := 0.0
		for step in 60 * 20:
			await get_tree().physics_frame
			if exits.has(id):
				age = float(f._capsules[id].age)
				break
		worst = maxf(worst, age)
		f.remove_capsule(id)
	Engine.physics_ticks_per_second = ticks
	Engine.time_scale = 1.0
	Engine.max_physics_steps_per_frame = max_steps
	var goals: Array = exits.values()
	_ok(exits.size() == xs.size() and goals.all(func(g): return g in ["left", "center", "right"]) and worst > 0.5 and worst < 13.0
		and int(hits.get("pin", 0)) >= xs.size() and int(hits.get("switch", 0)) >= 2,
		"game mode physics: 24 capsules dropped across the field hit pins and switches and all reach a goal well inside 15 s",
		"%s hits=%s worst=%.1fs" % [exits, hits, worst])
	_ok(is_zero_approx(f.settle_k(0.0)) and is_zero_approx(f.settle_k(f.settle_after_s)) and is_equal_approx(f.settle_k(f.settle_after_s + f.settle_over_s), 1.0)
		and f.settle_k(f.settle_after_s + f.settle_over_s * 0.5) > 0.4 and f.settle_after_s + f.settle_over_s < f.max_stay_s,
		"game mode physics: a fresh capsule bounces at full strength, one that stays calms down well before the time limit (#147)",
		"%.1f %.1f %.1f" % [f.settle_after_s, f.settle_over_s, f.max_stay_s])
	remove_child(holder)
	holder.free()

func _test_game_mode_powerup_followup(rs: Node) -> void:
	# ---- the light's mode is a function of the state
	var f := GameModeController.light_mode_for
	_ok(f.call("COUNTDOWN", false, false).mode == "GAME_READY" and f.call("RESULT", true, true).mode == "RESULT"
		and f.call("IDLE", true, true).mode == "IDLE" and f.call("STOPPED", false, true).is_empty()
		and f.call("TUTORIAL", false, false).is_empty(),
		"light: READY in the countdown, RESULT at the end, the title show on the score game's title, not the game's otherwise")
	var g := GameModeController.light_scene_for
	_ok(g.call("title").mode == "IDLE" and g.call("study").mode == "STUDY" and int(g.call("study").brightness) == 255
		and g.call("").is_empty() and g.call("settings").is_empty(),
		"light outside the score game: the title show, the bright study light, nothing elsewhere")
	_ok(f.call("PLAYING", false, false).speed == 128 and f.call("PLAYING", true, false).speed == 230
		and f.call("PLAYING", true, true).mode == "CUSTOM" and f.call("SETTLING", true, false).speed == 230,
		"light: rainbow, the fast rainbow in the last stretch, gold over both while x2 runs")
	# ---- the light while the score game is closed: the title's show, the study light
	var outside := _gm_game()
	var oc: GameModeController = outside.game_mode
	oc.lights_tick(0.1)
	var ohub := oc.mock_hub
	var o0 := _gm_light_modes(ohub)
	oc.scene_outside = "study"
	oc.lights_tick(0.1)
	oc.lights_tick(0.1)
	var o1 := _gm_light_modes(ohub)
	oc.scene_outside = ""
	oc.lights_tick(0.1)
	var o2 := _gm_light_modes(ohub)
	ohub.restart_session()
	ohub.connected = true
	oc.scene_outside = "title"
	oc.lights_tick(0.1)
	var o3 := _gm_light_modes(ohub)
	_ok(o1.size() == o0.size() + 1 and o1[-1].mode == "STUDY" and o2.size() == o1.size()
		and o3.size() == o2.size() + 1 and o3[-1].mode == "IDLE",
		"closed score game: the study light once, nothing for another screen, the title show (again after a new hub session)",
		str(o3))
	remove_child(outside)
	outside.free()
	var game := _gm_game()
	var ctl := _gm_playing(game)
	var hub := ctl.mock_hub
	var lane: GameModeController.Lane = ctl.lanes["left"]
	var modes := _gm_light_modes(hub)
	_ok(modes.size() == 2 and modes[0].mode == "GAME_READY" and modes[1].mode == "GAME_PLAY" and int(modes[1].speed) == 128,
		"light: one command per change (READY, then PLAY)", str(modes))
	_gm_step(ctl, 1.0)
	_ok(_gm_light_modes(hub).size() == 2, "light: nothing is sent while nothing changes")
	_ok(ctl.force_powerup("double") and _gm_light_modes(hub)[-1].mode == "CUSTOM", "x2 (forced, no ball needed): gold at once")
	ctl.time_left = ctl.hurry_s + 0.5
	_gm_step(ctl, 1.0)  # the last stretch begins under the gold
	_ok(ctl._hurry_done and _gm_light_modes(hub)[-1].mode == "CUSTOM" and _gm_light_modes(hub).size() == 3,
		"last stretch during x2: the gold stays, no rainbow is sent over it")
	_gm_step(ctl, float(ctl.powerups.duration.double))
	var last: Dictionary = _gm_light_modes(hub)[-1]
	_ok(not ctl.powerups.active("double") and last.mode == "GAME_PLAY" and int(last.speed) == 230 and int(last.brightness) == 220
		and _gm_light_modes(hub).size() == 4,
		"x2 ends in the last stretch: back to the FAST rainbow, with one command", str(last))
	# ---- the staff's keys, and what they need
	_ok(not ctl.force_powerup("multiball") and not ctl.force_powerup("nothing"), "forced MULTI BALL needs a ball on the field")
	game._unhandled_input(_key(KEY_F2))
	_ok(ctl.powerups.active("speed"), "F2: SPEED UP now")
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(lane.capsule.capsule_id)
	game._unhandled_input(_key(KEY_F3))
	ctl.tick(1.0 / 60.0)
	_ok(ctl.field.capsule_count() == 3 and ctl._multi_balls.has(id) and not ctl.force_powerup("multiball"),
		"F3: MULTI BALL on the ball in play, once per capsule")
	# ---- the balls vanish without a word: the capsule still goes back
	for vid in (ctl._multi_balls[id] as Array).duplicate():
		ctl.field.remove_capsule(str(vid))
	ctl.tick(1.0 / 60.0)
	_ok(lane.state == "RETURNING" and ctl._multi_balls.is_empty() and ctl._virtual_root.is_empty()
		and not ctl.fx.power_portals.left, "multiball: balls that vanished do not hold the capsule (it returns)")
	_gm_step(ctl, 4.0)
	_ok(hub.count(GM_L, "RELEASE_BALL") == 1 and lane.state == "READY", "…and it is released once")
	# ---- the ball left before the split was made: nothing waits for balls that never were
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	id = str(lane.capsule.capsule_id)
	ctl._multi_pending.append({"ball": id, "root": id})  # as asked for inside a physics callback
	ctl.field.capsule_exited.emit(id, "left", Vector2(200, 1000))
	ctl.tick(1.0 / 60.0)
	_ok(lane.state == "RETURNING" and ctl._multi_balls.is_empty() and ctl._multi_pending.is_empty()
		and ctl.field.capsule_count() == 0, "multiball asked for as the ball left: no split, the capsule returns")
	_gm_step(ctl, 4.0)
	_ok(hub.count(GM_L, "RELEASE_BALL") == 2 and lane.state == "READY", "…and the Dial is ready again")
	# ---- a FAULT ends the capsule's balls
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	id = str(lane.capsule.capsule_id)
	ctl.force_powerup("multiball")
	ctl._fault(lane, "test")
	_ok(ctl.field.capsule_count() == 0 and ctl._multi_balls.is_empty() and ctl._virtual_root.is_empty(),
		"a faulted Dial: its capsule's three balls are gone")
	_gm_free(game, rs)
	# ---- the switches
	game = _gm_game()
	ctl = game.game_mode
	ctl.powerups_on = false
	ctl = _gm_playing(game)
	_gm_step(ctl, ctl.field.powerup_first_s + 1.0)
	_ok(not ctl.field.powerup_enabled and ctl.field.powerup_kind == "", "powerups.enabled false: no item appears")
	ctl.power_notice = false
	ctl.power_sounds = false
	ctl.power_lights = false
	hub = ctl.mock_hub
	lane = ctl.lanes["left"]
	hub.mock_ball(GM_L)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	id = str(lane.capsule.capsule_id)
	var lights_before := _gm_light_modes(hub).size()
	ctl.sounds.log.clear()
	ctl.force_powerup("double")
	ctl.force_powerup("multiball")
	ctl.force_powerup("speed")
	ctl.tick(1.0 / 60.0)
	ctl.field.target_hit.emit(id, "bumper", "bumper_0", Vector2(300, 600))
	_ok(ctl.score.score == 200 and ctl.field.capsule_count() == 3 and ctl.powerups.active("speed"),
		"notice, sounds and lights off: the powers themselves work")
	_ok(ctl.fx._power_notice.text == "" and ctl.fx.power_status.size() == 3, "notice off: no big notice, the small timers stay")
	_ok(not ctl.sounds.log.has("power_double") and not ctl.sounds.log.has("power_multi") and ctl.sounds.pickup_duck() == 0.0,
		"sounds off: no pickup sound, the music is not turned down")
	_ok(_gm_light_modes(hub).size() == lights_before
		and not hub.executed.any(func(e): return e[1] == "SET_DIAL_EFFECT" and e[2].get("target", "") == "FRONT"),
		"lights off: no gold light, no Dial front LED")
	_gm_free(game, rs)
	# ---- the music steps down under a pickup, and back
	var snd := GameModeSounds.new()
	add_child(snd)
	snd.duck(0.5, -8.0)
	var down := snd.pickup_duck()
	snd._process(0.6)
	_ok(down == -8.0 and snd.pickup_duck() == 0.0, "pickup: the music is 8 dB down for its time, then as it was")
	snd.duck(0.0, -8.0)
	snd.duck(1.0, 0.0)
	_ok(snd.pickup_duck() == 0.0, "pickup duck: no time or no dB = nothing")
	snd.queue_free()

## A camera frame: dark grey with a block of `col` covering `share` of it in the middle.
static func _colour_frame(col: Color, share: float, second := Color.TRANSPARENT, second_share := 0.0) -> Image:
	var img := Image.create(80, 60, false, Image.FORMAT_RGB8)
	img.fill(Color(0.18, 0.18, 0.2))
	var side := int(sqrt(share * 80 * 60))
	img.fill_rect(Rect2i(40 - side / 2, 30 - side / 2, side, side), col)
	if second_share > 0.0:
		var s2 := int(sqrt(second_share * 80 * 60))
		img.fill_rect(Rect2i(20, 18, s2, s2), second)
	return img

## #266: one frame's colour, the frames' votes, the values of the kinds, the sprites.
func _test_capsule_colour_read() -> void:
	var red := CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.2))
	var blue := CapsuleKinds.classify(_colour_frame(Color("2860f0"), 0.2))
	var green := CapsuleKinds.classify(_colour_frame(Color("20c040"), 0.2))
	var grey := CapsuleKinds.classify(_colour_frame(Color(0.6, 0.6, 0.62), 0.3))
	var dark_red := CapsuleKinds.classify(_colour_frame(Color(0.15, 0.02, 0.02), 0.3))  # too dark to be sure
	var speck := CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.01))
	var mixed := CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.12, Color("2860f0"), 0.1))
	var none := CapsuleKinds.classify(null)
	_ok(red.kind == "fire" and blue.kind == "water" and green.kind == "green" and grey.kind == "" and dark_red.kind == ""
		and speck.kind == "" and mixed.kind == "" and none.kind == "" and float(red.share) > 0.1,
		"capsule kinds #266: a frame is red (fire), blue (water) or green when that colour fills enough of it; grey, dark, a speck or two colours close together are nothing",
		"%s %s %s %s %s %s %s" % [red, blue, green, grey.kind, dark_red.kind, speck.kind, mixed])
	var r := CapsuleKinds.Reader.new()
	for k in ["fire", "", "fire", "water", "fire", "", "fire"]:
		r.add(k)
		r.advance(0.2)
	var fire_wins: bool = r.decide(3, 0.6) == "fire"  # 4 of the 5 coloured frames
	var r2 := CapsuleKinds.Reader.new()
	r2.add("water")
	r2.add("water")
	var too_few: bool = r2.decide(3, 0.6) == "normal"
	r2.add("green")
	r2.add("green")
	r2.add("water")
	var too_split: bool = r2.decide(3, 0.7) == "normal"  # 3 of 5: not sure enough
	r.advance(r.memory_s + 1.0)
	var forgotten: bool = r.decide(3, 0.6) == "normal" and r.count() == 0
	_ok(fire_wins and too_few and too_split and forgotten,
		"capsule kinds #266: the capsule is the colour most frames saw, when enough of them did and clearly; old frames are forgotten",
		"%s %s %s %s" % [fire_wins, too_few, too_split, forgotten])
	var k := CapsuleKinds.new()
	var defaults_ok: bool = k.of("normal").hit_k == 1.0 and k.of("fire").hit_k > 1.0 and k.of("water").goal_k > 1.0 \
		and k.of("water").gravity_k < 1.0 and k.of("green").bounce > k.of("water").bounce and k.of("nope") == k.of("normal")
	k.configure({"fire": {"hit_k": 99, "gravity_k": 1.5}, "read": {"min_votes": 5}})
	var clamped: bool = k.of("fire").hit_k == 5.0 and k.of("fire").gravity_k == 1.5 and int(k.read.min_votes) == 5 \
		and k.of("water").goal_k == 2.0
	var tex := CapsuleKinds.sheet("fire")
	var sprites: bool = tex != null and tex.get_width() == CapsuleKinds.FRAME * 8 and tex.get_height() == CapsuleKinds.FRAME * 2 \
		and CapsuleKinds.sheet("water") != null and CapsuleKinds.sheet("green") != null and CapsuleKinds.sheet("normal") == null
	var names: bool = CapsuleKinds.display_name("fire") == "ファイヤーボールカプセル" and CapsuleKinds.display_name("water") == "ウォーターボールカプセル" \
		and CapsuleKinds.display_name("green") == "グリーンボールカプセル"
	_ok(defaults_ok and clamped and sprites and names,
		"capsule kinds #266: each kind has its own values (config overrides them, kept in range), its name and an 8-frame pixel-art sprite sheet (the capsule, which turns with the ball, and the kind's upright part)",
		"%s %s %s %s" % [defaults_ok, clamped, sprites, names])

## #266: the kind in the round: read from the arm camera, shown, played and scored.
func _test_capsule_kinds_game(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	var frame := _colour_frame(Color("e83020"), 0.2)
	var frames := [0]
	ctl.colour_source = func() -> Image:
		frames[0] += 1
		return frame
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	game._unhandled_input(_key(KEY_ENTER))
	game._unhandled_input(_key(KEY_ENTER))
	var title_no_read: bool = frames[0] == 0  # nothing is read before the round takes capsules
	_gm_step(ctl, ctl.countdown_s + 0.2)
	_gm_step(ctl, 1.0)
	var read_some: bool = frames[0] >= 4 and frames[0] <= 8 and ctl.colour_reader.count("fire") >= 4  # about sample_hz a second
	var l: GameModeController.Lane = ctl.lanes["left"]
	ctl.kinds.params["fire"]["hit_k"] = 3.0
	game._unhandled_input(_key(KEY_Z))
	var c: Dictionary = l.capsule
	var kind_set: bool = l.state == "ABSORBING" and str(c.kind) == "fire" and ctl.last_kind == "fire" and ctl.colour_reader.count() == 0
	var show_kind: bool = not ctl.fx.collects().is_empty() and str(ctl.fx.collects()[0].kind) == "fire"
	_gm_step(ctl, ctl.absorb_s * GameModeVFX.COLLECT_RISE * 0.5)
	var no_sound_yet: bool = not ctl.sounds.log.has("reveal_fire")
	_gm_step(ctl, ctl.absorb_s * GameModeVFX.COLLECT_RISE)
	var sound: bool = no_sound_yet and ctl.sounds.log.count("reveal_fire") == 1 and not ctl.sounds.log.has("reveal")
	var files: bool = GameModeSounds.OWN_FILES.keys().all(func(k): return ctl.sounds.source_of(k) == "file")
	sound = sound and files  # the magic sounds of 効果音ラボ (se/), not synthesised
	show_kind = show_kind and sound
	# #277: the shelf's light in the capsule's colour as it comes up big, a flash as UFOくん
	# shines, the round's light again once it has dropped
	var lights_of := func() -> Array:
		return ctl.mock_hub.executed.filter(func(e): return e[0] == GameModeDevices.ILLUMINATION and e[1] == "SET_LIGHT_MODE")
	var fc: Color = CapsuleKinds.COLORS["fire"]
	var custom: Array = lights_of.call()
	var light_in: bool = not custom.is_empty() and str(custom[-1][2].mode) == "CUSTOM" \
		and custom[-1][2].color == [int(round(fc.r * 255.0)), int(round(fc.g * 255.0)), int(round(fc.b * 255.0))]
	var flashes_before: int = ctl.mock_hub.count(GameModeDevices.ILLUMINATION, "TRIGGER_EFFECT")
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.1)
	var after: Array = lights_of.call()
	var light_back: bool = str(after[-1][2].mode) != "CUSTOM" and after.size() > custom.size() \
		and ctl.mock_hub.count(GameModeDevices.ILLUMINATION, "TRIGGER_EFFECT") == flashes_before + 1
	show_kind = show_kind and light_in and light_back
	var id: String = str(c.capsule_id)
	var on_field: bool = l.state == "SIMULATING" and ctl.field.capsule_kind(id) == "fire" \
		and ctl.field.capsule_color(id) == CapsuleKinds.COLORS["fire"]
	var body: RigidBody2D = ctl.field._capsules[id].body
	var physics: bool = absf(body.gravity_scale - ctl.field.gravity_scale * ctl.kinds.of("fire").gravity_k) < 0.05 \
		and is_equal_approx(body.physics_material_override.bounce, ctl.kinds.of("fire").bounce) \
		and is_equal_approx(body.linear_damp, ctl.kinds.of("fire").damp)
	ctl.particles.clear()
	_gm_step(ctl, 0.2)
	var trail: bool = ctl.particles.sparks() > 0
	var before: int = int(c.score)
	var total_before: int = ctl.score.score
	ctl.field.target_hit.emit(id, "bumper", "bumper_0", ctl.field.capsule_position(id))
	var gained: int = int(c.score) - before
	# the round's own score (the result, the ranking) gets the same points (review on #268)
	var scored: bool = gained > 0 and gained % 3 == 0 and ctl.score.score - total_before == gained
	var made: Array[String] = ctl.field.split_capsule(id, ["k1", "k2"] as Array[String])
	var children: bool = made.size() == 2 and ctl.field.capsule_kind("k1") == "fire" and ctl.field.capsule_kind("k2") == "fire"
	ctl.field.remove_capsule("k1")
	ctl.field.remove_capsule("k2")
	_ok(title_no_read and read_some and kind_set and show_kind and on_field and physics and trail and scored and children,
		"capsule kinds #266: the arm camera is read while the round takes capsules; the capsule taken in is the colour it saw (red = fire): the show (with its own sound as it comes up big, the shelf's light in its colour, #277), the field's colour and sprite, its physics, its particles and its points (hit_k) follow it, and a multiball's balls are the same kind",
		"%s %s %s %s %s %s %s %s(%d) %s" % [title_no_read, read_some, kind_set, show_kind, on_field, physics, trail, scored, gained, children])
	# nothing sure (grey frames): a normal capsule, as ever; off: always normal
	ctl.colour_source = func() -> Image: return _colour_frame(Color(0.5, 0.5, 0.5), 0.3)
	ctl.colour_reader.clear()
	_gm_step(ctl, 1.0)
	var plain: bool = ctl.decide_kind() == "normal"
	ctl.colour_source = func() -> Image: return _colour_frame(Color("2860f0"), 0.25)
	ctl.colour_reader.clear()
	_gm_step(ctl, 1.0)
	var water: bool = ctl.decide_kind() == "water"
	ctl.kinds_enabled = false
	var off: bool = ctl.decide_kind() == "normal"
	ctl.kinds_enabled = true
	# no camera, mock Dials: mock_kind (the rehearsal shows the kinds); with frames, never
	ctl.colour_source = Callable()
	ctl.colour_reader.clear()
	ctl.mock_kind = "green"
	var mock_green: bool = ctl.decide_kind() == "green"
	ctl.mock_kind = "random"
	var random_one: bool = ctl.decide_kind() in ["fire", "water", "green"]
	ctl.mock_kind = "normal"
	var mock_plain: bool = ctl.decide_kind() == "normal"
	_ok(plain and water and off and mock_green and random_one and mock_plain,
		"capsule kinds #266: frames with no clear colour make a normal capsule; blue makes water; switched off always normal; with no camera and mock Dials the config's mock_kind (random by default)",
		"%s %s %s %s %s %s" % [plain, water, off, mock_green, random_one, mock_plain])
	_gm_free(game, rs)

## #291: a frame `w` x `h` of `bg`, with blocks [Rect2i, Color] painted on it.
static func _probe_frame(blocks: Array, bg := Color(0.18, 0.18, 0.2), w := 80, h := 60) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(bg)
	for b in blocks:
		img.fill_rect(b[0], b[1])
	return img

## #291: classify() says why; the thresholds' edges; background LEDs; the votes' window and reset.
func _test_capsule_colour_explain() -> void:
	var red := CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.2), {}, true)
	var grey := CapsuleKinds.classify(_colour_frame(Color(0.6, 0.6, 0.62), 0.3))
	var dark := CapsuleKinds.classify(_colour_frame(Color(0.15, 0.02, 0.02), 0.3))
	var violet := CapsuleKinds.classify(_colour_frame(Color.from_hsv(0.8, 0.9, 0.9), 0.3))  # in no colour's range
	var speck := CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.01))
	var mixed := CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.12, Color("2860f0"), 0.1))
	var none := CapsuleKinds.classify(null)
	var reasons: bool = red.reason == "ok" and grey.reason == "dull" and dark.reason == "dull" and violet.reason == "hue" \
		and speck.reason == "small" and mixed.reason == "dominance" and none.reason == "no_frame" and violet.kind == "" \
		and {mixed.best: 1, mixed.second: 1}.keys().size() == 2 and int(mixed.best_n) >= int(mixed.second_n) and int(mixed.second_n) > 0 and not mixed.dominance_ok and mixed.share_ok
	# every looked-at pixel is counted once, the left-out ones are in the share's denominator
	var looked := int(red.looked)
	var parts: int = int(red.low_sat) + int(red.low_val) + int(red.hue_miss) + int(red.counts.fire) + int(red.counts.water) + int(red.counts.green)
	var hist_n := 0
	for c in red.hue_hist:
		hist_n += c
	var sums: bool = parts == looked and is_equal_approx(float(red.shares.fire), float(red.counts.fire) / looked) \
		and is_equal_approx(float(red.share), float(red.shares.fire)) and red.samples.size() == looked \
		and int(red.cols) * int(red.rows) == looked and hist_n == looked - int(red.low_sat) - int(red.low_val) \
		and int(red.roi_pixels) == red.roi.size.x * red.roi.size.y
	var same_kind: bool = CapsuleKinds.classify(_colour_frame(Color("e83020"), 0.2)).kind == red.kind  # detail changes nothing
	_ok(reasons and sums and same_kind,
		"capsule probe #291: classify() says why a frame is no colour (too grey / dark, no colour's hue, too small, not dominant, no frame); every looked-at pixel is counted once and the share's denominator has the left-out ones",
		"%s %s %s / %s %s %s %s %s %s" % [reasons, sums, same_kind, grey.reason, dark.reason, violet.reason, speck.reason, mixed.reason, parts])
	# the edges: a threshold met exactly passes, a hair more does not
	var img := _colour_frame(Color("e83020"), 0.2)
	var at_share: bool = CapsuleKinds.classify(img, {"min_share": float(red.share)}).kind == "fire"
	var over_share := CapsuleKinds.classify(img, {"min_share": float(red.share) + 0.001})
	var d := float(mixed.best_n) / float(mixed.second_n)
	var mix_img := _colour_frame(Color("e83020"), 0.12, Color("2860f0"), 0.1)
	var at_dom: bool = CapsuleKinds.classify(mix_img, {"dominance": d - 1e-9}).kind == str(mixed.best)  # (d * second_n may round past best_n)
	var over_dom := CapsuleKinds.classify(mix_img, {"dominance": d + 0.01})
	var flat := _probe_frame([], Color.from_hsv(0.6, 0.5, 0.6))
	var p := flat.get_pixel(40, 30)
	var at_sat: bool = CapsuleKinds.classify(flat, {"min_sat": p.s, "min_val": p.v}).kind == "water"
	var over_sat := CapsuleKinds.classify(flat, {"min_sat": p.s + 0.001})
	var over_val := CapsuleKinds.classify(flat, {"min_val": p.v + 0.001})
	# red wraps round 1.0: just under and just over are both red; cyan is not
	var wrap: bool = CapsuleKinds.classify(_probe_frame([], Color.from_hsv(0.97, 0.9, 0.9))).kind == "fire" \
		and CapsuleKinds.classify(_probe_frame([], Color.from_hsv(0.02, 0.9, 0.9))).kind == "fire" \
		and CapsuleKinds.classify(_probe_frame([], Color.from_hsv(0.48, 0.9, 0.9))).reason == "hue"
	var edges: bool = at_share and over_share.kind == "" and over_share.reason == "small" and at_dom and over_dom.reason == "dominance" \
		and at_sat and over_sat.reason == "dull" and int(over_sat.low_sat) == int(over_sat.looked) \
		and over_val.reason == "dull" and int(over_val.low_val) == int(over_val.looked) and wrap
	_ok(edges, "capsule probe #291: min_share, dominance, min_sat and min_val met exactly pass, a hair more do not; red's hue range wraps round 1.0",
		"%s %s %s %s %s %s %s %s" % [at_share, over_share.reason, at_dom, over_dom.reason, at_sat, over_sat.reason, over_val.reason, wrap])
	# background LEDs: a big bright strip outside the ROI is never looked at; small LED dots
	# inside it stay under min_share; the capsule wins over a few of them
	var strip := _probe_frame([[Rect2i(0, 0, 80, 8), Color("20ff40")]])  # the ROI starts at 15% (y 9)
	var dots := []
	for i in 6:
		dots.append([Rect2i(20 + i * 7, 12 + (i % 3) * 14, 1, 1), Color("20ff40")])
	var leds := _probe_frame(dots)
	var with_capsule := _probe_frame(dots + [[Rect2i(30, 22, 18, 18), Color("2860f0")]])
	var led_ok: bool = CapsuleKinds.classify(strip).kind == "" and int(CapsuleKinds.classify(strip).counts.green) == 0 \
		and CapsuleKinds.classify(leds).kind == "" and CapsuleKinds.classify(with_capsule).kind == "water"
	_ok(led_ok, "capsule probe #291: shelf LEDs outside the ROI are not looked at, a few small LED dots inside it are too little, a capsule among them still wins",
		"%s %s %s" % [CapsuleKinds.classify(strip).counts, CapsuleKinds.classify(leds).reason, CapsuleKinds.classify(with_capsule).kind])
	# the votes: why, the window's edge, the reset
	var r := CapsuleKinds.Reader.new()
	var empty: bool = r.explain(3, 0.6).reason == "no_votes" and r.cleared_at < 0.0
	r.add("fire")
	r.add("")
	r.add("fire")
	var few := r.explain(3, 0.6)
	r.add("water")
	r.add("water")
	r.add("fire")
	var split := r.explain(3, 0.6)  # 3 of 5 coloured = 0.6: just enough
	var split_more := r.explain(3, 0.61)
	r.advance(r.memory_s)
	var at_edge: bool = r.count() == 5 and r.count("") == 1  # exactly memory_s old still counts
	r.advance(0.01)
	var gone: bool = r.count() == 0 and r.explain(3, 0.6).reason == "no_votes"
	r.add("green")
	r.clear()
	var reset: bool = r.count() == 0 and r.votes.is_empty() and is_equal_approx(r.cleared_at, r.clock)
	var votes_ok: bool = empty and few.reason == "few_votes" and int(few.none) == 1 and int(few.counts.fire) == 2 \
		and split.kind == "fire" and split.reason == "ok" and split_more.reason == "ratio" and split_more.kind == "normal" \
		and r.decide(3, 0.6) == "normal" and at_edge and gone and reset
	_ok(votes_ok, "capsule probe #291: the votes say why the capsule is normal (no votes, too few, too split); a vote exactly memory_s old counts, older ones not; a reset forgets all and says when",
		"%s %s %s %s %s %s %s" % [empty, few, split.reason, split_more.reason, at_edge, gone, reset])

## #291: the probe screen: the game's values and verdicts, pause and judge again, stale frames,
## the export, the round's reading, and nothing sent.
func _test_capsule_colour_probe(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	var probe: CapsuleColourProbe = game.capsule_probe
	probe.dir = "user://capsule_probe_test/"
	var n := [0]
	var col := [Color("e83020")]
	# a new picture each time (one pixel changes, as a real camera's noise)
	probe.frame_source = func() -> Image:
		n[0] += 1
		var img := _colour_frame(col[0], 0.2)
		img.set_pixel(0, 0, Color(float(n[0] % 7) / 10.0, 0.1, 0.1))
		return img
	var sent_before: int = game.ws._seq
	var read_before: Dictionary = ctl.kinds.read.duplicate(true)
	var closed_idle: bool = not probe.active() and not probe.is_processing()
	probe.open()
	var starts_as_game: bool = probe.cfg == ctl.kinds.read and probe.memory_s == ctl.colour_reader.memory_s
	for i in 60:
		probe.tick(1.0 / 60.0)
	var voted: int = probe.reader.count("fire")
	var same: bool = probe.result.kind == "fire" and probe.result.kind == CapsuleKinds.classify(probe.frame, ctl.kinds.read).kind \
		and probe.base_result.kind == "fire" and voted >= 4 and voted <= 8 \
		and probe.reader.explain(int(probe.cfg.min_votes), float(probe.cfg.min_ratio)).kind == "fire"
	var text_ok: bool = probe.numbers_text().contains("色ごと") and probe.numbers_text().contains("min_share") \
		and probe.votes_text().contains("最終判定: fire")
	_ok(closed_idle and starts_as_game and same and text_ok,
		"capsule probe #291: closed it does nothing; opened it starts with the game's values and judges the arm camera's frames with the game's classify() and votes (same verdict)",
		"%s %s %s %s %d" % [closed_idle, starts_as_game, same, text_ok, voted])
	# pause: no new frames; a changed value judges the same picture again, without a vote
	probe.set_paused(true)
	var frames_before: int = n[0]
	for i in 60:
		probe.tick(1.0 / 60.0)
	var held: bool = n[0] == frames_before and probe.reader.count("fire") == voted
	probe.set_value("min_share", 0.9)
	var rejudged: bool = probe.result.kind == "" and probe.result.reason == "small" and probe.base_result.kind == "fire" \
		and probe.reader.count("fire") == voted and n[0] == frames_before
	var game_untouched: bool = ctl.kinds.read == read_before and probe.base_cfg == read_before
	probe.set_value("hue:fire:0", 0.9)
	probe.set_value("roi:2", 0.3)
	var odd_keys: bool = float(probe.cfg.hues.fire[0]) == 0.9 and float(probe.cfg.roi[2]) == 0.3 and ctl.kinds.read == read_before
	var votes_before: int = probe.reader.votes.size()
	probe.step_frame()
	var one_more: bool = n[0] == frames_before + 1 and probe.reader.votes.size() == votes_before + 1
	probe.reset_settings()
	var reset: bool = probe.cfg == read_before and probe.result.kind == "fire"
	# the votes' window moves on while paused: the screen says so (review on #293)
	var shown_before: String = probe._votes.text
	probe.set_paused(true)
	for i in int((probe.memory_s + 1.0) * 60.0):
		probe.tick(1.0 / 60.0)
	var expired: bool = probe.reader.count() == 0 and probe._votes.text.contains("色を見たフレームがない") \
		and shown_before != probe._votes.text
	# the game's values vote at the game's rate, whatever rate is tried (review on #293)
	probe.set_paused(false)
	probe.clear_votes()
	probe.set_value("sample_hz", 1.0)
	for i in 120:
		probe.tick(1.0 / 60.0)
	var rates_own: bool = probe.reader.votes.size() <= 3 and probe.base_reader.votes.size() >= 10 \
		and float(probe.base_cfg.sample_hz) == float(ctl.kinds.read.sample_hz)
	probe.reset_settings()
	reset = reset and expired and rates_own
	_ok(held and rejudged and game_untouched and odd_keys and one_more and reset,
		"capsule probe #291: paused, no frame is taken; a changed value judges the same frame again at once (no vote) and never reaches the game; 1 フレーム takes one; 戻す brings the game's values back; the votes' window moves on while paused; the game's values vote at the game's rate",
		"%s %s %s %s %s %s" % [held, rejudged, game_untouched, odd_keys, one_more, reset])
	# a still picture (the same frame again), no picture, no camera: never voted, shown as such
	var still := _colour_frame(Color("2860f0"), 0.2)
	probe.frame_source = func() -> Image: return still
	probe.step_frame()
	var votes_n: int = probe.reader.votes.size()
	probe.step_frame()
	var stale: bool = probe.frame_info.status == "stale" and probe.reader.votes.size() == votes_n \
		and probe.numbers_text().contains("未更新")
	probe.frame_source = func() -> Image: return null
	probe.step_frame()
	var failed: bool = probe.frame_info.status == "failed" and probe.frame == null and probe.result.reason == "no_frame" \
		and probe.reader.votes.size() == votes_n
	probe.frame_source = Callable()
	probe.step_frame()
	var no_cam: bool = probe.frame_info.status in ["no_camera", "headless"] and probe.frame == null \
		and probe.reader.votes.size() == votes_n
	_ok(stale and failed and no_cam,
		"capsule probe #291: a frame that did not change, a failed read and no camera are shown as such and never voted",
		"%s %s %s %s" % [stale, failed, no_cam, probe.frame_info])
	# the export: one JSON line per judged frame, with the label; the tally per label
	probe.frame_source = func() -> Image:
		n[0] += 1
		var img := _colour_frame(col[0], 0.2)
		img.set_pixel(0, 0, Color(float(n[0] % 7) / 10.0, 0.1, 0.1))
		return img
	probe.tally.clear()
	probe.set_label("fire")
	probe.set_recording(true)
	for i in 3:
		probe.step_frame()
	col[0] = Color(0.5, 0.5, 0.5)
	probe.step_frame()
	probe.set_recording(false)
	var lines: Array = []
	var f := FileAccess.open(probe.export_path, FileAccess.READ)
	while f != null and not f.eof_reached():
		var t := f.get_line()
		if t != "":
			lines.append(JSON.parse_string(t))
	var l0: Dictionary = lines[0] if lines.size() > 0 and lines[0] is Dictionary else {}
	var exported: bool = lines.size() == 4 and str(l0.get("label")) == "fire" and str(l0.result.kind) == "fire" \
		and l0.has("time") and int(l0.image.w) == 80 and l0.camera.status == "live" and l0.settings.read.has("min_share") \
		and l0.result.has("low_sat") and l0.result.roi is Array and l0.votes.has("counts") and l0.has("final") \
		and l0.base.kind == "fire" and not l0.result.has("samples") and l0.has("game") and str(lines[3].result.reason) == "dull"
	var rate := probe.rates("fire")
	var tallied: bool = rate.n == 4 and rate.right == 3 and rate.undecided == 1 and rate.wrong == 0 and probe.tally_text().contains("赤のカプセル 4")
	var saved := probe.save_settings()
	var saved_ok: bool = saved != "" and JSON.parse_string(FileAccess.get_file_as_string(saved)) is Dictionary
	var png := probe.save_image()
	var png_ok: bool = png != "" and FileAccess.file_exists(png)
	# the saved picture again (paused, judged once): the same verdict
	png_ok = png_ok and probe.load_image(png) and probe.paused and probe.frame_info.status == "file" \
		and probe.result.kind == "" and not probe.load_image(probe.dir.path_join("nothing.png")) and probe.frame == null
	probe.set_paused(false)
	_ok(exported and tallied and saved_ok and png_ok,
		"capsule probe #291: recording writes one JSON line per judged frame (time, size, camera, values, counts, verdicts, votes, final, label); the tally counts right / undecided / wrong per label; the tried values and an image are saved only by their buttons, and a saved image can be judged again",
		"%s %s %s %s %d %s" % [exported, tallied, saved_ok, png_ok, lines.size(), rate])
	for file in DirAccess.get_files_at(probe.dir):
		DirAccess.remove_absolute(probe.dir.path_join(file))
	# with a round: the game's own reading shows (read only) and the probe agrees with it
	var gframe := _colour_frame(Color("20c040"), 0.2)
	ctl.colour_source = func() -> Image: return gframe
	probe.close()  # the round is started with the keys (the probe takes them while open)
	_gm_playing(game)
	_gm_step(ctl, 1.0)
	probe.open()
	var st := ctl.colour_status()
	var status_ok: bool = st.active and st.reading and int(st.votes.counts.green) >= 4 and str(st.last.kind) == "green" \
		and str(st.votes.kind) == ctl.decide_kind() and probe.game_text().contains("読取中")
	var agree: bool = CapsuleKinds.classify(gframe, probe.cfg).kind == str(st.last.kind)
	# the probe covers the screen: the game's keys do not reach behind it; Esc closes it
	game._unhandled_input(_key(KEY_Z))
	var swallowed: bool = ctl.colour_status().events.is_empty() and probe.active()
	game._unhandled_input(_key(KEY_ESCAPE))
	var esc_closes: bool = not probe.active() and swallowed
	game._unhandled_input(_key(KEY_Z))
	var st2 := ctl.colour_status()
	var decided: bool = not st2.events.is_empty() and st2.events[-1][1] == "decided" and st2.events[-1][2] == "green" \
		and int(st2.votes.any) == 0 and float(st2.cleared_at) >= 0.0 and probe.game_text().contains("確定")
	var nothing_sent: bool = game.ws._seq == sent_before
	probe.close()
	var closed: bool = not probe.active() and not probe.is_processing()
	_ok(status_ok and agree and decided and nothing_sent and closed and esc_closes,
		"capsule probe #291: with a round the probe shows the game's reading (reading or not, votes, last frame, reset and decision); its verdict agrees; it never sends a command; the game's keys do not reach behind it and Esc closes it",
		"%s %s %s %s %s %s" % [status_ok, agree, decided, nothing_sent, closed, esc_closes])
	ctl.colour_source = Callable()
	_gm_free(game, rs)
