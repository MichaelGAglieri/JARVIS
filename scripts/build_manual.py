import math, sys
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle as PS
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Frame, NextPageTemplate, PageBreak, PageTemplate, Paragraph, Spacer,
                                Table, TableStyle, KeepTogether, Flowable)

OUT = sys.argv[1]
F = "/System/Library/Fonts/Supplemental/"
for n, f in [("A", "Arial.ttf"), ("AB", "Arial Bold.ttf"), ("AI", "Arial Italic.ttf"), ("C", "Courier New.ttf")]:
    pdfmetrics.registerFont(TTFont(n, F + f))
pdfmetrics.registerFontFamily("A", normal="A", bold="AB", italic="AI", boldItalic="AB")

EDITION, EDITION_SHORT, VERSION = "8 NOVEMBER 2026", "8 NOV 2026", "1.30.2"
NAVY = colors.HexColor("#12293E"); TEAL = colors.HexColor("#0B7F91"); INK = colors.HexColor("#22313F")
GREY = colors.HexColor("#6B7B88"); ROW = colors.HexColor("#EDF5F7"); LINE = colors.HexColor("#CFDDE3")
CREAM = colors.HexColor("#FFF6E5"); AMBER = colors.HexColor("#E7A63C"); MINT = colors.HexColor("#E9F7F8")
CYAN = colors.HexColor("#3CC7D6"); PALE = colors.HexColor("#BDF1F6")

kick = PS("k", fontName="AB", fontSize=8, textColor=TEAL, spaceAfter=6, leading=10)
h1 = PS("h1", fontName="AB", fontSize=24, leading=28, textColor=NAVY, spaceAfter=4)
sub = PS("sub", fontName="A", fontSize=9.5, leading=13, textColor=GREY, spaceAfter=10)
h2 = PS("h2", fontName="AB", fontSize=12.5, leading=15, textColor=TEAL, spaceBefore=9, spaceAfter=4)
p = PS("p", fontName="A", fontSize=9.6, leading=13.6, textColor=INK, spaceAfter=5)
small = PS("s", parent=p, fontSize=8.3, leading=11.5, textColor=GREY)
bul = PS("b", parent=p, leftIndent=11, bulletIndent=1, spaceAfter=3)
cell = PS("c", parent=p, fontSize=8.8, leading=12, spaceAfter=0)
head = PS("th", parent=cell, fontName="AB", textColor=colors.white)
code = PS("code", fontName="C", fontSize=9, leading=12, textColor=NAVY, backColor=ROW, borderPadding=(4, 6, 4, 6),
          leftIndent=6, spaceBefore=4, spaceAfter=8)
call_t = PS("ct", parent=p, fontName="AB", spaceAfter=2)
toc = PS("toc", parent=cell, fontSize=9.5)

W = A4[0] - 2 * 22 * mm
sections = []  # (index title, page)


class Bookmark(Flowable):
    """Marks the page of a section, for the table of contents."""
    def __init__(self, key, label):
        super().__init__(); self.key, self.label = key, label; self.width = self.height = 0
    def draw(self):
        self.canv.bookmarkPage(self.key)
        PAGES[self.key] = self.canv.getPageNumber()


def table(rows, widths=(0.3, 0.7), header=True):
    data = [[Paragraph(c, head if header and i == 0 else cell) for c in r] for i, r in enumerate(rows)]
    t = Table(data, colWidths=[W * w for w in widths], repeatRows=1 if header else 0)
    st = [("VALIGN", (0, 0), (-1, -1), "TOP"), ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
          ("LEFTPADDING", (0, 0), (-1, -1), 7), ("RIGHTPADDING", (0, 0), (-1, -1), 7),
          ("LINEBELOW", (0, 0), (-1, -1), 0.4, LINE)]
    if header: st.append(("BACKGROUND", (0, 0), (-1, 0), NAVY))
    for i in range(1 if header else 0, len(rows)):
        if (i % 2) == 0: st.append(("BACKGROUND", (0, i), (-1, i), ROW))
    t.setStyle(TableStyle(st))
    return [t, Spacer(1, 7)]


def callout(title, text, warn=True):
    t = Table([[[Paragraph(title, call_t), Paragraph(text, PS("x", parent=p, spaceAfter=0))]]], colWidths=[W])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), CREAM if warn else MINT),
                           ("LINEBEFORE", (0, 0), (0, -1), 3, AMBER if warn else CYAN),
                           ("LEFTPADDING", (0, 0), (-1, -1), 11), ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                           ("TOPPADDING", (0, 0), (-1, -1), 7), ("BOTTOMPADDING", (0, 0), (-1, -1), 8)]))
    return [Spacer(1, 3), KeepTogether(t), Spacer(1, 7)]


def bullets(*items): return [Paragraph(i, bul, bulletText="•") for i in items]
def P(t): return [Paragraph(t, p)]
def H(t): return [Paragraph(t, h2)]
def S(t): return [Paragraph(t, small)]


SECTIONS = []
def section(key, index_title, title, subtitle, *blocks):
    SECTIONS.append((key, index_title, title, subtitle, blocks))


section("start", "First launch and permissions", "First launch and permissions", "Getting the app ready for everyday use.",
    H("1. Open the app"), P("Open JARVIS from Applications. On first launch allow microphone access and wait for AVVIO SISTEMI (system start-up) to finish. The Whisper models are downloaded and optimised on first use: you need a connection during this preparation."),
    H("2. Check that it is ready"), P("In the HUD check that IN ATTESA (waiting) appears under the reactor. Hover over the window and open the Modules panel (the stack of sheets). For the free wake word it must show “JARVIS” ATTIVA · WHISPER. The Control + Option + Space shortcut lets you speak even without the wake word."),
    H("3. Try a simple request"), P("Say “Jarvis, what time is it?”. Check in the conversation that the phrase was transcribed correctly. Then try “open Reminders” and “quit Reminders”."),
    H("4. Enrol your voice"), P("From Settings › Riconoscimento della mia voce (voice recognition): 18 sentences read aloud, about 2 minutes. See the dedicated chapter."),
    H("5. Grant permissions when needed"),
    table([["Feature", "Permission or preparation"],
           ["Listening and voice commands", "Microphone: System Settings › Privacy & Security › Microphone."],
           ["App control", "Accessibility: Privacy & Security › Accessibility › JARVIS."],
           ["Calendar and Reminders", "Access to their data; the requests appear on first use."],
           ["Mail, Music and system", "Automation of the apps involved. Mail must have an account configured."],
           ["Recipients by name", "Contacts, to look up the person’s address."],
           ["Screen analysis", "Screen & System Audio Recording, in Privacy & Security."],
           ["Photos of objects or circuits", "Camera; using the iPhone’s needs Continuity Camera."],
           ["Protected folders", "Desktop, Documents, Downloads and similar: macOS asks for permission on the first search."]]),
    callout("Launch at login", "You can change this in Settings › System › Launch JARVIS at login.", warn=False))

