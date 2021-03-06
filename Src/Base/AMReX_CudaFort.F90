module cuda_module

  use cudafor, only: cuda_stream_kind, cudaSuccess, cudaGetErrorString, cudaDeviceProp, dim3

  implicit none

  public

  integer, parameter :: max_cuda_streams = 16
  integer(kind=cuda_stream_kind) :: cuda_streams(0:max_cuda_streams) ! Note: zero will be the default stream.

  integer :: cuda_device_id

  integer :: verbose

  type(cudaDeviceProp), private :: prop

  ! Some C++ static class members will initialize at program load,
  ! before we have the ability to initialize this module. Guard against
  ! this by only testing on the device properties if we have actually
  ! loaded them.

  logical, private :: have_prop = .false.

  integer :: is_program_running = 1

  ! Max block size in each direction
  integer :: max_threads_dim(3)

  ! The current stream index

  integer :: stream_index
  !$omp threadprivate(stream_index)

  ! The current CUDA stream
  integer(kind=cuda_stream_kind) :: cuda_stream
  !$omp threadprivate(cuda_stream)

  ! The current number of blocks and threads
  type(dim3) :: numBlocks, numThreads
  !$omp threadprivate(numBlocks, numThreads)

  ! The minimum number of threads per dimension
  type(dim3) :: numThreadsMin = dim3(1,1,1)
  !$omp threadprivate(numThreadsMin)

  ! Implement our own interface to cudaProfilerStart/cudaProfilerStop
  ! since XL does not provide this.

  interface
     subroutine cudaProfilerStart() bind(c, name='cudaProfilerStart')
     end subroutine cudaProfilerStart
     subroutine cudaProfilerStop() bind(c, name='cudaProfilerStop')
     end subroutine cudaProfilerStop
  end interface

contains

  subroutine initialize_cuda(id) bind(c, name='initialize_cuda')
#ifdef AMREX_USE_ACC
    use openacc, only: acc_init, acc_set_device_num, acc_device_nvidia
#endif
    use cudafor, only: cudaStreamCreate, cudaGetDeviceProperties, cudaSetDevice, &
                       cudaDeviceSetCacheConfig, cudaFuncCachePreferL1
    use amrex_error_module, only: amrex_error

    implicit none

    integer, intent(in) :: id

    integer :: i, cudaResult, ilen

#ifdef AMREX_USE_ACC
    call acc_init(acc_device_nvidia)
    call acc_set_device_num(id, acc_device_nvidia)
#endif

    ! Set our stream 0 corresponding to CUDA stream 0, the null/default stream.
    ! This stream is synchronous and blocking. It is our default choice, and we
    ! only use the other, asynchronous streams when we know it is safe.

    cuda_streams(0) = 0

    stream_index = -1
    cuda_stream = cuda_streams(0)

    do i = 1, max_cuda_streams
       cudaResult = cudaStreamCreate(cuda_streams(i))
       call gpu_error_test(cudaResult)
    enddo

    cudaResult = cudaGetDeviceProperties(prop, cuda_device_id)
    call gpu_error_test(cudaResult)

    have_prop = .true.

    if (prop%major < 3) then
       call amrex_error("CUDA functionality unsupported on GPUs with compute capability earlier than 3.0")
    end if

    max_threads_dim = prop%maxThreadsDim

    ! Prefer L1 cache to shared memory (this has no effect on GPUs with a fixed L1 cache size).

    cudaResult = cudaDeviceSetCacheConfig(cudaFuncCachePreferL1)
    call gpu_error_test(cudaResult)

    ilen = verify(prop%name, ' ', .true.)

  end subroutine initialize_cuda



  subroutine finalize_cuda() bind(c, name='finalize_cuda')
#ifdef AMREX_USE_ACC
    use openacc, only: acc_shutdown, acc_device_nvidia
#endif
    use cudafor, only: cudaStreamDestroy, cudaDeviceReset

    implicit none

    integer :: i, cudaResult

    do i = 1, max_cuda_streams
       cudaResult = cudaStreamDestroy(cuda_streams(i))
       call gpu_error_test(cudaResult, abort=0)
    end do

    call gpu_stop_profiler()

