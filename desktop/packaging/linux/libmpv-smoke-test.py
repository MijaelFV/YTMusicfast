#!/usr/bin/env python3
"""Checks a packaged libmpv works where it's going to run: it loads with every library it needs,
streams over HTTPS, has the decoders YouTube's audio and video need, and plays a file.

    python3 libmpv-smoke-test.py LIB_DIR

LIB_DIR holds libmpv.so.2 and the libavcodec it uses (the AppImage's usr/lib, or the Flatpak's
/app/lib). Audio and video go to mpv's null outputs, so no sound card or display is needed.
"""

import ctypes
import math
import os
import struct
import sys
import tempfile
import wave

lib_dir = sys.argv[1]
mpv = ctypes.CDLL(os.path.join(lib_dir, "libmpv.so.2"))
version = mpv.mpv_client_api_version()
print(f"libmpv client API {version >> 16}.{version & 0xFFFF}")
assert version >> 16 == 2, "the app needs client API 2.x"

c_void_p, c_char_p = ctypes.c_void_p, ctypes.c_char_p
mpv.mpv_create.restype = c_void_p
mpv.mpv_set_option_string.argtypes = [c_void_p, c_char_p, c_char_p]
mpv.mpv_initialize.argtypes = [c_void_p]
mpv.mpv_command.argtypes = [c_void_p, ctypes.POINTER(c_char_p)]
mpv.mpv_get_property_string.argtypes = [c_void_p, c_char_p]
mpv.mpv_get_property_string.restype = c_void_p
mpv.mpv_free.argtypes = [c_void_p]
mpv.mpv_terminate_destroy.argtypes = [c_void_p]
mpv.mpv_error_string.restype = c_char_p


class Event(ctypes.Structure):
    _fields_ = [("event_id", ctypes.c_int), ("error", ctypes.c_int), ("reply_userdata", ctypes.c_uint64), ("data", c_void_p)]


class EndFile(ctypes.Structure):
    _fields_ = [("reason", ctypes.c_int), ("error", ctypes.c_int)]


mpv.mpv_wait_event.argtypes = [c_void_p, ctypes.c_double]
mpv.mpv_wait_event.restype = ctypes.POINTER(Event)
START_FILE, END_FILE, FILE_LOADED = 6, 7, 8
END_FILE_EOF = 0


def check(status, what):
    assert status >= 0, f"{what}: {mpv.mpv_error_string(status).decode()}"


handle = mpv.mpv_create()
assert handle, "mpv_create failed"
for name, value in [("vo", "null"), ("ao", "null"), ("terminal", "no"), ("idle", "no")]:
    check(mpv.mpv_set_option_string(handle, name.encode(), value.encode()), f"set {name}")
check(mpv.mpv_initialize(handle), "mpv_initialize")

raw = mpv.mpv_get_property_string(handle, b"protocol-list")
assert raw, "no protocol-list property"
protocols = ctypes.string_at(raw).decode().split(",")
mpv.mpv_free(raw)
assert "https" in protocols, f"no HTTPS streaming (protocols: {protocols})"
print("HTTPS streaming: yes")

# The decoders YouTube Music needs: Opus and AAC audio, VP9, AV1 and H.264 video.
avcodec = next(
    (ctypes.CDLL(os.path.join(lib_dir, name)) for name in sorted(os.listdir(lib_dir)) if name.startswith("libavcodec.so.")),
    None,
)
assert avcodec, f"no libavcodec in {lib_dir}"
avcodec.avcodec_find_decoder_by_name.argtypes = [c_char_p]
avcodec.avcodec_find_decoder_by_name.restype = c_void_p
missing = [d for d in ("opus", "aac", "vp9", "h264") if not avcodec.avcodec_find_decoder_by_name(d.encode())]
if not any(avcodec.avcodec_find_decoder_by_name(d) for d in (b"libdav1d", b"av1")):
    missing.append("av1")
assert not missing, f"missing decoders: {missing}"
print("Decoders: opus, aac, vp9, av1, h264")

# Play one second of a 440 Hz tone to the end.
with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as file:
    path = file.name
with wave.open(path, "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(48000)
    out.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(48000)))
args = (c_char_p * 3)(b"loadfile", path.encode(), None)
check(mpv.mpv_command(handle, args), "loadfile")
seen = set()
while True:
    event = mpv.mpv_wait_event(handle, 10).contents
    assert event.event_id != 0, "timed out waiting for playback to finish"
    seen.add(event.event_id)
    if event.event_id == END_FILE:
        end = ctypes.cast(event.data, ctypes.POINTER(EndFile)).contents
        assert end.reason == END_FILE_EOF, f"playback ended with reason {end.reason}, error {end.error}"
        break
assert FILE_LOADED in seen, "the file never loaded"
print("Played a test tone to the end")
mpv.mpv_terminate_destroy(handle)
os.unlink(path)
print("libmpv works")
