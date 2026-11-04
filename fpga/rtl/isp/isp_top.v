module isp_top (
    input    axi4s_video_aclk,
    input    I_rst_n   ,
    input    I_tlast   ,
    input    I_tuser   ,
    input [39:0]  I_tdata   ,
    input    I_tvalid  ,
    input [9:0]  I_tdest   ,
    input    O_tready  ,
    output [127:0]  O_tdata   ,
    output    O_tlast   ,
    output    O_tuser   ,
    output    O_tvalid  ,
    output    I_tready
);

    wire         m_aixs_tvalid;  //synthesis keep 
    wire [127:0] m_aixs_tdata;  //synthesis keep 
    wire         m_aixs_tuser;  //synthesis keep 
    wire         m_aixs_tlast;  //synthesis keep 
    wire         m_aixs_tready;  //synthesis keep 

    wire [ 95:0] m_aixs_tdata_96;  //synthesis keep 

    wire         awb_O_tlast;  //synthesis keep 
    wire         awb_O_tuser;  //synthesis keep 
    wire [ 95:0] awb_O_tdata;  //synthesis keep 
    wire         awb_O_tvalid;  //synthesis keep 
    wire         awb_O_tready;  //synthesis keep 

    wire         awb_O_tuser_128;  //synthesis keep 
    wire         awb_O_tvalid_128;  //synthesis keep 
    wire [127:0] awb_O_tdata_128;  //synthesis keep 

    assign awb_O_tready = O_tready;
    assign O_tdata      = awb_O_tdata_128;
    assign O_tlast      = awb_O_tlast;
    assign O_tuser      = awb_O_tuser_128;
    assign O_tvalid     = awb_O_tvalid_128;

    demosaic #(
        .IMG_HEIGHT         (720),
        .IMG_WIDTH          (1280),
        .data_complete_delay(50),
        .BAYER_MODE         ("BGGR")
    ) u_demosaic (
        .I_clk             (axi4s_video_aclk),
        .I_rst_n           (I_rst_n),
        .axi4s_video_tdata (I_tdata),
        .axi4s_video_tdest (I_tdest),
        .axi4s_video_tlast (I_tlast),
        .axi4s_video_tvalid(I_tvalid),
        .axi4s_video_tuser (I_tuser),
        .axi4s_video_tready(I_tready),
        .O_tlast           (m_aixs_tlast),
        .O_tuser           (m_aixs_tuser),
        .O_tdata           (m_aixs_tdata),
        .O_tvalid          (m_aixs_tvalid),
        .O_tready          (m_aixs_tready)
    );

    data128_96 u_data128_96 (
        .I_tdata(m_aixs_tdata),
        .O_tdata(m_aixs_tdata_96)
    );

    isp_awb_auto #(
        .IMG_HEIGHT(720),
        .IMG_WIDTH (1280),
        .R_GAIN    (333),
        .G_GAIN    (256),
        .B_GAIN    (358),
        .AUTO_EN   (1)
    ) u_awb (
        .I_clk   (axi4s_video_aclk),
        .I_rst_n (I_rst_n),
        .I_tlast (m_aixs_tlast),
        .I_tuser (m_aixs_tuser),
        .I_tdata (m_aixs_tdata_96),
        .I_tvalid(m_aixs_tvalid),
        .I_tready(m_aixs_tready),
        .O_tlast (awb_O_tlast ),
        .O_tuser (awb_O_tuser ),
        .O_tdata (awb_O_tdata ),
        .O_tvalid(awb_O_tvalid),
        .O_tready(awb_O_tready)
    );

    data_96bit_to_128bit u_data_96bit_to_128bit (
        .I_clk  (axi4s_video_aclk),
        .I_rst_n(I_rst_n),

        .I_96b_frame_start(awb_O_tuser),
        .I_96b_valid      (awb_O_tvalid),
        .I_96b_data       (awb_O_tdata),

        .O_128b_frame_start(awb_O_tuser_128),
        .O_128b_valid      (awb_O_tvalid_128),
        .O_128b_data       (awb_O_tdata_128)
    );

endmodule
