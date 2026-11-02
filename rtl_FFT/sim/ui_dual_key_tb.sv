`timescale 1ns/1ps

module ui_dual_key_tb;

    import ui_pkg::*;

    logic       clk;
    logic       rst_n;
    logic       key0;
    logic       key1;
    logic       ev0_valid, ev1_valid;
    logic [2:0] ev0, ev1;
    logic       ev_valid;
    logic [2:0] ev;
    logic [1:0] page;
    logic [1:0] setting_sel;
    logic [3:0] effects;

    integer errors;

    key_ui_event #(
        .DEBOUNCE_CNT(4), .LONG_CNT(12),
        .SHORT_EVENT(UI_EV_NEXT), .LONG_EVENT(UI_EV_OK)
    ) u_key0 (
        .clk(clk), .rst_n(rst_n), .key_in(key0),
        .ev_valid(ev0_valid), .ev(ev0)
    );

    key_ui_event #(
        .DEBOUNCE_CNT(4), .LONG_CNT(12),
        .SHORT_EVENT(UI_EV_PREV), .LONG_EVENT(UI_EV_BACK)
    ) u_key1 (
        .clk(clk), .rst_n(rst_n), .key_in(key1),
        .ev_valid(ev1_valid), .ev(ev1)
    );

    assign ev_valid = ev0_valid | ev1_valid;
    assign ev = ev0_valid ? ev0 : ev1;

    ui_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .ev_valid(ev_valid), .ev(ev),
        .page(page), .setting_sel(setting_sel), .effects(effects)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic press_short(input integer which);
        integer i;
        begin
            if (which == 0) key0 = 1'b0; else key1 = 1'b0;
            for (i = 0; i < 8; i = i + 1) @(posedge clk);
            if (which == 0) key0 = 1'b1; else key1 = 1'b1;
            for (i = 0; i < 8; i = i + 1) @(posedge clk);
        end
    endtask

    task automatic press_long(input integer which);
        integer i;
        begin
            if (which == 0) key0 = 1'b0; else key1 = 1'b0;
            for (i = 0; i < 30; i = i + 1) @(posedge clk);
            if (which == 0) key0 = 1'b1; else key1 = 1'b1;
            for (i = 0; i < 8; i = i + 1) @(posedge clk);
        end
    endtask

    task automatic check_page(input [1:0] want);
        begin
            repeat (8) @(posedge clk);
            #1;
            if (page !== want) begin
                $error("page expected %0d got %0d", want, page);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        key0 = 1'b1;
        key1 = 1'b1;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        press_short(0);
        check_page(UI_PAGE_WAVE);

        press_short(0);
        check_page(UI_PAGE_FALL);

        press_short(1);
        check_page(UI_PAGE_WAVE);

        press_short(1);
        check_page(UI_PAGE_BARS);

        press_long(0);
        check_page(UI_PAGE_SETTINGS);

        press_long(1);
        check_page(UI_PAGE_BARS);

        if (errors == 0)
            $display("=== UI DUAL KEY TEST PASSED ===");
        else
            $display("=== UI DUAL KEY TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
