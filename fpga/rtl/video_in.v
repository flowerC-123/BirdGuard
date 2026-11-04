module video_in #(
    parameter RESET_GUARD = 32
) (
    input wire I_rst_n,

    input wire         I_camera_clk,
    input wire         I_camera_frame_start,
    input wire         I_camera_valid,
    input wire [127:0] I_camera_data,
    input wire         I_mipi_rx_error,

    input wire I_ddr_clk,

    input  wire       I_display_pause,
    input  wire       I_video_out_rd_busy,
    output wire       O_video_in_wr_busy,
    output reg  [1:0] O_video_out_rp,

    output reg          O_ddr_user_wr_en,
    output reg  [ 24:0] O_ddr_user_addr,
    output wire [127:0] O_ddr_user_wr_data,
    input  wire         I_ddr_user_ready
);

    wire         S_fifo_rst;
    reg          S_camera_frame_start_extend;
    reg  [  3:0] S_extend_cnt;
    reg          S_camera_frame_start_extend_1d;
    reg          S_camera_frame_start_extend_2d;
    reg          S_camera_frame_start_extend_3d;
    wire         S_frame_start;
    reg  [  1:0] S_video_in_wp;
    wire [  8:0] S_fifo_rd_num;
    wire         S_fifo_rd_en;
    wire         S_fifo_rd_valid;
    wire [127:0] S_fifo_rd_data;
    reg          S_ddr_wr_valid;
    reg  [  9:0] S_ddr_wr_cnt;

    localparam IMAGE_BASE_ADDR_0 = 25'd0;
    localparam IMAGE_BASE_ADDR_1 = 25'd7000000;
    localparam IMAGE_BASE_ADDR_2 = 25'd14000000;
    localparam IMAGE_BASE_ADDR_3 = 25'd21000000;

    assign S_fifo_rst = !I_rst_n || S_camera_frame_start_extend_3d;

    (* ram_style="dram" *) reg [127:0] guard_mem[0:RESET_GUARD-1];
    reg [$clog2(RESET_GUARD)-1:0] guard_ptr;
    reg [RESET_GUARD-1:0] guard_valid_sr;
    reg [127:0] guard_data;
    reg guard_valid;
    always @(posedge I_camera_clk) begin
        guard_mem[guard_ptr] <= I_camera_data;
        guard_data <= guard_mem[guard_ptr];
    end
    always @(posedge I_camera_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            guard_ptr <= 0;
            guard_valid_sr <= 0;
            guard_valid <= 0;
        end else begin
            guard_ptr <= guard_ptr == RESET_GUARD - 1 ? 0 : guard_ptr + 1'b1;
            guard_valid_sr <= {guard_valid_sr[RESET_GUARD-2:0], I_camera_valid};
            guard_valid <= guard_valid_sr[RESET_GUARD-1];
        end
    end

    assign O_video_in_wr_busy = S_ddr_wr_valid;

    w128_d512_fifo U_w128_d512_fifo (
        .rst(S_fifo_rst),

        .clkw     (I_camera_clk),
        .we       (guard_valid),
        .di       (guard_data),
        .afull    (),
        .full_flag(),
        .wrusedw  (),

        .clkr      (I_ddr_clk),
        .re        (S_fifo_rd_en),
        .dout      (O_ddr_user_wr_data),
        .rdusedw   (S_fifo_rd_num),
        .valid     (),
        .empty_flag(),
        .aempty    ()
    );

    always @(posedge I_camera_clk or negedge I_rst_n) begin
        if (!I_rst_n) S_camera_frame_start_extend <= 1'b0;
        else if (I_camera_frame_start) S_camera_frame_start_extend <= 1'b1;
        else if (S_extend_cnt == 'd7) S_camera_frame_start_extend <= 1'b0;
        else S_camera_frame_start_extend <= S_camera_frame_start_extend;
    end

    always @(posedge I_camera_clk) begin
        if (S_camera_frame_start_extend) S_extend_cnt <= S_extend_cnt + 'd1;
        else S_extend_cnt <= 'd0;
    end

    always @(posedge I_ddr_clk) begin
        S_camera_frame_start_extend_1d <= S_camera_frame_start_extend;
        S_camera_frame_start_extend_2d <= S_camera_frame_start_extend_1d;
        S_camera_frame_start_extend_3d <= S_camera_frame_start_extend_2d;
    end

    assign S_frame_start = ~S_camera_frame_start_extend_3d & S_camera_frame_start_extend_2d;

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) S_video_in_wp <= 'd0;
        else if (I_display_pause) S_video_in_wp <= S_video_in_wp;
        else if (S_frame_start) begin
            if (I_mipi_rx_error) S_video_in_wp <= S_video_in_wp;
            else S_video_in_wp <= S_video_in_wp + 'd1;
        end else S_video_in_wp <= S_video_in_wp;
    end

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) O_video_out_rp <= 'd0;
        else if (I_display_pause) O_video_out_rp <= O_video_out_rp;
        else if (S_frame_start) begin
            case (S_video_in_wp)
                'd0: O_video_out_rp <= 'd2;
                'd1: O_video_out_rp <= 'd3;
                'd2: O_video_out_rp <= 'd0;
                'd3: O_video_out_rp <= 'd1;
            endcase
        end else O_video_out_rp <= O_video_out_rp;
    end

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) S_ddr_wr_valid <= 1'b0;
        else if (S_ddr_wr_valid && I_ddr_user_ready && S_ddr_wr_cnt == 'd239)
            S_ddr_wr_valid <= 1'b0;
        else if (S_fifo_rd_num >= 'd240 && (!I_video_out_rd_busy) && (!S_fifo_rst))
            S_ddr_wr_valid <= 1'b1;
        else S_ddr_wr_valid <= S_ddr_wr_valid;
    end

    always @(posedge I_ddr_clk) begin
        if (S_ddr_wr_valid) begin
            if (I_ddr_user_ready) S_ddr_wr_cnt <= S_ddr_wr_cnt + 'd1;
            else S_ddr_wr_cnt <= S_ddr_wr_cnt;
        end else S_ddr_wr_cnt <= 'd0;
    end

    assign S_fifo_rd_en = S_ddr_wr_valid & I_ddr_user_ready;

    always @(posedge I_ddr_clk) begin
        O_ddr_user_wr_en <= S_fifo_rd_en;
    end

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) O_ddr_user_addr <= 1'b0;
        else if (S_frame_start && (!I_mipi_rx_error)) begin
            case (S_video_in_wp)
                'd0: O_ddr_user_addr <= IMAGE_BASE_ADDR_0;
                'd1: O_ddr_user_addr <= IMAGE_BASE_ADDR_1;
                'd2: O_ddr_user_addr <= IMAGE_BASE_ADDR_2;
                'd3: O_ddr_user_addr <= IMAGE_BASE_ADDR_3;
            endcase
        end else if (S_frame_start && I_mipi_rx_error) begin
            case (S_video_in_wp)
                'd0: O_ddr_user_addr <= IMAGE_BASE_ADDR_3;
                'd1: O_ddr_user_addr <= IMAGE_BASE_ADDR_0;
                'd2: O_ddr_user_addr <= IMAGE_BASE_ADDR_1;
                'd3: O_ddr_user_addr <= IMAGE_BASE_ADDR_2;
            endcase
        end else if (O_ddr_user_wr_en) O_ddr_user_addr <= O_ddr_user_addr + 'd8;
        else O_ddr_user_addr <= O_ddr_user_addr;
    end

endmodule
