# Logic MCP — verifierade fynd och teknisk handoff

Senast uppdaterad: 2026-08-24

## Syfte

Målet är att bygga en modelloberoende MCP-server som låter AI-klienter läsa, analysera och säkert manipulera projekt i Apple Logic Pro.

Den centrala idén är att MCP-servern ska vara AI-modellens standardiserade gränssnitt till Logic. Servern ska inte själv vara beroende av Gemini, OpenAI, Anthropic eller någon annan modellleverantör. Den ska exponera deterministiska verktyg och strukturerad projektinformation som valfri MCP-kompatibel klient kan använda.

Det viktigaste fyndet hittills är att Logic Pro 12.3.1 exponerar semantiskt beskrivna och skrivbara pluginparametrar genom macOS Accessibility API. Detta har verifierats praktiskt på Apples Compressor-plugin i ett riktigt Logic-projekt.

## Kort slutsats

- Logic-projekt kan läsas delvis direkt från `.logicx`-paketet.
- Direkt redigering av `ProjectData` är olämplig eftersom formatet är proprietärt och binärt.
- Den öppna Logic-sessionen kan styras genom en kombination av Accessibility, kontroll­yteprotokoll, CoreMIDI, AppleScript och Logic-kommandon.
- Apples Compressor exponerade elva huvudsakliga reglage som `AXSlider`.
- Samtliga elva rapporterade `AXValue` som skrivbart.
- Knappar, modeller, sidechain, presets och bypass exponerades också semantiskt.
- Det befintliga open-source-projektets begränsning till verifierad Compressor-threshold är en implementations- och säkerhetsgräns, inte en fundamental Logic-begränsning.
- En körbar, modelloberoende MCP proof of concept finns nu i detta repository och kan både inventera och verifierat skriva Compressor-parametrar utan att modifiera `ProjectData` direkt.

## Testmiljö

Fynden verifierades i följande miljö:

- Logic Pro: 12.3.1
- Logic bundle identifier: `com.apple.logic10`
- Testprojekt: `CS Smällare.logicx`
- Lokal testprojektsökväg: `/Users/dev/Music/Logic/CS Smällare.logicx`
- Testspår: `Acke Vocals`
- Testplugin: Apple `Compressor`
- Aktiv preset: `Vintage Vocal`
- Aktiv kompressormodell i UI: `Vintage FET`
- Sidechain-källa: `Internal`
- Accessibility-behörighet: beviljad före den lyckade inventeringen

Den första inventeringen var skrivskyddad. Den 2026-08-24 gjordes därefter ett uttryckligen godkänt skrivtest i den öppna Logic-sessionen. Compressor Ratio på `Acke Vocals` ändrades från `4.2:1` till `3.1:1` och lästes tillbaka. Ingen direkt skrivning gjordes till projektpaketets `ProjectData`.

## Körbar MCP-demo

Repositoryt innehåller nu en minimal lokal MCP-server i Swift:

```text
Package.swift
Sources/LogicMCPDemo/main.swift
mcp-config.example.json
```

Servern använder MCP över standard input/output och har inga externa paketberoenden. Den är modelloberoende: en MCP-kompatibel klient kan vara byggd runt valfri AI-modell.

Bygg servern:

```bash
swift build -c release
```

Den färdiga servern finns därefter här:

```text
.build/release/logic-mcp-demo
```

`mcp-config.example.json` visar den generella klientkonfigurationen. Exakt var konfigurationen ska placeras beror på MCP-klienten. Klienten som startar servern måste ha macOS-behörigheten Hjälpmedel för att skrivning ska fungera.

### Implementerade MCP-verktyg

Version 0.15 av servern exponerar följande verktyg:

Läsverktyg:

- `logic_health` — kontrollerar om Logic körs, om Hjälpmedel är tillgängligt och vilket projekt som är öppet.
- `logic_list_windows` — listar Logic-fönster med subrole och `AXDocument`; fönster med dokument är projektfönster, dialoger utan dokument är plugin- eller hjälpfönster.
- `logic_list_tracks` — listar spårhuvuden som just nu renderas i Tracks-arean: spårnummer, namn, selektionsstatus samt `is_stack`/`expanded` för track stacks.
- `logic_list_inserts` — listar det valda spårets audio-effekt-inserts från vänstra inspector-channel-strippen: slotindex, visat pluginnamn och bypass-status.
- `logic_list_plugin_parameters` — inventerar semantiskt exponerade reglage i ett öppet pluginfönster.
- `logic_get_transport` — läser transportläget från Control Bar: playing, recording, cycle, playhead (takt/slag), tempo, taktart, tonart, metronom, count-in.
- `logic_evaluate_change` — kör hela closed-loop-utvärderingen (baseline → ändring → mätning → keep/rollback → kontroll) som en enda operation; se v0.8.0-avsnittet.
- `logic_sensor_capture` — bouncar senaste ljudet vid varje sensorpunkt till lyssningsbar WAV; se v0.9.0-avsnittet.
- `logic_sensor_read` — läser live-mätvärden (peak/RMS i dBFS, beat, tempo, transport) från LogicMCPSensor-AU-instanser; se v0.7.0-avsnittet.

Skrivverktyg:

- `logic_set_playing` — startar uppspelning via Play-knappen (`AXPress`) och stoppar via space-tangentkommando som bara skickas efter verifierad frontmost-kontroll; båda vägarna verifieras via Play-knappens värde.
- `logic_set_cycle` — slår på/av cycle via Cycle-knappen (fallback: tangentkommandot `C` med frontmost-kontroll, readback via linjalens cycle region) och verifierar.
- `logic_set_cycle_range` — sätter loop-lokatorerna till ett heltaktsområde (t.ex. takt 5–9), med valfri cycle på/av efteråt. Se v0.6.0-avsnittet för mekanik och verifiering.
- `logic_set_playhead` — flyttar playhead till takt (och valfritt slag) genom stegvis konvergerande `AXValue`-skrivningar mot LCD-displayens sliders, med verifiering.

- `logic_select_track` — väljer ett spår via `AXSelectedChildren` på Tracks-header-gruppen (fallback: spårhuvudets `Has Focus`-knapp) och verifierar genom både headerns `AXSelected` och att inspector-strippen visar spåret. Kräver `track_number` vid namndubbletter, återställer föregående selektion om verifieringen misslyckas och rapporterar alltid föregående selektion.
- `logic_set_track_stack` — expanderar eller kollapsar en track stack, verifierar det nya läget och rapporterar vilka subspår som blev synliga eller dolda. Återställer spårselektionen om klicket ändrade den.
- `logic_add_plugin` / `logic_remove_plugin` — lägger till/tar bort plugins via insertmenyn; `logic_survey_plugins` — kartlägger ett spårs inserts; `logic_set_track_mute`/`_solo`/`_volume`/`_pan` — mixerkontroller via inspector-strippen. Se v0.10.0-avsnittet.
- `logic_open_plugin` — öppnar pluginfönstret för en specifik insert genom insertens open-knapp och verifierar att ett fönster dök upp. Detekterar redan öppna fönster via toggle-beteendet och återställer dem. Kräver `insert_index` när samma plugin ligger i flera slottar.
- `logic_close_plugin` — stänger en specifik inserts pluginfönster genom samma toggle och verifierar att ett fönster försvann. Fungerar även när flera fönster delar titel.
- `logic_close_plugin_window` — stänger ett pluginfönster via dess stängknapp; vägrar stänga projektfönster och felar med `ambiguous` när flera fönster delar titeln.
- `logic_set_plugin_parameter` — sätter ett formaterat värde, läser tillbaka det och återställer det gamla värdet automatiskt om verifieringen misslyckas.

Skrivverktygen kräver exakt identitet före varje mutation: `logic_open_plugin` kan dessutom verifiera projektets absoluta sökväg via `expected_project_path` innan något trycks. Parameterskrivningen kräver exakt fönstertitel, parameternamn, förväntat nuvärde och målvärde; ett oväntat nuvärde stoppar operationen innan någon skrivning sker.

Feltaxonomi: alla felresultat innehåller `error_code` med något av `not_found`, `ambiguous`, `not_exposed`, `precondition_failed`, `write_failed`, `verification_failed`, `not_trusted`, `not_running` eller `invalid_arguments`, tillsammans med en beskrivande text. Vid `ambiguous` och `precondition_failed` utförs ingen åtgärd alls.

### Verifierat demotest

Följande kördes mot det öppna Compressor-fönstret `Acke Vocals`:

```json
{
  "window_title": "Acke Vocals",
  "parameter": "Ratio",
  "expected_current_value": "4.2:1",
  "target_value": "3.1:1"
}
```

MCP-serverns bekräftade resultat:

```json
{
  "success": true,
  "verified": true,
  "state": "confirmed",
  "before": "4.2:1",
  "after": "3.1:1"
}
```

En separat parameterinventering efter skrivningen visade Ratio-råvärde `28`, vilket motsvarade det synliga värdet `3.1:1`.

Målet `3.0:1` gick inte att uttrycka exakt genom den exponerade Compressor-kontrollen i denna Logic-version. Kalibrering visade att råvärde `27` ger `2.9:1` och råvärde `28` ger `3.1:1`; kontrollen hoppar alltså över `3.0:1`. Det närmaste högre värdet `3.1:1` valdes. Två tidigare försök att skriva `3:1` och `3.0:1` gav `2.9:1`; servern upptäckte båda avvikelserna och återställde automatiskt `4.2:1` innan det slutliga verifierade testet.

### Förutsättningar och tidsåtgång i första demon

Den verifierade skrivningen hade två viktiga förutsättningar:

1. Processen som startade MCP-servern hade macOS-behörigheten **Hjälpmedel**.
2. Compressor-fönstret för `Acke Vocals` var redan öppet, så dess reglage och värdefält fanns i Logics Accessibility-träd.

Den första demon kunde alltså bara manipulera ett redan öppet pluginfönster. Sedan v0.2.0 (2026-08-24) kan servern själv hitta det valda spårets channel strip och inserts, öppna ett stängt pluginfönster verifierat och återställa fönsterläget; se avsnittet om verifierad spår- och insertidentifiering nedan. Sedan v0.3.0 kan servern dessutom själv välja spår bland de synliga spårhuvudena, så hela kedjan fungerar utan manuella försteg.

Hela MCP-anropet, inklusive start av demoprocessen, skrivning och verifierad återläsning, tog ungefär `0,8–0,9` sekunder. Med en redan körande server bedöms en enskild parameterändring ta ungefär `0,5–0,7` sekunder med nuvarande försiktiga väntetider. Väntetiderna finns för att Logic ska hinna uppdatera UI och tillstånd innan readback; de kan senare ersättas eller kompletteras med Accessibility-notifikationer.

Den avsedda helautomatiska kedjan är:

```text
projekt -> spår -> channel strip -> insert -> öppna plugin
        -> hitta parameter -> compare-and-set -> verifiera
        -> återställ eller stäng tillfälligt UI
```

## Verifierad spår- och insertidentifiering (2026-08-24, v0.2.0)

Den 2026-08-24 togs kravet bort på att användaren manuellt öppnar rätt pluginfönster. Följande kedja är nu implementerad och verifierad i den öppna Logic-sessionen:

```text
projekt (AXDocument) -> valt spår -> inspector channel strip -> insert-slot
        -> öppna plugin (verifierat) -> hitta parameter -> compare-and-set
        -> readback -> återställ värde -> stäng/återställ fönster (verifierat)
```

### Verifierade Accessibility-fynd för navigering

Samtliga fynd nedan är verifierade i Logic Pro 12.3.1 mot `Testlåt.logicx`:

- **Projektidentitet**: projektfönstrets `AXDocument` innehåller projektets absoluta sökväg (`file://`-URL). Pluginfönster har tom `AXDocument` och subrole `AXDialog`. Detta ger en robust identitetskontroll före varje write.
- **Opålitlig fönsterlista**: appelementets `AXWindows` returnerar ibland en tom lista när Logic inte är frontmost, trots att `AXMainWindow` och `AXFocusedWindow` fungerar. Appelementets `AXChildren` innehåller oftast fönstren plus menyraden — men senare samma dag observerades ett läge där även `AXChildren` bara innehöll menyraden medan `AXMainWindow`/`AXFocusedWindow` fortsatte fungera. Servern använder nu tre nivåer: `AXWindows`, sedan `AXChildren` filtrerat på roll `AXWindow`, sedan `AXMainWindow`+`AXFocusedWindow` (dedupplicerat). I sista läget kan pluginfönster saknas i listan.
- **Spårhuvuden**: gruppen `AXGroup desc='Tracks header'` innehåller ett `AXLayoutItem` per synligt spår med beskrivning `Track N “Namn”` (typografiska citattecken) och attributet `AXSelected`. Endast spårhuvuden som just nu renderas exponeras — i testprojektet 13 av 27 spår. Spårhuvudena exponerar bara `AXShowMenu`, ingen `AXPress`; spårselektionen löstes i stället via headergruppens `AXSelectedChildren`, se avsnittet om v0.3.0 nedan.
- **Inspector-strippar**: vänstra inspector-channel-strippen är ett `AXLayoutItem` vars beskrivning är spårnamnet och vars hjälptext börjar med `Left inspector channel strip`. Högra strippen är output (`Stereo Out`). Endast det valda spårets strip exponeras i inspektorn.
- **Insert-slottar**: varje audio-effekt-insert är en `AXGroup` direkt under strippen, i visuell ordning, med beskrivning = visat pluginnamn samt barnen `AXCheckBox desc='bypass'`, `AXButton desc='open'` och `AXButton desc='list'`. Send-slottar (t.ex. `Bus 3`) saknar open-knapp och filtreras därmed bort. Visade namn trunkeras: `Space D` för Space Designer. `Acke Vocals` exponerade sju inserts: Space D, Channel EQ, Tape Delay, Compressor, Compressor, DeEsser 2, Channel EQ.
- **Open-knappen är en toggle**: `AXPress` öppnar ett stängt pluginfönster och stänger ett öppet. Servern verifierar genom fönsterdiff (CFEqual/CFHash på fönsterelementen) med polling. Om ett fönster försvann i stället för att dyka upp var pluginen redan öppen; servern trycker då igen, verifierar att fönstret kom tillbaka och rapporterar `already_open`.
- **Fönstertitlar identifierar inte plugin**: pluginfönstrets titel är spårnamnet. Två öppna plugins på samma spår ger två fönster med identisk titel; ingen plugin-namnmarkör hittades i fönstrets AX-träd. Stängning per titel felar därför med `ambiguous` vid dubbletter, medan `logic_close_plugin` via insert-toggeln är entydig.

### Genomförda tester 2026-08-24

Alla tester kördes genom MCP-servern mot den öppna sessionen, utan Save:

1. `logic_list_windows`, `logic_list_tracks`, `logic_list_inserts` — skrivskyddade, korrekta resultat inklusive selektionsstatus och de sju inserts ovan.
2. Felvägar utan sidoeffekter: insert-listning för ej valt spår (`not_exposed` med uppgift om vilket spår som visas), `logic_open_plugin` för `Compressor` utan index (`ambiguous`, slottar 4 och 5 rapporterade), fel `expected_project_path` (`precondition_failed`, inget tryck), fel plugin på angivet index (`precondition_failed`), försök att stänga projektfönstret (`not_exposed`, vägrat).
3. `logic_open_plugin` DeEsser 2 → `opened` med verifierat nytt fönster; `logic_close_plugin` → `closed` verifierat.
4. `already_open`-detektering på Compressor slot 4 verifierad (toggle stängde, servern återöppnade och rapporterade korrekt).
5. Hela kedjan på Compressor slot 5: stäng → öppna via verktyget (`opened`, med projektverifiering) → `logic_set_plugin_parameter` Ratio `3.1:1` → `3.5:1` (`confirmed`) → återställt till `3.1:1` (`confirmed`). Fönster- och parameterläget lämnades exakt som före testet.

