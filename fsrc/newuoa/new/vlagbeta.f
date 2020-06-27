!      subroutine vlagbeta(n, npt, idz, kopt, bmat, zmat, xpt, xopt, d,  &
!     & vlag, beta, wcheck)
      subroutine vlagbeta(n, npt, idz, kopt, bmat, zmat, xpt, xopt, d,  &
     & vlag, beta, wcheck, dsq, xoptsq)

      use consts, only : rp, one, half, zero
      use lina
      implicit none

      integer, intent(in) :: n, npt, idz, kopt
      real(kind = rp), intent(in) :: bmat(npt+n, n), zmat(npt, npt-n-1),&
     & xpt(n, npt), xopt(n), d(n)
      real(kind = rp), intent(out) :: vlag(npt+n), beta, wcheck(npt)

      integer :: k, j
      real(kind = rp) :: wb(n), wbvd, wz(npt-n-1), wzsave(npt-n-1), dx, &
     & dsq, xoptsq


!----------------------------------------------------------------------!
      ! This is the one of the two places where WCHECK is calculated,
      ! the other being BIGDEN. 
      ! WCHECK contains the first NPT entries of (w-v) for the vectors 
      ! w and v defined in eq(4.10) and eq(4.24) of the NEWUOA paper,
      ! and also \hat{w} in eq(6.5) of 
      !
      ! M. J. D. Powell, Least Frobenius norm updating of quadratic
      ! models that satisfy interpolation conditions. Math. Program.,
      ! 100:183--215, 2004
      !
      ! WCHECK is used ONLY in CALQUAD, which evaluates the qudratic
      ! model. Indeed, we may calculate WCHECK internally in CALQUAD.
      wcheck = matmul(d, xpt)
      wcheck = wcheck*(half*wcheck + matmul(xopt, xpt))
!----------------------------------------------------------------------!

      vlag(1 : npt) = matmul(bmat(1 : npt, :), d)

      wz = matmul(wcheck, zmat)
      wzsave = wz
      wz(1 : idz - 1) = -wz(1 : idz - 1)
      beta = -dot_product(wzsave, wz)
!----------------------------------------------------------------------!
      ! The following DO LOOP implements the update below. The results
      ! will not be identical due to the non-associativity of
      ! floating point arithmetic addition.
!-----!vlag(1 : npt) = vlag(1 : npt) + matmul(zmat, wz) !--------------!
      do k = 1, npt - n - 1
          vlag(1 : npt) = vlag(1 : npt) + wz(k)*zmat(:, k)
      end do
!----------------------------------------------------------------------!

      wb = matmul(wcheck, bmat(1 : npt, :))
!----------------------------------------------------------------------!
      ! The following DO LOOP implements the update below. The results
      ! will not be identical due to the non-associativity of
      ! floating point arithmetic addition.
!-----!vlag(npt + 1: npt + n) = wb + matmul(bmat(npt + 1, npt + n, :), d)
      vlag(npt + 1 : npt + n) = wb
      do k = 1, n
          vlag(npt + 1 : npt + n) = vlag(npt + 1 : npt + n) +           &
     &     bmat(npt + 1 : npt + n, k)*d(k)
      end do
!----------------------------------------------------------------------!

!----------------------------------------------------------------------!
      ! The following DO LOOP implements the dot product below. The
      ! results will not be identical due to the non-associativity of
      ! floating point arithmetic addition.
!-----!wbvd = dot_product(wb + vlag(npt+1 : npt+n), d) !---------------!
      wbvd = zero
      do j = 1, n
          wbvd = wbvd + wb(j)*d(j) + vlag(npt + j)*d(j)
      end do
!----------------------------------------------------------------------!

      dx = dot_product(d, xopt)

      !dsq = dot_product(d, d)
      !xoptsq = dot_product(xopt, xopt)

      beta = dx*dx + dsq*(xoptsq + dx + dx + half*dsq) + beta - wbvd
      vlag(kopt) = vlag(kopt) + one

      return

      end subroutine vlagbeta
