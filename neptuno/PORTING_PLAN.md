# Port de PSX_MiSTer a NeptUNO+ (EP4CGX150 + RP2040/mist-firmware-rp2040)

Este documento es la referencia técnica viva del port. Se actualiza a medida
que avanza el trabajo. Última actualización: ver historial de git.

## 0. Estado

Fase de arquitectura/andamiaje completada. Empezando la reescritura del
módulo "gordo" (`neptuno/psx_mist.sv`, copia sin modificar de `PSX.sv` como
punto de partida). Nada de esto ha sido compilado ni probado en hardware
todavía.

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

- `mist-devel/mist-modules` (submódulo en `neptuno/mist-modules`):
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

## 4. SDRAM — decisión de Fase 1: una sola SDRAM física

`rtl/sdram.sv` (el propio controlador del core PSX) **ya es un controlador
"bare metal" para SDR SDRAM física genérica** (pines `SDRAM_A/DQ/BA/nCS/
nWE/nRAS/nCAS/CKE/CLK`, arbitraje propio de 3 canales + FIFO DMA) — no es
un puente Avalon-HPS. Es prácticamente igual en naturaleza a los
controladores custom que NeoGeo (`sdram_2w_cl2`) y PCEngine (`sdram_amr`)
escribieron para esta misma placa. Se reutiliza casi tal cual, retimando
para los parámetros reales de la SDRAM de la NeptUNO+.

El core también usa un segundo bus, `DDRAM_*` (estilo Avalon burst,
normalmente el puente a la DDR3 del HPS en MiSTer), **exclusivamente para
la RAM del SPU** (512KB) — ver opción de menú "SPU RAM select: DDR3,
SDRAM2". En modo `MISTER_DUAL_SDRAM` este bus se sustituye por una 2ª
SDRAM física completa.

**Decisión Fase 1:** no activar la 2ª SDRAM todavía. En su lugar, escribir
un pequeño puente `neptuno/ddram_bram.sv` que emula la interfaz `DDRAM_*`
usando RAM interna de la FPGA (M9K) para los 512KB de SPU RAM. Esto evita
necesitar un 2º PLL/chip para el primer arranque. EP4CGX150 tiene ~830KB de
memoria embebida total — 512KB para SPU RAM es ajustado pero factible si el
resto de buffers internos del core (cache, líneas de vídeo) no compiten por
el mismo bloque (no lo hacen: usan el canal `ch1/cache_*` de la SDRAM
principal). Si no cierra en área/timing, la alternativa ya probada
(`NeoGeo_neptunoplus_dr` + `pll2_mist`) queda como plan B para activar la
2ª SDRAM real.

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
- **PLL de vídeo dinámico (NTSC/PAL/debug/fast-forward vía reconfig
  Avalon-MM de `pll_cfg`)**: ese mecanismo es exclusivo de la IP
  `altera_pll` (Cyclone V/10/Arria), no existe en Cyclone IV GX (`altpll`
  clásico, reconfig por scan-chain, API distinta). Fase 1 usa un `clk_vid`
  fijo (NTSC, 53.693175MHz nominal). Reconfiguración dinámica PAL/NTSC
  queda para una fase posterior (posiblemente con `altpll_reconfig` o con
  un enfoque de NCO).
- **SNAC** (pass-through de mando/memory card real vía puerto dedicado):
  requiere pines específicos que no están confirmados en el pinout de
  NeptUNO+. `snacPort1/2` forzados a 0.
- **Framebuffer de depuración HDMI** (`FB_*`, `MISTER_FB`): específico de
  HDMI/ADV7513, no aplica a salida VGA. Eliminado.
- **Gamma correction vía OSD**: dependía de `gamma_bus` desde `hps_io`.
  Simplificado a paso directo (`video_gamma = video_aspect`) hasta que se
  decida si vale la pena re-implementarlo vía `user_io`.
- **CHD**: `mist-firmware` no soporta CHD (solo CUE+BIN e ISO plano) — no
  se persigue soporte CHD en este port.
