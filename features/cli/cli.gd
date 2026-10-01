extends Node
## Command-line mode: runs GodotPipe headless, without exporting it first.
##
##   godot --headless --path <GodotPipe> -- publish --project <app> [options]
##
## MainWindow starts this node instead of showing the window when there are
## arguments after "--". It drives the window's own code (the same checks,
## export, SteamCMD and butler runs as the Build & Publish button) with the
## apps and sign-ins the window saved, prints the console as plain text,
## writes it to a log file and optionally ends with a one-line JSON summary.
## Nothing is saved back: overrides such as --branch apply to this run only.
## See README.md, "Command line".

const EXIT_OK := 0
const EXIT_USAGE := 1  # bad arguments, unknown app, internal error
const EXIT_PREFLIGHT := 2  # the checks before the export, or a store's check
const EXIT_EXPORT := 3
const EXIT_SCRIPT_ERRORS := 4  # the exported build printed script errors (--strict)
const EXIT_UPLOAD := 5
const EXIT_AUTH := 6  # a sign-in, Steam Guard code or approval is needed

const EXIT_REASONS := {
	EXIT_OK: "ok",
	EXIT_USAGE: "usage",
	EXIT_PREFLIGHT: "preflight_failed",
	EXIT_EXPORT: "export_failed",
	EXIT_SCRIPT_ERRORS: "script_errors",
	EXIT_UPLOAD: "upload_failed",
	EXIT_AUTH: "auth_needed",
}

const DEFAULT_SMOKE_SECONDS := 15.0
const LOG_DIR := "user://cli_logs"
const KEEP_LOGS := 50

const USAGE := """Usage: godot --headless --path <GodotPipe folder> -- <command> [options]

Commands:
  list                      Apps, App IDs, depots, channels, presets and the Setup page state.
  check   --project <app>   The checks Build & Publish runs before exporting, including
                            the store checks (SteamCMD sign-in, depot IDs, branch; butler).
                            Nothing is exported or uploaded.
  publish --project <app>   Build & Publish: export, start the build, upload.
  help                      This text.

Options:
  --project <app>       project.godot, its folder, the app name or the Steam App ID
                        of an app added in the GodotPipe window.
  --stores steam,itch   Stores for this run (default: the app's ticked stores).
  --desc <text>         Steam build description; for itch.io only, the version.
  --branch <name>       Set the build live on this beta branch (not default/public).
  --dry-run             publish: export and start the build, but upload nothing.
  --strict              publish: stop before uploading when an exported build
                        printed script errors or crashed when started.
  --smoke-seconds <n>   How long each exported build runs headless (default 15).
  --no-smoke            Do not start the exported builds.
  --json                End with a one-line JSON summary on stdout.
  --log <file>          Write the full console here (default: user://cli_logs/).

Exit codes: 0 ok, 1 usage, 2 pre-flight failed, 3 export failed,
4 script errors in the exported build (--strict), 5 upload failed, 6 sign-in needed."""

var _w: MainWindow
var _opts := {}
var _command := ""
var _log: FileAccess
var _log_path := ""
var _started_ms := 0
var _step := ""  # title of the open console step, "" outside one
var _issues: Array[Dictionary] = []  # warning/error lines of the tools
var _issue_index := {}  # "<stage>|<line>" → index into _issues
var _messages: Array[Dictionary] = []  # GodotPipe's own warnings and errors
var _progress_shown := {}  # progress label → last quarter printed


func run(window: MainWindow, args: PackedStringArray) -> void:
	_w = window
	_started_ms = Time.get_ticks_msec()
	var err := _parse(args)
	if _command in ["help", "--help", "-h"]:
		print(USAGE)
		_quit(EXIT_OK)
		return
	_open_log()
	_w.console_emitted.connect(_on_console)
	_w.child_output.connect(_on_child_output)
	_w.progress_changed.connect(_on_progress)
	if not err.is_empty():
		_say("error: " + err)
		_say(USAGE)
		_finish(EXIT_USAGE, {})
		return
	match _command:
		"list":
			_list()
		"check", "publish":
			await _publish()
		_:
			_say("error: unknown command '%s'." % _command)
			_say(USAGE)
			_finish(EXIT_USAGE, {})


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

