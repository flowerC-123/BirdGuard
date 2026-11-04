`timescale 1 ns / 100 fs

module ph1p_ddrphy_pll1 #(
    parameter  REFCLK_FREQ = "100",
    parameter  REFCLK_DIV  = 1,
    parameter  CLK0_DIV    = 12
)(
    input   refclk  ,
    input   reset   ,
    output  clk0_out,
    output  lock
);

localparam  FAST_LOOP = "ENABLE";

localparam  LPF_RES  =  0;  

localparam  LPF_CAP = ((CLK0_DIV*REFCLK_DIV >=   1) && (CLK0_DIV*REFCLK_DIV <    2)) ?  3 :
                      ((CLK0_DIV*REFCLK_DIV >=   2) && (CLK0_DIV*REFCLK_DIV <    4)) ?  3 :
                      ((CLK0_DIV*REFCLK_DIV >=   4) && (CLK0_DIV*REFCLK_DIV <    8)) ?  3 :
                      ((CLK0_DIV*REFCLK_DIV >=   8) && (CLK0_DIV*REFCLK_DIV <   15)) ?  3 :
                      ((CLK0_DIV*REFCLK_DIV >=  15) && (CLK0_DIV*REFCLK_DIV <   20)) ?  5 :
                      ((CLK0_DIV*REFCLK_DIV >=  20) && (CLK0_DIV*REFCLK_DIV <   30)) ?  5 :
                      ((CLK0_DIV*REFCLK_DIV >=  30) && (CLK0_DIV*REFCLK_DIV <   40)) ? 13 :
                      ((CLK0_DIV*REFCLK_DIV >=  40) && (CLK0_DIV*REFCLK_DIV <   60)) ? 25 :
                      ((CLK0_DIV*REFCLK_DIV >=  60) && (CLK0_DIV*REFCLK_DIV <   80)) ? 31 :
                      ((CLK0_DIV*REFCLK_DIV >=  80) && (CLK0_DIV*REFCLK_DIV <  128)) ? 31 :
                      ((CLK0_DIV*REFCLK_DIV >= 128) && (CLK0_DIV*REFCLK_DIV <= 160)) ? 31 : 3;

localparam  ICP_CUR = ((CLK0_DIV*REFCLK_DIV >=   1) && (CLK0_DIV*REFCLK_DIV <    2)) ?  1 :
                      ((CLK0_DIV*REFCLK_DIV >=   2) && (CLK0_DIV*REFCLK_DIV <    4)) ?  3 :
                      ((CLK0_DIV*REFCLK_DIV >=   4) && (CLK0_DIV*REFCLK_DIV <    8)) ?  7 :
                      ((CLK0_DIV*REFCLK_DIV >=   8) && (CLK0_DIV*REFCLK_DIV <   15)) ? 15 :
                      ((CLK0_DIV*REFCLK_DIV >=  15) && (CLK0_DIV*REFCLK_DIV <   20)) ? 20 :
                      ((CLK0_DIV*REFCLK_DIV >=  20) && (CLK0_DIV*REFCLK_DIV <   30)) ? 29 :
                      ((CLK0_DIV*REFCLK_DIV >=  30) && (CLK0_DIV*REFCLK_DIV <   40)) ? 29 :
                      ((CLK0_DIV*REFCLK_DIV >=  40) && (CLK0_DIV*REFCLK_DIV <   60)) ? 29 :
                      ((CLK0_DIV*REFCLK_DIV >=  60) && (CLK0_DIV*REFCLK_DIV <   80)) ? 31 :
                      ((CLK0_DIV*REFCLK_DIV >=  80) && (CLK0_DIV*REFCLK_DIV <  128)) ? 31 :
                      ((CLK0_DIV*REFCLK_DIV >= 128) && (CLK0_DIV*REFCLK_DIV <= 160)) ? 31 : 15;

wire  [6:0] clkc   ;
wire  [6:0] clkc_en;
wire        fbclk  ;

assign clkc_en  = 7'b000_0001;
assign clk0_out = fbclk;

`ifndef PH1P_DDRPHY_SIM
    `ifdef PH1P_FPSOC
    DR1P_LOGIC_BUFG u_bufg_fbclk (.i(clkc[0]), .o(fbclk));
    `else
    PH1P_LOGIC_BUFG u_bufg_fbclk (.i(clkc[0]), .o(fbclk));
    `endif
`else
assign fbclk = clkc[0];
`endif

`ifdef PH1P100
PH1P_PHY_PLL    #(
`elsif PH1P35
PH1P_PHY_PLL_V2 #(
`elsif PH1P50
PH1P_PHY_PLL_V2 #(
`elsif PH1P_FPSOC
DR1P_PHY_PLL #(
`endif
 
    .FIN                          ( REFCLK_FREQ  ), 

    .PLL_FEED_TYPE                ( "EXTERNAL"   ),  
    .FEEDBK_MODE                  ( "NORMAL"     ),  
    .FBKCLK                       ( "CLKC0_EXT"  ), 
    .FBKCLK_INT                   ( "CLKC0_EXT"  ),

    .REFCLK_DIV                   ( REFCLK_DIV   ),  
    .FBCLK_DIV                    ( REFCLK_DIV   ),  

    .CLKC0_ENABLE                 ( "ENABLE"     ),  
    .CLKC1_ENABLE                 ( "DISABLE"    ),  
    .CLKC2_ENABLE                 ( "DISABLE"    ),  
    .CLKC3_ENABLE                 ( "DISABLE"    ),  
    .CLKC4_ENABLE                 ( "DISABLE"    ),  
    .CLKC5_ENABLE                 ( "DISABLE"    ),  
    .CLKC6_ENABLE                 ( "DISABLE"    ),  

    .CLKC0_DIV                    ( CLK0_DIV     ),  
    .CLKC1_DIV                    ( 1            ),  
    .CLKC2_DIV                    ( 1            ),  
    .CLKC3_DIV                    ( 1            ),  
    .CLKC4_DIV                    ( 1            ),  
    .CLKC5_DIV                    ( 1            ),  
    .CLKC6_DIV                    ( 1            ),  

    .CLKC0_DUTY_INT               ((CLK0_DIV+1)/2),  
    .CLKC1_DUTY_INT               ( 1            ),  
    .CLKC2_DUTY_INT               ( 1            ),  
    .CLKC3_DUTY_INT               ( 1            ),  
    .CLKC4_DUTY_INT               ( 1            ),  
    .CLKC5_DUTY_INT               ( 1            ),  
    .CLKC6_DUTY_INT               ( 1            ),  

    .LPF_RES                      ( LPF_RES      ),  
    .LPF_CAP                      ( LPF_CAP      ),  
    .ICP_CUR                      ( ICP_CUR      ),  

    .CLKC0_FPHASE                 ( 0            ),  
    .CLKC1_FPHASE                 ( 0            ),  
    .CLKC2_FPHASE                 ( 0            ),  
    .CLKC3_FPHASE                 ( 0            ),  
    .CLKC4_FPHASE                 ( 0            ),  
    .CLKC5_FPHASE                 ( 0            ),  
    .CLKC6_FPHASE                 ( 0            ),  

    .CLKC0_FPHASE_RSTSEL          ( 0            ),  
    .CLKC1_FPHASE_RSTSEL          ( 0            ),  
    .CLKC2_FPHASE_RSTSEL          ( 0            ),  
    .CLKC3_FPHASE_RSTSEL          ( 0            ),  
    .CLKC4_FPHASE_RSTSEL          ( 0            ),  
    .CLKC5_FPHASE_RSTSEL          ( 0            ),  
    .CLKC6_FPHASE_RSTSEL          ( 0            ),  

    .CLKC0_CPHASE                 ( CLK0_DIV-1   ),  
    .CLKC1_CPHASE                 ( 0            ),  
    .CLKC2_CPHASE                 ( 0            ),  
    .CLKC3_CPHASE                 ( 0            ),  
    .CLKC4_CPHASE                 ( 0            ),  
    .CLKC5_CPHASE                 ( 0            ),  
    .CLKC6_CPHASE                 ( 0            ),  

    .PREDIV_MUXC0                 ( "VCO"        ),  
    .PREDIV_MUXC1                 ( "VCO"        ),  
    .PREDIV_MUXC2                 ( "VCO"        ),  
    .PREDIV_MUXC3                 ( "VCO"        ),  
    .PREDIV_MUXC4                 ( "VCO"        ),  
    .PREDIV_MUXC5                 ( "VCO"        ),  
    .PREDIV_MUXC6                 ( "VCO"        ),  

    .DIVOUT_MUXC0                 ( "DIV"        ),  
    .DIVOUT_MUXC1                 ( "DIV"        ),  
    .DIVOUT_MUXC2                 ( "DIV"        ),  
    .DIVOUT_MUXC3                 ( "DIV"        ),  
    .DIVOUT_MUXC4                 ( "DIV"        ),  
    .DIVOUT_MUXC5                 ( "DIV"        ),  
    .DIVOUT_MUXC6                 ( "DIV"        ),  

    .REFCLK_DET_BYP               ( "DISABLE"    ),  

    .FRAC_ENABLE                  ( "DISABLE"    ),  
    .SDM_FRAC                     ( 0            ),  

    .PHASE_PATH_SEL               ( 0            ),  
    .DYN_PHASE_PATH_SEL           ( "DISABLE"    ),  
    .DYN_FPHASE_EN                ( "DISABLE"    ),  
    .DYN_CPHASE_EN                ( "DISABLE"    ),  

    .PLL_FASTLOOP                 ( FAST_LOOP    ),
    .CLKC0_FRAC_EN                ( "DISABLE"    ),  
    .CLKC0_FRAC                   ( 0            ),  
    .PI_OUT_SEL                   ( "NORMAL"     ),  
    .PI_FRAC_EN                   ( "DISABLE"    ),  
    .CLKC0_PI_SHIFT_EN            ( "DISABLE"    )   
) u_pll_inst (
 
    .refclk      ( refclk      ),  
    .refclk_rst  ( 1'b0        ),  

    .pllreset    ( reset       ),  
    .pllpd       ( 1'b0        ),  
    .wakeup      ( 1'b1        ),  

    .fbclk       ( fbclk       ),  
    .clkc_rst    ( 2'b00       ),  
    .clkc_en     ( clkc_en     ),  
    .clkc        ( clkc        ),  

    .lock        ( lock        ),  

    .drp_clk     ( 1'b0        ),  
    .drp_rstn    ( 1'b1        ),  
    .drp_sel     ( 1'b0        ),  
    .drp_rd      ( 1'b0        ),  
    .drp_wr      ( 1'b0        ),  
    .drp_addr    ( 8'h00       ),  
    .drp_wdata   ( 8'h00       ),  
    .drp_err     (             ),  
    .drp_rdy     (             ),  
    .drp_rdata   (             ),  

    .psdone      (             ),  
    .psclk       ( 1'b0        ),  
    .psdown      ( 1'b0        ),  
    .psstep      ( 1'b0        ),  
    .psclksel    ( 3'b000      ),  
    .cps_step    ( 1'b0        ),  

    .ssc_reset   ( 1'b1        ),  

    .scan_clk    ( 1'b0        ),  
    .scan_enable ( 1'b1        ),  
    .scan_mode   ( 1'b0        ),  
    .scan_resetn ( 1'b0        )   
);

endmodule
