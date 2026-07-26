extends Node
## Plays WAV from converted SFX (case-insensitive).
## Export-safe: uses sfx_index.json because DirAccess often cannot list PCK folders.

signal sfx_finished

const SFX_RES := "res://assets/converted/sfx/"
const SFX_INDEX := "res://assets/converted/sfx/sfx_index.json"

var _player: AudioStreamPlayer
var _music: AudioStreamPlayer
var _index: Dictionary = {}  # lower filename / stem -> res path
var _voice_busy := false


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "SFX"
	_player.finished.connect(_on_sfx_finished)
	add_child(_player)
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	add_child(_music)
	_rebuild_index()


func play_sfx(name: String, volume_db: float = 0.0) -> void:
	var stream := _load_stream(name)
	if stream == null:
		_voice_busy = false
		sfx_finished.emit()
		return
	_voice_busy = true
	_player.stream = stream
	_player.volume_db = volume_db
	_player.play()


func is_voice_playing() -> bool:
	return _voice_busy and _player.playing


func play_music(name: String, volume_db: float = -6.0) -> void:
	var stream := _load_stream(name)
	if stream == null:
		return
	_enable_loop(stream)
	_music.stream = stream
	_music.volume_db = volume_db
	_music.play()


func stop_music() -> void:
	_music.stop()


func is_music_playing() -> bool:
	return _music != null and _music.playing


func _enable_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true


func stop_sfx() -> void:
	_player.stop()
	_voice_busy = false


func _on_sfx_finished() -> void:
	_voice_busy = false
	sfx_finished.emit()


func rebuild_index() -> void:
	_rebuild_index()


func _rebuild_index() -> void:
	_index.clear()
	# 1) Packed JSON index (required for EXE/APK — DirAccess list is unreliable).
	if ResourceLoader.exists(SFX_INDEX) or FileAccess.file_exists(SFX_INDEX):
		var f := FileAccess.open(SFX_INDEX, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			if typeof(data) == TYPE_DICTIONARY:
				var files: Array = data.get("files", [])
				for fn in files:
					var name := str(fn)
					var lower := name.to_lower()
					var path := SFX_RES + name
					_index[lower] = path
					_index[lower.get_basename()] = path
	# 2) DirAccess fallback (editor / when index missing).
	var dir := DirAccess.open(SFX_RES)
	if dir:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if not dir.current_is_dir():
				var lower := fn.to_lower()
				if lower.ends_with(".wav") or lower.ends_with(".ogg"):
					_index[lower] = SFX_RES + fn
					_index[lower.get_basename()] = SFX_RES + fn
			fn = dir.get_next()


func _load_stream(name: String) -> AudioStream:
	if _index.is_empty():
		_rebuild_index()
	var base := name.get_file().to_lower()
	var stem := base.get_basename()
	var candidates := [
		base,
		stem,
		stem + ".wav",
		stem + ".ogg",
	]
	for key in candidates:
		if _index.has(key):
			var path: String = _index[key]
			var stream := _try_load(path)
			if stream:
				return stream
	# Direct path fallback (case variants) — works when index misses a file.
	var exts: Array[String] = [".wav", ".WAV", ".ogg", ".OGG"]
	var stems: Array[String] = [stem, stem.to_upper(), stem.to_lower()]
	# Preserve common Acknex mixed case (Pip001 already lowercased).
	for s in stems:
		for ext in exts:
			var direct: String = SFX_RES + s + ext
			var stream2 := _try_load(direct)
			if stream2:
				_index[stem] = direct
				_index[stem + ".wav"] = direct
				return stream2
	_rebuild_index()
	for key in candidates:
		if _index.has(key):
			var stream3 := _try_load(str(_index[key]))
			if stream3:
				return stream3
	push_warning("SFX missing: %s (index=%d)" % [name, _index.size()])
	return null


func _try_load(path: String) -> AudioStream:
	if path == "":
		return null
	if ResourceLoader.exists(path):
		var s = load(path)
		if s is AudioStream:
			return s as AudioStream
	if FileAccess.file_exists(path):
		var s2 = load(path)
		if s2 is AudioStream:
			return s2 as AudioStream
	return null
