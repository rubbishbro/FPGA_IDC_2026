/*
pad_driver_pkg -- shared types for the pad_driver module
use this types by:   
    import pad_driver_pkg::*;
*/

package pad_driver_pkg;

//-------------------------------- led ---------------------------------------
typedef struct packed{
    logic [7:0] g;
    logic [7:0] r;
    logic [7:0] b;
} pixel_t;

typedef union packed{
    pixel_t [7:0][7:0] pixels;
    logic [1535:0] raw;
} gram_t;

typedef enum logic [1:0] {
    S_PREPARE,
    S_TX,
    S_RESET,
    S_LATCH
} state_t;

//-------------------------------- pad ---------------------------------------
typedef struct packed{
    logic [7:0] val;
} byte_t;

typedef union packed{
    byte_t   [3:0][3:0]   strc_d;
    byte_t   [15:0]       flat_d;
} force_map_t;

//-------------------------------- top ---------------------------------------
typedef struct packed{
    logic    [2:0]   x, y;
    pixel_t          pix;
    logic            wr;
} led_param;

typedef struct packed{
    logic    [3:0]   row_s, col_s;
    force_map_t      fmap;
} sensor_param;

endpackage
