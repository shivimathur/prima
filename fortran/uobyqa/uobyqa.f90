module uobyqa_mod
!--------------------------------------------------------------------------------------------------!
! UOBYQA_MOD is a module providing the reference implementation of Powell's UOBYQA algorithm in
!
! M. J. D. Powell, UOBYQA: unconstrained optimization by quadratic approximation, Math. Program.,
! 92(B):555--582, 2002
!
! UOBYQA approximately solves
!
!   min F(X),
!
! where X is a vector of variables that has N components and F is a real-valued objective function.
! It tackles the problem by a trust region method that forms quadratic models by interpolation.
!
! Coded by Zaikun ZHANG (www.zhangzk.net) based on the UOBYQA paper and Powell's code, with
! modernization, bug fixes, and improvements.
!
! Dedicated to the late Professor M. J. D. Powell FRS (1936--2015).
!
! Started: February 2022
!
! Last Modified: Thursday, February 22, 2024 PM03:29:24
!--------------------------------------------------------------------------------------------------!

implicit none
private
public :: uobyqa


contains


subroutine uobyqa(calfun, x, &
    & f, nf, rhobeg, rhoend, ftarget, maxfun, iprint, eta1, eta2, gamma1, gamma2, &
    & xhist, fhist, maxhist, callback_fcn, info)
