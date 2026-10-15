#!/usr/bin/env python3
"""Playback stress test for a Debug build of YT Musicfast, driven through its `ytmusicfast` tool.

Runs the hard cases of local playback — rapid skips, pause and seek while a song loads, skips
during a crossfade, Song/Video switches mid-skip, repeat one, the end of the queue while radio
extends, Offline Mode toggles and output device changes — and after each step checks the song,
play state and position the app reports (`ytmusicfast debug-state`, Debug builds only).

    scripts/playback-stress.py [--app path/to/YT\\ Musicfast.app] [--runs N] [--only name,...]

Plays music (at a low volume) for about ten minutes per run and needs the network. Settings it
changes are put back at the end. Exit status 0 when every run passes.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_APP = os.path.join(ROOT, "build/Build/Products/Debug/YT Musicfast.app")

# Slow connections take a while to start a song; nothing here should take longer than this.
SETTLE = 60
QUERIES = ["Tame Impala The Less I Know The Better", "Daft Punk Get Lucky", "Arctic Monkeys Do I Wanna Know",
           "Gorillaz Feel Good Inc", "The Strokes Reptilia"]


class Failure(Exception):
    pass


class App:
    def __init__(self, path):
        self.path = path
        self.tool = os.path.join(path, "Contents/Helpers/ytmusicfast")
        self.log = []

    def run(self, *args, check=True, timeout=40):
        started = time.time()
        result = subprocess.run([self.tool, *args], capture_output=True, text=True, timeout=timeout)
        line = f"{time.strftime('%H:%M:%S')} {' '.join(args)} -> {result.returncode} ({int((time.time() - started) * 1000)} ms)"
        if args[0] == "debug-state" and result.returncode == 0:
            # Only when it changes: the song, its state, and whether it's loading or switching.
            try:
                s = json.loads(result.stdout)
                line = (f"{time.strftime('%H:%M:%S')}   state: #{s['index']} {s['videoId']} {'video' if s['isVideo'] else 'song'} "
                        f"{'playing' if s['playing'] else 'paused'} {s['timeControl']}{' loading' if s['loading'] else ''}"
                        f"{' switching→' + s['versionTarget'] if s['versionTarget'] else ''}{' crossfading' if s['crossfading'] else ''}"
                        f"{' no-item' if not s['hasItem'] else '' if s['itemMatchesEntry'] else ' ITEM-MISMATCH'} items={s['deckItems']}")
            except (ValueError, KeyError):
                pass
            if self.log and self.log[-1].split(" ", 1)[1] == line.split(" ", 1)[1]:
                return result.stdout.strip()
        self.log.append(line)
        if check and result.returncode != 0:
            raise Failure(f"`ytmusicfast {' '.join(args)}` failed: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout.strip()

    def state(self):
        return json.loads(self.run("debug-state"))

    def set(self, name, value):
        self.run("debug-set", name, str(value))


def describe(s):
    keys = ["index", "queueCount", "videoId", "title", "isVideo", "playing", "buffering", "loading", "timeControl",
            "hasItem", "itemMatchesEntry", "position", "shownPosition", "duration", "crossfading", "versionTarget",
            "videoMode", "offlineMode", "advanceWhenExtended", "extending", "error"]
    return ", ".join(f"{k}={s.get(k)!r}" for k in keys)


def wait_until(app, what, predicate, timeout=SETTLE, interval=0.25):
    """Polls the app's state until `predicate` holds; fails with the last state seen."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = app.state()
        if predicate(last):
            return last
        time.sleep(interval)
    raise Failure(f"timed out after {timeout}s waiting for {what}\n    last state: {describe(last)}")


def settled(playing):
    """Loaded and in the expected state: the player's item is the queue's current entry, nothing
    is still loading or switching, and play state as expected."""
    def check(s):
        return (not s["loading"] and s["hasItem"] and s["itemMatchesEntry"] and s["versionTarget"] == ""
                and s["playing"] == playing
                and (s["timeControl"] == "playing" if playing else s["timeControl"] == "paused"))
    return check


def expect(condition, message, s=None):
    if not condition:
        raise Failure(message + (f"\n    state: {describe(s)}" if s else ""))


