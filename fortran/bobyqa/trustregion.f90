module trustregion_bobyqa_mod
!--------------------------------------------------------------------------------------------------!
! This module provides subroutines concerning the trust-region calculations of BOBYQA.
!
! Coded by Zaikun ZHANG (www.zhangzk.net) based on Powell's code and the BOBYQA paper.
!
! Dedicated to the late Professor M. J. D. Powell FRS (1936--2015).
!
! Started: February 2022
!
! Last Modified: Thursday, April 04, 2024 PM09:26:23
!--------------------------------------------------------------------------------------------------!

implicit none
private
public :: trsbox, trrad


contains


subroutine trsbox(delta, gopt_in, hq_in, pq_in, sl, su, tol, xopt, xpt, crvmin, d)
!--------------------------------------------------------------------------------------------------!
! This subroutine approximately solves
! minimize Q(XOPT + D) subject to ||D|| <= DELTA, SL <= XOPT + D <= SU.
! See Section 3 of the BOBYQA paper.
!
! A version of the truncated conjugate gradient is applied. If a line search is restricted by
! a constraint, then the procedure is restarted, the values of the variables that are at their
! bounds being fixed. If the trust region boundary is reached, then further changes may be made to
! D, each one being in the two dimensional space that is spanned by the current D and the gradient
! of Q at XOPT+D, staying on the trust region boundary. Termination occurs when the reduction in
! Q seems to be close to the greatest reduction that can be achieved.
!
! CRVMIN is set to zero if D reaches the trust region boundary. Otherwise it is set to the least
! curvature of H that occurs in the conjugate gradient searches that are not restricted by any
! constraints. In Powell's BOBYQA code, a negative value (-1) is assigned to CRVMIN if all of
! the conjugate gradient searches are constrained. However, we set CRVMIN = 0 in this case, which
! makes no difference to the algorithm, because CRVMIN is only used to tell whether the recent
! models are sufficiently accurate, where both CRVMIN = 0 and CRVMIN < 0 provide a negative answer.
!
! XPT, XOPT, GOPT, HQ, PQ, SL and SU have the same meanings as the corresponding arguments of BOBYQB.
! DELTA is the trust region radius for the present calculation
! XNEW will be set to a new vector of variables that is approximately the one that minimizes the
!   quadratic model within the trust region subject to the SL and SU constraints on the variables.
!   It satisfies as equations the bounds that become active during the calculation.
! GNEW holds the gradient of the quadratic model at XOPT+D. It is updated when D is updated.
! XBDI is a working space vector. For I=1,2,...,N, the element XBDI(I) is set to -1.0, 0.0, or 1.0,
!   the value being nonzero if and only if the I-th variable has become fixed at a bound, the bound
!   being SL(I) or SU(I) in the case XBDI(I)=-1.0 or XBDI(I)=1.0, respectively. This information is
!   accumulated during the construction of XNEW.
! The arrays S and HS hold the current search direction and the change in the gradient of Q along S.
!--------------------------------------------------------------------------------------------------!

! Common modules
use, non_intrinsic :: consts_mod, only : RP, IK, ZERO, ONE, TWO, TEN, HALF, REALMIN, EPS, REALMAX, &
    & DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
use, non_intrinsic :: infnan_mod, only : is_nan, is_finite
use, non_intrinsic :: linalg_mod, only : inprod, issymmetric, trueloc, norm
use, non_intrinsic :: powalg_mod, only : hess_mul
use, non_intrinsic :: univar_mod, only : interval_max

implicit none

! Inputs
real(RP), intent(in) :: delta
real(RP), intent(in) :: gopt_in(:)  ! GOPT_IN(N)
real(RP), intent(in) :: hq_in(:, :)  ! HQ_IN(N, N)
real(RP), intent(in) :: pq_in(:)  ! PQ_IN(NPT)
real(RP), intent(in) :: sl(:)  ! SL(N)
real(RP), intent(in) :: su(:)  ! SU(N)
real(RP), intent(in) :: tol
real(RP), intent(in) :: xopt(:)  ! XOPT(N)
real(RP), intent(in) :: xpt(:, :)  ! XPT(N, NPT)

! Outputs
real(RP), intent(out) :: crvmin
real(RP), intent(out) :: d(:)  ! D(N)

