extends RefCounted
## The script check of Build & Publish: loads every script of an exported
## build, so a script that only fails in an exported build (e.g. one that uses
## an editor-only class such as EditorInterface) is caught even when nothing
## loads it in the first seconds of the game.
##
## The uploaded files are never touched. MainWindow copies the build to a
## scratch folder; [method make_check_pck] rewrites the copy's .pck with
## PCKPacker: the game's files, plus a checker scene and an override.cfg that
## makes it the main scene (an exported build refuses --main-pack). Started
## headless, the game's autoloads run, then the checker:
## - load()s every .gd (scenes are not loaded or instantiated: that is slow
##   for big terrain data and can have side effects);
## - checks that every dependency of every .tscn and .tres exists.
## It prints Godot's own errors for broken scripts, a MISSING line per missing
## dependency and a DONE line at the end (see [method findings]).

const DIR := "__godotpipe_script_check"
const SCENE := "res://%s/check.tscn" % DIR
const MARK := "GODOTPIPE_SCRIPT_CHECK"

## PCK header flags and file flags (core/io/file_access_pack.h).
const PACK_DIR_ENCRYPTED := 1
const PACK_REL_FILEBASE := 2
const PACK_FILE_ENCRYPTED := 1
const PACK_FILE_REMOVAL := 2

const CHECKER := """extends Node
## Written by GodotPipe for its script check; never part of an upload.

func _ready() -> void:
	var lists := FileAccess.get_file_as_string("res://%s/paths.txt").split("\\n\\n")
	var scripts := lists[0].split("\\n", false)
	var resources := lists[1].split("\\n", false) if lists.size() > 1 else PackedStringArray()
	print("%s START %%d scripts, %%d scenes and resources" %% [scripts.size(), resources.size()])
	var broken := 0
	for path in scripts:
		var script := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as Script
		if script == null or not script.can_instantiate():
			broken += 1
			print("%s BROKEN\t" + path)
	var missing := 0
	for path in resources:
		for dep: String in ResourceLoader.get_dependencies(path):
			var dep_path: String = dep.get_slice("::", 2) if dep.contains("::") else dep
			var uid: String = dep.get_slice("::", 0) if dep.contains("::") else ""
			if uid.begins_with("uid://") and ResourceUID.has_id(ResourceUID.text_to_id(uid)):
				dep_path = ResourceUID.get_id_path(ResourceUID.text_to_id(uid))
			if dep_path.is_empty():
				dep_path = uid
			if not ResourceLoader.exists(dep_path):
				missing += 1
				print("%s MISSING\t" + path + "\t" + dep_path)
	print("%s DONE %%d broken scripts, %%d missing files" %% [broken, missing])
	get_tree().quit()
""" % [DIR, MARK, MARK, MARK, MARK]

const CHECKER_SCENE := """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://%s/check.gd" id="1"]

[node name="GodotPipeScriptCheck" type="Node"]
script = ExtResource("1")
""" % DIR

const OVERRIDE := """[application]

run/main_scene="%s"
""" % SCENE