!--------------------------------------------------------------------------------------------------!
! Among all the arguments, only CALFUN and X are obligatory. The others are OPTIONAL and you can
! neglect them unless you are familiar with the algorithm. Any unspecified optional input will take
! the default value detailed below. For instance, we may invoke the solver as follows.
!
! ! First define CALFUN and X, and then do the following.
! call uobyqa(calfun, x, f)
!
! or
!
! ! First define CALFUN and X, and then do the following.
! call uobyqa(calfun, x, f, rhobeg = 1.0D0, rhoend = 1.0D-6)
!
! See examples/uobyqa_exmp.f90 for a concrete example.
!
! A detailed introduction to the arguments is as follows.
! N.B.: RP and IK are defined in the module CONSTS_MOD. See consts.F90 under the directory name
! "common". By default, RP = kind(0.0D0) and IK = kind(0), with REAL(RP) being the double-precision
! real, and INTEGER(IK) being the default integer. For ADVANCED USERS, RP and IK can be defined by
! setting PRIMA_REAL_PRECISION and PRIMA_INTEGER_KIND in common/ppf.h. Use the default if unsure.
!
! CALFUN
!   Input, subroutine.
!   CALFUN(X, F) should evaluate the objective function at the given REAL(RP) vector X and set the
!   value to the REAL(RP) scalar F. It must be provided by the user, and its definition must conform
!   to the following interface:
!   !-------------------------------------------------------------------------!
!    subroutine calfun(x, f)
!    real(RP), intent(in) :: x(:)
!    real(RP), intent(out) :: f
!    end subroutine calfun
!   !-------------------------------------------------------------------------!
!
! X
!   Input and output, REAL(RP) vector.
!   As an input, X should be an N dimensional vector that contains the starting point, N being the
!   dimension of the problem. As an output, X will be set to an approximate minimizer.
!
! F
!   Output, REAL(RP) scalar.
!   F will be set to the objective function value of X at exit.
!
! NF
!   Output, INTEGER(IK) scalar.
!   NF will be set to the number of calls of CALFUN at exit.
!
! RHOBEG, RHOEND
!   Inputs, REAL(RP) scalars, default: RHOBEG = 1, RHOEND = 10^-6. RHOBEG and RHOEND must be set to
!   the initial and final values of a trust-region radius, both being positive and RHOEND <= RHOBEG.
!   Typically RHOBEG should be about one tenth of the greatest expected change to a variable, and
!   RHOEND should indicate the accuracy that is required in the final values of the variables.
!
! FTARGET
!   Input, REAL(RP) scalar, default: -Inf.
!   FTARGET is the target function value. The algorithm will terminate when a point with a function
!   value <= FTARGET is found.
!
! MAXFUN
!   Input, INTEGER(IK) scalar, default: MAXFUN_DIM_DFT*N with MAXFUN_DIM_DFT defined in the module
!   CONSTS_MOD (see common/consts.F90). MAXFUN is the maximal number of calls of CALFUN.
!
! IPRINT
!   Input, INTEGER(IK) scalar, default: 0.
!   The value of IPRINT should be set to 0, 1, -1, 2, -2, 3, or -3, which controls how much
!   information will be printed during the computation:
!   0: there will be no printing;
!   1: a message will be printed to the screen at the return, showing the best vector of variables
!      found and its objective function value;
!   2: in addition to 1, each new value of RHO is printed to the screen, with the best vector of
!      variables so far and its objective function value;
!   3: in addition to 2, each function evaluation with its variables will be printed to the screen;
!   -1, -2, -3: the same information as 1, 2, 3 will be printed, not to the screen but to a file
!      named UOBYQA_output.txt; the file will be created if it does not exist; the new output will
!      be appended to the end of this file if it already exists.
!   Note that IPRINT = +/-3 can be costly in terms of time and/or space.
!
! ETA1, ETA2, GAMMA1, GAMMA2
!   Input, REAL(RP) scalars, default: ETA1 = 0.1, ETA2 = 0.7, GAMMA1 = 0.5, and GAMMA2 = 2.
!   ETA1, ETA2, GAMMA1, and GAMMA2 are parameters in the updating scheme of the trust-region radius
!   detailed in the subroutine TRRAD in trustregion.f90. Roughly speaking, the trust-region radius
!   is contracted by a factor of GAMMA1 when the reduction ratio is below ETA1, and enlarged by a
!   factor of GAMMA2 when the reduction ratio is above ETA2. It is required that 0 < ETA1 <= ETA2
!   < 1 and 0 < GAMMA1 < 1 < GAMMA2. Normally, ETA1 <= 0.25. It is NOT advised to set ETA1 >= 0.5.
!
! XHIST, FHIST, MAXHIST
!   XHIST: Output, ALLOCATABLE rank 2 REAL(RP) array;
!   FHIST: Output, ALLOCATABLE rank 1 REAL(RP) array;
!   MAXHIST: Input, INTEGER(IK) scalar, default: MAXFUN
!   XHIST, if present, will output the history of iterates, while FHIST, if present, will output the
!   history function values. MAXHIST should be a nonnegative integer, and XHIST/FHIST will output
!   only the history of the last MAXHIST iterations. Therefore, MAXHIST = 0 means XHIST/FHIST will
!   output nothing, while setting MAXHIST = MAXFUN requests XHIST/FHIST to output all the history.
!   If XHIST is present, its size at exit will be (N, min(NF, MAXHIST)); if FHIST is present, its
!   size at exit will be min(NF, MAXHIST).
!
!   IMPORTANT NOTICE:
!   Setting MAXHIST to a large value can be costly in terms of memory for large problems.
!   MAXHIST will be reset to a smaller value if the memory needed exceeds MAXHISTMEM defined in
!   CONSTS_MOD (see consts.F90 under the directory named "common").
!   Use *HIST with caution!!! (N.B.: the algorithm is NOT designed for large problems).
!
! CALLBACK_FCN
!   Input, function to report progress and optionally request termination.
!
! INFO
!   Output, INTEGER(IK) scalar.
!   INFO is the exit flag. It will be set to one of the following values defined in the module
!   INFOS_MOD (see common/infos.f90):
!   SMALL_TR_RADIUS: the lower bound for the trust region radius is reached;
!   FTARGET_ACHIEVED: the target function value is reached;
!   MAXFUN_REACHED: the objective function has been evaluated MAXFUN times;
!   MAXTR_REACHED: the trust region iteration has been performed MAXTR times (MAXTR = 2*MAXFUN);
!   NAN_INF_MODEL: NaN or Inf occurs in the model;
!   NAN_INF_X: NaN or Inf occurs in X.
!   !--------------------------------------------------------------------------!
!   The following case(s) should NEVER occur unless there is a bug.
!   NAN_INF_F: the objective function returns NaN or +Inf;
!   TRSUBP_FAILED: a trust region step has failed to reduce the model;
!   !--------------------------------------------------------------------------!
!--------------------------------------------------------------------------------------------------!