! Local variables
character(len=*), parameter :: srname = 'TRSBOX'
integer(IK) :: iact
integer(IK) :: n
integer(IK) :: npt
integer(IK) :: xbdi(size(gopt_in))
integer(IK) :: grid_size
integer(IK) :: iter
integer(IK) :: itercg
integer(IK) :: maxiter
integer(IK) :: nact
integer(IK) :: nactsav
logical :: scaled
logical :: twod_search
real(RP) :: beta
real(RP) :: bstep
real(RP) :: cth
real(RP) :: delsq
real(RP) :: dhd
real(RP) :: dhs
real(RP) :: dold(size(d))
real(RP) :: dredg
real(RP) :: dredsq
real(RP) :: ds
real(RP) :: ggsav
real(RP) :: gredsq
real(RP) :: hangt
real(RP) :: hangt_bd
real(RP) :: hq(size(hq_in, 1), size(hq_in, 2))
real(RP) :: pq(size(pq_in))
real(RP) :: qred
real(RP) :: rayleighq
real(RP) :: resid
real(RP) :: sbound(size(gopt_in))
real(RP) :: sdec
real(RP) :: shs
real(RP) :: sqrtd
real(RP) :: sredg
real(RP) :: stepsq
real(RP) :: sth
real(RP) :: stplen
real(RP) :: temp
real(RP) :: xtest(size(xopt))
real(RP) :: args(5)
real(RP) :: dred(size(gopt_in))
real(RP) :: gnew(size(gopt_in))
real(RP) :: gopt(size(gopt_in))
real(RP) :: hdred(size(gopt_in))
real(RP) :: hs(size(gopt_in))
real(RP) :: modscal
real(RP) :: s(size(gopt_in))
real(RP) :: sqdscr(size(gopt_in))
real(RP) :: ssq(size(gopt_in))
real(RP) :: tanbd(size(gopt_in))
real(RP) :: xnew(size(gopt_in))

! Sizes
n = int(size(gopt_in), kind(n))
npt = int(size(pq_in), kind(npt))

! Preconditions
if (DEBUGGING) then
    call assert(n >= 1 .and. npt >= n + 2, 'N >= 1, NPT >= N + 2', srname)
    call assert(delta > 0, 'DELTA > 0', srname)
    call assert(size(hq_in, 1) == n .and. issymmetric(hq_in), 'HQ is n-by-n and symmetric', srname)
    call assert(size(pq_in) == npt, 'SIZE(PQ) == NPT', srname)
    call assert(size(sl) == n .and. all(sl <= 0), 'SIZE(SL) == N, SL <= 0', srname)
    call assert(size(su) == n .and. all(su >= 0), 'SIZE(SU) == N, SU >= 0', srname)
    call assert(size(xopt) == n .and. all(is_finite(xopt)), 'SIZE(XOPT) == N, XOPT is finite', srname)
    call assert(all(xopt >= sl .and. xopt <= su), 'SL <= XOPT <= SU', srname)
    call assert(size(xpt, 1) == n .and. size(xpt, 2) == npt, 'SIZE(XPT) == [N, NPT]', srname)
    call assert(all(is_finite(xpt)), 'XPT is finite', srname)
    ! call assert(all(xpt >= spread(sl, dim=2, ncopies=npt)) .and. &
    !     & all(xpt <= spread(su, dim=2, ncopies=npt)), 'SL <= XPT <= SU', srname)
    call assert(size(d) == n, 'SIZE(D) == N', srname)
    call assert(size(gnew) == n, 'SIZE(GNEW) == N', srname)
    call assert(size(xnew) == n, 'SIZE(XNEW) == N', srname)
end if

!====================!
! Calculation starts !
!====================!

! Scale the problem if GOPT contains large values. Otherwise, floating point exceptions may occur.
! Note that CRVMIN must be scaled back if it is nonzero, but step is scale invariant.
! N.B.: It is faster and safer to scale by multiplying a reciprocal than by division. See
! https://fortran-lang.discourse.group/t/ifort-ifort-2021-8-0-1-0e-37-1-0e-38-0/
if (maxval(abs(gopt_in)) > 1.0E12) then  ! The threshold is empirical.
    modscal = max(TWO * REALMIN, ONE / maxval(abs(gopt_in)))  ! MAX: precaution against underflow.
    gopt = gopt_in * modscal
    pq = pq_in * modscal
    hq = hq_in * modscal
    scaled = .true.
else
    modscal = ONE  ! This value is not used, but Fortran compilers may complain without it.
    gopt = gopt_in
    pq = pq_in
    hq = hq_in
    scaled = .false.
end if

! The initial values of IACT, DREDSQ, and GGSAV are unused but to entertain Fortran compilers.
! TODO: Check that GGSAV has been initialized before used.
iact = 0
dredsq = ZERO
ggsav = ZERO

! The sign of GOPT(I) gives the sign of the change to the I-th variable that will reduce Q from its
! value at XOPT. Thus XBDI(I) shows whether or not to fix the I-th variable at one of its bounds
! initially, with NACT being set to the number of fixed variables.
xbdi = 0
xbdi(trueloc(xopt >= su .and. gopt <= 0)) = 1
xbdi(trueloc(xopt <= sl .and. gopt >= 0)) = -1
nact = int(count(xbdi /= 0), kind(nact))