## Fills _command and _opts; returns an error message or "".
func _parse(args: PackedStringArray) -> String:
	var flags := ["--dry-run", "--strict", "--no-smoke", "--json"]
	var valued := ["--project", "--stores", "--desc", "--branch", "--smoke-seconds", "--log"]
	var i := 0
	while i < args.size():
		var arg := args[i]
		var value := ""
		var has_value := false
		if arg.begins_with("--") and "=" in arg:
			value = arg.get_slice("=", 1)
			arg = arg.get_slice("=", 0)
			has_value = true
		if arg in flags:
			_opts[arg.trim_prefix("--")] = true
		elif arg in valued:
			if not has_value:
				if i + 1 >= args.size():
					return "%s needs a value." % arg
				i += 1
				value = args[i]
			_opts[arg.trim_prefix("--")] = value
		elif arg.begins_with("-") and _command.is_empty() and arg in ["-h", "--help"]:
			_command = "help"
		elif arg.begins_with("-"):
			return "unknown option '%s'." % arg
		elif _command.is_empty():
			_command = arg
		else:
			return "unexpected argument '%s'." % arg
		i += 1
	if _command.is_empty():
		_command = "help"
	if _command in ["check", "publish"] and str(_opts.get("project", "")).strip_edges().is_empty():
		return "%s needs --project <app>." % _command
	if _opts.has("smoke-seconds") and not str(_opts["smoke-seconds"]).is_valid_float():
		return "--smoke-seconds needs a number."
	if _opts.has("stores"):
		for store in str(_opts["stores"]).split(",", false):
			if not store.strip_edges().to_lower() in ["steam", "itch", "itch.io"]:
				return "--stores takes steam, itch or both (steam,itch), not '%s'." % store
	return ""


## Index into the window's apps for [param spec]: a project.godot path, a
## folder, an app name (or a unique part of one) or a Steam App ID. -1 with
## the reason logged when none or several match.
func _find_project(spec: String) -> int:
	spec = spec.strip_edges()
	var path := spec
	if path.begins_with("~"):
		path = MainWindow._home_dir() + path.substr(1)
	if path.get_file() == "project.godot":
		path = path.get_base_dir()
	if path.is_relative_path() and DirAccess.dir_exists_absolute(path):
		path = OS.get_environment("PWD").path_join(path)
	path = path.simplify_path().trim_suffix("/")
	var projects := _w._projects
	for i in projects.size():
		if str(projects[i]["path"]).simplify_path().trim_suffix("/") == path:
			return i
	var by_name: Array[int] = []
	for i in projects.size():
		var p := projects[i]
		if str(p["name"]).to_lower() == spec.to_lower() or str(p.get("app_id", "")).strip_edges() == spec:
			return i
		if str(p["name"]).to_lower().contains(spec.to_lower()):
			by_name.append(i)
	if by_name.size() == 1:
		return by_name[0]
	if by_name.size() > 1:
		var names := PackedStringArray()
		for i in by_name:
			names.append("'%s'" % projects[i]["name"])
		_say("error: '%s' matches several apps: %s. Use the full name or the path." % [spec, ", ".join(names)])
		return -1
	if FileAccess.file_exists(path.path_join("project.godot")) or DirAccess.dir_exists_absolute(path):
		_say("error: %s is not an app in GodotPipe. Add it with + in the GodotPipe window once (it holds the App ID, depots and presets), then run this again." % path)
	else:
		_say("error: no app matches '%s'. Run the list command to see the apps." % spec)
	return -1


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

func _list() -> void:
	var w := _w
	var steamcmd := w._resolve_steamcmd(w.get_node("%SteamCmdBinary").text)
	var butler := w._resolve_butler(w.get_node("%ButlerBinary").text)
	var steam_user: String = w.get_node("%SteamUsername").text.strip_edges()
	var setup := {
		"steamcmd": steamcmd,
		"steam_username": steam_user,
		"steam_signed_in": w._login_ok(),
		"steam_password_remembered": not w.get_node("%SteamPassword").text.is_empty(),
		"steam_shared_secret_set": not w.get_node("%SteamSharedSecret").text.strip_edges().is_empty(),
		"butler": butler,
		"itch_signed_in": w._itch_ok(),
		"itch_username": w._itch_user,
	}
	_say("Setup")
	_say("  SteamCMD: %s" % (steamcmd if not steamcmd.is_empty() else "not found"))
	_say("  Steam: %s%s" % [steam_user if not steam_user.is_empty() else "no account", " (signed in)" if setup["steam_signed_in"] else " (not signed in)"])
	_say("  butler: %s" % (butler if not butler.is_empty() else "not found"))
	_say("  itch.io: %s" % ("signed in as %s" % w._itch_user if setup["itch_signed_in"] else "not signed in"))
	var apps: Array[Dictionary] = []
	for p in w._projects:
		var folder := w._is_folder_app(p)
		var presets: Array[Dictionary] = []
		if not folder:
			w._read_presets(p["path"])
			for i in w._preset_names.size():
				presets.append({"name": w._preset_names[i], "platform": w._preset_platforms[i], "kind": w._platform_kind(i)})
		var rows: Array[Dictionary] = []
		for i in p["depots"].size():
			var d: Dictionary = p["depots"][i]
			var kind := w._row_kind(p, d)
			var row := {
				"row": i + 1,
				"depot_id": str(d.get("depot_id", "")).strip_edges(),
				"itch_channel": str(d.get("itch_channel", "")).strip_edges(),
			}
			if folder:
				row["folder"] = str(d.get("content_dir", ""))
			else:
				row["preset"] = str(d.get("preset", ""))
				row["platform"] = kind
				row["executable"] = "index.html" if kind == "web" else str(d.get("output", "")).strip_edges() + w._shown_extension(kind)
			rows.append(row)
		var app := {
			"name": p["name"],
			"path": p["path"],
			"kind": p["kind"],
			"godot_binary": p.get("godot_binary", ""),
			"version": "" if folder else w._read_project_version(p["path"]),
			"steam": MainWindow._steam_on(p),
			"app_id": str(p.get("app_id", "")).strip_edges(),
			"branch": w._branch_name(p),
			"itch": MainWindow._itch_on(p),
			"itch_target": str(p.get("itch_target", "")).strip_edges(),
			"rows": rows,
			"presets": presets,
		}
		apps.append(app)
		_say("")
		_say("%s  (%s)" % [app["name"], app["path"]])
		_say("  Stores: %s%s" % [MainWindow._targets_label(p), "" if app["version"].is_empty() else " · version %s" % app["version"]])
		if app["steam"]:
			_say("  Steam: App %s · set live on: %s" % [app["app_id"], app["branch"] if not app["branch"].is_empty() else "(nothing, upload only)"])
		if app["itch"]:
			_say("  itch.io: %s" % app["itch_target"])
		for row in rows:
			var what: String = row.get("folder", "%s → %s" % [row.get("preset", ""), row.get("executable", "")])
			_say("  Row %d: %s · depot %s · channel %s" % [row["row"], what, row["depot_id"] if not row["depot_id"].is_empty() else "-", row["itch_channel"] if not row["itch_channel"].is_empty() else "-"])
		if not folder:
			var names := PackedStringArray()
			for preset in presets:
				names.append("%s [%s]" % [preset["name"], preset["platform"]])
			_say("  Presets: %s" % (", ".join(names) if not names.is_empty() else "none"))
	if apps.is_empty():
		_say("")
		_say("No apps yet. Add one with + in the GodotPipe window.")
	_finish(EXIT_OK, {"setup": setup, "apps": apps})