#ifdef AMREX_USE_ACC
    call acc_shutdown(acc_device_nvidia)
#endif
    cudaResult = cudaDeviceReset()
    call gpu_error_test(cudaResult, abort=0)

  end subroutine finalize_cuda



  subroutine set_is_program_running(r) bind(c, name='set_is_program_running')

    implicit none

    integer, intent(in), value :: r

    is_program_running = r

  end subroutine set_is_program_running



  subroutine set_gpu_stack_limit(size) bind(c, name='set_gpu_stack_limit')

    use cudafor, only: cudaDeviceSetLimit, cudaLimitStackSize, cuda_count_kind

    implicit none

    integer(cuda_count_kind), intent(in) :: size

    integer :: cudaResult

    ! Set the GPU stack size, in bytes.

    cudaResult = cudaDeviceSetLimit(cudaLimitStackSize, size)
    call gpu_error_test(cudaResult)

  end subroutine set_gpu_stack_limit



  subroutine get_cuda_device_id(id) bind(c, name='get_cuda_device_id')

    implicit none

    integer :: id

    id = cuda_device_id

  end subroutine get_cuda_device_id



  subroutine set_stream_idx(index_in) bind(c, name='set_stream_idx')

    implicit none

    integer, intent(in), value :: index_in

    stream_index = index_in
    cuda_stream = cuda_streams(stream_from_index(stream_index))

  end subroutine set_stream_idx



  subroutine get_stream_idx(index) bind(c, name='get_stream_idx')

    implicit none

    integer, intent(out) :: index

    index = stream_index

  end subroutine get_stream_idx



  integer function stream_from_index(idx)

    implicit none

    integer :: idx

    stream_from_index = MOD(idx, max_cuda_streams) + 1

  end function stream_from_index