## Verifierad programmatisk spårselektion (2026-08-24, v0.3.0)

Spårselektionen är löst. Verifierade fynd:

- Spårhuvudets `AXLayoutItem` har `AXSelected`, men attributet är **inte** settable, och huvudet exponerar bara `AXShowMenu`.
- Tracks-header-gruppen (`AXGroup desc='Tracks header'`) exponerar **`AXSelectedChildren` som är settable**. Att skriva `[målspårets AXLayoutItem]` dit selekterar spåret; detta är verktygets primära skrivväg och den enda som hittills behövts i test.
- Varje spårhuvud har dessutom en `AXRadioButton desc='Has Focus'` med `AXPress`, vars värde speglar selektionen (1 för valt spår). Den är implementerad som fallback-skrivväg men har ännu inte behövt användas i live-test — betrakta fallbacken som obeprövad.
- Verifieringen sker genom två oberoende avläsningar: headerns `AXSelected` och att vänstra inspector-strippen byter till spårets namn.

`logic_select_track` avbryter utan åtgärd vid `not_found` (med lista över synliga spår), `ambiguous` (t.ex. `Ivan Vocals` som finns som både spår 21 och 22 — kräver `track_number`), namn/nummer-mismatch (`precondition_failed`) och fel projekt (`precondition_failed`). Vid misslyckad verifiering återställs föregående selektion automatiskt.

### Genomförda tester v0.3.0 (2026-08-24)

1. Felvägar utan sidoeffekter: okänt spårnamn, `Ivan Vocals` utan nummer, `Vocals` med fel nummer 21, fel `expected_project_path` — samtliga avbröt korrekt utan åtgärd.
2. `already_selected` för `Acke Vocals` rapporterades korrekt utan skrivning (`write_route: none`).
3. Selektion `Acke Vocals` → `Bas` → tillbaka, båda `verified` via `ax_selected_children`.
4. **Hela autonoma cross-track-kedjan** utan att något var föröppnat: välj `Bas` → `logic_open_plugin` Compressor slot 1 (`opened`, projektverifierad) → parameterinventering → Ratio `2.8:1` → `3.1:1` (`confirmed`) → återställt till `2.8:1` (`confirmed`) → `logic_close_plugin` (`closed`) → selektion återställd till `Acke Vocals` → fönsterläget verifierat identiskt med ursprunget. Ingen Save gjordes.
5. Bonusfynd: `Bas`-spårets insertlista exponerade även tredjepartsplugins — `Trilian` (Spectrasonics) och `PShft` (Pitch Shifter, korrekt rapporterad som bypassad). Insertinventeringen är alltså inte begränsad till Apple-plugins; deras inre parameterexponering är dock inte undersökt.

## Verifierade track stack-fynd (2026-08-24, v0.4.0)

Spår som inte syntes i spårlistan (6–19 i testprojektet) var inte utscrollade utan låg under en kollapsad track stack. Verifierade fynd:

- Ett stack-huvudspår har en `AXDisclosureTriangle` bland spårhuvudets barn, med hjälptexten `Track stack disclosure arrow. Show or hide subtracks.` och värde `0` (kollapsad) eller `1` (expanderad). Vanliga spår saknar triangeln. `logic_list_tracks` rapporterar detta som `is_stack`/`expanded`.
- **Logics spårhuvudkontroller är semantiskt läsbara men inte semantiskt manövrerbara**: `AXPress` på disclosure-triangeln returnerar success men gör ingenting, `AXValue`-skrivning likaså, och `AXShowMenu` på spårhuvudet returnerar `kAXErrorCannotComplete`. Ingen expand/collapse-menypost finns i menyraden (bara `Create Track Stack…`/`Flatten Stack`).
- Fungerande skrivväg: **ett syntetiskt musklick på triangelns egen `AXFrame`-mittpunkt**. Detta är inte blind koordinatklickning — målet identifieras semantiskt, och före klicket görs ett hit-test (`AXUIElementCopyElementAtPosition`) som måste träffa exakt triangelelementet, annars vägrar verktyget. Logic aktiveras (tas till förgrunden) före klicket, muspekaren återställs efteråt, och resultatet verifieras via triangelvärdet plus diff av spårlistan.
- Klicket kan som bieffekt selektera stack-huvudspåret (observerat en gång av tre); verktyget upptäcker detta och återställer föregående selektion automatiskt (`selection_restored: unchanged/restored/lost`).
- Diffen av spårlistan före/efter ger stackens submedlemmar: `Drums 'n' shit` (spår 5) avslöjade `Fill` (6), `Acke Slagverk` (7), `Ivan Slagverk` (8), `Drum Synth Kit` (9).

### Genomförda tester v0.4.0 (2026-08-24)

1. `logic_list_tracks` rapporterar `is_stack`/`expanded` korrekt (`Drums 'n' shit` kollapsad, `Vocals` expanderad).
2. Felvägar utan åtgärd: `logic_set_track_stack` på icke-stack (`Bas`) → `not_exposed`; expandering av redan expanderad `Vocals` → `already_expanded`.
3. Expandera `Drums 'n' shit` → `expanded`, verifierat, fyra subspår rapporterade som `revealed_tracks`; `AXPress`-vägen no-opade och `cg_click_on_ax_frame` användes.
4. E2E mot tidigare dolt subspår: välj `Acke Slagverk` (spår 7) → insertlista (Tape Delay bypassad, Pedalboard, Compressor bypassad, Channel EQ, …) → selektion tillbaka till `Bas` → kollaps verifierad med samma fyra spår som `hidden_tracks` → slutlistan identisk med ursprungsläget.
5. Selektionsåterställningen verifierad i båda riktningarna (en cykel där klicket ändrade selektionen och en där den var oförändrad).

Anmärkning om spår 10–19, **löst senare samma dag**: de låg i en nästlad stack — `Drum Synth Kit` (spår 9) är själv en track stack inuti `Drums 'n' shit`. Med båda stackarna expanderade listar `logic_list_tracks` alla 27 spår, inklusive 10–19 (`Kick Tight`, `Kick Top 2`, `Kick Punch`, `Clap Lofi`, `Clap Kött`, `Hi-Hat Click`, `Hi-Hat Mid`, `Hi-Hat Open`, `KRANE_snap_better_snare`, `KSHMR_Snare_Enhancer_33_Vinyl`), och nästlade stacks rapporteras korrekt som `is_stack` på alla nivåer. Verktyget hanterar dem utan specialfall: expandera den yttre stacken först, sedan den inre.

### Kvarstående begränsningar efter v0.4.0

- Endast renderade spårhuvuden kan listas och selekteras. Subspår i kollapsade stacks nås nu via `logic_set_track_stack`, men spår dolda via Hide-funktionen eller utanför renderingsytan är fortfarande onåbara; scrollning till spår är olöst.
- Track stack-toggling kräver klick-fallbacken (`cg_click_on_ax_frame`), som aktiverar Logic och tar det till förgrunden.
- `logic_set_plugin_parameter` adresserar fortfarande fönster per titel; med två öppna plugins på samma spår kan fel fönster träffas. Stäng övriga pluginfönster på spåret före parameterskrivning, eller utöka verktyget med fönsterdisambiguering.
- `Has Focus`-fallbacken i `logic_select_track` är obeprövad i live-test.
- Multiselektion: `AXSelectedChildren` skrivs alltid som en lista med exakt ett spår; beteendet vid befintlig multiselektion i Logic är inte undersökt.
- Hjälpmedelsbehörigheten är knuten till processen som startar servern. 2026-08-24 var AX-API:t avstängt (`kAXErrorAPIDisabled`, AXError -25211) tills användaren beviljade Hjälpmedel för klientappen; `logic_health` rapporterar detta som `accessibility_trusted`.

## Verifierad transportkontroll (2026-08-24, v0.5.0)

Transportkontrollen är förkravet för AU-planens jämförbara före/efter-mätningar (Cycle-loopning av samma takter). Verifierade fynd:

- **Control Bar är riktig AppKit**, till skillnad från spårhuvudenas canvas: `AXPress` fungerar på dess checkboxar (Cycle verifierat 0→1→0) och LCD-displayens sliders är faktiskt settable.
- **LCD-displayen** (`AXGroup desc='Playhead Position'` i inre Control Bar-gruppen) exponerar `bar`- och `beat`-sliders plus Tempo-slider, taktart- och tonartspopups. Playhead-position, tempo, taktart och tonart kan läsas direkt.
- **Stegvis slider-semantik**: en `AXValue`-skrivning på LCD-slidern flyttar värdet exakt ett steg mot målet, inte till målet. `logic_set_playhead` skriver därför upprepat tills konvergens, med fastnat-detektering. Verifierat: takt 9→5→9.
- **Play-knappen är asymmetrisk**: `AXPress` startar uppspelning (värdet blir 1), men ett nytt tryck stoppar INTE. Inget stoppkommando finns i menyraden — posterna under `Navigate > Stop Button Options` är knappkonfiguration, inte kommandon. `CGEventPostToPid` med space ignoreras av Logic i bakgrunden. Fungerande stoppväg: space via HID-tap med Logic verifierat frontmost (`AXFrontmost == 1` krävs före tangenttryck, annars vägrar verktyget — skyddar mot att tangenten hamnar i fel app).
- Transportläget (playing/recording/cycle/metronom/count-in/solo) läses från Control Bar-checkboxarnas värden.

### Genomförda tester v0.5.0 (2026-08-24)

1. `logic_get_transport` — komplett korrekt avläsning (tempo 120, 4/4, B♭-dur, playhead 9.1).
2. `logic_set_playhead` 9→5.1→9 verifierat (`ax_value_stepwise`).
3. `logic_set_cycle` på→av verifierat (`ax_press`).
4. `logic_set_playing` true (`ax_press`) → uppspelning bekräftad med rörlig playhead → false via space-frontmost-vägen, verifierad → `already_stopped` vid upprepning. Playhead återställd efteråt.
5. Felupptäckt under vägen: ett `AXPress` på menyposten `Navigate > Stop Button Options > Stop` gjordes i tron att det var ett stoppkommando; det är en inställning för stoppknappens beteende. Nuvarande markering är `Stop`; ursprungsvärdet är okänt.

### Kvarstående för AU-jämförbarhet

- ~~Cycle-områdets lokatorer kan ännu inte sättas programmatiskt.~~ **Löst i v0.6.0**, se nästa avsnitt.
- Stoppvägen kräver att Logic tas till förgrunden (samma begränsning som stack-klicket).

## Verifierade lokatorer / cycle-område (2026-08-24, v0.6.0)

Sista pusselbiten för AU-planens jämförbara mätningar: `logic_set_cycle_range` sätter loop-lokatorerna till exakta heltakter. Verifierade fynd:

- **Linjalen** (`AXLayoutArea desc='Tracks time ruler'`, roleDescription "time line") exponerar barnen `cycle region` (AXLayoutItem), `Playhead thumb`, `Start Marker` och `End Marker` (AXValueIndicator).
- **Pixelkoordinater är färskvara**: Logic auto-scrollar vyn vid playhead-flytt och layouten ändras vid fönsterresize. Tumme och region måste alltid läsas i samma ögonblicksbild och aldrig jämföras över en playhead-flytt — detta orsakade den första implementationens verifieringsfel.
- **Skala**: px/takt beräknas ur Start/End-markörernas positioner och deras `AXValueDescription` ("1 bar", "82 bars"). **Ankare**: playhead parkeras på regionens takt och tumme↔regionkant-matchning ger exakt takt↔pixel-ankare plus konstant ikonoffset.
- **Tre verifierade skrivbeteenden i cycle-remsan**:
  1. `AXPosition`-skrivning på regionen flyttar starten och **snappar till taktgräns** (`AXSize` är inte skrivbar — en size-write är en tyst no-op).
  2. Drag som **startar på tom remsa** skapar ett nytt taktsnappat område från dragstart till dragslut.
  3. Drag som **startar inne i regionen flyttar den** i stället — därför väljer verktyget riktning eller flyttar undan regionen (via position-write) så att dragstarten aldrig träffar den.
- **Playhead-tummens `AXValue`** är settable i tick-skala men stegar bara en tick per skrivning — oanvändbart för hopp; LCD-vägen består.
- **Flytande pluginfönster kan täcka linjalen**: dragvägen gör `AXRaise` på projektfönstret före hit-test, och hit-testet måste träffa linjalen/regionen, annars vägrar verktyget med besked om vad som täcker.
- **Verifiering**: playhead flyttas till starttakten och tummen (plus uppmätt offset) måste linjera med regionkanten inom 0,3 takt, samtidigt som regionens `AXSizeDescription` måste rapportera exakt begärt antal takter. Playhead återställs alltid efteråt.
- **Modala dialoger** (t.ex. felmeddelande om saknad plugin) tömmer Logics AX-fönsterlistor — detta var orsaken till dagens tidigare "tomma fönster"-läge. Fönsterresize kollapsar dessutom Control Bar-knappar: Cycle-knappen kan försvinna, så cycle-toggling har fallback via tangentkommandot `C` och cycle-status läses ur regionens `AXValueDescription` (`on`/`off`).

### Genomförda tester v0.6.0 (2026-08-24)

1. Flytt av område med samma längd 9–13 → 5–9 via ren positionsskrivning (`ax_position_grid_snap`), verifierad.
2. Längdändring 5–9 → 3–10 via drag-create (`cg_drag_create`), verifierad; kollisionsfallet där målområdet låg helt inne i befintlig region löstes genom undanflyttning före draget.
3. Cycle på/av via `enabled`-argumentet, inklusive C-tangent-fallback när knappen kollapsat bort.
4. **Acceptanstest för mätprimitiven**: loop 5–9 med cycle på → uppspelning → playhead vid takt 8 efter 6 s (exakt 3 takter vid 120 BPM, inuti loopen — cyklingen bekräftad) → stopp → området återställt till 9–13 med cycle av. Allt verifierat.

Kvarstående begränsning: målområdet måste vara synligt i linjalen (ingen programmatisk scroll/zoom ännu), och heltakter är enda upplösningen.

## Verifierat AU-sensorskelett (2026-08-24, v0.7.0)

Första versionen av "öronen" från Live AI Mix Assistant-planen är byggd och validerad. Komponenter:

```text
Sensor/LogicMCPSensor.c   — AUv2-effekt i ren C, utan externa SDK:er
Sensor/Info.plist         — komponentregistrering (aufx / lmsn / LMcp)
Sensor/build.sh           — bygg + signering + installation + auval
```

### Arkitektur (verifierad)

- **AUv2 i C** valdes för att den kan byggas utan Xcode-projekt och körs i värdens process, vilket gör IPC trivial. Hela `AudioComponentPlugInInterface`-dispatchen är handimplementerad (~700 rader): properties, lyssnare med notifikationer, render-notify, format, presets.
- **Transparent passthrough med metering**: rendervägen drar input via callback/connection, mäter peak och RMS per kanal och rör aldrig ljudet. Realtidsregler följs: inga lås, ingen allokering, ingen fil-I/O eller loggning i render (ringen är mmappad och förberörd vid initialize).
- **Ringbuffer over mmap**: `~/Library/Application Support/LogicMCPSensor/sensor-<uuid>.ring` (128 B header + 2048 frames à 72 B, ~10 frames/s). Sandboxade värdar som App Store-Logic skriver samma relativa sökväg inne i sin container; MCP-servern söker båda platserna. Layouten är låst med `_Static_assert` i C och parsas offsetbaserat i Swift. Publicering sker med atomisk release-store av skrivkursorn; filen unlinkas vid uninitialize (verifierat).
- **HostCallbacks**: sensorn fångar beat, tempo och transportläge från värden per frame — i Logic blir AU:n därmed den oberoende sanningen om huruvida ljudet faktiskt rullar (jfr play-anomalien från transportdemon).

