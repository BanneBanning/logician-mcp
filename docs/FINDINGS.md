# Logic MCP — verifierade fynd och teknisk handoff

Senast uppdaterad: 2026-08-28

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

### set_tempo, musfri remove, MIT (2026-08-25, v0.34.0)

- **`logic_set_tempo`**: control bar-sliderns rapid-fire-konvergens som eget verktyg med compare-and-set (`expected_current_bpm`). Uppmätt 0,3 s för 120→140; vägran vid fel förväntan verifierad. Hel-BPM-upplösning; konstant tempo antas.
- **`logic_remove_plugin` MCU-först**: bläddra den upptagna slotten baklänges till "--" (No Plug-in), settle-verifiera posten, bekräfta, korsverifiera via AX att pluginen är borta från spårets namngivna insertlista. Uppmätt 7,1 s för Exciter (gränsposten låg nära). AX-choosern (mus) endast bakom `allow_mouse: true` — sista musberoende operationen är därmed opt-in-degraderad.
- **findChannel själv-läker projektbytestransienten**: en tom full-scan (Logic bygger om ytan i sekunder efter projektladdning) väntar 2,5 s och skannar om en gång i stället för att fela — eliminerar den återkommande "match count 0"-klassen.
- **Licens: MIT** (LICENSE-fil, README uppdaterad).

### Regionläsning + regionval (2026-08-25, v0.35.0)

**Arrangemangskartan är läsbar** — fundamentet för hela redigeringssviten. Tracks-areans spårrader är `AXLayoutArea 'Track N "Namn"'` och deras AXLayoutItem-barn (AXRoleDescription "Region") ÄR regionerna: namn i AXDescription, och **AXHelp innehåller allt**: "Region starts at 9 bars 2 beats and ends at 11 bars , MIDI region." → start/slut-takt (+slag), typ. `logic_list_regions` parsar hela kartan på **0,2 s** (Testlåt: 15 spår, 38 regioner).

`logic_select_region` väljer exakt EN region (spår + namn/starttakt; tvetydighet vägras med kandidatlista) — `AXSelected` är skrivbar åt båda hållen, och `exclusive` (default) rensar först alla andra regionval så nästa redigeringskommando träffar bara målet. Verifierat: exklusivt val + korrekt avmarkering av övriga. En stale-element-transient direkt efter kartläsning motiverade engångs-retry i verifieringen.

Regionerna exponerar också AXHandles (trim-handtag!) och AXPosition/AXFrame — pixelvägar för framtida behov, men nudge-key-commands är rätt flyttmekanism. Nästa: redigeringssviten (cut/copy/paste/delete/nudge via inlärda kommandon ovanpå valet).

### Redigeringssviten (2026-08-25, v0.36.0)

**`logic_delete_region`, `logic_move_region`, `logic_copy_region`** — klipp/klistra/flytta utan mus, byggda på exklusivt regionval + inlärda key commands (Cut=108, Copy=109, Paste=110, Delete=111, Nudge bar/beat höger/vänster=112–115; exakta namn: "Nudge Region/Event Position Right by Bar" osv).

Säkerhetsdesign: **delete vägrar om inte EXAKT en region är vald projektövergripande** omedelbart innan kommandot avfyras (`selectedRegionCount`-vakten); flytt verifieras exakt mot arrangemangskartan för heltaktssteg; copy verifieras genom att regionen dyker upp på måltakten.

Två buggar hittade och fixade under verifieringen:

1. **Paste landade på fel slag**: `setPlayhead(bar:)` konvergerar bara takten och lämnar slaget där det stod — paste hamnade på 20.4 i stället för 20.1 (samma attributklass som beat-synk-buggen i record). Fix: copy sätter alltid beat 1 explicit.
2. **Delete kräver fokus**: Delete-kommandot agerar på fokuserad area — med enbart AXSelected misslyckades 3 av 4 raderingar tyst ("region still in the arrangement map"). Regionerna har skrivbart AXFocused; selectRegion ger nu regionen tangentbordsfokus efter valet. Därefter 3/3 raderingar.

Skarp användning direkt: användarens skräpregioner på Bas i Testlåt (test-tagningar "Bas" @ 44, 48, 62, 63) raderade och verifierade; spåret återställt till originalinnehållet (Inst 31 @ 9, 23, 35). Regionen @73 som synts tidigare fanns inte längre i kartan (redan borttagen).

### Automationsinspelning (2026-08-26, v0.37.0) — kronjuvelen

**`logic_record_automation`** skriver volymautomationskurvor helt i dataplanet — funktionen ingen Logic-MCP-konkurrent har:

1. **Kalibrering**: varje mål-dB konvergeras (LCD-verifierat via setVolume) och den absoluta 14-bit-positionen läses ur **Logics eget motorfader-eko** (`faders_14bit` i bryggspegeln) — dB→fader-mappningen kommer alltså från Logic själv, inte från antaganden om fader-tapern. Ursprungsvolymen återställs efter kalibreringen.
2. **Lägesbyte via MCU:s automationsknappar** (standard Mackie: Read 0x4A, Write 0x4B, Trim 0x4C, Touch 0x4D, Latch 0x4E — verkar på valt spår), verifierat genom stripens AX-etikett ("Latch, automation enabled").
3. **Inspelning**: playhead parkeras en takt före, playback rullar, timecode-synk vid taktkorsningen, och absoluta fader-kommandon (pitch bend + touch, som en riktig hand) placeras vid varje punkts musikaliska ögonblick. `ramp` (default) interpolerar mjuka övergångar med 2 delpunkter/slag.
4. **Verifiering med Logic som vittne**: intervallet SPELAS OM i Read-läge och motorfader-ekot samplas vid varje punkt. Första skarpa testet: 0 dB@takt2 → −15 dB@takt4, **exakt återläsning på båda punkterna (12483/12483, 6479/6479 av 16384 — noll avvikelse)**, 20,2 s totalt inklusive kalibrering och verifieringsreplay.

Felvägar återställer alltid: stop + Read-läge + ursprungsfader. v1 = volym; pan/sends/pluginparametrar via vpot-läget är nästa utbyggnad (relativa vpots kräver eko-konvergens under uppspelning).

### Pan/send/plugin-automation (2026-08-26, v0.38.0)

`logic_record_automation` breddad till **pan, send-nivåer och godtyckliga pluginparametrar** via en generaliserad motor med läs/skriv-closures per parametertyp:

- **Pan**: läser och skriver via stripens pan-knopp i AX (exakt eko; rapid-fire stegvis skrivning ±1/15 ms). PN-vyns LCD-värderad visade sig INTE alltid vara målad — AX-knoppen är den pålitliga källan. Verifierat: 0→+40→0, exakt återläsning på alla tre punkter.
- **Send/plugin**: relativa vpots med engångskalibrerad ticks-per-enhet (4-ticks-probe, återställd), blinda kalibrerade hopp vid varje musikaliskt ögonblick + budgetstyrda korrektionsrundor mot LCD-ekot; sista punkten får full konvergensbudget (1,5 s).
- **Verifieringsgenombrott: playhead-chase.** Replay-sampling av plugin-LCD:n underrapporterade (LCD:n laggar under uppspelning; kurvan såg ut att sluta på −33 när den i själva verket slutade exakt på −35 — bevisat genom att parkera playheaden efter riden: Logic chasar automationslanen till playheadpositionen och ger stationära, exakta avläsningar). Vpot-motorns verifiering parkerar nu playheaden på varje punkt i Read-läge i stället för att replaya — exaktare OCH snabbare. Verifierat: Compressor Thrs −20→−35 över takt 2–4, chase-avläsning −20,5/−35,0.

Send-vägen delar exakt samma maskineri men är inte skarptestad end-to-end (sandlådan saknar sends) — noterat som känd lucka tills ett send-projekt testas.

### Send-automationens skarptest (2026-08-26, v0.38.1)

Användarens utmaning: "gör testet i detta projekt — du har verktygen". Stämde nästan helt:

1. **Send-SKAPANDE via kontrollytan bevisat**: vpot-vridning på SenNIn-destinationsfältet i SE-vyn bläddrar destinationer (Output 1/2, Bus 1, 2, 3…) och vpot-press bekräftar — Inst 1 fick en Bus 1-send helt via MIDI. OBS: denna bläddrare stegar **1 post per tick** (pluginbläddraren: 1 per 2 ticks) — stegtakten måste probas per bläddrartyp. Kandidat för `logic_add_send`-verktyg.
2. Nya sends startar på **"-oodB"** (−∞): `parseDb` hanterar nu -oo (som −70) — parseNumber gjorde det inte.
3. **Send-automationen skriver äkta kurvor** (chase: −15,2 mitt i rampen, slutvärde −7,8 stabilt efter riden) men träffar inte målen exakt: (a) ankarpunkten vid första takten registreras inte trots touch-wiggle (Latch verkar inte fånga send-vpotens touch i SE-vyn — kurvan börjar först vid första faktiska värdeändringen), (b) slutvärdet stannade −7,8 mot mål −6 (konvergensen i SE-vyn under uppspelning terminerar tidigt). **Status: funktionell men ±2 dB — volym/pan/plugin är exakta; send behöver en egen finjusteringssession.** Även: vy-tillståndsläxa igen — en abort som lämnar PN-vyn aktiv gör att nästa raw-vpot-probe träffar PAN på kanal 0; alltid verifiera assignment-koden före vpot-vridningar.

Incidentnotis: pan-vridningar på Audio 1 under felsökningen tog aldrig (pan var kvar på 0 — enkelparamläget i PN ignorerade dem); inget att återställa.

### Send-finjusteringen (2026-08-26, v0.39.0) — automationsfamiljen komplett och exakt

Tre rotorsaker hittades och fixades, alla generella förbättringar av vpot-motorn:

1. **Adaptiv tick-ratio**: encoderskalor är olinjära (en dB nära −∞ är en bråkdel av en tick; nära unity flera) — seed-ration från startproben undersköt alla blinda hopp. `vpotJump` mäter nu observerad förflyttning per tick vid varje varv och uppdaterar ration löpande (glidande medel). Detta ensamt fixade slutpunkten (−6,0 exakt, synligt i användarens skärmdump av lanen).
2. **Rullstarts-ankare i stället för taktkorsnings-ankare**: första punktens konvergens behöver försprång, men med ankaret på korsningen in i första takten finns ingen tid "före". Synken ankrar nu vid själva rullstarten (timecode-förändring från parkerad position) och schemat förskjuts en förrullningstakt — första punkten får 1,2 s lead och full budget, så kurvan är framme och ankrad när dess ögonblick kommer (viktigt när en BEFINTLIG lane spelar upp ett annat värde vid rullstart och åsidosätter det parkerade statiska värdet).
3. **Vy-återinträde före verifiering** (buggen användaren fångade via lane-skärmdumpen: kurvan landade rätt men verifieringen läste fel/None): automationslägesknapparnas tryck kan knuffa ytan ur arbetsvyn — verifieringen går nu in i send-/pluginvyn igen (`refreshView`) innan chase-avläsningarna.

Slutresultat send: −19,8/−20 och −6,1/−6. Familjens facit: volym exakt, pan exakt, plugin exakt, send ±0,2 dB.

### CC + pitch bend i record_midi (2026-08-26, v0.40.0)

`logic_record_midi` tar nu `cc_events` (bar/beat/cc/value/channel — modhjul, expression, valfri controller) och `pitch_bends` (value −8192..8191, 0 = center) — händelserna byggs in i samma tidsstämplade ström som noterna och spelas in i samma region. Billig utbyggnad: bryggans midi_stream tog redan godtyckliga bytes; bara schemat och offset-matematiken behövde breddas (start_bar/duration tar nu hänsyn till cc/bend-händelser som ligger utanför notintervallet). Verifierat: C3 med 9-punkters modsvep + 8-punkters benddyk (19 händelser), inspelat och render-verifierat; ljudfilen levererad till användaren som hörbart bevis.

### Spårlivscykel, send-destinationer, presets (2026-08-26, v0.41.0)

**`logic_rename_track`**: headerns/stripens namnfält ignorerar direkta AXValue-skrivningar OCH AXPress — vägen är key commandet **"Rename Track"** som öppnar inline-editorn, vars fokuserade element ÄR skrivbart (AXValue + AXConfirm). Fälla fixad: rename-POPOVERN hänger kvar efter bekräftelsen och blockerar efterföljande kommandon — den stängs nu explicit (AXDialog med nya namnet som titel).

**`logic_duplicate_track`**: Logic har inget "Duplicate Track"-kommando — det heter **"New Track with Duplicate Settings and Content"**. Verifierad via spårantal.

**`logic_delete_track`** (destruktiv): selektionen omverifieras mot spårlistan omedelbart före avfyrning; verifieringen räknar namn-FÖREKOMSTER (inte total frånvaro — dubbletter delar ju namn).

**`logic_add_send`**: den manuellt bevisade destinationsbläddraren paketerad — första lediga slot, bläddra till namngiven destination (1 post/tick i denna bläddrare), settle-verifiera, bekräfta, verifiera via send-listan. Nya sends startar på −∞; sätt nivå med logic_mcu_set_send.

**`logic_plugin_preset`**: key commandet **"Next/Previous Plug-in Setting for topmost Plug-in Window"** (agerar på översta pluginfönstret — ingen fokusproblematik) + verifiering via pluginfönstrets preset-popup (AXPopUpButton-etiketten läsbar). Verifierat: "Default Preset" → "Classic Drums" → "VCA Vocal" på Compressor. Fönstret stängs igen om verktyget öppnade det.

### Rapido-batch 1 (2026-08-26, v0.42.0)

Allmän hastighetsjakt på användarens begäran. Tre strukturella förbättringar + två grävda rotorsaker:

1. **In-bridge-konvergens** (`converge`-kommandot): hela den adaptiva tick-loopen flyttad in i bryggan där LCD-ekot landar — 3 ms-polling i stället för socket-rundresa + 350 ms await per tick. Inkopplad i param-/send-/volym-/vpot-vägarna med serverloopen som fallback.
2. **Varm plugin-vy**: `setPluginParameter` lämnar medvetet edit-vyn öppen och cachear (spår, slot, namncache-nyckel); efterföljande skrivningar på samma mål hoppar över hela select→vy→enter-koreografin. Läxa på vägen: cacheKey MÅSTE följa med i hot-state — utan den föll sökningen till slow-vägen med 1,3 s fade per sida (9–13 s-regression innan fixen).
3. **Uppmätt**: parameterskrivning varm 2,8 → **1,6 s**; kall ~3,8 s (första anropet betalar vy-setup). Kvarvarande varm tid domineras av normalizeToPageOne (0,9 s indikatorvänta) + sidvandring — nästa steg: slå upp parameterns sida direkt ur namncachen.

Rotorsaker grävda under arbetet:

- **En uråldrig fristående `logic-mcu-bridge`-daemon** (från före enbinärs-eran) ägde socketen — ping svarade så ensureRunning bytte aldrig ut den, och alla "bryggomstarter" sedan dess hade varit no-ops. Fix: **versionsstämplad ping** (`bridge_protocol: 2`); föråldrade daemoner termineras och ersätts automatiskt.
- **Slumpade CoreMIDI-unique-IDs** bröt Logics kontrollytebindning vid varje äkta bryggomstart. Fix: **fasta kMIDIPropertyUniqueID** ('LMC0'–'LMC3') — en engångs-ombindning i Control Surfaces Setup krävdes (utförd av användaren), därefter överlever bindningen alla omstarter.
- Incidentnotis: sandlådan hade sparats med ENBART ett pluginfönster som fönsterlayout ("jag ser bara en kompressor"); att stänga projektets sista fönster stänger projektet. Huvudfönstret återställdes via Window > Open Main Window och layouten sparad.

Kvarvarande rapido-backlog: parametersida-uppslag ur cachen (1,6 → ~0,8 s), samma varm-vy-mönster för sends/instrument, batch-verktyg (N operationer per anrop utan per-anrops-setup), trimning av await-tak (350 → ~180 ms), volymens payload saknar db-fältet i bridge-converge-vägen (kosmetiskt).

### Gemini-kraschen + lyssningsvägen (2026-08-26, v0.43.0)

Användarens Gemini-session kraschade hårt ("Agent execution terminated") efter "can you listen to the file?": Gemini LÄSTE den råa binära wav-filen in i sin kontext (megabytes) — känd Gemini-krasch vid för stor input, och sessionen förblir brickad eftersom historiken följer med varje ny prompt. Inte ett Logician-fel, men det exponerade en verklig lucka: agenter behöver en SÄKER lyssningsväg.

Åtgärder: (1) **`logic_get_audio_clip`** — trimmar (via vår egen sliceAudioFile; afconvert saknar offset-stöd) och komprimerar (mono AAC 64 kbps) upp till 20 s och returnerar det som ett äkta **MCP audio content block** (typ "audio", base64 + mimeType) — multimodala klienter kan lyssna på protokollets villkor, ~8 KB/s. `toolResult` stödjer nu audio-block via `_audio`-nyckeln. (2) **`preview_path`** på render/bounce-resultat: komprimerad stereo-AAC-syskonfil (Geminis filvisare stödjer AAC/MP3/WAV men INTE AIFF — användarens fynd). (3) Varningsnoter i resultat + nytt guide-avsnitt "Listening to audio (IMPORTANT)": läs aldrig audiofiler som text.

### logic_duplicate_project (2026-08-26, v0.44.0)

Agent-sandlådan: kopierar det öppna projektet på disk (Autosave-mapparna rensas ur kopian — annars recovery-dialog vid öppning) och öppnar kopian som aktivt projekt. `save_first` bakar in osparade ändringar; varning i resultatet när diskbilden saknar dem. Verifierat: 2,0 s, kopian aktiv via project_document, original orört. Guiden instruerar agenter att duplicera FÖRST inför icke-godkända ändringar.

### Geminis femfelsrapport: rotorsaken var portidentiteten (2026-08-26, v0.45.0)

Geminis diagnos ("save-timeout", "bounce-dialog kvar", "end-bar readback-mismatch", "freeze aktiverades aldrig", "NFC/NFD") ledde till ett viktigare fynd än de fem symptomen: **Logic scope:ar key command-MIDI-bindningar till portens unika identitet.** När bryggan bytte till fasta kMIDIPropertyUniqueID ('LMC0'–'LMC3') blev ALLA tidigare inlärda bindningar föräldralösa — de VISAS fortfarande i Key Commands-fönstret ("Note 105") men matchar aldrig inkommande MIDI. Save, freeze (= render), cut/copy/paste — allt keycmd-baserat dog tyst samtidigt. Symptom 1 och 4 var samma fel.

