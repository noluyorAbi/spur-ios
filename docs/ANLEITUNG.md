# Spur: Anleitung

Spur zeichnet auf, wo ihr mit dem Versuchsträger gefahren seid: genau, auch im Hintergrund und bei gesperrtem Display. Seit Version 1.1 zählt Spur außerdem Ampeln, Stoppschilder und schräge Kreuzungen auf eurer Strecke, mit Straßendaten aus OpenStreetMap. Eure Fahrten bleiben auf dem iPhone.

## Installieren

1. Das iPhone per Kabel an den Mac anschließen und in Xcode das Projekt `Spur.xcodeproj` öffnen (vorher im Projektordner `xcodegen generate` ausführen).
2. Oben das eigene iPhone als Ziel wählen und auf Start drücken. Beim ersten Mal unter Einstellungen, Allgemein, VPN und Geräteverwaltung dem Entwicklerzertifikat vertrauen.
3. Spur erscheint auf dem Home-Bildschirm.

## Berechtigungen

- Beim ersten Start einer Fahrt fragt iOS nach dem Standort. „Beim Verwenden“ reicht für die Aufzeichnung, auch bei gesperrtem Display.
- Besser ist „Immer“: Dann kann iOS Spur während einer Fahrt neu starten, falls das System die App beendet. Spur bietet das in einer ruhigen Karte an und in den Einstellungen unter Standortzugriff.
- „Genaue Position“ muss an sein. Ist sie aus, zeigt Spur einen Hinweis und fragt während der Fahrt nach genauer Position.
- Wurde der Zugriff abgelehnt, zeigt der Tab Fahrt einen Knopf, der direkt in die iOS Einstellungen führt.

## Vor der Fahrt

- In den Einstellungen Fahrer und Fahrzeug eintragen. Beides wird in jede neue Fahrt und in die Exporte geschrieben.
- Das iPhone in die Halterung setzen, am besten mit Ladekabel. Unter 15 % Akku zeigt Spur einen Hinweis.
- Solange der Tab Fahrt offen ist, wärmt Spur das GPS schon vor dem Start auf: Oben rechts steht dann die aktuelle Genauigkeit (zum Beispiel „± 4 m“). Diese Positionen werden nicht gespeichert.
- Außerhalb des Gebiets Dallas: Einstellungen, Straßendaten, „Gebiet vorladen“ lädt die Straßendaten im Umkreis von 15 km, am besten im WLAN.

## Start und Stopp

- **Bedienung nur durch Beifahrer.** Der Fahrer bedient Spur nie.
- Im Tab Fahrt auf den blauen Knopf **Start** tippen. Ab dann läuft alles ohne weitere Bedienung, auch wenn das Display gesperrt ist oder eine andere App vorne ist.
- **Stopp:** den runden Knopf etwa eine Sekunde gedrückt halten, bis der Ring voll ist. So kann die Fahrt nie aus Versehen enden. Danach erscheint eine kurze Zusammenfassung mit „Fahrt ansehen“.
- **Ereignis markieren:** während der Fahrt auf Ereignis tippen und einen Typ wählen (Baustelle, Interessantes Szenario, Gefahrenstelle, Sperrung, Fahrbahnmarkierung schlecht, Schild verdeckt, Sonstiges). Ein Tippen setzt die Markierung an der aktuellen Position.
- Wird Spur während der Fahrt beendet (vom System oder durch einen Absturz), setzt Spur dieselbe Fahrt beim nächsten Start fort und vermerkt die Lücke. Liegt die letzte Position mehr als 30 Minuten zurück, wird die alte Fahrt stattdessen abgeschlossen.

## Was die Karte zeigt

