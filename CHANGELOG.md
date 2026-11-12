# Changelog

Every version was built, installed and tested on the Mac (and on the iPhone and iPad app when it was
involved) before moving to the next one. All dates are in 2026.

## 1.30.25 — 11 November

- More detailed SATELLITE, same style: gold propellant tanks, a richer engine with vernier nozzles, truss yokes,
  radiator fins and edge lights on the solar wings, a second small dish, a helical antenna, a crown of lights around
  the eye and marks on the rings.
- The two rings now sit in front of the wings, around the eye, and tilt less: they no longer pass through the wing
  supports, the dish or the antennas.

## 1.30.24 — 11 November

- Neural sphere, brain look: a large neuron with long branching dendrites at the centre instead of the round light;
  the 44 neurons are spread evenly through the whole sphere, joined by a mix of straight and curved axons; each
  neuron has more branches, with a dot at every fork. The dashes turning around the outline are gone and the small
  data screens go from 34 to 8.
- The sphere breathes slowly, and while JARVIS speaks its surface waves follow the beat of the voice.

## 1.30.23 — 11 November

- Denser neural sphere: 44 neurons instead of 16, each joined to its three nearest instead of two, and 1500 points in
  the background mesh instead of 1150. The same sphere is in the iPhone and iPad app.

## 1.30.22 — 11 November

- No more state label under the neural sphere ("in attesa", "elaborazione", "risposta"): the sphere shows the state
  by itself. Privacy mode and errors are still written, because they need attention.

## 1.30.21 — 11 November

- The window of the neural sphere wraps it closely: 440×472 points instead of 600×600, so much less invisible space
  around the sphere takes clicks meant for the windows behind it.
- A double click on the sphere goes back to the SATELLITE.

## 1.30.20 — 11 November

- iPhone and iPad app: the same neural sphere as on the Mac. The app had stopped building after the sphere
  redesign, because the sphere drew itself with macOS-only code; it now draws with Metal on iOS and iPadOS too.
- Faster voice on the phone: the new Italian voice reaches the iPhone and iPad in pieces of 0.3 s while it is being
  generated, so the first words start after about a third of a second, as on the Mac.

## 1.30.19 — 11 November

- Lighter, quicker Italian voice: JARVIS now uses the small Qwen3 voice model (Qwen3-TTS 12Hz 0.6B Base, 8-bit) with
  the same reference voice, and plays each sentence in pieces while the rest is still being generated. In a test of
  three sentences the first word came after 0.35 s instead of 4.1 s, and the GPU worked about 40% less per second
  of speech. "Basta" also stops the generation of the rest of the sentence. The 1.7B model stays as a fallback.

## 1.30.18 — 11 November

- The SATELLITE now floats above every window, on every desktop and over full-screen apps. The other NUCLEUS styles
  still stay on the desktop, behind the apps.
- No more buttons around the neural orb. Hiding it (Esc), the SATELLITE and the settings are in the JARVIS icon's menu.

## 1.30.17 — 11 November

- The panels (Frasi, Registro, Attività, Moduli, Protocollo, Pensiero) are no longer attached beside JARVIS. They open
  from the "Schede" menu, in the menu bar on the left while JARVIS is in front and in the JARVIS icon's menu on the
  right. Each panel is its own window that can be dragged anywhere and resized, with both the neural orb and the
  SATELLITE. Each window remembers where it was left, and the open ones reopen at the next launch.
- Around the orb only the hide, settings and SATELLITE buttons remain.

## 1.30.16 — 11 November

- Long sentences are no longer cut off: a short command still ends after 0.8 s of silence, a longer sentence waits
  1.3–1.7 s, and the limit for one sentence rises from 20 to 30 seconds.
- Breaks in study and work sessions: "pausa" or "facciamo una pausa" no longer closes the session. JARVIS pauses it,
  starts a 10-minute timer, then says "la pausa è finita, ricominciamo? Avvio la sessione?"; a "sì" resumes it.
  Breaks are not counted as study time; at the end JARVIS says the effective time, the total time and how many
  breaks were taken.
- Session reports: when a session ends JARVIS asks what to write in the report and saves it; at the next session
  with the same name it reminds you where you had got to.
- AirPods stem button: while JARVIS uses the headphones' microphone, a press works like ⌃⌥Space (speak without
  "Jarvis", or interrupt) instead of starting the music or showing "impossibile connettere JARVIS al microfono".

## 1.30.15 — 11 November

- Crash with AirPods 4 fixed: when the headset's microphone opened, macOS switched it to 24 kHz while JARVIS still
  used the 48 kHz format, and installing the microphone tap with the old format made macOS close the app. JARVIS now
  compares the two formats, rebuilds the audio engine once and, if they still differ, retries later without
  crashing.
- Headsets that keep changing audio configuration no longer cause a rebuild every two seconds (88 in six minutes):
  repeated rebuilds wait longer, and a change that leaves the microphone working is ignored.
- After an audio change the microphone is reattached on the same engine instead of a new one: closing and
  reopening it switched the AirPods' profile again each time, so the yellow microphone dot kept blinking. JARVIS keeps
  using the headphones' microphone.

## 1.30.14 — 10 November

- The Satellite window wraps it closely: 221 × 130 points instead of 221 × 221 (the wings reach the sides, above and
  below there was only empty space), so it can sit much closer to the edges of the display. The satellite keeps the
  same size on screen; the dark backdrop becomes an ellipse.
- At every launch the satellite starts in the top right corner of its display; it can still be dragged anywhere
  while JARVIS runs. The reactor keeps its remembered position.

## 1.30.13 — 10 November

- The Satellite look is 30% larger (221 points instead of 170); the reactor keeps its size. Switching style in
  Settings resizes the window around the same centre. GPU of the JARVIS process alone, desktop uncovered: 0.54%
  while waiting (reactor 1.21%), 0.8% in a thinking-and-speaking test (1.8% in an earlier test at the old size: the
  numbers vary with how long it speaks).

## 1.30.12 — 10 November

- New "Satellite" look for the desktop window (Settings → SATELLITE → Aspetto: "Reattore" or "Satellite"; the
  reactor stays the default). A faithful SceneKit port of the three.js preview the user approved, built in code with
  no external models: same sizes and parts, physically based chrome and titanium lit by a soft studio environment,
  hexagonal hull panels, wrinkled gold foil, solar cells, lens eye with 8-blade aperture and glow, LED mouth,
  eyebrows, two gyroscopic rings, folding solar wings, dish, star trackers, antenna, strobe and RCS puffs.
  Waiting it drifts slowly with wings half open; listening it turns to the viewer, opens wings and iris and signal
  rings come in; thinking the rings spin and tilt, the dish scans and particles orbit; speaking mouth, ring lights
  and outgoing waves follow the real voice level.
- Light on the fanless Air: 15 fps without antialiasing while waiting (10 after a minute), 30 fps with 2x
  antialiasing while active, stopped when covered or hidden; parts that never move on their own are merged into a
  few draw calls. GPU of the JARVIS process alone (IOKit, voice server excluded), desktop uncovered, waiting:
  reactor 1.21%, satellite 0.40–0.68%; satellite while thinking and speaking 1.8%.
- The desktop window is now called SATELLITE in menus, tooltips and Settings (the local AI model is still the
  "nucleo locale").

## 1.30.11 — 10 November

- Instant robot STOP: from a movement command ("esegui sequenza", "torna a home", joint moves) until Robot Console
  reports the arm still, every short phrase is checked for "stop", "basta", "fermati", "ferma", "alt" and similar,
  without saying "Jarvis" and without the voiceprint. The STOP goes to Robot Console before anything else: in tests
  with audio files it left about 0.45 s after the word ended (plus the 0.3 s pause that marks the end of a phrase).
  Phrases are cut shorter only while the arm moves; "non fermarti" or a long phrase are not a STOP.