section("voice", "Talking to Jarvis and using the interface", "Voice and interface", "How to wake it, talk to it and read the HUD.",
    table([["Action", "How"],
           ["Command in one sentence", "“Jarvis, set a 25 minute study timer”."],
           ["Call and request apart", "Say “Jarvis”, wait for the beep and speak right away. It does not answer “Yes, sir?”: it answers only at the end of the sentence."],
           ["Keyboard activation", "Control + Option + Space. Press it again to cancel listening or interrupt an answer."],
           ["Immediate acknowledgment", "When you ask it to do or check something it answers at once, for example “Right away, sir” or “One moment, sir”, and then works. If it takes more than 10 seconds it warns once. Greetings and small talk just get an answer."],
           ["After the answer", "It goes back to waiting: you can talk freely, and for a new command say “Jarvis” again. It keeps listening for a few seconds only if it waits for a “yes” or “no”. After one of its questions it waits 8 seconds for your answer, without you saying “Jarvis” again."],
           ["Interrupting it", "“Stop”, “basta”, “fermati”, “zitto” or “silenzio”, with or without “Jarvis”. They stop it in about a second and also stop connected robots."],
           ["Hide / show", "Esc or × hide the HUD. The icons appear when you hover over the reactor. From the Jarvis menu choose Show HUD."],
           ["Reset the conversation", "Jarvis menu › New conversation. Saved memories stay."],
           ["Quit the app", "Jarvis menu › Quit JARVIS."]]),
    H("HUD"), P("The HUD is the reactor alone, on a translucent background that fades into the desktop, with the state written below. It reacts to listening and to the voice, and moves by dragging it. Hovering shows the icons in a circle around the reactor: on the left the five panels Phrases, Log, Activity, Modules and Protocol, which open to the side, one or all together; on the right the NUCLEUS, the settings gear and ×. A second click on an icon closes its panel."),
    P("In the PROTOCOL panel the dot ● shows who is answering right now: LOCALE (local) or CLAUDE. Below you can choose HAIKU, SONNET or OPUS."),
    S("Main states: IN ATTESA (waiting) → IN ASCOLTO (listening) → ELABORAZIONE (processing) → ANALISI (thinking) → ESECUZIONE (running, when a tool is needed) → RISPOSTA (answering). ANOMALIA (error) shows a problem with a short detail."),
    H("NUCLEUS on the desktop"), P("The button with concentric circles shrinks the HUD to the round reactor, which you can drag. It lives above the wallpaper and below the windows. A click reopens the HUD exactly around the NUCLEUS, like a magnification of it; the right button opens a small menu. When you open a central panel of the desktop widgets, the NUCLEUS hides and comes back when it closes."),
    callout("Hiding does not turn the microphone off", "Esc, × and NUCLEUS mode leave Jarvis working. To stop listening use privacy mode or quit the app. Privacy mode turns off at every JARVIS restart."))

section("voiceprint", "Owner voice recognition", "Owner voice recognition", "Making “Jarvis” work only with your voice.",
    P("JARVIS compares whoever says “Jarvis” with a voiceprint of your voice and silently ignores voices that are too different. Everything happens on the Mac with a local model. The audio is not kept: only numbers remain, from which the voice cannot be rebuilt."),
    table([["Mode", "What it does"],
           ["Off", "No voice check: it answers anyone who says “Jarvis”."],
           ["Observe only", "Blocks nobody, writes the score to voce.log. Useful to choose the strictness."],
           ["Active", "Ignores voices below the chosen strictness. Current setting: 0.45; with loud TV or music JARVIS checks small windows and lowers the threshold by itself."]]),
    H("Enrolling and improving the voiceprint"),
    *[bullets("<b>Record my voice:</b> 18 sentences, about 2 minutes. Replaces the previous voiceprint.",
              "<b>Add sentences:</b> another 15 “Jarvis” added to the previous ones. At each beep change distance, direction or tone. It can be repeated.",
              "<b>Add commands:</b> 24 real commands to read, in Italian and English. They teach the voice of whole sentences. It can be repeated.",
              "<b>Delete the voiceprint:</b> removes voiceprint and scores from the Mac.")],
    H("How to read the strictness"),
    P("The score says how much a phrase resembles your voiceprint. Higher strictness: fewer strangers get through, but JARVIS also ignores you more often. From afar your voice scores much lower: that is why sentences recorded at different distances are needed."),
    callout("What it does not check", "It checks “Jarvis” and the command said after the beep: a phrase said by others, or by the TV, is silently ignored. Anyone can give the “yes” to confirmations. Control + Option + Space always works and “stop” works for everyone. If the check fails, JARVIS answers anyway."),
    callout("It is not a lock", "A similar voice or a recording of yours can fool it. That is why the most delicate actions also ask for Touch ID, which a voice cannot imitate."),
    H("If it ignores you or answers others"),
    bullets("It ignores you from afar: use <b>Add sentences</b> from that distance, or lower the strictness a little.",
            "It answers another person: raise the strictness a little and try again."),)