- **Blaue Linie:** die laufende Fahrt, hinter dem Pfeil. Weiße Pfeilspitzen auf der ganzen Strecke zeigen die Fahrtrichtung; weit herausgezoomt stehen sie weiter auseinander.
- **Blauer Pfeil:** die aktuelle Position, gedreht in Fahrtrichtung. Der helle Kreis darum ist die Ungenauigkeit.
- **Tempolimit:** neben der Geschwindigkeit das Tempolimit der Straße laut OpenStreetMap, in der Einheit des Schilds (mph als weißes Rechteck, km/h rund mit rotem Rand). Es erscheint nur, wenn die Position sicher auf einer Straße liegt (einige Sekunden auf derselben Straße, genaue Position, keine parallele Straße mit anderem Limit daneben); sonst bleibt es weg, nie geraten. Mehr als 5 mph (8 km/h) zu schnell für 2 Sekunden: die Zahl wird rot, das Schild bekommt einen roten Rand, ohne Ton. Es kann fehlen oder falsch sein. Abschalten in den Einstellungen unter „Tempolimit anzeigen“.
- **Gelbe und grüne Straßen:** „bereits gefahren“, nach Fahrtrichtung. Gelb heißt in einer Richtung gefahren, mit Pfeilspitzen in diese Richtung; grün mit dunklem Mittelstreifen (wie zwei Fahrspuren) heißt in beiden Richtungen gefahren, mit zwei Pfeilspitzen, die voneinander weg zeigen. Wo sehr viele Straßen gefahren sind, stehen die Pfeile weiter auseinander, damit sie lesbar bleiben. Beim ersten Mal erklärt ein kurzer Hinweis die Farben. Eine Straßenseite gilt als gefahren, wenn mindestens 70 % des Stücks zwischen zwei Kreuzungspunkten abgefahren sind, über alle Fahrten zusammen. Einbahnstraßen und die getrennten Fahrbahnen großer Straßen bleiben gelb, weil sie nur eine Richtung haben; zwei gelbe Linien mit Gegenpfeilen nebeneinander heißen dort „beide Richtungen“. Die Farben kommen aus der Auswertung nach der Fahrt (Straßendaten laut OpenStreetMap), die laufende Fahrt wird erst nach dem Beenden eingefärbt.
- **Dünne weiße Linien:** frühere Fahrten, die nicht oder kaum auf Straßen abgeglichen sind (zum Beispiel ohne Straßendaten). Der Ebenen-Knopf rechts blendet alles „bereits gefahren“ ein und aus und sagt beim Einschalten, was die Farben bedeuten.
- Der zweite Knopf schaltet zwischen „in Fahrtrichtung“ und „Norden oben“. Wer die Karte verschiebt, bekommt einen Knopf zum Zentrieren.
- **Kleine Symbole:** Ampelkreuzungen (drei Lichter), Stoppschilder (rotes Achteck, mit weißem Ring bei Allwege-Stopp) und schräge Kreuzungen (Gabelpfeil), laut OpenStreetMap, nur in der Nähe: im Umkreis von 600 m um das Auto (ohne Fahrt um die Kartenmitte), höchstens 25, die nächsten zuerst. Was auf der eigenen Straße voraus liegt, ist etwas größer und kräftiger, alles andere blass. Weit herausgezoomt (etwa bei Autobahntempo) sind die Symbole ausgeblendet. Straßen mit vielen Ampeln in der Nähe sind leicht gelblich hinterlegt. Der Knopf mit dem Wegweiser blendet das ein und aus. Unten rechts über der Karte steht dann „Straßendaten © OpenStreetMap-Mitwirkende (ODbL)“.
- Oben: Aufnahmedauer, die Straße jetzt und GPS-Genauigkeit (grün bis 5 m, gelb bis 15 m, rot darüber, grau ohne aktuelle Position). Die Straße zeigt die Kategorie laut OpenStreetMap („Hauptstraße, laut OSM“), wenn die Fahrt gerade auf eine Straße abgeglichen ist, sonst die geschätzte Streckenart („Autobahn, geschätzt“).
- Unten: Geschwindigkeit, Strecke, Dauer, der Durchschnitt in Fahrt und die Zähler der Fahrt („7 Ampeln · 2 Stopp · 1 schräg“).
- Bleibt die Genauigkeit 30 s lang im Mittel schlechter als 15 m, erscheint „Ungenaue Position (± 18 m): freie Sicht zum Himmel?“. Der Hinweis verschwindet von selbst.

## Was „geschätzt“ bedeutet

Die Streckenart Stadt, Land, Autobahn wird aus dem Geschwindigkeitsprofil geschätzt: Median der letzten 60 s, Autobahn ab 85 km/h, Land 50 bis 85 km/h, Stadt darunter oder bei mehr als 2 Stopps je km. Eine neue Klasse muss 30 s halten. Ein Stau auf der Autobahn zählt so zum Beispiel als Stadt. Sie bleibt als Rückfall für Strecken ohne Straßendaten; wo Straßendaten da sind, zeigt Spur die Straßenkategorie laut OpenStreetMap. Jede Kennzahl in den Fahrt-Details hat ein „i“ mit ihrer genauen Definition.

## Straßendaten (laut OpenStreetMap)

