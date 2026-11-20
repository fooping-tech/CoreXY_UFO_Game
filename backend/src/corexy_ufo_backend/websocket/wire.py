"""The names of the WebSocket commands and which of them are accepted when (see server.py
for what each command does), and the timestamp every message carries."""

from __future__ import annotations

import time

# The device hub (#108): never the robot, never waits behind its commands, its STOP ALL always goes
DEVICEHUB_COMMANDS = ("devicehub_meta", "devicehub_devices", "devicehub_status", "devicehub_diag",
                      "devicehub_command", "devicehub_stop_all", "devicehub_mock_ball")
COMMANDS = ("enable_motors", "home", "move_xy", "move_z", "z_zero", "z_set", "z_restore", "z_servo_recover", "grab", "stop", "soft_stop", "jog",
            "clear_alarm", "get_state", "list_ports", "gesture_config", "arm_step", "arm_zero",
            "arm_set", "arm_goto", "auto_catch", "auto_catch_status",
            "homework_spot_set", "homework_approach", "homework_approach_release", "homework_approach_status",
            "homework_navigate",
            "camera_map_add", "camera_map_undo", "camera_map_clear", "camera_map_status",
            "study_height_status", "study_height_set", "study_height_confirm",
            "study_cleanup_start", "study_cleanup_confirm", "study_cleanup_status",
            "calibration_prepare", "calibration_prepare_status",
            "easy_grab", "easy_reset", "easy_deliver", "easy_cancel", "easy_status", "easy_dial_set", "easy_dial_confirm",
            "easy_goto", "jog_boost",
            *DEVICEHUB_COMMANDS, "services_check", "worksheet_find")
MOTION_COMMANDS = ("home", "move_xy", "move_z", "grab", "arm_step", "arm_goto", "z_servo_recover", "easy_goto")
# Never queued behind another command of the same connection: a stop must reach
# the robot while a move_xy of that connection is still running.
# Out-of-band commands that only read: cancelled at once when their client disconnects, so
# the disconnect's safety aborts never wait for them (review on #115: services_check can wait
# 90 s for an AI). Anything that stops something (stop, devicehub_stop_all, ...) is let finish.
CANCEL_ON_DISCONNECT = ("services_check", "worksheet_find", "devicehub_meta", "devicehub_devices", "devicehub_status",
                        "devicehub_diag")
PRIORITY_COMMANDS = (*DEVICEHUB_COMMANDS, "services_check", "worksheet_find", "stop", "soft_stop", "jog", "jog_boost", "get_state", "auto_catch_status",
                     "homework_approach_release", "homework_approach_status",
                     "study_cleanup_confirm", "study_cleanup_status", "calibration_prepare_status",
                     "easy_deliver", "easy_cancel", "easy_status")
# Accepted while the auto catch runs (anything else is refused as busy).
AUTO_CATCH_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch", "auto_catch_status", "list_ports",
                      "gesture_config", "homework_approach_status", "camera_map_status", "study_cleanup_status",
                      "study_height_status", "easy_status")
# Accepted while the arm approaches the homework (anything else is refused as busy).
APPROACH_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                    "homework_approach", "homework_approach_release", "homework_approach_status",
                    "camera_map_status", "study_cleanup_status", "study_height_status", "easy_status")
# Accepted while the 校正 tab's preparation runs (#167; anything else is refused as busy).
PREPARE_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                   "homework_approach_status", "camera_map_status", "study_cleanup_status", "study_height_status",
                   "calibration_prepare_status", "easy_status")
# Accepted while the study mode tidies up (anything else is refused as busy).
CLEANUP_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                   "homework_approach_status", "camera_map_status", "study_cleanup_start", "study_cleanup_confirm",
                   "study_cleanup_status", "study_height_status", "easy_status")
# Accepted while the easy mode catches, waits for its destination or carries (#169).
EASY_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                "homework_approach_status", "camera_map_status", "study_cleanup_status", "study_height_status",
                "easy_deliver", "easy_cancel", "easy_status")


def now_ms() -> int:
    return int(time.time() * 1000)