section("settings", "Settings and personalisation", "Settings", "Open the gear in the HUD or Settings from the Jarvis menu.",
    table([["Section", "Options and use"],
           ["Activation", "Always listen for “Jarvis”; optional Picovoice key and its sensitivity.<br/>Continue the conversation without repeating “Jarvis”: <b>off</b>, turn it on to keep listening after every answer.<br/>Interrupt by voice. Echo cancellation: off, on a MacBook Air it makes the microphone almost mute."],
           ["Owner voice recognition", "Record, Add sentences, Add commands, mode (Off / Observe only / Active), strictness, Delete the voiceprint."],
           ["Voice", "Neural voice (Qwen3 in Italian, Kokoro in English) and speed; Apple voices as a fallback."],
           ["Brain", "Local model, Ollama address, your name."],
           ["App control", "Let JARVIS use the buttons and fields of apps.<br/>Touch ID for very delicate actions."],
           ["Initiative", "Appointments, reminders, study, battery, morning briefing, quiet hours."],
           ["NUCLEUS", "Dark disc behind the NUCLEUS: makes the reactor readable on light wallpapers."],
           ["System", "Greet at launch and Launch JARVIS at login."]], widths=(0.27, 0.73)),
    P("Press <b>Save</b> to apply the changes. Launch at login changes at once with its switch."),
    H("Reference values"),
    table([["Local model", "gemma4:12b-it-qat, kept in memory for 30 minutes and unloaded before RAM fills up (below 20 % free)."],
           ["Brain", "Claude Sonnet with internet, Gemma without."],
           ["Transcription", "Whisper large-v3 turbo, also for “Jarvis” and for “stop”."],
           ["Neural voices", "Lewis for English, Qwen3 imitating a synthetic voice for Italian."],
           ["Quiet hours for alerts", "From 23:00 to 8:00."],
           ["Test mode", "Off."]], header=False, widths=(0.27, 0.73)),
    callout("Advanced configuration", "Settings live in config.json in Jarvis’s data folder: userName, userFullName, userAbout, vocabulary, notesFolders and labProject are personal. For manual edits quit the app first, keep a copy and keep the JSON valid."))

section("mac", "Mac, files, music and web", "Mac, files, music and web", "Useful requests while studying and developing.",
    table([["Area", "Examples to say"],
           ["Applications", "“Open Visual Studio Code”. “Which apps are open?”. JARVIS knows every app on the Mac and understands mangled names (“PDF Graft” opens PdfCraft); if two are similar it asks which. Opening and quitting apps, volume and timers run at once, without the model. macOS apps can also be called by their Italian names: Orologio, Meteo, Contatti.<br/>“Quit Safari”, “quit Safari and Netflix”, “quit all apps”: no confirmation, unless there are unsaved changes.<br/>“Close YouTube”: if it is a browser tab, it closes that tab."],
           ["Windows", "“Minimise the Safari window”: at once, without confirmation."],
           ["Audio and system", "“Volume to 30”. “Mute”. “Turn on dark mode”. “Turn off the screen”. “How is the battery?”."],
           ["Music", "“Play Bohemian Rhapsody by Queen”. “Play the Study playlist”. “Next song”. “Pause the music”. “What song is this?”. It searches your playlists and the Apple Music catalog, with an active subscription. From the catalog it can take a few seconds, up to half a minute if Music is closed."],
           ["TV", "“Turn on the TV”. “Turn off the TV”. “Turn up the TV volume”. “Open Netflix on the TV”. The first time the TV asks on screen to allow it. To turn it on from off, power on with mobile must be enabled in the TV’s expert network settings."],
           ["Protocols", "“Modalità studio” (study mode), also with the subject: “modalità studio Chimica”. “Fine studio” (end of study). “Buongiorno”. “Buonanotte”. One phrase, several actions: see the Protocols chapter. They are changed in protocolli.json."],
           ["Files and folders", "“Find the firmware file”. “Open the certificate”. “Show the project folder in the Finder”."],
           ["Projects", "“Which robotics projects do I have?”. “How is the MioRobot project doing?”. “What did I work on this week?”."],
           ["Web and weather", "“Search ROS 2 documentation on topics”. “Open github.com”. “What’s the weather in Rome?”."],
           ["Timers", "“25 minute study timer”. “How long is left?”. “Cancel the study timer”."],
           ["Shortcuts", "“Which shortcuts do I have?”. “Run the Home shortcut”: “yes” and Touch ID."]], widths=(0.22, 0.78)),
    H("Making requests more precise"),
    P("Give the name of the project, file or app. File search uses Spotlight and name matching that tolerates errors; project analysis starts from ~/Projects. Dynamic web pages or pages behind a login may come back incomplete."),
    H("Quitting apps"),
    P("If macOS reports unsaved changes, JARVIS asks for a “yes”. If the app does not report them it quits normally: usually the app itself asks whether to save, but some may quit without a word. “Quit all apps” leaves JARVIS, Finder, Übersicht and LuLu open. Quitting Fusion leaves Autodesk system services running (licence and updates): that is normal."),
    callout("Apps and executable files", "Opening an app by name is direct. Opening a program, a script or an installer from a path asks for “yes” and Touch ID, like Shortcuts.", warn=False))

section("control", "App control", "App control", "JARVIS uses the buttons and fields of apps for you.",
    P("With the Accessibility permission JARVIS reads a window, presses buttons, types into fields and uses the keyboard. If an app does not expose its elements it looks at the window and clicks a point. It works <b>only with Claude</b> and never in privacy mode."),
    bullets("“Jarvis, open the Calculator and do 7 plus 8.”", "“Jarvis, in the open page look for the lab opening hours.”", "“Jarvis, in Notes delete the shopping note.”"),
    Spacer(1, 4),
    table([["What it asks", "Actions"],
           ["Nothing", "Everything else, at once: reading, scrolling, opening, pressing, clicking, typing, closing, deleting what you asked to delete, printing, moving the robot."],
           ["Spoken “yes”", "Only three things: buying or paying, a password, sending an email (in Mail or prepared by JARVIS). The robot asks only for a move Claude judges dangerous."],
           ["Forbidden", "Password managers, banks (also in the browser), System Settings, Installer, terminals, editors with a terminal (VS Code, Xcode, Cursor), assistants that run commands, LuLu, JARVIS itself. Password fields are never read and never typed into."]], widths=(0.2, 0.8)),
    H("Stopping it"), P("“Stop” also stops a running sequence, even while JARVIS works silently. After a “yes” the sequence does not carry on by itself: you have to tell it to continue."),
    H("Security"), P("What it reads in apps is data, not an order: a page that “asks” it to do something is not obeyed. Every action goes to audit.log."),
    callout("Turning it off", "Settings › App control. Without app control all the other tools remain available.", warn=False))

