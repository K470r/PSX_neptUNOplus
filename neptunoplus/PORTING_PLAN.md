# Port de PSX_MiSTer a NeptUNO+ (EP4CGX150 + RP2040/mist-firmware-rp2040)

Este documento es la referencia técnica viva del port. Se actualiza a medida
que avanza el trabajo. Última actualización: ver historial de git.

## 0. Estado

`neptunoplus/psx_mist.sv` reescrito (primer borrador) reemplazando `hps_io` por
`user_io`/`data_io`/`osd` de `mist-modules`, con `MISTER_DUAL_SDRAM`
activado permanentemente. Es también el `TOP_LEVEL_ENTITY` directamente
(módulo `psx_mist_core`) — se decidió no crear un wrapper "thin" separado
porque, a diferencia de NeoGeo/PCEngine, este port no comparte el mismo
core entre varias placas MiST distintas; un solo módulo con los nombres
de pin de la NeptUNO+ directamente es más simple.

Proyecto Quartus creado: `PSX_neptunoplus.qpf/.qsf/.sdc` + `files.qip`,
pinout tomado literal de `NeoGeo_neptunoplus_dr.qsf`/
`tgfx16_neptUNOplus.qsf`.

Regla de organización de carpetas (a partir de ahora): lo que es común
entre MiSTer y NeptUNO+ se queda donde ya estaba en el repo de MiSTer
(`rtl/`, `sys/`, etc., sin tocar); lo que se crea o se modifica
específicamente para NeptUNO+ vive dentro de `neptunoplus/`. Esto incluye
cosas que "se parecen" a un archivo de MiSTer pero cuyo contenido difiere
por ser específico del dispositivo (ver el caso de `pll.v`/`pll2.v` en
§7/§9 — mismo nombre de módulo, pero NO es el mismo archivo, así que no
puede vivir en `rtl/` o pisaría la versión de MiSTer para Cyclone V).

**Nada de esto ha sido compilado ni probado en hardware todavía.** Es
código de primera pasada, escrito leyendo las interfaces de cada módulo
(no hay manera de simular aquí) — se espera iterar sobre errores reales
de Quartus/hardware. Ver §10 para la lista de puntos que más probablemente
necesiten ajuste.

## 1. Hardware objetivo

- FPGA: módulo QMTECH `EP4CGX150DF27I7`, familia **Cyclone IV GX**.
- Placa: NeptUNO+ (esquemático `NeptUNO+PICO.kicad_sch` del usuario), sin
  HDMI/TMDS — salida de vídeo únicamente por DAC resistivo VGA de 24 bits.
- IO controller: RP2040 corriendo `mist-firmware-rp2040` (ZXMicroJack),
  protocolo SPI clásico de MiST (`user_io`/`data_io`/`osd`).
- Memoria: 1x SDRAM 64MB onboard (chip principal). Hay una 2ª SDRAM de 64MB
  de expansión, pero **no se usa en la Fase 1** (ver §4).
- Config FPGA: Passive Serial vía RP2040 (nCONFIG/CONF_DONE/CONF_NSTATUS/
  FPGA_DCLK/FPGA_DATA0), leyendo `CORE.RBF`/`PSX.RBF` desde la SD.

Pinout confirmado pin-a-pin contra `delgrom/NeoGeo_FPGA` (`neptunoplus/
NeoGeo_neptunoplus.qsf`) y `delgrom/TurboGrafx16_FPGA` (`neptUNOplus/
tgfx16_neptUNOplus.qsf`), y coincide con el Excel/esquemático del usuario:
mismo `EP4CGX150DF27I7`, mismos números de pin para SDRAM/VGA/SPI/CLOCK_50.
Reutilizamos ese pin table literal.

## 2. Repos de referencia usados

- `mist-devel/mist-modules` (submódulo en `neptunoplus/mist-modules`):
  `user_io.v`, `data_io.v`, `osd.v`, `mist.vhd`, `mist_video.v`,
  `scandoubler`, `sd_card.v` (no instanciado por NeoGeo/PCEngine — usan el
  mecanismo genérico de `user_io.v` directamente).
