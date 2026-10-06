class_name MainWindow
extends Control
## GodotPipe – main window controller.
##
## Owns the sidebar project list, the per-project settings form (Godot binary,
## publish targets, App ID, branch, itch.io game, build table), the Steam and
## itch.io accounts, and the live debug console. Build & Publish exports once
## and then uploads to each enabled target in turn: Steam (SteamCMD), then
## itch.io (butler). Child processes stream their output into the console
## line by line.
##
## Started with arguments after "--" it runs headless as a command-line tool
## instead (see features/cli/cli.gd), driving the same pipeline.

## Every console message as plain text, for the command-line mode: [param kind]
## is "line", "banner", "step", "step_done", "cmd", "out" or "exit", and
## [param color] the COLOR_* level of the message.
signal console_emitted(kind: String, text: String, color: String)
## One line of a child's output, before the console shows or folds it.
signal child_output(line: String, is_stderr: bool, tool: String)
## The console's live progress bar moved to [param pct] percent.
signal progress_changed(label: String, pct: int)

const PROJECTS_FILE := "user://projects.cfg"
const SETTINGS_FILE := "user://settings.cfg"
## Window rect, divider positions, console and last app; written on quit.
const WINDOW_FILE := "user://window.cfg"
## Cached "<binary> --version" results, so switching apps never has to spawn Godot.
const VERSION_CACHE_FILE := "user://godot_versions.cfg"
const STEAM_TOTP_ALPHABET := "23456789BCDFGHJKMNPQRTVWXY"

## Valve's official SteamCMD archives; static, unauthenticated downloads.
const STEAMCMD_DOCS_URL := "https://developer.valvesoftware.com/wiki/SteamCMD"
## Steamworks → Installation → General for one app; %s is the App ID.
const STEAMWORKS_APP_CONFIG_URL := "https://partner.steamgames.com/apps/config/%s"
## Steamworks → SteamPipe → Builds for one app; %s is the App ID. Branches are
## created and builds set live by hand here.
const STEAMWORKS_BUILDS_URL := "https://partner.steamgames.com/apps/builds/%s"
const STEAMWORKS_DEPOTS_URL := "https://partner.steamgames.com/apps/depots/%s"

## Community Discord server, rendered from the public Server Widget JSON.
const DISCORD_GUILD_ID := "1084592623819444365"
const DISCORD_INVITE_URL := ""  # Fallback when widget.json carries no instant_invite.
const DISCORD_REFRESH_SECONDS := 60.0
const STEAMCMD_URLS := {
	"Windows": "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip",
	"macOS": "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz",
	"Linux": "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz",
}

## Godot editor visibility icons (public/icons/editor, MIT) for the show/hide toggles.
const EYE_VISIBLE := preload("res://public/icons/editor/visibility_visible.svg")
const EYE_HIDDEN := preload("res://public/icons/editor/visibility_hidden.svg")
## Composer button: play while idle, stop while something runs.
const ICON_PLAY := preload("res://public/icons/editor/main_play.svg")
const ICON_STOP := preload("res://public/icons/editor/stop.svg")
## Godot scene-tree arrows for disclosure toggles and the account row chevron.
const ARROW_RIGHT := preload("res://public/icons/editor/gui_tree_arrow_right.svg")
const ARROW_DOWN := preload("res://public/icons/editor/gui_tree_arrow_down.svg")
const ICON_CLOSE := preload("res://public/icons/editor/close.svg")
const ICON_FOLDER := preload("res://public/icons/editor/folder.svg")
## Console header: copy icon, swapped for a check mark briefly after copying.
const ICON_COPY := preload("res://public/icons/editor/action_copy.svg")
const ICON_CHECK := preload("res://public/icons/editor/import_check.svg")
## The copy button puts a redacted support report on the clipboard (see
## _diagnostics_report), with at most this many console lines.
const COPY_TOOLTIP := "Copy the console and your setup, ready to paste to an AI or on Discord (passwords, keys, secrets, your account names and home folder are removed)"
const REPORT_CONSOLE_LINES := 5000
const BUILD_TOOLTIP := "Build and publish"
const STOP_TOOLTIP := "Stop what is running"


## App name from project.godot, so console and diagnostics text follow it.
static func _app_name() -> String:
	return str(ProjectSettings.get_setting("application/config/name", "GodotPipe"))


## "1 depot", "3 depots".
static func _plural(count: int, noun: String) -> String:
	return "%d %s%s" % [count, noun, "" if count == 1 else "s"]

## Smallest window in logical points. The console hides itself as soon as the
## main view can no longer shrink to make room for it (see _console_fits) and
## comes back once there is room again.
const MIN_WINDOW_SIZE := Vector2i(500, 340)

## How far (logical points) the cursor has to be pulled past the point where
## the console divider stops moving before the console expands or closes. It
## stops at the console's minimum on one side and the main view's real minimum
## on the other. Half the console's 360 px minimum width, so a small nudge at
## the edge does not flip the layout (see _input).
const SPLIT_OVERSHOOT := 180.0

## How far (logical points) the sidebar can be dragged past its minimum
## width. Its minimum is the 260 px set on the Sidebar node in the scene,
## but long project names raise it (the project list never scrolls
## horizontally), so the cap is relative rather than an absolute width.
## Note that Layout's split_offset is the sidebar width in pixels, not the
## extra past the minimum: the Sidebar does not expand, so the splitter's
## default dragger position is 0 (see _clamp_sidebar_split).
const SIDEBAR_MAX_EXTRA := 160.0

## macOS: height of the (now transparent) title bar in logical points. The
## sidebar reserves this much room above its nav so the traffic-light buttons
## never overlap the nav, and an invisible strip of this height across the
## whole window width is the drag / double-click-zoom area.
const MACOS_TITLEBAR_HEIGHT := 28

## Whether the user wants the console open (independent of whether it fits).
var _console_wanted := true
## Distraction-free mode: the main view is hidden and the console takes its
## width. Never persisted; hiding the console clears it.
var _console_expanded := false
## Divider position before the console was expanded, put back on restore so
## the divider does not end up parked at the main view's minimum width.
var _split_offset_before_expand := 0
## True while the user drags the divider between the main view and the
## console. Overshooting the console's minimum width closes it; overshooting
## the main view's minimum expands it (see _input).
var _console_splitter_dragging := false

# Console / status colours (bbcode + Color). Muted to match the ConsoleBody
# variation in public/theme.tres (generated by tools/theme_generator.py).
const COLOR_INFO := "#a3a3a3"
const COLOR_OUT := "#8a8a8a"  # stdout/stderr stream of a child process
const COLOR_CMD := "#7fb6e0"
const COLOR_CMD_BG := "#7fb6e014"  # translucent pill behind a "$ command" line
const COLOR_OK := "#86c29a"
const COLOR_WARN := "#d9a64a"
const COLOR_ERR := "#e07b72"
const COLOR_STAMP := "#808080"
const COLOR_GUTTER := "#333333"  # "│" bar on lines inside a step block
const COLOR_GUTTER_ERR := "#d9a64a8c"  # same bar, tinted for stderr lines
const COLOR_TEXT := "#ececec"
const COLOR_TEXT_2 := "#a3a3a3"
const COLOR_MUTED := "#8a8a8a"  # >= 4.5:1 on the app and card backgrounds (WCAG AA)

## Banner text for a folder app until the user closes it for that app.
const FOLDER_APP_NOTICE := "No project.godot here, so this app uploads its folders as-is, without a Godot export. Good for soundtracks, DLC or builds from other engines."

## Step block state: log_step() opens a block, log_step_done() closes it with a
## ✓/✗ line. Lines logged in between get a "│" gutter.
var _step_open := false
var _step_started_ms := 0
var _step_failed := false

## Follow new output at the bottom until the user scrolls up.
var _console_autoscroll := true
var _console_scroll_lock := false  # true while the script moves the scrollbar
var _console_dragging := false  # true while the user drags the console scrollbar

const Motion := preload("res://features/main_window/ui_motion.gd")
const ConsoleProgress := preload("res://features/main_window/console_progress.gd")
const ScriptCheck := preload("res://features/main_window/script_check.gd")
## Command-line mode (preloaded by path: a class_name only resolves after the
## editor rescanned the project).
const Cli := preload("res://features/cli/cli.gd")
## Live progress bar in the console: one line (label, bar, percentage)
## rewritten in place. _bar_para is its paragraph while it is live, else -1.
const BAR_CELLS := 20
const BAR_LABEL_WIDTH := 23
var _bar_para := -1
var _bar_label := ""
var _bar_pct := -1
var _bar_line := ""
## Reads the running child's progress lines (see ConsoleProgress); null when
## its output has none.
var _progress: ConsoleProgress
## Process frame in which _show_project last cleared the banners. Banners
## built in that same frame (the app just selected) appear at once; later
## ones, e.g. from the Godot version probe, grow in.
var _banners_reset_frame := -1

## Each project is a Dictionary:
## {
##   name: String, path: String, kind: "godot" | "folder", godot_binary: String,
##   uid: String (random, names the app's build folder),
##   steam_enabled: bool, app_id: String, branch: String, description: String,
##   itch_enabled: bool, itch_target: String ("user/game"),
##   depots: Array[Dictionary]  (the build rows; one export or folder each)
##     godot:  { preset: String, depot_id: String, output: String, itch_channel: String }
##             (output is the executable base name; the extension follows the preset platform)
##     folder: { content_dir: String, depot_id: String, itch_channel: String }
##             (a plain folder uploaded as-is – no Godot export; kind is fixed at creation)
##   A row goes to Steam when Steam is on, it is not a web build and it has a
##   depot ID; to itch.io when itch.io is on and it has a channel.
## }
var _projects: Array[Dictionary] = []
var _selected_index: int = -1
## Project names already sent to the Steam store for an App ID lookup, so
## switching between projects does not repeat the same search.
var _app_id_lookups_done: Dictionary = {}
## "<project name>|<app id>" keys for which depots were fetched automatically,
## so a failed or empty result does not re-run SteamCMD on every keystroke.
var _auto_depot_fetches: Dictionary = {}
## True when an automatic depot fetch was wanted while something else ran;
## _set_busy(false) retries it for the selected project.
var _auto_fetch_pending := false
## True while _fetch_depots owns the busy state. Delete stays enabled then:
## removing the app cancels its fetch (see _on_remove_project_pressed).
var _fetching_depots := false
## App ID → PackedStringArray of the depot IDs Steam listed for it this
## session (SteamAppInfo.uploadable_depot_ids). Only non-empty answers are
## kept; Build & Publish skips its depot check when they cover every row.
var _steam_depot_ids: Dictionary = {}
## App ID → Dictionary of the branches Steam listed for it this session, name
## → live buildid (SteamAppInfo.branch_builds). Only non-empty answers are kept.
var _steam_branches: Dictionary = {}
var _project_button_group := ButtonGroup.new()
## Discord widget: invite link from the last answer and when it was fetched.
var _discord_invite := ""
var _discord_fetched_msec := -1
# Thin accent line shown between sidebar rows while a project is being dragged.
var _drop_line: Panel
var _is_busy := false
## The app a Build & Publish run is working on; empty when none runs.
var _publishing: Dictionary = {}
## This run unpacked a macOS bundle without its executable bits (Windows).
var _exec_bits_lost := false
var _preset_names: PackedStringArray
## Platform of each entry in _preset_names, as written in export_presets.cfg.
var _preset_platforms: PackedStringArray
## Godot problem _check_godot_version found for the selected app
## ({ "text", "color" }), or empty when the binary is fine or still probing.
var _godot_status := {}
## Leading fix from the last failed run of the selected app, or empty.
var _run_status := {}
## Banner texts the user closed while on this app; a changed text shows again.
var _dismissed_banners := {}
## binary path -> { "version": String, "mtime": int }. Probing a Godot binary
## launches it (it bounces in the Dock), so each one is probed once and the
## answer is kept until the file changes.
var _version_cache: Dictionary = {}
## Bumped per _check_godot_version call so a probe that finishes after the
## user switched project cannot write into the wrong page.
var _probe_serial := 0

## Theme variations that draw a red border around a field that failed validation.
const ERROR_FIELD := &"ErrorField"
const ERROR_OPTION := &"ErrorOption"
## App and depot IDs are 32-bit, so never longer than this.
const ID_MAX_DIGITS := 10
## depot index -> { "preset": true, "depot_id": true, "output": true } for the
## depot fields marked red at the last submit. Rows are rebuilt from data, so
## the marks live here rather than on the controls.
var _depot_errors: Dictionary = {}

# Reader threads for the currently running child process.
var _reader_threads: Array[Thread] = []
var _reader_stop := false  # tells the pipe readers the process has exited
## PID of the child run_process is waiting on, -1 while nothing runs.
var _child_pid := -1
## True once OS.kill() reaped the child: its pid can no longer be polled.
var _child_killed := false
## Set by the composer stop button. Pipelines check it after every await and
## bail out quietly instead of reporting a failure; _set_busy resets it.
var _cancel_requested := false
## While true, stdout lines from run_process are also collected in _capture
## so a caller can parse them (see run_process_capture).
var _capturing := false
var _capture: PackedStringArray
## stdin/stdout pipe of the child run_process is currently waiting on, so a
## Steam Guard code can be written to SteamCMD while it is still running.
var _child_stdio: FileAccess
## True from the moment SteamCMD asked for a Steam Guard code until one was
## written to it. The login button turns into "Submit code" meanwhile.
var _awaiting_guard_code := false
## True while the running SteamCMD login takes a typed code although it is not
## at a code prompt (a sign-in, or waiting for the mobile app): submitting one
## restarts SteamCMD with it (see [method _submit_guard_code]).
var _code_submittable := false
## Code the next launch of the running SteamCMD passes with
## +set_steam_guard_code; set right before that run is killed for a restart.
var _guard_restart_code := ""
## Set when a Guard prompt was seen during the current child process, and
## when a code was written to it, so the failure hint can tell the two apart.
var _guard_prompt_seen := false
var _guard_code_sent := false
## Set when the child printed one of GUARD_FAILURES: SteamCMD did not prompt
## but refused the login until a (correct) Steam Guard code is supplied.
var _guard_failure_seen := false
## Set when the child asked for the account password ("password:") and when
## the saved one was written to it. Without a saved password the child is
## stopped instead of hanging on the prompt forever.
var _password_prompt_seen := false
var _password_sent := false
## Set when the child printed GUARD_WAIT_PROMPT: SteamCMD sent a push to the
## Steam mobile app and is polling Steam for the approval.
var _guard_wait_seen := false
## Tool whose output the running child streams (KnownIssues.STEAMCMD,
## KnownIssues.GODOT or "") and the KnownIssues ids its output matched so
## far. Reset per process like the guard flags above.
var _child_tool := ""
var _seen_issues := PackedStringArray()
## Save targets whose last save failed, so the error is logged once per file
## until a save works again (see _report_save).
var _failed_saves: Dictionary = {}
## Remembered secrets as last written to the OS credential store (SecretStore
## name -> value), so unchanged values are not written again. A write runs on
## _secret_thread; a request that comes in meanwhile sets _secrets_dirty and
## runs once that write is done.
var _stored_secrets: Dictionary = {}
var _secret_thread: Thread
var _secrets_dirty := false
## Set while the last secret write failed, so the warning is logged once.
var _secret_write_failed := false
## SecretStore name → { "field": LineEdit, "remember": Button, "label": String }
## for every remembered secret; filled in _ready.
var _secrets: Dictionary = {}
## Label of the progress bar the next run_process shows for tools whose
## output does not say what they work on (butler: the channel it pushes).
var _progress_label := ""
## One banner per publish target after a run with more than one target
## ({ "text", "color" }), in upload order.
var _target_status: Array[Dictionary] = []

## Next steps logged when a failed run printed nothing KnownIssues recognises.
const STEAMCMD_FALLBACK := "Scroll up to the first line from SteamCMD that says FAILED or ERROR for the reason. If it does not make sense, press the copy button in the console header and paste the result to an AI or on Discord."
const EXPORT_FALLBACK := "Scroll up to Godot's first ERROR line for the reason. To see the full message, open the project in Godot and export the same preset from Project → Export…. If it still does not make sense, press the copy button in the console header and paste the result to an AI or on Discord."
const BUTLER_FALLBACK := "Scroll up to butler's last lines for the reason. Check that the itch.io game (user/game) is yours and that the API key on the Setup page belongs to the same account. If it does not make sense, press the copy button in the console header and paste the result to an AI or on Discord."
## Banner text per fallback, shown when a failure had no recognised cause.
const FALLBACK_BANNERS := {
	EXPORT_FALLBACK: "The export failed. See the console for Godot's error.",
	STEAMCMD_FALLBACK: "SteamCMD failed. See the console for its error.",
	BUTLER_FALLBACK: "The itch.io upload failed. See the console for butler's error.",
}
## Shown once a Web build went to itch.io: butler cannot mark a project as
## playable in the browser, the game's edit page has to.
const ITCH_HTML_NOTE := "Web builds play in the browser only after you set Kind of project to HTML on the itch.io edit page and tick 'This file will be played in the browser' on the html5 upload."
## No new byte for this long ends the SteamCMD download as stalled.
const DOWNLOAD_STALL_MS := 30000
## Build & Publish warns (without blocking) below this much free disk space.
const LOW_DISK_BYTES := 1 << 30
## File names Windows refuses regardless of extension.
const WINDOWS_RESERVED_NAMES: PackedStringArray = [
	"CON", "PRN", "AUX", "NUL",
	"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
	"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
]
## Characters no desktop OS accepts in a file name (Windows is the strictest).
const ILLEGAL_FILE_CHARS := ["/", "\\", "<", ">", ":", "\"", "|", "?", "*"]
## Prompt SteamCMD prints (without a trailing newline) when no cached
## session exists. The password is never passed on the command line, where
## other processes could read it, so this is how SteamCMD gets it.
const PASSWORD_PROMPT := "password:"
## SecretStore names of the remembered secrets.
const SECRET_PASSWORD := "steam_password"
const SECRET_SHARED_SECRET := "steam_shared_secret"
const SECRET_ITCH_KEY := "itch_api_key"
## Prompts SteamCMD prints (without a trailing newline) when it needs a code.
const GUARD_PROMPTS := ["steam guard code:", "two-factor code:", "enter the current code"]
## Line SteamCMD prints while it waits for the login to be approved in the
## Steam mobile app (no code prompt follows).
const GUARD_WAIT_PROMPT := "waiting for confirmation"
## Lines SteamCMD prints when the login was refused for a Steam Guard code
## (missing, or wrong), lowercase.
const GUARD_FAILURES := [
	"account logon denied",
	"two-factor code mismatch",
	"invalid login auth code",
	"need two-factor",
	"not been authenticated for your account using steam guard",
	"that steam guard code was invalid",
	"timed out waiting for confirmation",
	"wait for confirmation timed out",
]
const LOGIN_BUTTON_TEXT := "Sign in"
const SUBMIT_CODE_TEXT := "Submit code"
const DOWNLOAD_BUTTON_TEXT := "Download SteamCMD"
const DOWNLOAD_BUTTON_TOOLTIP := "Downloads Valve's official SteamCMD into this app's data folder and fills in the path"
const UPDATE_BUTTON_TEXT := "Update SteamCMD"
const UPDATE_BUTTON_TOOLTIP := "Runs SteamCMD once so it can update itself"

## Set once "Sign in" succeeded for _login_verified_user. Together with a
## resolvable SteamCMD this unlocks adding apps (see _setup_complete).
var _login_verified := false
var _login_verified_user := ""
## Steam persona (display) name of _login_verified_user, "" until fetched.
var _login_persona := ""

# SteamCMD downloader state.
var _steamcmd_http: HTTPRequest
var _steamcmd_archive := ""
var _steamcmd_downloading := false

# butler downloader state.
var _butler_http: HTTPRequest
var _butler_archive := ""
var _butler_downloading := false

## Set once "Sign in" on the itch.io card accepted the API key. The account
## is remembered so the sidebar chip shows it at once on the next start.
var _itch_verified := false
var _itch_user := ""  # itch.io username (the part before .itch.io)
var _itch_display := ""  # display name, "" when the account has none
var _itch_user_id := ""
## Serials of the ItchApi requests whose answers are still wanted.
var _itch_profile_serial := -1
var _itch_games_serial := -1
## True once the account's games list arrived (it may be empty).
var _itch_games_loaded := false
## The next games list forces a fresh cover download (the Refresh button).
var _itch_cover_force := false
## Games of the signed-in account from the last fetch ({ title, target, … }).
var _itch_games: Array = []

## True when started with command-line arguments (see Cli): no window state,
## nothing written to the settings files, no lookups that only feed the UI,
## and a sign-in or Steam Guard prompt stops the run instead of waiting.
var cli_mode := false
## Set in cli_mode when a run stopped because Steam or itch.io needs a sign-in
## (password, Steam Guard code, approval in the mobile app) the CLI cannot give.
var auth_needed := false
## Set when the running child is stopped on purpose after a set time (the
## exported build's smoke test), so its end is not reported as a failure.
var _child_timed_out := false


func _ready() -> void:
	cli_mode = not OS.get_cmdline_user_args().is_empty()
	get_tree().auto_accept_quit = cli_mode  # Quitting mid-publish asks first.
	if not cli_mode:
		_apply_display_scale()
		_apply_macos_titlebar()
	get_viewport().size_changed.connect(_on_window_resized)
	%ContentMargin.minimum_size_changed.connect(_on_window_resized)
	%ComposerMargin.minimum_size_changed.connect(_on_window_resized)
	%ProjectHeaderMargin.minimum_size_changed.connect(_on_window_resized)
	_on_window_resized()
	%AddAppButton.pressed.connect(_on_new_app_pressed)
	%NewAppButton.pressed.connect(_on_new_app_pressed)
	%NewAppButton.button_group = _project_button_group  # Pressed look while adding, cleared by any other selection.
	%ConsoleToggle.toggled.connect(_set_console_visible)
	%HideConsoleButton.pressed.connect(_set_console_visible.bind(false))
	%ExpandConsoleButton.toggled.connect(_set_console_expanded)
	var content_split: HSplitContainer = %ConsoleDock.get_parent()
	content_split.drag_started.connect(func() -> void: _console_splitter_dragging = true)
	content_split.drag_ended.connect(func() -> void: _console_splitter_dragging = false)
	($Layout as HSplitContainer).dragged.connect(_clamp_sidebar_split)
	%SteamCmdButton.button_group = _project_button_group
	%SteamCmdButton.pressed.connect(_show_project.bind(-1))
	%SteamAccountHeader.pressed.connect(_show_project.bind(-1))
	%ItchAccountHeader.pressed.connect(_show_project.bind(-1))
	%DiscordJoinButton.pressed.connect(_on_discord_join_pressed)
	%DiscordWidget.widget_ready.connect(_on_discord_widget_ready)
	%DiscordWidget.widget_failed.connect(_on_discord_widget_failed)
	%DiscordWidget.avatar_ready.connect(_on_discord_avatar_ready)
	%ProjectHeaderButton.pressed.connect(_on_browse_pressed)
	%RemoveProjectButton.pressed.connect(_on_remove_project_pressed)
	%ProjectDialog.dir_selected.connect(_on_project_dir_selected)
	%DepotFolderDialog.dir_selected.connect(_on_depot_folder_selected)
	%BuildPublishButton.pressed.connect(_on_build_publish_pressed)
	%ClearConsoleButton.pressed.connect(_clear_console)
	%CopyConsoleButton.pressed.connect(_copy_console)
	%AutoScrollButton.toggled.connect(_set_console_autoscroll)
	%Console.get_v_scroll_bar().value_changed.connect(_on_console_scrolled)
	%Console.get_v_scroll_bar().gui_input.connect(_on_console_bar_input)
	%Console.gui_input.connect(_on_console_input)
	%Console.resized.connect(_scroll_console_to_bottom)
	%SteamLoginButton.pressed.connect(_on_steam_login_pressed)
	%SteamSignOutButton.pressed.connect(_on_steam_sign_out_pressed)
	%AddDepotButton.pressed.connect(_on_add_depot_pressed)
	%FetchDepotsButton.pressed.connect(_on_fetch_depots_pressed)
	%CheckGodotButton.pressed.connect(_on_check_godot_pressed)
	%BrowseGodotButton.pressed.connect(func() -> void: %GodotDialog.popup_centered())
	%GodotDialog.file_selected.connect(_on_godot_binary_selected)
	%GodotDialog.dir_selected.connect(_on_godot_binary_selected)
	%DetectSteamCmdButton.pressed.connect(_on_detect_steamcmd_pressed)
	%BrowseSteamCmdButton.pressed.connect(func() -> void: %SteamCmdDialog.popup_centered())
	%SteamCmdDialog.file_selected.connect(_on_steamcmd_selected)
	%DownloadSteamCmdButton.pressed.connect(_on_download_steamcmd_pressed)
	%SteamCmdWebsiteButton.pressed.connect(func() -> void: OS.shell_open(STEAMCMD_DOCS_URL))
	%DetectButlerButton.pressed.connect(_on_detect_butler_pressed)
	%BrowseButlerButton.pressed.connect(func() -> void: %ButlerDialog.popup_centered())
	%ButlerDialog.file_selected.connect(_on_butler_selected)
	%DownloadButlerButton.pressed.connect(_on_download_butler_pressed)
	%ButlerWebsiteButton.pressed.connect(func() -> void: OS.shell_open(ButlerTool.DOCS_URL))
	%ItchSignInButton.pressed.connect(_on_itch_sign_in_pressed)
	%ItchSignOutButton.pressed.connect(_on_itch_sign_out_pressed)
	%ItchKeysPageButton.pressed.connect(func() -> void: OS.shell_open(ButlerTool.API_KEYS_URL))
	%ItchApi.profile_ready.connect(_on_itch_profile_ready)
	%ItchApi.profile_failed.connect(_on_itch_profile_failed)
	%ItchApi.games_ready.connect(_on_itch_games_ready)
	%ItchApi.games_failed.connect(_on_itch_games_failed)
	%SteamTargetToggle.toggled.connect(_on_target_toggled.bind("steam"))
	%ItchTargetToggle.toggled.connect(_on_target_toggled.bind("itch"))
	%ItchPageButton.pressed.connect(_on_itch_page_pressed)
	%RefreshItchButton.pressed.connect(_refresh_itch_game.bind(true))
	%ItchApi.cover_ready.connect(_on_itch_cover_ready)
	%ItchApi.cover_failed.connect(_on_itch_cover_failed)
	%ItchGameCard.resized.connect(_on_itch_card_resized)
	%ItchCoverImage.resized.connect(func() -> void:
		(%ItchCoverImage.material as ShaderMaterial).set_shader_parameter("size", %ItchCoverImage.size))
	%PickItchGameButton.about_to_popup.connect(_on_pick_itch_game_opening)
	%PickItchGameButton.get_popup().id_pressed.connect(_on_itch_game_picked)
	%InstallationGeneralButton.pressed.connect(_on_installation_general_pressed)
	%BuildsPageButton.pressed.connect(_on_builds_page_pressed)
	%DepotsPageButton.pressed.connect(_on_depots_page_pressed)
	%SteamAssets.header_ready.connect(_on_header_ready)
	%SteamAssets.header_failed.connect(_on_header_failed)
	%SteamAssets.app_id_found.connect(_on_app_id_found)
	%SteamProfile.profile_ready.connect(_on_profile_ready)
	%SteamProfile.profile_failed.connect(_on_profile_failed)
	%RefreshHeaderButton.pressed.connect(_refresh_steam_header.bind(true))
	%HeaderDebounce.timeout.connect(_on_app_id_settled)
	%SteamCard.resized.connect(_on_steam_card_resized)
	%HeaderImage.resized.connect(_update_header_shader_size)

	# Per-project fields write straight back into the selected project.
	%GodotBinary.text_changed.connect(func(t: String) -> void:
		_commit_field("godot_binary", t)
		_set_field_error(%GodotBinary, false)
	)
	%AppId.text_changed.connect(func(t: String) -> void:
		t = _digits_only(%AppId, t)
		_commit_field("app_id", t)
		_set_field_error(%AppId, false)
		_refresh_installation_link()
		%HeaderDebounce.start()
	)
	%Branch.text_changed.connect(func(t: String) -> void:
		_commit_field("branch", t)
		_set_field_error(%Branch, false)
	)
	%ItchTarget.text_changed.connect(func(t: String) -> void:
		_commit_field("itch_target", t.strip_edges())
		_set_field_error(%ItchTarget, false)
		_refresh_itch_game(false)
	)
	# A pasted game page address becomes user/game once the field is left.
	%ItchTarget.focus_exited.connect(_normalize_itch_target)
	%ItchTarget.text_submitted.connect(func(_t: String) -> void: _normalize_itch_target())
	%BuildDescription.text_changed.connect(func(t: String) -> void: _commit_field("description", t))
	# Plain Enter only leaves the field, so a stray Enter never starts an
	# upload; Cmd/Ctrl+Enter publishes (here and in _shortcut_input).
	%BuildDescription.text_submitted.connect(func(_t: String) -> void:
		if Input.is_key_pressed(KEY_META if OS.get_name() == "macOS" else KEY_CTRL):
			_on_build_publish_pressed()
	)

	# Global settings.
	%SteamCmdBinary.text_changed.connect(func(_t: String) -> void:
		_save_settings()
		_set_field_error(%SteamCmdBinary, false)
		_refresh_setup_state()
	)
	%SteamUsername.text_changed.connect(func(_t: String) -> void:
		_save_settings()
		_set_field_error(%SteamUsername, false)
		_refresh_setup_state()
	)
	%SteamPassword.text_changed.connect(func(_t: String) -> void:
		_save_settings()
		_set_field_error(%SteamPassword, false)
	)
	%SteamSharedSecret.text_changed.connect(func(_t: String) -> void:
		_save_settings()
		_check_shared_secret()
		_update_steam_header()
	)
	%RememberPassword.toggled.connect(func(_on: bool) -> void:
		_save_settings()
		_persist_secrets()
	)
	# Secrets are written when the field is left, not per keystroke: a
	# credential store round trip can take a second (PowerShell on Windows).
	%SteamPassword.focus_exited.connect(_persist_secrets)
	%SteamSharedSecret.focus_exited.connect(_persist_secrets)
	%SteamGuardCode.text_submitted.connect(func(_t: String) -> void:
		if _accepts_guard_code():
			_submit_guard_code()
		else:
			_on_steam_login_pressed()
	)
	%SteamGuardCode.text_changed.connect(func(_t: String) -> void: _set_field_error(%SteamGuardCode, false))
	%RememberSharedSecret.toggled.connect(func(_on: bool) -> void:
		_save_settings()
		_persist_secrets()
	)
	_bind_secret_toggle(%TogglePasswordVisible, %SteamPassword, "password")
	_bind_secret_toggle(%ToggleSecretVisible, %SteamSharedSecret, "shared secret")

	%ButlerBinary.text_changed.connect(func(_t: String) -> void:
		_save_settings()
		_set_field_error(%ButlerBinary, false)
		_refresh_setup_state()
	)
	%ItchApiKey.text_changed.connect(_on_itch_key_changed)
	%ItchApiKey.focus_exited.connect(_persist_secrets)
	%ItchApiKey.text_submitted.connect(func(_t: String) -> void: _on_itch_sign_in_pressed())
	%RememberItchKey.toggled.connect(func(_on: bool) -> void:
		_save_settings()
		_persist_secrets()
	)
	_bind_secret_toggle(%ToggleItchKeyVisible, %ItchApiKey, "API key")

	_steamcmd_http = _make_download_request(_on_steamcmd_download_completed)
	_butler_http = _make_download_request(_on_butler_download_completed)

	_secrets = {
		SECRET_PASSWORD: {"field": %SteamPassword, "remember": %RememberPassword, "label": "password"},
		SECRET_SHARED_SECRET: {"field": %SteamSharedSecret, "remember": %RememberSharedSecret, "label": "shared secret"},
		SECRET_ITCH_KEY: {"field": %ItchApiKey, "remember": %RememberItchKey, "label": "itch.io API key"},
	}
	_apply_secret_store_state()
	_load_settings()
	_auto_detect_steamcmd()
	_auto_detect_butler()
	_drop_line = Panel.new()
	_drop_line.theme_type_variation = &"Dot"
	_drop_line.self_modulate = Color(COLOR_OK)
	_drop_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drop_line.top_level = true
	_drop_line.visible = false
	add_child(_drop_line)

	_load_projects()
	_load_version_cache()
	_rebuild_sidebar()
	_show_project(-1)
	_check_shared_secret()
	_refresh_setup_state()
	if cli_mode:
		var cli := Cli.new()
		cli.name = "Cli"
		add_child(cli)
		cli.run.call_deferred(self, OS.get_cmdline_user_args())
		return
	_restore_window_state()
	%BuildPublishButton.tooltip_text = "%s (%s)" % [BUILD_TOOLTIP, _shortcut_label("Enter")]
	# Checkbox-style toggles whose "Remember" label is a separate node.
	%RememberPassword.accessibility_name = "Remember password"
	%RememberSharedSecret.accessibility_name = "Remember shared secret"
	%RememberItchKey.accessibility_name = "Remember itch.io API key"
	%SteamTargetToggle.accessibility_name = "Publish to Steam"
	%ItchTargetToggle.accessibility_name = "Publish to itch.io"
	%StatusBanner.get_node("BannerRow/DismissBannerButton").accessibility_name = "Dismiss message"
	_name_unlabeled_controls(self)
	log_line("%s ready." % _app_name(), COLOR_OK)


## Screen readers (AccessKit) announce a control by its accessibility_name.
## Icon-only buttons and fields without a label next to them in the tree have
## none, so they get their tooltip (or placeholder) text. Names set
## explicitly, like the ones the row builders give, are left alone.
func _name_unlabeled_controls(root: Node) -> void:
	for node in root.find_children("*", "Control", true, false):
		var c := node as Control
		if not c.accessibility_name.is_empty():
			continue
		if c is Button and (c as Button).text.is_empty():
			c.accessibility_name = c.tooltip_text
		elif c is LineEdit:
			c.accessibility_name = c.tooltip_text if not c.tooltip_text.is_empty() else (c as LineEdit).placeholder_text


## Render the UI at the OS scale factor so it is the same physical size on a
## Retina/HiDPI screen as on a 1x screen (Godot draws in device pixels when
## stretch mode is disabled). Runs with an unscaled window when embedded in
## the editor, whose panel owns the window size.
func _apply_display_scale() -> void:
	var ui_scale := DisplayServer.screen_get_scale()
	match OS.get_name():
		"Windows":
			ui_scale = DisplayServer.screen_get_dpi() / 96.0
		"Linux":
			ui_scale = maxf(ui_scale, DisplayServer.screen_get_dpi() / 96.0)
	ui_scale = clampf(snappedf(ui_scale, 0.25), 1.0, 3.0)

	var window := get_window()
	window.min_size = Vector2i(Vector2(MIN_WINDOW_SIZE) * ui_scale)
	window.content_scale_factor = ui_scale

	# Embedded game view: the "screen" is the editor panel – never resize it.
	if DisplayServer.screen_get_size() == DisplayServer.window_get_size():
		return
	# Never larger than the screen minus menu bar, Dock or taskbar (a 1440×900
	# window does not fit a 1366×768 laptop, nor 2× that a Retina Air).
	var usable := DisplayServer.screen_get_usable_rect(window.current_screen).size
	var target := (Vector2i(Vector2(1440, 900) * ui_scale)).min(usable)
	if window.size != target:
		window.size = target
		window.move_to_center()


## macOS: draw the app under the title bar so it takes the sidebar colour
## instead of the system grey. Only the traffic lights remain. Godot's view
## now owns the mouse under the title bar, so macOS no longer drags the window
## from there; an invisible full-width Control over the top strip does it
## instead (and handles double-click zoom). It draws nothing, so the window
## looks exactly the same.
func _apply_macos_titlebar() -> void:
	if OS.get_name() != "macOS":
		return
	# Embedded game view: the editor panel owns the window – leave it alone.
	if DisplayServer.screen_get_size() == DisplayServer.window_get_size():
		return
	var wid := get_window().get_window_id()
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_EXTEND_TO_TITLE, true, wid)
	var margin: int = %NavMargin.get_theme_constant("margin_top")
	%NavMargin.add_theme_constant_override("margin_top", margin + MACOS_TITLEBAR_HEIGHT)

	var strip := Control.new()
	strip.name = "TitlebarDragStrip"
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.offset_bottom = MACOS_TITLEBAR_HEIGHT
	strip.mouse_filter = Control.MOUSE_FILTER_STOP
	strip.gui_input.connect(_on_titlebar_gui_input.bind(wid))
	add_child(strip)  # Last child: receives clicks in the strip before the layout does.


func _on_titlebar_gui_input(event: InputEvent, wid: int) -> void:
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		return
	if event.double_click:
		var maximized := DisplayServer.window_get_mode(wid) == DisplayServer.WINDOW_MODE_MAXIMIZED
		var mode := DisplayServer.WINDOW_MODE_WINDOWED if maximized else DisplayServer.WINDOW_MODE_MAXIMIZED
		DisplayServer.window_set_mode(mode, wid)
	else:
		DisplayServer.window_start_drag(wid)
	get_viewport().set_input_as_handled()


func _on_window_resized() -> void:
	# Deferred: minimum_size_changed can fire mid-layout, before the combined
	# minimum sizes read in _console_fits are settled.
	_apply_console_visibility.call_deferred()


## True when sidebar, main content at its real minimum width and the console
## all fit side by side. MainView's scroll container never shows a horizontal
## bar, so its content minimum does not propagate up – ask the content directly.
## With [param expanded] the main view is hidden, so only sidebar and console
## have to fit.
func _console_fits(expanded := false) -> bool:
	var layout: HSplitContainer = $Layout
	var content: HSplitContainer = %ConsoleDock.get_parent()
	var needed: float = $Layout/Sidebar.get_combined_minimum_size().x \
		+ layout.get_theme_constant("separation") \
		+ %ConsoleDock.get_combined_minimum_size().x
	if not expanded:
		needed += _main_view_min_width() + content.get_theme_constant("separation")
	return size.x >= needed


## The main view's real minimum width. Its scroll container never shows a
## horizontal bar, so the content minimum does not propagate up – ask the
## widest content directly.
func _main_view_min_width() -> float:
	return maxf(maxf(
		%ContentMargin.get_combined_minimum_size().x,
		%ComposerMargin.get_combined_minimum_size().x),
		%ProjectHeaderMargin.get_combined_minimum_size().x)