section("agenda", "Calendar, reminders and mail", "Calendar, reminders and mail", "Organising your schedule with the apps already set up on the Mac.",
    H("Calendar"),
    bullets("“What’s on tomorrow?”.", "“Create an event Robot review on Thursday at 3 pm, 30 minutes, in the lab”.", "“Delete the Robot review event on Thursday”."),
    P("Without a duration it lasts 60 minutes, with an alert 15 minutes before. It deletes at once what you ask. If several events have the same name it asks which; of a repeating event it deletes only that occurrence. Calendar has no trash."),
    H("Reminders"),
    bullets("“Remind me to buy servos tomorrow at 9”.", "“What do I have to do?”.", "“Mark buy servos as done”.", "“Delete the reminder buy servos”."),
    H("Mail"),
    P("“Any new mail?”, “find Marco’s emails about the project”, “read me the one about the exam”. To send, give recipient, subject and text; the name is looked up in Contacts."),
    table([["You", "“Write an email to [address], subject Robot review, text: can we meet tomorrow at 3 pm?”."],
           ["Jarvis", "Sums up recipient, subject and text, and waits."],
           ["You", "“Yes” to send, “no” to cancel."]], header=False, widths=(0.12, 0.88)),
    H("Notes"), P("There is no direct command: JARVIS uses the Notes app through app control."),
    H("Briefing"), P("“Good morning Jarvis” asks for a summary with weather, appointments, reminders, unread mail, study and projects. It also starts by itself: see the Initiative chapter."))

section("initiative", "Initiative: Jarvis speaks first", "Initiative", "Jarvis warns you without being asked.",
    table([["Alert", "When"],
           ["Appointments", "10 minutes before every timed event. Not all-day or cancelled ones."],
           ["Reminders", "At the due time, for reminders with a time."],
           ["Study", "Every 2 hours of a session opened with “I’m starting to study…”, it suggests a break."],
           ["Battery", "At 20 % or less without a charger, once. Again only after plugging it in."],
           ["Briefing", "At the first activation of the day between 5 and 12: it answers first, then gives the briefing. Once a day."]], widths=(0.22, 0.78)),
    H("When it waits"), P("Alerts stay queued if JARVIS is in privacy mode, in a conversation or with a pending confirmation, and during quiet hours (from 23:00 to 8:00). Those no longer relevant are dropped: an appointment that already started is not announced. Alerts already given are not repeated after a restart."),
    H("Adjusting them"), P("Settings › Initiative: every alert has its own switch, and you can change the quiet hours."),
    callout("Bambu Studio", "With the printer configured in Settings, JARVIS warns if the print finishes, pauses or gets stuck, and answers “how is the print going?”. It can also load and unload filament and print, always through Bambu Studio’s buttons.", warn=False))

section("study", "Study, projects and memory", "Study, projects and memory", "Measuring time, reading the state of projects and saving facts.",
    table([["Request", "Result"],
           ["“I’m starting to study Chemistry”", "Starts a study session with that name."],
           ["“I’m starting work on the MioRobot project”", "Starts a project session."],
           ["“I’ve finished studying”", "Closes the active session and reports its length."],
           ["“How much did I study this week?”", "Sums up the time recorded in the period."],
           ["“How much did I work yesterday?”", "Report of the previous day’s activities."]], widths=(0.42, 0.58)),
    P("Only one session can be active: starting another closes the previous one. Close it when you finish."),
    S("Sessions are in activity.json. A session left open for more than six hours is closed at six hours."),
    H("Searching your notes"), P("“Search my notes for Ohm’s law” or “what do the Electronics handouts say about capacitors?” search inside PDF, Word, PowerPoint and text files in the folders chosen in the settings (at first Documents/Appunti): personal documents stay out. JARVIS answers from the passages found and quotes document and page; if they are not enough it says so. The index builds itself in the background on the Mac, at low priority, and updates every 6 hours. Scanned pages are read on mains power and with the Mac cool, so they can take hours. Search also understands concepts: “shortest path in a graph” finds pages on shortest paths even if you use different words from the book, and passages found this way are flagged. It corrects misheard names (“Tevenin” becomes “Thevenin”, saying so). The first concept question can take a few seconds more, because the Mac loads the bge-m3 model, and if that model is missing search works by words only."),
    H("Knowing your projects"), P("“How is the MioRobot project doing?” reads README, Git branch, recent commits and changes. “What did I work on this week?” uses the changes indexed by Spotlight: it describes traces in files, without measuring hours."),
    H("Persistent memory"),
    bullets("“Remember that the chemistry exam is on 15 December” saves a fact.", "“What do you remember about me?” lists the facts.", "“Forget the chemistry exam” asks for “yes” and Touch ID."),
    H("A vocabulary that learns"), P("If two requests in a row fail or you correct it (“you didn’t get it”, “I said…”), JARVIS passes the request to Claude Opus. Opus works out what you meant and points out the misheard words, which enter Whisper’s vocabulary: from then on it spells them correctly."),
    callout("A memory is not a notification", "For an alert at a date and time use a reminder. “New conversation” resets the dialogue, not the memories."))

section("protocols", "Protocols, quizzes and flashcards", "Protocols and review", "One phrase for several actions, and studying from your notes.",
    H("Study and daily protocols"),
    table([["Phrase", "What it does"],
           ["“Modalità studio” (study mode)", "Starts the study session, opens the notes folder and a 25 minute timer. It does not turn on Do Not Disturb: macOS allows it only through a Shortcut you make yourself."],
           ["“Fine studio” (end of study)", "Closes the session, cancels the timer and says how long you studied."],
           ["“Buongiorno” (good morning)", "Weather, schedule, reminders, mail and any print in progress."],
           ["“Buonanotte” (good night)", "Closes the session, says what you have tomorrow and then turns off the screen. It does not quit apps."]], widths=(0.3, 0.7)),
    H("Quizzes and flashcards"),
    P("“Quiz me on Chemistry” asks one question at a time taken from your notes, corrects you citing the file and gives the score at the end. “Make flashcards on Fourier series” saves them with their source: without a source in the notes a card is not added. “Let’s review the flashcards” brings back the ones due: answer well and they come back later and later, get them wrong and they come back tomorrow. They live in schede.json, only on the Mac."))

