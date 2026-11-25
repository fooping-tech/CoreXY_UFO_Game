class_name EasyModeControl
extends RefCounted
## The score game's easy mode (#169): what the hand's shapes mean while it is on.
##
##   pinch and move        XY (the hand stick, as ever; nothing of this script)
##   a fist held hold_s    catch here by itself          -> the backend's `easy_grab`
##                         and then carry it to the portal (Dial 1, on the left) by itself
##                         -> `easy_deliver {destination: 1}` (#266: no finger to show any more)
##   (#200: the portal is on the left only. #266: one finger and two mean nothing.)
##
##   OFF -> MANUAL_XY --fist--> AUTO_GRAB --(the backend caught)--> WAIT_DESTINATION
##       --(at once, #266)--> DELIVER_DIAL_1 --(the backend delivered)--> MANUAL_XY
##   The carry is asked for by this script as soon as the backend waits for it (the fist was
##   the player's choice of both). It is still new motion: not while the gate is closed or the
##   round takes nothing; a refusal is tried again auto_retry_s later, auto_tries times at most,
##   then the wait runs out like before (EXPIRED: nothing moves, staff).
##   MANUAL_XY --request_reset() (a game starts)--> RESET --(the backend: claw open, arm at
##       the top)--> MANUAL_XY. The easy mode cannot raise the arm by hand, so every game
##       starts from there (#177). A fist with the arm down needs nothing here: the backend's
##       `easy_grab` then closes the claw where it is and brings it up.
##   WAIT_DESTINATION --an open hand kept up for cancel_hold_s--> CANCEL --(the backend
##       opened the claw)--> MANUAL_XY (#179: the claw came up empty: let go and try again).
##       The short open hand between the fist and the fingers is not that: it must be kept up.
##   anything wrong (a fault, a stop, the link, no answer, nobody chose in time) --> FAULT:
##   nothing starts again by itself; reset() (a new round, or staff) leaves it.
##
## Pure logic. It moves nothing: the sequence runs in the backend, which holds the motion
## lock and checks everything; this only asks for it, once per sign, and follows the
## backend's own report (RobotState.easy_mode). It is fed a snapshot of the hand (already
## judged by GestureControl: event order, staleness, the camera, one hand only) and of the
## world every physics tick. Its state is its own: not RobotState, not GameState, not the
## round's phase.
##
## A sign counts once: after any request, and after a run ended, the hand must show a
## neutral shape (パー, or a pinch) before the next sign is read. A sign must be held
## without a break for hold_s; another shape, a lost hand, two hands, a stale event or a
## lost camera start it over. The fingers are read only while the backend waits for the
## destination of the catch this script asked for (its grab_id), so a late or repeated
## sign can never carry twice. A finished delivery means the claw opened over the Dial,
## not that a capsule landed: that is the Dial's own BALL_RECEIVED, the score game's business.
##
## The hand snapshot (`hand`):
##   fresh / camera_ok / detected   an event within the stale time, of one hand in view
##   pose / pinch                   the shape, the pinch
##   steering                       the hand stick is arming or steering, or a jog is still out
## The world snapshot (`world`):
##   enabled   the easy mode is on (the score game is open, difficulty easy, usable)
##   taking    the round takes capsules now (PLAYING, or the practice capsule)
##   link      the backend's link is open
##   gate      "" when the hand may ask the robot to move now, else why not (a catch and a
##             carry are both new motion: neither sign is read while it is closed)
##   status    the backend's report (RobotState.easy_mode)

signal state_changed(from: String, to: String)
## The backend said the delivery to Dial `destination` (1, the only one) ended. Not "a capsule landed".
signal delivered(destination: int)
## For the sounds and UFOくん: "grab" / "caught" / "deliver" / "done" / "refused" / "fault"
signal cue(name: String)

const STATES := ["OFF", "MANUAL_XY", "RESET", "AUTO_GRAB", "WAIT_DESTINATION", "DELIVER_DIAL_1", "CANCEL", "FAULT"]
const SIGN_OF := {"fist": "grab", "thumb": "grab"}