def settle(app, index=None, playing=True, what="the song to settle"):
    s = wait_until(app, what + (f" (index {index}, {'playing' if playing else 'paused'})" if index is not None else ""),
                   lambda s: settled(playing)(s) and (index is None or s["index"] == index))
    if playing:
        s = advancing(app)
    return s


def advancing(app):
    """The position moves on (playing for real, not stuck) and what's shown follows it."""
    first = app.state()
    def moved(s):
        return s["videoId"] == first["videoId"] and s["position"] - first["position"] >= 0.5
    s = wait_until(app, "the position to advance", moved, timeout=30, interval=0.5)
    expect(abs(s["shownPosition"] - s["position"]) < 2.5, "shown position is off from the player's", s)
    return s


def still(app, s0, seconds=2.0):
    """Paused for real: the position doesn't move."""
    time.sleep(seconds)
    s = app.state()
    expect(not s["playing"] and abs(s["position"] - s0["position"]) < 0.3 and s["index"] == s0["index"],
           "paused song kept going (or changed)", s)
    return s


def play_search(app):
    """Starts a song's radio; returns the index it plays at (0, unless it was already playing:
    then it goes on where it is and the radio follows it)."""
    query = random.choice([q for q in QUERIES if q != getattr(app, "last_query", None)])
    app.last_query = query
    app.run("play-search", query)
    return app.state()["index"]


def start_fresh(app):
    index = play_search(app)
    wait_until(app, "the radio", lambda s: s["queueCount"] > index + 8 and not s["extending"])
    return settle(app, index=index)


def soon(app, what, predicate):
    """Shown at once — within the 50 ms fade a skip or pause makes, plus the tool's round trip."""
    return wait_until(app, what, predicate, timeout=1, interval=0.05)


# MARK: Scenarios

def rapid_skips(app):
    start_fresh(app)
    for burst in [5, 3]:
        i0 = app.state()["index"]
        for _ in range(burst):
            app.run("next")
        soon(app, f"{burst} quick nexts from {i0} to land on {i0 + burst} at once", lambda s: s["index"] == i0 + burst)
        settle(app, index=i0 + burst)
    # Back: from the start of a song each previous is a song back.
    i0 = app.state()["index"]
    app.run("seek-to", "0")
    for _ in range(3):
        app.run("previous")
    soon(app, f"3 quick previous from {i0} to land on {i0 - 3}", lambda s: s["index"] == i0 - 3)
    settle(app, index=i0 - 3)
    # Mixed, as fast as possible.
    i0 = app.state()["index"]
    for command in ["next", "next", "previous", "next", "next"]:
        app.run(command)
    settle(app, index=i0 + 3)
    # Previous further than 3 s into a song restarts it.
    app.run("seek-to", "20")
    wait_until(app, "seek to 20", lambda s: s["position"] >= 19.5)
    i0 = app.state()["index"]
    app.run("previous")
    s = settle(app, index=i0)
    expect(s["position"] < 5, "previous after 3 s should restart the song", s)


def pause_and_seek_while_loading(app):
    settle(app)
    # Pause right after a skip: it loads, but stays paused (shown at once).
    i0 = app.state()["index"]
    app.run("next")
    app.run("pause")
    soon(app, "pause right after a skip to show paused at once", lambda s: not s["playing"] and s["index"] == i0 + 1)
    s = settle(app, index=i0 + 1, playing=False)
    still(app, s)
    app.run("play")
    settle(app, index=i0 + 1)

    # Seek right after a skip: it starts from there.
    app.run("next")
    app.run("seek-to", "30")
    s = settle(app, index=i0 + 2)
    expect(29 <= s["position"] <= 45, "seek while loading should start the song from there", s)

    # Pause, seek, play, all while loading.
    app.run("next")
    app.run("pause")
    app.run("seek-to", "45")
    app.run("play")
    s = settle(app, index=i0 + 3)
    expect(44 <= s["position"] <= 60, "seek while loading (paused, then played) should start from there", s)

    # Pause and play again while loading: one load, playing.
    app.run("next")
    app.run("play-pause")
    app.run("play-pause")
    soon(app, "pause then play while loading to show playing", lambda s: s["playing"])
    settle(app, index=i0 + 4)

    # Skip while paused: the next song plays.
    app.run("pause")
    s = settle(app, playing=False)
    app.run("next")
    settle(app, index=i0 + 5)

    # A plain seek while playing, then back.
    app.run("seek-to", "60")
    s = wait_until(app, "seek to 60", lambda s: 59.5 <= s["position"] <= 70)
    app.run("seek", "--", "-10")
    wait_until(app, "seek back 10 s", lambda s: 49.5 <= s["position"] <= 60)

    # Fast play/pause presses while playing: an odd number ends paused.
    for _ in range(5):
        app.run("play-pause")
    s = settle(app, playing=False)
    still(app, s)
    app.run("play")
    settle(app)