section("brains", "Claude and Gemma", "Claude and Gemma", "Who answers, and how to change it.",
    table([["Situation", "Who answers"],
           ["With internet", "<b>Claude Sonnet</b>, through Claude Code and your subscription. No paid API. Requests count towards your plan’s limits."],
           ["Without internet", "<b>Gemma</b> locally, automatically. It loads into memory only when you say “Jarvis” without internet: the first answer takes about 45 seconds. When the network is back, Claude returns."],
           ["Claude does not answer", "Jarvis says so and tries Gemma."]], widths=(0.22, 0.78)),
    H("Changing by voice"),
    bullets("“Use Opus”, “switch to Sonnet”, “use Haiku”: from now on. Opus is the most capable and uses more of your limits; Haiku is the fastest.",
            "“Use Opus to explain this error”, “ask Claude…”: one request only.",
            "“Back to local”: stays on Gemma even after a restart, until you say “use Claude”."),
    P("The same can be done with the LOCALE / CLAUDE and HAIKU / SONNET / OPUS buttons in the PROTOCOL panel."),
    H("Gemma and memory"),
    bullets("With Claude set, Gemma does not load when the app opens or when the Mac starts.",
            "Once loaded it stays in memory for 30 minutes. If you open heavy apps and free RAM drops below 20 % it leaves by itself.",
            "“Scarica Gemma dalla memoria” (unload Gemma) removes it at once. It stays on disk.",
            "The first load takes about 45 seconds."),
    H("Preparing Claude Code"), P("If Claude does not answer, from Terminal:"),
    [Paragraph("claude auth status<br/>claude auth login --claudeai", code)],
    H("What data Claude receives"), P("The request, the memories in context, recent exchanges and tool results. If you ask it to look at a screenshot or a photo, it receives the image. With Gemma requests stay on the Mac."))

section("vision", "Screen and camera", "Screen and camera", "Asking for help on what you see or on an object shown to the Mac.",
    H("Looking at a window"), P("Bring the window to the front and ask “Jarvis, explain this error” or “summarise this page”. Jarvis uses the frontmost window, leaves itself out and, if it finds no suitable one, uses the whole screen."),
    bullets("For code or a terminal: make message, line and context readable before calling it.", "For the whole screen: “Jarvis, look at the whole screen and tell me what you see”."),
    S("Permission: System Settings › Privacy & Security › Screen & System Audio Recording."),
    H("Showing a component"), P("Frame the object and ask “Jarvis, what is this component?” or “look at this circuit and describe the connections”. You can say “use the Mac camera” or “use the iPhone”. By default it prefers the iPhone, if available with Continuity Camera."),
    H("For a useful image"),
    bullets("Use enough light and show labels and markings as sharply as possible.", "Ask a precise question: “read the component’s marking” is better than “look at this”.", "Images are scaled to 1600 pixels on the long side: fine details may be lost."),
    callout("Privacy and interpretation", "Privacy mode blocks screen and camera. Images are not saved; with Claude they are sent to the service. A visual description can contain errors: check markings and connections before working on the circuit."))

section("ros", "ROS 2 and the simulated lab", "ROS 2 and the simulated lab", "Starting the simulation and querying the ROS system.",
    H("Preparation"), P("The integration uses the project ~/Projects/ros2_lab (change it with labProject in the settings file) and needs pixi. The ROS bridge starts on the first request. The default domain is 42. The lab commands are in Italian."),
    table([["Step", "Request or operation"],
           ["1. Start", "“Jarvis, start the lab”. Opens Webots and the nodes."],
           ["2. Simulation", "Press Play in Webots when the environment is ready."],
           ["3. Check", "“How is the lab doing?”."],
           ["4. Command", "“Sposta campione a in postazione 1” (move sample a to station 1)."],
           ["5. Return", "“Riporta campione a” (bring sample a back)."],
           ["6. Stop", "“Jarvis, stop everything”."]], widths=(0.2, 0.8)),
    H("Nodes, topics and messages"),
    bullets("“Which nodes and topics are running?” queries the ROS 2 graph.", "“What does /laboratorio/stato publish?” reads one message; if no data arrives it times out.", "“Publish [message] on [topic]” runs at once. A new topic may need the message type."),
    callout("Simulation and real robot", "Lab commands concern the simulation. A generic ROS publication can reach any node in the domain: it runs at once, without confirmation, so state topic and content clearly. “Stop” halts the active links."),
    S("Jarvis closes its own ROS bridge when it exits, but not necessarily the windows and processes started by the lab."))

section("console", "Robot Console", "Robot Console", "Connecting the local API, preparing a program and running it.",
    H("1. Connect the session"), P("In Robot Console open Diagnostics and ROS2 › Python API. Press Start local API, then Copy this session’s token. Say “Jarvis, connect to Robot Console”. The token stays in memory only."),
    H("2. Read the state and the targets"), P("“How is the robot?”, “which targets are saved?”. A permission to plan does not mean the robot is moving."),
    H("3. Prepare the plan"),
    bullets("“Prepare a move to the Part target”.", "“Prepare the pick and place from Part to Bin”.", "“Prepare a return to HOME”."),
    P("Planning replaces the instructions of the active project and runs at once. The robot does not move with this operation alone."),
    H("4. Run it"), P("“Run the prepared program” starts without a spoken confirmation, unless the model judges the move dangerous. On the real robot the approval in Studio › Approve and run is also needed, within 60 seconds. Jarvis announces aloud when the program ends or stops."),
    callout("Stop available, without confirmation", "“Jarvis, stop”, “basta”, “stop the robot” or “stop everything” ask the active links to stop. The voice command depends on microphone, recognition and communication: <b>it does not replace a physical emergency stop</b>."),
    callout("At once, without confirmations", "Robot and Arduino run at once: JARVIS asks for a “yes” only for a move it judges dangerous. The approval in Studio remains the check that matters, and STOP never asks for confirmation."),
    S("If you restart Robot Console or the token changes, connect again. Without a prepared plan, running is refused."))

