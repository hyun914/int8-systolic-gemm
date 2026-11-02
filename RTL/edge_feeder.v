`timescale 1ns/1ps

// edge_feeder : COMPUTE 동안 배열 가장자리(edge)에 들어갈 데이터의 타이밍을 정한다.
//   lane마다 bank 읽기 주소(rd_addr)와 그 값이 진짜인지(valid)를 만든다.
//
// 필요한 이유: PE(r,c)에서 A[r][k]와 B[k][c]가 같은 사이클에 만나려면 행(열) i가 i사이클 늦게 들어가야 한다 (skew).
// - lane i (A쪽이면 행, B쪽이면 열)는 COMPUTE 사이클 t에 k = t - i 번째 칸을 읽는다.
//   이 "- i"가 skew이고, 공용 카운터 t 하나로 만든다 (지연 레지스터 방식과의 비교는 README 7.3절).
// - 0 <= k < K이고 i < lanes_valid일 때만 유효하다. 경계 타일의 padding lane은 valid=0으로 두어 배열에 넣지 않는다.
// - 주소는 조합으로 같은 사이클에 bank로 간다. bank 읽기가 1사이클 걸리므로 valid도 1사이클 늦춰 데이터와 맞춘다.
module edge_feeder #(
    parameter NLANE = 4,                     // lane 수 (A쪽 ROWS, B쪽 COLS)
    parameter AW    = 6                      // bank 안 주소 폭
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                active,       // COMPUTE 상태일 때 1
    input  wire [15:0]         t,            // COMPUTE 시작부터 센 사이클 번호 (A, B 공용)
    input  wire [15:0]         k_len,        // K
    input  wire [15:0]         lanes_valid,  // 유효 lane 수 (A쪽 rows_valid, B쪽 cols_valid)

    output wire [NLANE*AW-1:0] rd_addr,      // lane i의 bank 읽기 주소 = rd_addr[i*AW +: AW]
    output wire [NLANE-1:0]    valid_out     // bank 데이터와 같은 사이클에 맞춘 valid
);

    genvar i;
    generate
        for (i = 0; i < NLANE; i = i + 1) begin : g_lane
            wire [15:0] k        = t - i;    // 이 lane이 이번 사이클에 읽을 칸 (i사이클 늦게 출발)
            // 이 lane이 지금 진짜 데이터를 보낼 차례인가: COMPUTE 중, 출발함, K개 안 끝남, 실제 있는 lane
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
