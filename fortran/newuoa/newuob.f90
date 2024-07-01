module newuob_mod
!--------------------------------------------------------------------------------------------------!
! This module performs the major calculations of NEWUOA.
!
! Coded by Zaikun ZHANG (www.zhangzk.net) based on Powell's code and the NEWUOA paper.
!
! Dedicated to the late Professor M. J. D. Powell FRS (1936--2015).
!
! Started: July 2020
!
! Last Modified: Sunday, April 07, 2024 AM12:31:14
!--------------------------------------------------------------------------------------------------!

implicit none
private
public :: newuob


contains


subroutine newuob(calfun, iprint, maxfun, npt, eta1, eta2, ftarget, gamma1, gamma2, rhobeg, &
    & rhoend, x, nf, f, fhist, xhist, info, callback_fcn)
!--------------------------------------------------------------------------------------------------!
! This subroutine performs the actual calculations of NEWUOA.
!
! IPRINT, MAXFUN, MAXHIST, NPT, ETA1, ETA2, FTARGET, GAMMA1, GAMMA2, RHOBEG, RHOEND, X, NF, F,
! FHIST, XHIST, and INFO are identical to the corresponding arguments in subroutine NEWUOA.
!
! XBASE holds a shift of origin that should reduce the contributions from rounding errors to values
!   of the model and Lagrange functions.
! XOPT is the displacement from XBASE of the best vector of variables so far (i.e., the one provides
!   the least calculated F so far). FOPT = F(XOPT + XBASE). However, we do not save XOPT and FOPT
!   explicitly, because XOPT = XPT(:, KOPT) and FOPT = FVAL(KOPT), which is explained below.
! [XPT, FVAL, KOPT] describes the interpolation set:
! XPT contains the interpolation points relative to XBASE, each COLUMN for a point; FVAL holds the
!   values of F at the interpolation points; KOPT is the index of XOPT in XPT.
! [GOPT, HQ, PQ] describes the quadratic model: GOPT will hold the gradient of the quadratic model
!   at XBASE+XOPT; HQ will hold the explicit second order derivatives of the quadratic model; PQ
!   will contain the parameters of the implicit second order derivatives of the quadratic model.
! [BMAT, ZMAT, IDZ] describes the matrix H in the NEWUOA paper (eq. 3.12), which is the inverse of
!   the coefficient matrix of the KKT system for the least-Frobenius norm interpolation problem:
!   ZMAT will hold a factorization of the leading NPT*NPT submatrix of H, the factorization being
!   ZMAT*Diag(DZ)*ZMAT^T with DZ(1:IDZ-1)=-1, DZ(IDZ:NPT-N-1)=1. BMAT will hold the last N ROWs of H
!   except for the (NPT+1)th column. Note that the (NPT + 1)th row and column of H are not saved as
!   they are unnecessary for the calculation.
! D is reserved for trial steps from XOPT. It is chosen by subroutine TRSAPP or GEOSTEP. Usually
!   XBASE + XOPT + D is the vector of variables for the next call of CALFUN.
!
! See Section 2 of the NEWUOA paper for more information about these variables.
!--------------------------------------------------------------------------------------------------!

! Common modules
use, non_intrinsic :: checkexit_mod, only : checkexit
use, non_intrinsic :: consts_mod, only : RP, IK, ONE, HALF, TENTH, REALMAX, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
! use, non_intrinsic :: evaluate_mod, only : evaluate
use, non_intrinsic :: history_mod, only : savehist, rangehist
use, non_intrinsic :: infnan_mod, only : is_nan, is_posinf, is_finite
use, non_intrinsic :: infos_mod, only : INFO_DFT, MAXTR_REACHED, SMALL_TR_RADIUS, CALLBACK_TERMINATE, NAN_INF_MODEL
use, non_intrinsic :: linalg_mod, only : norm
use, non_intrinsic :: message_mod, only : retmsg, rhomsg, fmsg
use, non_intrinsic :: pintrf_mod, only : OBJ, CALLBACK
use, non_intrinsic :: powalg_mod, only : quadinc, updateh
use, non_intrinsic :: ratio_mod, only : redrat
use, non_intrinsic :: redrho_mod, only : redrho
use, non_intrinsic :: shiftbase_mod, only : shiftbase

! Solver-specific modules
use, non_intrinsic :: geometry_newuoa_mod, only : setdrop_tr, geostep
! use, non_intrinsic :: initialize_newuoa_mod, only : initxf, initq, inith
use, non_intrinsic :: trustregion_newuoa_mod, only : trsapp, trrad
use, non_intrinsic :: update_newuoa_mod, only : updatexf, updateq, tryqalt

implicit none

! Inputs
procedure(OBJ) :: calfun  ! N.B.: INTENT cannot be specified if a dummy procedure is not a POINTER
procedure(CALLBACK), optional :: callback_fcn
integer(IK), intent(in) :: iprint
integer(IK), intent(in) :: maxfun
integer(IK), intent(in) :: npt
real(RP), intent(in) :: eta1
real(RP), intent(in) :: eta2
real(RP), intent(in) :: ftarget
real(RP), intent(in) :: gamma1
real(RP), intent(in) :: gamma2
real(RP), intent(in) :: rhobeg
real(RP), intent(in) :: rhoend

! In-outputs
real(RP), intent(inout) :: x(:)      ! X(N)

! Outputs
integer(IK), intent(out) :: info
integer(IK), intent(out) :: nf
real(RP), intent(out) :: f
real(RP), intent(out) :: fhist(:)   ! FHIST(MAXFHIST)
real(RP), intent(out) :: xhist(:, :)    ! XHIST(N, MAXXHIST)

! Local variables
character(len=*), parameter :: solver = 'NEWUOA'
character(len=*), parameter :: srname = 'NEWUOB'
integer(IK) :: idz
integer(IK) :: ij(2, max(0_IK, int(npt - 2 * size(x) - 1, IK)))
integer(IK) :: itest
integer(IK) :: k
integer(IK) :: knew_geo
integer(IK) :: knew_tr
integer(IK) :: kopt
integer(IK) :: maxfhist
integer(IK) :: maxhist
integer(IK) :: maxtr
integer(IK) :: maxxhist
integer(IK) :: n
integer(IK) :: subinfo
integer(IK) :: tr
logical :: accurate_mod
logical :: adequate_geo
logical :: bad_trstep
logical :: close_itpset
logical :: improve_geo
logical :: reduce_rho
logical :: shortd
logical :: small_trrad
logical :: terminate
logical :: trfail
logical :: ximproved
real(RP) :: bmat(size(x), npt + size(x))
real(RP) :: crvmin
real(RP) :: d(size(x))
real(RP) :: delbar
real(RP) :: delta
real(RP) :: distsq(npt)
real(RP) :: dnorm
real(RP) :: dnorm_rec(2)  ! Powell's implementation: DNORM_REC(3)
real(RP) :: fval(npt)
real(RP) :: gamma3
real(RP) :: gopt(size(x))
real(RP) :: hq(size(x), size(x))
real(RP) :: moderr
real(RP) :: moderr_rec(size(dnorm_rec))
real(RP) :: pq(npt)
real(RP) :: qred
real(RP) :: ratio
real(RP) :: rho
real(RP) :: xbase(size(x))
real(RP) :: xdrop(size(x))
real(RP) :: xosav(size(x))
real(RP) :: xpt(size(x), npt)
real(RP) :: zmat(npt, npt - size(x) - 1)
real(RP), parameter :: trtol = 1.0E-2_RP  ! Convergence tolerance of trust-region subproblem solver

! Sizes
n = int(size(x), kind(n))
maxxhist = int(size(xhist, 2), kind(maxxhist))
maxfhist = int(size(fhist), kind(maxfhist))
maxhist = max(maxxhist, maxfhist)

! Preconditions
if (DEBUGGING) then
    call assert(abs(iprint) <= 3, 'IPRINT is 0, 1, -1, 2, -2, 3, or -3', srname)
    call assert(n >= 1 .and. npt >= n + 2, 'N >= 1, NPT >= N + 2', srname)
    call assert(maxfun >= npt + 1, 'MAXFUN >= NPT + 1', srname)
    call assert(rhobeg >= rhoend .and. rhoend > 0, 'RHOBEG >= RHOEND > 0', srname)
    call assert(all(is_finite(x)), 'X is finite', srname)
    call assert(eta1 >= 0 .and. eta1 <= eta2 .and. eta2 < 1, '0 <= ETA1 <= ETA2 < 1', srname)
    call assert(gamma1 > 0 .and. gamma1 < 1 .and. gamma2 > 1, '0 < GAMMA1 < 1 < GAMMA2', srname)
    call assert(maxhist >= 0 .and. maxhist <= maxfun, '0 <= MAXHIST <= MAXFUN', srname)
    call assert(maxfhist * (maxfhist - maxhist) == 0, 'SIZE(FHIST) == 0 or MAXHIST', srname)
    call assert(size(xhist, 1) == n .and. maxxhist * (maxxhist - maxhist) == 0, &
        & 'SIZE(XHIST, 1) == N, SIZE(XHIST, 2) == 0 or MAXHIST', srname)
end if

!====================!
! Calculation starts !
!====================!

! Initialize XBASE, XPT, FVAL, and KOPT, together with the history, NF, and IJ.
! call initxf(calfun, iprint, maxfun, ftarget, rhobeg, x, ij, kopt, nf, fhist, fval, xbase, xhist, xpt, subinfo)

! Report the current best value, and check if user asks for early termination.
terminate = .false.
if (present(callback_fcn)) then
    ! call callback_fcn(xbase + xpt(:, kopt), fval(kopt), nf, 0_IK, terminate=terminate)
    if (terminate) then
        subinfo = CALLBACK_TERMINATE
    end if
end if

! Initialize X and F according to KOPT.
x = xbase + xpt(:, kopt)
f = fval(kopt)

! Finish the initialization if INITXF completed normally and CALLBACK did not request termination;
! otherwise, do not proceed, as XPT etc may be uninitialized, leading to errors or exceptions.
if (subinfo == INFO_DFT) then
    ! Initialize [BMAT, ZMAT, IDZ], representing inverse of KKT matrix of the interpolation
    ! system.
    ! call inith(ij, xpt, idz, bmat, zmat)

    ! Initialize the quadratic represented by [GOPT, HQ, PQ], so that its gradient at XBASE+XOPT is
    ! GOPT; its Hessian is HQ + sum_{K=1}^NPT PQ(K)*XPT(:, K)*XPT(:, K)'.
    ! call initq(ij, fval, xpt, gopt, hq, pq)
    if (.not. (all(is_finite(gopt)) .and. all(is_finite(hq)) .and. all(is_finite(pq)))) then
        subinfo = NAN_INF_MODEL
    end if
end if

