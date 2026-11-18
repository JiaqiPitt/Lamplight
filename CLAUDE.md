# Lamplight — notes for working on this project

A native macOS typewriter app for diaries and reading notes: Swift + SpriteKit, SwiftUI for the
overlay controls. See README.md for what it does and how the source is laid out.

## Build

```bash
./scripts/build.sh        # swift build -c release, then wraps build/Lamplight.app
```

This Mac has only the Command Line Tools, not Xcode. Two consequences:

- **`@State` does not compile** (it is a macro in this SDK and the `SwiftUIMacros` plugin ships only
  with Xcode). Hold state as a plain value instead: `private var x = State(initialValue: false)`,
  then `x.wrappedValue` and `x.projectedValue`. `@StateObject`, `@ObservedObject`,
  `@EnvironmentObject` and `@Published` are fine. Do the same for `@Entry` / `@Animatable`.
- There is no `xcodebuild`, no previews, no Instruments. Everything goes through `swift build`.

## Checking your work

You cannot see or click the running app, and `screencapture` is not permitted. Use the built-in tools:

- `.build/release/Lamplight --render-test <dir> [--size WxH] [scenario ...]` renders the scene
  offscreen to PNGs, stepping time by hand. Read the PNGs. Add a scenario there when you change
  how something looks or moves.
