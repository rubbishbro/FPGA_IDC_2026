// =============================================================================
// key_debounce.v - 2FF synchroniser + counter debounce, press pulse output
//
// Any change on the synchronised input restarts the counter; once the input
// is stable for DEBOUNCE_CNT clocks it is adopted.  key_pulse is one clock on
// the falling edge (press) of the stable signal.
//
// clk = clk_pix = 33.333 MHz, async active-low reset rst_n.
// =============================================================================
module key_debounce #(
    parameter DEBOUNCE_CNT = 20'd660_000   // ~20ms at 33MHz
)(
    input               clk,
    input               rst_n,
    input               key_in,     // active low
    output              key_pulse   // one-cycle pulse on press
);

    reg  [19:0] cnt;
    reg         key_sync1;
    reg         key_sync2;
    reg         key_sync2_prev;   // previous synced sample (change detector)
    reg         key_stable;
    reg         key_prev;

    // two-stage sync + one extra for change detect
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync1      <= 1'b1;
            key_sync2      <= 1'b1;
            key_sync2_prev <= 1'b1;
        end
        else begin
            key_sync1      <= key_in;
            key_sync2      <= key_sync1;
            key_sync2_prev <= key_sync2;
        end
    end

    // debounce: any change in the synced input resets the counter;
    // once it stays unchanged for DEBOUNCE_CNT, adopt it as stable.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= 20'd0;
            key_stable <= 1'b1;
        end
        else begin
            if (key_sync2 != key_sync2_prev) begin
                cnt <= 20'd0;                       // input toggled -> restart
            end
            else if (cnt < DEBOUNCE_CNT) begin
                cnt <= cnt + 1'b1;
            end
            else begin
                key_stable <= key_sync2;            // stable long enough -> lock
            end
        end
    end

    // edge detect on key_stable falling = press (active low)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_prev <= 1'b1;
        else
            key_prev <= key_stable;
    end

    assign key_pulse = key_prev && !key_stable;

endmodule