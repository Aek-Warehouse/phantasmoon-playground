# Phantasmoon tournament bot
#
# Strategy:
#   * Solve every delivered Lights Out puzzle with a row-chasing reduction and
#     a tiny (at most 8x8) modular Gaussian elimination.  This replenishes the
#     Moonlight spent on catches without burning match-scale time.
#   * Carry close to the 100-radiance limit before returning home.  Targets use
#     a travel-first score with a bounded radiance preference and a final-pickup
#     detour test that avoids capacity-fragmentation hunts.
#   * Re-scan during every chase, so hopping or stolen wisps never leave the bot
#     driving toward a stale coordinate.
#   * Return immediately if a scored gate is opened, relock before depositing,
#     and reserve enough endgame time to bank carried radiance.
#   * Unlock the opposing gate whenever a normal route passes within range.

.equ MMIO_VELOCITY,             0xffff0000
.equ MMIO_HEADING,              0xffff0004
.equ MMIO_SELF_X,               0xffff0008
.equ MMIO_SELF_Y,               0xffff000c
.equ MMIO_OPPONENT_X,           0xffff0010
.equ MMIO_OPPONENT_Y,           0xffff0014
.equ MMIO_CYCLE_LO,             0xffff0018
.equ MMIO_MOONLIGHT,            0xffff0020
.equ MMIO_SCORE_LO,             0xffff0024
.equ MMIO_EVENTS,               0xffff002c
.equ MMIO_EVENT_ACK,            0xffff0030
.equ MMIO_PLAYER_ID,            0xffff0034
.equ MMIO_SCAN_WISPS,           0xffff0040
.equ MMIO_CATCH_WISP,           0xffff0044
.equ MMIO_DEPOSIT_WISPS,        0xffff0048
.equ MMIO_LOCK_GATE,            0xffff004c
.equ MMIO_UNLOCK_GATE,          0xffff0050
.equ MMIO_CARRIED_COUNT,        0xffff0054
.equ MMIO_CARRIED_WEIGHT,       0xffff0058
.equ MMIO_OWN_GATE,             0xffff005c
.equ MMIO_OPPONENT_GATE,        0xffff0060
.equ MMIO_OWN_GATE_LOCKED,      0xffff0064
.equ MMIO_OPPONENT_GATE_LOCKED, 0xffff0068
.equ MMIO_ATTACK,               0xffff006c
.equ MMIO_REQUEST_PUZZLE,       0xffff0070
.equ MMIO_SUBMIT_PUZZLE,        0xffff0074
.equ MMIO_PUZZLE_STATUS,        0xffff0078
.equ MMIO_MATCH_LIMIT_LO,       0xffff007c

.equ WISP_SLOT_SIZE, 24
.equ WISP_SCAN_SIZE, 292
attack_trap_handler:
  la tp, trap_scratch
  sw t0, 0(tp)
  csrrs t0, mepc, zero
  li tp, 0x13
  sw tp, 0(t0)
  addi t0, t0, 4
  csrrw zero, mepc, t0
  la tp, trap_scratch
  lw t0, 0(tp)
  mret


.section .text.init, "ax", @progbits
.global _start
.type _start, @function
_start:
  li s0, MMIO_VELOCITY
  la s1, wisp_scan
  li s2, -1
  # gp holds the stun opcode so every armed site is a single store.
  li gp, 1
  la tp, attack_trap_handler
  csrrw zero, mtvec, tp
  # tp paces the outbound opportunistic-catch scan.
  li tp, 1

  # Cache both gates.  Packed gate registers contain X in the high halfword.
  lw t0, MMIO_OWN_GATE - MMIO_VELOCITY(s0)
  srli s5, t0, 16
  slli s6, t0, 16
  srli s6, s6, 16
  lw t0, MMIO_OPPONENT_GATE - MMIO_VELOCITY(s0)
  srli s7, t0, 16
  slli s8, t0, 16
  srli s8, s8, 16

  lw t0, MMIO_PLAYER_ID - MMIO_VELOCITY(s0)
  xori t0, t0, 1
  la t1, opponent_id
  sw t0, 0(t1)

  # Keep exactly one asynchronous puzzle request in flight.
  la t0, puzzle_buffer
  sw t0, MMIO_REQUEST_PUZZLE - MMIO_VELOCITY(s0)

main_loop:
  # A scored, open gate is the highest-priority emergency.
  lw t0, MMIO_SCORE_LO - MMIO_VELOCITY(s0)
  beqz t0, main_endgame_check
  lw t1, MMIO_OWN_GATE_LOCKED - MMIO_VELOCITY(s0)
  beqz t1, return_home

main_endgame_check:
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  # If carrying, leave a distance-sensitive reserve for the trip and deposit.
  lw t0, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  beqz t0, main_puzzle_check
  lw t1, MMIO_CYCLE_LO - MMIO_VELOCITY(s0)
  lw t2, MMIO_MATCH_LIMIT_LO - MMIO_VELOCITY(s0)
  sub t2, t2, t1
  lw t3, MMIO_SELF_X - MMIO_VELOCITY(s0)
  sub t3, s5, t3
  bgez t3, main_home_dx_ok
  neg t3, t3
main_home_dx_ok:
  lw t4, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub t4, s6, t4
  bgez t4, main_home_dy_ok
  neg t4, t4
main_home_dy_ok:
  # Distance estimate = max + 3*min/8; full-speed travel is about 500 cycles/u.
  bge t3, t4, main_home_dx_larger
  slli t5, t3, 1
  add t5, t5, t3
  srli t5, t5, 3
  add t5, t5, t4
  j main_home_distance_ready
main_home_dx_larger:
  slli t5, t4, 1
  add t5, t5, t4
  srli t5, t5, 3
  add t5, t5, t3
