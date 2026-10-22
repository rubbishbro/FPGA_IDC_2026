module decoder38(
   a,
   b,
   c,
   en,
   out
);

   input a;
   input b;
   input c;
   input en;

   output [7:0] out;

   reg [7:0] out;

   always @(*) begin
      if (en) begin
         out = 8'b0000_0001 << {c, b, a};
      end 
      else begin
         out = 8'b0000_0000;
      end
   end

endmodule