## 1.30.10 — 10 November

- Direct channel to Robot Console: "abilita robot" (enable the robot), "esegui sequenza" (run the sequence), joint
  moves and closing the app go through a private local socket instead of clicks.
- Fixes after the first real tests, in Robot Console's Python side: HOME is set only after the 3 second USB quiet
  window (before it, the heartbeat had not started and the firmware watchdog tripped); "HALTED"/"ERROR WATCHDOG"
  lines left over from the previous session are ignored before the board identifies itself; enabling restores the
  last limits applied to the real robot.
- Whisper's spellings "Abilità robot", "E segui sequenzo", "segui sequenza" are understood.
- If the board stays silent after the USB opens (it did not even answer hello), enabling reopens the port once with
  a board reset, as pressing "Connetti Mega" again would.
- "Torna a home" (go back HOME) uses the direct channel, like the "Vai a HOME…" button, instead of the old
  token-based API.

## 1.30.9 — 9 November

- New **Thought** panel (PENSIERO) in the HUD, available from the terminal icon. It shows the request route, commands, queries, files consulted, domains found, and timestamped outcomes.
- The panel follows the latest line, keeps up to 300 events in memory, and clears on “New conversation”.

## 1.30.8 — 9 November

- The HUD sphere becomes a neural network: the spiral is replaced by 16 neurons with dendrites, joined by soft
  glowing axons. Each neuron fires in turn: its body flashes and a pulse runs along its axons, more often while
  JARVIS listens, thinks or speaks.
- The striped blocks are small data screens with live bars, waveforms or scrolling lines; they turn with the sphere
  (none circles the outline any more).
- Denser shell, brighter at the edges, so the sphere reads as a solid that turns. While waiting it turns about three
  times faster, at 20 fps instead of 12; after a minute it slows down to 6 fps as before.

## 1.30.7 — 9 November

- One NUCLEUS on every display. A click opens the HUD around that NUCLEUS; if the HUD is open on another display,
  it first shrinks into the NUCLEUS there. Each display remembers its own position, and a NUCLEUS can be dragged
  only within its display: one pushed onto another display got stuck at the edge.
- The NUCLEUS sits at the back of the normal level instead of level −1: there, on the main display, the full-screen
  Übersicht window stayed in front of it and took its clicks. If an app window ends up underneath it, the NUCLEUS
  goes back behind it, or hides while that window covers it completely (an app enlarged to fill the screen).

## 1.30.6 — 9 November

- New holographic sphere in the open HUD, inspired by JARVIS in *Age of Ultron*: drawn with Metal, a plexus of
  nodes, glowing ribbons spiralling into a white core, striped data blocks and a broken rim. It reacts to listening,
  thinking and the voice; every change of state eases in, so pulses never jump or reverse abruptly. The NUCLEUS on
  the desktop keeps the original reactor.
- Smoothness: each frame takes a fresh drawable from the Metal layer. A live test (`tests/reactor_sphere/live.sh`,
  `GPU_LOAD=1` adds a load like speech synthesis) measures 30 fps in every active state and 12 while waiting.

## 1.30.5 — 9 November

- Running a Robot Console sequence by voice failed: the app exposes only what is on screen and JARVIS could not
  scroll, so it pressed unrelated buttons and switched tabs. New `app_scroll` tool: scrolls the page, or the list that
  contains an element, without keys or clicks. The model is told to scroll instead of searching elsewhere.
- In protocols `{resto}` also works in the request to the model (`chiedi`), not only in tool arguments.

## 1.30.4 — 9 November

- Actions without commentary: during a Robot Console sequence JARVIS said 22 sentences in a minute, describing steps
  already finished. Now, while it acts (apps, clicks, robot, printer, music), the sentences said between one step and
  the next are dropped before speech synthesis: it gives the acknowledgment and at the end only "Done", the result,
  the error or a question. Questions and conversation are answered as before.