main_home_distance_ready:
  li t6, 500
  mul t5, t5, t6
  bleu t2, t5, return_home

main_puzzle_check:
  lw t0, MMIO_EVENTS - MMIO_VELOCITY(s0)
  andi t0, t0, 1
  beqz t0, main_opportunistic_raid
  lw t0, MMIO_MOONLIGHT - MMIO_VELOCITY(s0)
  bnez t0, main_opportunistic_raid
  sw zero, 0(s0)
  jal ra, solve_puzzle
  j main_loop

main_opportunistic_raid:
  # A route that naturally crosses the enemy gate gets a free unlock attempt.
  lw t0, MMIO_OPPONENT_GATE_LOCKED - MMIO_VELOCITY(s0)
  beqz t0, main_resource_check
  lw t1, MMIO_SELF_X - MMIO_VELOCITY(s0)
  sub t1, s7, t1
  bgez t1, raid_dx_ok
  neg t1, t1
raid_dx_ok:
  lw t2, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub t2, s8, t2
  bgez t2, raid_dy_ok
  neg t2, t2
raid_dy_ok:
  mul t3, t1, t1
  mul t4, t2, t2
  add t3, t3, t4
  li t4, 935
  bgtu t3, t4, main_resource_check
  la t0, opponent_id
  lw t0, 0(t0)
  sw t0, MMIO_UNLOCK_GATE - MMIO_VELOCITY(s0)
  j main_resource_check

main_resource_check:
  lw t0, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  li t1, 20
  bgeu t0, t1, return_home
  lw t0, MMIO_CARRIED_WEIGHT - MMIO_VELOCITY(s0)
  li t1, 101
  bgeu t0, t1, return_home
  lw t0, MMIO_MOONLIGHT - MMIO_VELOCITY(s0)
  bnez t0, select_target

  # A ready puzzle will be handled above.  With no Moonlight, wait for the
  # active request instead of taking a useless trip.
  sw zero, 0(s0)
  j main_loop

select_target:
  sw s1, MMIO_SCAN_WISPS - MMIO_VELOCITY(s0)
  lw a0, 0(s1)
  addi a1, s1, 4
  li a2, 0
  li a4, 0x7fffffff           # best effective cost
  li s2, -1
  lw a5, MMIO_SELF_X - MMIO_VELOCITY(s0)
  lw a6, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub t0, s5, a5
  bgez t0, select_home_dx_ok
  neg t0, t0
select_home_dx_ok:
  sub t1, s6, a6
  bgez t1, select_home_dy_ok
  neg t1, t1
select_home_dy_ok:
  bge t0, t1, select_home_dx_larger
  slli a7, t0, 1
  add a7, a7, t0
  srli a7, a7, 3
  add a7, a7, t1
  j select_home_distance_ready
select_home_dx_larger:
  slli a7, t1, 1
  add a7, a7, t1
  srli a7, a7, 3
  add a7, a7, t0
select_home_distance_ready:
  lw s9, MMIO_CARRIED_WEIGHT - MMIO_VELOCITY(s0)

select_loop:
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  beq a2, a0, select_done
  lhu t2, 12(a1)
  add t5, s9, t2
  li t6, 100
  bgtu t5, t6, select_next

  lw t0, 4(a1)
  lw t1, 8(a1)

  # Approximate Euclidean distance by max(|dx|,|dy|) + 3*min/8.
  sub t3, t0, a5
  bgez t3, select_self_dx_ok
  neg t3, t3
select_self_dx_ok:
  sub t4, t1, a6
  bgez t4, select_self_dy_ok
  neg t4, t4
select_self_dy_ok:
  bge t3, t4, select_self_dx_larger
  slli t5, t3, 1
  add t5, t5, t3
  srli t5, t5, 3
  add t3, t4, t5
  j select_self_distance_done
select_self_dx_larger:
  slli t5, t4, 1
  add t5, t5, t4
  srli t5, t5, 3
  add t3, t3, t5
select_self_distance_done:
  # Do not commit to a wisp that is scheduled to hop before arrival.  A hop can
  # displace it by 100 units.  The engine's scan serializes offset 20 as the
  # remaining-cycle countdown (despite the rules calling it a cycle low word).
  addi t5, t3, -28
  blez t5, select_hop_safe
  li t6, 500
  mul t5, t5, t6
  lw t6, 20(a1)
  bgeu t6, t5, select_hop_safe
  addi t3, t3, 40            # expected route disruption, not a hard veto
select_hop_safe:
  # At low load, minimize travel per unit of radiance.  Scaling the
  # numerator retains useful integer resolution for radiance values 5..20.
  slli t4, t3, 3
  divu t4, t4, t2
  li t5, 80
  bltu s9, t5, select_compare

  # At or above 80 weight, judge a final pickup by its true detour on the way home:
  # self->wisp + wisp->gate - self->gate, less its radiance benefit.
  sub t5, t0, s5
  bgez t5, select_finish_dx_ok
  neg t5, t5
select_finish_dx_ok:
  sub t6, t1, s6
  bgez t6, select_finish_dy_ok
  neg t6, t6
select_finish_dy_ok:
  bge t5, t6, select_finish_dx_larger
  slli t4, t5, 1
  add t5, t5, t4
  srli t5, t5, 3
  add t5, t5, t6
  j select_finish_distance_ready
select_finish_dx_larger:
  slli t4, t6, 1
  add t6, t6, t4
  srli t6, t6, 3
  add t5, t5, t6
select_finish_distance_ready:
  add t4, t3, t5
  sub t4, t4, a7
  li t5, 8
  mul t5, t2, t5
  sub t4, t4, t5

select_compare:
  li t5, -1
  beq s2, t5, select_take
  bge t4, a4, select_next