## how long a sign must be held, unbroken (config game_mode.easy.hold_s)
var hold_s := 0.6
## how long the open hand must be kept up, while waiting for the destination, to give the
## catch up (config game_mode.easy.cancel_hold_s)
var cancel_hold_s := 1.5
## how long the neutral shape must be seen before the next sign counts
var neutral_s := 0.2
## no answer to a request for this long: FAULT (the request is never sent again)
var request_timeout_s := 3.0
## a refused carry is asked for again after this long, this many times in all (config
## game_mode.easy.auto_retry_s / auto_tries)
var auto_retry_s := 1.0
var auto_tries := 3
## Sends a backend command: func(name: String, params: Dictionary) -> String (the request
## id; "" = it could not be sent).
var send: Callable

var state := "OFF"
## why the last sign was not taken, or why it stopped (for the screen; "" = nothing)
var note := ""
## the sign building up now ("" / "grab" / "cancel") and its hold, 0..1
var holding := ""
var progress := 0.0
## the hand must show the neutral shape before a sign counts
var need_neutral := true
var destination := 0
var grab_id := ""
## the backend's step and the time left to choose, for the screen
var step := ""
var wait_left_s := 0.0
var wait_s := 15.0
## how many requests went out (the tests count them)
var resets_sent := 0
var grabs_sent := 0
var cancels_sent := 0
var delivers_sent := 0
## carries asked for for this catch, and the time until the next may be
var _tries := 0
var _retry_left := 0.0

var _hold := 0.0
var _neutral := 0.0
var _rid := ""
var _rid_what := ""
var _rid_left := 0.0
## a catch asked for and then stopped before its answer came: if the answer says it
## started after all, it is stopped again
var _stopped_rid := ""

func configure(cfg: Dictionary) -> void:
	hold_s = clampf(float(cfg.get("hold_s", hold_s)), 0.2, 5.0)
	cancel_hold_s = clampf(float(cfg.get("cancel_hold_s", cancel_hold_s)), 0.5, 10.0)
	neutral_s = clampf(float(cfg.get("neutral_s", neutral_s)), 0.05, 2.0)
	request_timeout_s = clampf(float(cfg.get("request_timeout_s", request_timeout_s)), 0.5, 30.0)
	wait_s = float(cfg.get("wait_destination_s", wait_s))
	auto_retry_s = clampf(float(cfg.get("auto_retry_s", auto_retry_s)), 0.2, 10.0)
	auto_tries = clampi(int(cfg.get("auto_tries", auto_tries)), 1, 10)

func enabled() -> bool:
	return state != "OFF"

## The backend's sequence is (or is about to be) running for this script: the hand and
## the keys do not move the crane meanwhile.
func busy() -> bool:
	return state in ["RESET", "AUTO_GRAB", "WAIT_DESTINATION", "DELIVER_DIAL_1", "CANCEL"]

func faulted() -> bool:
	return state == "FAULT"

## Space (the stop key): whatever this script asked for is over, now. The stop itself
## (soft_stop: the backend ends its sequence with ABORT) is the caller's to send.
func on_stop() -> void:
	if not busy():
		return
	var pending := _rid if _rid_what in ["grab", "reset"] else ""
	_fault("ストップした")
	_stopped_rid = pending

## A game starts (the practice, the countdown): the backend is asked to bring the arm to
## its start (the claw open, the arm at the top), whatever height it was left at. Only from
## MANUAL_XY, once per call; a refusal (not calibrated, an alarm, ...) is only said. Returns
## true when the request went out.
func request_reset() -> bool:
	if state != "MANUAL_XY" or not send.is_valid():
		return false
	var rid := str(send.call("easy_reset", {}))
	if rid == "":
		return false
	resets_sent += 1
	_forget()
	note = ""
	_rid = rid
	_rid_what = "reset"
	_rid_left = request_timeout_s
	_set_state("RESET")
	return true

