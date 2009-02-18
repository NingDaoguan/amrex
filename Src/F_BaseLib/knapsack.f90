
module sfc_module
  use box_module
  !
  ! This is more than a bit of a hack.  We're going to store a few values here
  ! while inside the sfc_i() routine, so that they're accessible via sfc_greater_i().
  !
  integer            :: dm, mpower
  type(box), pointer :: pbxs(:)
end module sfc_module

module knapsack_module

  use bl_types

  implicit none

  logical, private :: do_mcc = .true.

  logical, private :: knapsack_verbose = .true.

  real(kind=dp_t), private :: knapsack_threshold = 0.9_dp_t

  private :: greater_d, mcc

contains

  subroutine knapsack_set_verbose(yesorno)
    logical, intent(in) :: yesorno
    knapsack_verbose = yesorno
  end subroutine knapsack_set_verbose

  subroutine knapsack_set_mcc(yesorno)
    logical, intent(in) :: yesorno
    do_mcc = yesorno
  end subroutine knapsack_set_mcc

  function greater_d(a,b) result(r)
    logical :: r
    real(kind=dp_t), intent(in) :: a, b
    r = a > b
  end function greater_d
  !
  ! Attempt to minimize the communication costs of knapsack.
  !
  subroutine mcc(prc, ibxs, bxs, np, verbose)

    use parallel
    use box_module
    use sort_i_module
    use vector_i_module
    use boxarray_module
    use bl_error_module

    integer,   intent(inout) :: prc(:)
    integer,   intent(in   ) :: ibxs(:)
    type(box), intent(in   ) :: bxs(:)
    integer,   intent(in   ) :: np
    logical,   intent(in   ) :: verbose

    integer                     :: i, j, k, val
    integer,        parameter   :: swap_and_test_count = 1
    integer(ll_t)               :: icc
    integer,        allocatable :: idx(:)
    integer(ll_t),  allocatable :: percpu(:)
    type(vector_i), allocatable :: nbrs(:), samesize(:)
    type(vector_i)              :: uniq

    if ( size(ibxs) /= size(bxs) ) call bl_error('mcc: how did this happen?')

    allocate(nbrs(size(bxs)))

    do i = 1, size(nbrs)
       call build(nbrs(i))
    end do

    call calculate_neighbors()
    !
    ! Want vectors of box IDs containing same size boxes.
    !
    allocate(idx(size(ibxs)))

    call sort(ibxs, idx)

    val = ibxs(idx(1))

    call build(uniq)

    call push_back(uniq, val)

    do i = 2, size(ibxs)
       if ( ibxs(idx(i-1)) /= ibxs(idx(i)) ) call push_back(uniq, ibxs(idx(i)))
    end do

    allocate(samesize(size(uniq)))

    do i = 1, size(samesize)
       call build(samesize(i))
    end do
 
    do i = 1, size(idx)
       do j = 1, size(uniq)
          if ( at(uniq,j) == ibxs(idx(i)) ) then
             call push_back(samesize(j), idx(i))
             exit
          end if
       end do
    end do

    deallocate(idx)
    !
    ! Build a data structure to maintain the latency count on a per-CPU basis.
    !
    allocate(percpu(0:np-1))

    percpu = 0_ll_t

    do i = 1, size(nbrs)
       do j = 1, size(nbrs(i))
          k = prc(at(nbrs(i),j))
          if ( prc(i) /= k ) percpu(k) = percpu(k) + 1
       end do
    end do

    icc = sum(percpu)

    do i = 1, swap_and_test_count
       call swap_and_test()
    end do

    if ( verbose .and. parallel_ioprocessor() ) then
       print*, 'MCC: initial off-CPU connection count: ', icc
       print*, 'MCC:   final off-CPU connection count: ', sum(percpu)
    end if

    call destroy(uniq)

    do i = 1, size(samesize)
       call destroy(samesize(i))
    end do

    do i = 1, size(nbrs)
       call destroy(nbrs(i))
    end do

  contains

    subroutine calculate_neighbors()

      type(boxarray) :: ba

      call build(ba, bxs, sort = .false.)

      call boxarray_grow(ba, 1)   ! Use a "grow" factor of 1.

      do i = 1, nboxes(ba)
         do j = 1, nboxes(ba)
            if ( j == i ) cycle
            if ( intersects(ba%bxs(i), ba%bxs(j)) ) then
               call push_back(nbrs(i), j)
            end if
         end do
      end do

      call destroy(ba)

    end subroutine calculate_neighbors

    subroutine swap_and_test()

    integer       :: ival1, ival2, pmap1, pmap2, pmapstar, m
    integer(ll_t) :: percpu_val1, percpu_val2, cost_old, cost_new, tmp

    do i = 1, size(samesize)
       do j = 1, size(samesize(i))
          ival1 = at(samesize(i),j)
          do k = j+1, size(samesize(i))
             ival2 = at(samesize(i),k)
             !
             ! Do not consider boxes on the same CPU.
             !
             if ( prc(ival1) == prc(ival2) ) cycle
             !
             ! Will swapping these boxes decrease latency?
             !
             percpu_val1 = percpu(prc(ival1))
             percpu_val2 = percpu(prc(ival2))
             !
             ! Change prc & redo necessary calculations ...
             !
             tmp        = prc(ival1)
             prc(ival1) = prc(ival2)
             prc(ival2) = tmp
             pmap1      = prc(ival1)
             pmap2      = prc(ival2)
             !
             ! Update percpu in place.
             !
             do m = 1, size(nbrs(ival1))
                pmapstar = prc(at(nbrs(ival1),m))
                if ( pmapstar == pmap2 ) then
                   percpu(pmap1) = percpu(pmap1) + 1;
                   percpu(pmap2) = percpu(pmap2) + 1;
                else if ( pmapstar == pmap1 ) then
                   percpu(pmap1) = percpu(pmap1) - 1;
                   percpu(pmap2) = percpu(pmap2) - 1;
                else
                   percpu(pmap1) = percpu(pmap1) + 1;
                   percpu(pmap2) = percpu(pmap2) - 1;
                end if
             end do

             do m = 1, size(nbrs(ival2))
                pmapstar = prc(at(nbrs(ival2),m))
                if ( pmapstar == pmap1 ) then
                   percpu(pmap1) = percpu(pmap1) + 1;
                   percpu(pmap2) = percpu(pmap2) + 1;
                else if ( pmapstar == pmap2 ) then
                   percpu(pmap1) = percpu(pmap1) - 1;
                   percpu(pmap2) = percpu(pmap2) - 1;
                else
                   percpu(pmap1) = percpu(pmap1) - 1;
                   percpu(pmap2) = percpu(pmap2) + 1;
                end if
             end do

             cost_old = percpu_val1   + percpu_val2
             cost_new = percpu(pmap1) + percpu(pmap2)

             if (cost_new >= cost_old) then
                !
                ! Undo our changes ...
                !
                tmp                = prc(ival1)
                prc(ival1)         = prc(ival2)
                prc(ival2)         = tmp
                percpu(prc(ival1)) = percpu_val1;
                percpu(prc(ival2)) = percpu_val2;
             end if
          end do
       end do
    end do

    end subroutine swap_and_test

  end subroutine mcc

  subroutine knapsack_i(prc, ibxs, bxs, np, verbose, threshold)

    use parallel
    use box_module
    use vector_i_module
    use sort_d_module
    use bl_error_module
    use bl_prof_module

    integer,         intent(out), dimension(:) :: prc
    integer,         intent(in ), dimension(:) :: ibxs
    type(box),       intent(in ), dimension(:) :: bxs
    integer,         intent(in )               :: np
    real(kind=dp_t), intent(in ), optional     :: threshold
    logical,         intent(in ), optional     :: verbose

    logical         :: lverb
    integer         :: i, j, k, isizes(size(ibxs))
    real(kind=dp_t) :: w1o, wjo, w1n, wjn, dif, efficiency, lthresh, t1, t2
    real(kind=dp_t) :: total_weight, xmean, stddev, sizes(size(ibxs))

    integer,         allocatable :: iprocs(:)
    type(vector_i),  allocatable :: procs(:)
    real(kind=dp_t), allocatable :: pweights(:)

    type(bl_prof_timer), save :: bpt

    if ( np < 1 ) call bl_error('knapsack_i(): np < 1')

    call build(bpt, 'knapsack')

    call cpu_time(t1)

    lverb   = knapsack_verbose  ; if ( present(verbose  ) ) lverb   = verbose
    lthresh = knapsack_threshold; if ( present(threshold) ) lthresh = threshold

    allocate(procs(np), iprocs(np), pweights(np))
    !
    ! Each processor maintains a list of its boxes in a dynamic array,
    ! which is addressed indirectly through the array iprocs.
    !
    do i = 1, size(procs)
       call build(procs(i))
       iprocs(i) = i
    end do
    sizes = ibxs
    total_weight = sum(sizes)
    call sort(sizes, isizes, greater_d)
    !
    ! Place the box in the least loaded processor.
    ! Before we start, the procs array satisfies a heap property.
    !
    pweights = weights(np)
    do i = 1, size(ibxs)
       call push_back(procs(iprocs(1)), isizes(i))
       call reheap_procs()
    end do
    call sort_procs() ! now, they need to be sorted.
    outer: do
       efficiency = total_weight/np/weight(1)
       if ( efficiency > lthresh ) exit outer
       !
       ! For each box in the most loaded processor.
       !
       do i = 1, size(procs(iprocs(1)))
          !
          ! Check each less lightly loaded processor...
          !
          do j = 2, size(procs)
             !
             ! By looking at each box in that processor.
             !
             do k = 1, size(procs(iprocs(j)))
                w1o = weight(1)
                wjo = weight(j)
                dif = weight_ball(1,i) - weight_ball(j,k)
                w1n = w1o - dif
                wjn = wjo + dif
                if ( w1n < w1o .AND. wjn < w1o ) then
                   !
                   ! If we decrease the overall load in both the processors by
                   ! comparing to the most loaded processor, and we decrease 
                   ! the load in the less loaded processor, move the box.
                   !
                   call swap_balls(1,i,j,k)
                   !
                   ! Reorder the processors.
                   !
                   call sort_procs()
                   !
                   ! Start over again.
                   !
                   cycle outer
                end if
             end do
          end do
       end do
       exit outer
    end do outer

    do i = 1, size(procs)
       do j = 1, size(procs(iprocs(i)))
          prc(ball(i,j)) = i
       end do
    end do

    prc = prc - 1   ! Processor numbers start at 0.

    call cpu_time(t2)

     if ( .false. .and. lverb .and. np > 1 .and. parallel_ioprocessor() ) then
        xmean  = sum(ibxs)/size(ibxs)
        stddev = sqrt(sum((ibxs-xmean)**2)/(size(ibxs)-1))
        print *, 'np               = ', np
        print *, 'n                = ', size(ibxs)
        print *, 'max box weight   = ', maxval(ibxs)
        print *, 'min box weight   = ', minval(ibxs)
        print *, 'mean bx weight   = ', xmean
        print *, 'stdd bx weight   = ', stddev
        print *, 'max weight       = ', weight(1)
        print *, 'max weight       = ', weight(np)
        print *, 'total weight     = ', sum(weights(np))
     end if

    efficiency = sum(weights(np))/(np*weight(1))

    do i = 1, size(procs)
       call destroy(procs(i))
    end do

    if ( np > 1 .and. do_mcc ) call mcc(prc, ibxs, bxs, np, lverb)

    call cpu_time(t2)

    if ( lverb .and. np > 1 .and. parallel_ioprocessor() ) then
       print *, 'KNAPSACK effi = ', efficiency
       print *, 'KNAPSACK time = ', t2-t1
    end if

    call destroy(bpt)

  contains

    subroutine swap_balls(m,i,j,k)
      integer, intent(in) :: m, i, j, k
      integer :: dmi, djk, ii, kk
      dmi = ball(m,i)
      ii = erase(procs(iprocs(m)), i)
      djk = ball(j,k)
      kk = erase(procs(iprocs(j)), k)
      call push_back(procs(iprocs(j)), dmi)
      call push_back(procs(iprocs(m)), djk)
    end subroutine swap_balls

    function weights(np) result(r)
      integer, intent(in) :: np
      real(kind=dp_t), dimension(np) :: r
      integer :: j
      r = 0
      do j = 1, np
         r(j) = weight(j)
      end do
    end function weights

    function weight(i) result(r)
      integer, intent(in) :: i
      real(kind=dp_t) :: r
      integer :: j
      r = 0
      do j = 1, size(procs(iprocs(i)))
         r = r + sizes(at(procs(iprocs(i)),j))
      end do
    end function weight

    function weight_ball(i,j) result(r)
      integer, intent(in) :: i, j
      real(kind=dp_t) :: r
      r = sizes(ball(i,j))
    end function weight_ball

    function ball(i,j) result(r)
      integer, intent(in) :: i, j
      integer :: r
      r = at(procs(iprocs(i)),j)
    end function ball

    subroutine sort_procs()
      integer :: iii(size(procs))
      real(kind=dp_t) :: iss(size(procs))
      iss = weights(np)
      call sort(iss, iii, greater_d)
      iprocs = iprocs(iii)
    end subroutine sort_procs

    subroutine reheap_procs()
      integer :: i, dd, sz, tmp
      real(kind=dp_t) :: wt
      sz = size(procs)
      wt = weight(1)
      dd = iprocs(1)
      ! first remove the last
      tmp = iprocs(sz)
      sz = sz - 1
      i = 2
      do while ( i <= sz+1/2 )
         if ( i < sz .AND. &
              (pweights(iprocs(i)) > pweights(iprocs(i+1))) ) i = i + 1
         if ( .not. ( pweights(tmp) >= pweights(iprocs(i))) ) exit
         iprocs(i/2) = iprocs(i)
         i = 2*i
      end do
      iprocs(i/2) = tmp
      ! now, put it back!
      sz = sz + 1
      i = sz
      iprocs(i) = dd
      pweights(dd) = wt
      do while ( i > 1 )
         if ( .not. (pweights(iprocs(i/2)) > pweights(dd)) ) exit
         iprocs(i) = iprocs(i/2)
         i = i/2
      end do
      iprocs(i) = dd
    end subroutine reheap_procs

  end subroutine knapsack_i

  subroutine sfc_i(prc, ibxs, bxs, np, verbose)

    use sfc_module
    use parallel
    use box_module
    use sort_i_module
    use bl_error_module
    use bl_prof_module

    integer,   intent(out)           :: prc(:)
    integer,   intent(in )           :: ibxs(:)
    type(box), intent(in ), target   :: bxs(:)
    integer,   intent(in )           :: np
    logical,   intent(in ), optional :: verbose

    logical         :: lverb
    integer         ::  i
    real(kind=dp_t) :: t1, t2, efficiency

    integer, allocatable :: iorder(:), whichcpu(:)

    type(bl_prof_timer), save :: bpt

    if ( np < 1 ) call bl_error('sfc_i(): np < 1')

    if ( size(ibxs) < 1 ) call bl_error('sfc_i(): size(ibxs) < 1')

    call build(bpt, 'sfc')

    call cpu_time(t1)

    lverb = knapsack_verbose ; if ( present(verbose) ) lverb = verbose
    !
    ! Set dm, mpower & pbxs in sfc_module so they're accessible to sfc_greater_i().
    !
    dm     =  get_dim(bxs(1))
    mpower =  maxpower()
    pbxs   => bxs

    allocate(iorder(size(ibxs)), whichcpu(size(ibxs)))
    !
    ! Set to "bad" value that we can check for later to ensure array filled correctly.
    !
    whichcpu = -1

    do i = 1, size(ibxs)
       iorder(i) = i
    end do

    call sort(iorder, sfc_greater_i)
    !
    ! "iorder" now indexes the boxes in morton space-filling-curve order.
    !
    call distribute()
    !
    ! "whichcpu(i)" now contains the CPU on which to place the iorder(i)'th box.
    !
    if ( minval(whichcpu) < 0 ) call bl_error('sfc_i(): improper CPU number')

    do i = 1, size(ibxs)
       prc(iorder(i)) = whichcpu(i)
    end do

    call cpu_time(t2)

    if ( lverb .and. np > 1 .and. parallel_ioprocessor() ) then
       print *, 'SFC effi = ', efficiency
       print *, 'SFC time = ', t2-t1
    end if

    call destroy(bpt)

    contains

      function maxpower() result(r)

        integer :: r, maxijk, i, d

        maxijk = lwb(bxs(1),1)

        do i = 1,size(bxs)
           do d = 1, dm
              maxijk = max(maxijk,lwb(bxs(i),d))
           end do
        end do

        r = 0
        do while ( ishft(1,r) <= maxijk )
           r = r + 1
        end do

      end function maxpower

      subroutine distribute()

        integer         :: k, cnt, sz
        real(kind=dp_t) :: totalvol, volpercpu, vol, maxvol

        maxvol = -Huge(1_dp_t)

        volpercpu = 0_dp_t
        do i = 1, size(ibxs)
           volpercpu = volpercpu + ibxs(i)
        end do
        volpercpu = volpercpu / np

        k        = 1
        sz       = size(ibxs)
        totalvol = 0_dp_t

        do i = 1, np

           cnt = 0
           vol = 0_dp_t

           do while ( (k <= sz) .and. ((i == np) .or. (vol < volpercpu)) )
              whichcpu(k) = i
              vol = vol + ibxs(iorder(k))
              k   = k   + 1
              cnt = cnt + 1
           end do

           totalvol = totalvol + vol

           if ( (totalvol/i) > volpercpu .and. (cnt > 1) .and. (k <= sz) ) then
              k        = k - 1
              vol      = vol - ibxs(iorder(k))
              totalvol = totalvol - ibxs(iorder(k))
           endif

           maxvol = max(maxvol,vol)

        end do
        !
        ! Force "whichcpu" values to be zero-based instead of one-based.
        !
        whichcpu = whichcpu - 1

        efficiency = volpercpu / maxvol

      end subroutine distribute

  end subroutine sfc_i

  function sfc_greater_i(ilhs,irhs) result(r)

    use sfc_module

    logical             :: r
    integer, intent(in) :: ilhs,irhs

    integer m,d,NNN

    do m = mpower,0,-1

       NNN = ishft(1,m)

       do d = 1, dm
          if ( lwb(pbxs(ilhs),d)/NNN < lwb(pbxs(irhs),d)/NNN ) then
             r = .true.
             return
          else if ( lwb(pbxs(ilhs),d)/NNN > lwb(pbxs(irhs),d)/NNN ) then
             r = .false.
             return
          end if
       end do
    end do

    r = .false.

  end function sfc_greater_i

end module knapsack_module
