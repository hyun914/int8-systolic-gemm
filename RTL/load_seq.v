`timescale 1ns/1ps

// load_seq : 타일 하나를 메모리에서 읽어 오는 순서를 만든다.
//
//   A 단계: r = 0 .. rows_valid-1, k = 0 .. K-1   (A[i0+r][k])
//   B 단계: k = 0 .. K-1, c = 0 .. cols_valid-1   (B[k][j0+c])
//
// 출력은 "지금 차례인 원소"의 위치(phase_b, lane, k)와 메모리 주소(addr)이다.
// step이 1인 사이클이 끝나면 다음 원소로 넘어가고, 마지막 원소를 지나면 finished가 1이 된다.
//
// 코어는 이 모듈을 두 개 쓴다. 하나는 읽기 요청을 보낼 때, 하나는 응답을 받을 때 한 칸씩 진행한다.
// 메모리가 요청 순서대로 응답한다고 가정하므로 두 순서가 1:1로 맞고,
// 응답 쪽 출력으로 돌아온 바이트를 넣을 bank와 칸을 알 수 있다.
module load_seq #(
    parameter AW = 16
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          init,        // 타일 시작: 첫 원소로 되돌린다
    input  wire          step,        // 1이면 이번 사이클이 끝날 때 다음 원소로
    input  wire [15:0]   rows_valid,
    input  wire [15:0]   cols_valid,
    input  wire [15:0]   k_len,       // K
    input  wire [15:0]   n_len,       // N (B의 한 행 길이)
    input  wire [AW-1:0] a_start,     // A[i0][0]의 주소
    input  wire [AW-1:0] b_start,     // B[0][j0]의 주소
    output reg           phase_b,     // 0: A 단계, 1: B 단계
    output reg  [15:0]   lane,        // A 단계면 r, B 단계면 c
    output reg  [15:0]   k,
    output reg  [AW-1:0] addr,
    output reg           finished
);

    reg [AW-1:0] row_base;            // B 단계: 현재 행 B[k][j0]의 주소

    wire last_k   = (k == k_len - 1);
    wire last_row = (lane == rows_valid - 1);
    wire last_col = (lane == cols_valid - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            phase_b  <= 1'b0;
            lane     <= 16'd0;
            k        <= 16'd0;
            addr     <= {AW{1'b0}};
            row_base <= {AW{1'b0}};
            finished <= 1'b1;
        end else if (init) begin
            phase_b  <= 1'b0;
            lane     <= 16'd0;
            k        <= 16'd0;
            addr     <= a_start;
            row_base <= b_start;
            finished <= 1'b0;
        end else if (step && !finished) begin
            if (!phase_b) begin
                // A 단계: k가 안쪽 루프. A 타일의 행들은 메모리에서 이어져 있어 주소가 1씩 증가한다.
                if (!last_k) begin
                    k    <= k + 1'b1;
                    addr <= addr + 1'b1;
                end else if (!last_row) begin
                    k    <= 16'd0;
                    lane <= lane + 1'b1;
                    addr <= addr + 1'b1;
                end else begin
                    // A 타일 끝: B 단계로 넘어간다
                    phase_b <= 1'b1;
                    lane    <= 16'd0;
                    k       <= 16'd0;
                    addr    <= b_start;
                end
            end else begin
                // B 단계: c가 안쪽 루프. 한 행을 다 읽으면 N만큼 떨어진 다음 행으로 간다.
                if (!last_col) begin
                    lane <= lane + 1'b1;
                    addr <= addr + 1'b1;
                end else if (!last_k) begin
                    lane     <= 16'd0;
                    k        <= k + 1'b1;
                    row_base <= row_base + n_len;
                    addr     <= row_base + n_len;
                end else begin
                    finished <= 1'b1;
                end
            end
        end
    end

endmodule
