`timescale 1ns/1ps

module spectrum_dump_tb;

    reg clk_pix, rst_n;
    reg samp_en, frame_pulse;
    reg [6:0] rd_bar_idx;
    reg rd_valid;
    wire [9:0] rd_q_y, rd_q_ov;
    wire [5:0] wf_base_row, wf_rd_row;
    wire [6:0] wf_rd_col;
    wire [9:0] wf_rd_data;

    real_audio_chain u_chain(
        .clk_core(clk_pix), .rst_core_n(rst_n),
        .clk_pix(clk_pix), .rst_pix_n(rst_n),
        .samp_en(samp_en), .frame_pulse(frame_pulse),
        .rd_bar_idx(rd_bar_idx), .rd_valid(rd_valid),
        .rd_q_y(rd_q_y), .rd_q_ov(rd_q_ov),
        .wf_base_row(wf_base_row),
        .wf_rd_row(wf_rd_row), .wf_rd_col(wf_rd_col), .wf_rd_data(wf_rd_data)
    );

    always #15 clk_pix = ~clk_pix;

    reg [15:0] div;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin div <= 0; samp_en <= 0; end
        else begin
            samp_en <= 0;
            if (div >= 16'd693) begin div <= 0; samp_en <= 1; end
            else div <= div + 1;
        end
    end

    reg [19:0] fcnt;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin fcnt <= 0; frame_pulse <= 0; end
        else begin
            frame_pulse <= 0;
            if (fcnt == 20'd635335) begin fcnt <= 0; frame_pulse <= 1; end
            else fcnt <= fcnt + 1;
        end
    end

    integer fd;
    integer frame = 0;

    initial begin
        fd = $fopen("spectrum_bars.txt", "w");
        clk_pix = 0; rst_n = 0;
        samp_en = 0; frame_pulse = 0;
        rd_bar_idx = 0; rd_valid = 0;
        #40;
        rst_n = 1;
    end

    always @(posedge clk_pix) begin
        if (u_chain.sm_bar_we)
            $fwrite(fd, "%0d %0d %0d\n", frame, u_chain.sm_bar_addr, u_chain.sm_bar_w);

        if (u_chain.sm_frame_done) begin
            frame = frame + 1;
            if (frame >= 8) begin
                $fclose(fd);
                $display("dumped %0d frames", frame);
                $finish;
            end
        end
    end

endmodule
