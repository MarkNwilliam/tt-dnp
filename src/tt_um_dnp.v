/*
 * tt_um_dnp — Tiny Tapeout wrapper for the Digital Number Plate evidence core
 * (IC Projects/10-Digital-Number-Plate-ASIC).
 *
 * The core is the trusted security/enforcement heart of a digital number
 * plate. A host MCU (or a roadside reader) provisions it once through a
 * byte-wide host port, then reads back 24-byte toll/evidence tokens:
 *
 *   SETUP   : host mode -> write the 32-byte header on WR/DATA, then pulse GO
 *             to seal (only when all 32 bytes are present and valid).
 *   SEALED  : GO re-snapshots the record and computes a fresh 64-bit digest;
 *             in host mode, RD streams the 24-byte token out on DATA,
 *             auto-incrementing.
 *
 * Pin budget: the core wants an 8-bit data bus plus ~10 control/sensor lines,
 * but Tiny Tapeout only offers 8 uo + 8 uio (+ ena/clk/rst). So the 8-bit bus
 * is time-multiplexed: SEL (ui[4]) selects "host byte bus" vs "sensor inject".
 * In sensor mode the host drives a sensor vector on DATA and pulses WR, and the
 * wrapper turns each asserted bit into a one-cycle pulse to the core. That
 * lets the host synthesise the full sensor waveform (brake, wheel, impact,
 * weighbridge axle, zone enter/exit, removal shock) with a few writes.
 *
 * Pin map:
 *   ui_in[0]  = EN           global enable (also AND'ed with ena)
 *   ui_in[1]  = GO           command strobe: seal (setup) / issue token (sealed)
 *   ui_in[2]  = WR           host mode: write DATA->header ; sensor mode: sample
 *   ui_in[3]  = RD           host mode: read next token byte from DATA
 *   ui_in[4]  = SEL          0 = host byte-bus mode, 1 = sensor-inject mode
 *   ui_in[5]  = PPS          1 Hz time window
 *   ui_in[6]  = ZONE         toll-zone level (high = inside a zone)
 *   ui_in[7]  = TAMPER       enclosure/seal broken (active-high level)
 *
 *   uio_in[7:0] = DATA      host byte bus in mode 0; sensor vector in mode 1:
 *                            [0] brake  [1] wheel  [2] impact  [3] weigh
 *                            [4] zenter [5] zexit  [6] removal  [7] spare
 *   uio_out[7:0]= DATA      (driven during a host read, oe = &RD)
 *   uio_oe[0]   = 1 -> DATA is an output (host read phase)
 *
 *   uo_out[7:0]= status     [0]BUSY [1]SEALED [2]ERR [3]TAMPER
 *                          [4]BAL_OK [5]IMMOB [6]RDY [7]VALID
 *
 * Zone enter/exit: the wrapper edge-detects the ZONE level so a GNSS/host can
 * simply hold ZONE high while inside a zone; in sensor mode the explicit
 * zenter/zexit vector bits override it.
 *
 * Security note: the 64-bit digest is tamper-EVIDENT, not cryptographic. See
 * IC Projects/10-Digital-Number-Plate-ASIC/doc/research.md.
 */

`default_nettype none

module tt_um_dnp (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is enabled
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  localparam UI_EN = 0, UI_GO = 1, UI_WR = 2, UI_RD = 3;
  localparam UI_SEL = 4, UI_PPS = 5, UI_ZONE = 6, UI_TAMPER = 7;

  // ---- control decode ----
  wire en_i        = ui_in[UI_EN] & ena;
  wire go_i        = ui_in[UI_GO];
  wire wr_strobe_raw = ui_in[UI_WR];
  wire rd_raw      = ui_in[UI_RD];
  wire sel_i       = ui_in[UI_SEL];
  wire sensor_mode = sel_i;
  wire host_mode   = ~sel_i;

  // host byte bus (mode 0)
  wire host_wr = wr_strobe_raw & host_mode & en_i;
  wire host_rd = rd_raw         & host_mode & en_i;

  // sensor inject (mode 1): each asserted vector bit is a one-cycle pulse
  wire sens_strobe = wr_strobe_raw & sensor_mode & en_i;
  wire [7:0] sens_vec = uio_in;

  wire brake_p  = sens_strobe & sens_vec[0];
  wire wheel_p  = sens_strobe & sens_vec[1];
  wire impact_p = sens_strobe & sens_vec[2];
  wire weigh_p  = sens_strobe & sens_vec[3];
  wire zenter_e = sens_strobe & sens_vec[4];
  wire zexit_e  = sens_strobe & sens_vec[5];
  wire g_pulse  = sens_strobe & sens_vec[6];

  // ---- level sensors ----
  wire pps_i      = ui_in[UI_PPS] & en_i;
  wire in_zone_i  = ui_in[UI_ZONE] & en_i;
  wire seal_open_i = ui_in[UI_TAMPER] & en_i;

  // ZONE level -> enter/exit edges
  reg zone_d;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) zone_d <= 1'b0;
    else        zone_d <= in_zone_i;
  end
  wire zenter_lvl = in_zone_i & ~zone_d;
  wire zexit_lvl  = ~in_zone_i & zone_d;
  // explicit sensor-mode bits override the derived level edges
  wire zenter = zenter_e | zenter_lvl;
  wire zexit  = zexit_e  | zexit_lvl;

  // ---- host data bus ----
  wire [7:0] dio = uio_in;      // 8-bit host bus (both directions)
  wire data_oe = host_rd;       // drive DATA during a host read
  wire [7:0] core_dout;

  // ---- core ----
  wire [7:0] status;
  np_core u_core (
      .clk       (clk),
      .rst_n     (rst_n),
      .wr        (host_wr),
      .go        (go_i & en_i),
      .rd        (host_rd),
      .din       (dio),
      .dout      (core_dout),
      .pps       (pps_i),
      .zenter    (zenter),
      .zexit     (zexit),
      .brake_p   (brake_p),
      .wheel_p   (wheel_p),
      .impact_p  (impact_p),
      .weigh_p   (weigh_p),
      .seal_open (seal_open_i),
      .g_pulse   (g_pulse),
      .status    (status)
  );

  // ---- IO drive ----
  assign uio_out = data_oe ? core_dout : 8'd0;
  assign uio_oe  = {7'd0, data_oe};

  // ---- dedicated status outputs (gated on ena for flash/demo mode) ----
  assign uo_out[0] = ena ? status[0] : 1'b0;  // BUSY
  assign uo_out[1] = ena ? status[1] : 1'b0;  // SEALED
  assign uo_out[2] = ena ? status[2] : 1'b0;  // ERR
  assign uo_out[3] = ena ? status[3] : 1'b0;  // TAMPER
  assign uo_out[4] = ena ? status[4] : 1'b0;  // BAL_OK
  assign uo_out[5] = ena ? status[5] : 1'b0;  // IMMOB
  assign uo_out[6] = ena ? status[6] : 1'b0;  // RDY
  assign uo_out[7] = ena ? status[7] : 1'b0;  // VALID

endmodule
