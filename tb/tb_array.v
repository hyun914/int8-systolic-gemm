`timescale 1ns/1ps

// tb_array : ROWS x COLS 배열 단독 랜덤 검증 (S1b)
//
// - A, B, 정답 C는 model/gen_vectors.py가 만든 build/*.hex에서 읽는다.
// - TB가 skew 규칙대로 경계 입력을 자동으로 넣는다.
// - 매 사이클 모든 PE의 acc를 TB가 계산한 부분합과 비교한다.
// - 마지막에 모든 PE의 acc를 Python 정답 C와 비교한다.
//
// ROWS, COLS, K는 컴파일할 때 -P 옵션으로 바꾼다. 예:
//   iverilog -g2005 -Ptb_array.ROWS=4 -Ptb_array.COLS=4 -Ptb_array.K=29 ...
module tb_array;

    parameter ROWS = 4;
    parameter COLS = 4;
    parameter K    = 8;

    // 마지막 MAC이 일어나는 사이클 번호와, 한 타일의 연산 사이클 수
    localparam T_LAST = K + ROWS + COLS - 3;
    localparam N_CYC  = K + ROWS + COLS - 2;
    // 입력이 끝난 뒤 acc가 유지되는지 더 확인할 사이클 수
    localparam N_HOLD = 2;

    // DUT 입력
    reg                     clk;
    reg                     rst_n;
    reg                     clear;
    reg  [ROWS*8-1:0]       a_in;
    reg  [ROWS-1:0]         a_valid_in;
    reg  [COLS*8-1:0]       b_in;
    reg  [COLS-1:0]         b_valid_in;

    // DUT 출력
    wire [ROWS*COLS*32-1:0] acc_out;

    // 행렬 저장 공간 (row-major, 원소 하나가 배열 칸 하나)
    reg [7:0]  A_mem [0:ROWS*K-1];      // A[r][k] = A_mem[r*K + k]
    reg [7:0]  B_mem [0:K*COLS-1];      // B[k][c] = B_mem[k*COLS + c]
    reg [31:0] C_mem [0:ROWS*COLS-1];   // C[r][c] = C_mem[r*COLS + c]

    integer cycle;      // 메인 루프의 사이클 번호 t
    integer checks;     // 비교한 PE 값의 개수

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .a_in(a_in),
        .a_valid_in(a_valid_in),
        .b_in(b_in),
        .b_valid_in(b_valid_in),
        .acc_out(acc_out)
    );

    // 100MHz 클럭
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // PE(r,c)의 누산값을 acc_out에서 꺼낸다 (row-major, 32비트 signed)
    function signed [31:0] acc;
        input integer r;
        input integer c;
        begin
            acc = acc_out[(r*COLS + c)*32 +: 32];
        end
    endfunction

    // PE(r,c)가 사이클 t의 posedge까지 누산했어야 하는 값
    // A[r][k]와 B[k][c]는 t = k + r + c에 만나므로, 사이클 t까지 마친 k는 0 .. t-r-c 이다.
    function integer partial_sum;
        input integer r;
        input integer c;
        input integer t;
        integer k;
        integer k_last;
        begin
            k_last = t - r - c;
            if (k_last > K - 1)
                k_last = K - 1;

            partial_sum = 0;
            for (k = 0; k <= k_last; k = k + 1)
                partial_sum = partial_sum
                            + $signed(A_mem[r*K + k]) * $signed(B_mem[k*COLS + c]);
        end
    endfunction

    // 사이클 t에 경계로 들어갈 값을 skew 규칙대로 넣는다.
    //   행 r: A[r][t-r],  열 c: B[t-c][c]  (0 <= k < K일 때만 valid)
    // valid가 0인 칸에는 무작위 값을 넣어, PE가 무효 데이터를 무시하는지도 함께 확인한다.
    task drive_edges;
        input integer t;
        integer r;
        integer c;
        integer k;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                k = t - r;
                if (k >= 0 && k < K) begin
                    a_in[r*8 +: 8] = A_mem[r*K + k];
                    a_valid_in[r]  = 1'b1;
                end else begin
                    a_in[r*8 +: 8] = $random;
                    a_valid_in[r]  = 1'b0;
                end
            end

            for (c = 0; c < COLS; c = c + 1) begin
                k = t - c;
                if (k >= 0 && k < K) begin
                    b_in[c*8 +: 8] = B_mem[k*COLS + c];
                    b_valid_in[c]  = 1'b1;
                end else begin
                    b_in[c*8 +: 8] = $random;
                    b_valid_in[c]  = 1'b0;
                end
            end
        end
    endtask

    // 사이클 t의 posedge 직후, 모든 PE의 acc가 부분합과 같은지 확인한다.
    task check_cycle;
        input integer t;
        integer r;
        integer c;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    if (acc(r, c) !== partial_sum(r, c, t))
                        $fatal(1, "FAIL t=%0d PE(%0d,%0d): acc=%0d expected=%0d",
                               t, r, c, acc(r, c), partial_sum(r, c, t));
                    checks = checks + 1;
                end
            end
        end
    endtask

    // 연산이 끝난 뒤 모든 PE의 acc를 Python 정답 C와 비교한다.
    task check_final;
        integer r;
        integer c;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    if (acc(r, c) !== $signed(C_mem[r*COLS + c]))
                        $fatal(1, "FAIL final PE(%0d,%0d): acc=%0d model=%0d",
                               r, c, acc(r, c), $signed(C_mem[r*COLS + c]));
                end
            end
        end
    endtask

    initial begin
        $readmemh("build/a.hex", A_mem);
        $readmemh("build/b.hex", B_mem);
        $readmemh("build/c.hex", C_mem);

        rst_n      = 1'b0;
        clear      = 1'b0;
        a_in       = 0;
        a_valid_in = 0;
        b_in       = 0;
        b_valid_in = 0;
        checks     = 0;

        // reset을 2사이클 건 뒤 해제
        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // 사이클마다: negedge에 경계 입력을 넣고, posedge 직후 모든 PE를 확인한다.
        for (cycle = 0; cycle < N_CYC + N_HOLD; cycle = cycle + 1) begin
            @(negedge clk);
            drive_edges(cycle);

            @(posedge clk);
            #1;
            check_cycle(cycle);
        end

        check_final;

        $display("PASS: ROWS=%0d COLS=%0d K=%0d, %0d cycles, %0d PE checks, last MAC at t=%0d",
                 ROWS, COLS, K, N_CYC + N_HOLD, checks, T_LAST);
        $finish;
    end

    // 무한 대기 방지
    initial begin
        #100000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule
