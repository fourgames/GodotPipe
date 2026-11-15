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
## Nothing is saved back (overrides such as --branch apply to this run only),
## except by the add command, which exists to add an app to projects.cfg.
## See README.md, "Command line".

const EXIT_OK := 0
const EXIT_USAGE := 1  # bad arguments, unknown app, internal error
const EXIT_PREFLIGHT := 2  # the checks before the export, or a store's check
const EXIT_EXPORT := 3
const EXIT_SCRIPT_ERRORS := 4  # script or shader errors or missing files in the exported build (--strict)
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
  add --app <id> --project <folder>
                            Adds a Godot game as a Steam app, as + in the window
                            would, with one row per desktop platform. Export
                            presets missing for those platforms are added to
                            the game's export_presets.cfg. Saved to projects.cfg.
  help                      This text.

Options:
  --project <app>       project.godot, its folder, the app name or the Steam App ID
                        of an app added in the GodotPipe window.
  --stores steam,itch   Stores for this run (default: the app's ticked stores).
  --desc <text>         Steam build description; for itch.io only, the version.
  --branch <name>       Set the build live on this beta branch (not default/public).
  --dry-run             publish: export and start the build, but upload nothing.
  --strict              publish: stop before uploading when an exported build
                        has script errors, shader errors or missing files,
                        or crashed.
  --smoke-seconds <n>   How long each exported build runs headless, and then
                        with a renderer, in game time (default 15). The
                        script check (every script loaded, every scene's and
                        resource's files checked) runs as well.
  --no-smoke            Do not start the exported builds (no script check).
  --json                End with a one-line JSON summary on stdout.

add options (all but --app and --project default as described):
  --app <id>            Steam App ID. Refused when an app has it, unless --update.
  --project <folder>    The game's folder or its project.godot.
  --update              Replace the app with this App ID (keeps its build folder,
                        branch, description and itch.io settings).
  --name <text>         Default: config/name in project.godot.
  --output <name>       Executable base name. Default: the name without spaces
                        or other symbols (Deadstop → Deadstop.exe/.app/.x86_64).
  --platforms <list>    windows,macos,linux (default: all three, in that order).
  --windows-depot <id>  Default: App ID + 1.
  --macos-depot <id>    Default: App ID + 2.
  --linux-depot <id>    Default: App ID + 3.
  --godot <binary>      Default: an installed Godot matching the project's version.
  --branch <name>       Beta branch to set builds live on (default: none).
  --bundle-id <id>      macOS bundle identifier for a macOS preset that is
                        created (default: com.example.<name>).
  --no-presets          Do not add missing export presets.
  --log <file>          Write the full console here (default: user://cli_logs/).

Exit codes: 0 ok, 1 usage, 2 pre-flight failed, 3 export failed,
4 script or shader errors or missing files in the exported build (--strict), 5 upload failed, 6 sign-in needed."""

## The rows add creates: platform, export_presets.cfg platform name, depot
## offset from the App ID and the file extension of the export path.
const ADD_PLATFORMS := {
	"windows": {"platform": "Windows Desktop", "offset": 1, "ext": ".exe"},
	"macos": {"platform": "macOS", "offset": 2, "ext": ".zip"},
	"linux": {"platform": "Linux", "offset": 3, "ext": ".x86_64"},
}

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
		"add", "add-game":
			_command = "add"
			await _add()
		_:
			_say("error: unknown command '%s'." % _command)
			_say(USAGE)
			_finish(EXIT_USAGE, {})


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

## Fills _command and _opts; returns an error message or "".
func _parse(args: PackedStringArray) -> String:
	var flags := ["--dry-run", "--strict", "--no-smoke", "--json", "--update", "--no-presets"]
	var valued := ["--project", "--stores", "--desc", "--branch", "--smoke-seconds", "--log",
		"--app", "--name", "--output", "--platforms", "--windows-depot", "--macos-depot",
		"--linux-depot", "--godot", "--bundle-id"]
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
	if _command in ["add", "add-game"]:
		if str(_opts.get("project", "")).strip_edges().is_empty():
			return "add needs --project <the game's folder>."
		if not _is_id(str(_opts.get("app", ""))):
			return "add needs --app <Steam App ID> (digits)."
		for key in ["windows-depot", "macos-depot", "linux-depot"]:
			if _opts.has(key) and not _is_id(str(_opts[key])):
				return "--%s needs a depot ID (digits)." % key
		for kind in str(_opts.get("platforms", "windows")).split(",", false):
			if not kind.strip_edges().to_lower() in ADD_PLATFORMS:
				return "--platforms takes windows, macos and linux, not '%s'." % kind
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
		var app := _app_summary(p)
		var rows: Array[Dictionary] = app["rows"]
		var presets: Array[Dictionary] = app["presets"]
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


## What list reports for app [param p]: stores, rows and the project's presets.
func _app_summary(p: Dictionary) -> Dictionary:
	var w := _w
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
	return app


## Adds (or with --update replaces) a Godot game as a Steam app, filled in as
## the window's + button and depot table would: name from project.godot, one
## row per platform with depot App ID + 1/2/3 and the name without symbols as
## the executable. Saved to projects.cfg, unlike every other command.
func _add() -> void:
	var w := _w
	var app_id := str(_opts["app"]).strip_edges()
	var dir := str(_opts["project"]).strip_edges()
	if dir.begins_with("~"):
		dir = MainWindow._home_dir() + dir.substr(1)
	if dir.get_file() == "project.godot":
		dir = dir.get_base_dir()
	if dir.is_relative_path():
		dir = OS.get_environment("PWD").path_join(dir)
	dir = dir.simplify_path().trim_suffix("/")
	if not FileAccess.file_exists(dir.path_join("project.godot")):
		_say("error: no project.godot in %s." % dir)
		_finish(EXIT_USAGE, {})
		return
	var existing := -1
	for i in w._projects.size():
		if str(w._projects[i].get("app_id", "")).strip_edges() == app_id:
			existing = i
			break
	if existing >= 0 and not _opts.get("update", false):
		_say("error: App %s is already in GodotPipe as '%s' (%s). Pass --update to replace it." % [app_id, w._projects[existing]["name"], w._projects[existing]["path"]])
		_finish(EXIT_USAGE, {"app": _app_summary(w._projects[existing])})
		return
	var same_folder := w._project_index_for_path(dir)
	if same_folder >= 0 and same_folder != existing:
		_message("warning", "'%s' already uses %s. Both entries upload separately, which is right for a demo or playtest with its own App ID." % [w._projects[same_folder]["name"], dir])

	var game_name := str(_opts.get("name", "")).strip_edges()
	if game_name.is_empty():
		game_name = w._read_project_name(dir)
	var output := str(_opts.get("output", "")).strip_edges()
	if output.is_empty():
		output = RegEx.create_from_string("[^A-Za-z0-9_-]").sub(game_name, "", true)
		if output.is_empty():
			output = "game"
	output = w._strip_known_extension(output)
	var kinds := PackedStringArray()
	for kind in str(_opts.get("platforms", "windows,macos,linux")).split(",", false):
		kind = kind.strip_edges().to_lower()
		if not kind in kinds:
			kinds.append(kind)

	var binary := str(_opts.get("godot", "")).strip_edges()
	if binary.is_empty() and existing >= 0:
		binary = str(w._projects[existing].get("godot_binary", ""))
	if binary.is_empty():
		var required := w._read_required_godot_version(dir)
		_say("Looking for an installed Godot %s…" % required)
		binary = await w._guess_godot_binary(required)
		if binary.is_empty():
			_message("warning", "No installed Godot matches the project's version %s. Set the Godot binary in the window, or pass --godot." % required)

	var created := PackedStringArray()
	if not _opts.get("no-presets", false):
		var result: Variant = _add_missing_presets(dir, kinds, game_name, output)
		if result == null:
			_finish(EXIT_USAGE, {})
			return
		created = result
	w._read_presets(dir)

	var p: Dictionary
	if existing >= 0:
		p = w._projects[existing]
		p["path"] = dir
		p["name"] = game_name
		p["kind"] = "godot"
		p["godot_binary"] = binary
	else:
		p = w._new_project(dir, "godot", binary)
		p["name"] = game_name
		p["itch_enabled"] = false  # No itch.io game is known; tick it in the window.
	p["steam_enabled"] = true
	p["app_id"] = app_id
	if _opts.has("branch"):
		p["branch"] = str(_opts["branch"]).strip_edges()
	var old_rows: Array = p.get("depots", [])
	var rows: Array = []
	var taken := PackedStringArray()
	for kind in kinds:
		var info: Dictionary = ADD_PLATFORMS[kind]
		var at := w._preset_platforms.find(info["platform"])
		var preset: String = w._preset_names[at] if at >= 0 else info["platform"]
		if at < 0:
			_message("warning", "%s has no %s export preset. Add one in Godot → Project → Export…, named '%s'." % [dir.path_join("export_presets.cfg"), info["platform"], preset])
		var depot := str(_opts.get(kind + "-depot", str(int(app_id) + int(info["offset"])))).strip_edges()
		var channel := ""
		for old: Dictionary in old_rows:
			if str(old.get("preset", "")) == preset:
				channel = str(old.get("itch_channel", "")).strip_edges()
		if channel.is_empty() or channel in taken:
			channel = ButlerTool.default_channel(kind, taken)
		taken.append(channel)
		rows.append({"depot_id": depot, "itch_channel": channel, "output": output, "preset": preset})
	p["depots"] = rows
	if existing < 0:
		w._projects.insert(0, p)  # New apps go on top, as in the window.
	w._save_projects(true)

	_say("%s '%s' (App %s, %s)" % ["Updated" if existing >= 0 else "Added", game_name, app_id, dir])
	for preset in created:
		_say("  Added the %s export preset to %s" % [preset, dir.path_join("export_presets.cfg")])
	var app := _app_summary(p)
	for row: Dictionary in app["rows"]:
		_say("  Row %d: %s → %s · depot %s" % [row["row"], row["preset"], row["executable"], row["depot_id"]])
	_say("  Godot: %s" % (binary if not binary.is_empty() else "not found"))
	_say("Close and reopen the GodotPipe window if it is open, or its next save drops this change.")
	_finish(EXIT_OK, {"added": existing < 0, "updated": existing >= 0, "presets_created": created, "app": app})


## Appends a preset for each platform in [param kinds] that
## [param dir]/export_presets.cfg has none for, copying the filters of the
## file's first preset, and leaves the rest of the file untouched. Returns the
## names added, or null (reason said) when the file cannot be read or written.
func _add_missing_presets(dir: String, kinds: PackedStringArray, game_name: String, output: String) -> Variant:
	var path := dir.path_join("export_presets.cfg")
	var cfg := ConfigFile.new()
	var text := ""
	if FileAccess.file_exists(path):
		text = FileAccess.get_file_as_string(path)
		if cfg.parse(text) != OK:
			_say("error: %s cannot be read; fix it in Godot first." % path)
			return null
	var count := 0
	var platforms := PackedStringArray()
	while cfg.has_section("preset.%d" % count):
		platforms.append(str(cfg.get_value("preset.%d" % count, "platform", "")))
		count += 1
	var template := "preset.0" if count > 0 else ""
	var export_dir := "export"
	if not template.is_empty():
		var old_path := str(cfg.get_value(template, "export_path", ""))
		if old_path.contains("/"):
			export_dir = old_path.get_base_dir()
	var bundle := str(_opts.get("bundle-id", "")).strip_edges()
	if bundle.is_empty():
		bundle = "com.example." + output.to_lower().replace("_", "-")
	var add := ConfigFile.new()
	var created := PackedStringArray()
	for kind in kinds:
		var info: Dictionary = ADD_PLATFORMS[kind]
		if info["platform"] in platforms:
			continue
		var s := "preset.%d" % count
		var o := s + ".options"
		count += 1
		add.set_value(s, "name", info["platform"])
		add.set_value(s, "platform", info["platform"])
		add.set_value(s, "dedicated_server", false)
		for key in ["custom_features", "include_filter", "exclude_filter"]:
			add.set_value(s, key, str(cfg.get_value(template, key, "")) if not template.is_empty() else "")
		add.set_value(s, "export_filter", str(cfg.get_value(template, "export_filter", "all_resources")) if not template.is_empty() else "all_resources")
		add.set_value(s, "export_path", export_dir.path_join(output + info["ext"]))
		add.set_value(s, "script_export_mode", int(cfg.get_value(template, "script_export_mode", 2)) if not template.is_empty() else 2)
		match kind:
			"windows":
				add.set_value(o, "binary_format/embed_pck", false)
				add.set_value(o, "binary_format/architecture", "x86_64")
				add.set_value(o, "texture_format/s3tc_bptc", true)
				add.set_value(o, "texture_format/etc2_astc", false)
				add.set_value(o, "application/product_name", game_name)
			"macos":
				add.set_value(o, "export/distribution_type", 1)
				add.set_value(o, "binary_format/architecture", "universal")
				add.set_value(o, "application/bundle_identifier", bundle)
				add.set_value(o, "application/app_category", "Games")
				add.set_value(o, "display/high_res", true)
				add.set_value(o, "codesign/codesign", 0)
			"linux":
				add.set_value(o, "binary_format/embed_pck", false)
				add.set_value(o, "binary_format/architecture", "x86_64")
				add.set_value(o, "texture_format/s3tc_bptc", true)
				add.set_value(o, "texture_format/etc2_astc", false)
		var template_options := template + ".options"
		if not template.is_empty() and cfg.has_section_key(template_options, "shader_baker/enabled"):
			add.set_value(o, "shader_baker/enabled", cfg.get_value(template_options, "shader_baker/enabled"))
		created.append(info["platform"])
	if created.is_empty():
		return created
	var out := text.strip_edges(false, true)
	out += ("\n\n" if not out.is_empty() else "") + add.encode_to_text().strip_edges() + "\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("error: cannot write %s (%s)." % [path, error_string(FileAccess.get_open_error())])
		return null
	f.store_string(out)
	f.close()
	return created


func _message(level: String, text: String) -> void:
	_say("%s: %s" % [level, text])
	_messages.append({"level": level, "text": text})


static func _is_id(text: String) -> bool:
	text = text.strip_edges()
	return text.is_valid_int() and int(text) > 0


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
		"script_check": mode != "check" and not _opts.get("no-smoke", false),
		"all_or_nothing": true,
		# The render run's last frame goes next to this run's log.
		"frame_dir": _log_path.get_base_dir() if not _log_path.is_empty() else ProjectSettings.globalize_path(LOG_DIR),
		"frame_prefix": _log_path.get_file().get_basename() if not _log_path.is_empty() else _command,
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
	if row.has("render"):
		out["render"] = row["render"]
	if row.has("script_check"):
		out["script_check"] = row["script_check"]
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


## Keeps the newest KEEP_LOGS logs in [param dir], with the frames their
## render runs saved (<log name>_row<n>_<platform>.png).
static func _prune_logs(dir: String) -> void:
	var files := DirAccess.get_files_at(dir)
	var logs := Array(files).filter(func(f: String) -> bool: return f.ends_with(".log"))
	logs.sort()  # Names start with the date, so this is oldest first.
	for i in maxi(0, logs.size() - KEEP_LOGS + 1):
		DirAccess.remove_absolute(dir.path_join(logs[i]))
		var stem: String = logs[i].get_basename() + "_"
		for f in files:
			if f.begins_with(stem) and f.ends_with(".png"):
				DirAccess.remove_absolute(dir.path_join(f))


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
