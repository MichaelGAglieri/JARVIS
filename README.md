# J.A.R.V.I.S.

A personal voice assistant for macOS, inspired by Iron Man's JARVIS, with companion apps for iPhone and iPad.

It runs locally on the Mac: it listens for the word "Jarvis", understands Italian and English, answers
with a neural voice, acts on the Mac (apps, calendar, mail, timers, files…) and knows your robotics
projects. When more power is needed it switches to Claude through your Claude subscription, with no
paid API.

- **Local first.** Speech recognition (Whisper on the Neural Engine), the local model (Gemma 4 via
  Ollama) and the neural voices (Qwen3, Kokoro) all run on the Mac.
- **Hands off the Mac.** It opens and drives apps, reads the screen, controls music, the TV and a 3D
  printer, and asks for confirmation only for purchases, passwords and sending email.
- **Robotics.** ROS 2, a simulated ROS 2 + Webots lab, Robot Console, Arduino and Bambu Studio.
- **iPhone and iPad.** Talk to JARVIS from the phone, at home or away (Tailscale), and see and control
  the Mac screen as an H.264 video stream over an encrypted link.

> JARVIS speaks Italian as its main language (answers in English when you speak English), so many voice
> commands and app labels are in Italian. Full manual: [`Manual_JARVIS.pdf`](Manual_JARVIS.pdf). Version
> history: [`CHANGELOG.md`](CHANGELOG.md).

## Requirements

- A Mac with Apple Silicon and macOS 15 or later; 16 GB of RAM is the practical minimum for the
  local model, 24 GB is comfortable.
- Xcode (for the Swift toolchain and the iPhone app) and Homebrew.
- An Apple Development certificate (Xcode › Settings › Accounts). A stable signature lets macOS
  remember the app's permissions between builds.
- Optional: a Claude subscription and Claude Code (`claude`), Tailscale, an iPhone or iPad.

## Installation

```bash
cp local.env.example local.env   # then edit it, see below
./scripts/setup.sh
```

`setup.sh` installs Ollama and the local model, the neural voices, builds the app and copies it to
`/Applications`. Whisper downloads itself on first launch (about 800 MB, then about a minute of
optimisation for the Neural Engine).

`local.env` holds values that are specific to your Mac and stays out of Git:

| Variable | Meaning |
|---|---|
| `JARVIS_BUNDLE_ID` | bundle identifier of the Mac app, e.g. `com.yourname.jarvis`. macOS ties microphone, screen and accessibility permissions to it, so do not change it after the first launch |
| `JARVIS_IPHONE_BUNDLE_ID` | bundle identifier of the iPhone and iPad app |
| `JARVIS_TEAM` | Team ID of your Apple account, needed to install on iPhone and iPad |

Then open the settings (⚙︎) or `~/Library/Application Support/JARVIS/config.json` and add your own
values. The ones in the code are neutral examples:

| Key | Meaning |
|---|---|
| `userName` | how JARVIS addresses you |
| `userFullName`, `userAbout` | your full name and one line about you, in English, for the model's instructions |
| `vocabulary` | names and acronyms Whisper should spell correctly |
| `notesFolders` | folders searched by "search my notes" (default `~/Documents/Appunti`) |
| `labProject` | the ROS 2 project of the simulated lab (default `~/Projects/ros2_lab`) |

After a code change, rebuild and reinstall:

```bash
./scripts/build.sh --install
```

For Claude, log in once:

```bash
claude auth login --claudeai
```

## Quick start

- Say **"Jarvis"** followed by the command ("Jarvis, what time is it?"), or just "Jarvis" and wait for the beep.
- When you ask it to do something it acknowledges at once ("Right away, sir") and then works.
- Or press **⌃⌥Space** (Control + Option + Space) and speak. Press it again to interrupt.
- "Stop" or "cancel" ("basta", "annulla") stop it. It answers in the language you speak.
- **Esc** or **×** hide the HUD; JARVIS keeps listening. The ◎ icon in the menu bar brings it back.
- JARVIS starts at login (can be turned off in ⚙︎ › System).

## What it can do

| Area | Examples |
|---|---|
| Apps | "open Visual Studio Code", "quit Safari and Netflix", "which apps are open?" |
| System | "volume to 30", "mute", "turn on dark mode", "how is the battery?" |
| Music | "play the Study playlist", "next track", "what's playing?" (Apple Music, library and catalog) |
| Files and projects | "which robotics projects do I have?", "open MioRobot in VS Code", "find the firmware file" |
| Calendar and reminders | "what's on tomorrow?", "remind me to buy servos tomorrow at 9", "delete the robot review event" |
| Mail | "any new mail?", "read me the one from Marco", "write to Marco that…" (sent only after your "yes") |
| Web | "search for the latest ROS 2 release", "what's the weather?", "open github.com" |
| Timers and Shortcuts | "25 minute study timer", "how long is left?", "run the Home shortcut" |
| Memory | "remember that the chemistry exam is on 15 December", "what do you remember about me?" |
| Study | "I'm starting to study Chemistry", "quiz me on Chemistry", "make flashcards on Fourier series" |
| Notes | "what do my notes say about capacitors?" → answers quoting document and page |
| Briefing | "good morning Jarvis" → weather, appointments, reminders, mail, study and projects |
| Vision | "explain this error", "what's wrong in this schematic?", "summarise this page", "look at the camera" |
| TV | "turn on the TV", "open Netflix on the TV" (Samsung Tizen on the local network) |
| Protocols | one phrase, several actions: study mode, end of study, good morning, good night (`protocolli.json`) |

The first time it uses Calendar, Reminders, Mail, Contacts, Music, the screen or the camera, macOS asks
for permission once.

## Robotics

| System | Examples | Notes |
|---|---|---|
| **Simulated lab** (ROS 2 + Webots) | "start the lab", "sposta campione a in postazione 1", "lab status" | lab commands are in Italian; simulation only |
| **ROS 2** (any topic, domain 42) | "which nodes and topics are running?", "what does /laboratorio/stato publish?" | publishing runs at once |
| **Robot Console** | "connect to Robot Console", "how is the robot?", "pick and place from Part to Bin" | moves run at once, except a move the model judges dangerous |
| **Arduino** | "which boards are connected?", "compile the firmware", "what does the serial port say?" | busy ports are never touched |
| **Bambu Studio and printer** | "how is the print going?", "unload the filament", "print the gripper", "stop the print" | through Bambu Studio's buttons, because the firmware rejects direct commands |

**"Jarvis, stop!"** ("ferma il robot", "ferma tutto") stops Robot Console and the lab at once.

**Robot Console**: in Robot Console open Diagnostics and ROS2 › Python API, press **Start local API** and
**Copy this session's token**, then say "Jarvis, connect to Robot Console". The token stays in memory only.
On the real robot, Robot Console's own approval still applies.

The ROS 2 bridge (`Resources/ros_bridge.py`) starts on the first request inside the pixi environment of
`labProject` and closes with JARVIS.

## iPhone and iPad app

A second app, in `iPhone/`, with the same reactor as the HUD. It is a remote: Whisper, Claude, Gemma and
the tools stay on the Mac; the phone carries your voice and shows the answers. You can say "Jarvis" with
the app open, tap or hold the microphone, type, or use Siri ("Hey Siri, talk to JARVIS") and the Action button.

- **Off by default.** Nothing listens on the network until you enable "iPhone app link" in the settings.
- **Encrypted.** TLS with a pre-shared key on port 47831. The key comes from a 20-character code (100 random
  bits) that never travels over the network: you pair with a QR code. Addresses outside the local network
  and Tailscale are refused.
- **Face ID** at every opening, before connecting.
- **Away from home** with Tailscale on both devices, also on 4G/5G.
- **Mac screen on the phone**: H.264 video at the Mac's resolution, up to 30 fps, Display P3 colour,
  hardware encoded; on a slow link the quality drops, not the smoothness.
- **Manual control**: tap to click, double tap, long press for right click, drag with one finger (moves
  windows, selects text), scroll with two fingers, pinch to zoom, and a keyboard.
- **Not from the phone**: moving robots, uploading to Arduino, changing filament, publishing on ROS,
  confirming Touch ID actions, leaving privacy mode. A "yes" counts only on the side that asked.
- One device at a time: the Mac follows the last one opened; the other pauses ("Use here" to switch).
- Every connection, refusal and action goes to `audit.log` with source `iphone`.

To install: connect the iPhone or iPad with a cable and double-click `Installa su iPhone e iPad.command`
(it reads the team and bundle identifier from `local.env`), or open `iPhone/JARVISPhone.xcodeproj` in Xcode,
pick your team in Signing & Capabilities and press Run. With a free Apple account the app must be
reinstalled every 7 days (it warns two days before); pairing and settings are kept.

## HUD and NUCLEUS

- **HUD**: the animated reactor and its state on a borderless translucent background. Hovering shows the
  buttons in a circle around the reactor: five panels (Phrases, Log, Activity, Modules, Protocol), NUCLEUS,
  settings and ×.
- **NUCLEUS** (◎): shrinks JARVIS to the reactor alone, in a round window on the desktop, above the wallpaper
  and below every app window. It pulses while JARVIS listens or speaks; a click reopens the HUD around it.
- The animation runs at 30 fps while JARVIS works, 12 while waiting, 6 after a minute, and stops when hidden.

## Brains: Gemma and Claude

With internet, **Claude Sonnet** answers through Claude Code (`claude -p`) and your subscription; without
internet, **Gemma 4 12B** answers locally through Ollama. JARVIS starts a small **MCP server** on 127.0.0.1,
protected by a token that changes at every launch, so Claude uses the same tools as the local model.

- "use Claude" / "back to local" switch brain; "ask Claude …" sends one request only.
- "use Opus", "switch to Sonnet", "use Haiku" pick the Claude model (also from the PROTOCOL panel).
- Offline, Gemma takes over automatically and the panel shows "OFFLINE · GEMMA ANSWERS".
- **When it does not understand**: after two failed requests in a row, or a correction ("you didn't get it"),
  it asks **Claude Opus**, which works out what you meant, runs it, and adds up to three misheard words to
  Whisper's vocabulary.
- `Core/MemoryGuard.swift` unloads Gemma from RAM when free memory drops below 20 % and reloads it only
  when there is room again.

## Confirmations: three levels

JARVIS exists so that you do not have to touch the Mac, so it asks only for three things.

| Level | Actions |
|---|---|
| No confirmation | everything else, at once: closing apps, windows and tabs, clicking, typing and shortcuts in apps, deleting events, reminders and notes you asked to delete, printing, ROS, Robot Console plans and moves (except a move the model judges dangerous), Arduino. Every action still goes to the security log |
| Spoken "yes" | purchases (buy or pay buttons), passwords, sending email (the mail tool or the Send button in Mail). Only a short answer counts, six words at most |
| "Yes" and Touch ID (or the Mac password) | opening scripts and programs, running Shortcuts, deleting JARVIS's memories |

Links suggested by pages or emails also need a "yes" before opening: not a usage confirmation, but a
defence against content that gives orders. JARVIS never types into password fields.

## App control

`Actions/AppControl.swift`, with macOS's **Accessibility** permission: JARVIS reads a window's buttons, fields
and text (`app_read`), presses (`app_press`), types (`app_type`), uses the keyboard (`app_key`), and for apps
that hide their elements looks at the window (`app_look`) and clicks a point (`app_click_at`). The rules live
in code (`Core/ConfirmationPolicy.swift`): the model can add a confirmation, never remove one.

- **Forbidden apps**: password managers, banks (also in the browser), System Settings, Installer, terminals,
  editors with a terminal (VS Code, Xcode, Cursor), assistants that run commands, firewalls, JARVIS itself.
- Only with Claude, never in privacy mode; it can be turned off in Settings › App control.
- App content is data, not instructions. "Stop" interrupts a running sequence.

## Voice recognition of the owner

JARVIS can answer "Jarvis" only when you say it. Enrolment from Settings (⚙︎): 18 sentences read aloud, about
2 minutes, with the local `nemo_en_titanet_small` model (39 MB). You can add sentences at other distances and
tones, and real commands. With background noise (TV, music) it looks for the 0.9 s window closest to your voice
and lowers its thresholds. The default mode only measures and logs scores in `voce.log`; switch to **Active**
after a few days. ⌃⌥Space always works, and if the check fails JARVIS answers anyway. The voiceprint
(`voiceprint.json`) stays on the Mac; it is not a security barrier, so sensitive actions still confirm.