- `delgrom/NeoGeo_FPGA` (rama `mist`) — pinout Neptuno+, variante dual-SDRAM
  (`sdram_2w_cl2`, 2º PLL) como referencia de "cómo se hace" si en el futuro
  hace falta banda ancha extra.
- `delgrom/TurboGrafx16_FPGA` (`neptUNOplus`) — mismo pinout, controlador
  `sdram_amr` (parametrizado por macros `SDRAM_ROWBITS/COLBITS/CL/tRC/...`).
- `ZXMicroJack/mist-firmware-rp2040` + submódulo `mist-firmware` — firmware
  RP2040. Ya trae `psx.c` (CUE+BIN, LibCrypt/SBI, detección de región)
  **completo pero no compilado para Neptuno+** (falta añadirlo al
  `CMakeLists.txt` y definir `-DHAVE_PSX`).
- `somhi/jtcores` (`modules/jtframe/target/mist_neptuno2`, `demist_neptuno2`)
  — segunda implementación independiente de `user_io.v` para exactamente
  esta placa, confirma que el ancho de `status` es 64 bits (ver §5).

## 3. Hallazgo clave: la interfaz de CD del core ya es "genérica estilo MiST"

Verificado directamente en `rtl/cd_top.vhd` / `PSX.sv`: el CD usa
`cd_hps_req/cd_hps_lba/cd_hps_ack/cd_hps_write/cd_hps_data`, que en
`PSX.sv` son simplemente alias de `sd_rd[1]/sd_lba1/sd_ack[1]/sd_buff_wr/
sd_buff_dout` — el mecanismo genérico de imagen de disco de `hps_io`
(histórico, viene de MiST). `mist-modules/user_io.v` expone exactamente
`sd_lba/sd_rd/sd_wr/sd_ack/sd_buff_addr/sd_buff_dout/img_mounted/img_size`.
Y `psx.c` del firmware habla ese mismo protocolo genérico
(`UIO_SECTOR_RD`=0x17, drive_index 1 = CD).

**Conclusión: no hace falta un canal custom tipo `data_io_neogeo.v`/
`data_io_pce.v`.** Basta con conectar los `sd_*` del core a los `sd_*` de
`user_io.v`. Única diferencia de forma: `hps_io` tenía un array de 4
`sd_lba` (uno por VDNUM), `user_io.v` tiene un único bus `sd_lba` compartido
+ `drive_sel` interno — hay que muxear `sd_lba1/2/3` hacia ese bus único
según qué bit de `sd_rd`/`sd_wr` esté activo (mux combinacional trivial).

## 4. SDRAM — CORRECCIÓN: hace falta la 2ª SDRAM desde el hito 1

**(Esta sección reemplaza una decisión anterior que era incorrecta — se
deja constancia del error más abajo para que quede claro por qué cambió.)**

`rtl/sdram.sv` (el propio controlador del core PSX) **ya es un controlador
"bare metal" para SDR SDRAM física genérica** (pines `SDRAM_A/DQ/BA/nCS/
nWE/nRAS/nCAS/CKE/CLK`, arbitraje propio de 3 canales + FIFO DMA) — no es
un puente Avalon-HPS. Es prácticamente igual en naturaleza a los
controladores custom que NeoGeo (`sdram_2w_cl2`) y PCEngine (`sdram_amr`)
escribieron para esta misma placa. Se reutiliza casi tal cual, retimando
para los parámetros reales de la SDRAM de la NeptUNO+.

El core también usa un segundo bus, `DDRAM_*` (estilo Avalon burst, el
puente a la DDR3 del HPS en MiSTer). Revisando `rtl/psx_top.vhd` a fondo
(el mux de 3 vías sobre `ddr3_*`: `ddr3_savestate` / `arbiter_active` /
`vram_*` como rama por defecto) se confirma que este bus **no es solo para
la RAM del SPU** como sugiere la etiqueta del menú ("SPU RAM select: DDR3,
SDRAM2") — también carga tráfico de **VRAM del GPU** (rama `vram_*`,
por defecto) y de **memoria card** (`memDDR3card1/2_ADDR` dentro del
arbiter), además del SPU RAM. Es decir: es el bus de memoria de vídeo en
tiempo real del GPU, no un canal secundario opcional.

Esto descarta la idea original de emularlo con un puente a RAM interna de
la FPGA (1MB de VRAM + memoria card + SPU no caben ni de lejos en los
~830KB de memoria embebida del EP4CGX150, y aunque cupieran, el ancho de
banda que necesita el GPU en tiempo real no es viable así).

**Decisión correcta:** activar `MISTER_DUAL_SDRAM` desde el hito 1, tal
cual ya existe en este mismo repo como variante `PSX_DualSDRAM.qsf`/`.qpf`
(ese `ifdef` ya instancia un segundo `sdram sdram2(...)` completo sobre
`SDRAM2_*`, usando el mismo `rtl/sdram.sv` genérico) — encaja perfecto con
el hardware real de la NeptUNO+ (64MB onboard + 64MB de expansión, como
ya me indicó el usuario). Ventaja adicional confirmada leyendo
`rtl/sdram.sv`: el reloj `SDRAM_CLK` de cada instancia lo genera el propio
módulo (registro de salida sobre `clk`/`clk_base` ya existentes) — **no
hace falta un segundo PLL**, a diferencia del patrón de NeoGeo
(`pll2_mist`) que sí usa un PLL separado por razones propias de su placa/
reloj de referencia. Pines de `SDRAM2_*` se toman literalmente del
`NeoGeo_neptunoplus_dr.qsf` (ya confirmados contra el pinout físico real).

No se necesita ningún puente/adaptador nuevo: basta con (a) compilar con
`MISTER_DUAL_SDRAM=1` definido, (b) cablear los pines `SDRAM2_*` en el
`.qsf`, y (c) verificar en el body de `psx_mist.sv` que `SDRAM2_EN` queda
en 1 (actualmente depende de `status[44]`-derivado en el original; en
Fase 1 lo fijamos a constante 1 ya que no hay opción de menú para elegir
"DDR3 vs SDRAM2" — solo existe SDRAM2 en este hardware).

## 5. Restricción real y permanente: `status` de 64 bits

Confirmado en **dos** implementaciones independientes de `user_io.v` para
esta placa (mist-devel stock y el fork de jtframe/jotego): el registro de
opciones `status` es de **64 bits**, no 128 como en `hps_io` de MiSTer. El
`CONF_STR` actual de PSX referencia bits hasta el 127. Esto obliga a
**recortar/reorganizar el menú OSD** a lo esencial para que quepa en 64
bits. No es una limitación de la Fase 1: es permanente mientras se use el
protocolo SPI clásico de MiST tal cual. (Posible mejora futura: revisar si
`mist-firmware-rp2040` soporta algún opcode extendido de `status` más
ancho — no investigado todavía.)

Menú mínimo propuesto para Fase 1 (bits a definir al escribir el CONF_STR
nuevo): Reset, región (Auto/US/JP/EU), tipo de pad puerto 1/2 (Digital/
Analog/Dualshock), fastboot, aspect ratio. Todo lo demás (cheats,
savestates, turbo, hacks de vídeo, SNAC, multitap, etc.) se difiere a
fases posteriores.

## 6. Funcionalidades explícitamente fuera de alcance en Fase 1

- **Savestates**: en MiSTer usan un bus dedicado de alta velocidad HPS↔DDR3
  (`hps_ext.v`/`EXT_BUS`) sin equivalente factible por SPI a 24MHz con el
  tamaño de estado de PSX. Se elimina `hps_ext.v` del fork; `ss_save`/
  `ss_load` se atan a 0 por ahora.