- **CD-ROM (CUE+BIN)**: no es Fase 1, pero gracias a §3 y a que `psx.c` ya
  existe en el firmware, es la Fase 2 más corta de lo esperado en un
  principio. Ver §8.

## 7. Relojes

De `rtl/pll.v`/`rtl/pll2.v` (IP `altera_pll`, Cyclone V, a regenerar):

| Señal     | Frecuencia     | Uso                                   |
|-----------|---------------:|----------------------------------------|
| `clk_1x`  | 33.8688 MHz    | reloj de sistema/CPU (33.8688=44100×768)|
| `clk_2x`  | 67.7376 MHz    | 2×, usado como `DDRAM_CLK`             |
| `clk_3x`  | 101.6064 MHz   | dominio de la SDRAM principal          |
| `clk_vid` | 53.693175 MHz  | reloj de píxel (NTSC, fijo en Fase 1)  |

Todos derivados de `CLOCK_50` (50MHz, pin `B14` confirmado en el pinout).

**Importante:** 101.6064MHz coincide casi exactamente con el `FMAX_REQUIREMENT
"101.58 MHz"` que usa el `.sdc` de `NeoGeo_neptunoplus` en el **mismo
dispositivo físico** (`EP4CGX150DF27I7`) — buena señal de que el timing es
alcanzable en este FPGA con un diseño de complejidad comparable.

**Acción pendiente que requiere Quartus (GUI, no lo puedo generar yo de
forma fiable sin la herramienta):** regenerar `rtl/pll.v` y `rtl/pll2.v`
como IP `altpll` (no `altera_pll`) para `Cyclone IV GX` / dispositivo
`EP4CGX150DF27I7`, con referencia `CLOCK_50` (50MHz) y las frecuencias de
salida de la tabla de arriba. Usar el IP Catalog de Quartus
(`ALTPLL` megafunction) en vez de intentar derivar a mano los enteros
M/N/C — la herramienta los calcula de forma óptima y verificada.

## 8. Plan de hitos

1. **[EN CURSO] Arquitectura + andamiaje** — este documento, submódulo
   `mist-modules`, pinout confirmado.
2. **Reescritura de `neptuno/psx_mist.sv`** (fork de `PSX.sv`): swap
   `hps_io`→`user_io`+`data_io`, mux de `sd_lba`, `ddram_bram.sv`, CONF_STR
   recortado a 64 bits, PLL fijo sin reconfig, sin SNAC/savestates/gamma/FB.
3. **Top-level `psx_neptuno_top.sv`** + `.qsf/.qpf/.sdc` para
   `EP4CGX150DF27I7` (pinout de §1).
4. **Regenerar PLLs en Quartus** (usuario, ver §7) y primera compilación.
5. **Primer arranque en hardware real**: BIOS + homebrew `.exe`, sin CD.
   Iterar sobre errores de compilación/timing/vídeo que reporte el usuario.
6. **Firmware RP2040**: activar `psx.c` (`HAVE_PSX`, CMakeLists). Verificar
   handshake `CORE_TYPE_8BIT`/`FEAT_PSX` desde el gateware.
7. **CD-ROM (CUE+BIN)** usando el mecanismo genérico ya confirmado (§3).
8. Reincorporar funcionalidades diferidas (§6) según prioridad: savestates,
   SNAC, menú OSD completo, PAL/NTSC dinámico, posible 2ª SDRAM para ancho
   de banda extra en CD a velocidades altas.

## 9. Archivos de este port

- `neptuno/mist-modules/` — submódulo `mist-devel/mist-modules`.
- `neptuno/psx_mist.sv` — **WIP**: copia sin modificar de `../PSX.sv` como
  punto de partida; se irá reescribiendo en el hito 2.
- `neptuno/psx_neptuno_top.sv` — pendiente (hito 3).
- `neptuno/ddram_bram.sv` — pendiente (hito 2).
- `neptuno/psx_neptuno.qsf/.qpf/.sdc` — pendiente (hito 3).
