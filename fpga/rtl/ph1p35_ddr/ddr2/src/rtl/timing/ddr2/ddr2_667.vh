localparam nCCD = 2;
localparam nRTP = 3;
localparam nWTR = 3;

localparam real tWTR = 7_500;

`ifdef DDR2_256M
localparam real tRRD = 7_500;
localparam real tFAW = 37_500;
`else
`ifdef DDR2_X16
localparam real tRRD = 10_000;
localparam real tFAW = 50_000;
`else
localparam real tRRD = 7_500;
localparam real tFAW = 37_500;
`endif
`endif