def near_end(app, seconds_left):
    s = app.state()
    expect(s["duration"] > 40, "song too short to test its end", s)
    app.run("seek-to", str(int(s["duration"] - seconds_left)))
    return s


def crossfade(app):
    app.set("crossfade", 6)
    try:
        s = settle(app)
        # Wait for the next song to be queued (crossfade needs it), then go near the end.
        wait_until(app, "next song queued", lambda s: s["deckItems"] > 1 or s["crossfading"], timeout=SETTLE)
        i0 = app.state()["index"]
        near_end(app, 9)
        s = wait_until(app, "crossfade to start", lambda s: s["crossfading"], timeout=20)
        expect(s["index"] == i0 + 1, "crossfade should move to the next song", s)
        # Next during the fade: skips from the incoming song.
        app.run("next")
        soon(app, "next during a crossfade to land two on", lambda s: not s["crossfading"] and s["index"] == i0 + 2)
        settle(app, index=i0 + 2)

        # Pause during the fade: everything stops.
        wait_until(app, "next song queued", lambda s: s["deckItems"] > 1, timeout=SETTLE)
        i0 = app.state()["index"]
        near_end(app, 9)
        wait_until(app, "crossfade to start", lambda s: s["crossfading"], timeout=20)
        app.run("pause")
        s = settle(app, index=i0 + 1, playing=False)
        expect(not s["crossfading"], "pause should end the crossfade", s)
        still(app, s)
        app.run("play")
        settle(app, index=i0 + 1)

        # Previous during the fade: back to the song that was fading out.
        wait_until(app, "next song queued", lambda s: s["deckItems"] > 1, timeout=SETTLE)
        i0 = app.state()["index"]
        near_end(app, 9)
        wait_until(app, "crossfade to start", lambda s: s["crossfading"], timeout=20)
        app.run("previous")
        settle(app, index=i0)

        # A full crossfade, left alone.
        wait_until(app, "next song queued", lambda s: s["deckItems"] > 1, timeout=SETTLE)
        i0 = app.state()["index"]
        near_end(app, 9)
        wait_until(app, "crossfade to start", lambda s: s["crossfading"], timeout=20)
        s = wait_until(app, "crossfade to finish", lambda s: not s["crossfading"], timeout=15)
        expect(s["index"] == i0 + 1, "after a crossfade the next song plays", s)
        settle(app, index=i0 + 1)
    finally:
        app.set("crossfade", 0)


def video_or_none(app, index):
    """In Video mode the song plays as its video — unless it has none. A song that arrived on its
    own (after a skip) quietly stays a song then; clicking Video on it must play the video, or
    say there's none and turn the mode off."""
    s = settle(app, index=index)
    if s["isVideo"] or not s["videoMode"]:
        return s
    app.set("video", "off")
    app.set("video", "on")
    s = settle(app, index=index)
    expect(s["isVideo"] or not s["videoMode"], "Video clicked on a song should play its video (or turn off when there's none)", s)
    return s


def song_video(app):
    try:
        settle(app)
        # Video on right after a skip (the song still loading).
        i0 = app.state()["index"]
        app.run("next")
        app.set("video", "on")
        video_or_none(app, i0 + 1)
        # The next song follows the mode.
        app.set("video", "on")
        app.run("next")
        video_or_none(app, i0 + 2)

        # Skip right after switching (the switch for the song skipped past has nothing to do).
        app.set("video", "off")
        app.run("next")
        s = settle(app, index=i0 + 3)
        expect(not s["isVideo"] and not s["videoMode"], "song mode after a skip mid-switch", s)

        # Switch back and forth quickly while playing.
        for mode in ["on", "off", "on", "off"]:
            app.set("video", mode)
        s = settle(app, index=i0 + 3)
        expect(not s["isVideo"] and not s["videoMode"], "back and forth ends on the song", s)

        # Switch to the video while playing, then skip.
        app.set("video", "on")
        settle(app, index=i0 + 3)
        app.run("next")
        app.set("video", "off")
        s = settle(app, index=i0 + 4)
        expect(not s["isVideo"], "song mode after switching mid-skip", s)
    finally:
        app.set("video", "off")


