module np_audit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        freeze,
    input  wire        ev,          // one-cycle event pulse
    input  wire [3:0]  ev_code,     // event type
    input  wire [7:0]  ev_mag,      // event magnitude
    input  wire        tamper_p,
    input  wire [15:0] sec,
    output reg  [7:0]  log_head,     // count of events (saturating)
    output wire        chain_bit    // rolling chain accumulator bit
);

  // 4-entry ring of last events (code 4b + magnitude 4b each), plus a
  // one-bit rolling chain flag that flips on every event -> swap detection.
  reg [7:0] ring [0:3];
  reg [1:0] wptr;
  reg       chain_q;

  integer j;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      log_head  <= 8'd0;
      wptr      <= 2'd0;
      chain_q     <= 1'b0;
      for (j = 0; j < 4; j = j + 1) ring[j] <= 8'd0;
    end else if (!freeze && ev) begin
      ring[wptr]   <= {ev_code, ev_mag[3:0]};
      wptr         <= wptr + 2'd1;
      chain_q        <= ~chain_q;
      if (log_head != 8'hFF) log_head <= log_head + 8'd1;
    end
  end

  assign chain_bit = chain_q;

endmodule
