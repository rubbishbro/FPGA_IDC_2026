module Gowin_ADC (
    output logic        adcrdy,
    output logic [13:0] adcvalue,
    input  logic        drstn,
    input  logic        adcreqi,
    input  logic [9:0]  fscal_value,
    input  logic [11:0] offset_value
);

    assign adcrdy   = drstn;
    assign adcvalue = 14'd0;

endmodule