Reparationen: `logic_setup_key_commands {relearn: true}` — raderar först kommandots befintliga controller-tilldelningar (Delete Assignment-knappen i Key Commands-fönstret, per rad) och lär sedan om en enda fräsch bindning. Tre AX-fällor upptäcktes på vägen: (1) varje radering re-renderar panelen så tabell/checkbox-referenser blir tysta nop:ar — allt måste hämtas färskt per iteration; (2) raderingarna släpper KOMMANDORADENS markering, så Learn tilldelar till ingenting om raden inte väljs om; (3) verifieringen får inte kräva texten "Note N" — Logic visar vissa noter symboliskt (109 → "F2 (Modifiers ▶︎ Cmd/Alt)" eftersom noten mappar till en namngiven MCU-kontroll), så "raden ändrades" är rätt kriterium.

**Bounce-dialogens positionsfält knäckta på riktigt:** gruppens fyra AXSliders speglar samma råtick-värde men stegar i VAR SIN enhet mot ett skrivet värde — segment 0 = takter, 1 = slag, 2 = divisioner, 3 = ticks. Kaskadkonvergering (segment för segment tills exakt träff) når varje position, inklusive från Logics icke-taktjusterade default (projektslutet, t.ex. "44 2 3 1") som ren taktstegning aldrig kan lämna — det var Geminis mismatch. Verifierat: bounce 41–45 grön, 25,6 s inkl. AAC-preview.

Övriga fixar: save verifieras nu även via ProjectData-mtime (dirty-flaggan kan vara view-only); bounce-dialogen avbryts alltid på felvägar (modal dialog = total lockout annars); duplicate_project degraderar save_first-fel till diskkopia-med-varning; NFC-normalisering på AppleScript-dokumentnamn; freeze-felmeddelandet nämner Track Header-konfig och relearn-reparationen.

**Het vy-läcka fixad:** när servern dör med ytan kvar i plugin/instrument-vy auto-öppnar Logic pluginfönster vid varje spårval (Trilian poppade upp mitt i freeze-testet). Servern skickar nu exitToPan när stdin stängs — verifierat via LCD-spegeln (PL-vy → Pan-namn).

### method "solo_bounce" — spårnivå-A/B för ofrysbara spår (2026-08-26, v0.46.0)

Uppföljning på Ivan Vocals-fyndet: spår som Logic vägrar frysa (subspår i stackar, spår som delar kanalremsa) hade ingen spårnivå-A/B alls. Ny metod i logic_evaluate_change: solo på (AX-strippen är auktoritativ när track_number ges — dubblettnamn gör MCU-namnmatchning tvetydig) → offline-bounce A → verifierad MCU-parameterändring → bounce B → rollback → solo av. Solo-återställningen körs på ALLA felvägar; solo_restored rapporteras separat i payloaden. Master-kedjan ligger kvar i signalvägen (inneboende i solo-bounce) men träffar både A och B, så deltan är ärliga.

Verifierat på exakt det spår Gemini gick bet på: Ivan Vocals #21, Channel EQ Pea4Ga +1,0→+2,8 dB, bounce 41–45: rolled_back, solo_restored, RMS-delta +0,09 dB. 157 s totalt — långsammare än freeze-render (15 s) men täcker spåren render inte kan. Guiden pekar dit från freeze-felmeddelandet.

### Bounce-positionens oscillation + min-klampningen (2026-08-26, v0.46.1)

Användaren filmade dialogen hoppandes 40↔41 i evighet: när fältet bär en subtakts-rest MED bråkdels-ticks ("41 1 4 240.") oscillerar taktstegningen runt målet (−1 takt under, +1 takt över, om och om) — och stall-detektorn triggade aldrig eftersom värdet ändras varje skrivning. Tick-segmentet hade dessutom behövt 240+ steg och kan aldrig träffa en bråkdelsrest exakt.

Nyckelfyndet: **fältet klampar EXAKT till sitt minimum** — en nedvandring till min raderar hela resten (verifierat: "14 4 4 240." → 16 skrivningar → "1 1 1 1", raw == min). Ny strategi: taktjusterat värde stegar direkt mot målet (snabba vägen); värde med rest klampas först till min och stegas sedan upp exakt. Plus oscillationsvakt (värde == näst-föregående → avbryt). Kaskad-segmenten från v0.45 behövs inte längre. Resultat: bounce 41–45 på 7,1 s och 9–13 på 6,4 s (var ~25 s); solo_bounce-A/B:t sjunker därmed från ~157 s till uppskattningsvis ~50 s.

### Riktiga öron i Antigravity + tysta bounce-vakter (2026-08-26, v0.47.0)

Empiriskt testat med `agy --print`: Antigravity binder nu logic_*-verktygen nativt (v0.46.2-handskakningen), men **släpper INTE igenom MCP-audioblock** — logic_get_audio_clip når modellen som enbart text. Däremot skickar Antigravitys **filläsare (read_file) ljudfiler som äkta multimodal audio**: Gemini beskrev guard-test-bouncen korrekt (svensk drill, glidande 808:or, ~140 BPM halvtempo). Lyssningsvägen i Antigravity är alltså: bounce → öppna preview_path (.m4a) med filläsaren. Guiden och bounce-notisen uppdaterade.

Upptäcktes via att Geminis "final"-bouncar var tysta (AAC ~2 kbps = tystnad): spår 4 "Inst 2" stod kvar med Solo=1 från dess session, så varje master-bounce innehöll bara det tysta spåret — och Gemini "lyssnade" ändå. Två ärlighetsvakter i bounceRange: `metrics` alltid med + `warning` när filen är tyst (RMS ≤ −65 dB) eller när spår står solade (namnges).

### Ljudet kommer till agenten (2026-08-26, v0.48.0-0.48.1)

Användarens designbeslut efter det neutrala prompttestet: INGA fler sifferverktyg (varje mätverktyg är en flyktväg från lyssnandet) — i stället ska lyssningen vara obligatorisk och friktionsfri. Två steg: (1) v0.48.0: listen_note på varje ljudpåverkande skrivning + fader≠loudness-doktrin i instructions/guiden (agenten hade matchat faders på inspelningar med helt olika nivåer). (2) v0.48.1: resultat som producerar ljud BÄR ljudet — bounce/render bifogar sitt eget MCP-audioblock (stereo AAC 64 kbps; OBS: afconvert -c 1 kraschar på AIFF med explicit stereolayout, 'cclo' -66564), och alla tre evaluate-metoderna bifogar BÅDA versionerna i ordning (block 1 = baseline, block 2 = after) via _audio_list. Agenten hör A/B:t i samma svar som keep/rollback-beslutet fattas i. Verifierat: bounce 7,4 s med 66 KB block, render 8,1 s med block.

### Kodbasrestrukturering: main.swift → 28 domänfiler (2026-08-26, v0.49.1)

10 348-raders main.swift delad längs MARK-sömmarna till 28 filer i Sources/Logician (modulen omdöpt från LogicMCPDemo): Support (fel/typer/globaler), LogicAccessibility-kärna + 9 AX-extensionfiler, MCUController-kärna + 10 MCU-extensionfiler, bridge-klient, registry, MCPServer-kärna + ToolHandlers + ToolSchemas, samt en minimal main.swift (entry). Mekanik: klasser delas över filer via extensions; lagrade (även statiska) properties får inte ligga i extensions så hotPluginView/lastResolveLearned flyttades till kärnfilerna; medlems-private ströks blankt (blir internal inom modulen — kravet vid fildelning). Bygget gick igenom på första försöket; röktest grönt (57 verktyg, health, tracks, bounce med audioblock). Ett volymfel ("Requested 808, selection is Bas") visade sig via worktree-jämförelse mot 87cd4ca vara PRE-existerande, ej regression — separat utredning.

### Volymbuggen: PAN-knappens tillståndsmaskin och LCD-transienterna (2026-08-26, v0.49.2)

Jakten på "Requested 808, selection is Bas" gick genom FEM lager: (1) PAN-assignmentknappen TOGGLAR multi↔singelkanalvy, och singelvyn ("Pan  -  -  ...") ser ut som en transient för settledTop (≥4 streck) → bankscans dog på timeout; (2) övergången MELLAN vyerna målas via en mode-banner ("Pan/Surround parameter: Pan" över fält 5–8) med sub-sekunds pauser som lurade korta stabilitetsfönster — beslut fattade på transienta bilder fick loopen att jaga sina egna toggles; (3) bankklampningen: med spårantal ≠ 8×n klampar högraste banken, så relativ vänsternavigering går längs ett förskjutet raster — navigera alltid om från vänsterkanten; (4) CS-vyns 7-segmentskod är inte tillförlitlig — kräv det funktionella beviset ("Channel Strip parameter: Volume" i LCD-toppen); (5) ytan kan stå i VILKEN vy som helst (kanalöversikt, pluginvyer) — tillståndsmaskinen behöver tryck-som-default för okända stabila vyer, vänta-ut endast för äkta banners (innehåller "parameter:" MED assignment PN).

Slutresultat: ensurePanNames är en stabil-tillstånds-maskin (1 s tyst LCD innan klassificering), och 7/7 volymanrop från tvingat trasigt läge går via MCU-vägen (bridge_converge) på i snitt 6,4 s. AX-fallbackens selection-fel visade sig vara följdfel av MCU-bankstormen — borta när MCU-vägen fungerar.

### Socket-framing och singelinstans-lås (2026-08-27, v0.50.0)

Två tysta felkällor som två oberoende Opus-granskare var för sig flaggade, fixade ihop eftersom de är samma gränssnitt. (1) Protokollet gjorde EN write() och EN read() av en 64 KB-buffert med returvärdena slängda — men macOS ger unix-socketen 8 KB mottagarbuffert, så allt större trunkerades tyst och besvarades "invalid JSON": logic_record_midi dog över ~130 noter medan bryggan utlovade 20 000 events. Ny delad Framing.swift (BÅDA sidor importerar den) med writeAll() som retryar korta skrivningar/EINTR och readToEOF() som läser tills peeren halvstänger — klienten gjorde redan shutdown(SHUT_WR), så EOF var alltid väldefinierat, ingen använde det bara. Verifierat: 140 KB / 6 000 events går igenom intakt; bröt förut vid 27 KB. bridgeProtocolVersion bor nu i delade modulen (var två literaler i två moduler — skev-kontrollen var själv oskyddad mot skev), höjd till 3.

(2) Ingen singelinstans-vakt: `unlink(socketPath)` + bind utan lås gjorde att två klienter som startar samtidigt båda spawnar en daemon; nummer två stjäl socketen medan dess MIDI-endpoints inte kan ta de fasta unique-ID:na — och de MIDIObjectSetIntegerProperty-anropen ignorerade sin OSStatus, så förloraren körde vidare med slumpade ID:n och alla Logic-bindningar slutade tyst matcha. Exakt den orphaning-katastrof fasta ID:n finns för att förhindra. Nu: flock innan unlink/bind, och OSStatus kontrolleras — daemonen vägrar köra med fel identitet i stället för att se frisk ut.

Sidofynd (förelåg redan, verifierat mot föregående build): startar man om daemonen medan Logic kör återöppnar Logic INTE kontrollyteporten av sig själv — den måste väljas om i Control Surfaces > Setup, eller Logic startas om. logic_health skiljer nu på "färsk setup" och "bryggan startades om".

### Utomstående granskning: fyra Opus-agenter, och vad de hittade (2026-08-27, v0.50.x)

Fyra parallella granskare utan projekthistorik (arkitektur, korrekthet, MCP/API, säkerhet) läste kodbasen. Utfallet motiverade övningen flera gånger om:

**Säkerhet — en RCE.** `closeProject` interpolerade dokumentnamnet rakt in i osascript-källan, och namnet är ett filnamn agenten själv väljer: ett projekt döpt med citattecken + radbrytning + `do shell script` bröt sig ut och körde godtycklig shell som användaren. Fixat via argv (värden kan aldrig bli kod), verifierat inert med exakt payloaden. Plus path traversal via labels, en förbigången consent-grind i `logic_mcu_command`, socket 0600 och en `pkill -f` som kunde träffa orelaterade processer.

**Korrekthet.** `insert_slot` utanför 1–8 indexerade LCD-fält före sin egen bounds-kontroll → serverkrasch (en agent som läser slot 9 från AX-ordinalerna dödade sessionen). `solo_bounce` lämnade spåret solat när parameterskrivningen kastade — vanligaste agentmisstaget, och varje efterföljande bounce blev tyst. Bounce-metodens A/B lämnade ändringen kvar vid misslyckad B-render.

**Arkitektur.** Två oberoende granskare flaggade socket-framingen och avsaknaden av singelinstans-lås. Dessutom: filsplitten hade strandsatt fyra doc-kommentarer på fel deklarationer — en av dem (`hotPluginView`) beskrev en invariant som inte gällde. Inga tester alls trots att MIDI-parsern, dB-kurvan och LCD-parsningen är rena funktioner.

**Efterarbetet.** Testtarget (50 tester, 0,04 s, ingen Logic). Tool-descriptor-registry: `callTool` 1330 → 35 rader, honesty guards blev flaggor i stället för handhållna namnlistor, verifierat beteendeneutralt via identisk sha256 på schemadumpen. Cache-scoping som också avslöjade att fält 6–7 aldrig validerades (de gömmer sig bakom "Page x/y"-indikatorn), så en plugin-uppdatering kunde para cachade namn med fel värden.

**En egen läxa:** mina nya framing-tester hängde 10 minuter hos en subagent. Orsaken var min testkod, inte framingen — skrivaren låg på en GCD-kö medan huvudtråden blockerade i `read()`, och med mättad trådpool schemaläggs skrivaren aldrig. En tråd som blockerar i ett syscall kan inte ge efter. Riktiga OS-trådar + läs-timeout; verifierat med tre parallella sviter under full CPU-last (1 s).

### Smart Tempo-vakten: Project Tempo-knappen finns i AX men bär inget värde (2026-08-27, v0.50.x)

Roadmap-punkt 1:s farligaste hål: Logics **projekttempoläge** (Smart Tempo) avgör vad en inspelning gör med projektets *tempokarta* — **Keep** lämnar den ifred, **Adapt** SKRIVER OM den så att den följer inspelningen, **Auto** väljer själv (lutar mot Adapt när metronomen är av). Sedan Logic 10.4.2 gäller det MIDI-inspelningar också, och `logic_record_midi` streamar just en MIDI-performance medan Logic spelar in. På ett Adapt-projekt förstörde verktyget alltså användarens tempospår som sidoeffekt — på ett konstant-tempo-projekt, tyst, utan ett ord i resultatet. Ingenting vaktade det.

**Experimentet (skrivskyddad AX-probe mot körande Logic, `Testlåt Copy.logicx`, pid 25052, LCD i Display Mode "Beats & Project" — den vy som FAKTISKT visar läget):** knappen finns. Den ligger som direkt syskon till `Tempo`-slidern inne i den inre "Control Bar"-gruppen, i ordningen `Display Mode` → `Playhead Position` → `Tempo` → **Project Tempo** → `Time Signature` → `Key Signature`. Men den bär inget värde alls:

- `AXRole` = `AXPopUpButton`, `AXRoleDescription` = "pop up button", ram 60×29 px strax under tempo-slidern.
- `AXDescription` = **tom sträng** — till skillnad från varje annat display-element i control baren (`"Tempo"`, `"Time Signature"`, `"Key Signature"`), så knappen kan bara identifieras på sin `AXHelp`-prefix `"Project Tempo menu"`.
- `AXValue`, `AXTitle`, `AXValueDescription`: **saknas helt** — inte tomma, attributen finns inte ens i `AXUIElementCopyAttributeNames`. Hela attributmängden är geometri + `AXHelp`.
- Grannarna `Time Signature` och `Key Signature` publicerar däremot sina `AXValue` ("4/4", "B♭ Major"). Logic håller alltså tillbaka just detta värde; det är inte proben som missar det.
- Sökning i HELA projektfönstret (djup 14) på keep/adapt/auto/smart gav noll element vars värde eller titel ÄR ett lägesord — bara Apples tooltip-prosa på knappen ("…whether the project tempo is maintained, adapts to the tempo of audio recordings…", statisk, inte tillståndsbärande) plus orelaterade träffar (Smart Controls, automationsläge).
- `AXUIElementCopyActionNames` på knappen: `["AXShowMenu", "AXPress"]`, `AXChildren` tom. Menyn — och därmed förmodligen en markering av aktivt läge — materialiseras först vid tryck.

**Följd för designen: läget är i praktiken OLÄSBART, och det fick bli ett förstaklassigt svar.** `ProjectTempoMode` har fem fall: `keep`/`adapt`/`auto` plus `unreadable` (knappen finns, inget värde) och `absent` (ingen knapp). Att *anta* Keep när läget inte går att läsa är exakt det antagande som kostar tempospåret, så vakten i `logic_record_midi` gör tre olika saker: ADAPT → vägran (`precondition_failed`, inget inspelat, fixen namngiven); AUTO → samma vägran, med skälet att Auto kan lösa ut till Adapt och att vi inte kan verifiera vilket; oläsbart → spelar in, men resultatet bär en `warning` som säger att kontrollen gick overifierad och att ett Adapt-projekt i så fall just fick sin tempokarta omskriven (kolla tempospåret, Undo vid behov). `logic_get_transport` lägger till `project_tempo_mode` bara när läget är känt, annars `project_tempo_mode_note` med skälet — ett oläsbart läge får aldrig serialiseras som ett värde, för ett saknat värde läses som "keep".

Strängmappningen (`normalizedProjectTempoMode`) är därför ren och separat testad fastän AX-vägen i dag ger noll: den dagen Logic börjar publicera värdet — eller menyvägen landar — är det den mappningen vakten hänger på. Exakt ettordsmatchning först, sedan adapt/auto före keep i substrängfallet, så en sträng som nämner två lägen lutar mot vägran i stället för mot en destruktiv inspelning.

