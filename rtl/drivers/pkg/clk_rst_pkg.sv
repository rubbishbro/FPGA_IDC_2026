/*
clk_rst_pkg -- shared convention of clock and reset
use this type by:
    import clk_rst_pkg::*;

always_ff template:
    always_ff @(posedge cr.clk or negedge cr.rst_n) begin
        if(!cr.rst_n) begin
            //do sth
        end
        else if(cr.clk_en & (internal en)) begin
            //do sth
        end
    end

pass down the cr info like:
    .cr({cr.clk, cr.clk_en & (internal en or clk), (internal rst or cr.rst)})
*/


package clk_rst_pkg;

typedef struct packed{
    logic clk;
    logic clk_en;
    logic rst_n;
} clk_rst;

endpackage