- Protocols with `"sintetico": true`: sequences of actions that acknowledge at once and speak only at the end.
- A result with numbers ("15, sir.") is no longer mistaken for a repeated acknowledgment and left unsaid.

## 1.30.3 — 9 November

From the logs of the last day:
- Printer switched off: the network search (254 addresses) ran every 4 minutes all night, even in privacy mode.
  Now it comes back less and less often (4, 8, 16, then every 30 minutes), never in quiet hours or privacy mode,
  and starts at once when you ask about the printer.
- "Mi sa che Jarvis ti ha dato ragione" ("I think Jarvis proved you right"), said to another person, woke it up.
  With "Jarvis" in the middle of the sentence the model reads the whole sentence and stays silent if it is not
  addressed to it. Real requests are answered as before.
- Morning briefing: Mail takes about 10 seconds. The briefing now waits for it at most 5 seconds; when it starts
  by itself, the data is gathered while JARVIS answers the first request.
- "Jarvis Apriclode" went to the model (7.7 seconds): instant commands recognise how Whisper writes "Claude"
  (Clode, Cloud, Claud, Clod).

## 1.30.2 — 8 November

- Repository in English: README, changelog, code comments and manual. The app itself still speaks Italian
  (and English when you speak English).
- MIT license.

## 1.30.1 — 8 November

- Ready for GitHub: only neutral example values in the code. Name, profile, vocabulary, notes folders and
  lab project live in the settings (`config.json`).
- Bundle identifier and Apple Team in `local.env`, outside Git (example in `local.env.example`), read by
  `scripts/build.sh` and `Installa su iPhone e iPad.command`.
- Configurable path for the ROS 2 lab (`labProject`).
- README and manual updated with the 1.29.2 confirmation rules.

## 1.30.0 — 8 November

- Screen view on iPhone and iPad: dragging with one finger moves windows, two fingers scroll.

## 1.29.2 — 8 November

- Confirmations only for three things: purchases, passwords and sending email. Robots, printing and
  everything else run at once, and still go to the security log.
- A "yes" counts only as a short answer (six words at most): a sentence said to someone else no longer confirms.

## 1.29.1 — 8 November

- The Bambu printer is found again on the network when its address changes.
- Looking at apps also sees their small confirmation windows; one "yes" per action.

## 1.29.0 — 8 November

- Mac screen on the phone as full-resolution H.264 video, Display P3 colours, shown by the system video
  player: smoother, sharper and lighter on the CPU.

## 1.28.3 — 8 November

- Screen on the phone as a continuous stream of 12 images per second, 1280 points wide.

## 1.28.2 — 8 November

- "Alt" recognised only as a whole word; an empty answer during a quiz is asked again; quizzes taken from
  your notes.

## 1.28.1 — 7 November

- TV: the remote control accepts the TV's certificate.

## 1.28.0 — 7 November

- Music from the Apple Music catalog, Samsung TV control on the local network, Protocols (one phrase,
  several actions) and flashcards. New manual chapter on Protocols and review.

## 1.27.0 — 7 November

- iPad app; the Mac follows one device at a time. Simpler final message in the installer.

## 1.26.2 — 7 November

- The microphone reconnects by itself when the Mac's audio device changes.

## 1.26.1 — 7 November

- iPhone: the screen view rotates properly, keyboard included.

## 1.26.0 — 7 November

- iPhone: manual control of the Mac, printing from away, reactor in the centre.

## 1.25.0 — 7 November

- iPhone: hands-free "Jarvis", Siri, self-service installation; clicks in small windows.

## 1.24.0 — 7 November

- iPhone app away from home (Tailscale), with Face ID and the Mac screen.

## 1.23.1 — 7 November

- iPhone app tested on a real phone: microphone, icon and ROS limits.

## 1.23.0 — 7 November

- Notes search also understands meaning (local meaning vectors).

## 1.22.0 — 7 November

- iPhone app: talk to JARVIS from the phone, on the local network, over an encrypted link.

## 1.21.1 — 7 November