## A new round, or staff: out of FAULT. Nothing is sent; the backend still refuses
## whatever is not in order (an alarm, no homing, ...), and the hand starts from neutral.
func reset() -> void:
	if state == "OFF":
		return
	_forget()
	note = ""
	_set_state("MANUAL_XY")

func _forget() -> void:
	_rid = ""
	_rid_what = ""
	_rid_left = 0.0
	_hold = 0.0
	_neutral = 0.0
	holding = ""
	progress = 0.0
	need_neutral = true
	destination = 0
	grab_id = ""
	step = ""
	wait_left_s = 0.0
	_tries = 0
	_retry_left = 0.0

func _set_state(s: String) -> void:
	if s == state:
		return
	var from := state
	state = s
	state_changed.emit(from, s)

func _fault(why: String) -> void:
	_forget()
	note = why
	if state != "FAULT":
		_set_state("FAULT")
		cue.emit("fault")

## What the hand shows, for this script: "grab" / "neutral" / "" (nothing that
## can be judged: no hand, a stale event, the camera gone, another shape).
static func sign_of(hand: Dictionary) -> String:
	if not bool(hand.get("fresh", false)) or not bool(hand.get("camera_ok", false)) or not bool(hand.get("detected", false)):
		return ""
	if bool(hand.get("pinch", false)):
		return "neutral"  # a pinch is the hand stick's: never a fist, never a number
	var pose := str(hand.get("pose", ""))
	if pose == "open":
		return "neutral"
	return str(SIGN_OF.get(pose, ""))

## The answer to a request (the WebSocket client's ack signal: also a refusal, a timeout,
## a closed socket).
func on_ack(rid: String, ok: bool, data: Dictionary) -> void:
	if rid != "" and rid == _stopped_rid:
		_stopped_rid = ""
		if ok and send.is_valid():
			send.call("soft_stop", {})  # the stop overtook the request: it must not run on
		return
	if rid == "" or rid != _rid:
		return
	var what := _rid_what
	_rid = ""
	_rid_what = ""
	var reason := str(data.get("reason", ""))
	if what == "reset":
		if state != "RESET":
			return
		if ok and str(data.get("grab_id", "")) != "":
			grab_id = str(data.grab_id)  # this run's id: its report is followed like a catch's
		elif ok or reason in ["timeout", "socket_closed"]:
			_fault("じゅんびの へんじが こない（%s）" % (reason if reason != "" else "?"))
		else:
			# refused before anything moved: the hand has the crane; why is said
			_forget()
			note = refusal_text(reason)
			_set_state("MANUAL_XY")
	elif what == "grab":
		if state != "AUTO_GRAB":
			return
		if ok and str(data.get("grab_id", "")) != "":
			grab_id = str(data.grab_id)
		elif ok:
			_fault("バックエンドの へんじが おかしい（grab_id がない）")
		elif reason in ["timeout", "socket_closed"]:
			# was it started? Not known: never asked again by itself
			_fault("キャッチの へんじが こない（%s）" % reason)
		else:
			# refused before anything moved: back to the hand, with the reason; a new sign is needed
			_forget()
			note = refusal_text(reason)
			_set_state("MANUAL_XY")
			cue.emit("refused")
	elif what == "cancel":
		if state != "CANCEL":
			return
		if ok:
			return  # the backend's report says the rest
		if reason in ["timeout", "socket_closed"]:
			_fault("やりなおしの へんじが こない（%s）" % reason)
		else:
			need_neutral = true
			note = refusal_text(reason)
			_set_state("WAIT_DESTINATION")
			cue.emit("refused")
	elif what == "deliver":
		if not state.begins_with("DELIVER_DIAL_"):
			return
		if ok:
			return  # the backend's report says the rest
		if reason in ["timeout", "socket_closed"]:
			_fault("はこぶ へんじが こない（%s）" % reason)
		else:
			# refused: the backend is still waiting (or has just given up: its report says so).
			# Asked again auto_retry_s later, while tries are left (#266).
			destination = 0
			need_neutral = true
			_retry_left = auto_retry_s
			note = refusal_text(reason)
			_set_state("WAIT_DESTINATION")
			cue.emit("refused")