- **PLL de vídeo dinámico (NTSC/PAL/240p-480i/fast-forward)**: el
  mecanismo original (`pll_cfg`, reconfig Avalon-MM de la IP `altera_pll`)
  es exclusivo de Cyclone V/10/Arria y no existe en Cyclone IV GX. Fase 1
  usa un `clk_vid` fijo (NTSC, 53.693175MHz nominal) generado por un PLL
  **separado** (`pll2.v`, distinto de `pll.v` que da clk_1x/2x/3x) —
  esto es intencional y se queda así aunque de momento sea fijo: así el
  futuro reconfig de vídeo no toca los relojes de CPU/SDRAM.
  **Confirmado que el mecanismo de reconfig SÍ existe en este dispositivo**:
  revisando `neptunoplus/pll2_mist.v` de `delgrom/NeoGeo_FPGA` (el PLL2 que
  ya usan en esta misma placa) el `altpll` que genera Quartus para
  `EP4CGX150DF27I7` expone los puertos de scan-chain
  (`scanclk/scandata/scanclkena/configupdate/scandone`, ahí atados a
  `PORT_UNUSED` porque NeoGeo no los necesita) — es la megafunción
  `ALTPLL_RECONFIG` clásica (el mismo truco que ya usaban los cores de
  MiST desde la época de Cyclone III). **Acción para cuando se genere
  `pll2.v` en Quartus: elegir el modo "reconfigurable" del wizard (no
  el modo fijo/simple)**, para no tener que rehacer el PLL cuando se
  implemente el cambio dinámico NTSC/PAL/240p/480i en una fase posterior
  (falta escribir el bloque de control que maneje `scanclk`/`scandata`/
  `configupdate` — no forma parte del hito 1).
- **SNAC** (pass-through de mando/memory card real vía puerto dedicado):
  requiere pines específicos que no están confirmados en el pinout de
  NeptUNO+. `snacPort1/2` forzados a 0.
- **Framebuffer de depuración HDMI** (`FB_*`, `MISTER_FB`): específico de
  HDMI/ADV7513, no aplica a salida VGA. Eliminado.
- **Gamma correction vía OSD**: dependía de `gamma_bus` desde `hps_io`.
  Simplificado a paso directo hasta que se decida si vale la pena
  re-implementarlo vía `user_io`.
- **`video_freak` + tablas `aspect_ratio_lut_*` + recálculo de hblank
  fijo**: todo esto alimenta el escalador HDMI (`ascal`) de MiSTer
  (metadatos ARX/ARY para VGA_SCALER), que no existe en NeptUNO+ (DAC VGA
  directo). Se elimina del fork; la salida de vídeo pasa directo del core
  (`hs/vs/hbl/vbl/r/g/b`) al `osd.v` de `mist-modules` (que se puede
  insertar directamente entre el core y los pines VGA físicos, ya que el
  GPU de PSX ya genera timing VGA correcto por sí mismo — no hace falta
  `mist_video.v`/scandoubler) y de ahí a los pines VGA.
- **CHD**: `mist-firmware` no soporta CHD (solo CUE+BIN e ISO plano) — no
  se persigue soporte CHD en este port.
- **CD-ROM (CUE+BIN)**: no es Fase 1, pero gracias a §3 y a que `psx.c` ya
  existe en el firmware, es la Fase 2 más corta de lo esperado en un
  principio. Ver §8.

## 7. Relojes

Dos módulos PLL, regenerados para Cyclone IV GX / `EP4CGX150DF27I7` a
partir de los originales `rtl/pll.v`/`rtl/pll2.v` (IP `altera_pll`,
Cyclone V). **Importante:** aunque se llaman igual (`pll`/`pll2`), estos
NO son los mismos archivos que los de MiSTer — hay que generarlos y
guardarlos dentro de `neptunoplus/` (como `neptunoplus/pll.v`/`.qip` y
`neptunoplus/pll2.v`/`.qip`), no sobrescribir `rtl/pll.v`/`rtl/pll2.v`,
porque esos siguen siendo los que usa el build de MiSTer para Cyclone V.

