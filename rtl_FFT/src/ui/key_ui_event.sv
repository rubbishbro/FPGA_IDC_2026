module key_ui_event #(
    parameter integer DEBOUNCE_CNT = 660_000,
    parameter integer LONG_CNT     = 26_666_667,
    parameter logic [2:0] SHORT_EVENT = 3'd1,
    parameter logic [2:0] LONG_EVENT  = 3'd2
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       key_in,
    output logic       ev_valid,
    output logic [2:0] ev
);

    import ui_pkg::*;

    logic        key_sync1;
    logic        key_sync2;
    logic        key_sync2_d;
    logic        key_stable;
    logic        key_stable_d;
    logic [31:0] debounce_cnt;
    logic [31:0] hold_cnt;
    logic        press_seen;
    logic        long_fired;

    wire press_edge   = key_stable_d && !key_stable;
    wire release_edge = !key_stable_d && key_stable;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync1  <= 1'b1;
            key_sync2  <= 1'b1;
            key_sync2_d <= 1'b1;
        end
        else begin
            key_sync1   <= key_in;
            key_sync2   <= key_sync1;
            key_sync2_d <= key_sync2;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debounce_cnt <= 32'd0;
            key_stable   <= 1'b1;
        end
        else begin
            if (key_sync2 != key_sync2_d) begin
                debounce_cnt <= 32'd0;
            end
            else if (debounce_cnt < DEBOUNCE_CNT) begin
                debounce_cnt <= debounce_cnt + 32'd1;
            end
            else begin
                key_stable <= key_sync2;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_stable_d <= 1'b1;
        end
        else begin
            key_stable_d <= key_stable;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_valid    <= 1'b0;
            ev          <= UI_EV_NONE;
            hold_cnt    <= 32'd0;
            press_seen  <= 1'b0;
            long_fired  <= 1'b0;
        end
        else begin
            ev_valid <= 1'b0;
            ev       <= UI_EV_NONE;

            if (press_edge) begin
                press_seen <= 1'b1;
                long_fired <= 1'b0;
                hold_cnt   <= 32'd0;
            end
            else if (press_seen && !long_fired && !key_stable) begin
                if (hold_cnt >= LONG_CNT - 1) begin
                    ev_valid   <= 1'b1;
                    ev         <= LONG_EVENT;
                    long_fired <= 1'b1;
                end
                else begin
                    hold_cnt <= hold_cnt + 32'd1;
                end
            end

            if (release_edge) begin
                if (press_seen && !long_fired) begin
                    ev_valid <= 1'b1;
                    ev       <= SHORT_EVENT;
                end
                press_seen <= 1'b0;
                long_fired <= 1'b0;
                hold_cnt   <= 32'd0;
            end
        end
    end

endmodule
