localparam nCCD = 4;
localparam nRTP = 5;
localparam nWTR = 5;

localparam real tWTR = 7_500;

`ifdef DDR2_256M
localparam real tRRD = 7_500;
localparam real tFAW = 35_000;
`else
`ifdef DDR2_X16
localparam real tRRD = 10_000;
localparam real tFAW = 45_000;
`else
localparam real tRRD = 7_500;
localparam real tFAW = 35_000;
`endif
`endif
