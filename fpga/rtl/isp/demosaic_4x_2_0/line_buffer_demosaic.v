`timescale 1ns / 1ps

module line_buffer_demosaic #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
) (
    input              I_clk,
    input              I_rst_n,
    input              I_tuser,
    input  wire        I_valid,
    input  wire [32:0] I_data,
    output wire        O_valid,
    output wire [32:0] O_data
);

    wire        rd_en;  // synthesis keep 

    reg  [10:0] addra;
    reg  [10:0] addrb;
    reg  [32:0] data_d0;
    reg         valid_d0;

    localparam IMG_WIDTH_4x = (IMG_WIDTH >> 2);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            data_d0  <= 0;
            valid_d0 <= 0;
        end else begin
            data_d0  <= I_data;
            valid_d0 <= I_valid;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            addra <= 0;
        end else if (valid_d0) begin

            addra <= (addra == IMG_WIDTH_4x - 1) ? 0 : addra + 1'b1;

        end
    end

    reg tlast_lock_d0;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            tlast_lock_d0 <= 1'b0;
        end else if ((tlast_lock_d0 == 1'b0) & (addra == IMG_WIDTH_4x - 1)) begin
            tlast_lock_d0 <= 1'b1;
        end
    end

    assign rd_en = (I_valid && tlast_lock_d0) ? 1'b1 : 1'b0;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            addrb <= 0;
        end else begin

            addrb <= rd_en ? ((addrb == IMG_WIDTH_4x - 1) ? 0 : addrb + 1'b1) : addrb;

        end
    end

    assign O_valid = (valid_d0 && tlast_lock_d0) ? 1'b1 : 1'b0;

    blk_mem_gen_demosaic blk_mem_gen_demosaic_r0 (
        .clka (I_clk),
        .wea  (valid_d0),
        .addra(addra),
        .dia  (data_d0),
        .clkb (I_clk),
        .addrb(addrb),
        .dob  (O_data)
    );

endmodule
