module osd_logo_rom (
    input  wire [4:0] row,
    input  wire [5:0] col,
    output wire       bit_out
);

    reg [63:0] line;
    always @* begin
        case (row)
            5'd0: line = 64'h0000000000000000;
            5'd1: line = 64'h0000000000000000;
            5'd2: line = 64'h0001000000000000;
            5'd3: line = 64'h0007000000003800;
            5'd4: line = 64'h0003800000003000;
            5'd5: line = 64'h0001c0000ff86000;
            5'd6: line = 64'h000180000e187ff0;
            5'd7: line = 64'h07ffffe00e18e060;
            5'd8: line = 64'h07ffffe00e18c0e0;
            5'd9: line = 64'h060000600e19e0c0;
            5'd10: line = 64'h060600600e1bb180;
            5'd11: line = 64'h060700600ff93b80;
            5'd12: line = 64'h000e00000ff81f00;
            5'd13: line = 64'h000c000000c00e00;
            5'd14: line = 64'h001c000000c01f80;
            5'd15: line = 64'h1ffffff800c039c0;
            5'd16: line = 64'h1ffffff80cc1f0f8;
            5'd17: line = 64'h003806000cfbc03c;
            5'd18: line = 64'h00700e000cfb0008;
            5'd19: line = 64'h00600c000cc0ffe0;
            5'd20: line = 64'h00f01c000cc0c060;
            5'd21: line = 64'h01fe38000cc0c060;
            5'd22: line = 64'h001ff0000cc0c060;
            5'd23: line = 64'h0001f8000cc6c060;
            5'd24: line = 64'h0001fe000cfec060;
            5'd25: line = 64'h00078f800ff8ffe0;
            5'd26: line = 64'h003f03e03fc0ffe0;
            5'd27: line = 64'h0ff800f81e00c060;
            5'd28: line = 64'h07e000701000c060;
            5'd29: line = 64'h060000000000c000;
            5'd30: line = 64'h0000000000000000;
            5'd31: line = 64'h0000000000000000;
            default: line = 64'd0;
        endcase
    end

    assign bit_out = line[63-col];

endmodule
