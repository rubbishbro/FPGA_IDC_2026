`timescale 1ns/1ps
module sidebar_ctrl #(
    parameter integer HOT_DWELL_MS=180
)(
    input logic clk,rst_n,tick_ms,
    input logic joy_calibrated,joy_stale,
    input logic signed[14:0] dx,dy,
    input joystick_pkg::joy_dir_t direction,
    input logic nav_valid,nav_repeat,
    input joystick_pkg::joy_dir_t nav_dir,
    output logic nav_ready,
    input logic key_valid,
    input logic[2:0] key_event,              // demo 兼容：1下、2进入、3上、4返回
    input config_pkg::cfg_values_t active_values,
    input logic[config_pkg::CFG_COUNT-1:0] supported,
    output logic cfg_valid,
    input logic cfg_ready,
    output config_pkg::cfg_request_t cfg_request,
    input logic rsp_valid,
    output logic rsp_ready,
    input config_pkg::cfg_response_t cfg_response,
    output config_pkg::sidebar_scene_t scene
);
    import config_pkg::*;
    import joystick_pkg::*;
    localparam logic[2:0] UP=1,DOWN=2,LEFT=3,RIGHT=4;
    logic armed,last_axis_y;
    logic [$clog2(HOT_DWELL_MS+1)-1:0] dwell;
    logic[15:0] tag;
    logic[2:0] action;
    logic action_valid,action_repeat;
    logic[14:0] abs_x,abs_y;
    logic[3:0] step_x,step_y;
    logic signed[10:0] next_x,next_y;
    integer item,count,limit,change;
    // count/limit/change 只在 category/selection/edit_index 变化时锁存；item
    // 保持组合，因为 selection 变化后下一拍就可能用于进入 edit，锁存会落后一拍。
    logic [3:0]  count_q;
    logic [15:0] limit_q;
    logic [4:0]  change_q;
    logic [2:0]  cat_q;
    logic [4:0]  sel_q;
    logic [4:0]  edit_q;
    logic        changed_q;
    wire scene_changed = cat_q!=scene.category || sel_q!=5'(scene.selection) ||
                         edit_q!=scene.edit_index;
    // 变化后的两个周期用组合值旁路，避免进入新 category/edit 页时 count_q/
    // limit_q 还停在上一个 scene 的锁存值。
    wire [3:0]  count_use  = (scene_changed || changed_q) ? 4'(count)  : count_q;
    wire [15:0] limit_use  = (scene_changed || changed_q) ? 16'(limit) : limit_q;
    wire [4:0]  change_use = (scene_changed || changed_q) ? 5'(change) : change_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            count_q<=0;limit_q<=0;change_q<=5'd1;
            cat_q<=0;sel_q<=0;edit_q<=0;changed_q<=0;
        end else begin
            changed_q<=scene_changed;
            if(scene_changed || changed_q) begin
                count_q<=4'(count);limit_q<=16'(limit);change_q<=5'(change);
                cat_q<=scene.category;sel_q<=5'(scene.selection);edit_q<=scene.edit_index;
            end
        end
    end
    assign nav_ready=1'b1;
    assign rsp_ready=1'b1;
    always_comb begin
        abs_x=dx<0?-$signed({dx[14],dx}):$signed({dx[14],dx});
        abs_y=dy<0?-$signed({dy[14],dy}):$signed({dy[14],dy});
        step_x=(abs_x>900 && direction!=JOY_CENTER)?((abs_x>>11)==0?1:(abs_x>>11)):0;
        step_y=(abs_y>900 && direction!=JOY_CENTER)?((abs_y>>11)==0?1:(abs_y>>11)):0;
        next_x=$signed({1'b0,scene.cursor_x})+(dx<0?-$signed({7'd0,step_x}):$signed({7'd0,step_x}));
        next_y=$signed({2'b0,scene.cursor_y})+(dy>0?-$signed({7'd0,step_y}):$signed({7'd0,step_y}));
        if(next_x<0)next_x=0;else if(next_x>799)next_x=799;
        if(next_y<0)next_y=0;else if(next_y>479)next_y=479;
        action=0;action_valid=0;action_repeat=nav_repeat;
        if(nav_valid && armed && joy_calibrated && !joy_stale && nav_dir==direction)begin
            case(nav_dir)
                JOY_UP:action=UP;JOY_DOWN:action=DOWN;JOY_LEFT:action=LEFT;JOY_RIGHT:action=RIGHT;
                JOY_UP_LEFT,JOY_UP_RIGHT,JOY_DOWN_LEFT,JOY_DOWN_RIGHT:begin
                    if(abs_y>abs_x || (abs_y==abs_x && last_axis_y)) action=dy>0?UP:DOWN;
                    else action=dx>0?RIGHT:LEFT;
                end
                default:action=0;
            endcase
            action_valid=(action!=0);
        end
        if(key_valid)begin
            action_repeat=0;action_valid=1;
            case(key_event)1:action=DOWN;2:action=RIGHT;3:action=UP;4:action=LEFT;default:action_valid=0;endcase
        end
        item=category_item(scene.category,int'(scene.selection));
        count=category_count(scene.category);
        limit=cfg_max(scene.edit_index);
        if(scene.edit_index==5)limit=1; // low/high 16-note group, committed by audio backend
        if(scene.edit_index==0)limit=11; // Legacy IDs preserved; ABC piano/guitar at10/11
        if(scene.edit_index==6)limit=2; // 当前实际绘制目录：0/1/2
        change=scene.edit_index==1?10:1;
    end

    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            scene<='0;scene.cursor_x<=400;scene.cursor_y<=240;
            cfg_valid<=0;cfg_request<='0;tag<=0;armed<=0;last_axis_y<=1;dwell<=0;
        end else begin
            if(cfg_valid&&cfg_ready)cfg_valid<=0;
            if(rsp_valid&&scene.busy&&!cfg_valid && cfg_response.tag==cfg_request.tag &&
               cfg_response.id==cfg_request.id)begin
                scene.busy<=0;scene.has_result<=1;scene.result<=cfg_response.result;
            end
            if(joy_calibrated&&!joy_stale&&direction==JOY_CENTER)armed<=1;
            if(joy_stale||!joy_calibrated)begin armed<=0;dwell<=0;end
            if(!scene.open && tick_ms && armed && joy_calibrated&&!joy_stale)begin
                scene.cursor_x<=10'(next_x);scene.cursor_y<=9'(next_y);
                if(next_x<16)begin
                    if(dwell==HOT_DWELL_MS-1)begin
                        scene.open<=1;scene.layer<=0;scene.selection<=0;armed<=0;dwell<=0;
                    end else dwell<=dwell+1'b1;
                end else dwell<=0;
            end
            if(action_valid)begin
                if(action==UP||action==DOWN)last_axis_y<=1;
                else last_axis_y<=0;
                if(!scene.open)begin
                    // 兼容按键打开；摇杆仍须真的把指针移进热区。
                    if(key_valid)begin scene.open<=1;scene.layer<=0;scene.selection<=0;armed<=0;end
                end else if(action==LEFT && !action_repeat)begin
                    armed<=0;
                    if(scene.layer==2)scene.layer<=1; // 取消草稿，不提交
                    else if(scene.layer==1)begin scene.layer<=0;scene.selection<=scene.category;end
                    else begin scene.open<=0;scene.cursor_x<=80;dwell<=0;end
                end else if(scene.layer==0)begin
                    if(action==UP && scene.selection!=0)scene.selection<=scene.selection-1'b1;
                    if(action==DOWN && scene.selection<5)scene.selection<=scene.selection+1'b1;
                    if(action==RIGHT&&!action_repeat)begin
                        scene.category<=scene.selection;scene.selection<=0;scene.layer<=1;armed<=0;
                    end
                end else if(scene.layer==1)begin
                    if(action==UP && scene.selection!=0)scene.selection<=scene.selection-1'b1;
                    if(action==DOWN && int'(scene.selection)<int'(count_use)-1)scene.selection<=scene.selection+1'b1;
                    if(action==RIGHT&&!action_repeat)begin
                        armed<=0;
                        if(!supported[item] || (item==20 && active_values[11]==0))begin scene.has_result<=1;scene.result<=CFG_UNSUPPORTED;end
                        else begin scene.edit_index<=5'(item);scene.draft<=(item==5 && active_values[item]==2)?32'd0:active_values[item];scene.layer<=2;end
                    end
                end else if(scene.layer==2)begin
                    if(action==UP)begin
                        if(scene.edit_index==1||scene.edit_index==21)begin
                            if(scene.draft<limit_use)scene.draft<=scene.draft+change_use>limit_use?limit_use:scene.draft+change_use;
                        end else if(scene.draft>0)scene.draft<=scene.draft-1;
                    end
                    if(action==DOWN)begin
                        if(scene.edit_index==1||scene.edit_index==21)begin
                            if(scene.draft>0)scene.draft<=scene.draft<change_use?0:scene.draft-change_use;
                        end else if(scene.draft<limit_use)scene.draft<=scene.draft+1;
                    end
                    if(action==RIGHT&&!action_repeat&&!scene.busy)begin
                        cfg_request.tag<=tag;cfg_request.id<=cfg_id(scene.edit_index);
                        cfg_request.value<=cfg_action(scene.edit_index)?32'd0:scene.draft;
                        tag<=tag+1'b1;cfg_valid<=1;scene.busy<=1;scene.has_result<=0;
                        scene.layer<=1;armed<=0;
                    end
                end
            end
        end
    end
endmodule