## One physics tick.
func tick(dt: float, hand: Dictionary, world: Dictionary) -> void:
	if not bool(world.get("enabled", false)):
		if busy() and send.is_valid():
			# left in the middle (the title, the mode switched off): the crane must not go on
			# alone. soft_stop ends the backend's sequence in its safe state (ABORT).
			send.call("soft_stop", {})
			if _rid_what in ["grab", "reset"]:
				_stopped_rid = _rid
		if state != "OFF":
			_forget()
			note = ""
			_set_state("OFF")
		return
	if state == "OFF":
		_forget()
		note = ""
		_set_state("MANUAL_XY")
	var sgn := sign_of(hand)
	if sgn == "neutral":
		_neutral += dt
		if _neutral >= neutral_s:
			need_neutral = false
	else:
		_neutral = 0.0
	if _rid != "":
		_rid_left -= dt
		if _rid_left <= 0.0:
			var what := _rid_what
			_rid = ""
			_rid_what = ""
			_fault("%sの へんじが こない" % {"grab": "キャッチ", "reset": "じゅんび", "cancel": "やりなおし"}.get(what, "はこぶ"))
			return
	var status: Dictionary = world.get("status", {}) if world.get("status") is Dictionary else {}
	var link := bool(world.get("link", false))
	match state:
		"MANUAL_XY":
			_tick_manual(dt, sgn, hand, world, status)
		"RESET", "AUTO_GRAB":
			if not link:
				_fault("つうしんが きれた")
			elif grab_id != "":
				_follow(status)
				if state == "WAIT_DESTINATION":
					_tick_wait(dt, sgn, hand, world)  # #266: the carry is asked for in the same tick
		"WAIT_DESTINATION":
			if not link:
				_fault("つうしんが きれた")
			else:
				_follow(status)
				if state == "WAIT_DESTINATION":
					_tick_wait(dt, sgn, hand, world)
		"DELIVER_DIAL_1", "CANCEL":
			if not link:
				_fault("つうしんが きれた")
			else:
				_follow(status)
		"FAULT":
			_hold_reset()

func _hold_reset() -> void:
	_hold = 0.0
	holding = ""
	progress = 0.0

## The sign `want` held without a break: true once, when it has been there for hold_s.
func _held(want: String, sgn: String, dt: float) -> bool:
	if sgn != want or need_neutral:
		if holding == want or sgn != want:
			_hold_reset()
		return false
	holding = want
	_hold += dt
	progress = clampf(_hold / maxf(hold_s, 0.01), 0.0, 1.0)
	return _hold >= hold_s

func _tick_manual(dt: float, sgn: String, hand: Dictionary, world: Dictionary, status: Dictionary) -> void:
	if sgn != "grab":
		_hold_reset()
		return
	if need_neutral:
		_hold_reset()
		return
	# why a catch may not start now (said on the screen; the fist does not build up meanwhile)
	var block := ""
	if not bool(world.get("taking", false)):
		block = "いまは キャッチできないよ（ゲームちゅう だけ）"
	elif not bool(world.get("link", false)):
		block = "バックエンドに つながっていない"
	elif str(world.get("gate", "")) != "":
		block = str(world.get("gate", ""))
	elif bool(hand.get("steering", false)):
		block = "とまってから グーに してね"
	elif bool(status.get("active", false)):
		block = "まえの うごきが おわるまで まってね"
	if block != "":
		_hold_reset()
		note = block
		return
	if not _held("grab", sgn, dt):
		return
	_hold_reset()
	need_neutral = true  # this fist is used up, whatever the answer
	_neutral = 0.0
	var rid := str(send.call("easy_grab", {})) if send.is_valid() else ""
	if rid == "":
		note = "バックエンドに おくれなかった"
		cue.emit("refused")
		return
	grabs_sent += 1
	note = ""
	grab_id = ""
	destination = 0
	_rid = rid
	_rid_what = "grab"
	_rid_left = request_timeout_s
	_set_state("AUTO_GRAB")
	cue.emit("grab")

