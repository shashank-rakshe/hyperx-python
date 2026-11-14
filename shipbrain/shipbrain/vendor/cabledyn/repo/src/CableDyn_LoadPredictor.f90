! File: src/CableDyn_LoadPredictor.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_LoadPredictor
  !! Coupled loads between supercycled mooring solves. When the mooring steps on dtM, a whole
  !! number of host steps, the host still asks for the loads at every one of its steps. Held at
  !! the last committed solve they lag the platform by up to dtM; extrapolated linearly from
  !! the last two committed solves,
  !!
  !!   F(t) = F_c + tau (F_c - F_p),   tau = (t - t_c)/dtM in [0, 1],
  !!
  !! they follow it to second order: the error is of order dtM^2 F'' instead of dtM F'. The
  !! extrapolation is used only when the two solves are exactly one dtM apart (consecutive
  !! commits), so the first interval of a run, or after a gap, keeps the held loads.
  USE CableDyn_Precision, ONLY: wp
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Predictor_Ready, CD_Predictor_Fraction, CD_Predict_Loads

CONTAINS

  PURE LOGICAL FUNCTION CD_Predictor_Ready(t_commit, t_prev, dt) RESULT(ready)
    !! The previous committed solve (time t_prev; negative when there is none) is the one
    !! immediately before the last (time t_commit): exactly dt earlier, within 1e-6 dt.
    REAL(wp), INTENT(IN) :: t_commit, t_prev, dt
    ready = .FALSE.
    IF (.NOT. (dt > 0.0_wp .AND. t_prev >= 0.0_wp)) RETURN
    ready = ABS((t_commit - t_prev) - dt) <= 1.0e-6_wp*dt
  END FUNCTION CD_Predictor_Ready

  PURE REAL(wp) FUNCTION CD_Predictor_Fraction(t, t_commit, dt) RESULT(tau)
    !! The fraction of the mooring step elapsed since the last committed solve, clamped to
    !! [0, 1] (no extrapolation beyond one step, none backwards).
    REAL(wp), INTENT(IN) :: t, t_commit, dt
    tau = MAX(0.0_wp, MIN(1.0_wp, (t - t_commit)/dt))
  END FUNCTION CD_Predictor_Fraction

  PURE SUBROUTINE CD_Predict_Loads(f_last, f_prev, tau, f)
    !! F = F_c + tau (F_c - F_p), element by element.
    REAL(wp), INTENT(IN) :: f_last(:, :), f_prev(:, :), tau
    REAL(wp), INTENT(OUT) :: f(:, :)
    f = f_last + tau*(f_last - f_prev)
  END SUBROUTINE CD_Predict_Loads

END MODULE CableDyn_LoadPredictor