select_take:
  mv a4, t4
  lw s2, 0(a1)
  lw s3, 4(a1)
  lw s4, 8(a1)

select_next:
  addi a1, a1, WISP_SLOT_SIZE
  addi a2, a2, 1
  j select_loop

select_done:
  li t0, -1
  beq s2, t0, select_no_target
  li t0, 80
  bltu s9, t0, navigate_target
  # Only extend a nearly-full trip when the added pickup pays for its detour.
  li t0, 20
  bgt a4, t0, return_home
  j navigate_target
select_no_target:
  lw t0, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  bnez t0, return_home
  j main_loop

navigate_target:
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  # During the final phase, abort a chase exactly when the live distance-to-gate
  # reserve is consumed.  This banks partial loads without a blanket idle tail.
  lw t0, MMIO_CYCLE_LO - MMIO_VELOCITY(s0)
  lw t1, MMIO_MATCH_LIMIT_LO - MMIO_VELOCITY(s0)
  sub t1, t1, t0
  li t2, 400000
  bgtu t1, t2, nav_gate_emergency_check
  lw t2, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  beqz t2, nav_gate_emergency_check
  lw t2, MMIO_SELF_X - MMIO_VELOCITY(s0)
  sub t2, s5, t2
  bgez t2, nav_end_dx_ok
  neg t2, t2
nav_end_dx_ok:
  lw t3, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub t3, s6, t3
  bgez t3, nav_end_dy_ok
  neg t3, t3
nav_end_dy_ok:
  bge t2, t3, nav_end_dx_larger
  slli t4, t2, 1
  add t4, t4, t2
  srli t4, t4, 3
  add t4, t4, t3
  j nav_end_distance_ready
nav_end_dx_larger:
  slli t4, t3, 1
  add t4, t4, t3
  srli t4, t4, 3
  add t4, t4, t2
nav_end_distance_ready:
  li t5, 500
  mul t4, t4, t5
  bleu t1, t4, return_home

nav_gate_emergency_check:
  # Bank a useful load when an ordinary pursuit line already crosses home.
  # Do not brake or divert: failed edge-of-radius writes are harmless and the
  # next navigation refresh retries while the bot remains in range.
  lw t0, MMIO_CARRIED_WEIGHT - MMIO_VELOCITY(s0)
  li t1, 1
  bltu t0, t1, nav_driveby_bank_done
  lw t0, MMIO_OWN_GATE_LOCKED - MMIO_VELOCITY(s0)
  beqz t0, nav_driveby_bank_done
  lw t1, MMIO_SELF_X - MMIO_VELOCITY(s0)
  sub t1, s5, t1
  lw t2, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub t2, s6, t2
  mul t3, t1, t1
  mul t4, t2, t2
  add t3, t3, t4
  li t4, 935
  bgtu t3, t4, nav_driveby_bank_done
  lw t0, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  sw t0, MMIO_DEPOSIT_WISPS - MMIO_VELOCITY(s0)
nav_driveby_bank_done:
  # Unlike the main-loop check, this catches a gate crossed between wisps.
  # Movement continues throughout, so a failed/protected attempt costs no detour.
  lw t0, MMIO_OPPONENT_GATE_LOCKED - MMIO_VELOCITY(s0)
  beqz t0, nav_own_gate_emergency
  lw t1, MMIO_SELF_X - MMIO_VELOCITY(s0)
  sub t1, s7, t1
  lw t2, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub t2, s8, t2
  mul t3, t1, t1
  mul t4, t2, t2
  add t3, t3, t4
  li t4, 935
  bgtu t3, t4, nav_own_gate_emergency
  la t0, opponent_id
  lw t0, 0(t0)
  sw t0, MMIO_UNLOCK_GATE - MMIO_VELOCITY(s0)
nav_own_gate_emergency:
  # Interrupt a chase for an exposed scored gate or a ready puzzle.
  lw t0, MMIO_SCORE_LO - MMIO_VELOCITY(s0)
  beqz t0, nav_puzzle_check
  lw t1, MMIO_OWN_GATE_LOCKED - MMIO_VELOCITY(s0)
  beqz t1, return_home
nav_puzzle_check:
  j nav_refresh_target

nav_refresh_target:
  sw s1, MMIO_SCAN_WISPS - MMIO_VELOCITY(s0)
  lw a0, 0(s1)
  addi a1, s1, 4
  li a2, 0
nav_find_id:
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  beq a2, a0, main_loop       # caught by the opponent or otherwise replaced
  lw t0, 0(a1)
  beq t0, s2, nav_target_found
  addi a1, a1, WISP_SLOT_SIZE
  addi a2, a2, 1
  j nav_find_id

nav_target_found:
  lw s3, 4(a1)
  lw s4, 8(a1)
  lw t0, MMIO_SELF_X - MMIO_VELOCITY(s0)
  lw t1, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub a0, s3, t0              # signed dx
  sub a1, s4, t1              # signed dy
  mv t2, a0
  bgez t2, nav_abs_dx_ok
  neg t2, t2
nav_abs_dx_ok:
  mv t3, a1
  bgez t3, nav_abs_dy_ok
  neg t3, t3
nav_abs_dy_ok:
  # MMIO coordinates are integer samples of fixed-point positions.  Squared
  # threshold 1100 starts attempts just outside the legal 32-unit circle; the
  # carried-count check below makes those early attempts safe.
  mul t4, t2, t2
  mul t5, t3, t3
  add t4, t4, t5
  li t5, 1100
  bgtu t4, t5, nav_keep_moving
  # Integer MMIO samples can understate the true fixed-point distance.  Check
  # the carried count after resolution so an early attempt cannot stop forever.
  lw t6, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  sw s2, MMIO_CATCH_WISP - MMIO_VELOCITY(s0)
  lw t5, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  beq t5, t6, navigate_target
  j main_loop