! Check whether to return due to abnormal cases that may occur during the initialization.
if (subinfo /= INFO_DFT) then
    info = subinfo
    ! Arrange FHIST and XHIST so that they are in the chronological order.
    call rangehist(nf, xhist, fhist)
    ! Print a return message according to IPRINT.
    call retmsg(solver, info, iprint, nf, f, x)
    ! Postconditions
    if (DEBUGGING) then
        call assert(nf <= maxfun, 'NF <= MAXFUN', srname)
        call assert(size(x) == n .and. .not. any(is_nan(x)), 'SIZE(X) == N, X does not contain NaN', srname)
        call assert(.not. (is_nan(f) .or. is_posinf(f)), 'F is not NaN/+Inf', srname)
        call assert(size(xhist, 1) == n .and. size(xhist, 2) == maxxhist, 'SIZE(XHIST) == [N, MAXXHIST]', srname)
        call assert(.not. any(is_nan(xhist(:, 1:min(nf, maxxhist)))), 'XHIST does not contain NaN', srname)
        ! The last calculated X can be Inf (finite + finite can be Inf numerically).
        call assert(size(fhist) == maxfhist, 'SIZE(FHIST) == MAXFHIST', srname)
        call assert(.not. any(is_nan(fhist(1:min(nf, maxfhist))) .or. is_posinf(fhist(1:min(nf, maxfhist)))), &
            & 'FHIST does not contain NaN/+Inf', srname)
        call assert(.not. any(fhist(1:min(nf, maxfhist)) < f), 'F is the smallest in FHIST', srname)
    end if
    return
end if

! Set some more initial values.
! We must initialize RATIO. Otherwise, when SHORTD = TRUE, compilers may raise a run-time error that
! RATIO is undefined. But its value will not be used: when SHORTD = FALSE, its value will be
! overwritten; when SHORTD = TRUE, its value is used only in BAD_TRSTEP, which is TRUE regardless of
! RATIO. Similar for KNEW_TR.
! No need to initialize SHORTD unless MAXTR < 1, but some compilers may complain if we do not do it.
rho = rhobeg
delta = rho
shortd = .false.
trfail = .false.
ratio = -ONE
dnorm_rec = REALMAX
moderr_rec = REALMAX
knew_tr = 0
knew_geo = 0
itest = 0

! If DELTA <= GAMMA3*RHO after an update, we set DELTA to RHO. GAMMA3 must be less than GAMMA2. The
! reason is as follows. Imagine a very successful step with DENORM = the un-updated DELTA = RHO.
! Then TRRAD will update DELTA to GAMMA2*RHO. If GAMMA3 >= GAMMA2, then DELTA will be reset to RHO,
! which is not reasonable as D is very successful. See paragraph two of Sec. 5.2.5 in
! T. M. Ragonneau's thesis: "Model-Based Derivative-Free Optimization Methods and Software".
! According to test on 20230613, for NEWUOA, this Powellful updating scheme of DELTA works slightly
! better than setting directly DELTA = MAX(NEW_DELTA, RHO).
gamma3 = max(ONE, min(0.75_RP * gamma2, 1.5_RP))

! MAXTR is the maximal number of trust-region iterations. Here, we set it to HUGE(MAXTR) so that
! the algorithm will not terminate due to MAXTR. However, this may not be allowed in other languages
! such as MATLAB. In that case, we can set MAXTR to 10*MAXFUN, which is unlikely to reach because
! each trust-region iteration takes 1 or 2 function evaluations unless the trust-region step is short
! or fails to reduce the trust-region model but the geometry step is not invoked.
! N.B.: Do NOT set MAXTR to HUGE(MAXTR), as it may cause overflow and infinite cycling in the DO
! loop. See
! https://fortran-lang.discourse.group/t/loop-variable-reaching-integer-huge-causes-infinite-loop
! https://fortran-lang.discourse.group/t/loops-dont-behave-like-they-should
maxtr = huge(maxtr) - 1_IK  !!MATLAB: maxtr = 10 * maxfun;
info = MAXTR_REACHED

