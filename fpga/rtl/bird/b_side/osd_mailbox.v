module osd_mailbox #(
    parameter WIDTH = 597
) (
    input wire src_clk,
    src_rst_n,
    src_send,
    input wire [WIDTH-1:0] src_payload,
    output wire src_ready,
    input wire dst_clk,
    dst_rst_n,
    dst_take,
    output wire dst_valid,
    output wire [WIDTH-1:0] dst_payload
);
    reg [WIDTH-1:0] held;
    reg req, ack;
    (* async_reg = "true" *) reg ack1, ack2, req1, req2;
    assign src_ready   = (ack2 == req);
    assign dst_valid   = (req2 != ack);
    assign dst_payload = held;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            held <= 0;
            req  <= 0;
            ack1 <= 0;
            ack2 <= 0;
        end else begin
            ack1 <= ack;
            ack2 <= ack1;
            if (src_send && src_ready) begin
                held <= src_payload;
                req  <= ~req;
            end
        end
    end
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            ack  <= 0;
            req1 <= 0;
            req2 <= 0;
        end else begin
            req1 <= req;
            req2 <= req1;
            if (dst_take && dst_valid) ack <= req2;
        end
    end
endmodule
