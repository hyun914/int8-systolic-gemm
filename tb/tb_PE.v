`timescale 1ns/1ps
// 1ns -> #1 = 1ns로 해석
// 1ps -> 시간을 1ps 단위의 정밀도로 표현

// input -> DUT
// posedge에서 연산 시작 -> 실제 출력과 예상값을 비교

module tb_PE; // 내부에서 입력 생성하므로 외부 입출력 포트 필요 x
    
    
    // tb가 값을 직접 대입해서 DUT를 제어하는 신호
    reg clk;
    reg rst_n;
    reg clear;
    reg signed [7:0] a_in;
    reg signed [7:0] b_in;
    reg a_valid_in;
    reg b_valid_in;
    
    // DUT가 만든 출력을 TB가 관찰하는 연결선
    wire signed [7:0] a_out;
    wire signed [7:0] b_out;
    wire a_valid_out;
    wire b_valid_out;
    wire signed [31:0] acc_out;

    // 지금까지 검사를 통과한 테스트의 갯수를 저장하는 TB 변수
    integer checks;

    // dut: 검증할 PE 회로를 TB 안에 배치하고 신호 연결
    PE dut(
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),

        .a_in(a_in),
        .b_in(b_in),

        .a_valid_in(a_valid_in),
        .b_valid_in(b_valid_in),
        .a_out(a_out),
        .b_out(b_out),
        .a_valid_out(a_valid_out),
        .b_valid_out(b_valid_out),
        .acc_out(acc_out)
    );

    // 100MHz
    initial clk = 1'b0;
    always #5 clk = ~clk;



    // check_cycle : 한 번의 입력 설정과 결과 검사를 묶어놓음
    task check_cycle;
        input reset_n_value;
        input clear_value;
        input signed [7:0] a_value;
        input signed [7:0] b_value;
        input a_valid_value;
        input b_valid_value;
        input signed[31:0] expected_acc;
        // check_cycle(1,0,2,7,1,1,19) 식으로 입력값 받을 수 있다
        begin
            @(negedge clk); 
            rst_n       = reset_n_value;
            clear       = clear_value;
            a_in        = a_value;
            b_in        = b_value;
            a_valid_in  = a_valid_value;
            b_valid_in  = b_valid_value;

            @(posedge clk);
            #1; // 값 갱신이 끝난 뒤 값을 읽도록 1ns를 기다리는 장치
            
            if (acc_out !== expected_acc)
                $fatal(1, "Fail case %0d: acc=%0d expected = %0d",
                        checks + 1, acc_out, expected_acc);
            if(!reset_n_value || clear_value) begin
                if(a_out !== 8'sd0      || 
                   b_out !== 8'sd0      || 
                   a_valid_out !== 1'b0 || 
                   b_valid_out !== 1'b0)
                   
                $fatal(1, "Fail case %0d : reset, clear forwarding", checks + 1);
            end else begin
                if (a_out !== a_value             ||
                    b_out !== b_value             ||
                    a_valid_out !== a_valid_value ||
                    b_valid_out !== b_valid_value)
                    $fatal(1,"Fail case %0d: data/valid forwarding", checks+1);
            end

            checks = checks + 1;
            $display("PASS case %0d: a=%0d, b=%0d, a_valid=%b, b_valid= %b, acc=%0d",
                    checks, a_value, b_value, a_valid_value, b_valid_value, acc_out);
        end
    endtask

    initial begin  
        $dumpfile("PE.vcd");
        $dumpvars(0,tb_PE);
        //TB가 initial value를 정함
        rst_n = 1'b0;
        clear = 1'b0;
        a_in = 8'sd0;
        b_in = 8'sd0;
        a_valid_in = 1'b0;
        b_valid_in = 1'b0;
        checks = 0;

        // 인수 순서: rst_n, clear, A,B, A_valid, B_valid, 예상 누산값
        check_cycle(0, 0,   11,   -9, 1, 1,     0); // reset이 MAC보다 우선한다.
        check_cycle(1, 0,    1,    5, 1, 1,     5);
        check_cycle(1, 0,    2,    7, 1, 1,    19);
        check_cycle(1, 0,    3,    9, 1, 0,    19); // A만 유효: 누산값 유지
        check_cycle(1, 0,    4,   10, 0, 1,    19); // B만 유효: 누산값 유지
        check_cycle(1, 0,  127,  127, 0, 0,    19); // 둘 다 무효: 누산값 유지
        check_cycle(1, 0,   -3,    4, 1, 1,     7);
        check_cycle(1, 0, -128, -128, 1, 1, 16391);
        check_cycle(1, 0, -128,  127, 1, 1,   135);
        check_cycle(1, 0,  127,  127, 1, 1, 16264);
        check_cycle(1, 1,  127,  127, 1, 1,     0); // clear가 MAC보다 우선한다.
        check_cycle(1, 0,   -1,    5, 1, 1,    -5);
        check_cycle(0, 0,    3,    4, 1, 1,     0); // 실행 중 reset
        check_cycle(1, 0,    2,    3, 1, 1,     6);

        $display("PASS: %0d PE test cases", checks);
        $finish;
    end

    initial begin
        #1000;
        $fatal(1, "FAIL: simulation timeout");
    end
endmodule
