# Plugin-register — Testlåt.logicx (MCU-svep)

Genererat 2026-08-25 genom MCU-värdautomation: varje kanal i Mackie Control-bankerna
(inklusive global view för stack-subspår) valdes, varje insert öppnades i plugin-edit-läget och
samtliga parametersidor lästes. Allt är läs- OCH skrivbart via `logic_mcu_set_plugin_parameter`.

`*` i förekomster = pluginen var bypassad vid svepet. Instrument (Q-Sampler, Trilian, DMD) ligger
i instrumentslottar och omfattas inte av insertsvepet (nås via `assign_instrument`, framtida arbete).

**23 unika plugin-typer, 74 instanser, 479 unika parametrar totalt.**

| Plugin (MCU-namn) | AX-namn | Parametrar (MCU) | Parametrar (AX) | Sidor | Instanser |
|---|---|---:|---:|---:|---|
| SpaceD | Space D | 88 | 13 | 11 | IvnVoc#7; IvnVoc#4; IvanFx#2*; AckVoc#7; Aux 1#2 … +3 |
| ChrVer | ? | 68 | — | 9 | Reverb#1 |
| Pedlba | Pedalboard | 44 | 19 | 6 | Audio8#3; AckSlg#3; IvnSlg#3; DrSyKi#4 |
| Cha EQ | Channel EQ | 41 | 26 | 6 | LofPad#1; Bas#1; Bas#3; 808#5; Inst 2#1 … +14 |
| Bs Amp | Bass Amp | 28 | 16 | 4 | Audio8#2 |
| AutFi | AutoFilter | 23 | 4 | 4 | LofPad#2* |
| Amp | Amp | 22 | 10 | 3 | Audio8#1 |
| Comprs | Compressor | 20 | 11 | 3 | Bas#4; 808#3; IvnVoc#3; IvnVoc#4; IvnVoc#2 … +10 |
| St-De | St-Delay | 19 | 0 | 3 | DrSyKi#6* |
| PtVer | PtVerb | 18 | 0 | 3 | DrSyKi#7* |
| TapDel | Tape Delay | 16 | 0 | 3 | IvnVoc#5; AckVoc#5; Aux 1#1; AckSlg#4*; IvnSlg#4* … +1 |
| Decptt | Decapitato | 12 | 0 | 2 | 808#6 |
| ClpDis | ClipDist | 10 | 3 | 2 | IvanFx#3 |
| Expndr | Expander | 9 | 0 | 2 | IvanFx#5 |
| Limitr | Limiter | 8 | 0 | 1 | St Out#2 |
| Sensor | Sensor | 8 | 0 | 1 | St Out#3 |
| SmplD | SmpleDly | 8 | 0 | 1 | Hi-Hat#1* |
| Envlp | Enveloper | 8 | 0 | 1 | DrSyKi#5* |
| Bitcrs | Bitcrusher | 8 | 1 | 1 | DrSyKi#3*; Delay#2 |
| PShft | PShft | 6 | 0 | 1 | Bas#2*; KRANE_#1 |
| DeEss2 | DeEsser 2 | 6 | 0 | 1 | IvnVoc#2; IvnVoc#3; AckVoc#2 |
| Cho | ? | 5 | — | 1 | SP/1.3#1* |
| Ovrdr | Overdrive | 4 | 0 | 1 | DrSyKi#2* |

## Parameterlistor

### SpaceD (88 parametrar, 11 sidor)
`OutDry`, `OutWet`, `Predly`, `Length`, `LatCom`, `InCrss`, `Qualit`, `Revers`, `VoInLe`, `VoATim`, `VolAX1`, `VolAY1`, `VolAX2`, `VolAY2`, `VoDTim`, `VolDX1`, `VolDY1`, `VolDX2`, `VolDY2`, `VoEnLe`, `FiInLe`, `FiATim`, `FirAX1`, `FirAY1`, `FirAX2`, `FirAY2`, `FiMaLe`, `FiDTim`, `FirDX1`, `FirDY1`, `FirDX2`, `FirDY2`, `FiEnLe`, `Filter`, `FilrMd`, `FilRes`, `LoShGa`, `LoShF`, `X-OvrF`, `StSpLo`, `VolDMd`, `ReVoCo`, `IntDen`, `EndDen`, `RefShp`, `RamTim`, `IROffs`, `IR Md`, `Load R`, `CreatR`, `DecodR`, `Rest..`, `Env Md`, `EQ`, `Lo Sh`, `Lo Mid`, `Hi Mid`, `Hi Sh`, `LoMiGa`, `LoMidF`, `LoMidQ`, `HiMiGa`, `HiMidF`, `HiMidQ`, `HiShGa`, `HiShF`, `CenLev`, `BalF/R`, `LoShY`, `HiShY`, `PrcsMd`, `LFETRe`, `PrdSyn`, `Size`, `StSpHi`, `ShBeHa`, `Lo Cut`, `LoCuOr`, `LoCutF`, `LoCutQ`, `LoShQ`, `HiShQ`, `Hi Cut`, `HiCuOr`, `HiCutF`, `HiCutQ`, `Volume`, `Densit`