**Nästa experiment (medvetet inte gjort här):** `AXShowMenu` + uppräkning av menyposterna via `AXMenuItemMarkChar` är den troliga läsvägen, och om posterna går att `AXPress` blir vägran i stället ett vaktat set-and-restore (sätt KEEP, spela in, återställ). Men det är en UI-mutation på en läsväg, och anropspunkten är precis där en inspelning armeras — en öppen meny där kan svälja transporten. Proben var strikt skrivskyddad (inga `AXUIElementSetAttributeValue`, inga tryck, inga klick, inga tangenttryck, inga fönster öppnade eller stängda) och `logician`-binären startades aldrig: dubbla virtuella MIDI-portar orphanar tyst alla key command-bindningar (se v0.45.0).
### MCU-timecodens läge: vakt mot SMPTE-tolkade takter (2026-08-27, v0.50.x)

`timecodeBar()` läste de tre första tecknen i den 10-siffriga 7-segmentsdisplayen som takt — men displayen har TVÅ lägen (takt/slag eller SMPTE) och MCU-protokollet bär **ingen lägesbit**: tio CC-meddelanden (0x40–0x49) målar tio siffror, och inget säger om de betyder takt/slag/division/tick eller timmar/minuter/sekunder/bildrutor. I SMPTE-läge läste alltså MIDI-inspelningens synk timmar som takt och minuter som slag — och synkade tyst mot nonsens. Roadmap-punkt 1, "Guard the MCU timecode parse".

Ny ren klassificerare `classifyTimecode` (`Sources/Logician/MCUMIDIRecording.swift`, 11 enhetstester, varken brygga eller Logic behövs). Fältlayouten är fasta snitt ur bryggans 10-bytesbuffert (takt 3, slag 2, division 2, tick 3 — bryggan lägger inga separatorer; den mellanslagsseparerade formen 3/2/2/3 accepteras också, så ett framtida formatbyte degraderar till "fortfarande tolkad" i stället för "varje position otrolig"). Vakten vägrar bara på POSITIVA belägg, eftersom ett falskt nej blockerar en legitim inspelning:

- takt, slag och division är **ettbaserade** överallt i Logic medan SMPTE:s timmar/minuter/sekunder är nollbaserade — en nolla (eller ett blankt fält) i takt- eller slagfältet, eller en bokstavlig `00`-division, är belägg för SMPTE-läge snarare än för en musikalisk position;
- blank division och blanka tickar TOLERERAS och rapporteras som 0 (7-segmentsavkodningen är bara verifierad för siffror och mellanslag, se 2026-08-25);
- `ALERT`-sentinelen (modal dialog fryser hela spegeln) och den aldrig målade displayen klassas separat — inget av dem är ett lägesproblem;
- **avgörande** kontroll: den takt anroparen just parkerat playheaden på — AX-verifierad av `setPlayhead`, som kastar om kontrollradens takt inte stämmer — jämförs mot displayens takt med ±1 takts slack. Sifferkombinationer som bara SER ut som en position (SMPTE 01:02:03:04:05 blir "takt 10, slag 20, division 30") fångas ENBART här; formkontrollen kan bevisligen inte se dem, och testerna dokumenterar just den gränsen.

Inkopplat i de synkkritiska konsumenterna, båda i två steg: billig formkontroll innan något valts, flyttats eller armerats, och korskontrollen mot parkerad takt precis före rullning. `recordMIDI` återställer playheaden själv på vägran (dess städ-`defer` är inte armerad än); `recordVolumeAutomation` vägrar redan före kalibreringspasset, och i det senare läget låter den befintliga catchen återställa Read-läge och originalvolym. `timecodeBar()`/`timecodeBarBeat()` går nu genom klassificeraren och returnerar nil i stället för nonsens, så pollningsloopar timeoutar med sina egna `verification_failed`. Rena strängjämförelser är lägesoberoende och orörda: `MCURender`s ALERT-detektering och vpot-automationens rullstartsankare.

Felkoden är `precondition_failed` (inget skrivet) och meddelandet namnger åtgärden: *"the MCU secondary display is in SMPTE mode; press the SMPTE/Beats button in Logic's control bar or the MCU display to switch to beats, then retry"*. Automatfixen är INTE implementerad: bryggan mappar redan `smpte_beats` (`Bridge.swift:447`) och ett tryck behöver inget återställande (trycket ÄR fixen), men effekten kan inte verifieras utan live Logic + brygga — och en oprövad knapptryckning i ett synkkritiskt läge är sämre än ett tydligt nej. TODO i `requireBeatsDisplay` pekar tillbaka på roadmap-punkten.

**Overifierat, för ärlighetens skull:** ingenting i den här ändringen har körts mot Logic — allt är enhetsnivå (`swift test`, 143 tester gröna). Det exakta siffermönster Logic målar i SMPTE-läge är därmed ANTAGET (nollbaserade fält, högerställda), taktfältets tak på 999 är oprövat, och takt/slag-layouten `BBB bb dd ttt` är samma antagande som den gamla parsen redan gjorde — vakten ärver alltså inget nytt formatantagande, men om Logic målar annorlunda skulle den kunna vägra en giltig display. Därav toleransen för blanka fält och kravet på positiva belägg. Nästa forskningssession bör logga båda lägenas råa tio tecken och bekräfta `smpte_beats`-tryckets effekt på spegeln.

### Tvåpunktssampling av tempot: positionsberoendet blev sensorn (2026-08-27, v0.50.x)

Roadmap-punkt 1:s kärna. All takt→sekunder-matematik i servern går genom EN primitiv, `barRangeSeconds` (`Sources/Logician/ToolHandlers.swift`), som räknar `(takt − 1) × slag × 60/BPM` på ETT tempovärde läst från kontrollraden. Och kontrollraden visar tempot **vid playhead-positionen** — samma positionsberoende som gör matematiken tyst fel från projektets första tempoändring är också det som gör frågan billig att besvara: parkera playheaden på områdets första takt, läs, parkera på sista takten, läs, ställ tillbaka. Två läsningar avgör "är tempot konstant över dessa takter?".

**Asymmetrin som motiverar hela punkten:** verktyg som *lämnar takterna till Logic* (`logic_bounce_range`, `logic_evaluate_change` med `bounce`/`solo_bounce`, `logic_set_cycle_range`, regionverktygen) är redan korrekta under vilken tempokarta som helst — Logic tolkar. Verktyg som *skär sekunder själva* (`logic_render_track`s slice, `logic_evaluate_change` metod `render`, `logic_record_midi`s notplacering och verifieringsrender) var tysta fel. En korrekt bounce intill en felaktig freeze-slice av samma takter, utan ett ord om skillnaden.

**Vad varje väg gör med svaret nu:**

- `logic_evaluate_change` metod `render` **VÄGRAR** (`precondition_failed`) och namnger `bounce`/`solo_bounce`. En varning räcker inte där verktygets hela uppgift är ett trovärdigt A/B: under en tempokarta täcker baseline-slicen och den ändrade slicen OLIKA musik, så dB-deltat skulle tillskrivas pluginet. Vägran sker innan något valts eller skrivits.
- `logic_render_track` varnar och säger att **hela** rendern är opåverkad — bara slicens gränser är det. Utan takterval samplas ingenting.
- `logic_record_midi` varnar, och **vägrar `speed > 1`**: speed-läget skruvar upp tempo-slidern för tagningen och skriver tillbaka ETT värde, vilket inte kan återställa en karta (`setTempo` skriver dessutom in på den nod playheaden står på).
- `logic_set_tempo` vägrar rakt av. Den slider verktyget skriver styr den tempo-nod playheaden står på, så på ett kartlagt projekt redigerar den användarens tempospår i stället för projekttempot. Andra samplingspunkten är **takt 1** — projektets första tempo-nod, den enda punkt varje projekt har.

**Designbeslut, med skälen:**

- **Epsilon 0,05 BPM.** Slidern *skrivs* i heltals-BPM (`setTempo` rundar, dess egen compare-and-set använder 0,5) men *publicerar* ett värde som parsas som Double, och ett projekt vars tempo kommer från tempospåret kan bära decimaler. 0,05 ligger under varje verkligt tempo-steg och över läsbrus: en avvikelse så liten flyttar en takt-33-gräns vid 120 BPM i 4/4 med ~27 ms, innanför den ~45 ms synkkompensation MIDI-vägen redan lever med.
- **Ingen override på `logic_set_tempo`.** Frestelsen var "flytta playheaden medvetet och skicka `expected_current_bpm`". Men VILKEN nod Logic redigerar — eller om den skapar en ny — är overifierat härifrån, så en sådan flagga hade varit en gissning klädd som samtycke. Vägran namnger i stället var en karta redigeras: tempospåret eller Tempo List.
- **Två punkter BEVISAR inte konstant tempo.** En karta som är tillbaka på sitt utgångsvärde mellan samplingspunkterna läser som konstant. Varje meddelande säger därför bara vad det vet, och `tempo_sampled_at_bars` i `logic_set_tempo`-resultatet talar om vilka två takter som faktiskt jämfördes.
- **En misslyckad kontroll degraderar till varning, aldrig till vägran.** Ett verktyg som fungerar i dag får inte gå sönder av att en *kontroll* inte kunde köras — samma val som Smart Tempo-vaktens oläsbara läge. Och playheaden flyttas ALDRIG när det inte finns någon position att ställa tillbaka; en återställning som inte hände följer med domen i stället för att sväljas av den (`TempoSample.playheadLeak`).
- **Kostnadskontroll:** högst en sampling per verktygsanrop. `logic_record_midi` anropade `barRangeSeconds` två gånger (schemaläggning + verifieringsrender) — nu löses tempo/taktart ut en gång och båda delar ett område och en sampling. Bounce-vägarna samplar inte alls.

**Live-verifierat mot körande Logic** (`Testlåt Copy.logicx`, pid 25052, konstant 120 BPM, 4/4, playhead takt 57 slag 4) via ett tillfälligt XCTest som togs bort efteråt: en 4-takters sampling nära playheaden kostade **1,07 s**; playhead→takt 1 från takt 57 kostade **14,25 s**, dvs **~0,13 s per takt playhead-resa** (LCD-slidern konvergerar ett steg per skrivning, ~0,12 s). Båda gav `constant`, playheaden kom tillbaka till takt 57 slag 4 exakt, och tempot var orört. Det är också den ärliga kostnadssiffran i verktygsbeskrivningarna: `logic_set_tempo` med playheaden långt från takt 1 tar sekunder, och en render av takt 1–9 med playheaden på takt 57 betalar ~120 takters resa. Snabbare playhead-förflyttning finns inte i dag (nyckelkommandon och MCU-jog är oprövade för detta); den riktiga fixen är roadmap-punkt 3 — läs tempokartan direkt ur Tempo List och sluta sampla.

**Overifierat, för ärlighetens skull:** avvikelsegrenarna (varningen, de tre vägranssorterna) är ENBART enhetstestade. Testprojektet har ingen tempokarta, och att bygga en hade betytt att skriva i användarens projekt — så att en riktig tempoändring verkligen visar sig som två olika slider-värden är fortfarande ett *antagande* om Logic, byggt på att kontrollraden är positionsberoende (vilket däremot är observerat sedan 2026-08-24). Nästa forskningssession bör göra just det på ett kladdprojekt: lägg en tempoändring mitt i, kör samplingen, och kontrollera att slidern verkligen visar decimaler när tempot inte är heltal — epsilonet 0,05 är valt för det fallet men har aldrig sett det.

**Sidofix i samma svep, samma rotorsak:** `logic_record_midi` mätte tagningens längd med hårdkodad 4 slag per takt på tre ställen medan verifieringsrendern precis under redan använde projektets riktiga taktart. I 3/4 var de alltså oense om var tagningen slutar, och den hårdkodade avgjorde vilket område tempot lästes för. Matematiken är nu en ren, enhetstestad funktion som tar taktarten som parameter (`MCPServer.takeEnd`).

`swift test`: 165 tester gröna (16 nya), 1,4 s, ingen Logic behövs.

### Stereo Out och masterkedjan: bankklampningen var den riktiga blockeraren (2026-08-27, v0.51.0)

Roadmap-punkt 2. Utgångshypotesen var att allt satt fast i EN vana: varje mixnings- och pluginverktyg inledde med AX `selectTrack(trackName:)`, som slår mot **spårhuvuden** i Tracks-området — och utgångar, auxar och bussar har inga spårhuvuden, så anropet kastade `trackNotFound` innan någon av kontrollplanen ens frågades. Det stämde, men det var inte hela sanningen. Den avgörande buggen låg i `findChannel` själv.

**Experiment mot körande Logic** (`Testlåt Copy.logicx`, pid 25052, brygga pid 24761, tillfälligt XCTest som togs bort efteråt). Strikt icke-skrivande mot projektdata: bara spegelläsningar, LCD-läsningar, banknavigering, vy-byten och MCU-kanal**val** — noll faders, noll vpots, noll mute/solo, noll parameterskrivningar, noll AX-skrivningar. Bankcachen säkerhetskopierades och lades tillbaka; vyn och det ursprungliga kanalvalet ('Bas', kanal 1, bank 0) återställdes och verifierades.

**Bankkartan (4 banker, 25 strippar):**

```
bank 0: LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg
bank 1: DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash
bank 2: Vinyl  Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out
bank 3: Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out Master
```

**Fynd 1 — den högraste banken KLAMPAR, och dubbelräkningen gjorde unika namn "tvetydiga".** Med 25 strippar (25 mod 8 = 1) visar sista banken de *sista* 8 stripparna, alltså föregående banks svans förskjuten ett steg. `findChannel` samlade träffar per (bank, kanal) över hela svepet, fick **två** träffar för `Stereo Out` och tolkade det som tvetydigt → `nil`. Samma sak för `Aux 1-3`, `Audio 8/9` och bussen `SP/1.3` — hela klampöverlappet. Live före/efter: `findChannel("Stereo Out")` = `nil` ("match count 2") → **kanal 7 på bank 2, 3,1 s**. `findChannel("Master")` fungerade redan *före* fixen (Master finns bara i sista banken, alltså en enda träff) — vilket är precis varför buggen kunde ligga och gömma sig. Fixen är en ren funktion: räkna ut klampens skift genom att matcha sista bankens huvud mot föregående banks svans (här skift 1) och kollapsa dubbletten till den *tidigaste* positionen (samma stripp, icke-klampad bank).

**Fynd 2 — subsekvensmatchningen accepterade celler som inte har med namnet att göra.** `lcdNameMatches` är avsiktligt generös för att återskapa Logics förkortningar (`Lofi Pad` → `LofPad`), men "ordnad subsekvens" betyder också att en förfrågan på `Stereo Out` matchar ett spår som bokstavligen heter `Set` (s-e-t förekommer i ordning). På ett projekt utan Stereo Out hade den falska träffen varit den ENDA — och skrivningen hade landat på `Set`. Tillägget är Logics eget beteende: **Logic fyller cellen till 6 tecken innan det börjar kasta tecken** (mätt över 21 strippar: `Acke Slagverk` → `AckSlg`, `Audio 8` → `Audio8`, `Stereo Out` → `St Out`; namn på ≤6 tecken målas helt, mellanslag och allt: `Inst 2`, `Aux 1`). En cell som är kortare än 6 kan därför inte vara en förkortning av ett längre namn. `Stereo Out` vs `Stereo Outro` löses inte av regeln — båda fyller cellen likadant — men utfallet blir `ambiguous` med cellerna namngivna, inte en slantsingling.

**Fynd 3 — Logic SUBSTITUERAR ibland ord i förkortningen, och då hjälper ingen subsekvensmatchning.** Spåret `Ivan Effect` visas som `IvanFx`: "Effect" blev "Fx", som inte är en subsekvens av namnet alls. Det spåret har alltså **aldrig** varit adresserbart via kontrollytan (befintlig lucka, ingen regression) och faller nu ut som `not_found` med de synliga stripparna listade — aldrig som fel stripp. Dokumenterat i ett test.

**Fynd 4 — MCU-val av en utgångsstripp beter sig exakt som ett spår.** SELECT-lysdioderna (not `0x18`+kanal) ekas av Logic: före experimentet lyste 25 (= kanal 1, 'Bas', vilket stämde med AX:ens valda spår 2 'Bas'); efter val av St Out lyste 31 ensam. PL-vyn för den valda utgången fylldes normalt: topp `Ins1Pl Ins2Pl …`, botten `Cha EQ Limitr Sensor -- …`. **Direkt efter ett val målar Logic en transient `Select`-banner ÖVER namncellen** — därför läses namnet FÖRE tryckningen och lysdioden EFTER; den nya `selectChannelVerified` gör precis så (LCD-namn + "bara den lysdioden lyser"), och det är den omvända varianten av fel-kanal-buggen från v0.31.0.

**Fynd 5 — insertordningen är OMVÄND mellan planen på Stereo Out.** AX-inspektorstrippen listade `1: Sensor, 2: Limiter, 3: Channel EQ`; MCU-slottarna läste `1: Cha EQ, 2: Limitr, 3: Sensor`. Den gamla noten ("MCU-slottar kan skilja sig från AX-ordinaler") är alltså mildare än verkligheten på masterstrippen. Översätt aldrig ett AX `insert_index` till ett MCU `insert_slot`.

**Fynd 6 — AX ser bara den stripp en inspektor visar; MCU ser alla.** `anyInspectorStrip("Stereo Out")` löste ut (den syns som valda spårets utgång), men `Master`, `Aux 1` och `Aux 2` gjorde det inte. Datavägen adresserar däremot varje stripp i projektet. Därav routningen: MCU först överallt, AX som reserv — och `logic_list_inserts`/`logic_survey_plugins` (rena AX-verktyg) får ett ärligt förbehåll i sina beskrivningar i stället för ett tyst nej.

**Fynd 7 — CS-volymvyn publicerar dB för masterstrippen.** Med bank 2 framme och volymvyn aktiv läste botten `-19,5  +0,0dB +0,0dB … +0,0dB` — cell 7 (St Out) = `+0,0dB`, parsad till 0,0 av `parseDb`. Återläsningshalvan av `logic_set_volume` fungerar alltså på masterkedjan. Sändvyn för St Out svarade med en **tom** lista (en utgång har inga sändningar) — inget fel, korrekt svar.

**Fynd 8 — masterfadern (spegelindex 8) går inte att identifiera genom läsning.** Index 8 ändrades inte vid bankbyte (som en dedikerad fader ska bete sig), men samtliga strippar på bank 2-3 stod på 12443 = +0,0 dB, precis som index 8 — så den kan inte skiljas från `Master`- eller `St Out`-strippens fader. Att avgöra det kräver en faderflytt, alltså en skrivning: medvetet inte gjort. (Sidofynd: 12443 ↔ +0,0 dB, och `Vinyl` på 5412 ↔ -19,5 dB.)