! Initialized D and CRVMIN.
d = ZERO
crvmin = -REALMAX

! GNEW is the gradient at the current iterate.
gnew = gopt
gredsq = sum(gnew(trueloc(xbdi == 0))**2)
! DELSQ is the upper bound on the sum of squares of the free variables.
delsq = delta * delta
! QRED is the reduction in Q so far.
qred = ZERO
! BETA is the coefficient for the previous searching direction in the conjugate gradient method.
beta = ZERO

! ITERCG is the number of CG iterations corresponding to the current set of active bounds.
itercg = 0

! TWOD_SEARCH: whether to perform a 2-dimensional search after the truncated CG method.
twod_search = .false.  ! The default value of TWOD_SEARCH is FALSE!

! Powell's code is essentially a DO WHILE loop. We impose an explicit MAXITER.
! The formulation of MAXITER below contains a precaution against overflow. In MATLAB/Python/Julia/R,
! we can write maxiter = min(10000, (n - nact)^2).
! Powell commented in the BOBYQA paper (the paragraph above (3.7)) that "numerical experiments show
! that it is very unusual for subroutine TRSBOX to make more than ten changes to d when seeking an
! approximate solution to the subproblem (1.8), even if there are hundreds of variables."
maxiter = int(min(10**min(4, range(0_IK)), int(n - nact)**2), IK)
do iter = 1, maxiter
    resid = delsq - sum(d(trueloc(xbdi == 0))**2)
    if (resid <= 0) then
        twod_search = .true.
        exit
    end if

    ! Set the next search direction of the conjugate gradient method. It is the steepest descent
    ! direction initially and when the iterations are restarted because a variable has just been
    ! fixed by a bound, and of course the components of the fixed variables are zero. MAXITER is an
    ! upper bound on the indices of the conjugate gradient iterations.
    if (itercg == 0) then
        ! TODO: If we are sure that S contain only finite values, we may merge this case into the next.
        s = -gnew
    else
        s = beta * s - gnew
    end if
    s(trueloc(xbdi /= 0)) = ZERO
    stepsq = sum(s**2)
    ds = inprod(d(trueloc(xbdi == 0)), s(trueloc(xbdi == 0)))

    if (.not. (stepsq > EPS * delsq .and. gredsq * delsq > (tol * qred)**2 .and. .not. is_nan(ds))) then
        exit
    end if

    ! Set BSTEP to the length of the step to the trust region boundary and STPLEN to the steplength,
    ! ignoring the simple bounds.

    ! SQRTD: square root of a discriminant. The MAXVAL avoids SQRTD < ABS(DS) due to underflow.
    sqrtd = maxval([sqrt(stepsq * resid + ds * ds), sqrt(stepsq * resid), abs(ds)])

    ! Zaikun 20220210: For the IF ... ELSE ... END IF below, Powell's condition for the IF is DS>=0.
    ! In theory, switching the condition to DS > 0 changes nothing; indeed, the two formulations
    ! of BSTEP are equivalent. However, surprisingly, DS > 0 clearly worsens the performance of
    ! BOBYQA in tests on 20220210, 20221206. Why? When DS = 0, what should be the best formulation?
    ! What if we are at the first iteration? BSTEP = DELTA/||D||?
    ! See TRSAPP.F90 of NEWUOA.
    !if (ds > 0) then  ! Zaikun 20210925
    if (ds >= 0) then
        bstep = resid / (sqrtd + ds)
    else
        bstep = (sqrtd - ds) / stepsq
    end if
    ! BSTEP < 0 should not happen. BSTEP can be 0 or NaN when, e.g., DS or STEPSQ becomes Inf.
    ! Powell's code does not handle this.
    if (bstep <= 0 .or. .not. is_finite(bstep)) then
        exit
    end if

    hs = hess_mul(s, xpt, pq, hq)
    shs = inprod(s(trueloc(xbdi == 0)), hs(trueloc(xbdi == 0)))
    stplen = bstep
    if (shs > 0) then
        stplen = min(bstep, gredsq / shs)
    end if

    ! Reduce STPLEN if necessary in order to preserve the simple bounds, letting IACT be the index
    ! of the new constrained variable.
    ! N.B. (Zaikun 20220422):
    ! Theory and computation differ considerably in the calculation of STPLEN and IACT.
    ! 1. Theoretically, the WHERE constructs can simplify (S > 0 .and. XTEST > SU) to (S > 0) and
    ! (S < 0, XTEST < SL) to (S < 0), which will be equivalent to Powell's original code. However,
    ! overflow will occur due to huge values in SU or SL that indicate the absence of bounds, and
    ! Fortran compilers will complain. It is not an issue in MATLAB/Python/Julia/R.
    ! 2. Theoretically, we can also simplify (S > 0 .and. XTEST > SU) to (XTEST > SU). This is
    ! because the algorithm intends to ensure that SL <= XSUM <= SU, under which the inequality
    ! XTEST(I) > SU(I) implies S(I) > 0. Numerically, however, XSUM may violate the bounds slightly
    ! due to rounding. If we replace (S > 0 .and. XTEST > SU) with (XTEST > SU), then SBOUND(I) will
    ! be -Inf when SU(I) - XSUM(I) is negative (although tiny) and S(I) is +0 (positively signed
    ! zero), which will lead to STPLEN = -Inf and IACT = I > 0. This will trigger a restart of the
    ! conjugate gradient method with DELSQ updated to DELSQ - D(IACT)**2; if D(IACT)**2 << DELSQ,
    ! then DELSQ can remain unchanged due to rounding, leading to an infinite cycling.
    ! 3. Theoretically, the WHERE construct corresponding to S > 0 can calculate SBOUND by
    ! MIN(STPLEN * S, SU - XSUM) / S instead of (SU - XSUM) / S, since this quotient matters only if
    ! it is less than STPLEN. The motivation is to avoid overflow even without checking XTEST > XU.
    ! Yet such an implementation clearly worsens the performance of BOBYQA in our test on 20220422.
    ! Why? Note that the conjugate gradient method restarts when IACT > 0. Due to rounding errors,
    ! MIN(STPLEN * S, SU - XSUM) / S can frequently contain entries less than STPLEN, leading to a
    ! positive IACT and hence a restart. This turns out harmful to the performance of the algorithm,
    ! but WHY? It can be rectified in two ways: use MIN(STPLEN, (SU-XSUM) / S) instead of
    ! MIN(STPLEN*S, SU-XSUM)/S, or set IACT to a positive value only if the minimum of SBOUND is
    ! surely less STPLEN, e.g. ANY(SBOUND < (ONE-EPS) * STPLEN). The first method does not avoid
    ! overflow and makes little sense.
    xnew = xopt + d
    xtest = xnew + stplen * s
    sbound = stplen
    where (s > 0 .and. xtest > su) sbound = (su - xnew) / s
    where (s < 0 .and. xtest < sl) sbound = (sl - xnew) / s
    !!MATLAB:
    !!sbound(s > 0) = (su(s > 0) - xnew(s > 0)) / s(s > 0);
    !!sbound(s < 0) = (sl(s < 0) - xnew(s < 0)) / s(s < 0);
    !----------------------------------------------------------------------------------------------!
    ! The code below is mathematically equivalent to the above but numerically inferior as explained.
    !where (s > 0) sbound = min(stplen * s, su - xnew) / s
    !where (s < 0) sbound = max(stplen * s, sl - xnew) / s
    !----------------------------------------------------------------------------------------------!
    sbound(trueloc(is_nan(sbound))) = stplen  ! Needed? No if we are sure that D and S are finite.
    iact = 0
    if (any(sbound < stplen)) then
        iact = int(minloc(sbound, dim=1), kind(iact))
        stplen = sbound(iact)
        !!MATLAB: [stplen, iact] = min(sbound);
    end if
    !----------------------------------------------------------------------------------------------!
    ! Alternatively, IACT and STPLEN can be calculated as below.
    ! !IACT = INT(MINLOC([STPLEN, SBOUND], DIM=1), KIND(IACT)) - 1_IK
    ! !STPLEN = MINVAL([STPLEN, SBOUND]) ! This line cannot be exchanged with the last
    ! We prefer our implementation, as the code is more explicit; in addition, it is more flexible:
    ! we can change the condition ANY(SBOUND < STPLEN) to ANY(SBOUND < (1 - EPS) * STPLEN) or
    ! ANY(SBOUND < (1 + EPS) * STPLEN), depending on whether we believe a false positive or a false
    ! negative of IACT > 0 is more harmful --- according to our test on 20220422, it is the former,
    ! as mentioned above.
    !----------------------------------------------------------------------------------------------!

    ! Update CRVMIN, GNEW, and D. Set SDEC to the decrease that occurs in Q.
    sdec = ZERO
    if (stplen > 0) then
        itercg = itercg + 1_IK
        rayleighq = shs / stepsq
        if (iact == 0 .and. rayleighq > 0) then
            if (crvmin <= -REALMAX) then  ! CRVMIN <= -REALMAX means CRVMIN has not been set.
                crvmin = rayleighq
            else
                crvmin = min(crvmin, rayleighq)
            end if
        end if
        ggsav = gredsq
        gnew = gnew + stplen * hs
        gredsq = sum(gnew(trueloc(xbdi == 0))**2)
        dold = d
        d = d + stplen * s

        ! Exit in case of Inf/NaN in D.
        if (.not. is_finite(sum(abs(d)))) then
            d = dold
            exit
        end if

        sdec = max(stplen * (ggsav - HALF * stplen * shs), ZERO)
        qred = qred + sdec
    end if

    ! Restart the conjugate gradient method if it has hit a new bound.
    if (iact > 0) then
        nact = nact + 1_IK
        call assert(abs(s(iact)) > 0, 'S(IACT) /= 0', srname)
        xbdi(iact) = nint(sign(ONE, s(iact)), kind(xbdi))  !!MATLAB: xbdi(iact) = sign(s(iact))
        ! Exit when NACT = N (NACT > N is impossible). We must update XBDI before exiting!
        if (nact >= n) then
            exit  ! This leads to a difference. Why?
        end if
        delsq = delsq - d(iact)**2
        if (delsq <= 0) then
            twod_search = .true.
            ! Why set TWOD_SEARCH to TRUE? Because DELSQ <= 0 just means that D reaches the trust
            ! region boundary.
            exit
        end if
        beta = ZERO
        itercg = 0
        gredsq = sum(gnew(trueloc(xbdi == 0))**2)
    elseif (stplen < bstep) then
        ! Either apply another conjugate gradient iteration or exit.
        ! N.B. ITERCG > N - NACT is impossible.
        if (itercg >= n - nact .or. sdec <= tol * qred .or. is_nan(sdec) .or. is_nan(qred)) then
            exit
        end if
        beta = gredsq / ggsav  ! Has GGSAV got the correct value yet?
    else
        twod_search = .true.
        exit
    end if
