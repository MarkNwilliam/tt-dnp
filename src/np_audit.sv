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

  // A saturating event count plus a rolling chain bit that flips on every
  // event, so a reader can spot a swapped or replayed evidence log. (An
  // earlier 4-entry event ring was removed: nothing ever read it back, and
  // it cost flops for no evidence value.)
  reg chain_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      log_head <= 8'd0;
      chain_q  <= 1'b0;
    end else if (!freeze && ev) begin
      chain_q <= ~chain_q;
      if (log_head != 8'hFF) log_head <= log_head + 8'd1;
    end
  end

  assign chain_bit = chain_q;

endmodule
