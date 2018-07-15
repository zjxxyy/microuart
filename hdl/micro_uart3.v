//
// Micro uart 3
//
// Third extension to mini UART
// Added :
// - Baud counter re-load when writing
//   to baud rate register 
//
// Aim is to get reasonable UART behaviour with minimal registers.
// Can be used with a CPU or controlled from a hardware FSM.
//
//
// Freeware 2015, Fen Logic Ltd.
// This code is free and is delivered 'as is'.
// It comes without any warranty, to the extent permitted by applicable law.
// There are no restrictions to any use or re-use of this code
// in any form or shape. It would be nice if you keep my company name
// in the source or modified source code but even that is not
// required as I can't check it anyway.
// But the code comes with no warranties or guarantees whatsoever.
//
// Features:
//  - 16 bit baud rate,
//  - eight times oversampling
//  - 1 start bit, 1 stop bit, 8 databits, no parity
//  - Double buffered input and output
//  - Input overrun flag
//  - 16 bit data bus++
//  - Receive & Transmit interrupts
//
// ++ Changing to an 8-bit bus requires splitting (or removing)
//    the baudrate register.
//
// Missing-features**:
//   - Other formats (8/7 bits, 1/2 stop , +parity)
//   - Double buffered transmit
//   - Break generation, break detection
//   - More I/O: CTS, RTS etc.
//
// **As the UART core functionality is present it is not too
//   difficult to add missing features
//

/*
     Current register count:
     Baud rate:
         3 reference clock conversion
         1 new baud rate flag 
        16 holding
        16 counting
     Transmit:
        3 regs for sample counter
        3 regs for bit counter
        8 regs for shift register
        2 regs for state machine
     Receive:
        2 regs for input synchronisation
        3 regs for sample counter
        3 regs for bit counter
        8 regs for shift register
        8 regs for data hold register
        2 regs for state machine
    Control/status:
        1 reg  for 'data recieved' flag
        1 reg  for input overrun error
        2 regs for interrupt control
Total: 79 register

  To save 16 registers the baudrate can be set 'hard coded'.


*/


module micro_uart3
(
   input             clk,          // system clock
   input             reset_n,      // active low reset
   input             ref_clock,    // System unchanging timing clock 
                                   // must be slower then clk/2

   // CPU bus
   input             data_select,  // High when cpu read/writes data reg.
   input             baud_select,  // High when cpu read/writes baud reg.
   input             cpu_read,     // High when cpu does read
   input             cpu_write,    // High when cpu does write
   input      [15:0] cpu_wdata,    // Data written by cpu
   output reg [15:0] cpu_rdata,    // Data back to cpu,
                                   //     0 when cpu_read is low
   output            irq,          // Interrupt

   //
   input             ser_in,       // Micro uart serial input
   output reg        ser_out       // Micro uart serial output
);


// states
localparam TX_IDLE = 2'h0,
           TX_TICK = 2'h1,
           TX_SS   = 2'h2,
           TX_DATA = 2'h3,

           RX_IDLE = 2'h0,
           RX_DATA = 2'h1,
           RX_LOAD = 2'h2,
           RX_STOP = 2'h3;

localparam TX_IRQ  = 0,
           RX_IRQ  = 1;


reg [ 1:0] irq_enable;
reg        ref_meta,ref_sync,ref_edge;
wire       ref_pulse;
reg        new_baud_rate;
reg [15:0] baud_rate,baud_count;
wire       samp_tick;

reg  [2:0] tx_bit_cnt, nxt_tx_bit_cnt;
reg  [2:0] tx_samp_cnt,nxt_tx_samp_cnt;
reg  [1:0] tx_state,   nxt_tx_state;
reg  [7:0] shift_out,  nxt_shift_out;

