module initialize_uobyqa_mod
!--------------------------------------------------------------------------------------------------!
! This module performs the initialization of UOBYQA, described in Section 4 of the UOBYQA paper.
!
! Coded by Zaikun ZHANG (www.zhangzk.net) based on Powell's code and the UOBYQA paper.
!
! Started: July 2020
!
! Dedicated to the late Professor M. J. D. Powell FRS (1936--2015).
!
! Last Modified: Saturday, March 16, 2024 PM04:50:24
!--------------------------------------------------------------------------------------------------!

implicit none
private
public :: initxf, initq, initl


contains


subroutine initxf(calfun, iprint, maxfun, ftarget, rhobeg, x0, kopt, nf, fhist, fval, xbase, &
    & xhist, xpt, info)
!--------------------------------------------------------------------------------------------------!
! This subroutine does the initialization about the interpolation points & their function values.
! See Section 4 of the UOBYQA paper.
!--------------------------------------------------------------------------------------------------!

! Common modules
use, non_intrinsic :: checkexit_mod, only : checkexit
use, non_intrinsic :: consts_mod, only : RP, IK, ZERO, TWO, REALMAX, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
! use, non_intrinsic :: evaluate_mod, only : evaluate
use, non_intrinsic :: history_mod, only : savehist
use, non_intrinsic :: infnan_mod, only : is_finite, is_posinf, is_nan
use, non_intrinsic :: infos_mod, only : INFO_DFT
use, non_intrinsic :: linalg_mod, only : eye, trueloc, linspace
use, non_intrinsic :: message_mod, only : fmsg
use, non_intrinsic :: pintrf_mod, only : OBJ

implicit none

! Inputs
procedure(OBJ) :: calfun  ! N.B.: INTENT cannot be specified if a dummy procedure is not a POINTER
integer(IK), intent(in) :: iprint
integer(IK), intent(in) :: maxfun
real(RP), intent(in) :: ftarget
real(RP), intent(in) :: rhobeg
real(RP), intent(in) :: x0(:)   ! X0(N)

! Outputs
integer(IK), intent(out) :: info
integer(IK), intent(out) :: kopt
integer(IK), intent(out) :: nf
real(RP), intent(out) :: fhist(:)   ! FHIST(MAXFHIST)
real(RP), intent(out) :: fval(:)
real(RP), intent(out) :: xbase(:)   ! XBASE(N)
real(RP), intent(out) :: xhist(:, :)    ! XHIST(N, MAXXHIST)
real(RP), intent(out) :: xpt(:, :)  ! XPT(N, NPT)

! Local variables
character(len=*), parameter :: solver = 'UOBYQA'
character(len=*), parameter :: srname = 'INITXF'
integer(IK) :: ip
integer(IK) :: iq
integer(IK) :: k
integer(IK) :: kk(size(x0))
integer(IK) :: maxfhist
integer(IK) :: maxhist
integer(IK) :: maxxhist
integer(IK) :: n
integer(IK) :: npt
integer(IK) :: subinfo
integer(IK) :: i, j
logical :: evaluated(size(xpt, 2))
real(RP) :: f
real(RP) :: x(size(x0))
real(RP) :: xw(size(x0))
real(RP), dimension(:, :), allocatable:: eye_matrix

! Sizes
n = int(size(xpt, 1), kind(n))
npt = int(size(xpt, 2), kind(npt))
maxxhist = int(size(xhist, 2), kind(maxxhist))
maxfhist = int(size(fhist), kind(maxfhist))
maxhist = max(maxxhist, maxfhist)

