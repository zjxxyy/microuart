
//
// Micro uart testbench
//
// Freeware 2015, Fen Logic Ltd.
//
// This code is free and is delivered 'as is'.
// It comes without any warranty, to the extent permitted by applicable law.
// There are no restrictions to any use or re-use of this code
// in any form or shape. It would be nice if you keep my company name
// in the source or modified source code but even that is not
// required as I can't check it anyway.
// But the code comes with no warranties or guarantees whatsoever.
//

// This testbench stop as soon as an error is detected
// Therefore the fact that it finishes means that no errors where found
// (Which is not the same as "there are no errors"!)

module micro_uart1_apb_testbench;

localparam CLK_PERIOD=100;

//
// Status register bits
//
`define MUA_REC_HAS_DATA 16'h0001
`define MUA_REC_OVERFLOW 16'h0002
`define MUA_TRANS_READY  16'h0004
// Enable and pending bits have different position
// This is just for future IRQ control bits implementation
`define MUA_RX_IRQ_ENBL  16'h0001
`define MUA_TX_IRQ_ENBL  16'h0002
`define MUA_RX_IRQ_PEND  16'h0008
`define MUA_TX_IRQ_PEND  16'h0010

//
// Test parameters
//
// Set high baudrate to reduce simulation time
`define MUATST_BAUDCOUNT 16'h3
// Timeout is two character times
// This take into account that the cpu read/write tasks
// take two clock cycles to complete
`define MUATST_TIMEOUT   (`MUATST_BAUDCOUNT*8*10)

// Read & Write task destinations
`define MUATST_STATREG   2'h00
`define MUATST_CNTLREG   2'h00
`define MUATST_BAUDREG   2'h01
`define MUATST_DATAREG   2'h02


reg          clk;
reg          reset_n;

// CPU bus
// APB interface
reg           apb_psel;     // active high if UART is selected
reg           apb_penable;  // active high if UART is selected
reg           apb_pwrite;   // active high if writing
reg   [ 31:0] apb_pwdata;   // APB write data
reg   [  3:0] apb_paddr;    // APB address bus LS 2 bits are unused
wire  [ 31:0] apb_prdata;   // data read back
wire         irq;

   //
wire         ser_in;
wire         ser_out;

   initial
   begin

      clk            = 1'b0;
      reset_n        = 1'b0;
   //

      apb_psel       = 1'b0;
      apb_penable    = 1'b0;
      apb_pwrite     = 1'b0;
      apb_penable    = 1'b0;
      apb_pwdata     = 32'b0;
      apb_paddr      = 4'b0;

      #(5*CLK_PERIOD) ;
      reset_n        = 1'b1;
      #(5*CLK_PERIOD) ;

      basic_loopback_test;
      overflow_test;
      input_stuck_active_test;


      #(50*CLK_PERIOD) ;
      $display("***\n*** %m@%0t:All tests passed\n***",$time);

      $stop;


   end


micro_uart1_apb
micro_uart1_apb_inst (
   .clk          (clk),
   .reset_n      (reset_n),

   // CPU bus   
   .apb_psel   (apb_psel   ),
   .apb_penable(apb_penable),
   .apb_pwrite (apb_pwrite ),
   .apb_pwdata (apb_pwdata ),
   .apb_paddr  (apb_paddr  ),
   .apb_prdata (apb_prdata ),
   .irq        (irq),
  
   .ser_in       (ser_in),
   .ser_out      (ser_out)
);

   // Loop back
   assign ser_in = ser_out;



   // Generate clock. 
   initial
   begin
      clk = 1'b0;
      forever
         #(CLK_PERIOD/2) clk = ~clk;
   end

