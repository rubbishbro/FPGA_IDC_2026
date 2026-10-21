// -----------------------------------------------------------------------------
// class_format_pkg.sv -- 统一记录格式（A/B/C 共用）与力度带地址
//
// 冻结（2026-10-20）：
//   Event 64 / Index 64 / Control 256 / Core 72 / Seed 64
//   Key = {class, instrument, note}，没有 layer
//   n_vel = 4（先冻结），band = vel8[7:6]
//   core 地址 = mode_offset + band*n_modes + mode
//
// 这里只放类型和纯函数；pack/unpack 的位序必须与
// python/modal_sim/class_format.py 完全一致。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package class_format_pkg;

    // ---- Event（64-bit）---------------------------------------------------
    typedef struct packed {
        logic [9:0]  reserved_hi;   // [63:54]
        logic [15:0] timestamp;     // [53:38]
        logic [1:0]  event_type;    // [37:36]
        logic [11:0] note_id;       // [35:24]
        logic [7:0]  velocity;      // [23:16] 0..255
        logic        gate;          // [15]
        logic [6:0]  note;          // [14:8]
        logic [3:0]  instrument;    // [7:4]
        logic [1:0]  reserved_lo;   // [3:2]  原 layer；B/C 必须 0
        logic [1:0]  cls;         // [1:0]
    } event_t;

    // ---- Key（13-bit）-----------------------------------------------------
    typedef struct packed {
        logic [1:0] cls;
        logic [3:0] instrument;
        logic [6:0] note;
    } key_t;

    // ---- Index（64-bit）---------------------------------------------------
    typedef struct packed {
        logic        present;       // [63]
        logic [6:0]  n_modes;       // [62:56] 1..48
        logic [2:0]  n_vel;         // [55:53] 1..8（冻结 4）
        logic [15:0] mode_offset;   // [52:37] 第 0 带 core 起点
        logic [11:0] ctrl_index;    // [36:25]
        logic [1:0]  version;       // [24:23] 0=A/B，2=C
        logic        has_control;   // [22]
        logic        has_seed;      // [21]
        logic [1:0]  cls;         // [20:19]
        logic [5:0]  flags;         // [18:13]
        logic [12:0] reserved;      // [12:0]
    } index_t;

    // ---- Core（72-bit）----------------------------------------------------
    typedef struct packed {
        logic signed [25:0] G;      // [71:46] Q2.24
        logic [23:0]        a2;     // [45:22] UQ0.24
        logic signed [21:0] a1;     // [21:0]  Q2.20
    } core_t;

    // ---- Seed（64-bit）----------------------------------------------------
    typedef struct packed {
        logic signed [31:0] y2;     // [63:32] Q2.30
        logic signed [31:0] y1;     // [31:0]  Q2.30
    } seed_t;

    // ---- Control 公共头（word0，64-bit）-----------------------------------
    typedef struct packed {
        logic [4:0]  reserved_hi;   // [63:59]
        logic [19:0] tail_samples;  // [58:39]
        logic [2:0]  choke_group;   // [38:36]
        logic [3:0]  flags;         // [35:32]
        logic [15:0] key_gain;      // [31:16] UQ1.15
        logic [7:0]  ctrl_format;   // [15:8]  0=A，1=B，2=C
        logic [3:0]  instrument;    // [7:4]
        logic [1:0]  reserved_lo;   // [3:2]   原 layer
        logic [1:0]  cls;         // [1:0]
    } ctrl_common_t;

    // ---- 力度：MIDI 0..127 -> 8-bit，band = 高 2 位 ------------------------
    function automatic logic [7:0] vel8_from_midi(input logic [6:0] midi);
        return {midi, 1'b0};          // ×2，0..254
    endfunction

    function automatic logic [1:0] band_of(input logic [7:0] vel8);
        return vel8[7:6];             // 4 带
    endfunction

    function automatic logic band_valid(input index_t idx, input logic [1:0] band);
        return ({1'b0, band} < {1'b0, idx.n_vel});
    endfunction

    // 18-bit 足够：16-bit offset + 4 带 × 48 模态
    function automatic logic [17:0] core_addr(input index_t idx,
                                              input logic [1:0] band,
                                              input logic [6:0] mode);
        logic [17:0] off, stride, b;
        begin
            off    = {2'b0, idx.mode_offset};
            stride = {11'b0, idx.n_modes};
            b      = {16'b0, band};
            core_addr = off + b * stride + {11'b0, mode};
        end
    endfunction

    function automatic key_t key_of(input event_t ev);
        key_t k;
        k.cls        = ev.cls;
        k.instrument = ev.instrument;
        k.note       = ev.note;
        return k;
    endfunction

endpackage