- **Woher:** Ampeln, Stoppschilder, Vorfahrt-Achten-Schilder, Kreisverkehre, Bahnübergänge, Ausfahrten und die Form jeder Kreuzung kommen aus OpenStreetMap. Für das Gebiet Dallas sind sie fest in der App (Offline-Paket, Stand siehe Einstellungen). Anderswo lädt Spur sie, wenn „Straßendaten aus dem Internet laden“ an ist, von öffentlichen Overpass-Servern. Dabei werden nur die Quadrate von etwa 4 km um die Strecke abgefragt, nie eure Positionen oder die Strecke. Geladene Gebiete bleiben 30 Tage im Zwischenspeicher. Schlägt das Laden fehl (die öffentlichen Server sind oft ausgelastet), versucht Spur es später von selbst wieder. Ist die Einstellung aus, wird nichts nachgeladen, auch keine Anfrage, die gerade läuft; beim Einschalten fragt Spur die fehlenden Gebiete sofort an. Am Rand des Dallas-Gebiets enthält das Offline-Paket Quadrate nur zum Teil; Spur nutzt sie, zeigt sie als fehlend an und lädt sie, wenn erlaubt, vollständig nach.
- **Wie gezählt wird:** Nach jeder Fahrt legt Spur die Fahrt mit dem Kartenabgleich des Hauptprojekts auf das Straßennetz. Ein Schild oder eine Ampel zählt nur, wenn es auf dem abgeglichenen Weg liegt; eine Ampel an der Parallelstraße unter der Autobahn zählt nicht. Die zwei bis vier Ampelknoten einer Kreuzung mit getrennten Fahrbahnen zählen als eine Ampel. Stoppschilder zählen nur in ihrer Fahrtrichtung; ein Stoppschild, das in OpenStreetMap nur für die Nebenstraße gilt („stop=minor“), zählt auf der Hauptstraße nicht.
- **Schräge Kreuzung:** mindestens drei Zufahrten, und zwei davon treffen unter 70° oder zwischen 110° und 150° aufeinander (Regel des Hauptprojekts).
- **Stopps** gelten als an der Ampel oder am Stoppschild, wenn so ein Knoten des abgeglichenen Wegs höchstens 30 m entfernt ist.
- **Straßen mit vielen Ampeln oder Stoppschildern:** mindestens 300 m gefahren und mehr als 3 je km.
- **In den Fahrt-Details** steht alles im Abschnitt „Kreuzungen und Verkehrszeichen (laut OpenStreetMap)“, mit dem Anteil der Strecke, für den Straßendaten da waren („Straßendaten für 97 % der Strecke“), und dem Knopf „Neu auswerten“. Fehlende Gebiete werden nachgeladen, sobald Internet da ist; dann wertet Spur von selbst neu aus. Fahrten von vor Version 1.1 werden beim ersten Start im Hintergrund ausgewertet.
- **Grenzen:** In OpenStreetMap fehlen viele Stoppschilder; die Zahl ist eine Untergrenze. Neue oder geänderte Ampeln kennt Spur erst, wenn sie in OpenStreetMap stehen. Die Zähler unten in der Karte sind eine schnelle Live-Schätzung; maßgeblich sind die Zahlen nach der Fahrt.
- Straßendaten © OpenStreetMap-Mitwirkende (ODbL).

## Bewegungssensor (ab Version 1.2)