! Preconditions
if (DEBUGGING) then
    call assert(abs(iprint) <= 3, 'IPRINT is 0, 1, -1, 2, -2, 3, or -3', srname)
    call assert(n >= 1 .and. npt == (n + 1) * (n + 2) / 2, 'N >= 1, NPT == (N+1)*(N+2)/2', srname)
    call assert(maxfun >= npt + 1, 'MAXFUN >= NPT + 1', srname)
    call assert(maxhist >= 0 .and. maxhist <= maxfun, '0 <= MAXHIST <= MAXFUN', srname)
    call assert(maxfhist * (maxfhist - maxhist) == 0, 'SIZE(FHIST) == 0 or MAXHIST', srname)
    call assert(size(fval) == npt, 'SIZE(FVAL) == NPT', srname)
    call assert(size(xhist, 1) == n .and. maxxhist * (maxxhist - maxhist) == 0, &
        & 'SIZE(XHIST, 1) == N, SIZE(XHIST, 2) == 0 or MAXHIST', srname)
    call assert(rhobeg > 0, 'RHOBEG > 0', srname)
    call assert(size(x0) == n .and. all(is_finite(x0)), 'SIZE(X0) == N, X0 is finite', srname)
    call assert(size(xbase) == n, 'SIZE(XBASE) == N', srname)
end if

!====================!
! Calculation starts !
!====================!

! Initialize INFO to the default value. At return, an INFO different from this value will indicate
! an abnormal return.
info = INFO_DFT

! Initialize XBASE to X0.
xbase = x0

! EVALUATED is a boolean array with EVALUATED(I) indicating whether the function value of the I-th
! interpolation point has been evaluated. We need it for a portable counting of the number of
! function evaluations, especially if the loop is conducted asynchronously. However, the loop here
! is not fully parallelizable if NPT>2N+1, as the definition XPT(:, 2N+2:end) involves FVAL(1:2N+1).
evaluated = .false.

! Initialize XHIST, FHIST, and FVAL. Otherwise, compilers may complain that they are not
! (completely) initialized if the initialization aborts due to abnormality (see CHECKEXIT).
! N.B.: 1. Initializing them to NaN would be more reasonable (NaN is not available in Fortran).
! 2. Do not initialize the models if the current initialization aborts due to abnormality. Otherwise,
! errors or exceptions may occur, as FVAL and XPT etc are uninitialized.
xhist = -REALMAX
fhist = REALMAX
fval = REALMAX

! Set XPT(:, 1 : 2*N+1) and FVAL(:, 1 : 2*N+1).
xpt = ZERO
kk = linspace(2_IK, 2_IK * n, n)
! xpt(:, kk) = rhobeg * eye(n)
allocate(eye_matrix(n, n))
eye_matrix = 0.0
do i = 1, n
    eye_matrix(i, i) = 1.0
end do

do j = 1, n
    xpt(:, j) = rhobeg * eye_matrix(:, j)
end do
do k = 1, 2_IK * n + 1_IK
    x = xpt(:, k) + xbase
    ! call evaluate(calfun, x, f)

    ! Print a message about the function evaluation according to IPRINT.
    call fmsg(solver, 'Initialization', iprint, k, rhobeg, f, x)
    ! Save X and F into the history.
    call savehist(k, x, xhist, f, fhist)

    evaluated(k) = .true.
    fval(k) = f

    ! When K is even, determine XPT(:, K+1) according to F(K).
    ! N.B.: This heuristic strategy does increase the performance. In addition, it is a GOOD idea to
    ! evaluate F at XBASE + 2*XPT(:, K) or XBASE - XPT(:, K) IMMEDIATELY after XBASE + XPT(:, K).
    ! This increases the probability of finding a smaller function value earlier in the sampling
    ! process for the first model. This process itself can be regarded as a simple direct search. It
    ! is IMPORTANT for the performance of the algorithm during the early stage, even before the
    ! first model is built.
    if (modulo(k, 2_IK) == 0) then
        if (fval(k) < fval(1)) then
            xpt(:, k + 1) = TWO * xpt(:, k)  ! XPT(K / 2, K + 1) = TWO * RHOBEG
        else
            xpt(:, k + 1) = -xpt(:, k)  ! XPT(K / 2, K + 1) = -RHOBEG
        end if
    end if

    ! Check whether to exit.
    subinfo = checkexit(maxfun, k, f, ftarget, x)
    if (subinfo /= INFO_DFT) then
        info = subinfo
        exit
    end if