! Begin the iterative procedure.
! After solving a trust-region subproblem, we use three boolean variables to control the workflow.
! SHORTD: Is the trust-region trial step too short to invoke a function evaluation?
! IMPROVE_GEO: Should we improve the geometry (Box 8 of Fig. 1 in the NEWUOA paper)?
! REDUCE_RHO: Should we reduce rho (Boxes 14 and 10 of Fig. 1 in the NEWUOA paper)?
! NEWUOA never sets IMPROVE_GEO and REDUCE_RHO to TRUE simultaneously.
do tr = 1, maxtr
    ! Generate the next trust region step D.
    call trsapp(delta, gopt, hq, pq, trtol, xpt, crvmin, d)
    dnorm = min(delta, norm(d))

    ! Check whether D is too short to invoke a function evaluation.
    ! SHORTD corresponds to Box 3 of the NEWUOA paper. N.B.: we compare DNORM with RHO, not DELTA.
    ! HALF seems to work better than TENTH or QUART.
    shortd = (dnorm <= HALF * rho)  ! `<=` works better than `<` in case of underflow.

    ! Set QRED to the reduction of the quadratic model when the move D is made from XOPT. QRED
    ! should be positive. If it is nonpositive due to rounding errors, we will not take this step.
    qred = -quadinc(d, xpt, gopt, pq, hq)
    trfail = (.not. qred > 1.0E-6 * rho**2)  ! QRED is tiny/negative, or NaN.

    if (shortd .or. trfail) then
        ! In this case, do nothing but reducing DELTA. Afterward, DELTA < DNORM may occur.
        ! N.B.: 1. This value of DELTA will be discarded if REDUCE_RHO turns out TRUE later.
        ! 2. Without shrinking DELTA, the algorithm may be stuck in an infinite cycling, because
        ! both REDUCE_RHO and IMPROVE_GEO may end up with FALSE in this case.
        delta = TENTH * delta
        if (delta <= gamma3 * rho) then
            delta = rho  ! Set DELTA to RHO when it is close to or below.
        end if
    else
        ! Calculate the next value of the objective function.
        ! If X is close to one of the points in the interpolation set, then we do not evaluate the
        ! objective function X, assuming it to have the value at the closest point.
        x = xbase + (xpt(:, kopt) + d)
        distsq = [(sum((x - (xbase + xpt(:, k)))**2, dim=1), k=1, npt)]  ! Implied do-loop
        !!MATLAB: distsq = sum((x - (xbase + xpt))**2, 1)  % Implicit expansion
        k = int(minloc(distsq, dim=1), kind(k))
        if (distsq(k) <= (1.0E-3 * rhoend)**2) then
            f = fval(k)
        else
            ! Evaluate the objective function at X, taking care of possible Inf/NaN values.
            ! call evaluate(calfun, x, f)
            nf = nf + 1_IK
            ! Save X and F into the history.
            call savehist(nf, x, xhist, f, fhist)
        end if

        ! Print a message about the function evaluation according to IPRINT.
        call fmsg(solver, 'Trust region', iprint, nf, delta, f, x)

        ! Update DNORM_REC and MODERR_REC.
        ! DNORM_REC records the DNORM of the recent function evaluations with the current RHO.
        dnorm_rec = [dnorm_rec(2:size(dnorm_rec)), dnorm]
        ! MODERR is the error of the current model in predicting the change in F due to D.
        ! MODERR_REC records the prediction errors of the recent models with the current RHO.
        moderr = f - fval(kopt) + qred
        moderr_rec = [moderr_rec(2:size(moderr_rec)), moderr]

        ! Calculate the reduction ratio by REDRAT, which handles Inf/NaN carefully.
        ratio = redrat(fval(kopt) - f, qred, eta1)

        ! Update DELTA. After this, DELTA < DNORM may hold.
        delta = trrad(delta, dnorm, eta1, eta2, gamma1, gamma2, ratio)
        if (delta <= gamma3 * rho) then
            delta = rho  ! Set DELTA to RHO when it is close to or below.
        end if

        ! Is the newly generated X better than current best point?
        ximproved = (f < fval(kopt))

        ! Set KNEW_TR to the index of the interpolation point to be replaced with XNEW = XOPT + D.
        ! KNEW_TR will ensure that the geometry of XPT is "good enough" after the replacement.
        ! N.B.:
        ! 1. KNEW_TR = 0 means it is impossible to obtain a good interpolation set by replacing any
        ! current interpolation point with XNEW. Then XNEW and its function value will be discarded.
        ! In this case, the geometry of XPT likely needs improvement, which will be handled below.
        ! 2. If XIMPROVED = TRUE (i.e., RATIO > 0), then SETDROP_TR should ensure KNEW_TR > 0 so that
        ! XNEW is included into XPT. Otherwise, SETDROP_TR is buggy.
        knew_tr = setdrop_tr(idz, kopt, ximproved, bmat, d, delta, rho, xpt, zmat)

        ! Update [BMAT, ZMAT, IDZ] (represents H in the NEWUOA paper), [XPT, FVAL, KOPT] and
        ! [GOPT, HQ, PQ] (the quadratic model), so that XPT(:, KNEW_TR) becomes XNEW = XOPT + D.
        ! If KNEW_TR = 0, the updating subroutines will do essentially nothing, as the algorithm
        ! decides not to include XNEW into XPT.
        if (knew_tr > 0) then
            xdrop = xpt(:, knew_tr)
            xosav = xpt(:, kopt)
            call updateh(knew_tr, kopt, d, xpt, idz, bmat, zmat)
            call updatexf(knew_tr, ximproved, f, xosav + d, kopt, fval, xpt)
            call updateq(idz, knew_tr, ximproved, bmat, d, moderr, xdrop, xosav, xpt, zmat, gopt, hq, pq)

            ! Test whether to replace the new quadratic model Q by the least-Frobenius norm
            ! interpolant Q_alt. Perform the replacement if certain criteria are satisfied.
            ! N.B.: 1. This part is OPTIONAL, but it is crucial for the performance on some
            ! problems. See Section 8 of the NEWUOA paper.
            ! 2. TRYQALT is called only after a trust-region step but not after a geometry step,
            ! maybe because the model is expected to be good after a geometry step.
            ! 3. If KNEW_TR = 0 after a trust-region step, TRYQALT is not invoked. In this case, the
            ! interpolation set is unchanged, so it seems reasonable to keep the model unchanged.
            ! 4. In theory, FVAL - FVAL(KOPT) in the call of TRYQALT can be changed to FVAL + C with
            ! any constant C. This constant will not affect the result in precise arithmetic. Powell
            ! chose C = - FVAL(KOPT_OLD), where KOPT_OLD is the KOPT before the update above (Powell
            ! updated KOPT after TRYQALT). Here we use C = -FVAL(KOPT), as it worked slightly better
            ! on CUTEst, although there is no difference theoretically. Note that FVAL(KOPT_OLD) may
            ! not equal FOPT_OLD --- it may happen that KNEW_TR = KOPT_OLD so that FVAL(KOPT_OLD)
            ! has been revised after the last function evaluation.
            ! 5. Powell's code tries Q_alt only when DELTA == RHO.
            call tryqalt(idz, bmat, fval - fval(kopt), ratio, xpt(:, kopt), xpt, zmat, itest, gopt, hq, pq)
            if (.not. (all(is_finite(gopt)) .and. all(is_finite(hq)) .and. all(is_finite(pq)))) then
                info = NAN_INF_MODEL
                exit
            end if
        end if

        ! Check whether to exit
        subinfo = checkexit(maxfun, nf, f, ftarget, x)
        if (subinfo /= INFO_DFT) then
            info = subinfo
            exit
        end if
    end if  ! End of IF (SHORTD .OR. TRFAIL). The normal trust-region calculation ends.


    !----------------------------------------------------------------------------------------------!
    ! Before the next trust-region iteration, we may improve the geometry of XPT or reduce RHO
    ! according to IMPROVE_GEO and REDUCE_RHO, which in turn depend on the following indicators.
    ! N.B.: We must ensure that the algorithm does not set IMPROVE_GEO = TRUE at infinitely many
    ! consecutive iterations without moving XOPT or reducing RHO. Otherwise, the algorithm will get
    ! stuck in repetitive invocations of GEOSTEP. To this end, make sure the following.
    ! 1. The threshold for CLOSE_ITPSET is at least DELBAR, the trust region radius for GEOSTEP.
    ! Normally, DELBAR <= DELTA <= the threshold (In Powell's UOBYQA, DELBAR = RHO < the threshold).
    ! 2. If an iteration sets IMPROVE_GEO = TRUE, it must also reduce DELTA or set DELTA to RHO.

    ! ACCURATE_MOD: Are the recent models sufficiently accurate? Used only if SHORTD is TRUE.
    accurate_mod = all(abs(moderr_rec) <= 0.125_RP * crvmin * rho**2) .and. all(dnorm_rec <= rho)
    ! CLOSE_ITPSET: Are the interpolation points close to XOPT? It affects IMPROVE_GEO, REDUCE_RHO.
    ! distsq = sum((xpt - spread(xpt(:, kopt), dim=2, ncopies=npt))**2, dim=1)
    !!MATLAB: distsq = sum((xpt - xpt(:, kopt)).^2)  % Implicit expansion
    close_itpset = all(distsq <= 4.0_RP * delta**2)  ! Powell's code.
    ! Below are some alternative definitions of CLOSE_ITPSET.
    ! N.B.: The threshold for CLOSE_ITPSET is at least DELBAR, the trust region radius for GEOSTEP.
    ! !close_itpset = all(distsq <= 4.0_RP * rho**2)  ! Powell's UOBYQA code.
    ! !close_itpset = all(distsq <= max((TWO * delta)**2, (TEN * rho)**2))  ! Powell's BOBYQA code.
    ! !close_itpset = all(distsq <= max(delta**2, 4.0_RP * rho**2))  ! Powell's LINCOA code.
    ! ADEQUATE_GEO: Is the geometry of the interpolation set "adequate"?
    adequate_geo = (shortd .and. accurate_mod) .or. close_itpset
    ! SMALL_TRRAD: Is the trust-region radius small? This indicator seems not impactive in practice.
    ! When MAX(DELTA, DNORM) > RHO, as Powell mentioned under (2.3) of the NEWUOA paper, "RHO has
    ! not restricted the most recent choice of D", so it is not reasonable to reduce RHO.
    small_trrad = (max(delta, dnorm) <= rho)  ! Powell's code.
    !small_trrad = (delsav <= rho)  ! Behaves the same as Powell's version. DELSAV = unupdated DELTA.

    ! IMPROVE_GEO and REDUCE_RHO are defined as follows.

    ! BAD_TRSTEP (for IMPROVE_GEO): Is the last trust-region step bad?
    bad_trstep = (shortd .or. trfail .or. ratio <= eta1 .or. knew_tr == 0)
    improve_geo = bad_trstep .and. .not. adequate_geo
    ! BAD_TRSTEP (for REDUCE_RHO): Is the last trust-region step bad?
    bad_trstep = (shortd .or. trfail .or. ratio <= 0 .or. knew_tr == 0)
    reduce_rho = bad_trstep .and. adequate_geo .and. small_trrad

    ! Equivalently, REDUCE_RHO can be set as follows. It shows that REDUCE_RHO is TRUE in two cases.
    ! !bad_trstep = (shortd .or. trfail .or. ratio <= 0 .or. knew_tr == 0)
    ! !reduce_rho = (shortd .and. accurate_mod) .or. (bad_trstep .and. close_itpset .and. small_trrad)

    ! With REDUCE_RHO properly defined, we can also set IMPROVE_GEO as follows.
    ! !bad_trstep = (shortd .or. trfail .or. ratio <= eta1 .or. knew_tr == 0)
    ! !improve_geo = bad_trstep .and. (.not. reduce_rho) .and. (.not. close_itpset)

    ! With IMPROVE_GEO properly defined, we can also set REDUCE_RHO as follows.
    ! !bad_trstep = (shortd .or. trfail .or. ratio <= 0 .or. knew_tr == 0)
    ! !reduce_rho = bad_trstep .and. (.not. improve_geo) .and. small_trrad

    ! NEWUOA never sets IMPROVE_GEO and REDUCE_RHO to TRUE simultaneously.
    !call assert(.not. (improve_geo .and. reduce_rho), 'IMPROVE_GEO and REDUCE_RHO are not both TRUE', srname)
    !
    ! If SHORTD or TRFAIL is TRUE, then either IMPROVE_GEO or REDUCE_RHO is TRUE unless CLOSE_ITPSET
    ! is TRUE but SMALL_TRRAD is FALSE.
    !call assert((.not. (shortd .or. trfail)) .or. (improve_geo .or. reduce_rho .or. &
    !    & (close_itpset .and. .not. small_trrad)), 'If SHORTD or TRFAIL is TRUE, then either &
    !    & IMPROVE_GEO or REDUCE_RHO is TRUE unless CLOSE_ITPSET is TRUE but SMALL_TRRAD is FALSE', srname)
    !----------------------------------------------------------------------------------------------!

    ! Comments on REDUCE_RHO:
    ! REDUCE_RHO corresponds to Boxes 14 and 10 of the NEWUOA paper.
    ! There are two case where REDUCE_RHO will be set to TRUE.
    ! Case 1. The trust-region step is short (SHORTD) and all the recent models are sufficiently
    ! accurate (ACCURATE_MOD), which corresponds to Box 14 of the NEWUOA paper. Why do we reduce RHO
    ! in this case? The reason is well explained by the BOBYQA paper around (6.9)--(6.10). Roughly
    ! speaking, in this case, a trust-region step is unlikely to decrease the objective function
    ! according to some estimations. This suggests that the current trust-region center may be an
    ! approximate local minimizer. When this occurs, the algorithm takes the view that the work for
    ! the current RHO is complete, and hence it will reduce RHO, which will enhance the resolution
    ! of the algorithm in general. The penultimate paragraph of Sec. 2 of the NEWUOA explains why
    ! this strategy is important to efficiency: without this strategy, each value of RHO typically
    ! consumes at least NPT - 1 function evaluations, which is laborious when NPT is (modestly) big.
    ! Case 2. All the interpolation points are close to XOPT (CLOSE_ITPSET) and the trust region is
    ! small (SMALL_TRRAD), but the trust-region step is "bad" (SHORTD is TRUE or RATIO is small). In
    ! this case, the algorithm decides that the work corresponding to the current RHO is complete,
    ! and hence it shrinks RHO (i.e., update the criterion for the "closeness" and SHORTD). Surely,
    ! one may ask whether this is the best choice --- it may happen that the trust-region step is
    ! bad because the trust-region model is poor. NEWUOA takes the view that, if XPT contains points
    ! far away from XOPT, the model can be substantially improved by replacing the farthest point
    ! with a nearby one produced by the geometry step; otherwise, it does not try the geometry step.
    ! N.B.:
    ! 0. If SHORTD is TRUE at the very first iteration, then REDUCE_RHO will be set to TRUE.
    ! 1. DELTA has been updated before arriving here: if SHORTD = TRUE, then DELTA was reduced by a
    ! factor of 10; otherwise, DELTA was updated after the trust-region iteration. DELTA < DNORM may
    ! hold due to the update of DELTA.
    ! 2. If SHORTD = FALSE and KNEW_TR > 0, then XPT has been updated after the trust-region
    ! iteration; if RATIO > 0 in addition, then XOPT has been updated as well.
    ! 3. If SHORTD = TRUE and REDUCE_RHO = TRUE, the trust-region step D does not invoke a function
    ! evaluation at the current iteration, but the same D will be generated again at the next
    ! iteration after RHO is reduced and DELTA is updated. See the end of Sec 2 of the NEWUOA paper.
    ! 4. If SHORTD = FALSE and KNEW_TR = 0, then the trust-region step invokes a function evaluation
    ! at XOPT + D, but [XOPT + D, F(XOPT +D)] is not included into [XPT, FVAL]. In other words, this
    ! function value is discarded.
    ! 5. If SHORTD = FALSE, KNEW_TR > 0 and RATIO <= TENTH, then [XPT, FVAL] is updated so that
    ! [XPT(KNEW_TR), FVAL(KNEW_TR)] = [XOPT + D, F(XOPT + D)], and the model is updated accordingly,
    ! but such a model will not be used in the next trust-region iteration, because a geometry step
    ! will be invoked to improve the geometry of the interpolation set and update the model again.
    ! 6. RATIO must be set even if SHORTD = TRUE. Otherwise, compilers will raise a run-time error.
    ! 7. We can move this setting of REDUCE_RHO downward below the definition of IMPROVE_GEO and
    ! change it to REDUCE_RHO = BAD_TRSTEP .AND. (.NOT. IMPROVE_GEO) .AND. (MAX(DELTA,DNORM) <= RHO)
    ! This definition can even be moved below IF (IMPROVE_GEO) ... END IF. Although DNORM gets a new
    ! value after the geometry step when IMPROVE_GEO = TRUE, this value does not affect REDUCE_RHO,
    ! because DNORM comes into play only if IMPROVE_GEO = FALSE.

    ! Comments on IMPROVE_GEO:
    ! IMPROVE_GEO corresponds to Box 8 of the NEWUOA paper.
    ! The geometry of XPT likely needs improvement if the trust-region step is bad (SHORTD or RATIO
    ! is small). As mentioned above, NEWUOA tries improving the geometry only if some points in XPT
    ! are far away from XOPT.  In addition, if the work for the current RHO is complete, then NEWUOA
    ! reduces RHO instead of improving the geometry of XPT. Particularly, if REDUCE_RHO is true
    ! according to Box 14 of the NEWUOA paper (D is short, and the recent models are sufficiently
    ! accurate), then "trying to improve the accuracy of the model would be a waste of effort"
    ! (see Powell's comment above (7.7) of the NEWUOA paper).

    ! Comments on BAD_TRSTEP:
    ! 0. KNEW_TR == 0 means that it is impossible to obtain a good XPT by replacing a current point
    ! with the one suggested by the trust-region step. According to SETDROP_TR, KNEW_TR is 0 only if
    ! RATIO <= 0. Therefore, we can remove KNEW_TR == 0 from the definitions of BAD_TRSTEP.
    ! Nevertheless, we keep it for robustness. Powell's code includes this condition as well.
    ! 1. Powell used different thresholds (0 and 0.1) for RATIO in the definitions of BAD_TRSTEP
    ! above. Unifying them to 0 makes little difference to the performance, sometimes worsening,
    ! sometimes improving, never substantially; unifying them to 0.1 makes little difference either.
    ! Update 20220204: In the current version, unifying the two thresholds to 0 seems to worsen
    ! the performance on noise-free CUTEst problems with at most 200 variables; unifying them to 0.1
    ! worsens it a bit as well.
    ! 2. Powell's code does not have TRFAIL in BAD_TRSTEP; it terminates if TRFAIL is TRUE.
    ! 3. Update 20221108: In UOBYQA, the definition of BAD_TRSTEP involves DDMOVE, which is the norm
    ! square of XPT_OLD(:, KNEW_TR) - XOPT_OLD, where XPT_OLD and XOPT_OLD are the XPT and XOPT
    ! before UPDATEXF is called. Roughly speaking, BAD_TRSTEP is set to FALSE if KNEW_TR > 0 and
    ! DDMOVE > 2*RHO. This is critical for the performance of UOBYQA. However, the same strategy
    ! does not improve the performance of NEWUOA/BOBYQA/LINCOA in a test on 20221108/9.


    ! Since IMPROVE_GEO and REDUCE_RHO are never TRUE simultaneously, the following two blocks are
    ! exchangeable: IF (IMPROVE_GEO) ... END IF and IF (REDUCE_RHO) ... END IF.

    ! Improve the geometry of the interpolation set by removing a point and adding a new one.
    if (improve_geo) then
        ! XPT(:, KNEW_GEO) will become XOPT + D below. KNEW_GEO /= KOPT unless there is a bug.
        knew_geo = int(maxloc(distsq, dim=1), kind(knew_geo))

        ! Set DELBAR, which will be used as the trust-region radius for the geometry-improving
        ! scheme GEOSTEP. Note that DELTA has been updated before arriving here. See the comments
        ! above the definition of IMPROVE_GEO.
        delbar = max(min(TENTH * sqrt(maxval(distsq)), HALF * delta), rho)  ! Powell's code
        !delbar = rho  ! Powell's UOBYQA code
        !delbar = max(TENTH * delta, rho)  ! Powell's LINCOA code
        !delbar = max(min(TENTH * sqrt(maxval(distsq)), delta), rho)  ! Powell's BOBYQA code

        ! Find D so that the geometry of XPT will be improved when XPT(:, KNEW_GEO) becomes XOPT + D.
        ! The GEOSTEP subroutine will call Powell's BIGLAG and BIGDEN.
        d = geostep(idz, knew_geo, kopt, bmat, delbar, xpt, zmat)

        ! Calculate the next value of the objective function.
        ! If X is close to one of the points in the interpolation set, then we do not evaluate the
        ! objective function X, assuming it to have the value at the closest point.
        x = xbase + (xpt(:, kopt) + d)
        distsq = [(sum((x - (xbase + xpt(:, k)))**2, dim=1), k=1, npt)]  ! Implied do-loop
        !!MATLAB: distsq = sum((x - (xbase + xpt))**2, 1)  % Implicit expansion
        k = int(minloc(distsq, dim=1), kind(k))
        if (distsq(k) <= (1.0E-3 * rhoend)**2) then
            f = fval(k)
        else
            ! Evaluate the objective function at X, taking care of possible Inf/NaN values.
            ! call evaluate(calfun, x, f)
            nf = nf + 1_IK
            ! Save X and F into the history.
            call savehist(nf, x, xhist, f, fhist)
        end if

        ! Print a message about the function evaluation according to IPRINT.
        call fmsg(solver, 'Geometry', iprint, nf, delbar, f, x)

        ! Update DNORM_REC and MODERR_REC. (Should we?)
        ! DNORM_REC contains the DNORM of the recent function evaluations with the current RHO.
        dnorm = min(delbar, norm(d))  ! In theory, DNORM = DELBAR in this case.
        dnorm_rec = [dnorm_rec(2:size(dnorm_rec)), dnorm]

        ! MODERR is the error of the current model in predicting the change in F due to D.
        ! MODERR_REC is the prediction errors of the recent models with the current RHO.
        moderr = f - fval(kopt) - quadinc(d, xpt, gopt, pq, hq)
        moderr_rec = [moderr_rec(2:size(moderr_rec)), moderr]
        !------------------------------------------------------------------------------------------!
        ! Zaikun 20200801: Powell's code does not update DNORM. Therefore, DNORM is the length of
        ! the last trust-region trial step, which seems inconsistent with what is described in
        ! Section 7 (around (7.7)) of the NEWUOA paper. Seemingly we should keep DNORM = ||D||
        ! as we do here. The same problem exists in BOBYQA.
        !------------------------------------------------------------------------------------------!

        ! Is the newly generated X better than current best point?
        ximproved = (f < fval(kopt))

        ! Update [BMAT, ZMAT, IDZ] (represents H in the NEWUOA paper), [XPT, FVAL, KOPT] and
        ! [GOPT, HQ, PQ] (the quadratic model), so that XPT(:, KNEW_GEO) becomes XNEW = XOPT + D.
        xdrop = xpt(:, knew_geo)
        xosav = xpt(:, kopt)
        call updateh(knew_geo, kopt, d, xpt, idz, bmat, zmat)
        call updatexf(knew_geo, ximproved, f, xosav + d, kopt, fval, xpt)
        call updateq(idz, knew_geo, ximproved, bmat, d, moderr, xdrop, xosav, xpt, zmat, gopt, hq, pq)
        if (.not. (all(is_finite(gopt)) .and. all(is_finite(hq)) .and. all(is_finite(pq)))) then
            info = NAN_INF_MODEL
            exit
        end if

        ! Check whether to exit
        subinfo = checkexit(maxfun, nf, f, ftarget, x)
        if (subinfo /= INFO_DFT) then
            info = subinfo
            exit
        end if
    end if  ! End of IF (IMPROVE_GEO). The procedure of improving geometry ends.

    ! The calculations with the current RHO are complete. Enhance the resolution of the algorithm
    ! by reducing RHO; update DELTA at the same time.
    if (reduce_rho) then
        if (rho <= rhoend) then
            info = SMALL_TR_RADIUS
            exit
        end if
        delta = max(HALF * rho, redrho(rho, rhoend))
        rho = redrho(rho, rhoend)
        ! Print a message about the reduction of RHO according to IPRINT.
        call rhomsg(solver, iprint, nf, delta, fval(kopt), rho, xbase + xpt(:, kopt))
        ! DNORM_REC and MODERR_REC are corresponding to the recent function evaluations with
        ! the current RHO. Update them after reducing RHO.
        dnorm_rec = REALMAX
        moderr_rec = REALMAX
    end if  ! End of IF (REDUCE_RHO). The procedure of reducing RHO ends.

    ! Shift XBASE if XOPT may be too far from XBASE.
    ! Powell's original criteria for shifting XBASE is as follows.
    ! 1. After a trust region step that is not short, shift XBASE if SUM(XOPT**2) >= 1.0E3*DNORM**2.
    ! 2. Before a geometry step, shift XBASE if SUM(XOPT**2) >= 1.0E3*DELBAR**2.
    ! 3. 1.0E2 works better than 1.0E3 on 20230227. In addition, 1.0E2 works better than 2.0E2,
    ! 5.0E2, and 1.0E3 on 20240406, especially if RP = REAL32.
    if (sum(xpt(:, kopt)**2) >= 1.0E2_RP * delta**2) then
        call shiftbase(kopt, xbase, xpt, zmat, bmat, pq, hq, idz)
    end if

    ! Report the current best value, and check if user asks for early termination.
    if (present(callback_fcn)) then
        ! call callback_fcn(xbase + xpt(:, kopt), fval(kopt), nf, tr, terminate=terminate)
        if (terminate) then
            info = CALLBACK_TERMINATE
            exit
        end if
    end if

end do  ! End of DO TR = 1, MAXTR. The iterative procedure ends.

! Return from the calculation, after trying the Newton-Raphson step if it has not been tried yet.
x = xbase + (xpt(:, kopt) + d)
if (info == SMALL_TR_RADIUS .and. shortd .and. norm(x - (xbase + xpt(:, kopt))) > TENTH * rhoend .and. nf < maxfun) then
    ! call evaluate(calfun, x, f)
    nf = nf + 1_IK
    ! Save X, F into the history.
    call savehist(nf, x, xhist, f, fhist)
    ! Print a message about the function evaluation according to IPRINT.
    ! Zaikun 20230512: DELTA has been updated. RHO is only indicative here. TO BE IMPROVED.
    call fmsg(solver, 'Trust region', iprint, nf, rho, f, x)
    if (f < fval(kopt)) then
        xpt(:, kopt) = xpt(:, kopt) + d
        fval(kopt) = f
    end if
end if

! Choose the [X, F] to return.
x = xbase + xpt(:, kopt)
f = fval(kopt)

! Arrange FHIST and XHIST so that they are in the chronological order.
call rangehist(nf, xhist, fhist)

! Print a return message according to IPRINT.
call retmsg(solver, info, iprint, nf, f, x)

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(nf <= maxfun, 'NF <= MAXFUN', srname)
    call assert(size(x) == n .and. .not. any(is_nan(x)), 'SIZE(X) == N, X does not contain NaN', srname)
    call assert(.not. (is_nan(f) .or. is_posinf(f)), 'F is not NaN/+Inf', srname)
    call assert(size(xhist, 1) == n .and. size(xhist, 2) == maxxhist, 'SIZE(XHIST) == [N, MAXXHIST]', srname)
    call assert(.not. any(is_nan(xhist(:, 1:min(nf, maxxhist)))), 'XHIST does not contain NaN', srname)
    ! The last calculated X can be Inf (finite + finite can be Inf numerically).
    call assert(size(fhist) == maxfhist, 'SIZE(FHIST) == MAXFHIST', srname)
    call assert(.not. any(is_nan(fhist(1:min(nf, maxfhist))) .or. is_posinf(fhist(1:min(nf, maxfhist)))), &
        & 'FHIST does not contain NaN/+Inf', srname)
    call assert(.not. any(fhist(1:min(nf, maxfhist)) < f), 'F is the smallest in FHIST', srname)
end if

end subroutine newuob


end module newuob_mod