- **Was:** Während einer Fahrt speichert Spur Beschleunigung und Drehrate des iPhones roh, 100 oder 50 Mal je Sekunde (Einstellungen, „Bewegungssensor“). Etwa 22 MB pro Stunde bei 100 Hz, 11 MB bei 50 Hz; der belegte Speicher steht in den Einstellungen. Eine Freigabe braucht das nicht. Ausschalten während einer Fahrt stoppt die Aufzeichnung sofort; Einschalten und die Abtastrate gelten ab der nächsten Fahrt (eine fortgesetzte Fahrt behält ihre Rate).
- **Ausrichtung:** Das Handy sitzt schräg in der Halterung. Spur ermittelt nach jeder Fahrt selbst, wo vorn, links und oben ist: oben aus der Schwerkraft, vorn aus dem Vergleich mit der GPS-Geschwindigkeit, links aus Drehrate mal Geschwindigkeit. Das geschieht je Abschnitt zwischen zwei Lageänderungen des Handys; eine neue Lage erkennt Spur, wenn sich das Handy mit der Hand bewegt (über 10° Drehung in einer halben Sekunde, Wackeln der Halterung zählt nicht), wenn es sich in der Halterung um die Senkrechte dreht (die Richtung laut Kreisel weicht dauerhaft um mehr als 10° von der GPS-Richtung ab, auch langsam), im Stand gedreht wird oder sich um mehr als 25° neigt. Langsames Nachkippen der Halterung und Steigungen gleicht Spur aus, ohne neu zu beginnen. Jeder Abschnitt braucht etwas Beschleunigen, Bremsen oder Kurven und muss für sich gut passen; sonst bleiben seine Längs- und Querwerte leer, Stöße zählen trotzdem.
- **Qualität in den Fahrt-Details:** erste Zeile „Ausrichtung gut · r = 0,93 (längs und quer)“ (auf der Autobahn mit fast gleichem Tempo „(quer, Tempo gleichmäßig)“: dann zählen nur die Spurwechsel und Kurven), zweite Zeile „Ausgerichtet für 98 % der Fahrzeit (2 von 2 Abschnitten) · Sensordaten für 99 % der Fahrzeit“. Gelb wird der Punkt, wenn weniger als 90 % ausgerichtet sind, die Sensordaten unter 90 % liegen, die Skala des Sensors quer um mehr als 15 % von Kreisel mal GPS-Tempo abweicht („Skala quer weicht ab“; längs zählt nicht, weil iOS die GPS-Geschwindigkeit glättet) oder die Drehrichtung des Kreisels der GPS-Richtung widerspricht (dann tauscht Spur links und rechts für diese Fahrt und sagt es). Ist nichts ausgerichtet, steht darunter weiter „Fahrdynamik (ca.)“ aus GPS. Mit sehr wenigen Messungen steht dort „Zu wenige Sensordaten“.
- **Werte:** „Fahrdynamik (Bewegungssensor)“ mit den Höchstwerten in m/s² und g, den starken Bremsungen, Beschleunigungen, Querbeschleunigungen und Stößen (Bodenwelle, Schlagloch o. ä.) und einem Verlauf der Längsbeschleunigung; „Fahrbahn (Bewegungssensor)“ mit den Anteilen glatt, normal, uneben, sehr uneben je 100 m und den unebensten Abschnitten. Ein Ereignis endet erst 0,5 m/s² unter seiner Schwelle, Ereignisse weniger als 0,75 s auseinander zählen als eines, eine Sensorlücke trennt immer. Auf der Karte stehen die Ereignisse (bei vielen Stößen nur die 30 stärksten); Antippen zeigt Wert, Uhrzeit, Tempo und Straße. Jede Zahl hat ein „i“ mit ihrer Regel. Fahrten ohne Sensordaten zeigen wie bisher „Fahrdynamik (ca.)“ aus GPS.
- **Fahrbahn-Klassen:** gemessen bei 20 Hz Tiefpass (50 und 100 Hz vergleichbar) und auf 50 km/h umgerechnet; glatt unter 0,5 m/s², normal unter 1,0, uneben unter 2,0, darüber sehr uneben. Das ist eine erste Schätzung und wird nach der ersten echten Fahrt angepasst.

### Sensordaten (CSV)

- In den Fahrt-Details über das Menü, Teilen, „Sensordaten (CSV)“; davor steht die erwartete Größe (etwa 60 MB je Stunde bei 100 Hz). Während des Exports zeigt Spur den Fortschritt mit „Abbrechen“; er läuft weiter, wenn man die Details verlässt oder kurz die App wechselt.
- Eine Zeile je Messung. `time_s` ist Unix-Zeit in Sekunden (UTC, sechs Nachkommastellen), weil die Messungen viel dichter liegen als Millisekunden-Zeitstempel und so direkt mit den Positionen vergleichbar sind.
- Die Spalten `user_*`, `gravity_*`, `rotation_*`, `attitude_*` sind die Rohwerte des iPhones in seinen eigenen Achsen. Achtung Vorzeichen: `user_*` ist minus die tatsächliche Beschleunigung (so liefert iOS es), `gravity_*` zeigt zur Erde.
- `long_mps2` (vorwärts positiv), `lat_mps2` (links positiv) und `vert_mps2` (oben positiv) sind die tatsächlichen Beschleunigungen im Fahrzeug, ungeglättet. `aligned` ist 1, wenn der Abschnitt ausgerichtet ist (sonst sind längs und quer leer), `handling` ist 1, wenn das Handy gerade bewegt wurde.
- Die Höchstwerte in den Fahrt-Details sind über 0,25 s geglättet und deshalb kleiner als einzelne Spitzen in der CSV.

### Prüfliste für die erste Fahrt mit Version 1.2