**Fynd 9 — `global_view` (not `0x33`) behövdes inte.** Svepet över fyra banker når varje stripp inklusive masterfaderkanalen, så en "stabilare utgångsbank" är inget adresseringsproblem. Knappen förblir otryckt av servern.

**Sidofynd om spegelns färskhetsvakt:** en **helt tyst Logic** (ingen kontrollytetrafik på >600 s) gör att `freshStatus()` returnerar nil, och då rapporterar HELA MCU-vägen "otillgänglig" — första körningen av proben fick exakt det, tio minuter efter användarens senaste interaktion. Det är också varför AX-reserven för huvudlösa strippar inte är hypotetisk: utan den kastar `logic_set_volume("Stereo Out")` `trackNotFound` i just det läget. En banktryckning väcker spegeln.

**Vad som ändrades i koden.** Ny `MCUBankMap.swift` (klampskift, dubblettkollaps, förkortningsrimlighet, `ChannelResolution`) och `StripAddressing.swift` (vilket plan som adresserar ett namn, och vad ett misslyckande på BÅDA planen säger). `findChannel` är nu ett tunt skal runt `resolveChannel`, som returnerar *varför* — så ett misslyckande blir `not_found` med båda planens vy, `ambiguous` med cellerna, eller `not_exposed` med skälet, i stället för ett omärkt `nil`. 15 namntagande verktyg routar via `selectStripTarget`; `selectedStripChild` (volym/pan/mute/solo:s AX-väg) går via `stripForControls`; pluginbläddrarens båda vägar valideras nu med `selectChannelVerified`; `logic_evaluate_change` metod `bounce` fick samma reservväg (masterkedjans A/B). Resultaten bär `selection_route` (`ax_track_header`/`mcu_channel`). AX-korsverifieringen efter en pluginskrivning kan nu vara **omöjlig** i stället för misslyckad på en huvudlös stripp (ingen inspektor visar den) — den degraderas till `cross_check: "unavailable"` plus en `warning` som säger exakt vad som inte kunde bekräftas oberoende, i stället för att fälla en lyckad skrivning.

**Overifierat, för ärlighetens skull:** **ingen skrivning på en huvudlös stripp har körts.** Volym, mute/solo, sändnivå, pluginparametrar, add/remove och `evaluate_change`-A/B:t på `Stereo Out` är implementerade, byggda och enhetstestade men aldrig utförda — sessionen fick inte skriva i användarens projekt. Nästa forskningssession bör göra det på ett kladdprojekt, i den ordningen: (1) `logic_mcu_set_plugin_parameter` på St Out:s Channel EQ med `expected_current_value` (billigast, rullar tillbaka), (2) `logic_set_volume` på St Out (verifierar att konvergensen landar där dB-återläsningen redan bevisats finnas), (3) `logic_add_plugin` på en aux som ingen inspektor visar — det är fallet där korsverifieringen saknas och varningen ska dyka upp. Dessutom oprövat: automation på huvudlösa strippar (`setAutomationMode` läser automationsläget ur *spårhuvudets* AX-etikett), och identiteten hos masterfader-index 8.

`swift test`: 189 tester gröna (24 nya), 1,4 s, ingen Logic behövs.
### Tempokartan läses ur Tempo List — och integreras exakt (2026-08-27, v0.51.0)

Roadmap-punkt 3. Punkt 1 gjorde matematiken ärlig; den här gör den **rätt**. All takt→sekunder-matematik gick genom EN primitiv på ETT tempovärde. Nu läses projektets hela tempokarta och integreras stycke för stycke.

**Live-experimentet (skrivskyddat mot körande Logic, `Testlåt Copy.logicx`, konstant 120 BPM, 4/4):**

- **Det finns ingen "Open Tempo List"-menypost.** Roadmapens antagande om ett flytande ⌥⇧T-fönster stämmer inte i Logic Pro 12.3.1: en fullständig genomgång av menyraden (djup 8) på "tempo"/"list"/"editor" gav bara `File > Project Settings > Smart Tempo…`, `Track > Global Tracks > Show Tempo Track`, `Window > Open Smart Tempo Editor` (grå), `Navigate > Open Marker List`, `Window > Open Event List`, `Window > Open Signature List` — och **`View > List Editors`**. Signature List har alltså en egen post medan Tempo List inte har det; listan nås via List Editors-panelen.
- **Vägen, verifierad:** `View > List Editors` (togglar en panel i huvudfönstret) → `AXRadioGroup` med FYRA flikar vars `AXDescription` är `Event` / `Marker` / `Tempo` / `Signature` (den aktiva bär `AXValue` "1"; enda action är `AXPress`) → tryck `Tempo` → `AXGroup` desc `Tempo` (bär även `Catch Playhead`, `Additional Info`, `Create new Tempo Event`, en `Tempo Set:`-popup som visade `Untitled`, och `Number of Items`) → `AXScrollArea` → `AXTable`. Fliken och gruppen ligger på **fönsterdjup 2** — panelen är ett direkt barn till projektfönstret, inte begravd under arrangörens wrappers; tabellen 3 nivåer under gruppen, `Number of Items` 1 nivå under.
- **Radgrammatiken:** tabellen har tre kolumner (huvudradens knapptitlar: `Position`, `Tempo`, `SMPTE Position`). Varje `AXRow` har tre `AXCell`, och texten ligger på cellens barn-`AXGroup`s **`AXDescription`**, inte på något `AXValue`: `"1 1 1 1 "` (takt/slag/division/tick, allt ettbaserat), `"120,0000"` — **decimalkomma**, systemets locale, så parsern tar både komma och punkt — och `"01:00:00:00.00"`. Under grupperna finns per-siffra-`AXSlider`ar (`Segment 0…n`) som en andra läsväg om `AXDescription` någon gång tystnar.
- **`Additional Info` ger INGA extra kolumner.** Kryssrutan togglades på och av (enda UI-mutationen i experimentet utöver panelen och fliken, återställd) — kolumnuppsättningen förblev Position/Tempo/SMPTE Position. **Tempokurvor är alltså inte urskiljbara i Tempo List.** Roadmapens öppna fråga är därmed besvarad, och svaret är "ingen av de två alternativen": varken ändpunkter-plus-kurvflagga eller förtätade rader — kurvinformationen finns inte i listan alls.
- **Kostnad och beteende:** `readTempoMap()` kostade **2,03 s** och flyttade **ingen playhead**. Panelen stängdes igen (bara om anropet öppnade den), fliken återställdes till `Event`, fönsterantalet oförändrat 1. Två anrop i rad gav samma karta. Serverpathen med cache: **kall 2,04 s, varm 0,003 s**. Takt 5–9 gav exakt **8,000 s** — samma tal som 120 BPM-kalibreringen 2026-08-25 (FINDINGS:634), nu genom den nya integrationen.

**`TempoMap` (ren, enhetstestad).** Tempohändelser på (takt, slag) med **steg**- och **linjära rampsegment**; `seconds(atBeatOffset:beatsPerBar:)` integrerar stycke för stycke. Ramperna räknas med den **exakta integralen** — är BPM linjär i slag är ∫60/BPM d(slag) = (60/k)·ln(b₁/b₀), en logaritm, inte en subdivision (ett test jämför mot en 20 000-stegs mittpunktsregel för att bevisa att den slutna formen är rätt sluten form). Enhändelsekartan går genom den gamla konstantformeln **ordagrant, operationsordningen inkluderad** — `(takt−1)·(slag·60/BPM)`, inte `((takt−1)·slag)·60/BPM`: de skiljer sig i Doubles sista bit för vissa tempon, och konstant tempo är normalfallet. Ett test kör 120 kombinationer av tempo/taktart/taktintervall mot `MCPServer.barRangeSeconds` med exakt likhet.

**Ärlighet i det som INTE går att veta.** Tre saker, alla namngivna i resultaten i stället för dolda:

1. **Kurvor läses som steg.** `curveUncertaintySeconds` räknar skillnaden mellan att integrera varje intilliggande par som steg och som ramp — den maximala förskjutning en oläsbar kurva kan orsaka — och varningen anger den i millisekunder. Noll när kartan är konstant eller när alla avvikande par ligger efter intervallets slut; **inte** noll bara för att ingen tempoändring ligger mellan intervallets egna takter, eftersom gränserna mäts från projektstart och en kurva tidigare i låten förskjuter allt efter sig.
2. **Trunkering.** En AX-tabell i en scroll area kan publicera bara de rader den realiserat, och en karta som saknar sina sena händelser skulle integreras *självsäkert fel*. Därför korskontrolleras radantalet mot listans egen `Number of Items` ("1 Event" / "54 Events") — vid avvikelse **kastas kartan** och anroparen faller tillbaka på tvåpunktssamplingen. Att listan verkligen publicerar alla rader i en lång karta är overifierat (testprojektet har en enda händelse); korskontrollen finns just därför.
3. **Sub-beat-positioner** (division/tick > 1) konverteras med Logics defaultvärden (1/16-division, 960 ppq) — projektinställningar servern inte läser. Punkter på slaget är exakta oavsett; en karta med punkter utanför slaget flaggas i varningen.

**Vad som ändrades i beteendet.** `barRangeSeconds` tar en karta och integrerar den när den är LÄST (`source == .tempoList`; en `.singleReading`-karta är antagandet i typens kläder och tar den gamla vägen). `TempoKnowledge` avgör per anrop vad man vet: **läsbar karta ⇒ ingen sampling alls** (playheaden rörs inte, och en konstant läst karta ger ingen varning över huvud taget, eftersom det inte finns något förbehåll att bära), **oläsbar karta ⇒ exakt det beteende som shippade i går**, inklusive vägrandena. Konkret:

- `logic_evaluate_change` metod `render` **vägrar inte längre på en läsbar karta** — båda slicerna integreras över samma karta, täcker samma takter, och A/B:t är giltigt. Vägran gäller nu bara när Tempo List inte kunde läsas OCH samplingen ser en avvikelse; skälet namnger vilket av de två som gäller.
- `logic_record_midi` räknar varje events ms-offset som integralen från tagningens första taktlinje. `speed > 1` vägras fortfarande på icke-konstant tempo (kartan berättar tagningens timing, inte hur en slider-skrivning tas tillbaka). Cachen invalideras efter en inspelning vars Smart Tempo-läge inte var verifierbart Keep — Adapt skriver om kartan bakom oss.
- `logic_set_tempo` vägrar nu på kartbevis i stället för på två sampel när listan går att läsa, vilket tar bort upp till 14 s playhead-resa från ett anrop som ändå slutar i en vägran.
- `logic_record_automation`: punktplacering, förrullningstaktens längd (den taktens EGNA längd) och konvergensbudgetarna integrerar kartan; varje schemapost bär sitt eget ms-per-slag så rampexpansionen förblir musikalisk efter att takt/slag kastats. Den taktbaserade playhead-jaktverifieringen är oförändrad — den är beviset.
- Cache per projekt (`tempo-map-cache.json`) med samma scope-disciplin som bank-cachen (build + projektsökväg); bara LYCKADE läsningar cachas, aldrig ett misslyckande — "kunde inte läsas" får aldrig bli "projektet har ingen karta".

**Cachens riktiga risk var inte våra egna skrivningar** (de invalideras explicit) utan **användaren som redigerar tempospåret mellan två verktygsanrop** — en gammal karta hade integrerat självsäkert fel gränser. Därför valideras varje cache-träff mot kontrollradens tempo, som publiceras GRATIS (ingen playhead-förflyttning, inget fönster): `TempoMap.couldProduceTempo` frågar "kan den här kartan alls ge det här tempot?" — taktartsfritt med flit, så ingen oläst taktart kan lura den — och ett tempo kartan inte kan förklara kastar cachen. Den fångar ett ÄNDRAT tempovärde; den kan inte fånga en ny nod vars tempo råkar vara identiskt med en befintlig, eller en nod som flyttats till en annan takt. Det står i koden, och det är avsiktligt: samma sensor som punkt 1 använde för att UPPTÄCKA en karta används här för att VALIDERA en.

`swift test`: 201 tester gröna (36 nya), 1,4 s, ingen Logic behövs. `swift build -c release` grön.

**Kvar som antagande:** **taktarten**. Signaturändringar bor i sin egen lista (Signature-fliken i samma List Editors, och den HAR en egen menypost) och läses inte — all takt→slag-omräkning använder fortfarande ett enda slag-per-takt. Det är nu det enda kvarvarande antagandet i bar-matematiken, och det är dokumenterat i `TempoMap` och i AGENT-GUIDE.

**Overifierat, för ärlighetens skull:** allt om FLERA rader och om kurvor. Testprojektet har en enda tempohändelse, och att bygga en karta hade betytt att skriva i användarens projekt. Radgrammatiken är alltså verifierad för en rad; parsningen av flera rader, integrationen över steg och ramper, trunkeringskontrollen och varningstexterna är enhetstestade. Kurvor kan inte läsas alls (se ovan). Att `readTempoMap` beter sig när Logic rullar är overifierat — panelen togglades bara i stillastående transport.

### Pluginpresets: fel popup lästes, och menyn går att räkna upp helt (2026-08-27, v0.52.0)

Roadmap-punkt 4. Frågan var om pluginfönstrets **inställningsmeny** går att räkna upp via Accessibility, som Bounce-menyn gör. Svaret är ja — men experimentet hittade först en bugg i den kod som redan fanns.

**Miljö:** körande Logic (`Testlåt Copy.logicx`, pid 25052), tillfälligt XCTest som togs bort efteråt, `logician`-binären startades aldrig (dubbla virtuella MIDI-portar orphanar tyst alla key command-bindningar, se v0.45.0). Bryggan frågades inte alls: hela punkten ligger i AX-planet.

**Fynd 1 — `AXShowMenu` finns INTE på presetpopupen, `AXPress` gör det.** Första försöket gjorde precis vad roadmapen föreslog: `AXShowMenu` på elementet. Svaret var `AXError -25206` (*action unsupported*) och ingen meny. Elementets hela aktionsmängd är `["AXPress"]`. Ett tryck öppnade menyn direkt — och rapporterade `AXError -25204` medan det gjorde det, exakt som pluginväljaren i insertsslotten (v0.31.0). Statuskoden får alltså aldrig avgöra om menyn öppnades; närvaron av menyn gör det. Menyn hittas av den befintliga `popupMenus()` (djup 2 under applikationselementet).

**Fynd 2 — och det viktiga: `pluginPresetLabel` läste FEL popup på flera Logic-plugins.** Den gamla regeln var "den högraste `AXPopUpButton` i headern som bär ett värde". I pluginfönstrets header sitter det tre sorters popup, och de går bara att skilja på sin *aktionsmängd*:

| kontroll | roll | aktioner | textattribut |
|---|---|---|---|
| inställningspopupen (presetnamnet) | `AXPopUpButton` | `AXPress` | 6 av 6 |
| View/zoom-menyn | `AXMenuButton` | `AXShowMenu`, `AXPress` | 0 |
| en PARAMETER-popup | `AXPopUpButton` | `AXShowMenu`, `AXPress` | 0 |

Mätt på fem plugins. På `Compressor` låg inställningspopupen sist och den gamla regeln råkade träffa rätt. På `Channel EQ` låg den **först**, och den gamla regeln returnerade stereoläget (`Stereo`); på `Limiter` algoritmen (`Precision`); på `Pitch Shifter` läget (`Vocals`). De värdena rör sig inte när presetet byts — så `logic_plugin_preset`s stegverifiering rapporterade `stepped: false` på ett steg som faktiskt fungerade, på tre av de fem plugins vi tittade på. Ny regel: **den `AXPopUpButton` vars aktionsmängd är exakt `["AXPress"]`**. Att inställningspopupen dessutom är den enda som publicerar textfältsattribut (`AXSelectedText`, `AXNumberOfCharacters`, `AXPlaceholderValue`, `AXSelectedTextRange`, `AXInsertionPointLineNumber`, `AXVisibleCharacterRange`) och saknar `AXHelp` är stödjande bevis, inte nödvändigt.

**Fynd 3 — menyns form är identisk i varje plugin: ett FAST kommandoblock på 20 poster, sedan inställningarna.**

```
[0]  "Setting"    (disabled, rubrik)      [10] "Paste"
[1]  ""           (separator)             [11] ""
[2]  "Undo"                               [12] "Load…"
[3]  "Redo"                               [13] "Save"
[4]  "Include Plug-in Undo Steps in       [14] "Save As…"
      Project Undo History"               [15] "Save A Copy As…"
[5]  ""                                   [16] "Save As Default"
[6]  "Next"                               [17] "Recall Default"
[7]  "Previous"                           [18] "Delete"
[8]  ""                                   [19] ""
[9]  "Copy"                               [20…] INSTÄLLNINGARNA
```

Bekräftat post för post på `Compressor`, `Channel EQ`, `Limiter`, `Sensor`, `PShft` och tredjeparts-`Trilian`. Efter [19] kommer antingen **kategorier** (undermenyer) eller **platta** poster, aldrig blandat, och aldrig djupare än en nivå:

- `Compressor` (spår `Bas`): 6 kategorier / **156** inställningar (`01 Drums` 22, `02 Keyboards` 9, `03 Guitars` 25, `04 Voice` 32, `05 Compressor Tools` 18, `06 Compressor By Type` 50).
- `Channel EQ` (**`Stereo Out`**): 7 kategorier / **114** (`01 Drums` 25 … `07 EQ Tools` 18).
- `Limiter` (`Stereo Out`): **11 platta** poster, ingen kategori (`Classic Soft Knee` … `Warm Master`).
- `Sensor` (`Stereo Out`) och `Trilian` (`Bas`): **ingenting** efter [19]. Det är ett riktigt svar, inte ett fel — pluginet levererar inga fabriksinställningar, och `Load…` är enda vägen in.

Gränsen mellan kommandon och inställningar bestäms av två regler i ordning: `Delete` är sista kommandot i varje observerad meny (exakt ankare, tål att Logic lägger till ett kommando i blocket), och som reserv den strukturella regeln att kommandoblocket är den enda del av menyn som innehåller separatorer, alltså slutar blocket vid den **sista** separatorn. Båda ger samma svar på alla sex menyer.

