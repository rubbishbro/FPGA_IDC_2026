`ifndef JOYSTICK_PKG_SV
`define JOYSTICK_PKG_SV
package joystick_pkg;
    // 独立于菜单动作：上推不是 OK，下推不是 Back。
    typedef enum logic [3:0] {
        JOY_CENTER = 4'd0,
        JOY_UP     = 4'd1,
        JOY_DOWN   = 4'd2,
        JOY_LEFT   = 4'd3,
        JOY_RIGHT  = 4'd4,
        JOY_UP_LEFT    = 4'd5,
        JOY_UP_RIGHT   = 4'd6,
        JOY_DOWN_LEFT  = 4'd7,
        JOY_DOWN_RIGHT = 4'd8
    } joy_dir_t;
endpackage
`endif
