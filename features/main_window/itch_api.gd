extends Node
## itch.io's server-side API for the signed-in account: who the API key
## belongs to (name and avatar), which games it can upload to and their covers.
##
## The key goes in an Authorization header, never in a URL, so it cannot end
## up in a log line or a proxy's access log. Avatars are cached on disk
## (user://itch_assets/profiles/<user id>.img), and so are game covers
## (user://itch_assets/covers/<game id>.img).
##
## Knows nothing about the UI: call [method fetch_profile] / [method fetch_games]
## and listen for the signals. Every answer carries the serial of the request
## it belongs to, so the caller can drop answers for a key it no longer uses.

## [param user] is { id, username, display_name, url }; [param texture] is
## null when the account has no (decodable) avatar.
signal profile_ready(serial: int, user: Dictionary, texture: Texture2D)
## [param unauthorized] is true when itch.io rejected the key itself.
signal profile_failed(serial: int, reason: String, unauthorized: bool)
## [param games] is an Array of { id, title, target, url, published, cover_url }.
signal games_ready(serial: int, games: Array)
signal games_failed(serial: int, reason: String)
## The cover of the game [param target] (user/game) is ready.
signal cover_ready(target: String, texture: Texture2D)
signal cover_failed(target: String, reason: String)

const PROFILE_URL := "https://api.itch.io/profile"
const GAMES_URL := "https://api.itch.io/profile/games"
const CACHE_DIR := "user://itch_assets/profiles"
const COVER_CACHE_DIR := "user://itch_assets/covers"

var _profile_http: HTTPRequest
var _games_http: HTTPRequest
var _cover_http: HTTPRequest
var _cover_game := {}  # the game whose cover _cover_http is downloading
var _serial := 0
var _profile_serial := -1
var _games_serial := -1
var _user := {}
var _stage := ""  # "profile" | "avatar"


func _ready() -> void:
	_profile_http = _make_http(_on_profile_completed)
	_games_http = _make_http(_on_games_completed)
	_cover_http = _make_http(_on_cover_completed)


func _make_http(handler: Callable) -> HTTPRequest:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	http.request_completed.connect(handler)
	add_child(http)
	return http


static func _headers(key: String) -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer %s" % key.strip_edges(), "Accept: application/json"])


static func cache_path(user_id: String) -> String:
	return CACHE_DIR.path_join(user_id + ".img")


## Looks up the account [param key] belongs to. Returns the request's serial.
func fetch_profile(key: String) -> int:
	_serial += 1
	var serial := _serial
	if _profile_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_profile_http.cancel_request()
	_profile_serial = serial
	_user = {}
	_stage = "profile"
	if _profile_http.request(PROFILE_URL, _headers(key)) != OK:
		_profile_serial = -1
		profile_failed.emit.call_deferred(serial, "request failed", false)
	return serial


## Lists the games of the account [param key] belongs to. Returns the serial.
func fetch_games(key: String) -> int:
	_serial += 1
	var serial := _serial
	if _games_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_games_http.cancel_request()
	_games_serial = serial
	if _games_http.request(GAMES_URL, _headers(key)) != OK:
		_games_serial = -1
		games_failed.emit.call_deferred(serial, "request failed")
	return serial


func _on_profile_completed(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray) -> void:
	var serial := _profile_serial
	if serial < 0:
		return
	if _stage == "avatar":
		# The avatar is a bonus: without it the chip shows the first letter.
		_profile_serial = -1
		var img: Image = null
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			img = _decode(body)
		if img != null:
			DirAccess.make_dir_recursive_absolute(CACHE_DIR)
			var f := FileAccess.open(cache_path(str(_user["id"])), FileAccess.WRITE)
			if f != null:
				f.store_buffer(body)
				f.close()
		profile_ready.emit(serial, _user, ImageTexture.create_from_image(img) if img != null else null)
		return
	var answer := _parse(result, code, body)
	if answer.has("error"):
		_profile_serial = -1
		profile_failed.emit(serial, answer["error"], answer.get("unauthorized", false))
		return
	var user: Variant = answer["data"].get("user")
	if not user is Dictionary:
		_profile_serial = -1
		profile_failed.emit(serial, "itch.io sent no account details", false)
		return
	_user = {
		"id": str(user.get("id", "")),
		"username": str(user.get("username", "")),
		"display_name": str(user.get("display_name", "")) if user.get("display_name") != null else "",
		"url": str(user.get("url", "")),
	}
	var cover: Variant = user.get("cover_url")
	if FileAccess.file_exists(cache_path(_user["id"])):
		var cached := _decode(FileAccess.get_file_as_bytes(cache_path(_user["id"])))
		if cached != null:
			_profile_serial = -1
			profile_ready.emit(serial, _user, ImageTexture.create_from_image(cached))
			# Refresh the cached picture quietly for the next start.
			if cover is String and not cover.is_empty():
				_refresh_avatar(cover)
			return
	if not cover is String or cover.is_empty():
		_profile_serial = -1
		profile_ready.emit(serial, _user, null)
		return
	_stage = "avatar"
	if _profile_http.request(cover) != OK:
		_profile_serial = -1
		profile_ready.emit(serial, _user, null)