end do

! Set MAXITER for the 2-dimensional search on the trust region boundary. Powell's code essentially
! sets MAXITER to infinity; the loop exits when NACT >= N-1 or the procedure cannot significantly
! reduce the quadratic model. We set a finite but large MAXITER as a safeguard.
if (twod_search) then
    crvmin = ZERO
    maxiter = 10_IK * (n - nact)
else
    maxiter = 0
end if

! Improve D by a sequential 2-dimensional search on the boundary of the trust region for the
! variables that have not reached a bound. See (3.6) of the BOBYQA paper and the elaborations nearby.
! 1. At each iteration, the current D is improved by a search conducted on the circular arch
! {D(THETA): D(THETA) = (I-P)*D + [COS(THETA)*P*D + SIN(THETA)*S], 0<=THETA<=PI/2, SL<=XOPT+D(THETA)<=SU},
! where P is the orthogonal projection onto the space of the variables that have not reached their
! bounds, and S is a linear combination of P*D and P*G(XOPT+D) with ||S|| = ||P*D|| and G(.) being
! the gradient of the quadratic model. The iteration is performed only if P*D and P*G(XOPT+D) are
! not nearly parallel. The arc lies in the hyperplane (I-P)*D + Span{P*D, P*G(XOPT+D)} and the trust
! region boundary {D: ||D||=DELTA}; it is part of the circle (I-P)*D + {COS(THETA)*P*D + SIN(THETA)*S}
! with THETA being in [0, PI/2] and restricted by the bounds on X.
! 2. In (3.6) of the BOBYQA paper, Powell wrote that 0 <= THETA <= PI/4, which seems a typo.
! 3. The search on the arch is done by calling INTERVAL_MAX, which maximizes INTERVAL_FUN_TRSBOX.
! INTERVAL_FUN_TRSBOX is essentially Q(XOPT + D) - Q(XOPT + D(THETA)), but its independent variable
! is not THETA but TAN(THETA/2), namely "tangent of the half angle" in Powell's code/comments. This
! "half" may be the reason for the apparent typo mentioned above.
! Question (Zaikun 20220424): Shouldn't we try something similar in GEOSTEP?

