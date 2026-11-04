module disp_proc #(
    parameter IMG_W = 1280,
    parameter IMG_H = 720,
    parameter EDGE_TH = 8'd40,
    parameter EDGE_ADAPTIVE = 1,
    parameter EDGE_TH_MIN = 12'd24,
    EDGE_TH_MAX = 12'd160
) (
    input wire clk,
    input wire rst_n,

    input wire [1:0] mode,

    input wire        de,
    input wire        hs,
    input wire        vs,
    input wire [23:0] din,

    output reg        de_o,
    output reg        hs_o,
    output reg        vs_o,
    output reg [23:0] dout
);

    wire [15:0] r8 = {8'd0, din[23:16]};
    wire [15:0] g8 = {8'd0, din[15:8]};
    wire [15:0] b8 = {8'd0, din[7:0]};
    wire [15:0] ysum = ((r8 << 6) + (r8 << 3) + (r8 << 2) + r8)
                     + ((g8 << 7) + (g8 << 4) + (g8 << 2) + (g8 << 1))
                     + ((b8 << 4) + (b8 << 3) + (b8 << 2) + b8);
    wire [7:0] gy_now = ysum[15:8];
    reg [7:0] gy, gy2, gy3;
    reg [23:0] rgb1, rgb2, rgb3;
    reg de1, hs1, vs1, de2, hs2, vs2, de3, hs3, vs3;
    reg [1:0] mode1, mode2, mode3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gy <= 0;
            gy2 <= 0;
            gy3 <= 0;
            rgb1 <= 0;
            rgb2 <= 0;
            rgb3 <= 0;
            de1 <= 0;
            hs1 <= 0;
            vs1 <= 0;
            de2 <= 0;
            hs2 <= 0;
            vs2 <= 0;
            de3 <= 0;
            hs3 <= 0;
            vs3 <= 0;
            mode1 <= 0;
            mode2 <= 0;
            mode3 <= 0;
        end else begin
            gy <= gy_now;
            rgb1 <= din;
            de1 <= de;
            hs1 <= hs;
            vs1 <= vs;
            mode1 <= mode;
            gy2 <= gy;
            rgb2 <= rgb1;
            de2 <= de1;
            hs2 <= hs1;
            vs2 <= vs1;
            mode2 <= mode1;
            gy3 <= gy2;
            rgb3 <= rgb2;
            de3 <= de2;
            hs3 <= hs2;
            vs3 <= vs2;
            mode3 <= mode2;
        end
    end

    reg [10:0] x;
    reg [9:0] y;

    reg [1:0] wb;
    reg [1:0] b_prev1;
    reg [1:0] b_prev2;
    reg vs1_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs1_d <= 0;
        else vs1_d <= vs1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x       <= 11'd0;
            y       <= 10'd0;
            wb      <= 2'd0;
            b_prev1 <= 2'd2;
            b_prev2 <= 2'd1;
        end else if (vs1 && !vs1_d && !de1) begin

            x <= 0;
            y <= 0;
            wb <= 0;
            b_prev1 <= 2;
            b_prev2 <= 1;
        end else if (de1) begin
            if (x == IMG_W[10:0] - 11'd1) begin
                x       <= 11'd0;
                y       <= (y == IMG_H[9:0] - 10'd1) ? 10'd0 : y + 10'd1;
                wb      <= (wb == 2'd2) ? 2'd0 : wb + 2'd1;
                b_prev1 <= wb;
                b_prev2 <= b_prev1;
            end else begin
                x <= x + 11'd1;
            end
        end
    end

    (* ram_style = "bram" *)reg [7:0] buf0[0:IMG_W-1];
    (* ram_style = "bram" *)reg [7:0] buf1[0:IMG_W-1];
    (* ram_style = "bram" *)reg [7:0] buf2[0:IMG_W-1];

    always @(posedge clk) begin
        if (de1) begin
            if (wb == 2'd0) buf0[x] <= gy;
            if (wb == 2'd1) buf1[x] <= gy;
            if (wb == 2'd2) buf2[x] <= gy;
        end
    end

    wire win_valid = de1 && (y >= 10'd2) && (x >= 11'd2);
    reg [7:0] q0, q1, q2;
    always @(posedge clk) begin
        q0 <= buf0[x];
        q1 <= buf1[x];
        q2 <= buf2[x];
    end
    reg [1:0] prev1_q, prev2_q;
    reg win_read_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev1_q <= 2;
            prev2_q <= 1;
            win_read_q <= 0;
        end else begin
            prev1_q <= b_prev1;
            prev2_q <= b_prev2;
            win_read_q <= win_valid;
        end
    end
    wire [7:0] rd1 = (prev1_q == 0) ? q0 : (prev1_q == 1) ? q1 : q2;
    wire [7:0] rd2 = (prev2_q == 0) ? q0 : (prev2_q == 1) ? q1 : q2;

    reg [7:0] cur1, cur2;
    reg [7:0] m1, m2;
    reg [7:0] bb1, bb2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur1 <= 8'd0;
            cur2 <= 8'd0;
            m1   <= 8'd0;
            m2   <= 8'd0;
            bb1  <= 8'd0;
            bb2  <= 8'd0;
        end else if (de2) begin
            cur2 <= cur1;
            cur1 <= gy2;
            m2   <= m1;
            m1   <= rd1;
            bb2  <= bb1;
            bb1  <= rd2;
        end
    end

    wire [7:0] a00 = bb2, a01 = bb1, a02 = rd2;
    wire [7:0] a10 = m2, a11 = m1, a12 = rd1;
    wire [7:0] a20 = cur2, a21 = cur1, a22 = gy2;

    reg signed [11:0] gx_s, gy_s;
    always @* begin
        gx_s = $signed({4'd0, a02}) + ($signed({4'd0, a12}) <<< 1) + $signed({4'd0, a22}) -
            $signed({4'd0, a00}) - ($signed({4'd0, a10}) <<< 1) - $signed({4'd0, a20});
        gy_s = $signed({4'd0, a00}) + ($signed({4'd0, a01}) <<< 1) + $signed({4'd0, a02}) -
            $signed({4'd0, a20}) - ($signed({4'd0, a21}) <<< 1) - $signed({4'd0, a22});
    end

    reg signed [11:0] gx_q, gy_q;
    reg win_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gx_q  <= 0;
            gy_q  <= 0;
            win_q <= 0;
        end else begin
            gx_q  <= gx_s;
            gy_q  <= gy_s;
            win_q <= win_read_q;
        end
    end
    wire [11:0] agx = gx_q[11] ? (~gx_q + 12'd1) : gx_q[11:0];
    wire [11:0] agy = gy_q[11] ? (~gy_q + 12'd1) : gy_q[11:0];
    wire [12:0] mag = {1'b0, agx} + {1'b0, agy};

    localparam EDGE_SAMPLES = (IMG_W - 2) * (IMG_H - 2);
    localparam EDGE_MEAN_SHIFT = $clog2(EDGE_SAMPLES);
    localparam EDGE_COUNT_W = $clog2(EDGE_SAMPLES + 2);
    reg [31:0] edge_sum;
    reg [EDGE_COUNT_W-1:0] edge_count;
    reg [11:0] edge_threshold;
    reg edge_vs_d;
    wire [31:0] edge_mean = edge_sum >> EDGE_MEAN_SHIFT;
    wire [31:0] edge_scaled = edge_mean + (edge_mean >> 1);
    wire [11:0] edge_next=edge_scaled<EDGE_TH_MIN?EDGE_TH_MIN:
                            edge_scaled>EDGE_TH_MAX?EDGE_TH_MAX:edge_scaled[11:0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            edge_sum <= 0;
            edge_count <= 0;
            edge_threshold <= EDGE_TH;
            edge_vs_d <= 0;
        end else begin
            edge_vs_d <= vs3;
            if (vs3 && !edge_vs_d && !de3) begin
                edge_threshold <= edge_count == EDGE_SAMPLES ? edge_next : EDGE_TH;
                edge_sum <= 0;
                edge_count <= 0;
            end else if (win_q) begin

                if (edge_count <= EDGE_SAMPLES) begin
                    edge_count <= edge_count + 1'b1;
                    if (edge_count < EDGE_SAMPLES) edge_sum <= edge_sum + {19'd0, mag};
                end
            end
        end
    end
    wire [11:0] edge_limit = EDGE_ADAPTIVE ? edge_threshold : {4'd0, EDGE_TH};
    wire is_edge = win_q && (mag >= {1'b0, edge_limit});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_o <= 1'b0;
            hs_o <= 1'b0;
            vs_o <= 1'b0;
            dout <= 24'd0;
        end else begin
            de_o <= de3;
            hs_o <= hs3;
            vs_o <= vs3;
            case (mode3)
                2'd0:    dout <= rgb3;
                2'd1:    dout <= is_edge ? 24'hFFFFFF : 24'h000000;
                default: dout <= {gy3, gy3, gy3};
            endcase
        end
    end

    // synthesis translate_off
    initial
        if(IMG_W<3||IMG_W>2048||IMG_H<3||IMG_H>1024||EDGE_TH_MIN<1||EDGE_TH_MAX<EDGE_TH_MIN||EDGE_TH_MAX>2040||EDGE_TH<EDGE_TH_MIN||EDGE_TH>EDGE_TH_MAX)
            $fatal(1, "Invalid display edge parameters");
    // synthesis translate_on
endmodule