end do

if (info == INFO_DFT) then
    xw = -rhobeg
    xw(trueloc(fval(kk) < fval(1))) = rhobeg
    ! See (42)--(43) of the UOBYQA paper for IP and IQ.
    ip = 0
    iq = 2
    do k = 2_IK * n + 2_IK, npt
        ! Pick the shift from XBASE to the next initial interpolation point that provides the
        ! off-diagonal second derivatives of the quadratic interpolant.
        ip = ip + 1_IK
        if (ip == iq) then
            iq = iq + 1_IK
            ip = 1
        end if
        xpt([ip, iq], k) = xw([ip, iq])
        x = xpt(:, k) + xbase
        ! call evaluate(calfun, x, f)

        ! Print a message about the function evaluation according to IPRINT.
        call fmsg(solver, 'Initialization', iprint, k, rhobeg, f, x)
        ! Save X and F into the history.
        call savehist(k, x, xhist, f, fhist)

        evaluated(k) = .true.
        fval(k) = f

        ! Check whether to exit.
        subinfo = checkexit(maxfun, k, f, ftarget, x)
        if (subinfo /= INFO_DFT) then
            info = subinfo
            exit
        end if
    end do
end if

nf = int(count(evaluated), kind(nf))  !!MATLAB: nf = sum(evaluated);
! kopt = int(minloc(fval, mask=evaluated, dim=1), kind(kopt))
!!MATLAB: fopt = min(fval(evaluated)); kopt = find(evaluated & ~(fval > fopt), 1, 'first')

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(nf <= npt, 'NF <= NPT', srname)
    call assert(kopt >= 1 .and. kopt <= npt, '1 <= KOPT <= NPT', srname)
    call assert(size(xbase) == n .and. all(is_finite(xbase)), 'SIZE(XBASE) == N, XBASE is finite', srname)
    call assert(size(xpt, 1) == n .and. size(xpt, 2) == npt, 'SIZE(XPT) == [N, NPT]', srname)
    call assert(all(is_finite(xpt)), 'XPT is finite', srname)
    call assert(size(fval) == npt .and. .not. any(evaluated .and. (is_nan(fval) .or. is_posinf(fval))), &
        & 'SIZE(FVAL) == NPT and FVAL is not NaN or +Inf', srname)
    call assert(.not. any(evaluated .and. fval < fval(kopt)), 'FVAL(KOPT) = MINVAL(FVAL)', srname)
    call assert(size(fhist) == maxfhist, 'SIZE(FHIST) == MAXFHIST', srname)
    call assert(size(xhist, 1) == n .and. size(xhist, 2) == maxxhist, 'SIZE(XHIST) == [N, MAXXHIST]', srname)
end if

end subroutine initxf


subroutine initq(fval, xpt, pq, info)
!--------------------------------------------------------------------------------------------------!
! This subroutine initializes the quadratic model, whose coefficients are stored in PQ, where
! PQ(1 : N) containing the gradient of the model at XBASE, and PQ(N+1 : NPT-1) containing the upper
! triangular part of the Hessian, column by column. See Section 4 of the UOBYQA paper.
!--------------------------------------------------------------------------------------------------!

! Common modules
use, non_intrinsic :: consts_mod, only : RP, IK, TWO, HALF, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
use, non_intrinsic :: infnan_mod, only : is_nan, is_posinf, is_finite
use, non_intrinsic :: infos_mod, only : INFO_DFT, NAN_INF_MODEL

implicit none

! Inputs
real(RP), intent(in) :: fval(:)  ! XPT(N, NPT)
real(RP), intent(in) :: xpt(:, :)  ! XPT(N, NPT)