- For the real window (toolbar, drawer, settings), launch the app with
  `--capture <file> --capture-at <seconds> --quit-after <seconds>`; it photographs its own windows.
  Drive it with `--demo "text"`, `--keys "abc<ret><del>"`, `--open-drawer`, `--open-settings`.
  In `--keys`, `<glide-left:0.4>` holds Control-F for 0.4 s (key down, the system's repeats, key up).
  `--drag "-20:0.5@4"` drags the carriage 20 cells left with real mouse events, `--pointer "0.35,0.4@5"`
  moves the pointer and prints what becomes of it when it rests, `--carriage-log` prints where the
  carriage is twenty times a second, and `--capture-at 4,6.5` photographs more than once.
- Scripted events in `LamplightApp.swift` are scheduled with `onTime`, not `asyncAfter`: `asyncAfter`
  may run a tenth of its delay late, which once delivered a key's press and release together and made
  a working glide look broken.
- `--profile` prints frame rate and time spent in `update` before quitting. Set
  `LAMPLIGHT_FULLRATE=1`, since a test launch is never the active app and is otherwise throttled.

**Every test launch must use** `LAMPLIGHT_DATA_DIR=<temp dir> LAMPLIGHT_MUTE=1 ... --no-activate`.
Without them the test writes into the owner's real diary, plays sound, and takes their keyboard focus.
With `LAMPLIGHT_DATA_DIR` set, the app also keeps its preferences in a separate domain
(`app.lamplight.typewriter.testing`), which may be deleted freely.

- Add `LAMPLIGHT_AUDIO_DEVICE="MacBook Pro Speakers"` as well, unless the Mac's own output is the
  thing being tested. Whoever is at the Mac may be wearing wireless headphones that are shared
  with another device; a test that opens them, even silently, takes part in the tug-of-war over
  them. If the owner says they need their headphones, launch nothing at all until they say otherwise.
- The app refuses every `--` option unless `LAMPLIGHT_DATA_DIR` is set, and a measuring command with
  too few arguments exits instead of falling through to a normal launch (`main.swift`). Keep it so:
  `--audio-trace <file>` with nothing after it once opened the real app, unmuted, on the real diary.
- Test from `.build/release/Lamplight` (run in the project folder) while iterating. `scripts/build.sh`
  replaces `build/Lamplight.app`, which is the copy the owner runs, and whatever is in that bundle is
  what they will open next: put only tested code there. The script refuses to replace it while it is
  running and leaves the new build in `build/next/`; `./scripts/build.sh --wait` waits for the owner
  to quit and then swaps it in.
- zsh has its own `log` builtin. Call the system one by its path: `/usr/bin/log show ...`.

The owner uses this app. Their sheets are in `~/Library/Application Support/Lamplight/Entries/`
and their settings in the `app.lamplight.typewriter` defaults domain. **Never read the sheets,
and never run `defaults delete app.lamplight.typewriter`** — an earlier clean-up step did exactly
that and reset the owner's settings.

Change a real sheet only when the owner asks for that change. Then: make sure the app is not
running (it would overwrite the file from memory), copy the file to
`~/Library/Application Support/Lamplight/Backups/` first, use the app's own model code to edit it
(see `Dev/HeaderFix.swift`), look at no more of the sheet than the change needs — counts and the
line concerned, not the body — and check the result by opening a copy in a test launch.

## Things the owner has asked for

- The app's name is English: **Lamplight**, and the whole interface is English: menus, toolbar,
  drawer, settings, and the date the machine types at the top of a sheet. The owner asked for this
  because typing Chinese in the app is not yet good enough; Chinese input still has to work.
- Use what suits the Mac best and keep it extremely smooth: native only, 120 fps. Keep per-frame work
  in `TypewriterScene.update` small (it averages under 1 ms); never rasterise many rows in one frame.
- The carriage shows **no text and no clock**. The only thing that may light up on it is the
  input-source mark (A / 中 / あ), briefly, when the input source changes.
- The look is lights-off and immersive: one lamp on the carriage, everything else night.
- Original design only — it is inspired by the mood of a reference photo, not a copy of another app.
- Sound must closely match an old mechanical typewriter and feel like ASMR: close, detailed, soft.
  The four sounds that matter most are the strike, the space bar, the carriage return and delete.
  The owner chooses by listening; give them samples (`docs/sound-samples.html`) rather than deciding.
- The owner listened to the four packs and chose **Hermes · ASMR** (`hermes-asmr`) on 2026-11-17.
  It is the default. Do not change its voicing or the default pack without asking them first.
- A character removed with the correction tape must not stay on the page: its trace fades to
  nothing over 10 seconds (`traceFade`), and lifted ink is not written to the saved sheet.
- The carriage can be moved along the line by hand, fast and smoothly (asked 2026-11-17): by dragging
  it with the pointer, and by holding a key — unlike the arrow keys, which step one cell at a time.
  The owner's example was Shift-F for left and Shift-J for right. Those are how capital F and J are
  typed, so the keys are **Control-F / Control-J** (`TypewriterView.glideModifier`). Told why,
  the owner let that stand. (Shift could be had as "tap types the letter, hold glides", at the
  price of capital F and J landing on key-up; not built.)
- For immersion, the pointer disappears once it has not moved for 6 seconds, and the light it
  carries over the paper goes with it; moving the mouse brings both back (`TypewriterView.pointerRest`).
- Not yet judged by the owner's ear: the click the carriage makes passing over cells while it is
  dragged or glided. It is the pack's `tick` (the arrow-key sound) at a lower gain, at most 25 a
  second (`passCells`). Change it to whatever they say after listening.

## Why the app went silent (found and fixed 2026-11-17)

Twice the app was reported to have "suddenly gone silent". Both were the same bug, and it had
nothing to do with deleting or with input methods (an earlier guess).

- **Cause.** Whenever the output hardware changes, the system stops the `AVAudioEngine`. A player
  node that was playing at that moment goes on reporting `isPlaying == true`, and `play()` on it
  then does nothing, so after the restart every sound was scheduled on a player that stayed mute
  until the app was relaunched. The engine itself looked healthy (running, IO active).
- **What changes the hardware.** In practice, Bluetooth headphones. Any app that opens their
  microphone, even for a fraction of a second, drops them to call mode (24 kHz mono) for about two
  seconds, and each switch is a stop; so is their sound changing hands when they are connected to
  a second device. On the machine where this was found it happened dozens of times in an afternoon.
- **Fix** (`SoundBank`): after any stop, players are stopped before the engine starts again
  (`playersClean`), and each is set playing when first used. All engine work runs on one private
  queue, never the main thread; a heartbeat restarts an engine found stopped; `ObjCSafe` catches the
  exceptions AVFoundation raises. Verified by switching the output device while typing
  (`--audio-flap`): each restart took 28–65 ms and the recording shows the strikes continuing.
  The owner confirmed afterwards that sound was back; nobody has yet watched it ride out a real
  headphone switch.
- **Not fixable in the app.** While the headphones' audio belongs to another device, the Mac still
  lists them as its output, and what any Mac app plays goes nowhere until macOS takes them back.
  Settings shows the output device so that it can be seen where the sound is being sent.

If silence is reported again, read the logs before changing code:

```bash
# What the app's sound engine did (starts, stops, device changes, start failures):
/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "app.lamplight.typewriter"'
# What happened to Bluetooth headphones: who holds their audio ("Ownership Set as 1/0"), which
# process opened their microphone ("HFPInputShimDevice: StartIO ... PID="), and how loud the stream
# the Mac sent was while it did not hold them ("BTAudioDetect virtual avgPwr", -120 dB = silence):
/usr/bin/log show --last 30m --style compact --predicate 'process == "coreaudiod" AND subsystem == "com.apple.bluetooth"'
```

`--audio-log` prints the same engine history at the end of a test launch.

## The front page

The repository is public (github.com/JiaqiPitt/Lamplight), and its README opens with a film of the
app (asked for by the owner: "a very good demo … that shows the whole effect at a glance").
The README is written entirely in English, at the owner's request; so is the sound sample page.

- `Lamplight --make-demo <dir>` (run from the project folder) makes it: `demo.mp4`, 60 frames a
  second with sound, and the frames for `docs/demo.webp`, which is encoded with the `img2webp`
  line the tool prints. Nothing is opened or played — the scene is drawn offscreen and the
  soundtrack is mixed from the pack's recordings at the times the scene asks for them
  (`Soundtrack`, a simpler stand-in for `SoundBank`: no voice stealing, a plain balance for pan).
  Nobody has compared that soundtrack with the app by ear.
- The camera moving in on the carriage is the one thing in the film the app does not do; the
  README says so.
- The animation is the same loop as the film, entered at a picture of a typebar about to land:
  where moving images are switched off, the first frame is all that is seen.
- Things that cost time: SKRenderer lays a `.resizeFill` scene out as if the viewport were at
  2 px to the point, so an offscreen scene must be made at `pixelScale: 2` (at 3 the scene's
  coordinates silently stopped matching the size it was given). And `img2webp` needs `-kmax 1`:
  left to reuse parts of the previous frame, it leaves seams all over the dark of the room.
- Before anything is pushed, look for personal details in what is being added. The first commit
  was cleaned of them: no names, paths under a home folder, device names or accounts.

## Design rules worth keeping

- The scene is driven only by the time passed to `update(_:)`; nothing reads the wall clock for
  animation. That is what makes the offscreen renderer exact.
- The model is a grid of strikes, not a string. Typing, overtyping, striking out and lifting ink are
  all edits to that grid; text is derived from it (`Entry.text()`).
- Moving the carriage by hand (`stepHand`) steers `headTarget`, which may then sit between cells;
  the same spring that carries the carriage in typing follows it. `entry.cursorCol` changes only
  when the carriage is let go and drops into a cell. A glide's speed is a state that gains and
  brakes — it never jumps — and after key-up it brakes to stop exactly on a cell. The hand waits
  for the mechanism to be at rest before it takes hold, and a key struck takes the carriage out of it.
- The pointer's light belongs to the pointer: whatever hides the pointer (a key, six seconds of
  rest) also calls `pointer(at: nil)`.