### Verifierade tester v0.7.0

1. **`auval -v aufx lmsn LMcp`: AU VALIDATION SUCCEEDED** — instansiering, alla obligatoriska/rekommenderade properties inklusive property-listener-notifikationer, rendertester i 22050–192000 Hz, mono och stereo, connection-semantik, felhantering vid för stora buffertar.
2. **Full pipeline utan Logic**: en minimal testvärd matade en -6 dBFS-sinus genom sensorn i 3 sekunder; `logic_sensor_read` rapporterade peak `-6.02 dBFS` och RMS `-9.03 dB` — exakt teoretiskt värde för en 0,5-amplitudssinus — plus korrekt kanalantal, samplerate, åldersstämpel och fönsteraggregat. Beat/tempo/transport var korrekt `null`/`unknown` eftersom testvärden inte ger HostCallbacks.
3. Ring-filen städas bort vid uninitialize; `logic_sensor_read` rapporterar tom sensorlista efteråt.

Byggnotis: projektet ligger i en iCloud-synkad mapp vars utökade attribut (`FinderInfo`, `fileprovider`) får codesign att vägra; `build.sh` bygger därför i en osynkad temp-katalog och installerar med `ditto --noextattr`.

### Nytt MCP-verktyg

- `logic_sensor_read` — listar aktiva sensorinstanser med senaste frame (peak/RMS i dBFS per kanal, beat, tempo, transport, bypass, ålder) och aggregat över ett valbart tidsfönster, med `stale`-flagga när en sensor slutat publicera.

### Verifierat i Logic samma dag

Användaren lade in sensorn som insert på `Stereo Out` (`Audio Units > LMcp > LogicMCP: Sensor`) och startade om Logic. Verifierat:

- **Logic Pro 12.3.1 laddar AUv2-komponenten**, instansierar den och behåller den i projektet över omstart.
- **Logic driver effekter genom `AudioUnitProcess`** (`kAudioUnitProcessSelect`), inte klassiska `AudioUnitRender`. Första bygget exponerade bara Render och fick noll frames i Logic trots grönt `auval` — auval testar inte Process-vägen, en viktig blind fläck. Sensorn svarar nu på Render, Process och ProcessMultiple.
- **HostCallbacks fungerar**: under uppspelning rapporterade sensorn beat `23.99`, tempo `120` och `transport: playing` — beatpositionen stämde exakt med playheadens läge. Riktiga nivåer från Stereo Out: peak ≈ `-18.4 dBFS`, RMS ≈ `-22.5 dB`.
- **Sensorn publicerar även i stoppat läge** (Logic håller motorn igång) och rapporterar då `transport: stopped` med tystnadsnivåer — därmed finns den oberoende "rullar ljudet verkligen"-signal som transportdemons play-anomali visade behovet av.
- Ringfilen hamnade i den vanliga hemkatalogen, inte i Logics container — denna Logic-installation är inte filsandboxad för AU-skrivningar.
- Kosmetiskt: Logics pluginfönster för sensorn visar en evig laddsnurra eftersom AU:n saknar UI och parametrar; ofarligt.
- Transportfynd på köpet: Play-knappen vägrar aktiveras när playheaden står bortom projektslutet (takt 83 > End Marker 82) — flytta playheaden först.

### Verifierad closed-loop-mätning (2026-08-24)

AU/MCP-demons acceptanskriterium är uppfyllt. Följande kördes i sin helhet genom MCP-verktygen, med parameterändringarna applicerade mitt under pågående uppspelning:

1. `logic_set_cycle_range` 5–9 med cycle på; playhead till 5; play.
2. **Baseline** över ett helt looppass (8 s, 76 frames): RMS `-23.01/-22.99 dB`, max peak `-13.55/-13.82 dBFS`; beat-värdet bekräftade att loopen cyklade.
3. **Ändring**: 808-spårets Compressor Ratio `2.1:1 → 3.5:1` via compare-and-set (`confirmed`), under uppspelning.
4. **Efter-fönster** (8 s, 77 frames): RMS `-24.28/-24.25 dB`, max peak `-14.23/-14.55 dBFS` — hårdare kompression på 808:an sänkte masterbussens RMS med `1,27 dB` och peak med `~0,7 dB`. Objektivt detekterat.
5. **Beslut: rollback** till `2.1:1` (`confirmed`), följt av kontrollfönster: RMS `-23.01/-22.99`, peak `-13.55/-13.82` — **identiskt med baseline på 0,01 dB när**, vilket samtidigt validerar att cycle-loopning ger repeterbara mätfönster.
6. Städning: stopp, pluginfönster stängt, cycle av, playhead återställd.

Cycle-loopning över samma takter ger alltså mätrepeterbarhet på hundradels dB-nivå — gott och väl tillräckligt för closed-loop-beslut.

## Verifierat paketerat closed-loop-verktyg (2026-08-25, v0.8.0)

Hela mätloopen är nu ett enda MCP-verktyg: **`logic_evaluate_change`**. Ett anrop utför:

```text
välj spår -> öppna plugin -> sätt cycle-lokatorer -> spela
-> baseline-fönster (exakt ett looppass, längd ur tempo/taktart)
-> exakt en compare-and-set-parameterändring under uppspelning
-> efter-fönster -> keep eller rollback (default rollback)
-> kontrollfönster som verifierar rollbacken (default på)
-> återställ transport, cycle, playhead och fönsterläge
```

Designbeslut värda att notera:

- **Fönsterlängd = ett looppass** beräknat ur tempo och taktartens täljare. Eftersom parameterändringen är persistent behövs ingen loopfas-justering: varje sammanhängande fönster av exakt ett pass täcker samma musikaliska material en gång.
- **Sensorn är grindvakt**: verktyget vägrar starta utan en färsk sensorinstans, och varje mätfönster kräver att sensorn rapporterar `transport: playing` — skyddet mot play-anomalien är därmed inbyggt i kontraktet.
- Rapporten innehåller per sensor: baseline/efter/kontroll-fönster (RMS, max peak, frames, beat), deltas i dB samt `rollback_residual` som repeterbarhetsmått.
- `keep_change: true` behåller ändringen; default är ren mätning som lämnar sessionen orörd.

### Verifierat test (2026-08-25)

Ett enda anrop mot `808 > Compressor (slot 3) > Ratio 2.1:1 → 3.5:1`, loop 5–9, ~40 sekunder:

- Baseline RMS `-25.22/-25.17 dB` (nivåerna skiljde sig från gårdagens — användaren hade lagt till en Decapitator på spåret, vilket först fångades av slot-preconditionen: *"Insert slot 2 holds 'Channel EQ', not 'Compressor'. No action was taken"* — identitetskontrakten fungerar i praktiken).
- Efter-fönster: RMS-delta `-1.15/-1.14 dB`, peak-delta `-0.47/-0.53 dB` — objektivt detekterat.
- Rollback + kontrollfönster: `rollback_residual` RMS `0.00/0.00 dB` — mätrepeterbarheten på hundradels dB-nivå bekräftad igen.
- Återställt: stoppat, cycle av, playhead tillbaka, pluginfönster stängt, parameter återställd.

## Sensorn som bouncer — lyssningsbart ljud, inte bara siffror (2026-08-25, v0.9.0)

Designinsikt från användaren: siffror som LUFS/dB räcker inte som beslutsunderlag — modellen (eller människan) ska kunna **lyssna** på före/efter. Sensorn agerar därför nu även "bouncer":

- **Rullande audio-ring**: AU:n skriver kontinuerligt de senaste 45 sekunderna interleaved float32 till en andra mmappad fil (`sensor-<uuid>.audio`, ~16 MB vid 44,1 kHz stereo), med samma realtidsregler som feature-ringen. Feature-frames bär nu ett `audioSampleCursor`-fält för sample-noggrann tidsmappning (framelayout 72→80 byte, låst med `_Static_assert`).
- **`logic_sensor_capture`** — bouncar de senaste N sekunderna (max 45) från varje aktiv sensor till 16-bitars WAV i `~/Library/Application Support/LogicMCPSensor/captures/`. Read-only mot Logic.
- **`logic_evaluate_change` bifogar ljud**: varje mätfönster (baseline/efter/kontroll) fångas som WAV direkt efter mätningen — "senaste passlängden i ringen" är per definition det uppmätta fönstret. Rapporten innehåller nu både siffror och sökvägar till lyssningsbara filer per fönster.
- Kontraktet är modelloberoende: en audio-kapabel modell lyssnar på filerna; övriga klienter (och människan) använder dem som A/B-underlag; siffrorna kvarstår som grindvakt och snabbfilter.

### Verifierat test v0.9.0 (2026-08-25)

- `auval`: AU VALIDATION SUCCEEDED efter audio-ring-tillägget.
- Full pipeline utan Logic: -6 dBFS 440 Hz-sinus genom sensorn → `logic_sensor_capture` → WAV-analys av filen gav peak `-6.02 dBFS`, RMS `-9.03 dB`, frekvens `440 Hz`, längd exakt 3,000 s, 2 kanaler 44,1 kHz Int16. Bit-perfekt kedja.
- Kräver Logic-omstart för att den nya AU-koden ska laddas (in-process AUv2).

## Mixerkontroller, plugin-hantering och kartläggning (2026-08-25, v0.10.0)

### Stoppbuggen i evaluate-loopen fixad

`logic_evaluate_change` kunde lämna uppspelningen igång: macOS kan neka `NSRunningApplication.activate()` när användaren är aktiv i en annan app, varpå stopp-tangenten aldrig skickades och `try?` svalde felet tyst. Åtgärder: `ensureLogicFrontmost` har nu en andra, kraftfullare aktiveringsväg (`AXFocusedApplication` på system-wide-elementet), cleanup gör tre stoppförsök med verifiering, och rapportens `restored`-fält visar det faktiska utfallet (`STILL_PLAYING_stop_failed` i stället för tystnad).

### Nya mixerverktyg (alla livetestade och återställda)

- `logic_set_track_mute` / `logic_set_track_solo` — **inspector-strippens mute/solo-knappar svarar på `AXPress`** (till skillnad från spårhuvudenas döda kontroller). Verifierat av/på/av.
- `logic_set_track_volume` — konvergerar fadern mot ett mål i **dB** via `AXValueDescription`-avläsningen (stegvis skrivsemantik som LCD:n; obs svensk lokal med kommadecimal i avläsningen). Verifierat -14,2 → -10,0 → -14,2 dB exakt.
- `logic_set_track_pan` — rå knappposition (-64..63), stegvis konvergens, verifierat 0 → 10 → 0.

### Plugin-hantering: `logic_add_plugin` / `logic_remove_plugin`

Verifierade fynd om Logics pluginväljarmeny:

- Insert-slottens knappar öppnar väljaren (AXPress rapporterar fel men menyn öppnas; verifiera på menyns existens, inte statuskoden). Menyn identifieras som popup-menyn som innehåller `Audio Units` eller `No Plug-in`.
- Hela menyträdet (kategorier, Audio Units per tillverkare, Recent) är **läsbart** via AX utan att öppna undermenyer — men **`AXPress` på poster i stängda undermenyer är en tyst no-op**. Fungerande väg: mushovra upp varje undermeny längs titelvägen (frames från AX) och klicka slutposten.
- **Aktivering av Logic stänger en öppen meny** — frontmost måste säkras innan menyn öppnas, aldrig under navigering.
- Formatundermenyn följer kanalens format: ett monospår erbjuder bara `Mono`. Verktyget tar begärt format om det finns, annars det som erbjuds, och rapporterar valet.
- Nya plugins hamnar i **första lediga slot** (inte nödvändigtvis sist); verifieringen diffar slotlistorna positionsvis. Borttagning via slotmenyns `No Plug-in`, verifierad genom minskat insertantal.
- Livetestat: Gain in/ut på `808` flera gånger, strippen exakt återställd.

### Kartläggning: `logic_survey_plugins`

Inventerar varje insert på ett spår (öppna → lista parametrar → stäng) med klassificering och, för plugins utan semantiska sliders, en **rollcensus** av fönstret. Resultat för `808`:

| Insert | Klassificering | Fynd |
|---|---|---|
| Decapitator (Soundtoys) | `no_semantic_sliders` | Bara 2 knappar/2 checkboxar — custom canvas, opak för AX |
| Channel EQ | `read_write_candidate`, **26 parametrar** | Full bandexponering efter filterlättnad |
| Compressor | `read_write_candidate`, 11 parametrar | Matchar den verifierade tabellen |
| Q-Sampler | `no_semantic_sliders` | Custom canvas |

**Viktigt genombrott**: README:s öppna fråga "Hur exponerar Channel EQ sina band?" är besvarad. Banden är vanliga `AXSlider`s med namn i `AXDescription` i stället för hjälptext (`Low Cut Frequency`, `Peak 1 Gain`, `Peak 4 Q` osv, alla skrivbara). Parameterfiltret krävde tidigare både `AXIdentifier` och `AXHelp` (Compressor-formatet); nu räcker någon semantisk handtag, vilket öppnade alla 26 EQ-parametrarna.

**Begränsning bekräftad**: tredjepartsplugins med custom-ritade rattar (Decapitator) och Logic-instrumentytor (Q-Sampler) exponerar inga AX-reglage. Vägen till dem är värd-automation via kontrollytprotokoll/MIDI (Controller Assignments) — nästa stora forskningsspår.

## Projektomfattande plugin-svep genomfört (2026-08-25, v0.11.0)

Hela projektet sveptes med `logic_survey_plugins`: **alla 29 spår + Stereo Out, 87 inserts, 26 unika plugin-typer** på ~2 minuter. Resultatet ligger i [PLUGIN-REGISTRY.md](PLUGIN-REGISTRY.md) (läsbart register) och `plugin-survey-2026-08-25.json` (rådata).

Nyckeltal: **53 av 87 inserts (60 %) är styrbara** via MCP:ns verifierade parameterväg. Styrbara familjer: Channel EQ (26 parametrar), Pedalboard (19), Bass Amp (16), Space Designer (13), Compressor (11), Amp (10), Sampler (6), AutoFilter (4), ClipDist (3), Bitcrusher (1). Opaka (custom-UI utan AX-reglage): DeEsser 2, Tape Delay, Decapitator, Trilian, Q-Sampler, Drum Synth m.fl.

Fynd och fixar under svepet:

- **Drum Machine Designer** öppnas som en namnlös dialog som **bär projektets `AXDocument`** — den kapade `projectWindow()`-uppslaget och saknar `AXCloseButton`-attribut (stängs via en barn-knapp `close`). Båda hanteras nu: projektfönstret kräver `AXStandardWindow`, och fönsterstängning har fallback till barn-knappen.
- **Stack-toggling kräver synligt spårhuvud**: när spårlistan är scrollad felar disclosure-klickets hit-test. `logic_set_track_stack` väljer nu spåret först (auto-scrollar det i vy) och återställer användarens ursprungliga selektion efteråt.
- **Output-strippar adresserbara**: `inspectorStrip` faller tillbaka till valfri namnmatchande strip, så `Stereo Out` (högra inspector-strippen) fungerar med survey/open/parametrar utan att vara ett valbart spår.
- Limiter på Stereo Out har 4 sliders helt utan semantik (namnlösa) — nås inte via nuvarande namnmatchning; kandidat för positionsbaserad adressering.

## MCU-bryggan — den datadrivna kontrollvägen (2026-08-25, v0.12.0)

Efter beslutet att undvika "Browser Use för Logic" byggdes kontrollytvägen som README alltid pekat mot. Arkitektur:

```text
Sources/LogicMCUBridge/main.swift  ->  logic-mcu-bridge (daemon)
    virtuella CoreMIDI-portar "Logic MCP MCU" (källa + destination)
    Mackie Control-protokoll  <->  Logic (dokumenterat, dubbelriktat)
    tillståndsspegel: ~/Library/Application Support/LogicMCPMCU/state.json
    kommandon: unix-socket command.sock
MCP-verktyg: logic_mcu_status (läs spegeln), logic_mcu_command (skicka)
```

Engångskonfiguration (gjord 2026-08-25): Logic Pro → Control Surfaces → Setup → New → Install → Mackie Designs / Mackie Control, med in/ut-port `Logic MCP MCU`.

### Verifierat 2026-08-25 — allt utan UI, fokus eller fönster

- **Spårnamn som data**: LCD-toppen speglar bankens åtta spårnamn (`LofPad Bas 808 …`); nedre raden visar aktuella vpot-värden (pan-läge visade användarens `+9`-panorering).
- **Transport via protokollet**: play-tryck → play-LED tänd och tidsdisplayen rullar (takt 21 → 22.3); stopp-tryck → stop-LED, frusen display. **Ersätter space-tangent-hacket och frontmost-kravet helt.**
- **Playheadposition som data**: 7-segmentdisplayen ger takt/slag/division/tick kontinuerligt.
- **Faders med dubbelriktad feedback**: skrev 8000 (14-bit) till kanal 3, Logic snappade och ekade `7950`, återställde till exakt `6657`. Ekot är readback-verifieringen — compare-and-set-kontraktet får en riktig datakanal.
- **Plugin-läget är vägen in i ALLA plugins**: `assign_plugin` visar insertnamn per kanal på LCD:n; vpot-tryck öppnar parameterläget som strömmar **parameternamn och formaterade värden med enheter** (`LoCutS 24`, `LoShGa -8.5dB`, `Pea4Ga +9.6dB` …). Detta är värd-automation — den fungerar även för custom canvas-plugins (Decapitator, Trilian) som Accessibility aldrig når.

### Kvarstående för MCU-spåret

- Bridgen startas manuellt (`.build/release/logic-mcu-bridge`); produktion bör använda launchd. Virtuella portar försvinner när bridgen stoppas; Logic återansluter när de dyker upp igen (namnmatchning).
- Migrera högnivåverktygen till MCU som primär väg: transport (klar att byta), faders (14-bit ↔ dB-kalibrering återstår), mute/solo/select per bankkanal, bankning för >8 spår.
- Pluginparametrar via vpot: bygga bank-/sidnavigering, mappa vpot-delta ↔ värdesteg, verifiera skrivning med LCD-eko som readback.
- 7-segmentavkodningen av tidsdisplayen är förenklad (verifierad för siffror/mellanslag).
- AX degraderas därmed till: strukturinventering, plugin-tillägg (menyer), stackar, samt semantisk kartläggning — och fallback.

## MCU-migrering genomförd — datavägen är förstahandsval (2026-08-25, v0.13)

Högnivåverktygen kör nu MCU som primär väg med AX som fallback. Kontraktet: MCU-lagret returnerar "otillgänglig" (→ AX-fallback) bara när inget skrivits; efter en skrivning som inte kan verifieras kastas fel i stället för tyst fallback (aldrig dubbelskrivning).

| Verktyg | MCU-väg | Verifiering |
|---|---|---|
| `logic_set_playing` | play/stopp-knapp | transport-LED |
| `logic_set_cycle` | cycle-knapp | cycle-LED |
| `logic_set_track_mute`/`_solo` | bank-scan → kanalknapp | kanal-LED |
| `logic_set_track_volume` | bank-scan → CS-läge → vpot-konvergens | LCD-dB-eko |

**Kanaluppslag via bank-scanning**: LCD-namnen är Logics egna förkortningar ("LofPad", "AckVoc") och matchas som teckensubsekvens av spårnamnet. Skanningen bankar längst vänster, läser varje bank tills innehållet repeteras, kräver exakt en träff (annars AX-fallback) och navigerar tillbaka med innehållsverifiering. MCU-bankerna omfattar även aux-kanaler och subspår i kollapsade stackar.

Hårt vunna protokollfynd (alla verifierade 2026-08-25):

- **`assign_pan` är en TOGGLE** mellan flerkanalsvyn (spårnamn) och en enkanalsvy (`Pan    -   -   ...`) — och assignment-displayen visar `PN` i båda. Lägen måste verifieras på LCD-innehåll, aldrig genom blinda knapptryck; ett "extra" tryck för säkerhets skull inverterar läget och förgiftar allt efterföljande.
- **LCD-transienter**: snabba bankbyten målar banners innan innehållet stabiliseras. All skanning väntar på två identiska, icke-transienta läsningar i rad.
- **LCD-celler är 7 tecken** och `dB`-suffixet kan kapas mitt i (`-10,0 d`); värdeparsning tar bara den inledande numeriska delen (och hanterar svenskt decimalkomma).
- **En tyst Logic skickar ingenting**: passiv "online inom 10 s"-heuristik ger falska offline-beslut. Färskhetskravet är avslappnat; den verkliga livstecknet är per-operationens LED/LCD-eko.
- Volymkonvergensen är adaptiv: ~0,4 dB/tick som startgissning, per-tick-skattningen uppdateras från faktisk respons.

Regressionssvit (allt `route: mcu`): play/stopp, cycle på/av, mute på/av (`Acke Vocals`, bank 2), volym `Bas` -4,7 → -4,0 → -4,7 exakt. `logic_get_transport` och AX-vägarna kvarstår som dokumenterade fallbacks.

## Pluginparametrar via MCU — de opaka pluginsen är öppnade (2026-08-25, v0.14.0)

Tre nya verktyg gör värd-automation av pluginparametrar, helt utan UI:

- `logic_mcu_plugin_inserts` — spårets insertslottar som MCU:n ser dem (fysiska slotnummer 1–8 med pluginnamn).
- `logic_mcu_plugin_parameters` — parameternamn + formaterade värden för ett slot (första MCU-sidan, upp till 8).
- `logic_mcu_set_plugin_parameter` — verifierad skrivning: numeriska mål konvergeras adaptivt mot LCD-ekot (engångs-probe-tick lär sig stegstorleken), textmål (enums som `On`, `B`) stegas med eskalerande stegstorlek tills exakt träff. Compare-and-set via `expected_current_value`; misslyckad verifiering rullar tillbaka.

Verifierad mode-graf för `assign_plugin` (alla fynd 2026-08-25):

```text
PN --assign_plugin--> P1 (bankvy: insert 1 per kanal)
P1 --assign_plugin--> PL (VALDA spårets inserts, "Ins1Pl…Ins8Pl")
PL --vpot_press(i)--> P<i+1> EDIT (parameternamn + värden på LCD)
EDIT --assign_plugin--> P<i+1>-bankvy <--assign_plugin--> PL (alternerar)
```

