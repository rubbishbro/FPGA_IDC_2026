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
    input logic[19:0] supported,
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
    logic signed[15:0] abs_x,abs_y;
    integer step_x,step_y,next_x,next_y,item,count,limit,change;
    assign nav_ready=1'b1;
    assign rsp_ready=1'b1;
    always_comb begin
        abs_x=dx<0?-$signed({dx[14],dx}):$signed({dx[14],dx});
        abs_y=dy<0?-$signed({dy[14],dy}):$signed({dy[14],dy});
        step_x=(abs_x>900 && direction!=JOY_CENTER)?((abs_x>>11)==0?1:(abs_x>>11)):0;
        step_y=(abs_y>900 && direction!=JOY_CENTER)?((abs_y>>11)==0?1:(abs_y>>11)):0;
        next_x=int'(scene.cursor_x)+(dx<0?-step_x:step_x);
        next_y=int'(scene.cursor_y)+(dy>0?-step_y:step_y);
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
        item=category_base(scene.category)+int'(scene.selection);
        count=category_count(scene.category);
        limit=cfg_max(scene.edit_index);
        if(scene.edit_index==0)limit=9; // 当前 router_pkg 的音色目录 0..9，保持唯一 ID
        if(scene.edit_index==6)limit=2; // 当前实际绘制目录：0/1/2
        change=(scene.edit_index==1 || scene.edit_index==4)?10:1;
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
                    if(action==DOWN && int'(scene.selection)<count-1)scene.selection<=scene.selection+1'b1;
                    if(action==RIGHT&&!action_repeat)begin
                        armed<=0;
                        if(!supported[item])begin scene.has_result<=1;scene.result<=CFG_UNSUPPORTED;end
                        else begin scene.edit_index<=5'(item);scene.draft<=active_values[item];scene.layer<=2;end
                    end
                end else if(scene.layer==2)begin
                    if(action==UP)begin
                        if(scene.edit_index==1||scene.edit_index==4)begin
                            if(scene.draft<limit)scene.draft<=scene.draft+change>limit?limit:scene.draft+change;
                        end else if(scene.draft>0)scene.draft<=scene.draft-1;
                    end
                    if(action==DOWN)begin
                        if(scene.edit_index==1||scene.edit_index==4)begin
                            if(scene.draft>0)scene.draft<=scene.draft<change?0:scene.draft-change;
                        end else if(scene.draft<limit)scene.draft<=scene.draft+1;
                    end
                    if(action==RIGHT&&!action_repeat&&!scene.busy)begin
                        cfg_request.tag<=tag;cfg_request.id<=cfg_id(scene.edit_index);
                        cfg_request.value<=scene.edit_index>=16&&scene.edit_index!=18?32'd0:scene.draft;
                        tag<=tag+1'b1;cfg_valid<=1;scene.busy<=1;scene.has_result<=0;
                        scene.layer<=1;armed<=0;
                    end
                end
            end
        end
    end
endmodule
