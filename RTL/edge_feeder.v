`timescale 1ns/1ps

// edge_feeder : COMPUTE 동안 bank 읽기 주소와 배열 경계 valid를 skew 규칙대로 만든다.
//
// - 레인 i (A쪽이면 행, B쪽이면 열)는 COMPUTE 사이클 t에 k = t - i 번째 원소를 읽는다.
//   따라서 레인마다 i사이클씩 늦게 시작하는 skew가 카운터 하나로 만들어진다.
// - 0 <= k < K이고 i < lanes_valid일 때만 유효하다.
//   lanes_valid보다 큰 레인(경계 타일의 padding 행/열)은 valid=0으로 두어 배열에 넣지 않는다.
// - bank 읽기가 1사이클 걸리므로 valid도 1사이클 늦춰서 데이터와 같은 사이클에 내보낸다.
module edge_feeder #(
    parameter NLANE = 4,
    parameter AW    = 6
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                active,       // COMPUTE 상태일 때 1
    input  wire [15:0]         t,            // COMPUTE 안에서의 사이클 번호
    input  wire [15:0]         k_len,        // K
    input  wire [15:0]         lanes_valid,  // 이 타일의 유효 행 수 또는 유효 열 수
    output wire [NLANE*AW-1:0] rd_addr,      // bank i의 읽기 주소
    output wire [NLANE-1:0]    valid_out     // bank 데이터와 같은 사이클에 맞춘 valid
);

    genvar i;
    generate
        for (i = 0; i < NLANE; i = i + 1) begin : g_lane
            wire [15:0] k        = t - i;
            wire        in_range = active && (t >= i) && (k < k_len) && (i < lanes_valid);
            reg         valid_q;

            assign rd_addr[i*AW +: AW] = in_range ? k[AW-1:0] : {AW{1'b0}};

            always @(posedge clk) begin
                if (!rst_n)
                    valid_q <= 1'b0;
                else
                    valid_q <= in_range;
            end

            assign valid_out[i] = valid_q;
        end
    endgenerate

endmodule