! Outputs
integer(IK), intent(out), optional :: info
real(RP), intent(out) :: pq(:)  ! PQ((N + 1) * (N + 2) / 2 - 1)

! Local variables
character(len=*), parameter :: srname = 'INITQ'
integer(IK) :: k1
integer(IK) :: ih
integer(IK) :: ip
integer(IK) :: iq
integer(IK) :: k
integer(IK) :: k0
integer(IK) :: n
integer(IK) :: npt
real(RP) :: deriv(size(xpt, 1))
real(RP) :: fbase
real(RP) :: rhobeg
real(RP) :: rhosq

! Sizes
n = int(size(xpt, 1), kind(n))
npt = int(size(xpt, 2), kind(npt))

! Postconditions
if (DEBUGGING) then
    call assert(n >= 1 .and. npt == (n + 1) * (n + 2) / 2, 'N >= 1, NPT == (N+1)*(N+2)/2', srname)
    call assert(size(xpt, 1) == n .and. size(xpt, 2) == npt, 'SIZE(XPT) == [N, NPT]', srname)
    call assert(all(is_finite(xpt)), 'XPT is finite', srname)
    call assert(size(fval) == npt .and. .not. any((is_nan(fval) .or. is_posinf(fval))), &
        & 'SIZE(FVAL) == NPT and FVAL is not NaN or +Inf', srname)
end if

!====================!
! Calculation starts !
!====================!

rhobeg = maxval(abs(xpt(:, 2)))
rhosq = rhobeg**2
fbase = fval(1)

! Form the gradient and diagonal second derivatives of the quadratic model.
do k = 1, n
    k0 = 2_IK * k
    k1 = 2_IK * k + 1_IK
    ! Find the (K, K) element of the Hessian.
    ih = n + k * (k + 1_IK) / 2_IK
    if (xpt(k, k1) > 0) then  ! XPT(K, K1) = 2*RHO
        deriv(k) = (fbase + fval(k1) - TWO * fval(k0)) / rhosq
        pq(k) = (4.0_RP * fval(k0) - 3.0_RP * fbase - fval(k1)) / (TWO * rhobeg)
    else  ! XPT(K, K1) = -RHO
        deriv(k) = (fval(k0) + fval(k1) - TWO * fbase) / rhosq
        pq(k) = (fval(k0) - fval(k1)) / (TWO * rhobeg)
    end if
    pq(ih) = deriv(k)
end do

! Form the off-diagonal second derivatives of the initial quadratic model.
ip = 0
iq = 2
do k = 2_IK * n + 2_IK, npt
    ip = ip + 1_IK
    if (ip == iq) then
        iq = iq + 1_IK
        ip = 1
    end if
    ! Find the (IQ, IP) entry of the Hessian.
    ih = n + (iq - 1_IK) * iq / 2_IK + ip
    pq(ih) = (fval(k) - fbase - xpt(ip, k) * pq(ip) - xpt(iq, k) * pq(iq) &
        & - HALF * rhosq * (deriv(ip) + deriv(iq))) / (xpt(ip, k) * xpt(iq, k))
end do

if (present(info)) then
    if (is_nan(sum(abs(pq)))) then
        info = NAN_INF_MODEL
    else
        info = INFO_DFT
    end if
end if

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(size(pq) == npt - 1, 'SIZE(PQ) == NPT - 1', srname)
end if

end subroutine initq


subroutine initl(xpt, pl, info)
!--------------------------------------------------------------------------------------------------!
! This subroutine initializes the Lagrange functions. The coefficients of the K-th Lagrange function
! is stored in PL(:, K), with PL(1 : N, K) containing the gradient of the function at XBASE, and
! PL(N+1 : NPT-1, K) containing the upper triangular part of the Hessian, column by column.
! See Section 4 of the UOBYQA paper.
!--------------------------------------------------------------------------------------------------!
! Common modules
use, non_intrinsic :: consts_mod, only : RP, IK, ZERO, ONE, TWO, HALF, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
use, non_intrinsic :: infnan_mod, only : is_nan, is_finite
use, non_intrinsic :: infos_mod, only : INFO_DFT, NAN_INF_MODEL

