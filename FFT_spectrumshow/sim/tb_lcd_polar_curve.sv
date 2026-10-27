`timescale 1ns/1ps

// Self-checking TB for the inverse-mapping polar FALL renderer (decorated).
//
// The DUT advances pix_x by LAT internally, so a steady input at pixel X is
// driven as pix_x = X - LAT.  The stream test drives consecutive pixels and
// checks at the same clock, which verifies the latency compensation.
//
// Colours are checked structurally (dominant channels) because every pixel
// also carries the decorative background.
module tb_lcd_polar_curve;

    localparam int LAT = 17;

    logic        clk;
    logic        rst_n;
    logic        frame_pulse;
    logic        lcd_valid;
    logic [9:0]  pix_x;
    logic [9:0]  pix_y;
    wire  [9:0]  curve_rd_addr;
    logic [39:0] curve_rd_data;
    logic        theme;
    wire         hit;
    wire  [5:0]  r;
    wire  [5:0]  g;
    wire  [5:0]  b;

    integer errors;

    localparam logic [39:0] WORD0 = {10'd300, 10'd200, 10'd100, 10'd50};

    logic [39:0] mem [0:767];

    always_ff @(posedge clk) begin
        curve_rd_data <= mem[curve_rd_addr];
    end

    initial begin
        for (int i = 0; i < 768; i++) begin
            mem[i] = WORD0;
        end
    end

    lcd_polar_curve #(
        .CX  (400),
        .CY  (240),
        .LAT (LAT)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .frame_pulse   (frame_pulse),
        .lcd_valid     (lcd_valid),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .curve_rd_addr (curve_rd_addr),
        .curve_rd_data (curve_rd_data),
        .theme         (theme),
        .hit           (hit),
        .r             (r),
        .g             (g),
        .b             (b)
    );

    // one frame pulse every 9 clocks keeps the animation moving in sim
    initial begin
        frame_pulse = 1'b0;
        forever begin
            repeat (8) @(posedge clk);
            frame_pulse <= 1'b1;
            @(posedge clk);
            frame_pulse <= 1'b0;
        end
    end

    always #15 clk = ~clk;

    task automatic hold_pixel(input int x, input int y);
        begin
            pix_x     = x[9:0];
            pix_y     = y[9:0];
            lcd_valid = 1'b1;
            repeat (LAT + 8) @(posedge clk);
            #1;
        end
    endtask

    // steady-state check: compensate the internal LAT advance
    task automatic check_curve(input int x, input int y, input int id,
                               input string name);
        logic ok;
        begin
            hold_pixel(x - LAT, y);
            case (id)
                1: ok = hit && (r > 25) && (g > 25) && (b < 40);
                2: ok = hit && (g > 30) && (b > 30) && (r < 30);
                3: ok = hit && (r > 25) && (b > 30) && (g < 30);
                4: ok = hit && (b > 30) && (r < 20) && (g < 40);
                default: ok = 1'b0;
            endcase
            if (!ok) begin
                $display("FAIL %-12s (%0d,%0d) id=%0d hit=%0b rgb=%0d/%0d/%0d",
                         name, x, y, id, hit, r, g, b);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_hit(input int x, input int y, input bit exp,
                             input string name);
        begin
            hold_pixel(x - LAT, y);
            if (hit !== exp) begin
                $display("FAIL %-12s (%0d,%0d) hit=%0b exp=%0b", name, x, y, hit, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_dim(input int x, input int y, input string name);
        begin
            hold_pixel(x - LAT, y);
            if (!hit || (r > 20) || (g > 20) || (b > 20)) begin
                $display("FAIL %-12s (%0d,%0d) expected dim bg, hit=%0b rgb=%0d/%0d/%0d",
                         name, x, y, hit, r, g, b);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_center(input int x, input int y, input string name);
        begin
            hold_pixel(x - LAT, y);
            if (!hit || (r < 12) || (g < 12) || (b < 15)) begin
                $display("FAIL %-12s (%0d,%0d) expected bloom, hit=%0b rgb=%0d/%0d/%0d",
                         name, x, y, hit, r, g, b);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_rim(input int x, input int y, input string name);
        begin
            hold_pixel(x - LAT, y);
            if (!hit || (b < 26)) begin
                $display("FAIL %-12s (%0d,%0d) expected rim glow, hit=%0b rgb=%0d/%0d/%0d",
                         name, x, y, hit, r, g, b);
                errors = errors + 1;
            end
        end
    endtask

    // Count lit pixels over a screen region (starfield sanity check).
    task automatic count_sky(input int x0, input int y0, input int w, input int h,
                             input int lo, input int hi, input string name);
        integer cnt, xi, yi;
        begin
            cnt = 0;
            for (yi = 0; yi < h; yi = yi + 1) begin
                for (xi = 0; xi < w; xi = xi + 1) begin
                    pix_x     = (x0 + xi - LAT);
                    pix_y     = (y0 + yi);
                    lcd_valid = 1'b1;
                    @(posedge clk);
                    #1;
                    if (hit && ((r + g + b) > 18)) cnt = cnt + 1;
                end
            end
            if (cnt < lo || cnt > hi) begin
                $display("FAIL %-12s stars=%0d exp %0d..%0d", name, cnt, lo, hi);
                errors = errors + 1;
            end
        end
    endtask

    // Find the first bright sky pixel in a region (for the animation check).
    // The colour is captured in the same cycle the pixel is seen, because the
    // meteor moves fast.
    task automatic find_star(input int x0, input int y0, input int w, input int h,
                             output int fx, output int fy, output bit found,
                             output logic [17:0] c0);
        integer xi, yi;
        begin
            found = 1'b0;
            fx    = x0;
            fy    = y0;
            c0    = 18'd0;
            for (yi = 0; (yi < h) && !found; yi = yi + 1) begin
                for (xi = 0; (xi < w) && !found; xi = xi + 1) begin
                    pix_x     = (x0 + xi - LAT);
                    pix_y     = (y0 + yi);
                    lcd_valid = 1'b1;
                    @(posedge clk);
                    #1;
                    if (hit && ((r + g + b) > 70)) begin
                        fx    = x0 + xi;
                        fy    = y0 + yi;
                        c0    = {r, g, b};
                        found = 1'b1;
                    end
                end
            end
        end
    endtask

    integer i;

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        lcd_valid     = 1'b0;
        pix_x         = 10'd0;
        pix_y         = 10'd0;
        theme         = 1'b0;
        errors        = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // ---------------- curve cores ----------------
        // R = 190 - h*150/512:
        //   age0(h=300)=102.1  age3(h=50)=175.4  age7(h=100)=160.7
        //   age15(h=200)=131.4 ring=190
        check_curve(400, 138, 1, "age0_top");
        check_curve(400, 137, 1, "age0_top2");
        check_curve(400,  65, 2, "age3_top");
        check_curve(400,  66, 2, "age3_top2");
        check_curve(400,  79, 3, "age7_top");
        check_curve(400, 109, 4, "age15_top");
        check_curve(400, 110, 4, "age15_top2");

        // ---------------- glow (25% ring just outside the core) ----------------
        hold_pixel(400 - LAT, 134);
        if (!hit || (r < 10) || (g < 10) || (r > 45)) begin
            $display("FAIL glow_outer   (400,134) hit=%0b rgb=%0d/%0d/%0d", hit, r, g, b);
            errors = errors + 1;
        end

        // ---------------- decorative background ----------------
        check_dim   (420, 300, "bg_dim");
        check_center(400, 240, "center_bloom");
        check_hit   (400,  20, 1'b1, "outside");
        check_hit   (400,   0, 1'b1, "top_edge");
        check_rim   (590, 240, "rim_right");
        count_sky   (20, 190, 100, 100, 30, 1500, "sky_left");

        // ---------------- animation: a sky pixel must change over time ----
        begin : anim_check
            integer fx, fy;
            bit     found;
            logic [17:0] c0, c1;
            find_star(20, 190, 200, 100, fx, fy, found, c0);
            if (!found) begin
                $display("FAIL anim         no lit sky pixel found");
                errors = errors + 1;
            end
            else begin
                repeat (512) @(posedge clk);
                hold_pixel(fx - LAT, fy);
                c1 = {r, g, b};
                if (c0 === c1) begin
                    $display("FAIL anim         (%0d,%0d) static %h", fx, fy, c0);
                    errors = errors + 1;
                end
            end
        end

        // radial gradient: farther out is brighter in blue
        hold_pixel(430 - LAT, 240);
        begin : grad_check
            logic [5:0] b_near;
            b_near = b;
            hold_pixel(400 - LAT, 90);
            if (!(b > b_near + 5)) begin
                $display("FAIL gradient      b(150)=%0d b(30)=%0d", b, b_near);
                errors = errors + 1;
            end
        end

        // ---------------- stream: checks latency compensation ----------------
        for (i = 450; i <= 620; i = i + 1) begin
            pix_x     = i[9:0];
            pix_y     = 10'd240;
            lcd_valid = 1'b1;
            @(posedge clk);
            #1;
            if (i == 503) begin
                if (!(hit && (r > 45) && (g > 45))) begin
                    $display("FAIL stream x=503 core missing rgb=%0d/%0d/%0d", r, g, b);
                    errors = errors + 1;
                end
            end
            if (i == 504) begin
                if (r > 45 && g > 45) begin
                    $display("FAIL stream x=504 still core rgb=%0d/%0d/%0d", r, g, b);
                    errors = errors + 1;
                end
            end
            if (i == 590) begin
                if (!hit) begin
                    $display("FAIL stream x=590 no hit");
                    errors = errors + 1;
                end
            end
            if (i == 594) begin
                if (!hit || (r > 45 && g > 45)) begin
                    $display("FAIL stream x=594 outside wrong hit=%0b rgb=%0d/%0d/%0d", hit, r, g, b);
                    errors = errors + 1;
                end
            end
        end

        // ---------------- orientation: half the circle deep, half flat ------
        for (i = 0; i < 768; i++) begin
            if (i < 384) mem[i] = {4{10'd479}};
            else         mem[i] = {4{10'd0}};
        end
        // 12 o'clock (col 0) -> R=49.7 ; 6 o'clock (col 384) -> R=190
        hold_pixel(400 - LAT, 190);
        if (!hit || (r < 45) || (g < 45)) begin
            $display("FAIL orient_top     rgb=%0d/%0d/%0d", r, g, b);
            errors = errors + 1;
        end
        hold_pixel(400 - LAT, 430);
        if (!hit || (r < 45) || (g < 45)) begin
            $display("FAIL orient_bottom  rgb=%0d/%0d/%0d", r, g, b);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD POLAR CURVE TEST PASSED ===");
        else
            $display("=== LCD POLAR CURVE TEST FAILED: %0d error(s) ===", errors);

        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