section("arduino", "Arduino and Bambu Studio", "Arduino and Bambu Studio", "Preparing firmware and handling 3D prints.",
    P("Ask “which boards are connected?”. Jarvis uses arduino-cli, also the one bundled with Arduino IDE. Sketches are looked for under ~/Projects."),
    table([["Operation", "Request and behaviour"],
           ["Compile", "“Compile the firmware sketch”. Checks the code; does not upload it."],
           ["Upload", "“Upload the firmware sketch to port [port]”. Compiles and uploads at once, without confirmation."],
           ["Serial read", "“Read the board’s serial port at 115200 baud for 4 seconds”. Up to 15 seconds."]], widths=(0.2, 0.8)),
    P("Without a port some operations pick the first board found. The board type uses the given value, the detected one or, as a fallback, Arduino Mega 2560. If you use a different board, state port and type in the request."),
    callout("Busy port and board reset", "Jarvis may refuse a serial port already in use. Opening the serial port usually resets the board; an upload replaces the firmware and can change its behaviour."),
    H("Bambu Studio"), P("“Open Bambu Studio” launches the app. “Open the gripper in Bambu Studio” looks for a model under ~/Projects: 3MF, STL, STEP/STP and OBJ, preferring a 3MF project. “Unload the filament” and “load the filament” press the right button after reading its label and check on the printer that the operation started; during a print they are refused. With the external spool the operation stops halfway: JARVIS tells you to pull out or insert the filament and, when the sensor confirms it, presses “Finito, Continua” (done, continue). If the printer asks for something else, it tells you to look at its screen. “Print the gripper” opens the model, slices the selected plate, tells you duration and grams and starts the print. “Stop the print” stops it. If Bambu Studio shows a warning, JARVIS reports it and does not close it by itself. While it works, Bambu Studio comes to the front and the pointer moves: do not use the mouse in those seconds. Always check that the plate is clear and that orientation, material and settings are right."))

section("iphone", "iPhone and iPad app", "iPhone and iPad app", "Talking to JARVIS from the phone, at home and away.",
    P("The app is a remote: Whisper, Claude, Gemma and the tools stay on the Mac. The phone carries your voice and shows and speaks the answers."),
    H("Turning it on the first time"),
    *bullets("On the Mac: Settings, iPhone section. Turn on the iPhone app link and press Save. macOS asks whether JARVIS can accept connections: choose Allow.",
             "On the phone: open the app, which asks for local network permission. In Pairing scan the QR code shown by the Mac, or type the code.",
             "The dot at the top turns blue and the Mac’s name appears."),
    H("Using it"),
    table([["Gesture", "Effect"],
           ["Say “Jarvis”", "With the app open. A loud sound and a vibration, then speak: it stops by itself when you stop."],
           ["Tap the microphone", "Speak: it stops by itself when you stop, or when you tap again."],
           ["Hold the microphone", "Speak and release."],
           ["“Hey Siri, talk to JARVIS”", "Opens the app already listening. It can also go on the Action button."],
           ["Type in the field", "Like saying it aloud, but without a voice to recognise."],
           ["Tap the reactor", "Stops JARVIS while it works or speaks. While listening it cancels, and nothing is sent; the same if you say “annulla”."],
           ["Gear", "Pair again or forget this Mac."]], widths=(0.3, 0.7)),
    P("Answers asked from the phone do not come out of the Mac’s speakers. If JARVIS asks a question, answer by pressing again. On the phone you also see what happens on the Mac: the phrase understood and the answer."),
    callout("What cannot be done from the phone", "Moving the robot, publishing on ROS, moving the lab samples, uploading to Arduino, changing the filament, which must be pulled by hand. Prints can be sent, also from away. STOP and reading the state work. No Touch ID confirmations, which must be given on the Mac. A “yes” counts only on the side the request came from. With privacy mode on the Mac, the phone cannot turn it back on."),
    P("At every opening the app asks for Face ID or the phone’s passcode."),
    H("Installing and reinstalling"),
    P("Connect the iPhone or iPad with a cable, unlock it and double-click “Installa su iPhone e iPad.command” in the project folder; it reads your Apple Team and bundle identifier from local.env. With a free Apple account it must be redone every 7 days, and the app reminds you two days before; pairing and settings stay. With the paid Apple Developer Program the signature lasts a year."),
    H("On iPad"),
    P("It is the same app, with the same pairing code, and it rotates in every direction. The Mac follows one device at a time, the last one opened: the other pauses and resumes by reopening the app or tapping “Usa qui” (use here). To use it away from home the iPad needs Tailscale too."),
    H("Away from home"),
    P("Install Tailscale, free, on Mac and iPhone with the same account, and keep it on. The first time connect at home: the app receives the Mac’s address and remembers it. From then on it also works on 4G. You can ask something, close the app and reopen it later: the Mac finishes the work and you find the answer written. Away from home JARVIS does not use the Mac’s camera."),
    H("Looking at the Mac screen"),
    P("The monitor button at the top of the app shows the Mac screen while the view is open, as H.264 video at the Mac’s resolution. Zoom with two fingers or a double tap. Rotating the phone, or with the phone button at the top, it goes to landscape with the full keyboard: the controls sit in a column on the side and the keyboard opens from its button. Below you have the square to stop JARVIS, the microphone and the text field for more commands. With the cursor button you control the Mac by hand: a tap is a click, two taps a double click, a long press a right click, one finger dragging moves windows and selects text, two fingers scroll, and you can type with Return, Delete and Esc. It turns off at every opening. Every click goes to the log; typed text does not. With privacy mode on the view closes."),
    H("Limits"),
    P("The Mac must be on with JARVIS open. On mains power with the link on it does not sleep by itself, but the screen still turns off. With the lid closed or on battery it sleeps, and then it cannot be reached. If you lock the phone or switch app you lose the voice, not the work. There are no notifications: you see the result by reopening the app. To really stop JARVIS tap the reactor."),
    S("The link is encrypted and the code never travels over the network. “Change code” locks out the paired phone. Every connection goes to audit.log."))

