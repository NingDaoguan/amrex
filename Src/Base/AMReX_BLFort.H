#ifndef AMREX_BLFORT_H_
#define AMREX_BLFORT_H_

#include <AMReX_ArrayLim.H>
#include <AMReX_REAL.H>
#include <AMReX_SPACE.H>

#ifndef BL_LANG_FORT

#if   defined(BL_FORT_USE_UPPERCASE)
#define __BL_FORT_NAME__(A,B) A
#elif defined(BL_FORT_USE_LOWERCASE)
#define __BL_FORT_NAME__(A,B) B
#elif defined(BL_FORT_USE_UNDERSCORE)
#define __BL_FORT_NAME__(A,B) B##_
#else
#error "One of BL_FORT_USE_{UPPERCASE,LOWERCASE,UNDERSCORE} must be defined"
#endif

#ifdef __cplusplus
#define BL_FORT_PROC_DECL(A,B) extern "C" void __BL_FORT_NAME__(A,B)
#else
#define BL_FORT_PROC_DECL(A,B) void __BL_FORT_NAME__(A,B)
#endif
#define BL_FORT_PROC_CALL(A,B) __BL_FORT_NAME__(A,B)
#define BL_FORT_PROC_NAME(A,B) __BL_FORT_NAME__(A,B)

#define BL_FORT_FAB_ARG(A) amrex_real* A##_fab, AMREX_ARLIM_P(A##_lo), AMREX_ARLIM_P(A##_hi)
#define BL_FORT_IFAB_ARG(A) int* A##_fab, AMREX_ARLIM_P(A##_lo), AMREX_ARLIM_P(A##_hi)
#define BL_FORT_FAB_VAL_3D(A) A##_fab, A##_lo, A##_hi
#define BL_FORT_FAB_ARG_3D(A) amrex_real* A##_fab, const int* A##_lo, const int* A##_hi
#define BL_FORT_FAB_ARG_ANYD(A) amrex_real* A##_fab, const int* A##_lo, const int* A##_hi
#define BL_FORT_IFAB_ARG_3D(A) int* A##_fab, const int* A##_lo, const int* A##_hi
#define BL_FORT_IFAB_ARG_ANYD(A) int* A##_fab, const int* A##_lo, const int* A##_hi

#endif

// Define a macro that launches a Fortran function. For normal
// CPU code, it does nothing -- only launches the function. For
// GPU code, it launches a kernel using the first two arguments
// as bounds of the box to launch the kernel on.

// The form of the function launch MUST be:
// AMREX_FORT_LAUNCH(box, function, ...)
// where everything after the function name (represented here by ...)
// are the actual function arguments, as defined in the Fortran subroutine.
// box is the current Box for this MFIter iteration.

#if defined(AMREX_USE_GPU) && defined(__CUDACC__)

#include <AMReX_Gpu.H>

#define AMREX_FORT_LAUNCH(box, function, ...)  \
    { \
      dim3 numBlocks, numThreads; \
      amrex::Gpu::Device::c_threads_and_blocks(box.loVect(), box.hiVect(), numBlocks, numThreads); \
      function<<<numBlocks, numThreads, 0, amrex::Gpu::Device::cudaStream()>>>(__VA_ARGS__); \
      CudaErrorCheck(); \
    }

#define AMREX_FORT_LAUNCHABLE(func) __global__ func

#define AMREX_FORT_LAUNCH_PARTICLES(num_particles, function, ...) \
    { \
        int numThreads; int numBlocks; \
        amrex::Gpu::Device::particle_threads_and_blocks(num_particles, numThreads, numBlocks); \
        function<<<numBlocks, numThreads, 0, amrex::Gpu::Device::cudaStream()>>>(__VA_ARGS__); \
        CudaErrorCheck(); \
    }

#define AMREX_FORT_LAUNCH_PARTICLES_STREAM(num_particles, stream, function, ...)      \
    { \
        int numThreads; int numBlocks; \
        amrex::Gpu::Device::particle_threads_and_blocks(num_particles, numThreads, numBlocks); \
        amrex::Print() << amrex::Gpu::Device::stream_from_index(stream) << std::endl; \
        function<<<numBlocks, numThreads, 0, amrex::Gpu::Device::stream_from_index(stream)>>>(__VA_ARGS__); \
        CudaErrorCheck(); \
    }

#else

#define AMREX_FORT_LAUNCH(box, function, ...) function(__VA_ARGS__)
#define AMREX_FORT_LAUNCHABLE(func) func
#define AMREX_FORT_LAUNCH_PARTICLES(num_particles, function, ...) function(__VA_ARGS__)
#define AMREX_FORT_LAUNCH_PARTICLES_STREAM(num_particles, stream, function, ...) function(__VA_ARGS__)

#endif

#endif

// This macro "deletes" a function when we're using CUDA,
// so that a script can replace it.

#ifdef AMREX_USE_GPU
#define AMREX_DEVICE_LAUNCHABLE(func) null##func
#define AMREX_DEVICE_LAUNCHABLE_STRIDED(func) null##func
#else
#define AMREX_DEVICE_LAUNCHABLE(func) func
#define AMREX_DEVICE_LAUNCHABLE_STRIDED(func) func
#endif

// Decorate the calls to the GPU.

#if defined(AMREX_USE_GPU) && defined(__CUDACC__)

#if ((__CUDACC_VER_MAJOR__ > 9) || (__CUDACC_VER_MAJOR__ == 9 && __CUDACC_VER_MINOR__ >= 1))

#define AMREX_DEVICE_LAUNCH(function)                         \
      dim3 function##numBlocks, function##numThreads; \
      amrex::Gpu::Device::grid_stride_threads_and_blocks(function##numBlocks, function##numThreads); \
      CudaAPICheck(cudaFuncSetAttribute(&cuda_##function, cudaFuncAttributePreferredSharedMemoryCarveout, 0)); \
      cuda_##function<<<function##numBlocks, function##numThreads, 0, amrex::Gpu::Device::cudaStream()>>> \

#else

#define AMREX_DEVICE_LAUNCH(function)                         \
      dim3 function##numBlocks, function##numThreads; \
      amrex::Gpu::Device::grid_stride_threads_and_blocks(function##numBlocks, function##numThreads); \
      cuda_##function<<<function##numBlocks, function##numThreads, 0, amrex::Gpu::Device::cudaStream()>>> \

#endif

#else

#define AMREX_DEVICE_LAUNCH(function) function

#endif

// Define macros for doing reductions.

#if (defined(AMREX_USE_GPU) && !defined(AMREX_NO_DEVICE_LAUNCH))
#define AMREX_MFITER_REDUCE_SUM(var) mfi.add_reduce_value(var, amrex::MFIter::SUM)
#define AMREX_MFITER_REDUCE_MIN(var) mfi.add_reduce_value(var, amrex::MFIter::MIN)
#define AMREX_MFITER_REDUCE_MAX(var) mfi.add_reduce_value(var, amrex::MFIter::MAX)
#else
#define AMREX_MFITER_REDUCE_SUM(var) var
#define AMREX_MFITER_REDUCE_MIN(var) var
#define AMREX_MFITER_REDUCE_MAX(var) var
#endif