1. Handy fest in die Halterung, Spur öffnen, Fahrt starten.
2. Etwa 10 Minuten fahren, mit normalem Anfahren, Bremsen und ein paar Kurven. Einen Teil der Strecke mit gesperrtem Bildschirm fahren.
3. Fahrt beenden, die Fahrt-Details öffnen: erwartet sind „Ausrichtung gut“, Sensordaten für nahezu 100 % der Fahrzeit (auch im gesperrten Teil) und plausible Bremswerte (normales Bremsen etwa 1 bis 3 m/s²).
4. Alle Fahrten als ZIP exportieren; der Ordner der Fahrt enthält `motion.bin`.
5. Fällt der Anteil der Sensordaten im gesperrten Teil ab, ist das ein Fehler, der behoben wird, kein Wert zum Wegerklären.
6. Kurven und Stöße: Linkskurven erscheinen links, Rechtskurven rechts (auf der Karte und in den Werten); ein Bordstein oder Schlagloch zählt als Stoß, auch auf rauer Straße mit dem Handy in der Halterung. In der Qualitätszeile steht keine gelbe Warnung zu Skala oder Drehrichtung.
7. Qualität nach der ersten echten Fahrt: im „i“ der Qualitätszeile stehen die Skala quer (nahe 1) und „r Drehung“ (deutlich positiv, sonst „nicht prüfbar“). Bei einer Autobahnfahrt muss „Ausgerichtet für … %“ den Autobahnteil abdecken, auch wenn nur Spurwechsel vorkamen. Zeigt eine glatte Straße „normal“ oder schlechter: im JSON-Export der Fahrt steht unter `trip.motion` der Wert `vibrationRMS`, das Grundrütteln in m/s², das von der Fahrbahn abgezogen wird. Fehlt er, gab es keinen Halt mit laufendem Motor, und es wird nichts abgezogen. Wie stark der Motor in der Halterung während der Fahrt rüttelt, ist eine Annahme der Auswertung; diesen Wert bei einer Abweichung mitschicken.
8. Live-Aktivität, mit Standort „Immer“: Fahrt starten, iPhone sperren: auf dem Sperrbildschirm roter Punkt, laufende Zeit, Strecke, Tempo und GPS-Genauigkeit. Zum Home-Bildschirm wechseln: die Insel um die Kamera zeigt Punkt, Zeit und Strecke, nicht nur einen roten Punkt (im Simulator bleibt es beim roten Punkt); Gedrückthalten zeigt die aufgeklappte Form. Fahrt in der App beenden: „Fahrt beendet · … km · … min“ erscheint, verschwindet nach 5 Minuten, und keine zweite Live-Aktivität taucht auf.

## Live-Details (ab Version 1.3)

Während einer Fahrt öffnet „Live-Details“ über der Karte unten (oder ein Wisch nach oben auf der Karte mit Tempo und Stop) ein Panel über der Karte; die Karte unten und Stop bleiben frei. Halb hoch zeigt es die Fahrdynamik live: den Beschleunigungskreis (oben vorn, links links), Längs- und Querbeschleunigung in m/s² und g, Höchstwerte, starke Ereignisse und die letzten 60 Sekunden. Der Pfeil oben links zieht es ganz hoch, mit allen Abschnitten der Fahrt-Details; das Kreuz schließt es. In der Historie öffnet die laufende Fahrt dieselben Details; endet die Fahrt, werden sie zu den fertigen Fahrt-Details. „Kreuzungen und Verkehrszeichen“ sagt, warum kein Tempolimit gezeigt wird (zum Beispiel „Kein Tempolimit in OSM eingetragen“), und nach der Fahrt, wie viel der Fahrzeit mit Tempolimit lief und warum der Rest ohne.

### Prüfliste für die erste Fahrt mit Version 1.3

1. Fahrt starten, nach etwa einer Minute „Live-Details“ öffnen: vor dem ersten Anfahren und Bremsen steht „Ausrichtung läuft“, und es gibt nur die Größe der Beschleunigung („Gesamt“), keine Richtung.
2. Nach dem ersten kräftigen Bremsen und Anfahren erscheinen Längs- und Querwerte mit Richtung (vorn, Bremsen, links, rechts); Bremsen zieht den Punkt nach unten, eine Linkskurve nach links.
3. Das Panel ganz hochziehen: alle Abschnitte, und die Zahlen ändern sich ruhig, ohne zu springen.
4. Fahrt beenden, die Fahrt-Details öffnen: Höchstwerte und starke Ereignisse stimmen mit dem überein, was das Panel zuletzt zeigte (das Panel hält Werte während der Fahrt nur fest, die Fahrt-Details sind die Auswertung der ganzen Fahrt).
5. Wird das Handy in der Halterung gedreht, zeigt das Panel wieder nur die Größe, bis die neue Lage ausgerichtet ist.

## Karte, Pause und Planen (ab Version 1.4)

### Kartentyp und Häufigkeit