section("privacy", "Privacy and confirmations", "Privacy and confirmations", "Which actions run directly and which wait for your consent.",
    H("Three confirmation levels"),
    table([["Level", "Actions"],
           ["No confirmation", "Everything else, at once. Closing apps, windows and tabs; opening apps; volume, Music, timers, new memories. Creating, completing and deleting events, reminders and notes when you ask. Clicks, typing and shortcuts in apps. Printing and stopping a print. ROS, simulated lab, Robot Console plans and moves (except a move the model judges dangerous), Arduino and serial. Every action goes to audit.log."],
           ["Spoken “yes”", "Only three things: purchases (buy or pay buttons), passwords, sending email (the mail tool or the Send button in Mail). Only a short answer counts, six words at most. Links suggested by pages or emails also need a “yes” before opening."],
           ["“Yes” and Touch ID", "Opening scripts, programs and installers from a path. Running Shortcuts. Deleting JARVIS’s memories."]], widths=(0.2, 0.8)),
    P("Touch ID appears after the “yes”. Without a finger available, for example with the lid closed, macOS asks for the password. JARVIS receives only yes or no. After 30 seconds the action is cancelled. It can be turned off in Settings › App control."),
    H("Privacy mode"), P("Say “Jarvis, privacy”, use Control + Option + P or the menu. Microphone off, screen and camera blocked, app control off, grey reactor. To leave it use the keyboard or the menu. <b>It turns off at every JARVIS restart.</b>"),
    H("Where data can go"), P("Audio and transcription stay on the Mac, and so does the voiceprint. Gemma is local. Web searches, weather and websites contact the services involved. Claude receives requests and context when you use it. Calendar, Reminders and Mail sync through your accounts."),
    H("Log and content read"), P("Actions and confirmations go to audit.log: treat it as personal data. Mail, pages, files and app content are marked as data, not as instructions."),
    S("There are no tools to delete files or run free terminal commands. The effects of authorised actions remain possible, for example a Shortcut or an opened program."))

section("problems", "Troubleshooting", "If something does not work", "Start from the message in the HUD and check the service involved.",
    table([["Symptom", "Check and fix"],
           ["It does not hear “Jarvis”", "Leave privacy mode with Control + Option + P. Check the Microphone permission and “JARVIS” ATTIVA · WHISPER. Try Control + Option + Space. From afar or in a hurry it may miss it: repeat."],
           ["It hears but ignores you", "It is the voice recognition: use Add sentences or Add commands, lower the strictness or switch to Observe only."],
           ["It writes only “Grazie”", "Whisper is not understanding. <b>Before restarting note the time</b>: diagnostica.log measures the level. Then restart JARVIS."],
           ["It misunderstands the sentence", "Reduce the noise and repeat with explicit names. If you insist or correct it, the vocabulary learns."],
           ["Gemma is in memory", "Check that you did not choose LOCALE, and the connection. Say “scarica Gemma dalla memoria”. From Terminal: ollama ps."],
           ["The local model is offline", "Jarvis tries to start Ollama. From Terminal: ollama list; if it is not running: ollama serve."],
           ["Gemma’s first answer is slow", "Loading takes about 45 seconds."],
           ["You hear an Apple voice", "The neural voice is not available: run ./scripts/setup_tts.sh from the project folder."],
           ["Claude does not answer", "Check the network and claude auth status; if needed claude auth login --claudeai."],
           ["It does not control an app", "It needs Claude, outside privacy mode, with the Accessibility permission. Some apps are forbidden."],
           ["Screen or camera refused", "Turn off privacy mode and check the permissions."],
           ["Calendar / Mail unavailable", "Check the permissions and Automation in Privacy & Security."],
           ["ROS bridge not started", "Check pixi and the labProject path in the settings; press Play in Webots."],
           ["Robot Console does not connect", "Start the local API, copy the session token and say again “connect to Robot Console”."],
           ["Arduino not found / port busy", "Check arduino-cli, cable and port. Put the device in a safe state and quit the app using the port."],
           ["It does not find a file", "Check the name and Spotlight. The first time macOS may ask permission for the folder."]], widths=(0.27, 0.73)),
    S("With Übersicht, set “Send to background” only on the decorative widgets, so the interactive panels can cover the NUCLEUS."))

section("install", "Installation and data", "Installation and maintenance", "Essential technical reference for this project.",
    H("Installing or updating"), P("Apple Silicon Mac, macOS 15 or later, Swift development tools and Homebrew. Copy local.env.example to local.env and fill it in (see the README). Then from Terminal, in the JARVIS folder:"),
    [Paragraph("./scripts/setup.sh&nbsp;&nbsp;&nbsp;&nbsp;# first installation<br/>./scripts/build.sh --install&nbsp;&nbsp;&nbsp;&nbsp;# after a code change", code)],
    H("Data to keep"), P("Folder: ~/Library/Application Support/JARVIS/"),
    table([["Item", "Content"],
           ["config.json", "Settings; may contain the Picovoice key and the printer access code."],
           ["memory.json / activity.json", "Personal memories and study or work sessions."],
           ["voiceprint.json / voce.log", "Voiceprint and scores. No audio."],
           ["iphone_code", "Pairing code with the iPhone, readable only by you."],
           ["audit.log / diagnostica.log", "Action log and technical log (wake word, timings, level)."],
           ["models/ / tts/", "Whisper models, Qwen3, Supertonic and Kokoro voices, voiceprint model."]], widths=(0.3, 0.7)),
    S("For a backup quit the app and copy the folder. Timers do not survive quitting: for a lasting alert use a reminder. In normal use test mode (developerMode) stays false."),
    S(f"Manual for JARVIS version {VERSION} (Resources/Info.plist), written from the README and the sources. Commands and phrases are natural-language examples. Later changes may alter the behaviour described."))


class Doc(BaseDocTemplate):
    pass


PAGES = {}


def header_footer(c, d):
    c.saveState()
    if d.page > 1:
        c.setFont("AB", 7.5); c.setFillColor(NAVY); c.drawString(22 * mm, A4[1] - 13 * mm, "J.A.R.V.I.S. / OPERATING MANUAL")
        c.setFont("A", 7.5); c.setFillColor(GREY); c.drawRightString(A4[0] - 22 * mm, A4[1] - 13 * mm, EDITION_SHORT)
        c.setStrokeColor(LINE); c.setLineWidth(0.4); c.line(22 * mm, A4[1] - 15 * mm, A4[0] - 22 * mm, A4[1] - 15 * mm)
    c.setStrokeColor(LINE); c.setLineWidth(0.4); c.line(22 * mm, 15 * mm, A4[0] - 22 * mm, 15 * mm)
    c.setFont("A", 7.5); c.setFillColor(GREY); c.drawString(22 * mm, 11 * mm, "JARVIS project · English edition")
    c.drawRightString(A4[0] - 22 * mm, 11 * mm, f"{d.page:02d} / {TOTAL:02d}")
    c.restoreState()