### ChrVer (68 parametrar, 9 sidor)
`Dry`, `Wet`, `RooTyp`, `DcTime`, `DTiSyn`, `Freeze`, `Predly`, `PrdSyn`, `Attack`, `Size`, `Densit`, `Distnc`, `ModSpe`, `ModDep`, `ModSrc`, `ModSmo`, `Ea/Lat`, `Width`, `MonMak`, `MoMarF`, `DLoShF`, `Qualit`, `Visalz`, `-`, `DLSRat`, `DLoShQ`, `DLPakF`, `DLPRat`, `DLPakQ`, `DHPakF`, `DHPRat`, `DHPakQ`, `DHiShF`, `DHSRat`, `DHiShQ`, `-`, `-`, `-`, `-`, `-`, `-`, `-`, `-`, `EQOn/O`, `LCO/Of`, `LoCutF`, `LoCuOr`, `LoCutQ`, `LSO/Of`, `LoShF`, `LoShGa`, `LoShQ`, `LPO/Of`, `LoPekF`, `LoPeGa`, `LoPekQ`, `HPO/Of`, `HiPekF`, `HiPeGa`, `HiPekQ`, `HSO/Of`, `HiShF`, `HiShGa`, `HiShQ`, `HCO/Of`, `HiCutF`, `HiCuOr`, `HiCutQ`

### Pedlba (44 parametrar, 6 sidor)
`MaAVal`, `MaBVal`, `MaCVal`, `MaDVal`, `MaEVal`, `MaFVal`, `MaGVal`, `MaHVal`, `MaATar`, `MaBTar`, `MaCTar`, `MaDTar`, `MaETar`, `MaFTar`, `MaGTar`, `MaHTar`, `Sl1Stm`, `Sl2Stm`, `Sl3Stm`, `Sl4Stm`, `Sl5Stm`, `Sl6Stm`, `Sl7Stm`, `Sl8Stm`, `Sl9Stm`, `Sl10St`, `Sl11St`, `Sl12St`, `Sl13St`, `Sl14St`, `StATyp`, `StBTyp`, `StCTyp`, `StDTyp`, `StETyp`, `StFTyp`, `StGTyp`, `StHTyp`, `StITyp`, `StJTyp`, `StKTyp`, `StLTyp`, `StMTyp`, `StNTyp`

### Cha EQ (41 parametrar, 6 sidor)
`LoCutS`, `LoShGa`, `Pea1Ga`, `Pea2Ga`, `Pea3Ga`, `Pea4Ga`, `HiShGa`, `HiCutS`, `LoCutF`, `LoShF`, `Peak1F`, `Peak2F`, `Peak3F`, `Peak4F`, `HiShF`, `HiCutF`, `LoCutQ`, `LoShQ`, `Peak1Q`, `Peak2Q`, `Peak3Q`, `Peak4Q`, `HiShQ`, `HiCutQ`, `LCO/Of`, `LSO/Of`, `Pe1On/`, `Pe2On/`, `Pe3On/`, `Pe4On/`, `HSO/Of`, `HCO/Of`, `AnOn/O`, `AnlrMd`, `AnlzrD`, `AnlPos`, `AnlRes`, `AnlTop`, `Ga-QCo`, `G-QCou`, `MasGai`

### Bs Amp (28 parametrar, 4 sidor)
`EQ`, `Bass`, `Mids`, `Treble`, `Comp`, `ComAmt`, `CompAt`, `ComGai`, `Chan`, `Bright`, `Gain`, `Low`, `MidRan`, `High`, `Master`, `Amp/IM`, `DIGain`, `DIFCut`, `DITO/O`, `DITone`, `Grp/Pa`, `Model`, `Amp`, `Spkr`, `MicTyp`, `MiPosX`, `MiPosZ`, `OutGai`

