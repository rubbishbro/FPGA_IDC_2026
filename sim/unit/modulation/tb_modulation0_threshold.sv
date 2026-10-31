`timescale 1ns/1ps
module tb_modulation0_threshold;
    import modal_step_pkg::*;
    logic clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    logic [7:0] pressure;
    logic [2:0] busy,done;
    logic [4:0] we[3];
    logic [5:0] addr[3],mode_out[3];
    coeff_t data[3];
    integer pm[5][8],expected[3][5][5],vals[25];
    localparam int TH[3]='{64,102,230};
    for(genvar g=0;g<3;g++)begin: dut
        modulation0 #(.PAD_NOTE_ON_TH(TH[g])) u_mod(
            .clk(clk),.rst_n(rst_n),.start(start),.n_modes(16'd5),.fmap_i(pressure),
            .busy(busy[g]),.done(done[g]),.p_re(),.p_mode(addr[g]),
            .p_a11(pm[addr[g]][0]),.p_a12(pm[addr[g]][1]),
            .p_a22(pm[addr[g]][2]),.p_wo(pm[addr[g]][3]),
            .p_s11(pm[addr[g]][4]),.p_s12(pm[addr[g]][5]),
            .p_s22(pm[addr[g]][6]),.p_swo(pm[addr[g]][7]),
            .co_we(we[g]),.co_mode(mode_out[g]),.co_wdata(data[g]));
    end
    integer fd,rc,pressure_start,checks=0,writes[3],cycles;
    string vector_file="build/modulation_threshold/vectors.txt";
    initial begin
        rc=$value$plusargs("VECTORS=%s",vector_file);
        fd=$fopen(vector_file,"r");
        if(!fd)$fatal(1,"missing vectors");
        repeat(4)@(negedge clk);rst_n=1;
        // Three resource notes x all 256 pressures x three thresholds.
        // Includes 229/230/231 and every saturated code through 255.
        for(int trial=0;trial<768;trial++)begin
            for(int m=0;m<5;m++)begin
                for(int k=0;k<25;k++)begin
                    rc=$fscanf(fd,"%d",vals[k]);if(rc!=1)$fatal(1,"bad vector");
                end
                pressure_start=vals[0];
                if(vals[1]!=m)$fatal(1,"mode order");
                for(int k=0;k<8;k++)pm[m][k]=vals[k+2];
                for(int g=0;g<3;g++)for(int k=0;k<5;k++)expected[g][m][k]=vals[10+g*5+k];
            end
            pressure=8'(pressure_start);start=1;
            @(negedge clk);start=0;
            // Force a different pressure during the transaction: coefficients
            // must still all correspond to the pressure accepted with start.
            pressure=8'(255-pressure_start);
            for(int g=0;g<3;g++)writes[g]=0;
            cycles=0;
            while(done!=3'b111 && cycles<200)begin
                @(negedge clk);cycles++;
                for(int g=0;g<3;g++)if(we[g]!=0)begin
                    if(we[g]!=31 || mode_out[g]>=4)$fatal(1,"invalid write mask/mode");
                    if(data[g].a11!==expected[g][mode_out[g]][0] ||
                       data[g].a12!==expected[g][mode_out[g]][1] ||
                       data[g].a21!==expected[g][mode_out[g]][2] ||
                       data[g].a22!==expected[g][mode_out[g]][3] ||
                       data[g].wo !==expected[g][mode_out[g]][4])
                        $fatal(1,"write mismatch th=%0d pressure=%0d mode=%0d",TH[g],pressure_start,mode_out[g]);
                    writes[g]++;checks+=5;
                end
            end
            if(cycles>=200)$fatal(1,"timeout");
            for(int g=0;g<3;g++)if(writes[g]!=4)$fatal(1,"write count");
            @(negedge clk);
        end
        $display("PASS modulation0 thresholds=64/102/230 pressures=0..255 checks=%0d saturation_at_230 coherent pressure snapshot",checks);
        $finish;
    end
endmodule