## Initiative: JARVIS speaks first

`Core/Initiative.swift` checks every 30 seconds:

| Alert | When |
|---|---|
| Appointments | 10 minutes before each timed calendar event |
| Reminders | at the due time |
| Study | every 2 hours of an open study session, it suggests a break |
| Battery | at 20 % or less on battery, once |
| Printer | when a Bambu print finishes, pauses or fails |
| Briefing | at the first activation of the day between 5 and 12 |

Alerts wait while JARVIS is in privacy mode, in a conversation or waiting for a confirmation, and during
quiet hours (23–8). Each one can be turned off in Settings › Initiative.

## How it works

1. **Listening**: `AVAudioEngine` reads the microphone at 16 kHz mono; a voice activity detector cuts the
   phrases, so nothing runs while nobody speaks.
2. **"Jarvis"**: each phrase goes to Whisper `large-v3 turbo` on the Neural Engine (a small Whisper as a
   fallback, or Picovoice Porcupine with a key). Only the real word wakes it up.
3. **Transcription**: Whisper transcribes the command, picks the language (short phrases are transcribed in
   both languages and the surer one wins) and filters the phrases Whisper invents from noise.
4. **Direct commands**: "stop", "use Claude", "remember that…", the confirmation "yes"/"no" and the
   **instant commands** (`Core/InstantCommand.swift`: apps, volume, timers) skip the model.
5. **Brain**: Gemma (or Claude) receives JARVIS's personality and rules, the tools, long-term memory, the recent
   conversation and one line of context (date, time, language). The fixed instructions never change between
   requests, so Ollama keeps them cached.
6. **Tools**: AppleScript for Mail, Music and the system, EventKit for Calendar and Reminders, Spotlight for
   files, git for projects, DuckDuckGo and wttr.in for web and weather, ScreenCaptureKit for the screen.
   Several tools can be chained in one request.
7. **Voice**: the answer streams and is split into sentences; the first is spoken while the model is still
   writing. A local Python service synthesises it: **Qwen3** on MLX in Italian, imitating
   `Resources/voce_jarvis.wav` (a synthetic voice), **Kokoro** (Lewis) in English, with Supertonic and Apple
   voices as fallbacks. You can interrupt it by voice.
8. **HUD**: the reactor is drawn with SwiftUI `Canvas` and reacts to state and voice level.

## Project structure

| Part | Technology | Files |
|---|---|---|
| App, windows, animations | SwiftUI + AppKit | `Sources/JARVIS/App.swift` |
| HUD and reactor | SwiftUI `Canvas` | `Sources/JARVIS/HUD/` |
| Microphone, VAD, phrases | AVAudioEngine | `Sources/JARVIS/Audio/` |
| Wake word and transcription | WhisperKit (Porcupine optional) | `Sources/JARVIS/AI/Transcriber.swift`, `Audio/Porcupine.swift` |
| Local brain | Ollama, `gemma4:12b-it-qat`, tool calling | `Sources/JARVIS/AI/Ollama.swift`, `Persona.swift` |
| Tools | definitions and execution | `Sources/JARVIS/AI/Tools.swift` |
| Mac actions | AppleScript, EventKit, Contacts, Spotlight, Accessibility, web | `Sources/JARVIS/Actions/` |
| Memory, study, projects, notes | local JSON and SQLite, git, Spotlight | `Sources/JARVIS/Personal/` |
| Robotics | ROS 2 bridge (rclpy in pixi), Robot Console API, arduino-cli, Bambu Studio, MQTT | `Sources/JARVIS/Robotics/`, `Resources/ros_bridge.py` |
| Claude | Claude Code (`claude -p`) + MCP server | `Sources/JARVIS/AI/ClaudeBridge.swift`, `MCPServer.swift` |
| Voice | Qwen3, Kokoro, Supertonic in a Python service | `Sources/JARVIS/Audio/SpeechEngine.swift`, `Resources/tts_server.py` |
| Orchestration | state machine | `Sources/JARVIS/Core/Assistant.swift` |
| iPhone app and encrypted link | Network.framework (TLS-PSK), SwiftUI, VideoToolbox | `Sources/JARVIS/Core/PhoneBridge.swift`, `PhoneLink.swift`, `ScreenShare.swift`, `iPhone/` |
| Settings | JSON file + ⚙︎ window | `Sources/JARVIS/Core/Config.swift`, `SettingsView.swift` |
| Manual | ReportLab | `scripts/build_manual.py` → [`Manual_JARVIS.pdf`](Manual_JARVIS.pdf) |