| Módulo     | Señal     | Frecuencia     | Uso                              |
|------------|-----------|---------------:|-----------------------------------|
| `pll.v`     | `clk_1x`  | 33.8688 MHz    | reloj de sistema/CPU (33.8688=44100×768) |
| `pll.v`     | `clk_2x`  | 67.7376 MHz    | 2× (ya no alimenta DDRAM_CLK, ese bus se eliminó — ver §4) |
| `pll.v`     | `clk_3x`  | 101.6064 MHz   | dominio de la SDRAM principal y expansión |
| `pll2.v` | `clk_vid` | 53.693175 MHz  | reloj de píxel (NTSC, fijo en Fase 1) |

`pll2.v` se mantiene como **PLL separado** (no fusionado con `pll.v`)
a propósito: en una fase posterior necesitamos reconfigurar el reloj de
vídeo en tiempo real (NTSC/PAL, 240p/480i) sin tocar los relojes de CPU/
SDRAM — ver §6 para la confirmación de que el mecanismo de reconfig
(`ALTPLL_RECONFIG` por scan-chain) sí existe en este dispositivo. Al
generar `pll2.v` en el IP Catalog, usar el modo **reconfigurable**, no
el modo fijo/simple.

Ambos PLLs derivados de `CLOCK_50` (50MHz, pin `B14` confirmado en el
pinout).

**Importante:** 101.6064MHz coincide casi exactamente con el `FMAX_REQUIREMENT
"101.58 MHz"` que usa el `.sdc` de `NeoGeo_neptunoplus` en el **mismo
dispositivo físico** (`EP4CGX150DF27I7`) — buena señal de que el timing es
alcanzable en este FPGA con un diseño de complejidad comparable.

**Acción pendiente que requiere Quartus (GUI, no lo puedo generar yo de
forma fiable sin la herramienta):** generar, **dentro de la carpeta
`neptunoplus/`**, dos IP `altpll` (no `altera_pll`) llamados `pll` y
`pll2` para `Cyclone IV GX` / dispositivo `EP4CGX150DF27I7`, con
referencia `CLOCK_50` (50MHz) y las frecuencias de salida de la tabla de
arriba (`pll2` en modo reconfigurable). Usar el IP Catalog de Quartus
(`ALTPLL` megafunction) en vez de intentar derivar a mano los enteros
M/N/C — la herramienta los calcula de forma óptima y verificada.
`files.qip` ya espera encontrarlos como `neptunoplus/pll.qip` y
`neptunoplus/pll2.qip`.

## 8. Plan de hitos

1. **[EN CURSO] Arquitectura + andamiaje** — este documento, submódulo
   `mist-modules`, pinout confirmado.
2. **Reescritura de `neptunoplus/psx_mist.sv`** (fork de `PSX.sv`): swap
   `hps_io`→`user_io`+`data_io`, mux de `sd_lba`, `MISTER_DUAL_SDRAM=1`
   activado (2ª SDRAM real, ver §4 — sin puente nuevo, ya existe en el
   core), CONF_STR recortado a 64 bits, PLL fijo sin reconfig, sin
   SNAC/savestates/gamma/video_freak/FB.
3. **Proyecto Quartus** `PSX_neptunoplus.qsf/.qpf/.sdc` para
   `EP4CGX150DF27I7` (pinout de §1, incluyendo `SDRAM2_*` de
   `NeoGeo_neptunoplus_dr.qsf`).
4. **Regenerar PLLs en Quartus** (usuario, ver §7) y primera compilación.
5. **Primer arranque en hardware real**: BIOS + homebrew `.exe`, sin CD.
   Iterar sobre errores de compilación/timing/vídeo que reporte el usuario.
6. **Firmware RP2040**: activar `psx.c` (`HAVE_PSX`, CMakeLists). Verificar
   handshake `CORE_TYPE_8BIT`/`FEAT_PSX` desde el gateware.
7. **CD-ROM (CUE+BIN)** usando el mecanismo genérico ya confirmado (§3).
8. Reincorporar funcionalidades diferidas (§6) según prioridad: savestates,
   SNAC, menú OSD completo, PAL/NTSC dinámico.

