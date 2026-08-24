//============================================================================
//  PSX for NeptUNO+ (EP4CGX150 + RP2040/mist-firmware-rp2040)
//
//  Phase 1 port: forked from ../PSX.sv (MiSTer_PSX, Robert Peip / Sorgelig).
//  See neptuno/PORTING_PLAN.md for the full rationale of every change here.
//
//  Summary of what changed vs. the MiSTer original:
//   - hps_io  -> mist-modules' user_io + data_io (classic MiST SPI protocol,
//     spoken natively by mist-firmware-rp2040 on the NeptUNO+'s RP2040).
//   - DDRAM_* (HPS DDR3 bridge, used for live GPU VRAM + memcard + SPU RAM
//     traffic - NOT just SPU RAM as the menu label suggests) is replaced by
//     a second physical SDRAM chip: MISTER_DUAL_SDRAM is always enabled,
//     matching NeptUNO+'s actual hardware (64MB onboard + 64MB expansion)
//     and this repo's own existing PSX_DualSDRAM build variant.
//   - CONF_STR trimmed hard: user_io's `status` register is 64 bits wide
//     (confirmed against two independent NeptUNO+ implementations), not the
//     128 bits hps_io provides. Phase 1 only exposes Reset/Region/Fastboot/
//     Pad1/Pad2 via OSD; everything else is a fixed, hardcoded default.
//   - Removed for Phase 1 (see PORTING_PLAN.md §6 for why each is out of
//     scope, not just "not done yet"): savestates, SNAC passthrough, the
//     dynamic NTSC/PAL/fast-forward pll_cfg reconfig (Cyclone V-only IP),
//     the MiSTer HDMI debug framebuffer, video_freak/aspect-ratio-LUT
//     scaler metadata (no scaler on NeptUNO+, direct VGA out), gamma
//     correction, cheats file loading, PS/2 mouse.
//
//  *** First-draft RTL, not yet compiled or hardware-tested. ***
//  Written by reading interfaces, not by simulation - expect to iterate on
//  real Quartus/hardware feedback. Flag anything suspicious in review.
//============================================================================

module psx_mist_core
(
	input         CLOCK_50,

	// Classic MiST SPI link to the RP2040 IO controller
	input         SPI_SCK,
	input         SPI_DI,
	inout         SPI_DO,
	input         SPI_SS2,   // data_io  (ROM/EXE/CD-metadata uploads)
	input         SPI_SS3,   // osd
	input         SPI_SS4,   // data_io  QSPI select (unused, tied off)
	input         CONF_DATA0,// user_io  (options, joystick, sd image mgmt)

	// Main SDRAM (onboard, 64MB) - CPU/GPU main RAM, BIOS, cache, DMA
	inout  [15:0] SDRAM_DQ,
	output [12:0] SDRAM_A,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output  [1:0] SDRAM_BA,
	output        SDRAM_nCS,
	output        SDRAM_nWE,
	output        SDRAM_nRAS,
	output        SDRAM_nCAS,
	output        SDRAM_CKE,
	output        SDRAM_CLK,

	// Expansion SDRAM (64MB) - GPU VRAM + memory card + SPU RAM traffic
	// (replaces MiSTer's DDRAM/HPS-DDR3 bridge, see header comment)
	inout  [15:0] SDRAM2_DQ,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	output        SDRAM2_nCS,
	output        SDRAM2_nWE,
	output        SDRAM2_nRAS,
	output        SDRAM2_nCAS,
	output        SDRAM2_CLK,

	// VGA (24 bit resistor-ladder DAC on the NeptUNO+ DB FPGA board)
	output        VGA_HS,
	output        VGA_VS,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,

	// Analog audio out (sigma-delta, Phase 1 - I2S/PCM5121 path deferred)
	output        AUDIO_L,
	output        AUDIO_R
);

///////////////////////////  CLOCK/RESET  ///////////////////////////////////

// Same two-PLL split as the original MiSTer design (rtl/pll.v / rtl/
// pll2.v), regenerated for Cyclone IV GX / EP4CGX150DF27I7 - same module
// names too (pll / pll2), just retargeted, rather than renamed. See
// PORTING_PLAN.md §7 for the exact target frequencies (33.8688 / 67.7376
// / 101.6064 / 53.693175 MHz from a 50MHz CLOCK_50 reference).
//
// pll2 is kept separate from pll on purpose: the original's dynamic
// NTSC/PAL/fast-forward pixel-clock reconfig (pll_cfg, Avalon-MM reconfig
// of an `altera_pll`) is Cyclone V/10/Arria-only IP and has no direct
// equivalent here, so clk_vid is fixed (NTSC) for now - but pll2 should
// still be generated in the wizard's *reconfigurable* mode (exposing the
// classic ALTPLL_RECONFIG scan-chain ports), since NeoGeo_FPGA's own
// neptunoplus/pll2_mist.v confirms that mechanism is available on this
// device, and a later phase will drive it to switch NTSC/PAL/240p/480i
// without touching the CPU/SDRAM clocks in pll.
wire pll_locked;
wire clk_1x;   // 33.8688 MHz - system/CPU clock
wire clk_2x;   // 67.7376 MHz
wire clk_3x;   // 101.6064 MHz - main SDRAM domain
wire clk_vid;  // 53.693175 MHz - pixel clock (NTSC, fixed for now)