- All images are generated at launch (`Art.swift`, `Shaders.swift`); there are no image files.
- Sounds are packs of real recordings in `Resources/Sounds/<pack>/` (WAV files plus `pack.json`),
  built from `SoundSources/` by `Lamplight --build-packs` (recipes in `Dev/PackRecipes.swift`).
  `Synth.swift` is only the fallback for sounds a pack lacks.
- Nothing touches the audio engine from the main thread. Starting a Bluetooth device takes up to
  half a second, and typing must never wait for it: `play` only queues a request, and a request that
  had to wait behind a restart is dropped rather than played late.
- After the engine has stopped for any reason, stop every player before using it again. `reset()`
  is not enough, and `isPlaying` cannot be trusted. Starting a player costs a render cycle (~10 ms),
  which is why they are started one at a time as they are needed and not all at once.
- The engine does not run for ever: it is released after five minutes without typing, or fifteen
  seconds after the app leaves the front, and started again by the first key or pointer movement
  (about 35 ms on the built-in speakers). A running engine keeps the Mac awake and the headphones
  streaming, so do not "simplify" this back to always-on.
- Each strike sample starts a fixed time before its impact (`strikeLead` in the pack); the scene
  starts it that much early so the recorded impact and the slug on screen coincide.
  `Mechanics.carriageDurations` are the times to the carriage's stop click in the return samples.
  Change either only together with the packs.

## Working on sound without hearing it

You cannot listen. Nobody has judged these sounds by ear except the owner, so never say a sound
is good, warm, pleasant or realistic — report what was measured and let the owner listen.

- `--audio-scan <file>` lists each event in a recording (time, length, level, brightness, tonality).
- `--spectrogram <file> <start> <length> <out.png>` draws it; read the PNG. A strike is one bright
  vertical stroke, a bell is steady horizontal lines, a carriage slide is a block of dense noise.
- `--audio-trace` prints level every 10 ms; `--audio-balance` gives band shares and loudness.
- To check the real app, run it with `--record-audio <file>` (works under `LAMPLIGHT_MUTE=1`) and
  inspect the recording with the tools above. The recording is taken before volume and mute, and it
  keeps real time: a stretch where the engine was down is written as silence.
- `--audio-flap "Some Other Output@6,MacBook Pro Speakers@8.2"` switches the output device at
  those seconds, the way the system does (the engine is stopped, then finds another device); the
  names are those in the Sound settings. Use it whenever the engine's starting or stopping is
  changed, together with `--audio-log`.
- `LAMPLIGHT_AUDIO_IDLE=2` shortens the idle release to two seconds, to test waking up.
- Known wart: at launch the engine can start a few hundredths of a second before the saved volume
  and mute reach it. Nothing plays that early. When next working on `SoundBank`, have it begin
  muted until its first settings arrive — and test that, because a mistake there means no sound.
- The system FLAC decoder returns nothing for the BigSoundBank files (their encoder writes
  non-standard checksums); `Dev/FLACDecoder.swift` reads them instead.
- New recordings need the owner's permission to download, and a licence that allows bundling.