reg        ser_in_meta,ser_in_sync;
reg  [2:0] rx_bit_cnt, nxt_rx_bit_cnt;
reg  [2:0] rx_samp_cnt,nxt_rx_samp_cnt;
reg  [1:0] rx_state,   nxt_rx_state;
reg  [7:0] shift_in,   nxt_shift_in;
reg  [7:0] rec_reg;
reg        rx_transfer; // transfer from ser in shift register to data hold
reg        rec_has_data;
reg        overflow;

  //
  // Combinatorial part
  //

   always @( * )
   begin


      //
      // Transmit FSM
      //

      // Defaults for TX FSM
      nxt_tx_state    = tx_state;
      nxt_tx_bit_cnt  = tx_bit_cnt;
      nxt_tx_samp_cnt = tx_samp_cnt;
      nxt_shift_out   = shift_out;

      case (tx_state)
      TX_IDLE :
         begin
           // wait for write to TX register
           // catch the write data and go wait for a tick
           ser_out = 1'b1;
           if (cpu_write & data_select)
           begin
              nxt_shift_out  = cpu_wdata[7:0];
              // if (samp_tick).. could go straight to TX_SS
              // but this is a short wait and saves logic
              nxt_tx_state   = TX_TICK;
           end
         end
      TX_TICK :
         begin
            // wait for sample tick
            nxt_tx_samp_cnt = 3'h0;
            nxt_tx_bit_cnt  = 3'h0;
            ser_out =  1'b1;
            if (samp_tick)
               nxt_tx_state = TX_SS;
         end
      TX_SS :
         // combined start/stop state
         // Saves one FF in state
         // Re-using 3 bit comperator from TX_DATA
         begin
            ser_out = (tx_bit_cnt==3'h7) ? 1'b1 : 1'b0;
            if (samp_tick)
            begin
               nxt_tx_samp_cnt = tx_samp_cnt + 3'h1;
               if (tx_samp_cnt==3'h7)
               begin
                  if (tx_bit_cnt==3'h7)
                     nxt_tx_state = TX_IDLE;
                  else
                     nxt_tx_state = TX_DATA;
               end
            end
         end
      TX_DATA :
         begin
            ser_out = shift_out[0];
            if (samp_tick)
            begin
               nxt_tx_samp_cnt = tx_samp_cnt + 3'h1;
               if (tx_samp_cnt==3'h7)
               begin
                  nxt_shift_out= {1'b1,shift_out[7:1]}; // LS first
                  if (tx_bit_cnt==3'h7)
                     nxt_tx_state = TX_SS;
                  else
                     nxt_tx_bit_cnt = tx_bit_cnt + 3'h1;
               end
            end
         end
      endcase // Transmit FSM


      //
      // Receive FSM
      //

      // Defaults for RX FSM
      nxt_rx_state    = rx_state;
      nxt_rx_bit_cnt  = rx_bit_cnt;
      nxt_rx_samp_cnt = rx_samp_cnt;
      nxt_shift_in    = shift_in;
      rx_transfer     = 1'b0;

      case (rx_state)
      RX_IDLE :
         begin
            nxt_rx_bit_cnt  = 3'h0;
            if (samp_tick)
            begin
               // when input is low increment sample counter
               // if not: clear and thus re-start the count
               if (ser_in_sync==1'b0)
               begin
                  nxt_rx_samp_cnt = rx_samp_cnt + 3'h1;

                  // When do we decide it was really a start bit?
                  // after 4,5,6 conseq zeros???
                  if (rx_samp_cnt==3'h4) // 5??  6??
                     nxt_rx_state = RX_DATA;
               end
               else
                  nxt_rx_samp_cnt = 3'h0;

             end
         end
      RX_DATA :
         if (samp_tick)
         begin
            // let sample counter wrap around
            nxt_rx_samp_cnt = rx_samp_cnt + 3'h1;
            if (rx_samp_cnt==3'h3)
            begin
               // half way the next bit
               nxt_shift_in= {ser_in_sync,shift_in[7:1]}; // LS first
               nxt_rx_bit_cnt = rx_bit_cnt + 3'h1;
               if (rx_bit_cnt==3'h7)
                  nxt_rx_state = RX_LOAD;
            end
         end

      RX_LOAD :
         // load the data and wait for the last bit to finish
         if (samp_tick)
         begin
            rx_transfer = (rx_samp_cnt==3'h4);
            nxt_rx_samp_cnt = rx_samp_cnt + 3'h1;
            if (rx_samp_cnt==3'h7)
               nxt_rx_state = RX_STOP;
         end

      RX_STOP :
         if (samp_tick)
         begin
            // when input is high increment sample counter
            // if not: clear and thus re-start the count
            if (ser_in_sync==1'b1)
            begin
               nxt_rx_samp_cnt = rx_samp_cnt + 3'h1;

               // When do we decide it was really a stop bit?
               // after 4,5,6 consec. ones???
               // Do NOT wait for 8 as we want to be able to
               // early detect the next start bit
               // because baudrates rarely match for 100%
               if (rx_samp_cnt==3'h4)  // 5?? 6??
                  nxt_rx_state = RX_IDLE;
            end
            else
               nxt_rx_samp_cnt = 3'h0;

         end
      endcase // Receive FSM
   end // always

   // use rising edge of ref clock for baudrate
   assign ref_pulse = ~ref_edge & ref_sync;
   
   // Or you can use both edges running twice as fast:
   // assign ref_pulse = ref_edge ^ ref_sync;
   

   assign samp_tick = (baud_count==16'h0000);

  //
  // Register part
  //

   always @(posedge clk or negedge reset_n)
   begin
      if (!reset_n)
      begin
         new_baud_rate<= 1'b0;
         ser_in_meta  <= 1'b0;
         ser_in_sync  <= 1'b0;
         ref_meta     <= 1'b0;
         ref_sync     <= 1'b0;
         ref_edge     <= 1'b0;
         rec_has_data <= 1'b0;
         overflow     <= 1'b0;
         baud_count   <= 16'h0; // can set default baudrate here

         tx_state    <= TX_IDLE;
         rx_state    <= RX_IDLE;
         rx_samp_cnt <= 3'h0;
         tx_samp_cnt <= 3'h0;
         irq_enable  <= 2'b00;


         // Reset for these not strickly necessary
         shift_out   <= 8'h00;
         shift_in    <= 8'h00;
         rx_bit_cnt  <= 3'h0;
         tx_bit_cnt  <= 3'h0;
         rec_reg     <= 8'h00;
         baud_rate   <= 16'h0;

      end
      else
      begin

         // Input synchroniser
         // set false path from input to ser_in_meta
         ser_in_meta <= ser_in;
         ser_in_sync <= ser_in_meta;
         
         // Reference clock synchroniser
         // set false path from input to ref_meta
         ref_meta     <= ref_clock;
         ref_sync     <= ref_meta;
         
         // Edge detection
         ref_edge     <= ref_sync;
         
         // Baudrate
         if (ref_pulse)
         begin
            if (samp_tick | new_baud_rate)
            begin
               baud_count    <= baud_rate; // can make this a constant
               new_baud_rate <= 1'b0;
            end
            else
               baud_count <= baud_count-1'b1;
         end

         // default state machine transfers
         tx_bit_cnt  <= nxt_tx_bit_cnt;
         tx_samp_cnt <= nxt_tx_samp_cnt;
         tx_state    <= nxt_tx_state;
         shift_out   <= nxt_shift_out;
         rx_bit_cnt  <= nxt_rx_bit_cnt;
         rx_samp_cnt <= nxt_rx_samp_cnt;
         rx_state    <= nxt_rx_state;
         shift_in    <= nxt_shift_in;


         // CPU writes baudrate or control bits
         // This code is placed after the baud counter thus setting 
         // 'new_baud_rate' wins from clearing
         if (cpu_write)
         begin
            if (~data_select)
            begin
               if (baud_select)
               begin
                  baud_rate <= cpu_wdata[15:0];
                  new_baud_rate <= 1'b1;
               end
               else
                  irq_enable <= cpu_wdata[1:0];
            end
         end

         // transfer received data
         // rx_transfer and cpu data read both control the
         // 'rec_has_date' and 'overflow' bits
         if (rx_transfer)
         begin
            // data arriving
            rec_reg      <= shift_in;
            rec_has_data <= 1'b1; // we have unread data!

            // if CPU reads at the same time we are (just!) OK
            if (cpu_read & data_select)
               overflow <= 1'b0; // on read always clear overflow flag
            else
               // new data arrived when old data was not read
               if (rec_has_data)
                  overflow <= 1'b1;
         end
         else
         begin
            if (cpu_read & data_select)
            begin
               overflow     <= 1'b0; // on read always clear overflow flag
               rec_has_data <= 1'b0; // no more data waiting
            end
         end

      end // clocked

   end // always

   // Transmitter ready for next byte
wire tx_ready = (tx_state==TX_IDLE);

   //
   // Level interrupts
   //
wire tx_irq = (irq_enable[TX_IRQ] & tx_ready);
wire rx_irq = (irq_enable[RX_IRQ] & rec_has_data);

   assign irq = tx_irq | rx_irq ;

   //
   // CPU data read multiplexing
   //
   // Default on a read the status comes out which also makes it easier
   // to connect the UART to a hardware data processor.
   //
   always @( * )
   begin
      if (cpu_read)
      begin
         if (data_select)
            cpu_rdata = {8'h00,rec_reg};
         else
         if (baud_select)
            cpu_rdata = baud_rate;
         else
            // assume status reg. read
            cpu_rdata = {11'h0,tx_irq,rx_irq,tx_ready,overflow,rec_has_data};
      end
      else
         cpu_rdata = 16'h0; // allows OR-ing of data busses
   end


endmodule