**Fynd 4 — `AXMenuItemMarkChar` FINNS, och den är hela spåret till aktiv inställning.** Den laddade posten bär `✓` på sitt löv, och dess kategori bär `-`. På `Compressor` blev det `03 Guitars[-]` → `FET Electric Bass[✓]`. Att läsa kategorins märke som "aktiv" hade rapporterat `03 Guitars` som den laddade inställningen, vilket inte är en inställning; bara lövets märke räknas. När headern visar `Default Preset` (Channel EQ, Limiter) är **ingenting** märkt — vilket är korrekt, för det tillståndet är ingen namngiven inställning, och `current_preset_marked` blir `null`.

**Fynd 5 — `AXPress` på ett löv FUNGERAR här, till skillnad från i pluginväljaren.** v0.31.0 slog fast att `AXPress` på poster inne i *stängda* undermenyer är en tyst nolloperation i Logics pluginväljare, och därför drivs den med riktiga musrörelser. Inställningsmenyn materialiserar sina undermenyers barn direkt — lövet är ett riktigt element utan att någon hovrat fram undermenyn — och `AXPress` på `03 Guitars > Rock Bass` returnerade `.success` med headeretiketten som följde efter. Ingen mus behövs, alltså ingen pekarövertagning.

**Fynd 6 — och det obehagliga: ett presetnamn är INTE ett löfte om tillståndet.** Rundturen (steg bort, steg tillbaka, allt verifierat) kördes på spårets `Compressor` med Logics egen Compare-knapp som vakt: den var `AXEnabled='0'`, vilket är dess "orört"-läge. Etiketten gick `FET Electric Bass` → `Rock Bass` → `FET Electric Bass`, och **tio av elva** parametrar kom tillbaka på exakt sina utgångsvärden. Den elfte, `Output Gain`, stod på råvärde **54** före och **60** efter — fabriksvärdet. Utgångstillståndet var alltså `FET Electric Bass` *med en avvikelse ovanpå*, och Compare-knappen sa inget om det: den är sessionsbunden, inte en jämförelse mot det sparade tillståndet över tid. Slutsatsen står i produktkoden som `presetOverwriteWarning` och följer med VARJE presetändring, `step` inkluderat: att ladda en inställning skriver över samtliga parametrar, och att välja tillbaka det gamla namnet återställer inte en onämnd justering. Vägen tillbaka är pluginfönstrets egen `Setting ▸ Undo`.

**Fynd 7 — masterkedjan fungerar, med item 2:s förbehåll.** `Stereo Out` går hela vägen: `selectStripTarget` → `openPlugin` → inställningspopupen → 114 uppräknade inställningar på Channel EQ. Men menyn sitter i pluginfönstret, som är ett AX-objekt, så samma asymmetri som i v0.51.0 gäller: en huvudlös stripp måste **visas i en inspektor** för att fönstret ska gå att öppna. `Stereo Out` syntes som valda spårets utgång; `Master` och `Aux 1` gör det inte utan att man öppnar Mixern.

**Fynd 8 — MCU-vägen är fortfarande inte funnen, och letades inte efter med skrivningar.** Ingen observation av en kontrollytevy som listar presets finns; att leta efter en hade krävt vpot-tryck inne i en plugin-EDIT-vy, vilket är parameterskrivningar. Punkten avgörs alltså av AX-vägen, precis som roadmapen gissade. Sidoobservation som kan bli en genväg: menyn har egna `Next`/`Previous`-poster (index 6 och 7), så relativ stegning finns i AX-planet också och skulle inte behöva ett inlärt key command — otestat, och `step` lämnades oförändrat.

**Vad som ändrades i koden.** `PluginPresets.swift` (rent: kommandoblockets gräns, plattning, namnmatchning, varningstexterna) och `AXPresets.swift` (`presetPopUpButton`, den omskrivna `pluginPresetLabel`, `readPresetMenu`, `pressPresetMenuItem` — menyn stängs alltid, även på kast, för en öppen meny sväljer Logics tangentbord och nästa verktygs key command med det). `logic_plugin_preset` fick `action` (`list`/`select`/`step`) och `name`; standardvärdet är `step`, eller `select` när `name` finns, så varje anrop som fungerade före v2 betyder exakt samma sak. Verktyget bär nu också `selection_route` från item 2:s routning, vilket det tidigare kastade bort. Nya felkoder: `presetNotFound` (not_found, med namnen listade och kapade) och `presetAmbiguous` (ambiguous, med `Kategori/Namn`-vägarna). Matchningen är medvetet **inte** luddig: en nära miss vägras, för ett felaktigt laddat preset skriver över hela pluginet.

**Overifierat, för ärlighetens skull:** `action: "select"` är live-bevisad på `Compressor` på ett SPÅR (tryck + etikettverifiering + återställning), men **aldrig körd på en huvudlös stripp** — `Stereo Out`-vägen är bevisad till och med uppräkningen (`list`), inte förbi den. `list` på ett plugin utan inställningspopup (`presets: null`-grenen) är enhetstestad men inte live-sedd; alla fem plugins vi öppnade hade en popup, även `Trilian`. Och den nya popupregeln är mätt på fem plugins — ett plugin som publicerar `AXShowMenu` även på sin inställningspopup skulle få `null` i stället för ett fel värde, vilket är rätt riktning men inte samma sak som täckning.

**Kvar att städa i användarens projekt:** rundturen i fynd 6 lämnade `Bas` → `Compressor` (insert 1) med `Output Gain` på råvärde 60 i stället för 54. Återställningen kunde inte köras (behörighetsspärr i sessionen). Fixen är pluginfönstrets `Setting ▸ Undo` två gånger, eller att skruva `Output Gain` tillbaka; projektet är osparat, så ingenting har nått disken.

`swift test`: 220 tester gröna (31 nya), 1,4 s, ingen Logic behövs.

### Skrivrundan mot masterkedjan: teckenbortfallet, den låsta pressen, och en AX-krasch som avbröt tempodelen (2026-08-28, v0.53.0)

Den här sessionen körde de skrivningar som roadmap-punkterna 2, 3 och 4 shippat men aldrig utfört. Fyra buggar föll ut, tre av dem farliga, och sessionen slutade i förtid när **macOS hjälpmedelslager degraderade systemomfattande** — inte av Logic, och inte av oss.

**Miljö:** körande Logic Pro 12.3.1 (`Testlåt Copy.logicx`, pid 25052 — en sandlådekopia som användaren uttryckligen godkänt skrivningar i), användarens bryggdaemon pid 24761 (protokoll 3, **aldrig omstartad**), tillfälliga XCTest-harness som togs bort efteråt. Ingen `logician --bridge` startades, projektet sparades aldrig, allt ligger osparat i minnet. Varje skrivning föregicks av kontrollen att projektsökvägen innehåller "Copy".

#### Fynd 1 — den högraste strippens minustecken hamnar i grannens LCD-cell

Det första `logic_set_volume("Stereo Out", -2 dB)` gick från +0,0 dB till **+6,0 dB**, alltså rakt upp i fadertoppen, och svarade `success: true, verified: false`. Bryggans egen diagnostik: **62 iterationer, slutratio -3,29 (negativ)**.

Orsaken mättes fram genom att vrida en vpot åtta steg ned på kanal 1, 3, 5 och 7 i samma bank och läsa hela raden:

```
ch 5: |-19,5  +0,0 dB                     -1,7 dB              |
ch 7: |-19,5  +0,0 dB                                  -1,7 dB |
                                              cell 6 ^^ cell 7
```

När en vpot vrids byter Logic ut flerkanalsraden mot en enkanalsbanner och målar den berörda strippens värde som en **ÅTTA tecken bred grupp** — värdet plus dess efterföljande blanksteg — vänsterställd i strippens egen cell. På den högraste cellen skulle gruppen gå ett tecken förbi radens 56, så Logic börjar ett tecken TIDIGARE, och tecknet hamnar i cell 6:s sista kolumn. Bara kanal 7 skiftar; 1, 3 och 5 ligger exakt i sina celler.

En strikt 7-teckens skivning läste alltså `-1,7 dB` som `1,7 dB` — magnituden utan sitt tecken, vilket är **värre än ett oläsbart värde**: konvergensen läste sitt eget steg nedåt som ett steg uppåt, inverterade sin adaptiva tickratio och gick till ändläget medan den rapporterade framgång. Bara negativa värden korrumperas; ett `+` som faller bort parsas ändå rätt.

Buggen är INTE masterspecifik. Den träffar **vilken stripp som helst som råkar ligga på kanal 7 i sin bank** — på det här projektet är det `IvnSlg` (bank 0), `Crash` (bank 1), `St Out` (bank 2) och `Master` (bank 3) — och den har legat där sedan konvergensen shippade. Att de sju tidigare volymanropen (v0.49.2) fungerade betyder bara att ingen av dem låg på kanal 7 med ett negativt mål.

Fixen är en delad ren funktion, `MCULCDRow`, som BÅDA planen importerar: `cell` är den bokstavliga skivningen (namn läses så), `valueCell` återvinner det skiftade tecknet på sista cellen — på positiva belägg bara, eftersom teckenkolumnen tillhör cell 6 och ett cell 6-värde som slutar på `+`/`-` aldrig observerats, medan streckplaceholdern som skulle kunna förväxlas med ett tecken sitter sex kolumner till vänster. Alla eko som en skrivning konvergeras eller verifieras mot går nu genom den: daemonens in-process-konvergens, `setVolume`s dB-återläsning, plugin- och instrumentparametersidorna och sändnivån.

Daemonen som äger socketen kan vara äldre än fixen, så `bridgeProtocolVersion` går till **4** och `fastConverge` **avböjer den högraste cellen** mot en äldre daemon — anroparna äger alla en egen långsammare loop som läser via `lcdValueFields`, så ett avböjande betyder "gör det här", inte "ge upp". Det är också vad som gjorde fixen live-verifierbar i den här sessionen utan att röra användarens daemon.

**Live efter fixen:** `Stereo Out` +0,0 → -3,7 → +0,0 dB, `verified: true` båda vägarna, fadern tillbaka på exakt 12443. 6,8 s per anrop via serverloopen (mot ~3 s för bryggans, som återfår sin roll när daemonen är protokoll 4).

#### Fynd 2 — `Master` och `Stereo Out` är två olika objekt, och spegelfader 8 är `Master`

Roadmapens experiment (c), som v0.51.0 lämnade *inconclusive* eftersom varje stripp stod på 12443 och alltså inte gick att skilja åt genom läsning. En faderflytt avgjorde det:

Spegelindex 8 skrevs 12443 → 11543 (Logic ekade 11527 — faderupplösningen kvantiserar). På `St Out`-banken rörde sig **bara index 8**; `St Out`s egen stripfader (index 7) stod stilla. Ett banksteg till höger, där `Master` ligger på kanal 7 och `St Out` på 6, visade **index 7 = 11527**. Alltså:

> **MCU:ns dedikerade masterfader (spegelindex 8) är Logics `Master`-stripp, inte `Stereo Out`.** De är skilda objekt, och index 8 speglar `Master`-strippens fader var den än råkar ligga i en bank.

Återställt till 12443 och verifierat på båda bankerna.

#### Fynd 3 — en fader kan inte skrivas absolut; Logic ignorerar positionen utan touch

Sidofynd med en kostnad. Bryggans `fader`-kommando skickar pitch bend utan att först skicka faderns touch-not, och **Logic följer inte**. Värre: spegeln rapporterar kortvarigt det skrivna värdet (vårt eget meddelande), så en läsning direkt efteråt ser ut som en lyckad återställning innan Logic ekar tillbaka sitt riktiga värde. Tre strippar (`Audio 8`, `Aux 1`, `Aux 3`) troddes därför återställda i ett tidigt probe och var det inte — se städlistan. Vpot-vägen i CS-volymvyn fungerar; faderskrivningen gör det inte. **Inte fixad** (den kräver touch/untouch-noterna och ett eget verifieringspass) — se roadmapen.

#### Fynd 4 — mute och pluginparameter på masterkedjan fungerar rakt av

- `logic_set_track_mute("Stereo Out")` på → LED not 23 tänd → av → släckt. `route: mcu`, `readback_route: mcu_channel_led`. Återställd.
- `logic_mcu_set_plugin_parameter` på `Stereo Out` → MCU-slot 1 (`Cha EQ`) → `Pea3Ga` 0,0 dB → **-2,1 dB** på 17,9 s, LCD-eko-verifierat, `selection_route: mcu_channel`, `mcu_strip: 8`. Återställd till 0,0 dB.
- Channel EQ på `Stereo Out` räknar upp **6 sidor / 42 parametrar** över MCU.

#### Fynd 5 — masterkedjans A/B går inte, och skälet är inte adresseringen

`logic_evaluate_change` metod `bounce` föll på `parameterNotFound("Peak 3 Gain")` — **efter** att baseline-bouncen redan kört. Roten är att ett pluginfönster **LÄSES genom sina sliders och SKRIVS genom sina redigerbara fält**, och de två mängderna är inte samma plugin till plugin:

| plugin | AXSlider | AXTextField |
|---|---|---|
| `Compressor` (spår `Bas`) | 22 | **10** |
| `Channel EQ` (`Stereo Out`) | 26 | **0** |
| `Limiter` (`Stereo Out`) | 4 | **0** |
| `Sensor` (`Stereo Out`) | 0 | **0** |
| `Trilian` (`Bas`) | 0 | 0 |

Apples äldre effekter bygger på "knob and field"-kontroller och publicerar båda; ett rent rattbaserat plugin publicerar sliders och **inget fält alls**. Referensprojektets HELA masterkedja är rattbaserad, alltså oskrivbar från AX-planet — medan `logic_list_plugin_parameters` rapporterade var och en som `writable: true`, för den läste **sliderns** skrivbarhet för en skrivning som går genom ett fält som inte finns.

Tre ändringar: `listParameters` svarar nu per parameter på den fråga anroparen faktiskt ställer (`ax_writable`); `setParameter` skiljer "ingen sådan parameter" från "det här pluginet har inga skrivbara parametrar alls" — olika åtgärder, och den andra namnger kontrollytevägen som fungerar; och `evaluateChangeBounced` slår upp fältet **före** sin baseline-bounce. 9,7 s plus en herrelös ljudfil blev 1,1 s och en vägran.

Punkt 2:s steg 4 ("mix bus compressor A/B faller ut för fritt") är alltså **fortfarande inte körd**, men skälet är nu känt och namngivet: A/B:t behöver ett plugin med redigerbara fält på strippen. Att lägga dit en `Compressor` för ändamålet försöktes och avbröts — se fynd 6.

#### Fynd 6 — PL-vyn kan visa en annan stripp än SELECT-lysdioden säger

Det farligaste fyndet. `logic_add_plugin("Stereo Out", "Compressor")` misslyckades ("bläddraren visade aldrig Compressor på 500 steg"), och efteråt läste PL-raden `Cha EQ | *PShft | Cha EQ | Comprs` — vilket är spåret **`Bas`**, inte `Stereo Out` (vars PL är `Cha EQ | Limitr | Sensor`). Samtidigt lyste SELECT-lysdioden på stripp 8, bekräftat på TVÅ banker (kanal 7 på bank 2, kanal 6 på bank 3 — samma stripp), och AX bekräftade att `Stereo Out`s insert-lista var orörd.

Alltså: **båda de bevis `selectChannelVerified` tar — LCD-namnet före tryckningen och SELECT-lysdioden efter — kan vara rätt medan PL-vyn redigerar en annan stripp.** Ett SELECT-tryck på en stripp vars lysdiod REDAN lyser är en nolloperation, så ett omval kan inte laga det; att välja en granne och komma tillbaka kan (verifierat: `Vinyl` → `Stereo Out` gav rätt lista igen). En bläddrarskrivning i det läget hade landat i `Bas`. Det är fel-kanal-buggen från v0.31.0 igen, förbi båda de befintliga vakterna.

**Mekanismen är inte reproducerad.** Två riktade försök misslyckades med att framkalla tillståndet (AX-spårval av ett annat spår, och ett AX-pluginfönster öppnat på ett annat spår, gav båda rätt PL-vy). Det som är BEVISAT är att tillståndet uppstår och att det inte syns i de bevis vi tar.

Därför tar de två bläddrarskrivningarna nu ett **tredje, oberoende bevis** innan de bläddrar: listan ytan visar måste stämma med den Accessibility läser på samma stripp. Slot-ORDNINGEN jämförs medvetet inte (en utgångsstripp vänder på den, v0.51.0 fynd 5) — bara multimängden av upptagna namn, där varje MCU-cell ska vara en rimlig förkortning av något AX-namn. En stripp ingen inspektor visar svarar med ingenting, och en fråga som inte går att ställa får aldrig fälla en fungerande operation: den degraderar till `pl_view_check: "unavailable"`.

#### Fynd 7 — `select` på en huvudlös stripp, och vägen tillbaka som aldrig testats

Punkt 4:s flaggade hål. Körd på `Stereo Out`s **`Limiter`** i stället för Channel EQ, medvetet: den har fyra parametrar i stället för 26, alltså ett tillstånd som går att kontrollera och lägga tillbaka.

- `list` gav **114** inställningar på Channel EQ och **11** på Limiter, båda på `Stereo Out` — samma siffror som 2026-08-27.
- `select "Warm Master"`: `Default Preset` → `Warm Master`, `verified: true`, `selection_route: mcu_channel`. Fyra av åtta MCU-parametrar flyttade sig verkligen: `Gain` 0,0 → +12,0 dB, `Lookha` 5,0 → 0,5 ms, `OutLev` -0,0 → -0,1 dB, `Rel` 250,0 → 6,0 ms.
- **`Setting ▸ Undo` återställde ALLA ÅTTA exakt**, etiketten inkluderad — tillbaka till det ONAMNGIVNA `Default Preset`-tillstånd som inget `select` kunde ha återskapat.

Den sista raden stängde 2026-08-27:s öppna fråga, så den blev en funktion: `logic_plugin_preset` har nu `action: "undo"`. Den rapporterar `verified: false` med flit — etiketten är belägg, inte bevis: en undo mellan två onamngivna tillstånd lämnar den oförändrad medan parametrarna rör sig, så noten säger att läsa tillbaka parametrarna när tillståndet spelar roll i stället för att avge en dom på headern.

#### Fynd 8 — pressen som öppnar inställningsmenyn svaldes, och `ensureLogicFrontmost` kan inte se det