## 9. Archivos de este port

- `neptunoplus/mist-modules/` — submódulo `mist-devel/mist-modules`.
- `neptunoplus/psx_mist.sv` — módulo `psx_mist_core`, es el `TOP_LEVEL_ENTITY`
  directamente (ver §0 sobre por qué no hay un wrapper separado).
- `neptunoplus/PSX_neptunoplus.qpf/.qsf/.sdc` + `neptunoplus/files.qip` — proyecto
  Quartus para `EP4CGX150DF27I7`, pinout de `NeoGeo_neptunoplus_dr.qsf`,
  `MISTER_DUAL_SDRAM=1` activado.
- `neptunoplus/pll.v`/`.qip` y `neptunoplus/pll2.v`/`.qip` — **pendientes,
  hay que regenerarlos en Quartus** (ver §7); `psx_mist.sv` ya instancia
  módulos llamados `pll` (salidas `outclk_0/1/2` = clk_1x/2x/3x) y `pll2`
  (salida `outclk_0` = clk_vid, modo reconfigurable) — hay que generarlos
  con esos nombres exactos, **dentro de `neptunoplus/`** (no en `rtl/`,
  que es donde viven los originales de MiSTer para Cyclone V — ver la
  nota en §7 sobre por qué no se pueden mezclar). `files.qip` ya los
  referencia como `pll.qip`/`pll2.qip` (rutas relativas a esta carpeta).

## 10. Puntos a vigilar en la primera compilación

Cosas que decidí con la mejor información disponible pero que **no pude
verificar sin Quartus/simulación** — candidatas más probables a error en
la primera compilación real:

- `neptunoplus/PSX_neptunoplus.sdc` es un punto de partida mínimo (constraints
  básicas de reloj + false paths). El análisis de timing real de
  TimeQuest (sobre todo el dominio `clk_3x`/SDRAM a 101.6MHz) hay que
  revisarlo con el reporte real de Quartus.
- `sd_buff_addr`/`SD_BLKSZ` en `user_io.v`: usé `SD_BLKSZ(1'b0)` (ancho
  17 bits) tomando solo `[8:0]` para las tarjetas de memoria, igual que el
  original — pero no confirmé al 100% que el ancho por defecto sea
  compatible byte a byte con lo que espera `mist-firmware-rp2040` en el
  otro extremo del protocolo SPI.
- El campo `status` de 64 bits y el `CONF_STR` recortado: la sintaxis de
  posición de bits (`O12`, `O47`, etc., un carácter base-36 por posición)
  la tomé de `NeoGeo_MiST.sv` — debería ser correcta para este firmware,
  pero solo se confirma viendo el menú OSD real en la placa.
- `bk_pending`/`saving_memcard`: quedaron cableados pero no hay
  indicador visual de "guardando" en el menú recortado — funcionalmente
  no debería romper nada, es solo una mejora pendiente.
- `build_id.v`: se genera vía `../sys/build_id.tcl` (reusa el script
  existente del proyecto MiSTer) — confirmar que el `PRE_FLOW_SCRIPT_FILE`
  con ruta relativa `../sys/build_id.tcl` resuelve bien desde
  `neptunoplus/output_files` al correr `quartus_sh`.

## 11. Bitácora de compilación real (Quartus 17.0.2, EP4CGX150DF27I7)

1. **1er intento (Analysis & Synthesis falló)**: `rtl/RamMLAB.vhd`
   instanciaba `altdpram` en modo `ram_block_type=>"MLAB"` con
   `rdaddress_reg`/`outdata_reg=>"UNREGISTERED"` (lectura totalmente
   asíncrona/combinacional) — Cyclone IV GX no tiene bloques MLAB y sus
   M9K no pueden hacer esa lectura sin registro. **Arreglado** en
   `rtl/RamMLAB.vhd` (con el visto bueno del usuario, ver commit
   `2a28bff`): se reescribió con VHDL genérico inferido en vez de la
   megafunción explícita, mismo comportamiento funcional exacto, así que
   es compatible hacia atrás con el build de MiSTer/Cyclone V.
