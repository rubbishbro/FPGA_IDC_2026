// -----------------------------------------------------------------------------
// class_format_probe.sv -- 仅仿真：把 class_format_pkg 的 pack/unpack 结果
// 摊平成端口，供 cocotb 与 python/modal_sim/class_format.py 对拍。
// 不参与综合。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module class_format_probe (
    input  logic [63:0] event_i,
    input  logic [63:0] index_i,
    input  logic [71:0] core_i,
    input  logic [63:0] seed_i,
    input  logic [63:0] ctrl_i,
    input  logic [6:0]  midi_i,
    input  logic [7:0]  vel8_i,
    input  logic [6:0]  mode_i,

    output logic [1:0]  ev_class,
    output logic [1:0]  ev_reserved_lo,
    output logic [3:0]  ev_instrument,
    output logic [6:0]  ev_note,
    output logic        ev_gate,
    output logic [7:0]  ev_velocity,
    output logic [11:0] ev_note_id,
    output logic [1:0]  ev_event_type,
    output logic [15:0] ev_timestamp,

    output logic [1:0]  key_class,
    output logic [3:0]  key_instrument,
    output logic [6:0]  key_note,

    output logic        idx_present,
    output logic [6:0]  idx_n_modes,
    output logic [2:0]  idx_n_vel,
    output logic [15:0] idx_mode_offset,
    output logic [11:0] idx_ctrl_index,
    output logic [1:0]  idx_version,
    output logic        idx_has_control,
    output logic        idx_has_seed,
    output logic [1:0]  idx_class,
    output logic [5:0]  idx_flags,
    output logic [12:0] idx_reserved,

    output logic signed [25:0] core_G,
    output logic [23:0]        core_a2,
    output logic signed [21:0] core_a1,

    output logic signed [31:0] seed_y2,
    output logic signed [31:0] seed_y1,

    output logic [1:0]  ctrl_class,
    output logic [3:0]  ctrl_instrument,
    output logic [7:0]  ctrl_format,
    output logic [15:0] ctrl_key_gain,
    output logic [3:0]  ctrl_flags,
    output logic [2:0]  ctrl_choke_group,
    output logic [19:0] ctrl_tail_samples,

    output logic [7:0]  vel8_from_midi_o,
    output logic [1:0]  band_o,
    output logic        band_valid_o,
    output logic [17:0] core_addr_o
);
    import class_format_pkg::*;

    event_t      ev;
    index_t      idx;
    core_t       co;
    seed_t       sd;
    ctrl_common_t cc;
    key_t        k;

    assign ev = event_i;
    assign idx = index_i;
    assign co = core_i;
    assign sd = seed_i;
    assign cc = ctrl_i[63:0];
    assign k  = key_of(ev);

    assign ev_class       = ev.cls;
    assign ev_reserved_lo = ev.reserved_lo;
    assign ev_instrument  = ev.instrument;
    assign ev_note        = ev.note;
    assign ev_gate        = ev.gate;
    assign ev_velocity    = ev.velocity;
    assign ev_note_id     = ev.note_id;
    assign ev_event_type  = ev.event_type;
    assign ev_timestamp   = ev.timestamp;

    assign key_class      = k.cls;
    assign key_instrument = k.instrument;
    assign key_note       = k.note;

    assign idx_present     = idx.present;
    assign idx_n_modes     = idx.n_modes;
    assign idx_n_vel       = idx.n_vel;
    assign idx_mode_offset = idx.mode_offset;
    assign idx_ctrl_index  = idx.ctrl_index;
    assign idx_version     = idx.version;
    assign idx_has_control = idx.has_control;
    assign idx_has_seed    = idx.has_seed;
    assign idx_class       = idx.cls;
    assign idx_flags       = idx.flags;
    assign idx_reserved    = idx.reserved;

    assign core_G  = co.G;
    assign core_a2 = co.a2;
    assign core_a1 = co.a1;

    assign seed_y2 = sd.y2;
    assign seed_y1 = sd.y1;

    assign ctrl_class        = cc.cls;
    assign ctrl_instrument   = cc.instrument;
    assign ctrl_format       = cc.ctrl_format;
    assign ctrl_key_gain     = cc.key_gain;
    assign ctrl_flags        = cc.flags;
    assign ctrl_choke_group  = cc.choke_group;
    assign ctrl_tail_samples = cc.tail_samples;

    assign vel8_from_midi_o = vel8_from_midi(midi_i);
    assign band_o           = band_of(vel8_i);
    assign band_valid_o     = band_valid(idx, band_o);
    assign core_addr_o      = core_addr(idx, band_o, mode_i);

endmodule
