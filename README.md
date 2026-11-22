# Apple Music Now Playing – Stream Deck Plugin für Windows

Zeigt den aktuell laufenden Apple-Music-Titel im Stil von Apple Music auf dem Display eines Stream Decks mit Drehreglern und steuert die Wiedergabe. Entstanden für die **Corsair Galleon 100 SD** (Tastatur mit eingebautem Stream Deck), weil es dort bisher nur eine Spotify-Anzeige gab.

> Inoffizielles Community-Projekt. Nicht verbunden mit Apple, Elgato oder Corsair.

---

## Funktionen

**Display (Drehregler)**
- **Now Playing:** Albumcover mit abgerundeten Ecken, Titel, Künstler, Fortschrittsbalken, gespielte Zeit und Restzeit. Der Hintergrund ist das weichgezeichnete Cover, wie in Apple Music.
- Lange Titel laufen als Laufschrift durch.
- Bei Pause wird das Cover abgedunkelt und zeigt ein Play-Symbol.
- **Lautstärke:** Systemlautstärke mit Symbol, Prozentwert und Balken.

**Tasten**
- Play/Pause mit dem aktuellen Albumcover als Tastenbild
- Nächster / vorheriger Titel
- Zufallswiedergabe (Shuffle) mit Statusanzeige
- Wiederholen (Aus → Alle → Einen Titel) mit Statusanzeige
- Apple Music öffnen

**Sonstiges**
- Keine Zusatzinstallation nötig: Das Plugin nutzt Node.js aus der Stream-Deck-App und die Windows PowerShell, die Windows mitbringt. Es gibt keine npm-Abhängigkeiten.
- Läuft auch, wenn die PowerShell-Skriptausführung per Richtlinie eingeschränkt ist.
- Kann optional auf andere Medien-Apps zurückfallen, wenn Apple Music nicht läuft.

---

## Voraussetzungen