nactsav = nact - 1_IK
do iter = 1, maxiter
    xnew = xopt + d

    ! Update XBDI. It indicates whether the lower (-1) or upper bound (+1) is reached or not (0).
    xbdi(trueloc(xbdi == 0 .and. (xnew >= su))) = 1
    xbdi(trueloc(xbdi == 0 .and. (xnew <= sl))) = -1
    nact = int(count(xbdi /= 0), kind(nact))
    if (nact >= n - 1) then
        exit
    end if

    ! Update GREDSQ, DREDG, DREDSQ.
    gredsq = sum(gnew(trueloc(xbdi == 0))**2)
    dredg = inprod(d(trueloc(xbdi == 0)), gnew(trueloc(xbdi == 0)))
    if (iter == 1 .or. nact > nactsav) then
        dredsq = sum(d(trueloc(xbdi == 0))**2) ! In theory, DREDSQ changes only when NACT increases.
        dred = d
        dred(trueloc(xbdi /= 0)) = ZERO
        hdred = hess_mul(dred, xpt, pq, hq)
        nactsav = nact
    end if

    ! Let the search direction S be a linear combination of the reduced D and the reduced G that is
    ! orthogonal to the reduced D.
    temp = gredsq * dredsq - dredg * dredg
    if (.not. temp > tol**2 * max(gredsq * dredsq, qred**2)) then  ! TEMP is tiny or NaN occurs
        exit
    end if
    temp = sqrt(temp)
    s = (dredg * d - dredsq * gnew) / temp
    s(trueloc(xbdi /= 0)) = ZERO
    sredg = -temp

    ! By considering the simple bounds on the free variables, calculate an upper bound on the
    ! TANGENT of HALF the angle of the alternative iteration, namely ANGBD. The bounds are
    ! SL - XOPT <= COS(THETA)*D + SIN(THETA)*S <= SU - XOPT for the free variables.
    ! Defining HANGT = TAN(THETA/2), and using the tangent half-angle formula, we have
    ! (1+HANGT^2)*(SL - XOPT) <= (1-HANGT^2)*D + 2*HANGT*S <= (1+HANGT^2)*(SU - XOPT),
    ! which is required for all free variables. The indices of the free variable are those with
    ! XBDI == 0. Solving this inequality system for HANGT in [0, PI/4], we get bounds for HANGT,
    ! namely TANBD; the final bound for HANGT is the minimum of TANBD, which is HANGT_BD.
    ! When solving the system, note that SL < XOPT < SU and SL < XOPT + D < SU if XBDI = 0.
    !
    ! Note the following for the calculation of the first SQDSCR below (the second is similar).
    ! 0. SQDSCR means "square root of discriminant".
    ! 1. When calculating the first SQDSCR, Powell's code checks whether SSQ - (XOPT - SL)**2) is
    ! positive. However, overflow will occur if SL contains large values that indicate absence of
    ! bounds. It is not a problem in MATLAB/Python/Julia/R.
    ! 2. Even if XOPT - SL < SQRT(SSQ), rounding errors may render SSQ - (XOPT - SL)**2) < 0.
    ssq = d**2 + s**2  ! Indeed, only SSQ(TRUELOC(XBDI == 0)) is needed.
    tanbd = ONE
    sqdscr = -REALMAX
    where (xbdi == 0 .and. xopt - sl < sqrt(ssq)) sqdscr = sqrt(max(ZERO, ssq - (xopt - sl)**2))
    where (sqdscr - s > 0) tanbd = min(tanbd, (xnew - sl) / (sqdscr - s))
    sqdscr = -REALMAX
    where (xbdi == 0 .and. su - xopt < sqrt(ssq)) sqdscr = sqrt(max(ZERO, ssq - (su - xopt)**2))
    where (sqdscr + s > 0) tanbd = min(tanbd, (su - xnew) / (sqdscr + s))
    tanbd(trueloc(is_nan(tanbd))) = ZERO
    !----------------------------------------------------------------------------------------------!
    !!MATLAB code for defining TANBD:
    !!xfree = (xbdi == 0);
    !!ssq = NaN(n, 1);
    !!ssq(xfree) = s(xfree).^2 + d(xfree).^2;
    !!discmn = NaN(n, 1);
    !!discmn(xfree) = ssq(xfree) - (xopt(xfree) - sl(xfree))**2;  % This is a discriminant.
    !!tanbd = 1;
    !!mask = (xfree & discmn > 0 & sqrt(discmn) - s > 0);
    !!tanbd(mask) = min(tanbd(mask), (xnew(mask) - sl(mask)) / (sqrt(discmn(mask)) - s(mask)));
    !!discmn(xfree) = ssq(xfree) - (su(xfree) - xopt(xfree))**2;  % This is a discriminant.
    !!mask = (xfree & discmn > 0 & sqrt(discmn) + s > 0);
    !!tanbd(mask) = min(tanbd(mask), (su(mask) - xnew(mask)) / (sqrt(discmn(mask)) + s(mask)));
    !!tanbd(isnan(tanbd)) = 0;
    !----------------------------------------------------------------------------------------------!

    iact = 0
    hangt_bd = ONE
    if (any(tanbd < 1)) then
        iact = int(minloc(tanbd, dim=1), kind(iact))
        hangt_bd = tanbd(iact)
        !!MATLAB: [hangt_bd, iact] = min(tanbd);
    end if
    if (hangt_bd <= 0) then
        exit
    end if

    ! Calculate HS and some curvatures for the alternative iteration.
    hs = hess_mul(s, xpt, pq, hq)
    shs = inprod(s(trueloc(xbdi == 0)), hs(trueloc(xbdi == 0)))
    dhs = inprod(d(trueloc(xbdi == 0)), hs(trueloc(xbdi == 0)))
    dhd = inprod(d(trueloc(xbdi == 0)), hdred(trueloc(xbdi == 0)))

    ! Seek the greatest reduction in Q for a range of equally spaced values of HANGT in [0, ANGBD],
    ! with HANGT being the TANGENT of HALF the angle of the alternative iteration.
    args = [shs, dhd, dhs, dredg, sredg]
    if (any(is_nan(args))) then
        exit
    end if
    ! Define the grid size of the search for HANGT. Powell defined the size to be 4 if hangt_bd is
    ! nearly zero and 20 if it is nearly one, with a linear interpolation in between. We double this
    ! size, which improves the performance of BOBYQA in general according to a test on 20230827.
    !grid_size = nint(17.0_RP * hangt_bd + 4.1_RP, kind(grid_size))  ! Powell's version
    grid_size = 2_IK * nint(17.0_RP * hangt_bd + 4.1_RP, kind(grid_size))
    !!MATLAB: grid_size = 2 * round(17 * hangt_bd + 4.1_RP)
    hangt = interval_max(interval_fun_trsbox, ZERO, hangt_bd, args, grid_size)
    sdec = interval_fun_trsbox(hangt, args)
    if (.not. sdec > 0) then
        exit
    end if

    ! Update GNEW, D and HDRED. If the angle of the alternative iteration is restricted by a bound
    ! on a free variable, that variable is fixed at the bound. The MIN below is a precaution against
    ! rounding errors.
    cth = min((ONE - hangt**2) / (ONE + hangt**2), ONE - hangt**2)
    sth = min((hangt + hangt) / (ONE + hangt**2), hangt + hangt)
    gnew = gnew + (cth - ONE) * hdred + sth * hs
    dold = d
    d(trueloc(xbdi == 0)) = cth * d(trueloc(xbdi == 0)) + sth * s(trueloc(xbdi == 0))

    ! Exit in case of Inf/NaN in D.
    if (.not. is_finite(sum(abs(d)))) then
        d = dold
        exit
    end if

    hdred = cth * hdred + sth * hs
    qred = qred + sdec
    if (iact >= 1 .and. iact <= n .and. hangt >= hangt_bd) then  ! D(IACT) reaches lower/upper bound.
        xbdi(iact) = nint(sign(ONE, xopt(iact) + d(iact) - HALF * (sl(iact) + su(iact))), kind(xbdi))
        !!MATLAB: xbdi(iact) = sign(xopt(iact)+d(iact) - 0.5*(sl+su));
    elseif (.not. sdec > tol * qred) then  ! SDEC is small or NaN occurs
        exit
    end if