## The index of the .pck at [param path]: { version, godot (major, minor,
## patch), flags, base, entries: [{ path, offset, size, flags }] } with
## absolute offsets, or { error }.
static func read_pck(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"error": "cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	if f.get_32() != 0x43504447:  # "GDPC"
		return {"error": "%s is not a Godot .pck" % path.get_file()}
	var version := f.get_32()
	var godot := [f.get_32(), f.get_32(), f.get_32()]
	if version < 2:
		return {"error": "%s is a Godot 3 .pck" % path.get_file()}
	var flags := f.get_32()
	var base := f.get_64()
	if version >= 3:
		f.seek(f.get_64())  # The directory sits after the files.
	else:
		f.seek(f.get_position() + 16 * 4)
	if flags & PACK_DIR_ENCRYPTED:
		return {"error": "the .pck is encrypted"}
	var count := f.get_32()
	var entries: Array[Dictionary] = []
	for i in count:
		var name := f.get_buffer(f.get_32()).get_string_from_utf8()
		var offset := f.get_64()
		var size := f.get_64()
		f.get_buffer(16)  # md5
		var file_flags := f.get_32()
		if file_flags & PACK_FILE_ENCRYPTED:
			return {"error": "files in the .pck are encrypted"}
		if flags & PACK_REL_FILEBASE:
			offset += base
		entries.append({"path": name.trim_prefix("res://"), "offset": offset, "size": size, "flags": file_flags})
	if f.get_error() != OK and f.get_error() != ERR_FILE_EOF:
		return {"error": "%s is damaged" % path.get_file()}
	return {"version": version, "godot": godot, "flags": flags, "base": base, "entries": entries}


## What the checker loads: { scripts, resources } as res:// paths. An
## exported build keeps a converted or compiled file under its first name
## through a .remap file, so the names before .remap are used. Folders of
## editor plugins (with a plugin.cfg in [param project_dir]) are left out of
## the scripts: an exported game never runs them and they may use the editor's
## classes; a scene that uses one of their scripts still has it checked as a
## dependency.
static func check_lists(entries: Array[Dictionary], project_dir: String) -> Dictionary:
	var plugin_dirs := editor_plugin_dirs(project_dir)
	var scripts := {}
	var resources := {}
	for e in entries:
		var path: String = e["path"]
		if path.begins_with(".godot/") or path.begins_with(DIR + "/") or e["flags"] & PACK_FILE_REMOVAL:
			continue
		path = path.trim_suffix(".remap")
		match path.get_extension():
			"gd":
				var skip := false
				for dir in plugin_dirs:
					if path.begins_with(dir):
						skip = true
						break
				if not skip:
					scripts["res://" + path] = true
			"tscn", "tres":
				resources["res://" + path] = true
	var out := {"scripts": scripts.keys(), "resources": resources.keys(), "plugin_dirs": plugin_dirs}
	out["scripts"].sort()
	out["resources"].sort()
	return out


## "addons/<name>/" of every editor plugin in the project at [param project_dir].
static func editor_plugin_dirs(project_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var pending := ["addons"]
	while not pending.is_empty():
		var rel: String = pending.pop_back()
		var full := project_dir.path_join(rel)
		if FileAccess.file_exists(full.path_join("plugin.cfg")):
			out.append(rel + "/")
			continue
		if rel.count("/") >= 2:
			continue
		for d in DirAccess.get_directories_at(full):
			pending.append(rel.path_join(d))
	out.sort()
	return out


## Writes [param out_pck]: every file of the .pck at [param src_pck] (index
## [param pck]) plus the checker, which loads [param lists]. Files are
## unpacked into [param scratch] first, as PCKPacker reads them from disk.
## Returns "" or what went wrong. Runs on a thread.
static func make_check_pck(src_pck: String, pck: Dictionary, lists: Dictionary, out_pck: String, scratch: String) -> String:
	var src := FileAccess.open(src_pck, FileAccess.READ)
	if src == null:
		return "cannot open %s" % src_pck
	if DirAccess.make_dir_recursive_absolute(scratch) != OK:
		return "cannot create %s" % scratch
	var packer := PCKPacker.new()
	if packer.pck_start(out_pck) != OK:
		return "cannot write %s" % out_pck
	var i := 0
	for e: Dictionary in pck["entries"]:
		var target := "res://" + str(e["path"])
		if e["flags"] & PACK_FILE_REMOVAL:
			packer.add_file_removal(target)
			continue
		var tmp := scratch.path_join("%d" % i)
		i += 1
		var dst := FileAccess.open(tmp, FileAccess.WRITE)
		if dst == null:
			return "cannot write %s" % tmp
		src.seek(e["offset"])
		var left: int = e["size"]
		while left > 0:
			var chunk := src.get_buffer(mini(left, 1 << 20))
			if chunk.is_empty():
				return "%s ends early" % src_pck.get_file()
			dst.store_buffer(chunk)
			left -= chunk.size()
		dst.close()
		if packer.add_file(target, tmp) != OK:
			return "PCKPacker refused %s" % target
	var files := {
		"check.gd": CHECKER,
		"check.tscn": CHECKER_SCENE,
		"paths.txt": "\n".join(lists["scripts"]) + "\n\n" + "\n".join(lists["resources"]),
	}
	for name: String in files:
		var tmp := scratch.path_join(name)
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			return "cannot write %s" % tmp
		f.store_string(files[name])
		f.close()
		packer.add_file("res://%s/%s" % [DIR, name], tmp)
	var tmp_override := scratch.path_join("override.cfg")
	var o := FileAccess.open(tmp_override, FileAccess.WRITE)
	if o == null:
		return "cannot write %s" % tmp_override
	o.store_string(OVERRIDE)
	o.close()
	packer.add_file("res://override.cfg", tmp_override)
	if packer.flush() != OK:
		return "PCKPacker could not write %s" % out_pck
	# PCKPacker stamps GodotPipe's engine version; a game made with an older
	# 4.x refuses a .pck from a newer engine. The format is the same, so the
	# game's own version goes back in.
	var check := read_pck(out_pck)
	if check.has("error"):
		return check["error"]
	if check["version"] != pck["version"]:
		return "this GodotPipe writes .pck format %d, the game reads format %d" % [check["version"], pck["version"]]
	var f := FileAccess.open(out_pck, FileAccess.READ_WRITE)
	if f == null:
		return "cannot reopen %s" % out_pck
	f.seek(8)
	for n: int in pck["godot"]:
		f.store_32(n)
	f.close()
	return ""


## What the checker printed, from the lines of the run: { done (it reached
## the end), broken (script paths that failed to load), missing (lines
## "res://scene.tscn needs res://file, which is not in the build") }.
static func findings(lines: Array[String]) -> Dictionary:
	var out := {"done": false, "broken": PackedStringArray(), "missing": PackedStringArray()}
	for line in lines:
		line = line.strip_edges()
		if not line.begins_with(MARK + " "):
			continue
		var parts := line.trim_prefix(MARK + " ").split("\t")
		match parts[0].get_slice(" ", 0):
			"DONE":
				out["done"] = true
			"BROKEN":
				if parts.size() > 1:
					out["broken"].append(parts[1])
			"MISSING":
				if parts.size() > 2:
					out["missing"].append("%s needs %s, which is not in the build" % [parts[1], parts[2]])
	return out