Das Ebenen-Menü der Fahrt-Karte wählt den Kartentyp (Standard, Satellit, Hybrid) und die Abdeckung: „Richtung“ zeigt wie bisher, in welcher Richtung eine Straße schon gefahren ist, „Häufigkeit“ färbt jede Straße danach, wie oft sie gefahren wurde (fünf Stufen in Violett, mit Legende). Antippen einer Straße zeigt, wie oft und wann zuletzt. Über Satellitenbildern bekommen die Bedienelemente einen dunklen Hintergrund; ohne Internet steht „Satellitenbild nicht verfügbar (offline)“.

### Pause

- **Von Hand:** „Pause“ neben „Ereignis“ hält die Fahrt an. Während einer Pause werden keine Positionen geschrieben und der Bewegungssensor pausiert. Die Pause endet nur mit „Fortsetzen“, nie von selbst. Stopp bleibt Gedrückthalten.
- **Automatisch** (Einstellungen, „Automatisch pausieren“, an; Dauer 3, 5 oder 10 Minuten): Steht das Auto mindestens so lange abseits der Straße (Parkplatz, Tankstelle) oder an einer Nebenstraße, zählt der Halt ab seinem Beginn als Pause. Entschieden wird nur nach dem Standort und den Straßendaten auf dem iPhone, ohne Bewegungssensor und ohne Freigabe für „Bewegung und Fitness“. Auf Autobahnen und Hauptstraßen zählt ein Halt nie als Pause (Stau, Ampel). Ohne Straßendaten zählt jeder lange Halt. Die Fahrt geht von selbst weiter, sobald wieder gefahren wird.
- Pausen zählen weder zur Fahrzeit noch zur Standzeit, nur zur Dauer, und nicht als GPS-Lücke; die Fahrt-Details zeigen ihre Summe als „Pausenzeit“.

### Live-Details: Zustand des Sensors

Die Zeile über den Werten sagt, was der Sensor gerade tut: „Warte auf Sensordaten“, „Ausrichtung läuft (braucht Anfahren und Bremsen)“, „In der Hand, Werte pausiert“ oder nach dem Ablegen „Neu ausrichten nach dem Ablegen“. In den Fahrt-Details steht, für welchen Anteil der Fahrt die Werte ausgerichtet waren.

### Planen

Der Tab „Planen“:
- **Suche:** Ort oder Adresse eingeben, ein Treffer öffnet eine Karte mit Entfernung und Fahrzeit. „Navigieren“ öffnet Apple Karten, „In Google Maps öffnen“ Google Maps, „Route in Spur zeigen“ zeigt die Strecke auf der Fahrt-Karte über der eigenen Abdeckung.
- **Straßen suchen:** Das Suchfeld findet neben Orten auch Straßen aus den Straßendaten (ohne Internet, im Umkreis von 6 km): je Straße Länge, wie viel davon gefahren ist und die Entfernung, unbefahrene zuerst; „ss“ findet auch „ß“. Bei leerem Suchfeld stehen dort die nächsten „Unentdeckten Straßen in der Nähe“. Antippen zeigt die Straße auf der Karte (gefahren violett, unbefahren orange) mit „Zum unbefahrenen Teil“: das öffnet die Karte des nächsten unbefahrenen Stücks mit Entfernung, Fahrzeit, Navigieren und „Route in Spur zeigen“.
- **Entdecken:** Merkmale wählen (Ampeln, Stoppschilder, schiefe Kreuzungen, Kreisverkehre, Bahnübergänge und weitere), „Richtung egal“ oder „Nur fehlende Richtung“, den Umkreis, dann „Suchen“: die besten Stellen mit einem Satz, warum. „Nächste unbefahrene Strecke“ sucht die nächstgelegene Straße mit diesen Merkmalen, die noch nicht gefahren ist.
- **Entdeckerroute:** „Rundkurs“ mit einer Länge oder „Zum Ziel“ (der gesuchte Ort) mit einem erlaubten Umweg, dann „Route planen“. Die Route hält Einbahnstraßen ein, meidet private Wege und wendet nur in Sackgassen. Die Karte der Route zeigt Länge, neue Kilometer und die Merkmale darauf, mit bis zu zwei Alternativen. „Route anzeigen“ legt sie mit nummerierten Wegpunkten auf die Fahrt-Karte. Apple Karten bekommt nur den ersten Wegpunkt (das steht dabei), Google Maps bis zu neun, und „GPX“ teilt die ganze Route. Außerhalb des mitgelieferten Gebiets lädt Spur die Straßendaten aus dem Internet; dabei steht da, wie viele Kacheln schon geladen sind, und „Abbrechen“ hält an. Findet Spur keine Route, steht der Grund dabei: die Server antworten nicht, Straßendaten aus dem Internet sind aus, der Standort liegt an keiner geladenen Straße, oder es gibt keinen Rundkurs dieser Länge. „Zum Ziel“ geht bis 40 km Luftlinie.

