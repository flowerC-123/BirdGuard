module awb #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
) (
    input I_clk,
    input I_rst_n,

    input         I_tlast,
    input         I_tuser,
    input  [95:0] I_tdata,
    input         I_tvalid,
    output        I_tready,

    output        O_tlast,
    output        O_tuser,
    output [95:0] O_tdata,
    output        O_tvalid,
    input         O_tready
);

    reg I_tvalid_r0, I_tvalid_r1;
    reg [95:0] I_tdata_d0, I_tdata_d1;

    reg  [31:0] sum_r      [0:3];
    reg  [31:0] sum_g      [0:3];
    reg  [31:0] sum_b      [0:3];

    wire [95:0] data_d0;
    wire        valid_d0;
    wire        I_tuser_r0;

    reg         I_tuser_r1;

    reg  [95:0] data_d1;
    reg         valid_d1;
    reg  [ 9:0] rgb_sum    [0:3];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            I_tdata_d0 <= 0;
            I_tdata_d1 <= 0;
            {I_tvalid_r0, I_tvalid_r1} <= 0;
        end else begin
            I_tdata_d0  <= I_tdata;
            I_tdata_d1  <= I_tdata_d0;
            I_tvalid_r0 <= I_tvalid;
            I_tvalid_r1 <= I_tvalid_r0;
        end
    end

    wire [7:0] rgb888_r_d[0:3];
    wire [7:0] rgb888_g_d[0:3];
    wire [7:0] rgb888_b_d[0:3];

    assign rgb888_r_d[0] = I_tdata[16+:8];
    assign rgb888_g_d[0] = I_tdata[8+:8];
    assign rgb888_b_d[0] = I_tdata[0+:8];

    wire [7:0] rgb888_r_d0[0:3];
    wire [7:0] rgb888_g_d0[0:3];
    wire [7:0] rgb888_b_d0[0:3];

    assign rgb888_r_d0[0] = I_tdata_d0[16+:8];
    assign rgb888_g_d0[0] = I_tdata_d0[8+:8];
    assign rgb888_b_d0[0] = I_tdata_d0[0+:8];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            rgb_sum[0] <= 0;
        end else if (I_tvalid) begin
            rgb_sum[0] <= rgb888_r_d[0] + rgb888_g_d[0] + rgb888_b_d[0];
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin

            sum_r[0] <= 1;
            sum_g[0] <= 1;
            sum_b[0] <= 1;
        end else if (I_tvalid_r0 && (rgb_sum[0] < 720)) begin

            sum_r[0] <= sum_r[0] + rgb888_r_d0[0];
            sum_g[0] <= sum_g[0] + rgb888_g_d0[0];
            sum_b[0] <= sum_b[0] + rgb888_b_d0[0];
        end
    end

    wire [47:0] dout_R[3:0];
    wire [47:0] dout_B[3:0];

    wire done[3:0];

    wire [47:0] in_r_x1;
    wire [47:0] in_b_x1;
    assign in_r_x1 = dout_R[0][47:0];
    assign in_b_x1 = dout_B[0][47:0];

    divider div_gen_G_R_r1 (
        .clk(I_clk),
        .rst(!I_rst_n),
        .start(I_tvalid_r1),
        .denominator(sum_r[0]),
        .numerator({sum_g[0], 16'd0}),
        .quotient(dout_R[0]),
        .done(done[0])
    );

    divider divide_G_B_r1 (
        .clk(I_clk),
        .rst(!I_rst_n),
        .start(I_tvalid_r1),
        .denominator(sum_b[0]),
        .numerator({sum_g[0], 16'd0}),
        .quotient(dout_B[0]),
        .done()
    );

    signal_delay #(
        .IMG_HEIGHT (IMG_HEIGHT),
        .IMG_WIDTH  (IMG_WIDTH),
        .DATA_WIDTH (96),
        .DELAY_CYCLE(50)
    ) signal_delay_d (
        .I_clk  (I_clk),
        .I_rst_n(I_rst_n),
        .I_tuser(I_tuser),      //synthesis keep 
        .I_valid(I_tvalid_r1),  //synthesis keep 
        .I_data (I_tdata_d1),   //synthesis keep 
        .O_valid(valid_d0),     //synthesis keep 
        .O_data (data_d0),      //synthesis keep 
        .O_tuser(I_tuser_r0)
    );

    reg [19:0] in_r_r1;
    reg [19:0] in_b_r1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            in_r_r1 <= 20'h10000;
            in_b_r1 <= 20'h10000;
        end else if (done[0]) begin
            if (|in_r_x1[47:20]) in_r_r1 <= 20'hfffff;
            else in_r_r1 <= in_r_x1[19:0];
            if (|in_b_x1[47:20]) in_b_r1 <= 20'hfffff;
            else in_b_r1 <= in_b_x1[19:0];
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d1 <= 0;
            data_d1 <= 0;
            I_tuser_r1 <= 0;
        end else begin
            valid_d1 <= valid_d0;
            data_d1 <= data_d0;
            I_tuser_r1 <= I_tuser_r0;
        end
    end

    reg  [27:0] R_new_r1;
    reg  [27:0] G_new_r1;
    reg  [27:0] B_new_r1;

    reg  [27:0] R_new_r2;
    reg  [27:0] G_new_r2;
    reg  [27:0] B_new_r2;

    reg  [27:0] R_new_r3;
    reg  [27:0] G_new_r3;
    reg  [27:0] B_new_r3;

    reg  [27:0] R_new_r4;
    reg  [27:0] G_new_r4;
    reg  [27:0] B_new_r4;

    wire [ 7:0] rgb888_r_d1[0:3];
    wire [ 7:0] rgb888_g_d1[0:3];
    wire [ 7:0] rgb888_b_d1[0:3];

    assign rgb888_r_d1[0] = data_d1[16+:8];
    assign rgb888_g_d1[0] = data_d1[8+:8];
    assign rgb888_b_d1[0] = data_d1[0+:8];

    assign rgb888_r_d1[1] = data_d1[40+:8];
    assign rgb888_g_d1[1] = data_d1[32+:8];
    assign rgb888_b_d1[1] = data_d1[24+:8];

    assign rgb888_r_d1[2] = data_d1[64+:8];
    assign rgb888_g_d1[2] = data_d1[56+:8];
    assign rgb888_b_d1[2] = data_d1[48+:8];

    assign rgb888_r_d1[3] = data_d1[88+:8];
    assign rgb888_g_d1[3] = data_d1[80+:8];
    assign rgb888_b_d1[3] = data_d1[72+:8];
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            R_new_r1 <= 0;
            G_new_r1 <= 0;
            B_new_r1 <= 0;

            R_new_r2 <= 0;
            G_new_r2 <= 0;
            B_new_r2 <= 0;

            R_new_r3 <= 0;
            G_new_r3 <= 0;
            B_new_r3 <= 0;

            R_new_r4 <= 0;
            G_new_r4 <= 0;
            B_new_r4 <= 0;
        end else if (valid_d1) begin
            R_new_r1 <= in_r_r1 * rgb888_r_d1[0];
            G_new_r1 <= rgb888_g_d1[0];
            B_new_r1 <= in_b_r1 * rgb888_b_d1[0];

            R_new_r2 <= in_r_r1 * rgb888_r_d1[1];
            G_new_r2 <= rgb888_g_d1[1];
            B_new_r2 <= in_b_r1 * rgb888_b_d1[1];

            R_new_r3 <= in_r_r1 * rgb888_r_d1[2];
            G_new_r3 <= rgb888_g_d1[2];
            B_new_r3 <= in_b_r1 * rgb888_b_d1[2];

            R_new_r4 <= in_r_r1 * rgb888_r_d1[3];
            G_new_r4 <= rgb888_g_d1[3];
            B_new_r4 <= in_b_r1 * rgb888_b_d1[3];
        end
    end

    wire [7:0] R_new_x1;
    wire [7:0] G_new_x1;
    wire [7:0] B_new_x1;

    wire [7:0] R_new_x2;
    wire [7:0] G_new_x2;
    wire [7:0] B_new_x2;

    wire [7:0] R_new_x3;
    wire [7:0] G_new_x3;
    wire [7:0] B_new_x3;

    wire [7:0] R_new_x4;
    wire [7:0] G_new_x4;
    wire [7:0] B_new_x4;

    assign R_new_x1 = (R_new_r1[27:24]) ? 255 : R_new_r1[23:16];
    assign G_new_x1 = G_new_r1;
    assign B_new_x1 = (B_new_r1[27:24]) ? 255 : B_new_r1[23:16];

    assign R_new_x2 = (R_new_r2[27:24]) ? 255 : R_new_r2[23:16];
    assign G_new_x2 = G_new_r2;
    assign B_new_x2 = (B_new_r2[27:24]) ? 255 : B_new_r2[23:16];

    assign R_new_x3 = (R_new_r3[27:24]) ? 255 : R_new_r3[23:16];
    assign G_new_x3 = G_new_r3;
    assign B_new_x3 = (B_new_r3[27:24]) ? 255 : B_new_r3[23:16];

    assign R_new_x4 = (R_new_r4[27:24]) ? 255 : R_new_r4[23:16];
    assign G_new_x4 = G_new_r4;
    assign B_new_x4 = (B_new_r4[27:24]) ? 255 : B_new_r4[23:16];

    reg valid_d2, I_tuser_r2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d2   <= 0;
            I_tuser_r2 <= 0;
        end else begin
            valid_d2   <= valid_d1;
            I_tuser_r2 <= I_tuser_r1;
        end
    end

    assign O_tlast = (valid_d1 == 0) && (valid_d2 == 1);
    assign O_tuser = I_tuser;
    assign O_tvalid = valid_d2;

    assign  O_tdata = O_tvalid?{R_new_x4,G_new_x4,B_new_x4,
                       R_new_x3,G_new_x3,B_new_x3,
                       R_new_x2,G_new_x2,B_new_x2,
                       R_new_x1,G_new_x1,B_new_x1}:0;

    assign I_tready = O_tready;

endmodule
