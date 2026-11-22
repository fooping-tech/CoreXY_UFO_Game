extends Node
## Headless physics / mapping tests. Run with:
##   godot --headless --path game res://tests/test_runner.tscn
## Exit code 0 when everything passes.
##
## The tests are in the suites below (test_<name>.gd), the helpers they share in
## test_base.gd. The order of the calls in _ready is part of the tests: keep it.

const TestBase := preload("res://tests/test_base.gd")
const SUITES := {
	"rope_robot": preload("res://tests/test_rope_robot.gd"),
	"gesture": preload("res://tests/test_gesture.gd"),
	"study": preload("res://tests/test_study.gd"),
	"ui": preload("res://tests/test_ui.gd"),
	"game_mode": preload("res://tests/test_game_mode.gd"),
	"game_mode_show": preload("res://tests/test_game_mode_show.gd"),
	"tutorial_easy": preload("res://tests/test_tutorial_easy.gd"),
}
var _s := {}

func _ready() -> void:
	for name in SUITES:
		var suite: Node = SUITES[name].new()
		suite.name = name
		add_child(suite)
		_s[name] = suite
	var rs: Node = RobotState
	GameConfig.drop_local()  # this machine's config/local_settings.json (#93) must not change the tests
	GameModeSounds.load_music = false  # nor this machine's music files (#173: game/assets/audio/bgm/)
	_s.rope_robot._test_rest_state()
	_s.rope_robot._test_inextensible_under_motion()
	_s.rope_robot._test_sudden_stop_swing_and_decay()
	_s.rope_robot._test_xy_diagonal_3d()
	_s.rope_robot._test_rope_length_change()
	_s.rope_robot._test_pendulum_and_taut_rope()
	_s.rope_robot._test_playback_smoothing(rs)
	_s.rope_robot._test_playback_30hz_acceleration(rs)
	_s.rope_robot._test_mock_robot_settles(rs)
	_s.rope_robot._test_real_jog_velocity()
	_s.rope_robot._test_fit_travel_to_screen(rs)
	_s.rope_robot._test_motion_fx()
	_s.rope_robot._test_z_inverse_mapping(rs)
	_s.rope_robot._test_projection_consistency()
	_s.rope_robot._test_performance()
	_s.rope_robot._test_game_assets_in_sync()
	_s.rope_robot._test_ufo_metadata()
	_s.rope_robot._test_ufo_faces_and_pose_effects()
	_s.rope_robot._test_camera_scope()
	_s.study._test_study_image_encoding()
	_s.gesture._test_hand_joystick()
	_s.gesture._test_gesture_states()
	_s.gesture._test_gesture_z_and_claw()
	_s.gesture._test_gesture_schemes()
	_s.gesture._test_pose_direction_scheme()
	_s.gesture._test_pose_finger_direction()
	_s.gesture._test_pose_thumb_and_claw()
	_s.gesture._test_gesture_z_has_its_own_sound(rs)
	_s.gesture._test_gesture_with_mock_robot(rs)
	_s.gesture._test_error_clears_when_the_machine_recovers(rs)
	_s.gesture._test_claw_steps_on_the_mock(rs)
	_s.ui._test_vfx_manager()
	_s.ui._test_vfx_follows_the_game(rs)
	_s.ui._test_debug_panel_tabs_and_z_buttons(rs)
	_s.study._test_study_is_optional(rs)
	_s.study._test_homework_watch(rs)
	_s.ui._test_auto_catch_controls(rs)
	_s.study._test_study_worksheets_and_tracker()
	_s.study._test_study_mode_mock_story(rs)
	_s.study._test_study_mode_failures(rs)
	_s.study._test_study_mode_looks_again(rs)
	_s.study._test_study_mode_backend_messages(rs)
	_s.study._test_study_mode_without_tidy_up(rs)
	_s.study._test_study_sheet_photo(rs)
	_s.study._test_focus_stream()
	_s.study._test_study_hand_help(rs)
	_s.study._test_study_local_frames(rs)
	_s.study._test_study_voice(rs)
	_s.study._test_study_answer_check(rs)
	_s.study._test_study_real_print_problems(rs)
	_s.study._test_study_power_items(rs)
	_s.study._test_study_scenery(rs)
	_s.study._test_study_reward_show(rs)
	_s.study._test_study_voice_goes_to_look(rs)
	_s.ui._test_title_screen(rs)
	_s.ui._test_settings(rs)
	_s.ui._test_calibration_tab(rs)
	_s.ui._test_calibration_summary()
	_s.ui._test_focus_calibrator()
	_s.ui._test_device_test_tab(rs)
	_s.ui._test_sheet_check_tab(rs)
	_s.game_mode._test_game_mode_score()
	_s.game_mode._test_game_mode_powerups()
	_s.game_mode._test_game_mode_ufo_and_mock_dials()
	_s.game_mode._test_game_mode_round(rs)
	_s.game_mode._test_game_mode_powerup_integration(rs)
	_s.game_mode._test_game_mode_powerup_followup(rs)
	_s.game_mode._test_game_mode_duplicates_and_sessions(rs)
	_s.game_mode._test_game_mode_release_faults(rs)
	_s.game_mode._test_game_mode_dial_leds(rs)
	_s.game_mode._test_game_mode_clock_and_stop(rs)
	_s.game_mode._test_game_mode_backend_hub(rs)
	_s.game_mode_show._test_game_mode_visuals(rs)
	_s.game_mode_show._test_game_mode_juice(rs)
	_s.game_mode_show._test_game_mode_result_logic()
	_s.game_mode_show._test_game_mode_result_show(rs)
	_s.game_mode_show._test_ranking_logic()
	_s.game_mode_show._test_game_mode_ranking(rs)
	_s.game_mode_show._test_portrait_layout(rs)
	_s.game_mode_show._test_game_mode_scope(rs)
	_s.game_mode_show._test_game_mode_audio(rs)
	_s.game_mode_show._test_game_mode_reactions(rs)
	_s.tutorial_easy._test_gesture_tutorial_logic()
	_s.tutorial_easy._test_gesture_tutorial_more_steps()
	_s.tutorial_easy._test_gesture_tutorial_done_say()
	_s.tutorial_easy._test_tutorial_claw_demo(rs)
	_s.tutorial_easy._test_game_title_hand(rs)
	_s.tutorial_easy._test_gesture_tutorial_game(rs)
	_s.tutorial_easy._test_easy_mode_logic()
	_s.tutorial_easy._test_easy_mode_game(rs)
	await _s.game_mode._test_game_mode_physics()
	# (after the physics run: the field is chaotic, and a scene made and freed before it shifts
	# which capsule takes longest; the run's own limit is kept as it is)
	_s.game_mode_show._test_score_game_panel_and_spell_voice(rs)
	_s.game_mode_show._test_game_mode_music_files(rs)
	_s.ui._test_arm_recovery(rs)
	_s.ui._test_staff_control(rs)
	_s.ui._test_fonts()
	print("\n%d passed, %d failed" % [TestBase._passes, TestBase._fails])
	get_tree().quit(0 if TestBase._fails == 0 else 1)
