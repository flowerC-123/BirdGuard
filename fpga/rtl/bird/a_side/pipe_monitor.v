// Periodic pipeline counters and completed-transaction telemetry.
module pipe_monitor #(
    parameter integer CLK_HZ            = 50_000_000,
    parameter integer BAUD              = 115200,
    parameter integer PERIOD_MS         = 500,
    parameter integer TRACE_DIAGNOSTICS = 0,
    parameter integer MIN_AREA          = 100
) (
    input wire clk,
    input wire rst_n,

    input wire        i_frame_start,
    input wire        i_frame_end,
    input wire        i_cclv_valid,
    input wire        i_cclv_done,
    input wire [ 3:0] i_cclv_count,
    input wire [16:0] i_cclv_area,
    input wire        i_desc_valid,
    input wire        i_desc_ready,
    input wire        i_lease_valid,
    input wire        i_lease_gnt,
    input wire        i_reader_idle,
    input wire        i_busy,
    input wire        i_captured,
    input wire        i_rejected,
    input wire [ 3:0] i_error_code,
    input wire        i_wire_done,
    input wire        i_rx_byte,
    input wire        i_matched,
    input wire        i_timed_out,
    input wire [ 3:0] i_state_code,

    input  wire [  7:0] i_roi_diag,
    input  wire [383:0] i_roi_trace,
    input  wire         i_roi_trace_motion,
    output wire         mon_tx
);

    function [7:0] hx;
        input [3:0] v;
        reg [7:0] r;
        begin
            case (v)
                4'h0: r = "0";
                4'h1: r = "1";
                4'h2: r = "2";
                4'h3: r = "3";
                4'h4: r = "4";
                4'h5: r = "5";
                4'h6: r = "6";
                4'h7: r = "7";
                4'h8: r = "8";
                4'h9: r = "9";
                4'ha: r = "A";
                4'hb: r = "B";
                4'hc: r = "C";
                4'hd: r = "D";
                4'he: r = "E";
                4'hf: r = "F";
                default: r = "?";
            endcase
            hx = r;
        end
    endfunction

    localparam [63:0] PERIOD_CYCLES_WIDE = (64'd1 * CLK_HZ * PERIOD_MS) / 1000;
    localparam [31:0] PERIOD_CYCLES = PERIOD_CYCLES_WIDE[31:0];
    localparam integer MSG_LEN = TRACE_DIAGNOSTICS ? 286 : 112;
    localparam integer MSG_W = 760;

    reg [15:0]
        c_frame,
        c_cclv,
        c_done,
        c_end,
        c_desc,
        c_cap,
        c_gnt,
        c_rej,
        c_wire,
        c_rx,
        c_mat,
        c_to,
        c_maxa,
        c_over;
    reg [15:0]
        s_frame,
        s_cclv,
        s_done,
        s_end,
        s_desc,
        s_cap,
        s_gnt,
        s_rej,
        s_wire,
        s_rx,
        s_mat,
        s_to,
        s_maxa,
        s_over;
    reg [3:0] s_err, s_ccln, s_state, s_flags;
    reg [3:0] live_err, live_ccln;
    localparam [16:0] MIN_AREA17 = MIN_AREA[16:0];

    reg [31:0] wcnt;
    reg dump_pulse, load_req;

    `define SAT_INC(c) if (c != 16'hFFFF) c <= c + 16'd1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_frame <= 0;
            c_cclv <= 0;
            c_done <= 0;
            c_end <= 0;
            c_desc <= 0;
            c_cap <= 0;
            c_gnt <= 0;
            c_rej <= 0;
            c_wire <= 0;
            c_rx <= 0;
            c_mat <= 0;
            c_to <= 0;
            c_maxa <= 0;
            c_over <= 0;
            wcnt <= 0;
            dump_pulse <= 0;
            s_err <= 0;
            s_ccln <= 0;
            s_flags <= 0;
            s_state <= 0;
            live_err <= 0;
            live_ccln <= 0;
            s_frame <= 0;
            s_cclv <= 0;
            s_done <= 0;
            s_end <= 0;
            s_desc <= 0;
            s_cap <= 0;
            s_gnt <= 0;
            s_rej <= 0;
            s_wire <= 0;
            s_rx <= 0;
            s_mat <= 0;
            s_to <= 0;
            s_maxa <= 0;
            s_over <= 0;
        end else begin
            dump_pulse <= 1'b0;
            if (i_frame_start) `SAT_INC(c_frame);
            if (i_frame_end) `SAT_INC(c_end);
            if (i_cclv_valid) begin
                `SAT_INC(c_cclv);

                if (i_cclv_area[16]) c_maxa <= 16'hFFFF;
                else if (i_cclv_area[15:0] > c_maxa) c_maxa <= i_cclv_area[15:0];

                if (i_cclv_area >= MIN_AREA17) `SAT_INC(c_over);
            end
            if (i_cclv_done) begin
                `SAT_INC(c_done);
                live_ccln <= i_cclv_count;
            end
            if (i_desc_valid && i_desc_ready) `SAT_INC(c_desc);
            if (i_captured) `SAT_INC(c_cap);
            if (i_lease_gnt) `SAT_INC(c_gnt);
            if (i_rejected) begin
                `SAT_INC(c_rej);
                live_err <= i_error_code;
            end
            if (i_wire_done) `SAT_INC(c_wire);
            if (i_rx_byte) `SAT_INC(c_rx);
            if (i_matched) `SAT_INC(c_mat);
            if (i_timed_out) `SAT_INC(c_to);

            if (wcnt >= PERIOD_CYCLES - 1) begin
                wcnt       <= 0;
                dump_pulse <= 1'b1;
                s_frame    <= c_frame;
                s_cclv     <= c_cclv;
                s_done     <= c_done;
                s_end      <= c_end;
                s_desc     <= c_desc;
                s_cap      <= c_cap;
                s_gnt      <= c_gnt;
                s_rej      <= c_rej;
                s_wire     <= c_wire;
                s_rx       <= c_rx;
                s_mat      <= c_mat;
                s_to       <= c_to;
                s_maxa     <= c_maxa;
                s_over     <= c_over;
                s_err      <= live_err;
                s_ccln     <= live_ccln;
                s_flags    <= {i_desc_ready, i_reader_idle, i_lease_valid, i_busy};
                s_state    <= i_state_code;
                c_frame    <= i_frame_start;
                c_cclv     <= i_cclv_valid;
                c_done     <= i_cclv_done;
                c_end      <= i_frame_end;
                c_desc     <= i_desc_valid && i_desc_ready;
                c_cap      <= i_captured;
                c_gnt      <= i_lease_gnt;
                c_rej      <= i_rejected;
                c_wire     <= i_wire_done;
                c_rx       <= i_rx_byte;
                c_mat      <= i_matched;
                c_to       <= i_timed_out;
                c_maxa     <= i_cclv_valid ? (i_cclv_area[16] ? 16'hffff : i_cclv_area[15:0]) : 0;
                c_over     <= i_cclv_valid && i_cclv_area >= MIN_AREA17;
            end else begin
                wcnt <= wcnt + 1'b1;
            end
        end
    end

    reg [15:0] dc[0:7], ds[0:7];
    reg [383:0] last_trace, trace_snapshot;
    reg trace_seen, trace_seen_snapshot, last_kind, kind_snapshot;
    integer d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (d = 0; d < 8; d = d + 1) begin
                dc[d] <= 0;
                ds[d] <= 0;
            end
            last_trace <= 0;
            trace_snapshot <= 0;
            trace_seen <= 0;
            trace_seen_snapshot <= 0;
            last_kind <= 0;
            kind_snapshot <= 0;
        end else if (TRACE_DIAGNOSTICS) begin
            if (i_wire_done) begin
                last_trace <= i_roi_trace;
                last_kind  <= i_roi_trace_motion;
                trace_seen <= 1;
            end
            for (d = 0; d < 8; d = d + 1) begin
                if (i_roi_diag[d] && dc[d] != 16'hffff) dc[d] <= dc[d] + 1'b1;
                if (wcnt >= PERIOD_CYCLES - 1) begin
                    ds[d] <= dc[d];
                    dc[d] <= i_roi_diag[d];
                end
            end
            if (wcnt >= PERIOD_CYCLES - 1) begin
                trace_snapshot <= last_trace;
                kind_snapshot <= last_kind;
                trace_seen_snapshot <= trace_seen;
            end
        end
    end
    reg [MSG_W-1:0] sh;
    reg [8:0] idx;
    reg sending;
    wire tx_ready;
    reg [7:0] tx_data;
    reg is_hex;
    always @* begin
        tx_data = hx(sh[MSG_W-1:MSG_W-4]);
        is_hex  = 1;
        case (idx)
            0: begin
                tx_data = 8'd70;
                is_hex  = 0;
            end
            1,8,15,22,29,36,43,50,57,64,71,78,85,92,99,104,108,118,125,132,139,146,153,160,167,179,183,187:begin
                tx_data = 8'd61;
                is_hex  = 0;
            end
            6,13,20,27,34,41,48,55,62,69,76,83,90,97,102,106,116,123,130,137,144,151,158,165,177,181,185:begin
                tx_data = 8'd32;
                is_hex  = 0;
            end
            7: begin
                tx_data = 8'd67;
                is_hex  = 0;
            end
            14, 152: begin
                tx_data = 8'd78;
                is_hex  = 0;
            end
            21: begin
                tx_data = 8'd71;
                is_hex  = 0;
            end
            28: begin
                tx_data = 8'd68;
                is_hex  = 0;
            end
            35, 166: begin
                tx_data = 8'd80;
                is_hex  = 0;
            end
            42: begin
                tx_data = 8'd76;
                is_hex  = 0;
            end
            49: begin
                tx_data = 8'd87;
                is_hex  = 0;
            end
            56, 112: begin
                tx_data = 8'd82;
                is_hex  = 0;
            end
            63, 159: begin
                tx_data = 8'd77;
                is_hex  = 0;
            end
            70, 174: begin
                tx_data = 8'd84;
                is_hex  = 0;
            end
            77, 175: begin
                tx_data = 8'd88;
                is_hex  = 0;
            end
            84: begin
                tx_data = 8'd65;
                is_hex  = 0;
            end
            91: begin
                tx_data = 8'd66;
                is_hex  = 0;
            end
            98: begin
                tx_data = 8'd69;
                is_hex  = 0;
            end
            103, 178: begin
                tx_data = 8'd75;
                is_hex  = 0;
            end
            107: begin
                tx_data = 8'd83;
                is_hex  = 0;
            end
            110, 172, 284: begin
                tx_data = 8'd13;
                is_hex  = 0;
            end
            111, 173, 285: begin
                tx_data = 8'd10;
                is_hex  = 0;
            end
            113, 138: begin
                tx_data = 8'd79;
                is_hex  = 0;
            end
            114, 117: begin
                tx_data = 8'd73;
                is_hex  = 0;
            end
            115, 176: begin
                tx_data = 8'd57;
                is_hex  = 0;
            end
            124: begin
                tx_data = 8'd81;
                is_hex  = 0;
            end
            131: begin
                tx_data = 8'd85;
                is_hex  = 0;
            end
            145, 186: begin
                tx_data = 8'd72;
                is_hex  = 0;
            end
            182: begin
                tx_data = 8'd86;
                is_hex  = 0;
            end
            default: ;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh <= 0;
            idx <= 0;
            sending <= 0;
            load_req <= 0;
        end else begin
            if (dump_pulse) load_req <= 1;
            if (load_req && !sending) begin
                sh <= {
                    s_frame,
                    s_cclv,
                    s_done,
                    s_end,
                    s_desc,
                    s_cap,
                    s_gnt,
                    s_wire,
                    s_rx,
                    s_mat,
                    s_to,
                    s_rej,
                    s_maxa,
                    s_over,
                    s_err,
                    s_ccln,
                    s_flags,
                    s_state,
                    ds[0],
                    ds[1],
                    ds[2],
                    ds[3],
                    ds[4],
                    ds[5],
                    ds[6],
                    ds[7],
                    3'd0,
                    kind_snapshot,
                    3'd0,
                    trace_seen_snapshot,
                    trace_snapshot
                };
                idx <= 0;
                sending <= 1;
                load_req <= 0;
            end else if (sending && tx_ready) begin
                if (is_hex) sh <= sh << 4;
                if (idx == MSG_LEN - 1) sending <= 0;
                else idx <= idx + 1'b1;
            end
        end
    end
    uart_tx_8n1 #(
        .CLOCK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data(tx_data),
        .valid(sending),
        .ready(tx_ready),
        .tx(mon_tx),
        .done()
    );

    `undef SAT_INC
    // synthesis translate_off
    initial begin
        if (PERIOD_CYCLES_WIDE < 1 || PERIOD_CYCLES_WIDE > 64'hffffffff ||
            CLK_HZ <= 0 || PERIOD_MS <= 0 || BAUD <= 0 || MIN_AREA < 0 || MIN_AREA > 131071)
            $fatal(1, "Invalid pipe_monitor parameters");
    end
    // synthesis translate_on
endmodule
