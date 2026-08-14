//////////////////////////////////////////////////////////////////////////////////
/*
 *  AtomMiner XCA200T FPGA projects
 *
 *  Pipeline latency / nonce bookkeeping check for miner.v
 *
 *  miner.v discards results until `cou_deltanonce` reaches a hand-computed
 *  constant (6'h33 for THROUGHPUT=4), then assumes the Nth result out of the
 *  pipeline belongs to the Nth nonce fed in. atomminer_odocrypt.v gates
 *  ticket2moon on a second such constant (8'hcd). Both encode the total
 *  encrypt->keccak->compare latency and are silently wrong for any other
 *  THROUGHPUT or unrolling factor.
 *
 *  This bench measures that latency directly and shadows the pipeline with a
 *  FIFO of the nonces actually captured, so the constants can be re-derived
 *  after a change instead of guessed.
 *
 *  Expected for THROUGHPUT=4 (84 rounds / 21 unrolled, 12 keccak rounds / 3):
 *      read->write latency = 204 cycles
 *      51 advances issued before the first result  -> 6'h33 at miner.v:132
 *      no results dropped, no nonce mismatches
 *
 *  Run (Icarus Verilog):
 *      iverilog -g2005 -o sim_lat src/sim/miner_latency_tb.v \
 *               src/hdl/miner.v src/hdl/encrypt.v src/hdl/keccak800.v
 *      ./sim_lat
 *
 *  Note: encrypt.v elaborates 1260 S-box instances, so this is slow --
 *  roughly a minute of wall clock per simulated clock cycle is normal. The
 *  default RESULTS_WANTED=16 keeps it to a few hours; the interesting output
 *  (the measured latency) is printed as soon as the first result appears.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version. If not, see <http://www.gnu.org/licenses/>.
 *
 */
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module miner_latency_tb;

parameter RESULTS_WANTED = 16;

reg clk = 1'b0;
always #5 clk = ~clk;

reg  [607:0] header;
reg  [255:0] target;
reg          start_hash = 1'b0;
wire         res;
wire [31:0]  nonce;

miner dut(clk, header, target, start_hash, res, nonce);

integer cyc       = 0;
integer first_adv = -1;
integer first_res = -1;
integer adv_count = 0;
integer res_count = 0;
integer dropped   = 0;
integer errors    = 0;

// shadow of the nonces actually captured into the pipeline
reg [31:0] fifo [0:1023];
integer wr = 0, rd = 0;
reg [31:0] expected;

initial
begin
	// header contents are irrelevant here, only the nonce accounting matters
	header = 608'h0;
	header[31:0]    = 32'h20000e02;
	header[63:32]   = 32'hf274793a;
	header[607:576] = 32'h1c5c279b;

	// all-ones target: every hash "passes", so the pipeline emits a result in
	// every slot and every slot can be checked
	target = {256{1'b1}};

	repeat (20) @(posedge clk);
	start_hash <= 1'b1;
end

always @(posedge clk)
begin
	cyc <= cyc + 1;

	if (start_hash)
	begin
		if (dut.advance)
		begin
			if (first_adv < 0) first_adv = cyc;
			fifo[wr] = dut.nonce_in;
			wr        = wr + 1;
			adv_count = adv_count + 1;
		end

		if (dut.has_res)
		begin
			if (first_res < 0)
			begin
				first_res = cyc;
				$display("read->write latency      = %0d cycles", first_res - first_adv);
				$display("advances before result 0 = %0d (miner.v expects 6'h33 = 51)",
				         adv_count - 1);
				$display("nonce_out_go at result 0 = %b, nonce_out = %0d",
				         dut.nonce_out_go, dut.nonce_out);
			end

			if (dut.nonce_out_go)
			begin
				expected = fifo[rd];
				if (dut.nonce_out !== expected)
				begin
					if (errors < 5)
						$display("MISMATCH @%0d: nonce_out=%0d, pipeline emitting nonce %0d",
						         cyc, dut.nonce_out, expected);
					errors = errors + 1;
				end
				res_count = res_count + 1;
			end
			else
			begin
				$display("DROPPED @%0d: nonce %0d discarded, nonce_out_go still low",
				         cyc, fifo[rd]);
				dropped = dropped + 1;
			end
			rd = rd + 1;

			if (res_count == RESULTS_WANTED) finish_up;
		end
	end
end

task finish_up;
begin
	$display("----");
	$display("results checked = %0d, dropped = %0d, mismatches = %0d",
	         res_count, dropped, errors);
	if (errors == 0 && dropped == 0 && res_count > 0)
		$display("PASS: nonce_out tracks the pipeline exactly");
	else
		$display("FAIL");
	$finish;
end
endtask

initial
begin
	#100000000;
	$display("FAIL: timed out before %0d results", RESULTS_WANTED);
	$finish;
end

endmodule
