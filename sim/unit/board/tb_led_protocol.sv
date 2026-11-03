`timescale 1ns/1ps
// Receiver interprets the wire as GRB, MSB first, independent of driver storage.
module tb_led_protocol;
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;
    logic clk=0,rst_n=0,wr=1;
    always #10 clk=~clk;
    logic [4:0] div=0;
    wire ce=div==19;
    always @(posedge clk) if(!rst_n || ce) div<=0; else div<=div+1'b1;
    clk_rst cr;
    assign cr={clk,ce,rst_n};
    logic [2:0] x=0,y=0;
    pixel_t pixel='0;
    wire dat,busy,done;
    led8x8 dut(.cr(cr),.x(x),.y(y),.pix(pixel),
        .wr(wr),.dat(dat),.busy(busy),.frame_done(done));
    logic [23:0] expected [0:63];
    logic [23:0] received=0;
    integer bit_count=0,pixel_count=0,frames=0,total_pixels=0;
    time rise_time;
    always @(posedge dat) rise_time=$time;
    always @(negedge dat) if(rst_n) begin
        if($time-rise_time!=400 && $time-rise_time!=800)
            $fatal(1,"FAIL LED pulse width %0t",$time-rise_time);
        received={received[22:0],($time-rise_time==800)};
        bit_count++;
        if(bit_count==24) begin
            if(pixel_count>=64 || received!==expected[pixel_count])
                $fatal(1,"FAIL LED GRB/MSB frame=%0d pixel=%0d expected=%06x got=%06x",
                    frames,pixel_count,expected[pixel_count],received);
            pixel_count++;total_pixels++;bit_count=0;
        end
    end
    always @(negedge clk) if(rst_n && done) begin
        if(pixel_count!=64 || bit_count!=0) $fatal(1,"FAIL incomplete LED frame");
        frames++;pixel_count=0;
    end
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        // All 256 grayscale codes, then independent RGB values to check byte order.
        for(int frame_id=0;frame_id<5;frame_id++) begin
            wr=1;
            for(int cell_id=0;cell_id<64;cell_id++) begin
                @(negedge clk);while(!ce) @(negedge clk);
                x=3'(cell_id/8);y=3'(cell_id%8);
                if(frame_id<4) begin
                    pixel.g.val=8'(frame_id*64+cell_id);
                    pixel.r.val=pixel.g.val;pixel.b.val=pixel.g.val;
                end else begin
                    pixel.g.val=8'(cell_id*37+1);
                    pixel.r.val=8'(cell_id*13+64);
                    pixel.b.val=8'(cell_id*7+128);
                end
                expected[(7-cell_id/8)*8+((cell_id/8)%2 ? 7-cell_id%8 : cell_id%8)]=
                    {pixel.g.val,pixel.r.val,pixel.b.val};
            end
            @(negedge clk);while(!ce) @(negedge clk);
            @(negedge clk);wr=0;
            wait(frames==frame_id+1);@(negedge clk);
        end
        if(total_pixels!=320) $fatal(1,"FAIL missing decoded pixels");
        $display("PASS tb_led_protocol frames=5 pixels=320 gray_codes=256 GRB_MSB_first");
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL LED protocol timeout");end
endmodule