nav_keep_moving:
  jal ra, set_course
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  # A wisp the chase already drives through is free radiance: the heading is
  # unchanged, so this costs instructions but no travel.
  addi tp, tp, -1
  bnez tp, nav_route_catch_skip
  li tp, 16
  jal ra, home_route_catch
  bnez a0, main_loop
nav_route_catch_skip:
  lw t0, MMIO_EVENTS - MMIO_VELOCITY(s0)
  andi t0, t0, 1
  beqz t0, navigate_target
  lw t0, MMIO_MOONLIGHT - MMIO_VELOCITY(s0)
  li t1, 20
  bgt t0, t1, navigate_target
  jal ra, solve_puzzle
  j navigate_target

home_route_catch:
  # Heading and speed are already set directly toward the fixed home gate, so
  # this scan consumes instruction slots without adding travel distance.
  lw t0, MMIO_MOONLIGHT - MMIO_VELOCITY(s0)
  beqz t0, home_route_catch_done
  lw a7, MMIO_CARRIED_WEIGHT - MMIO_VELOCITY(s0)
  li t0, 100
  bgeu a7, t0, home_route_catch_done
  sw s1, MMIO_SCAN_WISPS - MMIO_VELOCITY(s0)
  lw a0, 0(s1)
  addi a1, s1, 4
  lw a2, MMIO_SELF_X - MMIO_VELOCITY(s0)
  lw a3, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  li a4, 0
  li a5, -1
  li a6, 0
home_route_catch_loop:
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  beq a4, a0, home_route_catch_scan_done
  lhu t0, 12(a1)
  add t1, a7, t0
  li t6, 100
  bgtu t1, t6, home_route_catch_next
  lw t2, 4(a1)
  sub t2, t2, a2
  mul t2, t2, t2
  lw t3, 8(a1)
  sub t3, t3, a3
  mul t3, t3, t3
  add t2, t2, t3
  li t6, 1024
  bgtu t2, t6, home_route_catch_next
  bleu t0, a6, home_route_catch_next
  mv a6, t0
  lw a5, 0(a1)
home_route_catch_next:
  addi a1, a1, WISP_SLOT_SIZE
  addi a4, a4, 1
  j home_route_catch_loop
home_route_catch_scan_done:
  li t0, -1
  beq a5, t0, home_route_catch_done
home_route_catch_attempt:
  sw a5, MMIO_CATCH_WISP - MMIO_VELOCITY(s0)
  # a0 = 1 when the load actually changed.  The homebound caller ignores this;
  # the outbound caller needs it because a pickup can invalidate its target.
  lw t0, MMIO_CARRIED_WEIGHT - MMIO_VELOCITY(s0)
  bne t0, a7, home_route_catch_hit
home_route_catch_done:
  li a0, 0
  ret
home_route_catch_hit:
  li a0, 1
  ret

return_home:
  # Gate coordinates are fixed, so this loop can be lean and deterministic.
  lw t0, MMIO_SELF_X - MMIO_VELOCITY(s0)
  lw t1, MMIO_SELF_Y - MMIO_VELOCITY(s0)
  sub a0, s5, t0
  sub a1, s6, t1
  mv t2, a0
  bgez t2, home_abs_dx_ok
  neg t2, t2
home_abs_dx_ok:
  mv t3, a1
  bgez t3, home_abs_dy_ok
  neg t3, t3
home_abs_dy_ok:
  mul t4, t2, t2
  mul t5, t3, t3
  add t4, t4, t5
  li t5, 935
  bgtu t4, t5, home_keep_moving

  sw zero, 0(s0)
home_lock_first:
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  lw t0, MMIO_OWN_GATE_LOCKED - MMIO_VELOCITY(s0)
  bnez t0, home_deposit
  # A burst with a nontrivial period prevents an attacker from phase-locking
  # every owner relock against a simultaneous unlock forever.
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  sw zero, MMIO_LOCK_GATE - MMIO_VELOCITY(s0)
  j home_lock_first

home_deposit:
  lw t0, MMIO_CARRIED_COUNT - MMIO_VELOCITY(s0)
  beqz t0, home_post_deposit
  sw t0, MMIO_DEPOSIT_WISPS - MMIO_VELOCITY(s0)
  j home_deposit

home_post_deposit:
  # Close again if an opponent managed to unlock on the deposit cycle.
  lw t0, MMIO_OWN_GATE_LOCKED - MMIO_VELOCITY(s0)
  beqz t0, home_lock_first
  j main_loop

home_keep_moving:
  jal ra, set_course
  sw gp, MMIO_ATTACK - MMIO_VELOCITY(s0)
  jal ra, home_route_catch
  lw t0, MMIO_EVENTS - MMIO_VELOCITY(s0)
  andi t0, t0, 1
  beqz t0, return_home
  lw t0, MMIO_MOONLIGHT - MMIO_VELOCITY(s0)
  li t1, 20
  bgt t0, t1, return_home
  jal ra, solve_puzzle
  j return_home

# Set one of 32 compass headings. Integer slope tests keep maximum steering
# error near six degrees without an expensive atan routine.
# Inputs: a0 = signed dx, a1 = signed dy.  Preserves every saved register.
set_course:
  mv t0, a0
  bgez t0, course_abs_dx_ok
  neg t0, t0
course_abs_dx_ok:
  mv t1, a1
  bgez t1, course_abs_dy_ok
  neg t1, t1
