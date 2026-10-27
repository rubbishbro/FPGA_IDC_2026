`timescale 1ns/1ps

module ui_key_ctrl_tb;

    import ui_pkg::*;

    logic       clk;
    logic       rst_n;
    logic       key_in;
    logic       ev_valid;
    logic [2:0] ev;
    logic [1:0] page;
    logic [1:0] setting_sel;
    logic [3:0] effects;

    integer ev_count;
    integer last_ev;
    integer errors;

    key_ui_event #(
        .DEBOUNCE_CNT(4),
        .LONG_CNT(12)
    ) u_key (
        .clk(clk), .rst_n(rst_n), .key_in(key_in),
        .ev_valid(ev_valid), .ev(ev)
    );

    ui_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .ev_valid(ev_valid), .ev(ev),
        .page(page), .setting_sel(setting_sel), .effects(effects)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_count <= 0;
            last_ev  <= 0;
        end
        else if (ev_valid) begin
            ev_count <= ev_count + 1;
            last_ev  <= ev;
        end
    end

    task automatic press_key(input integer cycles);
        integer i;
        begin
            key_in = 1'b0;
            for (i = 0; i < cycles; i = i + 1)
                @(posedge clk);
            key_in = 1'b1;
            for (i = 0; i < 8; i = i + 1)
                @(posedge clk);
        end
    endtask

    task automatic wait_events(input integer target);
        integer guard;
        begin
            guard = 0;
            while ((ev_count < target) && (guard < 200)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (ev_count < target) begin
                $error("timeout waiting for event %0d (got %0d)", target, ev_count);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_page(input [1:0] want);
        begin
            @(posedge clk);
            #1;
            if (page !== want) begin
                $error("page expected %0d got %0d", want, page);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_sel(input [1:0] want);
        begin
            @(posedge clk);
            #1;
            if (setting_sel !== want) begin
                $error("setting_sel expected %0d got %0d", want, setting_sel);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        key_in = 1'b1;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        press_key(8);
        wait_events(1);
        if (last_ev !== UI_EV_NEXT) begin
            $error("expected NEXT event, got %0d", last_ev);
            errors = errors + 1;
        end
        check_page(UI_PAGE_WAVE);

        press_key(8);
        wait_events(2);
        check_page(UI_PAGE_FALL);

        press_key(8);
        wait_events(3);
        check_page(UI_PAGE_SETTINGS);

        press_key(30);
        wait_events(4);
        if (effects[0] !== 1'b0) begin
            $error("effects[0] did not toggle");
            errors = errors + 1;
        end

        press_key(8);
        wait_events(5);
        check_sel(2'd1);

        press_key(30);
        wait_events(6);
        if (effects[1] !== 1'b0) begin
            $error("effects[1] did not toggle");
            errors = errors + 1;
        end
        if (errors == 0)
            $display("=== UI KEY/CTRL TEST PASSED ===");
        else
            $display("=== UI KEY/CTRL TEST FAILED: %0d error(s) ===", errors);

        $finish;
    end

endmodule
