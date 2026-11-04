module adc_to_voltage_mv #(
    parameter integer FULL_SCALE_MV = 4096
) (
    input  wire [11:0] adc_code,
    output wire [15:0] voltage_mv
);
    assign voltage_mv = (adc_code * FULL_SCALE_MV) / 4095;
endmodule