func _publish() -> void:
	var index := _find_project(str(_opts["project"]))
	if index < 0:
		_finish(EXIT_USAGE, {})
		return
	var p: Dictionary = _w._projects[index]
	# Overrides live in memory only: the window never saves in this mode.
	if _opts.has("stores"):
		var stores := str(_opts["stores"]).to_lower()
		p["steam_enabled"] = stores.contains("steam")
		p["itch_enabled"] = stores.contains("itch")
		if p["itch_enabled"]:
			_w._show_project(index)  # Channels follow the presets read here.
			_w._fill_default_channels(p)
	if _opts.has("branch"):
		p["branch"] = str(_opts["branch"]).strip_edges()
	if _opts.has("desc"):
		p["description"] = str(_opts["desc"])
	_w._show_project(index)
	await _w._check_godot_version()
	if not _w._godot_status.is_empty():
		var level := "error" if _w._godot_status["color"] == MainWindow.COLOR_ERR else "warning"
		_say("%s: %s" % [level, _w._godot_status["text"]])
		_messages.append({"level": level, "text": _w._godot_status["text"]})

	var mode := "check" if _command == "check" else ("dry_run" if _opts.get("dry-run", false) else "publish")
	var smoke := 0.0
	if mode != "check" and not _opts.get("no-smoke", false):
		smoke = float(_opts.get("smoke-seconds", DEFAULT_SMOKE_SECONDS))
	var ctx: Dictionary = await _w.build_and_publish({
		"mode": mode,
		"smoke_seconds": smoke,
		"strict": _opts.get("strict", false),
		"all_or_nothing": true,
	})
	ctx["mode"] = mode
	var summary := _summary(p, ctx)
	_finish(_exit_code(ctx), summary)


## Exit code for a finished run (see EXIT_*).
func _exit_code(ctx: Dictionary) -> int:
	if _w.auth_needed:
		return EXIT_AUTH
	match str(ctx.get("stage", "invalid")):
		"invalid", "preflight":
			return EXIT_PREFLIGHT
		"export":
			return EXIT_EXPORT
		"smoke":
			return EXIT_SCRIPT_ERRORS
		"done":
			for r: Dictionary in ctx.get("results", []):
				if not r["ok"]:
					return EXIT_UPLOAD
			return EXIT_OK
	return EXIT_USAGE  # "cancelled" / "upload" cannot happen without a window


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

func _summary(p: Dictionary, ctx: Dictionary) -> Dictionary:
	var app_id := str(p.get("app_id", "")).strip_edges()
	var branch := _w._branch_name(p)
	var out := {
		"project": {"name": p["name"], "path": p["path"], "app_id": app_id},
		"mode": ctx.get("mode", ""),
		"stage": ctx.get("stage", "invalid"),
		# The run clears the app's field after reading it, like the window does.
		"description": ctx.get("description", p.get("description", "")),
		"stores": {},
		"rows": [],
		"timings": {},
		"notes": [],
	}
	if not ctx.has("rows"):
		return out  # The form check failed before the run started.
	var results: Array = ctx["results"]
	var timings: Dictionary = ctx["timings"]
	for key: String in timings:
		out["timings"][key.trim_suffix("_ms") + "_s"] = snappedf(timings[key] / 1000.0, 0.1)
	var depots := PackedStringArray()
	var channels := PackedStringArray()
	for row: Dictionary in ctx["rows"]:
		if row["steam"]:
			depots.append(row["depot_id"])
		if row["itch"]:
			channels.append(row["channel"])
		out["rows"].append(_row_summary(row))
	if MainWindow._steam_on(p):
		var steam := _store_summary(ctx, "Steam", "steam", "steam_upload_ms")
		steam.merge({
			"app_id": app_id,
			"depots": depots,
			"branch": branch,
			"set_live": not branch.is_empty(),
			"build_id": ctx["steam_build_id"],
			"depot_check": ctx["depot_check"],
			"branches": ctx["steam_branches"],
			"builds_url": MainWindow.STEAMWORKS_BUILDS_URL % app_id,
		})
		out["stores"]["steam"] = steam
		if steam["status"] == "uploaded" and branch.is_empty():
			var note := "SteamCMD cannot set a build live on the default branch (Steam refuses it). Set build %s live in Steamworks → SteamPipe → Builds (%s); a released app confirms in the Steam Mobile app." % [ctx["steam_build_id"] if not str(ctx["steam_build_id"]).is_empty() else "(see the log)", steam["builds_url"]]
			out["notes"].append(note)
			_say("note: " + note)
	if MainWindow._itch_on(p):
		var itch := _store_summary(ctx, "itch.io", "itch", "itch_upload_ms")
		itch.merge({
			"target": ctx["target"],
			"channels": channels,
			"version": ctx["userversion"],
			"page_url": ButlerTool.page_url(ctx["target"]) if not str(ctx["target"]).is_empty() else "",
		})
		out["stores"]["itch"] = itch
	return out


