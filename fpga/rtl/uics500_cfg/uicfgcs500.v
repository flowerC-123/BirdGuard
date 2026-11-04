/*
 * Copyright (c) MiLianKe. All rights reserved.
 * The reference demo provided by Milianke is only used for learning.
 * We cannot ensure that the demo itself is free of bugs, so users
 * should be responsible for the technical problems and consequences
 * caused by the use of their own products.
 */

`timescale 1ns / 1ns

module uicfgcs500 #(
    parameter CLK_DIV = 16'd999
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_ae_req,
    input  wire [15:0] I_ae,
    input  wire [15:0] I_ag,
    output wire        O_cam_scl,
    inout  wire        IO_cam_sda,
    output reg         O_cfg_done,
    output reg         O_ae_cfg_done
);

    localparam CAM_ID = 8'h6C;

    reg [7:0] rst_cnt = 0;
    always @(posedge I_clk or negedge I_rst_n)
        if (I_rst_n == 1'b0) rst_cnt <= 8'd0;
        else if (rst_cnt[7] == 1'b0) rst_cnt <= rst_cnt + 1'b1;
        else rst_cnt <= rst_cnt;

    reg iic_req;
    wire ic_busy;
    reg [31:0] wr_data;
    reg [1 : 0] TS_S = 2'd0;
    reg [8 : 0] reg_index;
    wire [23:0] REG_DATA;
    wire [23:0] REG_DATA_REG;
    wire [23:0] REG_DATA_AE;
    wire [8 : 0] REG_SIZE;
    wire [8 : 0] REG_SIZE_REG;
    wire [8 : 0] REG_SIZE_AE;

    always @(posedge I_clk) begin
        if (rst_cnt[7] == 1'b0) begin
            reg_index     <= 9'd0;
            iic_req       <= 1'b0;
            wr_data       <= 32'd0;
            O_cfg_done    <= 1'b0;
            O_ae_cfg_done <= 1'b0;
            TS_S          <= 2'd0;
        end else begin
            case (TS_S)
                0:
                if (reg_index == REG_SIZE && O_cfg_done == 1'b0) begin
                    O_cfg_done <= 1'b1;
                end else if (reg_index == REG_SIZE && O_ae_cfg_done == 1'b0) begin
                    O_ae_cfg_done <= 1'b1;
                end else if (I_ae_req) begin
                    O_ae_cfg_done <= 0;
                    reg_index <= 0;
                end else if ((O_cfg_done & O_ae_cfg_done) == 1'b0) TS_S <= 2'd1;
                1:
                if (!iic_busy) begin
                    iic_req         <= 1'b1;
                    wr_data[7 : 0]  <= CAM_ID;
                    wr_data[15 : 8] <= REG_DATA[23:16];
                    wr_data[23:16]  <= REG_DATA[15:8];
                    wr_data[31:24]  <= REG_DATA[7 : 0];
                    TS_S            <= 2'd2;
                end
                2:
                if (iic_busy) begin
                    iic_req <= 1'b0;
                    TS_S    <= 2'd3;
                end
                3:
                if (!iic_busy) begin
                    reg_index<= reg_index + 1'b1;
                    TS_S    <= 2'd0;
                end
            endcase
        end
    end

    assign REG_DATA = (O_cfg_done == 0) ? REG_DATA_REG : REG_DATA_AE;
    assign REG_SIZE = (O_cfg_done == 0) ? REG_SIZE_REG : REG_SIZE_AE;

    uii2c #(
        .WMEN_LEN(4),
        .RMEN_LEN(1),
        .CLK_DIV (CLK_DIV)
    ) uii2c_inst (
        .I_clk(I_clk),
        .I_rstn(rst_cnt[7]),
        .O_iic_scl(O_cam_scl),
        .IO_iic_sda(IO_cam_sda),
        .I_wr_data(wr_data),
        .I_wr_cnt(8'd4),
        .O_rd_data(),
        .I_rd_cnt(8'd0),
        .I_iic_mode(1'b0),
        .I_iic_req(iic_req),
        .O_iic_busy(iic_busy)
    );

    uics500reg uics500reg_inst (
        .REG_SIZE (REG_SIZE_REG),
        .REG_INDEX(reg_index),
        .REG_DATA (REG_DATA_REG)
    );

    wire [15:0] w_gain_val;
    SC500GainTbl gain_tbl (
        .I_clk(I_clk),
        .I_rstn(rst_cnt[7] == 1'b0),
        .I(I_ag - 16),
        .O(w_gain_val)
    );

    uics500regAE uics500regAE_inst (
        .REG_SIZE(REG_SIZE_AE),
        .REG_INDEX(reg_index),
        .REG_DATA(REG_DATA_AE),
        .I_AG(w_gain_val),
        .I_AE(I_ae)
    );

endmodule