## Downloads [param url] into the avatar cache without emitting anything.
func _refresh_avatar(url: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	var user_id := str(_user["id"])
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and _decode(body) != null:
			DirAccess.make_dir_recursive_absolute(CACHE_DIR)
			var f := FileAccess.open(cache_path(user_id), FileAccess.WRITE)
			if f != null:
				f.store_buffer(body)
				f.close()
		http.queue_free()
	)
	add_child(http)
	if http.request(url) != OK:
		http.queue_free()


func _on_games_completed(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray) -> void:
	var serial := _games_serial
	_games_serial = -1
	if serial < 0:
		return
	var answer := _parse(result, code, body)
	if answer.has("error"):
		games_failed.emit(serial, answer["error"])
		return
	var games: Array = []
	var raw: Variant = answer["data"].get("games")
	if raw is Array:
		for g: Variant in raw:
			if not g is Dictionary:
				continue
			var url := str(g.get("url", ""))
			var target := ButlerTool.target_from_url(url)
			if target.is_empty():
				continue
			# An animated cover comes with a still frame; Godot cannot load GIFs.
			var cover: Variant = g.get("still_cover_url")
			if not cover is String:
				cover = g.get("cover_url")
			games.append({
				"title": str(g.get("title", target)),
				"target": target,
				"url": url,
				"published": g.get("published", false) == true,
				"id": str(g.get("id", "")),
				"cover_url": cover if cover is String else "",
			})
	games.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["title"]).naturalnocasecmp_to(b["title"]) < 0)
	games_ready.emit(serial, games)


static func cover_cache_path(game_id: String) -> String:
	return COVER_CACHE_DIR.path_join(game_id + ".img")


## Shows the cover of [param game] (an entry of [signal games_ready]) from the
## cache, or downloads it when there is none or [param force] is set. Only the
## latest request is answered.
func fetch_cover(game: Dictionary, force: bool) -> void:
	if _cover_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_cover_http.cancel_request()
	_cover_game = {}
	var target := str(game.get("target", ""))
	var game_id := str(game.get("id", ""))
	var url := str(game.get("cover_url", ""))
	if not force and not game_id.is_empty() and FileAccess.file_exists(cover_cache_path(game_id)):
		var cached := _decode(FileAccess.get_file_as_bytes(cover_cache_path(game_id)))
		if cached != null:
			cover_ready.emit.call_deferred(target, ImageTexture.create_from_image(cached))
			return
	if url.is_empty() or game_id.is_empty():
		cover_failed.emit.call_deferred(target, "the game has no cover image on itch.io")
		return
	_cover_game = game
	if _cover_http.request(url) != OK:
		_cover_game = {}
		cover_failed.emit.call_deferred(target, "request failed")


func _on_cover_completed(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray) -> void:
	var game := _cover_game
	_cover_game = {}
	if game.is_empty():
		return
	var target := str(game["target"])
	if result != HTTPRequest.RESULT_SUCCESS:
		cover_failed.emit(target, KnownIssues.http_result_text(result))
		return
	if code != 200:
		cover_failed.emit(target, "itch.io answered HTTP %d" % code)
		return
	var img := _decode(body)
	if img == null:
		cover_failed.emit(target, "the cover image could not be read")
		return
	DirAccess.make_dir_recursive_absolute(COVER_CACHE_DIR)
	var f := FileAccess.open(cover_cache_path(str(game["id"])), FileAccess.WRITE)
	if f != null:
		f.store_buffer(body)
		f.close()
	cover_ready.emit(target, ImageTexture.create_from_image(img))


## { "data": Dictionary } for a good JSON answer, or { "error": String,
## "unauthorized": bool } with a plain-words reason.
static func _parse(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"error": KnownIssues.http_result_text(result)}
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	var errors: Variant = data.get("errors") if data is Dictionary else null
	if code in [401, 403] or (errors is Array and "invalid key" in errors):
		return {"error": "itch.io did not accept the API key", "unauthorized": true}
	if code != 200:
		return {"error": "itch.io answered HTTP %d" % code}
	if not data is Dictionary:
		return {"error": "itch.io sent an answer that could not be read"}
	if errors is Array and not errors.is_empty():
		return {"error": "itch.io said: %s" % ", ".join(PackedStringArray(errors))}
	return {"data": data}


## JPEG / PNG / WebP avatars (a GIF avatar is skipped: Godot cannot load it).
static func _decode(bytes: PackedByteArray) -> Image:
	return preload("res://features/main_window/steam_profile.gd").decode_image(bytes)
