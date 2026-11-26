extends Node
class_name WorldsmithVoiceCapture

signal transcript_ready(value: String)
signal status_changed(message: String, recording: bool)

const MAX_SECONDS := 12.0

var recording := false
var uploading := false
var sample_rate := 0
var samples := PackedByteArray()
var sample_count := 0
var server_url := ""
var request: HTTPRequest


func _ready() -> void:
	request = HTTPRequest.new()
	request.timeout = 90.0
	add_child(request)
	request.request_completed.connect(_on_request_completed)


func toggle(endpoint: String) -> void:
	if recording:
		_finish_recording()
	elif not uploading:
		_start_recording(endpoint)


func cancel() -> void:
	if recording:
		AudioServer.set_input_device_active(false)
		recording = false
		samples.clear()
	if uploading:
		request.cancel_request()
		uploading = false


func _exit_tree() -> void:
	cancel()


func _start_recording(endpoint: String) -> void:
	if OS.has_feature("android") and not OS.request_permission("android.permission.RECORD_AUDIO"):
		status_changed.emit("Allow microphone access, then tap VOICE again", false)
		return
	var result := AudioServer.set_input_device_active(true)
	if result != OK:
		status_changed.emit("Microphone unavailable (%d)" % result, false)
		return
	sample_rate = int(AudioServer.get_input_mix_rate())
	if sample_rate < 8000 or sample_rate > 48000:
		AudioServer.set_input_device_active(false)
		status_changed.emit("Unsupported microphone sample rate", false)
		return
	server_url = endpoint.replace("ws://", "http://").replace("wss://", "https://")
	sample_count = 0
	samples.resize(int(sample_rate * MAX_SECONDS) * 2)
	recording = true
	status_changed.emit("Recording… tap VOICE to finish", true)


func _process(_delta: float) -> void:
	if not recording:
		return
	var available := AudioServer.get_input_frames_available()
	if available <= 0:
		return
	var room := samples.size() / 2 - sample_count
	var frames := AudioServer.get_input_frames(mini(available, room))
	for frame in frames:
		var sample := clampi(roundi((frame.x + frame.y) * 16383.5), -32768, 32767)
		samples.encode_s16(sample_count * 2, sample)
		sample_count += 1
	if sample_count >= samples.size() / 2:
		_finish_recording()


func _finish_recording() -> void:
	AudioServer.set_input_device_active(false)
	recording = false
	if sample_count < sample_rate / 4:
		status_changed.emit("Recording too short; try again", false)
		return
	var pcm := samples.slice(0, sample_count * 2)
	samples.clear()
	var wav := PackedByteArray()
	wav.resize(44)
	_write_ascii(wav, 0, "RIFF")
	wav.encode_u32(4, 36 + pcm.size())
	_write_ascii(wav, 8, "WAVEfmt ")
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)
	wav.encode_u16(22, 1)
	wav.encode_u32(24, sample_rate)
	wav.encode_u32(28, sample_rate * 2)
	wav.encode_u16(32, 2)
	wav.encode_u16(34, 16)
	_write_ascii(wav, 36, "data")
	wav.encode_u32(40, pcm.size())
	wav.append_array(pcm)
	uploading = true
	status_changed.emit("Transcribing on Mac…", false)
	var error := request.request_raw(server_url + "/api/transcribe", ["Content-Type: audio/wav"], HTTPClient.METHOD_POST, wav)
	if error != OK:
		uploading = false
		status_changed.emit("Could not send recording to Mac (%d)" % error, false)


func _write_ascii(bytes: PackedByteArray, offset: int, value: String) -> void:
	var encoded := value.to_ascii_buffer()
	for index in range(encoded.size()):
		bytes[offset + index] = encoded[index]


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	uploading = false
	if result != HTTPRequest.RESULT_SUCCESS:
		status_changed.emit("Transcription connection failed (%d)" % result, false)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		status_changed.emit("Invalid transcription response", false)
		return
	if code != 200:
		status_changed.emit("Voice error: " + str(parsed.get("detail", "HTTP %d" % code)), false)
		return
	var transcript := str(parsed.get("text", "")).strip_edges()
	if transcript.is_empty():
		status_changed.emit("No speech detected; try again", false)
		return
	transcript_ready.emit(transcript)
	status_changed.emit("Review the text, then SEND", false)