## The console only shows when the user wants it and there is room for it.
func _apply_console_visibility() -> void:
	var expanded := _console_wanted and _console_expanded
	var fits := _console_fits(expanded)
	%ConsoleDock.visible = _console_wanted and fits
	%MainView.visible = not (expanded and fits)
	# Give the main view its real minimum while the console sits beside it, so
	# the divider stops there and window shrinks narrow the console first.
	var beside: bool = %ConsoleDock.visible and %MainView.visible
	%MainView.custom_minimum_size.x = _main_view_min_width() if beside else 0.0
	%ExpandConsoleButton.set_pressed_no_signal(_console_expanded)
	%ExpandConsoleButton.tooltip_text = "Restore layout" if _console_expanded else "Expand console"
	%ConsoleToggle.disabled = not fits
	%ConsoleToggle.set_pressed_no_signal(%ConsoleDock.visible)
	%ConsoleToggle.tooltip_text = "Window is too narrow for the console" if not fits else "Show or hide the console (%s)" % _shortcut_label("J")


# ---------------------------------------------------------------------------
# Sidebar / project switching
# ---------------------------------------------------------------------------

func _on_new_app_pressed() -> void:
	if not _setup_complete():
		# Never greyed out: pressing it explains what is missing instead.
		_show_project(-1)
		log_line(_setup_hint(), COLOR_WARN)
		return
	# "+" beside Apps is not in the group; mirror it onto New. Plain assignment
	# unpresses the group siblings, set_pressed_no_signal does not.
	%NewAppButton.button_pressed = true
	_refresh_sidebar_selection()
	%ProjectDialog.set_meta("browse", false)
	%ProjectDialog.popup_centered()


func _on_browse_pressed() -> void:
	%ProjectDialog.set_meta("browse", true)
	%ProjectDialog.popup_centered()


## Removing forgets the app's App ID, branch, itch.io game and build rows;
## nothing is deleted on disk, on Steam or on itch.io.
func _on_remove_project_pressed() -> void:
	if _selected_index < 0:
		return
	var p := _projects[_selected_index]
	if str(p.get("app_id", "")).is_empty() and str(p.get("itch_target", "")).is_empty() and (p["depots"] as Array).is_empty():
		_remove_project(p)  # Nothing set up yet, so nothing to lose.
		return
	_confirm("Remove %s?" % p["name"], "Its App ID, itch.io game and build settings are forgotten. Nothing is deleted on disk, on Steam or on itch.io.", "Remove", _remove_project.bind(p))


func _remove_project(p: Dictionary) -> void:
	var index := -1
	for i in _projects.size():
		if is_same(_projects[i], p):
			index = i
	if index < 0:
		return
	if index == _selected_index and _is_busy and _fetching_depots:
		# The fetch belongs to the app being removed. Cancelling here sets
		# _cancel_requested before _fetch_depots resumes, so its
		# _bail_if_cancelled() returns early and nothing is merged into
		# whatever is selected afterwards.
		_auto_fetch_pending = false
		_cancel_running()
	log_line("Removed %s from the list." % p["name"], COLOR_WARN)
	var row := _live_child(%ProjectList, index)
	_projects.remove_at(index)
	_save_projects()
	_show_project(-1)
	if row == null:
		_rebuild_sidebar()
		return
	# The other rows still point at the old indices until the rebuild.
	for child in %ProjectList.get_children():
		Motion.ignore_mouse(child)
	Motion.collapse(row, Motion.OUT, _rebuild_sidebar)


## Folders with a project.godot become Godot apps; any other folder becomes a
## "folder" app that is uploaded as-is (soundtracks, DLC, builds from other
## tools).
func _on_project_dir_selected(dir: String) -> void:
	dir = dir.simplify_path().rstrip("/")
	var is_godot := FileAccess.file_exists(dir.path_join("project.godot"))

	var is_browse: bool = %ProjectDialog.get_meta("browse", false)
	var same_folder := _project_index_for_path(dir)
	if same_folder >= 0 and not (is_browse and same_folder == _selected_index):
		# Allowed on purpose: a demo or playtest can ship from the same project
		# under its own App ID. Said out loud so a double-add is easy to spot.
		log_line("'%s' already uses %s. Both entries upload separately, which is right for a demo or playtest with its own App ID; otherwise remove one of them." % [_projects[same_folder]["name"], dir], COLOR_WARN)

	if is_browse and _selected_index >= 0:
		var p := _projects[_selected_index]
		if _is_folder_app(p) == is_godot:
			var was := "content folder" if _is_folder_app(p) else "Godot project"
			log_line("'%s' was added as a %s. To switch kinds, remove it and add the folder again." % [p["name"], was], COLOR_ERR)
			return
		var old_path: String = p["path"]
		ProjectIcons.invalidate(old_path)
		p["path"] = dir
		p["name"] = _read_project_name(dir)
		if _is_folder_app(p):
			var moved := 0
			for d in p["depots"]:
				if str(d.get("content_dir", "")) == old_path:
					d["content_dir"] = dir
					moved += 1
			if moved > 0:
				log_line("Moved %s that pointed at the old app folder." % _plural(moved, "depot folder"), COLOR_INFO)
		_finish_add_project()
	elif is_godot:
		var binary := await _guess_godot_binary(_read_required_godot_version(dir))
		_projects.insert(0, _new_project(dir, "godot", binary))
		_selected_index = 0
		_finish_add_project(true)
	else:
		_projects.insert(0, _new_project(dir, "folder", ""))
		_selected_index = 0
		log_line("No project.godot in %s — added '%s' as a content folder. Build and publish uploads the folder as-is, without a Godot export." % [dir, dir.get_file()], COLOR_INFO)
		_finish_add_project(true)


## A fresh app for [param dir]. Every target that is set up starts switched
## on, so the usual case (one storefront) needs no toggling.
func _new_project(dir: String, kind: String, binary: String) -> Dictionary:
	return _sanitize_project({
		"name": _read_project_name(dir) if kind == "godot" else dir.get_file(),
		"path": dir,
		"kind": kind,
		"godot_binary": binary,
		"steam_enabled": _steam_setup_complete(),
		"itch_enabled": _itch_setup_complete(),
	})


## Index of the app whose folder is [param dir], or -1.
func _project_index_for_path(dir: String) -> int:
	for i in _projects.size():
		if str(_projects[i]["path"]).simplify_path().rstrip("/") == dir:
			return i
	return -1


## Shared tail of adding or re-pointing the selected app: drop cached lookups
## for its name, persist, and show it. A newly [param added] app's row
## slides into the sidebar.
func _finish_add_project(added := false) -> void:
	_app_id_lookups_done.erase(_projects[_selected_index]["name"])
	var prefix: String = _projects[_selected_index]["name"] + "|"
	for key in _auto_depot_fetches.keys():
		if str(key).begins_with(prefix):
			_auto_depot_fetches.erase(key)
	_save_projects()
	_rebuild_sidebar()
	_show_project(_selected_index)
	var row := _live_child(%ProjectList, _selected_index)
	if added and row != null:
		Motion.grow_in(row, Motion.ROW_IN, Motion.ROW_SLIDE)


## Child [param index] of [param parent], not counting children a rebuild
## has queued for deletion (they stay in the list until the frame ends).
func _live_child(parent: Node, index: int) -> Control:
	var i := 0
	for child in parent.get_children():
		if child.is_queued_for_deletion():
			continue
		if i == index:
			return child as Control
		i += 1
	return null


## Fills in the App ID from the Steam store when the project name matches a
## published app exactly and the user has not typed an ID yet. Each name is
## looked up once per run.
func _suggest_app_id(p: Dictionary) -> void:
	var project_name: String = p["name"]
	if not str(p.get("app_id", "")).strip_edges().is_empty() or _app_id_lookups_done.has(project_name):
		return
	_app_id_lookups_done[project_name] = true
	log_line("Looking up '%s' on the Steam store for an App ID…" % project_name, COLOR_INFO)
	%SteamAssets.find_app_id(project_name)


func _on_app_id_found(project_name: String, app_id: String) -> void:
	if app_id.is_empty():
		log_line("No Steam app is named exactly '%s'; enter the App ID by hand." % project_name, COLOR_INFO)
		return
	# A second entry for the same project (a demo, a playtest) must not inherit
	# the main game's App ID, or its build would be uploaded to the wrong app.
	for other in _projects:
		if str(other.get("app_id", "")).strip_edges() == app_id:
			log_line("Steam lists '%s' as App %s, but '%s' already uses that App ID. Enter this app's own App ID by hand." % [project_name, app_id, other["name"]], COLOR_INFO)
			return
	for i in _projects.size():
		var p := _projects[i]
		if p["name"] != project_name:
			continue
		if not str(p.get("app_id", "")).strip_edges().is_empty():
			continue
		if p.get("app_id", "") == app_id:
			continue
		p["app_id"] = app_id
		log_line("Steam lists '%s' as App %s, filled it in." % [project_name, app_id], COLOR_OK)
		if i == _selected_index:
			%AppId.text = app_id  # Setting text does not emit text_changed.
			_set_field_error(%AppId, false)
			_refresh_installation_link()
			_refresh_steam_header(false)
			_maybe_auto_fetch_depots(app_id)
		break  # One App ID belongs to one entry (see the check above).
	_save_projects()


func _rebuild_sidebar() -> void:
	for child in %ProjectList.get_children():
		child.queue_free()

	for i in _projects.size():
		%ProjectList.add_child(_make_project_row(i, _projects[i]))
	if _projects.is_empty():
		var hint := Label.new()
		hint.theme_type_variation = &"Caption"
		hint.text = "No apps yet. Press + to add a Godot project, or a folder to upload as-is."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		%ProjectList.add_child(hint)
	_refresh_sidebar_selection()


## A sidebar row: project icon · project name · required Godot version.
## The Button itself has no text; the children ignore the mouse so hover and
## click land on the button, which keeps the ButtonGroup selection working.
func _make_project_row(index: int, p: Dictionary) -> Button:
	var btn := Button.new()
	btn.theme_type_variation = &"SidebarItem"
	btn.toggle_mode = true
	btn.button_group = _project_button_group
	btn.tooltip_text = p["path"]
	btn.accessibility_name = p["name"]
	btn.custom_minimum_size.y = 34
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.button_pressed = (index == _selected_index)
	btn.pressed.connect(_show_project.bind(index))
	btn.set_drag_forwarding(
		_get_row_drag_data.bind(index, btn),
		_can_drop_on_row.bind(btn),
		_drop_on_row.bind(btn))

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -10
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	btn.add_child(row)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(16, 16)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.texture = ProjectIcons.load_texture(p["path"])
	row.add_child(icon)

	var name_label := Label.new()
	name_label.text = p["name"]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 13)
	row.add_child(name_label)
	btn.set_meta("name_label", name_label)

	var version := Label.new()
	version.theme_type_variation = &"Caption"
	if _is_folder_app(p):
		version.text = "Folder"
	elif not _project_file_exists(p):
		version.text = "Missing"
		version.add_theme_color_override("font_color", Color(COLOR_WARN))
		btn.tooltip_text = "Project not found at %s — select it and click its name to point at the new location" % p["path"]
	else:
		version.text = _read_required_godot_version(p["path"])
	version.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(version)
	return btn


# --- Drag-to-reorder -------------------------------------------------------

## Drag payload for a sidebar row plus a translucent ghost of the row that
## follows the cursor.
func _get_row_drag_data(_at: Vector2, index: int, btn: Button) -> Variant:
	if index < 0 or index >= _projects.size():
		return null
	var ghost := _make_project_row(index, _projects[index])
	ghost.button_group = null  # Must not steal the real selection.
	ghost.toggle_mode = false
	ghost.button_pressed = false
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.custom_minimum_size = btn.size
	ghost.size = btn.size
	ghost.modulate.a = 0.7
	btn.set_drag_preview(ghost)
	return {"type": "project_row", "index": index}


## Called continuously while a drag hovers a row: also moves the drop line.
func _can_drop_on_row(at: Vector2, data: Variant, btn: Button) -> bool:
	if not (data is Dictionary and data.get("type") == "project_row"):
		return false
	var below := at.y > btn.size.y * 0.5
	_drop_line.size = Vector2(btn.size.x, 2)
	_drop_line.global_position = Vector2(
		btn.global_position.x,
		btn.global_position.y + (btn.size.y if below else 0.0) - 1.0)
	_drop_line.visible = true
	return true


func _drop_on_row(at: Vector2, data: Variant, btn: Button) -> void:
	_drop_line.visible = false
	# Position of the target among the sidebar rows.
	var to := 0
	for child in %ProjectList.get_children():
		if child == btn:
			break
		if child is Button and not child.is_queued_for_deletion():
			to += 1
	if at.y > btn.size.y * 0.5:
		to += 1
	_move_project(int(data["index"]), to)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drop_line != null:
		_drop_line.visible = false
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _publishing.is_empty():
			_quit()
		else:
			_confirm("Quit while publishing?", "The upload of %s stops and %s the previous build." % [_publishing["name"], _stores_keep_text(_publishing)], "Quit", _quit)


## App-wide shortcuts, Cmd on macOS and Ctrl elsewhere: Enter publishes the
## app on screen (or asks to stop the run), N adds an app, J toggles the console.
func _shortcut_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or not key.is_command_or_control_pressed() or key.shift_pressed or key.alt_pressed:
		return
	match key.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if _selected_index >= 0 and not %BuildPublishButton.disabled:
				_on_build_publish_pressed()
		KEY_N:
			if not %AddAppButton.disabled:
				_on_new_app_pressed()
		KEY_J:
			if not %ConsoleToggle.disabled:
				_set_console_visible(not %ConsoleDock.visible)
		_:
			return
	get_viewport().set_input_as_handled()


## "⌘N" on macOS, "Ctrl+N" elsewhere.
static func _shortcut_label(key: String) -> String:
	return ("⌘" if OS.get_name() == "macOS" else "Ctrl+") + key


func _quit() -> void:
	_save_window_state()
	_stop_children_for_quit()
	_flush_secrets()
	get_tree().quit()


## The window as the user left it: rect, dividers, console and the app on
## screen. Nothing is saved when embedded in the editor, whose panel owns
## the window.
func _save_window_state() -> void:
	if _is_embedded():
		return
	var wid := get_window().get_window_id()
	var cfg := ConfigFile.new()
	cfg.set_value("window", "maximized", DisplayServer.window_get_mode(wid) == DisplayServer.WINDOW_MODE_MAXIMIZED)
	cfg.set_value("window", "position", DisplayServer.window_get_position(wid))
	cfg.set_value("window", "size", DisplayServer.window_get_size(wid))
	cfg.set_value("layout", "sidebar", int($Layout.split_offset))
	cfg.set_value("layout", "console", int((%ConsoleDock.get_parent() as HSplitContainer).split_offset))
	cfg.set_value("layout", "console_open", _console_wanted)
	cfg.set_value("layout", "app", _selected_index)
	_report_save(cfg.save(WINDOW_FILE), WINDOW_FILE)


## Puts back what _save_window_state wrote. A rect that no longer fits any
## screen (monitor unplugged, resolution changed) is dropped for the default
## centred one; one that is only too big is shrunk to the screen.
func _restore_window_state() -> void:
	var cfg := ConfigFile.new()
	if _is_embedded() or cfg.load(WINDOW_FILE) != OK:
		return
	var pos: Variant = cfg.get_value("window", "position", null)
	var sz: Variant = cfg.get_value("window", "size", null)
	if pos is Vector2i and sz is Vector2i:
		var rect := Rect2i(pos, sz)
		for screen in DisplayServer.get_screen_count():
			var usable := DisplayServer.screen_get_usable_rect(screen)
			if usable.has_point(rect.get_center()):
				rect.size = rect.size.min(usable.size)
				rect.position = rect.position.clamp(usable.position, usable.end - rect.size)
				var window := get_window()
				window.size = rect.size
				window.position = rect.position
				break
	if _as_bool(cfg.get_value("window", "maximized", false)):
		get_window().mode = Window.MODE_MAXIMIZED
	var sidebar: Variant = cfg.get_value("layout", "sidebar", null)
	if sidebar is int:
		$Layout.split_offset = sidebar
		_clamp_sidebar_split(sidebar)
	var console: Variant = cfg.get_value("layout", "console", null)
	if console is int:
		(%ConsoleDock.get_parent() as HSplitContainer).split_offset = console
	_set_console_visible(_as_bool(cfg.get_value("layout", "console_open", true)))
	var app: Variant = cfg.get_value("layout", "app", -1)
	if app is int and app >= 0 and app < _projects.size() and _setup_complete():
		_show_project(app)


## Running inside the editor's game panel instead of a window of its own.
func _is_embedded() -> bool:
	return DisplayServer.screen_get_size() == DisplayServer.window_get_size()


## Asks before a destructive action; [param on_ok] runs only on confirm.
## Cancel is the default button, so a stray Enter or double-click keeps going.
## Uses the system alert where there is one, like the native file dialogs.
func _confirm(title: String, text: String, ok_text: String, on_ok: Callable) -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG):
		DisplayServer.dialog_show(title, text, PackedStringArray(["Cancel", ok_text]), func(button: int) -> void:
			if button == 1:
				on_ok.call()
		)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.dialog_text = text
	dialog.dialog_autowrap = true
	dialog.ok_button_text = ok_text
	dialog.content_scale_factor = get_window().content_scale_factor
	dialog.confirmed.connect(on_ok)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free()
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(Vector2(420, 0) * dialog.content_scale_factor))
	dialog.get_cancel_button().grab_focus()


func _exit_tree() -> void:
	_stop_children_for_quit()  # Quit paths that skip the close request.
	# The fields have left the tree already (their %names no longer resolve),
	# so only a running secret write is waited for; the close request flushed.
	_secrets_dirty = false
	_finish_secret_write()


## Quitting stops whatever runs (a publish only after _confirm): the
## child (and everything it started) is killed so no SteamCMD or Godot keeps
## running without a window, a partial SteamCMD download is removed and the
## pipe readers are joined. Safe to call more than once.
func _stop_children_for_quit() -> void:
	_kill_child()
	if _steamcmd_downloading and is_instance_valid(_steamcmd_http):
		_steamcmd_http.cancel_request()
		_steamcmd_downloading = false
		if not _steamcmd_archive.is_empty():
			DirAccess.remove_absolute(_steamcmd_archive)
	if _butler_downloading and is_instance_valid(_butler_http):
		_butler_http.cancel_request()
		_butler_downloading = false
		if not _butler_archive.is_empty():
			DirAccess.remove_absolute(_butler_archive)
	OS.unset_environment("BUTLER_API_KEY")  # Never outlives a launch; belt and braces.
	_reader_stop = true
	for t in _reader_threads:
		if t.is_started():
			t.wait_to_finish()
	_reader_threads.clear()


## Moves project [param from] to insertion slot [param to] (0.._projects.size()),
## keeping the currently selected project selected.
func _move_project(from: int, to: int) -> void:
	if to > from:
		to -= 1
	if from == to or from < 0 or from >= _projects.size():
		return
	to = clampi(to, 0, _projects.size() - 1)
	var p := _projects[from]
	_projects.remove_at(from)
	_projects.insert(to, p)
	if _selected_index == from:
		_selected_index = to
	elif from < _selected_index and to >= _selected_index:
		_selected_index -= 1
	elif from > _selected_index and to <= _selected_index:
		_selected_index += 1
	_save_projects()
	_rebuild_sidebar()


## Selected row gets the bright text colour, the rest stay secondary.
func _refresh_sidebar_selection() -> void:
	for child in %ProjectList.get_children():
		if child is Button and child.has_meta("name_label"):
			var label: Label = child.get_meta("name_label")
			label.add_theme_color_override("font_color", Color(COLOR_TEXT) if child.button_pressed else Color(COLOR_TEXT_2))


## Switch the main view to project [param index]; -1 shows the Setup page
## (itch.io, SteamCMD and the accounts), which also carries the Discord
## community section.
func _show_project(index: int) -> void:
	_selected_index = index
	var has_project := index >= 0 and index < _projects.size()
	%SetupPage.visible = not has_project
	%ProjectSettings.visible = has_project
	%ProjectHeaderButton.visible = has_project
	%RemoveProjectButton.visible = has_project
	%SetupHeaderRow.visible = not has_project
	%ComposerBox.visible = has_project
	_godot_status = {}
	_run_status = {}
	_target_status.clear()
	_dismissed_banners.clear()
	# The new page's banners appear at once; see _refresh_banners.
	for child in %StatusStack.get_children():
		if child != %StatusBanner:
			child.queue_free()
	_banners_reset_frame = Engine.get_process_frames()
	%StatusStack.visible = false
	%SteamCmdButton.set_pressed_no_signal(not has_project)
	%NewAppButton.set_pressed_no_signal(false)  # Any real selection ends the pending "New" state.
	%SteamChevron.texture = ARROW_DOWN if not has_project else ARROW_RIGHT
	%ItchChevron.texture = %SteamChevron.texture
	_clear_project_errors()
	_refresh_sidebar_selection()
	_apply_build_lock()
	if not has_project:
		%HeaderDebounce.stop()
		_refresh_setup_state()
		if not cli_mode:
			_refresh_discord(false)
		return

	var p := _projects[index]
	%ProjectTitle.text = p["name"]
	%TitleMark.texture = ProjectIcons.load_texture(p["path"])
	%ProjectHeaderButton.tooltip_text = p["path"]
	%GodotBinary.text = p.get("godot_binary", "")
	%AppId.text = p.get("app_id", "")
	_refresh_installation_link()
	%Branch.text = p.get("branch", "")
	%BuildDescription.text = p.get("description", "")
	%ItchTarget.text = p.get("itch_target", "")
	_refresh_itch_page_link()

	var folder := _is_folder_app(p)
	%GodotSection.visible = not folder
	_apply_targets(p)
	_apply_depot_table_kind(folder)
	if folder:
		_preset_names = PackedStringArray()
		_preset_platforms = PackedStringArray()
		_probe_serial += 1  # Drop any in-flight Godot probe from the previous selection.
		_rebuild_depot_rows()
		_refresh_banners()
	else:
		_read_presets(p["path"])
		if not _project_file_exists(p):
			log_line(_missing_project_message(p), COLOR_WARN)
		elif not _has_presets():
			log_line("'%s' has no export presets. Open it in Godot → Project → Export… and add one, then reselect the project." % p["name"], COLOR_WARN)
		_rebuild_depot_rows()
		_check_godot_version()

	log_line("Selected app: %s" % p["name"], COLOR_INFO)
	# The command line uses the app as configured: no store lookups that fill
	# in the App ID or depots, and no capsule download.
	if _steam_on(p) and not cli_mode:
		_refresh_steam_header(false)
		_suggest_app_id(p)
		_maybe_auto_fetch_depots(_current_app_id())


## Rebuilds the banners above the build bar: one per thing the user should fix
## before publishing, errors first. %StatusBanner is the hidden template.
## Runs often (every edit that can change a warning), so it updates the stack
## in place: banners that still apply stay, new ones grow in and the ones
## that no longer apply (or were dismissed) shrink away.
func _refresh_banners() -> void:
	var wanted: Array[Dictionary] = []
	if _selected_index >= 0:
		for msg in _status_messages():
			if not _dismissed_banners.has(msg["text"]):
				wanted.append(msg)
	var instant := Engine.get_process_frames() == _banners_reset_frame
	# Slot in the stack (the banner, or its holder while it grows in) per text.
	var slots := {}
	var leaving := 0
	for child in %StatusStack.get_children():
		var banner := Motion.row_of(child)
		if banner == %StatusBanner or child.is_queued_for_deletion():
			continue
		if banner.has_meta("leaving"):
			leaving += 1
		else:
			slots[banner.get_meta("banner_text", "")] = child
	var wanted_texts := {}
	for msg in wanted:
		wanted_texts[msg["text"]] = true
	for text: String in slots:
		if wanted_texts.has(text):
			continue
		var slot: Control = slots[text]
		if instant or slot != Motion.row_of(slot):
			slot.queue_free()  # Another app's banner, or one still growing in.
		else:
			slot.set_meta("leaving", true)
			leaving += 1
			Motion.collapse(slot, Motion.OUT, _refresh_banners)
	var ordered: Array[Control] = []
	var fresh: Array[Control] = []
	for msg in wanted:
		var slot: Control = slots.get(msg["text"])
		if slot == null:
			slot = _make_banner(msg)
			%StatusStack.add_child(slot)
			fresh.append(slot)
		else:
			(Motion.row_of(slot).get_node("BannerRow/BannerDot") as Control).self_modulate = Color(msg["color"])
		ordered.append(slot)
	# Errors come first: reorder only when a new banner broke that order.
	var current := ordered.duplicate()
	current.sort_custom(func(a: Control, b: Control) -> bool: return a.get_index() < b.get_index())
	if current != ordered:
		for slot in ordered:
			%StatusStack.move_child(slot, -1)
	if not instant:
		for banner in fresh:
			Motion.grow_in(banner, Motion.BANNER_IN)
	%StatusStack.visible = not wanted.is_empty() or leaving > 0


## A copy of the hidden %StatusBanner template for [param msg].
func _make_banner(msg: Dictionary) -> Control:
	var banner: Control = %StatusBanner.duplicate()
	banner.unique_name_in_owner = false
	banner.set_meta("banner_text", msg["text"])
	var label: Label = banner.get_node("BannerRow/BannerLabel")
	label.text = msg["text"]
	var dot: Control = banner.get_node("BannerRow/BannerDot")
	dot.self_modulate = Color(msg["color"])
	var close: Button = banner.get_node("BannerRow/DismissBannerButton")
	close.accessibility_name = "Dismiss message"
	close.pressed.connect(_on_banner_closed.bind(msg["text"], msg.get("id", "")))
	banner.visible = true
	return banner


## Every banner for the selected app as { "text", "color", "id" }, errors
## before warnings. A missing project folder hides the rest: nothing else can
## be checked until it is found.
func _status_messages() -> Array[Dictionary]:
	var p := _projects[_selected_index]
	var folder := _is_folder_app(p)
	var all: Array[Dictionary] = []
	if not _failed_saves.is_empty():
		all.append({ "text": "Changes can't be saved and are lost when you quit. Free up disk space; the console has details.", "color": COLOR_ERR })
	if not folder and not _project_file_exists(p):
		all.append({ "text": _missing_project_message(p), "color": COLOR_ERR })
		return all
	if not _godot_status.is_empty():
		all.append(_godot_status)
	if not _run_status.is_empty():
		all.append(_run_status)
	all.append_array(_target_status)
	if not _steam_on(p) and not _itch_on(p):
		all.append({ "text": "Pick where this app publishes: tick Steam, itch.io or both in their section headers.", "color": COLOR_WARN })
	if not folder and not _has_presets():
		all.append({ "text": "No export presets found. Open the project in Godot → Project → Export… and add a preset, then reselect the project.", "color": COLOR_WARN })
	var dupes := _duplicate_depot_ids() if _steam_on(p) else PackedStringArray()
	if not dupes.is_empty():
		all.append({ "text": _duplicate_depot_message(dupes), "color": COLOR_WARN })
	var channel_dupes := _duplicate_itch_channels(p) if _itch_on(p) else PackedStringArray()
	if not channel_dupes.is_empty():
		all.append({ "text": _duplicate_channel_message(channel_dupes), "color": COLOR_WARN })
	if folder:
		var missing := _missing_depot_folder(p)
		if not missing.is_empty():
			all.append({ "text": "A depot points at a folder that does not exist: %s" % missing, "color": COLOR_WARN })
		if not p.get("folder_notice_dismissed", false):
			all.append({ "text": FOLDER_APP_NOTICE, "color": COLOR_WARN, "id": "folder_notice" })
	var errors: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	for msg in all:
		if msg["color"] == COLOR_ERR:
			errors.append(msg)
		else:
			warnings.append(msg)
	errors.append_array(warnings)
	return errors


## Hides one banner while this app is on screen; closing the folder-app notice
## hides it for that app for good.
func _on_banner_closed(text: String, id: String) -> void:
	_dismissed_banners[text] = true
	if id == "folder_notice" and _selected_index >= 0:
		_projects[_selected_index]["folder_notice_dismissed"] = true
		_save_projects()
	_refresh_banners()


func _commit_field(key: String, value: String) -> void:
	if _selected_index < 0:
		return
	_projects[_selected_index][key] = value
	_save_projects()


## Sets the build description field and saves it for the selected project.
## Setting LineEdit.text from code does not emit text_changed, so the commit is explicit.
func _set_description(text: String) -> void:
	%BuildDescription.text = text
	_commit_field("description", text)


# ---------------------------------------------------------------------------
# Form validation
# ---------------------------------------------------------------------------

## Strips everything but 0-9 from an ID field as the user types or pastes and
## caps it at ID_MAX_DIGITS, keeping the caret in place. Returns the cleaned
## text. Not LineEdit.max_length: that cuts a paste like "App ID: 2807130"
## before the letters are gone. Setting text from code does not re-emit
## text_changed, so this is safe inside that handler.
func _digits_only(field: LineEdit, text: String) -> String:
	var clean := ""
	var removed_before_caret := 0
	for i in text.length():
		var c := text[i]
		if c >= "0" and c <= "9":
			clean += c
		elif i < field.caret_column:
			removed_before_caret += 1
	clean = clean.left(ID_MAX_DIGITS)
	if clean == text:
		return text
	var caret := mini(field.caret_column - removed_before_caret, clean.length())
	field.text = clean
	field.caret_column = caret
	return clean


## Draws (or removes) the red border on a field that failed validation.
func _set_field_error(control: Control, error: bool) -> void:
	if control is OptionButton:
		control.theme_type_variation = ERROR_OPTION if error else &""
	else:
		control.theme_type_variation = ERROR_FIELD if error else &""


## Forgets every red mark on the per-project fields (switching project).
func _clear_project_errors() -> void:
	_depot_errors.clear()
	_set_field_error(%GodotBinary, false)
	_set_field_error(%AppId, false)
	_set_field_error(%Branch, false)
	_set_field_error(%ItchTarget, false)


func _mark_depot_error(index: int, key: String) -> void:
	if not _depot_errors.has(index):
		_depot_errors[index] = {}
	_depot_errors[index][key] = true


func _clear_depot_error(index: int, key: String) -> void:
	if _depot_errors.has(index):
		_depot_errors[index].erase(key)


## Checks the Steam account fields both Sign in and Build & Publish need,
## marks the failing ones red and shows the Setup page so they are visible.
func _validate_login_fields() -> bool:
	var ok := true
	var username: String = %SteamUsername.text.strip_edges()
	if username.is_empty():
		log_line("Enter a Steam username.", COLOR_ERR)
		auth_needed = auth_needed or cli_mode
		_set_field_error(%SteamUsername, true)
		%SteamUsername.grab_focus()
		ok = false
	elif "@" in username:
		# Only a warning: Steam decides, but SteamCMD wants the account name.
		log_line("'%s' looks like an email address. SteamCMD signs in with the Steam account name (shown top right in the Steam client, under Account details), not the email." % username, COLOR_WARN)
	var secret: String = %SteamSharedSecret.text
	if not secret.strip_edges().is_empty() and steam_totp(secret).is_empty():
		log_line("The shared secret is not valid (it must be the base64 shared_secret of the account). Leave the field empty unless you know you need it; Steam Guard codes from the mobile app or email work without it.", COLOR_ERR)
		_set_field_error(%SteamSharedSecret, true)
		ok = false
	if not _validate_steamcmd_field():
		ok = false
	if not ok and not %SetupPage.visible and not cli_mode:
		_show_project(-1)  # Put the red-marked fields on screen.
	return ok


## Checks what an itch.io upload needs on the Setup page: butler and a
## signed-in API key. Marks the failing fields red and shows the page.
func _validate_itch_setup() -> bool:
	var ok := true
	if _resolve_butler(%ButlerBinary.text).is_empty():
		log_line("butler, itch.io's upload tool, is not set up. Press Download butler or Find on the Setup page.", COLOR_ERR)
		_set_field_error(%ButlerBinary, true)
		ok = false
	if %ItchApiKey.text.strip_edges().is_empty():
		log_line("Paste your itch.io API key on the Setup page (itch.io → Settings → API keys) and press Sign in.", COLOR_ERR)
		_set_field_error(%ItchApiKey, true)
		auth_needed = auth_needed or cli_mode
		ok = false
	elif not _itch_ok():
		log_line("The itch.io API key is not checked yet. Press Sign in on the itch.io card of the Setup page.", COLOR_ERR)
		_set_field_error(%ItchApiKey, true)
		auth_needed = auth_needed or cli_mode
		ok = false
	if not ok and not %SetupPage.visible and not cli_mode:
		_show_project(-1)  # Put the red-marked fields on screen.
	return ok


## Checks only that SteamCMD can be resolved, marks the field red and shows the
## Setup page when it cannot. Used by the Depots Fetch button, which can run anonymously.
func _validate_steamcmd_field() -> bool:
	var ok := true
	if _resolve_steamcmd(%SteamCmdBinary.text).is_empty():
		log_line("SteamCMD not found. Use Download SteamCMD or Find, or the folder button next to the path.", COLOR_ERR)
		_set_field_error(%SteamCmdBinary, true)
		ok = false
	if not ok and not %SetupPage.visible and not cli_mode:
		_show_project(-1)  # Put the red-marked fields on screen.
	return ok


## Checks everything Build & Publish needs for the app's enabled targets,
## marks every failing field red and logs one line per problem. Duplicate
## depot IDs only warn.
func _validate_publish_form() -> bool:
	var p := _projects[_selected_index]
	var steam := _steam_on(p)
	var itch := _itch_on(p)
	_depot_errors.clear()
	var ok := _validate_common(p)
	if not steam and not itch:
		log_line("Tick Steam, itch.io or both in their section headers, so the build has somewhere to go.", COLOR_ERR)
		ok = false

	var space_left := _free_disk_bytes()
	if space_left >= 0 and space_left < LOW_DISK_BYTES:
		log_line("Only %s of disk space is left in %s. Exports and uploads need room for a full copy of the game; free up space if the build fails." % [String.humanize_size(space_left), OS.get_user_data_dir()], COLOR_WARN)

	# Last: a missing sign-in switches to the Setup page to show the fields.
	if steam and not _validate_steam(p):
		ok = false
	if itch and not _validate_itch(p):
		ok = false
	_rebuild_depot_rows()
	return ok


## "Row 2 (Windows Desktop)" for build row [param i] in console messages.
func _row_label(p: Dictionary, i: int) -> String:
	var d: Dictionary = p["depots"][i]
	var what := str(d.get("content_dir", "")).get_file() if _is_folder_app(p) else str(d.get("preset", ""))
	return "Row %d%s" % [i + 1, " (%s)" % what if not what.is_empty() else ""]


## Checks shared by every target: the project, the Godot binary and the build
## rows' presets, executable names and folders.
func _validate_common(p: Dictionary) -> bool:
	var depots: Array = p["depots"]
	var godot: String = p.get("godot_binary", "")
	var folder := _is_folder_app(p)
	var ok := true

	if not folder and not _project_file_exists(p):
		log_line(_missing_project_message(p), COLOR_ERR)
		ok = false

	if not folder:
		if godot.is_empty():
			log_line("Pick a Godot binary, or press Find.", COLOR_ERR)
			_set_field_error(%GodotBinary, true)
			ok = false
		elif not FileAccess.file_exists(godot):
			log_line("Godot binary not found: %s. It was moved or deleted. Press Find, or pick it with the folder button." % godot, COLOR_ERR)
			_set_field_error(%GodotBinary, true)
			ok = false
		elif not _is_executable_file(godot):
			log_line("%s is not marked as executable. Run  chmod +x \"%s\"  in a terminal, or pick the Godot program itself." % [godot, godot], COLOR_ERR)
			_set_field_error(%GodotBinary, true)
			ok = false
		elif _is_csharp_project(p["path"]) and not _is_dotnet_godot(godot):
			log_line("This is a C# project, but %s is the standard Godot build. Pick the .NET build of Godot %s, or the scripts will be missing from the export." % [godot.get_file(), _read_required_godot_version(p["path"])], COLOR_WARN)
	if depots.is_empty():
		log_line("Add at least one build row (the + button%s)." % (", or Fetch to read the depots from Steam" if _steam_on(p) else ""), COLOR_ERR)
		ok = false
	if not folder and _project_file_exists(p) and not _has_presets():
		log_line("No export presets found in %s. Add one in Godot → Project → Export… first." % p["path"].path_join("export_presets.cfg"), COLOR_ERR)
		ok = false

	var row_incomplete := false
	for i in depots.size():
		var d: Dictionary = depots[i]
		var row := _row_label(p, i)
		if folder:
			var content_dir := str(d.get("content_dir", "")).strip_edges()
			if content_dir.is_empty():
				_mark_depot_error(i, "content_dir")
				row_incomplete = true
			elif not DirAccess.dir_exists_absolute(content_dir):
				_mark_depot_error(i, "content_dir")
				log_line("Row %d: folder not found: %s. It was moved or deleted — pick it again with the folder button." % [i + 1, content_dir], COLOR_ERR)
				ok = false
			elif _dir_is_empty(content_dir):
				_mark_depot_error(i, "content_dir")
				log_line("Row %d: %s is empty, so nothing would be uploaded. Put the files to ship in it, or pick another folder." % [i + 1, content_dir], COLOR_ERR)
				ok = false
			elif content_dir.rstrip("/") in ["", _home_dir().rstrip("/")]:
				log_line("Row %d uploads %s, your whole %s. Pick the folder that holds only the files to ship." % [i + 1, content_dir, "disk" if content_dir.rstrip("/").is_empty() else "home folder"], COLOR_WARN)
			continue
		var preset := str(d.get("preset", ""))
		var preset_index := _preset_names.find(preset)
		if preset.strip_edges().is_empty():
			_mark_depot_error(i, "preset")
			row_incomplete = true
		elif _has_presets() and preset_index < 0:
			_mark_depot_error(i, "preset")
			log_line("%s: export preset '%s' no longer exists (renamed or deleted in Godot). Pick a preset in the row." % [row, preset], COLOR_ERR)
			ok = false
		var kind := _platform_kind(preset_index)
		if kind == "web":
			if not _itch_on(p) or str(d.get("itch_channel", "")).strip_edges().is_empty():
				_mark_depot_error(i, "preset")
				log_line("%s is a web build. Steam cannot run web builds; publish it to itch.io (switch on itch.io and give the row a channel) or pick a desktop preset." % row, COLOR_ERR)
				ok = false
			elif _web_preset_uses_threads(p["path"], preset_index):
				log_line("%s uses thread support, so on itch.io the game only starts with 'SharedArrayBuffer support' switched on (edit page → Embed options). Or turn off Thread Support in the Web preset." % row, COLOR_WARN)
			continue  # Web exports are always index.html; there is no name to check.
		var output := str(d.get("output", ""))
		var why := _invalid_file_name_reason(output)
		if output.strip_edges().is_empty():
			_mark_depot_error(i, "output")
			row_incomplete = true
		elif not why.is_empty():
			_mark_depot_error(i, "output")
			log_line("%s: executable name '%s' %s. Use letters, digits, '-' and '_'." % [row, output, why], COLOR_ERR)
			ok = false
	if row_incomplete:
		log_line("Every row needs a folder." if folder else "Every row needs an export preset and an executable name.", COLOR_ERR)
		ok = false
	return ok