2. **2do intento (Analysis & Synthesis falló)**: `sigma_delta_dac` sin
   agregar a `files.qip` (yo lo instancié en `psx_mist.sv` pero olvidé
   incluir `sys/sigma_delta_dac.v`). **Arreglado** en `files.qip`.
3. **3er intento (compiló completo, 0 errores, 604 warnings)**: primer
   bitstream generado. Pero **Critical Warning "Timing requirements not
   met"** en los 3 corners (slow 85°C, slow 0°C, fast 0°C), con TNS muy
   grande (~-1425ns peor caso) concentrado en el dominio `clk_1x`. Causa
   más probable: el `.sdc` marcaba `SPI_SCK` como reloj normal con solo
   *false paths* puntuales en vez de declarar todo ese dominio como
   asíncrono respecto a los relojes del sistema — eso hace que TimeQuest
   intente cronometrar como síncronos los cruces reales de dominio de
   reloj entre los registros internos de `user_io`/`data_io`/`osd` (que
   corren a `SPI_SCK`) y el resto del diseño, generando fallos masivos
   sin relación con el hardware real (esos cruces ya deberían estar
   sincronizados con flip-flops dobles, patrón ya probado en NeoGeo/
   PCEngine). **Arreglado** en `PSX_neptunoplus.sdc` con
   `set_clock_groups -asynchronous` entre `SPI_SCK` y los relojes
   derivados de `pll`/`pll2`.
   - También apareció un Critical Warning de que `pll` no está "fully
     compensated" por recibir su reloj de entrada por un pin remoto —
     esperable al tener dos PLLs alimentados del mismo oscilador físico;
     no resultó ser la causa principal (ver punto 4).
4. **4to intento (compiló, 0 errores, 608 warnings)**: el fix de
   `SPI_SCK` funcionó — ese dominio pasó a slack positivo (+15.265ns).
   Pero seguía fallando timing, ahora concentrado en `pll2|clk[0]`
   (`clk_vid`, peor slack -5.36ns) y en menor medida `pll|clk[0]`/`clk[1]`
   (-2.77/-2.50ns); `pll|clk[2]` (SDRAM a 101.6MHz, el reloj más rápido)
   **ya pasaba** (+0.51ns). El reporte de rutas (`report_timing -setup
   -npaths 20`) mostró que las 20 peores rutas eran **todas** el mismo
   patrón: `errorCode[1]/[3]` (dominio `clk_1x`, dentro de `psx_top`) →
   `gpu_overlay|...|col[]` (dominio `clk_vid`) — el overlay de depuración
   "Error Overlay" (que dejé forzado en `errorOn=1'b1`). Es un cruce de
   reloj real entre `pll` y `pll2` (dos PLLs independientes, sin relación
   de fase), no un problema de lógica lenta.

   Revisando el `.sdc` **original de MiSTer** (`PSX.sdc`, sin modificar,
   en la raíz del repo) confirmé que ya declara explícitamente
   `set_false_path` en ambas direcciones entre los relojes de `pll` y
   `pll2` — exactamente esta relación. Mi `.sdc` tenía un error de
   estructura: había agrupado `pll` y `pll2` **juntos** en un solo grupo
   asíncrono frente a `SPI_SCK` (`-group [get_clocks {pll*}]`), lo cual
   los trata como síncronos *entre sí*, en vez de tratarlos como un tercer
   grupo separado. **Arreglado**: ahora son tres grupos
   (`SPI_SCK` / `pll|*` / `pll2|*`), replicando la intención del `.sdc`
   original de MiSTer. Pendiente de confirmar con una recompilación real
   que esto cierra el timing.