//
// Basic data test
// UART must be in loop-back
//
task basic_loopback_test;
integer    time_out,loop;
reg        done;
reg [15:0] rdata;
begin
   $display("*** Basic loopback test");
   // write baudrate register
   cpu_write_task(`MUATST_BAUDREG,`MUATST_BAUDCOUNT);

   // Send & receive some test patterns
   for (loop=0; loop<5; loop=loop+1)
   begin

      wait_tx_idle;

      // write the test data
      cpu_write_task(`MUATST_DATAREG,test_pattern(loop));

      // wait for Receiver to have data
      done = 0;
      time_out = 0;
      while (!done)
      begin
         // read status register
         cpu_read_task(`MUATST_STATREG,rdata);
         if ((rdata & `MUA_REC_HAS_DATA)===`MUA_REC_HAS_DATA)
         begin
            done = 1'b1;
            // Get the data
            cpu_read_task(`MUATST_DATAREG,rdata);
            if (rdata!==test_pattern(loop))
            begin
               $display("%m@%0t:Receive data error",$time);
               $display("      Have:0x%04x, Expected:0x%04x",rdata,test_pattern(loop));
               #10 $stop;
            end
         end
         else
         begin
            time_out = time_out + 1;
            if (time_out > `MUATST_TIMEOUT)
            begin
               $display("%m@%0t:Receive time-out error",$time);
               #10 $stop;
            end
         end
      end
   end // loop

   $display("*** Basic loopback test passed");

end
endtask // basic_loopback_test

//
// Input overflow test
// UART must be in loop-back
//
task overflow_test;
integer    time_out,loop;
reg        done;
reg [15:0] rdata;
begin
   $display("*** Overflow test");
   // write baudrate register
   cpu_write_task(`MUATST_BAUDREG,`MUATST_BAUDCOUNT);

   //
   // basic overflow test
   //

   // Send two bytes
   for (loop=0; loop<2; loop=loop+1)
   begin

      wait_tx_idle;

      // write the test data
      cpu_write_task(`MUATST_DATAREG,test_pattern(loop));
   end // send loop

   wait_tx_idle;

   // read status register
   cpu_read_task(`MUATST_STATREG,rdata);

   // Overflow flag must be set
   if ((rdata & `MUA_REC_OVERFLOW)!==`MUA_REC_OVERFLOW)
   begin
      $display("%m@%0t:Receive status error: overflow not set",$time);
      #10 $stop;
   end

    // Receive data must be set
   if ((rdata & `MUA_REC_HAS_DATA)!==`MUA_REC_HAS_DATA)
   begin
      $display("%m@%0t:Receive status error: data ready not set",$time);
      #10 $stop;
   end

   // Get the data
   cpu_read_task(`MUATST_DATAREG,rdata);
   // NOT checking the received data as it is undefined after an overflow
   // In THIS implementation it is the last data received but in
   // others it might be the previous data received

   // read status register
   cpu_read_task(`MUATST_STATREG,rdata);

   // check flags cleared
   if ((rdata & `MUA_REC_OVERFLOW)!==16'h0)
   begin
      $display("%m@%0t:Receive status error: overflow not cleared",$time);
      #10 $stop;
   end
   if ((rdata & `MUA_REC_HAS_DATA)!==16'h0)
   begin
      $display("%m@%0t:Receive status error: data ready not cleared",$time);
      #10 $stop;
   end

   //
   // JUST IN TIME overflow test
   // This one is very difficult (impossible?) to do in SW
   // We have to do a cpu read exactly at the time that data arrives
   // In Verilog I can cheat as I can check the receiver state

   // Send two bytes
   for (loop=0; loop<2; loop=loop+1)
   begin

      wait_tx_idle;

      // write the test data
      cpu_write_task(`MUATST_DATAREG,test_pattern(loop));
   end // send loop

   // Check internal state of receiver
   // the trick is to align the cpu_read with the rx_transfer signal
   done = 0;
   time_out = 0;
   while (!done)
   begin
      @(posedge clk)
      begin
         if ( (micro_uart1_apb_inst.micro_uart1_inst.rx_state==2'h2) // (RX_LOAD)
              &
              (micro_uart1_apb_inst.micro_uart1_inst.baud_count==16'h003) // Near baud tick
            )
         begin
            done = 1'b1;
            // Get the data
            cpu_read_task(`MUATST_DATAREG,rdata);
         end
      end
   end // while not done

   // Both bytes should now be safe
   if (rdata!==test_pattern(0))
   begin
      $display("%m@%0t:Receive data[0] error",$time);
      $display("      Have:0x%04x, Expected:0x%04x",rdata,test_pattern(0));
      #10 $stop;
   end
   cpu_read_task(`MUATST_DATAREG,rdata);
   if (rdata!==test_pattern(1))
   begin
      $display("%m@%0t:Receive data[1] error",$time);
      $display("      Have:0x%04x, Expected:0x%04x",rdata,test_pattern(1));
      #10 $stop;
   end


   $display("*** Overflow test passed");

end
endtask // overflow_test


//
// Input stuck active test
// Check that if the input is continous 'active'
// only a single byte is received
// (the receiver FSM waits for a stop condition)
//
task input_stuck_active_test;
integer    time_out,loop;
reg        done;
reg [15:0] rdata;
begin
   $display("*** Input stuck active test");
   // write baudrate register
   cpu_write_task(`MUATST_BAUDREG,`MUATST_BAUDCOUNT);

   wait_tx_idle;

   // Force input active
   force ser_out=1'b0;

   // wait longer then a symbol time (8*10 baudrate tick)
   for (loop=0; loop<(`MUATST_BAUDCOUNT*8*12); loop=loop+1)
      @(posedge clk) ;

   // read status register
   cpu_read_task(`MUATST_STATREG,rdata);

   // Overflow flag must be clear
   if ((rdata & `MUA_REC_OVERFLOW)!==16'h0000)
   begin
      $display("%m@%0t:Receive status error: overflow set",$time);
      #10 $stop;
   end

    // Receive data must be set
   if ((rdata & `MUA_REC_HAS_DATA)!==`MUA_REC_HAS_DATA)
   begin
      $display("%m@%0t:Receive status error: data ready not set",$time);
      #10 $stop;
   end


   // wait for more then 2 symbol times
   for (loop=0; loop<(`MUATST_BAUDCOUNT*8*20); loop=loop+1)
      @(posedge clk) ;

   // read status register
   cpu_read_task(`MUATST_STATREG,rdata);

   // Overflow flag must still be clear
   if ((rdata & `MUA_REC_OVERFLOW)!==16'h0000)
   begin
      $display("%m@%0t:Receive status error: overflow set",$time);
      #10 $stop;
   end

    // Receive data must be set
   if ((rdata & `MUA_REC_HAS_DATA)!==`MUA_REC_HAS_DATA)
   begin
      $display("%m@%0t:Receive status error: data ready not set",$time);
      #10 $stop;
   end

   // restore system
   release ser_out;


   // Get the data
   cpu_read_task(`MUATST_DATAREG,rdata);
   if (rdata!==16'h0000)
   begin
      $display("%m@%0t:Receive data idle error",$time);
      #10 $stop;
   end

   // Wait for REC to finish the stop state
   for (loop=0; loop<(`MUATST_BAUDCOUNT*8); loop=loop+1)
      @(posedge clk) ;

   $display("*** Input stuck active test passed");

end
endtask // input_stuck_active_test

//
// Interrupt test
// UART must be in loop-back
//
task interrupt_test;
integer    loop;
reg [15:0] rdata;
begin
   $display("*** Interrupt test");
   // write baudrate register
   cpu_write_task(`MUATST_BAUDREG,`MUATST_BAUDCOUNT);
   // clear control register
   cpu_write_task(`MUATST_CNTLREG,16'h0);

   wait_tx_idle;

   // Check IRQ status bits are clear
   cpu_read_task(`MUATST_STATREG,rdata);
   if ((rdata & (`MUA_RX_IRQ_PEND | `MUA_RX_IRQ_PEND))!==16'h0)
   begin
      $display("%m@%0t:IRQ status bits not clear error",$time);
      #10 $stop;
   end
   // Check irq output is clear
   if (irq!==1'b0)
   begin
      $display("%m@%0t:IRQ output not clear error (0)",$time);
      #10 $stop;
   end

   // Set Receive and Transmit IRQ enable
   cpu_write_task(`MUATST_CNTLREG,`MUA_TX_IRQ_ENBL | `MUA_RX_IRQ_ENBL);

   // Check TX IRQ status bit is set, RX is clear
   cpu_read_task(`MUATST_STATREG,rdata);
   if ((rdata & `MUA_TX_IRQ_PEND)===16'h0)
   begin
      $display("%m@%0t:IRQ TX status bit not set error",$time);
      #10 $stop;
   end
   if ((rdata & `MUA_RX_IRQ_PEND)!==16'h0)
   begin
      $display("%m@%0t:IRQ RX status bit is set error",$time);
      #10 $stop;
   end
   // Check irq output is set
   if (irq!==1'b1)
   begin
      $display("%m@%0t:IRQ output not set error (0)",$time);
      #10 $stop;
   end


   // Send byte, TX FSM should leave idle state
   cpu_write_task(`MUATST_DATAREG,16'hAA);

   // Check TX IRQ status bit is now clear
   cpu_read_task(`MUATST_STATREG,rdata);
   if ((rdata & `MUA_TX_IRQ_PEND)!==16'h0)
   begin
      $display("%m@%0t:IRQ TX status bit not clear error (1)",$time);
      #10 $stop;
   end
   // Check irq output is clear
   if (irq!==1'b0)
   begin
      $display("%m@%0t:IRQ output not clear error (1)",$time);
      #10 $stop;
   end

   // wait for Receiver to have data
   // (Removed time-out as thus far it did not lock up)
   rdata = 16'h0;
   while ((rdata & `MUA_REC_HAS_DATA)==16'h0000)
      // read status register
      cpu_read_task(`MUATST_STATREG,rdata);

   // Check rx pending bit
   if ((rdata & `MUA_RX_IRQ_PEND)!==`MUA_RX_IRQ_PEND)
   begin
      $display("%m@%0t:IRQ RX status bit is not set error",$time);
      #10 $stop;
   end

   // Read the data
   cpu_read_task(`MUATST_DATAREG,rdata);
   // Check but had better be OK after all the tests we ran
   if (rdata!==16'h00AA)
   begin
      $display("%m@%0t:Receive data AA error",$time);
      #10 $stop;
   end

   // read the status
   cpu_read_task(`MUATST_STATREG,rdata);

   // Check rx pending bit
   if ((rdata & `MUA_RX_IRQ_PEND)!==16'h0)
   begin
      $display("%m@%0t:IRQ RX status bit is not cleared error",$time);
      #10 $stop;
   end

   wait_tx_idle;
   // read the status
   cpu_read_task(`MUATST_STATREG,rdata);

   // Check tx pending bit
   if ((rdata & `MUA_TX_IRQ_PEND)!==`MUA_TX_IRQ_PEND)
   begin
      $display("%m@%0t:IRQ TX status bit is not set error (1)",$time);
      #10 $stop;
   end

   // disable interrupts
   cpu_write_task(`MUATST_CNTLREG,16'h0);


   $display("*** Interrupt test passed");

end
endtask // interrupt_test


//
// Wait for UART transmit to be idle
//
task wait_tx_idle;
integer   time_out;
reg [15:0] rdata;
begin
   rdata = 16'h0;
   time_out = 0;
   while ((rdata & `MUA_TRANS_READY)==16'h0)
   begin
      // read status register
      cpu_read_task(`MUATST_STATREG,rdata);
      // time-out
      time_out = time_out + 1;
      if (time_out > `MUATST_TIMEOUT)
      begin
         $display("%m@%0t:Transmit time-out error",$time);
         #10 $stop;
      end
   end
end
endtask



//
// CPU bus read/write tasks
// This is simplest but sub-optimal as has the issue
// of requiring a cycle to de-activate the bus at the end
//

//
// APB write to a register
//
task   cpu_write_task;
input  [ 1:0] regist;
input  [15:0] wdata;
begin
   @(posedge clk)
   begin
      apb_pwrite <= 1'b1;
      apb_psel   <= 1'b1;
      apb_pwdata <= wdata;
     case (regist)
      `MUATST_CNTLREG :
         apb_paddr <= 4'h8;
      `MUATST_BAUDREG :
         apb_paddr <= 4'h4;
      `MUATST_DATAREG :
         apb_paddr <= 4'h0;
      default : $display("%m @%0t: Testbench error\n",$time);
      endcase
   end
   @(posedge clk)
      apb_penable  <= 1'b1;
   @(posedge clk)
    begin
      apb_psel    <= 1'b0;
      apb_penable <= 1'b0;
   end

end
endtask

//
// CPU read from a register
//
task   cpu_read_task;
input  [ 1:0] regist;
output [15:0] rdata;
begin
   @(posedge clk)
   begin
      apb_pwrite <= 1'b0;
      apb_psel   <= 1'b1;
      case (regist)
      `MUATST_STATREG :
         apb_paddr <= 4'h8;
      `MUATST_BAUDREG :
         apb_paddr <= 4'h4;
      `MUATST_DATAREG :
         apb_paddr <= 4'h0;
      default : $display("%m @%0t: Testbench error\n",$time);
      endcase
   end
   @(posedge clk)
      apb_penable  <= 1'b1;
   @(posedge clk)
    begin
      rdata = apb_prdata;
      apb_psel    <= 1'b0;
      apb_penable <= 1'b0;
   end

end
endtask


//
// Test pattern function
// Generate a few useful test patterns
//
function [15:0] test_pattern;
input [3:0] select;
begin
   case (select)
   4'h0 : test_pattern = 16'h0081;
   4'h1 : test_pattern = 16'h007E;
   4'h2 : test_pattern = 16'h00FF;
   4'h3 : test_pattern = 16'h0000;
   4'h4 : test_pattern = 16'h00C3;
   default: test_pattern = {8'h00,select,select};
   endcase
end
endfunction


endmodule