### Lücken ergänzen

Wo GPS fehlte, zeigen die Fahrt-Details unter der Karte die Karte „Lücken“: je Lücke Dauer, Länge und die wahrscheinliche Straße, auf der Karte gepunktet. Der Vorschlag ist ein legaler Weg über das Straßennetz, der zur verstrichenen Zeit passt. „Übernehmen“ zählt ihn als „Ergänzt“ zur Strecke, zur Abdeckung und zur Häufigkeit (mit dem Vermerk „ergänzt, ohne GPS“) und listet die Merkmale darauf getrennt. Geschwindigkeit, Zeiten, Fahrdynamik und Ereignisse bleiben unberührt. „Verwerfen“ blendet den Vorschlag aus; „Ergänzung entfernen“ und „Doch vorschlagen“ machen die Entscheidung rückgängig. Die aufgezeichneten Positionen ändern sich dabei nie. Im GPX-Export steht eine übernommene Ergänzung als eigene Route „Ergänzt (Lücke)“ (nicht als Trackpunkte, damit andere Programme sie nicht für gemessene Positionen halten), im GeoJSON mit `filled: true`. Gibt es keinen Vorschlag, steht der Grund dabei: „Lücke zu kurz“, „Keine Straßendaten hier“ oder „Kein plausibler Weg“.

### Prüfliste für die erste Fahrt mit Version 1.4

1. Vor der Fahrt in „Planen“ einen kurzen Rundkurs (etwa 10 km) planen und „Route anzeigen“ wählen. Die Fahrt starten: die Route bleibt während der Aufzeichnung auf der Karte.
2. Die Route abfahren. Danach in den Fahrt-Details prüfen, dass die Merkmale (zum Beispiel Ampeln) ungefähr den Zahlen auf der Karte der Route entsprechen. Die Fahrt zählt jede Durchfahrt, die Route jede Stelle einmal; Abweichungen bitte mit beiden Zahlen melden.
3. Unterwegs einmal „Pause“ und „Fortsetzen“ drücken; einmal mindestens 5 Minuten mit ausgeschaltetem Motor parken. In den Fahrt-Details enthält „Pausenzeit“ beide Pausen, und die Fahrzeit enthält sie nicht.
4. Die Fahrt-Karte auf „Häufigkeit“ und „Satellit“ stellen: die gefahrene Route ist sichtbar und lesbar.
5. Hat die Fahrt eine Lücke (zum Beispiel in einem Tunnel), den Vorschlag prüfen: liegt er auf der tatsächlich gefahrenen Straße? Übernehmen und wieder entfernen; Strecke und „Ergänzt“ ändern sich, Geschwindigkeit und Zeiten nicht.

## Live-Aktivität (ab Version 1.2)

- Während einer Fahrt zeigt Spur eine Live-Aktivität auf dem Sperrbildschirm und oben in der Insel um die Kamera: roter Punkt, Fahrzeit (läuft von selbst weiter), Strecke, Tempo und GPS-Genauigkeit, aufgeklappt zusätzlich Streckenart und Tempolimit. Antippen öffnet den Tab „Fahrt“.
- Sie startet nur, wenn Spur im Vordergrund ist (Vorgabe von iOS). Startet iOS Spur im Hintergrund neu, hängt sich Spur an die laufende Aktivität; fehlt sie, kommt sie beim nächsten Öffnen.
- Aktualisiert wird höchstens etwa alle 10 Sekunden oder sofort bei einer Änderung (Signal weg, Tempolimit, Streckenart). Kommt zwei Minuten lang keine Aktualisierung (Spur wurde beendet), wird sie grau und zeigt „Keine Aktualisierung“ statt eingefrorener Zahlen.
- Nach dem Stopp steht dort „Fahrt beendet · 12,4 km · 23 min“, fünf Minuten lang. Nach etwa 8 Stunden beendet iOS jede Live-Aktivität; Spur startet sie für diese Fahrt dann nicht neu, die Aufzeichnung läuft weiter.
- Abschalten: Einstellungen, „Live-Aktivität anzeigen“, oder in den iOS-Einstellungen für Spur.
- Für die Anzeige in der Insel um die Kamera: Standortzugriff auf „Immer“. Dann blendet Spur die blaue Standortanzeige aus, solange die Live-Aktivität läuft (sie zeigt ja selbst, dass aufgezeichnet wird). Mit „Beim Verwenden der App“ zeigt iOS die blaue Anzeige immer, und die Live-Aktivität bleibt in der Insel ein roter Punkt.
- Wird die Live-Aktivität weggewischt oder nach 8 Stunden von iOS beendet, startet Spur sie für diese Fahrt nicht neu, auch nicht nach einem Neustart der App.

