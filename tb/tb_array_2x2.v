`timescale 1ns/1ps

// 2x2 systolic array 연결, 타이밍을 검증한다.
// TB가 skew를 적용한 입력을 직접 넣고, 매 사이클 4개 PE의 acc를 손 계산과 직접 비교

module tb_array_2x2;
    localparam  ROWS = 2;
    localparam  COLS = 2;


    // TB가 값을 넣는 신호. DUT 입력이 됨
    // reg : 입력
    // wire: 출력
    reg                     clk;
    reg                     rst_n;
    reg                     clear;
    reg [ROWS*8-1:0]        a_in;       //INT8
    reg [ROWS-1:0]          a_valid_in;
    reg [COLS*8-1:0]        b_in;
    reg [COLS-1:0]          b_valid_in;

    // DUT 가 내보내는 신호 (DUT 출력)
    wire [ROWS*COLS*32-1:0] acc_out;

    // 통과한 step 수
    integer checks;



    // 검증할 systolic array 회로를 하나 꺼낸다.
    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS)
    ) dut(
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .a_in(a_in),
        .a_valid_in(a_valid_in),
        .b_in(b_in),
        .b_valid_in(b_valid_in),
        .acc_out(acc_out)
    );


    // 100 MHz clk
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // PE(r,c)의 누산값 acc을 acc_out에서 꺼낸다 (row-major, signed 32b)
    // PE 특정 값을 위치로 읽게 해줌 (r,c)
    function signed [31:0] acc;
    // acc(1,0) -> acc_out[95:64]를 signed 값으로 돌려줌
    // signed 32b 값을 돌려주는 function. 
        input integer r;
        input integer c;
        begin
            acc = acc_out[(r*COLS + c)*32 +: 32]; // +: -> 시작 비트부터 위로 32 비트만큼 잘라냄
        end
    endfunction

    // 1 cycle 동안 경계 입력 8개를 넣고, posedge 직후 4개 PE의 기대 acc를 확인한다.
    task step;
        input signed [7:0]      a0, a1;            // 경계 a_0,1 데이터
        input signed [7:0]      b0, b1;            // 경계 b_0,1 데이터
        input                   av0, av1;          // a valid
        input                   bv0, bv1;          // b valid
        input signed [31:0]     e00, e01, e10, e11; // expected acc
        begin
            @(negedge clk); // input.
                            // input을 negedge에서 넣는 이유 : PE는 posedge에서 입력 읽기에 TB에서 값 바꿀 때는 구분하려고
            clear       = 1'b0; // <= : nonblocking은 상승 엣지 순간에 갱신.
                                // = : blocking 은 적은 순서대로 즉시 값이 바뀜. TB에서는 이거 씀
            a_in        = {a1, a0};
            a_valid_in  = {av1, av0};
            b_in        = {b1, b0};
            b_valid_in  = {bv1, bv0};

            @(posedge clk);
            #1;

            if (acc(0,0) !== e00 ||
                acc(0,1) !== e01 ||
                acc(1,0) !== e10 ||
                acc(1,1) !== e11
                )
                $fatal(1, "FAIL step %0d: acc=[%0d %0d ; %0d %0d]. expected=[%0d %0d ; %0d %0d]",
                       checks + 1, acc(0,0), acc(0,1), acc(1,0), acc(1,1),
                       e00, e01, e10, e11);
            checks = checks + 1;
            $display("PASS step %0d: acc=[%0d %0d ; %0d %0d]",
                     checks, acc(0,0), acc(0,1), acc(1,0), acc(1,1));
        end
    endtask

    // task do_clear : clear를 1cycle걸고, PE 4개의 acc가 모두 0이 됐는지 확인한다.
    task do_clear;
        begin
            @(negedge clk);
            clear           = 1'b1;
            a_valid_in      = 0;
            b_valid_in      = 0;

            @(posedge clk);
            #1;

            if (acc_out !== 0)
                $fatal(1, "FAIL clear : acc_out is not zero");

            $display("PASS clear");
        end
    endtask

    // MAIN
    initial begin
        $dumpfile("array_2x2.vcd");
        $dumpvars(0, tb_array_2x2);

        rst_n           = 1'b0;
        clear           = 1'b0;
        a_in            = 0;
        a_valid_in      = 0;
        b_in            = 0;
        b_valid_in      = 0;
        checks          = 0;

        // reset을 2cycle 건 뒤 해제

        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // test1: A=[[1,2],[3,4]], B=[[5,6],[7,8]] -> C=[[19,22],[43,50]]
        //   a0, a1, b0, b1, av0, av1, bv0, bv1,  e00, e01, e10, e11
        step( 1,  0,  5,  0,  1,  0,  1,  0,    5,  0,  0,  0);  // t0
        step( 2,  3,  7,  6,  1,  1,  1,  1,   19,  6, 15,  0);  // t1
        step( 0,  4,  0,  8,  0,  1,  0,  1,   19, 22, 43, 18);  // t2
        step( 0,  0,  0,  0,  0,  0,  0,  0,   19, 22, 43, 50);  // t3
        step( 0,  0,  0,  0,  0,  0,  0,  0,   19, 22, 43, 50);  // 입력 없음: 유지

        //test 2: 같은 행렬인데 valid=0인 칸의 데이터에 의미없는 값 대입. 과연 valid=0인건 확실히 처리하는가?
        do_clear;
        step(   1, -77,   5,  99,  1, 0, 1, 0,   5,  0,  0,  0);  // t0
        step(   2,   3,   7,   6,  1, 1, 1, 1,  19,  6, 15,  0);  // t1
        step(-128,   4, 127,   8,  0, 1, 0, 1,  19, 22, 43, 18);  // t2
        step(  55,  -1,  33,  44,  0, 0, 0, 0,  19, 22, 43, 50);  // t3
        
        // test 3: A=[[-128,127],[-3,5]], B=[[-128,-1],[127,-2]] -> C=[[32513,-126],[1019,-7]]
        do_clear;
        step(-128,  0, -128,  0,  1, 0, 1, 0,  16384,    0,    0,  0);  // t0
        step( 127, -3,  127, -1,  1, 1, 1, 1,  32513,  128,  384,  0);  // t1
        step(   0,  5,    0, -2,  0, 1, 0, 1,  32513, -126, 1019,  3);  // t2
        step(   0,  0,    0,  0,  0, 0, 0, 0,  32513, -126, 1019, -7);  // t3

        $display("PASS: %0d steps", checks);
        $finish;
    end
        // 무한 대기 방지
    initial begin
        #1000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule