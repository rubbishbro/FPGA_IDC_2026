package ui_pkg;

    localparam logic [2:0] UI_EV_NONE = 3'd0;
    localparam logic [2:0] UI_EV_NEXT = 3'd1;
    localparam logic [2:0] UI_EV_OK   = 3'd2;

    localparam logic [2:0] UI_EV_PREV = 3'd3;
    localparam logic [2:0] UI_EV_BACK = 3'd4;

    localparam logic [1:0] UI_PAGE_BARS      = 2'd0;
    localparam logic [1:0] UI_PAGE_WAVE      = 2'd1;
    localparam logic [1:0] UI_PAGE_FALL      = 2'd2;
    localparam logic [1:0] UI_PAGE_SETTINGS  = 2'd3;

endpackage