course_abs_dy_ok:
  bge t0, t1, course_x_major

  # Y-major octant boundaries approximate 84.5, 73.5, 63.5, and 50.5 deg.
  slli t2, t0, 3
  slli t3, t0, 1
  add t2, t2, t3             # 10*|dx|
  bleu t2, t1, course_base_90
  slli t3, t1, 1
  add t3, t3, t1             # 3*|dy|
  bleu t2, t3, course_base_79
  slli t2, t0, 1             # 2*|dx|
  bleu t2, t1, course_base_68
  slli t2, t0, 2
  add t2, t2, t0             # 5*|dx|
  slli t3, t1, 2             # 4*|dy|
  bleu t2, t3, course_base_56
  li t3, 45
  j course_apply_quadrant

course_x_major:
  # Symmetric first-octant boundaries near 5.5, 16.5, 26.5, and 39.5 deg.
  slli t2, t1, 3
  slli t3, t1, 1
  add t2, t2, t3             # 10*|dy|
  bleu t2, t0, course_base_0
  slli t3, t0, 1
  add t3, t3, t0             # 3*|dx|
  bleu t2, t3, course_base_11
  slli t2, t1, 1             # 2*|dy|
  bleu t2, t0, course_base_22
  slli t2, t1, 2
  add t2, t2, t1             # 5*|dy|
  slli t3, t0, 2             # 4*|dx|
  bleu t2, t3, course_base_34
  li t3, 45
  j course_apply_quadrant

course_base_0:
  li t3, 0
  j course_apply_quadrant
course_base_11:
  li t3, 11
  j course_apply_quadrant
course_base_22:
  li t3, 22
  j course_apply_quadrant
course_base_34:
  li t3, 34
  j course_apply_quadrant
course_base_56:
  li t3, 56
  j course_apply_quadrant
course_base_68:
  li t3, 68
  j course_apply_quadrant
course_base_79:
  li t3, 79
  j course_apply_quadrant
course_base_90:
  li t3, 90

course_apply_quadrant:
  bgez a0, course_x_sign_done
  li t2, 180
  sub t3, t2, t3
course_x_sign_done:
  bgez a1, course_write
  beqz t3, course_write
  li t2, 360
  sub t3, t2, t3

course_write:
  sw t3, MMIO_HEADING - MMIO_VELOCITY(s0)
  li t3, 10
  sw t3, 0(s0)
  ret
# Solve the delivered puzzle.  Row chasing reduces the full board to a linear
# system whose dimension is only the number of columns (at most eight).  This
# is much cheaper than eliminating a 64x64 Lights Out matrix.
solve_puzzle:
  addi sp, sp, -64
  sw ra, 60(sp)
  sw s0, 56(sp)
  sw s1, 52(sp)
  sw s2, 48(sp)
  sw s3, 44(sp)
  sw s4, 40(sp)
  sw s5, 36(sp)
  sw s6, 32(sp)
  sw s7, 28(sp)
  sw s8, 24(sp)
  sw s9, 20(sp)
  sw s10, 16(sp)
  sw s11, 12(sp)

  la s0, puzzle_buffer
  lw t0, 4(s0)
  la t1, puzzle_rows
  sw t0, 0(t1)
  lw s1, 8(s0)               # columns
  la t1, puzzle_cols
  sw s1, 0(t1)
  lw s2, 12(s0)              # colors
  la t1, puzzle_colors
  sw s2, 0(t1)

  la t0, first_row
  sw zero, 0(t0)
  sw zero, 4(t0)

  # Base last-row residual with a zero first action row.
  addi a0, s0, 16
  la a1, first_row
  la a2, chase_actions
  la a3, chase_residual
  jal ra, chase_grid

  # Both color systems use precomputed generalized inverses for each dimension.
  # This avoids doing modular elimination in the one-instruction-per-cycle
  # guest.  The generic eliminator below is retained as a documented fallback.
  j solve_precomputed_table

  # Clear the 8 rows of the 12-byte-stride augmented matrix.
  la s3, small_matrix
  mv t0, s3
  li t1, 24
solve_clear_matrix:
  sw zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, solve_clear_matrix

  # RHS = -base_residual (mod colors).
  li s4, 0
  la t0, chase_residual
solve_fill_rhs:
  bge s4, s1, solve_basis_start
  lbu t1, 0(t0)
  beqz t1, solve_rhs_ready
  sub t1, s2, t1
solve_rhs_ready:
  slli t2, s4, 3
  slli t3, s4, 2
  add t2, t2, t3
  add t2, t2, s3
  add t2, t2, s1
  sb t1, 0(t2)
  addi t0, t0, 1
  addi s4, s4, 1
  j solve_fill_rhs

solve_basis_start:
  li s4, 0                    # basis column
solve_basis_loop:
  bge s4, s1, solve_elimination_start
  la t0, first_row
  add t0, t0, s4
  li t1, 1
  sb t1, 0(t0)

  li a0, 0                    # zero board
  la a1, first_row
  la a2, chase_actions
  la a3, basis_residual
  jal ra, chase_grid

  la t0, first_row
  add t0, t0, s4
  sb zero, 0(t0)
  li s5, 0                    # matrix row
  la t1, basis_residual
solve_store_basis:
  bge s5, s1, solve_next_basis
  lbu t2, 0(t1)
  slli t3, s5, 3
  slli t4, s5, 2
  add t3, t3, t4
  add t3, t3, s3
  add t3, t3, s4
  sb t2, 0(t3)
  addi t1, t1, 1
  addi s5, s5, 1
  j solve_store_basis
solve_next_basis:
  addi s4, s4, 1
  j solve_basis_loop

solve_precomputed_table:
  # Convert the base residual in place to b = -residual (mod colors).
  la t0, chase_residual
  li t1, 0
