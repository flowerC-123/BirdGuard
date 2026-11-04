/*
 * Copyright (c) MiLianKe. All rights reserved.
 * The reference demo provided by Milianke is only used for learning.
 * We cannot ensure that the demo itself is free of bugs, so users
 * should be responsible for the technical problems and consequences
 * caused by the use of their own products.
 */

`timescale 1ns / 1ns

module csi_unpacket (
    input wire I_clk,
    input wire I_rst_n,

    input wire          I_hs_valid,//synthesis keep //来自MIPI核的数据有效信号,其中也包含的数据类型
    input wire[15: 0]   I_hs_data, //synthesis keep //来自MIPI核的数据,其中也包含的数据类型数据，这里定义2LANE，1BYTE模式

    output reg O_csi_frame_start,
    output reg O_csi_frame_end,
    output reg O_csi_valid,  //synthesis keep      //有效数据输出
    output reg O_csi_hs,
    output reg  [31: 0]  O_csi_data   //synthesis keep      //有效数据，这里定义2LANE，1BYTE模式
);

    localparam FRAME_DATA_DT  = 8'h2B;

    localparam FRAME_START_DT = 8'h00;
    localparam FRAME_END_DT   = 8'h01;

    reg         S_hs_valid_1d;  //synthesis keep   
    reg  [15:0] S_hs_data_1d;  //synthesis keep   
    wire        S_head_en;  //synthesis keep   
    reg         S_head_en_1d;  //synthesis keep      
    reg  [15:0] S_data_length;  //synthesis keep      
    reg         S_data_en;  //synthesis keep        
    reg  [15:0] S_data_en_cnt;  //synthesis keep      

    assign S_head_en = ~S_hs_valid_1d & I_hs_valid;

    always @(posedge I_clk) begin
        S_hs_valid_1d <= I_hs_valid;
        S_hs_data_1d  <= I_hs_data;
        S_head_en_1d  <= S_head_en;
    end

    always @(posedge I_clk)
        O_csi_frame_start <= (S_head_en_1d && S_hs_data_1d[15:8] == FRAME_START_DT);

    always @(posedge I_clk) O_csi_frame_end <= (S_head_en_1d && S_hs_data_1d[15:8] == FRAME_END_DT);

    always @(posedge I_clk) begin
        if (I_hs_valid) begin
            if (S_head_en_1d && S_hs_data_1d[15:8] == FRAME_DATA_DT)
                S_data_length <= {I_hs_data[15:8], S_hs_data_1d[7:0]} >> 1;
            else S_data_length <= S_data_length;
        end else S_data_length <= 'd0;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) S_data_en <= 1'b0;
        else if (S_head_en_1d && S_hs_data_1d[15:8] == FRAME_DATA_DT) S_data_en <= 1'b1;
        else if (S_data_en_cnt == S_data_length - 1) S_data_en <= 1'b0;
        else S_data_en <= S_data_en;
    end

    always @(posedge I_clk) begin
        if (S_data_en) S_data_en_cnt <= S_data_en_cnt + 'd1;
        else S_data_en_cnt <= 'd0;
    end

    reg csi_valid_r;  //synthesis keep

    always @(posedge I_clk) begin
        csi_valid_r <= S_data_en ? ~csi_valid_r : 0;
        O_csi_valid <= csi_valid_r;
        O_csi_hs    <= I_hs_valid;
    end

    always @(posedge I_clk) begin
        O_csi_data <= S_data_en ? {O_csi_data[15:0], I_hs_data} : 0;
    end

    cwc3 cwc3_inst (
        .probe0(I_hs_valid),
        .probe1(I_hs_data),
        .probe2(S_hs_valid_1d),
        .probe3(S_hs_data_1d),
        .probe4(S_head_en),
        .probe5(S_head_en_1d),
        .probe6(S_data_length),
        .probe7(S_data_en),
        .probe8(S_data_en_cnt),
        .probe9(csi_valid_r),
        .probe10(O_csi_frame_start),
        .probe11(O_csi_frame_end),
        .probe12(O_csi_valid),
        .probe13(O_csi_hs),
        .probe14(O_csi_data),
        .clk(I_clk)
    );

endmodule
