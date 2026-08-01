extends Node
## Plays WAV from converted SFX (case-insensitive). Export-safe: uses
## sfx_index.json because DirAccess often cannot list PCK folders.
##
## Replaces autoload/audio_bus.gd, which gave dialogue (Voice) and every
## other sound (ambient/entity SFX) the SAME AudioStreamPlayer and the SAME
## _voice_busy/_voice_finished flag pair. That meant any unrelated SFX call
## -- an ambiance loop, a footstep, a hammer sound -- could stomp on
## GetPosition(Voice)'s timing state and corrupt dialogue that had nothing
## to do with it. Confirmed as the root cause of a "no audio" / dialogue
## racing to completion report (docs/CONTRACT.md §5, docs/SESSION_LOG.md
## 2026-07-30): Plane2's ambiance loop called play_entsound() every tick,
## which force-cleared the shared "voice finished" flag and made every
## GetPosition(Voice) wait in the game resolve instantly.
##
## Three independent channels, matching how this corpus actually uses sound:
## - Voice: sPlay/vPlay only (dialogue lines). GetPosition(Voice) reads
##   this channel's state.
## - SFX: play_sound/play_entsound (ambient, one-shot, entity sounds). A
##   small round-robin pool so overlapping SFX doesn't cut itself off.
##   `snd_playing(handle)` -- the standard WDL "is my ambiance loop still
##   playing, or do I need to restart it" idiom (`if (snd_playing(X)==0) {
##   play_sound(...); X=result; }`, used corpus-wide, not level-specific) --
##   polls a *specific* handle returned by play_sfx(), not global state.
## - Music: unchanged, already its own player.

signal voice_finished

const SFX_RES := "res://assets/converted/sfx/"
const SFX_INDEX := "res://assets/converted/sfx/sfx_index.json"
const SFX_POOL_SIZE := 6
## Handles are `slot * HANDLE_SLOT_SCALE + generation`, so a stale handle
## from a pool slot that's since been reused for a different sound reads as
## "not playing" instead of a false positive.
const HANDLE_SLOT_SCALE := 1000000

var _voice: AudioStreamPlayer
var _music: AudioStreamPlayer
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_generation: Array[int] = []
var _sfx_next := 0
var _index: Dictionary = {}  # lower filename / stem -> res path

var _voice_busy := false
## True once the current/most-recent line has finished (naturally or via
## stop/skip). Starts true (nothing played yet). See get_voice_progress().
var _voice_finished := true
## Bumped on every play_voice() call. Lets WdlInterpreter tell "this
## specific line's completion" apart from "voice has been sitting finished
## for a while" per-caller, instead of a single frame-global flag -- see
## WdlInterpreter._do_get_voice_position()'s comment for why a global flag
## starves any coroutine that isn't first to poll on a given frame.
var _voice_generation := 0


func _ready() -> void:
	_voice = AudioStreamPlayer.new()
	_voice.name = "Voice"
	_voice.finished.connect(_on_voice_finished)
	add_child(_voice)

	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	add_child(_music)

	for i in SFX_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "SFX%d" % i
		add_child(p)
		_sfx_pool.append(p)
		_sfx_generation.append(0)

	_rebuild_index()


## sPlay(Voice, snd) / vPlay -- dialogue lines. Only this channel feeds
## GetPosition(Voice).
func play_voice(name: String, volume_db: float = 0.0) -> void:
	_voice_generation += 1
	var stream := _load_stream(name)
	if stream == null:
		_voice_busy = false
		_voice_finished = true
		voice_finished.emit()
		return
	_voice_busy = true
	_voice_finished = false
	_voice.stream = stream
	_voice.volume_db = volume_db
	_voice.play()


## See _voice_generation.
func get_voice_generation() -> int:
	return _voice_generation


func is_voice_playing() -> bool:
	return _voice_busy and _voice.playing


## Acknex `GetPosition(Voice)` is a 0..1,000,000 fraction of the clip played
## so far. See autoload/audio_bus.gd history (docs/SESSION_LOG.md
## 2026-07-29) for why this must report 1.0 once a line has finished rather
## than 0.0 whenever nothing is *currently* playing.
func get_voice_progress() -> float:
	if _voice_finished:
		return 1.0
	if not is_voice_playing() or _voice.stream == null:
		return 0.0
	var stream_len := _voice.stream.get_length()
	if stream_len <= 0.0:
		return 0.0
	return clampf(_voice.get_playback_position() / stream_len, 0.0, 1.0)


func stop_voice() -> void:
	_voice.stop()
	_voice_busy = false
	_voice_finished = true  # explicit stop/skip counts as "line done" too


func _on_voice_finished() -> void:
	_voice_busy = false
	_voice_finished = true
	voice_finished.emit()