solve_ternary_rhs_loop:
  bge t1, s1, solve_ternary_choose_table
  lbu t2, 0(t0)
  beqz t2, solve_ternary_rhs_next
  sub t2, s2, t2
  sb t2, 0(t0)
solve_ternary_rhs_next:
  addi t0, t0, 1
  addi t1, t1, 1
  j solve_ternary_rhs_loop

solve_ternary_choose_table:
  la t0, puzzle_rows
  lw t0, 0(t0)
  addi t0, t0, -5
  slli t0, t0, 2
  add t0, t0, s1
  addi t0, t0, -5
  slli t0, t0, 6
  li t1, 2
  beq s2, t1, solve_choose_binary_table
  la s3, ternary_inverse_tables
  j solve_table_pointer_ready
solve_choose_binary_table:
  la s3, binary_inverse_tables_v2
solve_table_pointer_ready:
  add s3, s3, t0
  la t0, first_row
  sw zero, 0(t0)
  sw zero, 4(t0)
  li s4, 0                    # output component
solve_ternary_output_loop:
  bge s4, s1, solve_final_chase
  slli t0, s4, 3
  add t0, s3, t0             # padded 8-byte table row
  la t1, chase_residual
  li s5, 0
  li s7, 0
solve_ternary_dot_loop:
  bge s5, s1, solve_ternary_dot_done
  lbu t2, 0(t0)
  lbu t3, 0(t1)
  mul t2, t2, t3
  add s7, s7, t2
solve_ternary_reduce_dot:
  blt s7, s2, solve_ternary_dot_next
  sub s7, s7, s2
  j solve_ternary_reduce_dot
solve_ternary_dot_next:
  addi t0, t0, 1
  addi t1, t1, 1
  addi s5, s5, 1
  j solve_ternary_dot_loop
solve_ternary_dot_done:
  la t0, first_row
  add t0, t0, s4
  sb s7, 0(t0)
  addi s4, s4, 1
  j solve_ternary_output_loop

solve_elimination_start:
  li s4, 0                    # rank
  li s5, 0                    # column
  la s6, pivot_columns

solve_column_loop:
  bge s5, s1, solve_back_start
  bge s4, s1, solve_back_start
  mv s7, s4                   # pivot search row
solve_find_pivot:
  bge s7, s1, solve_no_pivot
  slli t0, s7, 3
  slli t1, s7, 2
  add t0, t0, t1
  add t0, t0, s3
  add t0, t0, s5
  lbu t1, 0(t0)
  bnez t1, solve_pivot_found
  addi s7, s7, 1
  j solve_find_pivot

solve_no_pivot:
  addi s5, s5, 1
  j solve_column_loop

solve_pivot_found:
  # Swap the useful suffix of the pivot row into the rank row.
  beq s7, s4, solve_pivot_in_place
  slli t0, s7, 3
  slli t1, s7, 2
  add t0, t0, t1
  add t0, t0, s3
  slli t2, s4, 3
  slli t3, s4, 2
  add t2, t2, t3
  add t2, t2, s3
  mv t4, s5
solve_swap_loop:
  bgt t4, s1, solve_pivot_in_place
  add t5, t0, t4
  add t6, t2, t4
  lbu a0, 0(t5)
  lbu a1, 0(t6)
  sb a1, 0(t5)
  sb a0, 0(t6)
  addi t4, t4, 1
  j solve_swap_loop

solve_pivot_in_place:
  slli t0, s4, 3
  slli t1, s4, 2
  add t0, t0, t1
  add s8, t0, s3            # pivot row base
  add t1, s8, s5
  lbu t2, 0(t1)
  li t3, 2
  bne t2, t3, solve_eliminate_start
  bne s2, t3, solve_eliminate_start
  # In GF(3), inverse(2)=2.  Multiplication by two maps v to 3-v.
  mv t4, s5
solve_normalize_loop:
  bgt t4, s1, solve_eliminate_start
  add t5, s8, t4
  lbu t6, 0(t5)
  beqz t6, solve_normalize_next
  sub t6, s2, t6
  sb t6, 0(t5)
solve_normalize_next:
  addi t4, t4, 1
  j solve_normalize_loop

solve_eliminate_start:
  addi s7, s4, 1
solve_eliminate_row:
  bge s7, s1, solve_record_pivot
  slli t0, s7, 3
  slli t1, s7, 2
  add t0, t0, t1
  add s9, t0, s3            # row base
  add t1, s9, s5
  lbu s10, 0(t1)            # elimination factor
  beqz s10, solve_next_eliminate_row
  mv s11, s5
solve_eliminate_cells:
  bgt s11, s1, solve_next_eliminate_row
  add t2, s9, s11
  add t3, s8, s11
  lbu t4, 0(t2)
  lbu t5, 0(t3)
  mul t5, t5, s10
  blt t5, s2, solve_product_reduced
  sub t5, t5, s2
solve_product_reduced:
  sub t4, t4, t5
  bgez t4, solve_cell_nonnegative
  add t4, t4, s2
solve_cell_nonnegative:
  sb t4, 0(t2)
  addi s11, s11, 1
  j solve_eliminate_cells
solve_next_eliminate_row:
  addi s7, s7, 1
  j solve_eliminate_row

solve_record_pivot:
  add t0, s6, s4
  sb s5, 0(t0)
  addi s4, s4, 1
  addi s5, s5, 1
  j solve_column_loop

solve_back_start:
  la t0, first_row
  sw zero, 0(t0)
  sw zero, 4(t0)
  addi s4, s4, -1
solve_back_row:
  bltz s4, solve_final_chase
  add t0, s6, s4
  lbu s5, 0(t0)             # pivot column
  slli t0, s4, 3
  slli t1, s4, 2
  add t0, t0, t1
  add s8, t0, s3
  add t1, s8, s1
  lbu s7, 0(t1)             # current RHS value
  addi s9, s5, 1