func _tick_wait(dt: float, sgn: String, hand: Dictionary, world: Dictionary) -> void:
	# #266: the carry first, by itself, as soon as it may be asked for
	_retry_left = maxf(_retry_left - dt, 0.0)
	if _tries < auto_tries and _retry_left <= 0.0:
		if not bool(world.get("taking", false)):
			# the round is over: nothing new is carried into a Dial that takes nothing
			note = "じかんぎれ。かかりの ひとが カプセルを もどすよ"
		elif str(world.get("gate", "")) != "":
			# the hand may not move the robot now (the window lost its focus, the hand control
			# is off, ...): a carry is new motion, so it waits for the gate (review on #170)
			note = str(world.get("gate", ""))
		else:
			_hold_reset()
			_deliver(1)
			return
	# the carry cannot be asked for (or was refused auto_tries times): an open hand kept up
	# gives the catch up (not the pinch)
	if sgn == "neutral" and str(hand.get("pose", "")) == "open" and not bool(hand.get("pinch", false)) and not need_neutral:
		if str(world.get("gate", "")) != "":
			_hold_reset()
			note = str(world.get("gate", ""))
			return
		if holding != "cancel":
			_hold_reset()
		holding = "cancel"
		_hold += dt
		progress = clampf(_hold / maxf(cancel_hold_s, 0.01), 0.0, 1.0)
		if _hold < cancel_hold_s:
			return
		_hold_reset()
		need_neutral = true
		_neutral = 0.0
		var crid := str(send.call("easy_cancel", {"grab_id": grab_id})) if send.is_valid() else ""
		if crid == "":
			note = "バックエンドに おくれなかった"
			cue.emit("refused")
			return
		cancels_sent += 1
		note = ""
		_rid = crid
		_rid_what = "cancel"
		_rid_left = request_timeout_s
		_set_state("CANCEL")
		return
	if holding == "cancel":
		_hold_reset()

## The carry to `dest` (#266: by itself, once the catch is up).
func _deliver(dest: int) -> void:
	_tries += 1
	_retry_left = auto_retry_s
	var rid := str(send.call("easy_deliver", {"destination": dest, "grab_id": grab_id})) if send.is_valid() else ""
	if rid == "":
		note = "バックエンドに おくれなかった"
		cue.emit("refused")
		return
	delivers_sent += 1
	note = ""
	destination = dest
	_rid = rid
	_rid_what = "deliver"
	_rid_left = request_timeout_s
	_set_state("DELIVER_DIAL_%d" % dest)
	cue.emit("deliver")

## The backend's report of the catch this script asked for (another catch's, or an old
## report from before the answer, is not read).
func _follow(status: Dictionary) -> void:
	if grab_id == "" or str(status.get("grab_id", "")) != grab_id:
		return
	step = str(status.get("step", ""))
	wait_left_s = float(status.get("wait_left_s", 0.0))
	wait_s = float(status.get("wait_s", wait_s))
	var bs := str(status.get("state", ""))
	match bs:
		"FAULT":
			_fault("とまったよ: %s" % fault_text(str(status.get("error", ""))))
		"EXPIRED":
			_fault("えらばなかったので とまったよ（つめは とじたまま）")
		"STOPPED":  # the stop key while it only waited: no alarm (the next game's start opens the claw)
			_fault("ストップした（つめは とじたまま）")
		"WAIT_DESTINATION":
			if state == "AUTO_GRAB":
				note = ""
				_set_state("WAIT_DESTINATION")
				cue.emit("caught")
		"DELIVER_DIAL_1":
			if state == "WAIT_DESTINATION" and _rid == "":
				# the backend carries though this script did not ask (it cannot: one owner). Follow it.
				destination = int(status.get("destination", 0))
				_set_state(bs)
		"MANUAL_XY":
			if state == "CANCEL" and str(status.get("last_result", "")) == "cancelled" and not bool(status.get("active", false)):
				_forget()
				note = "つめを ひらいたよ。もういちど やってみよう"
				_set_state("MANUAL_XY")
				cue.emit("cancelled")
			elif state == "RESET" and str(status.get("last_result", "")) == "done" and not bool(status.get("active", false)):
				_forget()
				note = ""
				_set_state("MANUAL_XY")
			elif state.begins_with("DELIVER_DIAL_") and str(status.get("last_result", "")) == "done" \
					and not bool(status.get("active", false)):
				var dest := int(status.get("destination", destination))
				_forget()
				note = ""
				_set_state("MANUAL_XY")
				delivered.emit(dest)
				cue.emit("done")