pll pll
(
	.refclk(CLOCK_50),
	.rst(1'b0),
	.outclk_0(clk_1x),
	.outclk_1(clk_2x),
	.outclk_2(clk_3x),
	.locked(pll_locked)
);

pll2 pll2
(
	.refclk(CLOCK_50),
	.rst(1'b0),
	.outclk_0(clk_vid),
	.locked()
);

wire reset_or = status[0] | bios_download | exe_download | cdDownloadReset;

////////////////////////////  MIST IO  ///////////////////////////////////

// Status Bit Map (Phase 1 - only 12 of 64 bits used, see PORTING_PLAN.md §5):
// 0     : Reset (momentary trigger)
// 2:1   : Region (0=Auto,1=US,2=JP,3=EU)
// 3     : Fastboot (skip BIOS, only takes effect once a CD is mounted)
// 7:4   : Pad1 type
// 11:8  : Pad2 type
`include "build_id.v"
localparam CONF_STR = {
	"PSX;;",
	"F0,BIN,Load Bios;",
	"F1,EXE,Load Exe;",
	"-;",
	"O12,Region,Auto,US,JP,EU;",
	"O3,Fastboot,Off,On;",
	"O47,Pad1,DualShock,Off,Digital,Analog,GunCon,NeGcon,WheelNeGcon,WheelAnalog,Mouse,Justifier,SNAC,AnalogJoystick,Popn,-,-,-;",
	"O8B,Pad2,DualShock,Off,Digital,Analog,GunCon,NeGcon,WheelNeGcon,WheelAnalog,Mouse,Justifier,SNAC,AnalogJoystick,Popn,-,-,-;",
	"-;",
	"T0,Reset;",
	"V,v",`BUILD_DATE
};

wire  [1:0] buttons;
wire [63:0] status;

wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3, joystick_4;
wire [31:0] joystick_analog_0, joystick_analog_1;
wire [15:0] joystick_analog_l0 = joystick_analog_0[15:0];
wire [15:0] joystick_analog_r0 = joystick_analog_0[31:16];
wire [15:0] joystick_analog_l1 = joystick_analog_1[15:0];
wire [15:0] joystick_analog_r1 = joystick_analog_1[31:16];

// joystick_0/1 bit layout (classic MiST convention, same as MiSTer's
// joystick_0/1): [0]=right [1]=left [2]=down [3]=up [4]=triangle/Y
// [5]=circle/B [6]=cross/A [7]=square/X [8]=select [9]=start
// [10]=L1 [11]=R1 [12]=L2 [13]=R2 [14]=L3 [15]=R3
wire [19:0] joy  = joystick_0[19:0];
wire [19:0] joy2 = joystick_1[19:0];
wire [19:0] joy3 = 20'd0; // multitap out of scope in Phase 1
wire [19:0] joy4 = 20'd0;

wire        spi_do_uio, spi_do_data_io;
assign SPI_DO = ~CONF_DATA0 ? spi_do_uio : ~SPI_SS2 ? spi_do_data_io : 1'bz;

wire [31:0] sd_lba1; // CD image (channel 1)
wire  [6:0] sd_lba2; // memory card 1 (channel 2)
wire  [6:0] sd_lba3; // memory card 2 (channel 3)
wire  [3:0] sd_rd, sd_wr;
wire  [3:0] sd_ack_x;
wire [16:0] sd_buff_addr;
wire [15:0] sd_buff_dout; // MCU -> core
wire [15:0] sd_buff_din2, sd_buff_din3; // core -> MCU
wire        sd_buff_wr;
wire  [3:0] img_mounted;
wire [63:0] img_size;

wire [31:0] sd_lba_mux = sd_rd[1] | sd_wr[1] ? sd_lba1 :
                          sd_rd[2] | sd_wr[2] ? {25'd0, sd_lba2} :
                          sd_rd[3] | sd_wr[3] ? {25'd0, sd_lba3} : 32'd0;
wire [15:0] sd_din_mux  = sd_wr[2] ? sd_buff_din2 : sd_wr[3] ? sd_buff_din3 : 16'd0;

user_io #(.STRLEN($size(CONF_STR)>>3), .SD_IMAGES(4), .SD_BLKSZ(1'b0)) user_io
(
	.conf_str(CONF_STR),
	.conf_addr(),
	.conf_chr(8'h00),

	.clk_sys(clk_1x),
	.clk_sd(clk_1x),

	.SPI_CLK(SPI_SCK),
	.SPI_SS_IO(CONF_DATA0),
	.SPI_MISO(spi_do_uio),
	.SPI_MOSI(SPI_DI),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),
	.joystick_4(),
	.joystick_analog_0(joystick_analog_0),
	.joystick_analog_1(joystick_analog_1),
	.buttons(buttons),
	.switches(),
	.scandoubler_disable(),
	.ypbpr(),
	.no_csync(),
	.status(status),
	.core_mod(),
	.rtc(),

	.sd_lba(sd_lba_mux),
	.sd_cnt(8'd0),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(),
	.sd_ack_conf(),
	.sd_ack_x(sd_ack_x),
	.sd_conf(1'b0),
	.sd_sdhc(1'b1),
	.sd_dout(sd_buff_dout),
	.sd_dout_strobe(sd_buff_wr),
	.sd_din(sd_din_mux),
	.sd_din_strobe(),
	.sd_buff_addr(sd_buff_addr),

	.img_mounted(img_mounted),
	.img_size(img_size),

	.ps2_kbd_clk(), .ps2_kbd_data(), .ps2_kbd_clk_i(1'b1), .ps2_kbd_data_i(1'b1),
	.ps2_mouse_clk(), .ps2_mouse_data(), .ps2_mouse_clk_i(1'b1), .ps2_mouse_data_i(1'b1),

	.key_pressed(), .key_extended(), .key_code(), .key_strobe(),
	.kbd_out_data(8'h00), .kbd_out_strobe(1'b0),
	.leds(8'h00),

	.mouse_x(), .mouse_y(), .mouse_z(), .mouse_flags(), .mouse_strobe(), .mouse_idx(),

	.i2c_start(), .i2c_read(), .i2c_addr(), .i2c_subaddr(), .i2c_dout(),
	.i2c_din(8'h00), .i2c_ack(1'b0), .i2c_end(1'b0),

	.serial_data(8'h00), .serial_strobe(1'b0)
);

wire        ioctl_download;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wr;
wire  [7:0] ioctl_index;

data_io #(.DOUT_16(1'b1)) data_io
(
	.clk_sys(clk_1x),
	.SPI_SCK(SPI_SCK),
	.SPI_SS2(SPI_SS2),
	.SPI_SS4(SPI_SS4),
	.SPI_DI(SPI_DI),
	.SPI_DO(spi_do_data_io),

	.QCSn(1'b1), .QSCK(1'b0), .QDAT(4'h0),
	.clkref_n(1'b0), // no extra pacing needed - see PORTING_PLAN.md/NeoGeo ref

	.ioctl_download(ioctl_download),
	.ioctl_upload(),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(8'h00),
	.ioctl_fileext(),
	.ioctl_filesize(),

	.hdd_clk(1'b0), .hdd_cmd_req(1'b0), .hdd_cdda_req(1'b0), .hdd_dat_req(1'b0),
	.hdd_cdda_wr(), .hdd_status_wr(), .hdd_addr(), .hdd_wr(),
	.hdd_data_out(), .hdd_data_in(16'h0), .hdd_data_rd(), .hdd_data_wr(),
	.hdd0_ena(), .hdd1_ena()
);

//////////////////////////  ROM DETECT  /////////////////////////////////

reg bios_download, exe_download, cdinfo_download;
always @(posedge clk_1x) begin
	bios_download    <= ioctl_download & (ioctl_index[5:0] == 0);
	exe_download     <= ioctl_download & (ioctl_index == 1);
	cdinfo_download  <= ioctl_download & (ioctl_index == 251); // unused in Phase 1 (no CD yet)
end

localparam EXE_START = 16777216;

reg [26:0] ramdownload_wraddr;
reg [31:0] ramdownload_wrdata;
reg        ramdownload_wr;

reg        hasCD = 0; // no CD support in Phase 1 - always 0

reg exe_download_1 = 0;
reg loadExe = 0;

reg sd_mounted2 = 0;
reg sd_mounted3 = 0;

reg memcard1_load = 0;
reg memcard2_load = 0;
reg memcard_save = 0;

wire saving_memcard;

reg memcard1_inserted = 0;
reg memcard2_inserted = 0;
reg [25:0] memcard1_cnt = 0;
reg [25:0] memcard2_cnt = 0;

reg cdbios = 0;
reg  [1:0] region;
reg  [1:0] biosregion;
wire [1:0] region_out;
reg        isPal;

reg [31:0] exe_initial_pc;
reg [31:0] exe_initial_gp;
reg [31:0] exe_load_address;
reg [31:0] exe_file_size;
reg [31:0] exe_stackpointer;

always @(posedge clk_1x) begin
	ramdownload_wr <= 0;
	if (exe_download | bios_download) begin
		if (ioctl_wr) begin
			if (~ioctl_addr[1]) begin
				ramdownload_wrdata[15:0] <= ioctl_dout;
				if (bios_download)     ramdownload_wraddr <= {4'd1, 2'b00, ioctl_index[7:6], ioctl_addr[18:0]};
				else if (exe_download) ramdownload_wraddr <= ioctl_addr[22:0] + EXE_START[26:0];
			end else begin
				ramdownload_wrdata[31:16] <= ioctl_dout;
				ramdownload_wr            <= 1;
			end
		end
	end

	exe_download_1 <= exe_download;
	loadExe        <= exe_download_1 & ~exe_download;

	if (exe_download & ramdownload_wr) begin
		if (ramdownload_wraddr[22:0] == 'h10) exe_initial_pc   <= ramdownload_wrdata;
		if (ramdownload_wraddr[22:0] == 'h14) exe_initial_gp   <= ramdownload_wrdata;
		if (ramdownload_wraddr[22:0] == 'h18) exe_load_address <= ramdownload_wrdata;
		if (ramdownload_wraddr[22:0] == 'h1C) exe_file_size    <= ramdownload_wrdata;
		if (ramdownload_wraddr[22:0] == 'h30) exe_stackpointer <= ramdownload_wrdata;
		if (ramdownload_wraddr[22:0] == 'h34) exe_stackpointer <= exe_stackpointer + ramdownload_wrdata;
	end

	case (status[2:1])
		0: begin // Auto
			case (region_out)
				0: begin region = 2'b00; isPal <= 0; end // unknown => default to NTSC
				1: begin region = 2'b01; isPal <= 0; end // JP
				2: begin region = 2'b00; isPal <= 0; end // US
				3: begin region = 2'b10; isPal <= 1; end // EU
			endcase
		end
		1: begin region = 2'b00; isPal <= 0; end // US
		2: begin region = 2'b01; isPal <= 0; end // JP
		3: begin region = 2'b10; isPal <= 1; end // EU
	endcase

	if (bios_download && ioctl_index[7:6] == 2'b11) cdbios <= 1'b1;
	biosregion <= cdbios ? 2'b11 : region;

	memcard1_load <= 0;
	memcard2_load <= 0;
	memcard_save  <= 0;

	// memcard 1
	if (img_mounted[2]) begin
		memcard1_inserted <= 0;
		memcard1_cnt      <= 26'd0;
		sd_mounted2       <= (img_size > 0);
		if (img_size > 0) memcard1_load <= 1;
	end
	if (sd_mounted2) begin
		if (memcard1_cnt[25]) memcard1_inserted <= 1;
		else memcard1_cnt <= memcard1_cnt + 1'd1;
	end

	// memcard 2
	if (img_mounted[3]) begin
		memcard2_inserted <= 0;
		memcard2_cnt      <= 26'd0;
		sd_mounted3       <= (img_size > 0);
		if (img_size > 0) memcard2_load <= 1;
	end
	if (sd_mounted3) begin
		if (memcard2_cnt[25]) memcard2_inserted <= 1;
		else memcard2_cnt <= memcard2_cnt + 1'd1;
	end
end

wire resetFromCD;
reg  cdDownloadReset = 0;
always @(posedge clk_1x) cdDownloadReset <= 0; // no CD in Phase 1, never set

////////////////////////////  PAD  ///////////////////////////////////

// 0000 -> DualShock, 0001 -> off, 0010 -> digital, 0011 -> analog,
// 0100 -> GunCon, 0101 -> NeGcon, 0110 -> Wheel NeGcon, 0111 -> Wheel Analog,
// 1000 -> mouse, 1001 -> Justifier, 1010 -> SNAC(unused, behaves as off),
// 1011 -> Analog Joystick, 1100 -> Pop'n
wire [3:0] Pad1Type = status[7:4];
wire [3:0] Pad2Type = status[11:8];

wire PadPortDS1      = (Pad1Type == 4'b0000);
wire PadPortEnable1  = (Pad1Type != 4'b0001);
wire PadPortDigital1 = (Pad1Type == 4'b0010) || (Pad1Type == 4'b1100);
wire PadPortAnalog1  = (Pad1Type == 4'b0011) || (Pad1Type == 4'b0111);
wire PadPortGunCon1  = (Pad1Type == 4'b0100);
wire PadPortNeGcon1  = (Pad1Type == 4'b0101) || (Pad1Type == 4'b0110);
wire PadPortWheel1   = (Pad1Type == 4'b0110) || (Pad1Type == 4'b0111);
wire PadPortMouse1   = (Pad1Type == 4'b1000);
wire PadPortJustif1  = (Pad1Type == 4'b1001);
wire PadPortStick1   = (Pad1Type == 4'b1011);
wire PadPortPopn1    = (Pad1Type == 4'b1100);

wire PadPortDS2      = (Pad2Type == 4'b0000);
wire PadPortEnable2  = (Pad2Type != 4'b0001);
wire PadPortDigital2 = (Pad2Type == 4'b0010) || (Pad2Type == 4'b1100);
wire PadPortAnalog2  = (Pad2Type == 4'b0011) || (Pad2Type == 4'b0111);
wire PadPortGunCon2  = (Pad2Type == 4'b0100);
wire PadPortNeGcon2  = (Pad2Type == 4'b0101) || (Pad2Type == 4'b0110);
wire PadPortWheel2   = (Pad2Type == 4'b0110) || (Pad2Type == 4'b0111);
wire PadPortMouse2   = (Pad2Type == 4'b1000);
wire PadPortJustif2  = (Pad2Type == 4'b1001);
wire PadPortStick2   = (Pad2Type == 4'b1011);
wire PadPortPopn2    = (Pad2Type == 4'b1100);

reg paddleMode = 0;
reg paddleMin = 0;
reg paddleMax = 0;
wire [7:0] joy0_xmuxed = joystick_analog_l0[7:0];

wire [1:0] padMode;
reg  [1:0] padMode_1;

reg [3:0] ToggleDS = 0;
reg [3:0] joy19_1 = 0;

always @(posedge clk_1x) begin
	padMode_1 <= padMode;
	joy19_1 <= {1'b0, 1'b0, joy2[19], joy[19]};
	ToggleDS[0] <= joy[19]  & ~joy19_1[0];
	ToggleDS[1] <= joy2[19] & ~joy19_1[1];
	ToggleDS[2] <= 1'b0;
	ToggleDS[3] <= 1'b0;
end

////////////////////////////  PAUSE and RESET  ///////////////////////////
reg paused = 0;
reg reset = 0;

reg buttonpause_1 = 0;
reg button_paused = 0;

always @(posedge clk_1x) begin
	paused <= 0;

	buttonpause_1 <= joy[18];
	if (joy[18] & ~buttonpause_1) button_paused <= ~button_paused;
	if (button_paused) paused <= 1;

	reset <= 0;
	if (reset_or) reset <= 1;
end

////////////////////////////  SYSTEM  ///////////////////////////////////

wire ce_pix, isPaused;
wire [7:0] r, g, b;
wire hs, vs, hbl, vbl, video_interlace, video_isPal, video_fbmode, video_fb24;
wire [2:0] video_hResMode;
wire [11:0] DisplayWidth, DisplayHeight;
wire [9:0] DisplayOffsetX;
wire [8:0] DisplayOffsetY;
wire [3:0] frameindex;

psx_mister
psx
(
	.clk1x(clk_1x),
	.clk2x(clk_2x),
	.clk3x(clk_3x),
	.clkvid(clk_vid),
	.reset(reset),
	.isPaused(isPaused),
	.pause(paused),
	.hps_busy(1'b0),
	.loadExe(loadExe),
	.exe_initial_pc(exe_initial_pc),
	.exe_initial_gp(exe_initial_gp),
	.exe_load_address(exe_load_address),
	.exe_file_size(exe_file_size),
	.exe_stackpointer(exe_stackpointer),
	.fastboot(status[3] && hasCD),
	.ram8mb(1'b0),
	.TURBO_MEM(1'b0),
	.TURBO_COMP(1'b0),
	.TURBO_CACHE(1'b0),
	.TURBO_CACHE50(1'b0),
	.REPRODUCIBLEGPUTIMING(0),
	.INSTANTSEEK(1'b0),
	.FORCECDSPEED(3'd0),
	.LIMITREADSPEED(1'b0),
	.IGNORECDDMATIMING(1'b0),
	.ditherOff(1'b0),
	.interlaced480pHack(1'b0),
	.showGunCrosshairs(1'b0),
	.enableNeGconRumble(1'b0),
	.fpscountOn(1'b0),
	.cdslowOn(1'b0),
	.testSeek(1'b0),
	.pauseOnCDSlow(1'b1),
	.errorOn(1'b1),
	.LBAOn(1'b0),
	.PATCHSERIAL(0),
	.noTexture(1'b0),
	.textureFilter(2'b00),
	.textureFilterStrength(2'b00),
	.textureFilter2DOff(1'b0),
	.dither24(1'b0),
	.render24(1'b0),
	.drawSlow(1'b0),
	.syncVideoOut(1'b0),
	.syncInterlace(1'b0),
	.rotate180(1'b0),
	.fixedVBlank(1'b0),
	.vCrop(2'b00),
	.hCrop(1'b0),
	.SPUon(1'b1),
	.SPUIRQTrigger(1'b0),
	.SPUSDRAM(1'b1), // always use the 2nd SDRAM path, see header comment
	.REVERBOFF(0),
	.REPRODUCIBLESPUDMA(1'b0),
	.WIDESCREEN(2'b00),
	.oldGPU(1'b0),
	// RAM/BIOS interface
	.biosregion(biosregion),
	.ram_refresh(sdr_refresh),
	.ram_dataWrite(sdr_sdram_din),
	.ram_dataRead32(sdr_sdram_dout32),
	.ram_Adr(sdram_addr),
	.ram_cntDMA(sdram_cntDMA),
	.ram_be(sdram_be),
	.ram_rnw(sdram_rnw),
	.ram_ena(sdram_req),
	.ram_dma(sdram_dma),
	.ram_cache(sdram_cache),
	.ram_done(sdram_ack),
	.ram_dmafifo_adr  (sdram_dmafifo_adr),
	.ram_dmafifo_data (sdram_dmafifo_data),
	.ram_dmafifo_empty(sdram_dmafifo_empty),
	.ram_dmafifo_read (sdram_dmafifo_read),
	.cache_wr(cache_wr),
	.cache_data(cache_data),
	.cache_addr(cache_addr),
	.dma_wr(dma_wr),
	.dma_reqprocessed(dma_reqprocessed),
	.dma_data(dma_data),
	// DDRAM bus: unused, always parked idle (SPUSDRAM=1 routes this
	// traffic to the 2nd physical SDRAM via spuram_* below instead)
	.DDRAM_BUSY      (1'b0),
	.DDRAM_BURSTCNT  (),
	.DDRAM_ADDR      (),
	.DDRAM_DOUT      (64'd0),
	.DDRAM_DOUT_READY(1'b0),
	.DDRAM_RD        (),
	.DDRAM_DIN       (),
	.DDRAM_BE        (),
	.DDRAM_WE        (),
	// cd - no CD support in Phase 1, cd_hps_* parked idle
	.region          (region),
	.region_out      (region_out),
	.hasCD           (hasCD),
	.LIDopen         (1'b0),
	.fastCD          (0),
	.trackinfo_data  (ramdownload_wrdata),
	.trackinfo_addr  (ramdownload_wraddr[10:2]),
	.trackinfo_write (1'b0),
	.resetFromCD     (resetFromCD),
	.cd_hps_req      (sd_rd[1]),
	.cd_hps_lba      (sd_lba1),
	.cd_hps_ack      (sd_ack_x[1]),
	.cd_hps_write    (sd_buff_wr),
	.cd_hps_data     (sd_buff_dout),
	// spuram - goes to the 2nd physical SDRAM (see MEMORY section)
	.spuram_dataWrite(spuram_dataWrite),
	.spuram_Adr      (spuram_Adr      ),
	.spuram_be       (spuram_be       ),
	.spuram_rnw      (spuram_rnw      ),
	.spuram_ena      (spuram_ena      ),
	.spuram_dataRead (spuram_dataRead ),
	.spuram_done     (spuram_done     ),
	// memcard
	.memcard_changed (bk_pending),
	.saving_memcard  (saving_memcard),
	.memcard1_load   (memcard1_load),
	.memcard2_load   (memcard2_load),
	.memcard_save    (memcard_save),
	.memcard1_mounted   (sd_mounted2),
	.memcard1_available (memcard1_inserted),
	.memcard1_rd     (sd_rd[2]),
	.memcard1_wr     (sd_wr[2]),
	.memcard1_lba    (sd_lba2),
	.memcard1_ack    (sd_ack_x[2]),
	.memcard1_write  (sd_buff_wr),
	.memcard1_addr   (sd_buff_addr[8:0]),
	.memcard1_dataIn (sd_buff_dout),
	.memcard1_dataOut(sd_buff_din2),
	.memcard2_mounted   (sd_mounted3),
	.memcard2_available (memcard2_inserted),
	.memcard2_rd     (sd_rd[3]),
	.memcard2_wr     (sd_wr[3]),
	.memcard2_lba    (sd_lba3),
	.memcard2_ack    (sd_ack_x[3]),
	.memcard2_write  (sd_buff_wr),
	.memcard2_addr   (sd_buff_addr[8:0]),
	.memcard2_dataIn (sd_buff_dout),
	.memcard2_dataOut(sd_buff_din3),
	// video
	.videoout_on     (1'b1),
	.isPal           (isPal),
	.pal60           (1'b0),
	.hsync           (hs),
	.vsync           (vs),
	.hblank          (hbl),
	.vblank          (vbl),
	.DisplayWidth    (DisplayWidth),
	.DisplayHeight   (DisplayHeight),
	.DisplayOffsetX  (DisplayOffsetX),
	.DisplayOffsetY  (DisplayOffsetY),
	.video_ce        (ce_pix),
	.video_interlace (video_interlace),
	.video_r         (r),
	.video_g         (g),
	.video_b         (b),
	.video_isPal     (video_isPal),
	.video_fbmode    (video_fbmode),
	.video_fb24      (video_fb24),
	.video_hResMode  (video_hResMode),
	.video_frameindex(frameindex),
	//Keys
	.DSAltSwitchMode(1'b0),
	.PadPortEnable1 (PadPortEnable1),
	.PadPortDigital1(PadPortDigital1),
	.PadPortAnalog1 (PadPortAnalog1),
	.PadPortMouse1  (PadPortMouse1 ),
	.PadPortGunCon1 (PadPortGunCon1),
	.PadPortNeGcon1 (PadPortNeGcon1),
	.PadPortWheel1  (PadPortWheel1),
	.PadPortDS1     (PadPortDS1),
	.PadPortJustif1 (PadPortJustif1),
	.PadPortStick1  (PadPortStick1),
	.PadPortPopn1   (PadPortPopn1),
	.PadPortEnable2 (PadPortEnable2),
	.PadPortDigital2(PadPortDigital2),
	.PadPortAnalog2 (PadPortAnalog2),
	.PadPortMouse2  (PadPortMouse2 ),
	.PadPortGunCon2 (PadPortGunCon2),
	.PadPortNeGcon2 (PadPortNeGcon2),
	.PadPortWheel2  (PadPortWheel2),
	.PadPortDS2     (PadPortDS2),
	.PadPortJustif2 (PadPortJustif2),
	.PadPortStick2  (PadPortStick2),
	.PadPortPopn2   (PadPortPopn2),
	.KeyTriangle({1'b0, 1'b0, joy2[4], joy[4] }),
	.KeyCircle  ({1'b0, 1'b0, joy2[5], joy[5] }),
	.KeyCross   ({1'b0, 1'b0, joy2[6], joy[6] }),
	.KeySquare  ({1'b0, 1'b0, joy2[7], joy[7] }),
	.KeySelect  ({1'b0, 1'b0, joy2[8], joy[8] }),
	.KeyStart   ({1'b0, 1'b0, joy2[9], joy[9] }),
	.KeyRight   ({1'b0, 1'b0, joy2[0], joy[0] }),
	.KeyLeft    ({1'b0, 1'b0, joy2[1], joy[1] }),
	.KeyUp      ({1'b0, 1'b0, joy2[3], joy[3] }),
	.KeyDown    ({1'b0, 1'b0, joy2[2], joy[2] }),
	.KeyR1      ({1'b0, 1'b0, joy2[11],joy[11]}),
	.KeyR2      ({1'b0, 1'b0, joy2[13],joy[13]}),
	.KeyR3      ({1'b0, 1'b0, joy2[15],joy[15]}),
	.KeyL1      ({1'b0, 1'b0, joy2[10],joy[10]}),
	.KeyL2      ({1'b0, 1'b0, joy2[12],joy[12]}),
	.KeyL3      ({1'b0, 1'b0, joy2[14],joy[14]}),
	.ToggleDS   (ToggleDS),
	.Analog1XP1(joy0_xmuxed),
	.Analog1YP1(joystick_analog_l0[15:8]),
	.Analog2XP1(joystick_analog_r0[7:0]),
	.Analog2YP1(joystick_analog_r0[15:8]),
	.Analog1XP2(joystick_analog_l1[7:0]),
	.Analog1YP2(joystick_analog_l1[15:8]),
	.Analog2XP2(joystick_analog_r1[7:0]),
	.Analog2YP2(joystick_analog_r1[15:8]),
	.Analog1XP3(8'h80), .Analog1YP3(8'h80), .Analog2XP3(8'h80), .Analog2YP3(8'h80),
	.Analog1XP4(8'h80), .Analog1YP4(8'h80), .Analog2XP4(8'h80), .Analog2YP4(8'h80),
	.RumbleDataP1(), .RumbleDataP2(), .RumbleDataP3(), .RumbleDataP4(),
	.padMode(padMode),
	.MouseEvent(1'b0),
	.MouseLeft(1'b0),
	.MouseRight(1'b0),
	.MouseX(9'd0),
	.MouseY(9'd0),
	.multitap(1'b0),
	.multitapDigital(1'b0),
	.multitapAnalog(1'b0),
	//snac - no SNAC hardware wiring confirmed on NeptUNO+, disabled
	.snacPort1(1'b0),
	.snacPort2(1'b0),
	.selectedPort1Snac(),
	.selectedPort2Snac(),
	.irq10Snac(1'b0),
	.transmitValueSnac(),
	.clk9Snac(),
	.receiveBufferSnac(8'h00),
	.beginTransferSnac(),
	.actionNextSnac(1'b0),
	.receiveValidSnac(1'b0),
	.ackSnac(1'b1),
	.snacMC(1'b0),
	//sound
	.sound_out_left(audio_l_pcm),
	.sound_out_right(audio_r_pcm),
	//savestates - out of scope in Phase 1 (see PORTING_PLAN.md §6)
	.increaseSSHeaderCount (1'b1),
	.save_state            (1'b0),
	.load_state            (1'b0),
	.savestate_number      (2'b00),
	.state_loaded          (),
	.validSStates          (),
	.rewind_on             (1'b0),
	.rewind_active         (1'b0),
	//cheats - out of scope in Phase 1
	.cheat_clear(1'b0),
	.cheats_enabled(1'b0),
	.cheat_on(1'b0),
	.cheat_in(128'd0),
	.cheats_active(),

	.Cheats_BusAddr(cheats_addr),
	.Cheats_BusRnW(cheats_rnw),
	.Cheats_BusByteEnable(cheats_be),
	.Cheats_BusWriteData(cheats_dout),
	.Cheats_Bus_ena(1'b0),
	.Cheats_BusReadData(cheats_din),
	.Cheats_BusDone(sdramCh3_done)
);

////////////////////////////  MEMORY  ///////////////////////////////////

wire         sdr_refresh;
wire  [31:0] sdr_sdram_din;
wire  [31:0] sdr_sdram_dout32;
wire  [24:0] sdram_addr;
wire   [1:0] sdram_cntDMA;
wire   [3:0] sdram_be;
wire         sdram_req;
wire         sdram_ack;
wire         sdram_readack;
wire         sdram_writeack;
wire         sdram_rnw;
wire         sdram_dma;
wire         sdram_cache;
wire [ 3:0]  cache_wr;
wire [31:0]  cache_data;
wire [ 7:0]  cache_addr;
wire         dma_wr;
wire         dma_reqprocessed;
wire [31:0]  dma_data;

wire  [22:0] sdram_dmafifo_adr;
wire  [31:0] sdram_dmafifo_data;
wire         sdram_dmafifo_empty;
wire         sdram_dmafifo_read;

wire [20:0] cheats_addr;
wire cheats_rnw;
wire [3:0] cheats_be;
wire [31:0] cheats_dout;
wire [31:0] cheats_din;
wire sdramCh3_done;

assign sdram_ack = sdram_readack | sdram_writeack;

sdram sdram
(
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CKE  (SDRAM_CKE),
	.SDRAM_CLK  (SDRAM_CLK),

	.SDRAM_EN(1'b1),
	.init(~pll_locked),
	.clk(clk_3x),
	.clk_base(clk_1x),

	.refreshForce(sdr_refresh),
	.ram_idle(),

	.ch1_addr(sdram_addr),
	.ch1_din(),
	.ch1_dout(),
	.ch1_dout32(sdr_sdram_dout32),
	.ch1_req(sdram_req & sdram_rnw),
	.ch1_rnw(1'b1),
	.ch1_dma(sdram_dma),
	.ch1_cntDMA(sdram_cntDMA),
	.ch1_cache(sdram_cache),
	.ch1_ready(sdram_readack),
	.cache_wr(cache_wr),
	.cache_data(cache_data),
	.cache_addr(cache_addr),
	.dma_wr(dma_wr),
	.dma_reqprocessed(dma_reqprocessed),
	.dma_data(dma_data),

	.ch2_addr (sdram_addr),
	.ch2_din  (sdr_sdram_din),
	.ch2_dout (),
	.ch2_req  (sdram_req & ~sdram_rnw),
	.ch2_rnw  (1'b0),
	.ch2_be   (sdram_be),
	.ch2_ready(sdram_writeack),

	.ch3_addr ((exe_download | bios_download) ? ramdownload_wraddr : cheats_addr),
	.ch3_din  ((exe_download | bios_download) ? ramdownload_wrdata : cheats_dout),
	.ch3_dout (cheats_din),
	.ch3_req  ((exe_download | bios_download) ? ramdownload_wr     : 1'b0),
	.ch3_rnw  (cheats_rnw),
	.ch3_be   ((exe_download | bios_download) ? 4'b1111            : cheats_be),
	.ch3_ready(sdramCh3_done),

	.dmafifo_adr  (sdram_dmafifo_adr),
	.dmafifo_data (sdram_dmafifo_data),
	.dmafifo_empty(sdram_dmafifo_empty),
	.dmafifo_read (sdram_dmafifo_read)
);

wire [31:0] spuram_dataWrite;
wire [18:0] spuram_Adr;
wire  [3:0] spuram_be;
wire        spuram_rnw;
wire        spuram_ena;
wire [31:0] spuram_dataRead;
wire        spuram_done;

sdram sdram2
(
	.SDRAM_DQ   (SDRAM2_DQ),
	.SDRAM_A    (SDRAM2_A),
	.SDRAM_DQML (),
	.SDRAM_DQMH (),
	.SDRAM_BA   (SDRAM2_BA),
	.SDRAM_nCS  (SDRAM2_nCS),
	.SDRAM_nWE  (SDRAM2_nWE),
	.SDRAM_nRAS (SDRAM2_nRAS),
	.SDRAM_nCAS (SDRAM2_nCAS),
	.SDRAM_CKE  (),
	.SDRAM_CLK  (SDRAM2_CLK),
	.SDRAM_EN   (1'b1),

	.init(~pll_locked),
	.clk(clk_3x),
	.clk_base(clk_1x),

	.refreshForce(1'b0),
	.ram_idle(),

	.ch1_addr(spuram_Adr),
	.ch1_din(),
	.ch1_dout(),
	.ch1_dout32(spuram_dataRead),
	.ch1_req(spuram_ena & spuram_rnw),
	.ch1_rnw(1'b1),
	.ch1_dma(1'b0),
	.ch1_cntDMA(2'b00),
	.ch1_cache(1'b0),
	.ch1_ready(spuram_readack),

	.ch2_addr (spuram_Adr),
	.ch2_din  (spuram_dataWrite),
	.ch2_dout (),
	.ch2_req  (spuram_ena & ~spuram_rnw),
	.ch2_rnw  (1'b0),
	.ch2_be   (spuram_be),
	.ch2_ready(spuram_writeack),

	.ch3_addr(0),
	.ch3_din(),
	.ch3_dout(),
	.ch3_req(1'b0),
	.ch3_rnw(1'b1),
	.ch3_ready(),

	.dmafifo_adr  (0),
	.dmafifo_data (0),
	.dmafifo_empty(1'b1),
	.dmafifo_read ()
);

// Only one of ch1_req/ch2_req is ever active for a given spuram access,
// so it's safe to just OR the two acks together.
wire spuram_readack, spuram_writeack;
assign spuram_done = spuram_readack | spuram_writeack;

////////////////////////////  VIDEO  ////////////////////////////////////

// No MiSTer-style scaler on NeptUNO+ (plain VGA DAC): the core's own
// hs/vs/hbl/vbl/r/g/b already match the physical VGA timing directly, so
// there is no video_freak/aspect-ratio-LUT/gamma_corr stage here - just
// the classic MiST OSD overlay sitting between the core and the pins.
wire [7:0] osd_r, osd_g, osd_b;

osd #(.OUT_COLOR_DEPTH(8)) osd
(
	.clk_sys(clk_vid),
	.ce(ce_pix),

	.SPI_SCK(SPI_SCK),
	.SPI_SS3(SPI_SS3),
	.SPI_DI(SPI_DI),

	.rotate(2'b00),

	.R_in(r), .G_in(g), .B_in(b),
	.HBlank(hbl), .VBlank(vbl), .HSync(hs), .VSync(vs),

	.R_out(osd_r), .G_out(osd_g), .B_out(osd_b),
	.osd_enable()
);

assign VGA_R  = osd_r;
assign VGA_G  = osd_g;
assign VGA_B  = osd_b;
assign VGA_HS = hs;
assign VGA_VS = vs;

////////////////////////////  AUDIO  ////////////////////////////////////

wire [15:0] audio_l_pcm, audio_r_pcm;

sigma_delta_dac #(.MSBI(15)) dac_l
(
	.DACout(AUDIO_L),
	.DACin({~audio_l_pcm[15], audio_l_pcm[14:0]}),
	.CLK(clk_1x),
	.RESET(reset)
);

sigma_delta_dac #(.MSBI(15)) dac_r
(
	.DACout(AUDIO_R),
	.DACin({~audio_r_pcm[15], audio_r_pcm[14:0]}),
	.CLK(clk_1x),
	.RESET(reset)
);

wire bk_pending;

endmodule
