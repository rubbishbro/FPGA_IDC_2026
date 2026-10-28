`ifndef CONFIG_PKG_SV
`define CONFIG_PKG_SV
package config_pkg;
    typedef struct packed {
        logic [15:0] tag;
        logic [15:0] id;
        logic signed [31:0] value;
    } cfg_request_t;
    localparam logic [7:0] CFG_OK=0, CFG_UNSUPPORTED=1, CFG_OUT_OF_RANGE=2,
                           CFG_DENIED=3, CFG_FAILED=4;
    typedef struct packed {
        logic [15:0] tag;
        logic [15:0] id;
        logic [7:0] result;
        logic signed [31:0] applied_value;
    } cfg_response_t;
    localparam integer CFG_COUNT=20;
    localparam logic [19:0] DISPLAY_MASK=20'h007c0;
    localparam logic [19:0] LOCAL_MASK=DISPLAY_MASK | 20'h10000;
    // 一个统一值数组；字段只在 cfg_id/cfg_index 中定义，UI 不拥有音频寄存器。
    typedef logic [CFG_COUNT-1:0][31:0] cfg_values_t;
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
        logic [19:0] supported;
    } sidebar_snapshot_t;

    function automatic logic [15:0] cfg_id(input integer index);
        case(index)
            0:cfg_id=16'h0100; 1:cfg_id=16'h0101; 2:cfg_id=16'h0200;
            3:cfg_id=16'h0210; 4:cfg_id=16'h0211; 5:cfg_id=16'h0300;
            6:cfg_id=16'h0400; 7:cfg_id=16'h0401; 8:cfg_id=16'h0402;
            9:cfg_id=16'h0403;10:cfg_id=16'h0404;11:cfg_id=16'h0500;
           12:cfg_id=16'h0501;13:cfg_id=16'h0502;14:cfg_id=16'h0600;
           15:cfg_id=16'h0601;16:cfg_id=16'h8000;17:cfg_id=16'h8001;
           18:cfg_id=16'h8002;19:cfg_id=16'h8003;default:cfg_id=16'hffff;
        endcase
    endfunction
    function automatic integer cfg_index(input logic [15:0] id);
        cfg_index=-1;
        for(integer i=0;i<CFG_COUNT;i=i+1) if(cfg_id(i)==id)cfg_index=i;
    endfunction
    function automatic integer category_base(input integer category);
        case(category)
            0:category_base=0;1:category_base=2;2:category_base=5;
            3:category_base=6;4:category_base=11;default:category_base=14;
        endcase
    endfunction
    function automatic integer category_count(input integer category);
        case(category)
            0:category_count=2;1:category_count=3;2:category_count=1;
            3:category_count=5;4:category_count=3;default:category_count=6;
        endcase
    endfunction
    function automatic integer cfg_max(input integer index);
        case(index)
            0,6:cfg_max=65534;1,4:cfg_max=1000;2,11,14,15:cfg_max=2;
            12:cfg_max=16;13:cfg_max=3;16,17,19:cfg_max=0;
            default:cfg_max=1;
        endcase
    endfunction
    function automatic logic cfg_value_valid(input integer index,input logic signed[31:0] value);
        cfg_value_valid=(index>=0 && index<CFG_COUNT && value>=0 && value<=cfg_max(index));
    endfunction
    function automatic cfg_values_t cfg_defaults();
        cfg_values_t v;
        v='0;v[1]=1000;v[4]=650;v[8]=1;v[9]=1;v[10]=1;
        v[13]=3;v[14]=1;v[15]=1;
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