implicit none

! Inputs
real(RP), intent(in) :: xpt(:, :)  ! XPT(N, NPT)

! Outputs
integer(IK), intent(out), optional :: info
real(RP), intent(out) :: pl(:, :)  ! PL((N + 1) * (N + 2) / 2 - 1, (N + 1) * (N + 2) / 2)

! Local variables
character(len=*), parameter :: srname = 'INITL'
integer(IK) :: ih
integer(IK) :: ip
integer(IK) :: iq
integer(IK) :: k
integer(IK) :: k0
integer(IK) :: k1
integer(IK) :: n
integer(IK) :: npt
real(RP) :: rhobeg
real(RP) :: rhosq
real(RP) :: temp

! Sizes
n = int(size(xpt, 1), kind(n))
npt = int(size(xpt, 2), kind(npt))

! Postconditions
if (DEBUGGING) then
    call assert(n >= 1 .and. npt == (n + 1) * (n + 2) / 2, 'N >= 1, NPT == (N+1)*(N+2)/2', srname)
    call assert(size(xpt, 1) == n .and. size(xpt, 2) == npt, 'SIZE(XPT) == [N, NPT]', srname)
    call assert(all(is_finite(xpt)), 'XPT is finite', srname)
end if

!====================!
! Calculation starts !
!====================!

rhobeg = maxval(abs(xpt(:, 2)))
rhosq = rhobeg**2

pl = ZERO

! Form the gradient and diagonal second derivatives of the Lagrange functions.
do k = 1, n
    k0 = 2_IK * k
    k1 = 2_IK * k + 1_IK
    ih = n + k * (k + 1_IK) / 2_IK  ! The (K, K) entry of the Hessian
    if (xpt(k, k1) > 0) then  ! XPT(K, K1) = 2*RHO
        pl(k, 1) = -1.5_RP / rhobeg
        pl(ih, 1) = ONE / rhosq
        pl(k, k0) = TWO / rhobeg
        pl(ih, k0) = -TWO / rhosq
    else  ! XPT(K, K1) = -RHO
        pl(ih, 1) = -TWO / rhosq
        pl(k, k0) = HALF / rhobeg
        pl(ih, k0) = ONE / rhosq
    end if
    pl(k, k1) = -HALF / rhobeg
    pl(ih, k1) = ONE / rhosq
end do

! Form the off-diagonal second derivatives of the Lagrange functions.
ip = 0
iq = 2
do k = 2_IK * n + 2_IK, npt
    ip = ip + 1_IK
    if (ip == iq) then
        iq = iq + 1_IK
        ip = 1
    end if

    ! Find the (IQ, IP) entry of the Hessian.
    temp = ONE / (xpt(ip, k) * xpt(iq, k))
    ih = n + (iq - 1_IK) * iq / 2_IK + ip

    pl(ih, 1) = temp
    pl(ih, k) = temp

    if (xpt(ip, k) < 0) then
        pl(ih, 2 * ip + 1) = -temp
    else
        pl(ih, 2 * ip) = -temp
    end if

    if (xpt(iq, k) < 0) then
        pl(ih, 2 * iq + 1) = -temp
    else
        pl(ih, 2 * iq) = -temp
    end if
end do

if (present(info)) then
    if (is_nan(sum(abs(pl)))) then
        info = NAN_INF_MODEL
    else
        info = INFO_DFT
    end if
end if

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(size(pl, 1) == npt - 1 .and. size(pl, 2) == npt, 'SIZE(PL) == [NPT - 1, NPT]', srname)
end if

end subroutine initl


end module initialize_uobyqa_mod
