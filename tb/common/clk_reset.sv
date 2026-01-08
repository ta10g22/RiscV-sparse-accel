module clk_reset #(
  parameter time TCLK = 10ns
)(
  output logic clk,
  output logic n_reset
);
  initial clk = 1'b0;
  always #(TCLK/2) clk = ~clk;

  task automatic apply_reset(int cycles = 5);
    n_reset = 1'b0;
    repeat (cycles) @(posedge clk);
    n_reset = 1'b1;
    repeat (2) @(posedge clk);
  endtask
endmodule
