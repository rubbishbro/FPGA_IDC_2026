`timescale 1ns/1ps
module tb_audio_loudness;
    logic clk=0,rst_n=0,key0=1,key1=1;
    always #10 clk=~clk;
    wire [7:0] a,b;
    test1_reference_top #(.DEBOUNCE_CYCLES(4)) ref_top(
        .clk(clk),.rst_n(rst_n),.key0(key0),.key1(key1),
        .amp_bclk(a[7]),.amp_ws(a[6]),.amp_din(a[5]),.amp_sd(a[4]),
        .dac_bck(a[3]),.dac_ws(a[2]),.dac_din(a[1]),.dac_pa_en(a[0]));
    test2_project_top #(.DEBOUNCE_CYCLES(4)) project_top(
        .clk(clk),.rst_n(rst_n),.key0(key0),.key1(key1),
        .amp_bclk(b[7]),.amp_ws(b[6]),.amp_din(b[5]),.amp_sd(b[4]),
        .dac_bck(b[3]),.dac_ws(b[2]),.dac_din(b[1]),.dac_pa_en(b[0]));
    // A complete cycle-by-cycle comparison includes both serial formats/enables.
    always @(negedge clk)if(rst_n && a!==b)
        $fatal(1,"FAIL reference/project outputs differ: %b / %b",a,b);
    logic [31:0] expected[0:4095];
    integer written=0,i2s_frames=0,pt_frames=0,total_frames=0;
    integer coverage[0:3][0:2];
    integer positives=0,negatives=0;
    // Capture source samples, before encoding. No serializer's data register used.
    always @(posedge clk)begin
        if(!ref_top.u_core.reset_n)written=0;
        else if(ref_top.u_core.g_reference.u_tx.count==1023)begin
            expected[written]=ref_top.u_core.pcm_pair;written++;
            coverage[ref_top.u_core.level_sel][ref_top.u_core.channel_sel]++;
            if(ref_top.u_core.square_sample>0)positives++;
            if(ref_top.u_core.square_sample<0)negatives++;
        end
    end
    // External standard I2S receiver: WS edges locate slots; skip one dummy bit,
    // capture 16 payload bits, and require the remaining slot bits to be zero.
    bit i_sync=0,i_prev=0;
    integer i_bit=0;
    logic [15:0] i_shift,i_left;
    time i_last=0;
    always @(posedge a[7] or negedge rst_n)begin
        if(!rst_n)begin i_sync=0;i_prev=0;i_bit=0;i2s_frames=0;i_last=0;end
        else begin
            if(i_last!=0 && $time-i_last!=320)$fatal(1,"FAIL I2S BCLK period");
            i_last=$time;
            if(a[6]!=i_prev)begin
                i_bit=0;
                if(!a[6])i_sync=1;
            end
            if(i_sync)begin
                if(i_bit>=1 && i_bit<=16)i_shift={i_shift[14:0],a[5]};
                if(i_bit>=17 && a[5]!==0)$fatal(1,"FAIL I2S padding");
                if(i_bit==16)begin
                    if(!a[6])i_left=i_shift;
                    else begin
                        if(i2s_frames>=written || {i_left,i_shift}!==expected[i2s_frames])
                            $fatal(1,"FAIL I2S decoded frame %0d actual=%h expected=%h",i2s_frames,{i_left,i_shift},expected[i2s_frames]);
                        i2s_frames++;total_frames++;
                    end
                end
            end
            i_bit++;i_prev=a[6];
        end
    end
    // External PT8211 receiver: WS low=right; no I2S dummy bit.
    bit p_sync=0,p_prev=0;
    integer p_bit=0;
    logic [15:0] p_shift,p_right;
    time p_last=0;
    always @(posedge a[3] or negedge rst_n)begin
        if(!rst_n)begin p_sync=0;p_prev=0;p_bit=0;pt_frames=0;p_last=0;end
        else begin
            if(p_last!=0 && $time-p_last!=640)$fatal(1,"FAIL PT8211 BCK period");
            p_last=$time;
            if(a[2]!=p_prev)begin p_bit=0;if(!a[2])p_sync=1;end
            if(p_sync)begin
                p_shift={p_shift[14:0],a[1]};
                if(p_bit==15)begin
                    if(!a[2])p_right=p_shift;
                    else begin
                        if(pt_frames>=written || {p_shift,p_right}!==expected[pt_frames])
                            $fatal(1,"FAIL PT8211 decoded frame %0d",pt_frames);
                        pt_frames++;
                    end
                end
            end
            p_bit++;p_prev=a[2];
        end
    end
    task automatic press(input bit which);
        @(negedge clk);if(which)key1=0;else key0=0;
        repeat(30)@(negedge clk); // Holding generates exactly one event.
        if(which)key1=1;else key0=1;
        repeat(30)@(negedge clk);
    endtask
    initial begin
        for(int l=0;l<4;l++)for(int c=0;c<3;c++)coverage[l][c]=0;
        repeat(5)@(negedge clk);rst_n=1;
        // All amplitude/channel combinations, at least a full tone period each.
        for(int l=0;l<4;l++)begin
            for(int c=0;c<3;c++)begin
                repeat(110*1024)@(negedge clk);
                press(1);
            end
            press(0);
        end
        if(ref_top.u_core.level_sel!=2 || ref_top.u_core.channel_sel!=0)
            $fatal(1,"FAIL key cycling/debounce");
        for(int l=0;l<4;l++)for(int c=0;c<3;c++)
            if(coverage[l][c]<100)$fatal(1,"FAIL missing level/channel coverage");
        if(positives<500 || negatives<500 || i2s_frames<1300 || pt_frames<1300)
            $fatal(1,"FAIL tone/sign/frame coverage");
        @(negedge clk);rst_n=0;
        repeat(5)@(negedge clk);
        if(a[4]!==0 || a[0]!==0)$fatal(1,"FAIL reset mute");
        rst_n=1;repeat(110*1024)@(negedge clk);
        if(i2s_frames<100 || pt_frames<100)$fatal(1,"FAIL reset recovery");
        $display("PASS tb_audio_loudness frames=%0d all_4_levels all_3_channels both_signs independent_I2S_PT8211_decode reset keys reference_equals_project",total_frames);
        $finish;
    end
    initial begin #50_000_000;$fatal(1,"FAIL timeout");end
endmodule
