`timescale 1ns/1ns

module decoder38_tb();

   reg A;
   reg B;
   reg C;
   reg EN;

   wire [7:0] out;

   integer errors = 0;
   integer i;

   decoder38 decoder38_A(
   .a(A),
   .b(B),
   .c(C),
   .en(EN),
   .out(out)
   );

   task check;
      input [7:0] exp;
      begin
         #1;
         if (out !== exp) begin
            errors = errors + 1;
            $error("Time %0t: EN=%0d C=%0d B=%0d A=%0d, out=%b, expected=%b",
                   $time, EN, C, B, A, out, exp);
         end else begin
            $display("Time %0t: EN=%0d C=%0d B=%0d A=%0d -> out=%b OK",
                     $time, EN, C, B, A, out);
         end
      end
   endtask

   initial begin
      $display("=== decoder38 self-check test ===");
      for (i = 0; i < 8; i = i + 1) begin
         {C, B, A} = i; EN = 0;
         #20;
         check(8'b0000_0000);
      end
      for (i = 0; i < 8; i = i + 1) begin
         {C, B, A} = i; EN = 1;
         #20;
         check(8'b0000_0001 << i);
      end
      if (errors == 0) begin
         $display("=== TEST PASSED ===");
      end else begin
         $display("=== TEST FAILED: %0d mismatch(es) ===", errors);
      end
      $finish;
   end

endmodule