end do

! Set D, giving careful attention to the bounds.
xnew = max(sl, min(su, xopt + d))
xnew(trueloc(xbdi == -1)) = sl(trueloc(xbdi == -1))
xnew(trueloc(xbdi == 1)) = su(trueloc(xbdi == 1))
d = xnew - xopt

! Set CRVMIN to ZERO if it has never been set or becomes NaN due to ill conditioning.
if (crvmin <= -REALMAX .or. is_nan(crvmin)) then
    crvmin = ZERO
end if

! Scale CRVMIN back before return. Note that the trust-region step is scale invariant.
if (scaled .and. crvmin > 0) then
    crvmin = crvmin / modscal
end if

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(size(d) == n .and. all(is_finite(d)), 'SIZE(D) == N, D is finite', srname)
    ! Due to rounding, it may happen that ||D|| > DELTA, but ||D|| > 2*DELTA is highly improbable.
    call assert(norm(d) <= TWO * delta, '||D|| <= 2*DELTA', srname)
    call assert(crvmin >= 0, 'CRVMIN >= 0', srname)
    ! D is supposed to satisfy the bound constraints SL <= XOPT + D <= SU.
    call assert(all(xopt + d >= sl - TEN * EPS * max(ONE, abs(sl)) .and. &
        & xopt + d <= su + TEN * EPS * max(ONE, abs(su))), 'SL <= XOPT + D <= SU', srname)