Två `list`-anrop i rad på `Stereo Out`s Channel EQ misslyckades med "menyn öppnades inte" medan terminalen låg i förgrunden; varje anrop EFTER ett första lyckat — samma plugin, samma fönster — öppnade på FÖRSTA pollningen. Att vänta längre hjälpte aldrig (3,75 s räckte inte två gånger) eftersom pressen aldrig kom fram: `ensureLogicFrontmost` returnerar så snart APPLIKATIONEN är frontmost, vilket inte säger något om vilket av Logics fönster som har fokus, och en press på en kontroll i ett ofokuserat fönster sväljs. Pluginfönstret höjs och fokuseras nu före pressen, och pressen görs om i upp till tre försök med den befintliga menyavvisningen emellan, så en press som FAKTISKT fungerade men pollades för tidigt inte stängs igen av omförsöket.

#### Fynd 9 — `readTempoMap` läste fel fönster

`readTempoMap` tog `logicWindows().first`. Med ett pluginfönster öppet var det pluginfönstret, och läsningen kom tillbaka `tempoTabNotFound` medan en fullt läsbar Tempo List satt ett fönster bort — varpå anroparen tyst föll tillbaka på att parka playheaden för en tvåpunktssampling (upp till 14 s). Varje pluginverktyg lämnar ett fönster öppet tillräckligt länge för att det ska hända. Använder nu `projectWindow()`.

#### Fynd 10 — Tempo List: knappen, positionen, och att sub-beat-antagandet stämmer

Punkt 3:s flerradsgrammatik. Med playheaden parkerad på takt 9:

- **`Create new Tempo Event` lägger händelsen på PLAYHEADEN**, inte på närmaste taktlinje. Den nya raden blev `9 1 4 201` — och kontrollradens playhead-läsning sa "takt 9, slag 1". Alltså: **`setPlayhead` landar INOM slaget, inte på det**, och kontrollraden visar bara takt/slag, så avvikelsen är osynlig därifrån. En takt-9-parkering låg i verkligheten 0,96 slag in i takten.
- **Flerradsgrammatiken parsas live.** `readTempoMap()` gav två händelser: `bar 1, beat 1, 120` och `bar 9, beat 1.9583, 120`, `source: .tempoList`, `subBeatPositions: true`, och `Number of Items` gick från `1 Event` till `2 Events` — så korskontrollen mot radantalet fungerar också med fler än en rad.
- **Sub-beat-konverteringen är BEKRÄFTAD mot Logics egen SMPTE-kolumn**, inte längre ett antagande. `9 1 4 201` ⇒ 0,75 + 200/960 = 0,9583 slag = 0,4792 s vid 120 BPM = 11,98 bildrutor vid 25 fps ⇒ `01:00:16:11.78` (Logic skriver underbildrutor i 1/80). Observerat: exakt `01:00:16:11.78`. Efter ett steg till division 3: 0,7083 slag ⇒ `01:00:16:08.68`, observerat `01:00:16:08.68`. **1/16-division och 960 ppq stämmer**, och bildfrekvensen i den här kolumnen är 25 fps. Punkt 3:s tredje ärlighetsförbehåll är därmed inlöst för default-inställningarna.
- **Positionsfältens `AXSlider`ar är STEGARE, inte fält.** En `AXUIElementSetAttributeValue` med vilket värde som helst flyttar ett steg (tick 201 → 200, tempo 120 → 121); aktionsmängden är `["AXIncrement", "AXDecrement"]`. Det finns alltså ingen absolut skrivning av en position eller ett tempo den här vägen — bara stegning.
- **Raden bär en `Delete`-aktion** (`"Name:Delete\nTarget:0x0\nSelector:(null)"`) och `AXSelected` är skrivbar, så borttagning av en tempohändelse har en AX-väg. Den hann aldrig köras — se nedan.

#### Fynd 11 — och sedan slutade macOS hjälpmedelslager fungera, systemomfattande

Mitt i tempoarbetet började varje AX-anrop komma tillbaka fel: Logics `AXWindows` returnerade **applikationselementet självt, två gånger** (`AXRole` = `AXApplication`, `AXPosition`/`AXSize`/`AXMain` = `AXError -25205`), `AXChildren` gav `[app, app, menubar]`, och `projectWindow()` hittade ingenting.

Logic var **inte** trasigt: bryggan svarade hela tiden, ett `bank_right` följt av `bank_left` ekades korrekt av Logic, och processen låg på normala 13 % CPU. Och felet var inte Logic-specifikt — samma probe mot andra processer gav `Finder` med fönsterroll `AXScrollArea` och `Terminal` med `AXApplication`. **Hela maskinens hjälpmedelsträd hade degraderat.** Varken `activate()`, hide/unhide, `AXEnhancedUserInterface`-växling eller att väcka skärmen tog tillbaka det; boten är sannolikt en utloggning eller en omstart av systemets hjälpmedelstjänst, vilket är användarens beslut och inget en agent ska göra.

Det är i sig ett arkitektoniskt argument som är värt att skriva ned: **datavägen överlevde det AX-vägen inte gjorde.** Volym, mute, pluginparametrar och bankscanning gick att köra vidare på MCU-planet efteråt; allt AX-buret — Tempo List, pluginfönster, presetmenyn — var borta.

#### Vad som blev kvar i användarens projekt (osparat, inget har nått disken)

1. **En andra tempohändelse på takt 9**, position `9 1 3 210`, **121,0000 BPM** (120 plus ett steg från stegarproben). Den skulle ha tagits bort med radens `Delete`-aktion; AX föll innan dess. Fixen: öppna `View > List Editors`, Tempo-fliken, markera rad 2 och radera — eller Ångra tills den är borta. Projektet har alltså en tempokarta det inte hade när sessionen började.
2. **`Audio 8`, `Aux 1` och `Aux 3` står på -0,1 dB** (fader 12403) i stället för +0,0 dB (12443). De sattes åtta vpot-steg ned i teckenproben och "återställdes" med en absolut faderskrivning som Logic ignorerade (fynd 3); konvergensen tog dem tillbaka till inom sin egen tolerans men inte till exakt samma råvärde.
3. **Playheaden står på takt 9** (var takt 57 slag 4 vid sessionens start).
4. Ett eller flera **pluginfönster kan stå öppna** på `Stereo Out` — de stängs normalt av den `defer` som öppnade dem, men AX-kraschen kan ha avbrutit en stängning.
5. Sedan förra sessionen, oförändrat: `Bas` → `Compressor` med `Output Gain` på råvärde 60 i stället för 54 (v0.52.0:s städnot).

Allt annat är återställt och verifierat: `Stereo Out`s volym (12443) och mute (av), masterfadern (12443), Channel EQ:s `Pea3Ga` (0,0 dB), och Limiterns åtta parametrar plus dess etikett.

`swift test`: 278 tester gröna (22 nya), 1,4 s, ingen Logic behövs. `swift build -c release` grön.


### List Editors som fyra läsningar: händelser, markörer, taktarter — plus insert-bypass och Mixern (2026-08-28, v0.54.0)

COVERAGE:s öppna fråga 3 var: **publicerar Event-, Marker- och Signature-flikarna rader på samma sätt som Tempo-fliken?** Tempo-grammatiken var verifierad för EN flik, och de tre andra antogs vara likadana "eftersom de delar panel". Den här slicen ställde frågan i stället för att fortsätta anta — och byggde ovanpå svaret G04 (`logic_list_events`), G46 (`logic_markers`), G48 (taktkartan i bar-matematiken), G36 (`logic_set_insert_bypass`) och G57 (`logic_set_mixer`), plus COVERAGE:s composability-pass U1–U10.

**Miljö:** körande Logic Pro 12.3.1 (`Testlåt Copy.logicx` — sandlådekopian användaren uttryckligen godkänt skrivningar i), användarens bryggdaemon pid 24761 orörd, ingen `logician --bridge` startad, projektet aldrig sparat. Tillfällig XCTest-harness (`LiveProbe.swift`) som togs bort efteråt. **Tre agenter arbetade parallellt mot samma Logic**, så varje live-batch kördes under ett rådgivande lås (`mkdir` på en låskatalog) och lämnade panelen i det läge den hittades. Hela harnessen låg dessutom bakom `LOGICIAN_LIVE=1` efter att ett vanligt `swift test` en gång råkat köra den utan lås — en probe som rör Logic får inte ligga i den vanliga sviten.

#### Fyndet: flikarna DELAR panel men INTE cellgrammatik

Svaret på öppen fråga 3 är **ja med förbehåll**. Alla fyra flikarna publicerar samma yttre struktur — en `AXGroup` vars `AXDescription` är flikens namn, med ett `Number of Items`-barn och en `AXTable` under sig — så panelvägen och trunkeringskontrollen bär rakt över. Men **celltexten ligger inte på samma attribut i alla flikar**, och Tempo-fliken råkade vara det enklaste fallet.

**Kolumnrubrikerna** (tabellens `AXHeader`-barns `AXTitle`):

| flik | kolumner | Number of Items |
|---|---|---|
| Event | `L`, `M`, `Position`, `Status`, `Ch`, `Num`, `Val`, `Length/Info` | `"18 Events"` |
| Marker | `L`, `Position`, `Marker Name`, `Length` | `"1 Marker"` (singular!) |
| Signature | `Position`, `Type`, `Value` | `"2 Events"` |
| Tempo | `Position`, `Tempo`, `SMPTE Position` | `"2 Events"` |

**Celltexten: `AXDescription` → `AXValueDescription` → `AXValue`, sammanfogat över cellens alla barn.** Fyra former, och de tre sista var okända:

- **Grupper med text i beskrivningen** — positioner och längder i alla flikar: `"1 1 1 1 "`, `"0 2 0 0"`, `"∞"`. Det var det Tempo-forskningen såg, och det är den enda formen den såg.
- **Ett textfält med texten på VÄRDET** — Event-flikens `Name`-kolumn: `AXTextField` med tom beskrivning och `AXValue = "Inst 4"`.
- **En slider vars `AXValue` INTE är den visade texten** — och det här är det farliga. Event-flikens `Num` läser `AXValue = 51` medan Logic visar `D♯2`, och `Val` läser **samma `3306422272` på VARENDA not** (ett rått 32-bitarsfält, `AXMaxValue = 4294967295`) medan Logic visar anslaget, `98`. Båda lägger den riktiga texten på **`AXValueDescription`**. En läsare som litade på `AXValue` hade rapporterat en konstant som varje nots anslag — sämre än att inte rapportera något — så koden tar beskrivningen först, och en "velocity" utanför 0–127 släpps helt hellre än att skickas vidare (enhetstestat med det observerade talet).
- **Två element i EN cell** — Signature-flikens `Value`: en `AXSlider` med täljaren och en `AXPopUpButton` med `"/4"`. Taktarten finns alltså inte som sträng förrän barnen fogas ihop: `"4"` + `"/4"` = `"4/4"`.

**Event-fliken har TVÅ nivåer.** Utan region vald listar den projektets REGIONER — 54 rader med `Position`/`Name`/`Trk`/`Length` och en `Leave Folder`-knapp i gruppen. Med en region vald listar den den regionens HÄNDELSER, och gruppens `Region Path`-text namnger vilken (`Inst 4`). Verktyget rapporterar den texten som `region`, så svarets räckvidd följer med svaret. Live: 18 händelser lästa ur `Inst 4`, med tonhöjder som notnamn och riktiga anslag.

**Signature-fliken: de INITIALA raderna publicerar ingen position — och ingen Delete.** Projektets egen första taktart och första tonart kommer tillbaka med en **tom** positionscell (inga barn, inget värde), medan en taktart skapad senare publicerar `"41 1 1 1 "` som alla andra listor. De initiala raderna saknar också radens `Delete`-aktion, vilket är samma sak sett från andra hållet: de är de förval projektet inte kan vara utan. **Att läsa den tomma cellen som ett parsningsfel fick hela taktartsläsningen att misslyckas på VARJE projekt** — det var så regeln hittades. En tom position är alltså takt 1, och det är en ren, enhetstestad funktion (`MeterMap.parseSignatureRow`).

**Radens `Delete`-aktion heter inte `Delete`.** Logic publicerar den som en CUSTOM action, och `AXUIElementCopyActionNames` returnerar hela deskriptorn som namnet: `"Name:Delete\nTarget:0x0\nSelector:(null)"`. Att utföra `"Delete"` returnerar fel och gör ingenting — vilket är exakt vad första skarpa körningen gjorde, tyst. Namnet slås nu upp i stället för att antas. (Tempo-sessionen 2026-08-28 såg aktionen och skrev "det är så en händelse tas bort"; den kördes aldrig, och namnet var fel.)

**Marker-fliken har en egen `Create new Marker`-knapp**, som nu används i stället för det inlärda `Create Marker`-kommandot COVERAGE pekade ut: knappen sitter i samma lista som resultatet verifieras mot, behöver ingen inlärd tilldelning, och kan inte bli föräldralös när Logics MIDI-portar skapas om. Key command-vägen är kvar som reserv.

**Logic OMNUMRERAR sina förvalda markörnamn efter position.** En markör skapad vid takt 33 framför den befintliga `Marker 1` vid takt 161 döpte om den befintliga till `Marker 2` och gav den nya namnet `Marker 1`. Radindex är alltså inte identitet och namnet är det inte heller: `create` identifierar den nya markören på sin TAKT, och verktygets not säger åt agenten att adressera markörer per takt när det spelar roll.

**Verifierat live, genom den shippade koden:**

- **Taktkartan läses.** `readMeterMap()` gav `[takt 1: 4/4, takt 41: 5/4]`, `source: .signatureList`, en tonartsrad räknad och överhoppad. G48:s läsdel är därmed live-bevisad — och testprojektet har nu en riktig varierande taktart, vilket ingen tidigare session haft.
- **Markörlistan läses**: `Marker 1` på takt 161, kolumnerna som ovan.
- **Händelselistan läses**: 18 händelser ur regionen `Inst 4`, `declared_count` 18, bar/beat/pitch/velocity/length tolkade.
- **Markörskapande fungerar och verifieras**: 1 → 2 markörer via knappen, `write_route: list_editor_create_marker_button`, `verified: true`.
- **`setPlayhead(bar: 33)` landade på takt 33 slag 4** — kontrollradens egen läsning. Att playheaden inte hamnar på taktlinjen är alltså värre än förra sessionens "inom slaget"; slagfältet följde inte med. Allt som placeras vid playheaden ärver det.

**Overifierat, och det ska stå:** insert-bypass-skrivningen (`AXPress` på kryssrutan), `logic_set_mixer` och därmed påståendet att en öppen Mixer lyfter AX-begränsningen, U1:s rullningslistsignal, `rename` på en markörrad, och trunkeringskontrollen mot en verkligt lång lista. Alla fyra har en färdig probe; ingen av dem hann köras.

#### Och sedan degraderade macOS hjälpmedelslager igen, systemomfattande

Andra gången på två dygn, samma signatur som v0.53.0 fynd 11: `AXWindows` returnerar **applikationselementet** i stället för fönstren, `AXMainWindow` och `AXFocusedWindow` likaså, och `projectWindow()` hittar ingenting. Inte Logic-specifikt — samma probe mot `Finder` gav fönsterrollerna `["AXApplication", "AXScrollArea"]` och mot `Terminal` `["AXApplication"]`. Logic mådde bra och `AXIsProcessTrusted()` var fortfarande sant.

Det inträffade mitt i städningen efter markörexperimentet, vilket är den dyraste tänkbara tidpunkten: skrivningarna var gjorda och borttagningarna inte. Sessionsregeln ("degraderar AX igen — stoppa och rapportera") följdes, låset släpptes direkt så att de parallella agenterna inte blockerades, och inget mer AX-arbete gjordes.

#### Vad som blev kvar i användarens projekt (osparat, inget har nått disken)

1. **Tre markörer vid takt 33 slag 4** (`Marker 1`–`Marker 3`), en per körning av markörproben — den andra och tredje kom av att borttagningen misslyckades tyst på fel aktionsnamn innan det var förstått. Den befintliga markören vid takt 161 heter därför nu `Marker 4` och får tillbaka sitt namn när de tre tas bort.
2. **En taktartshändelse `5/4` vid takt 41**, skapad av signaturproben (`Create new Time/Key Signature Change` gav 5/4, inte 4/4 — Logics eget förval här är inte kopierat från föregående taktart). Projektet har alltså en varierande taktart det inte hade när sessionen började. Till skillnad från de initiala raderna BÄR den en Delete-aktion, så den går att ta bort via radens egen Delete när AX-planet är tillbaka.
3. **Playheaden står på takt 33 slag 4** (var takt 62 slag 1 när låsfönstret började).
4. Sedan tidigare sessioner, oförändrat: den andra tempohändelsen vid takt 9 (121 BPM) och `Bas` → `Compressor` med `Output Gain` på 60.

Städningen kräver bara att AX-planet kommer tillbaka (utloggning eller omstart av hjälpmedelstjänsten — användarens beslut): öppna `View > List Editors`, ta bort de tre markörraderna vid takt 33 i Marker-fliken och 5/4-raden i Signature-fliken.


#### Taktkartan: `MeterMap`, och kontraktet som gör den ofarlig

Varje takt→sekunder-omräkning i den här servern är två halvor: **takter till slag**, sedan **slag till sekunder**. Tempokartan (v0.51.0) gjorde den andra halvan rätt under ett tempospår. Den första halvan var fortfarande *en* multiplikation med ett slag-per-takt — det sista antagandet i bar-matematiken, och roadmap-punkt 3:s parkerade uppföljning.

`MeterMap` bär Signature List:s taktarter på sina takter och gör den bar→beat-aritmetik som en skiftande taktart gör icke-linjär. Logics BPM räknar **fjärdedelar**, så en takts längd är `täljare × 4 / nämnare`: 3/4 är tre slag, 6/8 är tre, 7/8 är tre och en halv, 5/4 är fem. Notationsfrågan och aritmetikfrågan är alltså olika frågor — en karta med 3/4 och 6/8 är *konstant* för matematiken, och det står som ett eget test.

**Konstant-takt-kontraktet är hela säkerhetsargumentet.** En karta vars taktarter alla beskriver samma taktlängd **rapporteras och används aldrig**: varje konsument frågar `isVariable` först och faller tillbaka på anroparens skalära `beats_per_bar`. Det är inte lättja — det är det som gör att ett konstant-takts-projekts gränser förblir **bit för bit** vad de alltid varit, samma disciplin som `TempoMap.rangeSeconds` en-händelse-snabbväg redan hade. Testerna hävdar den likheten med exakt likhet, inte med tolerans, på båda nivåerna. En konstant karta tar heller inte ifrån anroparen `beats_per_bar`-overriden; en *varierande* karta gör det, och säger det i sin varning.