! Common modules
use, non_intrinsic :: consts_mod, only : DEBUGGING
use, non_intrinsic :: consts_mod, only : MAXFUN_DIM_DFT
use, non_intrinsic :: consts_mod, only : RHOBEG_DFT, RHOEND_DFT, FTARGET_DFT, IPRINT_DFT
use, non_intrinsic :: consts_mod, only : RP, IK, TWO, HALF, TEN, TENTH, EPS
use, non_intrinsic :: debug_mod, only : assert, warning
! use, non_intrinsic :: evaluate_mod, only : moderatex
use, non_intrinsic :: history_mod, only : prehist
use, non_intrinsic :: infnan_mod, only : is_nan, is_finite, is_posinf
use, non_intrinsic :: memory_mod, only : safealloc
use, non_intrinsic :: pintrf_mod, only : OBJ, CALLBACK
use, non_intrinsic :: preproc_mod, only : preproc
use, non_intrinsic :: string_mod, only : num2str

! Solver-specific modules
! use, non_intrinsic :: uobyqb_mod, only : uobyqb

implicit none

! Compulsory arguments
procedure(OBJ) :: calfun  ! N.B.: INTENT cannot be specified if a dummy procedure is not a POINTER
real(RP), intent(inout) :: x(:)  ! X(N)

! Optional inputs
procedure(CALLBACK), optional :: callback_fcn
integer(IK), intent(in), optional :: iprint
integer(IK), intent(in), optional :: maxfun
integer(IK), intent(in), optional :: maxhist
real(RP), intent(in), optional :: eta1
real(RP), intent(in), optional :: eta2
real(RP), intent(in), optional :: ftarget
real(RP), intent(in), optional :: gamma1
real(RP), intent(in), optional :: gamma2
real(RP), intent(in), optional :: rhobeg
real(RP), intent(in), optional :: rhoend

! Optional outputs
integer(IK), intent(out), optional :: info
integer(IK), intent(out), optional :: nf
real(RP), intent(out), optional :: f
real(RP), intent(out), optional, allocatable :: fhist(:)  ! FHIST(MAXFHIST)
real(RP), intent(out), optional, allocatable :: xhist(:, :)  ! XHIST(N, MAXXHIST)

! Local variables
character(len=*), parameter :: solver = 'UOBYQA'
character(len=*), parameter :: srname = 'UOBYQA'
integer(IK) :: info_loc
integer(IK) :: iprint_loc
integer(IK) :: maxfun_loc
integer(IK) :: maxhist_loc
integer(IK) :: n
integer(IK) :: nf_loc
integer(IK) :: nhist
real(RP) :: eta1_loc
real(RP) :: eta2_loc
real(RP) :: f_loc
real(RP) :: ftarget_loc
real(RP) :: gamma1_loc
real(RP) :: gamma2_loc
real(RP) :: rhobeg_loc
real(RP) :: rhoend_loc
real(RP), allocatable :: fhist_loc(:)  ! FHIST_LOC(MAXFHIST)
real(RP), allocatable :: xhist_loc(:, :)  ! XHIST_LOC(N, MAXXHIST)


! Sizes
n = int(size(x), kind(n))

! Replace any NaN in X by ZERO and Inf/-Inf in X by REALMAX/-REALMAX.
! x = moderatex(x)

! Read the inputs.

! If RHOBEG is present, then RHOBEG_LOC is a copy of RHOBEG; otherwise, RHOBEG_LOC takes the default
! value for RHOBEG, taking the value of RHOEND into account. Note that RHOEND is considered only if
! it is present and it is VALID (i.e., finite and positive). The other inputs are read similarly.
if (present(rhobeg)) then
    rhobeg_loc = rhobeg