### AutFi (23 parametrar, 4 sidor)
`Cutoff`, `Res`, `EnCuMo`, `LFOCMo`, `PrFiDi`, `PoFiDi`, `DrSign`, `MaiOut`, `Fatnss`, `FilrMd`, `St Ph`, `Wf`, `Pulswd`, `Retrgg`, `Thrs`, `Attack`, `Decay`, `Sus`, `Rel`, `EnvDyn`, `BeaSyn`, `Rate`, `SyncPh`

### Amp (22 parametrar, 3 sidor)
`Amp`, `Gain`, `Bass`, `Mids`, `Treble`, `Presnc`, `Master`, `Spkr`, `OutLev`, `Model`, `EQModl`, `MicTyp`, `MiPosX`, `MiPosZ`, `FXEnbl`, `FXType`, `FX Dep`, `FXSyMd`, `FXSped`, `RvbEnb`, `RvbTyp`, `RvbLev`

### Comprs (20 parametrar, 3 sidor)
`CirTyp`, `Thrs`, `Ratio`, `Attack`, `Rel`, `AutRel`, `MakeUp`, `AutGai`, `Knee`, `Peak/S`, `LimrOn`, `LimThr`, `Distrt`, `Mix`, `SiChDe`, `State`, `Mode`, `Freq`, `Q`, `Gain`

### St-De (19 parametrar, 3 sidor)
`LefNot`, `LefDev`, `LeftFb`, `LefMix`, `RigNot`, `RigDev`, `RigtFb`, `RigMix`, `LeDeTi`, `RiDeTi`, `CrssL-`, `CrssR-`, `BeaSyn`, `LeftIn`, `RigtIn`, `LeFbPh`, `RiFbPh`, `CrL->R`, `CrR->L`

### PtVer (18 parametrar, 3 sidor)
`Mix`, `Predly`, `RooSiz`, `RooShp`, `StBase`, `BalR/R`, `IntDel`, `Spread`, `RvbTim`, `Densit`, `LoRato`, `Crssvr`, `Hi Cut`, `LoFLev`, `Diffso`, `ERScal`, `Dry`, `Wet`

### TapDel (16 parametrar, 3 sidor)
`Note`, `Devato`, `Smothn`, `Lo Cut`, `Hi Cut`, `Fb`, `Dry`, `Wet`, `TemSyn`, `FltRat`, `FltInt`, `LFORat`, `LFOInt`, `Freeze`, `ClpThr`, `DelTim`

### Decptt (12 parametrar, 2 sidor)
`Bypass`, `Style`, `Drive`, `Punish`, `LowCut`, `Tone`, `HiCut`, `Mix`, `AutGai`, `LoThmp`, `HiSlop`, `OutTrm`

### ClpDis (10 parametrar, 2 sidor)
`ClpDrv`, `ClpTon`, `ClpSym`, `Mix`, `ClpFil`, `LPFilt`, `HiShGa`, `HiShFn`, `InGain`, `OutGai`

### Expndr (9 parametrar, 2 sidor)
`Thrs`, `Ratio`, `Attack`, `Rel`, `Gain`, `Knee`, `Peak/S`, `AutGai`, `OutClp`

### Limitr (8 parametrar, 1 sidor)
`Gain`, `Lookha`, `Softkn`, `Rel`, `OutLev`, `GaiRed`, `TrPeDe`, `-`

### Sensor (8 parametrar, 1 sidor)
`-`, `-`, `-`, `-`, `-`, `-`, `-`, `-`

### SmplD (8 parametrar, 1 sidor)
`LefDel`, `RigDel`, `LefDel`, `RigDel`, `Unit`, `LiLe&R`, `-`, `-`

### Envlp (8 parametrar, 1 sidor)
`AtTime`, `AtGain`, `RelTim`, `RelGai`, `Thrs`, `Lookha`, `OutLev`, `-`

### Bitcrs (8 parametrar, 1 sidor)
`Drive`, `ClpLev`, `ClipMd`, `Reslto`, `Downsm`, `Mix`, `-`, `-`

### PShft (6 parametrar, 1 sidor)
`Semtns`, `Cents`, `Delay`, `Crssfd`, `StLink`, `Mix`

### DeEss2 (6 parametrar, 1 sidor)
`DettrF`, `Thrs`, `MaxRed`, `FilSol`, `-`, `-`

### Cho (5 parametrar, 1 sidor)
`Mix`, `Intensi`, `ty`, `Rate`, `-`

### Ovrdr (4 parametrar, 1 sidor)
`Drive`, `Tone`, `Output`, `-`
