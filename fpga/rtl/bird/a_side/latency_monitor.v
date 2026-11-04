module latency_monitor #(
    parameter integer CLOCK_HZ = 50000000,
    MULTI_REQUEST = 0
) (
    input wire clk,
    rst_n,
    input wire context_valid,
    input wire [15:0] context_transmit_ms,
    context_reply_ms,
    context_total_ms,

    input wire arm,
    input wire wire_done,
    input wire matched_reply,
    input wire abandoned,
    input wire capture_error,

    input wire [31:0] processing_ms,

    output reg [15:0] last_transmit_ms,
    last_reply_ms,
    last_total_ms,
    output reg [15:0] last_processing_ms,
    output reg last_valid,

    output reg [15:0] min_total_ms,
    max_total_ms,
    output reg [31:0] total_acc_ms,
    output reg [15:0] sample_count,

    output reg [15:0] timeout_count,
    capture_error_count
);
    localparam integer MS_TICKS = CLOCK_HZ / 1000;
    localparam integer CW = $clog2(MS_TICKS);

    reg [CW-1:0] tick;
    reg [15:0] ms_since_arm, ms_at_wire_done;
    reg running, sent;

    always @(posedge clk) begin
        if (!rst_n) begin
            tick <= 0;
            ms_since_arm <= 0;
            ms_at_wire_done <= 0;
            running <= 0;
            sent <= 0;
            last_transmit_ms <= 0;
            last_reply_ms <= 0;
            last_total_ms <= 0;
            last_processing_ms <= 0;
            last_valid <= 0;
            min_total_ms <= 16'hffff;
            max_total_ms <= 0;
            total_acc_ms <= 0;
            sample_count <= 0;
            timeout_count <= 0;
            capture_error_count <= 0;
        end else begin

            if (running) begin
                if (tick == MS_TICKS - 1) begin
                    tick <= 0;

                    if (ms_since_arm != 16'hffff) ms_since_arm <= ms_since_arm + 1'b1;
                end else tick <= tick + 1'b1;
            end

            if (MULTI_REQUEST) begin
                running <= 0;
                sent <= 0;
                if (matched_reply && context_valid) begin
                    last_transmit_ms <= context_transmit_ms;
                    last_reply_ms <= context_reply_ms;
                    last_total_ms <= context_total_ms;
                    last_processing_ms <= processing_ms > 65535 ? 16'hffff : processing_ms[15:0];
                    last_valid <= 1;
                    if (context_total_ms < min_total_ms) min_total_ms <= context_total_ms;
                    if (context_total_ms > max_total_ms) max_total_ms <= context_total_ms;
                    total_acc_ms <= total_acc_ms + {16'd0, context_total_ms};
                    if (sample_count != 16'hffff) sample_count <= sample_count + 1'b1;
                end
                if (abandoned && timeout_count != 16'hffff) timeout_count <= timeout_count + 1'b1;
                if (capture_error && capture_error_count != 16'hffff)
                    capture_error_count <= capture_error_count + 1'b1;
            end else if (arm) begin
                running <= 1;
                sent <= 0;
                tick <= 0;
                ms_since_arm <= 0;
                ms_at_wire_done <= 0;
            end else if (running) begin
                if (wire_done && !sent) begin
                    sent <= 1;
                    ms_at_wire_done <= ms_since_arm;
                end

                if (matched_reply) begin
                    running <= 0;
                    last_transmit_ms <= ms_at_wire_done;
                    last_reply_ms <= ms_since_arm - ms_at_wire_done;
                    last_total_ms <= ms_since_arm;
                    last_processing_ms<=(processing_ms>32'hffff) ? 16'hffff
                                                 : processing_ms[15:0];
                    last_valid <= 1;
                    if (ms_since_arm < min_total_ms) min_total_ms <= ms_since_arm;
                    if (ms_since_arm > max_total_ms) max_total_ms <= ms_since_arm;
                    total_acc_ms <= total_acc_ms + {16'd0, ms_since_arm};
                    if (sample_count != 16'hffff) sample_count <= sample_count + 1'b1;
                end else if (abandoned) begin
                    running <= 0;
                    if (timeout_count != 16'hffff) timeout_count <= timeout_count + 1'b1;
                end else if (capture_error) begin
                    running <= 0;
                    if (capture_error_count != 16'hffff)
                        capture_error_count <= capture_error_count + 1'b1;
                end
            end
        end
    end
endmodule
