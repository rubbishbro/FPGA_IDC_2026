`timescale 1ns/1ps
// Board NOR initialization: 06h WREN + 01h (SR1=00, SR2=02), then 20ms wait.
// 6Bh read: 8 serial command + 24 serial address + 8 dummy clocks, then quad output.
// Source: instrument region + latched byte offset per destination slot.
// Destination remains {table_select, slot, mode}; no velocity scaling here.
module weight_loader #(
    parameter int SLOTS=16, N_MODES=64, CLK_HZ=100_000_000,
    parameter int SCK_DIV=4, BLANK_WAIT=100, // CS-high inter-note gap, not a content check
    parameter int FLASH_NOTES=SLOTS,
    parameter bit USE_OFFSETS=1'b0, SUPPORT_ABORT=1'b0,
    parameter bit LOAD_CONTROL=1'b0,
    parameter int FLASH_BYTES=8_388_608, // Physical chip capacity, not resource span.
    parameter logic [31:0] FLASH_BASE=32'h0000_0000,
    parameter int TIMEOUT_CYCLES=CLK_HZ/10
) (
    input logic clk, rst_n,
    input logic [3:0] inst,
    input logic start,
    input logic [SLOTS*32-1:0] slot_offsets,
    input logic [SLOTS-1:0] update_mask,
    input logic abort,
    output logic busy, done, err,
    output logic [2:0] error_code, // 1=address, 2=reserved, 3=abort, 4=timeout
    output logic ld_we,
    output logic [$clog2(SLOTS*N_MODES):0] ld_addr,
    output modal_step_pkg::coeff_t ld_co,
    output router_pkg::mod_par_t ld_pm,
    output logic control_we,
    output logic [9:0] control_addr,
    output logic [31:0] control_data,
    output logic cfg_we,
    output logic [$clog2(SLOTS)-1:0] cfg_slot,
    output router_pkg::sustain_cfg_t cfg_data,
    output logic qspi_cs_n, qspi_sck,
    output logic [3:0] qspi_dq_o,
    output logic qspi_dq_oe,
    input logic [3:0] qspi_dq_i
);
    localparam int MW=$clog2(N_MODES), VW=$clog2(SLOTS);
    localparam int NOTE_BYTES=N_MODES*64, TBL_BYTES=FLASH_NOTES*NOTE_BYTES;
    localparam int DIV4=(SCK_DIV/4<1)?1:SCK_DIV/4;
    localparam int DPW=(DIV4>1)?$clog2(DIV4):1;
    localparam int BWW=(BLANK_WAIT>1)?$clog2(BLANK_WAIT+1):1;
    localparam int TW=(TIMEOUT_CYCLES>1)?$clog2(TIMEOUT_CYCLES+1):1;
    localparam int QE_WAIT=(CLK_HZ/50>1)?CLK_HZ/50:1;   // 20ms status-register write cycle
    localparam int QEW=(QE_WAIT>1)?$clog2(QE_WAIT+1):1;
    typedef enum logic [4:0] {W_IDLE,W_QE,W_CHECK,W_HDR,W_DATA,W_WR,W_GAP,W_FILL,W_END} state_t;
    state_t st;
    logic global_read,global_pending;
    logic [9:0] global_word;
    logic [16:0] profile_header;
    logic [31:0] profile_attack,profile_release;
    logic [3:0] inst_r;
    logic [SLOTS*32-1:0] offsets_r;
    logic [SLOTS-1:0] mask_r;
    logic [VW-1:0] slot_i, check_i, fill_s;
    logic [MW-1:0] mode_i, fill_m;
    logic fill_sel, wr_sel;
    logic [1:0] ph;
    logic [DPW-1:0] dph;
    logic [5:0] beat;
    logic [2:0] nib_i;
    logic [3:0] word_i;
    logic [31:0] rx_sh;
    logic [BWW-1:0] wait_cnt;
    logic [TW-1:0] timer;
    logic failed;
    logic [1:0] qe_phase;   // 0=0x06, 3=CS gap, 1=0x01+SR1+SR2, 2=wait
    logic [4:0] qe_bit;
    logic [3:0] qe_gap;
    logic [QEW-1:0] qe_wait;
    wire [32:0] inst_base=33'(inst_r)*33'(TBL_BYTES);
    wire [32:0] base_w={1'b0,FLASH_BASE}+(global_read ? 33'(12*TBL_BYTES) : inst_base+{1'b0,offsets_r[slot_i*32 +: 32]});
    wire [32:0] check_offset={1'b0,offsets_r[check_i*32 +: 32]};
    wire address_bad=check_offset+33'(NOTE_BYTES)>33'(TBL_BYTES) ||
                     {1'b0,FLASH_BASE}+inst_base+check_offset+33'(NOTE_BYTES)>33'(FLASH_BYTES) ||
                     {1'b0,FLASH_BASE}+inst_base+check_offset+33'(NOTE_BYTES)>33'h1000000 ||
                     (check_offset[5:0]!=0) || (FLASH_BASE[5:0]!=0);
    wire ph_last=dph==DPW'(DIV4-1);
    assign qspi_sck=((st==W_HDR || st==W_DATA) && (ph==1 || ph==2))
                  || (st==W_QE && (qe_phase==0 || qe_phase==1) && (ph==1 || ph==2));
    assign qspi_dq_oe=((st==W_HDR) && beat<32) || (st==W_QE && (qe_phase==0 || qe_phase==1));
    function automatic logic [3:0] qe_bitval(input logic [1:0] p, input logic [4:0] b);
        logic [7:0] v;
        begin
            if(p==0) v=8'h06;
            else if(b<8) v=8'h01;
            else if(b<16) v=8'h00;
            else v=8'h02;
            qe_bitval={3'b111,v[7-b[2:0]]};
        end
    endfunction
    function automatic logic [3:0] hdr(input logic [5:0] b);
        logic [7:0] cmd;
        begin
            cmd=8'h6b;
            if(b<8) hdr={3'b111,cmd[7-b]};
            else if(b<32) hdr={3'b111,base_w[31-b]};
            else hdr=4'hf;
        end
    endfunction
    task automatic decode(input logic [3:0] widx,input logic [31:0] w);
        case(widx)
            0:ld_co.a11<=w; 1:ld_co.a12<=w; 2:ld_co.a21<=w; 3:ld_co.a22<=w;
            4:ld_co.gq<=w; 5:ld_co.gv<=w; 6:ld_co.wo<=w;
            7:case(mode_i)
                0:profile_header<=w[16:0];
                1:profile_attack<=w;
                2:profile_release<=w;
                default:;
            endcase
            // 参数表（8 个字）：4 个基值 + 4 个对 lambda 的斜率
            //   a21 不存（= -a12）、S21 不存（= -2*a12 - S12），都用时算出来
            8:ld_pm.a11<=w; 9:ld_pm.a12<=w; 10:ld_pm.a22<=w; 11:ld_pm.wo<=w;
            12:ld_pm.s11<=w; 13:ld_pm.s12<=w; 14:ld_pm.s22<=w; 15:ld_pm.swo<=w;
            default:;
        endcase
    endtask
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            global_read<=0;global_pending<=0;global_word<=0;control_we<=0;control_addr<=0;control_data<=0;cfg_we<=0;cfg_slot<=0;cfg_data<='0;profile_header<=0;profile_attack<=0;profile_release<=0;
            st<=W_IDLE;inst_r<=0;offsets_r<=0;mask_r<=0;
            slot_i<=0;check_i<=0;mode_i<=0;fill_s<=0;fill_m<=0;fill_sel<=0;wr_sel<=0;
            ph<=0;dph<=0;beat<=0;nib_i<=0;word_i<=0;rx_sh<=0;
            wait_cnt<=0;timer<=0;failed<=0;
            qe_phase<=0;qe_bit<=0;qe_gap<=0;qe_wait<=0;
            busy<=0;done<=0;err<=0;error_code<=0;ld_we<=0;ld_addr<=0;ld_co<='0;ld_pm<='0;
            qspi_cs_n<=1;qspi_dq_o<=4'hf;
        end else begin
            done<=0;ld_we<=0;control_we<=0;cfg_we<=0;
            if(busy && !failed && timer<TW'(TIMEOUT_CYCLES)) timer<=timer+1'b1;
            if(busy && !failed && ((SUPPORT_ABORT && abort) || timer>=TW'(TIMEOUT_CYCLES))) begin
                failed<=1;err<=1;error_code<=(SUPPORT_ABORT && abort)?3'd3:3'd4;
                qspi_cs_n<=1;qspi_dq_o<=4'hf;st<=W_FILL;
                fill_s<=0;fill_m<=0;fill_sel<=0;
            end else case(st)
                W_IDLE: if(start) begin
                    global_read<=0;global_pending<=LOAD_CONTROL;global_word<=0;
                    inst_r<=inst;mask_r<=USE_OFFSETS?update_mask:'1;
                    for(integer i=0;i<SLOTS;i++) offsets_r[i*32 +: 32]<=
                        USE_OFFSETS?slot_offsets[i*32 +: 32]:32'(i*NOTE_BYTES);
                    busy<=1;err<=0;failed<=0;error_code<=0;timer<=0;check_i<=0;slot_i<=0;
                    fill_s<=0;fill_m<=0;fill_sel<=0;
                    st<=W_QE;qe_phase<=0;qe_bit<=0;qe_gap<=0;qe_wait<=0;
                    ph<=0;dph<=0;qspi_cs_n<=0;qspi_dq_o<=qe_bitval(2'd0,5'd0);
                end
                W_QE: begin
                    if(qe_phase==2) begin
                        if(qe_wait+1>=QEW'(QE_WAIT)) begin qspi_cs_n<=1;st<=W_CHECK;end
                        else qe_wait<=qe_wait+1'b1;
                    end else if(qe_phase==3) begin
                        if(qe_gap==0) begin
                            qspi_cs_n<=0;qe_phase<=1;qe_bit<=0;ph<=0;dph<=0;
                            qspi_dq_o<=qe_bitval(2'd1,5'd0);
                        end else qe_gap<=qe_gap-1'b1;
                    end else if(ph_last) begin
                        dph<=0;ph<=ph+1'b1;
                        if(ph==2) qspi_dq_o<=qe_bitval(qe_phase,qe_bit+1'b1);
                        else if(ph==3) begin
                            if(qe_phase==0 && qe_bit==5'd7) begin
                                qspi_cs_n<=1;qe_phase<=3;qe_gap<=4'd8;
                            end else if(qe_phase==1 && qe_bit==5'd23) begin
                                qspi_cs_n<=1;qe_phase<=2;qe_wait<=0;
                            end else qe_bit<=qe_bit+1'b1;
                        end
                    end else dph<=dph+1'b1;
                end
                W_CHECK: begin
                    if(LOAD_CONTROL && ({1'b0,FLASH_BASE}+33'(12*TBL_BYTES+4096)>33'(FLASH_BYTES) ||
                       {1'b0,FLASH_BASE}+33'(12*TBL_BYTES+4096)>33'h1000000))begin
                        failed<=1;err<=1;error_code<=1;st<=W_FILL;
                    end else if(mask_r[check_i] && address_bad) begin
                        failed<=1;err<=1;error_code<=1;st<=W_FILL;
                    end else if(check_i==VW'(SLOTS-1)) begin
                        if(mask_r=='0) st<=W_END;
                        else begin wait_cnt<=0;st<=W_GAP;end
                    end else check_i<=check_i+1'b1;
                end
                W_GAP: begin
                    qspi_cs_n<=1;ph<=0;dph<=0;
                    if(wait_cnt<BWW'(BLANK_WAIT)) wait_cnt<=wait_cnt+1'b1;
                    else if(global_pending)begin
                        global_pending<=0;global_read<=1;global_word<=0;
                        st<=W_GAP;
                    end else if(!global_read && !mask_r[slot_i]) begin
                        if(slot_i==VW'(SLOTS-1)) st<=W_END;
                        else slot_i<=slot_i+1'b1;
                    end else begin
                        qspi_cs_n<=0;qspi_dq_o<=hdr(0);beat<=0;nib_i<=0;word_i<=0;
                        mode_i<=0;rx_sh<=0;st<=W_HDR;
                    end
                end
                W_HDR,W_DATA: if(ph_last) begin
                    dph<=0;ph<=ph+1'b1;
                    case(ph)
                        0: if(st==W_DATA) rx_sh<={rx_sh[27:0],qspi_dq_i};
                        2: if(st==W_HDR) qspi_dq_o<=hdr(beat+1'b1);
                        3: if(st==W_HDR) begin
                            if(beat==39) begin st<=W_DATA;nib_i<=0;end
                            else beat<=beat+1'b1;
                        end else if(nib_i==7) begin
                            nib_i<=0;
                            if(global_read)begin
                                control_we<=1;control_addr<=global_word;control_data<=rx_sh;
                                if(global_word==1023)begin
                                    global_read<=0;qspi_cs_n<=1;wait_cnt<=0;st<=W_GAP;
                                end else global_word<=global_word+1'b1;
                            end else begin
                            decode(word_i,rx_sh);
                            if(word_i==15) begin
                                word_i<=0;wr_sel<=0;st<=W_WR;
                            end else word_i<=word_i+1'b1;
                            end
                        end else nib_i<=nib_i+1'b1;
                        default:;
                    endcase
                end else dph<=dph+1'b1;
                W_WR: begin
                    if(LOAD_CONTROL && !wr_sel && mode_i==2)begin
                        cfg_we<=1;cfg_slot<=slot_i;
                        cfg_data.valid<=profile_header[16];cfg_data.period<=profile_header[15:0];
                        cfg_data.a_step<=profile_attack;cfg_data.r_step<=profile_release;
                    end
                    ld_we<=1;ld_addr<={wr_sel,slot_i,mode_i};wr_sel<=~wr_sel;
                    if(wr_sel) begin
                        if(mode_i==MW'(N_MODES-1)) begin
                            qspi_cs_n<=1;wait_cnt<=0;
                            if(slot_i==VW'(SLOTS-1)) st<=W_END;
                            else begin slot_i<=slot_i+1'b1;st<=W_GAP;end
                        end else begin mode_i<=mode_i+1'b1;st<=W_DATA;end
                    end
                end
                W_FILL: begin
                    ld_we<=mask_r[fill_s];ld_co<='0;ld_pm<='0;ld_addr<={fill_sel,fill_s,fill_m};
                    if(fill_sel) begin
                        fill_sel<=0;
                        if(fill_m==MW'(N_MODES-1)) begin
                            fill_m<=0;
                            if(fill_s==VW'(SLOTS-1)) st<=W_END;
                            else fill_s<=fill_s+1'b1;
                        end else fill_m<=fill_m+1'b1;
                    end else fill_sel<=1;
                end
                W_END: begin busy<=0;done<=1;err<=failed;qspi_cs_n<=1;st<=W_IDLE;end
                default: st<=W_IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(SLOTS<2 || N_MODES<2 || (LOAD_CONTROL && N_MODES<3) ||
           SCK_DIV<4 || SCK_DIV%4 || FLASH_NOTES<SLOTS || TIMEOUT_CYCLES<1)
            $fatal(1,"weight_loader invalid parameters");
    end
    // synthesis translate_on
endmodule