Inkopplat på de fyra ställen som räknar takter själva:

- `barRangeSeconds` — och när tempokartan INTE gick att läsa men taktkartan varierar uttrycks det enda tempot som en en-händelses `TempoMap`, så de två halvorna komponeras genom samma kodväg i stället för genom en andra formel.
- `takeEnd` — var en tagning SLUTAR är ett taktantal, och under skiftande taktart är det en vandring över takterna, inte en division. Fallet som skiljer dem åt: en 12-slagston som börjar i sista 4/4-takten löper tre 3/4-takter in och ut på andra sidan takt 11, vilket en-taktartsdivisionen rapporterar som slut på takt 11 — en tagning mätt (och renderad, och tempoläst) en hel takt för kort.
- `logic_record_midi`s per-event-offsets.
- `logic_record_automation`s punktplacering och dess ms-per-slag.

Resultaten bär ett `meter_map`-block **närhelst en läsning försöktes** — en oläst Signature List rapporteras som oläst, aldrig som en konstant taktart, för det är precis det fallet där det gamla antagandet fortfarande lever — och en varning bara när kartan faktiskt varierar (samma regel som tempokartans: en konstant karta har inget förbehåll att bära).

Panel-disciplinen som `readTempoMap` etablerade (öppna om stängd, återställ fliken, stäng det vi öppnade) flyttade in i `withListEditorsTab` så att de tre andra flikarna inte kan uppfinna halva den var för sig; `readTempoMap` går nu genom den, oförändrad i beteende.

#### `logic_list_events` (G04): MIDI var skrivbart men inte läsbart

`logic_record_midi` kunde komponera in noter i ett projekt vars befintliga noter agenten inte kunde läsa tillbaka — dess enda bevis var en renderings nivåmätning. Event-fliken stänger det.

Två designval är värda att skriva ned. **Raderna mappas mot tabellens EGNA kolumnrubriker**, inte mot hårdkodade positioner: Event-flikens kolumnuppsättning beror på vad som är valt, och en läsare som räknar positioner rapporterar fel den dag Logic lägger till en kolumn. Varje rad bär därför både Logics egna celltexter under Logics egna kolumnnamn OCH en tolkad vy (`bar`, `beat`, `pitch`, `velocity`, `length`) för de kolumner som gick att känna igen — plus `cells` ovillkorligt, så att en rad som tappar sina fält rapporteras som en rad vi inte kunde namnge i stället för som en tom rad. **`Num` och `Val` betyder tonhöjd/anslag på en note-rad och kontrollernummer/värde på en CC-rad**, så bara note-läsningen får egna namn; CC-raden behåller Logics kolumnnamn och hittar inte på något.

Och räckvidden, som är hela ärlighetsberättelsen: **Event List visar den VALDA regionen**, aldrig projektets MIDI som helhet. Verktyget kan välja åt anroparen (`track_name` + `region_name`/`start_bar`), och en tom lista bär en varning som säger att tomt betyder "inget är valt", inte "projektet har ingen MIDI". `Number of Items`-korskontrollen gäller här av exakt samma skäl som i tempokartan: en lista som tyst stannar på rad 30 av 400 är värre än en som vägrar, för en agent skulle dra slutsatsen att regionen har trettio noter.

#### `logic_markers` (G46): `Create Marker` hade legat inlärt utan verktyg bakom sig

`list` / `create` / `goto` / `rename` / `delete`. `create` fyrar Logics eget `Create Marker`-kommando (som legat i den inlärda uppsättningen sedan key command-arbetet, med ingenting bakom sig) och verifierar mot en ny läsning av listan. `delete` går via radens egen `Delete`-aktion — den aktion varje List Editors-rad observerades bära 2026-08-28 — och verifieras av att markören är borta, aldrig av aktionens returkod.

`rename` är medvetet en **körtidsfråga, inte ett antagande**: Tempo List:s positions- och tempoceller visade sig vara *stegare* (`AXIncrement`/`AXDecrement`), inte fält, så markörradens namncell testas för skrivbarhet och en icke-skrivbar cell vägras med skälet i stället för att kringgås med tangenttryck. Markörer adresseras på exakt namn (skiftlägesokänsligt, aldrig luddigt — att döpa om eller radera fel markör är tyst skada) eller på takt; tvetydighet vägras med kandidaterna listade.

En sak följer med från tempoarbetet och står i verktygets not: **`Create Marker` lägger markören på PLAYHEADEN, och `setPlayhead` landar inom slaget, inte på det**, så en markör kan hamna en bråkdel av ett slag sent.

#### `logic_set_insert_bypass` (G36): läsbart sedan första insert-listningen, oskrivbart tills nu

`insertSlots` har rapporterat `bypassed` från en `AXCheckBox` med `AXDescription` `bypass` sedan insert-listningen shippade, och ingenting kunde skriva den — medan bypass-och-lyssna är den snabbaste ärliga A/B:n i mixning och kostar en bråkdel av `logic_evaluate_change`s trettio-plus sekunder.

Kontrollen publicerar bara `AXPress` och ingen absolut skrivning, så en tryckning utan läsning först vore ett myntkast: verktyget läser, jämför mot `expected_current_bypassed` när det ges, och ett insert som redan står rätt är en **verifierad nolloperation** (`already_bypassed` / `already_active`) i stället för en blind toggling. Strippen resolvas genom `stripForControls`, alltså samma regel — och samma begränsning — som varje annat AX-plans-strippverktyg.

#### `logic_set_mixer` (G57): begränsningen som bara var dokumenterad

AX-planets strippverktyg når bara en kanalstripp som en **inspektor visar**, vilket är varför `Stereo Out` (det valda spårets utgång) går att nå och `Master` och auxarna inte gör det. Guiden har dokumenterat det som en begränsning med en åtgärd agenten inte kunde utföra. Nu kan den.

Verktyget rapporterar `inspector_strips` — varenda strippnamn Accessibility ser i det ögonblicket — just för att påståendet "en öppen Mixer lyfter begränsningen" ska gå att KONTROLLERA i resultatet i stället för att tros på en doc-kommentars ord.

#### Composability-passet U1–U10

COVERAGE:s U-avsnitt räknar *användbarhet*: fall där verktyget finns och en kompetent agent ändå misslyckas. Sju av tio var text eller schema och åtgärdades här.

- **U1 — den farligaste läsningen såg ut som den ofarligaste.** `logic_list_tracks` svarade `success: true` med en PARTIELL värld (13 av 27 spår på referensprojektet) och förbehållet låg som en fotnot på ett lyckat resultat. Nu bär resultatet `partial`, `partial_evidence` (en mening per signal), `missing_track_numbers` där numreringen namnger dem, `visible_tracks` och `completeness`. **Det finns ingen "complete"-dom, och kan inte finnas**: Accessibility publicerar det som är renderat och säger ingenting om det som inte är det, så frånvaro av bevis är inte bevis på frånvaro. De två svaren är `partial` (något saknas bevisligen, och här är vad) och `unknown`. Fyra signaler: rubriker utrullade ovanför (numreringen börjar inte på 1), luckor i numreringen, kollapsade spårstaplar, och Tracks-områdets egen rullningslist. Den sista är den avgörande för det dokumenterade 13-av-27-fallet, eftersom tretton sammanhängande rader från spår 1 inte lämnar något spår i numreringen — och den är trevärd (`true`/`false`/`nil`), för en rullningslist koden inte hittade får aldrig läsas som "allt får plats".
- **U2 — två numreringssystem delade ett ord.** `insert_index` (Accessibility-ordinal) och `insert_slot` (Mackie fysisk slot) heter nu ACCESSIBILITY respektive MACKIE i varje schema där de förekommer, med den observerade omvändningen på `Stereo Out` som konkret exempel och regeln "lista med det verktyg du ska använda" på plats.
- **U5 — en tanke, två anrop.** `logic_add_send` tar `level_db` och sätter nivån i samma anrop (samma konvergering och återläsning som `logic_mcu_set_send`, på strippen anropet redan valt). Misslyckas nivåskrivningen finns SENDEN kvar — det är en verifierad skrivning och får inte rapporteras som ett misslyckande — så resultatet säger att den står på -oo dB och namnger uppföljningsanropet.
- **U6 — kliffet som såg ut som en platå.** `logic_create_track`s beskrivning säger nu rakt ut att den inte laddar något instrument, att instrumentplatsen är en annan mekanism än insert-platserna, och att "skapa instrumentspår" + "lägg till plugin" båda rapporterar framgång medan spåret fortfarande är tyst.
- **U7** — `logic_render_track` säger att den skriver en FIL, inte en region: den är inte bounce-in-place. **U8** — `logic_list_regions` säger att regioner saknar stabilt handtag och att kartan ska läsas om mellan två redigeringar. **U9** — `logic_evaluate_change`s `method` säger att ingenting läser om ett spår är en stapel-subtrack eller delar kanalstripp, så valet upptäcks genom en snabb vägran. **U10** — `logic_evaluate_change` heter fortfarande samma sak men beskrivningen börjar med vad den GÖR ("A/B a change and hear both versions"), och båda inspelningsverktygen börjar med att de tar verklig väggklockstid.

Kvar av U-avsnittet, medvetet: **U3** (`logic_split_region`) och **U4** (`logic_list_key_commands`) hör till key command-slicen och byggdes inte här för att inte kollidera med den parallella agenten.

`swift test`: 325 tester gröna (47 nya), 1,4 s, ingen Logic behövs. `swift build -c release` grön. `serverVersion` är MEDVETET inte bumpad — tre slicear landar parallellt och versionen sätts när de slås ihop.
### Key commands, regionsredigering och leveransdialoger (2026-08-28, v0.53.x)

Den här sessionen tog COVERAGE:s **G00** (lär vilket key command som helst), **G24** (dela region), **G26** (flerregionsval), **G53** (bounce-format), **G33** (bounce in place), **G30** ("strip silence") och **G54** (stems). Sju verktyg shippade — och vägen dit hittade **fyra buggar i kod som redan fanns**, varav två gjorde att key command-inlärningen inte fungerade alls på den här Logic-versionen.

**Miljö:** körande Logic Pro 12.3.1 (`Testlåt Copy.logicx`, pid 75391 — sandlådekopian användaren godkänt skrivningar i), användarens bryggdaemon pid 24761, tillfälliga XCTest-harness som togs bort efteråt. Ingen `logician --bridge` startades. Projektet sparades aldrig. Varje skrivning föregicks av kontrollen att projektsökvägen innehåller "Copy". Tre agenter delade Logic via ett rådgivande lås (`agent-live.lock`); allt nedan kördes med låset hållet.

#### Fynd 1 — inlärningen var trasig på TVÅ ställen, och båda tystnade som "menyn/fältet finns inte"

`logic_setup_key_commands` har inte kunnat öppna Key Commands-fönstret på den här maskinen. Två oberoende orsaker:

1. **Menyposten heter `Edit Assignments…`, inte `Edit`** — och viktigare: `Logic Pro > Key Commands`-undermenyn **publicerar inga barn alls** förrän något öppnat den. En färsk genomgång av appmenyn visade `Settings` och `Control Surfaces` fullt utbyggda medan `Key Commands` hade **ett enda namnlöst barn**. Sökningen efter en post som innehåller "Edit" hittade alltså ingenting, och felet blev `windowNotFound("menu item 'Edit' under 'Key Commands'")`.
2. **Och när posten väl hittas är `AXPress` på den en tyst nolloperation.** Både `AXPress` och `AXPick` returnerade `.success` (0) och fönstret öppnades aldrig — med Logic verifierat frontmost (`NSWorkspace.frontmostApplication == "Logic Pro"`), menyn både stängd och nyss öppnad. Samma kodväg öppnar `File > Bounce > Project or Section…` varje gång. Det är alltså inte "menyer går inte att trycka" utan "den här menyn går inte att trycka".

**Lösningen kommer från menyposten själv.** En `AXMenuItem` publicerar sitt eget tangentbordskommando:

| menypost | `AXMenuItemCmdChar` | `AXMenuItemCmdModifiers` | betyder |
|---|---|---|---|
| `Edit Assignments…` | `K` | 10 | ⌥K |
| `Regions in Place…` | `B` | 12 | ⌃B |
| `Project or Section…` | `B` | 0 | ⌘B |

Bitmasken är Apples: 1 = shift, 2 = option, 4 = control, och **8 = INGET kommando** — Command är default och stängs AV av bit 3, vilket är precis tvärtom mot alla andra bitar och den lätta delen att få fel. `pressMenuItem` tar nu ett valfritt `settled:`-predikat: pressen görs som förut, och om ingenting händer inom ~1,8 s syntetiseras **den genvägen posten själv annonserar** (aldrig en hårdkodad tangent — den kunde vara ombunden till något annat). ⌥K öppnade fönstret på 0,5 s, varje gång. Anropare som inte skickar `settled:` får exakt det gamla beteendet, så bounce-vägen är orörd.

3. **Sökfältet hittades inte heller.** Den gamla regeln var "ett `AXTextField` med ett barn vars `AXDescription` är `search`". I 12.3.1 är fältet ett `AXTextField` med **subroll `AXSearchField` och inga barn alls**. Tre vittnen accepteras nu (subrollen, `AXHelp` som innehåller "search", det gamla barnet) — vilket som helst räcker.

Fönstrets titel, för övrigt: **`Key Command Assignments – Swedish – Edited`**. Användarens set är det svenska, redigerat, med tre konflikter enligt fönstrets egen `Conflicts (3)`-knapp.

#### Fynd 2 — G00: `logic_learn_key_command` och `logic_list_key_commands`

Maskineriet var redan generellt; det enda som stod i vägen var schemats `enum`. Det som byggdes runt det är samtyckesberättelsen:

- **Noten väljs ur ett reserverat intervall** (`KeyCommandRegistry.learnableNoteRange` = 60–99, sedan 122–127, sedan 21–59) och `takenNotes()` reserverar ALLA standardkommandonas önskade noter (100–121) oavsett om de är inlärda — ett godtyckligt kommando kan alltså aldrig ta en not produktens egna verktyg är på väg att vilja ha.
- **Registret säger vem som band vad och när**: nya poster bär `source` (`logic_learn_key_command`, `logic_select_regions`, …), `learned_at` (ISO-tidsstämpel) och `search`. Gamla poster saknar `source` och rapporteras som `"unrecorded (bound before the registry tracked a source)"` i stället för att tillskrivas onboardingen.
- **Sökordet härleds ur namnet** (`defaultSearchTerm`: de två första orden, tre om de är korta) vilket gör det till en delsträng av namnet **per konstruktion** — det kan bara missa om namnet är fel, och det är exakt det fallet kandidatlistan finns för.
- **`dry_run: true`** öppnar fönstret, filtrerar, läser raderna och stänger igen utan att binda något. Ett tomt resultat breddas automatiskt till namnets första ord.
- **`not_found` listar de riktiga raderna** (ny felkod `keyCommandNotFound`). COVERAGE:s öppna fråga 7 ("namn driftar mellan versioner") är därmed inte längre ett tyst misslyckande utan en lista att välja ur.

`logic_list_key_commands` är en ren filläsning (Logic rörs inte) och säger det: en post som listas kan ändå vara föräldralös inne i Logic om MIDI-portarna gjorts om.

**Live:** fyra kommandon lärdes in på noterna 60–63 (se fynd 3 för namnen), registret gick 22 → 26 poster, och varje ny post bär källa och tidsstämpel. Ett femte (`Select All Following of Same Track/Pitch`, not 64) lärdes in **på begäran av `logic_select_regions`** och resultatet bar `consent_note` om det.

#### Fynd 3 — vad kommandona FAKTISKT heter i Logic 12.3.1

Sökningar i Key Commands-fönstret, med de befintliga bindningarna i klartext:

| COVERAGE gissade | Logic 12.3.1 säger | genväg |
|---|---|---|
| "Strip Silence" | **`Remove Silence from Audio Region…`** | ⌃X |
| "Select All Following of Same Track" | **`Select All Following of Same Track/Pitch`** | ⌃⇧F |
| "Select All in Track" | **`Select All Regions/Cells of Same Track`** | — |
| — | `Select All Following` | ⇧F |
| — | `Select All Regions of Selected Tracks *` | — |
| "Bounce in Place" | **`Bounce Regions/Cells in Place…`** / `Bounce Tracks in Place` | ⌃B / ⌃⌘B |

`Split Regions/Events at Playhead Position` visade `⌘T ⌘1⃣ Note 103` — vår egen inlärda not, svart på vitt i användarens eget fönster. Sidofynd för framtida rader: `Normalize Region/Cell Gain…` (⌃⌥G), `Region Gain ±1 dB` och `±0.1 dB` finns som kommandon (G29), liksom `Stem Splitter…` med sex presets.

`View`-menyn hade inget "Strip Silence" alls, och Edit-menyn har bara `Select All` — hela urvalsfamiljen finns ENBART som key commands, vilket gör G26 beroende av G00 precis som COVERAGE gissade.

#### Fynd 4 — playheaden står inte där kontrollraden säger, och det är stegarnas fel

Roadmap-punkt 3:s fynd 10 (2026-08-28) noterade att `setPlayhead` "landar inom slaget". Den här sessionen mätte **varför** och **hur mycket**.

Playhead Position-gruppen i kontrollraden publicerar **exakt två `AXSlider`ar: `bar` och `beat`**. Ingen division, ingen tick — de fälten finns i displayen men inte i hjälpmedelsträdet. Och båda är RELATIVA stegare (`min`/`max` är ±1 runt nuvarande värde, aktionerna `AXIncrement`/`AXDecrement`). Alltså: ett underslag-offset som redan finns i playheaden **bärs med oförändrat genom varje steg**.

MCU:ns tiosiffriga display är sensorn som ser det. Tre verifierade parkeringar i rad:

```
setPlayhead(bar: 5, beat: 1)  ->  kontrollraden "5 bars 1 beat"  ->  MCU "  5 1 4201"
setPlayhead(bar: 6, beat: 1)  ->  kontrollraden "6 bars 1 beat"  ->  MCU "  6 1 4201"
setPlayhead(bar: 9, beat: 1)  ->  kontrollraden "9 bars 1 beat"  ->  MCU "  9 1 4201"
```

Division 4, tick 201 = 0,9583 slag efter slaget, **varje gång**. För tempo-sampling spelar det ingen roll; för en SPLIT är det skillnaden mellan ett snitt på taktlinjen och ett snitt nästan ett helt slag senare, och kontrollraden visar bara takt/slag så avvikelsen är osynlig därifrån.