## Where data lives

Everything is in `~/Library/Application Support/JARVIS/`, readable only by your user:

| File | Content |
|---|---|
| `config.json` | settings |
| `memory.json` | what JARVIS remembers about you |
| `activity.json` | study and work sessions |
| `appunti.sqlite` | search index of your notes (text and one meaning vector per passage) |
| `protocolli.json`, `schede.json` | protocols and flashcards |
| `voiceprint.json` | your voiceprint |
| `iphone_code`, `tv.json` | phone pairing code, TV key |
| `audit.log` | security log: one line per action run, requested, confirmed or cancelled, with its source |
| `diagnostica.log` | the last 400 lines of listening and timing diagnostics |
| `models/`, `tts/` | Whisper models and neural voices |

## Security and privacy

- **JARVIS does not delete files**: it has no tool for it and no terminal. In Claude mode, Claude can only
  search the web and read files in `~/Projects`.
- **External content** (mail, pages, files, screenshots, devices) is marked as data: JARVIS does not follow
  instructions found inside it, it reports them.
- **Local services** listen only on 127.0.0.1, with a token, and refuse browser requests.
- **Privacy mode**: "Jarvis, privacy" (or ⌃⌥P, or the ◎ menu) turns the microphone off and blocks camera and
  screen; you leave it only with ⌃⌥P or the menu, not by voice.
- **Stays on the Mac**: audio, transcripts, conversation, memory, calendar, mail, files, screenshots and photos
  (images are never saved). **Leaves the Mac**: web searches (DuckDuckGo), weather (wttr.in) and, in Claude
  mode, the requests to Claude, including screenshots you ask it to look at.

## Troubleshooting

- **It does not hear "Jarvis"**: the MODULES panel must show `"JARVIS" ATTIVA · WHISPER`; check the microphone
  permission in System Settings › Privacy & Security › Microphone, or use ⌃⌥Space. The `wake NO` lines in
  `diagnostica.log` show what Whisper heard.
- **Slow answers**: with the model loaded the first word comes in about 3 s; a cold reload takes about 45 s
  (rereading about 4,900 tokens of instructions). The model stays in RAM for 30 minutes (`modelKeepAlive`).
- **A file is not found**: macOS asks permission for Desktop, Documents, Downloads and iCloud Drive on first
  use; re-enable it in System Settings › Privacy & Security › Files and Folders › JARVIS.
- **"Nucleo offline"**: Ollama is not running; JARVIS tries to start it, otherwise run `ollama serve`.
- **Apple voice instead of the neural one**: run `./scripts/setup_tts.sh`.
- **Claude does not answer**: `claude auth status`, then `claude auth login --claudeai` if needed.

## Test mode (for development)

With `"developerMode": true` in `config.json`, JARVIS accepts test commands through distributed notifications,
only if they carry the key in `dev_token` (readable only by your user); the HUD shows "MODALITÀ TEST ATTIVA".
`<bundle id>.debug.text` with `"<key>|che ore sono?"` simulates a transcribed command,
`<bundle id>.debug.audio` with `"<key>|/path/file.aiff"` a phrase heard after "Jarvis", and
`<bundle id>.debug.wake` with `"<key>|/path/file.wav"` a phrase heard while waiting. Turn it off afterwards.

## Third-party components

WhisperKit (MIT), Kokoro / kokoro-onnx (Apache 2.0), Supertonic 3 (code MIT, model BigScience Open RAIL-M),
Qwen3-TTS (Apache 2.0) with mlx-audio (MIT), Picovoice Porcupine (Apache 2.0, in `Vendor/porcupine`),
Ollama (MIT), Gemma 4 model (Gemma terms of use). The voice sample `Resources/voce_jarvis.wav` is synthetic.

"J.A.R.V.I.S." is a character of Marvel's Iron Man; this is an independent hobby project, not affiliated
with or endorsed by Marvel.

## License

[MIT](LICENSE).