## A refusal of the backend, as what to do next (shown to the player and the staff).
static func refusal_text(reason: String) -> String:
	var r := reason.to_lower()
	if r.contains("near the portal"):  # #270: it would go down onto the portal
		return "ポータルの ちかくでは キャッチできないよ（すこし はなれてね）"
	if r.contains("not recorded") or r.contains("not confirmed") or r.contains("is not set") or r.contains("measured again"):
		return "じどうの うごきは まだ つかえない（校正が まだ: かかりの ひとへ）"
	if r.contains("alarm"):
		return "アラームちゅう（かかりの ひとを よんでね）"
	if r.contains("not homed"):
		return "げんてんふっきが いるよ（かかりの ひとを よんでね）"
	if r.contains("z reference not set"):  # #275
		return "アームの たかさが まだ きまっていない（校正タブ: Z の うえを きろく）"
	if r.contains("claw open / closed"):  # #275
		return "つめの ひらき・とじが まだ（校正タブで きろく）"
	if r.contains("robot not connected"):  # #275
		return "ロボットに つながっていない"
	if r.contains("motors not enabled"):
		return "モーターが オフ（かかりの ひとを よんでね）"
	if r.contains("below safe_z"):
		return "アームを うえまで あげてから（かかりの ひとへ）"
	if r.contains("jog") or r.contains("busy"):
		return "とまってから もういちど"
	if r.contains("stale") or r.contains("not waiting") or r.contains("already chosen"):
		return "いまは えらべないよ"
	return "できなかった: " + reason

static func fault_text(error: String) -> String:
	var r := error.to_lower()
	if r.contains("emergency stop") or r.contains("soft_stop") or r.contains("stopped"):
		return "ストップした"
	if r.contains("disconnected"):
		return "つうしんが きれた"
	if r.contains("timeout"):
		return "じかんない に うごかなかった"
	return error

## The big line for the screen.
func title_text() -> String:
	match state:
		"RESET":
			return "じゅんびちゅう…（アームを うえへ）"
		"AUTO_GRAB":
			return "じどうで キャッチちゅう…"
		"WAIT_DESTINATION":
			return "ポータルへ はこぶよ！"
		"DELIVER_DIAL_1":
			return "ひだりの ポータルへ はこぶよ"
		"CANCEL":
			return "やりなおすよ（つめを ひらく）"
		"FAULT":
			return "かかりの ひとを よんでね"
	return ""

## The backend's step in plain words.
const STEP_JA := {"OPEN_CLAW": "つめを ひらく", "LOWER_TO_CATCH": "おりる", "CLOSE_CLAW": "つかむ", "RAISE_WITH_ITEM": "あがる",
	"WAIT_DESTINATION": "はこぶ じゅんび", "MOVE_TO_DIAL": "はこぶ", "LOWER_TO_RELEASE": "おりる", "RELEASE": "はなす",
	"RAISE_EMPTY": "あがる"}

func step_text() -> String:
	return str(STEP_JA.get(step, ""))