## Historie und Details

- Die Historie zeigt Gesamtwerte und alle Fahrten nach Tagen. Wischen nach links löscht eine Fahrt (mit Rückfrage).
- Die Historie zählt zusätzlich alle überfahrenen Ampeln und Stoppschilder.
- Die Fahrt-Details zeigen die Karte (eingefärbt nach Geschwindigkeit oder Streckenart, mit Start, Ziel, Ereignissen, Lücken und den überfahrenen Ampeln, Stoppschildern und schrägen Kreuzungen) und alle Kennzahlen: Übersicht, Streckenart, Kreuzungen und Verkehrszeichen, Geschwindigkeit, Höhe, Stopps, Fahrdynamik, Tag und Nacht, GPS-Qualität (mit den Anteilen bis 5 m und bis 10 m und einem externen GNSS-Empfänger, falls benutzt), Orte und Straßen, Fahrer und Gerät, Ereignisse, Notiz.
- Über das Menü oben rechts: Teilen, Umbenennen, Notiz, Löschen. Mit Sensordaten gibt es beim Teilen zusätzlich „Sensordaten (CSV)“.

## Export

- **Eine Fahrt:** in den Details über das Menü, Teilen: GPX, CSV, GeoJSON, JSON oder alle vier.
- **Alle Fahrten:** in der Historie oben rechts oder in den Einstellungen. Es entsteht eine ZIP-Datei mit einem Ordner je Fahrt und einer Übersicht `trips.csv`.
- Jeder Export landet zusätzlich in der App Dateien unter Auf meinem iPhone, Spur, Exports.
- CSV und GPX lassen sich direkt im Hauptprojekt importieren. Zahlen nutzen den Punkt als Dezimaltrennzeichen, Zeiten sind UTC.
- Mit Straßendaten enthält die CSV hinten die Spalten wayId, street und osmCategory, die JSON-Datei die Straßenstatistik und jede überfahrene Ampel, jedes Schild und jede Kreuzung, die GeoJSON-Datei je einen Punkt dafür und `trips.csv` die Zähler je Fahrt.
- Mit Sensordaten (ab 1.2): „Sensordaten (CSV)“ enthält jede Messung in voller Rate, die Rohwerte und dazu längs, quer und senkrecht in m/s² mit einer Spalte, ob die Messung ausgerichtet ist. Die JSON-Datei enthält die Zusammenfassung und jedes Ereignis, GPX je einen Wegpunkt mit dem Typ `motion.hardBraking` und so weiter, GeoJSON je einen Punkt, `trips.csv` hinten die Sensor-Spalten. Die ZIP-Datei legt `motion.bin` in den Ordner jeder Fahrt und `MOTION-FORMAT.md` daneben, die das Format beschreibt. Die Positions-CSV bleibt unverändert, der Import ins Hauptprojekt klappt wie bisher.
- Ab 1.4: Jede abgeschlossene Pause steht im GPX als Wegpunkt „Pause“ (Typ `pause.manual` oder `pause.auto`, mit Beginn, Ende und Grund), im GeoJSON als Punkt mit `kind: pause` und in der JSON-Datei unter `trip.pauses`. Eine übernommene Lücken-Ergänzung steht im GPX als Route „Ergänzt (Lücke)“ und im GeoJSON mit `filled: true`, nie als Trackpunkte; die CSV enthält nur gemessene Positionen. Der Import ins Hauptprojekt liest weiterhin genau die gemessenen Punkte.

## Bekannte Grenzen

- Die Streckenart Stadt, Land, Autobahn ist eine Schätzung; den Kartenabgleich gibt es für die Kreuzungen und Verkehrszeichen und die Straßenkategorien.
- Ohne Internet und außerhalb des Offline-Pakets fehlen Straßendaten, bis das Gebiet geladen ist.
- Wer Spur in der App-Übersicht selbst wegwischt, beendet die Aufzeichnung; iOS startet Spur danach nicht von allein neu. Beim nächsten Öffnen läuft die Fahrt weiter (mit Lücke), wenn die letzte Position höchstens 30 Minuten alt ist.
- Ohne Netz bleiben Ortsnamen leer; die Aufzeichnung läuft trotzdem.
- Die Höhe ist eine Näherung aus GPS-Daten, die Fahrdynamik ohne Sensordaten auch.
- Nur Hochformat. Querformat ist noch nicht umgesetzt.
