module seg_display_8digit #(
    parameter integer CLK_FREQ_HZ        = 50000000,
    parameter integer SCAN_HZ            = 1000,
    parameter integer MEASUREMENT_VALID  = 1,
    parameter integer REFERENCE_VALUE    = 0,
    parameter integer SHOW_DECIMAL_POINT = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] voltage_mv,
    output reg  [ 7:0] DIG,
    output reg  [ 7:0] SEL
);
    localparam integer DIV_MAX = CLK_FREQ_HZ / (SCAN_HZ * 8);
    reg [31:0] div_cnt;
    reg [ 2:0] scan_idx;
    reg [ 3:0] digit;
    reg [ 7:0] seg_active_high;
    reg [3:0] d0, d1, d2, d3, d4;

    always @(*) begin
        d0 = voltage_mv % 10;
        d1 = (voltage_mv / 10) % 10;
        d2 = (voltage_mv / 100) % 10;
        d3 = (voltage_mv / 1000) % 10;
        d4 = (voltage_mv / 10000) % 10;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= 0;
            scan_idx <= 0;
        end else if (div_cnt >= DIV_MAX - 1) begin
            div_cnt  <= 0;
            scan_idx <= scan_idx + 1'b1;
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
    end

    always @(*) begin
        case (scan_idx)
            3'd0: begin
                digit = d0;
                SEL   = 8'b11111110;
            end
            3'd1: begin
                digit = d1;
                SEL   = 8'b11111101;
            end
            3'd2: begin
                digit = d2;
                SEL   = 8'b11111011;
            end
            3'd3: begin
                digit = d3;
                SEL   = 8'b11110111;
            end
            3'd4: begin
                digit = d4;
                SEL   = 8'b11101111;
            end
            3'd5: begin
                digit = (REFERENCE_VALUE && MEASUREMENT_VALID) ? 4'hc : 4'd0;
                SEL   = (REFERENCE_VALUE && MEASUREMENT_VALID) ? 8'b11011111 : 8'hff;
            end
            3'd6: begin
                digit = (REFERENCE_VALUE && MEASUREMENT_VALID) ? 4'hb : 4'd0;
                SEL   = (REFERENCE_VALUE && MEASUREMENT_VALID) ? 8'b10111111 : 8'hff;
            end
            default: begin
                digit = (REFERENCE_VALUE && MEASUREMENT_VALID) ? 4'ha : 4'd0;
                SEL   = (REFERENCE_VALUE && MEASUREMENT_VALID) ? 8'b01111111 : 8'hff;
            end
        endcase

        if (!MEASUREMENT_VALID) digit = 4'hf;
        case (digit)
            4'd0: seg_active_high = 8'h3f;
            4'd1: seg_active_high = 8'h06;
            4'd2: seg_active_high = 8'h5b;
            4'd3: seg_active_high = 8'h4f;
            4'd4: seg_active_high = 8'h66;
            4'd5: seg_active_high = 8'h6d;
            4'd6: seg_active_high = 8'h7d;
            4'd7: seg_active_high = 8'h07;
            4'd8: seg_active_high = 8'h7f;
            4'd9: seg_active_high = 8'h6f;

            4'ha: seg_active_high = 8'h50;
            4'hb: seg_active_high = 8'h79;
            4'hc: seg_active_high = 8'h71;
            4'hf: seg_active_high = 8'h40;
            default: seg_active_high = 8'h00;
        endcase

        if (SHOW_DECIMAL_POINT && MEASUREMENT_VALID && scan_idx == 3'd3) seg_active_high[7] = 1'b1;
        DIG = ~seg_active_high;
    end
endmodule