end if

end subroutine trsbox


function interval_fun_trsbox(hangt, args) result(f)
!--------------------------------------------------------------------------------------------------!
! This function defines the objective function of the search for HANGT in TRSBOX, with HANGT being
! the TANGENT of HALF the angle of the "alternative iteration".
!--------------------------------------------------------------------------------------------------!
use, non_intrinsic :: consts_mod, only : RP, ZERO, ONE, HALF, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
implicit none

! Inputs
real(RP), intent(in) :: hangt
real(RP), intent(in) :: args(:)

! Outputs
real(RP) :: f

! Local variables
character(len=*), parameter :: srname = 'INTERVAL_FUN_TRSBOX'
real(RP) :: sth

! Preconditions
if (DEBUGGING) then
    call assert(size(args) == 5, 'SIZE(ARGS) == 5', srname)
end if

!====================!
! Calculation starts !
!====================!

f = ZERO
if (abs(hangt) > 0) then
    sth = (hangt + hangt) / (ONE + hangt * hangt)
    f = args(1) + hangt * (hangt * args(2) - args(3) - args(3))
    f = sth * (hangt * args(4) - args(5) - HALF * sth * f)
    ! N.B.: ARGS = [SHS, DHD, DHS, DREDG, SREDG]
end if

!====================!
!  Calculation ends  !
!====================!
end function interval_fun_trsbox