solve_back_cells:
  bge s9, s1, solve_back_store
  add t0, s8, s9
  lbu t1, 0(t0)
  la t2, first_row
  add t2, t2, s9
  lbu t3, 0(t2)
  mul t1, t1, t3
  blt t1, s2, solve_back_product_ok
  sub t1, t1, s2
solve_back_product_ok:
  sub s7, s7, t1
  bgez s7, solve_back_value_ok
  add s7, s7, s2
solve_back_value_ok:
  addi s9, s9, 1
  j solve_back_cells
solve_back_store:
  la t0, first_row
  add t0, t0, s5
  sb s7, 0(t0)
  addi s4, s4, -1
  j solve_back_row

solve_final_chase:
  addi a0, s0, 16
  la a1, first_row
  la a2, puzzle_solution
  addi a2, a2, 4
  la a3, chase_residual
  jal ra, chase_grid

  lw t0, 0(s0)
  la t1, puzzle_solution
  sw t0, 0(t1)
  li t2, MMIO_SUBMIT_PUZZLE
  sw t1, 0(t2)
  li t0, 1
  li t2, MMIO_EVENT_ACK
  sw t0, 0(t2)
  la t0, puzzle_buffer
  li t2, MMIO_REQUEST_PUZZLE
  sw t0, 0(t2)

  lw s11, 12(sp)
  lw s10, 16(sp)
  lw s9, 20(sp)
  lw s8, 24(sp)
  lw s7, 28(sp)
  lw s6, 32(sp)
  lw s5, 36(sp)
  lw s4, 40(sp)
  lw s3, 44(sp)
  lw s2, 48(sp)
  lw s1, 52(sp)
  lw s0, 56(sp)
  lw ra, 60(sp)
  addi sp, sp, 64
  ret

# Apply the row-chasing recurrence.
#   a0: board pointer, or zero for an all-zero board
#   a1: first action row
#   a2: 64-byte action output
#   a3: final-row residual output
chase_grid:
  addi sp, sp, -64
  sw ra, 60(sp)
  sw s0, 56(sp)
  sw s1, 52(sp)
  sw s2, 48(sp)
  sw s3, 44(sp)
  sw s4, 40(sp)
  sw s5, 36(sp)
  sw s6, 32(sp)
  sw s7, 28(sp)
  sw s8, 24(sp)
  sw s9, 20(sp)
  sw s10, 16(sp)
  sw s11, 12(sp)

  mv s0, a0
  mv s1, a1
  mv s2, a2
  mv s3, a3
  la t0, puzzle_rows
  lw s4, 0(t0)
  la t0, puzzle_cols
  lw s5, 0(t0)
  la t0, puzzle_colors
  lw s6, 0(t0)

  mv t0, s2
  li t1, 16
chase_clear_actions:
  sw zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, chase_clear_actions

  li s7, 0
chase_copy_first:
  bge s7, s5, chase_rows_start
  add t0, s1, s7
  lbu t1, 0(t0)
  add t0, s2, s7
  sb t1, 0(t0)
  addi s7, s7, 1
  j chase_copy_first

chase_rows_start:
  li s7, 1                    # row being generated
chase_row_loop:
  bge s7, s4, chase_final_row
  addi t0, s7, -1
  mul s9, t0, s5             # base index of row above
  li s8, 0                    # column
chase_column_loop:
  bge s8, s5, chase_next_row
  add s10, s9, s8            # index of cell being cleared
  li s11, 0                  # neighborhood sum
  beqz s0, chase_no_board_cell
  add t0, s0, s10
  lbu t1, 0(t0)
  add s11, s11, t1
chase_no_board_cell:
  add t0, s2, s10
  lbu t1, 0(t0)              # action directly above
  add s11, s11, t1
  li t2, 1
  ble s7, t2, chase_no_two_rows_up
  sub t0, s10, s5
  add t0, s2, t0
  lbu t1, 0(t0)
  add s11, s11, t1
chase_no_two_rows_up:
  beqz s8, chase_no_left
  addi t0, s10, -1
  add t0, s2, t0
  lbu t1, 0(t0)
  add s11, s11, t1
chase_no_left:
  addi t0, s8, 1
  bge t0, s5, chase_no_right
  addi t0, s10, 1
  add t0, s2, t0
  lbu t1, 0(t0)
  add s11, s11, t1
chase_no_right:
chase_reduce_sum:
  blt s11, s6, chase_sum_reduced
  sub s11, s11, s6
  j chase_reduce_sum
chase_sum_reduced:
  beqz s11, chase_action_ready
  sub s11, s6, s11
chase_action_ready:
  add t0, s10, s5           # same column in the generated row
  add t0, s2, t0
  sb s11, 0(t0)
  addi s8, s8, 1
  j chase_column_loop
chase_next_row:
  addi s7, s7, 1
  j chase_row_loop

chase_final_row:
  addi t0, s4, -1
  mul s9, t0, s5            # last-row base index
  li s8, 0
chase_residual_loop:
  bge s8, s5, chase_done
  add s10, s9, s8
  li s11, 0
  beqz s0, chase_final_no_board
  add t0, s0, s10
  lbu t1, 0(t0)
  add s11, s11, t1
chase_final_no_board:
  add t0, s2, s10
  lbu t1, 0(t0)
  add s11, s11, t1
  sub t0, s10, s5
  add t0, s2, t0
  lbu t1, 0(t0)
  add s11, s11, t1
  beqz s8, chase_final_no_left
  addi t0, s10, -1
  add t0, s2, t0
  lbu t1, 0(t0)
  add s11, s11, t1
