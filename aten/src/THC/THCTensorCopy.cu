#include "THCApply.cuh"
#include "THCHalf.h"
#include "THCNumerics.cuh"
#include "THCTensorCopy.hpp"
#include <type_traits>

inline int curGPU() {
  int curDev;
  THCudaCheck(cudaGetDevice(&curDev));
  return curDev;
}

// Copy operator for the pointwise apply kernel
template <typename TypeDst, typename TypeSrc>
struct CopyOp {
  __device__ __forceinline__ void operator()(TypeDst* dst, TypeSrc* src) {
#if __CUDA_ARCH__ >= 350
    *dst = ScalarConvert<TypeSrc, TypeDst>::to(__ldg(src));
#else
    *dst = ScalarConvert<TypeSrc, TypeDst>::to(*src);
#endif
  }
};

// Copy for the same type to the same type
template <typename ScalarTypeDst, typename ScalarTypeSrc>
void THC_copyTensor(THCState* state, _THCTensor* dst, _THCTensor* src) {

  ptrdiff_t totalElements = THCTensor_nElement(state, dst);

  THArgCheck(totalElements ==
             THCTensor_nElement(state, src),
             2, "sizes do not match");

  if (THCTensor_nDimension(state, dst) == 0) {
    // Zero-dim tensor; copy nothing
    return;
  }

  // We can memcpy the memory if:
  // -both tensors are contiguous; or,
  // -there is only one element to copy; or,
  // -FIXME: if both tensors have matching size and stride arrays, and no
  // holes within (in other words, there is some permutation that can be applied
  // to the size/strides such that the resulting tensor is
  // contiguous).
  // -AND: both tensors have the same type.
  bool sameType = std::is_same<ScalarTypeDst, ScalarTypeSrc>::value;
  bool srcContig = THCTensor_isContiguous(state, src);
  bool dstContig = THCTensor_isContiguous(state, dst);
  bool memcpyEligible =
    ((srcContig && dstContig) || (totalElements == 1)) && sameType;

  int srcDev = THCTensor_getDevice(state, src);
  int dstDev = THCTensor_getDevice(state, dst);
  int oldDev = curGPU();

  // Try to enable p2p access. This also handles the case srcDev == dstDev.
  bool p2pEnabled = THCState_getPeerToPeerAccess(state, srcDev, dstDev);

  // We always perform the copy on the source device, using the
  // current stream on the source device.
  // If the copy is on the default stream, then we fully synchronize
  // both src and dst's default streams for completion of the
  // copy. We have to explicitly do this for non-contig copies.
  // This mimics the behavior of cross-device cudaMemcpyAsync on
  // the default stream.
  // If the copy is not on the default stream, then it is up to the
  // user to add needed synchronization on the dst device, since the
  // stream on the dst device that wishes to synchronize may not be
  // the same index as the one on the src device.
  cudaStream_t copyStream = THCState_getCurrentStreamOnDevice(state, srcDev);
  if (srcDev != dstDev && copyStream == NULL) {
    // This is a cross-device copy on the default stream. We perform a
    // two-way barrier between both devices' default streams before
    // the copy. This ensures that any write-after-write and
    // write-after-read dependencies on the destination side are
    // handled, so that no one is operating on the dst memory when
    // we perform the copy.
    // src waits on dst barrier (src already waits on src)
    cudaEvent_t dstReady;
    THCudaCheck(cudaSetDevice(dstDev));
    THCudaCheck(cudaEventCreateWithFlags(&dstReady, cudaEventDisableTiming));
    THCudaCheck(cudaEventRecord(dstReady, NULL));

    THCudaCheck(cudaSetDevice(srcDev));
    THCudaCheck(cudaStreamWaitEvent(NULL, dstReady, 0));
    THCudaCheck(cudaEventDestroy(dstReady));
  } else if (srcDev != oldDev) {
    THCudaCheck(cudaSetDevice(srcDev));
  }

  // We are now on srcDev
  if (memcpyEligible) {
    // Perform the copy
    THCudaCheck(cudaMemcpyAsync(
                  dst->template data<ScalarTypeDst>(),
                  src->template data<ScalarTypeSrc>(),
                  totalElements *
                  sizeof(ScalarTypeDst),
                  cudaMemcpyDeviceToDevice,
                  copyStream));
  } else {
    // Non-contiguous copy or a type-conversion copy

    // We avoid creating temporary memory copies if possible.
    // If both src and dst are on the same device, or if they are on
    // different devices and p2p access is enabled, perform the copy
    // by a pointwise copy kernel.
    // Otherwise, we'll have to make contiguous (which will in fact
    // invoke copy() again), and then perform the copy.
    // FIXME: might want to consider only running the pointwise kernel
    // if both src and dst innermost dimensions are contiguous. If
    // they are not, then taking the hit of the memory allocation/free
    // might be worth it to avoid non-coalesced reads or writes.
    if (p2pEnabled) {
      bool succ =
        THC_pointwiseApply2<ScalarTypeDst,
                            ScalarTypeSrc>(
          state, dst, src,
          CopyOp<ScalarTypeDst,
                 ScalarTypeSrc>());

      THArgCheck(succ, 2, CUTORCH_DIM_WARNING);
    } else {
      // GPUs can't access each other directly, but the tensors
      // involved are non-contiguous and/or are different types.

      // Make sure the src is contiguous and in the same type as dst
      THCudaCheck(cudaSetDevice(srcDev));
      _THCTensor* srcContig = NULL;

      if (sameType) {
        srcContig = THCTensor_newContiguous<ScalarTypeSrc>(state, src);

      } else {
        // Types are different
        // Copy into the new format, contiguous, on the source device
        srcContig = THCTensor_new(state,
                                  at::CTypeToScalarType<at::cuda::from_type<ScalarTypeDst>>::to());
        THCTensor_resizeAs(state, srcContig, dst);

        bool succ =
          THC_pointwiseApply2<ScalarTypeDst,
                              ScalarTypeSrc>(
            state, srcContig, src,
            CopyOp<ScalarTypeDst,
                   ScalarTypeSrc>());

        THArgCheck(succ, 2, CUTORCH_DIM_WARNING);
      }

      // Make sure the dst is contiguous
      THCudaCheck(cudaSetDevice(dstDev));
      _THCTensor* dstContig = THCTensor_newContiguous<ScalarTypeDst>(state, dst);

      // Now, we are ready for a cross-device memcpy of contiguous
      // data, of the same layout and type
      THCudaCheck(cudaSetDevice(srcDev));

      THCudaCheck(cudaMemcpyAsync(
                    dstContig->template data<ScalarTypeDst>(),
                    srcContig->template data<ScalarTypeDst>(),
                    totalElements *
                    sizeof(ScalarTypeDst),
                    cudaMemcpyDeviceToDevice,
                    copyStream));

      // We are done with the src
      THCTensor_free(state, srcContig);

      if (dst != dstContig) {
        THCTensor_freeCopyTo<ScalarTypeDst>(state, dstContig, dst);
      } else {
        THCTensor_free(state, dstContig);
      }

      // We're still on srcDev at this point
    }
  }

  if (srcDev != dstDev && copyStream == NULL) {
    // dst waits on src barrier (dst already waits on dst). We cannot
    // operate on dst's copy until the copy is complete.

    // Still on srcDev, record default stream event
    cudaEvent_t srcReady;
    THCudaCheck(cudaEventCreateWithFlags(&srcReady, cudaEventDisableTiming));
    THCudaCheck(cudaEventRecord(srcReady, NULL));

    THCudaCheck(cudaSetDevice(dstDev));
    THCudaCheck(cudaStreamWaitEvent(NULL, srcReady, 0));
    THCudaCheck(cudaEventDestroy(srcReady));

    // We are now on dstDev (right above). Restore prior device from dst
    if (dstDev != oldDev) {
      THCudaCheck(cudaSetDevice(oldDev));
    }
  } else {
    // We are still on srcDev. Restore prior device from src
    if (srcDev != oldDev) {
      THCudaCheck(cudaSetDevice(oldDev));
    }
  }

  THCudaCheck(cudaGetLastError());
}

#include "generic/THCTensorCopy.cu"
#include "THCGenerateAllTypes.h"
