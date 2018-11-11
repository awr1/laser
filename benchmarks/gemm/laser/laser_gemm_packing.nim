# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

# Due to issue with "static MicroKernel" as parameter
# as of 0.19.9 we pass it as a generic param
#   - 1. undeclared identifier mr/nr, when accessing ukernel
#   - 2. object constructor needs and object type when workaround first issue with macro

import
  ./laser_gemm_matrix,
  ./laser_gemm_utils,
  ./laser_gemm_tiling

# ##############
#
# Packing A
#
# ##############

proc pack_mr_kc[T; ukernel: static MicroKernel](
      buffer: ptr UncheckedArray[T],
      kc: int,
      A: var MatrixView[T]) {.sideeffect.}=
  ## Packs micro-panel [mr, kc] for buffer Ã[mc, kc] (half-L2 cache)

  ## ⚠ Warning, the buffer pointer will be moved even though it's not a var.
  ##     Unfortunately if it's made into a var, Nim will use a hidden pointer
  ##     and it's the hidden pointer that will be moved :/.
  const MR = ukernel.extract_mr

  assert A.ncols == kc
  while true:
    for i in `||`(0, MR-1, "simd"): # TODO can use _mm_i32gather_ps on AVX
      buffer[i] = A[i, 0]
    buffer += MR
    if 0 < A.ncols:
      break
    A.incCol()

proc pack_A_mc_kc*[T; ukernel: static MicroKernel](
      buffer: ptr UncheckedArray[T],
      kc: int,
      A: MatrixView[T]) =
  ## Packs panel [mc, kc] into buffer Ã (size ~half-L2 cache)
  ## Pads if needed
  ## Buffer uses Z-ordering so that the ukernel can access contiguous
  ## chunks of memory for the dot product

  ## ⚠ Warning, the buffer pointer will be moved even though it's not a var.
  ##     Unfortunately if it's made into a var, Nim will use a hidden pointer
  ##     and it's the hidden pointer that will be moved :/.
  const MR = ukernel.extract_mr
  let
    mb = A.nrows div MR
    mr = A.nrows mod MR

  var A = A
  echo "MR: ", MR
  echo "A[3, 3]: ": A[3,  3]

  for i in countup(0, A.nrows-1, MR):
    for k in 0 ..< kc:
      for ii in 0 ..< MR:
        buffer[ii] = A[i*MR+ii, k]
      buffer += MR
    buffer += kc*MR

  echo "mr: ", mr
  echo "A[0,  0]: ": A[0,  0]
  echo "A[0,  1]: ": A[0,  1]
  echo "A[0,  2]: ": A[0,  2]
  echo "A[0, -1]: ": A[0, -1]
  echo "A[0, -2]: ": A[0, -2]
  echo "A[0, -3]: ": A[0, -3]
  echo "A[0, -4]: ": A[0, -4]

  echo "A[A.nrows-mr, 0]: ": A[A.nrows-mr, 0]
  echo "mr: ", mr
  if mr > 0:
    for i in A.nrows-mr ..< A.nrows+2:
      buffer[i] = A[i, 0]
      echo "buffer i: ", buffer[i]
    for i in A.nrows ..< A.nrows + MR:
      buffer[i] = 0.T
    buffer += MR

proc pack_kc_nr[T; ukernel: static MicroKernel](
      buffer: ptr UncheckedArray[T],
      kc: int,
      B: var MatrixView[T]) {.sideeffect.}=
  ## Packs micro-panel kc*nr for ~B (half-L1 cache)

  ## ⚠ Warning, the buffer pointer will be moved even though it's not a var.
  ##     Unfortunately if it's made into a var, Nim will use a hidden pointer
  ##     and it's the hidden pointer that will be moved :/.
  const NR = ukernel.extract_nr

  assert B.nrows == kc
  while true:
    for j in `||`(0, NR-1, "simd"):
      buffer[j] = B[0, j]
    buffer += NR
    if 0 < B.nrows:
      break
    B.incRow()

proc pack_B_kc_nc*[T; ukernel: static MicroKernel](
      buffer: ptr UncheckedArray[T],
      kc: int,
      B: var MatrixView[T]) =
  ## Packs panel [kc, nc] for ~B (half-L1 cache)
  ## Pads if needed
  ## Buffer uses Z-ordering so that the ukernel can access contiguous
  ## chunks of memory for the dot product

  ## ⚠ Warning, the buffer pointer will be moved even though it's not a var.
  ##     Unfortunately if it's made into a var, Nim will use a hidden pointer
  ##     and it's the hidden pointer that will be moved :/.

  # Copy panels of B into the kc*nc buffer
  # Copy uses a tile of dimension kc*nr
  const NR = ukernel.extract_nr


  for j in countup(0, B.ncols-1, NR):
    for k in 0 ..< kc:
      for jj in 0 ..< NR:
        buffer[jj] = B[k, j*NR+jj]
      buffer += NR
    buffer += kc*NR

  # Process the tail
  if B.ncols > 0:
    let nr = B.ncols
    for i in 0 ..< kc:
      for j in 0 ..< nr:
        buffer[j] = B[0, j]
      for j in nr ..< NR:
        # Padding
        buffer[j] = 0.T
      buffer += NR
      B.incRow()