**Fixen är den enda absoluta förflyttning Logic erbjuder:** kontrollradens `Go to Beginning`-knapp (`AXButton desc='Go to Beginning'`, hjälptexten "Move the playhead to the start of the project"). Från ett nollställt offset håller stegningen sig noll. `parkPlayheadOnGrid` läser MCU-timecoden först, backar bara när offsetet är nollskilt **eller oläsbart**, och rapporterar `on_grid` från division/tick — `null`, aldrig `true`, när ytan inte går att läsa. Kostnad: ~0,12 s per takt från takt 1.

#### Fynd 5 — G24: `logic_split_region`, och modalen ingen visste om

Verktyget slår ihop de tre stegen till ett omdöme, med tre namngivna felmoder. Två av dem vägrar innan något skrivs (snittpunkt utanför regionen; playheaden landade fel), den tredje är arrangemangskartan.

**Ordningen visade sig vara load-bearing.** Första försöket valde regionen först och parkerade playheaden sedan — och splitten hände inte. Att parka playheaden går genom kontrollraden, vilket tar tangentbordsfokus från spårområdet, och ett key command som är scopat till "Main Window Tracks" gör då ingenting alls. Nu parkas playheaden FÖRST och regionen väljs SIST (`selectRegion` sätter `AXFocused` på regionen), och splitten fungerar.

**Och sedan kom modalen.** En MIDI-region vars noter korsar snittet får Logic att öppna ett `AXFloatingWindow` med titeln **`Notes Crossing Split Point`**:

```
"Do you want to keep, shorten, or split the notes that cross the point where the region is being split?"
AXRadioButton 'Keep' (0) | 'Shorten' (0) | 'Split' (1, förvald) | AXButton 'OK' | 'Cancel'
```

Den är modal på det obehagliga sättet: **key commands över MIDI-porten sväljs medan den står uppe**. Symptomet är att varje efterföljande verktyg rapporterar "kommandot avfyrades och ingenting hände" — vi förlorade tio minuter och ett par felsökningsvarv på precis det innan MCU-spegelns LCD avslöjade den (`lcd_bottom` läste `Keep Shortn Split Cancel OK`, `lcd_top` "plit the notes that cross the point where the region is"). Kontrollytans spegel är alltså en modal-detektor, vilket är värt att komma ihåg.

Verktyget svarar nu deterministiskt via `notes_crossing` (`keep`/`shorten`/`split`, default = Logics egen förval `split`), rapporterar vilken gren det tog, och har ett `defer` som **avbryter (Cancel) varje kvarlämnad dialog på alla felvägar**. En ljudregion, eller ett snitt ingen not korsar, öppnar ingenting och resultatet säger `notes_crossing: "not_asked"`.

**Live-verifierat** på en duplicerad kladdregion: `Crash` 60–64 → **60–62 + 62–64**, `verified: true`, `playhead.on_grid: true` (MCU: division 1, tick 1 — exakt på slaget), dialogen besvarad med `split`. En Undo återställde den enda regionen. Kladdkopian togs sedan bort med `logic_delete_region`, och spåret var tillbaka till sin ursprungliga enda region.

#### Fynd 6 — `logic_copy_region` klistrade in på FEL SPÅR och rapporterade misslyckande

Den farligaste buggen den här sessionen. `copyRegion` valde destinationsspåret bara när `to_track` angavs; utan det antog den att kopian landar på källspåret. Men **Paste landar på det VALDA spåret**, och att välja en REGION väljer inte dess spår.

Mätt: en kopia av `Crash` (spår "Crash") till takt 60 utan `to_track` landade på **`Bas`** — spåret som råkade vara valt — varpå verifieringen tittade på "Crash" och svarade `verification_failed: nothing appeared there`. En skrivning på fel spår som rapporterar misslyckande är den värsta formen en bugg kan ha: agenten tror att ingenting hände och gör om det.

Fixen är en rad: destinationsspåret väljs ALLTID, även i samma-spår-fallet. Den felplacerade regionen togs bort med `logic_delete_region` och `Bas` är tillbaka på sina tre regioner.

#### Fynd 7 — G26: `logic_select_regions`, med räkningen som bevis

Fem lägen, vart och ett ett riktigt Logic-kommando, och `selectedRegionCount()` före och efter som verifiering. Live på `808`-spåret:

| läge | kommando | räkning |
|---|---|---|
| `track` | `Select All Regions/Cells of Same Track` | 1 → **9** (spårets alla regioner) |
| `following_same_track` | `Select All Following of Same Track/Pitch` | 1 → **5** (takt 41 och framåt) |
| `following` | `Select All Following` | 1 → **15** (alla spår) |
| `none` | `Deselect All` | 15 → **0** |

Ett läge som inte flyttade räkningen kommer tillbaka `success: false` i stället för att låtsas. Noten säger det viktiga: räkningen ser bara SYNLIGA spårrader medan urvalet är projektomfattande — en efterföljande redigering kan alltså träffa fler regioner än siffran visade.

#### Fynd 8 — G53: bouncedialogens fullständiga grammatik

COVERAGE:s öppna fråga 6 är besvarad. Hela dialogen, gången skrivskyddat och avbruten med Cancel:

**Destinationstabellen** (redan känd): `AXCheckBox` desc `Uncompressed` / `MP3` / `M4A` / `Burn to CD / DVD`.

**Uncompressed-gruppens kontroller** — och nyckeln till dem: etiketterna är `AXStaticText` och kontrollerna `AXPopUpButton`, **syskon utan beskrivning eller titel**. Det enda som binder ihop dem är geometrin: varje etikett låg på x=715 och sin popup på x=819 med popupens y exakt EN punkt över etikettens (187/186, 217/216, 247/246, 277/276, 307/306). `labelledPopUp` parar därför "samma rad, till höger, närmast" med några punkters tolerans.

Varje popups fullständiga värdeförråd, uppräknat genom att öppna dem en och en (✓ = aktuellt):

```
File Type:    AIFF[✓]  WAVE  CAF
Bit Depth:    8-bit  16-bit  24-bit[✓]  32-bit float
Sample Rate:  11.025 / 12 / 22.05 / 24 / 32 / 44.1[✓] / 48 / 64 / 88.2 / 96 / 176.4 / 192 kHz
Dithering:    None[✓]  POW-r #1 (Dithering)  POW-r #2 (Noise Shaping)  POW-r #3 (Noise Shaping)  UV22HR
Format:       Split  Interleaved[✓]
Mode:         Automatic[✓]  Offline  Realtime
Normalize:    Off[✓]  Overload Protection Only  On
```

Plus kryssrutorna `Surround Bounce`, `Add to Project`, `Add to Apple Music Library` (i gruppen) och `Bounce 2nd Cycle Pass`, `Include Audio Tail`, `Include Tempo Information` (i dialogen), samt `Requires 11,4 MB of free disk space (Time 0:42)` som en läsbar uppskattning.

**MP3-varianten** byter ut hela gruppen: `Bit Rate Mono:` / `Bit Rate Stereo:` (320 kbit/s), `Quality:` (Highest), `Stereo Mode:` (Joint Stereo), `Use Variable Bit Rate Encoding (VBR)`, `Filter frequencies below 10 Hz`, `Use best encoding`, `Write ID3 tags` + en `ID3 Settings…`-knapp. Grammatiken är alltså känd men **inte implementerad** — `logic_bounce_range` stannar på Uncompressed, och det står i verktygsbeskrivningen.

`logic_bounce_range` tar nu `file_type`, `bit_depth`, `sample_rate`, `dithering`, `normalize` och `include_audio_tail`. Värden matchas överseende ("48k", "48000", "48 kHz" → `48 kHz`) men **aldrig luddigt**: ett tvetydigt prefix ("1" mot sample rate) vägras, och ett okänt värde vägras med hela listan INNAN dialogen rör sig. Varje skrivning verifieras genom att läsa popupens värde tillbaka, och resultatet bär `delivered_as` — hela leveranstillståndet läst ur dialogen strax före OK. **Ingenting återställs**: det här är användarens egna inställningar och Logic behåller dem, så `options_changed` säger vad som flyttades i stället för att låtsas att det var tillfälligt.

#### Fynd 9 — G33: bounce-in-place-arket

`File > Bounce > Regions in Place…` och `Tracks in Place…` finns båda i menyn (och som key commands, fynd 3). Arket är en **`AXSheet` utan titel** — det enda som namnger det är en `AXStaticText` som läser `Bounce Regions In Place`. Innehåll:

```
AXTextField 'Crash_bip' (SETTABLE)          Name:
AXPopUpButton 'Overload Protection Only'    Normalize:
AXRadioButton Selected Track(0) / New Track(1)   Destination:
AXRadioButton Mute(1) / Leave(0) / Delete(0)     Source:
AXPopUpButton 'One File'                    (fil-uppdelning vid flera regioner)
AXCheckBox  Include Volume/Pan Automation(1)   Include Audio Tail in Region(0)
            Include Audio Tail in File(1)      Bypass Effect Plug-ins(1)
            Bounce Second Loop Pass(0)         Include Instrument Multi-Outputs(0)
AXButton    Restore Defaults | Cancel | OK
```

**`Bypass Effect Plug-ins` stod på 1 i det här projektet.** En "print that" med den påslagen ger TORRT ljud — inserten renderas inte — vilket nästan aldrig är vad någon menar. `logic_bounce_in_place` ändrar bara det anroparen ber om, rapporterar hela arkets tillstånd, och **varnar** när bypass var på.

#### Fynd 10 — G30: det heter inte Strip Silence, och fönstret har en LIVE-förhandsvisning

`Remove Silence from Audio Region…` på en markerad ljudregion öppnar ett `AXFloatingWindow` med titeln `Remove Silence`:

```
AXStaticText '9 Regions'        <- Logics EGEN förhandsvisning, uppdateras med inställningarna
AXCheckBox   'Search Zero Crossing' (1)
AXGroup '0,1000' + label 'Minimum Time to accept as Silence:'   (5 sifferstegare, min 0 max 60)
AXGroup '0,0000' + label 'Post Release-Time:'
AXGroup '0,0060' + label 'Pre Attack-Time:'
AXGroup '-28'    + label 'Threshold:'                            (2 sifferstegare, min -80 max 0)
AXButton OK | Cancel
```

Sifferfälten är samma art som bouncedialogens positionsfält och Tempo Lists celler: per-siffra-`AXSlider`ar med `AXIncrement`/`AXDecrement`. **De skrivs inte** av det här verktyget — det är den ärliga uppdelningen: `logic_remove_silence` med `apply: false` (default) öppnar fönstret, läser Logics egen "N Regions"-siffra och de fyra värdena, stänger igen och ändrar ingenting; `apply: true` trycker OK och verifierar mot arrangemangskartan (en region blir N). En MIDI-region vägras innan fönstret ens öppnas.

Förhandsvisningen är den verkliga vinsten: "vad skulle det här göra?" besvaras med Logics eget svar, utan att röra projektet.

#### Fynd 11 — G54: stems är en komposition, och det viktiga är vad de INNEHÅLLER

`logic_export_stems` gör en offline-bounce per spår över SAMMA taktintervall med bara det spåret soloat, återställer solot efter varje, och jämför filernas `frames` — `aligned` är alltså en observation, inte ett påstående. Den vägrar innan första renderingen om något spår redan är soloat (ett kvarglömt solo skulle lägga sig i varje stem).

Valet av mekanism är hela poängen och står i verktygets egen not: en solo-bounce ger **masterutgången hörd ett spår i taget** — efter fader, efter panorering, efter inserts, MED spårets sändretur, genom masterkedjan. Det är vad en mixare menar med stem. Två konsekvenser sägs rakt ut: summan av stemsen återskapar mixen bara så länge masterkedjan är LINJÄR (en masterlimiter reagerar på hela mixen och kan inte reagera på en stem), och en buss som matas av flera av spåren räknas en gång per stem. `logic_render_track` är den ANDRA sortens fil — en pre-fader-frysning av spåret ensamt, utan sändningar och utan masterkedja — och den är inte en stem. `File > Export > All Tracks as Audio Files…` finns i menyn och vore den dedikerade vägen; dess dialog är inte gången och raden kvar som framtida arbete.

#### Fynd 12 — en blind Undo tog bort någon annans spår

Ärlighetsnoten. Tidigt i sessionen avfyrade harnesset två `Undo` efter ett verktyg som hade **misslyckats** — alltså utan något eget att ångra. Den första tog bort ett tomt spår (`Inst 9`) som en samtidig agent troligen just skapat; spårantalet gick 20 → 19. Det gick inte att göra om (en senare redigering rensar redo-stacken).

Det är precis den fara AGENT-GUIDE:s "fire Undo only right after a known edit" varnar för, och den är nu skriven som en egen `Cautions`-punkt med det här som belägg. Resten av sessionens städning gjordes med riktade `logic_delete_region`-anrop i stället för Undo.

#### Vad som ändrades i koden

`KeyCommandRegistry` (fritt notintervall, `takenNotes`, `defaultSearchTerm`, `source`/`learned_at`/`search` i posterna) · `AXKeyCommandLearning` (delade hjälpare, `searchKeyCommands` skrivskyddad, kandidater i `not_found`, exakt-sedan-skiftlägesokänslig radmatchning, subrollsfixen, den verifierade menypressen) · `MenuShortcut.swift` (ny, ren: modifierarmasken och tangentkoderna) · `AXBounce` (`settled:`-pressen, `labelledPopUp`, `selectPopUpItem`, `setCheckBox`, `applyBounceOptions`, `readBounceOptions`) · `BounceOptions.swift` (ny, ren: värdeförråden och den överseende matchningen) · `AXBounceInPlace.swift` (ny) · `AXRemoveSilence.swift` (ny, med `RemoveSilence.previewCount` ren) · `StemExport.swift` (ny, ren: listvalidering, ramjämförelse, innehållsnoten) · `AXRegions` (`splitRegion`, `selectRegions`, modalhanteringen, paste-på-rätt-spår) · `AXTransport` (`pressControlBarButton`, `parkPlayheadOnGrid`) · `MCURender.resolveKeyCommand` (`learnIfMissing`).

Sju nya verktyg: `logic_learn_key_command`, `logic_list_key_commands`, `logic_split_region`, `logic_select_regions`, `logic_remove_silence`, `logic_bounce_in_place`, `logic_export_stems`. `logic_bounce_range` fick sex nya argument. Inget verktyg döptes om.

#### Vad som är LIVE-VERIFIERAT och vad som inte är det

**Kört mot Logic, med belägg ovan:** inlärningen (fem kommandon, registret 22 → 26 poster, `dry_run`, `not_found` med kandidater), `logic_list_key_commands`, `logic_split_region` (kopia → delning → Undo → städning, `on_grid: true` mot MCU-timecoden, modalen besvarad), `logic_select_regions` (fyra lägen med räkningar), fel-spår-buggen i `logic_copy_region` (observerad, fixad, och fixen bevisad av en fungerande samma-spår-kopia), samt **alla tre dialoggrammatikerna** — bouncedialogen (inklusive varje popups poster och MP3-varianten), bounce-in-place-arket och Remove Silence-fönstret — gångna skrivskyddat och avbrutna med Cancel.

**Overifierat, för ärlighetens skull:**

- **`logic_bounce_range`s nya argument har aldrig SKRIVIT i dialogen.** Värdeförråden och geometriparningen är mätta, men `applyBounceOptions`/`selectPopUpItem` har inte körts skarpt — en bounce med `bit_depth`/`sample_rate` satta är alltså implementerad och enhetstestad, inte utförd.
- **`logic_bounce_in_place` har aldrig tryckt OK.** Arket är gånget och avbrutet; själva utskriften, verifieringen mot arrangemangskartan och 90-sekundersvakan är oprövade.
- **`logic_remove_silence` har aldrig körts genom verktyget** — fönstret öppnades för hand via det inlärda kommandot och avbröts. Både förhandsvisningsläget och `apply: true` är alltså kod, inte observation.
- **`logic_export_stems` har aldrig körts.** Solo-slingan, ramjämförelsen och den vägran som utlöses av ett kvarglömt solo är enhetstestade i sina rena delar och i övrigt oprövade.
- **MP3/M4A-destinationerna** är uppräknade men inte implementerade, och `File > Export > All Tracks as Audio Files…` (den dedikerade stem-vägen) är inte ens öppnad.
- **Splitten är verifierad på EN MIDI-region.** En ljudregion (som inte ska ge någon modal) är inte prövad, och `notes_crossing: "keep"`/`"shorten"` är inte heller det — bara `split`.

Skälet till att listan är så lång är miljön, inte designen: tre agenter delade Logic via ett rådgivande lås, och macOS hjälpmedelslager föll systemomfattande igen mitt i (samma symptom som 2026-08-28:s v0.53.0-session — `AXWindows` returnerar applikationselementet, i Finder och Terminal också). **Orsaken är nu känd**: användaren rapporterar att den utlöses av att maskinen går i strömsparläge, och ändrade energiinställningarna. En AX-probe efter uppvaknandet visade planet friskt igen, så degraderingen är återställbar och inte permanent.

#### Vad som blev kvar ändrat (osparat projekt; inget har nått disken)

1. **Fem nya key command-tilldelningar i användarens egna set** — det är leveransen, inte en biverkning: `Select All Following` (not 60), `Select All Regions/Cells of Same Track` (61), `Deselect All` (62), `Remove Silence from Audio Region…` (63), `Select All Following of Same Track/Pitch` (64), alla på porten `Logic MCP Commands`, alla additiva och borttagbara i Key Commands-fönstret (markera kommandot, Delete Assignment). `logic_list_key_commands` visar dem med källa och tidsstämpel.
2. **Ett tomt spår, `Inst 9`, är borta** — se fynd 12. Spårantalet gick 20 → 19 och Redo når det inte längre.
3. **Playheaden står inte där den stod** (sessionen parkerade den på flera takter; sist runt takt 62).
4. Kladdregionerna är borttagna och `Bas` och `Crash` är tillbaka på sina ursprungliga regioner, verifierat mot arrangemangskartan.
5. Från tidigare sessioner, oförändrat: tempohändelsen på takt 9 (121 BPM), `Audio 8`/`Aux 1`/`Aux 3` på -0,1 dB, och `Bas` → `Compressor` med `Output Gain` på råvärde 60.

`swift test`: 311 tester gröna (33 nya), 1,4 s, ingen Logic behövs. `swift build -c release` grön.