def cover(c, d):
    c.saveState()
    x, y, w, h = 14 * mm, 22 * mm, A4[0] - 28 * mm, A4[1] - 36 * mm
    c.setFillColor(NAVY); c.roundRect(x, y, w, h, 6, fill=1, stroke=0)
    L = x + 15 * mm; T = y + h
    c.setFillColor(PALE); c.setFont("AB", 8); c.drawString(L, T - 18 * mm, "PERSONAL ASSISTANT FOR macOS")
    c.setFillColor(colors.white); c.setFont("AB", 34); c.drawString(L, T - 37 * mm, "J.A.R.V.I.S.")
    c.setFont("A", 20); c.drawString(L, T - 49 * mm, "Operating manual")
    c.setFillColor(PALE); c.setFont("A", 9.5); c.drawString(L, T - 58 * mm, "Voice, study, projects and robotics on your Mac.")
    cx, cy = A4[0] / 2, y + h * 0.52
    c.setStrokeColor(colors.HexColor("#4C7A8C")); c.setLineWidth(0.6); c.circle(cx, cy, 70, fill=0)
    c.setStrokeColor(CYAN); c.setLineWidth(2.4); c.circle(cx, cy, 60, fill=0)
    c.setStrokeColor(colors.HexColor("#4C7A8C")); c.setLineWidth(0.6); c.circle(cx, cy, 49, fill=0)
    c.setStrokeColor(PALE); c.setLineWidth(1.8); c.circle(cx, cy, 39, fill=0)
    c.setStrokeColor(CYAN); c.setLineWidth(0.7); c.circle(cx, cy, 30, fill=0)
    c.setFillColor(PALE); c.circle(cx, cy, 17, fill=1, stroke=0)
    c.setFillColor(NAVY); c.setFont("AB", 10); c.drawCentredString(cx, cy - 3.5, "J")
    c.setStrokeColor(PALE); c.setLineWidth(1)
    for i in range(12):
        a = math.radians(i * 30)
        c.line(cx + 72 * math.cos(a), cy + 72 * math.sin(a), cx + 78 * math.cos(a), cy + 78 * math.sin(a))
    c.setStrokeColor(colors.HexColor("#4C7A8C")); c.setLineWidth(0.5); c.line(L, y + 52 * mm, x + w - 15 * mm, y + 52 * mm)
    c.setFillColor(colors.white); c.setFont("AB", 11); c.drawString(L, y + 42 * mm, "“Jarvis, what time is it?”")
    c.setFillColor(PALE); c.setFont("A", 9)
    c.drawString(L, y + 35 * mm, "Speak: Control + Option + Space")
    c.drawString(L, y + 29 * mm, "Privacy: Control + Option + P")
    c.setFont("AB", 8); c.drawString(L, y + 17 * mm, f"EDITION {EDITION}")
    c.setFont("A", 8.5); c.drawString(L, y + 10 * mm, f"Reference: JARVIS version {VERSION}")
    c.restoreState()
    header_footer(c, d)


def story():
    st = [NextPageTemplate("body"), PageBreak()]
    st += [Paragraph("OPERATING MANUAL / 02", kick), Paragraph("Start here", h1),
           Paragraph("Clickable contents and the commands to keep at hand.", sub)]
    rows = [["Topic", "Page"]]
    for key, idx, *_ in SECTIONS:
        n = PAGES.get(key, 0)
        rows.append([f'<a href="#{key}" color="#22313F">{idx}</a>', f'<a href="#{key}" color="#0B7F91">{n}</a>'])
    st += table(rows, widths=(0.86, 0.14))
    st += callout("The essential actions",
                  "<b>Wake:</b> “Jarvis”, wait for the beep and speak. Or Control + Option + Space.<br/>"
                  "<b>Confirm:</b> only for purchases, passwords and sending email; answer “yes” or “no”, in a few words. Scripts, Shortcuts and deleting memories also ask for Touch ID.<br/>"
                  "<b>Stop it:</b> “stop” or “basta”. It also stops connected robots.<br/>"
                  "<b>Privacy:</b> Control + Option + P turns the microphone off or back on.", warn=False)
    for key, idx, title, subtitle, blocks in SECTIONS:
        st.append(PageBreak())
        st.append(Bookmark(key, idx))
        st.append(KICK(key))
        st += [Paragraph(title, h1), Paragraph(subtitle, sub)]
        for b in blocks:
            st += b if isinstance(b, list) else [b]
    # The same flowables serve both passes: a mark left by the first pass ("postponed") would stop the second.
    for f in st:
        f.__dict__.pop("_postponed", None)
    return st


class KICK(Flowable):
    """Header with the real page number."""
    def __init__(self, key): super().__init__(); self.key = key; self.width = W; self.height = 14
    def wrap(self, a, b): return (W, 14)
    def draw(self):
        c = self.canv; c.setFont("AB", 8); c.setFillColor(TEAL)
        c.drawString(0, 3, f"OPERATING MANUAL / {c.getPageNumber():02d}")


def build(path):
    d = Doc(path, pagesize=A4, leftMargin=22 * mm, rightMargin=22 * mm, topMargin=20 * mm, bottomMargin=19 * mm,
            title="J.A.R.V.I.S. - Operating manual", author="JARVIS project",
            subject="Guide to commands, settings, privacy and robotics integrations",
            keywords="JARVIS, manual, macOS, ROS 2, Robot Console, Arduino")
    fr = Frame(d.leftMargin, d.bottomMargin, d.width, d.height, leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    d.addPageTemplates([PageTemplate("cover", frames=[fr], onPage=cover), PageTemplate("body", frames=[fr], onPage=header_footer)])
    d.build(story())
    return d.page


TOTAL = 0
TOTAL = build(OUT)           # first pass: page numbers
TOTAL = build(OUT)           # second: correct contents and total
print("pages:", TOTAL, PAGES)