- Notes search tolerates misheard words and quotes the page.

## 1.21.0 — 6 November

- Search in your notes (PDF, Word, PowerPoint): answers quoting document and page.

## 1.20.1 — 6 November

- Printer: tells apart the printer's requests while loading and unloading filament.

## 1.20.0 — 6 November

- Loads and unloads filament and prepares prints from Bambu Studio.

## 1.19.0 — 6 November

- Reads the Bambu printer's state and warns about problems.

## 1.18.2 — 6 November

- More instant commands; the frontmost app goes into Claude's context.

## 1.18.1 — 6 November

- Instant commands answer while the app is opening.

## 1.18.0 — 6 November

- Italian voice with Qwen3 on MLX, imitating `Resources/voce_jarvis.wav` (a synthetic voice).

## 1.17.0 — 6 November

- HUD panels can open all together around the reactor.

## 1.16.1 — 6 November

- A pause after "Jarvis" no longer loses the command.

## 1.16.0 — 6 November

- Italian voice with Supertonic.

## 1.15.0 — 6 November

- Confirmations only for dangerous actions, also for apps, ROS and Arduino.

## 1.14.2 — 6 November

- Apps open instantly even with a misheard verb ("abre", "aprei").

## 1.14.1 — 6 November

- Instant commands understand verbs misheard by Whisper; the spoken acknowledgment no longer goes missing.

## 1.14.0 — 6 November

- JARVIS acknowledges at once ("Right away, sir") and then works.

## 1.13.1 — 6 November

- Buttons in a circle around the reactor, with soft corners.

## 1.13.0 — 6 November

- The JARVIS window becomes the reactor alone, with drop-down panels.

## 1.12.1 — 6 November

- Answers to JARVIS's questions are no longer discarded by the voice check.

## 1.12.0 — 6 November

- After a question JARVIS keeps listening for the answer.

## 1.11.2 — 6 November

- "Turn the volume down a bit" and "volume to the max".

## 1.11.1 — 6 November

- Apps can be called by their Italian names.

## 1.11.0 — 6 November

- Instant commands: apps, volume and timers without going through the model.

## 1.10.0 — 5 November

- Recognises the Mac's apps even when their name is misheard.

## 1.9.0 — 5 November

- Owner voice recognition also on the command after the beep, more robust with TV and music in the
  background; new enrolment with real commands. Greeting at launch depends on the time of day. Gemma loads
  only when you call Jarvis without internet.

## 1.8.0 — 4 November

- Touch ID after the "yes" for delicate actions; three confirmation levels (Touch ID only for scripts,
  Shortcuts and memories).
- Deleting events and reminders, closing browser tabs by name, minimising without confirmation.
- More sentences can be added to the voiceprint; after each answer JARVIS goes back to waiting.
- New manual.

## 1.7.0 — 4 November

- Owner voice recognition on "Jarvis": enrolment and measurement.

## 1.6.0 — 4 November

- App control with the Accessibility permission.

## 1.5.0 — 3 November

- Interrupting by voice, earlier end of sentence detection, Gemma not loaded when Claude answers; wake word
  and interruption with the large Whisper (turbo).

## 1.4.0 — 3 November

- Initiative: JARVIS speaks first (appointments, reminders, battery, morning briefing).

## 1.0 – 1.3 — 2 and 3 November

- 1.0: local voice assistant for macOS (wake word, Whisper, Gemma with Ollama, neural voice, HUD).
- Local model out of RAM when unused; robust start-up with Whisper models from disk.
- Robotics: ROS 2, Robot Console, Arduino and Bambu Studio.
- Vision: screen and camera, also the iPhone camera through Continuity Camera.
- Security: confirmations, defence against instructions hidden in content, audit log, privacy mode.
- More reliable wake word, timing diagnostics, typo-tolerant file search.
- HUD showing who is answering; choice of Claude model (Haiku, Sonnet, Opus); Claude online and Gemma offline.
- Personal Whisper vocabulary, learned with Claude Opus.