## play_sound / play_entsound -- ambient/one-shot/entity SFX. Never touches
## Voice state. Prefers a genuinely free (not currently playing) slot;
## only falls back to blind round-robin eviction when every slot is busy
## -- cheap insurance against the same slot-theft-mid-playback class of
## bug as the real one found below, even though it wasn't the actual
## cause that time. Returns a handle for is_sfx_handle_playing()/
## snd_playing() -- -1.0 if the stream couldn't be loaded.
##
## Reported live (2026-08-01, Shiks): "a weird noise that plays in the
## background non stop." Root cause was NOT this pool at all: a leftover
## hand-ported branch in wdl_director.gd's setup() *also* called
## play_music() on SFX100.WAV/SFX140.WAV for the same WaterWheel/Watrfall
## entities Shiks.wdl's own interpreter-driven actions already loop via
## this function (play_entsound + snd_playing) -- a genuine duplicate
## implementation, since removed. play_music() -> _enable_loop() mutates
## the loaded AudioStream *resource* (shared/cached by path across every
## player using it, SFX pool included) and was setting `loop_mode` without
## `loop_end`, leaving it at its default of 0 -- a degenerate zero-length
## loop region. Once that ran, the SFX pool's own later playback of the
## same file could no longer sustain `.playing == true` for its natural
## duration, so `snd_playing()` read false almost immediately and the
## WDL ambiance loop retriggered up to ~140x/sec instead of once per
## ~3s (confirmed via a temporary per-call log: 1679 play_sfx calls in a
## 12s real-time run, vs ~22 expected). Fixed at both ends: the duplicate
## caller removed, and _enable_loop() now sets a real loop_end so any
## future play_music() caller can't corrupt a shared stream this way
## again.
func play_sfx(name: String, volume_db: float = 0.0) -> float:
	var stream := _load_stream(name)
	if stream == null:
		return -1.0
	var slot := _sfx_next
	for i in _sfx_pool.size():
		if not _sfx_pool[i].playing:
			slot = i
			break
	_sfx_next = (slot + 1) % _sfx_pool.size()
	_sfx_generation[slot] += 1
	var p := _sfx_pool[slot]
	p.stream = stream
	p.volume_db = volume_db
	p.play()
	return float(slot) * HANDLE_SLOT_SCALE + float(_sfx_generation[slot])


## `snd_playing(handle)` -- WDL's per-sound polling idiom (see file header).
## A handle from a pool slot since reused for a different sound reads as
## "not playing" (generation mismatch), not a false positive.
func is_sfx_handle_playing(handle: float) -> bool:
	if handle < 0.0:
		return false
	var slot := int(handle / HANDLE_SLOT_SCALE)
	var gen := int(handle) % HANDLE_SLOT_SCALE
	if slot < 0 or slot >= _sfx_pool.size():
		return false
	if _sfx_generation[slot] != gen:
		return false
	return _sfx_pool[slot].playing


## `stop_sound(handle)` -- WDL's per-sound stop idiom, same handle scheme as
## snd_playing(). Corpus-wide (confirmed via grep across every .wdl file
## that calls it), always called with a handle from a prior play_sound/
## play_entsound, never bare -- stopping the whole shared Voice channel
## instead was a real bug (same class as the earlier snd_playing fix): a
## level's own ambient-SFX stop call (e.g. Start.wdl's `stop_sound
## (my.skill40)` when a crowd-noise loop should end) was silently cutting
## off unrelated dialogue every time it ran instead. Stale/mismatched
## handles are silently ignored, matching is_sfx_handle_playing()'s
## generation check.
func stop_sfx_handle(handle: float) -> void:
	if handle < 0.0:
		return
	var slot := int(handle / HANDLE_SLOT_SCALE)
	var gen := int(handle) % HANDLE_SLOT_SCALE
	if slot < 0 or slot >= _sfx_pool.size():
		return
	if _sfx_generation[slot] != gen:
		return
	_sfx_pool[slot].stop()


func stop_all_sfx() -> void:
	for p in _sfx_pool:
		p.stop()


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


## Mutates the loaded AudioStream resource itself, not per-player state --
## `load()` caches and shares one Resource instance per path, so this
## affects every OTHER AudioStreamPlayer using the same stream too (e.g.
## the SFX pool, if anything else ever plays the same file). Setting only
## `loop_mode` without `loop_end` left it at its default of 0, producing a
## degenerate zero-length loop region (loop from frame 0 to frame 0) --
## found chasing a 2026-08-01 "weird noise, plays non-stop" report in
## Shiks: wdl_director.gd used to *also* call play_music() on SFX100.WAV/
## SFX140.WAV (a redundant duplicate of what Watrfall/WaterWheel's own
## interpreter-driven actions already do via play_entsound/snd_playing --
## removed as dead code), and once that call corrupted the shared
## AudioStreamWAV resource's loop region, the SFX pool's own later
## playback of the same file could no longer sustain `.playing == true`
## for its natural duration, retriggering up to ~140x/sec instead of once
## per ~3s. Setting `loop_end` to the actual sample count keeps this
## correct for any current or future legitimate play_music() caller.
func _enable_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		# PCM only (this corpus's converted SFX are all 8-bit mono/stereo
		# PCM, never IMA_ADPCM/QOA) -- bytes-per-sample from `format`
		# (FORMAT_8_BITS=0 -> 1 byte, FORMAT_16_BITS=1 -> 2 bytes) times
		# channel count. Falls back to the raw byte count (still better
		# than the previous always-0 default) for a compressed format.
		if wav.format == AudioStreamWAV.FORMAT_8_BITS or wav.format == AudioStreamWAV.FORMAT_16_BITS:
			var bytes_per_sample := 2 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 1
			var channels := 2 if wav.stereo else 1
			wav.loop_end = wav.data.size() / (bytes_per_sample * channels)
		else:
			wav.loop_end = wav.data.size()
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true


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