- **PL-vyn följer Logics valda spår** — kombinerat med den verifierade spårselektionen behövs ingen bank-scanning för pluginparametrar.
- ⚠️ **Vpot-VRIDNING i bankvyerna (P1/P#) öppnar plugin-BROWSERN** ("Insert 1 Plug-in: Parametric EQ …") — vridning + tryck skulle byta plugin. Verktygen vrider aldrig vpots utanför edit-läget.
- **MCU:ns slotnummer är fysiska positioner** och kan skilja sig från AX-listans ordningstal (808: AX säger [1,2,3], MCU säger Ins3/Ins5/Ins6) — använd `logic_mcu_plugin_inserts` för att slå upp slot före skrivning.
- Vpot-tryck i bankvyer byter dessutom Logics spårselektion — ännu ett skäl att bara trycka i PL-vyn.

Verifierade tester:

1. **Compressor (808, Ins3)**: hela första parametersidan läst (`CirTyp PltDig, Thrs -20.0, Ratio 2.1:1, Attack 15.0ms, …`); Ratio skriven 2.1:1 → 2.2:1 → 2.1:1 via vpot med LCD-eko.
2. **Decapitator (808, Ins6)** — pluginen som är helt osynlig för Accessibility: full parameterläsning (`Bypass Off, Style A, Drive 0.0, Punish Off, LowCut 20.0Hz, Tone 0.0 dB, HiCut 20000., Mix 100.0%`); numerisk skrivning `Drive 0.0 → 2.5 → 0.0` (`confirmed`, compare-and-set); enum-skrivning `Style A → E → A` (`confirmed`).

LCD-värden är 7 tecken (trunkerade enheter hanteras i parsern).

### Parametersidbläddring knäckt (2026-08-25, v0.15.0)

Sidbläddring i plugin-edit-läget sker med **cursor-tangenterna** (not `0x62`/`0x63`) — inte bank/channel-knapparna som paginerar i mixervyerna. Verifierade fynd:

- Direkt efter ett cursor-tryck visar LCD:ns två högra fält en **transient "Page x/y"-indikator** (~1–2 s) — den ger både aktuell sida och totalt antal, och används för normalisering: ett ofarligt cursor_left-tryck (no-op för parametrarna på sida 1) framkallar indikatorn, varpå verktyget bläddrar till sida 1 deterministiskt.
- Efter att indikatorn tonat bort visar alla 8 fält parametrar; läsningar väntar på indikatorfritt läge.
- **Sista sidan är end-alignad** och kan överlappa näst sista (Compressorns sida 3 repeterar sida 2:ans svans); överlappet dedupas genom längsta namn+värde-matchning.
- Cursor upp/ned byter insert-slot i edit-läget (används ej); `name_value`, `global_view` och shift+channel har andra effekter (dokumenterat i proberna, undviks).

`logic_mcu_plugin_parameters` läser nu **alla** sidor, och `logic_mcu_set_plugin_parameter` söker parametern över alla sidor, navigerar till rätt sida och konvergerar där.

Verifierat: Compressor **20 parametrar över 3 sidor** (inkl. sidechain-filtret Mode/Freq/Q/Gain på sida 3); skrivning på sida 2-parametern `Knee 0.7 → 1.0 → 0.7` (`confirmed`, compare-and-set). Decapitator visade sig ha **12 parametrar över 2 sidor** (sida 2: AutGai, LoThmp, HiSlop, OutTrm); Drive-regression `0.0 → 1.5 → 0.0` (`confirmed`).

## MCU-omsvept plugin-register — 100 % täckning (2026-08-25, v0.15)

Hela projektet omsveptes via ren MCU-orkestrering (python mot bridge-socketen): varje kanal i bankerna valdes med MCU:ns SELECT-knapp, varje insert öppnades i plugin-edit och samtliga parametersidor lästes. Resultat i [PLUGIN-REGISTRY.md](PLUGIN-REGISTRY.md) + rådata i `plugin-survey-mcu-2026-08-25.json`.

**23 unika plugin-typer, 74 insertinstanser, 479 unika parametrar — alla läs- och skrivbara.** Jämfört med AX-svepet: Channel EQ 41 parametrar (AX: 26), Space Designer 88 (AX: 13), och samtliga tidigare opaka plugins öppnade — Tape Delay 16, St-Delay 19, PlatinumVerb 18, Enveloper/SmpleDly/Bitcrusher 8, DeEsser 2 och PShft 6, Overdrive 4, Decapitator 12.

Fynd under svepet:

- **Stereo Out, auxar och busskanaler (Reverb/Delay/Preview/Click) är vanliga bankkanaler** i MCU:n — masterkedjan och sändbussarna sveps som vilka spår som helst.
- **Global view (not `0x33`) inkluderar subspår i kollapsade stackar** — svepet behövde aldrig expandera stackar via UI:t. (Symboliskt nog hade AX-vägens disclosure-klick just gått sönder av att användaren smalnat av spårhuvudkolumnen — datavägen märkte ingenting.)
- Bypassade plugins prefixas `*` på LCD:n och trunkeras då ett tecken kortare mitt i namnet (`SpaceD` → `*SpacD`); registret kanoniserar via subsekvensmatchning.
- Kanaler vars 7-teckensnamn kolliderar (tre `Hi-Hat`-spår) sveps bara en gång per namn — känd lucka, i praktiken delar de plugin-uppsättning.
- Instrument (Q-Sampler, Trilian, Drum Machine Designer) ligger i instrumentslottar utanför insertlistan — nås via `assign_instrument` (framtida arbete).

### Strategi för plugin-biblioteket (ej bara projektet)

Beslut efter användarfråga: **ingen massinstansiering av hela biblioteket.** MCU-vägen läser parametrar live vid användning, så registret är en cache, inte ett krav — en agent kan upptäcka vilken plugin som helst på sekunder med `logic_mcu_plugin_parameters`. Biblioteksregistret byggs i stället (1) lazy: varje plugin som passerar ett svep eller används hamnar i registret, och (2) på begäran: ett framtida verktyg kan temp-ladda en namngiven plugin på ett scratch-spår, svepa den och ta bort den. Blind massinstansiering undviks medvetet (timmar av instansieringar, iLok-dialoger för tredjepartsplugins, AU-valideringsavbrott).

## Instrumentslottar via assign_instrument (2026-08-25, v0.16.0)

Instrumentläget (`assign_instrument`, assignment-kod `IN`) speglar plugin-läget: bankvy med instrumentnamn per kanal (`-- Trilan Q-Samp --`), vpot-tryck öppnar parameter-edit med samma sidbläddring. Samma browserfara: **vpot-vridning i IN-bankvyn är instrumentbrowsern** — verktygen vrider aldrig där. Kärnlogiken (sidsökning + konvergens) är utbruten och delas mellan plugin- och instrumentverktygen.

Nya verktyg: `logic_mcu_instrument_parameters` och `logic_mcu_set_instrument_parameter` (samma compare-and-set-kontrakt).

Verifierat:

- **Q-Sampler (808)**: 64 parametrar över 9 sidor (tuning, filter, amp, LFO:er, …); skrivning `FinTun 0 cent → +5 cent → 0 cent` (`confirmed`).
- **Trilian (Bas)** — tredjepartsinstrument med helt AX-opakt UI: **512 parametrar över 64 sidor** lästa (Spectrasonics automationstabell: 8 part-levels + assignerbara slottar). Praktisk notis: så stora tabeller tar ~2 min att läsa i sin helhet; skrivverktyget söker sidorna sekventiellt tills träff, så parametrar på tidiga sidor går snabbt.

Därmed är **varje slot-typ i Logic nåbar via dataplanet**: audio-FX-inserts, instrument, faders/pan/mute/solo, transport, lokatorer — plus öron via sensorn.

## Prestandaoptimering — händelsedrivet i stället för sova-och-hoppas (2026-08-25, v0.17.0)

Användarens fokusskifte: allt kändes trögt. Rotorsaken var tre lager av konservativa fasta väntetider. Åtgärder:

1. **Bridgen fick `status`- och `await`-kommandon**: status läses ur minnet via socketen (statusfilens 150 ms-throttle borta), och `await {since, timeout_ms}` blockerar i bridgen tills ny MIDI faktiskt anlänt från Logic. Uppmätt: tryck→svar på ~50 ms mot tidigare fasta 700–800 ms.
2. **Alla heta väntor händelsedrivna** (`waitFor`/`quiescentStatus` i MCP-lagret): tryck → vänta på Logics faktiska svar → verifiera. "Stabil display" definieras som 120–150 ms utan nya MIDI-händelser i stället för långa fasta marginaler.
3. **Bankkartecache** (`bank-cache.json`): findChannel matchar först mot aktuell bankvy (0 tryck), sedan mot cachad karta (direktnavigering + verifiering), och gör full omscanning bara vid miss — cachen invalideras och byggs om automatiskt.
4. **Parameternamn-cache** (`param-names-cache.json`): den stora vinsten. "Page x/y"-indikatorn tar ~1,3 s att tona bort per sida, men **värderaden är komplett omedelbart** — bara namnen döljs. Namn ändras aldrig per plugin-typ, så de cachas vid första (långsamma) läsningen; efterföljande läsningar hämtar bara färska värden utan fade-väntan. Valideras mot de alltid synliga fälten 0–5; layoutändring ger automatisk långsam omscanning. Gäller både läsning och parametersökning i skrivverktygen (nyckel: pluginnamn resp. `instrument:<namn>`).

Fallgrop som fixades på vägen: `await` returnerar på *första* eventet, men Page-indikatorn ritas i ett senare sysex — sidantalsläsningen väntar nu explicit på indikatorn (den kalla Q-Sampler-läsningen tappade annars 8 av 9 sidor; cachen självläkte men i onödan långsamt).

Uppmätta resultat (kall = första läsningen av en plugintyp, fyller cachen):

| Operation | Före | Efter (varm) |
|---|---:|---:|
| Pluginparametrar, 3 sidor (Compressor) | 9,9 s | **1,5 s** |
| Instrumentparametrar, 9 sidor (Q-Sampler) | ~21 s | **4,5 s** |
| Volymsättning (samma bank) | 9,5 s | **0,4 s** |
| Parameterskrivning (compare-and-set) | ~10 s | **1,5–1,9 s** |
| Play + stop (båda) | ~2 s + frontmost | **0,13 s** |

### evaluate_change på nya hastigheten (2026-08-25)

Första omkörningen avslöjade att `logic_evaluate_change` anropade transporten *internt* via AX-vägen (space + frontmost): stoppet nekades, åt ~10 s i retries och lämnade uppspelningen igång — ärligt rapporterat som `STILL_PLAYING_stop_failed` i restored-fältet, precis som designat. Efter patch (MCU-först även inuti `evaluateChange` och `setCycleRange`): **35,9 s totalt** (från 52,6 s), varav ~30 s är musikens eget golv (tre looppass à 8 s + settle). Städningen helt grön: `transport: stopped`, playhead återställd, cycle av, parameter återställd. Mätrepeterbarheten intakt (delta -1,15 dB, residual 0,02 dB). Vill man pressa mer: `settle_seconds` (default 2) kan sänkas per anrop.

## Offline-bounce + två-pass evaluate (2026-08-25, v0.18.0)

Två användarförslag implementerade:

**1. `logic_evaluate_change` kör två pass som standard** (A → ändring → B → rollback); kontrollfönstret är opt-in via `verify_rollback: true` (rollback-residualen har verifierats ≈ 0,0 dB upprepade gånger). Cykeln landar på ~25 s varav 20 är musik.

**2. `logic_bounce_range`** — offline-rendering av ett taktområde till fil, utan uppspelning och utan sensor. Verifierade fynd:

- Bounce-dialogen (`File > Bounce > Project or Section…`) är äkta AppKit: destinationskryssrutor, Mode (`Automatic` väljer offline), Normalize, Start/End. **Start/End-fältens sliders använder samma tick-skala som playhead-tummen** (16 492 674 416 640/takt; `min` = takt 1) men stegar en enhet per skrivning — konvergens med beräknat mål.
- **Spara-panelen hostas ibland i Logics eget fönster, ibland i AppKits XPC-process** (`openAndSavePanelService`) — verktyget letar på båda ställena via Bounce-knappen. Panelens filnamnsfält kan hävda att ett satt namn "fastnat" fast panelen sparar under standardnamnet; filen hittas därför även via skapelsetid och **flyttas till captures-katalogen under etikettnamnet**.
- En eventuell "finns redan"-Replace-dialog trycks bort automatiskt.
- Verktyget växlar destination till Uncompressed; **användarens tidigare destinationsval (MP3) återställs inte automatiskt** i nuvarande version — begränsning, dokumenterad här.
- Byteverifiering: 4 takter @ 120 BPM, 24-bit/44,1 stereo interleaved = 2 120 524 byte — exakt träff varje körning.

Uppmätt: **en bounce ~10 s** (varav offline-rendern är ~1–2 s; resten är dialogkoreografi), **komponerad A/B (param → bounce → param-återställning) 15,2 s totalt**. Ärlig jämförelse: för 4 takter är vinsten mot realtids-evaluate (~25 s) måttlig — men bounce skalar nästan inte med längden (16 takter kostar ungefär samma overhead, mot 2×32 s realtid) och ger fullkvalitativ 24-bitars masterrender utan hörbar uppspelning.

Känd härdningspunkt: parametersökningens första värdesavläsning kan råka läsa mitt i en LCD-omritning (observerad transient `before: Off` på en Ratio-återställning — konvergensen träffade ändå rätt eftersom den verifierar mot live-läsningar). Ursprungsvärdet bör läsas ur ett tystnadsverifierat läge.

### method:"bounce" + headless-utredningen (2026-08-25, v0.19.0)

**`logic_evaluate_change` har nu `method: "bounce"`**: två offline-renders runt en verifierad parameterändring, metrik beräknad direkt ur AIFF-filerna (egen 24-bit PCM-parser), rollback som standard. Uppmätt: **20,3 s för hela A/B-cykeln** (mot ~25 s realtid) — och bounce B tar bara ~4 s eftersom dialoginställningar och positioner persisterar. Korsvalidering: filmetrikens RMS-delta (-1,15/-1,13 dB) matchar realtidssensorns (-1,15/-1,14) på hundradelen — två oberoende mätvägar, samma svar.

**Headless-utredningens ärliga slutsats** (på användarens fråga om reverse-engineering):

- Logic Pro har **ingen headless renderyta**: AppleScript-ordboken innehåller noll bounce/export-kommandon (verifierat via sdef — bara Standard/Text/Print-sviter), inga App Intents/Shortcuts-actions i bundlen, ingen CLI.
- **Alla bounce-dialogens inställningar är dock `defaults`** (`BounceOffline`, `BounceFileType`, `BounceDestinationTypes`, `BounceBitSize` …) som läses när dialogen öppnas — dialogen kan alltså vara helt förkonfigurerad, och koreografin är nedbantad till **fyra verifierade AX-elementtryck** (meny → OK → Bounce → ev. Replace). Inga syntetiska tangenttryck eller musklick förekommer i bounce-vägen — endast elementadresserade Accessibility-anrop, samma API som skärmläsare.
- Kvarvarande legitima spår mot ännu mindre UI: **Freeze** (renderar spår offline till fil helt utan dialoger — per spår, inte master; kandidat för spårnivå-A/B) och `defaults write`-förkonfiguration. Kodinjektion/privata API:er i Logic är avsiktligt uteslutna (hardened runtime, och fel väg för ett verktyg som ska funka på folks datorer).

### Dialogfri spårrendering via Freeze + MIDI-key-commands (2026-08-25, v0.20.0)

**Genombrottet användaren bad om: `logic_render_track` exporterar ett spår till fil med NOLL dialoger, noll syntetiska tangenttryck, noll fönster.** Uppmätt: **5,9 s för 808** (121 s audio, 32-bit float AIFF, inklusive select, render, kopiering, unfreeze och RMS/peak-metrik).

Mekanismen:

1. **Bryggan fick en andra virtuell CoreMIDI-port, "Logic MCP Commands"**, plus socketkommandot `keycmd {note, channel}`. Porten är skild från MCU-porten så att key-command-assignments aldrig kolliderar med Mackie-protokollet.
2. **"Toggle Track Freeze" lärdes in i Key Commands-fönstret** (Learn New Assignment) på not 117, kanal 16, via den nya porten. Viktig läxa: not 1 krockade med en befintlig assignment i användarens key-command-set och gav en "already assigned"-modal som blockerade allt — MCU-timecoden visar då bokstavligen `ALERT`, vilket i sig är en användbar dataplanssignal för modaldetektering. Assignments sparas i `~/Library/Preferences/com.apple.logic.pro.cs` och överlever omstart.
3. **Freeze är Logics enda helt dialogfria offline-render**: toggla freeze på valt spår (MIDI-not) → tryck play (MCU) → Logic renderar spåret offline till `Media/Freeze Files/` (`FreezeInProgress.lock` medan det pågår) → kopiera ut filen → toggla freeze av (Logic raderar då freeze-filen — därför kopieras den först). Hela spåret renderas från projektstart med alla plugins och automation (Pre Fader-läge).
4. **Registerfil som samtyckesmodell**: `~/Library/Application Support/LogicMCPMCU/keycmd-registry.json` listar inlärda kommandon; `logic_trigger_key_command` vägrar notnummer som inte finns i registret, eftersom en okänd not kan vara bunden till vad som helst.

Verifierade fällor och deras hantering:

- **Track stacks kan inte frysas** — Logic visar en modal ("Freezing doesn't work", bekräftad av användaren). Verktyget vägrar stackar i förväg via AX-`is_stack`, detekterar `ALERT` i MCU-timecoden under väntan, och snabbfelar efter 10 s om ingen freeze-aktivitet syns (i stället för 180 s timeout medan Logic bara spelar).
- **Kopieringsrace**: `FreezeInProgress.lock` försvinner innan filen är färdigskriven — en naiv kopiering gav en 4 KB header-stub. Fix: vänta tills filstorleken täcker FORM-chunkens deklarerade storlek och varit stabil i tre kontroller.
- **Tomma renderingar**: ett spår utan regioner ger en giltig men tom AIFF (`LofPad`); rapporteras ärligt med `warning` i stället för metrics.
- **AIFF-parsern utökad till AIFC/fl32** (32-bit big-endian float, freeze-filernas format) utöver 16/24-bit PCM, så `metrics` (RMS/peak per kanal) beräknas direkt ur freeze-filen.

Kvarstående i denna väg: not 1 ligger kvar som dubblett-assignment på Toggle Track Freeze (dokumenterad i registret, används ej — kan städas manuellt i Key Commands-fönstret); bar-range-slicing av freeze-filen via tempomatematik; freeze-mode-valet (Source Only vs Pre Fader) exponeras inte ännu.

### Bar-range-slicing + spårnivå-A/B via render (2026-08-25, v0.21.0)

**`logic_evaluate_change` har nu `method: "render"`** — hela A/B-cykeln på spårnivå, helt dialogfri: två freeze-renders runt en verifierad MCU-parameterändring, jämförda på enbart det utslicade taktintervallet. Uppmätt: **15,5 s totalt** (två renders av 121 s audio + parameterändring + rollback + metrik). Verifierat med Compressor MakeUp 0→+6 dB på 808, takt 5–9: RMS-delta +4,85 dB, peak-delta +3,65 dB — exakt reproducerbart mot ett oberoende handexperiment.

Mekaniken:

- **Bar→sekunder**: tempo och taktart läses från control bar (`getTransport`), överstyras med `tempo`/`beats_per_bar`-argument. Freeze-filer börjar alltid vid projektstart (takt 1) så offset = (takt−1) × slag/takt × 60/BPM. Konstant tempo antas (tempospår följs inte ännu).
- **`sliceAudioFile`**: klipper intervallet ur AIFF/AIFC (16/24-bit PCM eller fl32) och skriver 32-bit float WAV (RIFF fmt 3) med egna RMS/peak-metrics i samma pass. `logic_render_track` tar nu `start_bar`/`end_bar` och returnerar `slice` med egen fil + metrik. Verifierat: takt 5–9 @ 120 BPM = exakt 352 800 frames (8,000 s).
- **`insert_slot`** (MCU-fysisk slot) identifierar pluginen i render-metoden — fungerar därmed för alla plugins inklusive tredjepart, till skillnad från realtime/bounce som behöver AX-fönstret.

Lärdomar under vägen:

- **Freeze inkluderar inserts** (Pre Fader-beteende bekräftat empiriskt: MakeUp +6 dB syntes som +4,85 dB RMS i freeze-filen — mellanskillnaden är kompressorns egen gain reduction på den högre nivån).
- **Delta ≈ 0 kan vara ett korrekt svar**: första testet (Thrs −20→−30) gav ±0,01 dB — inte ett fel utan Compressorns AutoGain (−12 dB-läget) som kompenserar tröskeländringen nästan exakt på jämnt 808-material. A/B-metoden avslöjade det direkt — precis den sortens insikt verktyget är till för.
- **Rollback kan faila transient direkt efter unfreeze** (Logic laddar om pluginkedjan): nu 3 försök med quiescence-väntan emellan; sista försöket släpper compare-and-set (det verifierade applied-värdet är färskt och återställningen viktigare än omkontrollen). Misslyckad rollback rapporteras ärligt som `decision: "rollback_failed", verified: false`.
- Spårhuvudenas freeze-checkboxar är AX-läsbara (`AXCheckBox` desc="Freeze") — datadriven väg att läsa freeze-STATUS utan att toggla.

### MIDI-komposition via inspelning (2026-08-25, v0.22.0)

**Kompositionsgapet mot konkurrenterna är täppt — utan deras filimport-dialoger.** `logic_record_midi` tar en notlista (tonhöjd som MIDI-nummer eller namn à la Logic där C3 = 60, takt/slag/längd/velocity/kanal) och får in den i projektet som en riktig inspelad region: noll dialoger, inga temporära filer, inga tangenttryck.

Mekanismen (helt i dataplanet):

1. **Bryggan fick en tredje virtuell port, "Logic MCP MIDI In"** — utan kontrollytroll och utan key-command-assignments behandlar Logic den som ett vanligt keyboard: noter ljuder genom valt instrument och spelas in. Nya socketkommandon: `midi_stream` (tidsstämplade händelser, asynkron uppspelning från egen tråd med `usleep`-pacing), `midi_abort` (avbryt + all-notes-off), `midi_streaming`-flagga i status.
2. **Inspelningsflödet**: välj spår (MCU-först) → playhead till starttakt−1 → MCU-record (LED-verifierad) → **synka på timecode-övergången in i förrullningstaktens sista slag** (exakt ett slag kvar till start, oberoende av count-in-inställning) → strömma noterna med slaget som försprång minus kalibrerad displaylatens (`sync_compensation_ms`, default 45 ms uppmätt) → stop → playhead återställd.
3. **Verifiering med bevis**: som default freeze-renderas de inspelade takterna direkt och slice-metriken returneras — icke-tysta RMS/peak bevisar att noterna landade OCH ljuder genom instrumentet. Kompositions→render→lyssna-loopen ingen konkurrent har.

Uppmätt: 6-noters basgång på `Bas` (Trilian, tredjepartsinstrument) komponerad, inspelad och render-verifierad på **16 s** (peak −4,24 dB).

**Kalibreringsläxan (viktig):** de första timing-mätningarna gjordes i taktintervall där *originallåtens material* spelade — onset-detekteringen mätte låten, inte våra noter (takt 52 gav "perfekta" 0,0 ms eftersom originalkicken låg exakt på slaget). Korrekt kalibrering kräver takter **bortom projektets slut** (eller ett tomt spår) och en referenstakt före mättakten i slicen. Rena mätningar på takt 70/74/78: kompensation 45 ms ger avvikelse −1,5 ms med **±8–10 ms jitter** mellan körningar (pollintervall + LCD-granularitet; pollen skärptes till 5 ms). Default `sync_compensation_ms = 45` är alltså verifierat rätt; jittern är metodens golv och Logics regionkvantisering (`Q`) snäpper resten. Basgången i takt 44 spelades in med den äldre taktlinjesynken (~50 ms sent) — markera noterna och tryck Q, eller radera och spela in om.

Begränsningar (ärliga): inspelningen tar realtid (takter × slag × 60/BPM sekunder) — ett framtida knep är att tillfälligt höja tempot och skala händelsetiderna; konstant tempo antas; `start_bar >= 2` krävs (ett förrullningstakt för synken); regionen läggs ovanpå ev. befintligt innehåll (ta bort med Undo i Logic).

### CoreMIDI-tidsstämplar + rullningsdetektering (2026-08-25, v0.23.0)

Användarens fråga "borde inte MIDI:n sättas på rätt ställe direkt via text, som konkurrenterna?" ledde till två fynd:

1. **Konkurrenterna spelar också in i realtid.** MongLongs egen dokumentation avslöjar `record_sequence` via CoreMIDI — ingen headless SMF-import existerar i Logic (deras regioner paddas dessutom från takt 1 och **måste skapa ett nytt spår**; vår spelar in på befintliga spår genom deras pluginkedjor). "Direkt via text" är en illusion; frågan är bara vems inspelningsväg som är exaktast.
2. **Precisionen i "via text" går dock att få**: `midi_stream` skickar nu varje paket ~80 ms i förväg med **explicit CoreMIDI-tidsstämpel** (mach host time) — Logics inspelningsmotor placerar händelsen på stämpelns tid, inte ankomsttiden, så bryggans pacing-jitter når aldrig de inspelade positionerna.

Vägen dit fångade en riktig synkbugg: en testinspelning landade **exakt en takt tidigt** eftersom `setPlayhead` bara konvergerar *takten* — den parkerade displayen kan stå kvar på "beat 4" från ett tidigare stopp, och beat-edge-villkoret matchade innan transporten rullade. Fix: ingen kant accepteras förrän timecoden bevisligen ÄNDRATS (transporten rullar). Buggen är en bra påminnelse: lita aldrig på ett positionsfält som kan vara delvis staldat.

Uppmätta rena körningar efter fixen (takt 94/98/102/106, bortom låtslutet): **medel +2,5 ms, spridning 10,9 ms, ingen utstickare** — under mänsklig timing-varians, och kvantisering snäpper resten.

### Sends via MCU (2026-08-25, v0.24.0)

**`logic_mcu_sends` + `logic_mcu_set_send`** — luckan som konkurrenten uttryckligen gav upp på ("set_send is not exposed", MongLong) är stängd, med samma dataplansdisciplin som pluginparametrarna.

Empiriskt kartlagd yta: `assign_send` cyklar mellan **S1** (multi-kanal: EN send-parameter över alla kanaler — vpotarna står på *Destination* där, livsfarligt att vrida, används aldrig) och **SE** (kanalvy: valda spårets alla sends). SE-layouten är 4 fält per send, 2 sends per LCD-sida: `SenNIn` (destination, t.ex. "Bus 2"), `Send N` (nivå i dB), `SenNPo` (position, "PosPan"), `SenNMu` (status, "active"). Cursor 0x62/0x63 bläddrar sidor — **utan** "Page x/y"-indikator, så sends har egen navigering (fast sidgeometri i stället för indikatorparsning).

Skrivningen konvergerar ENDAST nivå-vpoten (fältnamnet "Send N" verifieras innan någon vridning; oväntad layout ⇒ vägran), med compare-and-set/LCD-readback. Verifierat på `Lofi Pad` send 1 → Bus 2: läs (2,0 s), skriv −9,0→−6,1 dB (1,5 s, vpot-granulariteten ger ±0,1 dB), och **compare-and-set-vägran fungerade skarpt** när fel förväntat värde angavs ("Expected -6.0, found -6,1dB. No write was attempted."), följt av exakt återställning till −9,0 dB.

Notera: verktygen tar AX-spårnamn ("Lofi Pad"), inte MCU:ns trunkerade ("LofPad") — samma konvention som pluginverktygen.

### Batch-inlärda key commands + freeze-tillståndsläsning (2026-08-25, v0.25.0)

**Fem key commands batch-inlärda** på Commands-porten via den skriptade learn-proceduren (öppna fönstret en gång, sök→markera→arma→skicka not per rad, verifiera "Note N" i raden, stäng): Undo=100, Redo=101, **Flashback Capture as Recording**=102 (Logic 12:s namn — inte "Capture as Recording"), Split Regions/Events at Playhead Position=103, Create Marker=104. Alla verifierade i Key Commands-fönstret; registerfilen uppdaterad. Undo funktionsverifierad: inspelad not på takt 64 (peak −5,7) → `logic_trigger_key_command {name:"Undo"}` → notlagret borta i ny render. **Disciplin: Undo avfyras bara direkt efter en känd edit** — menyraden visar bara "Undo" utan operationsnamn, så ett blint tryck kan ångra fel sak.

**Kaskadincidenten och tre härdningar den köpte:** ett probe-skript dog mellan play och stop → transporten rullade obemärkt i minuter → freeze-toggles och record-tryck sväljdes/köades, dialoger dök upp osynligt, och tomma render-cykler lämnade **Bas och 808 frusna** (användarens skärmdump av unfreeze-dialogen knäckte fallet). Fixar i `renderSelectedTrack`:

1. **Stoppa transporten först** (rullande transport köar freeze-dialoger osynligt), plus **dubbelt stop-tryck**: play gör INGENTING när playheaden står vid/bortom projektslutet, och stop-när-stoppad hoppar till projektstart — ren MCU-mekanik som gör rendern positionssäker.
2. **Freeze-tillstånd LÄSES nu innan toggling**: `trackFreezeState` (spårhuvudets AX-checkbox, desc="Freeze" — läsbar men AXPress-död) + `answerFreezeDialog` (svarar Logics "Track is frozen. Unfreeze?"-bekräftelse). `ensureUnfrozen` tinar ett redan-fruset spår innan rendern; sluttiningen dubbelkollas mot checkboxen; fast-fail-vägen togglar bara tillbaka om spåret faktiskt visar fruset (blind åter-toggling frös tidigare ett aldrig-fruset spår).

Verifierat slutresultat: render av en FRUSEN Bas → självtining via dialogsvar → render → slice (peak −4,67) → upptining, 12,8 s totalt.

Kvarlämnat skräp: 1–2 test-A0-noter kan ligga kvar på Bas takt 64 (radera manuellt; regionläsning via AX är nästa verktyg och hade löst inventeringen).

### Produktifiering enligt MCP-praxis (2026-08-25, v0.26.0)

Efter användarens fråga "går batch-inlärningen att dela?" — nej, assignments är per användare/maskin (`com.apple.logic.pro.cs`), men proceduren är kod. Serverns onboarding följer nu MCP-ekosystemets praxis:

1. **Bridgen autostartas** (`MCUBridge.ensureRunning` vid serverstart + i health): servern förvaltar sin egen sidoprocess i stället för att kräva manuell daemon-start; letar upp `logic-mcu-bridge` bredvid sin egen binär. Verifierat: dödad bridge → serverstart → bridge uppe.
2. **Key command-inlärningen bor i servern** (`setupKeyCommands` i LogicAccessibility, hela AX-flödet inkl. kollisionshantering med alternativa noter +20/+40 och "already assigned"-Cancel). Exponerad som `logic_setup_key_commands` (idempotent: redan-inlärda rader verifieras och hoppas över) — och körs **lazy automatiskt**: `resolveKeyCommand` lär in en saknad standardkommando första gången ett verktyg behöver den. Verifierat: Redo raderad ur registret → `trigger Redo` → auto-inlärning (fann befintlig Note 101 i prefs, "already_learned") → avfyrad, 2,9 s.
3. **`logic_health` är nu doctor**: accessibility (med deep-link-fix), Logic igång, projekt öppet, bridge (autostartas), MCU-anslutning (received_events), key command-status per kommando, sensor som VALFRI. Varje brist får en fix-instruktion i klartext — felmeddelanden som onboarding.
4. **`instructions`-fältet** i initialize beskriver förkrav, att health ska köras först, compare-and-set-disciplinen och v1-antagandet engelskt Logic-UI.
5. **Sensorn nedgraderad till valfritt tillägg** (beslut: bounce/freeze täcker A/B-behovet; sensorn är enda realtidslyssningen men krävs inte) — verktygsbeskrivningarna markerade, health rapporterar den som optional.

Kvarstående delbarhetsskuld (kända, ej blockerande): lokaliserade AX-strängar genom stacken (engelskt Logic-UI krävs i v1); MCU-konfigurationen i Logic är manuell engångssetup (guidad via health-fix); paketering till en distribuerbar artefakt (server + bridge i samma bundle) återstår.

### Nästa steg
- Paketering: en distribuerbar artefakt (server + bridge), npx/brew-stil.
- Regionläsning via AX (lägesmedvetenhet: vad ligger var i arrangemanget — hade löst både takt-64-inventeringen och tomspårsdetektering).
- `logic_record_midi` bör återanvända ensureUnfrozen/stop-disciplinen (record sväljs på frusna spår).
- Tempo-trick för snabbare inspelning (höj tempo N×, skala händelser, återställ).
- Läs freeze-status via spårhuvudets checkbox innan `logic_render_track` (skiljer "redan frusen" från "inget innehåll").
- Tempospårsföljning i bar-matematiken (läs tempoförändringar, styckvis integration).
- Härda parametersökningens ursprungsläsning (tystnadskrav före `before`-värdet).
- `logic_get_transport` bör läsa MCU-spegeln som primärkälla (LED + tidsdisplay) med AX som fallback.
- launchd-tjänst för logic-mcu-bridge; pan via MCU.
- Scratch-scan-verktyg för bibliotekplugins på begäran.
- Kalibrerade mätvärden (K-vägd loudness/LUFS) i sensorn; agentloop med lyssningsbeslut.
- Ytterligare fart: flytta konvergensloopar in i bridgen (eliminerar socket-rundresor per tick); förvärm cachar med ett bakgrundssvep.

## Är Hjälpmedel rätt kontrollväg?

### Bedömning

**Ja, som en viktig del av lösningen — men inte som hela lösningen.**

macOS Accessibility (`AXUIElement`) är ett offentligt Apple-API som uttryckligen kan läsa UI-element, kontrollera om attribut är skrivbara, sätta attribut och utföra semantiska actions. Det är därför tekniskt mycket rimligare än koordinatbaserade musklick eller bildigenkänning. För Logic-parametrar som saknar ett dokumenterat externt API är det sannolikt den snabbaste praktiska vägen till en fungerande produkt.

Accessibility är däremot inte ett officiellt, versionsbundet Logic-automations-API. Element kan saknas tills ett fönster har öppnats, ett plugin kan exponera bristfällig semantik och struktur, identifierare eller hjälptexter kan ändras mellan Logic-, plugin- och språkversioner. API:t kan också returnera fel om målappen är upptagen eller UI-elementet har blivit ogiltigt. Därför bör AX inte ensam behandlas som en stabil kontraktsyta.

### Rekommenderad god praxis

Använd en hybridarkitektur och välj den mest stabila kontrollvägen per operation:

1. **Logic Control Surface/MCU eller MIDI Controller Assignments** för transport, mixer, bankning, parameterfeedback och pluginparametrar som kan adresseras stabilt där. Apple dokumenterar dubbelriktad parameterkontroll och feedback för kontroll­ytor.
2. **Accessibility** för semantisk UI-inventering och kontroller som inte nås på annat sätt, särskilt Apples egna pluginfönster.
3. **AppleScript och Logic-kommandon** för de begränsade meny-, fönster- och kommandooperationer som de hanterar väl.
4. **Audioanalys och exporter** som en separat återkopplingskanal; ett lyckat UI-write bevisar inte i sig att mixresultatet blev bra.
5. **Direkt `ProjectData`-skrivning** bör undvikas så länge formatet är proprietärt och odokumenterat.

När Accessibility används i produktion bör implementationen:

- använda roller, namn, hjälptext och relationer i stället för skärmkoordinater;
- kräva uttryckligt användartillstånd och förklara varför Hjälpmedel behövs;
- identifiera projekt, spår, insert, plugin och parameter före varje write;
- använda compare-and-set, readback och rollback som i demon;
- vägra skriva vid tvetydig matchning eller oväntat nuvärde;
- versions- och språkstesta stödda Logic- och pluginversioner;
- undvika batchändringar under inspelning eller andra tidskritiska lägen;
- logga vilken kontrollväg som användes och hur resultatet verifierades.

Slutsatsen är att Accessibility här kan anses vara god praxis **som en defensivt implementerad fallback och pluginadapter**. Det vore däremot inte god praxis att bygga hela produkten som en serie blinda UI-klick och anta att ett lyckat anrop betyder att rätt ljudparameter ändrades.

## Bekräftad `.logicx`-information

Ett `.logicx`-projekt är ett macOS-paket, inte en enda platt fil. Det undersökta paketet var cirka 102 MB och innehöll bland annat:

```text
Resources/ProjectInformation.plist
Alternatives/000/ProjectData
Alternatives/000/MetaData.plist
Alternatives/000/DisplayState.plist
Alternatives/000/DisplayStateArchive
Alternatives/000/WindowImage.jpg
Alternatives/000/Project File Backups/
Alternatives/000/Autosave/
Media/Audio Files/
Media/Samples/Quick Sampler/
```

Läsbar metadata för det undersökta projektet:

- 27 spår
- 120 BPM
- 4/4
- B♭-dur
- 44,1 kHz
- 5 använda ljudfilsreferenser
- 2 ljudfiler markerade som oanvända
- 10 inbäddade Quick Sampler-samples
- 7 Space Designer-impulssvar
- Flera tidigare projektbackuper

Projektets vanliga `ProjectData` och metadata sparades senast 2021-01-03 från Logic Pro X 10.6.0. Projektet öppnades under undersökningen i Logic Pro 12.3.1 och hade en aktuell autosave från 2026-08-24. Alla framtida skrivtester bör därför utföras på en kopia för att undvika oavsiktlig formatmigrering.

### Vad som kan läsas direkt

Direkt från projektpaketet kan vi läsa eller härleda:

- Projektnamn och Logic-version från senaste vanliga sparning
- Tempo, tonart, taktart och samplingsfrekvens
- Antal spår
- Referenser till använda och oanvända ljudfiler
- Quick Sampler-samples
- Impulssvar
- Backuper och autosaves
- Fönster- och visningsläge
- En statisk bild av senaste sparade Logic-fönster
- Fullständig signaldata för inbäddade WAV- och AIFF-filer
- Många spår-, preset- och pluginnamn som textfragment i `ProjectData`

Exempel på identifierade spårnamn:

- `Lofi Pad`
- `Bas`
- `808`
- `Inst 2`
- `Drums 'n' shit`
- `Vocals`
- `Ivan Vocals`
- `Ivan Effect`
- `Acke Vocals`
- `Sweeps`
- `Crash bullshit`
- `Vinyl Shit`

Exempel på identifierade plugin- och presetnamn:

- `Channel EQ`
- `DeEsser 2`
- `Compressor`
- `Tape Delay`
- `Space Designer`
- `Vintage Vocal`
- `Male Vox 01`
- `Compressed Vocal`

### Begränsning: `ProjectData`

Den huvudsakliga sessionsstrukturen finns i `Alternatives/000/ProjectData`, ett proprietärt binärformat. Där måste bland annat regioner, MIDI, automation, routing, insertkopplingar och pluginstate finnas, men formatet är inte dokumenterat som ett stabilt externt API.

För vanliga Audio Units dokumenterar Apple egenskapen `AUAudioUnit.fullState`, som en värdapplikation kan använda för att spara och återställa pluginets parametrar och egenskaper. I ett Logic-projekt kan motsvarande state ligga inbäddat som ett ogenomskinligt pluginblock snarare än en enkel lista som `threshold = -20`.

Direkt skrivning till `ProjectData` bör inte användas i första implementationen eftersom:

- Kopplingen mellan spår, insert-slot och stateblock inte är dokumenterad.
- Pluginstate kan vara leverantörsspecifikt och binärt.
- Parameter-ID och serialisering kan ändras mellan versioner.
- Logic kan ha interna integritetskontroller eller migrationslogik.
- En felaktig byte kan korrumpera hela projektet.
- Filen får inte konkurrensskrivas medan Logic har projektet öppet.

Använd `ProjectData` för forskning och read-only-inspektion, inte som primär skrivväg.

## Verifierat Accessibility-fynd

Efter att Accessibility-behörighet beviljats kunde Logic-fönstren läsas genom både System Events och det lägre macOS-API:t `AXUIElement`.

Identifierade fönster:

```text
Acke Vocals
CS Smällare - Tracks
```

Compressor-fönstret exponerade riktiga kontroller, inte bara en bildyta. För huvudreglagen gick följande att läsa:

- `AXRole = AXSlider`
- Semantisk hjälptext med parameternamn och funktion
- `AXValue`
- `AXMinValue`
- `AXMaxValue`
- Intern `AXIdentifier`
- Stödda actions: `AXIncrement` och `AXDecrement`
- `AXValue` var settable enligt `AXUIElementIsAttributeSettable`

### Verifierade skrivbara Compressor-reglage

| Parameter | AX identifier | Råvärde | Minimum | Maximum | Skrivbar |
|---|---:|---:|---:|---:|---|
| Mix | `_NS:216` | 200 | 0 | 200 | Ja |
| Distortion | `_NS:219` | 2 | 0 | 3 | Ja |
| Limiter Threshold | `_NS:222` | 100 | 0 | 100 | Ja |
| Output Gain | `_NS:265` | 60 | 0 | 120 | Ja |
| Knee | `_NS:172` | 7 | 0 | 10 | Ja |
| Release | `_NS:169` | 37 | 0 | 119 | Ja |
| Input Gain | `_NS:166` | 60 | 0 | 120 | Ja |
| Attack | `_NS:163` | 39 | 0 | 100 | Ja |
| Make Up | `_NS:160` | 44 | 0 | 110 | Ja |
| Ratio | `_NS:157` | 36 | 0 | 85 | Ja |
| Threshold | `_NS:153` | 60 | 0 | 100 | Ja |

Observera att `_NS:*` ser ut som interna AppKit-identifierare och inte bör antas vara stabila mellan Logic-versioner. Matchning bör primärt göras med semantisk hjälptext, roll, pluginidentitet och strukturell position. Identifieraren kan användas som ytterligare bevis, inte som ensam identitet.

### Verifierad semantisk hjälptext

Accessibility-trädet gav fullständiga engelska beskrivningar, till exempel:

```text
Threshold knob and field. Set the threshold level—signals above this threshold value are reduced in level.

Attack knob and field. Set the time it takes for Compressor to react when the signal exceeds the threshold.

Release knob and field. Set the time it takes for Compressor to stop reducing the signal after the signal level falls below the threshold.
```

Detta innebär att en generell inventerare kan identifiera parametrar semantiskt utan hårdkodade pixelkoordinater.

### Verifierade knappar och menyer

Följande kontroller exponerades med `AXPress` eller `AXShowMenu`:

- Plugin bypass
- Compare
- Copy och Paste
- Undo och Redo
- Föregående och nästa preset
- Presetmeny: `Vintage Vocal`
- Sidechain-meny: `Internal`
- Limiter On/Off
- Auto Gain: Off, 0 dB, -12 dB
- Auto Release
- Side Chain- och Output-vyer
- Platinum Digital
- Studio VCA
- Studio FET
- Classic VCA
- Vintage VCA
- Vintage FET
- Vintage Opto
- Meter- och Graph-vyer

Knapparna hade också semantisk hjälptext. Exempelvis beskrev `Vintage FET` kontrollens kompressorkaraktär, och sidechain-menyn beskrev dess funktion.

### Värdemappning

`AXValue` använder interna eller normaliserade skalor, inte alltid den enhet användaren ser. `AXValueDescription` returnerade i testet främst procentandelar:

```text
Mix: raw 200 -> 100 %
Distortion: raw 2 -> 67 %
Output Gain: raw 60 -> 50 %
Knee: raw 7 -> 70 %
Release: raw 37 -> 31 %
Attack: raw 39 -> 39 %
Threshold: raw 60 -> 60 %
```

Samtidigt visade det dynamiska textfältet för Threshold `-20.0 dB`. En produktionsimplementation behöver därför en verifierad mappning:

```text
råvärde <-> visat musikaliskt värde och enhet
```

Möjliga källor för mappningen:

1. Läs pluginets dynamiska värdefält genom Accessibility.
2. Använd kontroll­yteprotokollets formaterade parameterfeedback.
3. Kalibrera parameterkurvan automatiskt på en projektkopia.
4. Underhåll testade parameterscheman för Apples stock-plugins.
5. Använd Audio Unit parameter metadata där den är åtkomlig.

## Rekommenderad arkitektur

```text
AI-klient
   |
   | MCP tools/resources
   v
Logic MCP-server
   |-- Project package reader       (read-only metadata/assets)
   |-- Accessibility adapter        (plugin UI/state)
   |-- Control surface adapter      (MCU/C4/plugin parameter banks)
   |-- CoreMIDI adapter             (MIDI/control surface transport)
   |-- Logic lifecycle adapter      (open/save/bounce)
   |-- Audio analysis adapter       (local deterministic DSP)
   |-- Snapshot and rollback layer  (safety)
   `-- Verification layer           (confirmed/uncertain/failed)
```

### Modelloberoende principer

- Kärnan får inte importera Gemini-, OpenAI- eller Anthropic-SDK:n.
- Tools och resources ska använda standardiserad JSON.
- Lokal signalanalys ska vara deterministisk.
- En direkt ljudbedömningsmodell ska vara ett valfritt externt eller utbytbart lager.
- Alla mutationer ska vara begränsade och verifierade.
- Servern ska rapportera `confirmed`, `uncertain` eller `failed`; aldrig anta att en UI-action lyckades.
- Modellens konstnärliga beslut ska hållas separerade från MCP-serverns tekniska exekvering.

## Live AI Mix Assistant — AU som öron åt MCP

Den rekommenderade produktidén är inte en LLM som försöker behandla varje ljudbuffer eller direkt agerar som compressor. Systemet bör vara flerskiktat: deterministisk DSP arbetar i realtid, MCP fungerar som kontrollplan och en valfri LLM är en långsammare musikalisk supervisor.

En första användbar version kräver därför inte en stor specialtränad ljudmodell. En egen transparent Audio Unit kan fungera som ett billigt realtidsinstrument som omvandlar ljudströmmen till kompakta och musikaliskt relevanta mätvärden. En vanlig modell kan sedan resonera över dessa mätvärden, användarens intention och förändringar före/efter en parameterwrite.

### Föreslaget dataflöde

```text
Logic-spår, buss eller master
        |
        | ljudbuffer
        v
AI Sensor Audio Unit
        |
        | kompakta feature frames, exempelvis 10–20 Hz
        v
Lokal telemetry-tjänst
        |
        | senaste state + tidsfönster + händelser
        v
Logic MCP-server
        |
        | resources, tools och uppdateringsnotiser
        v
LLM / mixagent
        |
        | begränsat parameterbeslut
        v
MCP -> MCU / MIDI / Accessibility -> Logic
        |
        `---------------- AU mäter resultatet igen
```

AU:n är i första hand en **sensor**, inte en universell fjärrkontroll för andra plugins. Den befintliga MCP-servern och dess kontrolladaptrar sköter själva mutationen i Logic. Om vi senare bygger egen adaptiv DSP kan även den ligga i AU:n och regleras sample- eller blocknära utan en LLM i loopen.

### Mätvärden utan tränad modell

Följande kan beräknas lokalt med klassisk DSP, exempelvis Accelerate/vDSP:

- peak, true peak, RMS och momentary/short-term loudness;
- crest factor och dynamiskt omfång;
- spektral energi i fasta eller perceptuella frekvensband;
- spectral centroid och tonal lutning;
- transienttäthet och transientstyrka;
- stereobredd och korrelation;
- enkla mått för lågmid, presence och sibilans;
- transportläge, tempo, taktart, beatposition och tidsstämpel där Logic exponerar detta.

Masking och balans räknas lämpligen i telemetry-tjänsten genom att jämföra flera sensorinstanser, inte av en ensam AU-instans. Mer avancerade embeddings eller specialiserade ljudmodeller kan läggas till senare som utbytbara analysmoduler, men behövs inte för att bevisa closed-loop-idén.

### Realtidssäkerhet

Audio Units render callback körs i en realtidskontext och får aldrig vänta på MCP, en modell, nätverk eller UI. Implementationen ska därför:

1. förallokera alla buffertar;
2. undvika lås, fil-I/O, nätverk, JSON, loggning och dynamisk minnesallokering i renderloopen;
3. skriva minimala feature frames till en låsfri ringbuffer;
4. låta en separat worker-tråd aggregera och skicka telemetry via exempelvis delat minne eller en lokal socket;
5. jämna och schemalägga parameterändringar så att de inte orsakar zipper noise eller instabil reglering.

### Flera tidsskalor

| Lager | Typisk tidsskala | Ansvar |
|---|---:|---|
| Audio DSP | Varje buffer, cirka 1–10 ms | Kompression, limiter, filter och signalbehandling |
| Lokal regulator | Cirka 20–100 Hz | Gain riding, clip protection, smoothing och enkla tröskelregler |
| Telemetry/analys | Cirka 2–20 Hz | Featurefönster, kanaljämförelse, masking och händelsedetektion |
| LLM/mixagent | Cirka 0,5–5 sekunder eller på händelse | Intention, musikalisk kontext, strategi och förklaringar |

LLM-loopen blir därmed nära realtid ur producentens perspektiv, men är inte del av den hårda ljudrealtiden. Snabba skydds- och kontrollfunktioner måste alltid fungera lokalt även om modellen är långsam eller otillgänglig.

### Föreslagna MCP-resurser och verktyg

```text
logic://live/master
logic://live/tracks/{sensor_id}
logic://history/{sensor_id}/last-30-seconds
logic://events/latest
logic://evaluation/latest-change
```

MCP stödjer prenumeration på resources och `notifications/resources/updated`. En uppdateringsnotis innebär dock inte automatiskt att en modell körs; MCP-klienten eller vår companion-app behöver en agentloop som bestämmer när modellen ska väckas.

Lämpliga triggers är:

- ny låtsektion eller tydlig förändring i arrangemanget;
- clipping eller ihållande nivåöverträdelse;
- masking över en tröskel under en bestämd tid;
- en verifierad parameterändring som behöver utvärderas;
- ett tidsintervall, exempelvis var femte sekund;
- en uttrycklig fråga från användaren.

Föreslagna nya tools:

```text
logic_audio.get_live_snapshot
logic_audio.get_feature_window
logic_audio.compare_windows
logic_audio.mark_baseline
logic_audio.evaluate_latest_change
logic_mix.apply_bounded_change
logic_mix.keep_or_rollback_change
```

### Closed-loop-kontrakt

En säker parameterloop bör vara:

1. Mät en baseline under ett definierat musikaliskt tidsfönster.
2. Sammanfatta mätvärden och aktuell Logic-state.
3. Låt agenten föreslå exakt en begränsad förändring.
4. Applicera den genom befintlig compare-and-set och verifierad readback.
5. Mät ett jämförbart tidsfönster efter förändringen.
6. Returnera både objektiva skillnader och osäkerheter.
7. Välj `keep`, `adjust_again` eller `rollback`.
8. Kräv mänskligt godkännande för större eller flera samtidiga förändringar.

Exempel på utvärderingsresultat:

```json
{
  "change": "Vocal Compressor Ratio 4.2:1 -> 3.1:1",
  "before": {
    "crest_db": 7.1,
    "short_term_lufs": -18.0
  },
  "after": {
    "crest_db": 8.4,
    "short_term_lufs": -18.2
  },
  "measurement_confidence": 0.88,
  "available_decisions": ["keep", "adjust_again", "rollback"]
}
```

Objektiv förbättring av ett mätvärde är inte automatiskt musikalisk förbättring. Agenten måste väga mätningen mot användarens mål, sektionens roll och eventuell referens, och systemet ska alltid kunna återställa förändringen.

### Första AU/MCP-demo

Första rimliga implementationen använder tre transparenta sensorinstanser:

- `lead_vocal` på `Acke Vocals`;
- `music_bus` på relevant instrumental- eller musikbuss;
- `master` på Stereo Out.

Varje instans får stabilt UUID och användarbekräftad semantisk roll. En AU hör bara signalen vid sin egen insertpunkt; en mastersensor kan inte pålitligt separera sång, gitarr och trummor. Fler spår kräver fler sensorer eller särskilda analysbussar.

Demons acceptanskriterium är:

> Sensorerna levererar live-features till MCP, agenten tar en baseline, ändrar en enda Compressor-parameter genom den verifierade Logic-kontrollen, mäter ett jämförbart efterfönster och kan behålla eller återställa förändringen.

## Föreslaget MCP-API

### Läsverktyg

```text
logic_project.inspect_package
logic_project.get_state
logic_tracks.list
logic_plugins.get_inventory
logic_plugins.inspect_open_window
logic_plugins.list_accessible_parameters
logic_audio.analyze_file
logic_audio.compare_files
```

### Skrivverktyg

```text
logic_project.create_snapshot
logic_project.restore_snapshot
logic_plugins.set_parameter_verified
logic_plugins.press_control_verified
logic_tracks.set_volume_verified
logic_tracks.set_pan_verified
logic_project.bounce_preview
```

### Exempel: parameterinventering

```json
{
  "project": "/path/to/project.logicx",
  "track": "Acke Vocals",
  "insert": 3,
  "plugin": "Compressor",
  "parameters": [
    {
      "name": "Threshold",
      "ax_identifier": "_NS:153",
      "raw_value": 60,
      "raw_min": 0,
      "raw_max": 100,
      "formatted_value": "-20.0 dB",
      "writable": true,
      "evidence": ["ax_help", "ax_value", "ax_settable"]
    }
  ]
}
```

### Exempel: verifierad skrivning

```json
{
  "project_expected_path": "/path/to/project.logicx",
  "track_expected_name": "Acke Vocals",
  "insert": 3,
  "plugin_expected_name": "Compressor",
  "parameter": "Threshold",
  "target_value": -24.0,
  "unit": "dB",
  "expected_current_value": -20.0,
  "snapshot_required": true
}
```

Ett lyckat svar måste innehålla både skrivbevis och oberoende readback:

```json
{
  "success": true,
  "verified": true,
  "state": "confirmed",
  "before": "-20.0 dB",
  "requested": "-24.0 dB",
  "after": "-24.0 dB",
  "write_route": "accessibility",
  "readback_route": "accessibility",
  "snapshot_id": "..."
}
```

## Säkerhetskrav

Innan MCP:n får skriva till Logic:

1. Verifiera exakt projekt genom normaliserad absolut sökväg.
2. Verifiera spåridentitet, inte bara spårindex.
3. Verifiera fysisk insert-slot och pluginidentitet.
4. Läs aktuellt värde och jämför med `expected_current_value`.
5. Skapa snapshot eller arbeta på en projektkopia.
6. Begränsa värdet till pluginets verifierade intervall.
7. Utför exakt en mutation.
8. Läs tillbaka värdet genom en oberoende eller tydligt märkt väg.
9. Återställ vid mismatch när detta kan göras säkert.
10. Logga mutation, bevis, versioner och resultat.

Undvik:

- Koordinatbaserade klick som primär metod
- Direkta writes till `ProjectData`
- Mutation av ett spår identifierat enbart med ett föränderligt index
- Antagandet att ett lyckat API-anrop betyder att Logic ändrades
- Godtyckliga tredjepartspluginwrites utan parameterschema och readback

## Rekommenderad proof of concept

### Fas 0 — read-only inspector

- Starta lokal Swift MCP-server.
- Hitta Logic via bundle identifier.
- Lista Logic-fönster.
- Identifiera öppet pluginfönster.
- Returnera alla semantiska kontroller, värden, intervall, actions och settable-status.
- Inga writes.

### Fas 1 — ett verifierat Compressor-reglage

- Duplicera testprojektet.
- Öppna Compressor på ett känt spår och insert.
- Läs Threshold.
- Skapa snapshot.
- Sätt ett försiktigt testvärde genom `AXValue`.
- Läs tillbaka.
- Återställ ursprungsvärdet.
- Verifiera att återställningen lyckades.

### Fas 2 — Compressor-schema

- Kartlägg råvärde till dB, ms, ratio och procent.
- Stöd alla elva verifierade reglage.
- Stöd modeller, bypass, limiter, auto gain och auto release.
- Lägg till parameterkontrakt och toleranser.

### Fas 3 — fler stock-plugins

Inventera på samma sätt:

- Channel EQ
- DeEsser 2
- Tape Delay
- Space Designer
- Limiter
- Gain
- Multipressor

Klassificera varje kontroll som:

```text
read_write_verified
read_only
write_unverified
not_exposed
ambiguous
```

### Fas 4 — live AU-telemetry och audio-feedback-loop

- Bygg en transparent Audio Unit-sensor med realtidssäker feature extraction.
- Koppla sensorernas worker-trådar till en lokal telemetry-tjänst.
- Exponera live snapshots, tidsfönster och events som MCP-resurser.
- Börja med sensorer på lead vocal, music bus och master.
- Mät en baseline, applicera exakt en verifierad förändring och mät efterfönstret.
- Stöd `keep`, `adjust_again` och `rollback`.
- Komplettera med exporterade previews och stems för långsammare A/B-bedömning.
- Kräv mänskligt godkännande före större eller flera samtidiga förändringar.

## Viktiga öppna frågor

- Är `AXIdentifier` stabilt inom samma Logic-version och mellan sessioner?
- Hur beter sig hjälptext och kontrollstruktur i andra UI-språk?
- Kan det formaterade värdet läsas utan hover/fokus?
- Kan alla Compressorvärden sättas atomiskt genom `AXValue`?
- Uppdateras UI och audiomotor synkront efter ett AX-write?
- Kan readback ske via MCU för att vara oberoende av AX-writevägen?
- Hur exponerar Channel EQ sina band och noder?
- Vilka tredjepartsplugins exponerar användbara AX-kontroller?
- Hur hanteras pluginfönster som är stängda eller bakom andra fönster?
- Kan kontroll­yteprotokollet enumerera kompletta parameterbanker med formaterade värden?
- Vilka writes kan återställas säkert med Logic Undo och vilka kräver snapshot?

## Befintligt open-source-projekt

Det finns redan en aktiv Logic MCP-server som bör utvärderas före ett bygge från grunden:

- Repository: <https://github.com/MongLong0214/logic-pro-mcp>
- API-dokumentation: <https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/API.md>

Den använder flera kontrollkanaler: MCU, Accessibility, AppleScript, CoreMIDI, CGEvent, Scripter och MIDI Key Commands. Den har en säkerhetsmodell med bekräftat, osäkert och misslyckat resultat.

Vid den verifierade undersökningen stödde dess publika API endast verifierad skrivning av Compressor `threshold`; godtyckliga pluginparametrar avvisades. Accessibility-fynden ovan visar att denna yta sannolikt kan utökas betydligt.

## Primära referenser

- MCP server primitives: <https://modelcontextprotocol.io/specification/2025-06-18/server/index>
- Apple `AXUIElement`: <https://developer.apple.com/documentation/applicationservices/axuielement_h>
- Apple Logic control surfaces overview: <https://support.apple.com/guide/logicpro-css/control-surfaces-overview-ctls036b3e21/mac>
- Logic send and plugin parameters: <https://support.apple.com/guide/logicpro/control-surface-group-send-plug-parameters-ctls718de493/12.3/mac/15.6>
- Logic controller assignments: <https://support.apple.com/en-ie/guide/logicpro/ctls71c31487/10.7/mac/11.0>
- Apple `AUAudioUnit.fullState`: <https://developer.apple.com/documentation/audiotoolbox/auaudiounit/fullstate>
- Apple `AUAudioUnit.renderBlock`: <https://developer.apple.com/documentation/audiotoolbox/auaudiounit/renderblock>
- Apple Accelerate `vDSP.FFT`: <https://developer.apple.com/documentation/accelerate/vdsp/fft>
- MCP resource subscriptions: <https://modelcontextprotocol.io/specification/2025-06-18/server/resources>

## Handoff till nästa agent

Vid fortsatt implementation:

1. Läs hela detta dokument.
2. Bevara skillnaden mellan verifierade fynd och hypoteser.
3. Utgå från den fungerande Swift-servern i `Sources/LogicMCPDemo/main.swift`.
4. Bevara compare-and-set, readback och automatisk rollback för alla nya skrivverktyg.
5. Använd Swift och macOS `ApplicationServices` för den inbyggda AX-integrationen.
6. Lägg till tester för elementmatchning och värdenormalisering.
7. Utöka identiteten från fönstertitel och parameter till explicit projekt-, spår-, insert- och pluginidentitet innan bredare användning.
8. Gör fortsatta destruktiva eller omfattande tester på en projektkopia och ta snapshot före batchändringar.
9. Använd det befintliga open-source-projektet som referens eller grund om dess licens och arkitektur passar.

Målidentifieringen projekt → spår → insert → plugin är löst och verifierad sedan v0.3.0, inklusive programmatisk spårselektion av synliga spår. De viktigaste nästa stegen är:

1. Fönsterdisambiguering i `logic_set_plugin_parameter` när flera pluginfönster delar titel, till exempel genom att verktyget tar insertidentitet och använder fönstret som öppnades av `logic_open_plugin`.
2. Utred var spår 10–19 finns (Hide-funktion? raderade nummer?) och lös åtkomst till spår utanför renderingsytan, t.ex. genom att scrolla Tracks-arean programmatiskt eller använda Mixer-fönstrets channel strips.
3. Parameterschema för Compressor (råvärde ↔ formaterat värde) och därefter fler stock-plugins; undersök även tredjepartsplugins (`Trilian`, `PShft` syns som inserts på `Bas`).
4. Undersök om klick-fallbacken kan ersättas med Logics key command för stack-disclosure, så att Logic inte behöver tas till förgrunden.
5. Påbörja AU/MCP-demot ovan: en transparent sensorsignal, lokal telemetry, ett MCP live snapshot och en före/efter-utvärdering av exakt en verifierad Compressor-ändring. Börja gärna med endast `lead_vocal` innan tre sensorsignaler kopplas samman.

### Enbinär + repo-struktur (2026-08-25, v0.27.0)

Produktifieringssteg 0+1: git-repo initierat (snapshot-commit av forskningsläget först), forskningsloggen flyttad till `docs/FINDINGS.md`, ny engelsk produkt-README i roten. **En distribuerbar binär**: `LogicMCUBridge` är nu ett bibliotek med `public func bridgeMain()`; servern startar daemonen som `logic-mcp-demo --bridge` (själv-spawn — inga grannfiler att installera). Verifierat: dödad brygga → serverstart → själv-spawnad brygga → Logic återansluten (mcu_connected true) → sends-läsning genom nya kedjan. Bryggan överlever server-exit (design: daemonen delas mellan MCP-sessioner). Notera: `timebase` fick bli lazy-initierad konstant (bibliotek tillåter inga top-level-uttryck), och bridge-filen döptes om till `Bridge.swift`.

### Namnet: Logician (2026-08-25, v0.28.0)

Produkten heter **Logician** (Logic + musician + logiker). `logic-mcp` förkastades efter kollisionskoll: 87 GitHub-träffar med båda konkurrenterna (`logic-pro-mcp`, 76★ och 59★) i toppen — och "Logic" ensamt är Apples varumärke. `logician-mcp` hade 0 träffar. Binären/produkten heter `logician`; bryggan är `logician --bridge`. Privat GitHub-repo: BanneBanning/logician-mcp.

### Projektlivscykel: new/open/save/close (2026-08-25, v0.29.0)

Fyra nya verktyg efter användarens önskan om konkurrensparitet — med sparande som EXPLICIT verktyg (regeln skärptes: `logic_save_project` är den enda vägen något någonsin sparas; inga bieffektssparningar).

Empirisk kartläggning av Logics AppleScript-standardsuite: `documents` med name/path/**modified** fungerar (datadriven osparat-detektering!), `close saving yes/no` fungerar, men `save` är en stub (AppleEvent-timeout −1712) och `make new document` skapar fönsterlösa **spökdokument**. Därför: save via inlärt Save-keycommand (not 105, tyst för sökvägssatta projekt) verifierat mot modified-flaggan; nya projekt via **bundlad tom mall** (`Resources/EmptyProject.logicx`, 160K, skördad från File > New + engångs-panelautomation med användarens uttryckliga OK) som kopieras till målsökvägen och öppnas — 1,9 s, noll dialoger.

Fällor som hanteras: Logic kör **enprojektsläge** (öppning stänger aktuellt projekt; osparade ändringar kräver explicit `if_current_modified: save/dont_save`, annars vägran); mallen bar först på **Autosave-data** som gav en recovery-dialog ("Saved or Auto-saved?") vid öppning — mallen städades och `answerRecoveryDialog` svarar defensivt "Saved".

**Incident, dokumenterad som varnande exempel**: under mallskörden träffade ett File > Save-menytryck användarens projekt i stället för det fönsterlösa spökdokumentet — en oavsiktlig sparning i strid med no-save-regeln. Rotorsak: dokumentriktade operationer utan verifiering av aktivt fönster. Kodifierad fix: alla fönsterriktade flöden verifierar AXMainWindow-titeln innan de agerar, och spökdokument-vägen (make new document) övergavs helt.

### Röktestet + musfri plugininsättning (2026-08-25, v0.30.0)

Generaliserings-röktest mot ett projekt Logician själv skapade (`Logician Smoke Test.logicx`). Resultat 7/8 gröna — där "missen" var compare-and-set som korrekt vägrade (Compressors default-Ratio är 2.1:1, inte 2.0:1). Bank- och paramnamnscachar själv-läkte vid projektbytet. `logic_record_midi` fungerade direkt på default-instrumentet (Augmented), spårnivå-A/B likaså.

Äkta generaliseringsfynd, alla fixade:

1. **Mallen har noll spår** → nytt verktyg `logic_create_track` (software_instrument/audio): key command + automatiskt svar på Create New Track-dialogen, verifierat via spårantal.
2. **Orörda strippar saknar "insert bar"-element** — tomma slots heter "audio plug-in"-knappen och är dessutom AXPress-död (hit-test-klick krävs).
3. **Användaråterkoppling: musövertagandet vid add_plugin är oacceptabelt** → `logic_add_plugin` är nu MCU-först via **kontrollytans inbyggda pluginbläddrare**: vpot-vridning på tom slot stegar pluginlistan med fulla namn i LCD:n ("Channel EQ (s/s)"), vpot-press instansierar, lämna-vyn avbryter säkert. Verifierat: Channel EQ tillagd på 27,4 s utan mus och utan menyer. LCD:n avancerar bara varannan tick (dubblettnamn = "inte flyttat än", wrap = FÖRSTA posten återkommer). AX-choosern (kräver fysisk mus för hovernavigering) körs bara med explicit `allow_mouse: true`.
4. Save är sedan v0.29 en MIDI-not (105) — bekräftat på användarfråga: helt musfri.

Kvarstående optimering: bläddringen stegar +1 per varv (~27 s till mitten av listan); större delta med överskjutningshantering kan halvera tiden.

### Fel-kanal-buggen i browser-add + latensprofil (2026-08-25, v0.31.0)

**Benchmarken** (39 verktyg tidsatta): 20 verktyg <0,6 s; outliers = mcu_instrument_parameters kall läsning av Augmented **140 s** (sidantal × indikatorfade — optimering: sidcap + snabbare fade-detektering), record_midi 22 s (realtid, tempo-tricket kvarstår), create_track 12 s (slö dialogpolling), browser-add ~27 s (+1-stegning).

**Buggen (användaren fångade den i mixern)**: LoPass och Channel EQ hamnade på **Stereo Out**, inte Inst 1. Rotorsak: assign_plugin cyklar P1/P2 (multikanal-vy: varje vpot = EN KANALS insert N — St Out är en kanal!) och PL (kanalvy: valda spårets slots) — och PL visar MCU-VALDA spårets inserts utan att namnge det; MCU-valet kan divergera från AX-valet. Fix i addPluginViaBrowser: (1) explicit MCU-select av målspåret (findChannel+select) innan PL-vyn, (2) **AX-korsverifiering efter instansiering** — oberoende källa som namnger spåret, så fel-kanal-träffar inte kan passera tyst. Verifierat: Chorus → Inst 1 (AX: Chorus, Compressor, Augmented), överlevde save/reopen, 7,2 s.

**Bonus: musfri borttagning finns** — bläddraren har en "--"-post (No Plug-in) vid listgränsen; bläddra en upptagen slot dit och bekräfta = plugin bort. Verifierat vid städningen av St Out (102 steg baklänges genom ~100-postlistan, ~60 s). Kandidat för MCU-först logic_remove_plugin. Varning inpräntad: bekräfta ALDRIG en browse utan att ha verifierat att önskad post visas (en oskyddad loop instansierade Distortion II av misstag under städningen — borttagen igen).

### Optimeringsbatch (2026-08-25, v0.32.0)

Från latensprofilen, uppmätta resultat:

| Operation | Före | Efter | Metod |
|---|---|---|---|
| Instrumentparametrar, kall (Augmented, 76 sidor) | 140 s | **29 s** | `max_pages`-cap (default 12) — varje ocachad sida kostar ~1,7 s indikatorfade (Logics egen, opressbar); trunkering rapporteras ärligt med `pages_total`/`truncated` |
| Instrumentparametrar, cachad + cap | — | **6,1 s** | fast-vägen vandrar bara cappade sidor (inte alla 76) |
| create_track | 12,4 s | **8,3 s** | tätare dialog-/spårlistpolling (0,12/0,15 s-steg); resten är Logics egen dialogtid |
| add_plugin via bläddraren | ~27 s | **~6 s** | delta 2 per sändning (listan avancerar per TVÅ ticks), kortare awaits — plus settle-omläsning före bekräftelse och baksteg-korrigering när visningen driftat förbi målet |

Cappade kalla läsningar skriver INTE namncachen (bara fullständiga läsningar gör det) så cachens fast-väg förblir ärlig. Viktig regression som fångades av AX-korskollen under arbetet: delta-2-stegningen driftade systematiskt en post förbi matchen och instansierade fel plugin en gång — settle-vakten + korrigeringsloopen eliminerar det, och vakten bevisade därmed sitt värde inom en timme från att den byggdes.

Kvarstående ur optimeringslistan: record_midi-tempotricket (höj BPM N×, skala händelsetider — halverar+ inspelningstid), musfri logic_remove_plugin via "--"-posten.

### Tempo-tricket som opt-in (2026-08-25, v0.33.0)

Produktbeslut (användaren): realtid förblir DEFAULT — att höra taken spelas in är ett värde, inte en väntetid. `speed` (1–8) är opt-in för långa fraser.

Mekanik: tempo-slidern i Control Bar är AXValue-skrivbar men stegvis (±1 BPM per skrivning oavsett mål) — MEN accepterar skrivningar var ~8:e ms, så `setTempo` rapid-fire-konvergerar 120→240 på 1,3 s. `logic_record_midi {speed: 4}` höjer tempot ×4, skalar händelsetiderna, spelar in, återställer tempot (verifierat: exakt återställning, restore även i felvägar). Ärlig ekonomi: korta fraser vinner lite (fast overhead på ~10 s dominerar: select, playhead-park, preroll, tail, tempo-swap); vinsten skalar med fraslängden (16 takter: ~40 s → ~13 s). Timing-jitter skalar med speed — dokumenterat i schemat med kvantiseringsrekommendation.
