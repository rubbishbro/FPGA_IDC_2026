/*
pad_driver_pkg -- shared types for the pad_driver module
use these types by:   
    import pad_driver_pkg::*;
*/

package pad_driver_pkg;

typedef struct packed{
    logic [7:0] val;
} byte_t;

//-------------------------------- led ---------------------------------------
typedef struct packed{
    byte_t      g;
    byte_t      r;
    byte_t      b;
} pixel_t;

//-------------------------------- pad ---------------------------------------

typedef union packed{
    byte_t   [3:0][3:0]   strc_d;
    byte_t   [15:0]       flat_d;
    logic    [127:0]      raw;
} mat4x4;

typedef struct packed{
    byte_t        x;
    byte_t        y;
} vec2;

//-------------------------------- top ---------------------------------------
typedef struct packed{
    logic    [2:0]   x, y;
    pixel_t          pix;
    logic            wr;
} led_param;

typedef struct packed{
    logic    [3:0]   row_s;
    logic    [2:0]   ch_s;
    mat4x4           fmap;
    vec2             pos;
} input_param;

endpackage
