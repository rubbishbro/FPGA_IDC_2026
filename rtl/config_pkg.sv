`ifndef CONFIG_PKG_SV
`define CONFIG_PKG_SV
package config_pkg;
    typedef struct packed {
        logic [15:0] tag;
        logic [15:0] id;
        logic signed [31:0] value;
    } cfg_request_t;
    localparam logic [7:0] CFG_OK=0, CFG_UNSUPPORTED=1, CFG_OUT_OF_RANGE=2,
                           CFG_DENIED=3, CFG_FAILED=4, CFG_BUSY=5;
    typedef struct packed {
        logic [15:0] tag;
        logic [15:0] id;
        logic [7:0] result;
        logic signed [31:0] applied_value;
    } cfg_response_t;
    // Stable slots: removed parameters 3/4/14/15/19 stay reserved.
    localparam integer CFG_COUNT=22;
    typedef logic [CFG_COUNT-1:0] cfg_supported_t;
    localparam cfg_supported_t DISPLAY_MASK=20'h007c0;
    localparam cfg_supported_t LOCAL_MASK=DISPLAY_MASK | 20'h10000;
    // 一个统一值数组；字段只在 cfg_id/cfg_index 中定义，UI 不拥有音频寄存器。
    typedef logic [CFG_COUNT-1:0][31:0] cfg_values_t;
    // 音频后端的已提交快照；channel使用UI的1-based编号，source沿用0/1/2。
    // 仅audio_valid=1时有效。标量结果仍保留原tag/id，关联字段由此快照统一更新。
    typedef struct packed {
        logic [15:0] instrument;
        logic [4:0] channel;
        logic [1:0] source;
        logic bank;
        router_pkg::reverb_preset reverb;
        logic guide;
        logic custom_keys; // committed key binding; bank remains the default low/high group
    } audio_config_t;
    function automatic logic [15:0] midi_instrument(input logic [4:0] channel);
        case(channel)
            1:midi_instrument=1; 2:midi_instrument=0; 3:midi_instrument=3;
            4:midi_instrument=5; 5:midi_instrument=4; 6:midi_instrument=2;
            7:midi_instrument=10;8:midi_instrument=11;
            default:midi_instrument=16'hffff;
        endcase
    endfunction
    function automatic logic [4:0] instrument_channel(input logic [15:0] instrument);
        case(instrument)
            0:instrument_channel=2; 1:instrument_channel=1; 2:instrument_channel=6;
            3:instrument_channel=3; 4:instrument_channel=5; 5:instrument_channel=4;
            10:instrument_channel=7;11:instrument_channel=8;
            default:instrument_channel=0;
        endcase
    endfunction
    function automatic logic[7:0] instrument_label(input logic[15:0] instrument);
        case(instrument)
            10:return 8'd124;
            11:return 8'd125;
            default:return instrument<=9 ? 8'(100+instrument) : 8'd72;
        endcase
    endfunction
    function automatic logic audio_config_valid(input audio_config_t a);
        return !(a.source==0 && a.guide) && a.source<=2 && router_pkg::reverb_value_valid(32'(a.reverb)) && a.instrument<=11 &&
               a.channel>=1 && a.channel<=8 &&
               (a.source==0 || midi_instrument(a.channel)==a.instrument);
    endfunction
    function automatic logic audio_parameter(input logic [15:0] id);
        return id==16'h0100 || id==16'h0200 || id==16'h0300 ||
               id==16'h0500 || id==16'h0501 || id==16'h0503;
    endfunction
    function automatic logic signed [31:0] audio_value(input audio_config_t a,
                                                      input logic [15:0] id);
        case(id)
            16'h0100:return 32'(a.instrument);
            16'h0200:return 32'(a.reverb);
            16'h0300:return 32'(a.bank);
            16'h0500:return 32'(a.source);
            16'h0501:return 32'(a.channel);
            16'h0503:return 32'(a.guide);
            default:return 0;
        endcase
    endfunction
    typedef struct packed {
        logic [15:0] style_id;
        logic theme, peak, smooth, grid;
    } display_config_t;
    typedef struct packed {
        logic open;
        logic [1:0] layer;               // 0 分类、1 参数、2 行内编辑
        logic [2:0] category, selection;
        logic [4:0] edit_index;
        logic signed [31:0] draft;
        logic busy, has_result;
        logic [7:0] result;
        logic [9:0] cursor_x;
        logic [8:0] cursor_y;
    } sidebar_scene_t;
    typedef struct packed {
        logic [15:0] epoch;
        display_config_t display_cfg;
        sidebar_scene_t scene;
        cfg_values_t values;
        cfg_supported_t supported;
    } sidebar_snapshot_t;

    function automatic logic [15:0] cfg_id(input integer index);
        case(index)
            0:cfg_id=16'h0100; 1:cfg_id=16'h0101; 2:cfg_id=16'h0200;
            5:cfg_id=16'h0300;
            6:cfg_id=16'h0400; 7:cfg_id=16'h0401; 8:cfg_id=16'h0402;
            9:cfg_id=16'h0403;10:cfg_id=16'h0404;11:cfg_id=16'h0500;
           12:cfg_id=16'h0501;13:cfg_id=16'h0502;
           16:cfg_id=16'h8000;17:cfg_id=16'h8001;
           18:cfg_id=16'h8002;20:cfg_id=16'h0503;21:cfg_id=16'h0102;default:cfg_id=16'hffff;
        endcase
    endfunction
    function automatic integer cfg_index(input logic [15:0] id);
        cfg_index=-1;
        for(integer i=0;i<CFG_COUNT;i=i+1) if(cfg_id(i)!=16'hffff && cfg_id(i)==id)cfg_index=i;
    endfunction
    function automatic integer category_base(input integer category);
        case(category)
            0:category_base=0;1:category_base=2;2:category_base=5;
            3:category_base=6;4:category_base=11;default:category_base=16;
        endcase
    endfunction
    function automatic integer category_count(input integer category);
        case(category)
            0:category_count=2;1:category_count=2;2:category_count=1;
            3:category_count=5;4:category_count=4;default:category_count=3;
        endcase
    endfunction
    // Stable parameter indices; the input menu appends mode without moving system IDs.
    function automatic integer category_item(input integer category,input integer row_index);
        if(category==1 && row_index==1)return 21;
        if(category==4 && row_index==3)return 20;
        return category_base(category)+row_index;
    endfunction
    function automatic logic cfg_action(input integer index);
        return index==16 || index==17;
    endfunction
    // Screen orientation is explicit. Default matches slot/row order; verify on hardware.
    function automatic logic[3:0] guide_cell_slot(input logic[3:0] cell_index);
        return cell_index;
    endfunction
    typedef struct packed {
        logic enabled, waiting_release, fault, link_fault, banked;
        logic [15:0] revision;
        audio_config_t audio;
        logic [16*7-1:0] note_map;
        logic [15:0] target, glow, pressed;
        // Display-only, level-sensitive: target's pitch is held on any bound key.
        // pressed remains physical key state; matched must never drive audio.
        logic [15:0] matched;
        logic [31:0] outside_count;
        logic [6:0] last_outside;
    } guide_display_t;
    function automatic integer cfg_max(input integer index);
        case(index)
            0,6:cfg_max=65534;1:cfg_max=1000;11:cfg_max=2;2:cfg_max=integer'(router_pkg::REVERB_CHAMBER);
            21:cfg_max=32;12:cfg_max=16;13:cfg_max=3;16,17:cfg_max=0;
            default:cfg_max=1;
        endcase
    endfunction
    function automatic logic cfg_value_valid(input integer index,input logic signed[31:0] value);
        // Same ranges as cfg_max; bound the high bits separately so narrow
        // configuration values never require a cascaded signed 32-bit compare.
        if(index<0 || index>=CFG_COUNT || value[31]) return 1'b0;
        if(cfg_id(index)==16'hffff) return 1'b0;
        case(index)
            0,6:return value[31:16]==0 && value[15:0]<=16'hfffe;
            1:return value[31:10]==0 && value[9:0]<=10'd1000;
            2:return router_pkg::reverb_value_valid(value);
            11:return value[31:2]==0 && value[1:0]<=2;
            21:return value[31:6]==0 && value[5:0]<=6'd32;
            12:return value[31:5]==0 && value[4:0]<=5'd16;
            13:return value[31:2]==0;
            16,17:return value==0;
            default:return value[31:1]==0;
        endcase
    endfunction
    function automatic cfg_values_t cfg_defaults();
        cfg_values_t v;
        v='0;v[2]=32'(router_pkg::REVERB_NONE);v[1]=1000;v[8]=1;v[9]=1;v[10]=1;
        v[13]=3;v[21]=16;
        return v;
    endfunction
    function automatic display_config_t display_defaults();
        display_config_t d;
        d.style_id=0;d.theme=0;d.peak=1;d.smooth=1;d.grid=1;
        return d;
    endfunction
    // 显式样式目录：扩展时在此及绘制器注册，不准用 style_id[1:0] 截断。
    function automatic logic style_supported(input logic[15:0] id);
        case(id)16'd0,16'd1,16'd2:style_supported=1;default:style_supported=0;endcase
    endfunction
endpackage
`endif