def repeat_one(app):
    try:
        settle(app)
        app.run("repeat", "one")
        s = app.state()
        i0 = s["index"]
        video = s["videoId"]
        near_end(app, 4)
        # Plays to its end, then starts over.
        s = wait_until(app, "the song to start over", lambda s: s["position"] < 3 and s["index"] == i0, timeout=20)
        s = settle(app, index=i0)
        expect(s["videoId"] == video, "repeat one should replay the same song", s)
        # Next still moves on.
        app.run("next")
        settle(app, index=i0 + 1)
    finally:
        app.run("repeat", "off")


def end_of_queue(app):
    # Next before the radio has arrived: it moves on once the songs land.
    i0 = play_search(app)
    app.run("next")
    wait_until(app, "radio to land and move on", lambda s: s["index"] == i0 + 1, timeout=SETTLE)
    s = settle(app, index=i0 + 1)
    expect(not s["advanceWhenExtended"], "nothing should still be waiting to advance", s)

    # Next then previous before the radio arrives: it stays. (From a new song: one already
    # playing goes on and previous could go back a song.)
    i0 = play_search(app)
    if i0 != 0:
        i0 = play_search(app)
    app.run("next")
    app.run("previous")
    wait_until(app, "radio to land", lambda s: s["queueCount"] > i0 + 2 and not s["extending"], timeout=SETTLE)
    time.sleep(1)
    s = settle(app, index=i0)
    expect(not s["advanceWhenExtended"], "previous should drop the waiting skip", s)

    # Pause while a skip waits for the radio: the next song starts paused.
    i0 = play_search(app)
    app.run("next")
    app.run("pause")
    wait_until(app, "radio to land", lambda s: s["index"] == i0 + 1, timeout=SETTLE)
    settle(app, index=i0 + 1, playing=False)
    app.run("play")
    settle(app, index=i0 + 1)


def offline_mode(app):
    try:
        s = settle(app)
        i0 = s["index"]
        app.set("offline", "on")
        # What's playing goes on.
        s = settle(app, index=i0)
        expect(s["offlineMode"], "offline mode on", s)
        # Next: an offline song if there is one; with none, nothing happens (nothing is streamed).
        app.run("next")
        time.sleep(1.5)
        s = app.state()
        expect(not s["advanceWhenExtended"], "offline: a skip shouldn't wait for radio", s)
        settle(app, index=s["index"])
        # Quick toggles while playing don't interrupt.
        for mode in ["off", "on", "off", "on", "off"]:
            app.set("offline", mode)
        s = settle(app, index=s["index"])
        # Back online, next streams again.
        i1 = s["index"]
        app.run("next")
        s = wait_until(app, "next after offline mode", lambda s: s["index"] == i1 + 1, timeout=SETTLE)
        settle(app, index=i1 + 1)
    finally:
        app.set("offline", "off")


def output_devices(app):
    devices = json.loads(app.run("devices", "--raw"))
    if len(devices) < 2:
        print("    (one output device: device switches skipped)")
        return
    original = next((d["uid"] for d in devices if d["active"] == "true"), "default")
    uids = [d["uid"] for d in devices]
    try:
        s = settle(app)
        i0 = s["index"]
        for uid in uids + ["default"]:
            app.run("transfer", uid)
            s = settle(app, index=i0)
        # Quick changes.
        for uid in uids * 2:
            app.run("transfer", uid)
        settle(app, index=i0)
        # During a load.
        app.run("next")
        app.run("transfer", uids[0])
        settle(app, index=i0 + 1)
        # While paused: stays paused.
        app.run("pause")
        s = settle(app, playing=False)
        app.run("transfer", uids[-1])
        still(app, s)
        app.run("play")
        settle(app)
    finally:
        app.run("transfer", "default" if original == "default" else original, check=False)


