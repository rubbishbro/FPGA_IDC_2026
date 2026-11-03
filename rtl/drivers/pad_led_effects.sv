`timescale 1ns/1ps
// ROMs provide every gain/RGB; runtime arithmetic is add/subtract/compare/shift.
module pad_led_effects #(
    parameter int FRAME_TICKS=12500, // 200Hz at 400ns per enable
    parameter bit RADIAL_DECAY=1'b1,
    parameter logic [7:0] NOTE_ON_TH=8'd64, NOTE_OFF_TH=8'd48,
    parameter TABLE_DIR="rtl/drivers/pad_led_tables"
)(
    input clk_rst_pkg::clk_rst cr,
    input pad_driver_pkg::mat4x4 force_map,
    input logic led_busy, led_frame_done,
    output pad_driver_pkg::led_param leds
);
    import pad_driver_pkg::*;
    localparam int FW=$clog2(FRAME_TICKS);
    localparam logic [31:0] PHASE_STEP=32'd4129776; // period 5.2s
    localparam logic [23:0] RADIUS_STEP=24'd1966; // Q8.16, 6 cells/s
    logic [15:0] phase_rom [0:63];
    logic [7:0] breath_rom [0:255];
    logic [5:0] palette_rom [0:255];
    logic [11:0] distance_rom [0:63];
    logic [5:0] shape_rom [0:511];
    logic [5:0] age_rom [0:63];
    logic [5:0] radial_rom [0:63];
    logic [5:0] combine_rom [0:4095];
    logic [23:0] colour_rom [0:3583];
    initial begin
        $readmemh({TABLE_DIR,"/phase.mem"},phase_rom);
        $readmemh({TABLE_DIR,"/breath.mem"},breath_rom);
        $readmemh({TABLE_DIR,"/palette.mem"},palette_rom);
        $readmemh({TABLE_DIR,"/distance.mem"},distance_rom);
        $readmemh({TABLE_DIR,"/shape.mem"},shape_rom);
        $readmemh({TABLE_DIR,"/age.mem"},age_rom);
        $readmemh({TABLE_DIR,"/radial.mem"},radial_rom);
        $readmemh({TABLE_DIR,"/combine.mem"},combine_rom);
        $readmemh({TABLE_DIR,"/colour.mem"},colour_rom);
    end

    logic [FW-1:0] frame_counter;
    wire frame_tick=cr.clk_en && frame_counter==FW'(FRAME_TICKS-1);
    logic [31:0] phase_acc;
    logic [23:0] travel_acc;
    logic [3:0] age_div;
    logic [15:0] age_clock;
    always_ff @(posedge cr.clk or negedge cr.rst_n) begin
        if(!cr.rst_n) begin
            frame_counter<=0; phase_acc<=0; travel_acc<=0; age_div<=0; age_clock<=0;
        end else if(cr.clk_en) begin
            if(frame_tick) begin
                frame_counter<=0; phase_acc<=phase_acc+PHASE_STEP; travel_acc<=travel_acc+RADIUS_STEP;
                if(age_div==9) begin age_div<=0; age_clock<=age_clock+1'b1; end
                else age_div<=age_div+1'b1;
            end else frame_counter<=frame_counter+1'b1;
        end
    end

    // Capture the phase of the image actually latched by the LED chain.
    logic [15:0] displayed_phase,tx_phase;
    always_ff @(posedge cr.clk or negedge cr.rst_n)
        if(!cr.rst_n) displayed_phase<=0;
        else if(led_frame_done) displayed_phase<=tx_phase;
    wire [15:0] phase_for_hit=led_frame_done ? tx_phase : displayed_phase;

    logic [15:0] pressed,down,pending;
    logic [15:0] pending_phase [0:15],pending_age [0:15];
    logic [23:0] pending_travel [0:15];
    wire [127:0] forces=force_map.raw;
    always_comb begin
        for(int i=0;i<16;i++)
            down[i]=pressed[i] ? forces[i*8 +:8]>=NOTE_OFF_TH : forces[i*8 +:8]>NOTE_ON_TH;
    end
    logic pending_found;
    logic [3:0] pending_id;
    always_comb begin
        pending_found=0; pending_id=0;
        for(int i=0;i<16;i++) if(pending[i] && !pending_found) begin
            pending_found=1; pending_id=4'(i);
        end
    end
    typedef enum logic [2:0] {E_IDLE,E_OFFSET_WAIT,E_OFFSET,E_PALETTE_WAIT,E_COMMIT} event_state_t;
    event_state_t event_state;
    wire take_pending=event_state==E_IDLE && pending_found;
    // Event payload is published together with pending. The resettable pending
    // bitmap prevents any consumer from using a slot before a complete write.
    always_ff @(posedge cr.clk) begin
        for(int i=0;i<16;i++) if(down[i] && !pressed[i]) begin
            pending_phase[i]<=phase_for_hit;
            pending_age[i]<=age_clock; pending_travel[i]<=travel_acc;
        end
    end
    always_ff @(posedge cr.clk or negedge cr.rst_n) begin
        if(!cr.rst_n) begin
            pressed<=0; pending<=0;
        end else begin
            pressed<=down;
            if(take_pending) pending[pending_id]<=0;
            for(int i=0;i<16;i++) if(down[i] && !pressed[i]) begin
                // New strike wins if its mailbox is consumed on this edge.
                pending[i]<=1;
            end
        end
    end

    logic [15:0] wave_valid;
    logic [15:0] wave_birth_age [0:15];
    // 16 条 wave 记录的顺序扫描表：命中时按 next_slot 写入，渲染时按 wave_idx
    // 读出。wave_q 更新后再等待一拍，让同步距离 ROM 产出本条记录的距离。
    (* syn_ramstyle="block_ram" *) logic [53:0] wave_ram [0:15];
    logic [53:0] wave_q;
    logic [15:0] frame_age;
    logic [3:0] next_slot,event_pad;
    logic [15:0] event_phase,event_age,event_colour_phase;
    logic [23:0] event_travel;
    wire [5:0] hit_pixel={event_pad[3:2],1'b0,event_pad[1:0],1'b0};
    logic [15:0] hit_offset_q;
    logic [5:0] palette_q;
    always_ff @(posedge cr.clk) begin
        hit_offset_q<=phase_rom[hit_pixel];
        palette_q<=palette_rom[event_colour_phase[15:8]];
    end
    // E_COMMIT writes a complete record on the edge publishing wave_valid.
    // Invalid records may feed combinational expressions, but cannot be used
    // as valid render snapshots. Birth timestamps are data, not live counters.
    always_ff @(posedge cr.clk) begin
        if(event_state==E_COMMIT) begin
            wave_birth_age[next_slot]<=event_age;
            // {4'b0, birth_travel[23:0], birth_age[15:0], colour[5:0], pad[3:0]}
            wave_ram[next_slot] <= {4'b0,event_travel,event_age,palette_q,event_pad};
        end
    end
    always_ff @(posedge cr.clk or negedge cr.rst_n) begin
        if(!cr.rst_n) begin
            event_state<=E_IDLE; next_slot<=0; wave_valid<=0;
            event_pad<=0; event_phase<=0; event_age<=0; event_travel<=0; event_colour_phase<=0;
        end else begin
            // Retire records permanently, so age-clock wrap cannot revive them.
            for(int i=0;i<16;i++)
                if(wave_valid[i] && 16'(age_clock-wave_birth_age[i])>=16'd64) wave_valid[i]<=0;
            case(event_state)
            E_IDLE: if(pending_found) begin
                event_pad<=pending_id; event_phase<=pending_phase[pending_id];
                event_age<=pending_age[pending_id]; event_travel<=pending_travel[pending_id];
                event_state<=E_OFFSET_WAIT;
            end
            E_OFFSET_WAIT: event_state<=E_OFFSET;
            E_OFFSET: begin event_colour_phase<=event_phase+hit_offset_q; event_state<=E_PALETTE_WAIT; end
            E_PALETTE_WAIT: event_state<=E_COMMIT;
            E_COMMIT: begin
                // FIFO allocation: a full pool replaces its oldest record.
                wave_valid[next_slot]<=1;
                next_slot<=next_slot+1'b1; event_state<=E_IDLE;
            end
            default: event_state<=E_IDLE;
            endcase
        end
    end

    logic [23:0] frame_travel;
    logic [15:0] frame_phase;
    (* syn_ramstyle="block_ram" *) pixel_t framebuffer [0:63];
    pixel_t framebuffer_q;
    logic [5:0] pixel_idx,fill_idx;
    logic [3:0] wave_idx;
    logic [7:0] background;
    logic [5:0] best_amplitude,best_colour;
    logic [15:0] pixel_phase;
    logic [8:0] shape_addr;
    logic [5:0] age_addr,radial_addr;
    logic [11:0] combine_addr;
    logic [15:0] phase_q;
    logic [7:0] breath_q;
    logic [11:0] distance_q;
    logic [5:0] shape_q,age_q,radial_q,combined_q;
    pixel_t colour_q;

    // Doubled coordinates: pad centre (4*c+1,4*r+1), LED (2*x,2*y).
    // Absolute odd differences 1..13 map to a symmetric 8x8 distance ROM.
    wire [4:0] px2={1'b0,pixel_idx[2:0],1'b0};
    wire [4:0] py2={1'b0,pixel_idx[5:3],1'b0};
    wire [4:0] cx2={1'b0,wave_q[1:0],2'b01};
    wire [4:0] cy2={1'b0,wave_q[3:2],2'b01};
    wire [4:0] dx=px2>=cx2 ? px2-cx2 : cx2-px2;
    wire [4:0] dy=py2>=cy2 ? py2-cy2 : cy2-py2;
    wire [5:0] distance_addr={dy[3:1],dx[3:1]};
    wire [23:0] distance_q16={4'b0,distance_q,8'b0};
    // Snapshot the origin and common frame time, then share one subtraction
    // across the already serialized wave scan. Never use the live travel_acc.
    wire [15:0] cur_age    = frame_age - wave_q[25:10];
    wire [5:0]  cur_age6   = cur_age[5:0];
    wire [23:0] cur_radius = frame_travel - wave_q[49:26];
    wire [23:0] cur_lag    = cur_radius - distance_q16;
    always_ff @(posedge cr.clk) begin
        phase_q<=phase_rom[pixel_idx];
        breath_q<=breath_rom[pixel_phase[15:8]];
        distance_q<=distance_rom[distance_addr];
        shape_q<=shape_rom[shape_addr]; age_q<=age_rom[age_addr]; radial_q<=radial_rom[radial_addr];
        combined_q<=combine_rom[combine_addr];
        colour_q<=colour_rom[{best_colour,best_amplitude}];
    end

    typedef enum logic [4:0] {
        R_BOOT_FILL,R_IDLE,R_PIXEL_ADDR,R_PHASE,R_BG_WAIT,R_BG,R_WAVE_ADDR,R_DISTANCE,
        R_SHAPE_WAIT,R_SHAPE,R_MIX1_WAIT,R_MIX1,R_MIX2_WAIT,R_COMPARE,R_NEXT_WAVE,
        R_COLOUR_ADDR,R_COLOUR,R_READY,R_FILL,R_DISTANCE_WAIT
    } render_state_t;
    render_state_t state;
    // Prefetch pixel zero while waiting for TX, and the next pixel on every
    // accepted fill tick. This also works with consecutive clk_en pulses.
    wire [5:0] framebuffer_read_addr = state==R_READY ? 6'd0 :
        ((state==R_FILL && cr.clk_en) ? fill_idx+6'd1 : fill_idx);
    always_ff @(posedge cr.clk) begin
        if(cr.rst_n && state==R_COLOUR)
            framebuffer[pixel_idx] <= {
                8'(colour_q.g.val+background),8'(colour_q.r.val+background),
                8'(colour_q.b.val+background)};
        framebuffer_q <= framebuffer[framebuffer_read_addr];
    end
    always_comb begin
        leds='0; leds.x=fill_idx[2:0]; leds.y=fill_idx[5:3];
        leds.wr=state==R_BOOT_FILL || state==R_FILL;
        if(state==R_FILL) leds.pix=framebuffer_q;
    end
    always_ff @(posedge cr.clk or negedge cr.rst_n) begin
        if(!cr.rst_n) begin
            state<=R_BOOT_FILL; pixel_idx<=0; fill_idx<=0; wave_idx<=0;
            tx_phase<=0; frame_phase<=0; pixel_phase<=0; background<=0;
            best_amplitude<=0; best_colour<=0; wave_q<=0; frame_age<=0;
            shape_addr<=0; age_addr<=0; radial_addr<=0; combine_addr<=0;
        end else case(state)
            // wr stays high until a full black image has been written.
            R_BOOT_FILL: if(cr.clk_en) begin
                if(fill_idx==63) begin fill_idx<=0; state<=R_IDLE; end
                else fill_idx<=fill_idx+1'b1;
            end
            R_IDLE: if(frame_tick) begin
                frame_phase<=phase_acc[31:16]; pixel_idx<=0;
                frame_travel<=travel_acc; frame_age<=age_clock;
                state<=R_PIXEL_ADDR;
            end
            R_PIXEL_ADDR: state<=R_PHASE;
            R_PHASE: begin pixel_phase<=frame_phase+phase_q; state<=R_BG_WAIT; end
            R_BG_WAIT: state<=R_BG;
            R_BG: begin background<=breath_q; best_amplitude<=0; best_colour<=0; wave_idx<=0; state<=R_WAVE_ADDR; end
            R_WAVE_ADDR: begin
                if(!wave_valid[wave_idx]) state<=R_NEXT_WAVE;
                else begin wave_q<=wave_ram[wave_idx]; state<=R_DISTANCE_WAIT; end
            end
            // distance_q samples the new wave_q on this edge; consume it next cycle.
            R_DISTANCE_WAIT: state<=R_DISTANCE;
            R_DISTANCE: begin
                if(cur_age>=16'd64 || cur_radius<distance_q16 ||
                   cur_lag>=24'd524288) state<=R_NEXT_WAVE;
                else begin
                    shape_addr<=cur_lag[18:10]; // 1/64-cell bins
                    age_addr<=cur_age6; radial_addr<=distance_q[11:6];
                    state<=R_SHAPE_WAIT;
                end
            end
            R_SHAPE_WAIT: state<=R_SHAPE;
            R_SHAPE: begin combine_addr<={shape_q,age_q}; state<=R_MIX1_WAIT; end
            R_MIX1_WAIT: state<=R_MIX1;
            R_MIX1: begin combine_addr<={combined_q,(RADIAL_DECAY ? radial_q : 6'd63)}; state<=R_MIX2_WAIT; end
            R_MIX2_WAIT: state<=R_COMPARE;
            R_COMPARE: begin
                if(combined_q>best_amplitude) begin best_amplitude<=combined_q; best_colour<=wave_q[9:4]; end
                state<=R_NEXT_WAVE;
            end
            R_NEXT_WAVE: begin
                if(wave_idx==15) state<=R_COLOUR_ADDR;
                else begin wave_idx<=wave_idx+1'b1; state<=R_WAVE_ADDR; end
            end
            R_COLOUR_ADDR: state<=R_COLOUR;
            R_COLOUR: begin
                // 80 background + 160 wave <= 240: no clipping/hue distortion.
                if(pixel_idx==63) state<=R_READY;
                else begin pixel_idx<=pixel_idx+1'b1; state<=R_PIXEL_ADDR; end
            end
            R_READY: if(!led_busy) begin fill_idx<=0; state<=R_FILL; end
            R_FILL: if(cr.clk_en) begin
                if(fill_idx==63) begin tx_phase<=frame_phase; fill_idx<=0; state<=R_IDLE; end
                else fill_idx<=fill_idx+1'b1;
            end
            default: state<=R_BOOT_FILL;
        endcase
    end
    // synthesis translate_off
    initial begin
        if(FRAME_TICKS<6000) $fatal(1,"LED frame period must allow rendering and TX");
        if(NOTE_OFF_TH>=NOTE_ON_TH) $fatal(1,"LED pressure thresholds need hysteresis");
    end
    // synthesis translate_on
endmodule