chase_final_no_left:
  addi t0, s8, 1
  bge t0, s5, chase_final_no_right
  addi t0, s10, 1
  add t0, s2, t0
  lbu t1, 0(t0)
  add s11, s11, t1
chase_final_no_right:
  blt s11, s6, chase_final_reduced
  sub s11, s11, s6
  j chase_final_no_right
chase_final_reduced:
  add t0, s3, s8
  sb s11, 0(t0)
  addi s8, s8, 1
  j chase_residual_loop

chase_done:
  lw s11, 12(sp)
  lw s10, 16(sp)
  lw s9, 20(sp)
  lw s8, 24(sp)
  lw s7, 28(sp)
  lw s6, 32(sp)
  lw s5, 36(sp)
  lw s4, 40(sp)
  lw s3, 44(sp)
  lw s2, 48(sp)
  lw s1, 52(sp)
  lw s0, 56(sp)
  lw ra, 60(sp)
  addi sp, sp, 64
  ret

.size _start, . - _start

.section .rodata
.balign 4
# 16 padded 8x8 generalized inverses, indexed by (rows-5)*4+(cols-5).
# Binary counterparts in the same padded/indexed layout.
binary_inverse_tables:
  .byte 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0
  .byte 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 1, 0
  .byte 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1
  .byte 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 0
  .byte 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 0
  .byte 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 1, 1, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0
  .byte 0, 0, 1, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 0
  .byte 1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0
  .byte 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0
  .byte 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0
  .byte 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0
  .byte 1, 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0
# Correct GF(2) generalized inverses.
binary_inverse_tables_v2:
  .byte 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0
  .byte 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0
  .byte 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0
  .byte 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0
  .byte 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0
  .byte 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0
  .byte 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0
  .byte 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1
  .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0
ternary_inverse_tables:
  .byte 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 2, 0, 0, 2, 0, 0, 1, 0, 1, 2, 2, 0, 0, 0, 2, 1, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 1, 2, 0, 0
  .byte 0, 2, 2, 1, 0, 1, 0, 0, 2, 0, 0, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 2, 2, 0, 2, 2, 0, 0, 2, 0, 0, 2, 2, 2, 0, 0, 2, 0, 1, 2, 1, 0, 0, 0, 0, 2, 2, 2, 2, 2, 0, 0
  .byte 2, 2, 1, 2, 2, 2, 0, 0, 2, 2, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 0, 1, 1, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 1, 2, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 2, 0, 2, 1, 2, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 2, 1, 0, 1, 2, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0
  .byte 2, 1, 2, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 2, 2, 0, 1, 1, 0, 0, 2, 2, 2, 0, 1, 1, 0, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 0, 0
  .byte 1, 1, 0, 2, 2, 2, 0, 0, 1, 1, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 2, 2, 2, 1, 0, 0, 0, 2, 2, 1, 0, 2, 1, 0, 0, 2, 1, 0, 1, 0, 2, 1, 0, 2, 0, 1, 0, 1, 0, 2, 0
  .byte 1, 2, 0, 1, 0, 1, 2, 0, 0, 1, 2, 0, 1, 2, 2, 0, 0, 0, 1, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 1, 1, 1, 1, 1, 1, 2, 1, 1, 2, 2, 2, 2, 0, 1, 1, 2, 2, 0, 0, 1, 2, 1, 1, 2, 0, 0, 2, 0, 2, 1
  .byte 1, 2, 0, 2, 0, 0, 2, 1, 1, 2, 1, 0, 0, 2, 2, 1, 1, 0, 2, 2, 2, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 0
  .byte 2, 2, 0, 1, 0, 0, 0, 0, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 2, 1, 1, 0, 0, 0, 1, 2, 1, 2, 1, 1, 0, 0, 1, 1, 2, 1, 2, 1, 0, 0
  .byte 0, 1, 1, 2, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 1, 1, 1, 1, 2, 2, 0, 1, 1, 2, 2, 0, 0, 2, 0, 1, 2, 2, 1, 1, 0, 1, 0, 1, 2, 1, 1, 1, 2, 1, 0
  .byte 1, 0, 1, 1, 2, 2, 1, 0, 2, 0, 0, 2, 2, 1, 1, 0, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 2, 1, 0, 2, 0, 1, 1, 1, 2, 1, 2, 1, 0, 0, 1, 2, 2, 1, 0, 2, 0, 2, 2, 2, 0, 2, 1, 1, 0
  .byte 1, 1, 1, 2, 0, 2, 2, 0, 0, 2, 0, 1, 2, 2, 1, 0, 2, 1, 2, 1, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 2, 1, 1, 2, 0, 2, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 2, 1, 2, 0, 0, 2, 1, 2, 0, 0, 1, 0, 0
  .byte 0, 1, 1, 0, 0, 1, 0, 0, 2, 0, 2, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 2, 1, 1, 1, 2, 0, 0
  .byte 1, 1, 1, 1, 1, 1, 0, 0, 1, 0, 0, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  .byte 0, 2, 1, 0, 0, 0, 0, 0, 2, 1, 2, 1, 0, 0, 0, 0, 1, 2, 1, 1, 0, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 0
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

.section .bss
.balign 4
trap_scratch:
  .zero 8

.balign 4
wisp_scan:
  .zero WISP_SCAN_SIZE

.balign 4
puzzle_buffer:
  .zero 80
puzzle_solution:
  .zero 68

.balign 4
chase_actions:
  .zero 64
first_row:
  .zero 8
chase_residual:
  .zero 8
basis_residual:
  .zero 8
pivot_columns:
  .zero 8

.balign 4
small_matrix:
  .zero 96

.balign 4
puzzle_rows:
  .zero 4
puzzle_cols:
  .zero 4
puzzle_colors:
  .zero 4
opponent_id:
  .zero 4