| | |
|---|---|
| Betriebssystem | Windows 10 oder 11 |
| Stream-Deck-Software | 6.5 oder neuer |
| Musik-App | [Apple Music für Windows](https://apps.microsoft.com/detail/9pfhdd62mxs1) (Microsoft Store) |
| Gerät | Stream Deck mit Drehreglern und Display, z. B. Corsair Galleon 100 SD oder Stream Deck + |

Die Tasten-Aktionen funktionieren auf jedem Stream Deck.

---

## Installation

1. Lade die Datei `de.local.applemusic.streamDeckPlugin` aus den [Releases](../../releases) herunter.
2. Öffne sie per Doppelklick. Die Stream-Deck-App fragt dann nach der Installation.
3. In der Aktionsliste erscheint die Gruppe **„Apple Music“**.

**Manuelle Installation** (falls der Doppelklick nicht klappt):
1. Benenne die Datei in `.zip` um und entpacke sie.
2. Kopiere den Ordner `de.local.applemusic.sdPlugin` nach `%APPDATA%\Elgato\StreamDeck\Plugins\`.
3. Starte die Stream-Deck-App neu.

**Update:** Beende die Stream-Deck-App über das Tray-Symbol, lösche den alten Ordner `de.local.applemusic.sdPlugin` und installiere die neue Version. Die Stream-Deck-App ersetzt ein laufendes Plugin nicht immer zuverlässig.

---

## Einrichtung

1. Wähle in der Stream-Deck-App dein Gerät aus.
2. Öffne rechts den Reiter **Dials** und zieh **Apple Music → Now Playing (Display)** auf ein Display-Feld. Falls dort schon eine andere Aktion liegt, etwa „Spotify: Multimedia“, entferne sie vorher über den Papierkorb.
3. Optional: Leg **Lautstärke (Display)** auf einen zweiten Drehregler oder in die zweite Ebene. Auf der Galleon wechselst du die Ebene, indem du den Drehregler 3 Sekunden gedrückt hältst.
4. Die Tasten-Aktionen findest du im Reiter **Tasten** unter „Apple Music“.

### Aktionen im Überblick

| Aktion | Typ | Drehen | Drücken / Tippen |
|---|---|---|---|
| Now Playing (Display) | Drehregler | Titel wechseln oder im Titel spulen | Play / Pause |
| Lautstärke (Display) | Drehregler | Lauter / leiser | Stumm an/aus |
| Play / Pause (mit Cover) | Taste | – | Play / Pause |
| Nächster Titel | Taste | – | Nächster Titel |
| Vorheriger Titel | Taste | – | Vorheriger Titel / Titelanfang |
| Zufallswiedergabe | Taste | – | Shuffle an/aus (rot = an) |
| Wiederholen | Taste | – | Aus → Alle → Einen (rot = an) |
| Apple Music öffnen | Taste | – | Startet Apple Music |

### Einstellungen

Wähl die Aktion aus, dann erscheinen die Einstellungen unten in der Stream-Deck-App.

- **Drehen** (Now Playing): *Titel wechseln* oder *Im Titel spulen*, Spul-Schrittweite 2–15 Sekunden
- **Schrittweite** (Lautstärke): 1, 2 oder 5 %
- **Quelle:** *Nur Apple Music* oder *Apple Music, sonst jede Medien-App*

### Vorschlag für eine Musik-Seite

```
┌──────────────── Display ────────────────┐
│  Now Playing (Display) │ Lautstärke      │
└─────────────────────────────────────────┘
 [ Zurück ]  [ Play/Pause ]  [ Weiter ]
 [ Shuffle ] [ Wiederholen ] [ Apple Music öffnen ]
```

---

## Albumcover

Das Plugin holt das Cover zuerst direkt von Apple Music über die Windows-Mediensteuerung. Liefert Apple Music kein Cover, sucht das Plugin es über die öffentliche **iTunes Search API** von Apple anhand von Titel und Künstler. Dabei werden **nur Titel und Künstler** an `itunes.apple.com` gesendet. Ob die Online-Suche nötig war, steht im Log.

---

## Fehlerbehebung

Das Plugin schreibt ein Log nach:

```
%APPDATA%\Elgato\StreamDeck\Plugins\de.local.applemusic.sdPlugin\plugin.log
```

| Problem | Lösung |
|---|---|
| Display zeigt „Keine Wiedergabe“, obwohl Musik läuft | Schau im Log nach der Zeile `Medien-Apps: [...]`. Taucht Apple Music dort nicht auf, meldet die App sich gerade nicht bei Windows: Apple Music neu starten. Mit der Einstellung *Quelle → jede Medien-App* lässt sich prüfen, ob das Plugin grundsätzlich funktioniert. |
| Kein Albumcover | Im Log stehen `Cover aus Apple Music nicht verfügbar` und `Cover online ...` mit dem Grund. Für die Online-Suche braucht der PC Internetzugang. |
| Feld sieht auf einer Seite anders aus | Die Aktion liegt in der nicht aktiven Ebene des Drehreglers. Die Galleon zeigt dort nur eine Vorschau. Wechsle die Ebene mit 3 Sekunden Halten oder tausch die Aktionen. |
| Nach einem Update keine Änderung | Stream Deck komplett beenden, alten Plugin-Ordner löschen, neu installieren (siehe [Installation](#installation)). |
| Shuffle / Wiederholen reagiert nicht | Im Log steht dann `Apple Music hat den Befehl abgelehnt`: Die App erlaubt das gerade nicht von außen. |

**Manueller Test des Hilfsprozesses.** Fügt man das in ein PowerShell-Fenster ein, während Musik läuft, gibt der Hilfsprozess seinen Zustand aus. Beenden mit Strg+C.

```powershell
& ([ScriptBlock]::Create((Get-Content -Raw "$env:APPDATA\Elgato\StreamDeck\Plugins\de.local.applemusic.sdPlugin\bin\media-helper.ps1"))) -NoRender
```

---

## Wie es funktioniert

```
Stream Deck App  ⇄  WebSocket  ⇄  bin/plugin.js (Node.js)  ⇄  stdin/stdout (JSON-Zeilen)  ⇄  bin/media-helper.ps1 (PowerShell 5.1)
                                                                                                   │
                                                                     Windows-Mediensteuerung (SMTC) · Core Audio · GDI+
```

- **`bin/plugin.js`**: das eigentliche Plugin. Es spricht das Stream-Deck-SDK v2 mit einem eigenen, schlanken WebSocket-Client, damit keine npm-Pakete nötig sind. Es verwaltet die Aktionen, leitet Tasten und Drehregler an den Hilfsprozess weiter und schickt Bilder ans Gerät.
- **`bin/media-helper.ps1`**: liest über `GlobalSystemMediaTransportControlsSessionManager` Titel, Künstler, Cover, Position und Status von Apple Music. Außerdem steuert er die Wiedergabe, regelt die Systemlautstärke über Core Audio und zeichnet die Display-Bilder (200 × 100 px) und Tastenbilder mit GDI+ in Segoe UI und Segoe Fluent Icons.
- **Display-Layout:** Das ganze Feld ist ein einziges Bild (`layouts/nowplaying.json`). Dadurch sieht die Anzeige unabhängig von den eingebauten Layout-Elementen der Stream-Deck-App aus.

### Projektstruktur

```
de.local.applemusic.sdPlugin/
├── manifest.json            Plugin-Definition (Aktionen, Icons, Mindestversionen)
├── bin/
│   ├── plugin.js            Plugin-Logik + WebSocket-Client
│   └── media-helper.ps1     Mediensteuerung, Lautstärke, Rendering
├── layouts/
│   └── nowplaying.json      Vollflächiges Display-Layout (200 × 100)
├── pi/
│   └── settings.html        Einstellungen in der Stream-Deck-App
└── imgs/                    Icons, Tastenbilder, Platzhalter
```

### Selbst bauen

Es gibt keinen Build-Schritt. Eine `.streamDeckPlugin`-Datei ist ein ZIP-Archiv, das den Ordner `de.local.applemusic.sdPlugin` enthält:

Am einfachsten mit dem mitgelieferten Skript, es legt das Paket im Ordner `dist/` an:

```powershell
.\build.ps1
```

Alternativ geht es mit Elgatos offiziellem CLI (`streamdeck pack`).

**Hinweis für Änderungen an `media-helper.ps1`:** Speichere die Datei als **UTF-8 mit BOM**. Sonst liest Windows PowerShell 5.1 Sonderzeichen falsch.

---

## Bekannte Einschränkungen

- Nur Windows. Unter macOS gibt es das offizielle Apple-Music-Plugin von Elgato.
- Das Layout ist für das Display-Feld des Stream Deck + bzw. der Galleon 100 SD (200 × 100 px) ausgelegt.
- Shuffle und Wiederholen hängen davon ab, ob Apple Music diese Befehle über die Windows-Mediensteuerung annimmt.
- Die Lautstärke-Aktion regelt die **Systemlautstärke**, nicht die interne Lautstärke von Apple Music.

---

## Lizenz

[MIT](LICENSE)