function trrad(delta_in, dnorm, eta1, eta2, gamma1, gamma2, ratio) result(delta)
!--------------------------------------------------------------------------------------------------!
! This function updates the trust region radius according to RATIO and DNORM.
!--------------------------------------------------------------------------------------------------!

! Generic module
use, non_intrinsic :: consts_mod, only : RP, DEBUGGING
use, non_intrinsic :: infnan_mod, only : is_nan
use, non_intrinsic :: debug_mod, only : assert

implicit none

! Input
real(RP), intent(in) :: delta_in   ! Current trust-region radius
real(RP), intent(in) :: dnorm   ! Norm of current trust-region step
real(RP), intent(in) :: eta1    ! Ratio threshold for contraction
real(RP), intent(in) :: eta2    ! Ratio threshold for expansion
real(RP), intent(in) :: gamma1  ! Contraction factor
real(RP), intent(in) :: gamma2  ! Expansion factor
real(RP), intent(in) :: ratio   ! Reduction ratio

! Outputs
real(RP) :: delta

! Local variables
character(len=*), parameter :: srname = 'TRRAD'

! Preconditions
if (DEBUGGING) then
    call assert(delta_in >= dnorm .and. dnorm > 0, 'DELTA_IN >= DNORM > 0', srname)
    call assert(eta1 >= 0 .and. eta1 <= eta2 .and. eta2 < 1, '0 <= ETA1 <= ETA2 < 1', srname)
    call assert(eta1 >= 0 .and. eta1 <= eta2 .and. eta2 < 1, '0 <= ETA1 <= ETA2 < 1', srname)
    call assert(gamma1 > 0 .and. gamma1 < 1 .and. gamma2 > 1, '0 < GAMMA1 < 1 < GAMMA2', srname)
    ! By the definition of RATIO in ratio.f90, RATIO cannot be NaN unless the actual reduction is
    ! NaN, which should NOT happen due to the moderated extreme barrier.
    call assert(.not. is_nan(ratio), 'RATIO is not NaN', srname)
end if

!====================!
! Calculation starts !
!====================!

if (ratio <= eta1) then
    delta = min(gamma1 * delta_in, dnorm)  ! Powell's BOBYQA.
    !delta = gamma1 * dnorm  ! Powell's UOBYQA/NEWUOA.
    !delta = gamma1 * delta_in  ! Powell's COBYLA/LINCOA. Works poorly here.
elseif (ratio <= eta2) then
    delta = max(gamma1 * delta_in, dnorm)    ! Powell's UOBYQA/NEWUOA/BOBYQA/LINCOA
else
    delta = max(gamma1 * delta_in, gamma2 * dnorm)  ! Powell's NEWUOA/BOBYQA.
    !delta = max(delta_in, gamma2 * dnorm)  ! Modified version. Works well for UOBYQA.
    !delta = max(delta_in, 1.25_RP * dnorm, dnorm + rho)  ! Powell's UOBYQA
    !delta = min(max(gamma1 * delta_in, gamma2 * dnorm), sqrt(gamma2) * delta_in)  ! Powell's LINCOA.
end if

! For noisy problems, the following may work better.
! !if (ratio <= eta1) then
! !    delta = gamma1 * dnorm
! !elseif (ratio <= eta2) then  ! Ensure DELTA >= DELTA_IN
! !    delta = delta_in
! !else  ! Ensure DELTA > DELTA_IN with a constant factor
! !    delta = max(delta_in * (1.0_RP + gamma2) / 2.0_RP, gamma2 * dnorm)
! !end if

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(delta > 0, 'DELTA > 0', srname)
end if

end function trrad


end module trustregion_bobyqa_mod
