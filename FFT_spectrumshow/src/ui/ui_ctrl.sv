// =============================================================================
// ui_ctrl.sv - page / settings state machine
//
// NEXT/PREV move through the four pages; on the SETTINGS page they move the
// setting row.  OK enters SETTINGS or toggles the selected effect bit; BACK
// returns to BARS.  Reset state: BARS page, effects = 4'b1011
// (SMTH on, PEAK on, THEM off, GRID on).
//
// clk = clk_pix = 33.333 MHz, async active-low reset rst_n.
// =============================================================================
module ui_ctrl (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       ev_valid,
    input  logic [2:0] ev,
    output logic [1:0] page,
    output logic [1:0] setting_sel,
    output logic [3:0] effects
);

    import ui_pkg::*;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page        <= UI_PAGE_BARS;
            setting_sel <= 2'd0;
            effects     <= 4'b1011;
        end
        else if (ev_valid) begin
            case (ev)
                UI_EV_NEXT: begin
                    if (page == UI_PAGE_SETTINGS)
                        setting_sel <= setting_sel + 2'd1;
                    else
                        page <= page + 2'd1;
                end

                UI_EV_PREV: begin
                    if (page == UI_PAGE_SETTINGS)
                        setting_sel <= setting_sel - 2'd1;
                    else if (page == UI_PAGE_BARS)
                        page <= UI_PAGE_SETTINGS;
                    else
                        page <= page - 2'd1;
                end

                UI_EV_OK: begin
                    if (page == UI_PAGE_SETTINGS)
                        effects[setting_sel] <= ~effects[setting_sel];
                    else
                        page <= UI_PAGE_SETTINGS;
                end

                UI_EV_BACK: begin
                    page <= UI_PAGE_BARS;
                end

                default: begin
                    page        <= page;
                    setting_sel <= setting_sel;
                end
            endcase
        end
    end

endmodule