5. **5to intento — el fix de arriba SÍ funcionó, pero costó detectarlo**:
   varias recompilaciones seguidas (incluso borrando `db`/`incremental_db`
   y recompilando completo desde la GUI de Quartus) seguían mostrando,
   vía `report_sdc`/`report_clocks` en la Consola Tcl, que `SPI_SCK`
   tenía período **1.000 ns** (1000 MHz) en vez de los 41.666 ns del
   `.sdc` real — con la sección `Set Clock Groups` directamente ausente
   del reporte, o sea que ni el `set_clock_groups` del punto 4 se estaba
   aplicando. Se descartaron, en orden: contenido del archivo (correcto,
   confirmado con Notepad por fuera de Quartus), organización del
   `.qsf`/`files.qip`, restricciones ocultas en el submódulo
   `mist-modules` (ninguna), caché vieja de compilación. La causa real:
   **la sesión gráfica de TimeQuest se abría sobre un snapshot viejo**
   y no releía el `.sdc` actual del disco pese a recompilar completo
   desde la GUI. Se confirmó corriendo el flujo completo por línea de
   comandos, como proceso totalmente aparte
   (`quartus_sh --flow compile PSX_neptunoplus -c PSX_neptunoplus`),
   que sí leyó el `.sdc` correcto (`SPI_SCK` → 41.666 ns / 24.0 MHz).
   **Lección**: para verificar timing de forma confiable en este
   proyecto, correr `quartus_sh --flow compile` desde línea de comandos
   en vez de confiar en una sesión de Quartus GUI que lleve rato abierta.

   De paso, se reorganizó `SDC_FILE`: estaba como
   `set_global_assignment` directo en `PSX_neptunoplus.qsf`; se movió
   dentro de `neptunoplus/files.qip` (commit `b88f3ac`/`f1d0421`),
   replicando la convención exacta de MiSTer (`files.qip:8` tiene
   `SDC_FILE PSX.sdc`, no el `PSX.qsf` de la raíz) — así el `.qsf` queda
   sin ninguna referencia directa a archivos, todo vive en `files.qip`
   vía `source files.qip`.

   **Resultado de esa compilación limpia por línea de comandos**: 0
   errores, timing prácticamente cerrado. TNS total del diseño:
   **-0.794 ns** (contra los ~-1425 ns del intento 3). Slack por dominio:
   `SPI_SCK` +15.057 ns, `pll2|clk[0]` (clk_vid) +9.822 ns, `pll|clk[1]`
   +1.019 ns, `pll|clk[2]` +0.772 ns — todos positivos. Solo queda
   **`pll|clk[0]`** (clk_1x, 33.85 MHz) con **-0.272 ns** de slack en el
   peor caso (corner Slow 1200mV 85°C).

   La ruta que falla es puramente combinacional, dentro de un único
   dominio de reloj (no es CDC): `rtl/cd_top.vhd` línea 1774,
   ```vhdl
   -- registered, keeps the SPT table and the multiply off the command path
   pause_rotation_ticks <= getSectorsPerTrack(currentLBA) * driveREADSPEED;
   ```
   Es el cálculo de "ticks de una rotación de disco" para la pausa de
   CD-Audio: una tabla de sectores-por-pista más una multiplicación, ya
   registrada intencionalmente por el propio MiSTer para sacarla del
   camino crítico — pero en el fabric más lento de Cyclone IV GX (vs.
   Cyclone V de MiSTer), ese margen ya no alcanza por 0.27 ns.

   **Decisión**: no tocar esto ahora. Es lógica de CD-ROM (rotación/pausa
   de audio) que no se ejercita en el Hito 1 (BIOS/EXE sin CD), y
   `currentLBA` cambia con muy poca frecuencia (solo en seeks/lecturas),
   así que aunque hubiera un glitch puntual ahí, no tiene ningún efecto
   observable sin un CD insertado. Queda pendiente para cuando se aborde
   soporte de CD (Tarea #8): la solución más probable ahí es un
   `set_multicycle_path` sobre este registro específico, ya que
   `currentLBA` no cambia cada ciclo y un ciclo extra de latencia en este
   cálculo es imperceptible para el timing de CD-Audio. **No** es un
   problema de la SDRAM dual, del framework MiST, ni de los PLLs — es
   aislado a esta única línea de `cd_top.vhd`.