#ifdef AMREX_SPACEDIM
  subroutine threads_and_blocks(lo, hi, numBlocks, numThreads)

    use cudafor, only: dim3
    use amrex_error_module, only: amrex_error

    implicit none

    integer,    intent(in   ) :: lo(AMREX_SPACEDIM), hi(AMREX_SPACEDIM)
    type(dim3), intent(inout) :: numBlocks, numThreads

    integer :: tile_size(AMREX_SPACEDIM)
    integer :: numThreadsTotal

    ! Our threading strategy will be to allocate thread blocks
    ! preferring the x direction first to guarantee coalesced accesses.

    tile_size = hi - lo + 1

    if (AMREX_SPACEDIM .eq. 1) then

       numThreads % x = max(numThreadsMin % x, min(tile_size(1), AMREX_CUDA_MAX_THREADS))
       numThreads % y = 1
       numThreads % z = 1

       numBlocks % x = (tile_size(1) + numThreads % x - 1) / numThreads % x
       numBlocks % y = 1
       numBlocks % z = 1

    else if (AMREX_SPACEDIM .eq. 2) then

       numThreads % x = max(numThreadsMin % x, min(tile_size(1), AMREX_CUDA_MAX_THREADS / numThreadsMin % y))
       numThreads % y = max(numThreadsMin % y, min(tile_size(2), AMREX_CUDA_MAX_THREADS / numThreads % x   ))
       numThreads % z = 1

       numBlocks % x = (tile_size(1) + numThreads % x - 1) / numThreads % x
       numBlocks % y = (tile_size(2) + numThreads % y - 1) / numThreads % y
       numBlocks % z = 1

    else

       numThreads % x = max(numThreadsMin % x, min(tile_size(1), min(max_threads_dim(1), AMREX_CUDA_MAX_THREADS / (numThreadsMin % y * numThreadsMin % z))))
       numThreads % y = max(numThreadsMin % y, min(tile_size(2), min(max_threads_dim(2), AMREX_CUDA_MAX_THREADS / (numThreads % x    * numThreadsMin % z))))
       numThreads % z = max(numThreadsMin % z, min(tile_size(3), min(max_threads_dim(3), AMREX_CUDA_MAX_THREADS / (numThreads % x    * numThreads % y   ))))

       numBlocks % x = (tile_size(1) + numThreads % x - 1) / numThreads % x
       numBlocks % y = (tile_size(2) + numThreads % y - 1) / numThreads % y
       numBlocks % z = (tile_size(3) + numThreads % z - 1) / numThreads % z

    endif

    ! Sanity checks

    numThreadsTotal = numThreads % x * numThreads % y * numThreads % z

    ! Should not exceed maximum allowable threads per block.

    if (numThreads % x > max_threads_dim(1)) then
       call amrex_error("Too many CUDA threads per block in x-dimension.")
    end if

    if (numThreads % y > max_threads_dim(2)) then
       call amrex_error("Too many CUDA threads per block in y-dimension.")
    end if

    if (numThreads % z > max_threads_dim(3)) then
       call amrex_error("Too many CUDA threads per block in z-dimension.")
    end if

    if (numThreadsTotal > prop % maxThreadsPerBlock) then
       call amrex_error("Too many CUDA threads per block requested compared to device limit.")
    end if

    ! Blocks or threads should be at least one in every dimension.

    if (min(numThreads % x, numThreads % y, numThreads % z) < 1) then
       call amrex_error("Number of CUDA threads per block must be positive.")
    end if

    if (min(numBlocks % x, numBlocks % y, numBlocks % z) < 1) then
       call amrex_error("Number of CUDA threadblocks must be positive.")
    end if

  end subroutine threads_and_blocks



  subroutine set_threads_and_blocks(lo, hi, txmin, tymin, tzmin) bind(c, name='set_threads_and_blocks')

    use cudafor, only: dim3

    implicit none

    integer, intent(in) :: lo(3), hi(3), txmin, tymin, tzmin

    numThreadsMin % x = txmin
    numThreadsMin % y = tymin
    numThreadsMin % z = tzmin

    call threads_and_blocks(lo, hi, numBlocks, numThreads)

  end subroutine set_threads_and_blocks



  subroutine get_threads_and_blocks(lo, hi, bx, by, bz, tx, ty, tz, txmin, tymin, tzmin) bind(c, name='get_threads_and_blocks')

    use cudafor, only: dim3

    implicit none

    integer, intent(in ) :: lo(3), hi(3)
    integer, intent(in ) :: txmin, tymin, tzmin
    integer, intent(out) :: bx, by, bz, tx, ty, tz

    type(dim3) :: numBlocks, numThreads

    numThreadsMin % x = txmin
    numThreadsMin % y = tymin
    numThreadsMin % z = tzmin

    call threads_and_blocks(lo, hi, numBlocks, numThreads)

    bx = numBlocks%x
    by = numBlocks%y
    bz = numBlocks%z

    tx = numThreads%x
    ty = numThreads%y
    tz = numThreads%z

  end subroutine get_threads_and_blocks