## Status of one store after the run: "uploaded", "upload_failed",
## "preflight_failed", "checked" (check passed), "ready" (dry run: built,
## not uploaded) or "not_uploaded" (the run stopped before the upload).
func _store_summary(ctx: Dictionary, target: String, key: String, timing: String) -> Dictionary:
	var status := "not_uploaded"
	var message := ""
	for r: Dictionary in ctx["results"]:
		if r["target"] == target:
			message = r["text"]
			if r["ok"]:
				status = "uploaded"
			else:
				status = "upload_failed" if ctx["timings"].has(timing) else "preflight_failed"
	if message.is_empty() and ctx[key] and ctx["stage"] == "done":
		status = "checked" if ctx["mode"] == "check" else ("ready" if ctx["mode"] == "dry_run" else status)
	var out := {"status": status, "message": message}
	if ctx["timings"].has(timing):
		out["duration_s"] = snappedf(ctx["timings"][timing] / 1000.0, 0.1)
	return out


func _row_summary(row: Dictionary) -> Dictionary:
	var out := {
		"row": int(row["index"]) + 1,
		"label": row["label"],
		"preset": row["preset"],
		"platform": row["kind"],
		"folder": row["dir"],
		"depot_id": row["depot_id"] if row["steam"] else "",
		"itch_channel": row["channel"] if row["itch"] else "",
		"steam": row["steam"],
		"itch": row["itch"],
		"exported": row.get("exported", false),
		"files": [],
		"size": 0,
	}
	if row.has("export_ms"):
		out["export_s"] = snappedf(row["export_ms"] / 1000.0, 0.1)
	if row.get("exported", false):
		var dir: String = row["dir"]
		var listing := DirAccess.open(dir)
		if listing != null:
			listing.include_hidden = true
			var entries := Array(listing.get_files()) + Array(listing.get_directories())
			for entry: String in entries:
				var size := _size_of(dir.path_join(entry))
				out["files"].append({"path": dir.path_join(entry), "size": size})
				out["size"] += size
	if row.has("smoke"):
		out["smoke"] = row["smoke"]
	return out


## Size in bytes of a file, or of a folder with everything in it.
static func _size_of(path: String) -> int:
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		return f.get_length() if f != null else 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	dir.include_hidden = true
	var total := 0
	for f in dir.get_files():
		total += _size_of(path.path_join(f))
	for d in dir.get_directories():
		if not dir.is_link(path.path_join(d)):
			total += _size_of(path.path_join(d))
	return total


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

## Prints the summary, writes the log and quits with [param code].
func _finish(code: int, summary: Dictionary) -> void:
	var elapsed := (Time.get_ticks_msec() - _started_ms) / 1000.0
	_say("")
	_say("%s · exit %d (%s) · %.1fs · log: %s" % ["OK" if code == EXIT_OK else "FAILED", code, EXIT_REASONS[code], elapsed, _log_path])
	if _opts.get("json", false):
		var json := {"command": _command, "ok": code == EXIT_OK, "exit_code": code, "exit_reason": EXIT_REASONS[code]}
		json.merge(summary)
		json["duration_s"] = snappedf(elapsed, 0.1)
		json["issues"] = _issues
		json["messages"] = _messages
		json["log_file"] = _log_path
		var line := JSON.stringify(json)
		if _log != null:
			_log.store_line(line)
		print(line)
	_quit(code)


func _quit(code: int) -> void:
	if _log != null:
		_log.close()
		_log = null
	get_tree().quit(code)


