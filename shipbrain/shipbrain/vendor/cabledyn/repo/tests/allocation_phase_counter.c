/* File: tests/allocation_phase_counter.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Phase window of the allocation counter (tests/allocation_counter.c) for a whole standalone
 * driver run made in process. The test executable is linked with GNU ld
 * --wrap=__cabledyn_profile_MOD_cd_profile_enter (the gfortran symbol of CD_Profile_Enter), which
 * every time march calls at each phase change of every step, armed or not. Armed, the wrapper
 * counts the allocations of the step phase (CD_PROF_SOLVE) after a number of warm-up steps and
 * switches the counter off at the next phase change, so the march's fluid sampling, checks and
 * outputs stay outside the counted window. */

void __real___cabledyn_profile_MOD_cd_profile_enter(const int *phase);
void cd_test_allocation_counting(int on);

/* CD_PROF_SOLVE of CableDyn_Profile */
enum { PHASE_SOLVE = 4 };

static int armed = 0;
static long long warm_steps = 0;
static long long solve_entries = 0;

void __wrap___cabledyn_profile_MOD_cd_profile_enter(const int *phase)
{
    if (armed) {
        if (*phase == PHASE_SOLVE) {
            solve_entries++;
            cd_test_allocation_counting(solve_entries > warm_steps);
        } else {
            cd_test_allocation_counting(0);
        }
    }
    __real___cabledyn_profile_MOD_cd_profile_enter(phase);
}

/* Arm (on != 0) with the number of step phases left uncounted, or disarm. */
void cd_test_phase_counting(int on, long long warm)
{
    armed = on;
    warm_steps = warm;
    solve_entries = 0;
    if (!on) cd_test_allocation_counting(0);
}

/* Step phases entered since the arming. */
long long cd_test_phase_solve_entries(void) { return solve_entries; }