#endif



  subroutine get_num_SMs(num) bind(c, name='get_num_SMs')

    implicit none

    integer, intent(inout) :: num

    if (have_prop) then
       num = prop % multiProcessorCount
    else
       ! Return an invalid number if we have no data.
       num = -1
    end if

  end subroutine get_num_SMs



  subroutine gpu_malloc(x, sz) bind(c, name='gpu_malloc')

    use cudafor, only: cudaMalloc, c_devptr
    use iso_c_binding, only: c_size_t

    implicit none

    type(c_devptr) :: x
    integer(c_size_t) :: sz

    integer :: cudaResult

    cudaResult = cudaMalloc(x, sz)
    call gpu_error_test(cudaResult)

  end subroutine gpu_malloc



  subroutine gpu_hostalloc(x, sz) bind(c, name='gpu_hostalloc')

    use cudafor, only: cudaHostAlloc, cudaHostAllocMapped
    use iso_c_binding, only: c_size_t, c_ptr

    implicit none

    type(c_ptr) :: x
    integer :: sz

    integer :: cudaResult

    cudaResult = cudaHostAlloc(x, sz, cudaHostAllocMapped)
    call gpu_error_test(cudaResult)

  end subroutine gpu_hostalloc



  subroutine gpu_malloc_managed(x, sz) bind(c, name='gpu_malloc_managed')

    use cudafor, only: cudaMallocManaged, cudaMemAttachGlobal, c_devptr
    use iso_c_binding, only: c_size_t
    use amrex_error_module, only: amrex_error

    implicit none

    type(c_devptr) :: x
    integer(c_size_t) :: sz

    integer :: cudaResult

    if ((.not. have_prop) .or. (have_prop .and. prop%managedMemory == 1)) then

       cudaResult = cudaMallocManaged(x, sz, cudaMemAttachGlobal)
       call gpu_error_test(cudaResult)

    else

       call amrex_error("The GPU does not support managed memory allocations")

    end if

  end subroutine gpu_malloc_managed



  subroutine gpu_free(x) bind(c, name='gpu_free')

    use cudafor, only: cudaFree, c_devptr

    implicit none

    type(c_devptr), value :: x

    integer :: cudaResult

    if (is_program_running == 1) then
       cudaResult = cudaFree(x)
       call gpu_error_test(cudaResult)
    end if

  end subroutine gpu_free



  subroutine gpu_freehost(x) bind(c, name='gpu_freehost')

    use cudafor, only: cudaFreeHost
    use iso_c_binding, only: c_ptr

    implicit none

    type(c_ptr), value :: x

    integer :: cudaResult

    if (is_program_running == 1) then
       cudaResult = cudaFreeHost(x)
       call gpu_error_test(cudaResult)
    end if

  end subroutine gpu_freehost



  subroutine gpu_host_device_ptr(x, y) bind(c, name='gpu_host_device_ptr')

    use cudafor, only: cudaHostGetDevicePointer, c_devptr
    use iso_c_binding, only: c_ptr

    type(c_devptr) :: x
    type(c_ptr), value :: y
    integer :: flags

    integer :: cudaResult

    flags = 0 ! This argument does nothing at present, but is part of the API.

    cudaResult = cudaHostGetDevicePointer(x, y, flags)
    call gpu_error_test(cudaResult)

  end subroutine gpu_host_device_ptr



  subroutine gpu_htod_memcpy_async(p_d, p_h, sz, idx) bind(c, name='gpu_htod_memcpy_async')

    use cudafor, only: cudaMemcpyAsync, cudaMemcpyHostToDevice, c_devptr, cuda_stream_kind
    use iso_c_binding, only: c_ptr, c_size_t

    implicit none

    type(c_devptr), value :: p_d
    type(c_ptr), value :: p_h
    integer(c_size_t) :: sz
    integer :: idx

    integer :: cudaResult

    cudaResult = cudaMemcpyAsync(p_d, p_h, sz, cudaMemcpyHostToDevice, cuda_streams(stream_from_index(idx)))
    call gpu_error_test(cudaResult)

  end subroutine gpu_htod_memcpy_async



  subroutine gpu_dtoh_memcpy_async(p_h, p_d, sz, idx) bind(c, name='gpu_dtoh_memcpy_async')

    use cudafor, only: cudaMemcpyAsync, cudaMemcpyDeviceToHost, c_devptr
    use iso_c_binding, only: c_ptr, c_size_t

    implicit none

    type(c_ptr), value :: p_h
    type(c_devptr), value :: p_d
    integer(c_size_t) :: sz
    integer :: idx

    integer :: cudaResult

    cudaResult = cudaMemcpyAsync(p_h, p_d, sz, cudaMemcpyDeviceToHost, cuda_streams(stream_from_index(idx)))
    call gpu_error_test(cudaResult)

  end subroutine gpu_dtoh_memcpy_async



  subroutine gpu_htod_memprefetch_async(p, sz, idx) bind(c, name='gpu_htod_memprefetch_async')

    use cudafor, only: cudaMemPrefetchAsync, c_devptr
    use iso_c_binding, only: c_size_t

    implicit none

    type(c_devptr) :: p
    integer(c_size_t) :: sz
    integer :: idx

    integer :: cudaResult

    if ((.not. have_prop) .or. (have_prop .and. prop%managedMemory == 1 .and. prop%concurrentManagedAccess == 1)) then

       cudaResult = cudaMemPrefetchAsync(p, sz, cuda_device_id, cuda_streams(stream_from_index(idx)))
       call gpu_error_test(cudaResult)

    end if

  end subroutine gpu_htod_memprefetch_async



  subroutine gpu_dtoh_memprefetch_async(p, sz, idx) bind(c, name='gpu_dtoh_memprefetch_async')

    use cudafor, only: cudaMemPrefetchAsync, c_devptr, cudaCpuDeviceId
    use iso_c_binding, only: c_size_t

    implicit none

    type(c_devptr) :: p
    integer(c_size_t) :: sz
    integer :: idx

    integer :: cudaResult

    if ((.not. have_prop) .or. (have_prop .and. prop%managedMemory == 1)) then

       cudaResult = cudaMemPrefetchAsync(p, sz, cudaCpuDeviceId, cuda_streams(stream_from_index(idx)))
       call gpu_error_test(cudaResult)

    end if

  end subroutine gpu_dtoh_memprefetch_async



  subroutine gpu_synchronize() bind(c, name='gpu_synchronize')

    use cudafor, only: cudaDeviceSynchronize

    implicit none

    integer :: cudaResult

    cudaResult = cudaDeviceSynchronize()
    call gpu_error_test(cudaResult)

  end subroutine gpu_synchronize



  subroutine gpu_stream_synchronize(index) bind(c, name='gpu_stream_synchronize')

    use cudafor, only: cudaStreamSynchronize

    implicit none

    integer, intent(in), value :: index

    integer :: cudaResult

    cudaResult = cudaStreamSynchronize(cuda_streams(stream_from_index(index)))
    call gpu_error_test(cudaResult)

  end subroutine gpu_stream_synchronize



  subroutine gpu_start_profiler() bind(c, name='gpu_start_profiler')

    implicit none

    call cudaProfilerStart()

  end subroutine gpu_start_profiler



  subroutine gpu_stop_profiler() bind(c, name='gpu_stop_profiler')

    implicit none

    call cudaProfilerStop()

  end subroutine gpu_stop_profiler



  subroutine gpu_error(cudaResult, abort) bind(c, name='gpu_error')

    use amrex_error_module, only: amrex_error

    implicit none

    integer, intent(in) :: cudaResult
    integer, intent(in), optional :: abort

    character(len=32) :: cudaResultStr
    character(len=128) :: error_string
    integer :: do_abort

    do_abort = 1

    if (present(abort)) then
       do_abort = abort
    end if

    write(cudaResultStr, "(I32)") cudaResult

    error_string = "CUDA Error " // trim(adjustl(cudaResultStr)) // ": " // cudaGetErrorString(cudaResult)

    if (abort == 1) then
       call amrex_error(error_string)
    else
       print *, error_string
    end if

  end subroutine gpu_error



  subroutine gpu_error_test(cudaResult, abort) bind(c, name='gpu_error_test')

    use cudafor, only: cudaErrorCudaRtUnloading

    implicit none

    integer, intent(in) :: cudaResult
    integer, intent(in), optional :: abort

    integer :: do_abort

    do_abort = 1

    if (present(abort)) then
       do_abort = abort
    end if

    ! Don't throw a warning for errors that result from the CUDA runtime
    ! having already been unloaded. These usually occur from CUDA API calls
    ! that occur in, e.g., static object destructors. They don't matter to
    ! the success of the application, so we can silently ignore them.

    if (cudaResult /= cudaSuccess .and. cudaResult /= cudaErrorCudaRtUnloading) then
       call gpu_error(cudaResult, do_abort)
    end if

  end subroutine gpu_error_test



  ! Check if any kernels or previous API calls have returned an error code.
  ! Abort if so.

  subroutine check_for_gpu_errors() bind(c, name='check_for_gpu_errors')

    use cudafor, only: cudaGetLastError

    implicit none

    integer :: cudaResult

    cudaResult = cudaGetLastError()

    call gpu_error_test(cudaResult)

  end subroutine check_for_gpu_errors

end module cuda_module