func _open_log() -> void:
	_log_path = str(_opts.get("log", ""))
	if _log_path.is_empty():
		var dir := ProjectSettings.globalize_path(LOG_DIR)
		DirAccess.make_dir_recursive_absolute(dir)
		_prune_logs(dir)
		var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
		_log_path = dir.path_join("%s_%s.log" % [stamp, _command])
	else:
		if _log_path.begins_with("~"):
			_log_path = MainWindow._home_dir() + _log_path.substr(1)
		if _log_path.is_relative_path():
			_log_path = OS.get_environment("PWD").path_join(_log_path)
		DirAccess.make_dir_recursive_absolute(_log_path.get_base_dir())
	_log = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log == null:
		printerr("warning: could not write the log file %s (%s)." % [_log_path, error_string(FileAccess.get_open_error())])
		_log_path = ""
		return
	_log.store_line("%s %s · %s" % [MainWindow._app_name(), _command, " ".join(OS.get_cmdline_user_args())])


## Keeps the newest KEEP_LOGS logs in [param dir].
static func _prune_logs(dir: String) -> void:
	var logs := Array(DirAccess.get_files_at(dir)).filter(func(f: String) -> bool: return f.ends_with(".log"))
	logs.sort()  # Names start with the date, so this is oldest first.
	for i in maxi(0, logs.size() - KEEP_LOGS + 1):
		DirAccess.remove_absolute(dir.path_join(logs[i]))


## One line on stdout and in the log file (with the time).
func _say(text: String) -> void:
	print(text)
	_log_only(text)


func _log_only(text: String) -> void:
	if _log != null:
		_log.store_line("%s  %s" % [Time.get_time_string_from_system(), text])


## True for the lines of the app info SteamCMD prints for the depot check
## (hundreds of KeyValues lines): they go to the log file only.
func _is_app_info_dump(text: String) -> bool:
	if not _step.begins_with("Checking depots"):
		return false
	var t := text.strip_edges()
	return text.begins_with("\t") or t.begins_with("\"") or t in ["{", "}"]


func _on_console(kind: String, text: String, color: String) -> void:
	var gutter := "  │ " if not _step.is_empty() else "  "
	match kind:
		"banner":
			_say("")
			_say("== %s ==" % text)
		"step":
			_step = text
			_say("▸ " + text)
		"step_done":
			_step = ""
			_say("  " + text)
		"cmd", "exit":
			_say(gutter + text)
		"out":
			if _is_app_info_dump(text):
				_log_only(gutter + text)
			else:
				_say(gutter + text)
		_:
			var prefix := ""
			if color == MainWindow.COLOR_ERR:
				prefix = "error: "
				_messages.append({"level": "error", "stage": _step, "text": text})
			elif color == MainWindow.COLOR_WARN:
				prefix = "warning: "
				_messages.append({"level": "warning", "stage": _step, "text": text})
			_say(gutter + prefix + text)


## Collects the warning and error lines of every tool's output.
static var _error_re := RegEx.create_from_string("(?i)\\b(error|errors|failed|failure|fatal|exception|denied|abort|aborted|crash|crashed)\\b")
## Lines the tools print on every successful run; still listed, marked benign.
const BENIGN: PackedStringArray = [
	"configstore.cpp",  # SteamCMD: "ConfigStore ... is dirty, and being destroyed" on quit
]
static var _warning_re := RegEx.create_from_string("(?i)\\b(warning|warnings|warn)\\b")


func _on_child_output(line: String, _is_stderr: bool, tool: String) -> void:
	var level := ""
	if _error_re.search(line) != null:
		level = "error"
	elif _warning_re.search(line) != null:
		level = "warning"
	if level.is_empty():
		return
	var key := "%s|%s" % [_step, line.strip_edges()]
	if _issue_index.has(key):
		_issues[_issue_index[key]]["count"] += 1
		return
	if _issues.size() >= 500:
		return
	_issue_index[key] = _issues.size()
	var issue := {"source": tool if not tool.is_empty() else "other", "stage": _step, "level": level, "line": line.strip_edges(), "count": 1}
	for needle: String in BENIGN:
		if line.contains(needle):
			issue["benign"] = true
	_issues.append(issue)


func _on_progress(label: String, pct: int) -> void:
	var quarter := pct / 25
	if _progress_shown.get(label, -1) == quarter:
		return
	_progress_shown[label] = quarter
	_say("  │ %s %d%%" % [label, pct])
