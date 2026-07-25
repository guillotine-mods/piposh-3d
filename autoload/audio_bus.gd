extends Node
## Plays WAV from converted SFX (case-insensitive).

signal sfx_finished

const SFX_RES := "res://assets/converted/sfx/"

var _player: AudioStreamPlayer
var _music: AudioStreamPlayer
var _index: Dictionary = {}  # lower filename -> res path
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
	var dir := DirAccess.open(SFX_RES)
	if dir == null:
		return
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
			if ResourceLoader.exists(path):
				return load(path) as AudioStream
	# Direct path fallback (DirAccess can miss freshly copied files)
	var exts: Array[String] = [".wav", ".WAV", ".ogg"]
	for ext in exts:
		var direct: String = SFX_RES + stem + ext
		if ResourceLoader.exists(direct):
			_index[stem] = direct
			_index[stem + ".wav"] = direct
			return load(direct) as AudioStream
	# Retry after rebuild (new files copied while editor open)
	_rebuild_index()
	for key in candidates:
		if _index.has(key):
			var path2: String = _index[key]
			if ResourceLoader.exists(path2):
				return load(path2) as AudioStream
	push_warning("SFX missing: %s" % name)
	return null
