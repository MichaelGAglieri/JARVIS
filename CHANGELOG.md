# Changelog

Every version was built, installed and tested on the Mac (and on the iPhone and iPad app when it was
involved) before moving to the next one. All dates are in 2026.

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