elseif (present(rhoend)) then
    ! Fortran does not take short-circuit evaluation of logic expressions. Thus it is WRONG to
    ! combine the evaluation of PRESENT(RHOEND) and the evaluation of IS_FINITE(RHOEND) as
    ! "IF (PRESENT(RHOEND) .AND. IS_FINITE(RHOEND))". The compiler may choose to evaluate the
    ! IS_FINITE(RHOEND) even if PRESENT(RHOEND) is false!
    if (is_finite(rhoend) .and. rhoend > 0) then
        rhobeg_loc = max(TEN * rhoend, RHOBEG_DFT)
    else
        rhobeg_loc = RHOBEG_DFT
    end if
else
    rhobeg_loc = RHOBEG_DFT
end if

if (present(rhoend)) then
    rhoend_loc = rhoend
elseif (rhobeg_loc > 0) then
    rhoend_loc = max(EPS, min((RHOEND_DFT / RHOBEG_DFT) * rhobeg_loc, RHOEND_DFT))
else
    rhoend_loc = RHOEND_DFT
end if

if (present(ftarget)) then
    ftarget_loc = ftarget
else
    ftarget_loc = FTARGET_DFT
end if

if (present(maxfun)) then
    maxfun_loc = maxfun
else
    maxfun_loc = max(MAXFUN_DIM_DFT * n, (n + 1_IK) * (n + 2_IK) / 2_IK + 1_IK)
end if

if (present(iprint)) then
    iprint_loc = iprint
else
    iprint_loc = IPRINT_DFT
end if

if (present(eta1)) then
    eta1_loc = eta1
elseif (present(eta2)) then
    if (eta2 > 0 .and. eta2 < 1) then
        eta1_loc = max(EPS, eta2 / 7.0_RP)
    end if
else
    eta1_loc = TENTH
end if

if (present(eta2)) then
    eta2_loc = eta2
elseif (eta1_loc > 0 .and. eta1_loc < 1) then
    eta2_loc = (eta1_loc + TWO) / 3.0_RP
else
    eta2_loc = 0.7_RP
end if

if (present(gamma1)) then
    gamma1_loc = gamma1
else
    gamma1_loc = HALF
end if

if (present(gamma2)) then
    gamma2_loc = gamma2
else
    gamma2_loc = TWO
end if

if (present(maxhist)) then
    maxhist_loc = maxhist
else
    maxhist_loc = maxval([maxfun_loc, 1_IK + (n + 1_IK) * (n + 2_IK) / 2_IK, MAXFUN_DIM_DFT * n])
end if

! Preprocess the inputs in case some of them are invalid.
call preproc(solver, n, iprint_loc, maxfun_loc, maxhist_loc, ftarget_loc, rhobeg_loc, rhoend_loc, &
    & eta1=eta1_loc, eta2=eta2_loc, gamma1=gamma1_loc, gamma2=gamma2_loc)

! Further revise MAXHIST_LOC according to MAXHISTMEM, and allocate memory for the history.
! In MATLAB/Python/Julia/R implementation, we should simply set MAXHIST = MAXFUN and initialize
! FHIST = NaN(1, MAXFUN), XHIST = NaN(N, MAXFUN) if they are requested; replace MAXFUN with 0 for
! the history that is not requested.
call prehist(maxhist_loc, n, present(xhist), xhist_loc, present(fhist), fhist_loc)