def chaos(app):
    """Random presses with short gaps; the play state follows a simple model: a skip plays, a
    play-pause flips it. Then it must settle where the model says."""
    s = settle(app)
    index, playing = s["index"], True
    rng = random.Random()
    for _ in range(25):
        command = rng.choice(["next", "next", "play-pause", "play-pause", "seek-to"])
        if command == "next":
            app.run("next")
            index += 1
            playing = True
        elif command == "play-pause":
            app.run("play-pause")
            playing = not playing
        else:
            app.run("seek-to", str(rng.randint(0, 60)))
        time.sleep(rng.choice([0, 0, 0.05, 0.2, 0.6, 1.5]))
    s = settle(app, index=index, playing=playing)
    if not playing:
        still(app, s)
        app.run("play")
        settle(app, index=index)


SCENARIOS = [
    ("rapid skips", rapid_skips),
    ("pause/seek while loading", pause_and_seek_while_loading),
    ("crossfade", crossfade),
    ("song/video", song_video),
    ("repeat one", repeat_one),
    ("end of queue", end_of_queue),
    ("offline mode", offline_mode),
    ("output devices", output_devices),
    ("chaos", chaos),
]


# MARK: Setup

def other_copies(app_path):
    out = subprocess.run(["pgrep", "-fl", "YT Musicfast.app/Contents/MacOS/YT Musicfast"], capture_output=True, text=True).stdout
    mine = os.path.realpath(os.path.join(app_path, "Contents/MacOS/YT Musicfast"))
    copies = []
    for line in out.splitlines():
        pid, _, command = line.partition(" ")
        if os.path.realpath(command.strip()) != mine:
            copies.append((int(pid), command.strip()))
    return copies


def ensure_running(app):
    for pid, command in other_copies(app.path):
        print(f"quitting another copy: {command}")
        subprocess.run(["kill", "-TERM", str(pid)])
    for _ in range(40):
        if not other_copies(app.path):
            break
        time.sleep(0.25)
    if subprocess.run([app.tool, "debug-state"], capture_output=True).returncode != 0:
        # In the background: never takes focus from what you're doing.
        subprocess.run(["open", "-g", "-a", app.path], check=True)
        for _ in range(80):
            time.sleep(0.25)
            if subprocess.run([app.tool, "debug-state"], capture_output=True).returncode == 0:
                break
        else:
            raise Failure("the app didn't start (or isn't a Debug build: no debug-state)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default=DEFAULT_APP)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--only", help="comma-separated scenario names")
    args = parser.parse_args()

    app = App(args.app)
    ensure_running(app)
    before = app.state()
    saved = {"volume": int(round(before["volume"] * 100)), "repeat": before["repeat"], "crossfade": before["crossfade"],
             "video": "on" if before["videoMode"] else "off", "offline": "on" if before["offlineMode"] else "off",
             "autoplay": "on" if before["autoplay"] else "off"}
    scenarios = [(n, f) for n, f in SCENARIOS if not args.only or n in args.only.split(",")]
    failures = 0
    try:
        app.run("volume", "8")
        app.run("repeat", "off")
        app.run("shuffle", "off")
        app.set("crossfade", 0)
        app.set("video", "off")
        app.set("offline", "off")
        app.set("autoplay", "on")
        for run in range(1, args.runs + 1):
            print(f"run {run}/{args.runs}")
            start_fresh(app)
            for name, scenario in scenarios:
                started = time.time()
                app.log = []
                try:
                    scenario(app)
                    print(f"  ok    {name} ({time.time() - started:.0f} s)")
                except Failure as failure:
                    failures += 1
                    print(f"  FAIL  {name}: {failure}")
                    print("    commands:\n      " + "\n      ".join(app.log[-40:]))
                    # Leave the others a clean start.
                    start_fresh(app)
    finally:
        app.run("volume", str(saved["volume"]), check=False)
        app.run("repeat", saved["repeat"], check=False)
        for name in ["crossfade", "video", "offline", "autoplay"]:
            app.run("debug-set", name, str(saved[name]), check=False)
        app.run("pause", check=False)
    print("PASS" if failures == 0 else f"{failures} FAILED")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
