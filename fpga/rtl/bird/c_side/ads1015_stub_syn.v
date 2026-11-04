// Reference ADC code source for the REF display.
module ads1015_ip #(
    parameter DEV_ADDR = 7'h48,
    parameter CLK_FREQ = 50000000
) (
    input wire clk,
    input wire rst_n,

    inout wire sda,
    inout wire scl,

    input wire [11:0] ain0,
    input wire [11:0] ain1,
    input wire [11:0] ain2,
    input wire [11:0] ain3,

    output wire alert,

    output wire [11:0] dac_out,
    output wire        comp_out,
    output wire        sample_hold,
    output wire [11:0] adc_code
);

    assign sda         = 1'bz;
    assign scl         = 1'bz;

    assign alert       = 1'b0;
    assign dac_out     = 12'd0;
    assign comp_out    = 1'b0;
    assign sample_hold = 1'b0;

    assign adc_code    = 12'd2048;

    wire _unused = &{1'b0, ain0, ain1, ain2, ain3, clk, rst_n, 1'b0};
endmodule