!-------------------- Call UOBYQB, which performs the real calculations. --------------------------!
! if (present(callback_fcn)) then
!     call uobyqb(calfun, iprint_loc, maxfun_loc, eta1_loc, eta2_loc, ftarget_loc, gamma1_loc, &
!         & gamma2_loc, rhobeg_loc, rhoend_loc, x, nf_loc, f_loc, fhist_loc, xhist_loc, info_loc, callback_fcn)
! else
!     call uobyqb(calfun, iprint_loc, maxfun_loc, eta1_loc, eta2_loc, ftarget_loc, gamma1_loc, &
!         & gamma2_loc, rhobeg_loc, rhoend_loc, x, nf_loc, f_loc, fhist_loc, xhist_loc, info_loc)
! end if
!--------------------------------------------------------------------------------------------------!


! Write the outputs.

if (present(f)) then
    f = f_loc
end if

if (present(nf)) then
    nf = nf_loc
end if

if (present(info)) then
    info = info_loc
end if

! Copy XHIST_LOC to XHIST if needed.
if (present(xhist)) then
    nhist = min(nf_loc, int(size(xhist_loc, 2), IK))
    !----------------------------------------------------!
    call safealloc(xhist, n, nhist)  ! Removable in F2003.
    !----------------------------------------------------!
    xhist = xhist_loc(:, 1:nhist)
    ! N.B.:
    ! 0. Allocate XHIST as long as it is present, even if the size is 0; otherwise, it will be
    ! illegal to enquire XHIST after exit.
    ! 1. Even though Fortran 2003 supports automatic (re)allocation of allocatable arrays upon
    ! intrinsic assignment, we keep the line of SAFEALLOC, because some very new compilers (Absoft
    ! Fortran 21.0) are still not standard-compliant in this respect.
    ! 2. NF may not be present. Hence we should NOT use NF but NF_LOC.
    ! 3. When SIZE(XHIST_LOC, 2) > NF_LOC, which is the normal case in practice, XHIST_LOC contains
    ! GARBAGE in XHIST_LOC(:, NF_LOC + 1 : END). Therefore, we MUST cap XHIST at NF_LOC so that
    ! XHIST contains only valid history. For this reason, there is no way to avoid allocating
    ! two copies of memory for XHIST unless we declare it to be a POINTER instead of ALLOCATABLE.
end if
! F2003 automatically deallocate local ALLOCATABLE variables at exit, yet we prefer to deallocate
! them immediately when they finish their jobs.
deallocate (xhist_loc)

! Copy FHIST_LOC to FHIST if needed.
if (present(fhist)) then
    nhist = min(nf_loc, int(size(fhist_loc), IK))
    !--------------------------------------------------!
    call safealloc(fhist, nhist)  ! Removable in F2003.
    !--------------------------------------------------!
    fhist = fhist_loc(1:nhist)  ! The same as XHIST, we must cap FHIST at NF_LOC.
end if
deallocate (fhist_loc)

! If MAXFHIST_IN >= NF_LOC > MAXFHIST_LOC, warn that not all history is recorded.
if ((present(xhist) .or. present(fhist)) .and. maxhist_loc < nf_loc) then
    call warning(solver, 'Only the history of the last '//num2str(maxhist_loc)//' function evaluation(s) is recorded')
end if

! Postconditions
if (DEBUGGING) then
    call assert(nf_loc <= maxfun_loc, 'NF <= MAXFUN', srname)
    call assert(size(x) == n .and. .not. any(is_nan(x)), 'SIZE(X) == N, X does not contain NaN', srname)
    nhist = min(nf_loc, maxhist_loc)
    if (present(xhist)) then
        call assert(size(xhist, 1) == n .and. size(xhist, 2) == nhist, 'SIZE(XHIST) == [N, NHIST]', srname)
        call assert(.not. any(is_nan(xhist)), 'XHIST does not contain NaN', srname)
    end if
    if (present(fhist)) then
        call assert(size(fhist) == nhist, 'SIZE(FHIST) == NHIST', srname)
        call assert(.not. any(is_nan(fhist) .or. is_posinf(fhist)), 'FHIST does not contain NaN/+Inf', srname)
        call assert(.not. any(fhist < f_loc), 'F is the smallest in FHIST', srname)
    end if
end if

end subroutine uobyqa


end module uobyqa_mod
