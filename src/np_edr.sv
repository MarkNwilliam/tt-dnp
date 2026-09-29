module np_edr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        freeze,
    input  wire        brake_p,    // harsh-braking sensor pulse
    input  wire        wheel_p,    // wheel-rotation pulse (4 per km)
    input  wire        impact_p,   // accelerometer impact pulse
    input  wire        weigh_p,    // weighbridge: one axle crossing
    input  wire        zenter,     // toll-zone entry (opens a passage)
    input  wire        zexit,      // toll-zone exit  (closes a passage)
    input  wire        tick_1s,    // 1 Hz boundary for the speed window
    output reg  [7:0]  brake_n,
    output reg  [7:0]  impact_n,
    output reg  [7:0]  weigh_n,
    output reg  [7:0]  peak_axles, // heaviest (max axles) passage seen
    output reg  [15:0] odo_km,     // x10 km, integrates 4 pulses/km
    output reg  [15:0] speed_kmh,  // x10 km/h from pulses in last 1 s
    output reg         speeding,
    output reg         overweight
);

  localparam [7:0] AXLE_LIMIT = 8'd6;    // >6 axles in a passage = overload
  localparam [15:0] SPEED_LIMIT = 16'd1000; // 100.0 km/h threshold (x10)

  reg [5:0]  sub40;        // 0..39 wheel pulses inside the current km
  reg [15:0] win_pulses;   // wheel pulses inside the current 1 s window
  reg [7:0]  cur_axles;    // axles counted in the open passage

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      brake_n    <= 8'd0;
      impact_n   <= 8'd0;
      weigh_n    <= 8'd0;
      peak_axles <= 8'd0;
      odo_km     <= 16'd0;
      speed_kmh  <= 16'd0;
      speeding   <= 1'b0;
      overweight <= 1'b0;
      sub40      <= 6'd0;
      win_pulses <= 16'd0;
      cur_axles  <= 8'd0;
    end else if (!freeze) begin
      // harsh-event counters (saturating)
      if (brake_p  && (brake_n  != 8'hFF)) brake_n  <= brake_n  + 8'd1;
      if (impact_p && (impact_n != 8'hFF)) impact_n <= impact_n + 8'd1;

      // axle-load enforcement across a passage
      if (zenter) cur_axles <= 8'd0;
      if (weigh_p) begin
        if (weigh_n != 8'hFF)  weigh_n  <= weigh_n  + 8'd1;
        if (cur_axles != 8'hFF) cur_axles <= cur_axles + 8'd1;
      end
      if (zexit) begin
        if (cur_axles > peak_axles) peak_axles <= cur_axles;
        if (cur_axles > AXLE_LIMIT)  overweight  <= 1'b1;
        cur_axles <= 8'd0;
      end

      // wheel integration: 40 pulses = 1 km
      if (wheel_p) begin
        if (win_pulses != 16'hFFFF) win_pulses <= win_pulses + 16'd1;
        if (sub40 == 6'd39) begin
          sub40 <= 6'd0;
          if (odo_km != 16'hFFFF) odo_km <= odo_km + 16'd1;
        end else begin
          sub40 <= sub40 + 6'd1;
        end
      end

      // roll the 1 Hz speed window
      if (tick_1s) begin
        speed_kmh <= win_pulses;
        if (win_pulses > SPEED_LIMIT) speeding <= 1'b1;
        win_pulses <= 16'd0;
      end
    end
  end

endmodule