## True when the Web preset at [param preset_index] of the project's
## export_presets.cfg exports with thread support, which browsers only run
## with cross-origin isolation (itch.io's SharedArrayBuffer option).
static func _web_preset_uses_threads(project_path: String, preset_index: int) -> bool:
	var cfg := ConfigFile.new()
	if preset_index < 0 or cfg.load(project_path.path_join("export_presets.cfg")) != OK:
		return false
	return _as_bool(cfg.get_value("preset.%d.options" % preset_index, "variant/thread_support", false))


## True when the preset named [param preset_name] in the project's
## export_presets.cfg has the shader baker on.
static func _preset_bakes_shaders(project_path: String, preset_name: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(project_path.path_join("export_presets.cfg")) != OK:
		return false
	var i := 0
	while cfg.has_section("preset.%d" % i):
		if str(cfg.get_value("preset.%d" % i, "name", "")) == preset_name:
			return _as_bool(cfg.get_value("preset.%d.options" % i, "shader_baker/enabled", false))
		i += 1
	return false


## Steam's part of the check: App ID, branch, depot IDs and the SteamCMD login.
func _validate_steam(p: Dictionary) -> bool:
	var depots: Array = p["depots"]
	var ok := true
	var app_id := str(p.get("app_id", "")).strip_edges()
	if app_id.is_empty():
		log_line("Steam App ID is required. It is the number in your app's Steamworks page address, e.g. partner.steamgames.com/apps/landing/480.", COLOR_ERR)
		_set_field_error(%AppId, true)
		ok = false
	elif not _is_positive_int(app_id):
		log_line("App ID '%s' is not a number. Use only the digits of the App ID shown in Steamworks." % app_id, COLOR_ERR)
		_set_field_error(%AppId, true)
		ok = false
	else:
		for other in _projects:
			if not is_same(other, p) and _steam_on(other) and str(other.get("app_id", "")).strip_edges() == app_id:
				log_line("'%s' uses App %s too. A demo or playtest has its own App ID in Steamworks; check that this is the app you mean to upload to." % [other["name"], app_id], COLOR_WARN)
				break

	var branch := _branch_name(p)
	if branch.to_lower() in ["default", "public"]:
		# Steamworks calls the default branch "default", build scripts "public".
		log_line("Steam doesn't let tools set builds live on the default branch ('default' in Steamworks, 'public' in build scripts); on a released game it refuses with 'Access Denied' after the whole upload. Leave 'Set live on branch' empty, upload, then set the build live in Steamworks → Builds.", COLOR_ERR)
		_set_field_error(%Branch, true)
		ok = false
	elif " " in branch or "\"" in branch or "'" in branch:
		log_line("Branch '%s' contains spaces or quotes. Type the branch name exactly as it is listed in Steamworks → SteamPipe → Builds (e.g. beta), or leave the field empty." % branch, COLOR_ERR)
		_set_field_error(%Branch, true)
		ok = false

	var steam_rows := 0
	var missing_id := false
	for i in depots.size():
		var d: Dictionary = depots[i]
		if _row_kind(p, d) == "web":
			continue
		steam_rows += 1
		var depot_id := str(d.get("depot_id", "")).strip_edges()
		if depot_id.is_empty():
			_mark_depot_error(i, "depot_id")
			missing_id = true
		elif not _is_positive_int(depot_id):
			_mark_depot_error(i, "depot_id")
			log_line("Depot ID '%s' is not a number. Copy the depot ID from Steamworks → SteamPipe → Depots." % depot_id, COLOR_ERR)
			ok = false
		elif depot_id == app_id:
			_mark_depot_error(i, "depot_id")
			log_line("Depot ID %s is the App ID. Depots have their own IDs, listed in Steamworks → SteamPipe → Depots (usually the App ID + 1, + 2, …)." % depot_id, COLOR_ERR)
			ok = false
	if missing_id:
		log_line("Every row Steam gets needs a depot ID (Fetch reads them from Steam).", COLOR_ERR)
		ok = false
	if steam_rows == 0 and not depots.is_empty():
		log_line("Steam gets nothing: every row is a web build. Add a Windows, macOS or Linux row, or switch Steam off for this app.", COLOR_ERR)
		ok = false

	var dupes := _duplicate_depot_ids()
	if not dupes.is_empty():
		log_line(_duplicate_depot_message(dupes), COLOR_WARN)
		for i in depots.size():
			if dupes.has(str(depots[i].get("depot_id", "")).strip_edges()):
				_mark_depot_error(i, "depot_id")

	if not _validate_login_fields():
		ok = false
	return ok


## itch.io's part of the check: the game, the channels, butler and the key.
func _validate_itch(p: Dictionary) -> bool:
	var depots: Array = p["depots"]
	var ok := true
	var target := str(p.get("itch_target", "")).strip_edges()
	if not ButlerTool.target_from_url(target).is_empty():
		# A pasted game page address: use its user/game.
		target = ButlerTool.target_from_url(target)
		p["itch_target"] = target
		if _is_selected(p):
			%ItchTarget.text = target
			_refresh_itch_page_link()
		_save_projects()
	if target.is_empty():
		log_line("Enter the itch.io game as user/game (for https://you.itch.io/my-game that is you/my-game), or pick it from the list next to the field.", COLOR_ERR)
		_set_field_error(%ItchTarget, true)
		ok = false
	elif not ButlerTool.is_valid_target(target):
		log_line("'%s' is not an itch.io game in the form user/game. Use the part of the game page address around .itch.io: https://you.itch.io/my-game → you/my-game." % target, COLOR_ERR)
		_set_field_error(%ItchTarget, true)
		ok = false

	var pushed := 0
	for i in depots.size():
		var channel := str(depots[i].get("itch_channel", "")).strip_edges()
		if channel.is_empty():
			continue
		pushed += 1
		if not ButlerTool.is_valid_channel(channel):
			_mark_depot_error(i, "itch_channel")
			log_line("Channel '%s' may only use lower-case letters, digits, '-', '_' and '.', e.g. windows or mac-beta." % channel, COLOR_ERR)
			ok = false
	if pushed == 0 and not depots.is_empty():
		log_line("No row has an itch.io channel, so itch.io would get nothing. Type one in the Channel column (e.g. windows, mac, linux, html5).", COLOR_ERR)
		ok = false
	var dupes := _duplicate_itch_channels(p)
	if not dupes.is_empty():
		log_line(_duplicate_channel_message(dupes), COLOR_ERR)
		for i in depots.size():
			if dupes.has(str(depots[i].get("itch_channel", "")).strip_edges()):
				_mark_depot_error(i, "itch_channel")
		ok = false

	if not _validate_itch_setup():
		ok = false
	return ok


## Channels used by more than one row of [param p], ignoring blanks.
func _duplicate_itch_channels(p: Dictionary) -> PackedStringArray:
	var dupes := PackedStringArray()
	var seen := {}
	for d in p["depots"]:
		var channel := str(d.get("itch_channel", "")).strip_edges()
		if channel.is_empty():
			continue
		if seen.has(channel) and not dupes.has(channel):
			dupes.append(channel)
		seen[channel] = true
	return dupes


func _duplicate_channel_message(dupes: PackedStringArray) -> String:
	var which := "Channel %s is" % dupes[0] if dupes.size() == 1 else "Channels %s are" % ", ".join(dupes)
	return "%s used by several rows. Each push replaces the channel's build, so only the last row would stay on itch.io. Give every row its own channel." % which


## True for a string of digits with a value above zero (App and depot IDs).
static func _is_positive_int(text: String) -> bool:
	return text.is_valid_int() and not text.begins_with("+") and not text.begins_with("-") and int(text) > 0


## Why [param file_name] cannot be an executable name on every desktop OS
## ("contains ':'", "is a reserved name on Windows", …), or "" when it can.
static func _invalid_file_name_reason(file_name: String) -> String:
	for c: String in ILLEGAL_FILE_CHARS:
		if c in file_name:
			return "contains '%s'" % c
	if file_name.begins_with(" ") or file_name.ends_with(" "):
		return "starts or ends with a space"
	if file_name.ends_with("."):
		return "ends with a dot"
	if file_name.get_slice(".", 0).to_upper() in WINDOWS_RESERVED_NAMES:
		return "is a reserved name on Windows"
	return ""


## [param text] without the characters no OS accepts in a file name.
static func _strip_illegal_file_chars(text: String) -> String:
	for c: String in ILLEGAL_FILE_CHARS:
		text = text.replace(c, "")
	return text


## True unless the file lacks every executable bit (macOS / Linux). Windows
## has no such bits, so it always counts as executable there.
static func _is_executable_file(path: String) -> bool:
	if OS.get_name() == "Windows":
		return true
	var mode := FileAccess.get_unix_permissions(path)
	return mode == 0 or (mode & 0x49) != 0  # 0 = unknown; 0x49 = 0111


## True for projects that use C# (a .csproj next to project.godot, or a
## [dotnet] section in it). Those only export correctly with the .NET build.
func _is_csharp_project(project_path: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(project_path.path_join("project.godot")) == OK and cfg.has_section("dotnet"):
		return true
	var dir := DirAccess.open(project_path)
	if dir == null:
		return false
	for f in dir.get_files():
		if f.get_extension().to_lower() == "csproj":
			return true
	return false


## True when [param binary] is a .NET ("mono") build of Godot, judged from
## its cached --version ("4.3.stable.mono.official"). A binary that was never
## probed counts as .NET so a missing probe never raises a false warning.
func _is_dotnet_godot(binary: String) -> bool:
	var version := str(_version_cache.get(binary, {}).get("version", "")).to_lower()
	return version.is_empty() or version.contains("mono")


## True when [param path] holds no visible files or folders.
static func _dir_is_empty(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	return dir.get_files().is_empty() and dir.get_directories().is_empty()


## Free bytes on the disk that holds this app's data folder, -1 if unknown.
static func _free_disk_bytes() -> int:
	var dir := DirAccess.open(OS.get_user_data_dir())
	if dir == null:
		return -1
	return dir.get_space_left()


## True when a Godot app's folder still has its project.godot. Folder apps
## always count as present; their depot folders are checked separately.
static func _project_file_exists(p: Dictionary) -> bool:
	if str(p.get("kind", "godot")) == "folder":
		return true
	return FileAccess.file_exists(str(p.get("path", "")).path_join("project.godot"))


func _missing_project_message(p: Dictionary) -> String:
	var path := str(p.get("path", ""))
	if DirAccess.dir_exists_absolute(path):
		return "'%s': there is no project.godot in %s any more. Click the app name at the top to point at the project's folder." % [p["name"], path]
	return "'%s': the project folder %s was moved, renamed or deleted. Click the app name at the top to point at its new location." % [p["name"], path]


# ---------------------------------------------------------------------------
# Steam library capsule
# ---------------------------------------------------------------------------

## Library capsules are 600x900 (2x: 1200x1800). The frame sits left of the
## Steam card, matches the card's height and keeps the capsule aspect ratio
## so image and placeholder share one size.
const CAPSULE_ASPECT := 600.0 / 900.0


func _on_steam_card_resized() -> void:
	# The minimum size is valid before the first layout pass, so the frame
	# gets its final size right away instead of snapping once the card lays out.
	var height: float = maxf(%SteamCard.size.y, %SteamCard.get_combined_minimum_size().y)
	if height <= 0.0:
		return
	var wanted := Vector2(roundf(height * CAPSULE_ASPECT), height)
	if not %HeaderFrame.custom_minimum_size.is_equal_approx(wanted):
		%HeaderFrame.custom_minimum_size = wanted


func _update_header_shader_size() -> void:
	var mat := %HeaderImage.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("size", %HeaderImage.size)


## A typed App ID has settled (debounce): refresh the capsule and fill the
## depot table when it is still empty.
func _on_app_id_settled() -> void:
	if _selected_index < 0 or not _steam_on(_projects[_selected_index]):
		return
	_refresh_steam_header(false)
	_maybe_auto_fetch_depots(_current_app_id())


func _current_app_id() -> String:
	if _selected_index < 0 or _selected_index >= _projects.size():
		return ""
	return str(_projects[_selected_index].get("app_id", "")).strip_edges()


## Enables the Installation → General button only while the selected project
## has an App ID, since the Steamworks URL needs one.
func _refresh_installation_link() -> void:
	var app_id := _current_app_id()
	%InstallationGeneralButton.disabled = app_id.is_empty()
	%InstallationGeneralButton.tooltip_text = "Enter the App ID first" if app_id.is_empty() \
		else "Open Installation → General for App %s in Steamworks to set the launch option" % app_id
	%DepotsPageButton.disabled = app_id.is_empty()
	%DepotsPageButton.tooltip_text = "Enter the App ID first" if app_id.is_empty() \
		else "Open the depots page for App %s in Steamworks" % app_id
	%BuildsPageButton.disabled = app_id.is_empty()
	%BuildsPageButton.tooltip_text = "Enter the App ID first" if app_id.is_empty() \
		else "Open Builds for App %s in Steamworks" % app_id


func _on_installation_general_pressed() -> void:
	var app_id := _current_app_id()
	if not app_id.is_empty():
		OS.shell_open(STEAMWORKS_APP_CONFIG_URL % app_id)


func _on_builds_page_pressed() -> void:
	var app_id := _current_app_id()
	if not app_id.is_empty():
		OS.shell_open(STEAMWORKS_BUILDS_URL % app_id)


func _on_depots_page_pressed() -> void:
	var app_id := _current_app_id()
	if not app_id.is_empty():
		OS.shell_open(STEAMWORKS_DEPOTS_URL % app_id)


## Branch typed in "Set live on branch", without surrounding whitespace.
func _branch_name(p: Dictionary) -> String:
	return str(p.get("branch", "")).strip_edges()


## Shows the selected project's Steam library capsule beside the Steam card. Cached
## images are reused unless [param force] is set (the Refresh button).
func _refresh_steam_header(force: bool) -> void:
	%HeaderDebounce.stop()
	var app_id := _current_app_id()
	_on_steam_card_resized()
	if app_id.is_empty():
		_show_capsule_placeholder()
		_set_refresh_header_enabled(false)
		return
	if not app_id.is_valid_int() or int(app_id) <= 0:
		_show_capsule_placeholder()
		_set_refresh_header_enabled(false)
		log_line("App ID '%s' is not a number, so no Steam capsule can be fetched. Use only the digits of the App ID shown in Steamworks." % app_id, COLOR_WARN)
		return

	# Keep the previous image while a different app loads only if it is the same app.
	if %HeaderImage.get_meta("app_id", "") != app_id:
		_show_capsule_placeholder()
	%RefreshHeaderButton.disabled = true
	if force:
		log_line("Fetching Steam capsule for App %s" % app_id, COLOR_INFO)
	%SteamAssets.fetch_header(app_id, force)


## The capsule frame is always visible; this swaps the image out for the
## "No Steam capsule found" panel so the frame keeps its shape.
func _show_capsule_placeholder() -> void:
	%HeaderImage.texture = null
	%HeaderImage.visible = false
	%HeaderImage.set_meta("app_id", "")
	%PlaceholderLabel.text = "No Steam capsule found"
	%HeaderPlaceholder.visible = true


## The Refresh button sits in the Steam section header, outside the capsule
## frame, so it is disabled rather than hidden while there is no valid App ID.
func _set_refresh_header_enabled(enabled: bool) -> void:
	%RefreshHeaderButton.disabled = not enabled
	%RefreshHeaderButton.tooltip_text = "Re-download the library capsule from Steam" if enabled \
		else "Enter the App ID first"


func _on_header_ready(app_id: String, texture: Texture2D) -> void:
	if app_id != _current_app_id():
		return  # Late answer for a project that is no longer selected.
	# A different app's capsule fades in; a refresh of the same one just swaps.
	var fresh: bool = not %HeaderImage.visible or %HeaderImage.get_meta("app_id", "") != app_id
	%HeaderImage.texture = texture
	%HeaderImage.set_meta("app_id", app_id)
	%HeaderImage.visible = true
	%HeaderPlaceholder.visible = false
	if fresh:
		Motion.fade_in(%HeaderImage)
	_set_refresh_header_enabled(true)
	log_line("Steam capsule ready for App %s" % app_id, COLOR_INFO)


func _on_header_failed(app_id: String, reason: String) -> void:
	if app_id != _current_app_id():
		return
	# A failed refresh keeps the image we already have.
	if %HeaderImage.texture == null:
		_show_capsule_placeholder()
	_set_refresh_header_enabled(true)
	log_line("Steam capsule for App %s unavailable: %s" % [app_id, reason], COLOR_WARN)


# ---------------------------------------------------------------------------
# Godot version per project
# ---------------------------------------------------------------------------

## Reads "4.7" out of config/features in the project's project.godot.
func _read_required_godot_version(project_path: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(project_path.path_join("project.godot")) != OK:
		return "?"
	var features: PackedStringArray = cfg.get_value("application", "config/features", PackedStringArray())
	var re := RegEx.create_from_string("^\\d+\\.\\d+$")
	for f in features:
		if re.search(f):
			return f
	return "?"


## Asks the configured binary for its version and compares it with the project.
func _check_godot_version() -> void:
	if _selected_index < 0:
		return
	var p := _projects[_selected_index]
	var required := _read_required_godot_version(p["path"])
	var binary: String = p.get("godot_binary", "")

	_godot_status = {}
	if not _project_file_exists(p):
		# _status_messages shows only this: nothing works until the folder is found.
		_probe_serial += 1
		%GodotVersionLabel.text = "Project not found"
		%GodotVersionDot.self_modulate = Color(COLOR_ERR)
		_refresh_banners()
		return

	if binary.is_empty() or not FileAccess.file_exists(binary):
		%GodotVersionLabel.text = "Needs Godot %s · no binary" % required
		%GodotVersionDot.self_modulate = Color(COLOR_ERR)
		_set_godot_status("Pick a Godot %s binary, or press Find, before building." % required, COLOR_ERR)
		return

	var index := _selected_index
	_probe_serial += 1
	var serial := _probe_serial
	if not _version_cache.has(binary):
		%GodotVersionLabel.text = "Needs Godot %s · checking…" % required
		%GodotVersionDot.self_modulate = Color(COLOR_MUTED)
	_refresh_banners()  # Depot warnings need not wait for the probe.
	var reported := await _binary_version(binary)
	# The user may have switched project (or re-checked) while Godot was probed.
	if serial != _probe_serial or index != _selected_index:
		return
	if reported.is_empty():
		%GodotVersionLabel.text = "Needs Godot %s · binary did not answer" % required
		%GodotVersionDot.self_modulate = Color(COLOR_ERR)
		_set_godot_status("%s did not report a Godot version. Pick the Godot editor program itself (not a launcher, shortcut or script), then press Find to check again." % binary.get_file(), COLOR_ERR)
		_rebuild_sidebar()
		return
	var matches := reported.begins_with(required + ".")
	%GodotVersionLabel.text = "Needs Godot %s · binary is %s" % [required, reported]
	%GodotVersionDot.self_modulate = Color(COLOR_OK if matches else COLOR_WARN)
	if matches and _is_csharp_project(p["path"]) and not reported.to_lower().contains("mono"):
		%GodotVersionDot.self_modulate = Color(COLOR_WARN)
		_set_godot_status("This is a C# project, but the binary is the standard Godot build. Pick the .NET build of Godot %s, or the export will be missing its scripts." % required, COLOR_WARN)
	elif not matches:
		_set_godot_status("Version mismatch: the project wants Godot %s but the binary is %s. Pick a Godot %s binary (Find looks for installed ones), or the export may fail or behave differently." % [required, reported, required], COLOR_WARN)
		log_line("Godot version mismatch for %s: project wants %s, binary is %s" % [p["name"], required, reported], COLOR_WARN)
	_rebuild_sidebar()


## Records the Godot problem of the selected app and shows it with the rest.
func _set_godot_status(text: String, color: String) -> void:
	_godot_status = { "text": text, "color": color }
	_refresh_banners()


## Depot IDs used by more than one row of the selected project, ignoring blanks.
func _duplicate_depot_ids() -> PackedStringArray:
	var dupes := PackedStringArray()
	if _selected_index < 0:
		return dupes
	var seen := {}
	for d in _projects[_selected_index]["depots"]:
		var id: String = d["depot_id"].strip_edges()
		if id.is_empty():
			continue
		if seen.has(id) and not dupes.has(id):
			dupes.append(id)
		seen[id] = true
	return dupes


func _duplicate_depot_message(dupes: PackedStringArray) -> String:
	var which := "Depot %s is" % dupes[0] if dupes.size() == 1 else "Depots %s are" % ", ".join(dupes)
	return "%s used by several rows. Steam filters downloads per depot, so every player would get all of those builds. Use one depot per export preset." % which


func _on_godot_binary_selected(path: String) -> void:
	var resolved := _resolve_godot_binary(path)
	if resolved.is_empty():
		log_line("No Godot program found inside %s. It is probably a Steam shortcut; pick Godot.app itself (for a Steam install: Steam → Godot Engine → Manage → Browse local files) or the Godot executable." % path, COLOR_ERR)
		return
	%GodotBinary.text = resolved  # text_changed does not fire on set, commit manually
	_set_field_error(%GodotBinary, false)
	_commit_field("godot_binary", resolved)
	_check_godot_version()


## Check button: verifies the version, or auto-fetches when the field is empty.
func _on_check_godot_pressed() -> void:
	if _selected_index < 0:
		return
	var current: String = %GodotBinary.text.strip_edges()
	if current.is_empty() or not FileAccess.file_exists(current):
		var required := _read_required_godot_version(_projects[_selected_index]["path"])
		var found := await _guess_godot_binary(required)
		if found.is_empty():
			log_line("No Godot %s install found on PATH, in common install folders, your Steam libraries or Downloads. Use the folder button to pick one, or download Godot %s from https://godotengine.org/download/archive/ first." % [required, required], COLOR_WARN)
		else:
			log_line("Found Godot %s at %s" % [required, found], COLOR_OK)
			%GodotBinary.text = found
			_set_field_error(%GodotBinary, false)
			_commit_field("godot_binary", found)
	else:
		_version_cache.erase(current)  # Check means check: probe again.
	_check_godot_version()


## Turns "Godot.app" (a macOS bundle) into the executable inside it.
## Any other path is returned untouched.
func _resolve_godot_binary(path: String) -> String:
	path = path.trim_suffix("/")
	if path.to_lower().ends_with(".app") and DirAccess.dir_exists_absolute(path):
		var macos_dir := path.path_join("Contents/MacOS")
		var dir := DirAccess.open(macos_dir)
		if dir == null:
			return ""
		var files := dir.get_files()
		if files.has("Godot"):
			return macos_dir.path_join("Godot")
		# Steam drops launcher bundles in ~/Applications whose only content is a
		# run.sh that opens Steam – never treat those as a Godot binary.
		for f in files:
			if not _is_script_file(f):
				return macos_dir.path_join(f)
		return ""
	return path


func _is_script_file(file_name: String) -> bool:
	var ext := file_name.get_extension().to_lower()
	return ext in ["sh", "command", "bat", "cmd", "ps1"]


## Finds a Godot binary whose --version matches [param required] ("4.7").
## Order: binaries already set on other projects, then PATH, the platform's
## usual install folders, every Steam library, Downloads, and finally the
## editor hosting this tool.
func _guess_godot_binary(required: String) -> String:
	for p in _projects:
		var b: String = p.get("godot_binary", "")
		if not b.is_empty() and _read_required_godot_version(p["path"]) == required:
			return b

	for candidate in _godot_candidates():
		# Cheap hints (Info.plist, file name) rule out most installs without
		# launching them; only an unknown candidate is actually run.
		var hint := _candidate_version_hint(candidate)
		if not hint.is_empty() and not hint.begins_with(required + "."):
			continue
		var reported := await _binary_version(candidate)
		if reported.begins_with(required + "."):
			return candidate
	return ""


## Best-effort version of a candidate without running it: the editor hosting
## this tool, the bundle's Info.plist, or a "4.7" in the file name. "" if unknown.
func _candidate_version_hint(exe: String) -> String:
	if exe == OS.get_executable_path():
		var v := Engine.get_version_info()
		return "%d.%d.%d" % [v["major"], v["minor"], v["patch"]]
	var re := RegEx.create_from_string("\\d+\\.\\d+(\\.\\d+)?")
	var macos_dir := "/Contents/MacOS/"
	if exe.contains(macos_dir):
		var plist := exe.substr(0, exe.find(macos_dir)).path_join("Contents/Info.plist")
		var text := FileAccess.get_file_as_string(plist)
		var key := text.find("CFBundleShortVersionString")
		if key >= 0:
			var m := re.search(text, key)
			if m:
				return m.get_string()
	var m := re.search(exe.get_file())
	return m.get_string() if m else ""


func _godot_candidates() -> PackedStringArray:
	var out := PackedStringArray()
	var home := _home_dir()
	var dirs := _path_dirs()
	match OS.get_name():
		"macOS":
			dirs.append_array([
				"/Applications",
				home.path_join("Applications"),
				"/usr/local/bin",
				"/opt/homebrew/bin",
			])
		"Windows":
			for env in ["ProgramFiles", "ProgramFiles(x86)"]:
				var base := OS.get_environment(env)
				if not base.is_empty():
					dirs.append(base.path_join("Godot"))
			var local := OS.get_environment("LOCALAPPDATA")
			if not local.is_empty():
				dirs.append(local.path_join("Programs/Godot"))
		_:
			dirs.append_array([
				home.path_join(".local/bin"),
				home.path_join("bin"),
				"/usr/bin",
				"/usr/local/bin",
			])
	for root in _steam_library_roots():
		dirs.append(root.path_join("steamapps/common/Godot Engine"))
		dirs.append(root.path_join("steamapps/common/Godot Engine 4"))
	dirs.append(OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS))

	var console := PackedStringArray()  # Windows ships a *_console.exe twin; try the GUI exe first.
	for d in dirs:
		if d.is_empty():
			continue
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for entry in dir.get_directories():
			if "godot" in entry.to_lower() and entry.to_lower().ends_with(".app"):
				var exe := _resolve_godot_binary(d.path_join(entry))
				if not exe.is_empty() and not out.has(exe):
					out.append(exe)
		for entry in dir.get_files():
			var lower := entry.to_lower()
			if "godot" not in lower or _is_script_file(entry):
				continue
			var full := d.path_join(entry)
			if out.has(full) or console.has(full):
				continue
			if "console" in lower:
				console.append(full)
			else:
				out.append(full)
	out.append_array(console)
	if OS.has_feature("editor") and not out.has(OS.get_executable_path()):
		out.append(OS.get_executable_path())  # the editor running this tool
	return out


## Steam install roots: the client's default location per platform plus every
## extra library listed in steamapps/libraryfolders.vdf (other drives).
func _steam_library_roots() -> PackedStringArray:
	var home := _home_dir()
	var defaults := PackedStringArray()
	match OS.get_name():
		"macOS":
			defaults.append(home.path_join("Library/Application Support/Steam"))
		"Windows":
			for env in ["ProgramFiles(x86)", "ProgramFiles"]:
				var base := OS.get_environment(env)
				if not base.is_empty():
					defaults.append(base.path_join("Steam"))
		_:
			defaults.append_array([
				home.path_join(".steam/steam"),
				home.path_join(".local/share/Steam"),
				home.path_join(".var/app/com.valvesoftware.Steam/.local/share/Steam"),
			])
	var out := PackedStringArray()
	for root in defaults:
		if not DirAccess.dir_exists_absolute(root):
			continue
		if not out.has(root):
			out.append(root)
		var vdf := FileAccess.get_file_as_string(root.path_join("steamapps/libraryfolders.vdf"))
		for line in vdf.split("\n"):
			var tokens: PackedStringArray = %SteamProfile.quoted_tokens(line.strip_edges())
			if tokens.size() >= 2 and tokens[0] == "path":
				# VDF escapes backslashes ("D:\\SteamLibrary").
				var extra: String = tokens[1].replace("\\\\", "/").replace("\\", "/").trim_suffix("/")
				if not extra.is_empty() and not out.has(extra) and DirAccess.dir_exists_absolute(extra):
					out.append(extra)
	return out


## Runs "<binary> --version" with a hard timeout so a launcher stub or a
## broken install can never freeze the UI. Returns "" when unsure.
func _binary_version(binary: String, timeout_msec: int = 8000) -> String:
	if binary.is_empty() or _is_script_file(binary) or not FileAccess.file_exists(binary):
		return ""
	var mtime := FileAccess.get_modified_time(binary)
	var cached: Dictionary = _version_cache.get(binary, {})
	if not cached.is_empty() and int(cached.get("mtime", -1)) == mtime:
		return cached["version"]
	var info := OS.execute_with_pipe(binary, ["--version"], false)
	if info.is_empty():
		return ""
	var pid: int = info["pid"]
	var stdio: FileAccess = info["stdio"]
	var started := Time.get_ticks_msec()
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() - started > timeout_msec:
			OS.kill(pid)
			stdio.close()
			info["stderr"].close()
			log_line("%s did not answer --version within %.0f s, so it is probably not the Godot editor (a launcher or shortcut?). Pick the real Godot program." % [binary, timeout_msec / 1000.0], COLOR_WARN)
			return ""
		await get_tree().process_frame  # keep the window responsive meanwhile
	var version := stdio.get_line().strip_edges()
	stdio.close()
	info["stderr"].close()
	# Godot prints "4.7.2.stable.official.<hash>"; anything else is not Godot.
	if not version.left(1).is_valid_int():
		version = ""
	if not version.is_empty():
		_version_cache[binary] = {"version": version, "mtime": mtime}
		_save_version_cache()
	return version


func _save_version_cache() -> void:
	var cfg := ConfigFile.new()
	for binary in _version_cache:
		cfg.set_value("versions", binary, _version_cache[binary])
	_report_save(cfg.save(VERSION_CACHE_FILE), VERSION_CACHE_FILE)


## Entries whose binary vanished or changed on disk are dropped on load.
func _load_version_cache() -> void:
	_version_cache.clear()
	var cfg := ConfigFile.new()
	if cfg.load(VERSION_CACHE_FILE) != OK or not cfg.has_section("versions"):
		return
	for binary in cfg.get_section_keys("versions"):
		var entry: Variant = cfg.get_value("versions", binary)
		if entry is Dictionary and FileAccess.file_exists(binary) \
				and int(entry.get("mtime", -1)) == FileAccess.get_modified_time(binary):
			_version_cache[binary] = entry


# ---------------------------------------------------------------------------
# Depot table
# ---------------------------------------------------------------------------

## Fills _preset_names and _preset_platforms from the project's export_presets.cfg.
func _read_presets(project_path: String) -> void:
	_preset_names = PackedStringArray()
	_preset_platforms = PackedStringArray()
	var cfg := ConfigFile.new()
	if cfg.load(project_path.path_join("export_presets.cfg")) != OK:
		return
	var i := 0
	while cfg.has_section("preset.%d" % i):
		var section := "preset.%d" % i
		_preset_names.append(cfg.get_value(section, "name", "preset %d" % i))
		_preset_platforms.append(str(cfg.get_value(section, "platform", "")))
		i += 1


## True when the selected project has at least one preset in export_presets.cfg.
func _has_presets() -> bool:
	return not _preset_names.is_empty()


## True for apps added from a folder without project.godot: uploaded as-is.
func _is_folder_app(p: Dictionary) -> bool:
	return str(p.get("kind", "godot")) == "folder"


func _selected_is_folder() -> bool:
	return _selected_index >= 0 and _is_folder_app(_projects[_selected_index])


## First depot folder of [param p] that is set but does not exist, or "".
func _missing_depot_folder(p: Dictionary) -> String:
	for d in p["depots"]:
		var content_dir := str(d.get("content_dir", "")).strip_edges()
		if not content_dir.is_empty() and not DirAccess.dir_exists_absolute(content_dir):
			return content_dir
	return ""


## Swaps the build table's header, empty text and hints between the Godot
## layout (preset / depot / channel / executable) and the folder layout
## (folder / depot / channel). The depot and channel columns follow the
## app's targets (see _apply_targets).
func _apply_depot_table_kind(folder: bool) -> void:
	%ColPresetRow.visible = not folder
	%ColOutputRow.visible = not folder
	%ColFolderRow.visible = folder
	if folder:
		%DepotsEmpty.text = "No builds yet. Add one row per folder to upload."
		%AddDepotButton.tooltip_text = "Add a row (one per folder)"
	else:
		%DepotsEmpty.text = "No builds yet. Add one row per export preset."
		%AddDepotButton.tooltip_text = "Add a row (one per export preset)"
	_refresh_installation_link()


# ---------------------------------------------------------------------------
# Publish targets (Steam, itch.io)
# ---------------------------------------------------------------------------

## True when [param p] publishes to Steam. Apps from before itch.io support
## have no flag and keep publishing to Steam.
static func _steam_on(p: Dictionary) -> bool:
	return p.get("steam_enabled", true) == true


static func _itch_on(p: Dictionary) -> bool:
	return p.get("itch_enabled", false) == true


## "Steam", "itch.io" or "Steam and itch.io" for the targets of [param p].
static func _targets_label(p: Dictionary) -> String:
	var names := PackedStringArray()
	if _steam_on(p):
		names.append("Steam")
	if _itch_on(p):
		names.append("itch.io")
	return " and ".join(names) if not names.is_empty() else "nowhere"


## "Steam keeps" / "Steam and itch.io keep" for the stop and quit prompts.
static func _stores_keep_text(p: Dictionary) -> String:
	var both := _steam_on(p) and _itch_on(p)
	return "%s %s" % [_targets_label(p), "keep" if both else "keeps"]


## Platform family of build row [param d] of [param p] ("windows", "macos",
## "linux", "web", or "" for folders and unknown presets).
func _row_kind(p: Dictionary, d: Dictionary) -> String:
	if _is_folder_app(p):
		return ""
	return _platform_kind(_preset_names.find(str(d.get("preset", ""))))


## Shows the section bodies, table columns and composer hint for the targets
## of [param p], and the state of the checkboxes in the store headers. A store
## that is off keeps its header, so it can be ticked again.
func _apply_targets(p: Dictionary) -> void:
	var steam := _steam_on(p)
	var itch := _itch_on(p)
	%SteamTargetToggle.set_pressed_no_signal(steam)
	%ItchTargetToggle.set_pressed_no_signal(itch)
	_refresh_target_toggles()
	%SteamBody.visible = steam
	%SteamOffHint.visible = not steam
	%RefreshHeaderButton.visible = steam
	%ItchBody.visible = itch
	%ItchOffHint.visible = not itch
	%RefreshItchButton.visible = itch
	if itch:
		_refresh_itch_game(false)
	%FetchDepotsButton.visible = steam
	%InstallationGeneralButton.visible = steam  # Steamworks launch option link
	%ColDepotRow.visible = steam
	%ColChannelRow.visible = itch
	if steam:
		%BuildDescription.placeholder_text = "Describe this build…"
		%BuildDescription.tooltip_text = "Shown as the build description in Steamworks, e.g. v1.0.3 – fixed save bug. Cleared after a successful run."
	else:
		%BuildDescription.placeholder_text = "Version, e.g. 1.0.3 (optional)"
		%BuildDescription.tooltip_text = "Sent to itch.io as the build's version. Leave empty to use the version from the project's settings (application/config/version), if it has one."


## A target can only be switched on once it is set up on the Setup page; one
## that is on stays switchable off, so an app never gets stuck.
func _refresh_target_toggles() -> void:
	for pair: Array in [
		[%SteamTargetToggle, _steam_setup_complete(), "Steam", "Set up SteamCMD and sign in to Steam on the Setup page first"],
		[%ItchTargetToggle, _itch_setup_complete(), "itch.io", "Set up butler and sign in to itch.io on the Setup page first"],
	]:
		var toggle: Button = pair[0]
		var set_up: bool = pair[1]
		var locked := not _publishing.is_empty() and _is_selected(_publishing)
		toggle.disabled = locked or (not set_up and not toggle.button_pressed)
		# Button has no "disabled + pressed" look: the disabled style hides the
		# check, so a toggle locked during a run would read as switched off.
		if toggle.disabled and toggle.button_pressed:
			toggle.add_theme_stylebox_override("disabled", toggle.get_theme_stylebox("pressed"))
			toggle.add_theme_color_override("icon_disabled_color", toggle.get_theme_color("icon_pressed_color"))
			toggle.modulate.a = 0.6
		else:
			toggle.remove_theme_stylebox_override("disabled")
			toggle.remove_theme_color_override("icon_disabled_color")
			toggle.modulate.a = 1.0
		toggle.tooltip_text = ("Publish this app to %s" % pair[2]) if set_up or toggle.button_pressed else pair[3]


func _on_target_toggled(on: bool, target: String) -> void:
	if _selected_index < 0:
		return
	var p := _projects[_selected_index]
	p["%s_enabled" % target] = on
	if on and target == "itch":
		_fill_default_channels(p)
	_save_projects()
	_depot_errors.clear()
	_apply_targets(p)
	_rebuild_depot_rows()
	_refresh_banners()
	if on and target == "steam":
		_refresh_steam_header(false)
		_suggest_app_id(p)
		_maybe_auto_fetch_depots(_current_app_id())
	log_line("%s now publishes to %s." % [p["name"], _targets_label(p)], COLOR_INFO)


## Gives every build row of [param p] without a channel the default one for
## its platform, so switching itch.io on leaves a table that is ready to push.
func _fill_default_channels(p: Dictionary) -> void:
	var taken := PackedStringArray()
	for d in p["depots"]:
		var channel := str(d.get("itch_channel", "")).strip_edges()
		if not channel.is_empty():
			taken.append(channel)
	for d in p["depots"]:
		if not str(d.get("itch_channel", "")).strip_edges().is_empty():
			continue
		var channel := ButlerTool.default_channel(_row_kind(p, d), taken, _row_folder_name(p, d))
		d["itch_channel"] = channel
		taken.append(channel)


## Folder name a folder row's default channel is made from.
func _row_folder_name(p: Dictionary, d: Dictionary) -> String:
	var dir := str(d.get("content_dir", "")).strip_edges()
	return dir.get_file() if not dir.is_empty() else str(p["name"])


## The Page row: the link button, and whether the game is a draft when it is
## one of the account's games.
func _refresh_itch_page_link() -> void:
	var target: String = %ItchTarget.text.strip_edges()
	var valid := ButlerTool.is_valid_target(target)
	%ItchPageButton.disabled = not valid
	%ItchPageButton.tooltip_text = "Open %s" % ButlerTool.page_url(target) if valid else "Enter the game as user/game first"
	if target.is_empty():
		%ItchPageStatus.text = "Enter the game first"
	elif not valid:
		%ItchPageStatus.text = "Not a user/game yet"
	else:
		var address := ButlerTool.page_url(target).trim_prefix("https://")
		var game := _current_itch_game()
		%ItchPageStatus.text = address if game.is_empty() \
			else "%s · %s" % ["Published" if game["published"] else "Draft", address]


## The account's game the Game field names, or {} when it is not one of them
## (or the list has not loaded).
func _current_itch_game() -> Dictionary:
	var target: String = %ItchTarget.text.strip_edges().to_lower()
	for g: Dictionary in _itch_games:
		if str(g["target"]).to_lower() == target:
			return g
	return {}


# ---------------------------------------------------------------------------
# itch.io cover
# ---------------------------------------------------------------------------

## itch.io covers are 315x250 (2x: 630x500). Like the Steam capsule, the frame
## sits left of the card, matches the card's height and keeps the aspect.
const ITCH_COVER_ASPECT := 315.0 / 250.0


func _on_itch_card_resized() -> void:
	var height: float = maxf(%ItchGameCard.size.y, %ItchGameCard.get_combined_minimum_size().y)
	if height <= 0.0:
		return
	var wanted := Vector2(roundf(height * ITCH_COVER_ASPECT), height)
	if not %ItchCoverFrame.custom_minimum_size.is_equal_approx(wanted):
		%ItchCoverFrame.custom_minimum_size = wanted


## Shows the cover and page status of the selected app's game. The account's
## games list is loaded first when it is not there yet; [param force] (the
## Refresh button) reloads the list and downloads the cover again.
func _refresh_itch_game(force: bool) -> void:
	_on_itch_card_resized()
	_refresh_itch_page_link()
	if force:
		_itch_games_loaded = false
		_itch_cover_force = true
	if not _itch_games_loaded:
		if _itch_ok():
			_itch_games_serial = %ItchApi.fetch_games(%ItchApiKey.text)
		else:
			_show_itch_cover_placeholder("Sign in to itch.io to show the cover")
		return
	var game := _current_itch_game()
	if game.is_empty():
		_show_itch_cover_placeholder("No itch.io cover found")
		return
	if %ItchCoverImage.get_meta("target", "") != game["target"]:
		_show_itch_cover_placeholder("Loading cover…")
	elif not _itch_cover_force:
		return  # This game's cover is already on screen.
	%ItchApi.fetch_cover(game, _itch_cover_force)
	_itch_cover_force = false


func _show_itch_cover_placeholder(text: String) -> void:
	%ItchCoverImage.texture = null
	%ItchCoverImage.visible = false
	%ItchCoverImage.set_meta("target", "")
	%ItchCoverPlaceholderLabel.text = text
	%ItchCoverPlaceholder.visible = true


func _on_itch_cover_ready(target: String, texture: Texture2D) -> void:
	if target.to_lower() != %ItchTarget.text.strip_edges().to_lower():
		return  # Late answer for another game or app.
	var fresh: bool = not %ItchCoverImage.visible or %ItchCoverImage.get_meta("target", "") != target
	%ItchCoverImage.texture = texture
	%ItchCoverImage.set_meta("target", target)
	%ItchCoverImage.visible = true
	%ItchCoverPlaceholder.visible = false
	if fresh:
		Motion.fade_in(%ItchCoverImage)


func _on_itch_cover_failed(target: String, reason: String) -> void:
	if target.to_lower() != %ItchTarget.text.strip_edges().to_lower():
		return
	if %ItchCoverImage.texture == null:
		_show_itch_cover_placeholder("No itch.io cover found")
	log_line("itch.io cover for %s unavailable: %s" % [target, reason], COLOR_WARN)


func _on_itch_page_pressed() -> void:
	var target: String = %ItchTarget.text.strip_edges()
	if ButlerTool.is_valid_target(target):
		OS.shell_open(ButlerTool.page_url(target))


## Turns a pasted game page address into user/game.
func _normalize_itch_target() -> void:
	var text: String = %ItchTarget.text.strip_edges()
	if not text.contains("itch.io"):
		return
	var target := ButlerTool.target_from_url(text)
	if target.is_empty():
		return
	%ItchTarget.text = target
	_commit_field("itch_target", target)
	_refresh_itch_game(false)


## The game list fills when it opens, from the account's games on itch.io.
func _on_pick_itch_game_opening() -> void:
	var popup: PopupMenu = %PickItchGameButton.get_popup()
	_fill_itch_game_menu()
	if not _itch_ok():
		return
	_itch_games_serial = %ItchApi.fetch_games(%ItchApiKey.text)
	if _itch_games.is_empty():
		popup.clear()
		popup.add_item("Loading your games…")
		popup.set_item_disabled(0, true)


func _fill_itch_game_menu() -> void:
	var popup: PopupMenu = %PickItchGameButton.get_popup()
	popup.clear()
	if not _itch_ok():
		popup.add_item("Sign in to itch.io on the Setup page first")
		popup.set_item_disabled(0, true)
		return
	if _itch_games.is_empty():
		popup.add_item("No games on this account yet. Create one on itch.io first.")
		popup.set_item_disabled(0, true)
		return
	var current := _current_itch_game()
	for i in _itch_games.size():
		var g: Dictionary = _itch_games[i]
		popup.add_radio_check_item("%s  (%s)%s" % [g["title"], g["target"], "" if g["published"] else " · draft"], i)
		popup.set_item_checked(i, g == current)


func _on_itch_games_ready(serial: int, games: Array) -> void:
	if serial != _itch_games_serial:
		return
	_itch_games = games
	_itch_games_loaded = true
	if %PickItchGameButton.get_popup().visible:
		_fill_itch_game_menu()
	if _selected_index >= 0 and _itch_on(_projects[_selected_index]):
		_refresh_itch_game(false)


func _on_itch_games_failed(serial: int, reason: String) -> void:
	if serial != _itch_games_serial:
		return
	log_line("Could not load your itch.io games (%s). Type the game as user/game instead." % reason, COLOR_WARN)
	_itch_cover_force = false
	if %ItchCoverImage.texture == null:
		_show_itch_cover_placeholder("No itch.io cover found")
	var popup: PopupMenu = %PickItchGameButton.get_popup()
	if popup.visible:
		popup.clear()
		popup.add_item("Could not load your games")
		popup.set_item_disabled(0, true)


func _on_itch_game_picked(id: int) -> void:
	if _selected_index < 0 or id < 0 or id >= _itch_games.size():
		return
	var target: String = _itch_games[id]["target"]
	%ItchTarget.text = target
	_commit_field("itch_target", target)
	_set_field_error(%ItchTarget, false)
	_refresh_itch_game(false)
	log_line("%s publishes to %s on itch.io." % [_projects[_selected_index]["name"], ButlerTool.page_url(target)], COLOR_INFO)


func _on_add_depot_pressed() -> void:
	if _selected_index < 0:
		return
	_depot_errors.clear()
	var depots: Array = _projects[_selected_index]["depots"]
	var idx := mini(depots.size(), _preset_names.size() - 1)
	var preset := _preset_names[idx] if _preset_names.size() > 0 else ""
	depots.insert(0, _new_depot_entry(preset, ""))
	_save_projects()
	_rebuild_depot_rows()
	_refresh_banners()
	var row := _live_child(%DepotRows, 0)
	if row != null:
		Motion.grow_in(row, Motion.DEPOT_IN)


## Asks SteamCMD for the App ID's depot list and appends a row for every depot
## not already in the table, picking a matching export preset by platform.
func _on_fetch_depots_pressed() -> void:
	_fetch_depots(false)


## Runs the depot fetch once for the selected project's App ID when its table
## is still empty, so an App ID (typed or looked up) fills the depots without a
## click. While something else runs the wish is kept and retried by _set_busy.
## Skips that the user can fix are logged; a project counts as fetched only
## after SteamCMD actually answered (see _fetch_depots).
func _maybe_auto_fetch_depots(app_id: String) -> void:
	if _selected_index < 0 or not _steam_on(_projects[_selected_index]):
		return
	app_id = app_id.strip_edges()
	if app_id.is_empty() or not _projects[_selected_index]["depots"].is_empty():
		return
	if not app_id.is_valid_int() or int(app_id) <= 0:
		return  # _refresh_steam_header already warned about the non-numeric ID.
	if _auto_depot_fetches.has(_auto_fetch_key(app_id)):
		return
	if _is_busy:
		_auto_fetch_pending = true
		return
	_fetch_depots(true)


func _auto_fetch_key(app_id: String) -> String:
	return "%s|%s" % [_projects[_selected_index]["name"], app_id]


## Depot fetch shared by the Depots Fetch button and the automatic fetch.
## [param auto] skips the red field marks and page switch a manual click gets.
func _fetch_depots(auto: bool) -> void:
	if _is_busy or _selected_index < 0:
		return
	var app_id: String = %AppId.text.strip_edges()
	if app_id.is_empty() or not app_id.is_valid_int():
		if not auto:
			_set_field_error(%AppId, true)
			log_line("Enter a numeric Steam App ID before fetching depots.", COLOR_ERR)
		return
	# app_info_print only needs a session, so a blank username falls back to
	# SteamCMD's anonymous login. That sees every released app; unreleased ones
	# still need an account with Steamworks access.
	var anonymous: bool = %SteamUsername.text.strip_edges().is_empty()
	if auto:
		if _resolve_steamcmd(%SteamCmdBinary.text).is_empty():
			log_line("SteamCMD not set, so the depots for App %s were not fetched. Set it on the Setup page and reselect the app." % app_id, COLOR_WARN)
			return
	elif not _validate_steamcmd_field():
		return
	var steamcmd := _resolve_steamcmd(%SteamCmdBinary.text)
	# The user may select another app while SteamCMD runs; the result belongs
	# to this one.
	var p := _projects[_selected_index]
	var auto_key := _auto_fetch_key(app_id)
	_fetching_depots = true
	_set_busy(true)
	var how := " (automatic)" if auto else ""
	log_step("Fetching depots for App ID %s%s%s" % [app_id, " (anonymous)" if anonymous else "", how])
	var args := PackedStringArray(["+login", "anonymous"]) if anonymous else _steam_login_args()
	# app_info_print is asked twice on purpose: on a fresh SteamCMD cache the
	# first print is often a stub without depots, the second one is complete.
	# The parser uses the last block it finds.
	var app_args := PackedStringArray(["+app_info_update", "1", "+app_info_print", app_id, "+app_info_print", app_id, "+quit"])
	args.append_array(app_args)
	var res := await _query_depots(steamcmd, args, app_id)
	if _bail_if_cancelled():
		return
	if res["code"] != 0 and _password_prompt_seen and not _password_sent and not anonymous:
		# Public apps list their depots to anyone, so a missing password need
		# not block the table. Unreleased apps still need the account. A
		# password that was sent and refused is reported instead.
		anonymous = true
		log_line("Fetching the public depot list for App ID %s anonymously instead." % app_id, COLOR_INFO)
		args = PackedStringArray(["+login", "anonymous"])
		args.append_array(app_args)
		res = await _query_depots(steamcmd, args, app_id)
		if _bail_if_cancelled():
			return
	if res["code"] == 0 and res["found"].is_empty():
		# Even two prints can both be stubs on a cold cache; the cache is on
		# disk now, so one more SteamCMD run usually has the full block.
		log_line("SteamCMD returned no depot list yet (cold cache), asking again…", COLOR_INFO)
		res = await _query_depots(steamcmd, args, app_id)
		if _bail_if_cancelled():
			return
	if res["code"] != 0:
		log_line("SteamCMD failed (exit code %d); depots not fetched." % res["code"], COLOR_ERR)
		_explain_known_issues(STEAMCMD_FALLBACK, _is_selected(p))
		log_step_done(false)
		_set_busy(false)
		return
	if not anonymous:
		_mark_login_verified()
	if not _is_selected(p):
		# The depot table and presets on screen belong to another app now.
		log_line("Depots for App %s arrived after you switched apps, so nothing was added. Select '%s' and press Fetch again." % [app_id, p["name"]], COLOR_WARN)
		log_step_done(false, "app switched")
		_set_busy(false)
		return
	if auto:
		_auto_depot_fetches[auto_key] = true
	var found: Array[Dictionary] = res["found"]
	if found.is_empty():
		if anonymous:
			log_line("No public depots found for App ID %s. Unreleased apps only show depots to a signed-in account with Steamworks access — enter your Steam username and try again." % app_id, COLOR_WARN)
		else:
			log_line("No depots found for App ID %s. Check that the account has access to the app and that its depots are published on the Steamworks partner site." % app_id, COLOR_WARN)
		log_step_done(false, "no depots")
		_set_busy(false)
		return
	_merge_fetched_depots(found)
	log_step_done(true)
	_set_busy(false)


## One SteamCMD run for [param app_id]'s app info, parsed:
## { "code": int, "found": Array[Dictionary], "all_ids": PackedStringArray,
## "branches": Dictionary } (see SteamAppInfo.parse_depots,
## uploadable_depot_ids and branch_builds). A non-empty all_ids also goes into
## _steam_depot_ids, non-empty branches into _steam_branches.
func _query_depots(steamcmd: String, args: PackedStringArray, app_id: String) -> Dictionary:
	var res := await run_process_capture(steamcmd, args)
	var found: Array[Dictionary] = []
	var all_ids := PackedStringArray()
	var branches := {}
	if res["code"] == 0:
		found = SteamAppInfo.parse_depots(res["output"], app_id)
		all_ids = SteamAppInfo.uploadable_depot_ids(res["output"], app_id)
		branches = SteamAppInfo.branch_builds(res["output"], app_id)
		if not all_ids.is_empty():
			_steam_depot_ids[app_id] = all_ids
		if not branches.is_empty():
			_steam_branches[app_id] = branches
	return {"code": res["code"], "found": found, "all_ids": all_ids, "branches": branches}


## Inserts the depots from [param found] that are not already in the table at
## the top, keeping their fetched order.
func _merge_fetched_depots(found: Array[Dictionary]) -> void:
	var depots: Array = _projects[_selected_index]["depots"]
	var existing_ids := {}
	var used_presets := {}
	for d in depots:
		existing_ids[str(d.get("depot_id", "")).strip_edges()] = true
		used_presets[str(d.get("preset", ""))] = true
	var added := PackedStringArray()
	var skipped := 0
	for depot in found:
		if existing_ids.has(depot["depot_id"]):
			skipped += 1
			continue
		var preset := ""
		if not _selected_is_folder():
			var preset_index := _pick_preset_for_oslist(depot["oslist"], used_presets)
			preset = _preset_names[preset_index] if preset_index >= 0 else ""
			if not preset.is_empty():
				used_presets[preset] = true
		depots.insert(added.size(), _new_depot_entry(preset, depot["depot_id"]))
		added.append("%s (%s)" % [depot["depot_id"], SteamAppInfo.oslist_label(depot["oslist"])])
	if not added.is_empty():
		_depot_errors.clear()
		_save_projects()
		_rebuild_depot_rows()
		_refresh_banners()
		# The new rows are at the top; they grow in one after another.
		var rows: Array[Control] = []
		for i in added.size():
			rows.append(_live_child(%DepotRows, i))
		for i in rows.size():
			if rows[i] != null:
				Motion.grow_in(rows[i], Motion.DEPOT_IN, 0.0, i * Motion.STAGGER)
		log_line("Added %s: %s" % [_plural(added.size(), "depot"), ", ".join(added)], COLOR_OK)
	if skipped > 0:
		log_line("Skipped %s already in the table." % _plural(skipped, "depot"), COLOR_INFO)
	if added.is_empty() and skipped == 0:
		log_line("Nothing to add.", COLOR_INFO)


## Index into _preset_names of the first preset whose platform can serve a
## depot with [param oslist] and that is not in [param used_presets], or -1.
## Presets already assigned to another depot are only reused when nothing
## else matches.
func _pick_preset_for_oslist(oslist: String, used_presets: Dictionary) -> int:
	var fallback := -1
	for i in _preset_platforms.size():
		if not SteamAppInfo.platform_matches(oslist, _preset_platforms[i]):
			continue
		if not used_presets.has(_preset_names[i]):
			return i
		if fallback < 0:
			fallback = i
	return fallback


func _rebuild_depot_rows() -> void:
	for child in %DepotRows.get_children():
		child.queue_free()
	if _selected_index < 0:
		return
	var depots: Array = _projects[_selected_index]["depots"]
	%DepotsEmpty.visible = depots.is_empty()
	%DepotColumns.visible = not depots.is_empty()
	for i in depots.size():
		%DepotRows.add_child(_make_depot_row(i, depots[i]))
	_apply_build_lock()


## Column widths shared by the header row in the scene and the rows built here.
## Every column expands, so a narrow window shrinks the row instead of pushing
## the content column (and the Steam header above it) wider than the viewport.
const PRESET_STRETCH := 1.6
const DEPOT_ID_MIN_WIDTH := 64.0
const DEPOT_ID_STRETCH := 1.0
const OUTPUT_MIN_WIDTH := 88.0
const OUTPUT_STRETCH := 1.3
const CHANNEL_MIN_WIDTH := 64.0
const CHANNEL_STRETCH := 1.0
## Folder apps show one folder column where Godot apps show preset + executable.
const FOLDER_STRETCH := PRESET_STRETCH + OUTPUT_STRETCH
## Platform logos are 32px; shrink them to text height in the preset dropdown.
const PRESET_ICON_SIZE := 16


func _make_depot_row(index: int, depot: Dictionary) -> HBoxContainer:
	if _selected_is_folder():
		return _make_folder_depot_row(index, depot)
	return _make_godot_depot_row(index, depot)


## Folder app row: content folder (editable path + folder button), depot ID, remove.
## The path field matches the Godot and SteamCMD path rows: type or paste a
## path, or pick one with the folder button. Existence is checked on submit.
func _make_folder_depot_row(index: int, depot: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var errors: Dictionary = _depot_errors.get(index, {})

	var folder_box := HBoxContainer.new()
	folder_box.custom_minimum_size.x = OUTPUT_MIN_WIDTH
	folder_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder_box.size_flags_stretch_ratio = FOLDER_STRETCH
	folder_box.add_theme_constant_override("separation", 4)

	var path := LineEdit.new()
	path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path.text = str(depot.get("content_dir", ""))
	path.placeholder_text = "Type a path or use the folder button"
	path.tooltip_text = "Every file in this folder is uploaded to the depot."
	path.accessibility_name = "Depot %d folder" % (index + 1)
	_set_field_error(path, errors.has("content_dir"))
	path.text_changed.connect(func(t: String) -> void:
		_clear_depot_error(index, "content_dir")
		_set_field_error(path, false)
		_projects[_selected_index]["depots"][index]["content_dir"] = t
		_save_projects()
		_refresh_banners()
	)
	folder_box.add_child(path)

	var browse := Button.new()
	browse.icon = ICON_FOLDER
	browse.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	browse.theme_type_variation = &"IconButton"
	browse.custom_minimum_size = Vector2(24, 24)
	browse.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	browse.tooltip_text = "Choose the folder to upload"
	browse.accessibility_name = "Choose depot %d folder" % (index + 1)
	browse.disabled = _is_busy
	browse.pressed.connect(func() -> void:
		%DepotFolderDialog.set_meta("row", index)
		var current := path.text.strip_edges()
		var start := current if DirAccess.dir_exists_absolute(current) else str(_projects[_selected_index]["path"])
		%DepotFolderDialog.current_dir = start
		%DepotFolderDialog.popup_centered()
	)
	folder_box.add_child(browse)
	row.add_child(folder_box)

	var p := _projects[_selected_index]
	if _steam_on(p):
		row.add_child(_make_depot_id_field(index, depot, errors))
	if _itch_on(p):
		row.add_child(_make_channel_field(index, depot, errors))
	row.add_child(_make_depot_remove_button(index))
	return row


func _on_depot_folder_selected(dir: String) -> void:
	if _selected_index < 0:
		return
	var i: int = %DepotFolderDialog.get_meta("row", -1)
	var depots: Array = _projects[_selected_index]["depots"]
	if i < 0 or i >= depots.size():
		return
	depots[i]["content_dir"] = dir.simplify_path().rstrip("/")
	_clear_depot_error(i, "content_dir")
	_save_projects()
	_rebuild_depot_rows()
	_refresh_banners()
	_rebuild_sidebar()


## Depot ID column shared by both row kinds. A web row never goes to Steam,
## so its field stays empty and read-only.
func _make_depot_id_field(index: int, depot: Dictionary, errors: Dictionary, web := false) -> LineEdit:
	var depot_id := LineEdit.new()
	depot_id.custom_minimum_size.x = DEPOT_ID_MIN_WIDTH
	depot_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	depot_id.size_flags_stretch_ratio = DEPOT_ID_STRETCH
	depot_id.placeholder_text = "2807131"
	depot_id.accessibility_name = "Depot %d ID" % (index + 1)
	depot_id.text = str(depot.get("depot_id", ""))
	_set_field_error(depot_id, errors.has("depot_id"))
	if web:
		depot_id.text = ""
		depot_id.placeholder_text = "itch.io only"
		depot_id.editable = false
		depot_id.tooltip_text = "Steam cannot run web builds, so this row only goes to itch.io."
		depot_id.set_meta("always_locked", true)
		return depot_id
	depot_id.text_changed.connect(func(t: String) -> void:
		t = _digits_only(depot_id, t)
		_clear_depot_error(index, "depot_id")
		_set_field_error(depot_id, false)
		_projects[_selected_index]["depots"][index]["depot_id"] = t
		_save_projects()
		_refresh_banners()
	)
	return depot_id


## itch.io channel column shared by both row kinds. Channels are lower-case
## on itch.io, so typing is folded to lower case and spaces become "-".
func _make_channel_field(index: int, depot: Dictionary, errors: Dictionary) -> LineEdit:
	var channel := LineEdit.new()
	channel.custom_minimum_size.x = CHANNEL_MIN_WIDTH
	channel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	channel.size_flags_stretch_ratio = CHANNEL_STRETCH
	channel.placeholder_text = "skipped"
	channel.accessibility_name = "Row %d itch.io channel" % (index + 1)
	channel.tooltip_text = "itch.io channel this row is pushed to. A name with windows, linux or mac gets that platform on itch.io; html5 is for web builds. Leave empty to skip this row on itch.io."
	channel.text = str(depot.get("itch_channel", ""))
	_set_field_error(channel, errors.has("itch_channel"))
	channel.text_changed.connect(func(t: String) -> void:
		var clean := t.to_lower().replace(" ", "-")
		if clean != t:
			var caret := channel.caret_column
			channel.text = clean
			channel.caret_column = mini(caret, clean.length())
		_clear_depot_error(index, "itch_channel")
		_set_field_error(channel, false)
		_projects[_selected_index]["depots"][index]["itch_channel"] = clean
		_save_projects()
		_refresh_banners()
	)
	return channel


func _make_depot_remove_button(index: int) -> Button:
	var remove := Button.new()
	remove.icon = ICON_CLOSE
	remove.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	remove.theme_type_variation = &"IconButton"
	remove.tooltip_text = "Remove row"
	remove.accessibility_name = "Remove row %d" % (index + 1)
	remove.custom_minimum_size.x = 28
	remove.pressed.connect(func() -> void:
		_depot_errors.clear()
		_projects[_selected_index]["depots"].remove_at(index)
		_save_projects()
		_refresh_banners()
		_rebuild_sidebar()
		# The row shrinks away, then the table is rebuilt. The other rows still
		# point at the old indices until then, so they ignore the mouse.
		var row: Node = remove
		while row != null and row.get_parent() != %DepotRows:
			row = row.get_parent()
		if row == null:
			_rebuild_depot_rows()
			return
		for child in %DepotRows.get_children():
			Motion.ignore_mouse(child)
		Motion.collapse(row, Motion.OUT, _rebuild_depot_rows)
	)
	return remove


## Godot app row: export preset, depot ID, executable name, remove.
func _make_godot_depot_row(index: int, depot: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var preset := OptionButton.new()
	preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset.size_flags_stretch_ratio = PRESET_STRETCH
	preset.clip_text = true
	preset.accessibility_name = "Depot %d export preset" % (index + 1)
	preset.add_theme_constant_override("icon_max_width", PRESET_ICON_SIZE)
	preset.get_popup().add_theme_constant_override("icon_max_width", PRESET_ICON_SIZE)
	for i in _preset_names.size():
		var icon := PlatformIcons.for_platform(_preset_platforms[i])
		if icon != null:
			preset.add_icon_item(icon, _preset_names[i])
		else:
			preset.add_item(_preset_names[i])
	if not _has_presets():
		preset.add_item("No export presets")
		preset.set_item_disabled(0, true)
		preset.tooltip_text = "Open the project in Godot → Project → Export… and add a preset, then reselect the project."
	var sel := _preset_names.find(depot["preset"])
	if sel >= 0:
		preset.select(sel)
	elif _has_presets() and not str(depot["preset"]).is_empty():
		# Renamed or deleted in Godot: show the stale name instead of letting
		# the dropdown pretend the first preset is chosen.
		preset.add_item("%s (missing)" % depot["preset"])
		preset.set_item_disabled(preset.item_count - 1, true)
		preset.select(preset.item_count - 1)
		preset.tooltip_text = "'%s' is no longer an export preset of this project (renamed or deleted in Godot). Pick another preset." % depot["preset"]
	elif _has_presets():
		preset.select(-1)  # Nothing chosen yet; the first item is not a choice.
	var errors: Dictionary = _depot_errors.get(index, {})
	_set_field_error(preset, errors.has("preset"))
	preset.item_selected.connect(func(idx: int) -> void:
		_clear_depot_error(index, "preset")
		var app: Dictionary = _projects[_selected_index]
		var d: Dictionary = app["depots"][index]
		var old_kind := _row_kind(app, d)
		d["preset"] = _preset_names[idx]
		_follow_channel_default(app, d, old_kind)
		_save_projects()
		_rebuild_depot_rows()
		_refresh_banners()
	)
	row.add_child(preset)

	var kind := _platform_kind(sel)
	var p := _projects[_selected_index]
	if _steam_on(p):
		row.add_child(_make_depot_id_field(index, depot, errors, kind == "web"))
	if _itch_on(p):
		row.add_child(_make_channel_field(index, depot, errors))

	# Executable column: editable base name with the platform extension drawn
	# as ghost text right after it, inside the same field, so every row's
	# field is the same width regardless of how long the extension is.
	var output := LineEdit.new()
	output.custom_minimum_size.x = OUTPUT_MIN_WIDTH
	output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output.size_flags_stretch_ratio = OUTPUT_STRETCH
	output.clip_contents = true
	output.placeholder_text = _default_base_name()
	output.accessibility_name = "Depot %d executable name" % (index + 1)
	output.tooltip_text = "Name of the game executable. The extension is added for you from the preset's platform. Steam launches this file, so use the same full name in your Steamworks launch option." if _steam_on(p) \
		else "Name of the game executable. The extension is added for you from the preset's platform."
	output.text = depot["output"]
	_set_field_error(output, errors.has("output"))
	if kind == "web":
		# Browsers and itch.io start a web build from index.html.
		output.text = "index"
		output.editable = false
		output.tooltip_text = "Web builds are always exported as index.html, the page itch.io opens in the browser."
		output.set_meta("always_locked", true)

	var ext := Label.new()
	ext.text = _shown_extension(kind) if sel >= 0 else ""
	ext.mouse_filter = Control.MOUSE_FILTER_PASS
	ext.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ext.clip_text = true
	ext.add_theme_font_override("font", output.get_theme_font("font"))
	ext.add_theme_font_size_override("font_size", output.get_theme_font_size("font_size"))
	ext.add_theme_color_override("font_color", output.get_theme_color("font_placeholder_color"))
	match kind:
		"macos":
			ext.tooltip_text = "Added from the preset's platform. Godot exports a zip; it is unpacked and the .app bundle inside is renamed to this name so it matches your Steamworks launch option."
		"web":
			ext.tooltip_text = output.tooltip_text
			if not _itch_on(p):
				ext.tooltip_text = "Steam cannot launch web builds. Switch on itch.io for this app, or use a desktop preset for this row."
				ext.add_theme_color_override("font_color", Color(COLOR_WARN))
		_:
			ext.tooltip_text = "Added from the preset's platform."
	output.add_child(ext)

	output.text_changed.connect(func(t: String) -> void:
		var clean := _strip_illegal_file_chars(t)
		if clean != t:
			var caret := output.caret_column
			output.text = clean
			output.caret_column = mini(caret, clean.length())
		_clear_depot_error(index, "output")
		_set_field_error(output, false)
		_projects[_selected_index]["depots"][index]["output"] = clean
		_save_projects()
		_place_ghost_extension(output, ext)
	)
	output.resized.connect(_place_ghost_extension.bind(output, ext))
	# Caret moves scroll the text; draw fires on each of those, so the ghost follows.
	output.draw.connect(_place_ghost_extension.bind(output, ext))
	_place_ghost_extension(output, ext)
	row.add_child(output)
	row.add_child(_make_depot_remove_button(index))
	return row


## Puts the ghost extension label directly after the text (or placeholder)
## of [param field], following the field's horizontal scroll. Hidden when the
## typed text already fills the field or there is no extension to show.
func _place_ghost_extension(field: LineEdit, ghost: Label) -> void:
	if ghost.text.is_empty():
		ghost.visible = false
		return
	var shown := field.text if not field.text.is_empty() else field.placeholder_text
	var font := field.get_theme_font("font")
	var font_size := field.get_theme_font_size("font_size")
	var style := field.get_theme_stylebox("normal")
	var x := style.content_margin_left \
		+ font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x \
		+ field.get_scroll_offset()  # <= 0 once the text scrolls left
	var width := field.size.x - style.content_margin_right - x
	var pos := Vector2(x, 0.0)
	var size := Vector2(width, field.size.y)
	# Only touch the label when something moved; this runs from draw.
	if ghost.position != pos or ghost.size != size:
		ghost.position = pos
		ghost.size = size
	ghost.visible = width > 0.0


## Platform family of the preset at [param preset_index]: "windows", "macos",
## "linux", "web" or "" when unknown. Falls back to the preset name for old
## entries without a platform.
func _platform_kind(preset_index: int) -> String:
	var lower := ""
	if preset_index >= 0 and preset_index < _preset_platforms.size():
		lower = _preset_platforms[preset_index].to_lower()
	if lower.is_empty() and preset_index >= 0 and preset_index < _preset_names.size():
		lower = _preset_names[preset_index].to_lower()
	if "windows" in lower:
		return "windows"
	if "mac" in lower:
		return "macos"
	if "web" in lower or "html" in lower:
		return "web"
	if "linux" in lower or "x11" in lower:
		return "linux"
	return ""


## Extension Godot writes for [param kind]. macOS exports as a zip, which is
## unpacked after export so the .app bundle gets uploaded; Web exports an
## index.html with its .js, .wasm and .pck next to it.
func _export_extension(kind: String) -> String:
	match kind:
		"windows":
			return ".exe"
		"macos":
			return ".zip"
		"web":
			return ".html"
		_:
			return ".x86_64"


## File a row of platform [param kind] with executable name [param output]
## exports to. Web builds are always index.html.
func _export_file_name(kind: String, output: String) -> String:
	if kind == "web":
		return "index.html"
	return output.strip_edges() + _export_extension(kind)


## Extension shown in the depot table: what the player and Steam's launch
## option see, so macOS shows .app rather than the intermediate .zip.
func _shown_extension(kind: String) -> String:
	if kind == "macos":
		return ".app"
	return _export_extension(kind)


## Default executable base name: the project name from project.godot reduced
## to letters, digits, "_" and "-", or "game" when nothing is left.
func _default_base_name() -> String:
	if _selected_index < 0:
		return "game"
	var name: String = _projects[_selected_index]["name"]
	var regex := RegEx.create_from_string("[^A-Za-z0-9_-]")
	var clean := regex.sub(name, "", true)
	return clean if not clean.is_empty() else "game"


## New build row for the selected project. Folder apps point the first row
## they create at the app folder itself; later ones start empty. The row gets
## the default itch.io channel for its platform (used once itch.io is on).
func _new_depot_entry(preset: String, depot_id: String) -> Dictionary:
	var p := _projects[_selected_index]
	var taken := PackedStringArray()
	for d in p["depots"]:
		taken.append(str(d.get("itch_channel", "")).strip_edges())
	var entry: Dictionary
	if _is_folder_app(p):
		var content_dir: String = p["path"] if p["depots"].is_empty() else ""
		entry = {"content_dir": content_dir, "depot_id": depot_id}
	else:
		entry = {"preset": preset, "depot_id": depot_id, "output": _default_base_name()}
	entry["itch_channel"] = ButlerTool.default_channel(_row_kind(p, entry), taken, _row_folder_name(p, entry))
	return entry


## After the preset of row [param d] changed from platform [param old_kind]:
## a channel that still is the default of the old platform follows the new
## one ("windows" → "mac"); a channel the user typed is kept.
func _follow_channel_default(p: Dictionary, d: Dictionary, old_kind: String) -> void:
	var current := str(d.get("itch_channel", "")).strip_edges()
	var taken := PackedStringArray()
	for other in p["depots"]:
		if not is_same(other, d):
			taken.append(str(other.get("itch_channel", "")).strip_edges())
	var old_default := ButlerTool.default_channel(old_kind, taken)
	if not current.is_empty() and current != old_default:
		return
	d["itch_channel"] = ButlerTool.default_channel(_row_kind(p, d), taken)


const KNOWN_EXPORT_EXTENSIONS: PackedStringArray = [".exe", ".x86_64", ".zip", ".app", ".html", ".pck"]

## Removes a trailing export extension from [param name]. Older saves stored
## the full file name ("game.exe"); the table now keeps only the base name.
func _strip_known_extension(name: String) -> String:
	var lower := name.to_lower()
	for ext in KNOWN_EXPORT_EXTENSIONS:
		if lower.ends_with(ext):
			return name.substr(0, name.length() - ext.length())
	return name


# ---------------------------------------------------------------------------
# Build & Publish pipeline
# ---------------------------------------------------------------------------

func _on_build_publish_pressed() -> void:
	if _is_busy:
		if _publishing.is_empty():
			_cancel_running()  # Sign-in, depot reads and downloads stop at once.
		else:
			_confirm("Stop publishing?", "The upload of %s stops and %s the previous build." % [_publishing["name"], _stores_keep_text(_publishing)], "Stop", _cancel_running)
		return
	if _selected_index < 0:
		return
	await build_and_publish({"strict": true})


## Build & Publish of the app on screen, shared by the button and the command
## line (see Cli). [param options]:
## - "mode": "publish" (the button), "check" (the checks and the store
##   checks, nothing exported) or "dry_run" (also exports, nothing uploaded).
## - "smoke_seconds": when above 0, every export this machine can run is
##   started headless for that long and its script errors are collected.
## - "script_check" (default true): every script of every export this
##   machine can run is loaded, and the files every scene and resource needs
##   are checked, in a copy of the build (see [method _smoke_test_rows]).
## - "strict": stop before the upload when either found something. The
##   button always passes it.
## - "all_or_nothing": a store that fails its check stops the whole run
##   instead of letting the other store go on.
## Returns the run's ctx (see [method _make_publish_ctx]) with "stage" set
## to where it ended: "done", "invalid", "preflight", "export", "smoke",
## "upload" or "cancelled"; {"stage": "invalid"} when the form check failed.
func build_and_publish(options := {}) -> Dictionary:
	var mode: String = options.get("mode", "publish")
	if not _validate_publish_form():
		return {"stage": "invalid"}
	var p := _projects[_selected_index]
	# Read everything that belongs to the page on screen now: the user may look
	# at another app while this one builds, which reloads _preset_names.
	var ctx := _make_publish_ctx(p)
	ctx["mode"] = mode
	ctx["smoke_seconds"] = float(options.get("smoke_seconds", 0.0))
	ctx["strict"] = bool(options.get("strict", false))
	ctx["script_check"] = bool(options.get("script_check", true))
	ctx["stage"] = "preflight"
	if mode == "publish":
		# The description works like a chat box: it is sent with this build and the
		# field clears right away. It is put back if the run fails or is cancelled.
		_set_description("")
	if not _run_status.is_empty() or not _target_status.is_empty():
		_run_status = {}  # The last run's fix no longer applies to this one.
		_target_status.clear()
		_refresh_banners()

	_set_busy(true)
	_publishing = p
	_exec_bits_lost = false
	_apply_build_lock()
	var where := PackedStringArray()
	if ctx["steam"]:
		where.append("Steam (App %s)" % str(p["app_id"]).strip_edges())
	if ctx["itch"]:
		where.append("itch.io (%s)" % ctx["target"])
	match mode:
		"check":
			log_banner("Check %s for %s" % [p["name"], " and ".join(where)])
		"dry_run":
			log_banner("%s %s for %s (dry run: nothing is uploaded)" % ["Check" if ctx["folder"] else "Build", p["name"], " and ".join(where)])
		_:
			log_banner(("Publish %s to %s" if ctx["folder"] else "Build and publish %s to %s") % [p["name"], " and ".join(where)])

	# 0) A wrong depot ID, a missing branch, a bad API key or an unknown itch.io
	# game only fail at the upload, after every export, with a vague error.
	# Ask the stores first. A target that fails here is skipped; the others go on.
	var started := Time.get_ticks_msec()
	var wanted := int(ctx["steam"]) + int(ctx["itch"])
	if ctx["steam"]:
		var check := await _preflight_steam(ctx)
		if check == "cancelled":
			ctx["stage"] = "cancelled"
			return ctx
		ctx["depot_check"] = check
		ctx["steam"] = check != "failed"
	if ctx["itch"]:
		var check := await _preflight_itch(ctx)
		if check == "cancelled":
			ctx["stage"] = "cancelled"
			return ctx
		ctx["itch"] = check != "failed"
	ctx["timings"]["preflight_ms"] = Time.get_ticks_msec() - started
	var passed := int(ctx["steam"]) + int(ctx["itch"])
	if passed == 0 or (passed < wanted and options.get("all_or_nothing", false)):
		_finish_publish(ctx)
		return ctx
	if mode == "check":
		ctx["stage"] = "done"
		_finish_publish(ctx)
		return ctx

	# 1) One export per row that a remaining target needs.
	ctx["stage"] = "export"
	started = Time.get_ticks_msec()
	if not await _export_rows(ctx):
		if ctx.get("cancelled", false):
			ctx["stage"] = "cancelled"
		return ctx
	ctx["timings"]["export_ms"] = Time.get_ticks_msec() - started
	if ctx["smoke_seconds"] > 0.0 or ctx["script_check"]:
		ctx["stage"] = "smoke"
		started = Time.get_ticks_msec()
		var smoke_ok := await _smoke_test_rows(ctx)
		ctx["timings"]["smoke_ms"] = Time.get_ticks_msec() - started
		if not smoke_ok:
			if ctx.get("cancelled", false):
				ctx["stage"] = "cancelled"
			return ctx
	if mode == "dry_run":
		ctx["stage"] = "done"
		_finish_publish(ctx)
		return ctx

	# 2) Upload to each target in turn.
	ctx["stage"] = "upload"
	if ctx["steam"]:
		started = Time.get_ticks_msec()
		if not await _publish_steam(ctx):
			ctx["stage"] = "cancelled"
			return ctx
		ctx["timings"]["steam_upload_ms"] = Time.get_ticks_msec() - started
	if ctx["itch"]:
		started = Time.get_ticks_msec()
		if not await _publish_itch(ctx):
			ctx["stage"] = "cancelled"
			return ctx
		ctx["timings"]["itch_upload_ms"] = Time.get_ticks_msec() - started
	ctx["stage"] = "done"
	_finish_publish(ctx)
	return ctx


## Everything a Build & Publish run of [param p] needs, read up front:
## { p, description, folder, steam, itch, steamcmd, butler, target,
## userversion, build_dir, depot_check, rows, results }. Each row is
## { index, label, preset, kind, file, dir, depot_id, channel, steam, itch }:
## [code]dir[/code] is the folder that gets uploaded (the export folder, or a
## folder app's own folder) and [code]steam[/code] / [code]itch[/code] say
## which targets take it.
func _make_publish_ctx(p: Dictionary) -> Dictionary:
	var folder := _is_folder_app(p)
	var build_dir := OS.get_user_data_dir().path_join("builds").path_join(str(p["uid"]))
	var content_root := build_dir.path_join("content")
	var rows: Array[Dictionary] = []
	var depots: Array = p["depots"]
	for i in depots.size():
		var d: Dictionary = depots[i]
		var kind := _row_kind(p, d)
		var channel := str(d.get("itch_channel", "")).strip_edges()
		rows.append({
			"index": i,
			"label": _row_label(p, i),
			"preset": str(d.get("preset", "")),
			"kind": kind,
			"output": str(d.get("output", "")).strip_edges(),
			"file": "" if folder else _export_file_name(kind, str(d.get("output", ""))),
			"dir": str(d.get("content_dir", "")).strip_edges() if folder else content_root.path_join("%d-%s" % [i + 1, kind if not kind.is_empty() else "build"]),
			"depot_id": str(d.get("depot_id", "")).strip_edges(),
			"channel": channel,
			"steam": _steam_on(p) and kind != "web",
			"itch": _itch_on(p) and not channel.is_empty(),
		})
	var description: String = p["description"]
	# Without Steam the composer field is the version itch.io shows.
	var userversion := "" if _steam_on(p) else description.strip_edges()
	if userversion.is_empty() and not folder:
		userversion = _read_project_version(p["path"])
	return {
		"p": p,
		"description": description,
		"folder": folder,
		"steam": _steam_on(p),
		"itch": _itch_on(p),
		"steamcmd": _resolve_steamcmd(%SteamCmdBinary.text) if _steam_on(p) else "",
		"butler": _resolve_butler(%ButlerBinary.text) if _itch_on(p) else "",
		"target": str(p.get("itch_target", "")).strip_edges(),
		"userversion": userversion,
		"build_dir": build_dir,
		"depot_check": "",
		"rows": rows,
		"results": [],
		# Filled as the run goes, read by the command line (see Cli):
		# stage durations, Steam's branches (name → live build ID) and the
		# BuildID SteamCMD reported for the upload.
		"timings": {},
		"steam_branches": {},
		"steam_build_id": "",
	}


## application/config/version from the project's project.godot, or "".
func _read_project_version(project_path: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(project_path.path_join("project.godot")) != OK:
		return ""
	return _as_str(cfg.get_value("application", "config/version", "")).strip_edges()


## Records how [param target] ("Steam" or "itch.io") ended in this run. A
## failure's text is the leading fix _explain_known_issues just put in the
## banner, when it found one.
func _add_result(ctx: Dictionary, target: String, ok: bool, text: String, color := "") -> void:
	if not ok and not _run_status.is_empty():
		text = _run_status["text"]
	_run_status = {}
	(ctx["results"] as Array).append({"target": target, "ok": ok, "text": text, "color": color if not color.is_empty() else (COLOR_OK if ok else COLOR_ERR)})


## After an await: true when the user pressed stop meanwhile. Ends the run
## like _bail_if_cancelled and gives the app its description back.
func _publish_cancelled(ctx: Dictionary) -> bool:
	if not _bail_if_cancelled():
		return false
	ctx["cancelled"] = true
	_restore_description(ctx["p"], ctx["description"])
	return true


## End of a run that got through its targets (or had none left): one banner
## per target, or the single target's result as the banner. The description
## goes back when Steam, which shows it, did not get the build, or when no
## target got it.
func _finish_publish(ctx: Dictionary) -> void:
	var p: Dictionary = ctx["p"]
	var results: Array = ctx["results"]
	var any_ok := false
	var steam_failed := false
	for r: Dictionary in results:
		any_ok = any_ok or r["ok"]
		if r["target"] == "Steam" and not r["ok"]:
			steam_failed = true
	if steam_failed or not any_ok:
		_restore_description(p, ctx["description"])
	if _is_selected(p):
		_run_status = {}
		_target_status.clear()
		if results.size() == 1:
			_run_status = {"text": results[0]["text"], "color": results[0]["color"]}
		else:
			for r: Dictionary in results:
				_target_status.append({"text": "%s: %s" % [r["target"], r["text"]], "color": r["color"]})
		_refresh_banners()
	_set_busy(false)


## Build & Publish step 0 for Steam: checks every depot ID the Steam rows use
## against the depot list Steam has for the App ID, and "Set live on branch"
## against the app's branches, from _steam_depot_ids / _steam_branches when
## those already cover them, otherwise with one SteamCMD run under the same
## login the upload uses. Returns "confirmed" when Steam lists them all,
## "unknown" when the depot list could not be read (the build goes on),
## "failed" when Steam cannot get this build (wrong IDs, missing branch,
## failed SteamCMD; the reason is logged and recorded) or "cancelled" when the
## user stopped the run, which is then already cleaned up.
func _preflight_steam(ctx: Dictionary) -> String:
	var p: Dictionary = ctx["p"]
	var steamcmd: String = ctx["steamcmd"]
	var app_id := str(p["app_id"]).strip_edges()
	var wanted := PackedStringArray()
	for row: Dictionary in ctx["rows"]:
		if row["steam"]:
			wanted.append(str(int(row["depot_id"])))
	var cached: PackedStringArray = _steam_depot_ids.get(app_id, PackedStringArray())
	var branch := _branch_name(p).to_lower()
	# A branch the cache does not list, or lists without a live build, may
	# have been fixed in Steamworks since, so only a branch with a build (or
	# no branch) may skip the SteamCMD run.
	var branch_ready := branch.is_empty() or _branch_has_build(_steam_branches.get(app_id, {}), branch)
	ctx["steam_branches"] = _steam_branches.get(app_id, {})
	if not cached.is_empty() and _ids_not_listed(wanted, cached).is_empty() and branch_ready:
		return "confirmed"

	log_step("Checking depots on Steam")
	var typed_code: bool = not %SteamGuardCode.text.strip_edges().is_empty()
	var args := _steam_login_args()
	# Printed twice: on a cold cache the first print is often a stub (see _fetch_depots).
	args.append_array(["+app_info_update", "1", "+app_info_print", app_id, "+app_info_print", app_id, "+quit"])
	var res := await _query_depots(steamcmd, args, app_id)
	if _publish_cancelled(ctx):
		return "cancelled"
	if res["code"] != 0:
		# Same login as the upload, so the upload would fail too: stop before exporting.
		log_line("SteamCMD failed (exit code %d) before anything was exported for Steam." % res["code"], COLOR_ERR)
		var guard_explained := _explain_guard_failure(typed_code)
		_explain_known_issues("" if guard_explained else STEAMCMD_FALLBACK, _is_selected(p))
		_add_result(ctx, "Steam", false, "SteamCMD failed before the export. See the console for its error.")
		log_step_done(false, "SteamCMD failed")
		return "failed"
	_mark_login_verified()
	if typed_code:
		%SteamGuardCode.text = ""  # Used up; the upload signs in with the cached session.
	ctx["steam_branches"] = res["branches"]

	var listed: PackedStringArray = res["all_ids"]
	if listed.is_empty():
		log_line("Steam did not show the depot list of App %s (unreleased apps only show it to an account with Steamworks access to the app), so the depot IDs are not checked. Building anyway." % app_id, COLOR_WARN)
	var missing := PackedStringArray() if listed.is_empty() else _ids_not_listed(wanted, listed)
	if missing.is_empty():
		var branch_problem := _missing_branch_message(p, res["branches"])
		if not branch_problem.is_empty():
			_add_result(ctx, "Steam", false, branch_problem)
			log_step_done(false, "no such branch")
			return "failed"
		log_step_done(true, "not checked" if listed.is_empty() else "")
		return "unknown" if listed.is_empty() else "confirmed"

	var shown := listed.slice(0, 12)
	var steam_list := ", ".join(shown) + (", …" if listed.size() > shown.size() else "")
	var msg := "%s %s not %s of App %s. Steam lists: %s. Fix the ID%s in the build table, or press Fetch to read them from Steam. A depot just added in Steamworks only counts once the change is published (SteamPipe → Depots, then Publish)." % [
		"Depot" if missing.size() == 1 else "Depots",
		", ".join(missing),
		"is a depot" if missing.size() == 1 else "are depots",
		app_id,
		steam_list,
		"" if missing.size() == 1 else "s",
	]
	log_line(msg, COLOR_ERR)
	if _is_selected(p):
		for row: Dictionary in ctx["rows"]:
			if row["steam"] and missing.has(str(int(row["depot_id"]))):
				_mark_depot_error(row["index"], "depot_id")
		_rebuild_depot_rows()
	_add_result(ctx, "Steam", false, msg)
	log_step_done(false, "wrong depot IDs")
	return "failed"


## Part of Steam's step 0: when [param p] sets a build live on a branch Steam
## does not list, logs how to create it and returns that message ("" when the
## branch is fine). SteamCMD cannot create branches, and SetLive on a missing
## one only fails after the upload. [param builds] is Steam's branch name →
## live buildid for the app (SteamAppInfo.branch_builds); a listed branch with
## no build only warns. An empty [param builds] means Steam did not show the
## branches: nothing is checked.
func _missing_branch_message(p: Dictionary, builds: Dictionary) -> String:
	var branch := _branch_name(p)
	if branch.is_empty() or builds.is_empty():
		return ""
	if builds.has(branch.to_lower()):
		if not _branch_has_build(builds, branch.to_lower()):
			log_line("Branch '%s' has no build live yet. If Steam refuses to set this build live on it, set it live by hand in Steamworks → SteamPipe → Builds; later builds from here can then go live on it." % branch, COLOR_WARN)
		return ""
	var names := PackedStringArray(builds.keys())
	names.sort()
	var msg := "App %s has no branch '%s' (Steam lists: %s). SteamCMD cannot create branches: check the spelling, or create it in Steamworks → SteamPipe → Builds (the Builds page button), then build again. Or clear 'Set live on branch' to upload without setting the build live." % [
		str(p["app_id"]).strip_edges(),
		branch,
		", ".join(names),
	]
	log_line(msg, COLOR_ERR)
	if _is_selected(p):
		_set_field_error(%Branch, true)
	return msg


## Build & Publish step 0 for itch.io: asks butler for the game's channels,
## which proves the API key works and the game exists before anything is
## exported. Returns "ok", "failed" (logged and recorded) or "cancelled".
func _preflight_itch(ctx: Dictionary) -> String:
	var p: Dictionary = ctx["p"]
	log_step("Checking %s on itch.io" % ctx["target"])
	var code := await run_process(ctx["butler"], PackedStringArray(["status", ctx["target"], "--json"]), KnownIssues.BUTLER, false, _butler_env())
	if _publish_cancelled(ctx):
		return "cancelled"
	if code != 0:
		log_line("butler could not read %s on itch.io (exit code %d), so nothing is built for itch.io." % [ctx["target"], code], COLOR_ERR)
		_explain_known_issues(BUTLER_FALLBACK, _is_selected(p))
		_add_result(ctx, "itch.io", false, "butler could not reach the game on itch.io. See the console for its error.")
		log_step_done(false, "itch.io check failed")
		return "failed"
	log_step_done(true)
	return "ok"


## Environment butler runs with: the API key, so it never appears on the
## command line (see run_process).
func _butler_env() -> Dictionary:
	return {"BUTLER_API_KEY": %ItchApiKey.text.strip_edges()}


## Build & Publish step 1: exports every row a remaining target takes into
## its own folder. Folder apps upload their folders as-is. Returns false when
## the run ended here (failed export or cancel), already cleaned up.
func _export_rows(ctx: Dictionary) -> bool:
	var p: Dictionary = ctx["p"]
	var description: String = ctx["description"]
	var build_dir: String = ctx["build_dir"]
	var content_root := build_dir.path_join("content")
	var folder: bool = ctx["folder"]
	if not folder and not _remove_dir_recursive(content_root):
		log_line("Could not delete the previous build in %s, so a file in it is still in use. Close any copy of the game started from that folder (and any window showing it), then build again." % content_root, COLOR_ERR)
		_fail_publish(p, description)
		return false
	if not _make_dir(build_dir.path_join("output")) or not _make_dir(content_root):
		_fail_publish(p, description)
		return false

	# A project that was never opened in Godot has no imported assets yet, and
	# a headless export of it can miss resources. Import once first.
	var godot: String = p.get("godot_binary", "")
	if not folder and not DirAccess.dir_exists_absolute(str(p["path"]).path_join(".godot")):
		if _supports_import_flag(_read_required_godot_version(p["path"])):
			log_step("Importing the project's assets (first export of this project)")
			var import_code := await run_process(godot, PackedStringArray(["--headless", "--path", p["path"], "--import"]), KnownIssues.GODOT)
			if _publish_cancelled(ctx):
				return false
			if import_code != 0:
				log_line("Godot reported problems while importing; the export below shows whether they matter.", COLOR_WARN)
			log_step_done(import_code == 0, "" if import_code == 0 else "continuing with the export")
		else:
			log_line("This project has never been opened in Godot, so its assets are not imported yet. If the export fails, open it once in the Godot editor and build again.", COLOR_WARN)

	for row: Dictionary in ctx["rows"]:
		var goes_to := PackedStringArray()
		if row["steam"] and ctx["steam"]:
			goes_to.append("depot %s" % row["depot_id"])
		if row["itch"] and ctx["itch"]:
			goes_to.append("itch.io %s" % row["channel"])
		if goes_to.is_empty():
			if (row["steam"] and _steam_on(p)) or (row["itch"] and _itch_on(p)):
				log_line("Skipped %s: its store was already ruled out above." % row["label"], COLOR_INFO)
			continue
		if folder:
			log_step("%s ← %s" % [" and ".join(goes_to), row["dir"]])
			log_step_done(true)
			continue
		var row_dir: String = row["dir"]
		if not _make_dir(row_dir):
			_fail_publish(p, description)
			return false
		var out_path := row_dir.path_join(row["file"])
		log_step("Exporting '%s' as %s → %s" % [row["preset"], out_path.get_file(), " and ".join(goes_to)])
		var export_started := Time.get_ticks_msec()

		# Godot skips the shader baker in a headless export without a word, so a
		# preset that bakes shaders exports with a window instead.
		var export_args := PackedStringArray(["--path", p["path"], "--export-release", row["preset"], out_path])
		if not _preset_bakes_shaders(p["path"], row["preset"]):
			export_args.insert(0, "--headless")
		var code := await run_process(godot, export_args, KnownIssues.GODOT)
		if _publish_cancelled(ctx):
			return false
		if code != 0 or not FileAccess.file_exists(out_path):
			var why := "" if code != 0 else " (Godot finished without writing %s)" % out_path.get_file()
			log_line("Export of '%s' failed%s." % [row["preset"], why], COLOR_ERR)
			_explain_known_issues(EXPORT_FALLBACK, _is_selected(p))
			_fail_publish(p, description, "export failed")
			return false

		# macOS exports are zipped .app bundles – unpack so the stores ship the bundle itself.
		if out_path.ends_with(".zip"):
			var ok := await _unzip_in_place(out_path, row_dir)
			if _publish_cancelled(ctx):
				return false
			if not ok:
				_fail_publish(p, description, "unpack failed")
				return false
			# Godot names the bundle inside the zip after the project name, not
			# the zip file. Rename it so it matches the executable in the table.
			if row["kind"] == "macos":
				_rename_app_bundle(row_dir, row["output"])
		row["exported"] = true
		row["export_ms"] = Time.get_ticks_msec() - export_started
		log_step_done(true, "may not launch" if _exec_bits_lost and row["kind"] == "macos" else "")
	return true


## Lines (lowercase) a Godot build prints when a script fails to load. Some
## only fail in an exported build, e.g. a script that uses an editor-only
## class such as EditorInterface still runs from the editor.
const SMOKE_SCRIPT_ERRORS: PackedStringArray = ["script error", "parse error", "failed to load script"]


## How long the script check may take before it counts as hung.
const SCRIPT_CHECK_TIMEOUT := 300.0


## Build & Publish step after the export: tests every exported row this
## machine can run, headless, with a scratch home folder (so the game's
## user:// is not the player's real one), GODOTPIPE_SMOKE_TEST=1 and the user
## argument --godotpipe-smoke-test (so it can skip things like signing in to
## Steam).
## - ctx["smoke_seconds"] above 0 (the command line's smoke test): starts the
##   build for that long and collects the script errors it prints into
##   row["smoke"] = { ran, reason, seconds, exit_code, crashed, script_errors,
##   errors, timed_out }.
## - ctx["script_check"]: loads every script and checks the dependencies of
##   every scene and resource in a copy of the build (see ScriptCheck and
##   [method _script_check_row]), into row["script_check"].
## Returns false when the run ended here: cancelled, or ctx["strict"] and a
## build had script errors, missing files or crashed.
func _smoke_test_rows(ctx: Dictionary) -> bool:
	var p: Dictionary = ctx["p"]
	var seconds: float = ctx["smoke_seconds"]
	var home: String = str(ctx["build_dir"]).path_join("smoke_home")
	var failed := PackedStringArray()
	for row: Dictionary in ctx["rows"]:
		if not row.get("exported", false):
			continue
		var exe := _runnable_export(row)
		if exe.is_empty():
			var reason := "a %s build cannot run on %s" % [row["kind"] if not str(row["kind"]).is_empty() else "build", OS.get_name()]
			if seconds > 0.0:
				row["smoke"] = {"ran": false, "reason": reason}
			if ctx["script_check"]:
				row["script_check"] = {"ran": false, "reason": reason}
			log_line("%s was not %s: %s." % [row["label"], "started" if seconds > 0.0 else "checked for script errors", reason], COLOR_INFO)
			continue
		var env := {
			"HOME": home,  # macOS and Linux keep user:// under it.
			"XDG_DATA_HOME": home.path_join(".local/share"),
			"XDG_CONFIG_HOME": home.path_join(".config"),
			"XDG_CACHE_HOME": home.path_join(".cache"),
			"APPDATA": home.path_join("AppData/Roaming"),  # Windows
			"LOCALAPPDATA": home.path_join("AppData/Local"),
			"GODOTPIPE_SMOKE_TEST": "1",
		}
		var row_failed := false
		if seconds > 0.0:
			log_step("Starting %s headless for %ds to catch script errors" % [row["label"], int(seconds)])
			_remove_dir_recursive(home)
			if not _make_dir(home):
				_fail_publish(p, ctx["description"], "no scratch folder")
				return false
			var run := await _run_headless(exe, env, seconds)
			if _publish_cancelled(ctx):
				return false
			var result := _smoke_findings(run["lines"])
			result["ran"] = true
			result["seconds"] = run["seconds"]
			result["timed_out"] = run["timed_out"]
			result["exit_code"] = run["exit_code"]
			result["crashed"] = not run["timed_out"] and run["exit_code"] != 0
			row["smoke"] = result
			var script_errors: Array = result["script_errors"]
			for line: String in script_errors:
				log_line(line, COLOR_ERR)
			if result["crashed"]:
				log_line("%s quit with exit code %d within %ds of starting." % [row["label"], run["exit_code"], int(seconds)], COLOR_ERR)
			if script_errors.is_empty() and not result["crashed"]:
				log_line("No script errors%s." % ("" if run["timed_out"] else ", and it quit by itself"), COLOR_OK)
				log_step_done(true, "%d other error lines" % result["errors"].size() if not result["errors"].is_empty() else "")
			else:
				row_failed = true
				log_step_done(false, "%s" % _plural(script_errors.size(), "script error"))
		if ctx["script_check"]:
			_remove_dir_recursive(home)
			if not _make_dir(home):
				_fail_publish(p, ctx["description"], "no scratch folder")
				return false
			var check := await _script_check_row(ctx, row, exe, env)
			if _publish_cancelled(ctx):
				return false
			row["script_check"] = check
			if check["ran"] and not check["ok"]:
				row_failed = true
		if row_failed:
			failed.append(row["label"])
	_remove_dir_recursive(home)
	if failed.is_empty():
		return true
	if ctx["strict"]:
		log_line("Stopped before the upload: %s %s script errors, missing files or crashed when started. Nothing was uploaded." % [", ".join(failed), "has" if failed.size() == 1 else "have"], COLOR_ERR)
		_fail_publish(p, ctx["description"], "script errors")
		return false
	log_line("%s %s script errors, missing files or crashed when started. Going on with the upload; strict mode stops here instead." % [", ".join(failed), "has" if failed.size() == 1 else "have"], COLOR_WARN)
	return true


## Starts [param exe] headless with [param env] and stops it after
## [param seconds]. Returns { lines, seconds, timed_out, exit_code } (-1
## when it was stopped).
func _run_headless(exe: String, env: Dictionary, seconds: float) -> Dictionary:
	var lines: Array[String] = []
	var collect := func(line: String, _is_stderr: bool, _tool: String) -> void:
		lines.append(line)
	child_output.connect(collect)
	var state := {"running": true}
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		if state["running"] and _child_pid > 0:
			_child_timed_out = true
			_kill_child()
	)
	var started := Time.get_ticks_msec()
	var code := await run_process(exe, PackedStringArray(["--headless", "--", "--godotpipe-smoke-test"]), "game", false, env)
	var timed_out := _child_timed_out
	state["running"] = false
	child_output.disconnect(collect)
	return {
		"lines": lines,
		"seconds": (Time.get_ticks_msec() - started) / 1000.0,
		"timed_out": timed_out,
		"exit_code": -1 if timed_out else code,
	}


## The script check of one exported [param row] (see ScriptCheck): copies
## the build to a scratch folder, rewrites the copy's .pck with the checker
## and starts it. Never touches the files that get uploaded. Returns
## { ran, ok, reason, scripts, resources, skipped_plugins, script_errors,
## broken, missing, errors, finished, exit_code, seconds }. "ran" is false
## when the build could not be checked (logged as a warning, not a failure).
func _script_check_row(ctx: Dictionary, row: Dictionary, exe: String, env: Dictionary) -> Dictionary:
	var p: Dictionary = ctx["p"]
	log_step("Loading every script of %s in a copy of the build" % row["label"])
	var not_checked := func(reason: String) -> Dictionary:
		log_line("%s was not checked: %s." % [row["label"], reason], COLOR_WARN)
		log_step_done(true, "not checked")
		return {"ran": false, "ok": true, "reason": reason}
	var pck_path := _pck_of(exe)
	if pck_path.is_empty():
		return not_checked.call("its .pck is inside the executable (Embed PCK), which the check cannot read")
	var pck := ScriptCheck.read_pck(pck_path)
	if pck.has("error"):
		return not_checked.call(pck["error"])
	var lists := ScriptCheck.check_lists(pck["entries"], p["path"])
	if not lists["plugin_dirs"].is_empty():
		log_line("Editor plugins are left out (an exported game never runs them): %s" % ", ".join(lists["plugin_dirs"]), COLOR_INFO)

	var row_dir: String = row["dir"]
	var root := str(ctx["build_dir"]).path_join("script_check")
	var copy_dir := root.path_join(row_dir.get_file())
	_remove_dir_recursive(root)
	if not _make_dir(copy_dir) or not _copy_tree(row_dir, copy_dir, pck_path):
		_remove_dir_recursive(root)
		return not_checked.call("the build could not be copied to %s" % copy_dir)
	var copy_pck := copy_dir + pck_path.substr(row_dir.length())
	var copy_exe := copy_dir + exe.substr(row_dir.length())
	var thread := Thread.new()
	thread.start(ScriptCheck.make_check_pck.bind(pck_path, pck, lists, copy_pck, root.path_join("unpacked")))
	while thread.is_alive():
		await get_tree().process_frame
	var packed: String = thread.wait_to_finish()
	_remove_dir_recursive(root.path_join("unpacked"))
	if not packed.is_empty():
		_remove_dir_recursive(root)
		return not_checked.call(packed)
	if _publish_cancelled(ctx):
		_remove_dir_recursive(root)
		return {"ran": false, "ok": true, "reason": "cancelled"}

	var run := await _run_headless(copy_exe, env, SCRIPT_CHECK_TIMEOUT)
	_remove_dir_recursive(root)
	var found := ScriptCheck.findings(run["lines"])
	var result := _smoke_findings(run["lines"])
	var script_errors: Array[String] = []
	script_errors.assign(result["script_errors"])
	# Every broken script is named, also when Godot printed no error for it.
	for path: String in found["broken"]:
		var named := false
		for line in script_errors:
			if line.contains(path):
				named = true
				break
		if not named:
			script_errors.append("Failed to load script %s" % path)
	result.merge({
		"ran": true,
		"scripts": lists["scripts"].size(),
		"resources": lists["resources"].size(),
		"skipped_plugins": lists["plugin_dirs"],
		"script_errors": script_errors,
		"broken": found["broken"],
		"missing": found["missing"],
		"finished": found["done"],
		"exit_code": run["exit_code"],
		"seconds": run["seconds"],
	}, true)
	for line in script_errors:
		log_line(line, COLOR_ERR)
	for line: String in found["missing"]:
		log_line("Missing file: " + line, COLOR_ERR)
	if not found["done"]:
		var how := "did not finish within %ds" % int(SCRIPT_CHECK_TIMEOUT) if run["timed_out"] else "quit with exit code %d before it finished" % run["exit_code"]
		log_line("The script check of %s %s." % [row["label"], how], COLOR_ERR)
	result["ok"] = found["done"] and script_errors.is_empty() and found["missing"].is_empty()
	if result["ok"]:
		log_line("%s load and the files of %d scenes and resources are all there." % [_plural(result["scripts"], "script"), result["resources"]], COLOR_OK)
		log_step_done(true)
	else:
		var notes := PackedStringArray()
		if not script_errors.is_empty():
			notes.append(_plural(script_errors.size(), "script error"))
		if not found["missing"].is_empty():
			notes.append(_plural(found["missing"].size(), "missing file"))
		if not found["done"]:
			notes.append("did not finish")
		log_step_done(false, ", ".join(notes))
	return result


## The .pck an exported [param exe] loads: Contents/Resources/<name>.pck in a
## macOS bundle, else <exe without extension>.pck next to it. "" when there
## is none (the .pck is embedded in the executable).
static func _pck_of(exe: String) -> String:
	var path := exe.get_basename() + ".pck"
	if exe.get_base_dir().ends_with("Contents/MacOS"):
		path = exe.get_base_dir().get_base_dir().path_join("Resources").path_join(exe.get_file() + ".pck")
	return path if FileAccess.file_exists(path) else ""


## Copies the folder [param from] into [param to] (which exists), leaving out
## the file [param skip]. Symlinks are copied as links; files keep their
## permissions, so executables stay executable.
func _copy_tree(from: String, to: String, skip: String) -> bool:
	var dir := DirAccess.open(from)
	if dir == null:
		return false
	dir.include_hidden = true
	for f in dir.get_files():
		var src := from.path_join(f)
		if src == skip:
			continue
		if dir.is_link(src):
			if dir.create_link(dir.read_link(src), to.path_join(f)) != OK:
				return false
		elif DirAccess.copy_absolute(src, to.path_join(f)) != OK:
			return false
		elif OS.get_name() != "Windows":
			FileAccess.set_unix_permissions(to.path_join(f), FileAccess.get_unix_permissions(src))
	for d in dir.get_directories():
		var src := from.path_join(d)
		if dir.is_link(src):
			if dir.create_link(dir.read_link(src), to.path_join(d)) != OK:
				return false
		elif DirAccess.make_dir_absolute(to.path_join(d)) != OK or not _copy_tree(src, to.path_join(d), skip):
			return false
	return true


## The executable of exported [param row] when it can run on this machine
## (its platform is this OS), or "".
func _runnable_export(row: Dictionary) -> String:
	var host: String = {"macOS": "macos", "Windows": "windows", "Linux": "linux"}.get(OS.get_name(), "")
	if host.is_empty() or row["kind"] != host:
		return ""
	var dir: String = row["dir"]
	if host != "macos":
		var path := dir.path_join(row["file"])
		return path if FileAccess.file_exists(path) else ""
	# The bundle normally carries the executable name (see _rename_app_bundle).
	var bundles := PackedStringArray([str(row["output"]) + ".app"])
	var listing := DirAccess.open(dir)
	if listing != null:
		for entry in listing.get_directories():
			if entry.to_lower().ends_with(".app") and not bundles.has(entry):
				bundles.append(entry)
	for bundle in bundles:
		var macos_dir := dir.path_join(bundle).path_join("Contents/MacOS")
		var files := DirAccess.get_files_at(macos_dir)
		if files.size() == 1:
			return macos_dir.path_join(files[0])
	return ""


## Script errors (see SMOKE_SCRIPT_ERRORS) and other ERROR lines in what an
## exported build printed, each with the "at:" line Godot puts under it and
## once, with " (×n)" when it was printed n times.
static func _smoke_findings(lines: Array[String]) -> Dictionary:
	var script_errors: Array[String] = []
	var errors: Array[String] = []
	var counts := {}
	for i in lines.size():
		var line := lines[i].strip_edges()
		var lower := line.to_lower()
		var is_script := false
		for needle in SMOKE_SCRIPT_ERRORS:
			if lower.contains(needle):
				is_script = true
				break
		if not is_script and not lower.begins_with("error:"):
			continue
		if i + 1 < lines.size() and lines[i + 1].strip_edges().begins_with("at:"):
			line += " (%s)" % lines[i + 1].strip_edges()
		counts[line] = counts.get(line, 0) + 1
		if counts[line] > 1:
			continue
		if is_script:
			script_errors.append(line)
		else:
			errors.append(line)
	for list: Array[String] in [script_errors, errors]:
		for j in list.size():
			if counts[list[j]] > 1:
				list[j] += " (×%d)" % counts[list[j]]
	return {"script_errors": script_errors.slice(0, 100), "errors": errors.slice(0, 100)}


## Build & Publish step 2 for Steam: writes the build script and uploads with
## SteamCMD. Returns false only when the user stopped the run.
func _publish_steam(ctx: Dictionary) -> bool:
	var p: Dictionary = ctx["p"]
	var build_dir: String = ctx["build_dir"]
	var vdf_path := build_dir.path_join("app_build.vdf")
	if not _write_app_build_vdf(vdf_path, p, build_dir, ctx["description"], ctx["rows"]):
		_add_result(ctx, "Steam", false, "The SteamCMD build script could not be written. See the console.")
		return true
	log_line("Wrote %s" % vdf_path, COLOR_INFO)

	log_step("Uploading to Steam")
	var steam_args := _steam_login_args()
	steam_args.append_array(["+run_app_build", vdf_path, "+quit"])
	var typed_code: bool = not %SteamGuardCode.text.strip_edges().is_empty()
	var upload := await run_process_capture(ctx["steamcmd"], steam_args)
	var upload_code: int = upload["code"]
	if _publish_cancelled(ctx):
		return false
	ctx["steam_build_id"] = _steam_build_id(upload["output"])
	if upload_code != 0:
		log_line("SteamCMD upload failed (exit code %d)." % upload_code, COLOR_ERR)
		if ctx["depot_check"] == "confirmed" and _seen_issues.has("build_access_denied"):
			log_line("Steam lists every depot in the table for App %s, so the depot IDs are right; the account's Steamworks permissions are the likely cause." % p["app_id"], COLOR_INFO)
		var guard_explained := _explain_guard_failure(typed_code)
		_explain_known_issues("" if guard_explained else STEAMCMD_FALLBACK, _is_selected(p))
		_add_result(ctx, "Steam", false, "The upload failed. See the console for SteamCMD's error.")
	else:
		_mark_login_verified()
		if _branch_name(p).is_empty():
			log_line("Upload complete. Set the build live in Steamworks → Builds; for a released app the default branch needs confirmation in the Steam Mobile app. A beta branch has to exist in Steamworks first; then the branch field sets builds live on it.", COLOR_OK)
			_add_result(ctx, "Steam", true, "Uploaded. Set the build live in Steamworks → Builds.")
		else:
			log_line("Upload complete and set live on branch '%s'." % _branch_name(p), COLOR_OK)
			_add_result(ctx, "Steam", true, "Uploaded and set live on branch '%s'." % _branch_name(p))
		if _exec_bits_lost and _has_row_kind(ctx, "macos", "steam"):
			var last: Dictionary = (ctx["results"] as Array).back()
			last["text"] = "Uploaded, but the macOS build may not launch: it lost its executable bits. Build macOS depots on a Mac."
			last["color"] = COLOR_WARN
	log_step_done(upload_code == 0)
	return true


## Build & Publish step 2 for itch.io: pushes each itch.io row to its channel
## with butler, stopping at the first failure. Returns false only when the
## user stopped the run.
func _publish_itch(ctx: Dictionary) -> bool:
	var p: Dictionary = ctx["p"]
	var target: String = ctx["target"]
	var pushed := PackedStringArray()
	var web := false
	for row: Dictionary in ctx["rows"]:
		if not row["itch"]:
			if _is_folder_app(p) or row["kind"] != "web":
				log_line("%s has no itch.io channel, so itch.io does not get it." % row["label"], COLOR_INFO)
			continue
		var channel: String = row["channel"]
		log_step("Uploading %s to itch.io (%s:%s)" % [row["label"], target, channel])
		_progress_label = "Push %s" % channel
		var args := ButlerTool.push_args(row["dir"], target, channel, ctx["userversion"])
		var code := await run_process(ctx["butler"], args, KnownIssues.BUTLER, false, _butler_env())
		_progress_label = ""
		if _publish_cancelled(ctx):
			return false
		if code != 0:
			log_line("butler could not push %s to %s:%s (exit code %d)." % [row["label"], target, channel, code], COLOR_ERR)
			_explain_known_issues(BUTLER_FALLBACK, _is_selected(p))
			var done := " (%s went up before it)" % ", ".join(pushed) if not pushed.is_empty() else ""
			_add_result(ctx, "itch.io", false, "The upload of %s failed%s. See the console for butler's error." % [channel, done])
			log_step_done(false)
			return true
		pushed.append(channel)
		web = web or row["kind"] == "web"
		log_step_done(true)
	var version := " as version %s" % ctx["userversion"] if not str(ctx["userversion"]).is_empty() else ""
	log_line("Pushed %s to %s%s. itch.io processes a new build for a minute or two before players can download it; the Edit game page shows its status." % [", ".join(pushed), ButlerTool.page_url(target), version], COLOR_OK)
	if web:
		log_line(ITCH_HTML_NOTE, COLOR_INFO)
	_add_result(ctx, "itch.io", true, "Pushed %s to %s%s." % [", ".join(pushed), target, version])
	return true


## The BuildID SteamCMD reports after run_app_build ("Successfully finished
## AppID 480 build (BuildID 1234567)."), or "" when [param output] has none.
static func _steam_build_id(output: String) -> String:
	var found := RegEx.create_from_string("BuildID\\s+(\\d+)").search_all(output)
	return found.back().get_string(1) if not found.is_empty() else ""


## True when a row of platform [param kind] went to [param target] ("steam"
## or "itch") in this run.
static func _has_row_kind(ctx: Dictionary, kind: String, target: String) -> bool:
	for row: Dictionary in ctx["rows"]:
		if row["kind"] == kind and row[target]:
			return true
	return false


## True when [param builds] (SteamAppInfo.branch_builds) has a build live on
## the lower-case [param branch].
static func _branch_has_build(builds: Dictionary, branch: String) -> bool:
	var build_id := str(builds.get(branch, ""))
	return not build_id.is_empty() and build_id != "0"


## The IDs of [param wanted] that are not in [param listed], each once.
static func _ids_not_listed(wanted: PackedStringArray, listed: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for id in wanted:
		if not listed.has(id) and not out.has(id):
			out.append(id)
	return out


## Ends a Build & Publish run that stopped before a successful upload: closes
## the open step, gives [param p] its description back and leaves the busy state.
func _fail_publish(p: Dictionary, description: String, note := "") -> void:
	log_step_done(false, note)
	_restore_description(p, description)
	_set_busy(false)


## Shows [param text] as the run's banner while [param p] is still on screen.
func _set_run_status(p: Dictionary, text: String, color: String) -> void:
	if _is_selected(p):
		_run_status = { "text": text, "color": color }
		_refresh_banners()


## Puts [param text] back as the build description of [param p]; also into
## the field when that app is still the one on screen.
func _restore_description(p: Dictionary, text: String) -> void:
	if _is_selected(p):
		_set_description(text)
	else:
		p["description"] = text
		_save_projects()


## True while [param p] is the app shown in the main view.
func _is_selected(p: Dictionary) -> bool:
	return _selected_index >= 0 and _selected_index < _projects.size() and is_same(_projects[_selected_index], p)


## Godot 4.2 added --import (import, then quit). [param required] is "4.7".
static func _supports_import_flag(required: String) -> bool:
	var parts := required.split(".")
	if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return false
	var major := int(parts[0])
	return major > 4 or (major == 4 and int(parts[1]) >= 2)


## Creates [param path] with its parents. Logs the reason and the fix when
## that fails.
func _make_dir(path: String) -> bool:
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK or DirAccess.dir_exists_absolute(path):
		return true
	log_line("Could not create the folder %s (%s). Free up disk space and check that this account may write there." % [path, error_string(err)], COLOR_ERR)
	return false


func _unzip_in_place(zip_path: String, dest_dir: String) -> bool:
	# System unzip preserves the executable bits inside the .app bundle.
	var unzip := _find_on_path("unzip") if OS.get_name() != "Windows" else ""
	if not unzip.is_empty():
		var code := await run_process(unzip, ["-o", "-q", zip_path, "-d", dest_dir])
		if code != 0:
			if not _cancel_requested:
				log_line("Could not unpack %s (unzip exit code %d). The disk may be full: free up space and build again." % [zip_path.get_file(), code], COLOR_ERR)
			return false
	else:
		# No unzip on this host (Windows, minimal Linux): Godot's own reader,
		# then put the executable bits back on the bundle's binaries by hand.
		var reader := ZIPReader.new()
		if reader.open(zip_path) != OK:
			log_line("Could not open %s. The export may be damaged: build again, and free up disk space if it keeps failing." % zip_path, COLOR_ERR)
			return false
		var unpacked := PackedStringArray()
		for f in reader.get_files():
			# Never write outside dest_dir, whatever the archive claims.
			if f.is_absolute_path() or ".." in f.replace("\\", "/").split("/"):
				log_line("Skipped '%s' in %s: it points outside the folder." % [f, zip_path.get_file()], COLOR_WARN)
				continue
			var target := dest_dir.path_join(f)
			if f.ends_with("/"):
				if not _make_dir(target):
					reader.close()
					return false
				continue
			if not _make_dir(target.get_base_dir()):
				reader.close()
				return false
			var fa := FileAccess.open(target, FileAccess.WRITE)
			if fa == null:
				log_line("Could not write %s (%s). Free up disk space and try again." % [target, error_string(FileAccess.get_open_error())], COLOR_ERR)
				reader.close()
				return false
			fa.store_buffer(reader.read_file(f))
			fa.close()
			unpacked.append(target)
		reader.close()
		_restore_bundle_exec_bits(unpacked)
	DirAccess.remove_absolute(zip_path)
	log_line("Unpacked %s" % zip_path.get_file(), COLOR_INFO)
	return true


## Marks every file under a Contents/MacOS/ folder executable (0755). Zip
## archives read with ZIPReader lose their Unix mode bits. On Windows the
## call is unavailable, so the bits are lost. Sets _exec_bits_lost so the
## publish ends with a warning banner instead of a plain success.
func _restore_bundle_exec_bits(files: PackedStringArray) -> void:
	var failed := false
	for path in files:
		if not path.contains("/Contents/MacOS/"):
			continue
		if FileAccess.set_unix_permissions(path, 0x1ED) != OK:  # 0755
			failed = true
	if failed:
		_exec_bits_lost = true
		log_line("Could not mark the .app binaries executable, so the macOS build may not launch. Build macOS depots on a Mac, or on Linux with unzip installed.", COLOR_WARN)


## Renames the single .app bundle inside [param depot_dir] to
## "[param base_name].app" so Steam's launch option can use the name shown in
## the depot table. Godot's macOS exporter names the bundle after the project's
## display name (which may contain spaces), ignoring the zip file name.
## Renaming the bundle folder is safe: Info.plist and the ad-hoc signature
## cover the contents, not the folder name. Returns false when no unique
## bundle was found; the publish continues either way.
func _rename_app_bundle(depot_dir: String, base_name: String) -> bool:
	var bundles: PackedStringArray = []
	var dir := DirAccess.open(depot_dir)
	if dir == null:
		return false
	for entry in dir.get_directories():
		if entry.to_lower().ends_with(".app"):
			bundles.append(entry)
	if bundles.size() != 1:
		log_line("Expected one .app bundle in %s, found %d — set the Steamworks launch option to the bundle's actual name." % [depot_dir, bundles.size()], COLOR_WARN)
		return false
	var wanted := base_name + ".app"
	if bundles[0] == wanted:
		return true
	var err := DirAccess.rename_absolute(depot_dir.path_join(bundles[0]), depot_dir.path_join(wanted))
	if err != OK:
		log_line("Could not rename '%s' to '%s' (%s) — set the Steamworks launch option to '%s'." % [bundles[0], wanted, error_string(err), bundles[0]], COLOR_WARN)
		return false
	log_line("Renamed bundle '%s' → '%s' to match the launch option." % [bundles[0], wanted], COLOR_INFO)
	return true


## Writes SteamCMD's app build script for the Steam rows of [param rows]
## (see _make_publish_ctx), each uploaded from its own folder. Returns false
## (with the reason logged) when the file cannot be written.
func _write_app_build_vdf(path: String, p: Dictionary, build_dir: String, description: String, rows: Array) -> bool:
	var lines: PackedStringArray = [
		'"AppBuild"',
		'{',
		'\t"AppID" "%s"' % _vdf_value(str(p["app_id"]).strip_edges()),
		'\t"Desc" "%s"' % _vdf_value(description),
		'\t"BuildOutput" "%s"' % _vdf_value(build_dir.path_join("output")),
		'\t"ContentRoot" "%s"' % _vdf_value(build_dir.path_join("content")),
	]
	var branch := _branch_name(p)
	if not branch.is_empty():
		lines.append('\t"SetLive" "%s"' % _vdf_value(branch))
	lines.append('\t"Depots"')
	lines.append('\t{')
	for row: Dictionary in rows:
		if not row["steam"]:
			continue
		var depot_id: String = row["depot_id"]
		var root: String = row["dir"]
		lines.append_array([
			'\t\t"%s"' % _vdf_value(depot_id),
			'\t\t{',
			'\t\t\t"ContentRoot" "%s"' % _vdf_value(root),
			'\t\t\t"FileMapping"',
			'\t\t\t{',
			'\t\t\t\t"LocalPath" "*"',
			'\t\t\t\t"DepotPath" "."',
			'\t\t\t\t"recursive" "1"',
			'\t\t\t}',
			'\t\t}',
		])
	lines.append('\t}')
	lines.append('}')
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		log_line("Could not write %s (%s). Free up disk space and check that %s is writable." % [path, error_string(FileAccess.get_open_error()), path.get_base_dir()], COLOR_ERR)
		return false
	f.store_string("\n".join(lines))
	f.close()
	return true


## A value for app_build.vdf: SteamCMD reads backslashes as escapes and a
## quote would end the string, so paths use "/" and quotes become apostrophes.
static func _vdf_value(text: String) -> String:
	return text.replace("\\", "/").replace('"', "'")


## Deletes [param path] with everything in it. Returns false when something
## could not be removed (on Windows: a file of a game that is still running).
## Symlinks are removed, never followed.
func _remove_dir_recursive(path: String) -> bool:
	if not DirAccess.dir_exists_absolute(path):
		return true
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	dir.include_hidden = true
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for d in dir.get_directories():
		var child := path.path_join(d)
		if dir.is_link(child):
			DirAccess.remove_absolute(child)
		else:
			_remove_dir_recursive(child)
	DirAccess.remove_absolute(path)
	return not DirAccess.dir_exists_absolute(path)


# ---------------------------------------------------------------------------
# Steam auth + TOTP
# ---------------------------------------------------------------------------

## Wires a toggle button so it flips masking on a LineEdit. Never persisted:
## both fields start masked on every launch.
func _bind_secret_toggle(button: Button, field: LineEdit, what: String) -> void:
	button.toggled.connect(func(on: bool) -> void:
		field.secret = not on
		button.icon = EYE_VISIBLE if on else EYE_HIDDEN
		button.tooltip_text = ("Hide " if on else "Show ") + what
	)


## Generates a Steam Guard code from the base64 shared_secret, same algorithm
## as the steam-totp action from the old GitHub workflow.
static func steam_totp(shared_secret_b64: String, unix_time: int = -1) -> String:
	if unix_time < 0:
		unix_time = int(Time.get_unix_time_from_system())
	var key := Marshalls.base64_to_raw(shared_secret_b64.strip_edges())
	if key.is_empty():
		return ""

	var counter := unix_time / 30
	var msg := PackedByteArray()
	msg.resize(8)
	for i in 8:
		msg[7 - i] = (counter >> (8 * i)) & 0xFF

	var hmac := HMACContext.new()
	hmac.start(HashingContext.HASH_SHA1, key)
	hmac.update(msg)
	var digest := hmac.finish()

	var offset := digest[19] & 0x0F
	var code: int = ((digest[offset] & 0x7F) << 24) \
		| (digest[offset + 1] << 16) \
		| (digest[offset + 2] << 8) \
		| digest[offset + 3]

	var out := ""
	for i in 5:
		out += STEAM_TOTP_ALPHABET[code % STEAM_TOTP_ALPHABET.length()]
		code /= STEAM_TOTP_ALPHABET.length()
	return out


func _current_guard_code() -> String:
	var secret: String = %SteamSharedSecret.text
	if not secret.strip_edges().is_empty():
		return steam_totp(secret)
	return %SteamGuardCode.text.strip_edges()


## SteamCMD login arguments. After one successful login SteamCMD caches its
## session; with a shared secret every later login also gets a fresh code, so
## the flow never needs manual input again. The password is left out on
## purpose: any process can read a command line, so SteamCMD gets it on stdin
## when it asks (see [method _on_password_prompt]).
func _steam_login_args() -> PackedStringArray:
	var args := PackedStringArray()
	var code := _current_guard_code()
	if not code.is_empty():
		args.append_array(["+set_steam_guard_code", code])
	args.append_array(["+login", %SteamUsername.text.strip_edges()])
	return args


## Marks the shared secret red while it cannot produce a code. The code itself
## is never shown: a live 2FA code leaks in screenshots and screen shares.
func _check_shared_secret() -> void:
	var secret: String = %SteamSharedSecret.text
	_set_field_error(%SteamSharedSecret, not secret.strip_edges().is_empty() and steam_totp(secret).is_empty())


func _on_steam_login_pressed() -> void:
	if _accepts_guard_code():
		_submit_guard_code()
		return
	if _is_busy:
		return
	if not _validate_login_fields():
		return
	var steamcmd := _resolve_steamcmd(%SteamCmdBinary.text)
	_set_busy(true)
	log_step("Signing in to Steam")
	%SteamStatusLabel.text = "Signing in…"
	_set_status_dot(%AccountDot, COLOR_WARN)
	var args := _steam_login_args()
	args.append("+quit")
	var typed_code: bool = not %SteamGuardCode.text.strip_edges().is_empty()
	# The user is at the code field: a code typed while SteamCMD signs in is
	# used right away instead of only on the next Sign in.
	_allow_code_submit()
	var code := await run_process(steamcmd, args)
	if _cancel_requested:
		%SteamStatusLabel.text = "Sign-in cancelled"
		_bail_if_cancelled()
		_refresh_setup_state()
		return
	_login_verified = code == 0
	_login_verified_user = %SteamUsername.text.strip_edges() if code == 0 else ""
	_login_persona = ""
	_save_settings()
	if code == 0:
		log_line("Signed in to Steam. SteamCMD cached the session.", COLOR_OK)
		%SteamStatusLabel.text = "Signed in"
		%SteamGuardCode.text = ""
		_set_field_error(%SteamGuardCode, false)
		if not %RememberPassword.button_pressed:
			%SteamPassword.text = ""
		_persist_secrets()
		# Forced so a changed avatar or persona shows up after every explicit login.
		%SteamProfile.fetch(_login_verified_user, steamcmd, true)
	else:
		log_line("Steam sign-in failed (exit code %d)." % code, COLOR_ERR)
		if _seen_issues.has("invalid_password"):
			%SteamStatusLabel.text = "Wrong password"
			_set_field_error(%SteamPassword, true)
			%SteamPassword.grab_focus()
			_explain_known_issues("", false)
		elif _seen_issues.has("rate_limit"):
			%SteamStatusLabel.text = "Too many attempts — wait before retrying"
			_explain_known_issues("", false)
		elif _password_prompt_seen:
			%SteamStatusLabel.text = "Password needed"
			log_line("Enter the password and press Sign in.", COLOR_INFO)
			_set_field_error(%SteamPassword, true)
			%SteamPassword.grab_focus()
		elif not _explain_guard_failure(typed_code):
			%SteamStatusLabel.text = "Sign-in failed"
			_explain_known_issues(STEAMCMD_FALLBACK, false)
	log_step_done(code == 0)
	_set_busy(false)
	_refresh_setup_state()


## After a failed SteamCMD run: when the failure was about a Steam Guard code,
## points the user at the code field and explains the next step. Returns
## false when the failure had nothing to do with Steam Guard.
## [param code_supplied] is true when a code was passed on the command line.
func _explain_guard_failure(code_supplied: bool) -> bool:
	var guard_related := _guard_failure_seen or _guard_prompt_seen or _guard_code_sent
	if not guard_related:
		return false
	auth_needed = auth_needed or cli_mode
	var status: String
	var msg: String
	var focus: LineEdit = %SteamGuardCode
	if not %SteamSharedSecret.text.strip_edges().is_empty() and not _guard_wait_seen:
		# Every login passes a code generated from the secret, so a rejection
		# means the secret or the clock is wrong, not a typing mistake.
		status = "Generated code rejected"
		msg = "Steam did not accept the code generated from the shared secret. Make sure the computer's date and time are set automatically (the codes depend on the exact time), and that the field holds the account's base64 shared_secret, not the revocation code (R12345). Clear the shared secret to use a code from the Steam mobile app or email instead."
		_set_field_error(%SteamSharedSecret, true)
		focus = %SteamSharedSecret
	elif code_supplied or _guard_code_sent:
		status = "Steam Guard code rejected"
		msg = "Steam Guard code not accepted. Codes change every 30 seconds and email codes expire: enter the newest code and press Sign in."
		_set_field_error(%SteamGuardCode, true)
	elif _guard_wait_seen:
		status = "Not approved in time"
		msg = "The sign-in was not approved in the Steam mobile app in time. Approve it sooner, or type a Steam Guard code and press Sign in."
	else:
		status = "Steam Guard code needed"
		msg = "Type the Steam Guard code from the Steam mobile app or your email and press Sign in again."
	%SteamStatusLabel.text = status
	log_line(msg, COLOR_INFO)
	if not %SetupPage.visible and not cli_mode:
		_show_project(-1)  # Put the code field on screen.
	focus.grab_focus()
	focus.select_all()
	return true


## Called (on the main thread) when the running child printed a Steam Guard
## prompt. With a shared secret the code is written straight away; otherwise
## the Guard row is revealed and the login button becomes "Submit code".
func _on_guard_prompt() -> void:
	if _child_stdio == null:
		return
	_guard_prompt_seen = true
	var secret: String = %SteamSharedSecret.text
	if not secret.strip_edges().is_empty() and not (cli_mode and _guard_code_sent):
		var code := steam_totp(secret)
		if not code.is_empty():
			log_line("Steam Guard code requested — sending the generated TOTP code.", COLOR_INFO)
			_guard_code_sent = _write_child_stdin(code)
			return
	_session_lost()
	if cli_mode:
		_stop_for_sign_in("SteamCMD asks for a Steam Guard code%s." % (" again: the generated one was rejected" if _guard_code_sent else ""))
		return
	if _awaiting_guard_code:
		return  # A wrong code makes SteamCMD ask again; the field is already open.
	_awaiting_guard_code = true
	_set_status_dot(%AccountDot, COLOR_WARN)
	if not %SetupPage.visible and not cli_mode:
		_show_project(-1)  # Put the code field on screen.
	%SteamGuardCode.grab_focus()
	%SteamGuardCode.select_all()
	%SteamLoginButton.disabled = false
	%SteamLoginButton.text = SUBMIT_CODE_TEXT
	%SteamStatusLabel.text = "Steam Guard code needed"
	log_line("Enter the Steam Guard code and press Submit code.", COLOR_INFO)


## True while a typed Steam Guard code can go to the running SteamCMD, which
## is when the login button reads "Submit code".
func _accepts_guard_code() -> bool:
	return _awaiting_guard_code or _code_submittable


## Lets the running SteamCMD login take a typed code although it is not at a
## code prompt: the login button becomes "Submit code" until the run ends.
func _allow_code_submit() -> void:
	_code_submittable = true
	%SteamLoginButton.disabled = false
	%SteamLoginButton.text = SUBMIT_CODE_TEXT


## Hands the typed Steam Guard code to the running SteamCMD: written to it
## when it is at a code prompt, otherwise (still signing in, or waiting for the
## mobile app, where SteamCMD reads nothing) by restarting it with the code on
## the command line, which skips the phone confirmation.
func _submit_guard_code() -> void:
	var code: String = %SteamGuardCode.text.strip_edges()
	if code.is_empty():
		_set_field_error(%SteamGuardCode, true)
		%SteamGuardCode.grab_focus()
		return
	if not _awaiting_guard_code:
		if _child_pid <= 0 or not OS.is_process_running(_child_pid):
			return  # The run is ending; its result decides what comes next.
		_guard_restart_code = code
		log_line("Restarting SteamCMD with the Steam Guard code…", COLOR_INFO)
		%SteamStatusLabel.text = "Checking Steam Guard code…"
		_end_guard_wait()
		%SteamLoginButton.disabled = true  # until the restarted run ends
		_kill_child()
		return
	if not _write_child_stdin(code):
		log_line("SteamCMD is no longer waiting for a code. Press Sign in to start again; the code in the field is sent along.", COLOR_ERR)
		_end_guard_wait()
		return
	_guard_code_sent = true
	log_line("Steam Guard code sent.", COLOR_INFO)
	%SteamStatusLabel.text = "Checking Steam Guard code…"
	_end_guard_wait()


## Called (on the main thread) when SteamCMD printed that it is waiting for
## the login to be approved in the Steam mobile app. Nothing to send: SteamCMD
## polls Steam itself; the user just needs to know where to look.
func _on_guard_wait() -> void:
	if _guard_wait_seen:
		return
	_guard_wait_seen = true
	if cli_mode:
		_stop_for_sign_in("SteamCMD waits for the sign-in to be approved in the Steam mobile app.")
		return
	_set_status_dot(%AccountDot, COLOR_WARN)
	%SteamStatusLabel.text = "Approve in the Steam mobile app…"
	_allow_code_submit()
	if not %SetupPage.visible and not cli_mode:
		_show_project(-1)  # Put the code field on screen.
	log_line("Steam sent a confirmation to the Steam mobile app. Approve it there to continue, or type the Steam Guard code and press Submit code.", COLOR_INFO)


## An authenticated SteamCMD run just succeeded for the username in the field:
## whatever it took (cached session, password, code), SteamCMD holds a fresh
## session now. Restores the verified state a [method _session_lost] dropped.
func _mark_login_verified() -> void:
	if _guard_code_sent:
		%SteamGuardCode.text = ""  # Used up; later runs use the cached session.
	var user: String = %SteamUsername.text.strip_edges()
	if user.is_empty() or (_login_verified and _login_verified_user == user):
		return
	_login_verified = true
	_login_verified_user = user
	_save_settings()
	_refresh_setup_state()


## SteamCMD asked for the password or a Steam Guard code, so the session it
## cached at the last verified sign-in is gone (expired, or another Steam
## install rewrote the config). Forget the verified state so the checklist and
## the account status row tell the truth once this run ends; a successful sign-in or
## upload sets it again.
func _session_lost() -> void:
	if not _login_verified:
		return
	_login_verified = false
	_login_verified_user = ""
	_save_settings()
	log_line("SteamCMD has no cached session for this account any more — a fresh sign-in is needed.", COLOR_WARN)
	%SteamStatusLabel.text = "Not signed in"
	_set_status_dot(%AccountDot, COLOR_WARN)


## Sign out: deletes the login token SteamCMD cached (config.vdf /
## local.vdf in the folders this app owns) and forgets the verified state, so
## the next "Sign in" runs the full password + Steam Guard flow again. The
## password, shared secret and cached avatar files are left alone.
func _on_steam_sign_out_pressed() -> void:
	if _is_busy or _accepts_guard_code():
		return
	log_step("Signing out of Steam")
	var removed := 0
	for path in steamcmd_session_files(_resolve_steamcmd(%SteamCmdBinary.text)):
		if not FileAccess.file_exists(path):
			continue
		if DirAccess.remove_absolute(path) == OK:
			removed += 1
			log_line("Removed %s" % path, COLOR_INFO)
		else:
			log_line("Could not remove %s. Quit the app and delete that file by hand to finish signing out." % path, COLOR_WARN)
	if removed == 0:
		log_line("No cached SteamCMD session found.", COLOR_INFO)
	_login_verified = false
	_login_verified_user = ""
	_login_persona = ""
	%AvatarImage.texture = null
	%AvatarImage.remove_meta("user")
	%SteamGuardCode.text = ""
	_set_field_error(%SteamGuardCode, false)
	_save_settings()
	%SteamStatusLabel.text = "Signed out"
	_set_status_dot(%AccountDot, COLOR_MUTED)
	log_line("Signed out. The next sign-in will ask for the password and Steam Guard again.", COLOR_OK)
	log_step_done(true)
	_refresh_setup_state()


## Command-line mode: SteamCMD wants something only a person can give, and
## nobody can answer it there. Stops SteamCMD and flags the run.
func _stop_for_sign_in(reason: String) -> void:
	auth_needed = true
	log_line("%s The command line cannot answer that: sign in once in the %s window (Setup page → Sign in); SteamCMD caches the session and later runs from the command line use it." % [reason, _app_name()], COLOR_ERR)
	_kill_child()


## Restores the login button after a code was sent or the process ended.
func _end_guard_wait() -> void:
	_awaiting_guard_code = false
	_code_submittable = false
	%SteamLoginButton.text = LOGIN_BUTTON_TEXT
	%SteamLoginButton.disabled = _is_busy


# ---------------------------------------------------------------------------
# SteamCMD – resolve / fetch / browse / download
# ---------------------------------------------------------------------------

func _steamcmd_install_dir() -> String:
	return OS.get_user_data_dir().path_join("steamcmd")


## The user's home directory on every platform. Windows normally has no
## HOME variable; USERPROFILE is the equivalent there.
static func _home_dir() -> String:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	return home


func _path_dirs() -> PackedStringArray:
	var sep := ";" if OS.get_name() == "Windows" else ":"
	var out := PackedStringArray()
	for d in OS.get_environment("PATH").split(sep, false):
		if not out.has(d):
			out.append(d)
	return out


## First executable called [param name] on PATH, or "" when there is none.
func _find_on_path(name: String) -> String:
	for d in _path_dirs():
		var full := d.path_join(name)
		if FileAccess.file_exists(full):
			return full
	return ""


## Turns what the user typed into a runnable path. A bare command name
## ("steamcmd") is looked up on PATH; anything with a directory part must
## exist as a file. Scripts (steamcmd.sh, the Homebrew wrapper) are the real
## entry points, so they are deliberately accepted here.
func _resolve_steamcmd(text: String) -> String:
	text = text.strip_edges()
	if text.is_empty():
		return ""
	if FileAccess.file_exists(text):
		return text
	if "/" in text or "\\" in text:
		return ""
	var names: PackedStringArray = [text]
	if OS.get_name() == "Windows":
		names.append(text + ".exe")
	for d in _path_dirs():
		for n in names:
			var full := d.path_join(n)
			if FileAccess.file_exists(full):
				return full
	return ""


## Well-known SteamCMD locations: PATH, package-manager dirs, the folders
## Valve's docs suggest, and finally this app's own download folder.
## [param include_user_folders] false skips Desktop/Downloads/Documents on
## macOS, where touching them pops a privacy prompt; the silent first-launch
## detect must not ask for access the user never requested.
func _steamcmd_candidates(include_user_folders: bool = true) -> PackedStringArray:
	var home := _home_dir()
	var dirs := _path_dirs()
	dirs.append_array([
		"/usr/local/bin",
		"/opt/homebrew/bin",
		"/usr/games",
		"C:/steamcmd",
	])
	if not home.is_empty():
		dirs.append_array([
			home.path_join(".steam/steamcmd"),
			home.path_join("steamcmd"),
			home.path_join("Steam"),
		])
		if include_user_folders or OS.get_name() != "macOS":
			dirs.append_array([
				# Where Windows users tend to unzip Valve's archive.
				home.path_join("Desktop/steamcmd"),
				home.path_join("Downloads/steamcmd"),
				home.path_join("Documents/steamcmd"),
			])
	for env_dir in ["ProgramData", "LOCALAPPDATA"]:
		var base := OS.get_environment(env_dir)
		if base.is_empty():
			continue
		dirs.append(base.path_join("chocolatey/bin" if env_dir == "ProgramData" else "steamcmd"))
	dirs.append(_steamcmd_install_dir())

	var out := PackedStringArray()
	for d in dirs:
		if d.is_empty():
			continue
		for n in ["steamcmd", "steamcmd.sh", "steamcmd.exe"]:
			var full := d.path_join(n)
			if FileAccess.file_exists(full) and not out.has(full):
				out.append(full)
	return out


## Refreshes the SteamCMD status dot/label. Returns the resolved path or "".
func _check_steamcmd() -> String:
	var text: String = %SteamCmdBinary.text.strip_edges()
	var resolved := _resolve_steamcmd(text)
	if text.is_empty():
		%SteamCmdStatusLabel.text = "Not installed"
		_set_status_dot(%SteamCmdDot, COLOR_MUTED)
	elif resolved.is_empty():
		%SteamCmdStatusLabel.text = "Not found"
		_set_status_dot(%SteamCmdDot, COLOR_ERR)
	else:
		%SteamCmdStatusLabel.text = "Ready"
		_set_status_dot(%SteamCmdDot, COLOR_OK)
	%SteamCmdStatusLabel.tooltip_text = resolved
	%SteamCmdBinary.tooltip_text = resolved if not resolved.is_empty() else "Path to the steamcmd executable, or just 'steamcmd' if it is on your PATH. Shared by all apps."
	# Same button either way: fetch one when nothing is set up, otherwise let
	# the installed copy update itself.
	var missing := resolved.is_empty()
	%DownloadSteamCmdButton.text = DOWNLOAD_BUTTON_TEXT if missing else UPDATE_BUTTON_TEXT
	%DownloadSteamCmdButton.tooltip_text = DOWNLOAD_BUTTON_TOOLTIP if missing else UPDATE_BUTTON_TOOLTIP
	return resolved


func _set_steamcmd_path(path: String) -> void:
	%SteamCmdBinary.text = path  # text_changed does not fire on set, commit manually
	_set_field_error(%SteamCmdBinary, false)
	_save_settings()
	_refresh_setup_state()


## Fetch button: confirms the current entry, or searches for one when it is
## empty or invalid.
func _on_detect_steamcmd_pressed() -> void:
	var current := _check_steamcmd()
	if not current.is_empty():
		log_line("SteamCMD OK at %s" % current, COLOR_OK)
		return
	var found := _steamcmd_candidates()
	if found.is_empty():
		log_line("No SteamCMD found on PATH or in common folders. Use the folder button or Download SteamCMD.", COLOR_WARN)
		return
	log_line("Found SteamCMD at %s" % found[0], COLOR_OK)
	_set_steamcmd_path(found[0])


## First launch: fills an empty path from PATH / well-known folders so the
## SteamCMD row can start out as "Ready" without any clicking.
func _auto_detect_steamcmd() -> void:
	if not %SteamCmdBinary.text.strip_edges().is_empty():
		return
	var found := _steamcmd_candidates(false)
	if found.is_empty():
		return
	log_line("Found SteamCMD at %s" % found[0], COLOR_OK)
	_set_steamcmd_path(found[0])


func _on_steamcmd_selected(path: String) -> void:
	_set_steamcmd_path(path)
	log_line("SteamCMD set to %s" % path, COLOR_INFO)


## Fetches Valve's archive into user://steamcmd, unpacks it, runs it once so
## it can update itself, then points the field at the result.
func _on_download_steamcmd_pressed() -> void:
	if _is_busy:
		return
	var installed := _check_steamcmd()
	if not installed.is_empty():
		_update_steamcmd(installed)
		return
	var host := OS.get_name()
	if not STEAMCMD_URLS.has(host):
		log_line("No SteamCMD download is available for %s. See %s" % [host, STEAMCMD_DOCS_URL], COLOR_ERR)
		return
	var url: String = STEAMCMD_URLS[host]
	var dir := _steamcmd_install_dir()
	if not _make_dir(dir):
		return
	_steamcmd_archive = dir.path_join(url.get_file())

	_set_busy(true)
	log_step("Downloading SteamCMD from %s" % url)
	_set_status_dot(%SteamCmdDot, COLOR_WARN)
	_steamcmd_http.download_file = _steamcmd_archive
	var err := _steamcmd_http.request(url)
	if err != OK:
		log_line("Could not start the download (%s). Check your internet connection and try again, or download SteamCMD yourself from %s and pick it with the folder button." % [error_string(err), STEAMCMD_DOCS_URL], COLOR_ERR)
		log_step_done(false)
		_set_busy(false)
		return

	_steamcmd_downloading = true
	var finished := await _await_download(_steamcmd_http, %SteamCmdStatusLabel, url.get_file(), func() -> bool: return _steamcmd_downloading)
	if not finished:
		_steamcmd_downloading = false
		DirAccess.remove_absolute(_steamcmd_archive)
		_finish_bar(false)
		log_line("The SteamCMD download stalled (no data for %.0f s). Check your internet connection, VPN or firewall and press Download SteamCMD again, or download it yourself from %s and pick it with the folder button." % [DOWNLOAD_STALL_MS / 1000.0, STEAMCMD_DOCS_URL], COLOR_ERR)
		log_step_done(false, "stalled")
		_refresh_setup_state()
		_set_busy(false)
		return
	# cancel_request() never emits request_completed, so finish up here.
	if _cancel_requested:
		DirAccess.remove_absolute(_steamcmd_archive)
		_finish_bar(false)
		%SteamCmdStatusLabel.text = "Download cancelled"
		_bail_if_cancelled()
		_refresh_setup_state()


func _on_steamcmd_download_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_steamcmd_downloading = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish_bar(false)
		var why := ("Valve's server answered HTTP %d" % code) if result == HTTPRequest.RESULT_SUCCESS else KnownIssues.http_result_text(result)
		log_line("SteamCMD download failed: %s. Press Download SteamCMD to try again, or download it yourself from %s and pick it with the folder button." % [why, STEAMCMD_DOCS_URL], COLOR_ERR)
		log_step_done(false, "HTTP %d" % code if result == HTTPRequest.RESULT_SUCCESS else "no download")
		DirAccess.remove_absolute(_steamcmd_archive)
		_refresh_setup_state()
		_set_busy(false)
		return
	_finish_bar(true)
	log_line("Downloaded %s" % _steamcmd_archive.get_file(), COLOR_INFO)
	log_step_done(true)
	log_step("Unpacking SteamCMD")

	%SteamCmdStatusLabel.text = "Unpacking…"
	_set_status_dot(%SteamCmdDot, COLOR_WARN)
	var dir := _steamcmd_install_dir()
	var is_windows := OS.get_name() == "Windows"
	var ok: bool
	if is_windows:
		ok = await _unzip_in_place(_steamcmd_archive, dir)
	else:
		# System tar keeps the executable bits on steamcmd.sh and the binary.
		var tar := _find_on_path("tar")
		if tar.is_empty():
			log_line("No 'tar' on PATH — install it (or unpack %s into %s yourself)." % [_steamcmd_archive.get_file(), dir], COLOR_ERR)
			ok = false
		else:
			ok = await run_process(tar, ["-xzf", _steamcmd_archive, "-C", dir]) == 0
			DirAccess.remove_absolute(_steamcmd_archive)
	if _bail_if_cancelled():
		_refresh_setup_state()
		return
	var exe := dir.path_join("steamcmd.exe" if is_windows else "steamcmd.sh")
	if not ok or not FileAccess.file_exists(exe):
		log_line("Could not unpack SteamCMD into %s. The download may be damaged or the disk full: free up space and press Download SteamCMD again." % dir, COLOR_ERR)
		log_step_done(false)
		_refresh_setup_state()
		_set_busy(false)
		return
	log_step_done(true)

	# The archive is only a bootstrapper: the first run downloads the real
	# client. Doing it now also proves the thing launches on this machine.
	log_step("Running SteamCMD once so it can update itself")
	%SteamCmdStatusLabel.text = "Updating…"
	var boot := await _run_steamcmd_boot(exe)
	if _bail_if_cancelled():
		_set_steamcmd_path(exe)  # Unpacked fine; only the self-update was cut short.
		return
	_report_steamcmd_boot(boot, "SteamCMD is ready.")
	_set_steamcmd_path(exe)
	_set_busy(false)


## "Update SteamCMD": runs the installed copy once so Valve's own updater
## refreshes it. Works for any path, not only the app's download folder.
func _update_steamcmd(exe: String) -> void:
	_set_busy(true)
	log_step("Updating SteamCMD")
	%SteamCmdStatusLabel.text = "Updating…"
	_set_status_dot(%SteamCmdDot, COLOR_WARN)
	var boot := await _run_steamcmd_boot(exe)
	if _bail_if_cancelled():
		_refresh_setup_state()
		return
	_report_steamcmd_boot(boot, "SteamCMD is up to date.")
	_refresh_setup_state()
	_set_busy(false)


## Runs "steamcmd +quit" and returns its exit code. A run that just updated
## SteamCMD can end with a non-zero code although the update worked; one more
## run then tells whether the fresh copy really starts.
func _run_steamcmd_boot(exe: String) -> int:
	var res := await run_process_capture(exe, PackedStringArray(["+quit"]))
	if res["code"] != 0 and not _cancel_requested and str(res["output"]).to_lower().contains("update complete"):
		log_line("SteamCMD updated itself; running it once more to finish.", COLOR_INFO)
		res = await run_process_capture(exe, PackedStringArray(["+quit"]))
	return res["code"]


## Logs the outcome of a "steamcmd +quit" run and closes the open step.
func _report_steamcmd_boot(code: int, ok_message: String) -> void:
	if code != 0:
		log_line("SteamCMD exited with code %d." % code, COLOR_WARN)
		if not _explain_known_issues("", false):
			_log_steamcmd_runtime_hint()
			log_line("→ The reason is usually in SteamCMD's last lines above. If it does not make sense, press the copy button in the console header and paste the result to an AI or on Discord.", COLOR_INFO)
	else:
		log_line(ok_message, COLOR_OK)
	log_step_done(code == 0)


## SteamCMD ships as an Intel / 32-bit binary; say what the host is missing
## when it fails to start or exits early.
func _log_steamcmd_runtime_hint() -> void:
	match OS.get_name():
		"macOS":
			if OS.has_feature("arm64"):
				log_line("SteamCMD is an Intel binary. On Apple Silicon install Rosetta first: softwareupdate --install-rosetta", COLOR_WARN)
		"Linux":
			log_line("SteamCMD is a 32-bit binary. Install the 32-bit runtime first: Debian/Ubuntu 'sudo apt install lib32gcc-s1', Fedora 'sudo dnf install glibc.i686 libstdc++.i686', Arch enable multilib and install lib32-gcc-libs.", COLOR_WARN)


## An HTTPRequest for a tool download: no timeout (the archive can take a
## while; _await_download watches for stalls) and its own thread.
func _make_download_request(on_completed: Callable) -> HTTPRequest:
	var http := HTTPRequest.new()
	http.timeout = 0
	http.use_threads = true
	http.request_completed.connect(on_completed)
	add_child(http)
	return http


## Shows the progress of the download [param http] is running in [param status]
## and in a console bar called [param bar_label], while [param running]
## returns true (the completed handler or the stop button clear it). The
## request has no timeout, so a connection that stops delivering would hang
## forever: after DOWNLOAD_STALL_MS without a new byte it is cancelled and
## this returns false.
func _await_download(http: HTTPRequest, status: Label, bar_label: String, running: Callable) -> bool:
	var last_bytes := -1
	var last_progress_ms := Time.get_ticks_msec()
	while running.call():
		var got := http.get_downloaded_bytes()
		var total := http.get_body_size()
		if total > 0:
			status.text = "Downloading…  %d%%" % int(100.0 * got / total)
			_progress_update(bar_label, 100.0 * got / total)
		else:
			status.text = "Downloading…  %d KB" % (got >> 10)
		if got != last_bytes:
			last_bytes = got
			last_progress_ms = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - last_progress_ms > DOWNLOAD_STALL_MS:
			http.cancel_request()
			return false
		await get_tree().process_frame
	return true


# ---------------------------------------------------------------------------
# butler (itch.io's upload tool) – resolve / find / browse / download
# ---------------------------------------------------------------------------

## Path and version of the butler _check_butler last asked, so the setup
## page does not start butler on every refresh.
var _butler_version_path := ""
var _butler_version := ""


## Turns what the user typed into a runnable butler: a file path, or a bare
## name looked up on PATH. "" when neither works.
func _resolve_butler(text: String) -> String:
	text = text.strip_edges()
	if text.is_empty():
		return ""
	if FileAccess.file_exists(text):
		return text
	if "/" in text or "\\" in text:
		return ""
	var names: PackedStringArray = [text]
	if OS.get_name() == "Windows" and not text.ends_with(".exe"):
		names.append(text + ".exe")
	for d in _path_dirs():
		for n in names:
			var full := d.path_join(n)
			if FileAccess.file_exists(full):
				return full
	return ""


## "15.31.0" for the butler at [param exe], "" when it does not answer.
## butler prints its version to stderr within a few milliseconds, so this
## runs synchronously.
static func _probe_butler_version(exe: String) -> String:
	var output: Array = []
	if OS.execute(exe, PackedStringArray(["-V"]), output, true) != 0 or output.is_empty():
		return ""
	return ButlerTool.parse_version(str(output[0]))


## Refreshes the butler status dot, label and Download button. Returns the
## resolved path or "".
func _check_butler() -> String:
	var text: String = %ButlerBinary.text.strip_edges()
	var resolved := _resolve_butler(text)
	if resolved != _butler_version_path:
		_butler_version_path = resolved
		_butler_version = _probe_butler_version(resolved) if not resolved.is_empty() else ""
	if text.is_empty():
		%ButlerStatusLabel.text = "Not installed"
		_set_status_dot(%ButlerDot, COLOR_MUTED)
	elif resolved.is_empty():
		%ButlerStatusLabel.text = "Not found"
		_set_status_dot(%ButlerDot, COLOR_ERR)
	elif _butler_version.is_empty():
		%ButlerStatusLabel.text = "Found, but it did not report a version"
		_set_status_dot(%ButlerDot, COLOR_WARN)
	else:
		%ButlerStatusLabel.text = "Ready · v%s%s" % [_butler_version, " (from the itch app)" if ButlerTool.is_itch_app_copy(resolved) else ""]
		_set_status_dot(%ButlerDot, COLOR_OK)
	%ButlerStatusLabel.tooltip_text = resolved
	%ButlerBinary.tooltip_text = resolved if not resolved.is_empty() else "Path to butler, itch.io's upload tool, or just 'butler' if it is on your PATH. Shared by all apps."
	var own := resolved.is_empty() or ButlerTool.is_own_copy(resolved)
	%DownloadButlerButton.text = "Download butler" if resolved.is_empty() else "Update butler"
	%DownloadButlerButton.visible = own
	%DownloadButlerButton.tooltip_text = "Downloads itch.io's official butler into this app's data folder and fills in the path" if resolved.is_empty() \
		else "Downloads the newest butler from itch.io over this app's copy"
	return resolved


func _set_butler_path(path: String) -> void:
	%ButlerBinary.text = path  # text_changed does not fire on set, commit manually
	_set_field_error(%ButlerBinary, false)
	_save_settings()
	_refresh_setup_state()


func _on_detect_butler_pressed() -> void:
	var current := _check_butler()
	if not current.is_empty():
		log_line("butler OK at %s" % current, COLOR_OK)
		return
	var found := ButlerTool.candidates(_home_dir(), _path_dirs())
	if found.is_empty():
		log_line("No butler found on PATH, in the itch app or in this app's folder. Press Download butler, or pick it with the folder button.", COLOR_WARN)
		return
	log_line("Found butler at %s" % found[0], COLOR_OK)
	_set_butler_path(found[0])


## First launch: fills an empty path so the butler row can start out ready.
func _auto_detect_butler() -> void:
	if not %ButlerBinary.text.strip_edges().is_empty():
		return
	var found := ButlerTool.candidates(_home_dir(), _path_dirs())
	if found.is_empty():
		return
	log_line("Found butler at %s" % found[0], COLOR_OK)
	_set_butler_path(found[0])


func _on_butler_selected(path: String) -> void:
	_set_butler_path(path)
	log_line("butler set to %s" % path, COLOR_INFO)


## Fetches itch.io's butler archive into user://butler and unpacks it; also
## "Update butler" for that same copy. A butler from the itch app or a
## package manager is left alone: its owner keeps it up to date.
func _on_download_butler_pressed() -> void:
	if _is_busy:
		return
	var url := ButlerTool.download_url()
	if url.is_empty():
		log_line("itch.io has no butler build for this computer (%s, %s). See %s" % [OS.get_name(), Engine.get_architecture_name(), ButlerTool.DOCS_URL], COLOR_ERR)
		return
	var dir := ButlerTool.install_dir()
	if not _make_dir(dir):
		return
	_butler_archive = dir.path_join("butler.zip")

	_set_busy(true)
	log_step("Downloading butler from itch.io")
	_set_status_dot(%ButlerDot, COLOR_WARN)
	_butler_http.download_file = _butler_archive
	var err := _butler_http.request(url)
	if err != OK:
		log_line("Could not start the download (%s). Check your internet connection and try again, or get butler from %s and pick it with the folder button." % [error_string(err), ButlerTool.DOCS_URL], COLOR_ERR)
		log_step_done(false)
		_set_busy(false)
		return
	_butler_downloading = true
	var finished := await _await_download(_butler_http, %ButlerStatusLabel, "butler", func() -> bool: return _butler_downloading)
	if not finished:
		_butler_downloading = false
		DirAccess.remove_absolute(_butler_archive)
		_finish_bar(false)
		log_line("The butler download stalled (no data for %.0f s). Check your internet connection, VPN or firewall and press Download butler again." % (DOWNLOAD_STALL_MS / 1000.0), COLOR_ERR)
		log_step_done(false, "stalled")
		_refresh_setup_state()
		_set_busy(false)
		return
	# cancel_request() never emits request_completed, so finish up here.
	if _cancel_requested:
		DirAccess.remove_absolute(_butler_archive)
		_finish_bar(false)
		%ButlerStatusLabel.text = "Download cancelled"
		_bail_if_cancelled()
		_refresh_setup_state()


func _on_butler_download_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_butler_downloading = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish_bar(false)
		var why := ("itch.io answered HTTP %d" % code) if result == HTTPRequest.RESULT_SUCCESS else KnownIssues.http_result_text(result)
		log_line("butler download failed: %s. Press Download butler to try again, or get it from %s and pick it with the folder button." % [why, ButlerTool.DOCS_URL], COLOR_ERR)
		log_step_done(false, "HTTP %d" % code if result == HTTPRequest.RESULT_SUCCESS else "no download")
		DirAccess.remove_absolute(_butler_archive)
		_refresh_setup_state()
		_set_busy(false)
		return
	_finish_bar(true)
	log_line("Downloaded %s" % _butler_archive.get_file(), COLOR_INFO)
	log_step_done(true)

	log_step("Unpacking butler")
	%ButlerStatusLabel.text = "Unpacking…"
	var dir := ButlerTool.install_dir()
	var exe := dir.path_join(ButlerTool.exe_name())
	DirAccess.remove_absolute(exe)  # An update replaces the old copy.
	var ok := await _unzip_in_place(_butler_archive, dir)
	if _bail_if_cancelled():
		_refresh_setup_state()
		return
	# Godot's own zip reader drops the executable bit; put it back.
	if ok and OS.get_name() != "Windows" and FileAccess.file_exists(exe):
		FileAccess.set_unix_permissions(exe, 0x1ED)  # 0755
	if not ok or not FileAccess.file_exists(exe):
		log_line("Could not unpack butler into %s. The download may be damaged or the disk full: free up space and press Download butler again." % dir, COLOR_ERR)
		log_step_done(false)
		_refresh_setup_state()
		_set_busy(false)
		return
	_butler_version_path = ""  # Probe the new copy.
	_set_butler_path(exe)
	if _butler_version.is_empty():
		log_line("butler was unpacked to %s but did not start. If your security software blocks it, allow it and press Find." % exe, COLOR_ERR)
		log_step_done(false)
	else:
		log_line("butler %s is ready." % _butler_version, COLOR_OK)
		log_step_done(true)
	_set_busy(false)


# ---------------------------------------------------------------------------
# itch.io account (API key)
# ---------------------------------------------------------------------------

## True once Sign in accepted the key that is in the field now.
func _itch_ok() -> bool:
	return _itch_verified and not %ItchApiKey.text.strip_edges().is_empty()


## A changed key is a different account (or none): it needs Sign in again.
func _on_itch_key_changed(_text: String) -> void:
	_set_field_error(%ItchApiKey, false)
	if _itch_verified:
		_itch_verified = false
		_itch_profile_serial = -1
		_itch_games.clear()
		_itch_games_loaded = false
		%ItchStatusLabel.text = "Press Sign in to check the new key"
		_save_settings()
	_refresh_setup_state()


func _on_itch_sign_in_pressed() -> void:
	var key: String = %ItchApiKey.text.strip_edges()
	if key.is_empty():
		log_line("Paste an itch.io API key first: itch.io → Settings → API keys → Generate new API key (the key button opens that page).", COLOR_ERR)
		_set_field_error(%ItchApiKey, true)
		%ItchApiKey.grab_focus()
		return
	log_line("Checking the itch.io API key…", COLOR_INFO)
	%ItchStatusLabel.text = "Signing in…"
	_set_status_dot(%ItchDot, COLOR_WARN)
	%ItchSignInButton.disabled = true
	_itch_profile_serial = %ItchApi.fetch_profile(key)


func _on_itch_profile_ready(serial: int, user: Dictionary, texture: Texture2D) -> void:
	if serial != _itch_profile_serial:
		return  # Late answer for a key that is no longer in the field.
	_itch_profile_serial = -1
	var fresh: bool = not _itch_verified or _itch_user != user["username"]
	_itch_verified = true
	_itch_user = user["username"]
	_itch_display = user["display_name"]
	_itch_user_id = user["id"]
	%ItchAvatarImage.texture = texture
	%ItchAvatarImage.set_meta("user", _itch_user if texture != null else "")
	_save_settings()
	_persist_secrets()
	%ItchStatusLabel.text = "Signed in as %s" % _itch_user
	if fresh:
		log_line("Signed in to itch.io as %s." % _itch_user, COLOR_OK)
	%ItchSignInButton.disabled = _is_busy
	_refresh_setup_state()
	if fresh and _selected_index >= 0 and _itch_on(_projects[_selected_index]):
		_refresh_itch_game(false)


func _on_itch_profile_failed(serial: int, reason: String, unauthorized: bool) -> void:
	if serial != _itch_profile_serial:
		return
	_itch_profile_serial = -1
	%ItchSignInButton.disabled = _is_busy
	if not unauthorized and _itch_verified:
		# Offline at start: keep the remembered sign-in, butler will tell.
		log_line("Could not refresh the itch.io account (%s)." % reason, COLOR_INFO)
		_refresh_setup_state()
		return
	_itch_verified = false
	_save_settings()
	if unauthorized:
		%ItchStatusLabel.text = "Key not accepted"
		_set_field_error(%ItchApiKey, true)
		log_line("itch.io did not accept the API key. Copy it again from itch.io → Settings → API keys (a revoked key stops working).", COLOR_ERR)
	else:
		%ItchStatusLabel.text = "Sign-in failed"
		log_line("Could not check the itch.io API key: %s. Try again in a moment." % reason, COLOR_ERR)
	_refresh_setup_state()


## Sign out: forgets the key (also in the credential store) and the account.
func _on_itch_sign_out_pressed() -> void:
	if _is_busy:
		return
	_itch_verified = false
	_itch_user = ""
	_itch_display = ""
	_itch_user_id = ""
	_itch_games.clear()
	_itch_games_loaded = false
	_itch_profile_serial = -1
	%ItchApiKey.text = ""
	%ItchAvatarImage.texture = null
	_save_settings()
	_persist_secrets()
	%ItchStatusLabel.text = "Signed out"
	log_line("Signed out of itch.io. The API key was removed from this app; it still works until you revoke it on itch.io → Settings → API keys.", COLOR_OK)
	_refresh_setup_state()


# ---------------------------------------------------------------------------
# Process runner – streams stdout/stderr into the console live
# ---------------------------------------------------------------------------

## Absolute path of the private HOME SteamCMD runs with on macOS and Linux.
## SteamCMD keeps its cached login (config.vdf, local.vdf) under $HOME there,
## in the same folder the Steam desktop client uses. The client rewrites that
## folder whenever it logs in, which throws SteamCMD's token away and brings
## the password + Steam Guard prompt back. A HOME of our own keeps the two apart.
## On Windows SteamCMD stores everything next to steamcmd.exe, so "" (no wrapper).
static func steamcmd_home() -> String:
	if OS.get_name() == "Windows":
		return ""
	return ProjectSettings.globalize_path("user://steamcmd_home")


## Every file SteamCMD may keep a cached login token in, limited to folders
## this app owns: the private HOME from [method steamcmd_home], the folder of
## [param steamcmd_path] (zip / Windows installs keep config next to the exe)
## and the app's own SteamCMD download. The user's real HOME is deliberately
## left out; deleting its config.vdf would log the Steam desktop client out.
static func steamcmd_session_files(steamcmd_path: String) -> PackedStringArray:
	var config_dirs := PackedStringArray()
	var home := steamcmd_home()
	if not home.is_empty():
		match OS.get_name():
			"macOS":
				config_dirs.append(home.path_join("Library/Application Support/Steam/config"))
			"Linux":
				config_dirs.append_array([
					home.path_join(".steam/steamcmd/config"),
					home.path_join("Steam/config"),
					home.path_join(".local/share/Steam/config"),
				])
	if not steamcmd_path.is_empty():
		config_dirs.append(steamcmd_path.get_base_dir().path_join("config"))
	config_dirs.append(OS.get_user_data_dir().path_join("steamcmd/config"))
	var out := PackedStringArray()
	for dir in config_dirs:
		for file in ["config.vdf", "local.vdf"]:
			var path := dir.path_join(file)
			if not out.has(path):
				out.append(path)
	return out


## True when [param exe] is a SteamCMD binary or launcher script (steamcmd,
## steamcmd.sh, steamcmd.exe, the Homebrew wrapper).
static func is_steamcmd_exe(exe: String) -> bool:
	return exe.get_file().to_lower().get_basename() == "steamcmd"


## Command line that actually starts [param exe]: SteamCMD on macOS/Linux is
## wrapped in `/usr/bin/env HOME=<steamcmd_home()>` (Godot cannot set a child's
## environment directly); everything else runs unchanged.
## Returns { "exe": String, "args": PackedStringArray }.
static func _steamcmd_launch(exe: String, args: PackedStringArray) -> Dictionary:
	var home := steamcmd_home()
	if home.is_empty() or not is_steamcmd_exe(exe):
		return {"exe": exe, "args": args}
	DirAccess.make_dir_recursive_absolute(home)
	var wrapped := PackedStringArray(["HOME=%s" % home, exe])
	wrapped.append_array(args)
	return {"exe": "/usr/bin/env", "args": wrapped}


## Runs [param exe] with [param args] and returns its exit code once done.
## Output is streamed to the console as it arrives. Passwords are masked.
## SteamCMD runs with its own HOME, see [method _steamcmd_launch].
## [param tool] (KnownIssues.GODOT, …) picks the known problems its output
## is checked against; SteamCMD is recognised by name.
## A Steam Guard code submitted while SteamCMD was not at a code prompt kills
## the run and starts it again with the code (see [method _submit_guard_code]);
## [param restarted] marks that second launch.
## [param env] (name → value) is set in this process's environment only for
## the instant the child is started, which inherits it: the way the itch.io
## API key reaches butler without showing up on a command line.
func run_process(exe: String, args: PackedStringArray, tool := "", restarted := false, env := {}) -> int:
	var program := exe
	var given_args := args
	if tool.is_empty() and is_steamcmd_exe(program):
		tool = KnownIssues.STEAMCMD
	var launch := _steamcmd_launch(exe, args)
	exe = launch["exe"]
	args = launch["args"]
	log_cmd(exe, _redact(args))
	_child_tool = tool
	_seen_issues.clear()
	_progress = ConsoleProgress.new(tool, _progress_label) if ConsoleProgress.reads(tool) else null

	# Values the variables had before, put back once the child started.
	var previous := {}
	if not env.is_empty():
		# A credential-store helper started by the secret thread right now
		# would inherit the variables too; let it finish first.
		while _secret_thread != null:
			await get_tree().process_frame
		for key: String in env:
			if OS.has_environment(key):
				previous[key] = OS.get_environment(key)
			OS.set_environment(key, env[key])
	var info := OS.execute_with_pipe(exe, args, false)
	for key: String in env:
		if previous.has(key):
			OS.set_environment(key, previous[key])
		else:
			OS.unset_environment(key)
	if info.is_empty():
		_log_start_failure(program)
		return -1

	var pid: int = info["pid"]
	var stdio: FileAccess = info["stdio"]
	var stderr: FileAccess = info["stderr"]
	_child_stdio = stdio
	_child_pid = pid
	_child_killed = false
	_child_timed_out = false
	_guard_prompt_seen = false
	_guard_code_sent = restarted
	_guard_failure_seen = false
	_password_prompt_seen = false
	_password_sent = false
	_guard_wait_seen = false

	_reader_threads.clear()
	_reader_stop = false
	for pipe: FileAccess in [stdio, stderr]:
		var t := Thread.new()
		t.start(_pipe_reader.bind(pipe, pipe == stderr))
		_reader_threads.append(t)

	while not _child_killed and OS.is_process_running(pid):
		await get_tree().process_frame

	# A killed child is already reaped, so its exit code cannot be read.
	var exit_code := -1 if _child_killed else OS.get_process_exit_code(pid)
	# The readers drain whatever is still buffered in the pipes, then stop.
	_reader_stop = true
	for t in _reader_threads:
		t.wait_to_finish()
	_reader_threads.clear()
	_child_stdio = null
	_child_pid = -1
	stdio.close()
	stderr.close()
	# Deferred log_out calls from the readers land on the next frame; wait so
	# the exit line comes after the output it belongs to.
	await get_tree().process_frame
	if _accepts_guard_code():
		_end_guard_wait()
	_progress = null

	var restart_code := _guard_restart_code
	_guard_restart_code = ""
	if not restart_code.is_empty() and not _cancel_requested:
		_finish_bar(false)
		if _capturing:
			_capture.clear()  # The killed run's output is incomplete.
		return await run_process(program, _with_guard_code(given_args, restart_code), tool, true, env)

	if _cancel_requested:
		_finish_bar(false)
		log_line("Stopped.", COLOR_WARN)
	elif _child_timed_out:
		_finish_bar(true)
		log_line("↳ stopped as planned after the set time", COLOR_MUTED)
	else:
		log_exit(exit_code)
		# Through /usr/bin/env a program that cannot start does not fail the
		# launch: env exits 126 (not executable) or 127 (not found) instead.
		if exe != program and exit_code in [126, 127]:
			_log_start_failure(program)
	return exit_code


## Stop button: kills the running child process or aborts the SteamCMD
## download. The awaiting pipeline notices _cancel_requested and cleans up.
func _cancel_running() -> void:
	if not _is_busy or _cancel_requested:
		return
	_cancel_requested = true
	%BuildPublishButton.disabled = true  # until _set_busy(false) runs
	log_line("Stopping…", COLOR_WARN)
	_kill_child()
	if _steamcmd_downloading:
		_steamcmd_http.cancel_request()
		_steamcmd_downloading = false
	if _butler_downloading:
		_butler_http.cancel_request()
		_butler_downloading = false


## Kills the child run_process is waiting on, together with everything it
## started. Does nothing when no child runs.
func _kill_child() -> void:
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		_kill_process_tree(_child_pid)
		_child_killed = true


## Kills [param pid] and all its descendants. SteamCMD's launchers
## (steamcmd.sh, the Homebrew wrapper) start the real binary as a child
## instead of replacing themselves, so killing only the launcher would leave
## SteamCMD running on its own with nobody reading its output.
static func _kill_process_tree(pid: int) -> void:
	if OS.get_name() == "Windows":
		OS.execute("taskkill", PackedStringArray(["/F", "/T", "/PID", str(pid)]))
		if OS.is_process_running(pid):
			OS.kill(pid)
		return
	# Collected while the parent lives: orphans are re-parented and lost.
	var family := _descendant_pids(pid)
	OS.kill(pid)
	for child in family:
		OS.kill(child)


## Every process below [param pid], children first, via `pgrep -P`. Empty
## when pgrep is not available.
static func _descendant_pids(pid: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var queue: Array[int] = [pid]
	while not queue.is_empty() and out.size() < 64:
		var parent: int = queue.pop_front()
		var output: Array = []
		if OS.execute("pgrep", PackedStringArray(["-P", str(parent)]), output) != 0 or output.is_empty():
			continue
		for line in str(output[0]).split("\n", false):
			var child := line.strip_edges()
			if child.is_valid_int() and not out.has(int(child)):
				out.append(int(child))
				queue.append(int(child))
	return out


## [param program] could not be launched at all: say which one and what
## usually causes it on this OS.
func _log_start_failure(program: String) -> void:
	log_line("Could not start %s." % program, COLOR_ERR)
	if not FileAccess.file_exists(program):
		log_line("The file is gone (moved, renamed or deleted). Pick it again with the folder button.", COLOR_INFO)
		return
	if is_steamcmd_exe(program):
		_log_steamcmd_runtime_hint()
	if not _is_executable_file(program):
		log_line("It is not marked as executable. Run  chmod +x \"%s\"  in a terminal and try again." % program, COLOR_INFO)
	elif OS.get_name() == "macOS":
		log_line("macOS may be blocking it because it was downloaded from the internet. Open it once from Finder (right-click → Open), or run  xattr -dr com.apple.quarantine \"%s\"  in Terminal." % program, COLOR_INFO)


## After an await: true when the user pressed stop meanwhile. Closes the open
## step as cancelled and leaves the busy state; the caller just returns.
func _bail_if_cancelled() -> bool:
	if not _cancel_requested:
		return false
	log_step_done(false, "cancelled")
	_set_busy(false)
	return true


## Sends one line to the running child's stdin. Returns false when no child
## is running (or it has already exited).
func _write_child_stdin(text: String) -> bool:
	if _child_stdio == null or not _child_stdio.is_open():
		return false
	_child_stdio.store_string(text + "\n")
	_child_stdio.flush()
	return true


## Reader thread for one non-blocking pipe. get_line() returns whatever is
## buffered right now: get_error() == OK means the line was newline-terminated,
## ERR_FILE_EOF means "nothing (more) yet" – possibly a partial line, which is
## kept until the rest arrives or the process ends.
## A partial line that stays quiet for PROMPT_IDLE_MS is shown right away as a
## prompt (SteamCMD prints "Steam Guard code:" without a newline and then
## waits for input); the part already shown is not repeated when the rest of
## the line arrives.
const PROMPT_IDLE_MS := 300

func _pipe_reader(pipe: FileAccess, is_stderr: bool) -> void:
	var pending := ""
	var shown := 0  # characters of `pending` already emitted as a prompt
	var idle_ms := 0
	while true:
		var chunk := pipe.get_line()
		if pipe.get_error() == OK:
			_emit_pipe_line.call_deferred((pending + chunk).substr(shown), is_stderr)
			pending = ""
			shown = 0
			idle_ms = 0
			continue
		if not chunk.is_empty():
			pending += chunk
			idle_ms = 0
		if _reader_stop:
			if pending.length() > shown:
				_emit_pipe_line.call_deferred(pending.substr(shown), is_stderr)
			return
		if pending.length() > shown and idle_ms >= PROMPT_IDLE_MS:
			_emit_pipe_prompt.call_deferred(pending.substr(shown), is_stderr)
			shown = pending.length()
		OS.delay_msec(10)
		idle_ms += 10


## Terminal colour/style codes. Godot's export progress prints them even into
## a pipe, where they would show up as "[90m[1m" noise in the console.
static var _ansi_re := RegEx.create_from_string("\\x1b\\[[0-9;?]*[A-Za-z]")


func _emit_pipe_line(line: String, is_stderr: bool) -> void:
	line = _mask_secrets(_ansi_re.sub(line, "", true))
	if line.is_empty():
		return
	child_output.emit(line, is_stderr, _child_tool)
	if not _show_progress(line, is_stderr):
		log_out(line, is_stderr)
	if _capturing and not is_stderr:
		_capture_line(line)
	# Only SteamCMD signs in to Steam; another tool's "password:" or "denied"
	# must not type the Steam password into it or blame Steam Guard.
	if _child_tool == KnownIssues.STEAMCMD:
		_check_guard_prompt(line)
		_check_guard_failure(line)
	_check_known_issue(line)


## Feeds [param line] to the running child's progress reader. Returns true
## when the line was handled there (folded into a bar, dropped, or printed
## as the reader's own text) and must not be printed as is.
func _show_progress(line: String, is_stderr := false) -> bool:
	if _progress == null:
		return false
	var step := _progress.feed(line)
	if step.is_empty():
		return false
	if step.has("text"):
		var text := str(step["text"])
		if not text.is_empty():
			if step.get("err", false):
				log_line(text, COLOR_ERR)
			else:
				log_out(text, is_stderr)
		return true
	if step.has("label"):
		_progress_update(step["label"], step["pct"])
		if step.get("end", false):
			_end_bar()
	return not step.get("print", false)


## Notes which KnownIssues entry [param line] matches, once per process.
func _check_known_issue(line: String) -> void:
	var issue := KnownIssues.match_line(line, _child_tool)
	if not issue.is_empty() and not _seen_issues.has(issue["id"]):
		_seen_issues.append(issue["id"])


## After a failed child process: logs the fix for every known problem its
## output showed, most relevant first, or [param fallback] when nothing was
## recognised ("" for none). The leading fix also goes into the banner when
## [param banner] is set (the failed run belongs to the app on screen).
## Returns true when a known problem was recognised.
func _explain_known_issues(fallback: String, banner := true) -> bool:
	var hints := PackedStringArray()
	var minor := PackedStringArray()
	for id in _seen_issues:
		var issue := KnownIssues.get_issue(id)
		if issue.is_empty():
			continue
		if issue.get("minor", false):
			minor.append(issue["hint"])
		else:
			hints.append(issue["hint"])
	hints.append_array(minor)
	if hints.is_empty():
		if not fallback.is_empty():
			log_line("→ " + fallback, COLOR_INFO)
			# Still say it failed where it shows with the console hidden.
			if banner and _selected_index >= 0:
				var what: String = FALLBACK_BANNERS.get(fallback, "Something failed. See the console for the error.")
				_run_status = { "text": what, "color": COLOR_ERR }
				_refresh_banners()
		return false
	for hint in hints:
		log_line("→ How to fix: " + hint, COLOR_WARN)
	if banner and _selected_index >= 0:
		_run_status = { "text": hints[0], "color": COLOR_ERR }
		_refresh_banners()
	return true


## A partial line that went quiet: shown like any output, then checked for a
## Steam Guard prompt so the user can answer while SteamCMD waits.
func _emit_pipe_prompt(text: String, is_stderr: bool) -> void:
	text = _mask_secrets(_ansi_re.sub(text, "", true))
	if text.strip_edges().is_empty():
		return
	if not _show_progress(text, is_stderr):
		log_out(text, is_stderr)
	if _child_tool == KnownIssues.STEAMCMD:
		_check_guard_prompt(text)


func _check_guard_prompt(text: String) -> void:
	var lower := text.to_lower()
	for prompt: String in GUARD_PROMPTS:
		if lower.contains(prompt):
			_on_guard_prompt()
			return
	if lower.contains(GUARD_WAIT_PROMPT):
		_on_guard_wait()
		return
	if lower.strip_edges().ends_with(PASSWORD_PROMPT):
		_on_password_prompt()


## Called (on the main thread) when the running child asked for the account
## password: SteamCMD has no cached session. This is the only way the
## password reaches SteamCMD, since it is kept off the command line.
## The entered password is written once; without one (or when it was refused)
## the child is stopped, since it would otherwise wait on the prompt forever.
func _on_password_prompt() -> void:
	if _child_stdio == null:
		return
	_password_prompt_seen = true
	_session_lost()
	var password: String = %SteamPassword.text
	if not password.is_empty() and not _password_sent:
		log_line("Steam asked for the password — sending it.", COLOR_INFO)
		_password_sent = _write_child_stdin(password)
		return
	auth_needed = auth_needed or cli_mode
	if _password_sent:
		log_line("Steam did not accept the password. Check it on the Setup page.", COLOR_ERR)
	else:
		log_line("SteamCMD asked for the password of %s and none is entered. Enter it on the Setup page (Remember keeps it)." % %SteamUsername.text.strip_edges(), COLOR_WARN)
	_kill_child()


func _check_guard_failure(text: String) -> void:
	var lower := text.to_lower()
	for failure: String in GUARD_FAILURES:
		if lower.contains(failure):
			_guard_failure_seen = true
			return


func _capture_line(line: String) -> void:
	_capture.append(line)


## Like [method run_process], but also returns everything the process wrote to
## stdout: { "code": int, "output": String }.
func run_process_capture(exe: String, args: PackedStringArray, tool := "", env := {}) -> Dictionary:
	_capture = PackedStringArray()
	_capturing = true
	var code := await run_process(exe, args, tool, false, env)
	# Reader threads have joined, but their deferred appends land next frame.
	await get_tree().process_frame
	_capturing = false
	return {"code": code, "output": "\n".join(_capture)}


## [param args] with +set_steam_guard_code [param code] in front of +login,
## replacing a code that was already passed.
static func _with_guard_code(args: PackedStringArray, code: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < args.size():
		if args[i] == "+set_steam_guard_code":
			i += 2
			continue
		if args[i] == "+login":
			out.append_array(["+set_steam_guard_code", code])
		out.append(args[i])
		i += 1
	return out


## Hides the Steam Guard code in the echoed command line. The password is
## never on it (see [method _steam_login_args]).
func _redact(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < args.size():
		out.append(args[i])
		if args[i] == "+set_steam_guard_code" and i + 1 < args.size():
			out.append("•••••")
			i += 1
		i += 1
	return out


## [param text] with the Steam password masked once it was written to the
## child, in case the child echoes its input, and the itch.io API key masked
## always. Short passwords are left alone: they would mask ordinary words in
## the output.
func _mask_secrets(text: String) -> String:
	var password: String = %SteamPassword.text
	if _password_sent and password.length() >= 6:
		text = text.replace(password, "•••••")
	var key: String = %ItchApiKey.text.strip_edges()
	if key.length() >= 8:
		text = text.replace(key, "•••••")
	return text


# ---------------------------------------------------------------------------
# Layout toggles (console, Steam account panel)
# ---------------------------------------------------------------------------

func _set_console_visible(visible_now: bool) -> void:
	_console_wanted = visible_now
	if not visible_now:
		_console_expanded = false
	_apply_console_visibility()


## The sidebar has a minimum from the scene but no natural maximum: the
## splitter would let it grow until the content pane hits its minimum.
func _clamp_sidebar_split(offset: int) -> void:
	var limit := int($Layout/Sidebar.get_combined_minimum_size().x + SIDEBAR_MAX_EXTRA)
	if offset > limit:
		$Layout.split_offset = limit


## Dragging the console divider past the point where it stops moving closes
## the console (VS Code style) or, on the other side, expands it (see
## _set_console_expanded). The splitter stops the divider at the console's
## minimum and at the main view's real minimum (set in
## _apply_console_visibility), so the overshoot is only visible in the raw
## cursor position: the cursor has to be SPLIT_OVERSHOOT past the stopped
## divider. A short nudge at the edge does nothing.
func _input(event: InputEvent) -> void:
	if not _console_splitter_dragging or not event is InputEventMouseMotion:
		return
	var content: HSplitContainer = %ConsoleDock.get_parent()
	var local_x: float = content.make_canvas_position_local(event.position).x
	var divider_x: float = %MainView.size.x
	var console_at_min: bool = %ConsoleDock.size.x <= %ConsoleDock.get_combined_minimum_size().x + 1.0
	# The main view's scroll container hides its content width, so its real
	# minimum is measured from the content (the divider stops right there).
	var main_min := _main_view_min_width()
	var main_at_min: bool = %MainView.size.x <= main_min + 1.0
	if console_at_min and local_x > divider_x + SPLIT_OVERSHOOT:
		_console_splitter_dragging = false
		_set_console_visible(false)
	elif main_at_min and not _console_expanded and local_x < main_min - SPLIT_OVERSHOOT:
		_console_splitter_dragging = false
		_set_console_expanded(true)


## Godot-style distraction-free toggle: hide the main view so the console
## fills the space next to the sidebar. The divider position is remembered
## while expanded and restored afterwards.
func _set_console_expanded(on: bool) -> void:
	var content: HSplitContainer = %ConsoleDock.get_parent()
	if on and not _console_expanded:
		# Safety net: the main view normally cannot go below its real minimum,
		# but if it was squished anyway, remember the divider at that minimum so
		# the restored layout is not clipped and sits a full SPLIT_OVERSHOOT
		# away from expanding again.
		content.clamp_split_offset()
		var squish := maxf(0.0, _main_view_min_width() - %MainView.size.x)
		_split_offset_before_expand = content.split_offset + int(squish)
	_console_expanded = on
	_apply_console_visibility()
	if not on:
		content.split_offset = _split_offset_before_expand
		content.queue_sort()


# ---------------------------------------------------------------------------
# Setup page (SteamCMD + Steam account checklist)
# ---------------------------------------------------------------------------

## True once "Sign in" succeeded for the username currently in the field.
func _login_ok() -> bool:
	var user: String = %SteamUsername.text.strip_edges()
	return _login_verified and not user.is_empty() and user == _login_verified_user


## Steam is ready to publish to: SteamCMD resolves and the login was verified.
func _steam_setup_complete() -> bool:
	return not _resolve_steamcmd(%SteamCmdBinary.text).is_empty() and _login_ok()


## itch.io is ready to publish to: butler resolves and the key was accepted.
func _itch_setup_complete() -> bool:
	return not _resolve_butler(%ButlerBinary.text).is_empty() and _itch_ok()


## At least one store is set up, which is all adding an app needs.
func _setup_complete() -> bool:
	return _itch_setup_complete() or _steam_setup_complete()


## What is still missing before an app can be added; logged when "New app" is
## pressed too early.
func _setup_hint() -> String:
	if _setup_complete():
		return "All set. Add an app to publish it to %s." % ("Steam and itch.io" if _itch_setup_complete() and _steam_setup_complete() else ("itch.io" if _itch_setup_complete() else "Steam"))
	var butler_ok := not _resolve_butler(%ButlerBinary.text).is_empty()
	var itch := "set up butler and sign in to itch.io" if not butler_ok and not _itch_ok() \
		else ("set up butler" if not butler_ok else "sign in to itch.io")
	var steamcmd_ok := not _resolve_steamcmd(%SteamCmdBinary.text).is_empty()
	var steam := "set up SteamCMD and sign in to Steam" if not steamcmd_ok and not _login_ok() \
		else ("set up SteamCMD" if not steamcmd_ok else "sign in to Steam")
	return "To add an app, %s (to publish on itch.io), or %s (to publish on Steam)." % [itch, steam]


## Re-evaluates both steps, the badges and the sidebar. Cheap enough to call
## after every relevant edit.
func _refresh_setup_state() -> void:
	var steamcmd := _check_steamcmd()
	var steamcmd_ok := not steamcmd.is_empty()
	var login_ok := _login_ok()
	var user: String = %SteamUsername.text.strip_edges()

	# The row text is owned by whoever knows the most (login handler, guard
	# prompt); only the states nobody else describes set it here.
	if _accepts_guard_code():
		_set_status_dot(%AccountDot, COLOR_WARN)
	elif login_ok:
		if not %SteamStatusLabel.text.begins_with("Signed in"):
			%SteamStatusLabel.text = "Signed in"
		_set_status_dot(%AccountDot, COLOR_OK)
	elif _login_verified and not user.is_empty() and user != _login_verified_user:
		%SteamStatusLabel.text = "Not signed in"
		_set_status_dot(%AccountDot, COLOR_WARN)
	else:
		_set_status_dot(%AccountDot, COLOR_MUTED)

	_check_butler()
	if _itch_profile_serial >= 0:
		_set_status_dot(%ItchDot, COLOR_WARN)  # Sign-in answer still pending.
	elif _itch_ok():
		if not %ItchStatusLabel.text.begins_with("Signed in"):
			%ItchStatusLabel.text = "Signed in as %s" % _itch_user
		_set_status_dot(%ItchDot, COLOR_OK)
	else:
		if %ItchStatusLabel.text.begins_with("Signed in"):
			%ItchStatusLabel.text = "Not signed in"
		_set_status_dot(%ItchDot, COLOR_ERR if %ItchStatusLabel.text == "Key not accepted" else COLOR_MUTED)
	%ItchSignOutButton.visible = _itch_ok() or not %ItchApiKey.text.is_empty()

	_update_add_app_button()
	%SteamSignOutButton.visible = login_ok
	_update_steam_header()
	_update_itch_header()
	if _selected_index >= 0:
		_refresh_target_toggles()


## Colours the status dot of a card row; the row text is set by the caller.
func _set_status_dot(dot: Panel, color: String) -> void:
	dot.self_modulate = Color(color)


## The "+" next to "Apps" only greys out while busy; with the setup incomplete
## it stays clickable and _on_new_app_pressed shows what is missing.
func _update_add_app_button() -> void:
	var tooltip := "Add an app (%s)" % _shortcut_label("N") if _setup_complete() else "Set up itch.io or Steam on the Setup page to add an app"
	%AddAppButton.disabled = _is_busy
	%AddAppButton.tooltip_text = tooltip
	%NewAppButton.disabled = _is_busy
	%NewAppButton.tooltip_text = tooltip


## The itch.io chip in the sidebar footer: avatar (or first letter), name and
## status. The footer shows a chip per signed-in store; with none signed in
## both show, so each one leads to its setup.
func _update_itch_header() -> void:
	var itch := _itch_ok()
	var steam := _login_ok()
	%ItchAccountHeader.visible = itch or not steam
	%SteamAccountHeader.visible = steam or not itch
	if not itch:
		%ItchAvatarLetter.text = "i"
		%ItchAvatarLetter.visible = true
		%ItchAvatarImage.visible = false
		%ItchAccountName.text = "itch.io account"
		%ItchAccountSub.text = "Not signed in"
		return
	var has_picture: bool = %ItchAvatarImage.texture != null and %ItchAvatarImage.get_meta("user", "") == _itch_user
	%ItchAvatarLetter.text = _itch_user.substr(0, 1).to_upper()
	%ItchAvatarLetter.visible = not has_picture
	%ItchAvatarImage.visible = has_picture
	%ItchAccountName.text = _itch_display if not _itch_display.is_empty() else _itch_user
	%ItchAccountSub.text = "itch.io · signed in"


## Header row of the account panel: avatar, name and a one-line status. Only a
## verified login is shown; while the username is being typed or after it was
## changed the header stays neutral until "Sign in" succeeds again.
func _update_steam_header() -> void:
	if not _login_ok():
		%AvatarLetter.text = "S"
		%AvatarLetter.visible = true
		%AvatarImage.visible = false
		%SteamAccountName.text = "Steam account"
		%SteamAccountSub.text = "Not signed in"
		return
	var user := _login_verified_user
	var has_picture: bool = %AvatarImage.texture != null and %AvatarImage.get_meta("user", "") == user
	%AvatarLetter.text = user.substr(0, 1).to_upper()
	%AvatarLetter.visible = not has_picture
	%AvatarImage.visible = has_picture
	%SteamAccountName.text = _login_persona if not _login_persona.is_empty() else user
	%SteamAccountSub.text = "Steam · signed in"


func _on_profile_ready(username: String, persona: String, texture: Texture2D) -> void:
	if username != _login_verified_user:
		return  # Late answer for an account that is no longer the verified one.
	%AvatarImage.texture = texture
	%AvatarImage.set_meta("user", username)
	if not persona.is_empty() and persona != _login_persona:
		_login_persona = persona
		_save_settings()
	_update_steam_header()


func _on_profile_failed(username: String, reason: String) -> void:
	if username != _login_verified_user:
		return
	log_line("Steam profile picture not loaded (%s)." % reason, COLOR_INFO)


# ---------------------------------------------------------------------------
# Discord section
# ---------------------------------------------------------------------------

## Loads the server widget; a recent answer is reused unless [param force].
func _refresh_discord(force: bool) -> void:
	var age_ok := _discord_fetched_msec >= 0 \
		and Time.get_ticks_msec() - _discord_fetched_msec < DISCORD_REFRESH_SECONDS * 1000.0
	if age_ok and not force:
		return
	_discord_fetched_msec = Time.get_ticks_msec()
	%DiscordStatus.text = "Loading…"
	%DiscordStatus.visible = true
	%DiscordWidget.fetch(DISCORD_GUILD_ID)


func _discord_invite_url() -> String:
	return _discord_invite if not _discord_invite.is_empty() else DISCORD_INVITE_URL


func _on_discord_join_pressed() -> void:
	var url := _discord_invite_url()
	if not url.is_empty():
		OS.shell_open(url)


func _on_discord_widget_ready(data: Dictionary) -> void:
	var invite: Variant = data.get("instant_invite")
	_discord_invite = str(invite) if invite is String else ""
	%DiscordJoinButton.disabled = _discord_invite_url().is_empty()
	%DiscordServerName.text = str(data.get("name", "Discord server"))
	var members: Array = data.get("members", [])
	var online := int(data.get("presence_count", members.size()))
	%DiscordOnlineLabel.text = "%d online" % online
	%DiscordOnlineDot.self_modulate = Color(COLOR_OK) if online > 0 else Color(COLOR_MUTED)

	%DiscordWidget.clear_avatar_queue()
	for child in %DiscordMembers.get_children():
		child.queue_free()
	for m in members:
		if m is Dictionary:
			%DiscordMembers.add_child(_make_discord_member_row(m))
	if members.is_empty():
		%DiscordStatus.text = "Nobody is online right now."
		%DiscordStatus.visible = true
	else:
		%DiscordStatus.visible = false
	for m in members:
		if m is Dictionary:
			%DiscordWidget.fetch_avatar(str(m.get("avatar_url", "")))


func _on_discord_widget_failed(reason: String) -> void:
	%DiscordJoinButton.disabled = _discord_invite_url().is_empty()
	%DiscordStatus.text = "Could not load the Discord server (%s)." % reason
	%DiscordStatus.visible = true
	log_line("Discord widget not loaded (%s)." % reason, COLOR_WARN)


## A member row: avatar · status dot · name · what they are playing. The avatar
## starts as the first letter and is swapped for the picture once it arrives.
func _make_discord_member_row(m: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size.y = 30

	var avatar := PanelContainer.new()
	avatar.theme_type_variation = &"Avatar"
	avatar.custom_minimum_size = Vector2(26, 26)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(avatar)

	var username := str(m.get("username", "?"))
	var letter := Label.new()
	letter.theme_type_variation = &"OnAccent"
	letter.text = username.substr(0, 1).to_upper()
	letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar.add_child(letter)

	var picture := TextureRect.new()
	picture.visible = false
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	picture.custom_minimum_size = Vector2(26, 26)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://features/main_window/rounded_rect.gdshader")
	mat.set_shader_parameter("radius", 13.0)
	mat.set_shader_parameter("size", Vector2(26, 26))
	picture.material = mat
	avatar.add_child(picture)
	row.set_meta("avatar_url", str(m.get("avatar_url", "")))
	row.set_meta("letter", letter)
	row.set_meta("picture", picture)

	var dot := Panel.new()
	dot.theme_type_variation = &"Dot"
	dot.custom_minimum_size = Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.self_modulate = _discord_status_color(str(m.get("status", "")))
	row.add_child(dot)

	var name_label := Label.new()
	name_label.text = username
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_label)

	var game: Variant = m.get("game")
	if game is Dictionary and not str(game.get("name", "")).is_empty():
		var playing := Label.new()
		playing.theme_type_variation = &"Caption"
		playing.text = "Playing %s" % str(game["name"])
		playing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		playing.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		playing.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(playing)
	return row


func _discord_status_color(status: String) -> Color:
	match status:
		"online":
			return Color(COLOR_OK)
		"idle":
			return Color(COLOR_WARN)
		"dnd":
			return Color(COLOR_ERR)
	return Color(COLOR_MUTED)


func _on_discord_avatar_ready(url: String, texture: Texture2D) -> void:
	for row in %DiscordMembers.get_children():
		if row.get_meta("avatar_url", "") != url:
			continue
		var picture: TextureRect = row.get_meta("picture")
		var letter: Label = row.get_meta("letter")
		picture.texture = texture
		picture.visible = true
		letter.visible = false


# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------

## Append a plain message to the console. [param color] doubles as the level:
## an error logged inside a step block marks that step as failed.
func log_line(text: String, color: String = COLOR_INFO) -> void:
	if color == COLOR_ERR and _step_open:
		_step_failed = true
	console_emitted.emit("line", text, color)
	_emit("[color=%s]%s[/color]" % [color, _bb_escape(text)])


## A section heading, e.g. the start of a Build & Publish run.
func log_banner(title: String) -> void:
	_close_step_if_open()
	_spacer()
	console_emitted.emit("banner", title, COLOR_TEXT)
	_emit("[font_size=13][color=%s]%s[/color][/font_size]" % [COLOR_TEXT, _bb_escape(title)])


## Opens a step block: a titled header followed by gutter-marked lines until
## [method log_step_done] closes it with a ✓/✗ status line.
func log_step(title: String) -> void:
	_close_step_if_open()
	_end_bar()
	console_emitted.emit("step", title, COLOR_TEXT)
	_emit("[color=%s]▸[/color] [color=%s]%s[/color]" % [COLOR_TEXT_2, COLOR_TEXT, _bb_escape(title)])
	_step_open = true
	_step_failed = false
	_step_started_ms = Time.get_ticks_msec()


## Closes the current step block with its status and elapsed time.
func log_step_done(ok: bool, note: String = "") -> void:
	if not _step_open:
		return
	_end_bar()  # The status line goes under the bar, not above it.
	var elapsed := "%.1fs" % ((Time.get_ticks_msec() - _step_started_ms) / 1000.0)
	var detail := elapsed if note.is_empty() else "%s · %s" % [elapsed, _bb_escape(note)]
	_step_open = false
	console_emitted.emit("step_done", "%s · %s" % ["✓ Done" if ok else "✗ Failed", detail], COLOR_OK if ok else COLOR_ERR)
	if ok:
		_emit("[color=%s]✓ Done[/color] [color=%s]· %s[/color]" % [COLOR_OK, COLOR_MUTED, detail])
	else:
		_emit("[color=%s]✗ Failed[/color] [color=%s]· %s[/color]" % [COLOR_ERR, COLOR_MUTED, detail])
	_spacer()


## Echo of a command line about to run, drawn as a highlighted pill.
func log_cmd(exe: String, args: PackedStringArray) -> void:
	console_emitted.emit("cmd", ("$ %s %s" % [exe, " ".join(args)]).strip_edges(), COLOR_CMD)
	var cmd := _bb_escape(("%s %s" % [exe, " ".join(args)]).strip_edges())
	_emit("[bgcolor=%s][color=%s] $ %s [/color][/bgcolor]" % [COLOR_CMD_BG, COLOR_CMD, cmd])


## One line of a child process's output. stderr is not treated as a warning
## (most tools print progress there); it only gets a tinted gutter bar.
func log_out(line: String, is_stderr: bool) -> void:
	console_emitted.emit("out", line, COLOR_GUTTER_ERR if is_stderr else COLOR_OUT)
	_emit("[color=%s]%s[/color]" % [COLOR_OUT, _bb_escape(line)], COLOR_GUTTER_ERR if is_stderr else COLOR_GUTTER)


## Exit status of a child process.
func log_exit(code: int) -> void:
	_finish_bar(code == 0)
	if code != 0 and _step_open:
		_step_failed = true
	console_emitted.emit("exit", "↳ exit %d" % code, COLOR_MUTED if code == 0 else COLOR_ERR)
	_emit("[color=%s]↳ exit %d[/color]" % [COLOR_MUTED if code == 0 else COLOR_ERR, code])


## Safety net: close a dangling step (e.g. an early return) with its current status.
func _close_step_if_open() -> void:
	if _step_open:
		log_step_done(not _step_failed)


func _bb_escape(text: String) -> String:
	return text.replace("[", "[lb]")


## The single writer: timestamp, optional step gutter, body, newline. A live
## progress bar stays the last line: it is taken out, the new line goes in,
## and the bar goes back under it.
func _emit(body: String, gutter_color: String = COLOR_GUTTER) -> void:
	var gutter := "[color=%s]│[/color] " % gutter_color if _step_open else "  "
	var line := "[color=%s]%s[/color]  %s%s\n" % [COLOR_STAMP, _console_stamp(), gutter, body]
	var bar_last := _bar_is_last()
	if bar_last:
		%Console.remove_paragraph(_bar_para)
	%Console.append_text(line)
	if bar_last:
		%Console.append_text(_bar_line)
		_bar_para = %Console.get_paragraph_count() - 2
	_scroll_console_to_bottom()


## Console timestamp (local time).
func _console_stamp() -> String:
	return Time.get_time_string_from_system()


func _spacer() -> void:
	_end_bar()
	%Console.append_text("\n")


func _clear_console() -> void:
	%Console.clear()
	_bar_para = -1
	_step_open = false
	_step_failed = false
	_set_console_autoscroll(true)


## Moves the live progress bar [param label] to [param pct] (0–100), or
## starts a new bar line for it. The line is only rewritten when the whole
## percentage changes. A bar that reaches 100 % is done and stays as is.
## Labels are padded so stacked bars line up; the narrow console (beside the
## page) drops the label so the bar fits on one line.
func _progress_update(label: String, pct: float, failed := false) -> void:
	var whole := clampi(int(pct), 0, 100)
	var same := _bar_para >= 0 and label == _bar_label
	if same and whole == _bar_pct and not failed:
		return
	if same and _bar_is_last():
		%Console.remove_paragraph(_bar_para)
	else:
		_end_bar()
	_bar_label = label
	_bar_pct = whole
	progress_changed.emit(label, whole)
	var filled := int(BAR_CELLS * whole / 100.0)
	var done := whole >= 100
	var fill_color := COLOR_ERR if failed else (COLOR_OK if done else COLOR_CMD)
	var stamp := _console_stamp()
	var gutter := "│ " if _step_open else "  "
	var shown := _bar_label_that_fits(label, "%s  %s%s  %3d%%" % [stamp, gutter, "█".repeat(BAR_CELLS), whole])
	var body := "[color=%s]%s[/color][color=%s]%s[/color][color=%s]%s[/color]  [color=%s]%3d%%[/color]" % [
		COLOR_TEXT_2, _bb_escape(shown),
		fill_color, "█".repeat(filled),
		COLOR_GUTTER, "█".repeat(BAR_CELLS - filled),
		COLOR_OK if done else COLOR_TEXT, whole,
	]
	var gutter_bb := "[color=%s]│[/color] " % COLOR_GUTTER if _step_open else "  "
	_bar_line = "[color=%s]%s[/color]  %s%s\n" % [COLOR_STAMP, stamp, gutter_bb, body]
	%Console.append_text(_bar_line)
	_bar_para = %Console.get_paragraph_count() - 2
	_scroll_console_to_bottom()
	if done or failed:
		_end_bar()


## The label part of a bar line whose other text is [param rest]: padded so
## stacked bars line up when the console is wide enough, unpadded when it is
## tighter, and dropped when even that would wrap the bar onto two lines.
func _bar_label_that_fits(label: String, rest: String) -> String:
	var console: RichTextLabel = %Console
	var font := console.get_theme_font("normal_font")
	var font_size := console.get_theme_font_size("normal_font_size")
	var scroll := console.get_v_scroll_bar()
	var room := console.size.x - 8.0
	if scroll.visible:
		room -= scroll.get_combined_minimum_size().x
	for shown: String in [label.rpad(BAR_LABEL_WIDTH) + "  ", label + "  "]:
		if font.get_string_size(shown + rest, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= room:
			return shown
	return ""


## Stops tracking the live bar; its line stays in the console as it is.
func _end_bar() -> void:
	_bar_para = -1
	_bar_pct = -1


## Ends the live bar at the end of a child process: a clean exit fills it
## (the tool may stop printing at 99 %), a failed one colours it red.
func _finish_bar(ok: bool) -> void:
	if _bar_para < 0:
		return
	if _bar_is_last():
		_progress_update(_bar_label, 100.0 if ok else _bar_pct, not ok)
	_end_bar()


func _bar_is_last() -> bool:
	return _bar_para >= 0 and _bar_para == %Console.get_paragraph_count() - 2


## Console header button: puts [method _diagnostics_report] on the clipboard
## so a stuck user can paste one message (to an AI or on Discord) instead of
## answering questions.
func _copy_console() -> void:
	DisplayServer.clipboard_set(_diagnostics_report())
	var button: Button = %CopyConsoleButton
	button.icon = ICON_CHECK
	button.tooltip_text = "Copied"
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(button):
		button.icon = ICON_COPY
		button.tooltip_text = COPY_TOOLTIP


## Plain-text support report: a short intro for an AI, app and OS versions,
## the SteamCMD and account setup, the selected app with its presets and
## depots, free disk space and the console. Run through [method _redact_report],
## so it is safe to paste in public.
func _diagnostics_report() -> String:
	var out := PackedStringArray()
	var app_version := str(ProjectSettings.get_setting("application/config/version", ""))
	out.append("I use %s, a desktop app that exports Godot projects and uploads them to Steam with SteamCMD and to itch.io with butler. Below are my setup and the console output. Help me find and fix the problem." % _app_name())
	out.append("")
	out.append("%s diagnostics · %s" % [_app_name(), Time.get_datetime_string_from_system()])
	out.append("App version: %s · engine %s" % [app_version if not app_version.is_empty() else "dev", Engine.get_version_info()["string"]])
	out.append("OS: %s %s (%s) · locale %s · UI scale %.2f" % [OS.get_name(), OS.get_version(), Engine.get_architecture_name(), OS.get_locale(), get_window().content_scale_factor])
	var free := _free_disk_bytes()
	out.append("Data folder: %s · free space %s" % [OS.get_user_data_dir(), String.humanize_size(free) if free >= 0 else "unknown"])
	out.append("")

	var typed: String = %SteamCmdBinary.text.strip_edges()
	var resolved := _resolve_steamcmd(typed)
	out.append("SteamCMD: field '%s' → %s" % [typed, resolved if not resolved.is_empty() else "NOT FOUND"])
	if not steamcmd_home().is_empty():
		out.append("SteamCMD HOME: %s (exists: %s)" % [steamcmd_home(), _yes_no(DirAccess.dir_exists_absolute(steamcmd_home()))])
	var guard := "none"
	if not %SteamSharedSecret.text.strip_edges().is_empty():
		guard = "shared secret (%s)" % ("valid" if not steam_totp(%SteamSharedSecret.text).is_empty() else "INVALID")
	elif not %SteamGuardCode.text.strip_edges().is_empty():
		guard = "code typed"
	out.append("Account: username set %s · signed in %s · password entered %s (remembered %s) · Steam Guard %s" % [
		_yes_no(not %SteamUsername.text.strip_edges().is_empty()), _yes_no(_login_ok()),
		_yes_no(not %SteamPassword.text.is_empty()), _yes_no(%RememberPassword.button_pressed), guard])
	var butler_typed: String = %ButlerBinary.text.strip_edges()
	var butler := _resolve_butler(butler_typed)
	out.append("butler: field '%s' → %s%s" % [butler_typed, butler if not butler.is_empty() else "NOT FOUND",
		" (version %s)" % _butler_version if not butler.is_empty() and butler == _butler_version_path and not _butler_version.is_empty() else ""])
	out.append("itch.io: API key entered %s (remembered %s) · signed in %s" % [
		_yes_no(not %ItchApiKey.text.strip_edges().is_empty()), _yes_no(%RememberItchKey.button_pressed), _yes_no(_itch_ok())])
	out.append("Apps in the list: %d · busy: %s" % [_projects.size(), _yes_no(_is_busy)])
	out.append("")

	if _selected_index >= 0 and _selected_index < _projects.size():
		var p := _projects[_selected_index]
		var folder := _is_folder_app(p)
		var path := str(p["path"])
		out.append("Selected app: '%s' (%s)" % [p["name"], "content folder" if folder else "Godot project"])
		out.append("  Folder: %s (exists: %s%s)" % [path, _yes_no(DirAccess.dir_exists_absolute(path)),
			"" if folder else ", project.godot: %s, imported: %s" % [_yes_no(_project_file_exists(p)), _yes_no(DirAccess.dir_exists_absolute(path.path_join(".godot")))]])
		out.append("  Publishes to: %s" % _targets_label(p))
		out.append("  Steam App ID: '%s' · branch: '%s'" % [p.get("app_id", ""), p.get("branch", "")])
		out.append("  itch.io game: '%s'" % p.get("itch_target", ""))
		if not folder:
			var binary := str(p.get("godot_binary", ""))
			var cached: Dictionary = _version_cache.get(binary, {})
			out.append("  Godot: project needs %s · binary %s (exists: %s, executable: %s, version: %s)" % [
				_read_required_godot_version(path), binary if not binary.is_empty() else "(none)",
				_yes_no(FileAccess.file_exists(binary)), _yes_no(FileAccess.file_exists(binary) and _is_executable_file(binary)),
				cached.get("version", "not probed")])
			out.append("  C# project: %s" % _yes_no(_is_csharp_project(path)))
			var presets := PackedStringArray()
			for i in _preset_names.size():
				presets.append("'%s' [%s]" % [_preset_names[i], _preset_platforms[i]])
			out.append("  Export presets: %s" % (", ".join(presets) if not presets.is_empty() else "NONE"))
		var depots: Array = p["depots"]
		if depots.is_empty():
			out.append("  Build rows: none")
		for i in depots.size():
			var d: Dictionary = depots[i]
			if folder:
				var dir := str(d.get("content_dir", "")).strip_edges()
				out.append("  Row %d: depot id '%s' · channel '%s' · folder %s (exists: %s)" % [i + 1, d.get("depot_id", ""), d.get("itch_channel", ""), dir, _yes_no(DirAccess.dir_exists_absolute(dir))])
			else:
				var preset := str(d.get("preset", ""))
				var kind := _platform_kind(_preset_names.find(preset))
				out.append("  Row %d: depot id '%s' · channel '%s' · preset '%s' (%s) · executable '%s'" % [i + 1, d.get("depot_id", ""), d.get("itch_channel", ""), preset,
					"%s, %s" % ["found", kind if not kind.is_empty() else "unknown platform"] if _preset_names.has(preset) else "MISSING", d.get("output", "")])
	else:
		out.append("Selected app: none (Setup page)")
	out.append("")

	var lines: PackedStringArray = %Console.get_parsed_text().split("\n")
	var first := maxi(0, lines.size() - REPORT_CONSOLE_LINES)
	out.append("--- Console (last %d of %d lines) ---" % [lines.size() - first, lines.size()] if first > 0 else "--- Console ---")
	out.append_array(lines.slice(first))
	return _redact_report("\n".join(out))


## [param text] with the password, shared secret, Guard code, itch.io API key,
## account and persona names and the home folder replaced. Values shorter
## than 3 characters are left alone so they do not blank out random words.
func _redact_report(text: String) -> String:
	for pair: Array in [
		[%SteamPassword.text, "<password>"],
		[%SteamSharedSecret.text.strip_edges(), "<shared secret>"],
		[%SteamGuardCode.text.strip_edges(), "<code>"],
		[%ItchApiKey.text.strip_edges(), "<itch.io api key>"],
	]:
		if str(pair[0]).length() >= 3:
			text = text.replacen(pair[0], pair[1])
	var home := _home_dir()
	if home.length() > 1:
		text = text.replace(home, "~").replace(home.replace("\\", "/"), "~")
	for pair: Array in [
		[%SteamUsername.text.strip_edges(), "<account>"],
		[_login_verified_user, "<account>"],
		[_login_persona, "<persona>"],
		[_itch_display, "<itch.io name>"],
		[_itch_user, "<itch.io account>"],
	]:
		if str(pair[0]).length() >= 3:
			text = text.replacen(pair[0], pair[1])
	return text


static func _yes_no(value: bool) -> String:
	return "yes" if value else "no"


func _set_console_autoscroll(on: bool) -> void:
	_console_autoscroll = on
	%AutoScrollButton.set_pressed_no_signal(on)
	%AutoScrollButton.tooltip_text = "Auto-scroll on" if on else "Auto-scroll off"
	if on:
		_scroll_console_to_bottom()


## Scrolling back to the bottom resumes following. Only the user scrolling up
## (wheel, keys, dragging the bar) pauses it; the bar also moves when lines
## are replaced or the console resizes, and that must not switch it off.
func _on_console_scrolled(value: float) -> void:
	if _console_scroll_lock:
		return
	var bar: VScrollBar = %Console.get_v_scroll_bar()
	var at_bottom := value + bar.page >= bar.max_value - 2.0
	if at_bottom:
		if not _console_autoscroll:
			_set_console_autoscroll(true)
	elif _console_dragging:
		_set_console_autoscroll(false)
	elif _console_autoscroll:
		_scroll_console_to_bottom()


## Wheel, trackpad or keys scrolling the console up pause following.
func _on_console_input(event: InputEvent) -> void:
	if not _console_autoscroll:
		return
	var bar: VScrollBar = %Console.get_v_scroll_bar()
	if bar.max_value <= bar.page:
		return
	var up := false
	if event is InputEventMouseButton:
		up = event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP
	elif event is InputEventPanGesture:
		up = event.delta.y < 0.0
	elif event is InputEventKey:
		up = event.pressed and event.keycode in [KEY_UP, KEY_PAGEUP, KEY_HOME]
	if up:
		_set_console_autoscroll(false)


func _on_console_bar_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_console_dragging = event.pressed
	_on_console_input(event)


func _scroll_console_to_bottom() -> void:
	if not _console_autoscroll:
		return
	await get_tree().process_frame
	if not _console_autoscroll:
		return
	var bar: VScrollBar = %Console.get_v_scroll_bar()
	_console_scroll_lock = true
	bar.value = bar.max_value
	_console_scroll_lock = false


func _set_busy(busy: bool) -> void:
	_is_busy = busy
	if not busy:
		_close_step_if_open()
		_fetching_depots = false
		if not _publishing.is_empty() and not get_window().has_focus():
			get_window().request_attention()  # A long publish ended in the background.
		_publishing = {}
	_cancel_requested = false
	%BuildPublishButton.disabled = false
	%BuildPublishButton.icon = ICON_STOP if busy else ICON_PLAY
	%BuildPublishButton.tooltip_text = STOP_TOOLTIP if busy else "%s (%s)" % [BUILD_TOOLTIP, _shortcut_label("Enter")]
	%BuildPublishButton.accessibility_name = %BuildPublishButton.tooltip_text
	%BuildDescription.editable = not busy
	%SteamLoginButton.disabled = busy and not _accepts_guard_code()
	%SteamSignOutButton.disabled = busy
	_update_add_app_button()
	%RemoveProjectButton.disabled = busy and not _fetching_depots
	%ProjectHeaderButton.disabled = busy
	%AddDepotButton.disabled = busy
	%FetchDepotsButton.disabled = busy
	%DetectSteamCmdButton.disabled = busy
	%BrowseSteamCmdButton.disabled = busy
	%DownloadSteamCmdButton.disabled = busy
	%DetectButlerButton.disabled = busy
	%BrowseButlerButton.disabled = busy
	%DownloadButlerButton.disabled = busy
	%ItchSignOutButton.disabled = busy
	%ItchSignInButton.disabled = busy or _itch_profile_serial >= 0
	_apply_build_lock()
	if not busy and _auto_fetch_pending:
		_auto_fetch_pending = false
		# Deferred so the pipeline that just finished unwinds first.
		_maybe_auto_fetch_depots.call_deferred(_current_app_id())


## Makes the fields of the app being published read-only while it is on
## screen: the run reads the App ID, branch and depot rows after the exports,
## so an edit mid-run would change where the build goes or shift the rows the
## export loop walks. Other apps stay editable during the run.
func _apply_build_lock() -> void:
	var locked := not _publishing.is_empty() and _is_selected(_publishing)
	for field: LineEdit in [%GodotBinary, %AppId, %Branch, %ItchTarget]:
		field.editable = not locked
	%BrowseGodotButton.disabled = locked
	%CheckGodotButton.disabled = locked
	%PickItchGameButton.disabled = locked
	if _selected_index >= 0:
		_refresh_target_toggles()
	# Rows of another app keep their own busy state (set when built).
	if locked or not _is_busy:
		for row in %DepotRows.get_children():
			_lock_controls(row, locked)


## Fields marked "always_locked" (a web row's depot ID and file name) stay
## read-only when the rest unlocks.
static func _lock_controls(node: Node, locked: bool) -> void:
	if node is LineEdit:
		node.editable = not locked and not node.get_meta("always_locked", false)
	elif node is BaseButton:
		node.disabled = locked
	for child in node.get_children():
		_lock_controls(child, locked)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _read_project_name(dir: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(dir.path_join("project.godot")) == OK:
		var project_name := _as_str(cfg.get_value("application", "config/name", "")).strip_edges()
		if not project_name.is_empty():
			return project_name
	return dir.get_file()


func _save_projects() -> void:
	if cli_mode:
		return  # Overrides from the command line apply to one run only.
	var cfg := ConfigFile.new()
	for i in _projects.size():
		for key in _projects[i]:
			cfg.set_value("project_%d" % i, key, _projects[i][key])
	_report_save(cfg.save(PROJECTS_FILE), PROJECTS_FILE)


## Loads the app list. A file that cannot be parsed is copied aside before
## anything else happens, so the next save cannot wipe the user's apps; a
## single broken entry is skipped. [param path] is only changed by tests.
func _load_projects(path := PROJECTS_FILE) -> void:
	_projects.clear()
	if not FileAccess.file_exists(path):
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		var backup := _backup_broken_file(path)
		log_line("Your app list could not be read (%s), so it starts empty. %s To get the apps back, fix that file in a text editor and rename it back to %s while this app is closed, or add the apps again." % [
			error_string(err),
			("The old file was kept as %s." % backup) if not backup.is_empty() else "",
			path.get_file()], COLOR_ERR)
		return
	var migrated := false
	for section in cfg.get_sections():
		var raw := {}
		for key in cfg.get_section_keys(section):
			raw[key] = cfg.get_value(section, key)
		var p := _sanitize_project(raw)
		if p.is_empty():
			log_line("Skipped a broken entry [%s] in %s: it has no folder. Add that app again." % [section, ProjectSettings.globalize_path(path)], COLOR_WARN)
			continue
		migrated = migrated or not raw.has("uid")
		_projects.append(p)
	if migrated and path == PROJECTS_FILE:
		_save_projects()  # Keeps the build folder names from this start on.


## [param raw] (one projects.cfg section) with every field the app reads
## coerced to its expected type, so a hand-edited or damaged file cannot
## crash the UI. {} when the entry has no folder at all.
func _sanitize_project(raw: Dictionary) -> Dictionary:
	var path := _as_str(raw.get("path")).strip_edges()
	if path.is_empty():
		return {}
	var p := raw.duplicate(true)
	for key in ["name", "godot_binary", "app_id", "branch", "description", "itch_target"]:
		p[key] = _as_str(raw.get(key))
	p["path"] = path
	if str(p["name"]).strip_edges().is_empty():
		p["name"] = path.get_file()
	p["kind"] = "folder" if _as_str(raw.get("kind")) == "folder" else "godot"
	p["folder_notice_dismissed"] = _as_bool(raw.get("folder_notice_dismissed"))
	# Apps from before itch.io support publish to Steam, as they always did.
	p["steam_enabled"] = _as_bool(raw.get("steam_enabled")) if raw.has("steam_enabled") else true
	p["itch_enabled"] = _as_bool(raw.get("itch_enabled"))
	var uid := _as_str(raw.get("uid")).strip_edges()
	p["uid"] = uid if uid.is_valid_hex_number() else Crypto.new().generate_random_bytes(6).hex_encode()
	var depots: Array = []
	var raw_depots: Variant = raw.get("depots")
	if raw_depots is Array:
		for d: Variant in raw_depots:
			if not d is Dictionary:
				continue
			if p["kind"] == "folder":
				depots.append({
					"content_dir": _as_str(d.get("content_dir")),
					"depot_id": _as_str(d.get("depot_id")),
					"itch_channel": _as_str(d.get("itch_channel")),
				})
			else:
				depots.append({
					"preset": _as_str(d.get("preset")),
					"depot_id": _as_str(d.get("depot_id")),
					"output": _strip_known_extension(_as_str(d.get("output"))),
					"itch_channel": _as_str(d.get("itch_channel")),
				})
	p["depots"] = depots
	return p


## [param value] as text; null becomes "" instead of "<null>".
static func _as_str(value: Variant) -> String:
	return "" if value == null else str(value)


## [param value] as a bool, also for "true"/"1" written by hand.
static func _as_bool(value: Variant) -> bool:
	if value is bool:
		return value
	return str(value).strip_edges().to_lower() in ["true", "1", "yes"]


## Copies an unreadable settings file to "<name>.broken-<unix time>" next to
## it. Returns the absolute backup path, or "" when the copy failed.
static func _backup_broken_file(path: String) -> String:
	var source := ProjectSettings.globalize_path(path)
	var backup := "%s.broken-%d" % [source, int(Time.get_unix_time_from_system())]
	return backup if DirAccess.copy_absolute(source, backup) == OK else ""


## Logs a failed save once per file until a save of it works again, so a
## full disk or read-only data folder does not flood the console on every
## keystroke. Warn, not error: it must not mark an unrelated step as failed.
func _report_save(err: Error, path: String) -> void:
	if err == OK:
		if _failed_saves.erase(path):
			_refresh_banners()
		return
	if _failed_saves.has(path):
		return
	_failed_saves[path] = true
	_refresh_banners()
	log_line("Could not save %s (%s). Changes stay only until you quit. Free up disk space and check that %s is writable." % [ProjectSettings.globalize_path(path), error_string(err), OS.get_user_data_dir()], COLOR_WARN)


## Only the "Remember" toggles are written here, never the password, shared
## secret or itch.io API key themselves: those go to the OS credential store
## (see [method _persist_secrets]) and otherwise live in memory until the app
## quits.
func _save_settings() -> void:
	if cli_mode:
		return  # The command line never changes the Setup page.
	var cfg := ConfigFile.new()
	cfg.set_value("tools", "steamcmd_binary", %SteamCmdBinary.text)
	cfg.set_value("tools", "butler_binary", %ButlerBinary.text)
	cfg.set_value("itch", "verified", _itch_verified)
	cfg.set_value("itch", "username", _itch_user)
	cfg.set_value("itch", "display_name", _itch_display)
	cfg.set_value("itch", "user_id", _itch_user_id)
	cfg.set_value("itch", "remember_api_key", %RememberItchKey.button_pressed)
	cfg.set_value("steam", "username", %SteamUsername.text)
	cfg.set_value("steam", "login_verified", _login_verified)
	cfg.set_value("steam", "login_verified_user", _login_verified_user)
	cfg.set_value("steam", "persona", _login_persona)
	cfg.set_value("steam", "remember_shared_secret", %RememberSharedSecret.button_pressed)
	cfg.set_value("steam", "remember_password", %RememberPassword.button_pressed)
	_report_save(cfg.save(SETTINGS_FILE), SETTINGS_FILE)


## Every value is coerced, so a hand-edited file cannot crash the app. An
## unreadable file is copied aside first and the fields start empty.
func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_FILE):
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(SETTINGS_FILE)
	if err != OK:
		var backup := _backup_broken_file(SETTINGS_FILE)
		log_line("Your settings could not be read (%s), so the tools and accounts on the Setup page need to be set up again. %s" % [
			error_string(err),
			("The old file was kept as %s." % backup) if not backup.is_empty() else ""], COLOR_WARN)
		return
	%SteamCmdBinary.text = _as_str(cfg.get_value("tools", "steamcmd_binary", ""))
	%ButlerBinary.text = _as_str(cfg.get_value("tools", "butler_binary", ""))
	_itch_verified = _as_bool(cfg.get_value("itch", "verified", false))
	_itch_user = _as_str(cfg.get_value("itch", "username", ""))
	_itch_display = _as_str(cfg.get_value("itch", "display_name", ""))
	_itch_user_id = _as_str(cfg.get_value("itch", "user_id", ""))
	%RememberItchKey.set_pressed_no_signal(_as_bool(cfg.get_value("itch", "remember_api_key", true)))
	%SteamUsername.text = _as_str(cfg.get_value("steam", "username", ""))
	_login_verified = _as_bool(cfg.get_value("steam", "login_verified", false))
	_login_verified_user = _as_str(cfg.get_value("steam", "login_verified_user", ""))
	_login_persona = _as_str(cfg.get_value("steam", "persona", ""))
	# Older versions kept both secrets here as plain text; _load_secrets moves
	# them to the credential store.
	var plain_secret := _as_str(cfg.get_value("steam", "shared_secret", ""))
	var plain_password := _as_str(cfg.get_value("steam", "password", ""))
	# No signal: toggled also syncs the credential store, which would erase the
	# stored secrets from the still-empty fields before they are read.
	# Older settings files have no remember flag: keep the secret if one was stored.
	%RememberSharedSecret.set_pressed_no_signal(_as_bool(cfg.get_value("steam", "remember_shared_secret", not plain_secret.is_empty())))
	%RememberPassword.set_pressed_no_signal(_as_bool(cfg.get_value("steam", "remember_password", false)))
	_load_secrets({SECRET_PASSWORD: plain_password, SECRET_SHARED_SECRET: plain_secret})
	if _login_ok():
		%SteamStatusLabel.text = "Signed in"
		# Cached avatar (or a fresh one when nothing is cached yet).
		if not cli_mode:
			%SteamProfile.fetch(_login_verified_user, _resolve_steamcmd(%SteamCmdBinary.text))
	if _itch_verified and %ItchApiKey.text.strip_edges().is_empty():
		_itch_verified = false  # The key was not remembered; sign in again.
	if _itch_ok() and not cli_mode:
		%ItchStatusLabel.text = "Signed in as %s" % _itch_user
		# Trust the remembered sign-in now, check the key and avatar quietly.
		_itch_profile_serial = %ItchApi.fetch_profile(%ItchApiKey.text)


# ---------------------------------------------------------------------------
# Remembered secrets (OS credential store, see SecretStore)
# ---------------------------------------------------------------------------

func _secret_field(key: String) -> LineEdit:
	return _secrets[key]["field"]


func _secret_remember_button(key: String) -> Button:
	return _secrets[key]["remember"]


func _secret_label(key: String) -> String:
	return _secrets[key]["label"]


## Without a credential store (Linux without secret-tool or a running keyring)
## nothing can be remembered, so the Remember toggles are disabled with the
## reason in their tooltip.
func _apply_secret_store_state() -> void:
	if not SecretStore.backend().is_empty():
		return
	for key: String in _secrets:
		var button := _secret_remember_button(key)
		button.set_pressed_no_signal(false)
		button.disabled = true
		button.get_parent().tooltip_text = "No keyring found, so the %s cannot be remembered. Install secret-tool (package libsecret-tools or libsecret) and a keyring such as GNOME Keyring or KWallet, then restart the app." % _secret_label(key)


## Fills the remembered secret fields (see _secrets) from the OS credential store.
## [param plain] (SecretStore key -> value) holds the plain-text copies older
## versions kept in settings.cfg: they are moved to the store and removed
## from the file.
func _load_secrets(plain: Dictionary) -> void:
	var store := SecretStore.backend()
	var moved := PackedStringArray()
	var dropped := PackedStringArray()
	for key: String in _secrets:
		var remember := _secret_remember_button(key)
		if store.is_empty():
			remember.set_pressed_no_signal(false)
		var old: String = plain.get(key, "")
		var value := old
		var stored := ""
		if remember.button_pressed:
			if old.is_empty():
				value = SecretStore.read(key)
				stored = value
			elif SecretStore.write(key, old):
				moved.append(_secret_label(key))
				stored = old
		if not old.is_empty() and stored.is_empty():
			dropped.append(_secret_label(key))
		_secret_field(key).text = value
		_stored_secrets[key] = stored
	if not moved.is_empty():
		log_line("Moved the remembered %s from settings.cfg (plain text) to %s." % [" and ".join(moved), store], COLOR_INFO)
	if not dropped.is_empty():
		log_line("Removed the plain-text %s from settings.cfg, but %s. %s filled in until you quit." % [
			" and ".join(dropped),
			("could not store it in %s" % store) if not store.is_empty() else "this system has no keyring to keep it in",
			"They stay" if dropped.size() > 1 else "It stays"], COLOR_WARN)
	if not moved.is_empty() or not dropped.is_empty():
		_save_settings()  # Rewrites the file without the plain-text copies.


## The secrets whose stored value differs from what should be stored now:
## the field text with Remember on, "" (erase) with it off.
func _secret_changes() -> Dictionary:
	var changes := {}
	for key: String in _secrets:
		var wanted: String = _secret_field(key).text if _secret_remember_button(key).button_pressed else ""
		if wanted != _stored_secrets.get(key, ""):
			changes[key] = wanted
	return changes


## Brings the OS credential store in line with the fields: writes remembered
## secrets that changed and erases the ones whose Remember toggle is off. Runs
## on a worker thread, since a round trip can take a second.
func _persist_secrets() -> void:
	if cli_mode:
		return
	if SecretStore.backend().is_empty():
		return
	if _secret_thread != null:
		_secrets_dirty = true
		return
	var changes := _secret_changes()
	if changes.is_empty():
		return
	_secret_thread = Thread.new()
	_secret_thread.start(_write_secrets.bind(changes))


## Worker thread: writes [param changes] (SecretStore key -> value).
func _write_secrets(changes: Dictionary) -> Dictionary:
	var failed := PackedStringArray()
	for key: String in changes:
		if not SecretStore.write(key, changes[key]):
			failed.append(key)
	_finish_secret_write.call_deferred()
	return {"changes": changes, "failed": failed}


## Joins the secret write thread and records what it stored. Does nothing
## when [method _flush_secrets] has joined it already.
func _finish_secret_write() -> void:
	if _secret_thread == null:
		return
	var res: Dictionary = _secret_thread.wait_to_finish()
	_secret_thread = null
	_record_secret_writes(res["changes"], res["failed"])
	if _secrets_dirty:
		_secrets_dirty = false
		_persist_secrets()


func _record_secret_writes(changes: Dictionary, failed: PackedStringArray) -> void:
	for key: String in changes:
		if not failed.has(key):
			_stored_secrets[key] = changes[key]
	if failed.is_empty():
		_secret_write_failed = false
		return
	if _secret_write_failed:
		return
	_secret_write_failed = true
	var labels := PackedStringArray()
	for key in failed:
		labels.append(_secret_label(key))
	log_line("Could not update the remembered %s in %s. Changing the field or the Remember toggle tries again." % [" and ".join(labels), SecretStore.backend()], COLOR_WARN)


## Quit: waits for a running write, then writes whatever changed since on
## this thread, since no deferred call runs any more. Safe to call twice.
func _flush_secrets() -> void:
	_secrets_dirty = false
	_finish_secret_write()
	if cli_mode or SecretStore.backend().is_empty():
		return
	var changes := _secret_changes()
	var failed := PackedStringArray()
	for key: String in changes:
		if not SecretStore.write(key, changes[key]):
			failed.append(key)
	_record_secret_writes(changes, failed)
